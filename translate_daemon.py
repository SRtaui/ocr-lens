#!/usr/bin/env python3
"""EN->RU translation daemon for ocr-lens.

Engines, tried in order for every request:
  1. Google Translate (free, no key; parallel requests on kept-alive connections)
  2. local LLM (llama.cpp server + Qwen2.5-3B-Instruct, started on demand)

Protocol: client connects, sends one line of JSON {"texts": [...]},
server replies one line {"translations": [...], "engine": "..."} (or {"error": "..."}).
Exits itself after IDLE_TIMEOUT seconds without requests; llama-server is stopped
after LLM_IDLE seconds without use to give the RAM back.
"""
import glob
import http.client
import json
import os
import signal
import socket
import socketserver
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DATA_DIR = os.path.expanduser("~/.local/share/ocr-lens")
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or DATA_DIR
SOCK_PATH = os.path.join(RUNTIME_DIR, "ocr-lens-translate.sock")

IDLE_TIMEOUT = 600
LLM_IDLE = 300
LLM_PORT = 18080
LLM_SLOTS = 3
LLM_MODEL = os.path.join(DATA_DIR, "llm", "qwen2.5-3b-instruct-q4_k_m.gguf")
LLM_BIN = (glob.glob(os.path.join(DATA_DIR, "llama", "*", "llama-server")) or [""])[0]

LLM_SYSTEM = (
    "You are a professional English-to-Russian translator. Translate the user's text "
    "into natural, fluent Russian. Keep numbers, names, code and product names intact. "
    "Output only the translation, without comments or quotes."
)

last_used = time.time()
log = lambda *a: print(*a, flush=True)


def has_letters(s):
    return any(c.isalpha() for c in s)


# ----------------------------------------------------------------- Google
class Google:
    """Free keyless Google Translate endpoint: one POST per text block, run in parallel
    on kept-alive HTTPS connections (one per worker thread)."""
    HOST = "translate.googleapis.com"
    HEADERS = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36",
               "Content-Type": "application/x-www-form-urlencoded"}
    WORKERS = 6

    def __init__(self):
        self.pool = ThreadPoolExecutor(self.WORKERS)
        self.local = threading.local()
        self.down_until = 0.0

    def available(self):
        return time.time() >= self.down_until

    def _conn(self, fresh=False):
        c = getattr(self.local, "conn", None)
        if c is None or fresh:
            if c is not None:
                c.close()
            c = self.local.conn = http.client.HTTPSConnection(self.HOST, timeout=5)
        return c

    def _one(self, text):
        body = urllib.parse.urlencode({"client": "gtx", "sl": "en", "tl": "ru", "dt": "t", "q": text})
        for attempt in (1, 2):  # a kept-alive connection may have gone stale
            try:
                c = self._conn(fresh=attempt == 2)
                c.request("POST", "/translate_a/single", body, self.HEADERS)
                r = c.getresponse()
                raw = r.read()
                break
            except (OSError, http.client.HTTPException):
                if attempt == 2:
                    raise
        if r.status != 200:
            raise RuntimeError(f"HTTP {r.status}")
        return "".join(seg[0] for seg in json.loads(raw)[0] if seg and seg[0]) or text

    def _warm(self, _):
        self._conn().connect()

    def prewarm(self):
        """Open the TLS connections now; returns False if Google is unreachable."""
        try:
            list(self.pool.map(self._warm, range(self.WORKERS)))
            return True
        except OSError:
            return False

    def translate(self, texts):
        try:
            return list(self.pool.map(lambda t: self._one(t) if has_letters(t) else t, texts))
        except Exception as e:
            # 429 means we were rate limited: back off longer before trying again
            self.down_until = time.time() + (120 if "429" in str(e) else 20)
            raise RuntimeError(f"Google: {e}")


# -------------------------------------------------------------- local LLM
class LocalLLM:
    def __init__(self):
        self.lock = threading.Lock()
        self.proc = None
        self.last_used = 0.0
        self.pool = ThreadPoolExecutor(LLM_SLOTS)

    def installed(self):
        return bool(LLM_BIN) and os.path.exists(LLM_BIN) and os.path.exists(LLM_MODEL)

    def _healthy(self):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{LLM_PORT}/health", timeout=1) as r:
                return r.status == 200
        except OSError:
            return False

    def ensure(self, wait=True):
        with self.lock:
            if self.proc and self.proc.poll() is None and self._healthy():
                return True
            if not self.proc or self.proc.poll() is not None:
                log("starting llama-server")
                self.proc = subprocess.Popen(
                    [LLM_BIN, "-m", LLM_MODEL, "--host", "127.0.0.1", "--port", str(LLM_PORT),
                     "-c", str(LLM_SLOTS * 2048), "-np", str(LLM_SLOTS), "-t", "6",
                     "-fa", "on", "--no-webui", "--reasoning-budget", "0"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
            if not wait:
                return True
            deadline = time.time() + 90
            while time.time() < deadline:
                if self._healthy():
                    return True
                if self.proc.poll() is not None:
                    return False
                time.sleep(0.15)
            return False

    def stop(self):
        with self.lock:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            self.proc = None

    def _one(self, text):
        if not has_letters(text):
            return text
        req = {"messages": [{"role": "system", "content": LLM_SYSTEM},
                            {"role": "user", "content": text}],
               "temperature": 0, "max_tokens": int(len(text) * 1.5) + 48, "cache_prompt": True}
        r = urllib.request.Request(f"http://127.0.0.1:{LLM_PORT}/v1/chat/completions",
                                   json.dumps(req).encode(), {"Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=120) as resp:
            return json.loads(resp.read())["choices"][0]["message"]["content"].strip() or text

    def translate(self, texts):
        if not self.installed():
            raise RuntimeError("local LLM is not installed")
        if not self.ensure():
            raise RuntimeError("llama-server failed to start")
        self.last_used = time.time()
        out = list(self.pool.map(self._one, texts))
        self.last_used = time.time()
        return out


google, llm = Google(), LocalLLM()


def translate_batch(texts):
    idx = [i for i, t in enumerate(texts) if has_letters(t)]
    result = list(texts)
    if not idx:
        return result, "none"
    todo = [texts[i] for i in idx]
    engines = []
    if google.available():
        engines.append(("Google", google.translate))
    engines.append(("локальная LLM", llm.translate))
    errors = []
    for name, fn in engines:
        try:
            for i, t in zip(idx, fn(todo)):
                result[i] = t
            return result, name
        except Exception as e:
            log(f"{name} failed: {e}")
            errors.append(f"{name}: {e}")
    raise RuntimeError("; ".join(errors))


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        global last_used
        line = self.rfile.readline()
        if not line:
            return
        last_used = time.time()
        try:
            texts = json.loads(line)["texts"]
            translations, engine = translate_batch(texts)
            resp = {"translations": translations, "engine": engine}
        except Exception as e:
            resp = {"error": str(e)}
        last_used = time.time()
        self.wfile.write((json.dumps(resp, ensure_ascii=False) + "\n").encode())


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def background_warmup():
    """Get the preferred engine ready before the first request arrives."""
    if google.prewarm():
        return
    if llm.installed():  # no internet: have the local model loaded and waiting
        llm.ensure()


def watchdog(server):
    while True:
        time.sleep(5)
        now = time.time()
        if llm.proc and llm.last_used and now - llm.last_used > LLM_IDLE:
            log("stopping idle llama-server")
            llm.stop()
            llm.last_used = 0.0
        if now - last_used > IDLE_TIMEOUT:
            server.shutdown()
            return


def main():
    try:
        os.unlink(SOCK_PATH)
    except OSError:
        pass
    server = Server(SOCK_PATH, Handler)
    os.chmod(SOCK_PATH, 0o600)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    log(f"listening on {SOCK_PATH}")
    threading.Thread(target=background_warmup, daemon=True).start()
    threading.Thread(target=watchdog, args=(server,), daemon=True).start()
    try:
        server.serve_forever()
    finally:
        llm.stop()
        try:
            os.unlink(SOCK_PATH)
        except OSError:
            pass


if __name__ == "__main__":
    main()

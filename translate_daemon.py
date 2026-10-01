"""Локальный демон перевода для ocr-lens (Argos Translate / CTranslate2).

Держит модель в памяти, чтобы каждый перевод не ждал её загрузки.
Протокол: одна строка JSON {"texts": [...]} -> одна строка {"translations": [...]}.
Сам завершается после IDLE_EXIT секунд без запросов.
"""
import json
import os
import socket
import threading
import time

import argostranslate.translate as at

SRC, DST = "en", "ru"
IDLE_EXIT = 30 * 60
DATA_DIR = os.path.expanduser("~/.local/share/ocr-lens")
SOCK_PATH = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or DATA_DIR, "ocr-lens-translate.sock")

translator = at.get_translation_from_codes(SRC, DST)
lock = threading.Lock()
last_used = time.monotonic()


def handle(conn):
    global last_used
    with conn:
        try:
            req = json.loads(conn.makefile("r").readline())
            with lock:
                trs = [translator.translate(t) if t.strip() else t for t in req["texts"]]
            resp = {"translations": trs}
        except Exception as e:
            resp = {"error": str(e)}
        last_used = time.monotonic()
        conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode())


def idle_watch(srv):
    while time.monotonic() - last_used < IDLE_EXIT:
        time.sleep(30)
    srv.close()
    os._exit(0)


def main():
    if os.path.exists(SOCK_PATH):
        os.remove(SOCK_PATH)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o600)
    srv.listen(8)
    threading.Thread(target=idle_watch, args=(srv,), daemon=True).start()
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=handle, args=(conn,), daemon=True).start()
    finally:
        if os.path.exists(SOCK_PATH):
            os.remove(SOCK_PATH)


if __name__ == "__main__":
    main()

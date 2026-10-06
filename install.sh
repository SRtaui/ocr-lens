#!/usr/bin/env bash
# Установщик ocr-lens.
#   ./install.sh               — установить / обновить
#   ./install.sh --no-llm      — без локальной LLM (офлайн-перевод не будет работать)
#   ./install.sh --uninstall   — удалить
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/ocr-lens"
LLM_DIR="$DATA_DIR/llm"
LLAMA_DIR="$DATA_DIR/llama"
MODEL_FILE="qwen2.5-3b-instruct-q4_k_m.gguf"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/$MODEL_FILE"
CMD="$BIN_DIR/ocr-lens"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { [ -r /dev/tty ] || return 1; read -r -p "$1 [y/N] " a < /dev/tty; [[ "$a" =~ ^[YyДд]$ ]]; }
ask_yes() { [ -r /dev/tty ] || return 0; read -r -p "$1 [Y/n] " a < /dev/tty; [[ ! "$a" =~ ^[NnНн]$ ]]; }

# ---------- удаление ----------
if [ "${1:-}" = "--uninstall" ]; then
  pkill -f "$DATA_DIR/translate_daemon.py" 2>/dev/null || true
  pkill -f "$LLAMA_DIR/.*/llama-server" 2>/dev/null || true
  rm -f "$CMD"
  rm -rf "$DATA_DIR"
  say "ocr-lens удалён. Системные пакеты и строка хоткея в конфиге не тронуты."
  exit 0
fi

[ "$(id -u)" -ne 0 ] || die "запускайте без sudo — пароль спросится только для системных пакетов."
for f in ocr-lens translate_daemon.py; do
  [ -f "$SRC_DIR/$f" ] || die "не найден $f рядом с install.sh"
done

# ---------- проверка окружения ----------
if [ "${XDG_SESSION_TYPE:-}" != "wayland" ]; then
  warn "Сессия не Wayland (${XDG_SESSION_TYPE:-неизвестно}). ocr-lens работает только в Wayland."
  ask "Всё равно продолжить?" || exit 1
fi
case "${XDG_CURRENT_DESKTOP:-}" in
  *GNOME*) warn "GNOME не поддерживает layer-shell и grim — ocr-lens там не запустится."
           ask "Всё равно продолжить?" || exit 1 ;;
esac

# ---------- 1. системные пакеты ----------
say "Установка системных пакетов"
if command -v pacman >/dev/null; then
  sudo pacman -S --needed --noconfirm python python-gobject python-cairo gtk3 gtk-layer-shell \
    grim tesseract tesseract-data-eng wl-clipboard curl
elif command -v apt-get >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 \
    gir1.2-gtklayershell-0.1 grim tesseract-ocr tesseract-ocr-eng wl-clipboard curl
elif command -v dnf >/dev/null; then
  sudo dnf install -y python3 python3-gobject python3-cairo gtk3 gtk-layer-shell \
    grim tesseract tesseract-langpack-eng wl-clipboard curl
elif command -v zypper >/dev/null; then
  sudo zypper --non-interactive install python3 python3-gobject python3-gobject-cairo \
    python3-gobject-Gdk typelib-1_0-Gtk-3_0 typelib-1_0-GtkLayerShell-0_1 \
    grim tesseract-ocr tesseract-ocr-traineddata-english wl-clipboard curl
else
  warn "Неизвестный пакетный менеджер. Установите вручную: PyGObject (GTK3 + cairo),"
  warn "gtk-layer-shell, grim, tesseract + английская модель, wl-clipboard, curl."
  ask "Пакеты уже установлены, продолжить?" || exit 1
fi

# системный python (не pyenv/conda), иначе не будет gi
SYS_PY=/usr/bin/python3
[ -x "$SYS_PY" ] || SYS_PY="$(command -v python3)"

say "Проверка зависимостей"
"$SYS_PY" - <<'PY' || die "PyGObject или gtk-layer-shell не найдены"
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, GtkLayerShell, PangoCairo
PY
command -v grim >/dev/null      || die "grim не установлен"
command -v tesseract >/dev/null || die "tesseract не установлен"
tesseract --list-langs 2>&1 | grep -qx eng || die "нет модели tesseract 'eng'"

# ---------- 2. локальная LLM (офлайн-режим) ----------
# Онлайн ocr-lens переводит через Google (ничего ставить не нужно). Локальная модель
# нужна только когда интернета нет.
mkdir -p "$DATA_DIR" "$BIN_DIR"
install_llm() {
  local arch url tmp
  case "$(uname -m)" in
    x86_64)        arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) warn "Архитектура $(uname -m) не поддерживается — локальная LLM пропущена."; return ;;
  esac

  if ! ls "$LLAMA_DIR"/*/llama-server >/dev/null 2>&1; then
    say "Загрузка llama.cpp (CPU-сборка)"
    url="$("$SYS_PY" - "$arch" <<'PY'
import json, re, sys, urllib.request
pat = re.compile(r"llama-b\d+-bin-ubuntu-%s\.tar\.gz$" % sys.argv[1])
rels = json.load(urllib.request.urlopen(
    "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10", timeout=30))
for r in rels:
    for a in r["assets"]:
        if pat.search(a["name"]):
            print(a["browser_download_url"]); raise SystemExit
raise SystemExit(1)
PY
    )" || { warn "Не удалось найти сборку llama.cpp — локальная LLM пропущена."; return; }
    tmp="$(mktemp -d)"
    curl -fL --progress-bar -o "$tmp/llama.tgz" "$url" || { rm -rf "$tmp"; warn "Не скачалась llama.cpp."; return; }
    rm -rf "$LLAMA_DIR"; mkdir -p "$LLAMA_DIR"
    tar xzf "$tmp/llama.tgz" -C "$LLAMA_DIR"
    rm -rf "$tmp"
  fi

  if [ ! -f "$LLM_DIR/$MODEL_FILE" ]; then
    say "Загрузка модели Qwen2.5-3B (~2 ГБ, докачивается при обрыве)"
    mkdir -p "$LLM_DIR"
    curl -fL -C - --progress-bar -o "$LLM_DIR/$MODEL_FILE" "$MODEL_URL" \
      || { warn "Модель не скачалась — запустите ./install.sh ещё раз."; return; }
  fi
  say "Локальная LLM готова"
}
if [ "${1:-}" = "--no-llm" ]; then
  warn "Локальная LLM пропущена: без интернета перевод работать не будет."
elif ask_yes "Скачать локальную LLM (~2 ГБ) для перевода без интернета?"; then
  install_llm
else
  warn "Локальная LLM пропущена: без интернета перевод работать не будет."
fi

# ---------- 3. файлы ----------
say "Копирование файлов"
install -m 644 "$SRC_DIR/translate_daemon.py" "$DATA_DIR/translate_daemon.py"
{ echo "#!$SYS_PY"; sed '1{/^#!/d}' "$SRC_DIR/ocr-lens"; } > "$CMD"
chmod 755 "$CMD"
[ "$(head -c 2 "$CMD")" = "#!" ] || die "в $CMD не записался shebang — установка повреждена"
pkill -f "$DATA_DIR/translate_daemon.py" 2>/dev/null || true   # старый демон перезапустится сам
pkill -f "$LLAMA_DIR/.*/llama-server" 2>/dev/null || true

# ---------- 4. хоткей ----------
setup_hotkey() {
  local cfg line
  if [ -f "$HOME/.config/hypr/hyprland.lua" ]; then
    cfg="$HOME/.config/hypr/hyprland.lua"
    line="hl.bind(\"CTRL + ALT + O\", hl.dsp.exec_cmd(\"$CMD\"))"
  elif [ -f "$HOME/.config/hypr/hyprland.conf" ]; then
    cfg="$HOME/.config/hypr/hyprland.conf"
    line="bind = CTRL ALT, O, exec, $CMD"
  elif [ -f "$HOME/.config/sway/config" ]; then
    cfg="$HOME/.config/sway/config"
    line="bindsym Ctrl+Alt+o exec $CMD"
  else
    warn "Назначьте хоткей на команду $CMD в настройках вашего окружения."
    return
  fi
  if grep -qF "$CMD" "$cfg"; then
    say "Хоткей уже есть в $cfg"
  elif ask "Добавить Ctrl+Alt+O в $cfg?"; then
    printf '\n%s\n' "$line" >> "$cfg"
    say "Добавлено в $cfg"
  else
    say "Добавьте вручную в $cfg:"
    echo "    $line"
  fi
}
setup_hotkey

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR нет в PATH — запускайте по полному пути: $CMD" ;;
esac

say "Готово. Запуск: $CMD   (удаление: ./install.sh --uninstall)"

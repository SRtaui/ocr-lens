#!/usr/bin/env bash
# Установщик ocr-lens.
#   ./install.sh               — установить / обновить
#   ./install.sh --uninstall   — удалить
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/ocr-lens"
VENV="$DATA_DIR/venv"
CMD="$BIN_DIR/ocr-lens"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { [ -r /dev/tty ] || return 1; read -r -p "$1 [y/N] " a < /dev/tty; [[ "$a" =~ ^[YyДд]$ ]]; }

# ---------- удаление ----------
if [ "${1:-}" = "--uninstall" ]; then
  pkill -f "$DATA_DIR/translate_daemon.py" 2>/dev/null || true
  rm -f "$CMD"
  rm -rf "$DATA_DIR"
  say "ocr-lens удалён. Системные пакеты и строка хоткея в конфиге не тронуты."
  exit 0
fi

[ "$(id -u)" -ne 0 ] || die "запускайте без sudo — пароль спросится только для системных пакетов."
for f in ocr-lens translate_daemon.py requirements.txt; do
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
    grim tesseract tesseract-data-eng wl-clipboard
  sudo pacman -S --needed --noconfirm translate-shell || true
elif command -v apt-get >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y python3 python3-venv python3-gi python3-gi-cairo gir1.2-gtk-3.0 \
    gir1.2-gtklayershell-0.1 grim tesseract-ocr tesseract-ocr-eng wl-clipboard
  sudo apt-get install -y translate-shell || true
elif command -v dnf >/dev/null; then
  sudo dnf install -y python3 python3-gobject python3-cairo gtk3 gtk-layer-shell \
    grim tesseract tesseract-langpack-eng wl-clipboard
  sudo dnf install -y translate-shell || true
elif command -v zypper >/dev/null; then
  sudo zypper --non-interactive install python3 python3-gobject python3-gobject-cairo \
    python3-gobject-Gdk typelib-1_0-Gtk-3_0 typelib-1_0-GtkLayerShell-0_1 \
    grim tesseract-ocr tesseract-ocr-traineddata-english wl-clipboard
  sudo zypper --non-interactive install translate-shell || true
else
  warn "Неизвестный пакетный менеджер. Установите вручную: PyGObject (GTK3 + cairo),"
  warn "gtk-layer-shell, grim, tesseract + английская модель, wl-clipboard, python3-venv."
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

# ---------- 2. офлайн-перевод ----------
say "Окружение для офлайн-перевода (в первый раз — несколько минут)"
mkdir -p "$DATA_DIR" "$BIN_DIR"
[ -x "$VENV/bin/python" ] || "$SYS_PY" -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
# torch только для CPU, иначе pip скачает CUDA-версию на ~2 ГБ
"$VENV/bin/pip" install -q --extra-index-url https://download.pytorch.org/whl/cpu \
  -r "$SRC_DIR/requirements.txt"

say "Модель перевода en → ru"
"$VENV/bin/argospm" update
"$VENV/bin/argospm" install translate-en_ru

# ---------- 3. файлы ----------
say "Копирование файлов"
install -m 644 "$SRC_DIR/translate_daemon.py" "$DATA_DIR/translate_daemon.py"
{ echo "#!$SYS_PY"; sed '1{/^#!/d}' "$SRC_DIR/ocr-lens"; } > "$CMD"
chmod 755 "$CMD"
pkill -f "$DATA_DIR/translate_daemon.py" 2>/dev/null || true   # старый демон перезапустится сам

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

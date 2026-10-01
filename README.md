# ocr-lens

Перевод текста на экране поверх оригинала, как в Google Lens. Работает офлайн (Argos Translate), без интернета нужен только для установки.

## Установка

```bash
tar xzf ocr-lens.tar.gz
cd ocr-lens
./install.sh
```

Установщик сам поставит системные пакеты (pacman / apt / dnf / zypper), создаст Python-окружение, скачает модель en→ru (~100 МБ) и предложит добавить хоткей `Ctrl+Alt+O` (Hyprland или Sway).

## Использование

| Клавиша | Действие |
|---|---|
| ЛКМ, тянуть | выделить область и перевести |
| Space | оригинал / перевод |
| C | скопировать перевод |
| Esc / ПКМ | закрыть |

## Требования

Wayland-композитор с поддержкой layer-shell и screencopy: Hyprland, Sway, river, niri, KDE Plasma 6 (частично). GNOME и X11 не поддерживаются.

## Удаление

```bash
./install.sh --uninstall
```

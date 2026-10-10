# Mini Desktop

A desktop widget for [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) that gives you a small, classic desktop area for a folder: its files appear as icons, and a context menu creates documents, folders and shortcuts right there. Everything is written to the folder itself, so your file manager sees the same files.

![Mini Desktop on the desktop](assets/screenshot.png)

## Features

- Shows the Desktop folder (`xdg-user-dir DESKTOP`) by default, or **any folder per widget**: add several widgets, each with its own folder, optionally titled with the folder name.
- **Blank-area menu:** New Text Document, New Folder, New from Template (files in `~/Templates`), Create Shortcut (application, file, folder, web address), Paste, Open Terminal Here, Open in File Manager, Widget Settings.
- **Item menu:** Open / Launch, Open With (DMS application picker), Cut, Copy, Copy Path, Rename, Move to Trash. Nothing is ever deleted permanently.
- New items are selected and their name opens for editing right away. Renaming a `.desktop` launcher changes its visible name, like Nemo does.
- Copy and cut put files on the Wayland clipboard in the formats GTK, Nemo, Nautilus, Dolphin and KDE apps read; paste accepts files, images, links and text.
- Drag and drop: from your file manager into the widget or onto a folder icon, between widgets, and out of the widget into other apps.
- Selection with Ctrl/Shift and rubber band; keyboard: Ctrl+A/C/X/V, Delete, F2, Enter, arrows, Esc, Menu / Shift+F10, F5.
- Image previews, and thumbnails for videos and other types through the system thumbnailers.
- The folder is watched, so changes made elsewhere show up immediately.
- Apps start through DMS's own launcher path (`SessionService.launchDesktopEntry`), so your launch prefix and per-app overrides apply.
- English and Turkish UI.

### Opening the menus

Middle-click a blank spot or an item, use the **+** button that appears in the top-right corner on hover, or press the Menu key. In DMS 1.6.x a right-click on a desktop widget is reserved for moving it; once DMS hands right-clicks to widgets, the menus open on right-click too.

Move and resize the widget the usual DMS way: right-click and drag it, or right-click and drag its bottom-right corner.

## Settings

Each widget instance has its own settings in **Settings → Desktop Widgets**:

- **Folder** — type a path (`~/Desktop/Games`) or pick one with **Choose…**; empty means the Desktop. If the folder does not exist, the widget offers to create it.
- **Show title** — the folder name above the icons (off by default).
- **Icon size** and **Background opacity** (0 shows only the icons).

## Installation

From the DMS plugin browser: **Settings → Desktop Widgets → Browse Plugins**, search for *Mini Desktop*, then add the widget.

Manually:

```bash
git clone https://github.com/KadirJeager/dms-mini-desktop ~/.config/DankMaterialShell/plugins/miniDesktop
```

Then restart DMS (or run `dms ipc call plugins reload miniDesktop`) and add it with **Settings → Desktop Widgets → Add Widget**.

## Requirements

- DankMaterialShell 1.6.0 or newer
- `python3` with PyGObject (`python-gobject`) and `python-pywayland`
- `wl-clipboard` (reading the clipboard)
- A compositor that offers `ext-data-control-v1` (Hyprland does) for Copy and Cut

Tested on DMS 1.6.2 with Hyprland 0.56.

## How it works

- `MiniDesktop.qml` — the widget: grid, selection, keyboard, drag and drop, menu actions.
- `MiniDesktopItem.qml` — one icon.
- `MiniDesktopOverlay.qml` — a full-screen overlay surface for the menus and the rename field; the widget itself sits on the bottom layer, below windows.
- `helper/minidesktop.py` — file, clipboard and preview backend (`python3 helper/minidesktop.py --help`). It watches the folder with GIO, makes thumbnails with the system `.thumbnailer` entries and owns the clipboard through `ext-data-control-v1` so several formats can be offered at once.

## License

MIT

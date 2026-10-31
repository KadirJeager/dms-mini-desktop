import QtQuick
import QtQuick.Controls
import QtCore
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Modules.Settings.Widgets
import qs.Modals.FileBrowser
import qs.Modals.Common

DesktopPluginComponent {
    id: root

    property bool acceptsKeyboardFocus: true
    property var screen: null
    minWidth: 180
    minHeight: 160
    widgetWidth: 420
    widgetHeight: 300

    readonly property int iconSize: boundedSetting(pluginData.iconSize, 48, 32, 96)
    readonly property real backgroundOpacity: boundedSetting(pluginData.backgroundOpacity, 60, 0, 100) / 100
    // Each widget instance shows its own folder; without one it shows the Desktop.
    readonly property string defaultDir: localPath(StandardPaths.writableLocation(StandardPaths.DesktopLocation))
    readonly property string homeDir: localPath(StandardPaths.writableLocation(StandardPaths.HomeLocation))
    readonly property string configuredDir: folderSetting(pluginData.folder)
    readonly property string desktopDir: configuredDir || defaultDir
    readonly property bool isDefaultDir: desktopDir === defaultDir
    readonly property bool showTitle: pluginData.showTitle === true
    readonly property string folderTitle: desktopDir.split("/").filter(part => part !== "").pop() || "/"
    readonly property string helperPath: localPath(Qt.resolvedUrl("helper/minidesktop.py"))
    readonly property int columns: Math.max(1, Math.floor(grid.width / Math.max(iconSize + Theme.spacingL * 2, Theme.fontSizeSmall * 8)))
    // App shortcuts above the folder's icons: chosen in the widget settings, launched with one click.
    readonly property var shortcuts: toArray(pluginData.shortcuts).filter(s => s && (s.desktopId || s.name))
    // Re-evaluates icon and launch lookups once the desktop entry database (re)loads.
    readonly property var desktopApps: DesktopEntries.applications.values
    readonly property var targetScreen: screen || root.QsWindow.window?.screen || null
    // Folders come first except in "manual", where items keep the order they were dragged into.
    readonly property string sortBy: ["name", "type", "modified", "size", "manual"].includes(pluginData.sortBy) ? pluginData.sortBy : "name"
    readonly property var manualOrder: toArray(pluginData.order)

    // The helper's listing, folders first and by name; items is that listing in sortBy order.
    property var listedItems: []
    property var items: []
    property bool internalDrag: false
    property int dropSlot: -1
    property var selection: ({})
    property int currentIndex: -1
    property string rangeAnchor: ""
    property bool activeFocusShown: false
    property var cutPaths: ({})
    property var pendingSelect: []
    property string pendingRename: ""
    property string renamePath: ""
    property int busyCount: 0
    property string directoryError: ""
    property bool loading: true
    property bool alive: false
    property int watchFailures: 0
    property var templates: []
    property bool pasteAvailable: false
    property int menuGeneration: 0
    property point blankMenuPosition: Qt.point(0, 0)
    // Creating needs only an existing folder, not a finished listing.
    readonly property bool menuWritable: desktopDir !== "" && !directoryError

    onActiveFocusChanged: {
        if (!activeFocus)
            activeFocusShown = false;
    }

    onSortByChanged: updateItems(listedItems)
    onManualOrderChanged: {
        if (sortBy === "manual")
            updateItems(listedItems);
    }

    function boundedSetting(value, fallback, minimum, maximum) {
        const n = Number(value ?? fallback);
        return Number.isFinite(n) ? Math.round(Math.max(minimum, Math.min(maximum, n))) : fallback;
    }

    // Accepts an absolute path, ~/..., a path relative to home or a file:// URL.
    function folderSetting(value) {
        let path = typeof value === "string" ? value.trim() : "";
        if (!path)
            return "";
        if (path.startsWith("file://"))
            path = localPath(path);
        else if (path === "~" || path.startsWith("~/"))
            path = homeDir + path.slice(1);
        else if (!path.startsWith("/"))
            path = homeDir + "/" + path;
        return path ? normalizedPath(path) : "";
    }

    onDesktopDirChanged: {
        if (!alive)
            return;
        overlay.close();
        listedItems = [];
        items = [];
        selection = {};
        cutPaths = {};
        currentIndex = -1;
        directoryError = "";
        restartWatcher();
    }

    // Menu entries travel through `var` properties and signals; on the way Qt turns nested
    // JS arrays into sequence objects that Array.isArray() rejects.
    function isList(value) {
        return value !== null && value !== undefined && typeof value !== "string" && typeof value.length === "number";
    }

    function toArray(value) {
        if (Array.isArray(value))
            return value;
        if (!isList(value))
            return [];
        const out = [];
        for (let i = 0; i < value.length; i++)
            out.push(value[i]);
        return out;
    }

    function desktopEntryFor(shortcut) {
        if (!shortcut.desktopId || desktopApps.length === 0)
            return null;
        return DesktopEntries.byId(shortcut.desktopId) || DesktopEntries.heuristicLookup(shortcut.desktopId);
    }

    function shortcutIcon(shortcut) {
        if (shortcut.iconOverride)
            return Paths.resolveIconUrl(shortcut.iconOverride);
        const entry = desktopEntryFor(shortcut);
        if (entry && entry.icon)
            return Paths.resolveIconUrl(String(entry.icon));
        return Paths.resolveIconUrl(shortcut.icon || "application-x-executable");
    }

    function launchShortcut(shortcut) {
        const entry = desktopEntryFor(shortcut);
        if (entry) {
            AppUsageHistoryData.addAppUsage({
                "id": entry.id,
                "name": entry.name || shortcut.name,
                "icon": entry.icon ? String(entry.icon) : "",
                "exec": entry.exec || "",
                "comment": entry.comment || ""
            });
            SessionService.launchDesktopEntry(entry);
            return;
        }
        // The app's desktop entry is gone (uninstalled or renamed); use the command saved when it was added.
        const command = toArray(shortcut.command);
        if (command.length) {
            SessionService.launchDesktopEntry({
                command: command,
                workingDirectory: homeDir
            });
            return;
        }
        ToastService.showError(I18n.trFor("miniDesktop", "Could not open %1").arg(shortcut.name), I18n.trFor("miniDesktop", "Its desktop entry was not found."));
    }

    function localPath(value) {
        const text = String(value || "");
        if (!text.startsWith("file://"))
            return text.startsWith("/") ? text : "";
        const rest = text.slice(7);
        const slash = rest.indexOf("/");
        const host = slash < 0 ? rest : rest.slice(0, slash);
        if (host && host !== "localhost")
            return "";
        try {
            return decodeURIComponent(slash < 0 ? "" : rest.slice(slash));
        } catch (_) {
            return "";
        }
    }

    function errorText(code) {
        switch (code) {
        case "exists":
            return I18n.trFor("miniDesktop", "An item with this name already exists.");
        case "invalid-name":
            return I18n.trFor("miniDesktop", "The name is not valid.");
        case "name-too-long":
            return I18n.trFor("miniDesktop", "The name is too long.");
        case "not-found":
            return I18n.trFor("miniDesktop", "The file or folder could not be found.");
        case "permission":
            return I18n.trFor("miniDesktop", "You do not have permission for this operation.");
        case "no-space":
            return I18n.trFor("miniDesktop", "There is not enough free space.");
        case "trash-unsupported":
            return I18n.trFor("miniDesktop", "The trash is not supported at this location.");
        case "trash-failed":
            return I18n.trFor("miniDesktop", "The item could not be moved to the trash.");
        case "clipboard-empty":
            return I18n.trFor("miniDesktop", "The clipboard is empty.");
        case "clipboard-unsupported":
            return I18n.trFor("miniDesktop", "The clipboard content is not supported.");
        case "clipboard-failed":
            return I18n.trFor("miniDesktop", "The clipboard could not be accessed.");
        case "no-data-control":
            return I18n.trFor("miniDesktop", "The compositor does not support clipboard access.");
        case "invalid-url":
            return I18n.trFor("miniDesktop", "The web address is not valid.");
        case "app-not-found":
            return I18n.trFor("miniDesktop", "The application could not be found.");
        case "into-itself":
            return I18n.trFor("miniDesktop", "A folder cannot be placed inside itself.");
        case "io":
            return I18n.trFor("miniDesktop", "The file operation could not be completed.");
        case "invalid-response":
            return I18n.trFor("miniDesktop", "The helper returned an invalid response.");
        default:
            return I18n.trFor("miniDesktop", "An unexpected error occurred.");
        }
    }

    function reportResult(result) {
        if (!result.ok) {
            ToastService.showError(I18n.trFor("miniDesktop", "Operation failed"), errorText(result.error));
            return;
        }
        if (Array.isArray(result.errors) && result.errors.length) {
            const reasons = [];
            result.errors.forEach(e => {
                const message = errorText(e.error);
                if (!reasons.includes(message))
                    reasons.push(message);
            });
            ToastService.showWarning(I18n.trFor("miniDesktop", "%1 items could not be processed.").arg(result.errors.length), reasons.join("\n"));
        }
    }

    // Each call owns its collector and callback; overlapping calls cannot steal output.
    function runHelper(args, callback) {
        const process = helperProcess.createObject(root, {
            command: ["python3", helperPath].concat(args),
            callback: callback || null
        });
        if (!process) {
            const failure = {
                ok: false,
                error: "io"
            };
            reportResult(failure);
            if (callback)
                callback(failure);
            return;
        }
        busyCount++;
        process.running = true;
    }

    Component {
        id: helperProcess
        Process {
            id: job
            property var callback: null
            property bool finished: false
            property int exitCode: -1
            property alias output: collector.text

            function finish() {
                if (finished || !root.alive)
                    return;
                finished = true;
                let result;
                try {
                    result = JSON.parse(output.trim());
                    if (!result || typeof result.ok !== "boolean")
                        throw new Error("Invalid helper response");
                    if (result.ok && exitCode !== 0)
                        result = {
                            ok: false,
                            error: "io"
                        };
                } catch (_) {
                    result = {
                        ok: false,
                        error: "invalid-response"
                    };
                }
                root.busyCount = Math.max(0, root.busyCount - 1);
                root.reportResult(result);
                try {
                    if (callback)
                        callback(result);
                } finally {
                    Qt.callLater(() => {
                        try {
                            job.destroy();
                        } catch (_) {}
                    });
                }
            }
            stdout: StdioCollector {
                id: collector
            }
            // A failed start also changes running to false, without an exited signal.
            onRunningChanged: {
                if (!running)
                    Qt.callLater(finish);
            }
            onExited: code => {
                exitCode = code;
                Qt.callLater(finish);
            }
        }
    }

    function restartWatcher() {
        watchRestart.stop();
        watch.running = false;
        watchFailures = 0;
        loading = true;
        watchRestart.interval = 100;
        watchRestart.start();
    }

    function watchStopped() {
        if (!alive || watchRestart.running)
            return;
        loading = false;
        if (directoryError !== "invalid-response")
            directoryError = "watch-stopped";
        watchRestart.interval = Math.min(10000, 500 * Math.pow(2, Math.min(watchFailures++, 5)));
        watchRestart.start();
    }

    Process {
        id: watch
        command: ["python3", root.helperPath, "watch", "--", root.desktopDir]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    const message = JSON.parse(data);
                    if (message.dir !== root.desktopDir)
                        return;
                    if (message.type === "list" && Array.isArray(message.items)) {
                        root.watchFailures = 0;
                        root.directoryError = "";
                        root.loading = false;
                        root.updateItems(message.items);
                    } else if (message.type === "error") {
                        root.loading = false;
                        root.directoryError = message.error;
                        root.updateItems([]);
                    } else {
                        throw new Error("Invalid watch response");
                    }
                } catch (_) {
                    root.loading = false;
                    if (root.directoryError !== "invalid-response")
                        root.reportResult({
                            ok: false,
                            error: "invalid-response"
                        });
                    root.directoryError = "invalid-response";
                    watch.running = false;
                }
            }
        }
        onRunningChanged: {
            if (!running)
                Qt.callLater(root.watchStopped);
        }
        onExited: root.watchStopped()
    }

    Timer {
        id: watchRestart
        onTriggered: {
            if (!root.alive)
                return;
            if (!root.desktopDir || !root.helperPath) {
                root.loading = false;
                root.directoryError = "not-found";
                return;
            }
            watch.running = true;
        }
    }

    function indexOfPath(path) {
        return items.findIndex(e => e.path === path);
    }

    function existingMap(map, paths) {
        const clean = {};
        Object.keys(map).forEach(path => {
            if (paths[path])
                clean[path] = true;
        });
        return clean;
    }

    function updateItems(list) {
        const currentPath = items[currentIndex]?.path;
        const present = {};
        list.forEach(e => present[e.path] = true);
        listedItems = list;
        items = sortedItems(list);
        selection = existingMap(selection, present);
        cutPaths = existingMap(cutPaths, present);
        currentIndex = currentPath ? indexOfPath(currentPath) : -1;
        if (!present[rangeAnchor])
            rangeAnchor = "";
        // A thumbnail refresh must not replace an in-progress rubber-band selection.
        if (blankMouse.selecting)
            updateRubberSelection();
        applyPending();
    }

    function queueResult(result, rename, directory) {
        if (!result.ok || (directory && directory !== desktopDir))
            return;
        const paths = result.path ? [result.path] : (result.created || []);
        if (!paths.length)
            return;
        if (!pendingSelect.length)
            selection = {};
        pendingSelect = pendingSelect.concat(paths.filter(p => !pendingSelect.includes(p)));
        if (rename)
            pendingRename = paths[0];
        applyPending(); // The watch notification may have arrived before the command's reply.
    }

    function applyPending() {
        if (!pendingSelect.length)
            return;
        const found = pendingSelect.filter(p => indexOfPath(p) >= 0);
        if (!found.length)
            return;
        const next = Object.assign({}, selection);
        found.forEach(p => next[p] = true);
        selection = next;
        pendingSelect = pendingSelect.filter(p => !found.includes(p));
        currentIndex = indexOfPath(found[0]);
        rangeAnchor = found[0];
        grid.positionViewAtIndex(currentIndex, GridView.Contain);
        if (pendingRename && indexOfPath(pendingRename) >= 0) {
            const path = pendingRename;
            pendingRename = "";
            Qt.callLater(() => beginRename(path));
        }
    }

    function sortedItems(list) {
        const rank = new Map(list.map((e, i) => [e.path, i]));
        const byName = (a, b) => rank.get(a.path) - rank.get(b.path);
        const folderFirst = (a, b) => (a.kind === "folder" ? 0 : 1) - (b.kind === "folder" ? 0 : 1);
        let compare;
        switch (sortBy) {
        case "type":
            compare = (a, b) => folderFirst(a, b) || String(a.mime || "").localeCompare(String(b.mime || "")) || byName(a, b);
            break;
        case "modified":
            compare = (a, b) => folderFirst(a, b) || (Number(b.modified) || 0) - (Number(a.modified) || 0) || byName(a, b);
            break;
        case "size":
            compare = (a, b) => folderFirst(a, b) || (a.kind === "folder" ? 0 : (Number(b.size) || 0) - (Number(a.size) || 0)) || byName(a, b);
            break;
        case "manual":
            {
                // Items the order does not know yet (new files) follow, by name.
                const position = new Map(manualOrder.map((name, i) => [name, i]));
                const at = e => position.has(e.name) ? position.get(e.name) : manualOrder.length + rank.get(e.path);
                compare = (a, b) => at(a) - at(b);
                break;
            }
        default:
            return list;
        }
        return list.slice().sort(compare);
    }

    function saveSettings(updates) {
        if (isInstance)
            SettingsData.updateDesktopWidgetInstanceConfig(instanceId, updates);
        else
            Object.keys(updates).forEach(key => setData(key, updates[key]));
    }

    // The insertion position in items for a point in grid coordinates: before or after the
    // cell under it, by which half the point is in.
    function slotAt(x, y) {
        const column = Math.max(0, Math.min(columns - 1, Math.floor(x / grid.cellWidth)));
        const row = Math.max(0, Math.floor((y + grid.contentY - grid.originY) / grid.cellHeight));
        const after = x - column * grid.cellWidth > grid.cellWidth / 2 ? 1 : 0;
        return Math.min(items.length, row * columns + column + after);
    }

    // Dragging items within the widget arranges them by hand from then on.
    function arrangeSelection(slot) {
        const moving = selectedEntries();
        if (!moving.length)
            return;
        const isMoving = {};
        moving.forEach(e => isMoving[e.path] = true);
        const order = items.slice(0, slot).filter(e => !isMoving[e.path]).concat(moving, items.slice(slot).filter(e => !isMoving[e.path])).map(e => e.name);
        if (sortBy === "manual" && order.join("/") === items.map(e => e.name).join("/"))
            return;
        saveSettings({
            sortBy: "manual",
            order: order
        });
    }

    function selectedEntries() {
        return items.filter(e => selection[e.path]);
    }

    function takeFocus() {
        root.forceActiveFocus(Qt.MouseFocusReason);
    }

    function selectOnly(index) {
        if (index < 0 || index >= items.length)
            return;
        selection = {
            [items[index].path]: true
        };
        currentIndex = index;
        rangeAnchor = items[index].path;
    }

    function selectRange(index, additive) {
        let anchor = indexOfPath(rangeAnchor);
        if (anchor < 0)
            anchor = currentIndex >= 0 ? currentIndex : index;
        rangeAnchor = items[anchor].path;
        const next = additive ? Object.assign({}, selection) : {};
        for (let i = Math.min(anchor, index); i <= Math.max(anchor, index); i++)
            next[items[i].path] = true;
        selection = next;
        currentIndex = index;
    }

    function pressItem(index, modifiers) {
        activeFocusShown = false;
        if (modifiers & Qt.ShiftModifier) {
            selectRange(index, !!(modifiers & Qt.ControlModifier));
        } else if (modifiers & Qt.ControlModifier) {
            const next = Object.assign({}, selection);
            const path = items[index].path;
            if (next[path])
                delete next[path];
            else
                next[path] = true;
            selection = next;
            currentIndex = index;
            rangeAnchor = path;
        } else if (!selection[items[index].path]) {
            selectOnly(index);
        } else {
            currentIndex = index;
        }
    }

    function releaseItem(index, modifiers, wasSelected) {
        if (wasSelected && !(modifiers & (Qt.ControlModifier | Qt.ShiftModifier)))
            selectOnly(index);
    }

    function globalPoint(item, x, y) {
        const pos = item.mapToItem(null, x, y);
        const window = root.QsWindow.window;
        return Qt.point((window?.margins.left || 0) + pos.x, (window?.margins.top || 0) + pos.y);
    }

    function openItem(entry) {
        if (!entry)
            return;
        if (entry.available === false) {
            reportResult({
                ok: false,
                error: entry.kind === "app" ? "app-not-found" : "not-found"
            });
            return;
        }
        if (entry.kind === "app" && entry.trusted === false) {
            ToastService.showWarning(I18n.trFor("miniDesktop", "%1 is not allowed to run").arg(entry.label), I18n.trFor("miniDesktop", "Choose Allow Launching from its menu if you trust it."));
            return;
        }
        if (entry.kind === "app") {
            SessionService.launchDesktopEntry({
                command: entry.exec,
                id: entry.appId,
                workingDirectory: entry.workdir,
                runInTerminal: entry.terminal
            });
        } else {
            SessionService.launchDesktopEntry({
                command: ["gio", "open", entry.kind === "link" ? entry.url : entry.path],
                workingDirectory: desktopDir
            });
        }
    }

    function copyEntries(entries, cut) {
        const paths = entries.map(e => e.path);
        if (!paths.length)
            return;
        runHelper(["copy"].concat(cut ? ["--cut"] : []).concat(["--"], paths), result => {
            if (!result.ok)
                return;
            const next = {};
            if (cut)
                paths.forEach(p => {
                    if (indexOfPath(p) >= 0)
                        next[p] = true;
                });
            cutPaths = next;
        });
    }

    function trashEntries(entries) {
        const paths = entries.map(e => e.path);
        if (paths.length)
            runHelper(["trash", "--"].concat(paths));
    }

    function paste() {
        runHelper(["paste", "--text-name", I18n.trFor("miniDesktop", "Pasted Text.txt"), "--image-name", I18n.trFor("miniDesktop", "Pasted Image"), "--", desktopDir], result => queueResult(result, false, desktopDir));
    }

    function beginRename(path) {
        const index = indexOfPath(path);
        if (index < 0 || !targetScreen)
            return;
        grid.positionViewAtIndex(index, GridView.Contain);
        grid.forceLayout();
        Qt.callLater(() => {
            const freshIndex = indexOfPath(path);
            const cell = grid.itemAtIndex(freshIndex);
            if (!cell || freshIndex < 0)
                return;
            const entry = items[freshIndex];
            const rect = cell.labelRect();
            const window = root.QsWindow.window;
            renamePath = path;
            overlay.openRename(targetScreen, Qt.rect(rect.x + (window?.margins.left || 0), rect.y + (window?.margins.top || 0), rect.width, rect.height), entry.label, entry.kind === "folder" || entry.isDesktopFile);
        });
    }

    function dragMimeData(entry) {
        const index = indexOfPath(entry.path);
        if (!selection[entry.path] && index >= 0)
            selectOnly(index);
        const entries = selectedEntries();
        internalDrag = true;
        return {
            "text/uri-list": entries.map(e => e.uri).join("\r\n") + "\r\n",
            "text/plain": entries.map(e => e.path).join("\n")
        };
    }

    function normalizedPath(path) {
        const components = [];
        String(path).split("/").forEach(part => {
            if (part === "..")
                components.pop();
            else if (part && part !== ".")
                components.push(part);
        });
        return "/" + components.join("/");
    }

    function canDropOn(drag, dir) {
        if (!dir || directoryError)
            return false;
        if (drag.hasUrls && drag.urls.length) {
            const target = normalizedPath(dir);
            let supported = false;
            for (let i = 0; i < drag.urls.length; i++) {
                const uri = String(drag.urls[i]);
                const path = localPath(uri);
                if (path) {
                    const source = normalizedPath(path);
                    if (target === source || target.startsWith(source + "/"))
                        return false;
                    supported = true;
                } else if (/^https?:\/\//i.test(uri)) {
                    supported = true;
                }
            }
            return supported;
        }
        return drag.hasText && String(drag.text).length > 0;
    }

    function handleDrop(drop, dir) {
        if (!canDropOn(drop, dir)) {
            drop.accepted = false;
            return;
        }
        // Report COPY even when the backend moves: otherwise the sender may delete its source.
        drop.accept(Qt.CopyAction);
        if (drop.hasUrls && drop.urls.length) {
            const urls = Array.from(drop.urls, u => String(u)).filter(u => localPath(u) || /^https?:\/\//i.test(u));
            runHelper(["drop", "--", dir, "auto"].concat(urls), result => queueResult(result, false, dir));
        } else {
            runHelper(["drop-text", "--text-name", I18n.trFor("miniDesktop", "Dropped Text.txt"), "--", dir, String(drop.text)], result => queueResult(result, false, dir));
        }
    }

    function blankEntries() {
        const entries = [
            {
                id: "new-file",
                text: I18n.trFor("miniDesktop", "New Text Document"),
                icon: "note_add",
                enabled: menuWritable
            },
            {
                id: "new-folder",
                text: I18n.trFor("miniDesktop", "New Folder"),
                icon: "create_new_folder",
                enabled: menuWritable
            }
        ];
        if (templates.length) {
            entries.push({
                text: I18n.trFor("miniDesktop", "New from Template"),
                icon: "file_copy",
                enabled: menuWritable,
                submenu: templates.map(t => ({
                            id: "from-template",
                            text: t.templateLabel || t.label,
                            icon: t.kind === "folder" ? "folder" : "description",
                            data: t.path
                        }))
            });
        }
        entries.push({
            text: I18n.trFor("miniDesktop", "Create Shortcut"),
            icon: "add_link",
            enabled: menuWritable,
            submenu: [
                {
                    id: "app-shortcut",
                    text: I18n.trFor("miniDesktop", "Application…"),
                    icon: "apps"
                },
                {
                    id: "file-link",
                    text: I18n.trFor("miniDesktop", "File…"),
                    icon: "description"
                },
                {
                    id: "folder-link",
                    text: I18n.trFor("miniDesktop", "Folder…"),
                    icon: "folder"
                },
                {
                    id: "url-link",
                    text: I18n.trFor("miniDesktop", "Web Address…"),
                    icon: "language"
                }
            ]
        }, {
            text: I18n.trFor("miniDesktop", "Sort By"),
            icon: "sort",
            submenu: [["name", I18n.trFor("miniDesktop", "Name")], ["type", I18n.trFor("miniDesktop", "Type")], ["modified", I18n.trFor("miniDesktop", "Date Modified")], ["size", I18n.trFor("miniDesktop", "Size")], ["manual", I18n.trFor("miniDesktop", "Manual")]].map(([key, text]) => ({
                        id: "sort",
                        text: text,
                        icon: sortBy === key ? "check" : "",
                        data: key
                    }))
        }, {
            separator: true
        }, {
            id: "paste",
            text: I18n.trFor("miniDesktop", "Paste"),
            icon: "content_paste",
            enabled: menuWritable && pasteAvailable
        }, {
            separator: true
        }, {
            id: "terminal",
            text: I18n.trFor("miniDesktop", "Open Terminal Here"),
            icon: "terminal",
            enabled: menuWritable
        }, {
            id: "file-manager",
            text: I18n.trFor("miniDesktop", "Open in File Manager"),
            icon: "folder_open",
            enabled: menuWritable
        }, {
            separator: true
        }, {
            id: "settings",
            text: I18n.trFor("miniDesktop", "Widget Settings"),
            icon: "tune"
        }, {
            // The widget takes right-clicks for its own menu, so DMS's widget menu is offered here.
            id: "edit-widgets",
            text: I18n.trFor("miniDesktop", "Edit Widgets"),
            icon: "edit"
        });
        return entries;
    }

    // Async answers update the open menu in place: the keyboard selection and an open
    // submenu stay where they are, and rows never shift under the pointer.
    function refreshBlankMenu(generation) {
        if (generation !== menuGeneration || !overlay.visible || overlay.mode !== "menu")
            return;
        const next = blankEntries();
        if (next.length !== overlay.entries.length)
            return; // template row appeared or vanished; shown on the next open
        overlay.updateEntries(next);
    }

    function refreshTemplates(generation) {
        runHelper(["templates"], result => {
            const next = result.ok && Array.isArray(result.templates) ? result.templates : [];
            if (JSON.stringify(next) === JSON.stringify(templates))
                return;
            templates = next;
            if (generation !== undefined)
                refreshBlankMenu(generation);
        });
    }

    function openBlankMenu(item, x, y) {
        takeFocus();
        activeFocusShown = false;
        if (!targetScreen)
            return;
        const generation = ++menuGeneration;
        blankMenuPosition = globalPoint(item, x, y);
        // Last known paste state and templates show at once; fresh answers follow.
        overlay.openMenu(targetScreen, blankMenuPosition, blankEntries());
        runHelper(["paste-info"], result => {
            if (generation !== menuGeneration)
                return;
            const available = result.ok && result.available === true;
            if (available === pasteAvailable)
                return;
            pasteAvailable = available;
            refreshBlankMenu(generation);
        });
        refreshTemplates(generation);
    }

    function openItemMenu(index, cell, x, y) {
        takeFocus();
        activeFocusShown = false;
        if (!items[index] || !targetScreen)
            return;
        if (!selection[items[index].path])
            selectOnly(index);
        currentIndex = index;
        const entries = selectedEntries();
        const single = entries.length === 1;
        const first = entries[0];
        const openText = first.kind === "app" ? I18n.trFor("miniDesktop", "Launch") : first.kind === "link" ? I18n.trFor("miniDesktop", "Open Link") : I18n.trFor("miniDesktop", "Open");
        const data = entries.slice();
        const untrusted = single && first.kind === "app" && first.trusted === false;
        ++menuGeneration;
        overlay.openMenu(targetScreen, globalPoint(cell, x, y), (untrusted ? [
                {
                    id: "trust",
                    text: I18n.trFor("miniDesktop", "Allow Launching"),
                    icon: "verified_user",
                    bold: true,
                    data: data
                }
            ] : []).concat([
            {
                id: "open",
                text: openText,
                icon: "open_in_new",
                bold: !untrusted,
                enabled: entries.every(e => e.available !== false && e.trusted !== false),
                data: data
            },
            {
                id: "open-with",
                text: I18n.trFor("miniDesktop", "Open With…"),
                icon: "apps",
                enabled: single && (first.kind === "file" || first.kind === "folder") && first.available !== false,
                data: data
            },
            {
                separator: true
            },
            {
                id: "cut",
                text: I18n.trFor("miniDesktop", "Cut"),
                icon: "content_cut",
                data: data
            },
            {
                id: "copy",
                text: I18n.trFor("miniDesktop", "Copy"),
                icon: "content_copy",
                data: data
            },
            {
                id: "copy-path",
                text: I18n.trFor("miniDesktop", "Copy Path"),
                icon: "link",
                data: data
            },
            {
                id: "rename",
                text: I18n.trFor("miniDesktop", "Rename"),
                icon: "edit",
                enabled: single,
                data: data
            },
            {
                separator: true
            },
            {
                id: "trash",
                text: I18n.trFor("miniDesktop", "Move to Trash"),
                icon: "delete",
                destructive: true,
                data: data
            }
        ]));
    }

    function create(args) {
        runHelper(args, result => queueResult(result, true, desktopDir));
    }

    function activateMenu(entry) {
        const entries = toArray(entry.data);
        switch (entry.id) {
        case "new-file":
            create(["new-file", "--", desktopDir, I18n.trFor("miniDesktop", "New Text Document.txt")]);
            break;
        case "new-folder":
            create(["new-folder", "--", desktopDir, I18n.trFor("miniDesktop", "New Folder")]);
            break;
        case "from-template":
            create(["from-template", "--", desktopDir, entry.data]);
            break;
        case "app-shortcut":
            appPicker.appsModel = AppSearchService.getVisibleApplications();
            appPicker.show();
            break;
        case "file-link":
        case "folder-link":
            filePicker.folderMode = entry.id === "folder-link";
            filePicker.browserTitle = entry.id === "folder-link" ? I18n.trFor("miniDesktop", "Select Folder") : I18n.trFor("miniDesktop", "Select File");
            filePicker.open();
            break;
        case "url-link":
            {
                // DMS 2.0's input dialog confirms twice on Enter (text field and dialog both
                // accept); one dialog creates one link.
                let confirmed = false;
                urlInput.showWithOptions({
                    title: I18n.trFor("miniDesktop", "Create Web Shortcut"),
                    message: I18n.trFor("miniDesktop", "Enter the web address."),
                    placeholder: I18n.trFor("miniDesktop", "Web address"),
                    confirmText: I18n.trFor("miniDesktop", "Create"),
                    cancelText: I18n.trFor("miniDesktop", "Cancel"),
                    onConfirm: text => {
                        if (confirmed)
                            return;
                        confirmed = true;
                        create(["url-link", "--", desktopDir, text]);
                    }
                });
                break;
            }
        case "paste":
            paste();
            break;
        case "sort":
            saveSettings({
                sortBy: entry.data
            });
            break;
        case "terminal":
            {
                const terminal = SessionData.resolveTerminal() || SessionData.installedTerminals[0];
                if (terminal)
                    SessionService.launchDesktopEntry({
                        command: [terminal],
                        workingDirectory: desktopDir
                    });
                else
                    ToastService.showError(I18n.trFor("miniDesktop", "No terminal application was found."));
                break;
            }
        case "file-manager":
            SessionService.launchDesktopEntry({
                command: ["gio", "open", desktopDir],
                workingDirectory: desktopDir
            });
            break;
        case "settings":
            if (root.instanceId && root.targetScreen)
                DesktopWidgetRegistry.editOptions(root.targetScreen, root.instanceId);
            else
                PopoutService.openSettingsWithTab("desktop_widgets");
            break;
        case "edit-widgets":
            DesktopWidgetRegistry.startEditing(root.targetScreen, false);
            break;
        case "trust":
            if (entries.length === 1)
                runHelper(["trust", "--", entries[0].path]);
            break;
        case "open":
            entries.forEach(e => openItem(e));
            break;
        case "open-with":
            if (entries.length === 1)
                SessionService.launchDesktopEntry({
                    command: ["dms", "open", entries[0].path],
                    workingDirectory: desktopDir
                });
            break;
        case "cut":
            copyEntries(entries, true);
            break;
        case "copy":
            copyEntries(entries, false);
            break;
        case "copy-path":
            SessionService.launchDesktopEntry({
                command: ["dms", "clipboard", "copy", entries.map(e => e.path).join("\n")],
                workingDirectory: desktopDir
            });
            break;
        case "rename":
            if (entries.length === 1)
                beginRename(entries[0].path);
            break;
        case "trash":
            trashEntries(entries);
            break;
        }
    }

    MiniDesktopOverlay {
        id: overlay
        onEntryTriggered: entry => root.activateMenu(entry)
        onDismissed: {
            ++root.menuGeneration;
            root.takeFocus();
        }
        onRenameFinished: (accepted, text) => {
            const path = root.renamePath;
            root.renamePath = "";
            if (accepted && path)
                root.runHelper(["rename", "--", path, text], result => root.queueResult(result, false, root.desktopDir));
        }
    }

    AppBrowserPopup {
        id: appPicker
        parentModal: root.QsWindow.window
        onAppSelected: appId => root.create(["app-shortcut", "--", root.desktopDir, appId])
    }

    FileBrowserSurfaceModal {
        id: filePicker
        targetScreen: root.targetScreen
        onFileSelected: path => {
            close();
            const target = path.startsWith("file://") ? root.localPath(path) : path;
            root.create(["file-link", "--", root.desktopDir, target]);
        }
    }

    InputModal {
        id: urlInput
        targetScreen: root.targetScreen
    }

    Keys.onPressed: event => {
        const ctrl = !!(event.modifiers & Qt.ControlModifier);
        const shift = !!(event.modifiers & Qt.ShiftModifier);
        let handled = true;
        root.takeFocus();
        root.activeFocusShown = true;
        if (ctrl && event.key === Qt.Key_A) {
            const next = {};
            root.items.forEach(e => next[e.path] = true);
            root.selection = next;
            if (root.currentIndex < 0 && root.items.length)
                root.currentIndex = 0;
        } else if (ctrl && event.key === Qt.Key_C) {
            root.copyEntries(root.selectedEntries(), false);
        } else if (ctrl && event.key === Qt.Key_X) {
            root.copyEntries(root.selectedEntries(), true);
        } else if (ctrl && event.key === Qt.Key_V) {
            root.paste();
        } else {
            switch (event.key) {
            case Qt.Key_Delete:
                root.trashEntries(root.selectedEntries());
                break;
            case Qt.Key_F2:
                {
                    const selected = root.selectedEntries();
                    if (selected.length === 1)
                        root.beginRename(selected[0].path);
                    break;
                }
            case Qt.Key_Return:
            case Qt.Key_Enter:
                root.selectedEntries().forEach(e => root.openItem(e));
                break;
            case Qt.Key_Left:
            case Qt.Key_Right:
            case Qt.Key_Up:
            case Qt.Key_Down:
                {
                    if (!root.items.length)
                        break;
                    const delta = event.key === Qt.Key_Left ? -1 : event.key === Qt.Key_Right ? 1 : event.key === Qt.Key_Up ? -root.columns : root.columns;
                    const next = root.currentIndex < 0 ? 0 : Math.max(0, Math.min(root.items.length - 1, root.currentIndex + delta));
                    if (shift)
                        root.selectRange(next, ctrl);
                    else if (ctrl)
                        root.currentIndex = next;
                    else
                        root.selectOnly(next);
                    grid.positionViewAtIndex(next, GridView.Contain);
                    break;
                }
            case Qt.Key_Escape:
                root.selection = {};
                root.currentIndex = -1;
                root.rangeAnchor = "";
                root.activeFocusShown = false;
                break;
            case Qt.Key_Menu:
                root.openKeyboardMenu();
                break;
            case Qt.Key_F10:
                if (shift)
                    root.openKeyboardMenu();
                else
                    handled = false;
                break;
            case Qt.Key_F5:
                root.restartWatcher();
                break;
            default:
                handled = false;
            }
        }
        event.accepted = handled;
    }

    function openKeyboardMenu() {
        if (currentIndex >= 0 && currentIndex < items.length) {
            grid.positionViewAtIndex(currentIndex, GridView.Contain);
            grid.forceLayout();
            const cell = grid.itemAtIndex(currentIndex);
            if (cell) {
                openItemMenu(currentIndex, cell, cell.width / 2, cell.height / 2);
                return;
            }
        }
        openBlankMenu(root, width / 2, height / 2);
    }

    function updateRubberSelection() {
        const next = Object.assign({}, blankMouse.baseSelection);
        const left = Math.min(blankMouse.startPoint.x, blankMouse.pointer.x);
        const right = Math.max(blankMouse.startPoint.x, blankMouse.pointer.x);
        const top = Math.min(blankMouse.startPoint.y, blankMouse.pointer.y + grid.contentY);
        const bottom = Math.max(blankMouse.startPoint.y, blankMouse.pointer.y + grid.contentY);
        items.forEach((entry, index) => {
            const x = (index % columns) * grid.cellWidth;
            const y = grid.originY + Math.floor(index / columns) * grid.cellHeight;
            if (right > x + 2 && left < x + grid.cellWidth - 2 && bottom > y + 2 && top < y + grid.cellHeight - 2)
                next[entry.path] = true;
        });
        const present = {};
        items.forEach(e => present[e.path] = true);
        selection = existingMap(next, present);
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceContainer, root.backgroundOpacity)
        border.width: root.backgroundOpacity > 0 ? 1 : 0
        border.color: Theme.withAlpha(Theme.outline, 0.18 * Math.min(1, root.backgroundOpacity * 2))
    }

    DropArea {
        id: widgetDrop
        anchors.fill: parent
        onEntered: drag => {
            if (!root.internalDrag && !root.canDropOn(drag, root.desktopDir))
                drag.accepted = false;
        }
        onPositionChanged: drag => {
            if (root.internalDrag) {
                const point = grid.mapFromItem(widgetDrop, drag.x, drag.y);
                root.dropSlot = root.slotAt(point.x, point.y);
            }
        }
        onExited: root.dropSlot = -1
        onDropped: drop => {
            root.dropSlot = -1;
            if (!root.internalDrag) {
                root.handleDrop(drop, root.desktopDir);
                return;
            }
            const point = grid.mapFromItem(widgetDrop, drop.x, drop.y);
            drop.accept(Qt.MoveAction);
            root.arrangeSelection(root.slotAt(point.x, point.y));
        }
    }

    DGridView {
        id: grid
        visible: !root.directoryError && !root.loading
        anchors.fill: parent
        anchors.margins: Theme.spacingS
        anchors.topMargin: Theme.spacingS + titleBar.height + shortcutBar.height
        flow: GridView.FlowLeftToRight
        layoutDirection: Qt.LeftToRight
        cellWidth: width / root.columns
        // Two label lines; a selected item shows its full name above the next row.
        cellHeight: root.iconSize + Theme.spacingS + Theme.spacingXS + Math.ceil(Theme.fontSizeSmall * 2.6) + Theme.spacingS
        clip: true
        model: root.items
        currentIndex: root.currentIndex
        delegate: MiniDesktopItem {
            desktop: root
        }
        interactive: !blankMouse.pressed && contentHeight > height
    }

    // Above the view: reject presses over cells so their MouseAreas receive them.
    MouseArea {
        id: blankMouse
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        preventStealing: true
        scrollGestureEnabled: false
        property point startPoint: Qt.point(0, 0)
        property point pointer: Qt.point(0, 0)
        property point pressPoint: Qt.point(0, 0)
        property var baseSelection: ({})
        property bool selecting: false

        onPressed: mouse => {
            const point = grid.mapFromItem(blankMouse, mouse.x, mouse.y);
            const scrollBar = grid.ScrollBar.vertical;
            const barPoint = scrollBar.mapFromItem(blankMouse, mouse.x, mouse.y);
            if ((scrollBar.visible && barPoint.x >= 0 && barPoint.x < scrollBar.width) || (grid.visible && point.x >= 0 && point.x < grid.width && point.y >= 0 && point.y < grid.height && grid.indexAt(point.x + grid.contentX, point.y + grid.contentY) >= 0)) {
                mouse.accepted = false;
                return;
            }
            root.takeFocus();
            root.activeFocusShown = false;
            if (mouse.button !== Qt.LeftButton) {
                root.openBlankMenu(blankMouse, mouse.x, mouse.y);
                return;
            }
            selecting = false;
            pointer = point;
            pressPoint = pointer;
            startPoint = Qt.point(point.x + grid.contentX, point.y + grid.contentY);
            baseSelection = mouse.modifiers & Qt.ControlModifier ? Object.assign({}, root.selection) : {};
            root.selection = Object.assign({}, baseSelection);
            root.currentIndex = -1;
            root.rangeAnchor = "";
        }
        onPositionChanged: mouse => {
            if (!(pressedButtons & Qt.LeftButton))
                return;
            pointer = grid.mapFromItem(blankMouse, mouse.x, mouse.y);
            if (!selecting && Math.hypot(pointer.x - pressPoint.x, pointer.y - pressPoint.y) >= 6)
                selecting = true;
            if (selecting)
                root.updateRubberSelection();
        }
        onReleased: {
            if (selecting)
                root.updateRubberSelection();
            selecting = false;
        }
        onCanceled: selecting = false
        onWheel: wheel => wheel.accepted = false
    }

    Timer {
        interval: 30
        repeat: true
        running: blankMouse.selecting && blankMouse.pressed
        onTriggered: {
            const y = blankMouse.pointer.y;
            const edge = Theme.spacingL;
            const direction = y < edge ? -1 : y > grid.height - edge ? 1 : 0;
            if (!direction)
                return;
            grid.contentY = Math.max(grid.originY, Math.min(Math.max(grid.originY, grid.originY + grid.contentHeight - grid.height), grid.contentY + direction * 10));
            root.updateRubberSelection();
        }
    }

    Item {
        anchors.fill: grid
        clip: true
        visible: blankMouse.selecting
        Rectangle {
            x: Math.min(blankMouse.startPoint.x - grid.contentX, blankMouse.pointer.x)
            y: Math.min(blankMouse.startPoint.y - grid.contentY, blankMouse.pointer.y)
            width: Math.abs(blankMouse.pointer.x - (blankMouse.startPoint.x - grid.contentX))
            height: Math.abs(blankMouse.pointer.y - (blankMouse.startPoint.y - grid.contentY))
            color: Theme.withAlpha(Theme.primary, 0.16)
            border.width: 1
            border.color: Theme.withAlpha(Theme.primary, 0.7)
        }
    }

    // Where dragged items will land when arranged by hand.
    Item {
        anchors.fill: grid
        clip: true
        visible: root.internalDrag && root.dropSlot >= 0 && widgetDrop.containsDrag
        Rectangle {
            readonly property int row: Math.floor(root.dropSlot / root.columns)
            readonly property int column: root.dropSlot % root.columns
            x: column * grid.cellWidth - width / 2
            y: row * grid.cellHeight - grid.contentY + grid.originY + Theme.spacingXS
            width: Theme.spacingXS
            height: grid.cellHeight - Theme.spacingXS * 2
            radius: width / 2
            color: Theme.primary
        }
    }

    Column {
        anchors.centerIn: grid
        width: grid.width - Theme.spacingS * 2
        spacing: Theme.spacingS
        // An empty folder under app shortcuts needs no message; errors are always shown.
        visible: !!root.directoryError || (root.items.length === 0 && !root.loading && root.shortcuts.length === 0)
        DIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: root.directoryError ? "folder_off" : "desktop_windows"
            size: root.iconSize
            color: root.directoryError ? Theme.error : Theme.surfaceVariantText
        }
        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: {
                if (!root.directoryError)
                    return root.isDefaultDir ? I18n.trFor("miniDesktop", "Desktop is empty") : I18n.trFor("miniDesktop", "This folder is empty");
                if (root.directoryError === "not-found")
                    return root.isDefaultDir ? I18n.trFor("miniDesktop", "Desktop folder not found") : I18n.trFor("miniDesktop", "Folder not found");
                return root.isDefaultDir ? I18n.trFor("miniDesktop", "Desktop folder could not be read") : I18n.trFor("miniDesktop", "Folder could not be read");
            }
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceText
        }
        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.directoryError ? root.desktopDir : I18n.trFor("miniDesktop", "Right-click to create an item")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
        DButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.directoryError === "not-found" && root.desktopDir !== ""
            text: I18n.trFor("miniDesktop", "Create Folder")
            iconName: "create_new_folder"
            onClicked: root.runHelper(["ensure-dir", "--", root.desktopDir], result => {
                if (result.ok)
                    root.restartWatcher();
            })
        }
        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: !!root.directoryError && root.directoryError !== "not-found"
            text: I18n.trFor("miniDesktop", "Press F5 to try again.")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    // Optional folder name above the icons.
    Item {
        id: titleBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingM
        height: root.showTitle ? Math.ceil(Theme.fontSizeMedium * 1.6) + Theme.spacingS : 0
        visible: root.showTitle

        StyledText {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: root.folderTitle
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            elide: Text.ElideRight
        }
    }

    // App shortcuts: above the blank-area mouse handling, so presses on them launch.
    Item {
        id: shortcutBar
        anchors.top: titleBar.bottom
        anchors.topMargin: root.shortcuts.length ? Theme.spacingS : 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        readonly property real cellHeight: root.iconSize + Theme.spacingS * 2 + Math.ceil(Theme.fontSizeSmall * 1.4)
        readonly property int rows: Math.ceil(root.shortcuts.length / root.columns)
        height: root.shortcuts.length ? rows * cellHeight + divider.height + Theme.spacingS : 0
        visible: root.shortcuts.length > 0

        Grid {
            id: shortcutGrid
            columns: root.columns

            Repeater {
                model: root.shortcuts

                delegate: Item {
                    id: shortcutCell

                    required property var modelData

                    width: grid.cellWidth
                    height: shortcutBar.cellHeight

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.primary, shortcutMouse.pressed ? 0.20 : 0.12)
                        opacity: shortcutMouse.containsMouse ? 1 : 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }
                    }

                    Image {
                        id: shortcutIcon
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: Theme.spacingS
                        width: root.iconSize
                        height: root.iconSize
                        scale: shortcutMouse.pressed ? 0.92 : 1
                        source: root.shortcutIcon(shortcutCell.modelData)
                        sourceSize.width: root.iconSize * 2
                        sourceSize.height: root.iconSize * 2
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        mipmap: true
                        onStatusChanged: {
                            if (status === Image.Error)
                                source = "image://icon/application-x-executable";
                        }

                        Behavior on scale {
                            NumberAnimation {
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }
                    }

                    StyledText {
                        anchors.top: shortcutIcon.bottom
                        anchors.topMargin: Theme.spacingXS
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - Theme.spacingXS * 2
                        horizontalAlignment: Text.AlignHCenter
                        text: shortcutCell.modelData.name
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        style: root.backgroundOpacity < 0.35 ? Text.Outline : Text.Normal
                        styleColor: Theme.withAlpha(Theme.surface, 0.55)
                    }

                    MouseArea {
                        id: shortcutMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.LeftButton)
                                root.launchShortcut(shortcutCell.modelData);
                            else
                                root.openBlankMenu(shortcutCell, mouse.x, mouse.y);
                        }
                    }
                }
            }
        }

        Rectangle {
            id: divider
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            height: Theme.dividerWidth
            color: Theme.withAlpha(Theme.outline, 0.3)
        }
    }

    DSpinner {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.spacingS
        size: Theme.iconSizeSmall
        visible: root.busyCount > 0 || root.loading
        color: Theme.primary
    }

    Component.onCompleted: {
        alive = true;
        // DMS lists installed terminals only on request; Open Terminal Here falls back to them.
        SessionData.probeTerminals();
        restartWatcher();
        refreshTemplates();
    }
    Component.onDestruction: {
        alive = false;
        watchRestart.stop();
        watch.running = false;
    }
}

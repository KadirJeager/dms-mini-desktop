import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets

// Full-screen overlay surface that hosts the context menu (with one submenu
// level) and the in-place rename field. The widget itself lives on the bottom
// layer, so anything drawn there would end up under windows; this surface sits
// above them and holds keyboard focus while it is open.
PanelWindow {
    id: root

    property string mode: "menu"
    property var entries: []
    property point menuPos: Qt.point(0, 0)
    property int menuIndex: -1

    property var submenuEntries: []
    property int submenuParent: -1
    property int submenuIndex: -1
    property bool submenuFocused: false
    property point submenuPos: Qt.point(0, 0)

    property rect renameRect: Qt.rect(0, 0, 0, 0)
    property string renameOriginal: ""

    // Same metrics as the DMS context menus, so the menu follows the shell's scaling.
    readonly property real menuWidth: Math.max(Theme.fieldDefaultWidth, Theme.fontSizeSmall * 20)
    readonly property real edgeMargin: Theme.spacingS
    readonly property real rowHeight: Theme.menuItemHeight
    readonly property real separatorHeight: Theme.spacingXS + Theme.dividerWidth

    signal entryTriggered(var entry)
    signal renameFinished(bool accepted, string text)
    signal dismissed

    onSubmenuIndexChanged: Qt.callLater(ensureSubmenuVisible)

    function ensureSubmenuVisible() {
        if (submenuIndex < 0)
            return;
        let top = 0;
        for (let i = 0; i < submenuIndex; i++)
            top += submenuEntries[i].separator ? separatorHeight : rowHeight;
        const bottom = top + (submenuEntries[submenuIndex].separator ? separatorHeight : rowHeight);
        if (top < submenuScroll.contentY)
            submenuScroll.contentY = top;
        else if (bottom > submenuScroll.contentY + submenuScroll.height)
            submenuScroll.contentY = bottom - submenuScroll.height;
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

    function openMenu(targetScreen, pos, menuEntries) {
        mode = "menu";
        screen = targetScreen;
        entries = menuEntries;
        menuPos = pos;
        menuIndex = -1;
        closeSubmenu();
        visible = true;
        Qt.callLater(() => keyScope.forceActiveFocus());
    }

    // Same rows with fresh state (enabled flags, submenu contents); keeps the selection.
    function updateEntries(menuEntries) {
        entries = menuEntries;
        if (submenuParent >= 0) {
            const parent = entries[submenuParent];
            if (parent && isList(parent.submenu) && parent.enabled !== false) {
                submenuEntries = toArray(parent.submenu);
                if (submenuIndex >= submenuEntries.length)
                    submenuIndex = -1;
            } else {
                closeSubmenu();
            }
        }
        if (menuIndex >= 0 && (entries[menuIndex].separator || entries[menuIndex].enabled === false))
            menuIndex = -1;
    }

    function openRename(targetScreen, rect, text, selectAll) {
        mode = "rename";
        screen = targetScreen;
        renameRect = rect;
        renameOriginal = text;
        renameInput.text = text;
        visible = true;
        Qt.callLater(() => {
            renameInput.forceActiveFocus();
            if (selectAll) {
                renameInput.selectAll();
                return;
            }
            const dot = text.lastIndexOf(".");
            renameInput.select(0, dot > 0 ? dot : text.length);
        });
    }

    function close() {
        if (!visible)
            return;
        visible = false;
        closeSubmenu();
        dismissed();
    }

    function finishRename(accepted) {
        if (mode !== "rename" || !visible)
            return;
        const text = renameInput.text;
        close();
        renameFinished(accepted && text.trim() !== "" && text !== renameOriginal, text.trim());
    }

    function trigger(entry) {
        if (!entry || entry.separator || entry.enabled === false)
            return;
        if (isList(entry.submenu))
            return;
        close();
        entryTriggered(entry);
    }

    function openSubmenu(index, rowItem) {
        const entry = entries[index];
        if (!entry || !isList(entry.submenu) || entry.enabled === false) {
            closeSubmenu();
            return;
        }
        if (submenuParent === index)
            return;
        submenuEntries = toArray(entry.submenu);
        submenuScroll.contentY = 0;
        submenuParent = index;
        submenuIndex = -1;
        const rowPos = rowItem.mapToItem(contentRoot, 0, 0);
        const subHeight = Math.min(listHeight(entry.submenu), contentRoot.height - edgeMargin * 2);
        let x = menuBox.x + menuBox.width - Theme.spacingXS;
        if (x + menuWidth > contentRoot.width - edgeMargin)
            x = menuBox.x - menuWidth + Theme.spacingXS;
        let y = rowPos.y - Theme.spacingXS;
        y = Math.max(edgeMargin, Math.min(contentRoot.height - subHeight - edgeMargin, y));
        submenuPos = Qt.point(x, y);
    }

    function closeSubmenu() {
        submenuEntries = [];
        submenuParent = -1;
        submenuIndex = -1;
        submenuFocused = false;
    }

    function listHeight(list) {
        let h = Theme.spacingXS * 2;
        for (let i = 0; i < list.length; i++)
            h += list[i].separator ? separatorHeight : rowHeight;
        return h;
    }

    function step(list, from, delta) {
        if (list.length === 0)
            return -1;
        let i = from;
        for (let n = 0; n < list.length; n++) {
            i = (i + delta + list.length) % list.length;
            if (i < 0)
                i = list.length - 1;
            const e = list[i];
            if (!e.separator && e.enabled !== false)
                return i;
        }
        return from;
    }

    screen: null
    visible: false
    color: "transparent"

    WlrLayershell.namespace: "dms:minidesktop-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    WindowBlur {
        targetWindow: root
        blurX: root.mode === "menu" ? menuBox.x : renameInput.x
        blurY: root.mode === "menu" ? menuBox.y : renameInput.y
        blurWidth: root.visible ? (root.mode === "menu" ? menuBox.width : renameInput.width) : 0
        blurHeight: root.visible ? (root.mode === "menu" ? menuBox.height : renameInput.height) : 0
        blurRadius: Theme.cornerRadius
    }

    Item {
        id: contentRoot
        anchors.fill: parent

        // Clicking anywhere outside closes the menu, or commits the rename the way file managers do.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onPressed: {
                if (root.mode === "rename")
                    root.finishRename(true);
                else
                    root.close();
            }
        }

        FocusScope {
            id: keyScope
            anchors.fill: parent
            focus: root.visible && root.mode === "menu"

            Keys.onPressed: event => {
                const inSub = root.submenuFocused && root.submenuEntries.length > 0;
                switch (event.key) {
                case Qt.Key_Escape:
                    if (inSub) {
                        root.submenuFocused = false;
                        root.submenuIndex = -1;
                    } else {
                        root.close();
                    }
                    break;
                case Qt.Key_Down:
                case Qt.Key_Tab:
                    if (inSub)
                        root.submenuIndex = root.step(root.submenuEntries, root.submenuIndex, 1);
                    else
                        root.menuIndex = root.step(root.entries, root.menuIndex, 1);
                    break;
                case Qt.Key_Up:
                case Qt.Key_Backtab:
                    if (inSub)
                        root.submenuIndex = root.step(root.submenuEntries, root.submenuIndex < 0 ? 0 : root.submenuIndex, -1);
                    else
                        root.menuIndex = root.step(root.entries, root.menuIndex < 0 ? 0 : root.menuIndex, -1);
                    break;
                case Qt.Key_Right:
                    if (!inSub && root.menuIndex >= 0 && isList(root.entries[root.menuIndex].submenu)) {
                        root.openSubmenu(root.menuIndex, menuRepeater.itemAt(root.menuIndex));
                        root.submenuFocused = true;
                        root.submenuIndex = root.step(root.submenuEntries, -1, 1);
                    }
                    break;
                case Qt.Key_Left:
                    if (inSub) {
                        root.submenuFocused = false;
                        root.submenuIndex = -1;
                    }
                    break;
                case Qt.Key_Return:
                case Qt.Key_Enter:
                case Qt.Key_Space:
                    if (inSub && root.submenuIndex >= 0) {
                        root.trigger(root.submenuEntries[root.submenuIndex]);
                    } else if (!inSub && root.menuIndex >= 0) {
                        const entry = root.entries[root.menuIndex];
                        if (isList(entry.submenu)) {
                            root.openSubmenu(root.menuIndex, menuRepeater.itemAt(root.menuIndex));
                            root.submenuFocused = true;
                            root.submenuIndex = root.step(root.submenuEntries, -1, 1);
                        } else {
                            root.trigger(entry);
                        }
                    }
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }
        }

        Rectangle {
            id: menuBox

            visible: root.mode === "menu"
            width: root.menuWidth
            height: root.listHeight(root.entries)
            x: Math.max(root.edgeMargin, Math.min(contentRoot.width - width - root.edgeMargin, root.menuPos.x))
            y: {
                const below = root.menuPos.y;
                if (below + height + root.edgeMargin <= contentRoot.height)
                    return below;
                return Math.max(root.edgeMargin, root.menuPos.y - height);
            }
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
            border.color: BlurService.borderColor
            border.width: BlurService.borderWidth
            opacity: root.visible ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.emphasizedEasing
                }
            }

            // Swallow clicks on the menu padding so they do not close it.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingXS

                Repeater {
                    id: menuRepeater
                    model: root.entries

                    delegate: Loader {
                        id: rowLoader

                        required property var modelData
                        required property int index

                        width: parent.width
                        sourceComponent: modelData.separator ? separatorComponent : rowComponent

                        Component {
                            id: rowComponent

                            MiniDesktopMenuItem {
                                entry: rowLoader.modelData
                                highlighted: root.menuIndex === rowLoader.index || root.submenuParent === rowLoader.index
                                onHovered: {
                                    root.menuIndex = rowLoader.index;
                                    root.submenuFocused = false;
                                    if (hasSubmenu)
                                        root.openSubmenu(rowLoader.index, rowLoader);
                                    else
                                        root.closeSubmenu();
                                }
                                onActivated: {
                                    if (hasSubmenu) {
                                        root.openSubmenu(rowLoader.index, rowLoader);
                                        return;
                                    }
                                    root.trigger(rowLoader.modelData);
                                }
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            id: submenuBox

            visible: root.mode === "menu" && root.submenuEntries.length > 0
            width: root.menuWidth
            height: Math.min(root.listHeight(root.submenuEntries), contentRoot.height - root.edgeMargin * 2)
            x: root.submenuPos.x
            y: root.submenuPos.y
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
            border.color: BlurService.borderColor
            border.width: BlurService.borderWidth

            WindowBlur {
                targetWindow: root
                blurX: submenuBox.x
                blurY: submenuBox.y
                blurWidth: submenuBox.visible ? submenuBox.width : 0
                blurHeight: submenuBox.visible ? submenuBox.height : 0
                blurRadius: Theme.cornerRadius
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            // Template directories can contain more entries than fit on screen.
            Flickable {
                id: submenuScroll
                anchors.fill: parent
                anchors.margins: Theme.spacingXS
                contentWidth: width
                contentHeight: submenuColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                }

                Column {
                    id: submenuColumn
                    width: submenuScroll.width

                    Repeater {
                        model: root.submenuEntries

                        delegate: Loader {
                            id: subLoader

                            required property var modelData
                            required property int index

                            width: parent.width
                            sourceComponent: modelData.separator ? separatorComponent : subRowComponent

                            Component {
                                id: subRowComponent

                                MiniDesktopMenuItem {
                                    entry: subLoader.modelData
                                    highlighted: root.submenuIndex === subLoader.index
                                    onHovered: {
                                        root.submenuFocused = true;
                                        root.submenuIndex = subLoader.index;
                                    }
                                    onActivated: root.trigger(subLoader.modelData)
                                }
                            }
                        }
                    }
                }
            }
        }

        Component {
            id: separatorComponent

            Item {
                height: root.separatorHeight

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    height: Theme.dividerWidth
                    color: Theme.outlineHeavy
                }
            }
        }

        DTextField {
            id: renameInput

            visible: root.mode === "rename"
            width: Math.min(contentRoot.width - root.edgeMargin * 2, Math.max(root.renameRect.width, Theme.fontSizeSmall * 14))
            x: Math.max(root.edgeMargin, Math.min(contentRoot.width - width - root.edgeMargin, root.renameRect.x + root.renameRect.width / 2 - width / 2))
            y: Math.max(root.edgeMargin, Math.min(contentRoot.height - height - root.edgeMargin, root.renameRect.y))
            font.pixelSize: Theme.fontSizeSmall
            onAccepted: root.finishRename(true)
            Keys.onEscapePressed: event => {
                root.finishRename(false);
                event.accepted = true;
            }
        }
    }
}

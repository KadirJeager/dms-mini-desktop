import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets

// One icon on the Mini Desktop grid.
Item {
    id: root

    required property var modelData
    required property int index
    required property var desktop

    readonly property var entry: modelData
    readonly property bool selected: desktop.selection[entry.path] === true
    readonly property bool isCurrent: desktop.currentIndex === index && desktop.activeFocusShown
    readonly property bool isCut: desktop.cutPaths[entry.path] === true
    readonly property int iconSize: desktop.iconSize
    property bool dropHovered: false

    readonly property string iconSource: {
        if (entry.image)
            return entry.uri;
        if (entry.thumbnail)
            return "file://" + entry.thumbnail;
        if (entry.desktopIcon) {
            const icon = entry.desktopIcon;
            if (icon.startsWith("/") || icon.startsWith("~") || icon.startsWith("file://"))
                return Paths.resolveIconUrl(icon);
            // The theme icon provider draws a placeholder instead of failing, so check first.
            if (Quickshell.iconPath(icon, true) !== "")
                return Paths.resolveIconUrl(icon);
        }
        const names = entry.icons || [];
        for (let i = 0; i < names.length; i++) {
            if (names[i].startsWith("/"))
                return "file://" + names[i];
            const found = Quickshell.iconPath(names[i], true);
            if (found)
                return found;
        }
        const generic = entry.kind === "folder" ? "folder" : entry.kind === "app" ? "application-x-executable" : "text-x-generic";
        return Quickshell.iconPath(generic, true);
    }
    // Material symbol used when the icon theme has neither the file's icon nor a generic one.
    readonly property string fallbackGlyph: {
        switch (entry.kind) {
        case "folder":
            return "folder";
        case "app":
            return "apps";
        case "link":
            return "link";
        case "broken":
            return "link_off";
        }
        return (entry.mime || "").startsWith("image/") ? "image" : "description";
    }
    property bool iconFailed: false
    onIconSourceChanged: iconFailed = false

    width: GridView.view.cellWidth
    height: GridView.view.cellHeight
    z: selected ? 2 : 0

    // Where the label sits, for the rename field drawn over it.
    function labelRect() {
        return label.mapToItem(null, 0, 0, label.width, Math.max(label.height, 24));
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 2
        radius: Theme.cornerRadius
        color: {
            if (root.dropHovered)
                return Theme.withAlpha(Theme.primary, 0.28);
            if (root.selected)
                return Theme.withAlpha(Theme.primary, mouse.containsMouse ? 0.26 : 0.20);
            if (mouse.containsMouse)
                return Theme.withAlpha(Theme.surfaceText, 0.08);
            return "transparent";
        }
        border.width: root.isCurrent || root.dropHovered ? 1 : 0
        border.color: Theme.withAlpha(Theme.primary, 0.7)

        Behavior on color {
            ColorAnimation {
                duration: Theme.shortDuration
            }
        }
    }

    Item {
        id: iconBox
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Theme.spacingS
        width: root.iconSize
        height: root.iconSize
        opacity: (root.isCut ? 0.45 : 1) * (root.entry.available === false ? 0.5 : 1)

        Image {
            id: icon
            anchors.fill: parent
            source: root.iconSource
            sourceSize.width: root.iconSize * 2
            sourceSize.height: root.iconSize * 2
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            mipmap: true
            visible: !root.iconFailed && root.iconSource !== ""
            onStatusChanged: {
                if (status === Image.Error)
                    root.iconFailed = true;
            }
        }

        DIcon {
            anchors.centerIn: parent
            visible: root.iconFailed || root.iconSource === ""
            name: root.fallbackGlyph
            size: root.iconSize * 0.9
            color: Theme.surfaceText
        }

        // A launcher that is not executable does not run until allowed from its menu.
        Rectangle {
            visible: root.entry.trusted === false
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: Math.max(14, root.iconSize * 0.34)
            height: width
            radius: width / 2
            color: Theme.surfaceContainerHigh
            border.width: 1
            border.color: Theme.withAlpha(Theme.outline, 0.4)

            DIcon {
                anchors.centerIn: parent
                name: "gpp_maybe"
                size: parent.width * 0.72
                color: Theme.warning
            }
        }

        Rectangle {
            visible: root.entry.symlink || root.entry.kind === "link"
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            width: Math.max(14, root.iconSize * 0.34)
            height: width
            radius: width / 2
            color: Theme.surfaceContainerHigh
            border.width: 1
            border.color: Theme.withAlpha(Theme.outline, 0.4)

            DIcon {
                anchors.centerIn: parent
                name: root.entry.kind === "broken" ? "link_off" : "arrow_outward"
                size: parent.width * 0.72
                color: root.entry.kind === "broken" ? Theme.error : Theme.surfaceText
            }
        }
    }

    // Behind a selected name that runs past the cell, so it stays readable over the next row.
    Rectangle {
        visible: root.selected && label.y + label.height > root.height
        x: label.x - Theme.spacingXS
        y: label.y - 2
        width: label.width + Theme.spacingXS * 2
        height: label.height + 4
        radius: Theme.cornerRadius / 2
        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.95)
        border.width: 1
        border.color: Theme.withAlpha(Theme.primary, 0.5)
    }

    StyledText {
        id: label
        anchors.top: iconBox.bottom
        anchors.topMargin: Theme.spacingXS
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - Theme.spacingXS * 2
        text: root.entry.label
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceText
        wrapMode: Text.Wrap
        maximumLineCount: root.selected ? 4 : 2
        elide: Text.ElideRight
        lineHeight: 0.95
        style: root.desktop.backgroundOpacity < 0.35 ? Text.Outline : Text.Normal
        styleColor: Theme.withAlpha(Theme.surface, 0.55)
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        drag.target: dragProxy
        drag.threshold: 8

        property bool pressedSelected: false
        property bool dragged: false

        drag.onActiveChanged: {
            if (drag.active) {
                dragged = true;
                dragProxy.mimeData = root.desktop.dragMimeData(root.entry);
                dragProxy.mimeReady = true;
            } else {
                dragProxy.mimeReady = false;
            }
        }

        onPressed: mouse => {
            root.desktop.takeFocus();
            if (mouse.button !== Qt.LeftButton) {
                root.desktop.openItemMenu(root.index, root, mouse.x, mouse.y);
                return;
            }
            pressedSelected = root.selected;
            dragged = false;
            root.desktop.pressItem(root.index, mouse.modifiers);
            dragProxy.x = mouse.x - dragProxy.width / 2;
            dragProxy.y = mouse.y - dragProxy.height / 2;
        }
        onReleased: mouse => {
            if (mouse.button === Qt.LeftButton && !dragged)
                root.desktop.releaseItem(root.index, mouse.modifiers, pressedSelected);
        }
        onDoubleClicked: mouse => {
            if (mouse.button === Qt.LeftButton)
                root.desktop.openItem(root.entry);
        }
    }

    // Invisible drag source: files dragged out land in file managers, browsers and chat apps.
    Item {
        id: dragProxy
        width: root.iconSize
        height: root.iconSize
        property var mimeData: ({})
        property bool mimeReady: false

        Drag.active: mouse.drag.active && mimeReady
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
        Drag.proposedAction: Qt.CopyAction
        Drag.mimeData: mimeData
        Drag.imageSource: icon.source
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2
        Drag.onDragFinished: dropAction => {
            dragProxy.x = 0;
            dragProxy.y = 0;
        }
    }

    DropArea {
        anchors.fill: parent
        enabled: root.entry.kind === "folder"
        onEntered: drag => {
            root.dropHovered = root.desktop.canDropOn(drag, root.entry.path);
            if (!root.dropHovered)
                drag.accepted = false;
        }
        onExited: root.dropHovered = false
        onDropped: drop => {
            root.dropHovered = false;
            root.desktop.handleDrop(drop, root.entry.path);
        }
    }
}

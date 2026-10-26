import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets

// One row of the Mini Desktop context menu; styled like the DMS dock menus.
Rectangle {
    id: root

    property var entry: ({})
    property bool highlighted: false
    // A JS array, or the sequence object Qt turns it into on the way through `var`.
    readonly property bool hasSubmenu: !!entry.submenu && typeof entry.submenu !== "string" && typeof entry.submenu.length === "number"
    readonly property bool destructive: entry.destructive === true

    signal activated
    signal hovered

    height: Theme.menuItemHeight
    radius: Theme.cornerRadius
    opacity: enabled ? 1 : 0.4
    enabled: entry.enabled !== false
    color: {
        if (!highlighted || !enabled)
            return "transparent";
        if (destructive)
            return Theme.errorHover;
        return BlurService.hoverColor(Theme.widgetBaseHoverColor);
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingS
        anchors.right: chevron.left
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        DIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: root.entry.icon || ""
            size: Theme.iconSizeSmall
            color: root.destructive && root.highlighted && root.enabled ? Theme.error : Theme.surfaceText
            opacity: 0.75
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Theme.iconSizeSmall - parent.spacing
            text: root.entry.text || ""
            font.pixelSize: Theme.fontSizeSmall
            font.weight: root.entry.bold ? Font.DemiBold : Font.Normal
            color: root.destructive && root.highlighted && root.enabled ? Theme.error : Theme.surfaceText
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
        }
    }

    DIcon {
        id: chevron
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        name: I18n.isRtl ? "chevron_left" : "chevron_right"
        size: Theme.iconSizeSmall
        color: Theme.surfaceText
        opacity: root.hasSubmenu ? 0.7 : 0
        width: root.hasSubmenu ? implicitWidth : 0
    }

    DRipple {
        id: ripple
        rippleColor: root.destructive ? Theme.error : Theme.surfaceText
        cornerRadius: Theme.cornerRadius
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onEntered: root.hovered()
        onPressed: mouse => ripple.trigger(mouse.x, mouse.y)
        onClicked: root.activated()
    }
}

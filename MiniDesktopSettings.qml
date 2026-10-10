import QtQuick
import QtCore
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.FileBrowser

PluginSettings {
    id: root
    pluginId: "miniDesktop"

    // DMS supplies an instance-scoped pluginService for this settings card.
    property string instanceId: ""
    property var instanceData: null

    Column {
        id: folderRow

        width: parent.width
        spacing: Theme.spacingS

        property string value: ""

        function load() {
            value = root.loadValue("folder", "");
            folderField.text = value;
        }

        function save(path) {
            const next = (path || "").trim();
            folderField.text = next;
            if (next === value)
                return;
            value = next;
            root.saveValue("folder", next);
        }

        Component.onCompleted: Qt.callLater(load)

        StyledText {
            text: I18n.trFor("miniDesktop", "Folder")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: I18n.trFor("miniDesktop", "The folder this widget shows; everything created in it is saved there. Leave empty for the Desktop.")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS

            DankTextField {
                id: folderField
                width: parent.width - chooseButton.width - resetButton.width - parent.spacing * 2
                placeholderText: decodeURIComponent(String(StandardPaths.writableLocation(StandardPaths.DesktopLocation)).replace(/^file:\/\//, ""))
                onEditingFinished: folderRow.save(text)
                onActiveFocusChanged: {
                    if (!activeFocus)
                        folderRow.save(text);
                }
            }

            DankButton {
                id: chooseButton
                anchors.verticalCenter: folderField.verticalCenter
                text: I18n.trFor("miniDesktop", "Choose…")
                iconName: "folder_open"
                onClicked: folderBrowser.open()
            }

            DankActionButton {
                id: resetButton
                anchors.verticalCenter: folderField.verticalCenter
                iconName: "restart_alt"
                enabled: folderRow.value !== ""
                opacity: enabled ? 1 : 0.35
                tooltipText: I18n.trFor("miniDesktop", "Back to the Desktop")
                onClicked: folderRow.save("")
            }
        }

        FileBrowserSurfaceModal {
            id: folderBrowser
            browserTitle: I18n.trFor("miniDesktop", "Choose Folder")
            browserIcon: "folder_open"
            browserType: "generic"
            folderMode: true
            onFileSelected: path => {
                folderRow.save(Paths.strip(path));
                close();
            }
        }
    }

    ToggleSetting {
        settingKey: "showTitle"
        label: I18n.trFor("miniDesktop", "Show title")
        description: I18n.trFor("miniDesktop", "Shows the folder name above the icons")
        defaultValue: false
    }

    SliderSetting {
        settingKey: "iconSize"
        label: I18n.trFor("miniDesktop", "Icon size")
        defaultValue: 48
        minimum: 32
        maximum: 96
        unit: " px"
    }

    SliderSetting {
        settingKey: "backgroundOpacity"
        label: I18n.trFor("miniDesktop", "Background opacity")
        description: I18n.trFor("miniDesktop", "Set to 0 to show only the icons")
        defaultValue: 60
        minimum: 0
        maximum: 100
        unit: "%"
    }
}

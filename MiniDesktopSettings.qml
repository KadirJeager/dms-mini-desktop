import QtQuick
import QtCore
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Modules.Settings.Widgets
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

            DTextField {
                id: folderField
                width: parent.width - chooseButton.width - resetButton.width - parent.spacing * 2
                placeholderText: decodeURIComponent(String(StandardPaths.writableLocation(StandardPaths.DesktopLocation)).replace(/^file:\/\//, ""))
                onEditingFinished: folderRow.save(text)
                onActiveFocusChanged: {
                    if (!activeFocus)
                        folderRow.save(text);
                }
            }

            DButton {
                id: chooseButton
                anchors.verticalCenter: folderField.verticalCenter
                text: I18n.trFor("miniDesktop", "Choose…")
                iconName: "folder_open"
                onClicked: folderBrowser.open()
            }

            DActionButton {
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


    // App shortcuts shown above the folder's icons; the widget itself only launches them.
    Column {
        id: shortcutManager

        property var items: []

        width: parent.width
        spacing: Theme.spacingS

        function load() {
            const value = root.loadValue("shortcuts", []);
            const list = [];
            for (let i = 0; i < (value?.length ?? 0); i++)
                list.push(value[i]);
            items = list;
        }

        function save(list) {
            items = list;
            root.saveValue("shortcuts", list);
        }

        function isAdded(app) {
            return items.some(item => (app.id && item.desktopId === app.id) || (!item.desktopId && item.name === app.name));
        }

        function addApp(appId) {
            const apps = AppSearchService.getVisibleApplications() || [];
            const app = apps.find(a => (a.id || a.execString) === appId);
            if (!app || isAdded(app))
                return;
            const command = [];
            for (let i = 0; i < (app.command?.length ?? 0); i++)
                command.push(app.command[i]);
            save(items.concat([{
                    "name": app.name || app.id,
                    "desktopId": app.id || "",
                    "command": command,
                    "icon": app.icon ? String(app.icon) : "application-x-executable"
                }]));
        }

        function removeAt(index) {
            const list = items.slice();
            list.splice(index, 1);
            save(list);
        }

        function move(from, to) {
            if (from < 0 || to < 0 || from >= items.length || to >= items.length || from === to)
                return;
            const list = items.slice();
            list.splice(to, 0, list.splice(from, 1)[0]);
            save(list);
        }

        function openPicker() {
            appPicker.appsModel = (AppSearchService.getVisibleApplications() || []).filter(app => !isAdded(app));
            appPicker.show();
        }

        function iconFor(shortcut) {
            if (shortcut.iconOverride)
                return Paths.resolveIconUrl(shortcut.iconOverride);
            const entry = shortcut.desktopId ? DesktopEntries.byId(shortcut.desktopId) : null;
            if (entry && entry.icon)
                return Paths.resolveIconUrl(String(entry.icon));
            return Paths.resolveIconUrl(shortcut.icon || "application-x-executable");
        }

        Component.onCompleted: Qt.callLater(load)

        AppBrowserPopup {
            id: appPicker
            parentModal: shortcutManager.QsWindow.window
            onAppSelected: appId => shortcutManager.addApp(appId)
        }

        StyledText {
            text: I18n.trFor("miniDesktop", "App shortcuts")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: I18n.trFor("miniDesktop", "Apps shown above the folder's icons; one click opens them. Use the arrows to change their order.")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Repeater {
            model: shortcutManager.items

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index

                width: shortcutManager.width
                height: Theme.menuItemHeight + Theme.spacingS
                radius: Theme.cornerRadius
                color: Theme.floatingWindowFieldColor

                Image {
                    id: rowIcon
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.iconSize
                    height: Theme.iconSize
                    source: shortcutManager.iconFor(row.modelData)
                    sourceSize.width: Theme.iconSize * 2
                    sourceSize.height: Theme.iconSize * 2
                    fillMode: Image.PreserveAspectFit
                    onStatusChanged: {
                        if (status === Image.Error)
                            source = "image://icon/application-x-executable";
                    }
                }

                StyledText {
                    anchors.left: rowIcon.right
                    anchors.right: rowButtons.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.modelData.name
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                Row {
                    id: rowButtons
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    DActionButton {
                        iconName: "arrow_upward"
                        iconSize: Theme.iconSizeSmall
                        enabled: row.index > 0
                        opacity: enabled ? 1 : 0.35
                        tooltipText: I18n.trFor("miniDesktop", "Move up")
                        onClicked: shortcutManager.move(row.index, row.index - 1)
                    }

                    DActionButton {
                        iconName: "arrow_downward"
                        iconSize: Theme.iconSizeSmall
                        enabled: row.index < shortcutManager.items.length - 1
                        opacity: enabled ? 1 : 0.35
                        tooltipText: I18n.trFor("miniDesktop", "Move down")
                        onClicked: shortcutManager.move(row.index, row.index + 1)
                    }

                    DActionButton {
                        iconName: "close"
                        iconSize: Theme.iconSizeSmall
                        iconColor: Theme.error
                        tooltipText: I18n.trFor("miniDesktop", "Remove")
                        onClicked: shortcutManager.removeAt(row.index)
                    }
                }
            }
        }

        DButton {
            anchors.horizontalCenter: parent.horizontalCenter
            text: I18n.trFor("miniDesktop", "Add app")
            iconName: "add"
            onClicked: shortcutManager.openPicker()
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

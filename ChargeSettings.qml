import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Services
import "logic/ChargeLimit.js" as CL

PluginSettings {
    id: root
    pluginId: "frameworkChargeProtection"

    readonly property var daemon: PluginService.pluginDaemonInstances?.[pluginId] ?? null
    readonly property ChargeTexts texts: ChargeTexts {}
    readonly property string helperState: daemon ? daemon.helperState : "probing"

    // The page is created when it opens: check the helper and the hardware again.
    onDaemonChanged: _refresh()
    Component.onCompleted: _refresh()

    function _refresh() {
        if (!daemon)
            return;
        daemon.probeHelper();
        daemon.refresh("settings", 30 * 1000);
    }

    ChargeControls {
        width: parent.width
        daemon: root.daemon
    }

    SectionHeader {
        text: I18n.trFor("frameworkChargeProtection", "Behavior")
    }

    ToggleSetting {
        settingKey: "restoreAfterBoot"
        label: I18n.trFor("frameworkChargeProtection", "Restore after boot")
        description: I18n.trFor("frameworkChargeProtection", "The firmware applies its own charge limit setting at every boot. Once per boot, after you log in, set your choice again if it differs. Restarting DMS only reads the limit.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "keepEnforcing"
        label: I18n.trFor("frameworkChargeProtection", "Keep enforcing this limit")
        description: I18n.trFor("frameworkChargeProtection", "Overrides other tools: at every check, writes your choice back if another program (framework_tool, Framework Control, the Framework tool TUI…) changed it. When off, changes made elsewhere are shown and adopted.")
        defaultValue: false
    }

    SelectionSetting {
        settingKey: "pollMinutes"
        label: I18n.trFor("frameworkChargeProtection", "Check every")
        description: I18n.trFor("frameworkChargeProtection", "How often the hardware limit is read to notice changes made elsewhere. It is also read when the popout opens and after resume. Each check runs the helper through pkexec, which logs a line in the system journal.")
        options: CL.POLL_MINUTES.map(m => ({
                    label: m < 60 ? I18n.trFor("frameworkChargeProtection", "%1 min").arg(m) : I18n.trFor("frameworkChargeProtection", "1 hour"),
                    value: String(m)
                }))
        defaultValue: String(CL.DEFAULT_POLL_MINUTES)
    }

    ToggleSetting {
        settingKey: "fullChargeOnDisable"
        label: I18n.trFor("frameworkChargeProtection", "Allow full charge when turned off")
        description: I18n.trFor("frameworkChargeProtection", "When you disable or uninstall this plugin, or remove its helper, set the maximum back to 100% if charging is limited. Logging out or restarting DMS never changes the limit.")
        defaultValue: true
    }

    SectionHeader {
        text: I18n.trFor("frameworkChargeProtection", "Bar")
    }

    SelectionSetting {
        settingKey: "pillClick"
        label: I18n.trFor("frameworkChargeProtection", "Click on the pill")
        options: [
            {
                label: I18n.trFor("frameworkChargeProtection", "Toggle the limit (right click: panel)"),
                value: "toggle"
            },
            {
                label: I18n.trFor("frameworkChargeProtection", "Open the panel (right click: toggle)"),
                value: "panel"
            }
        ]
        defaultValue: "toggle"
    }

    ToggleSetting {
        settingKey: "showLimitInBar"
        label: I18n.trFor("frameworkChargeProtection", "Show the limit in the bar")
        description: I18n.trFor("frameworkChargeProtection", "Next to the icon, while charging is limited")
        defaultValue: true
    }

    SectionHeader {
        text: I18n.trFor("frameworkChargeProtection", "System helper")
    }

    ColumnLayout {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            Layout.fillWidth: true
            text: root.texts.helperStateText(root.helperState, root.daemon ? root.daemon.installedHelperVersion : 0)
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Theme.fontWeightMedium
            color: root.helperState === "broken" || root.helperState === "no-polkit" ? Theme.warning : Theme.surfaceText
            wrapMode: Text.Wrap
        }

        StyledText {
            Layout.fillWidth: true
            text: root.daemon && root.daemon.toolFound ? I18n.trFor("frameworkChargeProtection", "framework_tool: %1").arg(root.daemon.toolPath) : root.texts.noToolText()
            font.pixelSize: Theme.fontSizeSmall
            color: root.daemon && root.daemon.toolFound ? Theme.surfaceVariantText : Theme.warning
            wrapMode: Text.Wrap
        }

        Flow {
            Layout.fillWidth: true
            spacing: Theme.spacingS
            visible: root.daemon !== null

            DButton {
                visible: root.helperState === "missing" || root.helperState === "broken" || root.helperState === "outdated"
                text: root.helperState === "missing" ? I18n.trFor("frameworkChargeProtection", "Install helper") : (root.helperState === "outdated" ? I18n.trFor("frameworkChargeProtection", "Update helper") : I18n.trFor("frameworkChargeProtection", "Reinstall helper"))
                iconName: "admin_panel_settings"
                busy: root.daemon && root.daemon.installing
                enabled: root.daemon && !root.daemon.busy && root.daemon.toolFound
                onClicked: root.daemon.installHelper()
            }

            DButton {
                visible: root.helperState === "installed" || root.helperState === "outdated" || root.helperState === "broken"
                text: I18n.trFor("frameworkChargeProtection", "Remove helper")
                iconName: "delete"
                variant: "tonal"
                danger: true
                busy: root.daemon && root.daemon.uninstalling
                enabled: root.daemon && !root.daemon.busy
                onClicked: root.daemon.uninstallHelper()
            }
        }

        StyledText {
            Layout.fillWidth: true
            text: I18n.trFor("frameworkChargeProtection", "The helper can only read the charge limit or set it from %1 to 100%, through framework_tool. polkit lets the active local session run it without a password; installing, updating and removing it ask for an administrator password. Files: %2, %3 and %4.").arg(CL.MIN_LIMIT).arg(CL.HELPER_PATH).arg(CL.UNINSTALLER_PATH).arg(CL.POLICY_PATH)
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.Wrap
        }

        StyledText {
            Layout.fillWidth: true
            text: I18n.trFor("frameworkChargeProtection", "Uninstalling the plugin from DMS offers to remove the helper. To remove it by hand: pkexec %1").arg(CL.UNINSTALLER_PATH)
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.Wrap
        }
    }

    SectionHeader {
        text: I18n.trFor("frameworkChargeProtection", "Other tools")
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("frameworkChargeProtection", "If Framework Control manages the battery charge limit too, turn its limit off: it reapplies its own value every ten minutes. Keep DMS's Scale battery level to charge limit off so the battery percentage stays real.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.Wrap
    }

    component SectionHeader: StyledText {
        width: parent.width
        topPadding: Theme.spacingM
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }
}

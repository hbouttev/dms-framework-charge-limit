import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.DCommon.Widgets
import "logic/ChargeLimit.js" as CL

// The charge limit controls, shared by the bar popout, the Control Center detail page and
// the settings page. State and actions live in the daemon; this only renders and forwards.
ColumnLayout {
    id: root

    property var daemon: null
    property bool showHeader: true

    readonly property bool ready: daemon !== null
    readonly property string status: daemon ? daemon.status : ""
    readonly property bool needsSetup: status === "setup"
    readonly property bool working: ready && daemon.busy
    readonly property ChargeTexts texts: ChargeTexts {}

    spacing: Theme.spacingM

    // ---- Status -----------------------------------------------------------------------

    RowLayout {
        Layout.fillWidth: true
        visible: root.showHeader
        spacing: Theme.spacingM

        DIcon {
            Layout.alignment: Qt.AlignVCenter
            name: root.texts.icon(root.daemon)
            size: Theme.iconSize
            color: root.status === "on" ? Theme.primary : (root.status === "error" || root.status === "unexpected" || !root.ready ? Theme.warning : Theme.surfaceVariantText)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            StyledText {
                Layout.fillWidth: true
                text: root.texts.statusTitle(root.daemon)
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Theme.fontWeightMedium
                color: Theme.surfaceText
            }

            StyledText {
                Layout.fillWidth: true
                // The setup notice below shows the detail instead.
                visible: text.length > 0 && !root.needsSetup
                text: root.texts.statusDetail(root.daemon)
                wrapMode: Text.Wrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        DActionButton {
            Layout.alignment: Qt.AlignVCenter
            visible: root.ready && root.daemon.helperUsable
            enabled: !root.working
            iconName: "refresh"
            buttonSize: Theme.buttonHeightXS
            tooltipText: I18n.trFor("frameworkChargeLimit", "Read the charge limit again")
            Accessible.name: tooltipText
            onClicked: root.daemon.refresh("manual")
        }
    }

    // Setup notice (without the header, e.g. in the settings page, the status shows here).
    StyledRect {
        Layout.fillWidth: true
        visible: root.needsSetup || (!root.showHeader && (root.status === "error" || root.status === "unexpected"))
        implicitHeight: noticeColumn.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: root.needsSetup ? Theme.primaryContainer : Theme.withAlpha(Theme.warning, 0.12)

        ColumnLayout {
            id: noticeColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            StyledText {
                Layout.fillWidth: true
                visible: !root.showHeader
                text: root.texts.statusTitle(root.daemon)
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Theme.fontWeightMedium
                color: Theme.surfaceText
                wrapMode: Text.Wrap
            }

            StyledText {
                Layout.fillWidth: true
                visible: !root.showHeader || root.needsSetup
                text: root.texts.statusDetail(root.daemon)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                wrapMode: Text.Wrap
            }

            DButton {
                visible: root.needsSetup && root.daemon.helperState !== "no-polkit" && root.daemon.toolFound
                text: root.daemon && root.daemon.helperState === "missing" ? I18n.trFor("frameworkChargeLimit", "Install helper") : I18n.trFor("frameworkChargeLimit", "Reinstall helper")
                iconName: "admin_panel_settings"
                variant: "tonal"
                busy: root.daemon && root.daemon.installing
                enabled: !root.working
                onClicked: root.daemon.installHelper()
            }
        }
    }

    // ---- Controls ---------------------------------------------------------------------

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacingM

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingXXS

            StyledText {
                Layout.fillWidth: true
                text: I18n.trFor("frameworkChargeLimit", "Limit charging")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Theme.fontWeightMedium
                color: Theme.surfaceText
                wrapMode: Text.Wrap
            }

            StyledText {
                Layout.fillWidth: true
                text: I18n.trFor("frameworkChargeLimit", "When disabled, charging is allowed up to 100%.")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.Wrap
            }
        }

        DToggle {
            Layout.alignment: Qt.AlignVCenter
            checked: root.ready && root.daemon.displayOn
            enabled: root.ready && !root.daemon.installing && !root.daemon.uninstalling
            Accessible.name: I18n.trFor("frameworkChargeLimit", "Limit charging")
            onToggled: checked => root.daemon.setEnabled(checked, true)
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacingM

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingXXS

            StyledText {
                Layout.fillWidth: true
                text: I18n.trFor("frameworkChargeLimit", "Maximum charge when enabled")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Theme.fontWeightMedium
                color: Theme.surfaceText
                wrapMode: Text.Wrap
            }

            StyledText {
                Layout.fillWidth: true
                text: root.ready && root.daemon.displayOn ? I18n.trFor("frameworkChargeLimit", "%1–%2%, applied right away.").arg(CL.MIN_LIMIT).arg(CL.MAX_PROTECTED_LIMIT) : I18n.trFor("frameworkChargeLimit", "%1–%2%, saved for the next time charging is limited.").arg(CL.MIN_LIMIT).arg(CL.MAX_PROTECTED_LIMIT)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.Wrap
            }
        }

        LimitField {
            Layout.alignment: Qt.AlignVCenter
            value: root.ready ? root.daemon.protectedLimit : CL.DEFAULT_LIMIT
            enabled: root.ready
            onCommitted: value => root.daemon.setProtectedLimit(value)
        }
    }

    StyledText {
        Layout.fillWidth: true
        text: I18n.trFor("frameworkChargeLimit", "The battery percentage is not rescaled, and it may settle a few points below the limit: the embedded controller resumes charging only once it drops about 5% under it.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.Wrap
    }
}

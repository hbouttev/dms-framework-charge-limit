import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.DCommon.Widgets
import "logic/ChargeLimit.js" as CL

// The charge limit controls, shared by the bar popout, the Control Center detail page and
// the settings page. State and actions live in the daemon; this only renders and forwards.
//
// Laid out like DMS's own battery popout: a hero card with a ring gauge, then the two
// controls as a grouped list (large outer corners, small inner ones, a thin gap).
ColumnLayout {
    id: root

    property var daemon: null
    property bool showHeader: true
    // Called by the hero card's settings button; the button is hidden when unset.
    property var openSettings: null

    readonly property bool ready: daemon !== null
    readonly property string status: daemon ? daemon.status : ""
    readonly property bool needsSetup: status === "setup"
    readonly property bool working: ready && daemon.busy
    readonly property bool problem: status === "error" || status === "unexpected" || !ready
    readonly property ChargeTexts texts: ChargeTexts {}

    readonly property bool limitOn: ready && daemon.displayOn

    // The hero icon and its circle: the accent, or the muted text color, at low opacity behind.
    readonly property color accent: problem ? Theme.warning : (limitOn ? Theme.primary : Theme.onSurfaceVariant)
    readonly property color accentContainer: Theme.withAlpha(accent, problem ? 0.16 : (limitOn ? 0.2 : 0.12))

    // A write usually ends within a fifth of a second; dimming the switch for that would
    // only flash, so it is dimmed only when a write is still running after a moment.
    readonly property bool writing: ready && daemon.busyKind === "write"
    property bool writePending: false

    onWritingChanged: {
        writePending = false;
        if (writing)
            pendingDelay.restart();
        else
            pendingDelay.stop();
    }

    Timer {
        id: pendingDelay
        interval: 300
        onTriggered: root.writePending = true
    }

    spacing: Theme.spacingM

    // ---- Hero -------------------------------------------------------------------------

    DCard {
        Layout.fillWidth: true
        Layout.preferredHeight: heroRow.implicitHeight + pad * 2
        visible: root.showHeader
        restRadius: Theme.cornerRadiusL

        RowLayout {
            id: heroRow
            width: parent.width
            spacing: Theme.spacingM

            // The icon in a tonal container, the size of DMS's battery ring. No ring: the
            // slider shows the limit, and a ring would read as the battery level.
            Rectangle {
                Layout.preferredWidth: Theme.iconButtonSize + Theme.spacingM
                Layout.preferredHeight: Layout.preferredWidth
                Layout.alignment: Qt.AlignVCenter
                radius: width / 2
                color: root.accentContainer

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.mediumDuration
                    }
                }

                DIcon {
                    anchors.centerIn: parent
                    name: root.texts.icon(root.daemon)
                    size: Theme.iconSize
                    color: root.accent
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: Theme.spacingXXS

                StyledText {
                    Layout.fillWidth: true
                    text: root.texts.statusTitle(root.daemon)
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.fontSizeXLarge
                    color: root.problem ? Theme.warning : Theme.onSurface
                }

                StyledText {
                    Layout.fillWidth: true
                    // The setup notice below shows the detail instead.
                    visible: text.length > 0 && !root.needsSetup
                    text: root.texts.statusDetail(root.daemon)
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.onSurfaceVariant
                }
            }

            DActionButton {
                Layout.alignment: Qt.AlignVCenter
                visible: root.ready && root.daemon.helperUsable
                enabled: !root.working
                iconName: "refresh"
                tooltipText: I18n.trFor("frameworkChargeLimit", "Read the charge limit again")
                Accessible.name: tooltipText
                onClicked: root.daemon.refresh("manual")
            }

            DActionButton {
                Layout.alignment: Qt.AlignVCenter
                visible: typeof root.openSettings === "function"
                iconName: "settings"
                tooltipText: I18n.trFor("frameworkChargeLimit", "Plugin settings")
                Accessible.name: tooltipText
                onClicked: root.openSettings()
            }
        }
    }

    // ---- Notice -----------------------------------------------------------------------

    // Setup notice (without the hero, e.g. in the settings page, problems show here too).
    DCard {
        Layout.fillWidth: true
        Layout.preferredHeight: noticeColumn.implicitHeight + pad * 2
        visible: root.needsSetup || (!root.showHeader && root.problem && root.ready)
        restRadius: Theme.cornerRadiusL
        tone: root.needsSetup ? "primary" : ""
        color: root.needsSetup ? surfaceColor : Theme.withAlpha(Theme.warning, 0.12)

        ColumnLayout {
            id: noticeColumn
            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                Layout.fillWidth: true
                visible: !root.showHeader
                text: root.texts.statusTitle(root.daemon)
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Theme.fontWeightMedium
                color: root.needsSetup ? Theme.onPrimaryContainer : Theme.warning
                wrapMode: Text.Wrap
            }

            StyledText {
                Layout.fillWidth: true
                visible: !root.showHeader || root.needsSetup
                text: root.texts.statusDetail(root.daemon)
                font.pixelSize: Theme.fontSizeSmall
                color: root.needsSetup ? Theme.onPrimaryContainer : Theme.onSurface
                wrapMode: Text.Wrap
            }

            DButton {
                visible: root.needsSetup && root.daemon.helperState !== "no-polkit" && root.daemon.toolFound
                text: root.daemon && root.daemon.helperState === "missing" ? I18n.trFor("frameworkChargeLimit", "Install helper") : I18n.trFor("frameworkChargeLimit", "Reinstall helper")
                iconName: "admin_panel_settings"
                busy: root.daemon && root.daemon.installing
                enabled: !root.working
                onClicked: root.daemon.installHelper()
            }
        }
    }

    // ---- Controls (grouped list) --------------------------------------------------------

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.groupedListGap

        // The whole row toggles, like the shell's settings switches.
        GroupCard {
            first: true
            Layout.preferredHeight: toggleRow.implicitHeight + pad * 2
            clickable: true
            enabled: root.ready && !root.daemon.installing && !root.daemon.uninstalling
            Accessible.role: Accessible.CheckBox
            Accessible.name: I18n.trFor("frameworkChargeLimit", "Limit charging")
            Accessible.checkable: true
            Accessible.checked: toggle.checked
            onClicked: {
                if (!root.writePending)
                    root.daemon.setEnabled(!toggle.checked, true);
            }

            RowLayout {
                id: toggleRow
                width: parent.width
                spacing: Theme.spacingM

                RowText {
                    Layout.fillWidth: true
                    title: I18n.trFor("frameworkChargeLimit", "Limit charging")
                    subtitle: I18n.trFor("frameworkChargeLimit", "When disabled, charging is allowed up to 100%.")
                }

                DToggle {
                    id: toggle
                    Layout.alignment: Qt.AlignVCenter
                    checked: root.ready && root.daemon.displayOn
                    toggling: root.writePending
                    activeFocusOnTab: false
                    Accessible.ignored: true
                    onToggled: checked => root.daemon.setEnabled(checked, true)
                }
            }
        }

        GroupCard {
            last: true
            Layout.preferredHeight: limitColumn.implicitHeight + pad * 2

            ColumnLayout {
                id: limitColumn
                width: parent.width
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingM

                    RowText {
                        Layout.fillWidth: true
                        title: I18n.trFor("frameworkChargeLimit", "Maximum charge when enabled")
                        subtitle: root.ready && root.daemon.displayOn ? I18n.trFor("frameworkChargeLimit", "%1–%2%, applied right away.").arg(CL.MIN_LIMIT).arg(CL.MAX_PROTECTED_LIMIT) : I18n.trFor("frameworkChargeLimit", "%1–%2%, saved for the next time charging is limited.").arg(CL.MIN_LIMIT).arg(CL.MAX_PROTECTED_LIMIT)
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignVCenter
                        text: I18n.trFor("frameworkChargeLimit", "%1%").arg(slider.value)
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Theme.fontWeightMedium
                        color: slider.enabled ? Theme.primary : Theme.onSurface_38
                    }
                }

                // − and + step by 1%. The limit is written when a drag ends or a step
                // button is pressed, never while dragging.
                DSlider {
                    id: slider
                    Layout.fillWidth: true
                    minimum: CL.MIN_LIMIT
                    maximum: CL.MAX_PROTECTED_LIMIT
                    step: 1
                    unit: "%"
                    startIcon: "remove"
                    endIcon: "add"
                    iconsClickable: true
                    enabled: root.ready
                    Accessible.name: I18n.trFor("frameworkChargeLimit", "Maximum charge when enabled, in percent")
                    onSliderDragFinished: finalValue => root.daemon.setProtectedLimit(finalValue)
                }

                // The slider sets its own value while dragging, so follow the daemon only
                // in between.
                Binding {
                    target: slider
                    property: "value"
                    value: root.ready ? root.daemon.protectedLimit : CL.DEFAULT_LIMIT
                    when: !slider.isDragging
                    restoreMode: Binding.RestoreNone
                }
            }
        }
    }

    // A card of the grouped list: large outer corners at its ends, small ones inside.
    component GroupCard: DCard {
        property bool first: false
        property bool last: false

        Layout.fillWidth: true
        topLeftRadius: first ? Theme.groupedListOuterRadius : Theme.groupedListInnerRadius
        topRightRadius: topLeftRadius
        bottomLeftRadius: last ? Theme.groupedListOuterRadius : Theme.groupedListInnerRadius
        bottomRightRadius: bottomLeftRadius
    }

    // Title and supporting text of a list row, in the shell's settings row type scale.
    component RowText: ColumnLayout {
        property string title
        property string subtitle

        spacing: Theme.spacingXXS

        StyledText {
            Layout.fillWidth: true
            text: parent.title
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Theme.fontWeightMedium
            color: Theme.onSurface
            wrapMode: Text.Wrap
        }

        StyledText {
            Layout.fillWidth: true
            visible: text.length > 0
            text: parent.subtitle
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.onSurfaceVariant
            wrapMode: Text.Wrap
        }
    }
}

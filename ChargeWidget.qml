import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Services

// Bar pill, popout and Control Center tile. One instance per bar and screen, plus the
// Control Center's; all of them read and drive the same daemon, so nothing is polled or
// written twice. Click toggles the limit and right click opens the popout, or the other
// way round (settings).
PluginComponent {
    id: root

    property var popoutService: null

    readonly property var daemon: pluginService?.pluginDaemonInstances?.[pluginId] ?? null
    readonly property string status: daemon ? daemon.status : ""
    readonly property bool limited: daemon ? daemon.displayOn : false
    readonly property bool clickOpensPanel: pluginData.pillClick === "panel"
    readonly property bool showLimit: pluginData.showLimitInBar !== false
    readonly property ChargeTexts texts: ChargeTexts {}

    readonly property string pillIcon: texts.icon(daemon)
    readonly property color pillIconColor: {
        if (status === "error" || status === "unexpected" || (pluginService && !daemon))
            return Theme.warning;
        return limited ? Theme.primary : Theme.widgetIconColor;
    }
    readonly property string pillText: daemon && limited && showLimit && status !== "setup" ? daemon.displayLimit + "%" : ""

    // Opens this widget's popout, bypassing pillClickAction.
    function openPanel() {
        const action = pillClickAction;
        pillClickAction = null;
        triggerPopout();
        pillClickAction = action;
    }

    function toggleLimit() {
        if (daemon)
            daemon.toggle(true);
    }

    // Assigned rather than bound: openPanel() swaps pillClickAction for a moment.
    function _applyClickActions() {
        pillClickAction = clickOpensPanel ? null : () => root.toggleLimit();
        pillRightClickAction = clickOpensPanel ? () => root.toggleLimit() : () => root.openPanel();
    }

    onClickOpensPanelChanged: _applyClickActions()
    Component.onCompleted: _applyClickActions()

    // Read again when the popout opens, unless a read just happened.
    onInteractionActiveChanged: {
        if (interactionActive && daemon)
            daemon.refresh("popout", 30 * 1000);
    }

    popoutWidth: 420

    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: I18n.trFor("frameworkChargeProtection", "Charge limit")
            headerActions: Component {
                DActionButton {
                    iconName: "settings"
                    buttonSize: Theme.buttonHeightXS
                    tooltipText: I18n.trFor("frameworkChargeProtection", "Plugin settings")
                    Accessible.name: tooltipText
                    onClicked: {
                        if (popout.closePopout)
                            popout.closePopout();
                        PopoutService.openSettingsWithTab("plugin:" + root.pluginId);
                    }
                }
            }

            ChargeControls {
                width: parent.width
                daemon: root.daemon
            }
        }
    }

    // ---- Control Center -----------------------------------------------------------------

    // Never empty: DMS lists the tile only if a bare instance (without daemon) has an icon.
    ccWidgetIcon: pillIcon
    ccWidgetPrimaryText: I18n.trFor("frameworkChargeProtection", "Charge limit")
    ccWidgetSecondaryText: texts.tileSubtitle(daemon)
    ccWidgetIsActive: limited

    onCcWidgetToggled: toggleLimit()
    onCcWidgetExpanded: {
        if (daemon)
            daemon.refresh("control-center", 30 * 1000);
    }

    ccDetailContent: Component {
        Rectangle {
            implicitHeight: detailControls.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.cardSurface

            ChargeControls {
                id: detailControls
                anchors.fill: parent
                anchors.margins: Theme.spacingM
                daemon: root.daemon
            }
        }
    }

    // ---- Bar pill ---------------------------------------------------------------------

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            opacity: root.daemon && root.daemon.busy ? 0.6 : 1

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.shortDuration
                }
            }

            DIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.pillIcon
                size: root.iconSize
                color: root.pillIconColor
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: text.length > 0
                text: root.pillText
                font.pixelSize: root.textSize
                color: Theme.widgetTextColor
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS
            opacity: root.daemon && root.daemon.busy ? 0.6 : 1

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.shortDuration
                }
            }

            DIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.pillIcon
                size: root.iconSize
                color: root.pillIconColor
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: text.length > 0
                text: root.pillText.replace("%", "")
                font.pixelSize: root.textSize
                color: Theme.widgetTextColor
            }
        }
    }
}

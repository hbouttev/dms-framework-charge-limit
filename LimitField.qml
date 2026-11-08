import QtQuick
import qs.Common
import qs.DCommon.Widgets
import "logic/ChargeLimit.js" as CL

// Whole percentage from 25 to 99 with −/+ buttons that step by one. Typed text is
// committed on Enter or when the field loses focus, and only when valid; anything else
// shakes the field and goes back to the current value.
Row {
    id: root

    property int value: CL.DEFAULT_LIMIT
    readonly property bool editing: field.inputFocused

    signal committed(int value)

    spacing: Theme.spacingXS

    function _commitText() {
        const n = CL.parseLimitInput(field.text);
        if (n === null) {
            field.shake();
            field.text = String(value);
            return;
        }
        field.text = String(n);
        if (n !== value)
            committed(n);
    }

    function _step(delta) {
        const n = value + delta;
        if (!CL.isProtectedLimit(n))
            return;
        field.text = String(n);
        committed(n);
    }

    onValueChanged: {
        if (!field.inputFocused)
            field.text = String(value);
    }
    Component.onCompleted: field.text = String(value)

    StyledTextMetrics {
        id: digits
        font.pixelSize: field.font.pixelSize
        text: "00"
    }

    DActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconName: "remove"
        enabled: root.enabled && root.value > CL.MIN_LIMIT
        tooltipText: I18n.trFor("frameworkChargeProtection", "Decrease by 1%")
        Accessible.name: tooltipText
        onClicked: root._step(-1)
    }

    DTextField {
        id: field
        anchors.verticalCenter: parent.verticalCenter
        width: digits.advanceWidth + leftPadding + rightPadding + Theme.spacingS
        enabled: root.enabled
        maximumLength: 2
        validator: RegularExpressionValidator {
            regularExpression: /\d{0,2}/
        }
        isError: inputFocused && CL.parseLimitInput(text) === null
        Accessible.name: I18n.trFor("frameworkChargeProtection", "Maximum charge when enabled, in percent")
        onEditingFinished: root._commitText()
    }

    StyledText {
        anchors.verticalCenter: parent.verticalCenter
        text: "%"
        font.pixelSize: Theme.fontSizeMedium
        color: root.enabled ? Theme.surfaceText : Theme.surfaceVariantText
    }

    DActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconName: "add"
        enabled: root.enabled && root.value < CL.MAX_PROTECTED_LIMIT
        tooltipText: I18n.trFor("frameworkChargeProtection", "Increase by 1%")
        Accessible.name: tooltipText
        onClicked: root._step(1)
    }
}

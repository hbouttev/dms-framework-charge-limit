import QtQuick
import Quickshell.Io
import qs.Common

// Allows the plugin on Framework laptops only. A missing framework_tool does not block
// it: the plugin then explains what to install.
QtObject {
    readonly property FileView vendorFile: FileView {
        path: "/sys/class/dmi/id/sys_vendor"
        blockLoading: true
        printErrors: false
    }

    function check() {
        const vendor = vendorFile.text().trim();
        if (vendor === "Framework")
            return null;
        return {
            title: I18n.trFor("frameworkChargeLimit", "Framework Charge Limit needs a Framework laptop"),
            details: I18n.trFor("frameworkChargeLimit", "It changes the battery charge limit through the Framework embedded controller, with Framework's framework_tool. This computer reports \"%1\" as its manufacturer.").arg(vendor || "?")
        };
    }
}

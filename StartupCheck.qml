import QtQuick
import qs.Common

// Allows the plugin on Framework laptops only. A missing framework_tool does not block
// it: the plugin then explains what to install.
QtObject {
    function check(done) {
        Proc.runCommand("frameworkChargeLimit.startupCheck", ["cat", "/sys/class/dmi/id/sys_vendor"], (stdout, exitCode) => {
            if (exitCode === 0 && stdout.trim() === "Framework") {
                done(null);
                return;
            }
            done({
                title: I18n.trFor("frameworkChargeLimit", "Framework Charge Limit needs a Framework laptop"),
                details: I18n.trFor("frameworkChargeLimit", "It changes the battery charge limit through the Framework embedded controller, with Framework's framework_tool. This computer reports \"%1\" as its manufacturer.").arg(stdout.trim() || "?")
            });
        });
    }
}

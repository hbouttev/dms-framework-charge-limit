import QtQuick
import qs.Common
import "logic/ChargeLimit.js" as CL

// User-facing wording for the codes the daemon and logic/ChargeLimit.js produce, in one
// place so every string goes through I18n.trFor with the literal plugin id.
QtObject {
    function errorText(code, detail) {
        let text;
        switch (code) {
        case "":
            return "";
        case "not-authorized":
            text = I18n.trFor("frameworkChargeLimit", "polkit did not allow the helper without a password. Charge operations work from the active local session only.");
            break;
        case "policy-missing":
            text = I18n.trFor("frameworkChargeLimit", "The helper's polkit policy is missing. Reinstall the helper in the plugin settings.");
            break;
        case "no-tool":
            return noToolText();
        case "ec":
            text = I18n.trFor("frameworkChargeLimit", "framework_tool could not communicate with the embedded controller.");
            break;
        case "mismatch":
            text = I18n.trFor("frameworkChargeLimit", "The embedded controller kept a different limit.");
            break;
        case "busy":
            text = I18n.trFor("frameworkChargeLimit", "Another charge limit operation was still running.");
            break;
        case "timeout":
            text = I18n.trFor("frameworkChargeLimit", "The helper did not answer in time.");
            break;
        case "invalid":
            text = I18n.trFor("frameworkChargeLimit", "The helper rejected the charge limit.");
            break;
        case "not-root":
            text = I18n.trFor("frameworkChargeLimit", "The helper did not run as root.");
            break;
        case "cancelled":
            return I18n.trFor("frameworkChargeLimit", "Authentication was cancelled or refused. Nothing was changed.");
        case "auth-failed":
            return I18n.trFor("frameworkChargeLimit", "Authentication failed. Nothing was changed.");
        default:
            text = I18n.trFor("frameworkChargeLimit", "The helper failed.");
            break;
        }
        return detail ? text + "\n" + detail : text;
    }

    function noToolText() {
        return I18n.trFor("frameworkChargeLimit", "framework_tool was not found in /usr/bin or /usr/local/bin, or is not owned by root. Install Framework's framework-system package.");
    }

    // Helper installation state, for the settings page and the setup notice.
    function helperStateText(state, installedVersion) {
        switch (state) {
        case "probing":
            return I18n.trFor("frameworkChargeLimit", "Checking…");
        case "no-polkit":
            return I18n.trFor("frameworkChargeLimit", "polkit (pkexec) is required but not installed.");
        case "missing":
            return I18n.trFor("frameworkChargeLimit", "Not installed. Installing it asks for your administrator password once.");
        case "broken":
            return I18n.trFor("frameworkChargeLimit", "Partly installed or too old. Reinstall it.");
        case "outdated":
            return I18n.trFor("frameworkChargeLimit", "Version %1 installed; version %2 is available.").arg(installedVersion).arg(CL.HELPER_VERSION);
        case "installed":
            return I18n.trFor("frameworkChargeLimit", "Version %1 installed.").arg(installedVersion);
        default:
            return "";
        }
    }

    function statusTitle(d) {
        if (!d)
            return I18n.trFor("frameworkChargeLimit", "Charge limit");
        switch (d.status) {
        case "installing":
            return I18n.trFor("frameworkChargeLimit", "Installing the helper…");
        case "applying":
            return d.applyingTarget === CL.FULL_CHARGE ? I18n.trFor("frameworkChargeLimit", "Allowing full charge…") : I18n.trFor("frameworkChargeLimit", "Limiting charge to %1%…").arg(d.applyingTarget);
        case "probing":
        case "reading":
            return I18n.trFor("frameworkChargeLimit", "Reading the charge limit…");
        case "setup":
            return I18n.trFor("frameworkChargeLimit", "Setup required");
        case "unexpected":
            return I18n.trFor("frameworkChargeLimit", "Unexpected charge limit");
        case "error":
            return I18n.trFor("frameworkChargeLimit", "Charge limit unknown");
        case "on":
            return I18n.trFor("frameworkChargeLimit", "Charging stops at %1%").arg(d.hwLimit);
        case "off":
            return I18n.trFor("frameworkChargeLimit", "Charging up to 100%");
        default:
            return "";
        }
    }

    function statusDetail(d) {
        if (!d)
            return I18n.trFor("frameworkChargeLimit", "The plugin's background service is not running. Re-enable the plugin in Settings → Plugins.");
        switch (d.status) {
        case "setup":
            if (d.helperState === "missing" && !d.toolFound)
                return noToolText();
            return d.helperState === "missing" ? I18n.trFor("frameworkChargeLimit", "Turning on Limit charging installs a small helper first. It asks for your administrator password once.") : helperStateText(d.helperState, d.installedHelperVersion);
        case "unexpected":
            return I18n.trFor("frameworkChargeLimit", "The embedded controller reports %1.").arg(d.hwLimit);
        case "error":
            return errorText(d.errorCode, d.errorDetail);
        case "on":
        case "off":
            break;
        default:
            return "";
        }
        const parts = [];
        if (d.hwReadAt > 0)
            parts.push(I18n.trFor("frameworkChargeLimit", "Checked %1").arg(elapsed(d.hwReadAt, d.now)));
        const ext = d.externalChange;
        if (ext && d.now - ext.at < 24 * 3600 * 1000) {
            parts.push(ext.corrected ? I18n.trFor("frameworkChargeLimit", "changed to %1% by another program at %2, restored").arg(ext.to).arg(clock(ext.at)) : I18n.trFor("frameworkChargeLimit", "changed to %1% by another program at %2").arg(ext.to).arg(clock(ext.at)));
        }
        if (d.status === "on" && !CL.isProtectedLimit(d.hwLimit))
            parts.push(I18n.trFor("frameworkChargeLimit", "below this plugin's %1–%2% range").arg(CL.MIN_LIMIT).arg(CL.MAX_PROTECTED_LIMIT));
        if (d.errorCode !== "")
            parts.push(I18n.trFor("frameworkChargeLimit", "last operation failed"));
        return parts.join(" · ");
    }

    // Short state for the Control Center tile.
    function tileSubtitle(d) {
        if (!d)
            return "";
        switch (d.status) {
        case "installing":
        case "applying":
        case "probing":
        case "reading":
            return I18n.trFor("frameworkChargeLimit", "Working…");
        case "setup":
            return I18n.trFor("frameworkChargeLimit", "Setup required");
        case "on":
            return I18n.trFor("frameworkChargeLimit", "Stops at %1%").arg(d.hwLimit);
        case "off":
            return I18n.trFor("frameworkChargeLimit", "Off · up to 100%");
        default:
            return I18n.trFor("frameworkChargeLimit", "Unknown");
        }
    }

    function icon(d) {
        if (!d)
            return "battery_android_frame_question";
        switch (d.status) {
        case "on":
            return "battery_android_frame_shield";
        case "off":
            return "battery_android_frame_full";
        case "applying":
        case "installing":
            return d.displayOn ? "battery_android_frame_shield" : "battery_android_frame_full";
        case "setup":
        case "probing":
        case "reading":
            return "battery_android_frame_question";
        default:
            return "battery_android_frame_alert";
        }
    }

    function elapsed(t, now) {
        const minutes = Math.floor((now - t) / 60000);
        if (minutes < 1)
            return I18n.trFor("frameworkChargeLimit", "just now");
        if (minutes < 60)
            return I18n.trFor("frameworkChargeLimit", "%1 min ago").arg(minutes);
        return I18n.trFor("frameworkChargeLimit", "%1 h ago").arg(Math.floor(minutes / 60));
    }

    function clock(t) {
        return new Date(t).toLocaleTimeString(Qt.locale(), Locale.ShortFormat);
    }
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Services
import "logic/ChargeLimit.js" as CL

// Single owner of the charge limit state. DMS creates it once per shell, independently of
// the bar pills (one per bar and screen), the Control Center tile and the settings page,
// which bind to its properties through PluginService.pluginDaemonInstances and call its
// functions. All hardware access goes through one helper process at a time.
PluginComponent {
    id: root

    property var popoutService: null

    // ---- Settings (ChargeSettings.qml) ----------------------------------------------

    property int protectedLimit: CL.DEFAULT_LIMIT
    property bool restoreAfterBoot: true
    property bool keepEnforcing: false
    property int pollMinutes: CL.DEFAULT_POLL_MINUTES
    property bool fullChargeOnDisable: true

    // ---- Selection --------------------------------------------------------------------

    // Whether "Limit charging" is on, as last chosen here or adopted from the hardware;
    // null until known. Saved in the plugin state with the boot it was handled in.
    property var selectedEnabled: null
    property string bootId: ""
    property string _handledBootId: ""

    // ---- Helper -----------------------------------------------------------------------

    // Result of CL.probeCommand, null until the first probe ends.
    property var probe: null
    readonly property string helperState: CL.helperState(probe)
    readonly property bool helperUsable: CL.helperUsable(helperState)
    readonly property string toolPath: probe?.tool ?? ""
    readonly property bool toolFound: toolPath !== ""
    readonly property int installedHelperVersion: probe?.installedVersion ?? 0
    readonly property int bundledHelperVersion: CL.HELPER_VERSION

    readonly property string helperDir: decodeURIComponent(Qt.resolvedUrl("helper").toString().replace(/^file:\/\//, ""))
    readonly property string installScript: helperDir + "/install.sh"
    readonly property string bundledHelper: helperDir + "/charge-limit"

    // ---- Hardware ---------------------------------------------------------------------

    // EC maximum from the last successful read or verified write, as reported (0 means no
    // limit); null while unknown: never read, or the last read failed.
    property var hwLimit: null
    property real hwReadAt: 0
    readonly property string hwKind: CL.classifyLimit(hwLimit)
    readonly property bool hwKnown: hwKind === "full" || hwKind === "limited"
    // Last change made by another program: {to, at, corrected}.
    property var externalChange: null

    // ---- Errors -----------------------------------------------------------------------

    // CL.failureCode of the last failed operation, empty after a success.
    property string errorCode: ""
    property string errorDetail: ""
    property string errorOp: ""
    property int errorStreak: 0

    // ---- Operations -------------------------------------------------------------------

    // "", "read", "write", "install" or "uninstall".
    property string busyKind: ""
    readonly property bool busy: busyKind !== ""
    readonly property bool installing: busyKind === "install"
    readonly property bool uninstalling: busyKind === "uninstall"
    // Limit being written, null otherwise.
    property var applyingTarget: null
    property real now: Date.now()

    // Requested state not yet verified: {enabled, limit, origin, after, from, retried}.
    property var _desired: null
    property bool _writeQueued: false
    property string _readQueued: ""
    property var _opDone: null
    property real _lastReadAttempt: 0
    property real _installedAt: 0
    property var _lastAdoptedRaw: null
    property var _corrections: []
    property var _probeCallbacks: []
    property var _afterInstall: null
    property bool _bootIdRead: false
    property bool _started: false
    property bool _bootPending: false
    property int _bootAttempt: 0

    // What the toggle shows: the request while it is being written, then the hardware,
    // and the last selection while the hardware is unknown.
    readonly property bool displayOn: {
        if (_desired)
            return _desired.enabled;
        if (hwKnown)
            return hwKind === "limited";
        return selectedEnabled === true;
    }
    // The maximum in force (or being written) when limited, else the saved limit.
    readonly property int displayLimit: {
        if (applyingTarget !== null && applyingTarget < CL.FULL_CHARGE)
            return applyingTarget;
        return hwKind === "limited" ? hwLimit : protectedLimit;
    }

    // One word for the views: "installing", "applying", "probing", "setup", "unexpected",
    // "on", "off", "error" or "reading".
    readonly property string status: {
        if (installing)
            return "installing";
        if (applyingTarget !== null)
            return "applying";
        if (helperState === "probing")
            return "probing";
        if (!helperUsable)
            return "setup";
        if (hwKind === "unexpected")
            return "unexpected";
        if (hwKnown)
            return hwKind === "limited" ? "on" : "off";
        return errorCode !== "" ? "error" : "reading";
    }

    readonly property ChargeTexts texts: ChargeTexts {}

    // Built while the daemon is alive: Component.onDestruction cannot rely on children.
    readonly property var lifecycleTexts: ({
            title: I18n.trFor("frameworkChargeProtection", "Framework Charge Protection"),
            resetOk: I18n.trFor("frameworkChargeProtection", "The plugin was turned off, so charging is allowed up to 100% again."),
            resetFailed: I18n.trFor("frameworkChargeProtection", "The plugin was turned off, but the charge limit could not be set back to 100%."),
            question: I18n.trFor("frameworkChargeProtection", "The plugin was removed. Also remove its system helper? This asks for your administrator password."),
            removeLabel: I18n.trFor("frameworkChargeProtection", "Remove helper"),
            keepLabel: I18n.trFor("frameworkChargeProtection", "Keep"),
            removed: I18n.trFor("frameworkChargeProtection", "The system helper was removed.")
        })

    // ---- Public API -------------------------------------------------------------------

    // Turns "Limit charging" on or off. With allowInstall (a click), a missing helper is
    // installed first, which asks for an administrator password; nothing else ever
    // triggers authentication.
    function setEnabled(on, allowInstall) {
        if (_desired?.origin === "uninstall" || installing || uninstalling)
            return false;
        if (!helperUsable) {
            if (allowInstall)
                _installThen(() => _request(on, protectedLimit, "user"));
            return false;
        }
        _request(on, protectedLimit, "user");
        return true;
    }

    function toggle(allowInstall) {
        return setEnabled(!displayOn, allowInstall);
    }

    // Saves the protected limit (25–99) and applies it right away while charging is
    // limited. Returns false for an invalid value, which is never saved or applied.
    function setProtectedLimit(value) {
        const n = Number(value);
        if (!CL.isProtectedLimit(n))
            return false;
        if (n !== protectedLimit) {
            protectedLimit = n;
            _saveSetting("protectedLimit", n);
        }
        if (displayOn && helperUsable)
            limitDebounce.restart();
        return true;
    }

    // Reads the hardware, unless the last read started less than maxAgeMs ago.
    function refresh(reason, maxAgeMs) {
        if (!helperUsable)
            return false;
        if (maxAgeMs > 0 && Date.now() - _lastReadAttempt < maxAgeMs)
            return false;
        if (busy) {
            _readQueued = reason || "manual";
            return false;
        }
        _read(reason || "manual");
        return true;
    }

    // Checks which helper is installed; then() runs once the probe has ended.
    function probeHelper(then) {
        if (then)
            _probeCallbacks = _probeCallbacks.concat([then]);
        if (!probeProc.start(CL.probeCommand(bundledHelper)))
            return;
        probeWatchdog.restart();
    }

    function installHelper() {
        return _installThen(null);
    }

    // Removes the system helper; with "Allow full charge…" on and charging limited, sets
    // the maximum back to 100% first.
    function uninstallHelper() {
        if (busy || _desired)
            return false;
        const remove = () => _run("uninstall", CL.installCommand(installScript, "uninstall"), (code, out, err) => {
                if (code !== CL.EXIT.ok) {
                    _setError(CL.failureCode(code, "uninstall"), CL.errorDetail(err), "uninstall");
                    _toastFailure(I18n.trFor("frameworkChargeProtection", "The helper was not removed"));
                } else {
                    const stillLimited = hwKind === "limited";
                    _clearError();
                    _readQueued = "";
                    hwLimit = null;
                    ToastService.showInfo(I18n.trFor("frameworkChargeProtection", "Charge limit helper removed"), stillLimited ? I18n.trFor("frameworkChargeProtection", "The current charge limit stays in place until another tool or the firmware changes it.") : "");
                }
                probeHelper();
            });
        if (fullChargeOnDisable && helperUsable && hwKind === "limited")
            _request(false, protectedLimit, "uninstall", () => remove());
        else
            remove();
        return true;
    }

    function statusJson() {
        return JSON.stringify({
            status: status,
            limitCharging: displayOn,
            protectedLimit: protectedLimit,
            hardware: {
                maximum: hwKnown ? CL.effectiveMax(hwLimit) : null,
                raw: hwLimit,
                kind: hwKind,
                readAt: hwReadAt ? new Date(hwReadAt).toISOString() : null
            },
            selected: selectedEnabled,
            applying: applyingTarget,
            busy: busyKind || null,
            error: errorCode ? {
                code: errorCode,
                operation: errorOp,
                detail: errorDetail,
                text: texts.errorText(errorCode, errorDetail)
            } : null,
            externalChange: externalChange ? {
                to: externalChange.to,
                at: new Date(externalChange.at).toISOString(),
                corrected: externalChange.corrected
            } : null,
            helper: {
                state: helperState,
                installedVersion: installedHelperVersion || null,
                bundledVersion: bundledHelperVersion,
                path: CL.HELPER_PATH,
                frameworkTool: toolPath || null
            },
            settings: {
                restoreAfterBoot: restoreAfterBoot,
                keepEnforcing: keepEnforcing,
                pollMinutes: pollMinutes,
                fullChargeOnDisable: fullChargeOnDisable
            }
        }, null, 2);
    }

    // ---- Operations -------------------------------------------------------------------

    function _run(kind, argv, done) {
        busyKind = kind;
        _opDone = done;
        // Install and uninstall wait for the password dialog.
        opWatchdog.interval = kind === "install" || kind === "uninstall" ? 10 * 60 * 1000 : 60 * 1000;
        opWatchdog.restart();
        if (!opProc.start(argv))
            _onOpFinished(CL.EXIT.busy, "", "error=a helper process is still running");
    }

    function _onOpFinished(code, out, err) {
        opWatchdog.stop();
        const done = _opDone;
        _opDone = null;
        busyKind = "";
        now = Date.now();
        if (done) {
            try {
                done(code, out, err);
            } catch (e) {
                console.warn("frameworkChargeProtection:", e.message);
            }
        }
        _drain();
    }

    // Starts what was asked while another operation ran: writes first, then a read.
    function _drain() {
        if (busy)
            return;
        if (_desired && _writeQueued) {
            _write();
            return;
        }
        if (_readQueued !== "") {
            const reason = _readQueued;
            _readQueued = "";
            _read(reason);
        }
    }

    function _read(reason) {
        _lastReadAttempt = Date.now();
        _run("read", CL.helperCommand(["get"]), (code, out, err) => {
            const limit = CL.parseLimit(out);
            if (code === CL.EXIT.ok && limit !== null) {
                _observe(limit);
                _clearError();
                _afterRead();
                return;
            }
            hwLimit = null;
            _setError(CL.failureCode(code, "read"), CL.errorDetail(err), "read");
            if (code === CL.EXIT.policyMissing || code === CL.EXIT.notAuthorized)
                probeHelper();
            if (_bootPending)
                _bootReadFailed();
        });
    }

    function _observe(limit) {
        hwLimit = limit;
        hwReadAt = Date.now();
        _persistState();
    }

    function _afterRead() {
        if (_bootPending) {
            _bootPending = false;
            _markBootHandled();
            if (CL.bootRestoreTarget({
                raw: hwLimit,
                selectedEnabled: selectedEnabled,
                protectedLimit: protectedLimit
            }) !== null) {
                console.info("frameworkChargeProtection: new boot, restoring", CL.targetLimit(selectedEnabled, protectedLimit) + "%", "(EC reports " + hwLimit + ")");
                _request(selectedEnabled, protectedLimit, "boot", null, hwLimit);
                return;
            }
        }
        // A request is pending: its write settles the state.
        if (_desired)
            return;
        const r = CL.reconcile({
            raw: hwLimit,
            selectedEnabled: selectedEnabled,
            protectedLimit: protectedLimit,
            keepEnforcing: keepEnforcing
        });
        if (r.action === "adopt")
            _adopt(r);
        else if (r.action === "enforce")
            _enforce();
    }

    // Follows the hardware after a change made elsewhere (or on the very first read).
    function _adopt(r) {
        const known = selectedEnabled === true || selectedEnabled === false;
        if (known && hwLimit !== _lastAdoptedRaw) {
            console.info("frameworkChargeProtection: charge limit changed outside the plugin to", hwLimit);
            externalChange = {
                to: CL.effectiveMax(hwLimit),
                at: Date.now(),
                corrected: false
            };
        }
        _lastAdoptedRaw = hwLimit;
        selectedEnabled = r.enabled;
        if (r.limit !== protectedLimit) {
            protectedLimit = r.limit;
            _saveSetting("protectedLimit", r.limit);
        }
        _persistState();
    }

    function _enforce() {
        const t = Date.now();
        _corrections = CL.recentCorrections(_corrections, t).concat([t]);
        console.info("frameworkChargeProtection: charge limit changed outside the plugin to", hwLimit + ", restoring it");
        _request(selectedEnabled, protectedLimit, "enforce", null, hwLimit);
    }

    // origin: "user", "boot", "enforce" or "uninstall"; after(ok) runs once written or
    // failed; from: the EC value being replaced, for messages.
    function _request(enabled, limit, origin, after, from) {
        _desired = {
            enabled: enabled,
            limit: limit,
            origin: origin,
            after: after ?? null,
            from: from ?? null,
            retried: false
        };
        _writeQueued = true;
        if (!busy)
            _write();
    }

    function _write() {
        const d = _desired;
        if (!d)
            return;
        _writeQueued = false;
        const target = CL.targetLimit(d.enabled, d.limit);
        applyingTarget = target;
        _run("write", CL.helperCommand(["set", String(target)]), (code, out, err) => {
            applyingTarget = null;
            const readBack = CL.parseLimit(out);
            if (readBack !== null)
                _observe(readBack);
            const ok = code === CL.EXIT.ok && readBack === target;
            if (ok) {
                _clearError();
                selectedEnabled = d.enabled;
                _lastAdoptedRaw = null;
                // Your own choice replaces whatever another program had set.
                if (d.origin === "user")
                    externalChange = null;
                _persistState();
                // Unless the user asked for something else in the meantime.
                if (_desired === d)
                    _desired = null;
                _announce(d, target);
            } else if (code === CL.EXIT.notAuthorized && !d.retried && Date.now() - _installedAt < 20 * 1000) {
                // polkit may not have loaded a just-installed policy yet.
                d.retried = true;
                writeRetryTimer.restart();
                return;
            } else {
                if (_desired === d)
                    _desired = null;
                _writeQueued = _desired !== null;
                _setError(CL.failureCode(code, "write"), CL.errorDetail(err), "write");
                // Learn what the hardware really holds, unless that cannot work either.
                if (code === CL.EXIT.policyMissing || code === CL.EXIT.notAuthorized)
                    probeHelper();
                else if (readBack === null && code !== CL.EXIT.noTool)
                    _readQueued = "after-failure";
                if (d.origin !== "enforce" || errorStreak === 1)
                    _toastFailure(target === CL.FULL_CHARGE ? I18n.trFor("frameworkChargeProtection", "Could not allow full charge") : I18n.trFor("frameworkChargeProtection", "Could not limit charging to %1%").arg(target));
            }
            if (d.after)
                d.after(ok);
        });
    }

    function _announce(d, target) {
        if (d.origin === "boot") {
            ToastService.showInfo(target === CL.FULL_CHARGE ? I18n.trFor("frameworkChargeProtection", "Charging allowed up to 100% again after boot") : I18n.trFor("frameworkChargeProtection", "Charge limit restored to %1% after boot").arg(target), d.from !== null ? I18n.trFor("frameworkChargeProtection", "The firmware had set it to %1%.").arg(CL.effectiveMax(d.from) ?? d.from) : "");
        } else if (d.origin === "enforce") {
            externalChange = {
                to: CL.effectiveMax(d.from) ?? d.from,
                at: Date.now(),
                corrected: true
            };
            const recent = CL.recentCorrections(_corrections, Date.now()).length;
            let detail = I18n.trFor("frameworkChargeProtection", "Another program had changed it to %1%.").arg(CL.effectiveMax(d.from) ?? d.from);
            if (recent >= CL.CONFLICT_CORRECTIONS)
                detail += " " + I18n.trFor("frameworkChargeProtection", "It was changed %1 times in the last hour: another tool, such as the battery limit of Framework Control, may be enforcing its own limit.").arg(recent);
            ToastService.showWarning(target === CL.FULL_CHARGE ? I18n.trFor("frameworkChargeProtection", "Full charge restored") : I18n.trFor("frameworkChargeProtection", "Charge limit restored to %1%").arg(target), detail);
        }
    }

    function _installThen(then) {
        if (busy)
            return false;
        if (probe && !probe.polkit) {
            ToastService.showError(I18n.trFor("frameworkChargeProtection", "Cannot install the charge limit helper"), texts.helperStateText("no-polkit", 0));
            return false;
        }
        if (probe && !toolFound) {
            ToastService.showError(I18n.trFor("frameworkChargeProtection", "Cannot install the charge limit helper"), texts.noToolText());
            return false;
        }
        console.info("frameworkChargeProtection: installing the helper");
        _run("install", CL.installCommand(installScript, "install"), (code, out, err) => {
            if (code !== CL.EXIT.ok) {
                _setError(CL.failureCode(code, "install"), CL.errorDetail(err), "install");
                _toastFailure(I18n.trFor("frameworkChargeProtection", "The helper was not installed"));
                probeHelper();
                return;
            }
            _clearError();
            _installedAt = Date.now();
            ToastService.showInfo(I18n.trFor("frameworkChargeProtection", "Charge limit helper installed"));
            _afterInstall = then;
            // polkit loads the new policy asynchronously.
            postInstallTimer.restart();
        });
        return true;
    }

    function _toastFailure(title) {
        ToastService.showError(title, texts.errorText(errorCode, errorDetail));
    }

    function _setError(code, detail, op) {
        errorCode = code;
        errorDetail = detail;
        errorOp = op;
        errorStreak++;
        console.warn("frameworkChargeProtection:", op, "failed:", code, detail);
    }

    function _clearError() {
        errorCode = "";
        errorDetail = "";
        errorOp = "";
        errorStreak = 0;
    }

    // ---- Startup and boot -------------------------------------------------------------

    // Runs once both the boot id and the helper probe are known.
    function _start() {
        if (_started || !_bootIdRead || !probe)
            return;
        _started = true;
        const newBoot = CL.isNewBoot(_handledBootId, bootId);
        if (!helperUsable) {
            // Nothing to restore without the helper; setup only ever starts from a click.
            if (newBoot)
                _markBootHandled();
            return;
        }
        if (newBoot && restoreAfterBoot && (selectedEnabled === true || selectedEnabled === false)) {
            _bootPending = true;
            _bootAttempt = 0;
        } else if (newBoot) {
            _markBootHandled();
        }
        refresh(newBoot ? "boot" : "startup");
    }

    function _bootReadFailed() {
        if (_bootAttempt < CL.BOOT_RETRY_DELAYS_MS.length) {
            bootRetryTimer.interval = CL.BOOT_RETRY_DELAYS_MS[_bootAttempt++];
            bootRetryTimer.restart();
            return;
        }
        _bootPending = false;
        _markBootHandled();
        _toastFailure(I18n.trFor("frameworkChargeProtection", "Could not restore the charge limit after boot"));
    }

    function _markBootHandled() {
        if (bootId === "")
            return;
        _handledBootId = bootId;
        _persistState();
    }

    function _tick() {
        const t = Date.now();
        const gap = t - now;
        now = t;
        if (!_started || !helperUsable || _bootPending)
            return;
        // A long gap between ticks: the system was suspended.
        if (gap > 3 * 60 * 1000) {
            refresh("resume");
            return;
        }
        if (!busy && t - _lastReadAttempt >= CL.nextReadDelayMs(errorStreak, pollMinutes * 60 * 1000))
            refresh("poll");
    }

    // ---- Persistence ------------------------------------------------------------------

    function _setting(key, fallback) {
        return pluginService ? pluginService.loadPluginData(pluginId, key, fallback) : fallback;
    }

    function _saveSetting(key, value) {
        if (pluginService)
            pluginService.savePluginData(pluginId, key, value);
    }

    function _loadSettings() {
        protectedLimit = CL.normalizeProtectedLimit(_setting("protectedLimit", CL.DEFAULT_LIMIT));
        restoreAfterBoot = _setting("restoreAfterBoot", true) !== false;
        keepEnforcing = _setting("keepEnforcing", false) === true;
        pollMinutes = CL.normalizePollMinutes(_setting("pollMinutes", String(CL.DEFAULT_POLL_MINUTES)));
        fullChargeOnDisable = _setting("fullChargeOnDisable", true) !== false;
    }

    function _persistState() {
        if (!pluginService)
            return;
        pluginService.savePluginState(pluginId, "state", {
            version: 1,
            enabled: selectedEnabled,
            bootId: _handledBootId
        });
    }

    function _restoreState() {
        if (!pluginService)
            return;
        const s = pluginService.loadPluginState(pluginId, "state", null);
        if (!s || s.version !== 1)
            return;
        selectedEnabled = typeof s.enabled === "boolean" ? s.enabled : null;
        _handledBootId = String(s.bootId || "");
    }

    onKeepEnforcingChanged: {
        if (keepEnforcing && _started)
            refresh("enforcing-enabled");
    }

    Component.onCompleted: {
        _loadSettings();
        _restoreState();
        bootIdProc.running = true;
        probeHelper(() => _start());
    }

    // Disabling or uninstalling the plugin destroys the daemon, but so do shell exits and
    // reloads: a detached script asks DMS a moment later which one it was.
    Component.onDestruction: {
        Quickshell.execDetached(CL.lifecycleCommand(fullChargeOnDisable && helperUsable && hwKind === "limited", pluginId, lifecycleTexts));
    }

    Connections {
        target: root.pluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root._loadSettings();
        }
    }

    Connections {
        target: SessionService
        function onSessionResumed() {
            resumeTimer.restart();
        }
    }

    // ---- Timers and processes ---------------------------------------------------------

    // Wall-clock tick rather than one long Timer: it stays correct across suspend.
    Timer {
        interval: 30 * 1000
        repeat: true
        running: true
        onTriggered: root._tick()
    }

    Timer {
        id: limitDebounce
        interval: 700
        onTriggered: {
            if (root.displayOn)
                root._request(true, root.protectedLimit, "user");
        }
    }

    Timer {
        id: resumeTimer
        interval: 5000
        onTriggered: root.refresh("resume")
    }

    Timer {
        id: bootRetryTimer
        onTriggered: root.refresh("boot")
    }

    Timer {
        id: writeRetryTimer
        interval: 2000
        onTriggered: {
            root._writeQueued = true;
            root._drain();
        }
    }

    Timer {
        id: postInstallTimer
        interval: 1500
        onTriggered: {
            const then = root._afterInstall;
            root._afterInstall = null;
            root.probeHelper(() => {
                if (!root.helperUsable)
                    return;
                if (!root._started) {
                    root._start();
                    return;
                }
                if (then)
                    then();
                else
                    root.refresh("install");
            });
        }
    }

    Timer {
        id: opWatchdog
        onTriggered: opProc.abandon(CL.EXIT.timeout)
    }

    Timer {
        id: probeWatchdog
        interval: 15 * 1000
        onTriggered: probeProc.abandon(CL.EXIT.timeout)
    }

    HelperProcess {
        id: opProc
        onFinished: (exitCode, out, err) => root._onOpFinished(exitCode, out, err)
    }

    HelperProcess {
        id: probeProc
        onFinished: (exitCode, out, err) => {
            probeWatchdog.stop();
            root.probe = CL.parseProbe(out);
            console.info("frameworkChargeProtection: helper", root.helperState, "(installed version", root.installedHelperVersion + ", bundled", root.bundledHelperVersion + "), framework_tool:", root.toolPath || "not found");
            const callbacks = root._probeCallbacks;
            root._probeCallbacks = [];
            for (const cb of callbacks)
                cb();
        }
    }

    Process {
        id: bootIdProc
        command: ["cat", "/proc/sys/kernel/random/boot_id"]
        stdout: StdioCollector {
            onStreamFinished: root.bootId = text.trim()
        }
        onExited: {
            root._bootIdRead = true;
            root._start();
        }
    }

    // dms ipc call frameworkChargeProtection <function> [argument]
    IpcHandler {
        target: "frameworkChargeProtection"

        function status(): string {
            return root.statusJson();
        }

        function enable(): string {
            return root._ipcResult(root.setEnabled(true, false));
        }

        function disable(): string {
            return root._ipcResult(root.setEnabled(false, false));
        }

        function toggle(): string {
            return root._ipcResult(root.toggle(false));
        }

        function limit(percent: string): string {
            const n = CL.parseLimitInput(percent);
            if (n === null)
                return "invalid limit: use a whole number from " + CL.MIN_LIMIT + " to " + CL.MAX_PROTECTED_LIMIT;
            root.setProtectedLimit(n);
            return root.displayOn ? "applying " + n + "%" : "saved " + n + "% for the next time charging is limited";
        }

        function refresh(): string {
            return root.refresh("ipc") ? "reading" : (root.helperUsable ? "queued" : "the helper is not installed");
        }
    }

    function _ipcResult(started) {
        if (started)
            return "applying";
        if (!helperUsable)
            return "the helper is not installed: click the bar pill or use Settings → Plugins → Framework Charge Protection";
        return "busy";
    }
}

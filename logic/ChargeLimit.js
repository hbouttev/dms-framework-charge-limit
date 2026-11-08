.pragma library

// Pure helpers shared by the daemon and the views. No QML or Quickshell APIs here, so
// tests/run.mjs can load this file under Node.
//
// No user-facing wording either: functions return codes and values, and ChargeTexts.qml
// turns them into translatable text (I18n.trFor only works, and is only extracted, in QML).
//
// Types are written as JSDoc for editors and `tsc --checkJs`; QML ignores them.

// ---- Types --------------------------------------------------------------------------

/**
 * Installation state of the system helper, from {@link helperState}.
 * @typedef {"probing" | "no-polkit" | "missing" | "broken" | "outdated" | "installed"} HelperState
 */

/**
 * What a helper or install.sh run was doing, for {@link failureCode}.
 * @typedef {"read" | "write" | "install" | "uninstall"} Operation
 */

/**
 * Why an operation failed, from {@link failureCode}; ChargeTexts.qml turns it into text.
 * @typedef {"invalid" | "not-root" | "no-tool" | "ec" | "mismatch" | "busy" | "policy-missing"
 *     | "not-authorized" | "timeout" | "cancelled" | "auth-failed" | "failed"} FailureCode
 */

/**
 * Meaning of a raw EC maximum, from {@link classifyLimit}.
 * @typedef {"unknown" | "full" | "limited" | "unexpected"} LimitKind
 */

/**
 * What the probe found on the system, from {@link parseProbe}.
 * @typedef {object} Probe
 * @property {number} installedVersion version of the installed helper, 0 when absent
 * @property {boolean} policy the polkit action file is installed
 * @property {boolean} polkit polkit's actions directory exists
 * @property {boolean} pkexec pkexec is in PATH
 * @property {string} tool path of the trusted framework_tool, empty when none exists
 * @property {number} bundledVersion version of the helper shipped with the plugin
 */

/**
 * Translated texts the lifecycle script shows in notifications.
 * @typedef {object} LifecycleTexts
 * @property {string} title notification title and app name
 * @property {string} resetOk after the maximum was set back to 100%
 * @property {string} resetFailed when that failed
 * @property {string} question offer to remove the helper after an uninstall
 * @property {string} removeLabel action button that removes it
 * @property {string} keepLabel action button that keeps it
 * @property {string} removed after the helper was removed
 */

/**
 * The plugin's view of the charge limit, passed to {@link reconcile} and
 * {@link bootRestoreTarget}.
 * @typedef {object} LimitState
 * @property {number | null} raw maximum read from the EC, null when not read
 * @property {boolean | null} selectedEnabled the user's "Limit charging" choice, null when
 *     never known
 * @property {number} protectedLimit the user's maximum when enabled, 25–99
 * @property {boolean} [keepEnforcing] write the choice back instead of following changes
 */

/**
 * Decision of {@link reconcile}.
 * @typedef {{ action: "none" }
 *     | { action: "adopt", enabled: boolean, limit: number }
 *     | { action: "enforce", target: number }} Reconciliation
 */

// ---- Constants ----------------------------------------------------------------------

// framework_tool accepts 25–100. 100 is what turning "Limit charging" off writes, so the
// protected limit stops at 99: enabled at 100 would mean the same as disabled.
const MIN_LIMIT = 25;
const MAX_PROTECTED_LIMIT = 99;
const FULL_CHARGE = 100;
const DEFAULT_LIMIT = 80;
// The EC refuses a maximum below 20; other tools may still set 20–24.
const EC_MIN_LIMIT = 20;

// Version of helper/charge-limit shipped with this plugin, and the oldest installed
// version it can still use (same command line and output).
const HELPER_VERSION = 1;
const MIN_HELPER_VERSION = 1;

const SYSTEM_NAME = "dms-framework-charge-limit";
const HELPER_DIR = `/usr/local/libexec/${SYSTEM_NAME}`;
const HELPER_PATH = `${HELPER_DIR}/charge-limit`;
const UNINSTALLER_PATH = `${HELPER_DIR}/uninstall`;
const POLKIT_ACTION = `io.github.hbouttev.${SYSTEM_NAME}.charge-limit`;
const POLICY_PATH = `/usr/share/polkit-1/actions/io.github.hbouttev.${SYSTEM_NAME}.policy`;

// Exit codes of helper/charge-limit, of the guard below, of timeout(1) and of pkexec.
const EXIT = {
    ok: 0,
    usage: 2,
    notRoot: 3,
    noTool: 4,
    ec: 5,
    mismatch: 6,
    busy: 7,
    policyMissing: 120,
    notAuthorized: 121,
    timeout: 124,
    pkexecDismissed: 126,
    pkexecFailed: 127
};

/** Choices of the "Check every" setting, in minutes. */
const POLL_MINUTES = [1, 2, 5, 15, 30, 60];
const DEFAULT_POLL_MINUTES = 5;

// ---- Commands -----------------------------------------------------------------------

// Runs the installed helper through pkexec, but only while polkit grants it without a
// password. A background check must never open an authentication dialog: if the policy
// was removed, or the session is not active, pkexec is not started at all.
// pkexec rejects a $SHELL missing from /etc/shells, hence the unset.
const GUARD_SCRIPT = 'unset SHELL; [ -f "$1" ] || exit 120; pkcheck --action-id "$2" --process $$ >/dev/null 2>&1 || exit 121; shift 2; exec pkexec "$@"';

/**
 * Command line running the installed helper as root, never asking for a password.
 * @param {string[]} args helper arguments: `["get"]` or `["set", "80"]`
 * @returns {string[]}
 */
function helperCommand(args) {
    return ["sh", "-c", GUARD_SCRIPT, "sh", POLICY_PATH, POLKIT_ACTION, HELPER_PATH, ...args];
}

/**
 * Command line installing or removing the helper; pkexec asks for an administrator password.
 * @param {string} installScript path of the plugin's helper/install.sh
 * @param {"install" | "uninstall"} mode
 * @returns {string[]}
 */
function installCommand(installScript, mode) {
    return ["env", "-u", "SHELL", "pkexec", "/bin/bash", installScript, mode];
}

// Reports the installed helper (installed.version=, installed.tool=), the policy and the
// framework_tool the bundled helper would use (bundled.tool=). Needs no privileges.
const PROBE_SCRIPT = [
    'if [ -x "$1" ]; then "$1" info 2>/dev/null | sed "s/^/installed./"; fi',
    '[ -f "$2" ] && echo policy=present',
    '[ -d "${2%/*}" ] && echo polkit=present',
    'command -v pkexec >/dev/null 2>&1 && echo pkexec=present',
    'bash "$3" info 2>/dev/null | sed "s/^/bundled./"',
    'exit 0'
].join("; ");

/**
 * Command line of the probe; its output goes to {@link parseProbe}.
 * @param {string} bundledHelper path of the plugin's helper/charge-limit
 * @returns {string[]}
 */
function probeCommand(bundledHelper) {
    return ["sh", "-c", PROBE_SCRIPT, "sh", HELPER_PATH, POLICY_PATH, bundledHelper];
}

// Started detached when the daemon is destroyed. Waits for DMS to settle, then asks it
// what happened: the plugin still loaded (reload, update, shell restart) or no answer
// (shell exit) changes nothing. Disabled or uninstalled: sets the maximum back to 100 %
// when $1 is 1, and after an uninstall offers to remove the system helper.
const LIFECYCLE_SCRIPT = [
    'reset=$1 id=$2 title=$3 reset_ok=$4 reset_failed=$5 question=$6 remove_label=$7 keep_label=$8 removed=$9 guard=${10}',
    'sleep 3',
    'status=$(dms ipc call plugins status "$id" 2>/dev/null) || exit 0',
    'case $status in disabled) event=disabled ;; PLUGIN_NOT_FOUND*) event=uninstalled ;; *) exit 0 ;; esac',
    'if [ "$reset" = 1 ]; then',
    `  if sh -c "$guard" sh "${POLICY_PATH}" "${POLKIT_ACTION}" "${HELPER_PATH}" set 100 >/dev/null 2>&1; then`,
    '    dms notify -a "$title" "$title" "$reset_ok"',
    '  else',
    '    dms notify -a "$title" -u critical "$title" "$reset_failed"',
    '  fi',
    'fi',
    `[ "$event" = uninstalled ] && [ -x "${UNINSTALLER_PATH}" ] || exit 0`,
    'choice=$(dms notify -a "$title" -t 0 -A remove="$remove_label" -A keep="$keep_label" "$title" "$question")',
    `[ "$choice" = remove ] && env -u SHELL pkexec "${UNINSTALLER_PATH}" >/dev/null && dms notify -a "$title" "$title" "$removed"`,
    'exit 0'
].join("\n");

/**
 * Command line of the lifecycle script, started detached when the daemon is destroyed.
 * @param {boolean} reset set the maximum back to 100% if the plugin was disabled or
 *     uninstalled
 * @param {string} pluginId
 * @param {LifecycleTexts} texts
 * @returns {string[]}
 */
function lifecycleCommand(reset, pluginId, texts) {
    return ["sh", "-c", LIFECYCLE_SCRIPT, "sh", reset ? "1" : "0", pluginId, texts.title, texts.resetOk, texts.resetFailed, texts.question, texts.removeLabel, texts.keepLabel, texts.removed, GUARD_SCRIPT];
}

// ---- Parsing ------------------------------------------------------------------------

/**
 * The `key=value` lines of a helper or probe output. Other lines are ignored.
 * @param {string | null | undefined} text
 * @returns {Record<string, string>}
 */
function parseKeyValues(text) {
    /** @type {Record<string, string>} */
    const out = {};
    for (const line of String(text ?? "").split("\n")) {
        const m = /^([a-z][a-z0-9_.]*)=(.*)$/.exec(line.trim());
        if (m)
            out[m[1]] = m[2];
    }
    return out;
}

/**
 * A whole number of 1 to 3 digits, or null.
 * @param {string | null | undefined} value
 * @returns {number | null}
 */
function parseIntStrict(value) {
    return /^\d{1,3}$/.test(String(value ?? "")) ? Number(value) : null;
}

/**
 * The `limit=` line of the helper, or null.
 * @param {string | null | undefined} text helper stdout
 * @returns {number | null}
 */
function parseLimit(text) {
    return parseIntStrict(parseKeyValues(text).limit);
}

/**
 * @param {string | null | undefined} text output of {@link probeCommand}
 * @returns {Probe}
 */
function parseProbe(text) {
    const kv = parseKeyValues(text);
    return {
        installedVersion: parseIntStrict(kv["installed.version"]) ?? 0,
        policy: kv.policy === "present",
        polkit: kv.polkit === "present",
        pkexec: kv.pkexec === "present",
        // Empty when no trusted framework_tool exists.
        tool: kv["installed.tool"] || kv["bundled.tool"] || "",
        bundledVersion: parseIntStrict(kv["bundled.version"]) ?? 0
    };
}

/**
 * "probing" (no probe yet), "no-polkit", "missing", "broken" (partly installed, or too old
 * to use), "outdated" (usable, update available) or "installed".
 * @param {Probe | null} probe
 * @returns {HelperState}
 */
function helperState(probe) {
    if (!probe)
        return "probing";
    const v = probe.installedVersion;
    if (v === 0 && !probe.policy)
        return probe.polkit && probe.pkexec ? "missing" : "no-polkit";
    if (v === 0 || !probe.policy || v < MIN_HELPER_VERSION)
        return "broken";
    return v < HELPER_VERSION ? "outdated" : "installed";
}

/**
 * Whether the installed helper can read and write the limit.
 * @param {HelperState} state
 * @returns {boolean}
 */
function helperUsable(state) {
    return state === "installed" || state === "outdated";
}

/**
 * The `error=` line of the helper, or the last line of the output; at most 300 characters.
 * @param {string | null | undefined} stderr
 * @returns {string}
 */
function errorDetail(stderr) {
    const text = String(stderr ?? "");
    const kv = parseKeyValues(text);
    if (kv.error)
        return kv.error.slice(0, 300);
    const lines = text.split("\n").map(l => l.trim()).filter(l => l.length > 0);
    return lines.length > 0 ? lines[lines.length - 1].slice(0, 300) : "";
}

/**
 * Failure code of a helper or install.sh run that did not exit with 0.
 * pkexec's 126/127 mean a dismissed or failed password prompt for install and uninstall,
 * which ask for one; for read and write, which must not, they mean polkit refused.
 * @param {number} exitCode
 * @param {Operation} op
 * @returns {FailureCode}
 */
function failureCode(exitCode, op) {
    switch (exitCode) {
    case EXIT.usage:
        return "invalid";
    case EXIT.notRoot:
        return "not-root";
    case EXIT.noTool:
        return "no-tool";
    case EXIT.ec:
        return "ec";
    case EXIT.mismatch:
        return "mismatch";
    case EXIT.busy:
        return "busy";
    case EXIT.policyMissing:
        return "policy-missing";
    case EXIT.notAuthorized:
        return "not-authorized";
    case EXIT.timeout:
        return "timeout";
    case EXIT.pkexecDismissed:
        return op === "install" || op === "uninstall" ? "cancelled" : "not-authorized";
    case EXIT.pkexecFailed:
        return op === "install" || op === "uninstall" ? "auth-failed" : "not-authorized";
    default:
        return "failed";
    }
}

// ---- Limits -------------------------------------------------------------------------

/**
 * Whether `n` is a valid "Maximum charge when enabled": a whole number from 25 to 99.
 * @param {number | null} n
 * @returns {n is number}
 */
function isProtectedLimit(n) {
    return typeof n === "number" && Number.isInteger(n) && n >= MIN_LIMIT && n <= MAX_PROTECTED_LIMIT;
}

/**
 * Whole number typed in the limit field, optionally followed by "%"; null unless 25–99.
 * @param {string | null | undefined} text
 * @returns {number | null}
 */
function parseLimitInput(text) {
    const m = /^\s*(\d{1,3})\s*%?\s*$/.exec(String(text ?? ""));
    if (!m)
        return null;
    const n = Number(m[1]);
    return isProtectedLimit(n) ? n : null;
}

/**
 * A saved protected limit, or the default when it is missing or invalid.
 * @param {unknown} value value read from the plugin settings
 * @returns {number}
 */
function normalizeProtectedLimit(value) {
    const n = Number(value);
    return isProtectedLimit(n) ? n : DEFAULT_LIMIT;
}

/**
 * A saved poll interval, or the default when it is not one of {@link POLL_MINUTES}.
 * @param {unknown} value value read from the plugin settings (a string)
 * @returns {number}
 */
function normalizePollMinutes(value) {
    const n = Number(value);
    return POLL_MINUTES.includes(n) ? n : DEFAULT_POLL_MINUTES;
}

/**
 * What the hardware maximum should be.
 * @param {boolean} enabled "Limit charging"
 * @param {number} protectedLimit
 * @returns {number}
 */
function targetLimit(enabled, protectedLimit) {
    return enabled ? protectedLimit : FULL_CHARGE;
}

/**
 * "unknown" (not read), "full" (no limit: 100, or 0 when disabled in the EC), "limited"
 * (20–99) or "unexpected".
 * @param {number | null} raw maximum read from the EC
 * @returns {LimitKind}
 */
function classifyLimit(raw) {
    if (typeof raw !== "number" || !Number.isInteger(raw))
        return "unknown";
    if (raw === 0 || raw === FULL_CHARGE)
        return "full";
    if (raw >= EC_MIN_LIMIT && raw < FULL_CHARGE)
        return "limited";
    return "unexpected";
}

/**
 * Maximum charge the EC applies, or null when unknown or unexpected.
 * @param {number | null} raw maximum read from the EC
 * @returns {number | null}
 */
function effectiveMax(raw) {
    switch (classifyLimit(raw)) {
    case "full":
        return FULL_CHARGE;
    case "limited":
        return raw;
    default:
        return null;
    }
}

/**
 * What to do after reading the EC outside a write of this plugin:
 * - "none": the hardware matches the selection, or its value is not understood;
 * - "adopt": follow a change made elsewhere (enabled, limit). A limit outside 25–99 keeps
 *   the saved protected limit, so it is never rounded into the field;
 * - "enforce": write `target` back ("Keep enforcing this limit").
 *
 * selectedEnabled is null before the first read: the hardware is adopted as is.
 * @param {LimitState} state
 * @returns {Reconciliation}
 */
function reconcile({ raw, selectedEnabled, protectedLimit, keepEnforcing }) {
    const kind = classifyLimit(raw);
    if (kind !== "full" && kind !== "limited")
        return { action: "none" };
    /** @type {Reconciliation} */
    const adopt = {
        action: "adopt",
        enabled: kind === "limited",
        limit: isProtectedLimit(raw) ? raw : protectedLimit
    };
    if (selectedEnabled !== true && selectedEnabled !== false)
        return adopt;
    const target = targetLimit(selectedEnabled, protectedLimit);
    if (effectiveMax(raw) === target)
        return { action: "none" };
    return keepEnforcing ? { action: "enforce", target } : adopt;
}

/**
 * Limit to write once after a new boot, or null when nothing needs to change or the
 * user's choice was never known.
 * @param {LimitState} state
 * @returns {number | null}
 */
function bootRestoreTarget({ raw, selectedEnabled, protectedLimit }) {
    if (selectedEnabled !== true && selectedEnabled !== false)
        return null;
    const target = targetLimit(selectedEnabled, protectedLimit);
    return effectiveMax(raw) === target ? null : target;
}

/**
 * Whether the system booted since the boot the plugin last handled.
 * @param {string | null | undefined} savedBootId boot id saved in the plugin state
 * @param {string} currentBootId content of /proc/sys/kernel/random/boot_id, empty when
 *     unreadable
 * @returns {boolean}
 */
function isNewBoot(savedBootId, currentBootId) {
    return !!currentBootId && savedBootId !== currentBootId;
}

// ---- Scheduling ---------------------------------------------------------------------

/**
 * Delay before the next background read: the poll interval, or sooner after failures
 * (30 s, 1, 2, 4… min, capped at the interval).
 * @param {number} errorStreak consecutive failed reads
 * @param {number} pollMs poll interval
 * @returns {number} milliseconds
 */
function nextReadDelayMs(errorStreak, pollMs) {
    if (errorStreak <= 0)
        return pollMs;
    return Math.min(pollMs, 30 * 1000 * 2 ** Math.min(errorStreak - 1, 10));
}

// Delays between attempts to read the EC after a new boot.
const BOOT_RETRY_DELAYS_MS = [5000, 15000, 30000, 60000, 120000];

// Enforcement corrections in the last hour after which another tool is probably enforcing
// its own limit.
const CONFLICT_WINDOW_MS = 60 * 60 * 1000;
const CONFLICT_CORRECTIONS = 2;

/**
 * The enforcement corrections made within {@link CONFLICT_WINDOW_MS} of `now`.
 * @param {number[]} timestamps times of past corrections, in ms since the epoch
 * @param {number} now
 * @returns {number[]}
 */
function recentCorrections(timestamps, now) {
    return timestamps.filter(t => now - t < CONFLICT_WINDOW_MS);
}

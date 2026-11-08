// Tests for logic/ChargeLimit.js and the helper scripts. Run: node tests/run.mjs
// The logic file is a QML ".pragma library" script; it is loaded here without QML.
// The helper runs unprivileged against a fake framework_tool (see fakeHelper below).
import { readFileSync, writeFileSync, mkdtempSync, chmodSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

const root = fileURLToPath(new URL("..", import.meta.url));
const src = readFileSync(join(root, "logic/ChargeLimit.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const names = [...src.matchAll(/^(?:function|const|let|var)\s+([A-Za-z_]\w*)/gm)].map(m => m[1]);
const CL = new Function(`${src}\nreturn { ${names.join(", ")} };`)();

let failed = 0;
function test(name, fn) {
    try {
        fn();
        console.log("ok  ", name);
    } catch (e) {
        failed++;
        console.log("FAIL", name);
        console.log(e.stack);
    }
}

function run(argv, env = {}) {
    const r = spawnSync(argv[0], argv.slice(1), { encoding: "utf8", env: { ...process.env, ...env } });
    return { code: r.status, out: r.stdout, err: r.stderr };
}

// ---- Logic ----------------------------------------------------------------------------

test("validates typed limits", () => {
    assert.equal(CL.parseLimitInput("80"), 80);
    assert.equal(CL.parseLimitInput(" 25 % "), 25);
    assert.equal(CL.parseLimitInput("99"), 99);
    for (const bad of ["", "24", "100", "8.5", "-80", "80a", "abc", "0", null, undefined])
        assert.equal(CL.parseLimitInput(bad), null, String(bad));
    assert.equal(CL.isProtectedLimit(25), true);
    assert.equal(CL.isProtectedLimit(99.5), false);
    assert.equal(CL.normalizeProtectedLimit("nope"), CL.DEFAULT_LIMIT);
    assert.equal(CL.normalizeProtectedLimit(70), 70);
    assert.equal(CL.normalizePollMinutes("15"), 15);
    assert.equal(CL.normalizePollMinutes("7"), CL.DEFAULT_POLL_MINUTES);
});

test("classifies EC values", () => {
    assert.equal(CL.classifyLimit(null), "unknown");
    assert.equal(CL.classifyLimit(0), "full");
    assert.equal(CL.classifyLimit(100), "full");
    assert.equal(CL.classifyLimit(80), "limited");
    assert.equal(CL.classifyLimit(20), "limited");
    assert.equal(CL.classifyLimit(19), "unexpected");
    assert.equal(CL.classifyLimit(228), "unexpected");
    assert.equal(CL.effectiveMax(0), 100);
    assert.equal(CL.effectiveMax(60), 60);
    assert.equal(CL.effectiveMax(150), null);
});

test("targets 100% when disabled", () => {
    assert.equal(CL.targetLimit(true, 80), 80);
    assert.equal(CL.targetLimit(false, 80), 100);
});

test("adopts the hardware on the first read", () => {
    assert.deepEqual(CL.reconcile({ raw: 80, selectedEnabled: null, protectedLimit: 70, keepEnforcing: true }), { action: "adopt", enabled: true, limit: 80 });
    assert.deepEqual(CL.reconcile({ raw: 0, selectedEnabled: null, protectedLimit: 70, keepEnforcing: false }), { action: "adopt", enabled: false, limit: 70 });
});

test("does nothing when the hardware matches", () => {
    assert.deepEqual(CL.reconcile({ raw: 80, selectedEnabled: true, protectedLimit: 80, keepEnforcing: false }), { action: "none" });
    assert.deepEqual(CL.reconcile({ raw: 100, selectedEnabled: false, protectedLimit: 80, keepEnforcing: true }), { action: "none" });
    assert.deepEqual(CL.reconcile({ raw: 0, selectedEnabled: false, protectedLimit: 80, keepEnforcing: true }), { action: "none" });
});

test("adopts external changes unless enforcing", () => {
    // External 100%: off, the saved protected limit is kept.
    assert.deepEqual(CL.reconcile({ raw: 100, selectedEnabled: true, protectedLimit: 80, keepEnforcing: false }), { action: "adopt", enabled: false, limit: 80 });
    // External 25–99%: on, at that limit.
    assert.deepEqual(CL.reconcile({ raw: 60, selectedEnabled: false, protectedLimit: 80, keepEnforcing: false }), { action: "adopt", enabled: true, limit: 60 });
    assert.deepEqual(CL.reconcile({ raw: 60, selectedEnabled: true, protectedLimit: 80, keepEnforcing: false }), { action: "adopt", enabled: true, limit: 60 });
    // Below the plugin's range: on, but never rounded into the field.
    assert.deepEqual(CL.reconcile({ raw: 22, selectedEnabled: true, protectedLimit: 80, keepEnforcing: false }), { action: "adopt", enabled: true, limit: 80 });
    assert.deepEqual(CL.reconcile({ raw: 60, selectedEnabled: true, protectedLimit: 80, keepEnforcing: true }), { action: "enforce", target: 80 });
    assert.deepEqual(CL.reconcile({ raw: 80, selectedEnabled: false, protectedLimit: 80, keepEnforcing: true }), { action: "enforce", target: 100 });
});

test("never acts on unexpected or unknown values", () => {
    assert.deepEqual(CL.reconcile({ raw: 228, selectedEnabled: true, protectedLimit: 80, keepEnforcing: true }), { action: "none" });
    assert.deepEqual(CL.reconcile({ raw: null, selectedEnabled: true, protectedLimit: 80, keepEnforcing: true }), { action: "none" });
});

test("restores once after boot only when needed", () => {
    assert.equal(CL.bootRestoreTarget({ raw: 100, selectedEnabled: true, protectedLimit: 80 }), 80);
    assert.equal(CL.bootRestoreTarget({ raw: 80, selectedEnabled: true, protectedLimit: 80 }), null);
    assert.equal(CL.bootRestoreTarget({ raw: 80, selectedEnabled: false, protectedLimit: 80 }), 100);
    assert.equal(CL.bootRestoreTarget({ raw: 0, selectedEnabled: false, protectedLimit: 80 }), null);
    assert.equal(CL.bootRestoreTarget({ raw: 240, selectedEnabled: true, protectedLimit: 80 }), 80);
    assert.equal(CL.bootRestoreTarget({ raw: 100, selectedEnabled: null, protectedLimit: 80 }), null);
    assert.equal(CL.isNewBoot("a", "b"), true);
    assert.equal(CL.isNewBoot("a", "a"), false);
    assert.equal(CL.isNewBoot("", "a"), true);
    assert.equal(CL.isNewBoot("a", ""), false);
});

test("parses helper output and failures", () => {
    assert.equal(CL.parseLimit("limit=80\n"), 80);
    assert.equal(CL.parseLimit("limit=\n"), null);
    assert.equal(CL.parseLimit("Minimum 0%, Maximum 80%\n"), null);
    assert.equal(CL.errorDetail("noise\nerror=the EC reports 70% after setting 80%\n"), "the EC reports 70% after setting 80%");
    assert.equal(CL.errorDetail("Error executing command as another user: Not authorized\n"), "Error executing command as another user: Not authorized");
    assert.equal(CL.failureCode(6, "write"), "mismatch");
    assert.equal(CL.failureCode(120, "read"), "policy-missing");
    assert.equal(CL.failureCode(126, "install"), "cancelled");
    assert.equal(CL.failureCode(126, "write"), "not-authorized");
    assert.equal(CL.failureCode(1, "read"), "failed");
});

test("derives the helper state from the probe", () => {
    const probe = text => CL.helperState(CL.parseProbe(text));
    assert.equal(CL.helperState(null), "probing");
    assert.equal(probe("polkit=present\npkexec=present\nbundled.version=1\nbundled.tool=/usr/bin/framework_tool\n"), "missing");
    assert.equal(probe("bundled.version=1\n"), "no-polkit");
    assert.equal(probe("installed.version=1\ninstalled.tool=/usr/bin/framework_tool\npolicy=present\npolkit=present\npkexec=present\n"), "installed");
    assert.equal(probe("installed.version=1\npolkit=present\npkexec=present\n"), "broken");
    assert.equal(probe("policy=present\npolkit=present\npkexec=present\n"), "broken");
    assert.equal(CL.helperUsable("installed"), true);
    assert.equal(CL.helperUsable("broken"), false);
    assert.equal(CL.parseProbe("bundled.tool=/usr/bin/framework_tool\n").tool, "/usr/bin/framework_tool");
    assert.equal(CL.parseProbe("bundled.tool=\n").tool, "");
});

test("backs off after failures, up to the poll interval", () => {
    const poll = 5 * 60 * 1000;
    assert.equal(CL.nextReadDelayMs(0, poll), poll);
    assert.equal(CL.nextReadDelayMs(1, poll), 30 * 1000);
    assert.equal(CL.nextReadDelayMs(2, poll), 60 * 1000);
    assert.equal(CL.nextReadDelayMs(20, poll), poll);
    assert.deepEqual(CL.recentCorrections([0, 3_000_000, 3_500_000], 3_700_000), [3_000_000, 3_500_000]);
});

test("helper version matches the shipped helper", () => {
    const helper = readFileSync(join(root, "helper/charge-limit"), "utf8");
    assert.equal(Number(/^readonly HELPER_VERSION=(\d+)$/m.exec(helper)[1]), CL.HELPER_VERSION);
});

test("paths agree between the plugin, the scripts and the policy", () => {
    const policy = readFileSync(join(root, "helper/polkit.policy"), "utf8");
    const install = readFileSync(join(root, "helper/install.sh"), "utf8");
    const uninstall = readFileSync(join(root, "helper/uninstall"), "utf8");
    assert.ok(policy.includes(`<action id="${CL.POLKIT_ACTION}">`));
    assert.ok(policy.includes(`>${CL.HELPER_PATH}</annotate>`));
    for (const script of [install, uninstall]) {
        assert.ok(script.includes(`HELPER_DIR=${CL.HELPER_DIR}\n`));
        assert.ok(script.includes(CL.POLICY_PATH.replace("/usr/share/polkit-1/actions", "")));
    }
});

// ---- Shell scripts --------------------------------------------------------------------

test("shell scripts are valid", () => {
    for (const f of ["helper/charge-limit", "helper/install.sh", "helper/uninstall"])
        assert.equal(run(["bash", "-n", join(root, f)]).code, 0, f);
    for (const script of [CL.GUARD_SCRIPT, CL.PROBE_SCRIPT, CL.LIFECYCLE_SCRIPT])
        assert.equal(run(["sh", "-n", "-c", script]).code, 0, script);
    const xml = run(["xmllint", "--noout", join(root, "helper/polkit.policy")]);
    assert.ok(xml.code === 0 || xml.code === null, xml.err);
});

test("the guard never starts pkexec without the policy", () => {
    // The policy is not installed in the test environment (or this checks a real install).
    const policyInstalled = run(["test", "-f", CL.POLICY_PATH]).code === 0;
    if (policyInstalled)
        return;
    const r = run(CL.helperCommand(["get"]));
    assert.equal(r.code, CL.EXIT.policyMissing);
    assert.equal(r.out, "");
});

test("the probe reports the bundled helper and tool", () => {
    const r = run(CL.probeCommand(join(root, "helper/charge-limit")));
    assert.equal(r.code, 0);
    const p = CL.parseProbe(r.out);
    assert.equal(p.bundledVersion, CL.HELPER_VERSION);
    // On a machine with framework-system installed from a package.
    if (run(["test", "-x", "/usr/bin/framework_tool"]).code === 0)
        assert.equal(p.tool, "/usr/bin/framework_tool");
});

test("the helper refuses invalid arguments and unprivileged access", () => {
    const helper = join(root, "helper/charge-limit");
    for (const args of [[], ["set"], ["set", "24"], ["set", "101"], ["set", "8x"], ["set", "80", "1"], ["get", "x"], ["--charge-limit"]])
        assert.equal(run([helper, ...args]).code, 2, args.join(" "));
    if (process.getuid() !== 0)
        assert.equal(run([helper, "get"]).code, 3);
    const info = CL.parseKeyValues(run([helper, "info"]).out);
    assert.equal(info.version, String(CL.HELPER_VERSION));
});

// A copy of the helper that runs unprivileged, with the given framework_tool candidates.
function fakeHelper(dir, { trustAnything }) {
    let helper = readFileSync(join(root, "helper/charge-limit"), "utf8");
    const replace = (from, to) => {
        assert.ok(helper.includes(from), from);
        helper = helper.replace(from, to);
    };
    replace("((EUID == 0)) ||", "true ||");
    replace(/readonly TOOL_CANDIDATES=\(.*\)/.exec(helper)[0], `readonly TOOL_CANDIDATES=(${dir}/framework_tool)`);
    replace("readonly LOCK_FILE=/run/dms-framework-charge-limit.lock", `readonly LOCK_FILE=${dir}/lock`);
    if (trustAnything)
        replace('if trusted_executable "$candidate"; then', 'if [[ -x $candidate ]]; then');
    const path = join(dir, "charge-limit");
    writeFileSync(path, helper);
    chmodSync(path, 0o755);
    return path;
}

// framework_tool stand-in: FAKE_MODE=ok (default), sticky (ignores writes), broken (EC
// error, exit 0 like the real tool), clamp (stores 50 whatever is asked).
function fakeTool(dir) {
    const path = join(dir, "framework_tool");
    writeFileSync(path, `#!/bin/bash
state=${dir}/limit
[[ -f $state ]] || echo 100 > "$state"
[[ $1 == --charge-limit ]] || exit 1
case \${FAKE_MODE:-ok} in
broken) echo "[ERROR] Failed to communicate with EC. Reason: \\"Timeout\\""; exit 0 ;;
esac
if [[ -n \${2:-} ]]; then
    case \${FAKE_MODE:-ok} in
    ok) echo "$2" > "$state" ;;
    clamp) echo 50 > "$state" ;;
    esac
fi
echo "Minimum 0%, Maximum $(cat "$state")%"
`);
    chmodSync(path, 0o755);
}

test("the helper reads, writes and verifies through framework_tool", () => {
    const dir = mkdtempSync(join(tmpdir(), "charge-limit-test-"));
    try {
        fakeTool(dir);
        const helper = fakeHelper(dir, { trustAnything: true });
        assert.deepEqual(run([helper, "get"]), { code: 0, out: "limit=100\n", err: "" });
        assert.deepEqual(run([helper, "set", "80"]), { code: 0, out: "limit=80\n", err: "" });
        assert.equal(run([helper, "get"]).out, "limit=80\n");
        assert.equal(run([helper, "set", "080"]).out, "limit=80\n");
        assert.equal(run([helper, "set", "100"]).out, "limit=100\n");

        const sticky = run([helper, "set", "60"], { FAKE_MODE: "sticky" });
        assert.equal(sticky.code, 6);
        assert.equal(sticky.out, "limit=100\n");
        assert.match(sticky.err, /^error=the EC reports 100% after setting 60%/);

        const clamp = run([helper, "set", "60"], { FAKE_MODE: "clamp" });
        assert.equal(clamp.code, 6);
        assert.equal(CL.parseLimit(clamp.out), 50);

        const broken = run([helper, "get"], { FAKE_MODE: "broken" });
        assert.equal(broken.code, 5);
        assert.equal(broken.out, "");
        assert.match(CL.errorDetail(broken.err), /could not read the charge limit: \[ERROR\] Failed to communicate with EC/);
        assert.equal(run([helper, "set", "70"], { FAKE_MODE: "broken" }).code, 5);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test("the helper refuses a framework_tool that others can modify", () => {
    const dir = mkdtempSync(join(tmpdir(), "charge-limit-test-"));
    try {
        fakeTool(dir);
        const helper = fakeHelper(dir, { trustAnything: false });
        if (process.getuid() !== 0) {
            const r = run([helper, "get"]);
            assert.equal(r.code, 4);
            assert.equal(CL.parseKeyValues(run([helper, "info"]).out).tool, "");
        }
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test("install.sh and uninstall refuse to run unprivileged", () => {
    if (process.getuid() === 0)
        return;
    assert.equal(run(["bash", join(root, "helper/install.sh"), "install"]).code, 1);
    assert.equal(run(["bash", join(root, "helper/uninstall")]).code, 3);
});

if (failed > 0) {
    console.log(`\n${failed} test(s) failed`);
    process.exit(1);
}
console.log("\nall tests passed");

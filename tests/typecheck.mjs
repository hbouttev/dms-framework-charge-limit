// Checks the JSDoc types of logic/*.js with TypeScript, using the options of jsconfig.json.
// Run: node tests/typecheck.mjs (npx downloads TypeScript on the first run, then caches it).
//
// ".pragma library" is QML, not JavaScript, and tsc skips type checking in a file with a
// syntax error, so a copy without that line is checked. Line numbers stay the same.

import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

// Same major version as the TypeScript bundled with VS Code, whose defaults differ from 5.x.
const TYPESCRIPT = "typescript@6.0.3";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(join(root, "jsconfig.json"), "utf8"));
const work = mkdtempSync(join(tmpdir(), "charge-limit-types-"));

let status;
try {
    mkdirSync(join(work, "logic"));
    for (const name of readdirSync(join(root, "logic")).filter(n => n.endsWith(".js"))) {
        const src = readFileSync(join(root, "logic", name), "utf8");
        writeFileSync(join(work, "logic", name), src.replace(/^\.pragma library$/m, ""));
    }
    writeFileSync(join(work, "tsconfig.json"), JSON.stringify({
        compilerOptions: { ...config.compilerOptions, allowJs: true, pretty: false },
        include: config.include
    }));

    // Run from the copy so reported paths read logic/<file>.js, as in the repository.
    const r = spawnSync("npx", ["--yes", "--package", TYPESCRIPT, "tsc", "--project", "tsconfig.json"], {
        cwd: work,
        encoding: "utf8"
    });
    if (r.error) {
        console.error(`could not run npx: ${r.error.message}`);
        status = 2;
    } else {
        const output = `${r.stdout}${r.stderr}`.split("\n").filter(l => l && !l.startsWith("npm notice"));
        if (output.length > 0)
            console.log(output.join("\n"));
        status = r.status ?? 1;
        if (status === 0)
            console.log("types ok");
    }
} finally {
    rmSync(work, { recursive: true, force: true });
}
process.exit(status);

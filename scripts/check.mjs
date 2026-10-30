#!/usr/bin/env node
// Runs every entry of specs/manifest.json through a TLA+ model checker and
// compares the outcome with the expected one. An entry "passes" when the
// checker reports what the manifest says it should, which for the bug and
// liveness demonstrations is a violation.
//
//   node scripts/check.mjs                  tla-ts (pure Node, no Java)
//   node scripts/check.mjs --engine tlc     the official TLC (Java 11+ and tla2tools.jar)
//   node scripts/check.mjs --only Flatten   only entries whose module or cfg name contains "Flatten"
//   node scripts/check.mjs --trace          also print the counterexample trace of each violation
//
// Environment for --engine tlc:
//   JAVA            path to the java executable      (default: "java" on PATH)
//   TLA2TOOLS_JAR   path to tla2tools.jar            (default: the jar bundled with the
//                                                     VS Code TLA+ extension, if installed)

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const specsDir = path.join(root, "specs");
const manifest = JSON.parse(fs.readFileSync(path.join(specsDir, "manifest.json"), "utf8"));

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const engine = option("--engine", "tla-ts");
const only = option("--only", "");
const showTrace = args.includes("--trace");

const entries = manifest.filter((e) => !only || e.cfg.includes(only) || e.module.includes(only));

// ---------------------------------------------------------------- tla-ts ---

async function runTlaTs(entry) {
  const { check } = await import("tla-ts");
  const source = fs.readFileSync(path.join(specsDir, `${entry.module}.tla`), "utf8");
  const config = fs.readFileSync(path.join(specsDir, entry.cfg), "utf8");
  const result = await check({
    source,
    config,
    loadModule: (name) => {
      const file = path.join(specsDir, `${name}.tla`);
      return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : undefined;
    },
    onPrint: () => {},
  });
  return {
    status: result.status,
    states: `${result.generatedStates}/${result.distinctStates}`,
    violated: result.violation?.name,
    trace: result.violation?.trace,
    message: result.failure?.message,
  };
}

// ------------------------------------------------------------------- TLC ---

function findJar() {
  if (process.env.TLA2TOOLS_JAR) return process.env.TLA2TOOLS_JAR;
  for (const ext of [".vscode", ".vscode-insiders"]) {
    const dir = path.join(os.homedir(), ext, "extensions");
    if (!fs.existsSync(dir)) continue;
    const candidates = fs
      .readdirSync(dir)
      .filter((d) => d.startsWith("tlaplus.vscode-ide-"))
      .sort()
      .reverse();
    for (const c of candidates) {
      const jar = path.join(dir, c, "tools", "tla2tools.jar");
      if (fs.existsSync(jar)) return jar;
    }
  }
  return undefined;
}

function runTlc(entry) {
  const jar = findJar();
  if (!jar) throw new Error("tla2tools.jar not found. Set TLA2TOOLS_JAR to its path.");
  const java = process.env.JAVA || "java";
  const metadir = fs.mkdtempSync(path.join(os.tmpdir(), "tlc-"));
  const res = spawnSync(
    java,
    ["-XX:+UseParallelGC", "-cp", jar, "tlc2.TLC", "-workers", "auto", "-cleanup",
     "-metadir", metadir, "-config", entry.cfg, `${entry.module}.tla`],
    { cwd: specsDir, encoding: "utf8" },
  );
  fs.rmSync(metadir, { recursive: true, force: true });
  // TLC writes trace-exploration modules next to the spec after a violation.
  for (const f of fs.readdirSync(specsDir)) {
    if (/_TTrace_\d+\.(tla|bin)$/.test(f)) fs.rmSync(path.join(specsDir, f));
  }
  if (res.error) throw res.error;

  const out = `${res.stdout}\n${res.stderr}`;
  // Anchored to the line start: TLC's Progress(...) lines print the same
  // phrase with a locale-dependent thousands separator in the numbers.
  const counts = out.match(/^(\d+) states generated, (\d+) distinct states found/m);
  const states = counts ? `${counts[1]}/${counts[2]}` : "?";

  let status = "error";
  let violated;
  let message;
  if (/No error has been found/.test(out)) status = "success";
  else if ((violated = out.match(/Invariant (\w+) is violated/)?.[1])) status = "invariant-violation";
  else if ((violated = out.match(/Action property (\w+) is violated/)?.[1])) status = "property-violation";
  else if ((violated = out.match(/Temporal property (\w+) was violated/)?.[1])) status = "liveness-violation";
  else if (/Deadlock reached/.test(out)) status = "deadlock";
  else if (/Assumption .* is false/.test(out)) status = "assumption-violation";
  else {
    message = out.split("\n").filter((l) => /Error|Exception/.test(l)).slice(0, 3).join(" | ")
      || `java exited with ${res.status}`;
  }

  const start = out.indexOf("State 1:");
  const end = out.search(/\n\d+ states generated/);
  const trace = start >= 0 ? out.slice(start, end > start ? end : undefined).trim() : undefined;
  return { status, states, violated, trace, message };
}

// ------------------------------------------------------------------ main ---

const pad = (s, n) => String(s ?? "").padEnd(n);
console.log(`engine: ${engine}\n`);
console.log(`${pad("", 5)}${pad("config", 44)}${pad("result", 52)}${pad("expected", 22)}${"generated/distinct"}`);

let mismatches = 0;
for (const entry of entries) {
  let r;
  try {
    r = engine === "tlc" ? runTlc(entry) : await runTlaTs(entry);
  } catch (err) {
    r = { status: "error", states: "?", message: err.message };
  }
  const ok = r.status === entry.expect;
  if (!ok) mismatches++;
  const detail = r.violated ? ` (${r.violated})` : r.message ? ` ${r.message}` : "";
  console.log(`${pad(ok ? "ok" : "FAIL", 5)}${pad(entry.cfg, 44)}${pad(r.status + detail, 52)}${pad(entry.expect, 22)}${r.states}`);
  if (showTrace && r.trace) {
    console.log(typeof r.trace === "string" ? r.trace : JSON.stringify(r.trace, null, 1));
    console.log();
  }
}

console.log(`\n${entries.length - mismatches}/${entries.length} outcomes as expected`);
process.exit(mismatches ? 1 : 0);

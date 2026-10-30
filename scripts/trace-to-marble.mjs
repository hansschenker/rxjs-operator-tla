#!/usr/bin/env node
// Turns a TLC counterexample into marble diagrams.
//
//   node scripts/trace-to-marble.mjs <config>      e.g. Flatten_bug_mergeForSwitch.cfg
//
// Runs the manifest entry for <config> through the tla-ts check() API, takes
// the counterexample trace, and prints every stream in it as a marble
// diagram: one frame per value of `now` when the spec has logical time, one
// frame per step otherwise. A stream is a sequence-valued variable; its
// terminal comes from the companion `<name>Done` variable, or from `sub[s]`
// for the per-subscription streams of the share specs. Several events in
// one frame are grouped as (ab); the frame-stamped event list underneath is
// exact (a group takes extra frames in TestScheduler's run mode).
//
// This is the manual step of part 06, section 4, made mechanical.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { check } from "tla-ts";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const specsDir = path.join(root, "specs");
const cfgName = process.argv[2];
if (!cfgName) {
  console.error("usage: node scripts/trace-to-marble.mjs <config.cfg>");
  process.exit(2);
}
const manifest = JSON.parse(fs.readFileSync(path.join(specsDir, "manifest.json"), "utf8"));
const entry = manifest.find((e) => e.cfg === cfgName) ?? { module: cfgName.split(/[_.]/)[0], cfg: cfgName };

const load = (name) => {
  const f = path.join(specsDir, `${name}.tla`);
  return fs.existsSync(f) ? fs.readFileSync(f, "utf8") : undefined;
};
const result = await check({
  source: load(entry.module),
  config: fs.readFileSync(path.join(specsDir, entry.cfg), "utf8"),
  loadModule: load,
  onPrint: () => {},
});

if (!result.violation) {
  console.log(`${entry.cfg}: ${result.status}, no counterexample to draw`);
  process.exit(0);
}

// ------------------------------------------------------------ values ---

/** TLA+ values as tla-ts returns them -> plain JS: sequences to arrays, records and functions to objects. */
function toJs(v) {
  if (v === null || typeof v !== "object") return v;
  if (v.kind === "ModelValue") return v.name;
  if (v.kind === "Function") {
    const dom = v.domain;
    const isSeq = dom.every((d, i) => d === i + 1);
    if (isSeq) return v.range.map(toJs);
    const o = {};
    dom.forEach((d, i) => (o[String(toJs(d))] = toJs(v.range[i])));
    return o;
  }
  if (Array.isArray(v)) return v.map(toJs);
  return v;
}
const show = (v) => (typeof v === "string" ? v : JSON.stringify(v));

// ------------------------------------------------------------ streams ---

const states = result.violation.trace.map((s) => ({ action: s.action, vars: Object.fromEntries(Object.entries(s.state).map(([k, v]) => [k, toJs(v)])) }));
const first = states[0].vars;
const hasTime = typeof first.now === "number";
const frameOf = (i) => (hasTime ? states[i].vars.now : i);

const STATUS = new Set(["active", "complete", "error"]);
const SUB = { idle: "active", on: "active", off: "active", complete: "complete", error: "error" };

/** Which streams to draw: [label, get values(vars), get status(vars) | null, kind]
 *  kind "stream": a sequence of values; "sub": a subscription's lifecycle (^ join, ! leave). */
function streams() {
  const out = [];
  const last = states[states.length - 1].vars; // the initial state's empty sequences say nothing about element types
  const plain = (xs) => Array.isArray(xs) && xs.every((x) => typeof x !== "object" || Array.isArray(x));
  for (const [name, value] of Object.entries(first)) {
    if (plain(last[name])) {
      const done = `${name}Done`;
      out.push([name, (v) => v[name], STATUS.has(first[done]) ? (v) => v[done] : null, "stream"]);
    } else if (value && typeof value === "object" && !Array.isArray(value)) {
      const vals = Object.values(last[name]);
      if (vals.every(plain)) {
        for (const key of Object.keys(value)) {
          out.push([`${name}[${key}]`, (v) => v[name][key], first.sub?.[key] !== undefined ? (v) => SUB[v.sub[key]] : null, "stream"]);
        }
      } else if (vals.every((x) => x in SUB)) {
        for (const key of Object.keys(value)) out.push([`${name}[${key}]`, (v) => v[name][key], null, "sub"]);
      }
    }
  }
  return out;
}

const letters = new Map();
const letterOf = (value) => {
  const k = show(value);
  if (!letters.has(k)) letters.set(k, "abcdefghijklmnopqrstuvwxyz"[letters.size] ?? "?");
  return letters.get(k);
};

const maxFrame = frameOf(states.length - 1);
const lines = [];
const eventLists = [];
for (const [label, vals, status, kind] of streams()) {
  const perFrame = Array.from({ length: maxFrame + 1 }, () => []);
  const events = [];
  for (let i = 1; i < states.length; i++) {
    const prev = vals(states[i - 1].vars);
    const cur = vals(states[i].vars);
    const f = frameOf(i);
    if (kind === "sub") {
      const sym = prev === cur ? null : cur === "on" ? "^" : cur === "off" ? "!" : cur === "complete" ? "|" : cur === "error" ? "#" : null;
      if (sym !== null) (perFrame[f].push(sym), events.push(`${f}: ${cur}`));
      continue;
    }
    for (let j = prev.length; j < cur.length; j++) {
      perFrame[f].push(letterOf(cur[j]));
      events.push(`${f}: ${show(cur[j])}`);
    }
    if (status) {
      const a = status(states[i - 1].vars);
      const b = status(states[i].vars);
      if (a === "active" && b === "complete") (perFrame[f].push("|"), events.push(`${f}: complete`));
      if (a === "active" && b === "error") (perFrame[f].push("#"), events.push(`${f}: error`));
    }
  }
  if (events.length === 0) continue;
  const marble = perFrame.map((s) => (s.length === 0 ? "-" : s.length === 1 ? s[0] : `(${s.join("")})`)).join("");
  lines.push([label, marble]);
  eventLists.push([label, events]);
}

// ------------------------------------------------------------- output ---

console.log(`${entry.cfg}: ${result.status} (${result.violation.name})`);
console.log(`${states.length} states, ${hasTime ? "frame = now" : "frame = step"}${result.violation.loopStart !== undefined ? `, loops back to state ${result.violation.loopStart + 1}` : ""}\n`);

console.log("steps:");
states.forEach((s, i) => console.log(`  ${String(i + 1).padStart(2)}  frame ${String(frameOf(i)).padStart(2)}  ${i === 0 ? "Init" : s.action}`));

console.log("\nmarbles:");
const width = Math.max(...lines.map(([l]) => l.length));
for (const [label, marble] of lines) console.log(`  ${label.padEnd(width)}  ${marble}`);
if (letters.size > 0) console.log(`\n  values: ${[...letters].map(([v, l]) => `${l} = ${v}`).join(", ")}`);

console.log("\nevents (exact frames):");
for (const [label, events] of eventLists) console.log(`  ${label}: ${events.join("; ")}`);

console.log("\nTestScheduler skeleton:");
const values = Object.fromEntries([...letters].map(([v, l]) => [l, v.startsWith('"') ? JSON.parse(v) : v]));
console.log(`  const values = ${JSON.stringify(values)};`);
for (const [label, marble] of lines) console.log(`  // ${label}\n  cold(${JSON.stringify(marble)}, values)`);

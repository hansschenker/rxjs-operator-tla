// Conformance of combineLatest, zip and forkJoin with specs/CombineLatest.tla,
// specs/Zip.tla and specs/ForkJoin.tla.
//
// The two sources use disjoint frames (A even, B odd), so their events are
// totally ordered and each spec's Next relation is deterministic. The test
// runs that relation as a reference and compares the real output to it.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { combineLatest, forkJoin, zip } from "rxjs";
import { RUNS, assertContract, runScheduler, sourceArb } from "./harness";
import type { Rec, SourceSpec } from "./harness";

type Side = "a" | "b";
type Event = { frame: number; side: Side } & ({ kind: "N"; value: string } | { kind: "C" } | { kind: "E" });

function timeline(a: SourceSpec, b: SourceSpec): Event[] {
  const evs: Event[] = [];
  for (const [side, spec] of [["a", a], ["b", b]] as const) {
    for (const e of spec.events) evs.push({ frame: e.frame, side, kind: "N", value: e.value });
    if (spec.end !== null) evs.push({ frame: spec.end.frame, side, kind: spec.end.kind === "complete" ? "C" : "E" });
  }
  return evs.sort((x, y) => x.frame - y.frame);
}

type Pair = [string, string];
type Out = Rec<Pair>;

function refCombineLatest(evs: Event[]): Out[] {
  const out: Out[] = [];
  const last: Partial<Record<Side, string>> = {};
  const done: Record<Side, boolean> = { a: false, b: false };
  for (const e of evs) {
    if (e.kind === "N") {
      last[e.side] = e.value;
      if (last.a !== undefined && last.b !== undefined) out.push({ frame: e.frame, kind: "N", value: [last.a, last.b] });
    } else if (e.kind === "C") {
      done[e.side] = true;
      if (done.a && done.b) return [...out, { frame: e.frame, kind: "C" }];
    } else return [...out, { frame: e.frame, kind: "E", error: "error" }];
  }
  return out;
}

function refZip(evs: Event[]): Out[] {
  const out: Out[] = [];
  const buf: Record<Side, string[]> = { a: [], b: [] };
  const done: Record<Side, boolean> = { a: false, b: false };
  const noMorePairs = (): boolean => (done.a && buf.a.length === 0) || (done.b && buf.b.length === 0);
  for (const e of evs) {
    if (e.kind === "N") {
      buf[e.side].push(e.value);
      if (buf.a.length > 0 && buf.b.length > 0) {
        out.push({ frame: e.frame, kind: "N", value: [buf.a.shift()!, buf.b.shift()!] });
        if (noMorePairs()) return [...out, { frame: e.frame, kind: "C" }];
      }
    } else if (e.kind === "C") {
      done[e.side] = true;
      if (noMorePairs()) return [...out, { frame: e.frame, kind: "C" }];
    } else return [...out, { frame: e.frame, kind: "E", error: "error" }];
  }
  return out;
}

function refForkJoin(evs: Event[]): Out[] {
  const last: Partial<Record<Side, string>> = {};
  const done: Record<Side, boolean> = { a: false, b: false };
  for (const e of evs) {
    if (e.kind === "N") last[e.side] = e.value;
    else if (e.kind === "C") {
      done[e.side] = true;
      if (last[e.side] === undefined) return [{ frame: e.frame, kind: "C" }];
      if (done.a && done.b) return [{ frame: e.frame, kind: "N", value: [last.a!, last.b!] }, { frame: e.frame, kind: "C" }];
    } else return [{ frame: e.frame, kind: "E", error: "error" }];
  }
  return [];
}

const aArb = sourceArb({ values: ["x", "y"], maxLen: 3, maxFrame: 7, frameSet: [0, 2, 4, 6], maxEndGap: 1 });
const bArb = sourceArb({ values: ["x", "y"], maxLen: 3, maxFrame: 7, frameSet: [1, 3, 5, 7], maxEndGap: 1 });

const cases = [
  { name: "combineLatest", run: (a: SourceSpec, b: SourceSpec) => combineLatest, ref: refCombineLatest },
  { name: "zip", run: (a: SourceSpec, b: SourceSpec) => zip, ref: refZip },
  { name: "forkJoin", run: (a: SourceSpec, b: SourceSpec) => forkJoin, ref: refForkJoin },
] as const;

for (const c of cases) {
  describe(`${c.name} conforms to its spec`, () => {
    it("the output equals the spec's deterministic run on the ordered events, and both sources are released at the terminal", () => {
      fc.assert(
        fc.property(aArb, bArb, (a, b) => {
          // an ending of A at an even gap keeps the frames disjoint; drop the rest
          const evs = timeline(a, b);
          fc.pre(evs.every((e, i) => i === 0 || evs[i - 1].frame !== e.frame));

          const { recs, subsA, subsB } = runScheduler((h) => {
            const ca = h.coldFrom(a);
            const cb = h.coldFrom(b);
            const op = c.run(a, b);
            return { recs: h.record(op([ca, cb]) as never as import("rxjs").Observable<Pair>), subsA: ca.subscriptions, subsB: cb.subscriptions };
          });
          assertContract(recs);
          expect(recs).toEqual(c.ref(evs));

          // a source is released when it ends on its own or when the result terminates, whichever is first
          const term = recs.find((r) => r.kind !== "N");
          const release = (spec: SourceSpec): number => Math.min(spec.end === null ? Infinity : spec.end.frame, term === undefined ? Infinity : term.frame);
          expect(subsA[0].unsubscribedFrame).toBe(release(a));
          expect(subsB[0].unsubscribedFrame).toBe(release(b));
        }),
        RUNS,
      );
    });
  });
}

// Conformance of the guarded forkJoin with specs/ForkJoinGuarded.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { defaultIfEmpty, forkJoin, take, takeUntil, timer } from "rxjs";
import type { Observable } from "rxjs";
import { RUNS, assertContract, runScheduler, sourceArb } from "./harness";
import type { Rec, SourceSpec } from "./harness";

type Guard = "take1" | "takeUntilTimer" | "takeUntilTimerDefault";
const D = 3;
const DEFAULT = "dflt";

const guard = (g: Guard, b: Observable<string>): Observable<string> =>
  g === "take1" ? b.pipe(take(1)) : g === "takeUntilTimer" ? b.pipe(takeUntil(timer(D))) : b.pipe(takeUntil(timer(D)), defaultIfEmpty(DEFAULT));

/** What the guarded branch delivers to forkJoin: its values and its end. */
function branch(g: Guard, b: SourceSpec): SourceSpec {
  if (g === "take1") {
    if (b.events.length > 0) return { events: [b.events[0]], end: { frame: b.events[0].frame, kind: "complete" } };
    return b;
  }
  // the timer wins the tie at frame D (it was subscribed first), so values at D are not delivered
  const endsFirst = b.end !== null && b.end.frame < D;
  const events = b.events.filter((e) => e.frame < D);
  const end: SourceSpec["end"] = endsFirst ? b.end : { frame: D, kind: "complete" };
  if (g === "takeUntilTimerDefault" && events.length === 0 && end?.kind === "complete") return { events: [{ frame: end.frame, value: DEFAULT }], end };
  return { events, end };
}

/** ForkJoin.tla's run over A and the branch. */
function refForkJoin(a: SourceSpec, b: SourceSpec): Rec<[string, string]>[] {
  type Ev = { frame: number; side: "a" | "b"; kind: "N" | "C" | "E"; value?: string };
  const evs: Ev[] = [];
  for (const [side, s] of [["a", a], ["b", b]] as const) {
    for (const e of s.events) evs.push({ frame: e.frame, side, kind: "N", value: e.value });
    if (s.end !== null) evs.push({ frame: s.end.frame, side, kind: s.end.kind === "complete" ? "C" : "E" });
  }
  // by frame, A before B within a frame, and (stable sort) a side's values before its end
  evs.sort((x, y) => x.frame - y.frame || (x.side === y.side ? 0 : x.side === "a" ? -1 : 1));
  const last: Partial<Record<"a" | "b", string>> = {};
  const done = { a: false, b: false };
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

const aArb = sourceArb({ values: ["x"], maxLen: 2, maxFrame: 5, frameSet: [0, 2, 4], ends: ["complete"], maxEndGap: 0 });
const bArb = sourceArb({ values: ["y", "z"], maxLen: 2, maxFrame: 7, frameSet: [1, 3, 5, 7], maxEndGap: 0 });

for (const g of ["take1", "takeUntilTimer", "takeUntilTimerDefault"] as const) {
  describe(`forkJoin([a$, ${g}(b$)]) conforms to ForkJoinGuarded.tla`, () => {
    it("the recording equals the spec's run, and B is released when the branch ends", () => {
      fc.assert(
        fc.property(aArb, bArb, (a, b) => {
          // keep A's events away from frame D and from B's, so the order of events is total
          fc.pre(!a.events.some((e) => e.frame === D) && (a.end === null || a.end.frame !== D));
          const { recs, subsB } = runScheduler((h) => {
            const ca = h.coldFrom(a);
            const cb = h.coldFrom(b);
            return { recs: h.record(forkJoin([ca, guard(g, cb)])), subsB: cb.subscriptions };
          });
          assertContract(recs);
          const br = branch(g, b);
          expect(recs).toEqual(refForkJoin(a, br));
          const term = recs.find((r) => r.kind !== "N");
          const branchEnd = br.end === null ? Infinity : br.end.frame;
          expect(subsB[0].unsubscribedFrame).toBe(Math.min(branchEnd, term === undefined ? Infinity : term.frame));
        }),
        RUNS,
      );
    });
  });
}

// Conformance of switchMap, mergeMap, concatMap and exhaustMap with specs/Flatten.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { concatMap, exhaustMap, map, mergeMap, switchMap } from "rxjs";
import type { Observable, OperatorFunction } from "rxjs";
import { RUNS, assertContract, nexts, runScheduler, terminalOf } from "./harness";
import type { Cold, SourceSpec } from "./harness";

type Strategy = "switch" | "merge" | "concat" | "exhaust";
const flatten = (s: Strategy, project: (k: number) => Observable<string>): OperatorFunction<number, string> =>
  s === "switch" ? switchMap(project) : s === "merge" ? mergeMap(project) : s === "concat" ? concatMap(project) : exhaustMap(project);

/** The outer source: terms 1..K at strictly increasing frames, then complete or not. */
interface Outer {
  termFrames: number[];
  end: number | null;
}
const outerArb: fc.Arbitrary<Outer> = fc
  .record({
    gaps: fc.array(fc.integer({ min: 0, max: 2 }), { minLength: 1, maxLength: 3 }),
    endGap: fc.option(fc.integer({ min: 0, max: 2 }), { nil: null }),
  })
  .map(({ gaps, endGap }) => {
    const termFrames: number[] = [];
    let f = 0;
    gaps.forEach((g, i) => {
      f = i === 0 ? g : f + 1 + g;
      termFrames.push(f);
    });
    return { termFrames, end: endGap === null ? null : f + endGap };
  });

/** Inner k delivers k.1 .. k.n at increasing frames, then completes. */
const innerArb = (k: number): fc.Arbitrary<SourceSpec> =>
  fc
    .record({
      gaps: fc.array(fc.integer({ min: 0, max: 2 }), { minLength: 1, maxLength: 2 }),
      endGap: fc.integer({ min: 0, max: 1 }),
    })
    .map(({ gaps, endGap }) => {
      const events: SourceSpec["events"] = [];
      let f = 0;
      gaps.forEach((g, j) => {
        f = j === 0 ? g : f + 1 + g;
        events.push({ frame: f, value: `${k}.${j + 1}` });
      });
      return { events, end: { frame: f + endGap, kind: "complete" as const } };
    });

const innersArb: fc.Arbitrary<SourceSpec[]> = fc.tuple(innerArb(1), innerArb(2), innerArb(3)).map((t) => [...t]);

const innerOf = (v: string): number => Number(v.split(".")[0]);
const indexOf = (v: string): number => Number(v.split(".")[1]);

function overlaps(a: { subscribedFrame: number; unsubscribedFrame: number }, b: { subscribedFrame: number; unsubscribedFrame: number }): boolean {
  return a.subscribedFrame < b.unsubscribedFrame && b.subscribedFrame < a.unsubscribedFrame;
}

for (const strategy of ["switch", "merge", "concat", "exhaust"] as const) {
  describe(`${strategy}Map conforms to Flatten.tla (Strategy = "${strategy}")`, () => {
    it("shared invariants and the strategy's own", () => {
      fc.assert(
        fc.property(outerArb, innersArb, (outer, innerSpecs) => {
          const { recs, inners } = runScheduler((h) => {
            const inners = innerSpecs.map((s) => h.coldFrom(s));
            const src = h
              .coldFrom({
                events: outer.termFrames.map((frame, k) => ({ frame, value: String(k + 1) })),
                end: outer.end === null ? null : { frame: outer.end, kind: "complete" },
              })
              .pipe(map(Number));
            return { recs: h.record(src.pipe(flatten(strategy, (k) => inners[k - 1]))), inners };
          });
          assertContract(recs);
          const outs = nexts(recs);
          const K = outer.termFrames.length;
          const subsOf = (k: number): Cold<string>["subscriptions"] => inners[k - 1].subscriptions;

          // PerInnerOrder: each inner's values arrive in order, without gaps
          for (let k = 1; k <= K; k++) {
            const mine = outs.filter((o) => innerOf(o.value) === k).map((o) => indexOf(o.value));
            expect(mine).toEqual(mine.map((_, j) => j + 1));
          }
          // OnlyActiveInnersDeliver: a value arrives while its inner is subscribed
          for (const o of outs) {
            const subs = subsOf(innerOf(o.value));
            expect(subs.length).toBe(1);
            expect(o.frame).toBeGreaterThanOrEqual(subs[0].subscribedFrame);
            expect(o.frame).toBeLessThanOrEqual(subs[0].unsubscribedFrame);
          }
          // An inner is subscribed at most once
          for (let k = 1; k <= K; k++) expect(subsOf(k).length).toBeLessThanOrEqual(1);

          const ks = outs.map((o) => innerOf(o.value));
          const nonDecreasing = ks.every((k, i) => i === 0 || ks[i - 1] <= k);
          const subscribed = Array.from({ length: K }, (_, i) => i + 1).filter((k) => subsOf(k).length === 1);
          const intervals = subscribed.map((k) => subsOf(k)[0]);
          const noOverlap = intervals.every((a, i) => intervals.every((b, j) => i === j || !overlaps(a, b)));
          const ranToCompletion = (k: number): boolean =>
            subsOf(k)[0].unsubscribedFrame === subsOf(k)[0].subscribedFrame + innerSpecs[k - 1].end!.frame;

          switch (strategy) {
            case "switch":
              expect(noOverlap).toBe(true); // AtMostOneActive
              expect(nonDecreasing).toBe(true); // NoInterleaving
              expect(subscribed.length).toBe(K); // NoDrop
              for (let k = 1; k <= K; k++) {
                expect(subsOf(k)[0].subscribedFrame).toBe(outer.termFrames[k - 1]); // starts on its term
                if (k < K) expect(subsOf(k)[0].unsubscribedFrame).toBeLessThanOrEqual(outer.termFrames[k]); // NewestOnly
              }
              break;
            case "merge":
              expect(subscribed.length).toBe(K); // NoDrop
              for (let k = 1; k <= K; k++) {
                expect(subsOf(k)[0].subscribedFrame).toBe(outer.termFrames[k - 1]);
                expect(ranToCompletion(k)).toBe(true); // NoCancellation
                expect(outs.filter((o) => innerOf(o.value) === k).length).toBe(innerSpecs[k - 1].events.length); // NothingLost
              }
              break;
            case "concat":
              expect(noOverlap).toBe(true); // AtMostOneActive
              expect(nonDecreasing).toBe(true); // NoInterleaving
              expect(subscribed.length).toBe(K); // NoDrop
              for (let k = 1; k <= K; k++) {
                const prevEnd = k === 1 ? 0 : subsOf(k - 1)[0].unsubscribedFrame;
                expect(subsOf(k)[0].subscribedFrame).toBe(Math.max(outer.termFrames[k - 1], prevEnd)); // InOrder
                expect(ranToCompletion(k)).toBe(true); // NoCancellation
                expect(outs.filter((o) => innerOf(o.value) === k).length).toBe(innerSpecs[k - 1].events.length); // NothingLost
              }
              break;
            case "exhaust":
              expect(noOverlap).toBe(true); // AtMostOneActive
              expect(nonDecreasing).toBe(true); // NoInterleaving
              for (let k = 1; k <= K; k++) {
                const f = outer.termFrames[k - 1];
                if (subsOf(k).length === 0) {
                  // dropped: another inner was running when the term arrived
                  expect(intervals.some((iv) => iv.subscribedFrame <= f && f <= iv.unsubscribedFrame)).toBe(true);
                } else {
                  expect(subsOf(k)[0].subscribedFrame).toBe(f);
                  expect(ranToCompletion(k)).toBe(true); // NoCancellation
                }
              }
              break;
          }

          // NotCompleteWhileLive: completes when the outer has, and every subscribed inner has ended
          const term = terminalOf(recs);
          if (outer.end === null) expect(term).toBeUndefined();
          else expect(term).toEqual({ frame: Math.max(outer.end, ...intervals.map((iv) => iv.unsubscribedFrame)), kind: "C" });
        }),
        RUNS,
      );
    });
  });
}

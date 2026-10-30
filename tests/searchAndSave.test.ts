// Conformance of terms$.pipe(switchMap(search), concatMap(save)) with specs/SearchAndSave.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { concatMap, map, switchMap, tap } from "rxjs";
import { RUNS, assertContract, isPrefix, runScheduler, terminalOf, valuesOf } from "./harness";
import type { SourceSpec } from "./harness";

interface Scenario {
  termFrames: number[];
  termsEnd: number | null;
  searches: SourceSpec[]; // one per term: results k.1, k.2 then complete
  saveDelays: number[]; // per possible result, frames until the acknowledgement
}

const scenarioArb: fc.Arbitrary<Scenario> = fc
  .record({
    gaps: fc.array(fc.integer({ min: 0, max: 2 }), { minLength: 1, maxLength: 3 }),
    endGap: fc.option(fc.integer({ min: 0, max: 2 }), { nil: null }),
    searchGaps: fc.array(fc.tuple(fc.integer({ min: 0, max: 2 }), fc.integer({ min: 1, max: 2 })), { minLength: 3, maxLength: 3 }),
    saveDelays: fc.array(fc.integer({ min: 0, max: 2 }), { minLength: 6, maxLength: 6 }),
  })
  .map(({ gaps, endGap, searchGaps, saveDelays }) => {
    const termFrames: number[] = [];
    let f = 0;
    gaps.forEach((g, i) => {
      f = i === 0 ? g : f + 1 + g;
      termFrames.push(f);
    });
    const searches = searchGaps.map(([gap, n], i) => ({
      events: Array.from({ length: n }, (_, j) => ({ frame: gap + j, value: `${i + 1}.${j + 1}` })),
      end: { frame: gap + n - 1, kind: "complete" as const },
    }));
    return { termFrames, termsEnd: endGap === null ? null : f + endGap, searches, saveDelays };
  });

const searchOf = (r: string): number => Number(r.split(".")[0]);
const resultIndex = (r: string): number => (searchOf(r) - 1) * 2 + Number(r.split(".")[1]) - 1;

describe("switchMap(search) then concatMap(save) conforms to SearchAndSave.tla", () => {
  it("AcksArePrefixOfResults, NoStaleSave, SavesSerialised, OneSavePerResult, EveryResultSaved", () => {
    fc.assert(
      fc.property(scenarioArb, (sc) => {
        const { recs, mid, saves } = runScheduler((h) => {
          const searches = sc.searches.map((s) => h.coldFrom(s));
          const saves = sc.saveDelays.map((d, i) => {
            const k = Math.floor(i / 2) + 1;
            const j = (i % 2) + 1;
            return h.coldFrom({ events: [{ frame: d, value: `${k}.${j}` }], end: { frame: d, kind: "complete" } });
          });
          const terms = h
            .coldFrom({
              events: sc.termFrames.map((frame, k) => ({ frame, value: String(k + 1) })),
              end: sc.termsEnd === null ? null : { frame: sc.termsEnd, kind: "complete" },
            })
            .pipe(map(Number));
          const mid: string[] = [];
          const out = terms.pipe(
            switchMap((k) => searches[k - 1]),
            tap((r) => mid.push(r)),
            concatMap((r) => saves[resultIndex(r)]),
          );
          return { recs: h.record(out), mid, saves };
        });
        assertContract(recs);
        const acks = valuesOf(recs);

        expect(isPrefix(acks, mid)).toBe(true); // AcksArePrefixOfResults
        expect(acks.every((a, i) => i === 0 || searchOf(acks[i - 1]) <= searchOf(a))).toBe(true); // NoStaleSave

        // SavesSerialised: save subscriptions never overlap; OneSavePerResult: exactly the delivered results are saved, once
        const intervals = saves.flatMap((s) => s.subscriptions);
        expect(intervals.every((a, i) => intervals.every((b, j) => i === j || a.unsubscribedFrame <= b.subscribedFrame || b.unsubscribedFrame <= a.subscribedFrame))).toBe(true);
        saves.forEach((s, i) => expect(s.subscriptions.length).toBe(mid.filter((r) => resultIndex(r) === i).length));

        // EveryResultSaved: on completion every delivered result was acknowledged
        const term = terminalOf(recs);
        if (term?.kind === "C") expect(acks).toEqual(mid);
        if (sc.termsEnd === null) expect(term).toBeUndefined();
      }),
      RUNS,
    );
  });
});

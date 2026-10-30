// Conformance of map, filter, scan and distinctUntilChanged with specs/Pointwise.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { distinctUntilChanged, filter, map, scan } from "rxjs";
import { RUNS, assertContract, endRec, runScheduler, sourceArb, specValues, terminalOf, valuesOf } from "./harness";

// The user functions of Pointwise.tla
const F = (x: number): number => x * 2;
const P = (x: number): boolean => x % 2 === 0;
const Acc = (a: number, x: number): number => a + x;
const Seed = 0;

// The declarative definitions of Pointwise.tla
const mapSpec = (s: number[]): number[] => s.map(F);
const filterSpec = (s: number[]): number[] => s.filter(P);
const scanSpec = (s: number[]): number[] => {
  const out: number[] = [];
  let acc = Seed;
  for (const x of s) {
    acc = Acc(acc, x);
    out.push(acc);
  }
  return out;
};
const distinctSpec = (s: number[]): number[] => s.filter((x, i) => i === 0 || x !== s[i - 1]);

describe("pointwise operators conform to Pointwise.tla", () => {
  it("out = Spec(in) for each operator, and the terminal passes through", () => {
    fc.assert(
      fc.property(sourceArb({ values: ["0", "1", "2"], maxLen: 4, maxFrame: 5 }), (spec) => {
        const r = runScheduler((h) => {
          const nums = h.coldFrom(spec).pipe(map(Number));
          return {
            map: h.record(nums.pipe(map(F))),
            filter: h.record(nums.pipe(filter(P))),
            scan: h.record(nums.pipe(scan(Acc, Seed))),
            distinct: h.record(nums.pipe(distinctUntilChanged())),
          };
        });
        const inp = specValues(spec).map(Number);
        for (const recs of [r.map, r.filter, r.scan, r.distinct]) assertContract(recs);

        expect(valuesOf(r.map)).toEqual(mapSpec(inp)); // MapCorrect
        expect(valuesOf(r.filter)).toEqual(filterSpec(inp)); // FilterCorrect
        expect(valuesOf(r.scan)).toEqual(scanSpec(inp)); // ScanCorrect
        expect(valuesOf(r.distinct)).toEqual(distinctSpec(inp)); // DistinctCorrect

        // TerminalPassesThrough: same kind, same frame, for all four
        const expected = endRec(spec);
        for (const recs of [r.map, r.filter, r.scan, r.distinct]) {
          const term = terminalOf(recs);
          if (expected === undefined) expect(term).toBeUndefined();
          else expect(term).toEqual(expected);
        }
      }),
      RUNS,
    );
  });
});

// Conformance of source.pipe(filter(P), take(N)) with specs/Pipeline.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { filter, map, take } from "rxjs";
import { RUNS, assertContract, isPrefix, runScheduler, sourceArb, terminalOf, valuesOf } from "./harness";

const P = (x: number): boolean => x % 2 === 0;

describe("filter then take conforms to Pipeline.tla", () => {
  it("EndToEnd, CompletesWhenEnoughPass, NoDeliveryAfterUnsubscribe", () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 2 }), sourceArb({ values: ["0", "1", "2", "3"], maxLen: 5, maxFrame: 6 }), (n, spec) => {
        const { recs, subs } = runScheduler((h) => {
          const src = h.coldFrom(spec);
          return { recs: h.record(src.pipe(map(Number), filter(P), take(n))), subs: src.subscriptions };
        });
        assertContract(recs);
        const out = valuesOf(recs);
        const passing = spec.events.filter((e) => P(Number(e.value)));
        const term = terminalOf(recs);

        expect(isPrefix(out, passing.map((e) => Number(e.value)))).toBe(true); // EndToEnd
        expect(out.length).toBeLessThanOrEqual(n);
        if (passing.length >= n) {
          expect(term).toEqual({ frame: passing[n - 1].frame, kind: "C" }); // CompletesWhenEnoughPass
        } else if (spec.end === null) expect(term).toBeUndefined();
        else expect(term).toMatchObject({ frame: spec.end.frame, kind: spec.end.kind === "complete" ? "C" : "E" });

        // unsubscription reaches the source through the whole chain
        expect(subs[0].unsubscribedFrame).toBe(term ? term.frame : Infinity);
      }),
      RUNS,
    );
  });
});

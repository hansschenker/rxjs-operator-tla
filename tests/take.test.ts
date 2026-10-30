// Conformance of take(N) with specs/Take.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { take } from "rxjs";
import { RUNS, assertContract, isPrefix, runScheduler, sourceArb, specValues, terminalOf, valuesOf } from "./harness";

describe("take(N) conforms to Take.tla", () => {
  it("AtMostN, OutIsPrefixOfIn, CompletesAtN, StillActiveBelowN, ErrorPropagates, UnsubscribedWhenDone", () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 3 }), sourceArb({ values: ["a", "b"], maxLen: 4, maxFrame: 6 }), (n, spec) => {
        const { recs, subs } = runScheduler((h) => {
          const src = h.coldFrom(spec);
          return { recs: h.record(src.pipe(take(n))), subs: src.subscriptions };
        });
        assertContract(recs);
        const out = valuesOf(recs);
        const inp = specValues(spec);
        const term = terminalOf(recs);

        expect(out.length).toBeLessThanOrEqual(n); // AtMostN
        expect(isPrefix(out, inp)).toBe(true); // OutIsPrefixOfIn

        if (out.length === n) {
          // CompletesAtN: in the same step as the N-th value, before anything the source does next
          expect(term).toEqual({ frame: spec.events[n - 1].frame, kind: "C" });
        } else {
          // StillActiveBelowN and ErrorPropagates: the source's own ending, or none
          if (spec.end === null) expect(term).toBeUndefined();
          else expect(term).toMatchObject({ frame: spec.end.frame, kind: spec.end.kind === "complete" ? "C" : "E" });
        }

        // UnsubscribedWhenDone: the source is let go exactly when the subscriber is done
        expect(subs).toHaveLength(1);
        expect(subs[0].unsubscribedFrame).toBe(term ? term.frame : Infinity);
      }),
      RUNS,
    );
  });
});

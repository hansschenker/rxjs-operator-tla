// Conformance of debounceTime(D) with specs/DebounceTime.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { debounceTime } from "rxjs";
import { RUNS, assertContract, endRec, nexts, runScheduler, sourceArb, terminalOf } from "./harness";

describe("debounceTime(D) conforms to DebounceTime.tla", () => {
  it("EveryOutputIsDebouncedOrFlushed, NoMoreOutThanIn, the terminal passes through", () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 3 }),
        sourceArb({ values: ["a", "b"], maxLen: 4, maxFrame: 6, multiPerFrame: true }),
        (d, spec) => {
          const recs = runScheduler((h) => h.record(h.coldFrom(spec).pipe(debounceTime(d))));
          assertContract(recs);
          const outs = nexts(recs);
          const inputs = spec.events;

          expect(outs.length).toBeLessThanOrEqual(inputs.length); // NoMoreOutThanIn

          outs.forEach((o, i) => {
            // Flushed: the completion delivers the pending value first
            const lastInput = inputs.length > 0 ? inputs[inputs.length - 1] : undefined;
            const flushed =
              spec.end !== null &&
              spec.end.kind === "complete" &&
              o.frame === spec.end.frame &&
              i === outs.length - 1 &&
              lastInput !== undefined &&
              o.value === lastInput.value;
            // Debounced: the last input at or before frame t - D, and nothing in (t - D, t]
            const before = inputs.filter((e) => e.frame <= o.frame - d);
            const quiet = !inputs.some((e) => e.frame > o.frame - d && e.frame <= o.frame);
            const debounced =
              before.length > 0 && before[before.length - 1].frame === o.frame - d && before[before.length - 1].value === o.value && quiet;
            expect(flushed || debounced).toBe(true); // EveryOutputIsDebouncedOrFlushed
          });

          // The terminal passes through unchanged; on error nothing is flushed
          const expected = endRec(spec);
          const term = terminalOf(recs);
          if (expected === undefined) expect(term).toBeUndefined();
          else expect(term).toEqual(expected);
          if (spec.end?.kind === "error") expect(outs.every((o) => o.frame < spec.end!.frame)).toBe(true);
        },
      ),
      RUNS,
    );
  });
});

// Conformance of the custom cancelAfter(D) = takeUntil(timer(D)) with specs/CancelAfter.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { takeUntil, timer } from "rxjs";
import type { MonoTypeOperatorFunction } from "rxjs";
import { RUNS, assertContract, nexts, runScheduler, sourceArb, terminalOf } from "./harness";

const cancelAfter =
  <T>(frames: number): MonoTypeOperatorFunction<T> =>
  (source) =>
    source.pipe(takeUntil(timer(frames)));

describe("cancelAfter(D) conforms to CancelAfter.tla", () => {
  it("NoEmitAfterDeadline, PassThrough, TerminatedByDeadline, UnsubscribedWhenDone", () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 4 }), sourceArb({ values: ["a", "b"], maxLen: 4, maxFrame: 6 }), (d, spec) => {
        const { recs, subs } = runScheduler((h) => {
          const src = h.coldFrom(spec);
          return { recs: h.record(src.pipe(cancelAfter(d))), subs: src.subscriptions };
        });
        assertContract(recs);
        const outs = nexts(recs);
        const term = terminalOf(recs);

        expect(outs.every((o) => o.frame <= d)).toBe(true); // NoEmitAfterDeadline

        // PassThrough: everything the source delivered while connected, unchanged.
        // The timer was subscribed first, so at frame D it wins the tie and a
        // value in that frame is not delivered (the spec allows either order).
        const sourceEndsFirst = spec.end !== null && spec.end.frame < d;
        const delivered = spec.events.filter((e) => e.frame < d);
        expect(outs.map((o) => ({ frame: o.frame, value: o.value }))).toEqual(delivered);

        // TerminatedByDeadline: the source's own ending if it comes first, else complete at D
        if (sourceEndsFirst) expect(term).toMatchObject({ frame: spec.end!.frame, kind: spec.end!.kind === "complete" ? "C" : "E" });
        else expect(term).toEqual({ frame: d, kind: "C" });

        // UnsubscribedWhenDone
        expect(subs).toHaveLength(1);
        expect(subs[0].unsubscribedFrame).toBe(term!.frame);
      }),
      RUNS,
    );
  });
});

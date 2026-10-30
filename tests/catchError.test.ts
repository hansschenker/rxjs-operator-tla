// Conformance of catchError with specs/CatchError.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { catchError } from "rxjs";
import { RUNS, assertContract, runScheduler, sourceArb } from "./harness";
import type { Rec, SourceSpec } from "./harness";

/** CatchError.tla's run: the source's values, then the fallback's if the source errored. */
function reference(src: SourceSpec, fb: SourceSpec): Rec<string>[] {
  const recs: Rec<string>[] = src.events.map((e) => ({ frame: e.frame, kind: "N", value: e.value }));
  if (src.end === null) return recs;
  if (src.end.kind === "complete") return [...recs, { frame: src.end.frame, kind: "C" }];
  const at = src.end.frame;
  for (const e of fb.events) recs.push({ frame: at + e.frame, kind: "N", value: e.value });
  if (fb.end === null) return recs;
  return [...recs, fb.end.kind === "complete" ? { frame: at + fb.end.frame, kind: "C" } : { frame: at + fb.end.frame, kind: "E", error: "error" }];
}

describe("catchError conforms to CatchError.tla", () => {
  it("OutIsSourceThenFallback, NoSourceErrorDelivered, FallbackOnlyAfterError, NoReturnToSource", () => {
    fc.assert(
      fc.property(
        sourceArb({ values: ["a", "b"], maxLen: 3, maxFrame: 4 }),
        sourceArb({ values: ["d"], maxLen: 2, maxFrame: 3 }),
        (src, fb) => {
          const { recs, fbSubs } = runScheduler((h) => {
            const fallback = h.coldFrom(fb);
            return { recs: h.record(h.coldFrom(src).pipe(catchError(() => fallback))), fbSubs: fallback.subscriptions };
          });
          assertContract(recs);
          expect(recs).toEqual(reference(src, fb));
          // the selector runs exactly once, at the source's error, or never
          if (src.end?.kind === "error") expect(fbSubs.map((s) => s.subscribedFrame)).toEqual([src.end.frame]);
          else expect(fbSubs).toHaveLength(0);
        },
      ),
      RUNS,
    );
  });
});

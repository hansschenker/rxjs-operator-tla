// Conformance of retry with specs/Retry.tla: a resubscribable source whose
// attempts may each behave differently, compared with the spec's run.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { defer, retry } from "rxjs";
import { RUNS, assertContract, runScheduler, sourceArb } from "./harness";
import type { Rec, SourceSpec } from "./harness";

const ATTEMPTS = 6;
const attemptsArb = fc.array(sourceArb({ values: ["a", "b"], maxLen: 2, maxFrame: 3 }), { minLength: ATTEMPTS, maxLength: ATTEMPTS });

interface Config {
  count: number;
  resetOnSuccess: boolean;
  delay: number;
}
const configArb: fc.Arbitrary<Config> = fc.record({
  count: fc.integer({ min: 1, max: 2 }),
  resetOnSuccess: fc.boolean(),
  delay: fc.integer({ min: 0, max: 2 }),
});

/** Retry.tla's run: the subscriber's notifications and the frame each attempt starts. */
function reference(attempts: SourceSpec[], c: Config): { recs: Rec<string>[]; starts: number[] } | null {
  const recs: Rec<string>[] = [];
  const starts: number[] = [];
  let offset = 0;
  let soFar = 0;
  for (const attempt of attempts) {
    starts.push(offset);
    for (const e of attempt.events) {
      recs.push({ frame: offset + e.frame, kind: "N", value: e.value });
      if (c.resetOnSuccess) soFar = 0;
    }
    if (attempt.end === null) return { recs, starts };
    const at = offset + attempt.end.frame;
    if (attempt.end.kind === "complete") return { recs: [...recs, { frame: at, kind: "C" }], starts };
    if (soFar < c.count) {
      soFar++;
      offset = at + c.delay;
    } else return { recs: [...recs, { frame: at, kind: "E", error: "error" }], starts };
  }
  return null; // ran out of generated attempts
}

describe("retry conforms to Retry.tla", () => {
  it("ValuesConcatenated, ErrorOnlyWhenExhausted, SuccessResetsCounter, WaitingIsBounded, one subscription per attempt", () => {
    fc.assert(
      fc.property(attemptsArb, configArb, (attempts, c) => {
        const expected = reference(attempts, c);
        fc.pre(expected !== null);
        const { recs, colds } = runScheduler((h) => {
          const colds = attempts.map((a) => h.coldFrom(a));
          let i = 0;
          const src = defer(() => colds[i++]);
          const op = c.delay === 0 ? retry({ count: c.count, resetOnSuccess: c.resetOnSuccess }) : retry({ count: c.count, resetOnSuccess: c.resetOnSuccess, delay: c.delay });
          return { recs: h.record(src.pipe(op)), colds };
        });
        assertContract(recs);
        expect(recs).toEqual(expected!.recs);
        // exactly the attempts the spec makes, each subscribed once, at the frame the spec says
        colds.forEach((cold, k) => {
          if (k < expected!.starts.length) expect(cold.subscriptions.map((s) => s.subscribedFrame)).toEqual([expected!.starts[k]]);
          else expect(cold.subscriptions).toHaveLength(0);
        });
      }),
      RUNS,
    );
  });
});

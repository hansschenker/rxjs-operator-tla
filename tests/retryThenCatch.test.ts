// Conformance of retry then catchError, and the reverse, with specs/RetryThenCatch.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { catchError, defer, retry } from "rxjs";
import { RUNS, assertContract, runScheduler, sourceArb } from "./harness";
import type { Rec, SourceSpec } from "./harness";

const N = 5;
const attemptsArb = fc.array(sourceArb({ values: ["a", "b"], maxLen: 2, maxFrame: 3 }), { minLength: N, maxLength: N });
const fallbacksArb = fc.array(sourceArb({ values: ["d"], maxLen: 1, maxFrame: 2 }), { minLength: N, maxLength: N });

type Ref = { recs: Rec<string>[]; attempts: number; fallbacks: number } | null;

function shifted(spec: SourceSpec, at: number, recs: Rec<string>[]): { end: SourceSpec["end"]; at: number } {
  for (const e of spec.events) recs.push({ frame: at + e.frame, kind: "N", value: e.value });
  return { end: spec.end, at };
}

/** retry(count) then catchError: attempts until one succeeds or count is used, then the fallback once. */
function refRetryFirst(attempts: SourceSpec[], fbs: SourceSpec[], count: number): Ref {
  const recs: Rec<string>[] = [];
  let offset = 0;
  let soFar = 0;
  for (let i = 0; i < attempts.length; i++) {
    const { end } = shifted(attempts[i], offset, recs);
    if (end === null) return { recs, attempts: i + 1, fallbacks: 0 };
    if (end.kind === "complete") return { recs: [...recs, { frame: offset + end.frame, kind: "C" }], attempts: i + 1, fallbacks: 0 };
    if (soFar < count) {
      soFar++;
      offset += end.frame;
      continue;
    }
    const at = offset + end.frame;
    const fb = shifted(fbs[0], at, recs);
    if (fb.end === null) return { recs, attempts: i + 1, fallbacks: 1 };
    return {
      recs: [...recs, fb.end.kind === "complete" ? { frame: at + fb.end.frame, kind: "C" } : { frame: at + fb.end.frame, kind: "E", error: "error" }],
      attempts: i + 1,
      fallbacks: 1,
    };
  }
  return null;
}

/** catchError then retry(count): every source error runs a fallback; only a fallback error is retried. */
function refCatchFirst(attempts: SourceSpec[], fbs: SourceSpec[], count: number): Ref {
  const recs: Rec<string>[] = [];
  let offset = 0;
  let soFar = 0;
  for (let i = 0; i < attempts.length; i++) {
    const { end } = shifted(attempts[i], offset, recs);
    if (end === null) return { recs, attempts: i + 1, fallbacks: i };
    if (end.kind === "complete") return { recs: [...recs, { frame: offset + end.frame, kind: "C" }], attempts: i + 1, fallbacks: i };
    const at = offset + end.frame;
    const fb = shifted(fbs[i], at, recs);
    if (fb.end === null) return { recs, attempts: i + 1, fallbacks: i + 1 };
    if (fb.end.kind === "complete") return { recs: [...recs, { frame: at + fb.end.frame, kind: "C" }], attempts: i + 1, fallbacks: i + 1 };
    if (soFar < count) {
      soFar++;
      offset = at + fb.end.frame;
      continue;
    }
    return { recs: [...recs, { frame: at + fb.end.frame, kind: "E", error: "error" }], attempts: i + 1, fallbacks: i + 1 };
  }
  return null;
}

for (const order of ["retryFirst", "catchFirst"] as const) {
  describe(`${order} conforms to RetryThenCatch.tla`, () => {
    it("the recording equals the spec's run; attempts and fallback runs are counted exactly", () => {
      fc.assert(
        fc.property(attemptsArb, fallbacksArb, fc.integer({ min: 1, max: 2 }), (attempts, fbs, count) => {
          const expected = order === "retryFirst" ? refRetryFirst(attempts, fbs, count) : refCatchFirst(attempts, fbs, count);
          fc.pre(expected !== null);
          const { recs, srcs, fallbacks } = runScheduler((h) => {
            const srcs = attempts.map((a) => h.coldFrom(a));
            const fallbacks = fbs.map((f) => h.coldFrom(f));
            let i = 0;
            let j = 0;
            const src = defer(() => srcs[i++]);
            const piped =
              order === "retryFirst"
                ? src.pipe(retry(count), catchError(() => fallbacks[j++]))
                : src.pipe(catchError(() => fallbacks[j++]), retry(count));
            return { recs: h.record(piped), srcs, fallbacks };
          });
          assertContract(recs);
          expect(recs).toEqual(expected!.recs);
          expect(srcs.filter((s) => s.subscriptions.length > 0).length).toBe(expected!.attempts);
          expect(fallbacks.filter((f) => f.subscriptions.length > 0).length).toBe(expected!.fallbacks);
        }),
        RUNS,
      );
    });
  });
}

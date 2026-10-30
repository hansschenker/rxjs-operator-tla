// Conformance of retry before and after share with specs/RetryOnShare.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { defer, retry, share } from "rxjs";
import { RUNS, assertContract, runScheduler, sourceArb, terminalOf } from "./harness";

const N = 5;
const attemptsArb = fc.array(sourceArb({ values: ["a", "b"], maxLen: 2, maxFrame: 3, maxEndGap: 1 }), { minLength: N, maxLength: N });
const COUNT = 2;

describe("retry and share conform to RetryOnShare.tla", () => {
  it('Placement = "before": one retry for everybody, nobody sees an error before exhaustion', () => {
    fc.assert(
      fc.property(attemptsArb, fc.integer({ min: 0, max: 2 }), (attempts, joinAt) => {
        const { r1, r2, srcs } = runScheduler((h) => {
          const srcs = attempts.map((a) => h.coldFrom(a));
          let i = 0;
          const shared = defer(() => srcs[i++]).pipe(retry(COUNT), share());
          return { r1: h.record(shared), r2: h.record(shared, joinAt), srcs };
        });
        assertContract(r1);
        assertContract(r2);
        // a completion resets share(), so a later join starts a second round of attempts
        const executions = srcs.filter((s) => s.subscriptions.length > 0).length;
        const executed = attempts.slice(0, executions);
        const lastComplete = executed.map((a) => a.end?.kind === "complete").lastIndexOf(true);
        const errorsInFinalRound = executed.slice(lastComplete + 1).filter((a) => a.end?.kind === "error").length;
        for (const recs of [r1, r2]) {
          const t = terminalOf(recs);
          if (t?.kind === "E") expect(errorsInFinalRound).toBe(COUNT + 1); // NoErrorBeforeExhaustion, SharedProtection
        }
        expect(executions).toBeLessThanOrEqual(2 * (1 + COUNT)); // at most one round per join, each of COUNT + 1 attempts
      }),
      RUNS,
    );
  });

  it('Placement = "after": the first error reaches the subscription without a retry; the retrying one re-executes the source', () => {
    fc.assert(
      fc.property(attemptsArb, (attempts) => {
        const { r1, r2, srcs } = runScheduler((h) => {
          const srcs = attempts.map((a) => h.coldFrom(a));
          let i = 0;
          const shared = defer(() => srcs[i++]).pipe(share());
          return { r1: h.record(shared.pipe(retry(COUNT))), r2: h.record(shared), srcs };
        });
        assertContract(r1);
        assertContract(r2);
        const firstError = attempts[0].end?.kind === "error" ? attempts[0].end.frame : null;
        const t2 = terminalOf(r2);
        if (firstError !== null) expect(t2).toEqual({ frame: firstError, kind: "E", error: "error" }); // ErrorReachesEveryone
        // RetriesReexecute: with share() resetting on error, each retry subscribes the source again
        const executions = srcs.filter((s) => s.subscriptions.length > 0).length;
        const errorsSeen = attempts.slice(0, executions).filter((a) => a.end?.kind === "error").length;
        const t1 = terminalOf(r1);
        if (t1?.kind === "E") expect(errorsSeen).toBe(COUNT + 1);
        expect(executions).toBe(Math.min(errorsSeen + (attempts[executions - 1]?.end?.kind === "error" ? 0 : 1), N));
      }),
      RUNS,
    );
  });

  it('Placement = "after" with share({resetOnError: false}): the retries are used up without a second execution', () => {
    fc.assert(
      fc.property(attemptsArb, (attempts) => {
        fc.pre(attempts[0].end?.kind === "error");
        const { r1, srcs } = runScheduler((h) => {
          const srcs = attempts.map((a) => h.coldFrom(a));
          let i = 0;
          const shared = defer(() => srcs[i++]).pipe(share({ resetOnError: false }));
          return { r1: h.record(shared.pipe(retry(COUNT))), srcs };
        });
        assertContract(r1);
        expect(srcs.filter((s) => s.subscriptions.length > 0).length).toBe(1); // the source ran once
        expect(terminalOf(r1)).toEqual({ frame: attempts[0].end!.frame, kind: "E", error: "error" }); // exhausted at once
      }),
      RUNS,
    );
  });
});

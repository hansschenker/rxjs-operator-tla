// Conformance of share with a delayed reset with specs/ShareDelayed.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { ReplaySubject, share, timer } from "rxjs";
import type { MonoTypeOperatorFunction } from "rxjs";
import { RUNS, assertContract, nexts, runScheduler, sourceArb } from "./harness";

const D = 2;
const variants: { name: string; op: MonoTypeOperatorFunction<string>; replay: boolean }[] = [
  { name: "share({resetOnRefCountZero: () => timer(2)})", op: share({ resetOnRefCountZero: () => timer(D) }), replay: false },
  {
    name: "share({connector: () => new ReplaySubject(1), resetOnRefCountZero: () => timer(2)})",
    op: share({ connector: () => new ReplaySubject<string>(1), resetOnRefCountZero: () => timer(D) }),
    replay: true,
  },
];

for (const v of variants) {
  describe(`${v.name} conforms to ShareDelayed.tla`, () => {
    it("GraceBounded, JoinKeepsConnection, OneExecutionPerTeardown, and what a joiner receives", () => {
      fc.assert(
        fc.property(
          sourceArb({ values: ["a", "b"], maxLen: 3, maxFrame: 6, ends: ["complete", "none"], maxEndGap: 1 }),
          fc.integer({ min: 0, max: 3 }),
          fc.integer({ min: 0, max: 6 }),
          (spec, leaveAt, rejoinGap) => {
            const joinAt = leaveAt + rejoinGap;
            const { r1, r2, conns } = runScheduler((h) => {
              const src = h.coldFrom(spec);
              const shared = src.pipe(v.op);
              return { r1: h.recordUntil(shared, 0, leaveAt), r2: h.record(shared, joinAt), conns: src.subscriptions };
            });
            assertContract(r1);
            assertContract(r2);
            const completion = spec.end === null ? Infinity : spec.end.frame;
            const graceEnd = leaveAt + D;

            // The join keeps the first connection if it comes before the source completes and no
            // later than the deadline: at the deadline frame the join runs before the reset, at
            // the completion frame the completion runs before the join (scheduling order).
            // (a join at frame 0 subscribes before anything else happens)
            const keep = joinAt === 0 || (joinAt < completion && joinAt <= graceEnd);
            if (keep) {
              expect(conns).toHaveLength(1); // JoinKeepsConnection
              expect(conns[0].unsubscribedFrame).toBe(completion);
            } else {
              // GraceBounded: released at completion or D frames after the last left, then re-executed on the join
              expect(conns[0].unsubscribedFrame).toBe(Math.min(completion, graceEnd));
              expect(conns.length).toBe(2); // OneExecutionPerTeardown
              expect(conns[1].subscribedFrame).toBe(joinAt);
            }

            // What the joiner receives: with a plain Subject only values from its join on;
            // with the ReplaySubject the last value delivered before the join as well.
            if (conns.length === 1 && completion > joinAt) {
              const delivered = spec.events.filter((e) => e.frame < joinAt).map((e) => e.value);
              const first = nexts(r2)[0];
              if (v.replay && delivered.length > 0) {
                expect(first.frame).toBe(joinAt);
                expect([delivered[delivered.length - 1], ...spec.events.filter((e) => e.frame === joinAt).map((e) => e.value)]).toContain(first.value);
              }
              if (!v.replay) expect(nexts(r2).every((n) => n.frame >= joinAt)).toBe(true); // NoValueUnobserved fails: those were lost
            }
          },
        ),
        RUNS,
      );
    });
  });
}

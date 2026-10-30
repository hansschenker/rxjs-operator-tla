// Conformance of share() and shareReplay with specs/Share.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { share, shareReplay } from "rxjs";
import type { MonoTypeOperatorFunction } from "rxjs";
import { RUNS, assertContract, runScheduler, sourceArb, specValues, valuesOf } from "./harness";
import type { Rec } from "./harness";

interface Subscriber {
  at: number;
  until: number | null;
}
const subscriberArb: fc.Arbitrary<Subscriber> = fc
  .record({ at: fc.integer({ min: 0, max: 6 }), stay: fc.option(fc.integer({ min: 0, max: 4 }), { nil: null }) })
  .map(({ at, stay }) => ({ at, until: stay === null ? null : at + stay }));

const variants: { name: string; op: MonoTypeOperatorFunction<string>; resetOnRefCountZero: boolean; replay: boolean }[] = [
  { name: "share()", op: share(), resetOnRefCountZero: true, replay: false },
  { name: "shareReplay(1)", op: shareReplay(1), resetOnRefCountZero: false, replay: true },
  { name: "shareReplay({bufferSize: 1, refCount: true})", op: shareReplay({ bufferSize: 1, refCount: true }), resetOnRefCountZero: true, replay: true },
];

for (const v of variants) {
  describe(`${v.name} conforms to Share.tla`, () => {
    it("NoGaps, SourceStopsWhenUnused (or not), ReplayCoversBuffer, PerSubscriberContract", () => {
      fc.assert(
        fc.property(
          sourceArb({ values: ["a", "b", "c"], maxLen: 3, maxFrame: 5, ends: ["complete", "none"] }),
          fc.array(subscriberArb, { minLength: 1, maxLength: 2 }),
          (spec, subscribers) => {
            const { recs, conns } = runScheduler((h) => {
              const src = h.coldFrom(spec);
              const shared = src.pipe(v.op);
              return { recs: subscribers.map((s) => h.recordUntil(shared, s.at, s.until)), conns: src.subscriptions };
            });
            const all = specValues(spec);
            recs.forEach((r) => assertContract(r));

            // NoGaps: what each subscriber received is a contiguous window of the connection's values
            for (const r of recs) {
              const got = valuesOf(r);
              const window = all.some((_, i) => JSON.stringify(all.slice(i, i + got.length)) === JSON.stringify(got));
              expect(got.length === 0 || window).toBe(true);
            }

            // Each subscriber's connection: the latest one subscribed no later than it joined
            const connOf = (s: Subscriber): number => {
              let c = -1;
              conns.forEach((cl, i) => {
                if (cl.subscribedFrame <= s.at) c = i;
              });
              return c;
            };
            // When a subscriber stopped being "on": unsubscribed, or terminated by the stream
            const offFrame = (s: Subscriber, r: Rec<string>[]): number => {
              const t = r.find((x) => x.kind !== "N");
              const candidates = [s.until ?? Infinity, t ? t.frame : Infinity];
              return Math.min(...candidates);
            };

            conns.forEach((cl, i) => {
              const completion = spec.end === null ? Infinity : cl.subscribedFrame + spec.end.frame;
              const members = subscribers.map((s, j) => ({ s, r: recs[j] })).filter(({ s }) => connOf(s) === i);
              const lastLeave = members.length === 0 ? Infinity : Math.max(...members.map(({ s, r }) => offFrame(s, r)));
              if (v.resetOnRefCountZero) {
                // SourceStopsWhenUnused: the connection ends when the last member leaves, or completes
                expect(cl.unsubscribedFrame).toBe(Math.min(completion, lastLeave));
              } else {
                // shareReplay without refCount keeps the source until it completes
                expect(cl.unsubscribedFrame).toBe(completion);
              }
            });

            // ReplayCoversBuffer: a late joiner on a live connection gets the last value at once
            if (v.replay) {
              subscribers.forEach((s, j) => {
                const i = connOf(s);
                if (i < 0) return;
                const cl = conns[i];
                // A value in the very frame of the join may arrive before or after it
                // (TestScheduler runs it first; the spec allows both), so the replayed
                // value is the last one delivered before the join, or at it.
                const upTo = (limit: (f: number) => boolean): string[] =>
                  spec.events.filter((e) => limit(cl.subscribedFrame + e.frame) && cl.subscribedFrame + e.frame <= cl.unsubscribedFrame).map((e) => e.value);
                const before = upTo((f) => f < s.at);
                const upToJoin = upTo((f) => f <= s.at);
                const completedBefore = spec.end !== null && cl.subscribedFrame + spec.end.frame < s.at;
                if (before.length > 0 && !completedBefore) {
                  const first = recs[j][0];
                  expect(first).toMatchObject({ frame: s.at, kind: "N" });
                  expect([before[before.length - 1], upToJoin[upToJoin.length - 1]]).toContain((first as { value: string }).value);
                }
              });
            }
          },
        ),
        RUNS,
      );
    });
  });
}

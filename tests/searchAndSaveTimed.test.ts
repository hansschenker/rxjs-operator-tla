// Conformance of timed, failing saves with specs/SearchAndSaveTimed.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { EMPTY, catchError, concatMap, defer, map, retry, switchMap, tap } from "rxjs";
import type { MonoTypeOperatorFunction } from "rxjs";
import { RUNS, assertContract, runScheduler, terminalOf, valuesOf } from "./harness";
import type { Cold, SourceSpec } from "./harness";

type Handling = "propagate" | "retryInner" | "catchInner";
const COUNT = 1;
const SAVE_MAX = 2;

/** A save attempt: an acknowledgement after d frames, or an error after d frames. */
interface Attempt {
  d: number;
  fails: boolean;
}
const attemptArb: fc.Arbitrary<Attempt> = fc.record({ d: fc.integer({ min: 1, max: SAVE_MAX }), fails: fc.boolean() });

interface Scenario {
  termFrames: number[];
  termsEnd: number;
  saves: Attempt[][]; // per result (term k has one result), the attempts
}
const scenarioArb: fc.Arbitrary<Scenario> = fc
  .record({
    gaps: fc.array(fc.integer({ min: 0, max: 2 }), { minLength: 1, maxLength: 2 }),
    endGap: fc.integer({ min: 0, max: 2 }),
    saves: fc.array(fc.array(attemptArb, { minLength: 3, maxLength: 3 }), { minLength: 2, maxLength: 2 }),
  })
  .map(({ gaps, endGap, saves }) => {
    const termFrames: number[] = [];
    let f = 0;
    gaps.forEach((g, i) => {
      f = i === 0 ? g : f + 1 + g;
      termFrames.push(f);
    });
    return { termFrames, termsEnd: f + endGap, saves };
  });

const handle = (h: Handling): MonoTypeOperatorFunction<string> =>
  h === "retryInner" ? retry(COUNT) : h === "catchInner" ? catchError(() => EMPTY) : (o) => o;

for (const handling of ["propagate", "retryInner", "catchInner"] as const) {
  describe(`concatMap(r => save(r).pipe(${handling})) conforms to SearchAndSaveTimed.tla`, () => {
    it("AcksAreDoneSaves, SavesSerialised, QueueSurvivesRetries or not, AckLatencyBounded", () => {
      fc.assert(
        fc.property(scenarioArb, (sc) => {
          const { recs, mid, attempts } = runScheduler((h) => {
            const terms = h
              .coldFrom({ events: sc.termFrames.map((frame, k) => ({ frame, value: String(k + 1) })), end: { frame: sc.termsEnd, kind: "complete" } })
              .pipe(map(Number));
            // search k delivers its single result k at once
            const search = (k: number): Cold<string> => h.coldFrom({ events: [{ frame: 0, value: String(k) }], end: { frame: 0, kind: "complete" } });
            const attempts: Cold<string>[][] = sc.saves.map((as, k) =>
              as.map((a) => h.coldFrom({ events: a.fails ? [] : [{ frame: a.d, value: String(k + 1) }], end: { frame: a.d, kind: a.fails ? "error" : "complete" } })),
            );
            const counters = sc.saves.map(() => 0);
            const mid: { frame: number; value: string }[] = [];
            const out = terms.pipe(
              switchMap((k) => search(k)),
              tap((r) => mid.push({ frame: h.now(), value: r })),
              concatMap((r) => defer(() => attempts[Number(r) - 1][counters[Number(r) - 1]++]).pipe(handle(handling))),
            );
            return { recs: h.record(out), mid, attempts };
          });
          assertContract(recs);
          const acks = valuesOf(recs);
          const subs = attempts.flatMap((as) => as.flatMap((c) => c.subscriptions));

          // SavesSerialised: no two save attempts overlap
          expect(subs.every((x, i) => subs.every((y, j) => i === j || x.unsubscribedFrame <= y.subscribedFrame || y.unsubscribedFrame <= x.subscribedFrame))).toBe(true);
          // AcksAreDoneSaves: acknowledgements are the results whose save completed, in order
          const done = mid.filter((m) => attempts[Number(m.value) - 1].some((c, i) => c.subscriptions.length > 0 && !sc.saves[Number(m.value) - 1][i].fails));
          expect(acks).toEqual(done.map((m) => m.value));
          // RetriesBounded
          sc.saves.forEach((_, k) => expect(attempts[k].filter((c) => c.subscriptions.length > 0).length).toBeLessThanOrEqual(handling === "retryInner" ? COUNT + 1 : 1));

          const term = terminalOf(recs);
          const firstFail = sc.saves.findIndex((as) => as[0].fails);
          const firstResultFailed = mid.length > 0 && sc.saves[Number(mid[0].value) - 1][0].fails;
          if (handling === "propagate" && firstResultFailed) expect(term?.kind).toBe("E"); // the queue is lost
          if (handling === "catchInner") expect(term?.kind).toBe("C"); // QueueSurvivesRetries, but EveryResultAcked may fail
          if (handling === "retryInner" && term?.kind === "C") expect(acks).toEqual(mid.map((m) => m.value)); // EveryResultAcked
          void firstFail;

          // AckLatencyBounded: from arrival to acknowledgement, at most (ahead + 1) * SaveMax * attempts
          const maxAttempts = handling === "retryInner" ? COUNT + 1 : 1;
          for (const r of recs) {
            if (r.kind !== "N") continue;
            const arrival = mid.find((m) => m.value === r.value)!;
            const ahead = mid.filter((m) => m.frame <= arrival.frame && m !== arrival).length;
            expect(r.frame - arrival.frame).toBeLessThanOrEqual((ahead + 1) * SAVE_MAX * maxAttempts);
          }
        }),
        RUNS,
      );
    });
  });
}

export type { SourceSpec };

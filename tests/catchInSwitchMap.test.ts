// Conformance of catchError inside versus outside switchMap with specs/CatchInSwitchMap.tla.
import { describe, it, expect } from "vitest";
import * as fc from "fast-check";
import { catchError, map, switchMap } from "rxjs";
import { RUNS, assertContract, nexts, runScheduler, sourceArb, terminalOf } from "./harness";
import type { SourceSpec } from "./harness";

const termsArb = fc
  .record({ gaps: fc.array(fc.integer({ min: 0, max: 2 }), { minLength: 1, maxLength: 3 }), endGap: fc.option(fc.integer({ min: 0, max: 2 }), { nil: null }) })
  .map(({ gaps, endGap }) => {
    const frames: number[] = [];
    let f = 0;
    gaps.forEach((g, i) => {
      f = i === 0 ? g : f + 1 + g;
      frames.push(f);
    });
    const spec: SourceSpec = { events: frames.map((frame, k) => ({ frame, value: String(k + 1) })), end: endGap === null ? null : { frame: f + endGap, kind: "complete" } };
    return spec;
  });
const searchArb = (k: number): fc.Arbitrary<SourceSpec> =>
  sourceArb({ values: [`${k}.r`], maxLen: 2, maxFrame: 2, ends: ["complete", "error"], maxEndGap: 1 });
const searchesArb = fc.tuple(searchArb(1), searchArb(2), searchArb(3)).map((t) => [...t]);
const fallbackArb = sourceArb({ values: ["fb"], maxLen: 1, maxFrame: 1, ends: ["complete"], maxEndGap: 0 });

for (const placement of ["inside", "outside"] as const) {
  describe(`catchError ${placement} switchMap conforms to CatchInSwitchMap.tla`, () => {
    it(placement === "inside" ? "every failed search is caught and the terms stay subscribed" : "the first failed search ends switchMap and the output ends with the fallback", () => {
      fc.assert(
        fc.property(termsArb, searchesArb, fallbackArb, (termsSpec, searchSpecs, fbSpec) => {
          const r = runScheduler((h) => {
            const terms = h.coldFrom(termsSpec);
            const searches = searchSpecs.map((s) => h.coldFrom(s));
            const fallbacks = searchSpecs.map(() => h.coldFrom(fbSpec));
            const outerFallback = h.coldFrom(fbSpec);
            const out =
              placement === "inside"
                ? terms.pipe(map(Number), switchMap((k) => searches[k - 1].pipe(catchError(() => fallbacks[k - 1]))))
                : terms.pipe(map(Number), switchMap((k) => searches[k - 1]), catchError(() => outerFallback));
            return { recs: h.record(out), terms, searches, fallbacks, outerFallback };
          });
          assertContract(r.recs);
          const term = terminalOf(r.recs);
          // a search that errored while subscribed: error frame inside its subscription
          // (a search cancelled by the next term in the frame it would have errored is cancelled first)
          const errored = searchSpecs
            .map((s, i) => ({ s, i, sub: r.searches[i].subscriptions[0], nextTerm: termsSpec.events[i + 1]?.frame ?? Infinity }))
            .filter(
              ({ s, sub, nextTerm }) =>
                sub !== undefined && s.end?.kind === "error" && sub.subscribedFrame + s.end.frame === sub.unsubscribedFrame && sub.unsubscribedFrame < nextTerm,
            );

          if (placement === "inside") {
            expect(term?.kind).not.toBe("E"); // NoSourceErrorDelivered
            for (const e of errored) expect(r.fallbacks[e.i].subscriptions.map((x) => x.subscribedFrame)).toEqual([e.sub.unsubscribedFrame]); // EveryInnerErrorIsCaught
            // OuterSurvivesInnerErrors: the terms are released only when they complete
            expect(r.terms.subscriptions[0].unsubscribedFrame).toBe(termsSpec.end === null ? Infinity : termsSpec.end.frame);
            expect(r.outerFallback.subscriptions).toHaveLength(0);
          } else {
            expect(errored.length).toBeLessThanOrEqual(1); // AtMostOneInnerError
            if (errored.length === 1) {
              const f = errored[0].sub.unsubscribedFrame;
              expect(r.terms.subscriptions[0].unsubscribedFrame).toBe(Math.min(f, termsSpec.end?.frame ?? Infinity)); // FirstErrorEndsSwitchMap
              expect(r.outerFallback.subscriptions.map((x) => x.subscribedFrame)).toEqual([f]);
              expect(term).toEqual({ frame: f + fbSpec.end!.frame, kind: "C" }); // OutputEndsWithFallback
              expect(nexts(r.recs).filter((n) => n.value === "fb").length).toBe(fbSpec.events.length);
            } else {
              expect(r.outerFallback.subscriptions).toHaveLength(0);
            }
          }
        }),
        RUNS,
      );
    });
  });
}

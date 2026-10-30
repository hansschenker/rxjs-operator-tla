// Shared machinery for the conformance tests.
//
// Each test generates random source behaviours within a spec's bounds,
// runs the real RxJS 7 operator under TestScheduler (virtual time, one
// marble frame = one Tick of the specs), records what the subscriber saw,
// and asserts the spec's invariants on the result. See part 06 of the
// analysis, section 6.

import * as fc from "fast-check";
import { Observable } from "rxjs";
import { TestScheduler } from "rxjs/testing";
import type { RunHelpers } from "rxjs/testing";

// ------------------------------------------------------------ sources ---

export type EndKind = "complete" | "error";

export interface SourceEvent {
  frame: number;
  value: string;
}

export interface SourceEnd {
  frame: number;
  kind: EndKind;
}

/** A source behaviour: values at frames, then an ending, or none. */
export interface SourceSpec {
  events: SourceEvent[];
  end: SourceEnd | null;
}

export interface SourceArbOptions {
  values: readonly string[];
  maxLen: number;
  maxFrame: number;
  /** Which endings to generate; default: all three. */
  ends?: readonly (EndKind | "none")[];
  /** Frames after the last value at which the ending may come; default 0..2. */
  maxEndGap?: number;
  /** Allow several values in one frame; default false. */
  multiPerFrame?: boolean;
  /** Restrict value frames to this set, e.g. the even frames. */
  frameSet?: readonly number[];
}

export function sourceArb(o: SourceArbOptions): fc.Arbitrary<SourceSpec> {
  const ends = o.ends ?? ["complete", "error", "none"];
  const frameArb = o.frameSet
    ? fc.constantFrom(...o.frameSet)
    : fc.integer({ min: 0, max: o.maxFrame });
  return fc
    .record({
      frames: fc.array(frameArb, { maxLength: o.maxLen }),
      vals: fc.array(fc.constantFrom(...o.values), { minLength: o.maxLen, maxLength: o.maxLen }),
      endKind: fc.constantFrom(...ends),
      endGap: fc.integer({ min: 0, max: o.maxEndGap ?? 2 }),
    })
    .map(({ frames, vals, endKind, endGap }) => {
      let fs = [...frames].sort((a, b) => a - b);
      if (!o.multiPerFrame) fs = fs.filter((f, i) => i === 0 || f !== fs[i - 1]);
      const events = fs.map((frame, i) => ({ frame, value: vals[i] }));
      const lastEvent = events.length > 0 ? events[events.length - 1].frame : 0;
      const end: SourceEnd | null = endKind === "none" ? null : { frame: lastEvent + endGap, kind: endKind };
      return { events, end };
    });
}

export function specValues(spec: SourceSpec): string[] {
  return spec.events.map((e) => e.value);
}

export interface Marble {
  marble: string;
  values: Record<string, string>;
}

/**
 * Render a SourceSpec as a run-mode marble diagram. Every frame is one
 * character or one group, so frame numbers in the spec are the frames
 * TestScheduler reports.
 */
export function toMarble(spec: SourceSpec): Marble {
  const keys = "abcdefghijklmnopqrstuvwxyz";
  const values: Record<string, string> = {};
  const frames = [...spec.events.map((e) => e.frame), spec.end?.frame ?? -1];
  const lastFrame = Math.max(-1, ...frames);
  let marble = "";
  let k = 0;
  for (let f = 0; f <= lastFrame; f++) {
    const syms: string[] = [];
    for (const e of spec.events) {
      if (e.frame === f) {
        const key = keys[k++];
        values[key] = e.value;
        syms.push(key);
      }
    }
    if (spec.end !== null && spec.end.frame === f) syms.push(spec.end.kind === "complete" ? "|" : "#");
    marble += syms.length === 0 ? "-" : syms.length === 1 ? syms[0] : `(${syms.join("")})`;
  }
  return { marble: marble === "" ? "-" : marble, values };
}

// ---------------------------------------------------------- recording ---

export type Rec<T> =
  | { frame: number; kind: "N"; value: T }
  | { frame: number; kind: "C" }
  | { frame: number; kind: "E"; error: unknown };

export interface SubLog {
  subscribedFrame: number;
  unsubscribedFrame: number;
}

/** A cold observable with TestScheduler's subscription log. */
export type Cold<T> = Observable<T> & { subscriptions: SubLog[] };

export interface Harness extends RunHelpers {
  scheduler: TestScheduler;
  /** The current virtual frame. */
  now: () => number;
  /** A cold observable built from a SourceSpec. */
  coldFrom: (spec: SourceSpec) => Cold<string>;
  /** Subscribe at a frame (default 0) and record every notification with its frame. */
  record: <T>(obs: Observable<T>, atFrame?: number) => Rec<T>[];
  /** Like record, with a handle to unsubscribe at a later frame. */
  recordUntil: <T>(obs: Observable<T>, atFrame: number, untilFrame: number | null) => Rec<T>[];
}

export function runScheduler<R>(body: (h: Harness) => R): R {
  const scheduler = new TestScheduler((actual: unknown, expected: unknown) => {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw new Error(`marble assertion failed: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
    }
  });
  return scheduler.run((helpers) => {
    const now = (): number => scheduler.now();
    const record = <T>(obs: Observable<T>, atFrame = 0): Rec<T>[] => recordUntil(obs, atFrame, null);
    const recordUntil = <T>(obs: Observable<T>, atFrame: number, untilFrame: number | null): Rec<T>[] => {
      const recs: Rec<T>[] = [];
      const subscribe = (): void => {
        const sub = obs.subscribe({
          next: (value) => recs.push({ frame: now(), kind: "N", value }),
          error: (error: unknown) => recs.push({ frame: now(), kind: "E", error }),
          complete: () => recs.push({ frame: now(), kind: "C" }),
        });
        if (untilFrame !== null) scheduler.schedule(() => sub.unsubscribe(), untilFrame - atFrame);
      };
      if (atFrame === 0) subscribe();
      else scheduler.schedule(subscribe, atFrame);
      return recs;
    };
    // A cold observable scheduled directly on the virtual clock, so that every
    // frame of the spec is the frame TestScheduler reports, several events in
    // one frame included. (A marble group "(ab)" takes four frames in run
    // mode, which is why cold(marble) is not used here; toMarble is kept for
    // printing.) Subscriptions are logged like TestScheduler's cold().
    const coldFrom = (spec: SourceSpec): Cold<string> => {
      const subscriptions: SubLog[] = [];
      const obs = new Observable<string>((subscriber) => {
        const log: SubLog = { subscribedFrame: now(), unsubscribedFrame: Infinity };
        subscriptions.push(log);
        subscriber.add(() => {
          log.unsubscribedFrame = now();
        });
        for (const e of spec.events) subscriber.add(scheduler.schedule(() => subscriber.next(e.value), e.frame));
        const end = spec.end;
        if (end !== null) {
          subscriber.add(scheduler.schedule(() => (end.kind === "complete" ? subscriber.complete() : subscriber.error("error")), end.frame));
        }
      });
      return Object.assign(obs, { subscriptions });
    };
    return body({ ...helpers, scheduler, now, coldFrom, record, recordUntil });
  });
}

// --------------------------------------------------------- assertions ---

export function valuesOf<T>(recs: Rec<T>[]): T[] {
  const out: T[] = [];
  for (const r of recs) if (r.kind === "N") out.push(r.value);
  return out;
}

export function nexts<T>(recs: Rec<T>[]): { frame: number; value: T }[] {
  const out: { frame: number; value: T }[] = [];
  for (const r of recs) if (r.kind === "N") out.push({ frame: r.frame, value: r.value });
  return out;
}

export function terminalOf<T>(recs: Rec<T>[]): Rec<T> | undefined {
  return recs.find((r) => r.kind !== "N");
}

export function eq(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

export function isPrefix(p: readonly unknown[], q: readonly unknown[]): boolean {
  return p.length <= q.length && p.every((x, i) => eq(x, q[i]));
}

/** The Observable contract, as seen in a recording: frames never go back,
 *  at most one terminal, nothing after it. */
export function assertContract<T>(recs: Rec<T>[]): void {
  for (let i = 1; i < recs.length; i++) {
    if (recs[i].frame < recs[i - 1].frame) throw new Error(`frames go back at ${i}: ${JSON.stringify(recs)}`);
  }
  const t = recs.findIndex((r) => r.kind !== "N");
  if (t >= 0 && t !== recs.length - 1) throw new Error(`notification after terminal: ${JSON.stringify(recs)}`);
}

/** The terminal a spec's source delivers, if any, as a recording entry. */
export function endRec(spec: SourceSpec): Rec<never> | undefined {
  if (spec.end === null) return undefined;
  return spec.end.kind === "complete"
    ? { frame: spec.end.frame, kind: "C" }
    : { frame: spec.end.frame, kind: "E", error: "error" };
}

export const RUNS = { numRuns: 200 };

---------------------------- MODULE RetryThenCatch ----------------------------
(***************************************************************************)
(* retry and catchError composed, in both orders:                          *)
(*                                                                         *)
(*   Order = "retryFirst"   source$.pipe(retry(Count), catchError(sel))   *)
(*   Order = "catchFirst"   source$.pipe(catchError(sel), retry(Count))   *)
(*                                                                         *)
(* retryFirst is the usual intent: try the source Count + 1 times, and if  *)
(* every attempt fails, switch to the fallback once. The subscriber sees   *)
(* the values of every attempt, then the fallback's, and an error only if *)
(* the fallback itself errors.                                             *)
(*                                                                         *)
(* catchFirst is the common mistake. catchError is upstream of retry, so  *)
(* retry only ever sees errors that escape catchError, which are the      *)
(* fallback's. A fallback that completes ends the stream after the first  *)
(* source error with no retry at all; a fallback that errors makes retry  *)
(* resubscribe the whole upstream, so the source runs again and the       *)
(* fallback runs again on its next error.                                  *)
(*                                                                         *)
(* Built from Retry.tla (a resubscribable source, a retry counter) and    *)
(* CatchError.tla (the fallback as an environment-controlled stream).     *)
(* resetOnSuccess and delay are left out; Retry.tla covers them.          *)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Order,            \* "retryFirst" | "catchFirst"
          Values,           \* values the source may deliver
          FallbackValues,   \* values the fallback may deliver
          Count,            \* retries allowed
          MaxTotal,         \* model bound: source values across all attempts
          MaxFallback       \* model bound: values per fallback run

ASSUME Order \in {"retryFirst", "catchFirst"}
ASSUME Count \in Nat /\ Count >= 1 /\ MaxTotal \in Nat /\ MaxFallback \in Nat

VARIABLES phase,          \* "source" | "fallback" | "done": which stream is subscribed
          attempts,       \* source subscriptions so far
          soFar,          \* retries used
          srcErrors,      \* source errors so far
          fbRuns,         \* fallback subscriptions so far
          fbErrors,       \* fallback errors so far
          all,            \* every value the source delivered, all attempts
          fb,             \* values of the current fallback run
          fbAll,          \* every value any fallback run delivered
          out, outDone    \* what the subscriber received

vars == <<phase, attempts, soFar, srcErrors, fbRuns, fbErrors, all, fb, fbAll, out, outDone>>

Min(a, b) == IF a <= b THEN a ELSE b

TypeOK == /\ phase \in {"source", "fallback", "done"}
          /\ attempts \in 1..(Count + 1) /\ soFar \in 0..Count
          /\ srcErrors \in 0..(Count + 1) /\ fbRuns \in 0..(Count + 1) /\ fbErrors \in 0..(Count + 1)
          /\ all \in Seq(Values) /\ fb \in Seq(FallbackValues) /\ fbAll \in Seq(FallbackValues)
          /\ out \in Seq(Values \cup FallbackValues) /\ outDone \in Status

Init == /\ phase = "source" /\ attempts = 1 /\ soFar = 0
        /\ srcErrors = 0 /\ fbRuns = 0 /\ fbErrors = 0
        /\ all = <<>> /\ fb = <<>> /\ fbAll = <<>>
        /\ out = <<>> /\ outDone = "active"

-----------------------------------------------------------------------------
(* Actions *)

SourceNext(v) ==
  /\ phase = "source" /\ Len(all) < MaxTotal
  /\ all' = Append(all, v) /\ out' = Append(out, v)
  /\ UNCHANGED <<phase, attempts, soFar, srcErrors, fbRuns, fbErrors, fb, fbAll, outDone>>

SourceComplete ==
  /\ phase = "source"
  /\ phase' = "done" /\ outDone' = "complete"
  /\ UNCHANGED <<attempts, soFar, srcErrors, fbRuns, fbErrors, all, fb, fbAll, out>>

(* The source errors. retryFirst: retry resubscribes while it can, and    *)
(* only then does catchError see an error. catchFirst: catchError is      *)
(* first in line and always runs the fallback.                            *)
SourceError ==
  /\ phase = "source"
  /\ srcErrors' = srcErrors + 1
  /\ IF Order = "retryFirst" /\ soFar < Count
       THEN /\ soFar' = soFar + 1 /\ attempts' = attempts + 1
            /\ UNCHANGED <<phase, fbRuns, fb>>
       ELSE /\ phase' = "fallback" /\ fbRuns' = fbRuns + 1 /\ fb' = <<>>
            /\ UNCHANGED <<soFar, attempts>>
  /\ UNCHANGED <<fbErrors, all, fbAll, out, outDone>>

FallbackNext(v) ==
  /\ phase = "fallback" /\ Len(fb) < MaxFallback
  /\ fb' = Append(fb, v) /\ fbAll' = Append(fbAll, v) /\ out' = Append(out, v)
  /\ UNCHANGED <<phase, attempts, soFar, srcErrors, fbRuns, fbErrors, all, outDone>>

FallbackComplete ==
  /\ phase = "fallback"
  /\ phase' = "done" /\ outDone' = "complete"
  /\ UNCHANGED <<attempts, soFar, srcErrors, fbRuns, fbErrors, all, fb, fbAll, out>>

(* The fallback errors. retryFirst: nothing is left to catch it.          *)
(* catchFirst: this is the error retry sees, so retry resubscribes the    *)
(* whole upstream, source included, while it can.                         *)
FallbackError ==
  /\ phase = "fallback"
  /\ fbErrors' = fbErrors + 1
  /\ IF Order = "catchFirst" /\ soFar < Count
       THEN /\ soFar' = soFar + 1 /\ attempts' = attempts + 1 /\ phase' = "source"
            /\ UNCHANGED outDone
       ELSE /\ phase' = "done" /\ outDone' = "error"
            /\ UNCHANGED <<soFar, attempts>>
  /\ UNCHANGED <<srcErrors, fbRuns, all, fb, fbAll, out>>

Done == phase = "done" /\ UNCHANGED vars

Next == \/ \E v \in Values : SourceNext(v)
        \/ SourceComplete \/ SourceError
        \/ \E v \in FallbackValues : FallbackNext(v)
        \/ FallbackComplete \/ FallbackError
        \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
(* Invariants for both orders *)

AttemptsBounded  == attempts <= Count + 1
RetriesBounded   == soFar <= Count
ValuesAccounted  == Len(out) = Len(all) + Len(fbAll)
ErrorOnlyWhenExhausted == outDone = "error" => soFar = Count
DoneIffTerminal  == (phase = "done") <=> Terminal(outDone)

-----------------------------------------------------------------------------
(* Invariants that separate the orders *)

(* retryFirst: the source is retried after each of its first Count errors, *)
(* the fallback runs once, only after the retries are used up, and the    *)
(* output is the source's values then the fallback's.                     *)
SourceIsRetriedAfterError == (srcErrors >= 1 /\ srcErrors <= Count) => attempts = srcErrors + 1
FallbackRunsAtMostOnce    == fbRuns <= 1
FallbackOnlyAfterExhaustion == fbRuns > 0 => soFar = Count
OutIsSourceThenFallback   == out = all \o fbAll

(* When the fallback completes the stream, every retry has been used.     *)
(* Fails for catchFirst: the fallback completes after the first error.    *)
FallbackCompletesOnlyAfterRetries == (outDone = "complete" /\ fbRuns > 0) => soFar = Count

(* catchFirst: the fallback runs on every source error, and the source is *)
(* retried only when the fallback errors.                                 *)
FallbackOnEveryError     == fbRuns = srcErrors
RetryOnlyOnFallbackError == attempts = 1 + Min(fbErrors, Count)

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(out, outDone)]_vars

(* A step in which the source errors never delivers an error: catchError  *)
(* is downstream of the source in both orders.                            *)
SourceErrorNeverDelivered == [][srcErrors' = srcErrors + 1 => outDone' /= "error"]_vars

Completes == <>Terminal(outDone)

=============================================================================

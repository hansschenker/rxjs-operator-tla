------------------------------ MODULE CatchError ------------------------------
(***************************************************************************)
(* catchError(selector): when the source errors, subscribe to the          *)
(* Observable the selector returns and continue with its notifications.   *)
(* Values delivered before the error stay delivered.                       *)
(*                                                                         *)
(* Operator family: error handling. The fallback is modelled as a second   *)
(* source chosen by the environment, so one model covers every selector:   *)
(*                                                                         *)
(*     catchError(() => EMPTY)            fallback completes at once       *)
(*     catchError(() => of(d))            fallback delivers d, completes   *)
(*     catchError(() => throwError(...))  fallback errors at once          *)
(*     a selector that throws             the same as the line above       *)
(*                                                                         *)
(* The one selector this does not cover is catchError((e, caught) =>       *)
(* caught), which resubscribes the source: that is retry(Infinity), see    *)
(* Retry.tla.                                                              *)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Values,           \* values the source may deliver
          FallbackValues,   \* values the fallback may deliver
          MaxLen            \* model bound, per stream

VARIABLES phase,        \* "source" | "fallback": which stream is subscribed
          in, inDone,   \* the source
          fb, fbDone,   \* the fallback; subscribed once phase = "fallback"
          out, outDone  \* what the subscriber received

vars == <<phase, in, inDone, fb, fbDone, out, outDone>>

TypeOK == /\ phase \in {"source", "fallback"}
          /\ in \in Seq(Values) /\ inDone \in Status
          /\ fb \in Seq(FallbackValues) /\ fbDone \in Status
          /\ out \in Seq(Values \cup FallbackValues) /\ outDone \in Status

Init == /\ phase = "source"
        /\ in = <<>> /\ inDone = "active"
        /\ fb = <<>> /\ fbDone = "active"
        /\ out = <<>> /\ outDone = "active"

-----------------------------------------------------------------------------
(* Actions *)

SourceNext(v) ==
  /\ phase = "source" /\ inDone = "active" /\ Len(in) < MaxLen
  /\ in'  = Append(in, v)
  /\ out' = Append(out, v)
  /\ UNCHANGED <<phase, inDone, fb, fbDone, outDone>>

SourceComplete ==
  /\ phase = "source" /\ inDone = "active"
  /\ inDone' = "complete" /\ outDone' = "complete"
  /\ UNCHANGED <<phase, in, fb, fbDone, out>>

(* The source errors. The selector runs, and its result is subscribed in   *)
(* the same step. The subscriber is told nothing.                          *)
SourceError ==
  /\ phase = "source" /\ inDone = "active"
  /\ inDone' = "error"
  /\ phase'  = "fallback"
  /\ UNCHANGED <<in, fb, fbDone, out, outDone>>

FallbackNext(v) ==
  /\ phase = "fallback" /\ fbDone = "active" /\ Len(fb) < MaxLen
  /\ fb'  = Append(fb, v)
  /\ out' = Append(out, v)
  /\ UNCHANGED <<phase, in, inDone, fbDone, outDone>>

(* The fallback terminates; catchError does not catch this error.          *)
FallbackEnd(how) ==
  /\ phase = "fallback" /\ fbDone = "active"
  /\ fbDone'  = how
  /\ outDone' = how
  /\ UNCHANGED <<phase, in, inDone, fb, out>>

Done == Terminal(outDone) /\ UNCHANGED vars

Next == \/ \E v \in Values : SourceNext(v)
        \/ SourceComplete
        \/ SourceError
        \/ \E v \in FallbackValues : FallbackNext(v)
        \/ \E how \in {"complete", "error"} : FallbackEnd(how)
        \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

(* What the subscriber sees is the source's values followed by the         *)
(* fallback's.                                                             *)
OutIsSourceThenFallback == out = in \o fb
SourceValuesKept        == IsPrefix(in, out)

(* The source's error is never delivered; an error can only come from the *)
(* fallback.                                                               *)
NoSourceErrorDelivered == outDone = "error" => (phase = "fallback" /\ fbDone = "error")

(* The fallback runs only after the source has errored, never alongside.  *)
FallbackOnlyAfterError    == phase = "fallback" => inDone = "error"
FallbackSilentBeforeError == phase = "source" => (fb = <<>> /\ fbDone = "active")

(* Completion comes from whichever stream was running.                     *)
CompleteFromRunningStream ==
  outDone = "complete" => \/ (phase = "source" /\ inDone = "complete")
                          \/ (phase = "fallback" /\ fbDone = "complete")

(* Demonstration, expected to fail: catchError is not a try/catch around   *)
(* the pipeline. An error in the fallback reaches the subscriber.          *)
NeverErrors == outDone /= "error"

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][ /\ Contract(in, inDone)
                          /\ Contract(fb, fbDone)
                          /\ Contract(out, outDone) ]_vars

(* The step in which the source errors delivers nothing downstream.        *)
ErrorIsSwallowed == [][(inDone = "active" /\ inDone' = "error") => UNCHANGED <<out, outDone>>]_vars

(* The selector runs at most once: there is no way back to the source.     *)
NoReturnToSource == [][phase = "fallback" => phase' = "fallback"]_vars

=============================================================================

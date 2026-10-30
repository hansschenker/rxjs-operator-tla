-------------------------------- MODULE Retry --------------------------------
(***************************************************************************)
(* retry(config): when the source errors, unsubscribe from it and          *)
(* subscribe again, up to Count times; after that, deliver the error.      *)
(*                                                                         *)
(*   retry(n)                                Count = n                     *)
(*                                           ResetOnSuccess = FALSE        *)
(*                                           Delay = 0                     *)
(*   retry({count: n, resetOnSuccess: true}) ResetOnSuccess = TRUE         *)
(*   retry({count: n, delay: d})             Delay = d frames              *)
(*                                                                         *)
(* Operator family: error handling. The source is *resubscribable*: every  *)
(* attempt is a fresh stream that may deliver any values and end in any    *)
(* way. The subscriber sees one stream: the values of all attempts, one    *)
(* after another, and the terminal notification of the last attempt.      *)
(*                                                                         *)
(* RxJS 7 increments its counter on every error (soFar++ < count) and      *)
(* retries while the old value was below Count, so retry(n) subscribes the *)
(* source at most n + 1 times. The spec does the same.                     *)
(***************************************************************************)
EXTENDS RxBase, Integers

CONSTANTS Values,
          Count,            \* retries allowed after the first attempt
          ResetOnSuccess,   \* BOOLEAN: a delivered value resets the counter
          Delay,            \* frames between an error and the resubscription; 0 = immediate
          MaxTotal,         \* model bound: values delivered across all attempts
          MaxTime           \* model bound on now; only matters when Delay > 0

ASSUME Count \in Nat /\ Delay \in Nat /\ MaxTotal \in Nat /\ MaxTime \in Nat
ASSUME ResetOnSuccess \in BOOLEAN

VARIABLES now,          \* frame; advances only when Delay > 0
          attempt,      \* how many times the source has been subscribed
          soFar,        \* the operator's retry counter
          src,          \* "active" | "waiting" | "done"
          in,           \* values delivered by the current attempt
          all,          \* values delivered by every attempt so far
          out, outDone, \* what the subscriber received
          resumeAt      \* frame of the pending resubscription, while src = "waiting"

vars == <<now, attempt, soFar, src, in, all, out, outDone, resumeAt>>

TypeOK == /\ now \in 0..MaxTime
          /\ attempt \in 1..(Count + 1 + MaxTotal)
          /\ soFar \in 0..(Count + 1)
          /\ src \in {"active", "waiting", "done"}
          /\ in \in Seq(Values) /\ all \in Seq(Values) /\ out \in Seq(Values)
          /\ outDone \in Status
          /\ resumeAt \in 0..MaxTime

Init == /\ now = 0 /\ attempt = 1 /\ soFar = 0 /\ src = "active"
        /\ in = <<>> /\ all = <<>> /\ out = <<>> /\ outDone = "active"
        /\ resumeAt = 0

-----------------------------------------------------------------------------
(* Actions *)

(* The current attempt delivers v; it passes straight through.             *)
SourceNext(v) ==
  /\ src = "active" /\ Len(all) < MaxTotal
  /\ in'  = Append(in, v)
  /\ all' = Append(all, v)
  /\ out' = Append(out, v)
  /\ soFar' = IF ResetOnSuccess THEN 0 ELSE soFar
  /\ UNCHANGED <<now, attempt, src, outDone, resumeAt>>

(* The current attempt completes; so does the subscriber.                  *)
SourceComplete ==
  /\ src = "active"
  /\ src' = "done" /\ outDone' = "complete"
  /\ UNCHANGED <<now, attempt, soFar, in, all, out, resumeAt>>

(* The current attempt errors. With retries left the operator unsubscribes *)
(* and subscribes again, at once or after Delay frames, and the subscriber *)
(* notices nothing. Otherwise the error is delivered.                      *)
SourceError ==
  /\ src = "active"
  /\ soFar' = soFar + 1
  /\ IF soFar < Count
       THEN /\ Delay = 0 \/ now + Delay <= MaxTime       \* model bound: the retry fits the horizon
            /\ IF Delay = 0
                 THEN /\ src' = "active" /\ attempt' = attempt + 1 /\ in' = <<>>
                      /\ UNCHANGED resumeAt
                 ELSE /\ src' = "waiting" /\ resumeAt' = now + Delay
                      /\ UNCHANGED <<attempt, in>>
            /\ UNCHANGED outDone
       ELSE /\ src' = "done" /\ outDone' = "error"
            /\ UNCHANGED <<attempt, in, resumeAt>>
  /\ UNCHANGED <<now, all, out>>

(* The delay has elapsed: subscribe to the source again.                   *)
Resubscribe ==
  /\ src = "waiting" /\ now = resumeAt
  /\ src' = "active" /\ attempt' = attempt + 1 /\ in' = <<>>
  /\ UNCHANGED <<now, soFar, all, out, outDone, resumeAt>>

(* Logical time, as in DebounceTime: a due resubscription happens first.   *)
Tick ==
  /\ Delay > 0 /\ now < MaxTime
  /\ ~(src = "waiting" /\ now = resumeAt)
  /\ now' = now + 1
  /\ UNCHANGED <<attempt, soFar, src, in, all, out, outDone, resumeAt>>

Done == src = "done" /\ UNCHANGED vars

Next == \/ Tick
        \/ \E v \in Values : SourceNext(v)
        \/ SourceComplete
        \/ SourceError
        \/ Resubscribe
        \/ Done

(* Fairness only on the operator's own machinery.                          *)
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Resubscribe)

-----------------------------------------------------------------------------
(* Invariants *)

(* retry neither hides nor replays values: the subscriber gets every value *)
(* of every attempt, in order. Values of failed attempts are not undone.   *)
ValuesConcatenated == out = all

(* The error is delivered only once Count retries have been used.          *)
RetriesBounded         == soFar <= Count + 1
ErrorOnlyWhenExhausted == outDone = "error" => soFar = Count + 1

(* Without resetOnSuccess the counter is exactly the number of failed      *)
(* attempts so far.                                                        *)
CounterTracksAttempts ==
  ~ResetOnSuccess =>
    soFar = IF src = "active" \/ outDone = "complete" THEN attempt - 1 ELSE attempt

(* With resetOnSuccess, any value in the current attempt clears the count. *)
SuccessResetsCounter == (ResetOnSuccess /\ src = "active" /\ in /= <<>>) => soFar = 0

(* Attempts are bounded by Count plus the number of values that could have *)
(* reset the counter.                                                      *)
AttemptsBounded == attempt <= Count + 1 + Len(all)

(* The wait between attempts is at most Delay frames, and absent when 0.   *)
WaitingIsBounded      == src = "waiting" => (now <= resumeAt /\ resumeAt <= now + Delay)
ImmediateWithoutDelay == Delay = 0 => src /= "waiting"

DoneIffTerminal == (src = "done") <=> Terminal(outDone)

(* Demonstration, expected to fail: the subscriber does see the values of  *)
(* attempts that later failed, before the final error.                     *)
NoPartialResults == outDone = "error" => out = <<>>

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(out, outDone)]_vars

(* Every value delivered by an attempt reaches the subscriber in that step.*)
ValuesPassThrough == [][Len(in') > Len(in) => out' = Append(out, Last(in'))]_vars

(* Between attempts the subscriber hears nothing.                          *)
NoDeliveryWhileWaiting == [][src = "waiting" => UNCHANGED <<out, outDone>>]_vars

(* A delayed retry always happens.                                         *)
WaitingEndsInResubscription == (src = "waiting") ~> (src = "active")

=============================================================================

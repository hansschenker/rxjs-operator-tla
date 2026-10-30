--------------------------- MODULE CatchInSwitchMap ---------------------------
(***************************************************************************)
(* catchError inside or outside a switchMap:                               *)
(*                                                                         *)
(*   Placement = "inside"                                                  *)
(*     terms$.pipe(switchMap(t => search(t).pipe(catchError(() => fb))))  *)
(*                                                                         *)
(*   Placement = "outside"                                                 *)
(*     terms$.pipe(switchMap(t => search(t)), catchError(() => fb))        *)
(*                                                                         *)
(* Inside, a failed search is replaced by the fallback as if the search    *)
(* had delivered the fallback's values and completed; the outer stream     *)
(* carries on and the next term starts a new search. Outside, the first    *)
(* failed search is an error for switchMap, which tears down the outer     *)
(* subscription; catchError then runs the fallback once and the output     *)
(* terminates with it. The search box stops working after one failure.    *)
(*                                                                         *)
(* Built from Flatten.tla (switch strategy, inner errors added) and        *)
(* CatchError.tla (the fallback as an environment-controlled stream).      *)
(* Values delivered are triples <<k, kind, j>>: k is the search (0 for    *)
(* the outside fallback), kind is "result" or "fallback", j the index.     *)
(***************************************************************************)
EXTENDS RxBase, FiniteSets

CONSTANTS Placement,     \* "inside" | "outside"
          MaxOuter,      \* model bound: search terms
          MaxInner,      \* results a search delivers before completing
          MaxFallback    \* model bound: values a fallback may deliver

ASSUME Placement \in {"inside", "outside"}
ASSUME MaxOuter \in Nat /\ MaxInner \in Nat /\ MaxInner >= 1 /\ MaxFallback \in Nat

VARIABLES outerDone, subscribed,   \* the terms, and whether switchMap still listens to them
          inner,                   \* Seq of [state, sent, fb, caught]: one search per term
          out, outDone,            \* what the subscriber received
          fallback, fbSent,        \* the outside fallback: its status and values delivered
          innerErrors              \* how many searches have errored

vars == <<outerDone, subscribed, inner, out, outDone, fallback, fbSent, innerErrors>>

InnerState == {"active",       \* the search is running
               "recovering",   \* inside: the search errored and its fallback is running
               "done",         \* completed (or recovered and the fallback completed)
               "errored",      \* inside: the fallback errored; outside: the search errored
               "cancelled"}    \* switched away from

Rec(st) == [state |-> st, sent |-> 0, fb |-> 0, caught |-> FALSE]

Active     == {k \in DOMAIN inner : inner[k].state = "active"}
Recovering == {k \in DOMAIN inner : inner[k].state = "recovering"}
Live       == Active \cup Recovering
Quiet(f)   == \A k \in DOMAIN f : f[k].state \in {"done", "errored", "cancelled"}

SetState(f, S, st) == [k \in DOMAIN f |-> IF k \in S THEN [f[k] EXCEPT !.state = st] ELSE f[k]]

Value == (0..MaxOuter) \X {"result", "fallback"} \X (1..(MaxInner + MaxFallback))

TypeOK == /\ outerDone \in Status /\ outDone \in Status /\ subscribed \in BOOLEAN
          /\ inner \in Seq([state : InnerState, sent : 0..MaxInner, fb : 0..MaxFallback, caught : BOOLEAN])
          /\ out \in Seq(Value)
          /\ fallback \in {"idle", "active", "done", "errored"} /\ fbSent \in 0..MaxFallback
          /\ innerErrors \in Nat

Init == /\ outerDone = "active" /\ subscribed = TRUE
        /\ inner = <<>> /\ out = <<>> /\ outDone = "active"
        /\ fallback = "idle" /\ fbSent = 0 /\ innerErrors = 0

-----------------------------------------------------------------------------
(* Actions *)

(* A new term: switchMap cancels whatever is live, a search or a fallback *)
(* still delivering inside a search, and starts a new search.             *)
OuterNext ==
  /\ subscribed /\ outerDone = "active" /\ Len(inner) < MaxOuter
  /\ inner' = Append(SetState(inner, Live, "cancelled"), Rec("active"))
  /\ UNCHANGED <<outerDone, subscribed, out, outDone, fallback, fbSent, innerErrors>>

OuterComplete ==
  /\ subscribed /\ outerDone = "active"
  /\ outerDone' = "complete" /\ subscribed' = FALSE
  /\ outDone' = IF Quiet(inner) THEN "complete" ELSE outDone
  /\ UNCHANGED <<inner, out, fallback, fbSent, innerErrors>>

InnerNext(k) ==
  /\ k \in Active /\ inner[k].sent < MaxInner
  /\ inner' = [inner EXCEPT ![k].sent = @ + 1]
  /\ out'   = Append(out, <<k, "result", inner[k].sent + 1>>)
  /\ UNCHANGED <<outerDone, subscribed, outDone, fallback, fbSent, innerErrors>>

InnerComplete(k) ==
  /\ k \in Active /\ inner[k].sent = MaxInner
  /\ LET f == [inner EXCEPT ![k].state = "done"]
     IN /\ inner'   = f
        /\ outDone' = IF outerDone = "complete" /\ Quiet(f) THEN "complete" ELSE outDone
  /\ UNCHANGED <<outerDone, subscribed, out, fallback, fbSent, innerErrors>>

(* A search errors. Inside: its catchError subscribes the fallback, and   *)
(* nothing else changes. Outside: switchMap errors, unsubscribing from the *)
(* terms, and the outer catchError subscribes the fallback.                *)
InnerError(k) ==
  /\ k \in Active
  /\ innerErrors' = innerErrors + 1
  /\ IF Placement = "inside"
       THEN /\ inner' = [inner EXCEPT ![k].state = "recovering", ![k].caught = TRUE]
            /\ UNCHANGED <<subscribed, fallback>>
       ELSE /\ inner' = [SetState(inner, Live, "cancelled") EXCEPT ![k].state = "errored"]
            /\ subscribed' = FALSE
            /\ fallback'   = "active"
  /\ UNCHANGED <<outerDone, out, outDone, fbSent>>

(* Inside: the fallback of search k delivers, completes, or errors.       *)
InnerFallbackNext(k) ==
  /\ k \in Recovering /\ inner[k].fb < MaxFallback
  /\ inner' = [inner EXCEPT ![k].fb = @ + 1]
  /\ out'   = Append(out, <<k, "fallback", inner[k].fb + 1>>)
  /\ UNCHANGED <<outerDone, subscribed, outDone, fallback, fbSent, innerErrors>>

InnerFallbackComplete(k) ==
  /\ k \in Recovering
  /\ LET f == [inner EXCEPT ![k].state = "done"]
     IN /\ inner'   = f
        /\ outDone' = IF outerDone = "complete" /\ Quiet(f) THEN "complete" ELSE outDone
  /\ UNCHANGED <<outerDone, subscribed, out, fallback, fbSent, innerErrors>>

(* An error in the inside fallback is not caught: it ends everything.     *)
InnerFallbackError(k) ==
  /\ k \in Recovering
  /\ inner'      = [SetState(inner, Live, "cancelled") EXCEPT ![k].state = "errored"]
  /\ outDone'    = "error"
  /\ subscribed' = FALSE
  /\ UNCHANGED <<outerDone, out, fallback, fbSent, innerErrors>>

(* Outside: the single fallback delivers, completes, or errors, and the    *)
(* output terminates with it.                                              *)
OuterFallbackNext ==
  /\ fallback = "active" /\ fbSent < MaxFallback
  /\ fbSent' = fbSent + 1
  /\ out'    = Append(out, <<0, "fallback", fbSent + 1>>)
  /\ UNCHANGED <<outerDone, subscribed, inner, outDone, fallback, innerErrors>>

OuterFallbackEnd(how) ==
  /\ fallback = "active"
  /\ fallback' = IF how = "complete" THEN "done" ELSE "errored"
  /\ outDone'  = how
  /\ UNCHANGED <<outerDone, subscribed, inner, out, fbSent, innerErrors>>

Done == Terminal(outDone) /\ UNCHANGED vars

Next == \/ OuterNext \/ OuterComplete
        \/ \E k \in DOMAIN inner : \/ InnerNext(k) \/ InnerComplete(k) \/ InnerError(k)
                                   \/ InnerFallbackNext(k) \/ InnerFallbackComplete(k) \/ InnerFallbackError(k)
        \/ OuterFallbackNext
        \/ \E how \in {"complete", "error"} : OuterFallbackEnd(how)
        \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
(* Invariants for both placements *)

(* switchMap's own guarantees, with a recovering fallback counted as live. *)
AtMostOneLive == Cardinality(Live) <= 1
NewestOnly    == Live \subseteq {Len(inner)}

(* Results and inside-fallback values are grouped by search, in order.     *)
Grouped == \A i \in DOMAIN out :
             (i + 1 \in DOMAIN out /\ out[i][1] > 0 /\ out[i + 1][1] > 0) => out[i][1] <= out[i + 1][1]

(* The subscriber sees an error only if a fallback errored.               *)
ErrorOnlyFromFallback ==
  outDone = "error" => IF Placement = "inside"
                         THEN \E k \in DOMAIN inner : inner[k].state = "errored"
                         ELSE fallback = "errored"

-----------------------------------------------------------------------------
(* Invariants that separate the placements *)

(* Inside: every failed search is recovered, and the outer stream carries  *)
(* on. Outside: both fail; see the two bug demos.                          *)
EveryInnerErrorIsCaught   == innerErrors = Cardinality({k \in DOMAIN inner : inner[k].caught})
OuterSurvivesInnerErrors  == (innerErrors > 0 /\ outerDone = "active" /\ outDone = "active") => subscribed
NotCompleteWhileTermsActive == outDone = "complete" => outerDone = "complete"

(* Outside: the first failed search ends switchMap; the fallback runs once *)
(* and the output ends with it.                                            *)
AtMostOneInnerError     == innerErrors <= 1
FirstErrorEndsSwitchMap == innerErrors > 0 => ~subscribed
OutputEndsWithFallback  == fallback \in {"done", "errored"} => Terminal(outDone)

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(out, outDone)]_vars

(* A value attributed to a search comes from a search that is live.       *)
OnlyLiveSearchesDeliver == [][(out' /= out /\ Last(out')[1] > 0) => Last(out')[1] \in Live]_vars

Completes == <>Terminal(outDone)

=============================================================================

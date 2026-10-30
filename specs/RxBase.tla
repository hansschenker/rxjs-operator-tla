------------------------------- MODULE RxBase -------------------------------
(***************************************************************************)
(* Shared vocabulary for the RxJS operator specifications in this folder.  *)
(*                                                                         *)
(* An Observable's output follows the grammar                              *)
(*                                                                         *)
(*     next* (complete | error)?                                           *)
(*                                                                         *)
(* Every spec models a stream with two variables:                          *)
(*                                                                         *)
(*   vals    a sequence of the values delivered so far (append-only)       *)
(*   status  "active" until a terminal notification, then "complete" or    *)
(*           "error" forever                                               *)
(*                                                                         *)
(* Splitting the grammar this way lets invariants talk about the values    *)
(* (out = F(in)) separately from termination (outDone = inDone).           *)
(***************************************************************************)
EXTENDS Naturals, Sequences

Status      == {"active", "complete", "error"}
Terminal(s) == s \in {"complete", "error"}

IsPrefix(s, t) == /\ Len(s) <= Len(t)
                  /\ \A i \in 1..Len(s) : s[i] = t[i]

Last(s)  == s[Len(s)]
Range(s) == {s[i] : i \in DOMAIN s}

(***************************************************************************)
(* Contract(vals, status) is an *action*: it relates a state to the next   *)
(* one (the primed variables). Used as                                     *)
(*                                                                         *)
(*     [][Contract(out, outDone)]_vars                                     *)
(*                                                                         *)
(* it says: every step the stream takes respects the Observable contract.  *)
(* This cannot be an ordinary invariant, because "nothing is delivered     *)
(* after complete" compares two consecutive states.                        *)
(***************************************************************************)
Contract(vals, status) ==
  /\ IsPrefix(vals, vals')                   \* values are only ever appended
  /\ Terminal(status) => status' = status    \* a terminal status is final
  /\ Terminal(status) => vals' = vals        \* nothing is delivered after it

=============================================================================

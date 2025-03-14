-------------------------------- MODULE dbft --------------------------------

EXTENDS
  Integers,
  FiniteSets

CONSTANTS
  \* RM is the set of consensus node indexes starting from 0.
  \* Example: {0, 1, 2, 3}
  RM,

  \* RMFault is a set of consensus node indexes that are allowed to become
  \* FAULT in the middle of every considered behavior and to send any
  \* consensus message afterwards. RMFault must be a subset of RM. An empty
  \* set means that all nodes are good in every possible behaviour.
  \* Examples: {0}
  \*           {1, 3}
  \*           {}
  RMFault,

  \* RMDead is a set of consensus node indexes that are allowed to die in the
  \* middle of every behaviour and do not send any message afterwards. RMDead
  \* must be a subset of RM. An empty set means that all nodes are alive and
  \* responding in in every possible behaviour. RMDead may intersect the
  \* RMFault set which means that node which is in both RMDead and RMFault
  \* may become FAULT and send any message starting from some step of the
  \* particular behaviour and may also die in the same behaviour which will
  \* prevent it from sending any message.
  \* Examples: {0}
  \*           {3, 2}
  \*           {}
  RMDead,

  \* MaxView is the maximum allowed view to be considered (starting from 0,
  \* including the MaxView itself). This constraint was introduced to reduce
  \* the number of possible model states to be checked. It is recommended to
  \* keep this setting not too high (< N is highly recommended).
  \* Example: 2
  MaxView

VARIABLES
  \* rmState is a set of consensus node states. It is represented by the
  \* mapping (function) with domain RM and range RMStates. I.e. rmState[r] is
  \* the state of the r-th consensus node at the current step.
  rmState,

 \* msgs is the shared pool of messages sent to the network by consensus nodes.
 \* It is represented by a subset of Messages set.
  msgs

\* vars is a tuple of all variables used in the specification. It is needed to
\* simplify fairness conditions definition.
vars == <<rmState, msgs>>

\* N is the number of validators.
N == Cardinality(RM)

\* F is the number of validators that are allowed to be malicious.
F == (N - 1) \div 3

\* M is the number of validators that must function correctly.
M == N - F

\* These assumptions are checked by the TLC model checker once at the start of
\* the model checking process. All the input data (declared constants) specified
\* in the "Model Overview" section must satisfy these constraints.
ASSUME
  /\ RM \subseteq Nat
  /\ N >= 4
  /\ 0 \in RM
  /\ RMFault \subseteq RM
  /\ RMDead \subseteq RM
  /\ Cardinality(RMFault) <= F
  /\ Cardinality(RMDead) <= F
  /\ Cardinality(RMFault \cup RMDead) <= F
  /\ MaxView \in Nat
  /\ MaxView <= 2

\* RMStates is a set of records where each record holds the node state and
\* the node current view.
RMStates == [
              type: {"initialized", "prepareSent", "commitSent", "cv", "blockAccepted", "bad", "dead"},
              view : Nat
            ]

\* Messages is a set of records where each record holds the message type,
\* the message sender and sender's view by the moment when message was sent.
Messages == [type : {"PrepareRequest", "PrepareResponse", "Commit", "ChangeView"}, rm : RM, view : Nat]

\* -------------- Useful operators --------------

\* IsPrimary is an operator defining whether provided node r is primary
\* for the current round from the r's point of view. It is a mapping
\* from RM to the set of {TRUE, FALSE}.
IsPrimary(r) == rmState[r].view % N = r

\* GetPrimary is an operator defining mapping from round index to the RM that
\* is primary in this round.
GetPrimary(view) == CHOOSE r \in RM : view % N = r

\* GetNewView returns new view number based on the previous node view value.
\* Current specifications only allows to increment view.
GetNewView(oldView) == oldView + 1

\* CountCommitted returns the number of nodes that have sent the Commit message
\* in the current round (as the node r sees it).
CountCommitted(r) == Cardinality({rm \in RM : Cardinality({msg \in msgs : msg.rm = rm /\ msg.type = "Commit" /\ msg.view = rmState[r].view}) /= 0})

\* MoreThanFNodesCommitted returns whether more than F nodes have been committed
\* in the current round (as the node r sees it).
MoreThanFNodesCommitted(r) == CountCommitted(r) > F

\* PrepareRequestSentOrReceived denotes whether there's a PrepareRequest
\* message received from the current round's speaker (as the node r sees it).
PrepareRequestSentOrReceived(r) == [type |-> "PrepareRequest", rm |-> GetPrimary(rmState[r].view), view |-> rmState[r].view] \in msgs

\* -------------- Safety temporal formula --------------

\* Init is the initial predicate initializing values at the start of every
\* behaviour.
Init ==
  /\ rmState = [r \in RM |-> [type |-> "initialized", view |-> 0]]
  /\ msgs = {}

\* RMSendPrepareRequest describes the primary node r broadcasting PrepareRequest.
RMSendPrepareRequest(r) ==
  /\ rmState[r].type = "initialized"
  /\ IsPrimary(r)
  /\ rmState' = [rmState EXCEPT ![r].type = "prepareSent"]
  /\ msgs' = msgs \cup {[type |-> "PrepareRequest", rm |-> r, view |-> rmState[r].view]}
  /\ UNCHANGED <<>>

\* RMSendPrepareResponse describes non-primary node r receiving PrepareRequest from
\* the primary node of the current round (view) and broadcasting PrepareResponse.
\* This step assumes that PrepareRequest always contains valid transactions and
\* signatures.
RMSendPrepareResponse(r) ==
  /\ \/ rmState[r].type = "initialized"
     \* We do allow the transition from the "cv" state to the "prepareSent" or "commitSent" stage
     \* as it is done in the code-level dBFT implementation by checking the NotAcceptingPayloadsDueToViewChanging
     \* condition (see
     \* https://github.com/nspcc-dev/dbft/blob/31c1bbdc74f2faa32ec9025062e3a4e2ccfd4214/dbft.go#L419
     \* and
     \* https://github.com/neo-project/neo-modules/blob/d00d90b9c27b3d0c3c57e9ca1f560a09975df241/src/DBFTPlugin/Consensus/ConsensusService.OnMessage.cs#L79).
     \* However, we can't easily count the number of "lost" nodes in this specification to match precisely
     \* the implementation. Moreover, we don't need it to be counted as the RMSendPrepareResponse enabling
     \* condition specifies only the thing that may happen given some particular set of enabling conditions.
     \* Thus, we've extended the NotAcceptingPayloadsDueToViewChanging condition to consider only MoreThanFNodesCommitted.
     \* It should be noted that the logic of MoreThanFNodesCommittedOrLost can't be reliable in detecting lost nodes
     \* (even with neo-project/neo#2057), because real nodes can go down at any time.
     \/ /\ rmState[r].type = "cv"
        /\ MoreThanFNodesCommitted(r)
  /\ \neg IsPrimary(r)
  /\ PrepareRequestSentOrReceived(r)
  /\ rmState' = [rmState EXCEPT ![r].type = "prepareSent"]
  /\ msgs' = msgs \cup {[type |-> "PrepareResponse", rm |-> r, view |-> rmState[r].view]}
  /\ UNCHANGED <<>>

\* RMSendCommit describes node r sending Commit if there's enough PrepareResponse
\* messages.
RMSendCommit(r) ==
  /\ \/ rmState[r].type = "prepareSent"
     \* We do allow the transition from the "cv" state to the "prepareSent" or "commitSent" stage,
     \* see the related comment inside the RMSendPrepareResponse definition.
     \/ /\ rmState[r].type = "cv"
        /\ MoreThanFNodesCommitted(r)
  /\ Cardinality({
                   msg \in msgs : /\ (msg.type = "PrepareResponse" \/ msg.type = "PrepareRequest")
                                  /\ msg.view = rmState[r].view
                 }) >= M
  /\ PrepareRequestSentOrReceived(r)
  /\ rmState' = [rmState EXCEPT ![r].type = "commitSent"]
  /\ msgs' = msgs \cup {[type |-> "Commit", rm |-> r, view |-> rmState[r].view]}
  /\ UNCHANGED <<>>

\* RMAcceptBlock describes node r collecting enough Commit messages and accepting
\* the block.
RMAcceptBlock(r) ==
  /\ rmState[r].type /= "bad"
  /\ rmState[r].type /= "dead"
  /\ PrepareRequestSentOrReceived(r)
  /\ Cardinality({msg \in msgs : msg.type = "Commit" /\ msg.view = rmState[r].view}) >= M
  /\ rmState' = [rmState EXCEPT ![r].type = "blockAccepted"]
  /\ UNCHANGED <<msgs>>

\* RMSendChangeView describes node r sending ChangeView message on timeout.
RMSendChangeView(r) ==
  /\ \/ (rmState[r].type = "initialized" /\ \neg IsPrimary(r))
     \/ rmState[r].type = "prepareSent"
  /\ LET cv == [type |-> "ChangeView", rm |-> r, view |-> rmState[r].view]
     IN /\ cv \notin msgs
        /\ rmState' = [rmState EXCEPT ![r].type = "cv"]
        /\ msgs' = msgs \cup {[type |-> "ChangeView", rm |-> r, view |-> rmState[r].view]}

\* RMReceiveChangeView describes node r receiving enough ChangeView messages for
\* view changing.
RMReceiveChangeView(r) ==
  /\ rmState[r].type /= "bad"
  /\ rmState[r].type /= "dead"
  /\ rmState[r].type /= "blockAccepted"
  /\ rmState[r].type /= "commitSent"
  /\ Cardinality({
                  rm \in RM : Cardinality({
                                            msg \in msgs : /\ msg.type = "ChangeView"
                                                           /\ msg.rm = rm
                                                           /\ GetNewView(msg.view) >= GetNewView(rmState[r].view)
                                         }) /= 0
                 }) >= M
  /\ rmState' = [rmState EXCEPT ![r].type = "initialized", ![r].view = GetNewView(rmState[r].view)]
  /\ UNCHANGED <<msgs>>

\* RMBeBad describes the faulty node r that will send any kind of consensus message starting
\* from the step it's gone wild. This step is enabled only when RMFault is non-empty set.
RMBeBad(r) ==
  /\ r \in RMFault
  /\ Cardinality({rm \in RM : rmState[rm].type = "bad"}) < F
  /\ rmState' = [rmState EXCEPT ![r].type = "bad"]
  /\ UNCHANGED <<msgs>>

\* RMFaultySendCV describes sending CV message by the faulty node r.
RMFaultySendCV(r) ==
  /\ rmState[r].type = "bad"
  /\ LET cv == [type |-> "ChangeView", rm |-> r, view |-> rmState[r].view]
     IN /\ cv \notin msgs
        /\ msgs' = msgs \cup {cv}
        /\ UNCHANGED <<rmState>>

\* RMFaultyDoCV describes view changing by the faulty node r.
RMFaultyDoCV(r) ==
  /\ rmState[r].type = "bad"
  /\ rmState' = [rmState EXCEPT ![r].view = GetNewView(rmState[r].view)]
  /\ UNCHANGED <<msgs>>

\* RMFaultySendPReq describes sending PrepareRequest message by the primary faulty node r.
RMFaultySendPReq(r) ==
  /\ rmState[r].type = "bad"
  /\ IsPrimary(r)
  /\ LET pReq == [type |-> "PrepareRequest", rm |-> r, view |-> rmState[r].view]
     IN /\ pReq \notin msgs
        /\ msgs' = msgs \cup {pReq}
        /\ UNCHANGED <<rmState>>

\* RMFaultySendPResp describes sending PrepareResponse message by the non-primary faulty node r.
RMFaultySendPResp(r) ==
  /\ rmState[r].type = "bad"
  /\ \neg IsPrimary(r)
  /\ LET pResp == [type |-> "PrepareResponse", rm |-> r, view |-> rmState[r].view]
     IN /\ pResp \notin msgs
        /\ msgs' = msgs \cup {pResp}
        /\ UNCHANGED <<rmState>>

\* RMFaultySendCommit describes sending Commit message by the faulty node r.
RMFaultySendCommit(r) ==
  /\ rmState[r].type = "bad"
  /\ LET commit == [type |-> "Commit", rm |-> r, view |-> rmState[r].view]
     IN /\ commit \notin msgs
        /\ msgs' = msgs \cup {commit}
        /\ UNCHANGED <<rmState>>

\* RMDie describes node r that was removed from the network at the particular step
\* of the behaviour. After this node r can't change its state and accept/send messages.
RMDie(r) ==
  /\ r \in RMDead
  /\ Cardinality({rm \in RM : rmState[rm].type = "dead"}) < F
  /\ rmState' = [rmState EXCEPT ![r].type = "dead"]
  /\ UNCHANGED <<msgs>>

\* Terminating is an action that allows infinite stuttering to prevent deadlock on
\* behaviour termination. We consider termination to be valid if at least M nodes
\* has the block being accepted.
Terminating ==
  /\ Cardinality({rm \in RM : rmState[rm].type = "blockAccepted"}) >= M
  /\ UNCHANGED <<msgs, rmState>>

\* Next is the next-state action describing the transition from the current state
\* to the next state of the behaviour.
Next ==
  \/ Terminating
  \/ \E r \in RM:
       RMSendPrepareRequest(r) \/ RMSendPrepareResponse(r) \/ RMSendCommit(r)
         \/ RMAcceptBlock(r) \/ RMSendChangeView(r) \/ RMReceiveChangeView(r)
         \/ RMDie(r) \/ RMBeBad(r)
         \/ RMFaultySendCV(r) \/ RMFaultyDoCV(r) \/ RMFaultySendCommit(r) \/ RMFaultySendPReq(r) \/ RMFaultySendPResp(r)

\* Safety is a temporal formula that describes the whole set of allowed
\* behaviours. It specifies only what the system MAY do (i.e. the set of
\* possible allowed behaviours for the system). It asserts only what may
\* happen; any behaviour that violates it does so at some point and
\* nothing past that point makes difference.
\*
\* E.g. this safety formula (applied standalone) allows the behaviour to end
\* with an infinite set of stuttering steps (those steps that DO NOT change
\* neither msgs nor rmState) and never reach the state where at least one
\* node is committed or accepted the block.
\*
\* To forbid such behaviours we must specify what the system MUST
\* do. It will be specified below with the help of fairness conditions in
\* the Fairness formula.
Safety == Init /\ [][Next]_vars

\* -------------- Fairness temporal formula --------------

\* Fairness is a temporal assumptions under which the model is working.
\* Usually it specifies different kind of assumptions for each/some
\* subactions of the Next's state action, but the only think that bothers
\* us is preventing infinite stuttering at those steps where some of Next's
\* subactions are enabled. Thus, the only thing that we require from the
\* system is to keep take the steps until it's impossible to take them.
\* That's exactly how the weak fairness condition works: if some action
\* remains continuously enabled, it must eventually happen.
Fairness == WF_vars(Next)

\* -------------- Specification --------------

\* The complete specification of the protocol written as a temporal formula.
Spec == Safety /\ Fairness

\* -------------- Liveness temporal formula --------------

\* For every possible behaviour it's true that eventually (i.e. at least once
\* through the behaviour) block will be accepted. It is something that dBFT
\* must guarantee (an in practice this condition is violated).
TerminationRequirement == <>(Cardinality({r \in RM : rmState[r].type = "blockAccepted"}) >= M)

\* A liveness temporal formula asserts only what must happen (i.e. specifies
\* what the system MUST do). Any behaviour can NOT violate it at ANY point;
\* there's always the rest of the behaviour that can always make the liveness
\* formula true; if there's no such behaviour than the liveness formula is
\* violated. The liveness formula is supposed to be checked as a property
\* by the TLC model checker.
Liveness == TerminationRequirement

\* -------------- ModelConstraints --------------

\* MaxViewConstraint is a state predicate restricting the number of possible
\* behaviour states. It is needed to reduce model checking time and prevent
\* the model graph size explosion. This formulae must be specified at the
\* "State constraint" section of the "Additional Spec Options" section inside
\* the model overview.
MaxViewConstraint == /\ \A r \in RM : rmState[r].view <= MaxView
                     /\ \A msg \in msgs : msg.view <= MaxView

\* -------------- Invariants of the specification --------------

\* Model invariant is a state predicate (statement) that must be true for
\* every step of every reachable behaviour. Model invariant is supposed to
\* be checked as an Invariant by the TLC Model Checker.

\* TypeOK is a type-correctness invariant. It states that all elements of
\* specification variables must have the proper type throughout the behaviour.
TypeOK ==
  /\ rmState \in [RM -> RMStates]
  /\ msgs \subseteq Messages

\* InvTwoBlocksAccepted states that there can't be two different blocks accepted in
\* the two different views, i.e. dBFT must not allow forks.
InvTwoBlocksAccepted == \A r1 \in RM:
                  \A r2 \in RM \ {r1}:
                  \/ rmState[r1].type /= "blockAccepted"
                  \/ rmState[r2].type /= "blockAccepted"
                  \/ rmState[r1].view = rmState[r2].view

\* InvFaultNodesCount states that there can be F faulty or dead nodes at max.
InvFaultNodesCount == Cardinality({
                                    r \in RM : rmState[r].type = "bad" \/ rmState[r].type = "dead"
                                 }) <= F

\* This theorem asserts the truth of the temporal formula whose meaning is that
\* the state predicates TypeOK, InvTwoBlocksAccepted and InvFaultNodesCount are
\* the invariants of the specification Spec. This theorem is not supposed to be
\* checked by the TLC model checker, it's here for the reader's understanding of
\* the purpose of TypeOK, InvTwoBlocksAccepted and InvFaultNodesCount.
THEOREM Spec => [](TypeOK /\ InvTwoBlocksAccepted /\ InvFaultNodesCount)

=============================================================================
\* Modification History
\* Last modified Mon Feb 27 16:46:19 MSK 2023 by root
\* Last modified Fri Feb 17 15:47:41 MSK 2023 by anna
\* Last modified Sat Jan 21 01:26:16 MSK 2023 by rik
\* Created Thu Dec 15 16:06:17 MSK 2022 by anna

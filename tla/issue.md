# dBFT 2.1 (solving 2.0 liveness lock)

### Summary or problem description

This issue is triggered by the dBFT 2.0 liveness lock problem mentioned in
https://github.com/neo-project/neo/issues/2029#issuecomment-725612388 and other
discussions in issues and PRs. We've used TLA+ formal modeling tool to analyze
dBFT 2.0 behaviour. In this issue we'll present the formal algorithm specification
with a set of identified problems and propose ways to fix them in so-called dBFT 2.1.

### dBFT 2.0 formal models

We've created two models of dBFT 2.0 algorithm in TLA+. Please, consider reading
the brief introduction to our modelling approach at
[the README](https://github.com/roman-khimov/dbft/tree/master/formal-models/README.md#dbft-formal-models)
and take a look at the [base model](https://github.com/roman-khimov/dbft/tree/master/formal-models/dbft/dbft.tla).
Below we present several error traces that were found by TLC Model Checker in the
four-nodes network scenario.

**Model checking note**

Please, consider reading the [model checking note](https://github.com/roman-khimov/dbft/tree/master/formal-models#model-checking-note)
before exploring the error traces below.

#### 1. Liveness lock with four non-faulty nodes

The TLA+ specification configuration assumes participating of the four non-faulty
replicas precisely following the dBFT 2.0 algorithm and maximum reachable view set to be 2.
Here's the model values configuration used for TLC Model Checker in the described scenario:

| RM           | RMFault | RMDead | MaxView |
|--------------|---------|--------|---------|
| {0, 1, 2, 3} | {}      | {}     | 2       |

The following liveness lock scenario was found by the TLC Model Checker:

<details>
<summary>Steps to reproduce the liveness lock</summary>

1. The primary (at view 0) replica 0 sends the `PrepareRequest` message.
2. The primary (at view 0) replica 0 decides to change its view (possible on timeout) and sends the `ChangeView` message.
3. The backup (at view 0) replica 1 receives the `PrepareRequest` of view 0 and broadcasts its `PrepareResponse`.
4. The backup (at view 0) replica 1 decides to change its view (possible on timeout) and sends the `ChangeView` message.
5. The backup (at view 0) replica 2 receives the `PrepareRequest` of view 0 and broadcasts its `PrepareResponse`.
6. The backup (at view 0) replica 2 collects `M` prepare messages (from itself and replicas 0, 1) and broadcasts the `Commit` message for view 0.
7. The backup (at view 0) replica 3 decides to change its view (possible on timeout) and sends the `ChangeView` message.
8. The primary (at view 0) replica 0 collects `M` `ChangeView` messages (from itself and replicas 1, 3) and changes its view to 1.
9. The backup (at view 0) replica 1 collects `M` `ChangeView` messages (from itself and replicas 0, 3) and changes its view to 1.
10. The primary (at view 1) replica 1 sends the `PrepareRequest` message.
11. The backup (at view 1) replica 0 receives the `PrepareResuest` of view 1 and sends the `PrepareResponse`.
12. The backup (at view 1) replica 0 decides to change its view (possible on timeout) and sends the `ChangeView` message.
13. The primary (at view 1) replica 1 decides to change its view (possible on timeout) and sends the `ChangeView` message.
14. The backup (at view 0) replica 3 collects `M` `ChangeView` messages (from itself and replicas 0, 1) and changes its view to 1.
15. The backup (at view 1) replica 3 receives `PrepareRequest` of view 1 and broadcasts its `PrepareResponse`.
16. The backup (at view 1) replica 3 collects `M` prepare message and broadcasts the `Commit` message for view 1.
17. The rest of undelivered messages eventually reaches their receivers, but it doesn't change the node's states.

Here's the [TLC error trace](./base_deadlock1_dl.txt) attached.

</details>

After the described sequence of steps we end up in the following situation:
 
| Replica | View | State                                                          |
|---------|------|----------------------------------------------------------------|
| 0       | 1    | `ChangeView` sent, in the process of changing view from 1 to 2 |
| 1       | 1    | `ChangeView` sent, in the process of changing view from 1 to 2 |
| 2       | 0    | `Commit` sent, waiting for the rest nodes to commit at view 0  |
| 3       | 1    | `Commit` sent, waiting for the rest nodes to commit at view 1  |

So we have the replica 2 stuck at the view 0 without possibility to exit from the commit
stage and without possibility to collect more `Commit` messages from other replicas.
We also have replica 3 stuck at the view 1 with the same problem. And finally, we have
replicas 0 and 1 entered the view changing stage and not being able either to commit (as
there's only `F` nodes that have been committed at the view 1) or to change view (as the
replica 2 can't send its `ChangeView` from the commit stage).

This liveness lock happens because the outcome of the subsequent consensus round (either
commit or do change view) completely depends on the message receiving order. Moreover,
we've faced with exactly this kind of deadlock in real functioning network, this incident
was fixed by the consensus nodes restarting.
 
#### 2. Liveness lock with one "dead" node and three non-faulty nodes

The TLA+ specification configuration assumes participating of the three non-faulty
nodes precisely following the dBFT 2.0 algorithm and one node which can "die" and stop sending
consensus messages or changing its state at any point of the behaviour. The liveness lock can
be reproduced both when the first primary node is able to "die" and when the non-primary node
is "dying" in the middle of the consensus process. The maximum reachable view set to be 2. 
Here are two model values configurations used for TLC Model Checker in the described scenario:

| RM           | RMFault | RMDead | MaxView |
|--------------|---------|--------|---------|
| {0, 1, 2, 3} | {}      | {0}    | 2       |
| {0, 1, 2, 3} | {}      | {1}    | 2       |


The following liveness lock scenario was found by the TLC Model Checker:

<details>
<summary>Steps to reproduce the liveness lock (first configuration with primary node "dying" is taken as an example)</summary>

1. The primary (at view 0) replica 0 sends the `PrepareRequest` message.
2. The primary (at view 0) replica is "dying" and can't send or handle any consensus messages further.
3. The backup (at view 0) replica 1 receives the `PrepareRequest` of view 0 and broadcasts its `PrepareResponse`.
4. The backup (at view 0) replica 1 decides to change its view (possible on timeout) and sends the `ChangeView` message.
5. The backup (at view 0) replica 2 receives the `PrepareRequest` of view 0 and broadcasts its `PrepareResponse`.
6. The backup (at view 0) replica 2 collects `M` prepare messages (from itself and replicas 0, 1) and broadcasts the `Commit` message for view 0.
7. The backup (at view 0) replica 3 decides to change its view (possible on timeout) and sends the `ChangeView` message.

Here's the TLC error traces attached:
 * [TLC error trace for the first configuration (primary is "dying")](./base_deadlock2_dl.txt)
 * [TLC error trace for the second configuration (non-primary is "dying")](./base_deadlock3_dl.txt)

</details>

After the described sequence of steps we end up in the following situation:
 
| Replica | View | State                                                          |
|---------|------|----------------------------------------------------------------|
| 0       | 0    | Dead (but `PrepareRequest` sent for view 0).                   |
| 1       | 0    | `ChangeView` sent, in the process of changing view from 0 to 1 |
| 2       | 0    | `Commit` sent, waiting for the rest nodes to commit at view 0  |
| 3       | 0    | `ChangeView` sent, in the process of changing view from 0 to 1 |

So we have the replica 0 permanently dead at the view 0 without possibility to affect
the consensus process. Replica 2 has its `Commit` sent and unsuccessfully waiting for
other replicas to enter the commit stage as far. Finally, replicas 1 and 3 have entered
the view changing stage and not being able either to commit (as there's only `F` nodes
that have been committed at the view 1) or to change view (as the replica 2 can't send
its `ChangeView` from the commit stage).

It should be noted that dBFT 2.0 algorithm is expected to guarantee the block acceptance
with at least `M` non-faulty ("alive" in this case) nodes, which isn't true in the
described situation.

#### 3. Running the TLC model checker with "faulty" nodes

Both models allow to specify the set of malicious nodes indexes via `RMFault` model
constant. "Faulty" nodes are allowed to send *any* valid message at *any* step of
the behaviour. At the same time, weak fairness is required from the next-state
action predicate for both models. It means if it's possible for the model to take
any non-stuttering step, this step must eventually be taken. Thus, running the
basic dBFT 2.0 model with single faulty and three non-faulty nodes doesn't reveal
any model deadlock: the malicious node keeps sending messages to escape
from the liveness lock. It should also be noticed that the presence of faulty
nodes slightly increases the states graph size, so that it takes more time to
evaluate the whole set of possible model behaviours.

Nethertheless, it's a thought-provoking experiment to check the model specification
behaviour with non-empty faulty nodes set. We've checked the basic model with the
following configurations and didn't find any liveness lock:

| RM           | RMFault | RMDead | MaxView |
|--------------|---------|--------|---------|
| {0, 1, 2, 3} | {0}      | {}    | 2       |
| {0, 1, 2, 3} | {1}      | {}    | 2       |

### dBFT 2.1 proposed models

Based on the liveness issues found by the TLC Model Checker we've developed a couple
of ways to improve dBFT 2.0 algorithm and completely avoid mentioned liveness and
safety problems. The improved models will further be referred to as dBFT 2.1 models.
Please, consider reading the dBFT 2.1 models description at
[the README](https://github.com/roman-khimov/dbft/tree/master/formal-models/README.md#proposed-dbft-21-models)
and check the models TLA+ specifications.

We believe that proposed models allow to solve the liveness lock problems. Anyone
who has thoughts, ideas, questions, suggestions or doubts is welcomed to join the
discussion. The proposed specifications may have bugs or inaccuracies thus we
accept all kinds of reasoned comments and related feedback. If you have troubles
with the models understanding/editing/checking, please, don't hesitate to write a
comment to this issue.

### Further work

The whole idea of TLA+ dBFT modelling was to reveal and avoid the liveness lock
problems so that we've got a normally operating consensus algorithm in our
network. There are several directions for the further related work in our mind:

1. Collect and process the community feedback on proposed TLA+ dBFT 2.0 and 2.1
  specifications, fix the models (in case of any bugs found).
2. Implement the improved dBFT 2.1 algorithm at the code level.
3. Create TLA+ specification and investigate any potential problems of the dBFT 3.0
  (double speaker model, https://github.com/neo-project/neo/issues/2029).
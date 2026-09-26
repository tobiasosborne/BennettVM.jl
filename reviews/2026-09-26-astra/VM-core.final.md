The VM core needs correctness fixes: **15 findings, including five S0 defects**, all backed by execution. Accepted programs lose byte data, copy zeros from ROM, and alias distinct allocations while full round-trip checks pass. An L2 inverse also loses stored-zero cells, masked by later replay.

Eighteen selected test files passed **2,657 assertions**; **1,321,490 independent arithmetic cases** matched their oracle. Non-vacuous trapped-program reversal was confirmed. No full suite or source changes were made.

- **F1 [S0]** Mixed-width memory accesses silently discard bytes or read the wrong cell.
- **F2 [S0]** Callee static allocations clobber caller dynamic allocations.
- **F3 [S0]** Bulk copies silently replace global ROM data with zeros.
- **F4 [S0]** MemoryAssignment’s empty delta loses explicitly stored zero cells.
- **F5 [S0]** Unchecked allocation arithmetic crosses address tiers and wraps cursors.
- **F6 [S1]** Libc memset/memcpy/memmove calls discard their return pointers.
- **F7 [S1]** initial_state rejects half the UInt64 input domain.
- **F8 [S1]** Allocation validation depends on delta-recording policy.
- **F9 [S1]** The injectivity trait certifies destructive phi-edge overwrites.
- **F10 [S1]** Memory accesses lack allocation-provenance bounds checks.
- **F11 [S2]** Failed steps can leave state and counters mutated.
- **F12 [S2]** History equality breaks for ordinary map and return deltas.
- **F13 [S2]** Finite checkpoint intervals can miss every checkpoint indefinitely.
- **F14 [S2]** The per-step reversal test scaffold loops forever after traps.
- **F15 [S3]** The width-64 compatibility test compares the implementation with itself.
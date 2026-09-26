19 findings: **7 S0, 10 S1, 2 S2**; 17 have executed evidence, two are static audits. All seven silent-failure cases reversed cleanly despite incorrect forward behavior. The property gate accepted a demonstrated wrong result, and its determinism checker equated programs returning 1 and 999.

Eleven selected test files passed **2,002 assertions**; no full suite was run. Parallel φ swaps, three-way joins, modern recursive calls and heap-literal certification passed focused checks. The report specifies fixes, regression tests and coverage limits.

- **F1 [S0]** Narrow negative GEP indices become positive offsets.
- **F2 [S0]** Loop-executed static allocas alias earlier allocations.
- **F3 [S0]** Dropped map-key widths split equivalent keys.
- **F4 [S0]** Intrinsic name dispatch replaces supplied function bodies.
- **F5 [S0]** Duplicated globals break cross-function pointer identity.
- **F6 [S0]** Generated register names overwrite legal input names.
- **F7 [S0]** Legacy `CallInstruction` silently skips calls.
- **F8 [S1]** The Float32 guard rejects integer Int32 calls.
- **F9 [S1]** Digest stripping breaks Unicode function names.
- **F10 [S1]** Constant conditional branches crash during lowering.
- **F11 [S1]** Scalar literal returns remain unsupported.
- **F12 [S1]** Globals referenced only through φ inputs or terminators remain uninitialized.
- **F13 [S1]** Aggregate φ/select values cannot propagate through lowering.
- **F14 [S1]** `IRInsertBits` lowering depends on physical block order.
- **F15 [S1]** Arithmetic assignments accept aliases their history cannot recover.
- **F16 [S1]** Random-program tests lack an independent forward oracle.
- **F17 [S1]** The determinism checker accepts semantically different programs.
- **F18 [S2]** Random “looping” tests contain no back-edges.
- **F19 [S2]** Coverage documentation contradicts shipped ingestion.
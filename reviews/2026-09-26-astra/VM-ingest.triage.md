# Triage — VM-ingest — 2026-09-26

Orchestrator triage of `VM-ingest.md` after independent re-execution of F1–F17
(`VM-ingest.verification.md`: 16 CONFIRMED, F15 PARTIAL; F7/F11/F13/F14/F15/F17 downgraded on reachability).
Real-Julia-reachable silent miscompile: F4 (user function named like an intrinsic is replaced by the intrinsic).

| Finding | Sev | Disposition |
|---|---|---|
| F1 narrow negative GEP index read as positive offset (real .ll) | S0 | bennettvm-zkhl (P1) |
| F3 map key/value widths dropped (hand-built; recogniser refuses isbits keys today) | S0 | bennettvm-r18l (P2) |
| F4 bare-name intrinsic dispatch replaces a supplied function body — user malloc → IntrinsicMalloc (REAL JULIA) | S0 | bennettvm-wtda (P1) |
| F5 shared global duplicated per function, pointer identity broken (real .ll) | S0 | bennettvm-190z (P1) |
| F8 Float32 guard rejects Int32 calls (real Julia) | S1 | bennettvm-8yne (P2) |
| F9 digest stripping breaks on trailing multibyte char (real Julia) | S1 | bennettvm-07kz (P2) |
| F10 constant conditional branch / identical-successor branch crashes lowering (real .ll) | S1 | bennettvm-nast (P2) |
| F12 globals referenced only via phi/terminator never initialised; ret @G returns no key | S1/S2 | bennettvm-ewob (P2) |
| F13 aggregate phi/select refused (coverage gap) | S2 | bennettvm-t8ql (P3) |
| F14 IRInsertBits chain depends on block order (unreachable today) | S2/S3 | bennettvm-filw (P3) |
| F16 property gate has no independent forward oracle (accepted 2 vs oracle 11) | S1/S2 | bennettvm-tghl (P2) |
| F2 loop-executed static alloca aliases live allocations (hand-built) | S0 | OVERLAPS bennettvm-347o (note: refutes its L3-soundness claim) |
| F6 generated _phi_const_* names overwrite legal input names (no frontend produces) | S0 | OVERLAPS bennettvm-3ah (note) |
| F7 legacy CallInstruction silently skips calls (hand-built VMProgram only) | S1/S2 | OVERLAPS bennettvm-xo2v (note) |
| F11 scalar literal returns refused (deliberate) | S2 | DUPLICATE → bennettvm-cw4g (note) |
| F15 ArithmeticAssignment inverse alias corruption (ingest never emits it; partial) | S2 | related bennettvm-6xy0 / ack; no bead |
| F17 determinism checker types-only | S2 | DUPLICATE → bennettvm-jpb (note) |
| F18 random looping tests have no back-edges | S2 | not filed (S2 test-quality; see report) |
| F19 coverage docs contradict shipped ingestion | S2 | not filed (fold into docs pass) |

All new beads carry label `astra-2026-09-26` and `discovered-from:bennettvm-b1e5`.

# Triage — VM-core — 2026-09-26

Orchestrator triage of `VM-core.md` after independent re-execution of F1–F10
(`VM-core.verification.md`: all 10 CONFIRMED; F4 downgraded S0→S2 — loads read an absent
cell as 0, so no output is ever wrong; F5 borderline S0/S1, the calloc overflow carries it).

| Finding | Sev (final) | Bead |
|---|---|---|
| F1 mixed-width accesses accepted, bytes discarded / wrong cell read | S0 | bennettvm-aul4 (P1) |
| F2 callee static alloca clobbers caller dynamic allocation | S0 | bennettvm-hyi6 (note added, P2→P1) |
| F3 bulk copy from ROM source copies zeros | S0 | bennettvm-gn6o (P1) |
| F4 MemoryAssignment inverse loses stored-zero presence | S2 | bennettvm-7ix4 (P3) |
| F5 unchecked allocation arithmetic crosses tiers / wraps cursors | S0/S1 | bennettvm-av72 (P1) |
| F6 libc memset/memcpy/memmove return pointer discarded → unbound SSA crash | S1 | bennettvm-9ktb (P2) |
| F7 initial_state rejects UInt64 with top bit set; accepts Float64 1.0 | S1 | bennettvm-0agz (P2) |
| F8 allocation validity depends on delta-recording policy | S1 | bennettvm-o68a (P2) |
| F9 injectivity trait certifies destructive phi-edge overwrites | S1 | bennettvm-6xy0 (P2) |
| F10 accesses outside the originating allocation accepted | S1 | bennettvm-pdqx (note added; description corrected: three cursors, no region table) |
| F11 step! raises after mutating state | S2 | bennettvm-66z8 (P2) |
| F12 DeltaEntry/RState equality broken | S2 | bennettvm-usw3 (P3) |
| F13 periodic checkpointing can starve forever at default K | S2 | bennettvm-4x29 (P2) |
| F14 per-step reversal scaffolds loop forever after a trap | S2 | bennettvm-r2r0 (P2) |
| F15 width-64 masking test compares implementation with itself | S3 | bennettvm-hgkq (P3) |

Campaign bead (this repo): bennettvm-b1e5. All new beads carry label `astra-2026-09-26`.

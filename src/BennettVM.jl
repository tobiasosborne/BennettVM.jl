"""
    BennettVM

Reversible-VM backend for [Bennett.jl](https://github.com/tobiasosborne/Bennett.jl).

# What this is

Bennett.jl compiles Julia functions to a *fixed reversible circuit*
(`target = :circuit`) — the right artifact for a quantum oracle, but it
cannot represent unbounded loops or runtime-sized memory. BennettVM is
the second lowering target (`target = :reversible_vm`) that closes that
gap: a reversible interpreter for terminating computations of
statically-unknown length.

The two backends are semantically distinct (PRD v4 §3.7) and stay
distinct. BennettVM is not a fork of Bennett.jl, not a replacement for
the circuit backend, and not an extension of it.

# Motivating cases (PRD v4 §3.6.2)

Four Julia functions chosen because Bennett.jl's circuit backend cannot
compile them. Phase-2 success criterion SC9 demands round-trip behavior
under `target = :reversible_vm`.

  * **Case A — Dict-as-reversible-map** (`fdict`). Statically-bounded
    insert/delete sequence into a `Dict{Int8,Int8}`. Requires the
    persistent-tree reversible heap from Bennett.jl plus a reversible
    Dict view layered over it.
  * **Case B — dynamic-size loop body** (`frtN`). Loop count known
    only at runtime. Requires a per-iteration delta log.
  * **Case C — nested loops** (`matrix_sum`). Two-level loop where the
    inner-loop history must be erased reversibly at each outer step.
  * **Case D — unbounded `while`** (`collatz_steps`). Termination
    proven by external argument, not by `max_loop_iterations`. The
    load-bearing case: SC9 Case D is the gate before any Phase-2
    target-dispatch arm lands in Bennett.jl (PRD v4 §3.7 Handoff B).

If SC9 fails on any of the four, BennettVM has no reason to exist
(PRD v4 §6 SC9).

# Phase

Phase 2 (production). The Phase-0 throwaway spike lives under `spike/`
and is `chmod -w`; no code from the spike is promoted here. Phase 2
starts from an empty `src/` and `test/` tree and builds from the
RC3-grounded RSSA design captured in
[`docs/adr/0001-rc3-rvm-smoke.md`](../docs/adr/0001-rc3-rvm-smoke.md).
The 12-instruction RSSA taxonomy and the eight Phase-2 decisions are
locked in that ADR's §Observations.

# Status

`v0.1.0-dev`. **M0.1 — package skeleton only.** No instructions, no
interpreter, no history layer, no Bennett.jl ingest yet. Subsequent
milestones (M0.2–M0.4, then M2.x) populate this module.
"""
module BennettVM

# Currently empty — populated by M0.2 (lower_vm stub) and M2.x
# (IR types). Each addition lands as its own atomic commit with a
# closed bd issue; this docstring is the durable index.

end # module BennettVM

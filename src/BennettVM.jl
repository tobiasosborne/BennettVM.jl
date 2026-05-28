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

# Bennett.jl is consumed *by type only* through `Bennett.ParsedIR`
# (Handoff A; PRD v4 §3.7; Rule 14). `import` (not `using`) keeps the
# dependency surface explicit: every reference to upstream Bennett.jl
# names in this package appears as `Bennett.<Name>`, making the
# Handoff-A contract visually auditable.
import Bennett

# M2.1 — interpreter state atom (`bennettvm-e7o`). Not yet exported;
# the public API surface stabilises in a later bead.
include("ir/IState.jl")
# M2.3 — history-bearing reversible-execution wrapper around `IState`
# (`bennettvm-teu`). Depends on `IState`, so MUST follow `IState.jl`
# in include order. Not yet exported.
include("ir/RState.jl")
# M4.1 — L3 history entry: `CheckpointEntry <: AbstractHistoryEntry`
# (`bennettvm-v1t`). Periodic full-state `IState` snapshot + step
# index, the safety-net layer of the PRD v4 §3.3 three-layer history
# scheme. Depends on `IState` (the snapshot field type, from
# `ir/IState.jl`) and `AbstractHistoryEntry` (the supertype, defined
# in `ir/RState.jl`), so MUST follow both in include order. The push-
# every-K-steps gating that makes this "periodic" (and therefore not
# the prohibited full-per-step-snapshot mechanism) lives in M4.2's
# `step!` modification, not in this file. Not yet exported.
include("history/CheckpointEntry.jl")
# M2.4 — dispatch skeleton: abstract `Instruction` / `ControlInstruction`
# / `RValue` plus generic `forward` / `inverse` fallbacks
# (`bennettvm-qkd`). Depends on `IState` (used in fallback error
# messages) so MUST follow `IState.jl`. Concrete instruction subtypes
# land at M2.7-M2.14. Not yet exported.
include("ir/instructions.jl")
# M2.5 — canonical BinaryOperator symbol set (`bennettvm-msl`). Defines
# `BINARY_OPERATORS` (integer / bitwise / shift / divrem opcode symbols,
# mirroring Bennett.jl's `_IR_BINOP_OPS`), `FP_BINARY_OPERATORS` (the
# four IEEE-754 ops that arrive as `IRCall` to SoftFloat wrappers, NOT
# as `IRBinOp`), their union `ALL_BINARY_OPERATORS`, and the
# `is_binary_operator` predicate used by `ArithmeticAssignment`'s
# constructor (M2.7) to reject typos at construction time. Also defines
# `COMPARISON_OPERATORS` (the LLVM `icmp` predicates, mirroring
# Bennett.jl's `_IR_ICMP_PREDS`; ADR 0012 §D2) and `is_comparison_operator`
# — a set disjoint from the arithmetic union, evaluated by `_apply_binop`
# but NOT accepted by the `ArithmeticAssignment` constructor. Depends on
# nothing in this module; ordered after `instructions.jl` because its
# downstream consumer is the `ArithmeticAssignment` concrete subtype.
# Not yet exported.
include("ir/operators.jl")
# M2.6 — first concrete RSSA instruction: `ArithmeticAssignment`
# (`bennettvm-lff`). Implements RC3's `x := y ⊕ (lhs op rhs)` form with
# the three-element modop set {:xor, :add, :sub} locked in ADR 0001.
# Depends on `Instruction` (from `instructions.jl`), `IState` (from
# `IState.jl`), and `BINARY_OPERATORS` / `is_binary_operator` (from
# `operators.jl`), so MUST follow all three. Not yet exported.
include("ir/arithmetic_assignment.jl")
# M2.7 — second concrete RSSA instruction: `SwapInstruction`
# (`bennettvm-ti3`). Implements RC3's four-field `x, y := z, w`
# register-exchange form (ADR 0001 §Observations row 2). The
# prototypical injective instruction — self-inverse via
# target↔source swap, no history record needed (PRD v4 §3.2).
# Depends on `Instruction` (from `instructions.jl`) and `IState`
# (from `IState.jl`); MUST follow both. Not yet exported.
include("ir/swap_instruction.jl")
# M2.8 — first two concrete control-flow instructions: `BeginInstruction`
# and `EndInstruction` (`bennettvm-n3c`). Rows 7 and 8 of the ADR 0001
# §Observations RSSA dispatch table — subroutine entry / exit markers
# (RC3 `begin l(x,...)` / `end l(y,...)`). Parameter / return-value
# transfer is `CallInstruction`'s job (M2.14); these markers reduce, at
# the dispatch layer, to pc bumpers carrying the label + signature as
# metadata. Depends on `ControlInstruction` (from `instructions.jl`,
# M2.4) and `IState` (from `IState.jl`, M2.1); MUST follow both. Not
# yet exported.
#
# M2.9 — next two concrete control-flow instructions, defined in the
# SAME file by intentional cohesion: `UnconditionalEntry` and
# `UnconditionalExit` (`bennettvm-08q`). Rows 9 and 10 of the ADR 0001
# §Observations RSSA dispatch table — basic-block entry / exit
# markers (RC3 `l(x,...) <-` / `-> l(y,...)`). These are the block-
# level analogues of the M2.8 subroutine markers; see the M2.9 block
# docstring in `control_instructions.jl` for the bead-vs-ADR
# reconciliation (the bead text mis-cited BobISA source-label
# encoding; the ADR decision-table row "Source-label jumps" is NO,
# Mogensen-RSSA paired entry/exit). Cross-block dispatch via
# `LabelTable` lands in M3.x's interpreter.
include("ir/control_instructions.jl")
# M2.11 — first concrete memory instruction: `MemoryAssignment`
# (`bennettvm-jew`). Row 3 of the ADR 0001 §Observations RSSA dispatch
# table — RC3's `M[addr] ⊕= (lhs op rhs)` in-place memory-update form.
# Depends on `Instruction` (from `instructions.jl`), `IState` (from
# `IState.jl` — including the `memory::Dict{Int64,Int64}` field added
# in this same milestone), `BINARY_OPERATORS` / `is_binary_operator`
# (from `operators.jl`), and the operand-helper functions `_resolve`,
# `_apply_binop`, `_apply_modop`, `dual_modop` (from
# `arithmetic_assignment.jl`, reused per Law 2 rather than reinvented).
# MUST follow all of them in include order. Not yet exported.
include("ir/memory_instructions.jl")
# M2.14 — sixth concrete RSSA instruction: `CallInstruction`
# (`bennettvm-dp1`). Row 6 of the ADR 0001 §Observations RSSA dispatch
# table — RC3's `(x,...) := call/uncall l(y,...)` procedure-call form,
# unified across the `:call` / `:uncall` directions under a single
# struct with a `direction::Symbol` field (Structural-Pattern point 4
# / decision-table row "Call/Uncall unification"). At this dispatch
# layer the instruction is pc-only (matches the M2.8 / M2.9 / M2.10
# control-flow-marker template); the recursive sub-execution lands in
# M3.x once VMProgram (M2.17) and the LabelTable (M2.16) exist. The
# `effective_call_direction` helper documents the XOR-of-directions
# semantics here so the rationale lives alongside the data. Depends on
# `Instruction` (from `instructions.jl`) and `IState` (from
# `IState.jl`); MUST follow both. Not yet exported.
include("ir/call_instruction.jl")
# M_UNBOUNDED (ADR 0012 §D1) — `Define`, the reversible SSA-create
# instruction (`bennettvm-d3p`). LLVM `IRBinOp` / `IRICmp` lower to a
# `Define` (`target := lhs op rhs`) whose operands are READ, never
# destroyed — the non-destructive create `ArithmeticAssignment` (a
# destructive transform) cannot express. Reuses `_resolve` /
# `_apply_binop` (from `arithmetic_assignment.jl`, Law 2) and the
# `is_binary_operator` / `is_comparison_operator` op-domain predicates
# (from `operators.jl`), so MUST follow both in include order. Its `op`
# domain is `BINARY_OPERATORS ∪ COMPARISON_OPERATORS` — `Define` is the
# create that legitimately carries comparisons (ADR 0012 §D2). Classified
# NON-injective (`is_injective(::Type{Define}) = false`, wired in
# `history/Injective.jl`, which MUST follow this include): in a loop the
# same SSA name is redefined each iteration, so a `Define` may overwrite
# a prior value; the static trait can't see runtime freshness, so it is
# conservatively `false` (Rule 1) and the M6.2/M7.6 push gate emits L3
# checkpoints around it. Its per-instruction `inverse()` is NOT on the L3
# replay path and is deferred (raises descriptively, the
# `CallInstruction` pattern). Not yet exported.
include("ir/define_instruction.jl")
# M_UNBOUNDED (ADR 0012 §D3) — `SelectInstruction`, the reversible 2-to-1
# multiplexer (`bennettvm-8wj`). LLVM `IRSelect` lowers to a
# `SelectInstruction` (`target := (cond != 0) ? val_true : val_false`)
# whose predicate and arms are READ, never destroyed — the structural
# sibling of `Define` (the non-destructive SSA-create, §D1). LLVM `select`
# has no RC3 analogue (documented Law-2 exception: it arises from Julia
# ternaries; Janus/RC3 source has none). Reuses `_resolve` (from
# `arithmetic_assignment.jl`, Law 2), so MUST follow it in include order;
# placed right after `define_instruction.jl` (its template) and BEFORE
# `history/Injective.jl` (which pins its trait). `val_true` / `val_false`
# are `Union{Symbol,Int64}` because collatz's `or.cond` true-arm is the
# literal `Const(-1)`. Classified NON-injective
# (`is_injective(::Type{SelectInstruction}) = false`, wired in
# `history/Injective.jl`): a 2-to-1 MUX discards the unselected arm, and in
# a loop the same SSA name is redefined each iteration, so a select may
# overwrite a prior value; the static trait can't see runtime freshness, so
# it is conservatively `false` (Rule 1) and the M6.2/M7.6 push gate emits
# L3 checkpoints around it. Its per-instruction `inverse()` is NOT on the L3
# replay path and is deferred (raises descriptively, the `Define` /
# `CallInstruction` pattern). Not yet exported.
include("ir/select_instruction.jl")
# M_OPCODE (ADR 0013 §D-5 step 1, ADR 0012 §D1 template) —
# `CastInstruction`, the reversible width-cast SSA-create
# (`bennettvm-hek`). LLVM `IRCast` (`sext` / `zext` / `trunc`) lowers to a
# `CastInstruction` (`target := cast(op, operand)`) whose single operand
# is READ, never destroyed — the non-destructive create analogue of
# `Define` for width casts, the remaining frontend-reachable non-memory
# body-instruction gap (`docs/coverage-matrix.md` row 6). Reuses `_resolve`
# (from `arithmetic_assignment.jl`, Law 2), so MUST follow it in include
# order; placed right after `select_instruction.jl` (its sibling create)
# and BEFORE `history/Injective.jl` (which pins its trait). The `op` domain
# is the three-element IRCast set `{:sext, :zext, :trunc}` (Bennett.jl
# `_IR_CAST_OPS`), disjoint from `BINARY_OPERATORS`, so it carries its own
# width-aware `_apply_cast` rather than routing through `_apply_binop`.
# Classified NON-injective (`is_injective(::Type{CastInstruction}) = false`,
# wired in `history/Injective.jl`): `:trunc` is lossy and in a loop the same
# SSA name is redefined each iteration, so a cast may overwrite a prior
# value; the static trait can't see runtime freshness, so it is
# conservatively `false` (Rule 1) and the M6.2/M7.6 push gate emits L3
# checkpoints around it. Its per-instruction `inverse()` is NOT on the L3
# replay path and is deferred (raises descriptively, the `Define` /
# `SelectInstruction` pattern). Not yet exported.
include("ir/cast_instruction.jl")
# M6.1 — `is_injective` trait (`bennettvm-9hf`). The L1 "no-log"
# layer-1 predicate of PRD v4 §3.3: tells the rest of the VM whether
# an instruction needs a history entry. Type-level `true` for the
# eight invariant injective cases (`SwapInstruction`,
# `BeginInstruction`, `EndInstruction`, `UnconditionalEntry`/`Exit`,
# `ConditionalEntry`/`Exit`, `MemoryInterchange`, `MemorySwap`);
# value-level `true` for `ArithmeticAssignment` iff `modop === :xor`;
# default `false` everywhere else (conservative — forces M6.2's
# `step!` to push when the trait is uncertain, per CLAUDE.md
# Rule 1). MUST follow every M2.6-M2.14 include because the
# specialisations dispatch on the concrete `Instruction` subtypes
# defined there. M6.2 (interpreter integration), M6.3 (golden-
# master regression test), and M6.4 (per-instruction `unstep!`
# short-circuit) consume this trait; M6.1 itself does NOT modify
# `step!`, `inverse`, or the round-trip path. Not yet exported —
# M6.2 decides the public-API surface.
include("history/Injective.jl")
# M7.2 — L2 history entry: `DeltaEntry{T<:Instruction} <:
# AbstractHistoryEntry` (`bennettvm-c4m`). The "delta with min-cut
# selection" layer of PRD v4 §3.3's three-layer history scheme: for
# non-injective instructions in deterministic regions, the entry
# carries the minimal payload needed to invert one forward step
# (Enzyme-style cache analysis ported to BennettVM's RSSA IR per
# ADR 0002). Parametric on the instruction type so the per-`T`
# `make_delta` constructors (M7.3) and `inverse(::T, s, payload::
# NamedTuple)` specialisations (M7.4) dispatch without `Any`-routing.
# Depends on `AbstractHistoryEntry` (the supertype, defined in
# `ir/RState.jl`) and `Instruction` (the abstract parent of `T`,
# defined in `ir/instructions.jl`), so MUST follow both in include
# order. M7.2 is type definition only — per-instruction
# `make_delta` lives co-located with `forward`/`inverse` per ADR
# 0002 Design Decision 3 and lands at M7.3; the push-site wiring
# into `step!` is M7.6's job. Not yet exported (M7.6 settles the
# public-API surface).
include("history/delta.jl")
# M2.15 — `BasicBlock` + `reversed(::BasicBlock)` (`bennettvm-jvh`). The
# unit of RSSA program structure: a single straight-line code segment
# bracketed by exactly one control-flow entry marker and exactly one
# control-flow exit marker. Adds `structural_inverse(::Instruction)`
# (the IR-graph-level instruction inverse, distinct from
# `inverse(::Instruction, ::IState, prev)`) at module level for the six
# non-control instruction subtypes, and inlines the block-label-aware
# entry/exit rewrites (`_reverse_entry_to_exit` / `_reverse_exit_to_entry`)
# for the six control-flow subtypes. MUST follow every M2.6-M2.14
# include because the constructors and `structural_inverse` methods
# dispatch on the concrete `Instruction` subtypes defined there. Not
# yet exported (callers go through `BennettVM.BasicBlock` / `.reversed`
# until the public API stabilises at a later bead).
include("ir/basic_block.jl")
# M2.16 — dual-address label table: `LabelEntry` + `LabelTable`
# (`bennettvm-vab`). RC3 `LabelEntry.java:7` port. The structural data
# carrier that lets RSSA control flow reverse WITHOUT a history tape
# (PRD v4 §3.1, §3.2): per block label, store both the forward arrival
# address (entry-instruction index in the flat stream) and the
# backward arrival address (exit-instruction index). MUST follow
# `basic_block.jl` because `LabelTable(::Vector{BasicBlock})` scans
# block bodies to compute the `1 + length(body) + 1` per-block
# instruction count. Consumed by `VMProgram` at M2.17. Not yet
# exported.
include("ir/label_table.jl")
# M2.17 — the real `VMProgram` (`bennettvm-tot`). Replaces the M0.2
# digest stub; now references `BasicBlock` (M2.15) and `LabelTable`
# (M2.16), so MUST follow both in include order. Defines
# `n_instructions(::VMProgram)` (top-level) and overloads
# `Base.length` / `Base.show` for the new shape. The M0.2 convenience
# constructor `VMProgram(arg_widths, return_widths)` is preserved as
# the bridge that lets `lower_vm` (still a digest stub) produce a
# typed `VMProgram` value while M3.x is pending.
include("ir/VMProgram.jl")
# M7.5 — stub liveness / min-cut analysis (`bennettvm-46p`). The L2
# layer's "which instructions need a DeltaEntry?" pre-computation,
# operationalising PRD v4 §3.3 layer 2 ("delta entries with min-cut
# selection") and Moses–Churavy 2020 §2 "Cache" per ADR 0002.
# Returns a `Set{Tuple{Symbol, Int}}` of `(block_label, instr_idx)`
# pairs whose forward steps must push a `DeltaEntry`. The stub is
# conservative: every non-injective instruction (per M6.1's
# `is_injective` trait) is included; the true min-cut tightening is
# deferred per ADR 0002 §"What M7.5 ships". MUST follow
# `history/Injective.jl` (consumes `is_injective`) and `ir/VMProgram.jl`
# (consumes the `VMProgram` type / its `blocks` field). M7.6 (bead
# `bennettvm-7e7`) consumes this analysis at the `step!` push site;
# M7.5 itself does NOT modify `VMProgram`, `step!`, or the round-trip
# path. Not exported — internal-access only until M7.6 settles the
# public-API surface.
include("analysis/liveness.jl")
# M_UNBOUNDED.1 (ADR 0012 §D1–D5) — the real `ParsedIR` → `VMProgram`
# ingest pass (`bennettvm-c39`). Translates a Bennett.jl `ParsedIR`
# (a CFG of `IRBasicBlock`s over the six IRInst types) into a runnable
# `VMProgram`: φ-nodes become block params (Mogensen RSSA §3), branch
# edges are critical-edge-split into trampoline blocks so each edge owns
# its own φ-arg list, constant φ-incomings are materialised via synthetic
# `Define`s, and the routine is framed by Begin/End. MUST follow every IR
# include it emits — `Define` / `SelectInstruction` (the create
# instructions), the six `ControlInstruction` subtypes
# (`control_instructions.jl`), `BasicBlock` / `LabelTable` / `VMProgram`,
# and the operand predicates — and MUST precede `lower_vm.jl`, which is
# now a thin wrapper over `_lower_parsed_ir`. Forward-only correctness is
# the gate; the round-trip is the L3 checkpoint-replay layer's job
# (ADR 0012 "cross-iteration crux"). Not separately exported — reached
# through `lower_vm`.
include("ir/ingest.jl")
include("lower_vm.jl")
# M3.1 — `initial_state(prog, input)` (`bennettvm-afj`). Gateway to the
# forward-only interpreter milestone (M3). Consumes a `VMProgram`
# (M2.17), reads the entry block's `fwd_address` via `LabelTable`
# lookup (M2.16), and constructs an `RState` wrapping a fresh `IState`
# whose `locals` are populated from `input`. MUST follow every M2.x
# include because it touches `VMProgram` / `LabelTable` / `BasicBlock` /
# `BeginInstruction` / `IState` / `RState` / `AbstractHistoryEntry`
# simultaneously. Exported so tests and the future M3.x dispatch loop
# can call it as `BennettVM.initial_state(...)` or via `using BennettVM`.
#
# M3.2 — `is_halted(s)` / `result(s)` accessors (`bennettvm-3ch`). Live
# in the same file as `initial_state` (they are the matching terminal
# accessors to its initial accessor); `is_halted` is the `run!` loop
# terminator predicate, `result` extracts a defensive copy of the
# halted locals dict with descriptive Rule-1 raise on non-halted
# state. Exported alongside `initial_state`.
#
# M3.3 — `step!(s, prog)` single-instruction dispatch (`bennettvm-1hn`).
# Forward-only at this milestone: resolves the instruction at the
# current pc via the private `_instruction_at` flat-stream walker,
# dispatches to the per-subtype `forward` method (M2.6–M2.14), and
# transitions status to `:halted` on `EndInstruction`. No history push
# yet — that arrives at M4, AFTER forward, per the spike Q3 ordering
# lesson documented in this function's docstring. Exported alongside
# `initial_state` / `is_halted` / `result`.
#
# M3.4 — `run!(s, prog; max_steps=10_000)` loop driver (`bennettvm-fbh`).
# The canonical forward driver: a while-loop calling `step!` until
# `is_halted(s)`, with a Rule-1 max-steps guard that errors descriptively
# (NOT silently returns) on divergence. PRD v4 §3.16 makes the loud
# raise binding; the RState is left mid-run on guard fire so a future
# M4 `unrun!` can roll it back. Exported alongside the rest of the M3
# surface.
include("interpreter/Interpreter.jl")
# M4.3 — `unstep!` via L3 checkpoint-replay (`bennettvm-3do`). The
# backward primitive that consumes the periodic `CheckpointEntry`s
# M4.2's `step!` pushes: find the nearest checkpoint at or before the
# target step, restore its (deep-copied) snapshot into `s.current`,
# truncate later entries off `s.history`, and replay `step!` forward
# to the target with `checkpoint_interval = typemax(Int)` so no
# spurious pushes fire during replay. Depends on `RState` (M2.3 +
# M4.3's `initial::IState` field — the fallback anchor when no
# checkpoint exists at or before target), `CheckpointEntry` (M4.1 —
# the entry type whose snapshot is restored), and `step!` (M4.2 — the
# replay primitive); MUST follow `interpreter/Interpreter.jl` in
# include order because the replay loop calls `step!`. The rr-style
# architecture (O'Callahan et al 2017 §2.1) is the canonical
# citation. Exported alongside `step!` / `run!`.
include("history/Replay.jl")

export VMProgram, lower_vm, n_instructions, initial_state, is_halted, result, step!, run!, unstep!, unrun!

end # module BennettVM

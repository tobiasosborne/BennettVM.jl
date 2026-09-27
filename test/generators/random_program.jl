# test/generators/random_program.jl — M8.4 seeded random RSSA program
# generator (bd `bennettvm-bii`).
#
# # Why a generator
#
# M8.5 (`bennettvm-tnp`, the 100-program property test) needs a steady
# supply of legal VMPrograms to push through `per_step_inverse_check`
# (M8.2). Hand-crafting one hundred conditional / loop / linear
# fixtures is a non-starter on engineering cost grounds AND fails Law 2
# — the spike RETROSPECTIVE Q4 §"Test patterns worth keeping" calls out
# *property-test generator: random but seeded for reproducibility;
# bounded loops for termination; covers control-flow patterns not
# expressible in a single hand-crafted test* as the discipline to keep.
# PRD v4 §3.15 binds property-test discipline at the M8 family layer.
# This file is the generator the property test consumes.
#
# # Why this seed
#
# `MersenneTwister(0xBE171973)` — BE1 = Bennett, 1973 = the foundational
# *Logical Reversibility of Computation* paper (IBM JRD 17(6),
# Nov 1973). Pinning the seed in the public API (`default_rng()`) makes
# every M8.5 failure replayable across machines without `.jld2` fixture
# files — the JSONL-friendly discipline `.beads/issues.jsonl` already
# established for the project (CLAUDE.md Rule 13 / cft-anyons pattern).
#
# # The three-shape taxonomy and why each is structurally distinct
#
#   1. **Linear** — single chain `:b_start → :b_1 → … → :b_n → :b_done`.
#      `UnconditionalEntry`/`UnconditionalExit` only; no splits. The
#      countdown shape (`test/reference/countdown.jl`) WITHOUT the
#      decrement specialisation — bodies carry arbitrary reversible
#      instructions, not a fixed `:sub`/`:add` pair.
#
#   2. **Conditional (reconvergent diamond)** — `:b_start → :b_branch →
#      {:b_then, :b_else} → :b_join → :b_done`. The branch block carries
#      a `ConditionalExit` on a precomputed predicate `:c`; the join is
#      a `ConditionalEntry` with `predecessor_true=:b_then,
#      predecessor_false=:b_else, condition=:c`. The predicate `:c` is
#      established by `:b_branch` once and **persists in `locals`
#      through the dispatch** — `_rename_args_to_params!`
#      (`src/interpreter/Interpreter.jl:1215`) only touches mentioned
#      args, leaving `:c` undisturbed across the diamond.
#
#   3. **Looping (unrolled)** — countdown-style chain with K identical
#      body blocks. The bead-noted bound: M_UNBOUNDED (true loops with
#      back-edges) is still a P0 ADR (`bennettvm-c39`); until it lands,
#      "looping" means **structural unrolling** — no CFG cycles. Termi-
#      nation is by construction (K is bounded by `size_hint`).
#
# Hybrids (linear-with-embedded-diamond, etc.) are *not* generated in
# this milestone: the bead's exit criterion asks for "at least three
# structurally distinct shapes", and pinning shape coverage tight
# (Rule 4) is easier when each generator output is one of exactly three
# categories.
#
# # The no-back-edges constraint
#
# Enforced by construction: every block builder visits a distinct fresh
# label, every cross-block edge points forward in the block sequence.
# There is no syntactic affordance in this file to emit a back-edge —
# you'd have to hand-edit the file to introduce one. M_UNBOUNDED's
# arrival (`bennettvm-c39`) is the gate for true loops; until then,
# *every program this generator emits is terminating* and `run!` with
# `max_steps=10_000` is safely bounded.
#
# # The no-CallInstruction exclusion
#
# `CallInstruction.make_delta` raises unconditionally per ADR 0002
# §Open Questions item 4 (v5-deferred) — driving a CallInstruction
# through the L2 path is impossible at this milestone. The M8.3
# mutation-proof harness made the same exclusion (cited verbatim in
# `test/test_mutation_proof.jl` line ~109); bead `bennettvm-7cg` is the
# v5 follow-up that will lift this. Until then, the generator emits
# only the five "safe" non-control instruction kinds:
# `ArithmeticAssignment`, `SwapInstruction`, `MemoryAssignment`,
# `MemoryInterchange`, `MemorySwap`. All three modop variants for
# `Arithmetic`/`MemoryAssignment` (`:xor`, `:add`, `:sub`) ride along
# (M7.1 ADR confirmed all three are structurally injective via
# `dual_modop`).
#
# # The RSSA phi-on-splits-and-joins invariant
#
# Mogensen 2016 §3 (cited in `src/ir/control_instructions.jl`'s M2.10
# block and in `docs/adr/0001-rc3-rvm-smoke.md` §Observations
# Structural-Pattern point 2): φ-equivalents appear at BOTH splits AND
# joins. The diamond shape obeys this directly — `ConditionalExit` is
# the split (predicate + two target labels), `ConditionalEntry` is the
# join (predicate + two predecessor labels). Each end of the diamond
# carries the same `:c` symbol; backward dispatch at the join recovers
# the predecessor by reading `:c` from `locals` (no history record
# needed — the predicate is live at every transition).
#
# # Ref
#
#   * `bennettvm_prd.md` (PRD v4) §3.13 (per-step inverse), §3.15
#     (property-test discipline; the M8 family bind).
#   * `spike/RETROSPECTIVE.md` Q4 §"Test patterns worth keeping" —
#     the property-test generator pattern's origin lesson.
#   * `references/foundational/bennett-1973-logical-reversibility.pdf`
#     — namesake of the seed `0xBE171973`.
#   * Mogensen, *RSSA: A Reversible SSA Form*, Persp. of System
#     Informatics 2015 §3 — phi-on-splits-and-joins, the invariant the
#     conditional-diamond shape embodies.
#   * `src/ir/control_instructions.jl` (M2.8/M2.9/M2.10) — the entry/
#     exit subtypes the shape constructors emit.
#   * `src/interpreter/Interpreter.jl:1100-1175` — cross-block dispatch
#     (`_handle_cross_block_dispatch!`, `_dispatch_to_block!`,
#     `_rename_args_to_params!`); the runtime contract this generator
#     targets.
#   * `test/reference/countdown.jl` (M8.1) — the canonical multi-block
#     factory whose construction idiom this file generalises.
#   * `test/test_per_step_inverse.jl` (M8.2) — the scaffold the M8.5
#     consumer drives the generator output through.
#   * `test/test_mutation_proof.jl` (M8.3) — the prior file in the M8
#     family; CallInstruction-exclusion citation precedent.
#   * `test/generators/semantic_model.jl` (`bennettvm-tghl`) — the
#     `SemDesc` vocabulary and the independent evaluator the third
#     return value is made of.
#   * `bd bennettvm-bii` (M8.4) — this milestone.
#   * `bd bennettvm-jpb` — the generator-hardening follow-up whose
#     items (1) edge-arity / predicate-liveness invariants and
#     (3) field-level `_structural_eq` land here, alongside the
#     description the determinism contract now also covers. Item (2)
#     (the unroll-K floor) is deliberately NOT here: it perturbs the
#     seeded program stream and the M8.4/M8.5 shape-count comments
#     pinned against it, which is its own diff.
#   * `bd bennettvm-7cg` — the v5 follow-up that will lift the
#     CallInstruction exclusion.
#   * `bd bennettvm-c39` — the M_UNBOUNDED ADR that gates true loops;
#     until it lands, "looping" here means unrolled.
#   * CLAUDE.md Rule 1 (fail loud on invariant violation), Rule 4
#     (every test asserts known-correct values), Rule 5 (mutation-prove
#     the determinism test catches regressions), Rule 10 (≤200 LOC),
#     Rule 11 (literate top-of-file docstring), Rule 13 (`.beads/`
#     JSONL sync — same discipline pinning seed reproducibility).

using Test
using Random
using BennettVM

include(joinpath(@__DIR__, "..", "reference", "countdown.jl"))

# The independent semantic model (`bennettvm-tghl`). Included HERE, next
# to the generator that produces the `SemDesc` each program is
# accompanied by — the two are one unit: a description whose ops drift
# from the instruction the same rng draw produced is a broken oracle,
# not a weak one. The model file loads no VM code, so "independent" is
# a property of the file's dependencies, not a comment. See its
# top-of-file docstring and `test/test_tghl_forward_oracle.jl`.
include(joinpath(@__DIR__, "semantic_model.jl"))

# ---------------------------------------------------------------------
# 1. Public API
# ---------------------------------------------------------------------

"""
    default_rng() -> MersenneTwister

The bead-pinned RNG seed for M8.4 / M8.5: `MersenneTwister(0xBE171973)`.
Mnemonic: `BE1` = **Be**nnett + `1973` = the foundational *Logical
Reversibility of Computation* paper. Holding the seed in the public
API makes every M8.5 failure replayable across machines without
fixture files.
"""
default_rng() = MersenneTwister(0xBE171973)

"""
    random_program(rng::AbstractRNG; shape=:any, size_hint=4)
        -> (vm::VMProgram, inputs::Dict{Symbol,Int64}, desc::SemDesc)

Generate a legal, terminating `VMProgram`, a matching `inputs` dict
ready to feed into `initial_state(vm, inputs)`, and the `SemDesc` that
says what the program MEANS (`bennettvm-tghl`).

The description is the forward oracle the M8.5 gate checks the VM
against BEFORE it reverses anything. It is drawn from the same rng
draws as the instructions, but it is a separate artefact in
source-level terms: `sem_eval` interprets it with its own register
file, its own memory dict and its own binop table, sharing no code with
the VM (`test/generators/semantic_model.jl`). Without the third
element the gate can only check that the VM reverses what it computed,
not that it computed the right thing (Astra VM-ingest F16).

`shape` selects the structural family (`:linear`, `:conditional`,
`:looping`); the default `:any` flips a uniform 3-way coin against
`rng`. `size_hint` bounds the body length (linear), branch length
(conditional), or unroll factor (looping). Determinism contract: same
`rng` state in → same program, inputs and description out.
"""
function random_program(rng::AbstractRNG; shape::Symbol = :any,
                        size_hint::Int = 4)
    shape === :any && (shape = rand(rng, (:linear, :conditional, :looping)))
    shape === :linear     ? _random_linear(rng, size_hint) :
    shape === :conditional ? _random_conditional_diamond(rng, size_hint) :
    shape === :looping    ? _random_unrolled_loop(rng, size_hint) :
    error("random_program: unknown shape :$shape; expected one of ",
          ":linear, :conditional, :looping, :any")
end

# ---------------------------------------------------------------------
# 2. Body-instruction palette
# ---------------------------------------------------------------------
#
# Exclusion: `CallInstruction` is omitted — its `make_delta` raises
# unconditionally (ADR 0002 §Open Questions item 4, v5-deferred). The
# M8.3 mutation-proof harness made the same exclusion (cited at
# `test/test_mutation_proof.jl` line ~109); bead `bennettvm-7cg`
# tracks the v5 lift. Every kind below has a fully-implemented
# `forward`/`inverse` pair AND (when non-injective) a real `make_delta`.

# Pick a fresh-name suffix from the rng so different body instructions
# don't collide on SSA names. The caller passes `n_counter`.
const _MODOPS = (:xor, :add, :sub)

# Emit a body instruction that consumes `cur` and produces `nxt`. For
# memory-touching kinds, also draws a literal address.
#
# # RSSA invariant: `lhs` / `rhs` must NOT equal `source`
#
# `ArithmeticAssignment.inverse` recomputes `e = (lhs op rhs)` from
# locals — `source` was deleted by `forward`. If `lhs == source` or
# `rhs == source`, the inverse `_resolve` raises `KeyError` (verified
# empirically: countdown_program(N)'s body always uses literal
# `lhs=1, rhs=1`, never the source SSA name). The palette therefore
# uses **literals only** for the modop operands — the same rule
# `test/reference/countdown.jl` follows; it is binding here, not
# stylistic.
#
# # `cur` vs `cur_src` (bennettvm-tghl)
#
# The VM instruction names the register the interpreter will actually
# have bound when it runs (`cur`); the description names the register
# the PROGRAM means (`cur_src`). The two differ only at a chain's FIRST
# step, and only in the conditional shape, whose arms execute under the
# entry-parameter names `:x0_t` / `:x0_f` that the interpreter's
# cross-block `_bind_args_to_params!` rename produces from the
# source-level input `:x0`. Threading both keeps the description free of
# VM-side naming while the instruction stays free of source-level
# fiction.
#
# Returns `(vm_emitted, sem_ops)` where `vm_emitted` is one
# `Instruction` or a 2-tuple of them (the pair forms are the
# memory-touching kinds that need a follow-up rename-only AA to advance
# the SSA chain) and `sem_ops` is the matching `Vector{SemOp}` — same
# order, same constants, same arity, by construction.
function _random_body_instr(rng::AbstractRNG, cur::Symbol,
                            cur_src::Symbol, nxt::Symbol, tag::Int)
    kind = rand(rng, 1:5)
    if kind == 1
        # ArithmeticAssignment: nxt := cur ⊕ (tag op tag). Literals on
        # both operand slots — the binding RSSA invariant above.
        modop = rand(rng, _MODOPS)
        op    = rand(rng, (:xor, :and, :or))
        return (BennettVM.ArithmeticAssignment(nxt, cur, modop,
                                               Int64(tag), op, Int64(1)),
                SemOp[SemArith(nxt, cur_src, modop, Int64(tag), op, Int64(1))])
    elseif kind == 2
        # Second AA variant — different modop/op palette and tag-derived
        # constant. Distinct from kind 1 to broaden modop coverage.
        return (BennettVM.ArithmeticAssignment(nxt, cur, :xor,
                                               Int64(tag * 2), :and,
                                               Int64(tag * 2)),
                SemOp[SemArith(nxt, cur_src, :xor, Int64(tag * 2), :and,
                               Int64(tag * 2))])
    elseif kind == 3
        # MemoryAssignment: M[addr] ⊕= (tag op tag); cur unchanged.
        # Pair with a rename-only AA to advance the SSA chain.
        addr = Int64(100 + tag)
        modop = rand(rng, _MODOPS)
        return ((BennettVM.MemoryAssignment(addr, modop, Int64(tag),
                                             :and, Int64(tag)),
                 BennettVM.ArithmeticAssignment(nxt, cur, :xor,
                                                Int64(0), :xor, Int64(0))),
                SemOp[SemMemAssign(addr, modop, Int64(tag), :and, Int64(tag)),
                      SemArith(nxt, cur_src, :xor, Int64(0), :xor, Int64(0))])
    elseif kind == 4
        # MemoryInterchange: nxt := M[addr] := cur (cur destroyed,
        # nxt created). Injective by construction; addr is a literal so
        # it cannot alias cur/nxt (M2.12 constructor's Symbol/Symbol
        # aliasing check would catch a hypothetical aliasing bug).
        addr = Int64(200 + tag)
        return (BennettVM.MemoryInterchange(nxt, addr, cur),
                SemOp[SemMemExchg(nxt, addr, cur_src)])
    else
        # MemorySwap: literal↔literal cell exchange; cur unchanged.
        # Pair with a rename-only AA to advance the SSA chain.
        a1, a2 = Int64(300 + tag), Int64(400 + tag)
        return ((BennettVM.MemorySwap(a1, a2),
                 BennettVM.ArithmeticAssignment(nxt, cur, :xor,
                                                Int64(0), :xor, Int64(0))),
                SemOp[SemMemSwap(a1, a2),
                      SemArith(nxt, cur_src, :xor, Int64(0), :xor, Int64(0))])
    end
end

# Materialise a chain of `n` body instructions advancing `cur → cur_1 →
# … → cur_n`, together with the description of the same chain. Returns
# `(instructions, sem_ops, final_current_symbol)`. The naming
# convention reuses the countdown idiom: `Symbol(prefix, "_", k)`.
# `cur_src` is the source-level name of the register the chain's FIRST
# step reads; from the second step on the description's source is the
# previous step's target, exactly as in the program (see
# `_random_body_instr` for why the first name can differ at all — it
# cannot differ later, because every later read names a value the chain
# itself produced).
function _chain(rng::AbstractRNG, n::Int, cur::Symbol, cur_src::Symbol,
                prefix::AbstractString)
    instrs = BennettVM.Instruction[]
    sems   = SemOp[]
    for k in 1:n
        nxt = Symbol(prefix, "_", k)
        (emitted, sem_ops) = _random_body_instr(rng, cur, cur_src, nxt, k)
        if emitted isa Tuple
            push!(instrs, emitted[1]); push!(instrs, emitted[2])
        else
            push!(instrs, emitted)
        end
        append!(sems, sem_ops)
        cur = nxt
        cur_src = nxt
    end
    return instrs, sems, cur
end

# Re-label the register a description arm's LAST step writes, so the
# conditional shape's two arms both end at the source-level join name
# (`:x_join`) instead of their VM-side tail names (`:xt_1` / `:xf_2`,
# which the interpreter's cross-block rename maps onto `:x_join`). The
# model then reproduces the join the program actually performs, and the
# description's `output` is a name the model really produces.
#
# A step that writes no register (`SemMemAssign` / `SemMemSwap`) raises:
# an arm that does not end in a register write has no join value for
# the oracle to compare (Rule 1). The generator's memory kinds always
# pair with a follow-up rename-only `SemArith`, so the last step of an
# arm is always a register write today.
_relabel_final(op::SemArith, name::Symbol) =
    SemArith(name, op.src, op.modop, op.a, op.op, op.b)
_relabel_final(op::SemMemExchg, name::Symbol) =
    SemMemExchg(name, op.addr, op.src)
function _relabel_final(op::SemOp, name::Symbol)
    error("generator: cannot re-label ", typeof(op), " as the arm's final ",
          "register write (:", name, ") — it writes no register, so the ",
          "arm has no join value for the description to predict")
end

# ---------------------------------------------------------------------
# 3. Shape constructors
# ---------------------------------------------------------------------

"""
    _random_linear(rng::AbstractRNG, size_hint::Int)
        -> (VMProgram, Dict{Symbol,Int64}, SemDesc)

Linear chain of `n ∈ 3:size_hint` body instructions (clamped low at 3
so the chain is non-trivial). Block layout:
`:b_start (Begin) → :b_body (UnconditionalEntry/Exit + body) →
:b_done (UnconditionalEntry/End)`. The description is the same chain in
source-level terms — one unconditional arm, no predicate.
"""
function _random_linear(rng::AbstractRNG, size_hint::Int)
    n = rand(rng, 3:max(3, size_hint))
    body, sems, final_sym = _chain(rng, n, :x0, :x0, "x")
    b_start = BennettVM.BasicBlock(:b_start,
        BennettVM.BeginInstruction(:p, [:x0]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:b_body, [:x0]))
    b_body = BennettVM.BasicBlock(:b_body,
        BennettVM.UnconditionalEntry(:b_body, [:x0]),
        body,
        BennettVM.UnconditionalExit(:b_done, [final_sym]))
    b_done = BennettVM.BasicBlock(:b_done,
        BennettVM.UnconditionalEntry(:b_done, [final_sym]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:p, [final_sym]))
    blocks = [b_start, b_body, b_done]
    vm = VMProgram(blocks, BennettVM.LabelTable(blocks), :b_start, [64], [64])
    _assert_vm_invariants(vm)
    desc = SemDesc(:linear, nothing, [sems], final_sym, 64)
    return vm, Dict(:x0 => Int64(rand(rng, 1:1_000_000))), desc
end

"""
    _random_conditional_diamond(rng::AbstractRNG, size_hint::Int)
        -> (VMProgram, Dict{Symbol,Int64}, SemDesc)

Reconvergent diamond. `:b_start` establishes data `:x0` AND predicate
`:c`; `:b_branch` carries a `ConditionalExit(:c, :b_then, :b_else,
[:x0])`. Both branches are independent chains of `1:max(1,size_hint÷3)`
body instructions, exiting to `:b_join` (a `ConditionalEntry` with
`predecessor_true=:b_then, predecessor_false=:b_else, condition=:c`).
`:c` rides through `locals` undisturbed (never appears in any args
list — `_rename_args_to_params!` leaves unmentioned locals alone),
so it is live at the join for backward predecessor recovery.

The description is the two arms as ONE function of `:x0`, selected by
`:c`: `arms[1]` runs when `:c` is nonzero, `arms[2]` when it is zero.
Both arms are described as reading `:x0` (not the VM-side `:x0_t` /
`:x0_f` the cross-block rename binds), so the model never has to know
about interpreter renaming to know which arm ran.
"""
function _random_conditional_diamond(rng::AbstractRNG, size_hint::Int)
    nt = rand(rng, 1:max(1, size_hint ÷ 3))
    nf = rand(rng, 1:max(1, size_hint ÷ 3))
    body_t, sems_t, final_t = _chain(rng, nt, :x0_t, :x0, "xt")
    body_f, sems_f, final_f = _chain(rng, nf, :x0_f, :x0, "xf")
    # Common join-side name so positional renames line up: both branches
    # rename their tail symbol to :x_join via the cross-block edge.
    b_start = BennettVM.BasicBlock(:b_start,
        BennettVM.BeginInstruction(:p, [:x0, :c]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:b_branch, [:x0]))
    b_branch = BennettVM.BasicBlock(:b_branch,
        BennettVM.UnconditionalEntry(:b_branch, [:x0]),
        BennettVM.Instruction[],
        BennettVM.ConditionalExit(:c, :b_then, :b_else, [:x0]))
    b_then = BennettVM.BasicBlock(:b_then,
        BennettVM.UnconditionalEntry(:b_then, [:x0_t]),
        body_t,
        BennettVM.UnconditionalExit(:b_join, [final_t]))
    b_else = BennettVM.BasicBlock(:b_else,
        BennettVM.UnconditionalEntry(:b_else, [:x0_f]),
        body_f,
        BennettVM.UnconditionalExit(:b_join, [final_f]))
    b_join = BennettVM.BasicBlock(:b_join,
        BennettVM.ConditionalEntry(:b_join, [:x_join], :b_then, :b_else, :c),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:b_done, [:x_join]))
    b_done = BennettVM.BasicBlock(:b_done,
        BennettVM.UnconditionalEntry(:b_done, [:x_join]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:p, [:x_join]))
    blocks = [b_start, b_branch, b_then, b_else, b_join, b_done]
    vm = VMProgram(blocks, BennettVM.LabelTable(blocks), :b_start,
                   [64, 64], [64])
    _assert_vm_invariants(vm)
    # Both arms end at the source-level join name (see `_relabel_final`).
    sems_t[end] = _relabel_final(sems_t[end], :x_join)
    sems_f[end] = _relabel_final(sems_f[end], :x_join)
    # Randomly pick true or false branch; both must halt.
    desc = SemDesc(:conditional, :c, [sems_t, sems_f], :x_join, 64)
    return vm, Dict(:x0 => Int64(rand(rng, 1:1_000_000)),
                    :c  => Int64(rand(rng, 0:1))), desc
end

"""
    _random_unrolled_loop(rng::AbstractRNG, size_hint::Int)
        -> (VMProgram, Dict{Symbol,Int64}, SemDesc)

Countdown-style unrolled loop with `K ∈ 1:max(1,size_hint)` identical
decrement-shaped blocks. Each block performs a (rng-chosen) reversible
single-counter mutation, advancing the SSA name chain `:y0 → :y1 →
… → :y_K`. The unroll factor K is the structural analogue of an
unbounded loop's iteration count; true back-edges await M_UNBOUNDED
(`bennettvm-c39`).

Semantically the K blocks are one straight-line chain of `K`
arithmetic updates, so the description is a single unconditional arm of
`K` `SemArith` steps — the shape distinction the description cannot
(and need not) see is the CFG, which the gate's reversal leg covers.
"""
function _random_unrolled_loop(rng::AbstractRNG, size_hint::Int)
    K = rand(rng, 1:max(1, size_hint))
    blocks = BennettVM.BasicBlock[]
    sems   = SemOp[]
    push!(blocks, BennettVM.BasicBlock(:b_start,
        BennettVM.BeginInstruction(:p, [:y0]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(Symbol("b_iter_", 1), [:y0])))
    for k in 1:K
        cur = Symbol("y", k - 1)
        nxt = Symbol("y", k)
        # Use a fixed-shape body (single AA with rng-picked modop/op),
        # not the full _chain palette, so iteration blocks are visibly
        # uniform — the structural mark of "looping". Literals on both
        # operand slots, per the RSSA invariant on `_random_body_instr`.
        modop = rand(rng, _MODOPS)
        op    = rand(rng, (:xor, :and, :or))
        body = BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(nxt, cur, modop,
                                           Int64(1), op, Int64(1))]
        push!(sems, SemArith(nxt, cur, modop, Int64(1), op, Int64(1)))
        next_label = k < K ? Symbol("b_iter_", k + 1) : :b_done
        push!(blocks, BennettVM.BasicBlock(Symbol("b_iter_", k),
            BennettVM.UnconditionalEntry(Symbol("b_iter_", k), [cur]),
            body,
            BennettVM.UnconditionalExit(next_label, [nxt])))
    end
    final = Symbol("y", K)
    push!(blocks, BennettVM.BasicBlock(:b_done,
        BennettVM.UnconditionalEntry(:b_done, [final]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:p, [final])))
    vm = VMProgram(blocks, BennettVM.LabelTable(blocks), :b_start, [64], [64])
    _assert_vm_invariants(vm)
    desc = SemDesc(:looping, nothing, [sems], final, 64)
    return vm, Dict(:y0 => Int64(rand(rng, 1:1_000_000))), desc
end

# ---------------------------------------------------------------------
# 4. Cross-edge label-resolution invariant
# ---------------------------------------------------------------------

"""
    _assert_vm_invariants(vm::VMProgram) -> Nothing

Per Rule 1: fail loud on any cross-block edge that cannot be executed
as written. Four checks, all at CONSTRUCTION time (a generator that
silently emits a program the interpreter cannot run breaks M8.5
catastrophically, and the gate must fire HERE, not at the first
`step!`):

  1. **Label resolution** — every `UnconditionalExit.target`,
     `ConditionalExit.target_{true,false}` and
     `ConditionalEntry.predecessor_{true,false}` resolves in
     `vm.label_table` (the original M8.4 check; the `VMProgram` inner
     constructor covers the entry label only).
  2. **Edge arity alignment** (`bennettvm-jpb` (1a)) — the exiting
     block's `args` and the destination entry-marker's `params` have
     equal length, on every edge, and on both sides of a
     `ConditionalEntry` (each predecessor's `args` must line up with
     the join's `params`). Until M2.18's `validate(::VMProgram)` pass
     lands, the interpreter's `_bind_args_to_params!` is the only
     arity check in the system and it fires mid-run with a message
     about a `KeyError` several blocks later.
  3. **Predicate liveness** (`bennettvm-jpb` (1b)) — every
     `ConditionalExit` / `ConditionalEntry` condition symbol is bound
     by the entry `BeginInstruction` (it is a program input) and is
     never the `target` of any instruction in the program. The
     interpreter reads the predicate out of the register file at the
     exit and `unstep!` reads it back at the join; a dead predicate
     would be a `KeyError` on the forward path and a silent
     wrong-predecessor on the backward one.
  4. **Predicate isolation** (`bennettvm-jpb` (1b)) — no condition
     symbol appears in ANY `args` or `params` list anywhere in the
     program. The diamond relies on this implicitly:
     `_bind_args_to_params!` renames only the names a list mentions, so
     a `:c` in a list would be rebound (or shadowed) across the
     transition and backward dispatch would recover the wrong
     predecessor. The M2.10 `Conditional{Entry,Exit}` constructors
     already forbid it on the split and the join; what was unasserted —
     and is what this extends — is the diamond's UNCONDITIONAL edges,
     which no constructor inspects.
"""
function _assert_vm_invariants(vm::VMProgram)
    by_label = Dict(bb.label => bb for bb in vm.blocks)
    begins = filter(bb -> bb.entry isa BennettVM.BeginInstruction, vm.blocks)
    length(begins) == 1 ||
        error("generator: expected exactly one BeginInstruction block, ",
              "found $(length(begins)) — the predicate-liveness check ",
              "needs a single entry block to read the inputs from")
    entry_params = begins[1].entry.params
    conditions = Symbol[]
    for bb in vm.blocks
        ex = bb.exit
        if ex isa BennettVM.UnconditionalExit
            _assert_edge_arity(vm, bb, by_label, ex.target, ex.args, true)
        elseif ex isa BennettVM.ConditionalExit
            push!(conditions, ex.condition)
            _assert_edge_arity(vm, bb, by_label, ex.target_true, ex.args, true)
            _assert_edge_arity(vm, bb, by_label, ex.target_false, ex.args, true)
        end
        en = bb.entry
        if en isa BennettVM.ConditionalEntry
            # Join side: each predecessor's `args` must line up with
            # this block's `params` (both arms of the diamond bind
            # `:x_join`, so a one-sided arity slip is a silent
            # mis-binding on the other arm).
            _assert_edge_arity(vm, bb, by_label, en.predecessor_true,
                               en.params, false)
            _assert_edge_arity(vm, bb, by_label, en.predecessor_false,
                               en.params, false)
            push!(conditions, en.condition)
        end
    end
    # SECOND PASS for (4): only now is the full set of predicate symbols
    # known, so a symbol introduced by a LATER block's `ConditionalExit`
    # is still checked against an EARLIER edge that carries it (the
    # diamond's `:b_start → :b_branch` edge precedes the split that
    # names `:c`). A single pass would miss exactly that edge.
    for bb in vm.blocks
        for target in _outgoing_labels(bb)
            _assert_no_condition_aliasing(bb, by_label[target], conditions)
        end
    end
    for c in conditions
        c in entry_params ||
            error("generator: condition :", c, " is not an entry-block " *
                  "parameter ($(entry_params)); the interpreter reads " *
                  "the predicate out of the register file at the split " *
                  "and unstep! reads it back at the join")
        for bb in vm.blocks, instr in bb.instructions
            hasproperty(instr, :target) && instr.target === c &&
                error("generator: condition :", c, " is also the target " *
                      "of $(typeof(instr)) in block :$(bb.label); the " *
                      "predicate would not survive to the join")
        end
    end
    return nothing
end

# The labels a block's exit transfers control to (one for an
# `UnconditionalExit`, two for a `ConditionalExit`, none for anything
# else).
function _outgoing_labels(bb::BennettVM.BasicBlock)
    ex = bb.exit
    ex isa BennettVM.UnconditionalExit && return [ex.target]
    ex isa BennettVM.ConditionalExit && return [ex.target_true, ex.target_false]
    return Symbol[]
end

# Resolve `target` (in both the LabelTable and the block list) and
# assert the `args` ↔ `params` arity of the edge. `outgoing = true`
# walks a block's exit to its destination's entry marker;
# `outgoing = false` walks a join's entry back to a predecessor's exit.
# Returns the destination block.
function _assert_edge_arity(vm::VMProgram, bb::BennettVM.BasicBlock,
                            by_label::AbstractDict, target::Symbol,
                            carried::Vector{Symbol}, outgoing::Bool)
    haskey(vm.label_table, target) && haskey(by_label, target) ||
        error("generator: block :$(bb.label) ", outgoing ? "→" : "←",
              " :", target, " — unknown label")
    dest   = by_label[target]
    other  = outgoing ? dest.entry : dest.exit
    other isa BennettVM.ControlInstruction ||
        error("generator: block :$(bb.label) ", outgoing ? "→" : "←",
              " :", target, " — the ", outgoing ? "entry" : "exit",
              " slot is a $(typeof(other)), not a control marker")
    # `carried` is the list the EDGE carries; `theirs` is the list on
    # the far side. An exit carries `args` into a `params`, and a join
    # receives `params` from a predecessor's `args`.
    theirs = outgoing ? other.params : other.args
    length(carried) == length(theirs) ||
        error("generator: block :$(bb.label) ", outgoing ? "→" : "←",
              " :", target, " — arity mismatch: $(length(carried)) ",
              outgoing ? "args" : "params", " vs ", length(theirs),
              " on the other side. The interpreter binds positionally, ",
              "so a slip here is a wrong-value bind rather than an error.")
    return dest
end

# (4) No condition symbol may appear in a block's `args` / `params`
# list. The M2.10 constructors already forbid it on a
# `ConditionalExit`'s `args` and a `ConditionalEntry`'s `params`; the
# hole this closes is the UNCONDITIONAL edges of the same diamond,
# which no constructor inspects and on which `_bind_args_to_params!`
# would silently rebind the predicate.
function _assert_no_condition_aliasing(bb::BennettVM.BasicBlock,
                                       dest::BennettVM.BasicBlock,
                                       conditions::Vector{Symbol})
    isempty(conditions) && return nothing
    lists = Symbol[]
    hasproperty(bb.exit, :args) && append!(lists, bb.exit.args)
    hasproperty(dest.entry, :params) && append!(lists, dest.entry.params)
    for name in lists, c in conditions
        name === c &&
            error("generator: condition :", c, " is carried in a " *
                  "parameter list (block :$(bb.label) → :$(dest.label), " *
                  "list $lists); _bind_args_to_params! would rebind it " *
                  "across the transition and the backward join dispatch " *
                  "would read the wrong predecessor")
    end
    return nothing
end

# ---------------------------------------------------------------------
# 5. Helpers for tests
# ---------------------------------------------------------------------

# Classify a generated program by its block-label pattern. The shape
# constructors are private; this helper lets the shape-coverage testset
# bucket :any output without depending on internal field names.
function _classify_shape(vm::VMProgram)
    labels = Set(bb.label for bb in vm.blocks)
    :b_branch in labels && :b_then in labels && :b_else in labels &&
        :b_join in labels && return :conditional
    any(startswith(string(l), "b_iter_") for l in labels) && return :looping
    :b_body in labels && return :linear
    error("_classify_shape: unrecognised shape with labels $labels")
end

# Structural equality on VMPrograms. `Base.==` is not overridden on
# VMProgram (it would compare Vector fields by identity); the determinism
# test compares the load-bearing structural projections.
#
# `bennettvm-jpb` (F17, Astra VM-ingest): this used to compare
# instruction and control-marker TYPES only, never their fields, so two
# programs computing different functions — `Define(:r,1,:add,0)` vs
# `Define(:r,999,:add,0)`, or `:add` vs `:mul` — compared EQUAL. Same-seed
# generation makes that invisible today (no live defect), but the
# determinism contract this function backs ("same RNG state in → same
# program out") is a claim about the programs, not about their shapes.
# Every field of every field-bearing node is now compared, so a
# constants-drift regression in the generator is caught here. Field-level
# equality is done by `isequal` on the node's `fieldnames`, which covers
# the `BasicBlock` / `Instruction` / `ControlInstruction` subtypes
# without a per-type hand-written projection — a new instruction type is
# compared field-by-field the day it is added, with no edit here.
function _node_eq(a, b)
    typeof(a) === typeof(b) || return false
    for f in fieldnames(typeof(a))
        isequal(getfield(a, f), getfield(b, f)) || return false
    end
    return true
end

function _structural_eq(a::VMProgram, b::VMProgram)
    a.entry_label === b.entry_label || return false
    isequal(a.arg_widths, b.arg_widths) || return false
    isequal(a.return_widths, b.return_widths) || return false
    isequal(sort!(collect(keys(a.label_table.entries))),
            sort!(collect(keys(b.label_table.entries)))) || return false
    length(a.blocks) == length(b.blocks) || return false
    for (ba, bb) in zip(a.blocks, b.blocks)
        ba.label === bb.label || return false
        _node_eq(ba.entry, bb.entry) || return false
        _node_eq(ba.exit, bb.exit) || return false
        length(ba.instructions) == length(bb.instructions) || return false
        all(_node_eq(ia, ib) for (ia, ib) in zip(ba.instructions, bb.instructions)) ||
            return false
    end
    return true
end

# Field-level equality on the SOURCE-LEVEL description, so the
# determinism contract covers the oracle as well as the program
# (`bennettvm-jpb`). Field-by-field for the same reason as `_node_eq`.
_sem_desc_eq(a::SemDesc, b::SemDesc) =
    a.kind === b.kind && a.predicate === b.predicate &&
    a.output === b.output && a.width == b.width &&
    length(a.arms) == length(b.arms) &&
    all(_sem_ops_eq(x, y) for (x, y) in zip(a.arms, b.arms))
_sem_ops_eq(a::Vector{<:SemOp}, b::Vector{<:SemOp}) =
    length(a) == length(b) && all(_node_eq(x, y) for (x, y) in zip(a, b))

# ---------------------------------------------------------------------
# 6. Testsets
# ---------------------------------------------------------------------

@testset "M8.4 — determinism" begin
    # Generate ten programs from a fresh default_rng(); then generate
    # ten more from another fresh default_rng(); assert pairwise
    # structural equality. Same RNG state in → same program out is the
    # bead-defined determinism contract. The description is compared
    # too (`_sem_desc_eq`, `bennettvm-jpb`): a generator whose
    # descriptions drifted while its programs did not would leave the
    # M8.5 forward oracle describing a different program than the one
    # under test — a determinism gap the program-only comparison
    # cannot see.
    rng1 = default_rng(); rng2 = default_rng()
    for _ in 1:10
        (vm1, in1, d1) = random_program(rng1; size_hint=6)
        (vm2, in2, d2) = random_program(rng2; size_hint=6)
        @test _structural_eq(vm1, vm2)
        @test in1 == in2
        @test _sem_desc_eq(d1, d2)
    end
end

@testset "M8.4 — shape coverage" begin
    # Generate 60 :any programs from default_rng() and pin per-shape
    # counts. With 60 trials and a 3-way uniform pick the expected per-
    # shape count is 20; pinning ≥5 of each catches any generator bias
    # that drops a shape entirely (the failure mode that would silently
    # erode M8.5 coverage) while leaving headroom against legitimate
    # RNG variance.
    rng = default_rng()
    counts = Dict(:linear => 0, :conditional => 0, :looping => 0)
    for _ in 1:60
        (vm, _, _) = random_program(rng; size_hint=6)
        counts[_classify_shape(vm)] += 1
    end
    @test counts[:linear]      >= 5
    @test counts[:conditional] >= 5
    @test counts[:looping]     >= 5
    @test sum(values(counts))  == 60
end

@testset "M8.4 — invariants (every shape × size_hint constructs, halts)" begin
    # For every (shape, size_hint) pair, generate three programs and
    # verify (a) the invariant helper passes, (b) initial_state succeeds
    # with the returned inputs, (c) run! halts within 10_000 steps, and
    # (d) the halted RState reports is_halted == true. The halts check
    # is the load-bearing termination guarantee (no back-edges → finite
    # program → bounded run!).
    rng = default_rng()
    for shape in (:linear, :conditional, :looping)
        for hint in (1, 4, 8)
            for _ in 1:3
                (vm, inputs, _) = random_program(rng; shape=shape, size_hint=hint)
                _assert_vm_invariants(vm)
                rs = initial_state(vm, inputs)
                run!(rs, vm; max_steps=10_000)
                @test is_halted(rs)
            end
        end
    end
end

@testset "M8.4 — description is evaluable (bennettvm-tghl)" begin
    # Every generated description must be interpretable on the inputs it
    # ships with: `sem_eval` raises (Rule 1) on an unbound register, an
    # unknown `SemOp`, or an unknown `modop`. Walking every shape at
    # three `size_hint` values keeps the oracle's vocabulary honest —
    # a description that cannot be evaluated is not a weak oracle, it is
    # a gate that stops testing forward semantics at all. The value
    # each description produces is checked against the VM in
    # `test/test_tghl_forward_oracle.jl`; here we pin only
    # evaluability, which is the generator's half of the contract.
    rng = default_rng()
    n = 0
    for shape in (:linear, :conditional, :looping)
        for hint in (1, 4, 8)
            for _ in 1:3
                (_, inputs, desc) = random_program(rng; shape=shape, size_hint=hint)
                outcome = sem_eval(desc, inputs)
                @test haskey(outcome.registers, desc.output)
                @test desc.kind === shape
                n += 1
            end
        end
    end
    @test n == 27
end

@testset "M8.4 — scaffold compatibility (L3 and L2)" begin
    # For one program of each shape, drive it through the M8.2 scaffold
    # in both regimes M8.5 will hit: L3 default (empty must_cache_set)
    # and L2 with `must_cache_set = compute_must_cache(vm)`. The
    # scaffold returns nothing on success; an error here is the gate
    # M8.5 leans on for "every random program round-trips".
    rng = default_rng()
    for shape in (:linear, :conditional, :looping)
        (vm, inputs, _) = random_program(rng; shape=shape, size_hint=4)
        @test per_step_inverse_check(vm, inputs;
            checkpoint_interval=4,
            label="M8.4-scaffold/$(shape)/L3") === nothing
        set = BennettVM.compute_must_cache(vm)
        @test per_step_inverse_check(vm, inputs;
            checkpoint_interval=typemax(Int),
            must_cache_set=set,
            label="M8.4-scaffold/$(shape)/L2") === nothing
    end
end

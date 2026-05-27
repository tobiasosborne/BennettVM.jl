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
#   * `bd bennettvm-bii` (M8.4) — this milestone.
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
        -> (vm::VMProgram, inputs::Dict{Symbol,Int64})

Generate a legal, terminating `VMProgram` and a matching `inputs`
dict ready to feed into `initial_state(vm, inputs)`. `shape` selects
the structural family (`:linear`, `:conditional`, `:looping`); the
default `:any` flips a uniform 3-way coin against `rng`. `size_hint`
bounds the body length (linear), branch length (conditional), or
unroll factor (looping). Determinism contract: same `rng` state in →
same program out.
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
# Returns one of {Instruction, (Instruction, Instruction)} — pair forms
# are for memory-touching kinds that need a follow-up rename-only AA to
# advance the SSA chain.
function _random_body_instr(rng::AbstractRNG, cur::Symbol, nxt::Symbol,
                            tag::Int)
    kind = rand(rng, 1:5)
    if kind == 1
        # ArithmeticAssignment: nxt := cur ⊕ (tag op tag). Literals on
        # both operand slots — the binding RSSA invariant above.
        modop = rand(rng, _MODOPS)
        op    = rand(rng, (:xor, :and, :or))
        return BennettVM.ArithmeticAssignment(nxt, cur, modop,
                                              Int64(tag), op, Int64(1))
    elseif kind == 2
        # Second AA variant — different modop/op palette and tag-derived
        # constant. Distinct from kind 1 to broaden modop coverage.
        return BennettVM.ArithmeticAssignment(nxt, cur, :xor,
                                              Int64(tag * 2), :and,
                                              Int64(tag * 2))
    elseif kind == 3
        # MemoryAssignment: M[addr] ⊕= (tag op tag); cur unchanged.
        # Pair with a rename-only AA to advance the SSA chain.
        addr = Int64(100 + tag)
        modop = rand(rng, _MODOPS)
        return (BennettVM.MemoryAssignment(addr, modop, Int64(tag),
                                           :and, Int64(tag)),
                BennettVM.ArithmeticAssignment(nxt, cur, :xor,
                                               Int64(0), :xor, Int64(0)))
    elseif kind == 4
        # MemoryInterchange: nxt := M[addr] := cur (cur destroyed,
        # nxt created). Injective by construction; addr is a literal so
        # it cannot alias cur/nxt (M2.12 constructor's Symbol/Symbol
        # aliasing check would catch a hypothetical aliasing bug).
        addr = Int64(200 + tag)
        return BennettVM.MemoryInterchange(nxt, addr, cur)
    else
        # MemorySwap: literal↔literal cell exchange; cur unchanged.
        # Pair with a rename-only AA to advance the SSA chain.
        a1, a2 = Int64(300 + tag), Int64(400 + tag)
        return (BennettVM.MemorySwap(a1, a2),
                BennettVM.ArithmeticAssignment(nxt, cur, :xor,
                                               Int64(0), :xor, Int64(0)))
    end
end

# Materialise a chain of `n` body instructions advancing `cur → cur_1 →
# … → cur_n`. Returns (instructions, final_current_symbol). The naming
# convention reuses the countdown idiom: `Symbol(prefix, "_", k)`.
function _chain(rng::AbstractRNG, n::Int, cur::Symbol, prefix::AbstractString)
    instrs = BennettVM.Instruction[]
    for k in 1:n
        nxt = Symbol(prefix, "_", k)
        emitted = _random_body_instr(rng, cur, nxt, k)
        if emitted isa Tuple
            push!(instrs, emitted[1]); push!(instrs, emitted[2])
        else
            push!(instrs, emitted)
        end
        cur = nxt
    end
    return instrs, cur
end

# ---------------------------------------------------------------------
# 3. Shape constructors
# ---------------------------------------------------------------------

"""
    _random_linear(rng::AbstractRNG, size_hint::Int)
        -> (VMProgram, Dict{Symbol,Int64})

Linear chain of `n ∈ 3:size_hint` body instructions (clamped low at 3
so the chain is non-trivial). Block layout:
`:b_start (Begin) → :b_body (UnconditionalEntry/Exit + body) →
:b_done (UnconditionalEntry/End)`.
"""
function _random_linear(rng::AbstractRNG, size_hint::Int)
    n = rand(rng, 3:max(3, size_hint))
    body, final_sym = _chain(rng, n, :x0, "x")
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
    return vm, Dict(:x0 => Int64(rand(rng, 1:1_000_000)))
end

"""
    _random_conditional_diamond(rng::AbstractRNG, size_hint::Int)
        -> (VMProgram, Dict{Symbol,Int64})

Reconvergent diamond. `:b_start` establishes data `:x0` AND predicate
`:c`; `:b_branch` carries a `ConditionalExit(:c, :b_then, :b_else,
[:x0])`. Both branches are independent chains of `1:max(1,size_hint÷3)`
body instructions, exiting to `:b_join` (a `ConditionalEntry` with
`predecessor_true=:b_then, predecessor_false=:b_else, condition=:c`).
`:c` rides through `locals` undisturbed (never appears in any args
list — `_rename_args_to_params!` leaves unmentioned locals alone),
so it is live at the join for backward predecessor recovery.
"""
function _random_conditional_diamond(rng::AbstractRNG, size_hint::Int)
    nt = rand(rng, 1:max(1, size_hint ÷ 3))
    nf = rand(rng, 1:max(1, size_hint ÷ 3))
    body_t, final_t = _chain(rng, nt, :x0_t, "xt")
    body_f, final_f = _chain(rng, nf, :x0_f, "xf")
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
    # Randomly pick true or false branch; both must halt.
    return vm, Dict(:x0 => Int64(rand(rng, 1:1_000_000)),
                    :c  => Int64(rand(rng, 0:1)))
end

"""
    _random_unrolled_loop(rng::AbstractRNG, size_hint::Int)
        -> (VMProgram, Dict{Symbol,Int64})

Countdown-style unrolled loop with `K ∈ 1:max(1,size_hint)` identical
decrement-shaped blocks. Each block performs a (rng-chosen) reversible
single-counter mutation, advancing the SSA name chain `:y0 → :y1 →
… → :y_K`. The unroll factor K is the structural analogue of an
unbounded loop's iteration count; true back-edges await M_UNBOUNDED
(`bennettvm-c39`).
"""
function _random_unrolled_loop(rng::AbstractRNG, size_hint::Int)
    K = rand(rng, 1:max(1, size_hint))
    blocks = BennettVM.BasicBlock[]
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
    return vm, Dict(:y0 => Int64(rand(rng, 1:1_000_000)))
end

# ---------------------------------------------------------------------
# 4. Cross-edge label-resolution invariant
# ---------------------------------------------------------------------

"""
    _assert_vm_invariants(vm::VMProgram) -> Nothing

Per Rule 1: fail loud on any cross-block edge whose label does not
resolve in `vm.label_table`. The `VMProgram` inner constructor
(`src/ir/VMProgram.jl:154`) checks the entry-label resolves and the
table-vs-blocks length agree; this helper extends to every
`UnconditionalExit.target`, `ConditionalExit.target_{true,false}`,
and `ConditionalEntry.predecessor_{true,false}`. A generator that
silently emits a label nobody owns would break M8.5 catastrophically;
the gate fires HERE, at construction, not at the first step!.
"""
function _assert_vm_invariants(vm::VMProgram)
    for bb in vm.blocks
        ex = bb.exit
        if ex isa BennettVM.UnconditionalExit
            haskey(vm.label_table, ex.target) ||
                error("generator: block :$(bb.label) UnconditionalExit ",
                      "→ :$(ex.target) — unknown label")
        elseif ex isa BennettVM.ConditionalExit
            haskey(vm.label_table, ex.target_true) ||
                error("generator: block :$(bb.label) ConditionalExit ",
                      "→ :$(ex.target_true) (true) — unknown label")
            haskey(vm.label_table, ex.target_false) ||
                error("generator: block :$(bb.label) ConditionalExit ",
                      "→ :$(ex.target_false) (false) — unknown label")
        end
        en = bb.entry
        if en isa BennettVM.ConditionalEntry
            haskey(vm.label_table, en.predecessor_true) ||
                error("generator: block :$(bb.label) ConditionalEntry ",
                      "← :$(en.predecessor_true) (true) — unknown label")
            haskey(vm.label_table, en.predecessor_false) ||
                error("generator: block :$(bb.label) ConditionalEntry ",
                      "← :$(en.predecessor_false) (false) — unknown label")
        end
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
function _structural_eq(a::VMProgram, b::VMProgram)
    length(a.blocks) == length(b.blocks) || return false
    a.entry_label === b.entry_label || return false
    for (ba, bb) in zip(a.blocks, b.blocks)
        ba.label === bb.label || return false
        typeof(ba.entry) === typeof(bb.entry) || return false
        typeof(ba.exit)  === typeof(bb.exit)  || return false
        length(ba.instructions) == length(bb.instructions) || return false
        all(typeof(ia) === typeof(ib) for (ia, ib) in
            zip(ba.instructions, bb.instructions)) || return false
    end
    return true
end

# ---------------------------------------------------------------------
# 6. Testsets
# ---------------------------------------------------------------------

@testset "M8.4 — determinism" begin
    # Generate ten programs from a fresh default_rng(); then generate
    # ten more from another fresh default_rng(); assert pairwise
    # structural equality. Same RNG state in → same program out is the
    # bead-defined determinism contract.
    rng1 = default_rng(); rng2 = default_rng()
    for _ in 1:10
        (vm1, in1) = random_program(rng1; size_hint=6)
        (vm2, in2) = random_program(rng2; size_hint=6)
        @test _structural_eq(vm1, vm2)
        @test in1 == in2
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
        (vm, _) = random_program(rng; size_hint=6)
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
                (vm, inputs) = random_program(rng; shape=shape, size_hint=hint)
                _assert_vm_invariants(vm)
                rs = initial_state(vm, inputs)
                run!(rs, vm; max_steps=10_000)
                @test is_halted(rs)
            end
        end
    end
end

@testset "M8.4 — scaffold compatibility (L3 and L2)" begin
    # For one program of each shape, drive it through the M8.2 scaffold
    # in both regimes M8.5 will hit: L3 default (empty must_cache_set)
    # and L2 with `must_cache_set = compute_must_cache(vm)`. The
    # scaffold returns nothing on success; an error here is the gate
    # M8.5 leans on for "every random program round-trips".
    rng = default_rng()
    for shape in (:linear, :conditional, :looping)
        (vm, inputs) = random_program(rng; shape=shape, size_hint=4)
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

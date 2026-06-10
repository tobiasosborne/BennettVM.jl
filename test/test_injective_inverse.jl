# test/test_injective_inverse.jl — M6.3 audit-and-contract tests for
# the "no-history-needed" inverse property of every M6.1-injective
# instruction (bd `bennettvm-1cg`).
#
# # What M6.3 contractually pins
#
# PRD v4 §3.3 layer 1 ("No log") classifies an `Instruction` as
# *injective* iff its `forward` is information-preserving on `IState`
# — i.e. given `s_post = forward(instr, deepcopy(s_pre))`, an
# `s_recovered := inverse(instr, deepcopy(s_post), prev)` satisfies
# `s_recovered == s_pre` **for any value of `prev`**. The load-bearing
# specialization at this milestone is `prev === nothing`: the
# per-instruction `inverse(instr, s::IState, nothing)` is the per-
# step backward primitive that M6.4 may call without consulting
# `s.history`, because M6.2 already guarantees no history entry was
# ever pushed for an injective instruction (commit `e9eb994`).
#
# M2.6-M2.14 already ship concrete `inverse()` methods for all twelve
# instruction subclasses. M6.1 (commit `6b59824`) added the
# `is_injective` trait that picks out the nine type-level cases and
# the value-level `ArithmeticAssignment(:xor, ...)` case. **M6.3
# itself contributes no production code** — its deliverable is this
# file, which pins the contract:
#
#   - For every M6.1-injective instruction type, **applying `forward`
#     followed by `inverse(..., nothing)` recovers the pre-state
#     bit-for-bit**.
#   - Per-testset comments cite the file:line of the production
#     `inverse()` method whose semantics are being pinned (Rule 1 +
#     Rule 11).
#   - Each testset documents one specific mutation in the production
#     `inverse()` that would turn the asserts RED, making the test's
#     discriminating power auditable (Rule 5, port-and-verify shape).
#
# # Scope (deliberately narrow)
#
#   * Per-instruction `forward` + `inverse(..., nothing)` round-trip
#     only. No `step!`, no `unstep!`, no `RState`. Those are M3.x /
#     M4.x / M6.4 territory.
#   * Pinning the `prev === nothing` argument explicitly at every
#     `inverse` call site. This is the load-bearing assertion of
#     M6.3 — if any of these instructions secretly needed `prev` to
#     invert correctly, the test would either crash (KeyError) or
#     produce `s_recovered != s_pre`.
#   * `ArithmeticAssignment` is covered ONLY for `modop === :xor`
#     here (the M6.1-injective case at the value level). The
#     `:add`/`:sub` cases are covered in
#     `test/test_arithmetic_assignment.jl` (which also passes
#     `nothing` for `prev` because the instruction is structurally
#     reversible regardless of `modop`, but they are not in M6.1's
#     trait-`true` set so they don't belong here).
#   * The six control-flow instructions (Begin, End, Uncond
#     Entry/Exit, Cond Entry/Exit) currently have `pc -= 1`-only
#     inverses at the per-instruction dispatch layer (see each
#     production docstring's "pc-only" section); cross-block backward
#     dispatch is M4.x's checkpoint+replay path's responsibility, NOT
#     this layer. The control-flow testsets below pin exactly the
#     pc-only invariant — `s_post.pc == s_pre.pc + 1` after `forward`
#     and `s_recovered.pc == s_pre.pc` after `inverse`. Cross-block
#     backward dispatch is **out of scope for M6.3**; the audit
#     surfaced a follow-up gap (no `_handle_backward_cross_block_dispatch!`
#     in `src/interpreter/Interpreter.jl`) that the orchestrator will
#     file as a separate bead.
#
# # Per-type audit summary (citations in each testset below)
#
#   * `SwapInstruction`            — `src/ir/swap_instruction.jl:179`
#   * `BeginInstruction`           — `src/ir/control_instructions.jl:231`
#   * `EndInstruction`             — `src/ir/control_instructions.jl:243`
#   * `UnconditionalEntry`         — `src/ir/control_instructions.jl:510`
#   * `UnconditionalExit`          — `src/ir/control_instructions.jl:520`
#   * `ConditionalEntry`           — `src/ir/control_instructions.jl:882`
#   * `ConditionalExit`            — `src/ir/control_instructions.jl:892`
#   * `MemoryInterchange`          — `src/ir/memory_instructions.jl:420`
#   * `MemorySwap`                 — `src/ir/memory_instructions.jl:659`
#   * `ArithmeticAssignment(:xor)` — `src/ir/arithmetic_assignment.jl:220`
#
# # Ref
#
#   * `bennettvm_prd.md` §3.2 (lines 413-446) — injective classification.
#   * `bennettvm_prd.md` §3.3 (lines 448-479) — layer-1 "No log" rule.
#   * `src/history/Injective.jl` — the M6.1 trait this file's per-type
#     selection mirrors.
#   * `test/test_swap_instruction.jl` (M2.7) — the structural template
#     for the round-trip pattern adopted below: snapshot via
#     `deepcopy`, `forward(instr, s)`, `inverse(instr, s, nothing)`,
#     assert `s_recovered == s_before`.
#   * CLAUDE.md Rule 1 (fail loud — every method that errors should
#     do so with context), Rule 4 (every @test pins a specific
#     value), Rule 5 (mutation-prove the tests catch regressions —
#     each testset documents one mutation).
#

# -----------------------------------------------------------------------------
# 1. SwapInstruction — register↔register exchange (M2.7).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/swap_instruction.jl`:
#   forward (line 153): reads locals[source1], locals[source2]; deletes
#     both sources; writes locals[target1] := old source1, locals[target2]
#     := old source2; pc += 1.
#   inverse (line 179): reads locals[target1], locals[target2]; deletes
#     both targets; writes locals[source1] := old target1, locals[source2]
#     := old target2; pc -= 1. The `prev` argument is documented as
#     unused (line 172-177).
#
# Mutation that would turn this testset RED: swap the (target ↔ source)
# pairing in the inverse — e.g., change `BennettVM.active_locals(s)[instr.source1] = v1`
# to `BennettVM.active_locals(s)[instr.source2] = v1` at line 184. The round-trip
# assertion would fail at `s3 == s_before` because the values would
# come back transposed.
@testset "SwapInstruction inverse(_, _, nothing) — M6.3" begin
    instr = BennettVM.SwapInstruction(:p, :q, :u, :v)
    s_pre = BennettVM.IState(3,
        Dict{Symbol,Int64}(:u => Int64(-7), :v => Int64(99), :other => Int64(42)),
        :running)
    s_before = deepcopy(s_pre)

    s_post = BennettVM.forward(instr, deepcopy(s_pre))
    @test s_post.pc == 4
    @test BennettVM.active_locals(s_post)[:p] == -7
    @test BennettVM.active_locals(s_post)[:q] == 99
    @test BennettVM.active_locals(s_post)[:other] == 42        # untouched local preserved
    @test !haskey(BennettVM.active_locals(s_post), :u)
    @test !haskey(BennettVM.active_locals(s_post), :v)

    # The load-bearing M6.3 call: `prev === nothing`.
    s_recovered = BennettVM.inverse(instr, deepcopy(s_post), nothing)
    @test s_recovered == s_before
    @test s_recovered.pc == 3
    @test BennettVM.active_locals(s_recovered)[:u] == -7
    @test BennettVM.active_locals(s_recovered)[:v] == 99
    @test BennettVM.active_locals(s_recovered)[:other] == 42
    @test !haskey(BennettVM.active_locals(s_recovered), :p)
    @test !haskey(BennettVM.active_locals(s_recovered), :q)
end

# -----------------------------------------------------------------------------
# 2. BeginInstruction — subroutine entry marker (M2.8).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/control_instructions.jl`:
#   forward (line 206): pc += 1; locals untouched.
#   inverse (line 231): pc -= 1; locals untouched; `prev` documented
#     unused at line 226-230.
#
# Mutation: change `s.pc -= 1` to `s.pc += 1` in
# `control_instructions.jl:232` → s_recovered.pc would be `s_pre.pc +
# 2`, asserts at `s_recovered == s_before` and `s_recovered.pc ==
# s_pre.pc` go RED.
#
# Scope note: cross-block backward dispatch is NOT in scope for M6.3.
# The pc-only invariant pinned here matches the per-instruction
# dispatch layer's deliberate split (forward / inverse adjust pc by
# ±1, the cross-block jump is `_handle_cross_block_dispatch!`'s job
# forward and would be `_handle_backward_cross_block_dispatch!`'s job
# backward — see the follow-up bead proposal below the test file).
@testset "BeginInstruction inverse(_, _, nothing) — M6.3" begin
    instr = BennettVM.BeginInstruction(:my_routine, [:p, :q])
    s_pre = BennettVM.IState(7,
        Dict{Symbol,Int64}(:a => Int64(11), :b => Int64(22)),
        :running)
    s_before = deepcopy(s_pre)

    s_post = BennettVM.forward(instr, deepcopy(s_pre))
    @test s_post.pc == s_pre.pc + 1                 # 8
    @test BennettVM.active_locals(s_post) == BennettVM.active_locals(s_before)          # untouched
    @test s_post.status === :running

    s_recovered = BennettVM.inverse(instr, deepcopy(s_post), nothing)
    @test s_recovered == s_before
    @test s_recovered.pc == s_pre.pc                # 7
end

# -----------------------------------------------------------------------------
# 3. EndInstruction — subroutine exit marker (M2.8).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/control_instructions.jl`:
#   forward (line 218): pc += 1.
#   inverse (line 243): pc -= 1; `prev` documented unused at line 239-242.
#
# Mutation: drop the `s.pc -= 1` line at `control_instructions.jl:244`
# → s_recovered.pc would equal s_post.pc (= s_pre.pc + 1), assert at
# `s_recovered.pc == s_pre.pc` goes RED.
@testset "EndInstruction inverse(_, _, nothing) — M6.3" begin
    instr = BennettVM.EndInstruction(:my_routine, [:r])
    s_pre = BennettVM.IState(12,
        Dict{Symbol,Int64}(:r => Int64(-1), :s => Int64(0)),
        :running)
    s_before = deepcopy(s_pre)

    s_post = BennettVM.forward(instr, deepcopy(s_pre))
    @test s_post.pc == s_pre.pc + 1                 # 13
    @test BennettVM.active_locals(s_post) == BennettVM.active_locals(s_before)

    s_recovered = BennettVM.inverse(instr, deepcopy(s_post), nothing)
    @test s_recovered == s_before
    @test s_recovered.pc == s_pre.pc                # 12
end

# -----------------------------------------------------------------------------
# 4. UnconditionalEntry — basic-block entry marker (M2.9).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/control_instructions.jl`:
#   forward (line 478): pc += 1; cross-block dispatch lands in
#     `_handle_cross_block_dispatch!` (M3.x interpreter), not here.
#   inverse (line 510): pc -= 1; `prev` documented unused at line
#     502-509. Cross-block backward dispatch is the M4.x
#     checkpoint+replay path's job today; no
#     `_handle_backward_cross_block_dispatch!` exists yet (audit gap —
#     see follow-up bead proposal at the bottom of this file).
#
# Mutation: change the `s.pc -= 1` at `control_instructions.jl:511` to
# a no-op → s_recovered.pc would equal s_post.pc, assert at
# `s_recovered.pc == s_pre.pc` goes RED.
@testset "UnconditionalEntry inverse(_, _, nothing) — M6.3" begin
    instr = BennettVM.UnconditionalEntry(:blk_entry, [:x, :y])
    s_pre = BennettVM.IState(0,
        Dict{Symbol,Int64}(:x => Int64(5), :y => Int64(-5)),
        :running)
    s_before = deepcopy(s_pre)

    s_post = BennettVM.forward(instr, deepcopy(s_pre))
    @test s_post.pc == s_pre.pc + 1                 # 1
    @test BennettVM.active_locals(s_post) == BennettVM.active_locals(s_before)

    s_recovered = BennettVM.inverse(instr, deepcopy(s_post), nothing)
    @test s_recovered == s_before
    @test s_recovered.pc == s_pre.pc                # 0
end

# -----------------------------------------------------------------------------
# 5. UnconditionalExit — basic-block exit marker (M2.9).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/control_instructions.jl`:
#   forward (line 494): pc += 1; cross-block jump is M3.x's job.
#   inverse (line 520): pc -= 1; `prev` documented unused at line 515-519.
#
# Mutation: change `s.pc -= 1` to `s.pc -= 2` at
# `control_instructions.jl:521` → s_recovered.pc would equal s_pre.pc
# - 1, assert at `s_recovered == s_before` goes RED.
@testset "UnconditionalExit inverse(_, _, nothing) — M6.3" begin
    instr = BennettVM.UnconditionalExit(:next_blk, [:a])
    s_pre = BennettVM.IState(4,
        Dict{Symbol,Int64}(:a => Int64(typemax(Int64))),
        :running)
    s_before = deepcopy(s_pre)

    s_post = BennettVM.forward(instr, deepcopy(s_pre))
    @test s_post.pc == s_pre.pc + 1                 # 5
    @test BennettVM.active_locals(s_post) == BennettVM.active_locals(s_before)

    s_recovered = BennettVM.inverse(instr, deepcopy(s_post), nothing)
    @test s_recovered == s_before
    @test s_recovered.pc == s_pre.pc                # 4
end

# -----------------------------------------------------------------------------
# 6. ConditionalEntry — predicate-bearing join (M2.10).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/control_instructions.jl`:
#   forward (line 850): pc += 1; predicate-driven predecessor recovery
#     is M3.x's job (consult locals[condition]; not here).
#   inverse (line 882): pc -= 1; `prev` documented unused at line
#     873-881. The predicate is live in `locals` during both directions
#     — that's the structural reason no history is needed; this test
#     asserts the predicate-as-local is preserved through the round
#     trip (the trait's "predicate in locals" guarantee).
#
# Mutation: at `control_instructions.jl:883`, accidentally `delete!`
# `BennettVM.active_locals(s)[instr.condition]` (a tempting "undo the predicate read"
# bug) → BennettVM.active_locals(s_recovered) would lose the `:c` key, assert at
# `s_recovered == s_before` AND `BennettVM.active_locals(s_recovered)[:c] == 1` go RED.
@testset "ConditionalEntry inverse(_, _, nothing) — M6.3" begin
    instr = BennettVM.ConditionalEntry(:join_blk, [:p],
                                       :true_pred, :false_pred, :c)
    s_pre = BennettVM.IState(2,
        Dict{Symbol,Int64}(:p => Int64(10), :c => Int64(1)),
        :running)
    s_before = deepcopy(s_pre)

    s_post = BennettVM.forward(instr, deepcopy(s_pre))
    @test s_post.pc == s_pre.pc + 1                 # 3
    @test BennettVM.active_locals(s_post) == BennettVM.active_locals(s_before)
    @test BennettVM.active_locals(s_post)[:c] == 1                    # predicate lives in locals

    s_recovered = BennettVM.inverse(instr, deepcopy(s_post), nothing)
    @test s_recovered == s_before
    @test s_recovered.pc == s_pre.pc                # 2
    @test BennettVM.active_locals(s_recovered)[:c] == 1               # predicate preserved
end

# -----------------------------------------------------------------------------
# 7. ConditionalExit — predicate-bearing split (M2.10).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/control_instructions.jl`:
#   forward (line 865): pc += 1; predicate-driven target selection is
#     M3.x's job.
#   inverse (line 892): pc -= 1; `prev` documented unused at line 887-891.
#
# Mutation: change `s.pc -= 1` at `control_instructions.jl:893` to
# `s.pc = 0` → s_recovered.pc would be 0 regardless of s_pre.pc,
# assert at `s_recovered.pc == s_pre.pc` (= 5) goes RED.
@testset "ConditionalExit inverse(_, _, nothing) — M6.3" begin
    instr = BennettVM.ConditionalExit(:c, :tgt_t, :tgt_f, [:arg1])
    s_pre = BennettVM.IState(5,
        Dict{Symbol,Int64}(:arg1 => Int64(77), :c => Int64(0)),
        :running)
    s_before = deepcopy(s_pre)

    s_post = BennettVM.forward(instr, deepcopy(s_pre))
    @test s_post.pc == s_pre.pc + 1                 # 6
    @test BennettVM.active_locals(s_post) == BennettVM.active_locals(s_before)
    @test BennettVM.active_locals(s_post)[:c] == 0                    # predicate (false branch)

    s_recovered = BennettVM.inverse(instr, deepcopy(s_post), nothing)
    @test s_recovered == s_before
    @test s_recovered.pc == s_pre.pc                # 5
    @test BennettVM.active_locals(s_recovered)[:c] == 0
end

# -----------------------------------------------------------------------------
# 8. MemoryInterchange — register↔memory exchange (M2.12).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/memory_instructions.jl`:
#   forward (line 373): atomic `x := M[y] := z` — reads locals[source]
#     and memory[addr] (zero-init: absent key reads as 0); writes
#     memory[addr] := source value; deletes locals[source]; inserts
#     locals[target] := old memory value; pc += 1.
#   inverse (line 420): atomic `z := M[y] := x` — reads locals[target]
#     (= pre-forward M[addr]) and memory[addr] (= pre-forward
#     locals[source]); applies delete-on-zero to restore the zero-
#     init absent-key state if needed; deletes locals[target]; inserts
#     locals[source] := old memory value; pc -= 1. `prev` documented
#     unused at line 385-393.
#
# This test exercises BOTH the non-zero-init case (pre-existing memory
# cell present) AND the zero-init case (pre-forward absent key →
# inverse must delete the key, otherwise `s_recovered.memory == s_pre.memory`
# fails on the `:absent_addr` discrepancy).
#
# Mutation: drop the `delete!(s.memory, a)` at
# `memory_instructions.jl:428` and unconditionally write
# `s.memory[a] = xval` → for the zero-init case, s_recovered.memory
# would carry `addr => 0` where s_pre.memory had no key, assert at
# `s_recovered == s_before` (Dict content compare) goes RED.
@testset "MemoryInterchange inverse(_, _, nothing) — M6.3" begin
    # Case A: pre-existing memory cell (delete-on-zero branch NOT taken).
    instr_a = BennettVM.MemoryInterchange(:x, Int64(100), :z)
    s_pre_a = BennettVM.IState(1,
        Dict{Symbol,Int64}(:z => Int64(42), :other => Int64(7)),
        :running,
        Dict{Int64,Int64}(Int64(100) => Int64(13), Int64(200) => Int64(-1)))
    s_before_a = deepcopy(s_pre_a)

    s_post_a = BennettVM.forward(instr_a, deepcopy(s_pre_a))
    @test s_post_a.pc == 2
    @test BennettVM.active_locals(s_post_a)[:x] == 13            # old M[100]
    @test BennettVM.active_locals(s_post_a)[:other] == 7
    @test !haskey(BennettVM.active_locals(s_post_a), :z)
    @test s_post_a.memory[Int64(100)] == 42    # M[100] := old z

    s_rec_a = BennettVM.inverse(instr_a, deepcopy(s_post_a), nothing)
    @test s_rec_a == s_before_a
    @test BennettVM.active_locals(s_rec_a)[:z] == 42
    @test s_rec_a.memory[Int64(100)] == 13
    @test s_rec_a.memory[Int64(200)] == -1     # untouched cell preserved

    # Case B: zero-init address (delete-on-zero branch TAKEN).
    # M[300] is absent pre-forward; locals[:z] == 0; after the swap
    # the inverse must DELETE M[300] (not leave it as 0).
    instr_b = BennettVM.MemoryInterchange(:x, Int64(300), :z)
    s_pre_b = BennettVM.IState(0,
        Dict{Symbol,Int64}(:z => Int64(0)),    # source value is 0
        :running,
        Dict{Int64,Int64}())                   # M[300] absent
    s_before_b = deepcopy(s_pre_b)

    s_post_b = BennettVM.forward(instr_b, deepcopy(s_pre_b))
    @test BennettVM.active_locals(s_post_b)[:x] == 0             # old M[300] read as 0
    # M[300] now present (= old z = 0)? per forward line 377, M[a] := zval
    # unconditionally, so YES the key is present here:
    @test haskey(s_post_b.memory, Int64(300))
    @test s_post_b.memory[Int64(300)] == 0

    s_rec_b = BennettVM.inverse(instr_b, deepcopy(s_post_b), nothing)
    @test s_rec_b == s_before_b
    @test !haskey(s_rec_b.memory, Int64(300))  # delete-on-zero fired
    @test BennettVM.active_locals(s_rec_b)[:z] == 0
    @test !haskey(BennettVM.active_locals(s_rec_b), :x)
end

# -----------------------------------------------------------------------------
# 9. MemorySwap — memory↔memory exchange (M2.13).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/memory_instructions.jl`:
#   forward (line 607): atomic `M[a] <-> M[b]` — reads va, vb (zero-
#     init); applies delete-on-zero independently to each cell; pc += 1.
#   inverse (line 659): same swap operation (self-inverse); pc -= 1;
#     `prev` documented unused at line 645-648.
#
# This test exercises BOTH the all-cells-present case AND the
# one-side-zero / both-sides-zero cases (delete-on-zero firing).
#
# Mutation: at `memory_instructions.jl:680`, change `s.pc -= 1` to a
# no-op → s_recovered.pc would equal s_post.pc = s_pre.pc + 1, assert
# at `s_recovered == s_before` goes RED.
@testset "MemorySwap inverse(_, _, nothing) — M6.3" begin
    # Case A: both cells present, non-zero.
    instr_a = BennettVM.MemorySwap(Int64(10), Int64(20))
    s_pre_a = BennettVM.IState(8,
        Dict{Symbol,Int64}(:l => Int64(-3)),
        :running,
        Dict{Int64,Int64}(Int64(10) => Int64(111),
                          Int64(20) => Int64(222),
                          Int64(30) => Int64(333)))
    s_before_a = deepcopy(s_pre_a)

    s_post_a = BennettVM.forward(instr_a, deepcopy(s_pre_a))
    @test s_post_a.pc == 9
    @test s_post_a.memory[Int64(10)] == 222
    @test s_post_a.memory[Int64(20)] == 111
    @test s_post_a.memory[Int64(30)] == 333    # untouched

    s_rec_a = BennettVM.inverse(instr_a, deepcopy(s_post_a), nothing)
    @test s_rec_a == s_before_a
    @test s_rec_a.memory[Int64(10)] == 111
    @test s_rec_a.memory[Int64(20)] == 222
    @test BennettVM.active_locals(s_rec_a)[:l] == -3

    # Case B: one side zero-init (M[40] absent pre-forward).
    instr_b = BennettVM.MemorySwap(Int64(40), Int64(50))
    s_pre_b = BennettVM.IState(0,
        Dict{Symbol,Int64}(),
        :running,
        Dict{Int64,Int64}(Int64(50) => Int64(999)))   # M[40] absent
    s_before_b = deepcopy(s_pre_b)

    s_post_b = BennettVM.forward(instr_b, deepcopy(s_pre_b))
    @test s_post_b.memory[Int64(40)] == 999    # got M[50]'s value
    @test !haskey(s_post_b.memory, Int64(50))  # got old M[40] = 0 → deleted

    s_rec_b = BennettVM.inverse(instr_b, deepcopy(s_post_b), nothing)
    @test s_rec_b == s_before_b
    @test !haskey(s_rec_b.memory, Int64(40))   # restored absent key
    @test s_rec_b.memory[Int64(50)] == 999
end

# -----------------------------------------------------------------------------
# 10. ArithmeticAssignment(modop=:xor) — value-level injective (M2.6).
# -----------------------------------------------------------------------------
# Production semantics — `src/ir/arithmetic_assignment.jl`:
#   forward (line 196): reads source and operands; computes
#     `xval := dual_modop-paired(yval, e)`; deletes source; writes
#     target := xval; pc += 1.
#   inverse (line 220): reads target and operands; reconstructs
#     `yval := dual_modop(modop)(xval, e)`; deletes target; writes
#     source := yval; pc -= 1. `prev` documented unused at line 211-219.
#
# Per M6.1 (`src/history/Injective.jl`), `ArithmeticAssignment` is
# type-level NOT injective but value-level injective iff
# `modop === :xor`. This testset covers the value-level injective
# slice; `:add` / `:sub` are tested in
# `test/test_arithmetic_assignment.jl` separately. (Note: the
# `inverse()` impl is structurally reversible regardless of modop —
# `dual_modop` handles all three — so the modop-level distinction is
# trait-policy, not invertibility-fact. The M6.3 contract is "no
# history needed for the injective subset"; the wider trait might
# broaden to `:add`/`:sub` in a separate bead per the M6.1 retrospective.)
#
# Mutation: at `arithmetic_assignment.jl:225`, change
# `dual_modop(instr.modop)` to `instr.modop` (a tempting "modop is
# self-inverse so dual is redundant" simplification, valid ONLY for
# :xor) — for :xor specifically THIS WOULD STILL PASS. The
# discriminating mutation for THIS testset is therefore at line 227:
# change `BennettVM.active_locals(s)[instr.source] = yval` to `BennettVM.active_locals(s)[instr.source] =
# xval` → BennettVM.active_locals(s_recovered)[:y] would carry the wrong value,
# assert at `s_recovered == s_before` AND `BennettVM.active_locals(s_recovered)[:y] == 5`
# go RED.
@testset "ArithmeticAssignment(modop=:xor) inverse(_, _, nothing) — M6.3" begin
    instr = BennettVM.ArithmeticAssignment(:x, :y, :xor, :a, :and, :b)
    s_pre = BennettVM.IState(0,
        Dict{Symbol,Int64}(:y => Int64(5), :a => Int64(0b1100), :b => Int64(0b1010),
                           :keep => Int64(99)),
        :running)
    s_before = deepcopy(s_pre)

    s_post = BennettVM.forward(instr, deepcopy(s_pre))
    @test s_post.pc == 1
    # forward computes e = 0b1100 & 0b1010 = 0b1000 = 8; x := 5 ⊻ 8 = 13.
    @test BennettVM.active_locals(s_post)[:x] == 13
    @test BennettVM.active_locals(s_post)[:keep] == 99            # untouched
    @test !haskey(BennettVM.active_locals(s_post), :y)
    @test haskey(BennettVM.active_locals(s_post), :a) && haskey(BennettVM.active_locals(s_post), :b)

    s_recovered = BennettVM.inverse(instr, deepcopy(s_post), nothing)
    @test s_recovered == s_before
    @test s_recovered.pc == 0
    @test BennettVM.active_locals(s_recovered)[:y] == 5
    @test BennettVM.active_locals(s_recovered)[:keep] == 99
    @test !haskey(BennettVM.active_locals(s_recovered), :x)
end

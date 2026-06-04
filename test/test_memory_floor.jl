# test/test_memory_floor.jl — scalar reversible-memory floor unit + lowering
# tests (bead `bennettvm-x9j`, ADR 0014 §D1–D4; ADR 0013 §D-2).
#
# # What this file pins
#
# `src/ir/memory_floor.jl` defines `MemoryStore` (`M[addr] := value`, void)
# and `MemoryLoad` (`dest := M[addr]`, a fresh-local create), the plain L3
# heap primitives LLVM `store` / `load` lower to (ADR 0014 §D2). A pointer is
# just an `Int64` address in `s.locals`, materialised by the ingest bump
# allocator's `Define(dest, base, :add, 0)` for each scalar `IRAlloca`
# (ADR 0014 §D1). Unlike the existing `MemoryInterchange` (a bijective
# register↔cell EXCHANGE), these are plain, NON-injective overwrite/read ops
# reversed exclusively via L3 checkpoint-replay (`IState.memory` is in the
# snapshot and in `==`/`hash`).
#
# The tests below pin (Rule 4 — every @test asserts a known-correct value):
#
#   1. **Forward — MemoryStore.** Store-then-load returns the stored value;
#      the pointer's address is read from `locals`; the value operand
#      survives (a store does not consume its value SSA name). Literal value.
#   2. **Forward — MemoryLoad.** Load of a written address returns the value;
#      load of an ABSENT address returns 0 (the zero-init convention).
#   3. **Overwrite at the forward level.** A second store overwrites the
#      cell; a second load overwrites `dest` — both without error (the
#      cross-iteration loop case).
#   4. **Constructor validation** (Rule 1): MemoryLoad rejects `dest === ptr`.
#   5. **`is_injective == false`** for BOTH types — load-bearing: a plain
#      overwrite/read is not a bijection on the slice it touches, so it is
#      conservatively non-injective → L3 checkpoints (NOT the injective
#      exchange path).
#   6. **`inverse` raises the deferral error** for both — the reverse is the
#      L3 checkpoint-replay path, never a per-instruction inverse. Pinned via
#      `occursin` on the descriptive message.
#   7. **Hand-built scalar ParsedIR** (alloca/store/load/binop/store/load/ret)
#      lowered via the real `lower_vm`, run forward matching a hand-computed
#      oracle, and round-tripped under L3 (run!/unrun! to empty history; the
#      `per_step_inverse_check` scaffold at K ∈ {1, 4}).
#   8. **Bump-allocator scheme** — two scalar allocas get DISTINCT Int64 base
#      addresses (1 and 2), pinned via the lowered `Define` bodies and the
#      live `locals` after a forward run.
#   9. **scope lift**: an array `IRAlloca` (`ConstOperand(N>1)`) lowers under
#      the array floor (Unit 1), and a dynamic `IRAlloca` (`SSAOperand`
#      n_elems) now lowers to a `DynAlloca` (bead `bennettvm-0zn`) — neither
#      is a "deferred to v2" reject any longer.
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree
#
# Perturbing `MemoryLoad.forward` to `s.locals[instr.dest] = Int64(0)` (return
# 0 always, ignoring the cell) makes testset (1)/(2) and the hand-built
# forward-oracle assertion in testset (7) go RED (store 7 then load returns 0,
# not 7). Confirmed RED, then restored. See the orchestration report for the
# captured RED evidence.
#
# Ref: src/ir/memory_floor.jl (the implementation; the reuse-vs-new
#      justification + L3 baseline rationale in its top-of-module docstring).
# Ref: docs/adr/0014-memory-floor-lowering.md §D1 (bump allocator), §D2 (L3
#      baseline + deferred inverse), §D3 (reuse → dedicated load/store),
#      §D4 (v1 scope; array/dynamic-N deferred).
# Ref: test/test_cast_instruction.jl / test/test_define.jl — the sibling
#      SSA-create unit-test layout this file mirrors.
# Ref: test/test_per_step_inverse.jl — the `per_step_inverse_check` scaffold
#      (M8.2) the lowering round-trip consumes.
# Ref: CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct values), Rule 5
#      (mutation-proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# Short aliases for the internals under test (not exported — the public API
# surface is `lower_vm` / `initial_state` / `run!` / `unrun!`).
const _MS = BennettVM.MemoryStore
const _ML = BennettVM.MemoryLoad
const _IState_MF = BennettVM.IState

# Build a running IState with the given locals (memory empty unless given).
_istate(locals::Dict{Symbol,Int64}) =
    _IState_MF(1, locals, :running)
_istate(locals::Dict{Symbol,Int64}, mem::Dict{Int64,Int64}) =
    _IState_MF(1, locals, :running, mem)

@testset "memory floor (scalar IRAlloca/IRStore/IRLoad; ADR 0014)" begin

    # ------------------------------------------------------------------
    # (1) MemoryStore forward semantics.
    # ------------------------------------------------------------------
    @testset "MemoryStore forward — write a cell, value survives" begin
        # ptr `p` holds address 1; value `v` holds 7. Store v into M[1].
        s = _istate(Dict(:p => Int64(1), :v => Int64(7)))
        BennettVM.forward(_MS(:p, :v), s)
        @test s.memory[1] == 7          # the cell now holds 7
        @test s.locals[:v] == 7         # value SSA name SURVIVES (store ≠ consume)
        @test s.locals[:p] == 1         # pointer unchanged
        @test s.pc == 2                 # pc bumped

        # Literal value: store i32 9 into M[2].
        s2 = _istate(Dict(:q => Int64(2)))
        BennettVM.forward(_MS(:q, Int64(9)), s2)
        @test s2.memory[2] == 9
    end

    # ------------------------------------------------------------------
    # (2) MemoryLoad forward semantics + zero-init.
    # ------------------------------------------------------------------
    @testset "MemoryLoad forward — read a cell; absent reads as 0" begin
        # Stored cell: M[1] = 7, ptr p → 1. Load into d.
        s = _istate(Dict(:p => Int64(1)), Dict(Int64(1) => Int64(7)))
        BennettVM.forward(_ML(:d, :p), s)
        @test s.locals[:d] == 7         # read the written value
        @test s.pc == 2

        # Zero-init: a load of a never-stored address returns 0 (Int64(0),
        # not `nothing`/KeyError) — the LLVM alloca-then-load-uninitialised
        # case. ptr q → address 5, which `s.memory` does not contain.
        s2 = _istate(Dict(:q => Int64(5)))
        BennettVM.forward(_ML(:d, :q), s2)
        @test s2.locals[:d] === Int64(0)
        @test !haskey(s2.memory, 5)     # the load did NOT materialise the cell
    end

    # Store-then-load round trip at the forward level (the canonical pairing).
    @testset "store-then-load returns the stored value" begin
        s = _istate(Dict(:p => Int64(3), :v => Int64(42)))
        BennettVM.forward(_MS(:p, :v), s)   # M[3] := 42
        BennettVM.forward(_ML(:d, :p), s)   # d := M[3]
        @test s.locals[:d] == 42
    end

    # ------------------------------------------------------------------
    # (3) Overwrite at the forward level (the loop / cross-iteration case).
    # ------------------------------------------------------------------
    @testset "forward overwrite is silent (cross-iteration case)" begin
        s = _istate(Dict(:p => Int64(1), :v1 => Int64(10), :v2 => Int64(20)))
        BennettVM.forward(_MS(:p, :v1), s)
        @test s.memory[1] == 10
        BennettVM.forward(_MS(:p, :v2), s)  # overwrite the same cell
        @test s.memory[1] == 20

        # A second load overwrites `dest` without error.
        s2 = _istate(Dict(:p => Int64(1), :d => Int64(99)),
                     Dict(Int64(1) => Int64(5)))
        BennettVM.forward(_ML(:d, :p), s2)
        @test s2.locals[:d] == 5            # overwritten from 99 to 5
    end

    # ------------------------------------------------------------------
    # (4) Constructor validation (Rule 1).
    # ------------------------------------------------------------------
    @testset "constructor validation" begin
        # MemoryLoad: dest === ptr is an SSA single-assignment violation.
        @test_throws ErrorException _ML(:x, :x)
        # Valid constructions do not throw.
        @test _ML(:d, :p) isa _ML
        @test _MS(:p, :v) isa _MS
        @test _MS(:p, Int64(7)) isa _MS     # literal value is fine
    end

    # ------------------------------------------------------------------
    # (5) is_injective == false for BOTH — the L3 baseline (load-bearing).
    # ------------------------------------------------------------------
    @testset "is_injective is false (non-injective → L3 checkpoints)" begin
        @test BennettVM.is_injective(_MS) == false
        @test BennettVM.is_injective(_ML) == false
        # Value-level dispatch agrees (the fallback routes type→value).
        @test BennettVM.is_injective(_MS(:p, :v)) == false
        @test BennettVM.is_injective(_ML(:d, :p)) == false
        # Contrast: the EXCHANGE form IS injective (the deferred L1 reuse).
        @test BennettVM.is_injective(BennettVM.MemoryInterchange) == true
    end

    # ------------------------------------------------------------------
    # (6) inverse raises the deferral error (reverse is L3-only).
    # ------------------------------------------------------------------
    @testset "inverse is deferred (raises; reverse is L3 checkpoint-replay)" begin
        s = _istate(Dict(:p => Int64(1)))
        err_store = try
            BennettVM.inverse(_MS(:p, Int64(1)), s, nothing); nothing
        catch e; e end
        @test err_store isa ErrorException
        @test occursin("MemoryStore", err_store.msg)
        @test occursin("L3", err_store.msg)
        @test occursin("ADR 0014", err_store.msg)

        err_load = try
            BennettVM.inverse(_ML(:d, :p), s, nothing); nothing
        catch e; e end
        @test err_load isa ErrorException
        @test occursin("MemoryLoad", err_load.msg)
        @test occursin("L3", err_load.msg)
        @test occursin("ADR 0014", err_load.msg)
    end

    # ------------------------------------------------------------------
    # (7)+(8) Hand-built scalar ParsedIR: lower → run → round-trip.
    # ------------------------------------------------------------------
    # A single-block routine mirroring the C `through_mem` shape but
    # hand-built, so the test does not depend on Bennett's `.ll` extractor
    # (the C-gate, test_memory_floor_cll.jl, exercises that path):
    #
    #   alloca a  (i32, 1)        # pointer __a → bump address 1
    #   alloca b  (i32, 1)        # pointer __b → bump address 2
    #   store __a, n              # M[1] := n
    #   load  t = __a             # t := M[1]
    #   u = t + 1                 # binop
    #   store __b, u              # M[2] := n + 1
    #   load  r = __b             # r := M[2]
    #   ret r                     # result key :r
    #
    # Oracle: r == n + 1. The bump allocator assigns __a→1, __b→2 (DISTINCT
    # addresses, testset 8). Reversal is L3-only (every body op is
    # non-injective; their per-instruction inverse is deferred).
    @testset "hand-built scalar ParsedIR lowers, runs, round-trips (L3)" begin
        block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__a, 32, Bennett.ConstOperand(1)),
                Bennett.IRAlloca(:__b, 32, Bennett.ConstOperand(1)),
                Bennett.IRStore(Bennett.SSAOperand(:__a),
                                Bennett.SSAOperand(:__n), 32),
                Bennett.IRLoad(:__t, Bennett.SSAOperand(:__a), 32),
                Bennett.IRBinOp(:__u, :add, Bennett.SSAOperand(:__t),
                                Bennett.ConstOperand(1), 32),
                Bennett.IRStore(Bennett.SSAOperand(:__b),
                                Bennett.SSAOperand(:__u), 32),
                Bennett.IRLoad(:__r, Bennett.SSAOperand(:__b), 32),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__r), 32),
        )
        parsed = Bennett.ParsedIR(32, [(:__n, 32)], [block], [32])
        vm = lower_vm(parsed; opts=:hand_mem)

        # (8) Bump-allocator scheme: the two scalar allocas get DISTINCT base
        #     addresses 1 and 2. Witnessed after a forward run via the
        #     pointer SSA values that the bump-allocator Define materialised.
        rs0 = initial_state(vm, Dict(:__n => Int64(5)))
        run!(rs0, vm; checkpoint_interval=4)
        r0 = result(rs0)
        @test r0[:__a] == 1            # first alloca → address 1
        @test r0[:__b] == 2            # second alloca → address 2 (distinct)
        @test r0[:__a] != r0[:__b]     # the load-bearing distinctness claim

        # (7a) Forward result matches the hand-computed oracle n+1 across a
        #      range of inputs (Rule 4 — known-correct values). The i32 add
        #      now computes in i32 semantics (ADR 0012 R1, bead bennettvm-bgc):
        #      `result` carries the LOW-32-BIT representation of the i32 value,
        #      so a NEGATIVE oracle (n=-3 → -2) is the zero-extended low-32-bit
        #      pattern `(n+1) & 0xFFFFFFFF`, not the sign-extended Int64. For
        #      non-negative results the mask is a no-op. (Pre-bgc the lowering
        #      did not mask, so -2 carried as sign-extended Int64; the masked
        #      form is the correct i32 carrier — every op re-extracts it.)
        _m32 = (Int64(1) << 32) - 1
        for n in (Int64(0), Int64(1), Int64(5), Int64(40), Int64(-3))
            rs = initial_state(vm, Dict(:__n => n))
            run!(rs, vm; checkpoint_interval=4)
            @test is_halted(rs)
            @test result(rs)[:__r] == ((n + 1) & _m32)   # ORACLE: i32 (n+1)

            # (7b) Aggregate run!/unrun! to empty history (P0.6).
            unrun!(rs, vm)
            @test rs.current == rs.initial
            @test isempty(rs.history)
            @test rs.step_count == 0
        end

        # (7c) Per-step inverse (L3) at two checkpoint densities — catches a
        #      mid-program (e.g. store/load) reversal bug that the aggregate
        #      round-trip can mask. Empty must_cache_set → pure L3 path
        #      (the only path that reverses non-injective memory ops).
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(:__n => Int64(7));
                checkpoint_interval = K,
                label = "hand_mem/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (9) scope lift: dynamic-N alloca now lowers to a DynAlloca (bead 0zn).
    #     NOTE: the static-array case (ConstOperand(N>1)) lowers under the
    #     array floor (ADR 0009 Case A Unit 1, test/test_array_floor.jl); the
    #     dynamic-N (SSAOperand) case is now lifted too — it lowers to a
    #     `DynAlloca` (`src/ir/alloca.jl`) instead of raising. This testset
    #     was retargeted from the original "dynamic-N raises (deferred 0zn)"
    #     to track that v2 lift; the full DynAlloca semantics live in
    #     test/test_alloca_delta.jl.
    # ------------------------------------------------------------------
    @testset "scope lift — dynamic-N IRAlloca lowers to DynAlloca (bead 0zn)" begin
        # Dynamic-N alloca: SSAOperand n_elems (the VLA / Case A dynamic-size
        # case). As of bead 0zn it lowers to a `DynAlloca` (frozen-base +
        # (base, n) L2 delta), no longer a Rule-1 reject.
        dyn_block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__dyn, 32, Bennett.SSAOperand(:__n)),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__dyn), 32),
        )
        dyn_parsed = Bennett.ParsedIR(32, [(:__n, 32)], [dyn_block], [32])
        dyn_vm = lower_vm(dyn_parsed; opts=:dyn)
        dynallocas = filter(i -> i isa BennettVM.DynAlloca,
                            first(dyn_vm.blocks).instructions)
        @test length(dynallocas) == 1
        @test dynallocas[1].dest == :__dyn
        @test dynallocas[1].n_operand == :__n
    end
end

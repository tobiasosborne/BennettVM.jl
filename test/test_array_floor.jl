# test/test_array_floor.jl — static-size array memory floor (SC9 Case A
# Unit 1; ADR 0009 Decisions 2b & 4; bead `bennettvm-ekc` precursor). The
# array analogue of `test/test_memory_floor.jl`.
#
# # What this file pins
#
# Unit 1 of SC9 Case A lifts the scalar memory floor (ADR 0014, n_elems=1)
# to a **static-size array**: an `IRAlloca` with `n_elems = ConstOperand(N)`,
# `N > 1`, reserving N consecutive heap cells, plus runtime-indexed element
# access `arr[i]` via `IRVarGEP(dest, base, index, elem_width)` which lowers
# to the new `VarGEP` VM instruction (`src/ir/array_index.jl`).
#
# Two pieces are exercised end-to-end:
#
#   1. `_lower_alloca!` extended for `ConstOperand(N>=1)` — the bump
#      allocator advances by N cells (`base … base+N-1`), still emitting
#      `Define(dest, base, :add, 0)` to materialise the pointer. The scalar
#      n_elems=1 case (ADR 0014) is the N=1 special case, unchanged.
#   2. `IRVarGEP` → `VarGEP(dest, base, index, stride)` with stride in CELLS.
#      `VarGEP.forward` computes `s.locals[dest] = base + index*stride`, a
#      runtime element-address create reversed via L3 (the MemoryLoad
#      pattern; NO new delta in this unit — the L2 (addr,old) store-delta is
#      a later bead, `bennettvm-ekc`). Dynamic-N (`SSAOperand` n_elems) is now
#      LIFTED (bead `bennettvm-0zn`): it lowers to a `DynAlloca` rather than
#      raising — testset (7) tracks that lift (full semantics in
#      `test/test_alloca_delta.jl`).
#
# # Addressing convention (the load-bearing choice; report item (d))
#
# **Stride = 1 CELL per element, regardless of `elem_width` (bits).**
# `IState.memory` is `Dict{Int64,Int64}` — ONE Int64 per cell, NOT a byte
# array. The bump allocator reserves one cell per element (`_lower_alloca!`
# advances the cursor by N), so a static array of N elements occupies cells
# `base … base+N-1` and `arr[i]` lives at cell `base + i`. The element bit
# width (`IRVarGEP.elem_width` / `IRAlloca.elem_width`) does NOT enter the
# address: the VM is cell-addressed, not byte-addressed. Stride is therefore
# `1`, exactly matching the cursor step. (Were the VM byte-addressed, stride
# would be `elem_width ÷ 8` bytes and the bump allocator would advance by
# `N * elem_width ÷ 8`; the two MUST stay consistent or `arr[i]` would index
# a different cell than the alloca reserved — they are both CELLS here.)
#
# The tests below pin (Rule 4 — every @test asserts a known-correct value):
#
#   1. **VarGEP forward semantics** — `dest = base + index*stride` over a
#      hand-built IState, incl. the orchestrator's example base=5,index=3,
#      stride=1 → 8; a stride>1 case to prove the multiply is live; SSA and
#      literal index operands; the base/index SSA names SURVIVE (a GEP reads,
#      never consumes); pc bumped.
#   2. **VarGEP constructor validation** (Rule 1): dest === base rejected.
#   3. **`is_injective(VarGEP) == false`** — load-bearing: a create that may
#      overwrite a prior `dest` across loop iterations is conservatively
#      non-injective → L3 (the MemoryLoad rationale).
#   4. **`inverse` raises the deferral error** — reverse is L3-only.
#   5. **Hand-built static-array ParsedIR** (`alloca N=4; arr[0..3]=…; gep
#      arr[idx]; load; ret`) lowered via the real `lower_vm`, run forward
#      matching a hand-computed irreversible oracle bit-for-bit, and round-
#      tripped under L3 (run!/unrun! to empty history; `per_step_inverse_check`
#      at K ∈ {1, 4}).
#   6. **Bump allocator reserves N cells** — the array base and the next
#      alloca's base differ by N (distinct, non-overlapping regions).
#   7. **v1→v2 lift**: dynamic-N `IRAlloca` (`SSAOperand` n_elems) now lowers
#      to a `DynAlloca` (bead `bennettvm-0zn`), no longer a "deferred" reject.
#   8. **Edge cases**: a non-positive `ConstOperand(N<=0)` alloca fails loud
#      (malformed IR); a scalar-then-array alloca mix yields non-overlapping
#      regions (cursor monotonicity: array base = scalar base + 1).
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree
#
# Two perturbations of `VarGEP.forward`, each confirmed RED then restored:
#   - drop `+base` (compute `index*stride`): caught by testset (1) AND the
#     hand-built forward-oracle in testset (5) — the gep returns the wrong
#     cell, so the load reads the wrong value and the oracle diverges.
#   - drop `*stride` (compute `base+index`): INVISIBLE to testset (5) and to
#     the stride-1 cases of (1) — every *lowered* gep uses stride=1, so
#     `base+index*1 ≡ base+index`. It is caught ONLY by testset (1)'s stride=2
#     case (`s2`: 10+4*2=18, vs 10+4=14). So testset (1)'s stride>1 case is the
#     SOLE guard on the multiply — do not remove it (Rule 4/5).
#
# Ref: src/ir/array_index.jl (the `VarGEP` implementation; the L3-baseline
#      rationale + the stride-in-cells convention in its top-of-module
#      docstring).
# Ref: src/ir/memory_floor.jl (the sibling MemoryStore/MemoryLoad L3 floor).
# Ref: docs/adr/0009-dynamic-size-memory.md Decision 2b (addr=base+i*stride),
#      Decision 4 (the prerequisite chain; arrays N>1 + IRVarGEP).
# Ref: docs/adr/0013-reversible-memory-architecture.md §D-2 GEP row (l.76);
#      docs/adr/0014-memory-floor-lowering.md §D1 (bump allocator), §D4
#      (arrays/GEP/dynamic-N deferred — this file lifts arrays + GEP).
# Ref: test/test_memory_floor.jl — the scalar sibling this file mirrors.
# Ref: test/test_per_step_inverse.jl — the `per_step_inverse_check` scaffold.
# Ref: CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct values), Rule 5
#      (mutation-proof), Rule 11 (literate).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# Short aliases for the internals under test (not exported — the public API
# surface is `lower_vm` / `initial_state` / `run!` / `unrun!`).
const _GEP = BennettVM.VarGEP
const _IState_AF = BennettVM.IState

_istate_af(locals::Dict{Symbol,Int64}) = _IState_AF(1, locals, :running)

@testset "array floor (static-N IRAlloca + IRVarGEP; ADR 0009 Case A Unit 1)" begin

    # ------------------------------------------------------------------
    # (1) VarGEP forward semantics: dest = base + index*stride.
    # ------------------------------------------------------------------
    @testset "VarGEP forward — address arithmetic base + index*stride" begin
        # The orchestrator's pinned example: base=5, index=3, stride=1 → 8.
        s = _istate_af(Dict(:b => Int64(5), :i => Int64(3)))
        BennettVM.forward(_GEP(:d, :b, :i, Int64(1)), s)
        @test s.locals[:d] == 8         # 5 + 3*1
        @test s.locals[:b] == 5         # base SSA name SURVIVES (gep ≠ consume)
        @test s.locals[:i] == 3         # index SSA name SURVIVES
        @test s.pc == 2                 # pc bumped

        # stride > 1 proves the multiply is live (a byte-addressed VM would
        # use stride=elem_width÷8; this VM is cell-addressed so stride is the
        # cursor step, but the field is exercised at >1 to catch a dropped *).
        s2 = _istate_af(Dict(:b => Int64(10), :i => Int64(4)))
        BennettVM.forward(_GEP(:d, :b, :i, Int64(2)), s2)
        @test s2.locals[:d] == 18       # 10 + 4*2

        # index = 0 → the base itself (arr[0] aliases the pointer).
        s3 = _istate_af(Dict(:b => Int64(7), :i => Int64(0)))
        BennettVM.forward(_GEP(:d, :b, :i, Int64(1)), s3)
        @test s3.locals[:d] == 7

        # Literal index operand (LLVM `getelementptr ... i64 2`).
        s4 = _istate_af(Dict(:b => Int64(100)))
        BennettVM.forward(_GEP(:d, :b, Int64(2), Int64(1)), s4)
        @test s4.locals[:d] == 102

        # Overwrite at the forward level (the loop / cross-iteration case):
        # a second gep overwrites `dest` without error.
        s5 = _istate_af(Dict(:b => Int64(3), :i => Int64(1), :d => Int64(999)))
        BennettVM.forward(_GEP(:d, :b, :i, Int64(1)), s5)
        @test s5.locals[:d] == 4        # overwritten 999 → 3+1
    end

    # ------------------------------------------------------------------
    # (2) Constructor validation (Rule 1).
    # ------------------------------------------------------------------
    @testset "VarGEP constructor validation" begin
        # dest === base is an SSA single-assignment violation (a name cannot
        # be both defined and read as the base by the same instruction).
        @test_throws ErrorException _GEP(:x, :x, :i, Int64(1))
        # Valid constructions do not throw.
        @test _GEP(:d, :b, :i, Int64(1)) isa _GEP
        @test _GEP(:d, :b, Int64(0), Int64(1)) isa _GEP    # literal index ok
    end

    # ------------------------------------------------------------------
    # (3) is_injective == false — the L3 baseline (load-bearing).
    # ------------------------------------------------------------------
    @testset "is_injective is false (non-injective → L3 checkpoints)" begin
        @test BennettVM.is_injective(_GEP) == false
        @test BennettVM.is_injective(_GEP(:d, :b, :i, Int64(1))) == false
    end

    # ------------------------------------------------------------------
    # (4) inverse raises the deferral error (reverse is L3-only).
    # ------------------------------------------------------------------
    @testset "inverse is deferred (raises; reverse is L3 checkpoint-replay)" begin
        s = _istate_af(Dict(:b => Int64(1), :i => Int64(0)))
        err = try
            BennettVM.inverse(_GEP(:d, :b, :i, Int64(1)), s, nothing); nothing
        catch e; e end
        @test err isa ErrorException
        @test occursin("VarGEP", err.msg)
        @test occursin("L3", err.msg)
        @test occursin("ADR 0014", err.msg)
    end

    # ------------------------------------------------------------------
    # (5)+(6) Hand-built static-array ParsedIR: lower → run → round-trip.
    # ------------------------------------------------------------------
    # A single-block routine that allocates a 4-element i32 array, writes a
    # constant pattern, then reads back ONE element at a RUNTIME index:
    #
    #   arr   = alloca(i32, N=4)     # pointer __arr → bump base B; cells B..B+3
    #   store __arr[via base], 10    # M[B+0] := 10   (gep idx 0)
    #   store gep(__arr, 1), 20      # M[B+1] := 20
    #   store gep(__arr, 2), 30      # M[B+2] := 30
    #   store gep(__arr, 3), 40      # M[B+3] := 40
    #   p     = gep(__arr, __idx)    # p := B + __idx   (RUNTIME index)
    #   r     = load p               # r := M[B + __idx]
    #   ret r
    #
    # Oracle: r == [10,20,30,40][__idx+1]  (Julia 1-based) == 10*(__idx+1).
    # The four stores use IRVarGEP-produced pointers (constant indices 0..3);
    # the read uses an IRVarGEP-produced pointer at a runtime index. This
    # exercises N>1 alloca + IRVarGEP (const & runtime indices) + indexed
    # IRStore/IRLoad flowing a gep pointer through unchanged.
    @testset "hand-built static-array ParsedIR lowers, runs, round-trips (L3)" begin
        # Helper: gep producing a pointer SSA name for arr[k] (constant k).
        gep(dest, k) = Bennett.IRVarGEP(dest, Bennett.SSAOperand(:__arr),
                                        Bennett.ConstOperand(k), 32)
        block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
                # arr[0] = 10  (gep then store)
                gep(:__p0, 0),
                Bennett.IRStore(Bennett.SSAOperand(:__p0),
                                Bennett.ConstOperand(10), 32),
                # arr[1] = 20
                gep(:__p1, 1),
                Bennett.IRStore(Bennett.SSAOperand(:__p1),
                                Bennett.ConstOperand(20), 32),
                # arr[2] = 30
                gep(:__p2, 2),
                Bennett.IRStore(Bennett.SSAOperand(:__p2),
                                Bennett.ConstOperand(30), 32),
                # arr[3] = 40
                gep(:__p3, 3),
                Bennett.IRStore(Bennett.SSAOperand(:__p3),
                                Bennett.ConstOperand(40), 32),
                # p = gep(arr, idx)  — RUNTIME index
                Bennett.IRVarGEP(:__p, Bennett.SSAOperand(:__arr),
                                 Bennett.SSAOperand(:__idx), 32),
                # r = load p
                Bennett.IRLoad(:__r, Bennett.SSAOperand(:__p), 32),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__r), 32),
        )
        parsed = Bennett.ParsedIR(32, [(:__idx, 32)], [block], [32])
        vm = lower_vm(parsed; opts=:hand_arr)

        # (6) Bump allocator reserves N=4 cells: the array base is 1 and the
        #     four element addresses are 1..4. Witnessed via the gep pointer
        #     SSA values after a forward run. (No second alloca here, so the
        #     non-overlap claim is pinned by the element-address spread.)
        rs0 = initial_state(vm, Dict(:__idx => Int64(0)))
        run!(rs0, vm; checkpoint_interval=4)
        r0 = result(rs0)
        @test r0[:__arr] == 1          # alloca base = bump cursor start
        @test r0[:__p0] == 1           # arr[0] @ base+0
        @test r0[:__p1] == 2           # arr[1] @ base+1
        @test r0[:__p2] == 3
        @test r0[:__p3] == 4           # arr[3] @ base+3 — the 4th reserved cell
        @test r0[:__p3] - r0[:__arr] == 3   # N-1 spread: N=4 cells reserved

        # (5a) Forward result matches the oracle for EVERY in-range index
        #      (Rule 4 — known-correct values). arr = [10,20,30,40].
        oracle = Int64[10, 20, 30, 40]
        for idx in (Int64(0), Int64(1), Int64(2), Int64(3))
            rs = initial_state(vm, Dict(:__idx => idx))
            run!(rs, vm; checkpoint_interval=4)
            @test is_halted(rs)
            @test result(rs)[:__r] == oracle[idx + 1]   # arr[idx] (0-based)

            # (5b) Aggregate run!/unrun! to empty history (P0.6).
            unrun!(rs, vm)
            @test rs.current == rs.initial
            @test isempty(rs.history)
            @test rs.step_count == 0
        end

        # (5c) Per-step inverse (L3) at two checkpoint densities — catches a
        #      mid-program (gep/store/load) reversal bug the aggregate round-
        #      trip can mask. Empty must_cache_set → pure L3 path.
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(:__idx => Int64(2));
                checkpoint_interval = K,
                label = "hand_arr/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (7) v1→v2 lift: dynamic-N alloca now LOWERS to a DynAlloca (bead 0zn).
    # ------------------------------------------------------------------
    @testset "dynamic-N IRAlloca lowers to DynAlloca (bead 0zn)" begin
        # SSAOperand n_elems is the dynamic-N (VLA) case. As of bead 0zn it is
        # NO LONGER rejected: it lowers to a `DynAlloca` (`src/ir/alloca.jl`)
        # whose forward materialises the pointer at a frozen compile-time base
        # and whose L2 (base, n) delta retracts the region on reverse. (The
        # full DynAlloca behaviour — delta, round-trip, soundness lemma — is
        # pinned in `test_alloca_delta.jl`; here we only confirm the ingest
        # dispatch produces a DynAlloca, the positive half of the v1→v2 lift.)
        dyn_block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__dyn, 32, Bennett.SSAOperand(:__n)),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__dyn), 32),
        )
        dyn_parsed = Bennett.ParsedIR(32, [(:__n, 32)], [dyn_block], [32])
        dyn_vm = lower_vm(dyn_parsed; opts=:dyn)
        dyn_entry = first(dyn_vm.blocks)
        dynallocas = filter(i -> i isa BennettVM.DynAlloca, dyn_entry.instructions)
        @test length(dynallocas) == 1
        @test dynallocas[1].dest == :__dyn
        @test dynallocas[1].n_operand == :__n
        @test dynallocas[1].base == 1            # frozen compile-time base

        # Static array alloca (ConstOperand(N>1)) now LOWERS (no longer the
        # scalar-floor "deferred to v2" reject) — the positive half of the
        # v1→v2 lift, pinned so a regression to the old reject is caught.
        arr_block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__arr, 32, Bennett.ConstOperand(4)),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__arr), 32),
        )
        arr_parsed = Bennett.ParsedIR(32, [(:__n, 32)], [arr_block], [32])
        vm = lower_vm(arr_parsed; opts=:arr)
        rs = initial_state(vm, Dict(:__n => Int64(0)))
        run!(rs, vm; checkpoint_interval=4)
        @test result(rs)[:__arr] == 1   # base materialised; no throw
    end

    # ------------------------------------------------------------------
    # (8) Edge cases: N<=0 alloca rejects; scalar+array regions don't overlap.
    # ------------------------------------------------------------------
    @testset "edge: N<=0 alloca rejects; scalar+array regions non-overlapping" begin
        # A non-positive ConstOperand(N) is malformed IR — `_lower_alloca!`
        # must fail LOUD (Rule 1, ingest.jl:340), not reserve zero/negative
        # cells and miscompile the bump cursor.
        z_block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[Bennett.IRAlloca(:__z, 32, Bennett.ConstOperand(0))],
            Bennett.IRRet(Bennett.SSAOperand(:__z), 32),
        )
        z_parsed = Bennett.ParsedIR(32, [(:__n, 32)], [z_block], [32])
        err = try lower_vm(z_parsed; opts=:z); nothing catch e; e end
        @test err isa ErrorException
        @test occursin("IRAlloca", err.msg)
        @test occursin("N >= 1", err.msg)
        @test occursin("malformed", err.msg)

        # A scalar alloca (1 cell) FOLLOWED by an array alloca (4 cells): the
        # bump cursor is monotone, so the array base = scalar base + 1 and the
        # two regions (scalar @ B0; array @ B0+1 … B0+4) do NOT overlap. This
        # pins cursor monotonicity across mixed scalar/array allocas.
        mix_block = Bennett.IRBasicBlock(
            :entry,
            Bennett.IRInst[
                Bennett.IRAlloca(:__sc, 32, Bennett.ConstOperand(1)),
                Bennett.IRAlloca(:__ar, 32, Bennett.ConstOperand(4)),
            ],
            Bennett.IRRet(Bennett.SSAOperand(:__sc), 32),
        )
        mix_parsed = Bennett.ParsedIR(32, [(:__n, 32)], [mix_block], [32])
        vmix = lower_vm(mix_parsed; opts=:mix)
        rsm = initial_state(vmix, Dict(:__n => Int64(0)))
        run!(rsm, vmix; checkpoint_interval=4)
        rm = result(rsm)
        @test rm[:__ar] == rm[:__sc] + 1   # array base just past the scalar's 1 cell
        @test rm[:__ar] - rm[:__sc] >= 1   # non-overlap: the scalar cell is clear
    end
end

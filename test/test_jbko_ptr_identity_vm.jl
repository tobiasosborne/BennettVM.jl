# test/test_jbko_ptr_identity_vm.jl — the BennettVM (downstream) half of
# Bennett.jl bead `Bennett-jbko`.
#
# # What upstream changed
#
# Under the closed-world `ptr_cells` gate, `ptrtoint ptr %p to i64` no longer
# fails loud when it is a POINTER-IDENTITY coercion. It is admitted as the
# width-64 cell identity
#   IRBinOp(dest, :or, <src>, ConstOperand(0), 64)
# iff the SOURCE is a certified cell-valued pointer SSA (an `extractvalue` of a
# StructType pointer field, or a `load` of a pointer, addrspace 0, 64->64) AND
# EVERY use of the result is an `icmp eq`/`icmp ne` against an in-model SSA
# value or the zero cell. This is wall 5 of the `bennettvm-xkl` push!-Vector
# chain — Julia's `MemoryRef` CONCURRENT-MUTATION GUARD in `_growend!` `%L84`,
# which compares a MemoryRef's CURRENT data pointer against a CAPTURED copy of
# it that codegen read back as a plain `i64`.
#
# # Why BVM has ZERO src changes (and what this file is for)
#
# `IRBinOp` ingests to `Define` (`src/ir/ingest_body.jl` / `define_instruction.jl`),
# `:or` is in the accepted op set and evaluates as `(am | bm) & mask`, so
# `x | 0 == x`. `IRICmp` ingests to a `Define` carrying the predicate
# (`ingest_body.jl:112-119`), with `IRICmp.width` the OPERAND width (jbko emits
# 64 on both sides). Both are non-destructive SSA creates, reversed by the
# standard L2/L3 machinery — the VM never learns an operand was a pointer.
#
# What has NEVER been executed is the END-TO-END claim, and in particular the
# DETERMINISM argument that licenses the whole arm:
#
#   * a pointer under `ptr_cells` is ONE Int64 VM cell, handed out by BVM's
#     DETERMINISTIC, INJECTIVE bump allocator (`ARENA_BASE + arena_top`,
#     `ARENA_BASE = Int64(1) << 40`). Two distinct live allocations therefore
#     have distinct cell values, and `eq`/`ne` on them is a LOCATION-IDENTITY
#     predicate — invariant under the address->cell map, hence a SOURCE-LEVEL
#     fact rather than a LAYOUT fact. Test (2) pins the coerced cell at exactly
#     `ARENA_BASE` (the first malloc), which is the operational form of that
#     claim: it is a value the VM chose deterministically, not a host address.
#   * ORDERING and ARITHMETIC on that cell are NOT invariant and stay fail-loud
#     upstream (`../Bennett.jl/test/test_jbko_ptr_identity_icmp.jl` gates (C)-(F));
#     nothing here can or should test them.
#
# # What this pins (Rule 4 — known values, never "didn't throw")
#
#   (1) the ParsedIR BVM receives really carries the jbko emission
#       `IRBinOp(:c, :or, SSAOperand(:po), ConstOperand(0), 64)` immediately
#       consumed by `IRICmp(:e1, :eq, _, SSAOperand(:c), 64)`, with the 8g7m
#       sibling `IRICmp(:e2, :eq, …, 64)` intact, and the dead throw arm reduced
#       to the Bennett-utzc `:__unreachable__` sink shape;
#   (2) `lower_vm` produces a `Define` for the `:or` identity and a `Define`
#       carrying the `:eq` predicate;
#   (3) GUARD-MATCH (capture == current data pointer) takes the `ok` arm and
#       `run!` reaches `:halted` with the oracle result `x + 1`, and the coerced
#       cell equals the captured cell equals `ARENA_BASE`;
#   (4) GUARD-MISMATCH (capture is a DIFFERENT allocation) takes the throw arm:
#       `run!` raises loudly at the `:__unreachable__` halt sink with
#       `status === :error` — a faithful reversible throw, never a silent wrong
#       answer. This is the failure mode the determinism argument leans on;
#   (5) `unrun!` returns the EXACT initial state with a drained history under
#       BOTH history regimes AND in BOTH branch outcomes (including from the
#       TRAPPED mid-run state, which `run!` deliberately leaves for inspection);
#   (6) `per_step_inverse_check` passes at K ∈ {1, 4} on the match path.
#
# # HONEST SCOPE BOUNDARY — this file is the C/word tier only
#
# The fixtures allocate with `malloc` (the C heap tier). The REAL `_growend!`
# guard arrives in a JULIA-tier program and cannot yet run E2E: after jbko the
# push! closed-world set advances only as far as `%L93`, where it meets the
# LIVE whole-struct `store { ptr, ptr }` wall (Bennett-lgzx / U114), with a
# further 583s coverage gap at `%idxend` behind it. Nothing here claims
# otherwise; this file proves the MECHANISM, not the corpus.
#
# # Ref
#   * `../Bennett.jl/test/test_jbko_ptr_identity_icmp.jl` — the upstream gate
#     (the (P1)-(P4) predicates + the adversarial reject matrix).
#   * `../Bennett.jl/src/extract/instructions.jl` — the jbko arm and its
#     determinism comment block.
#   * `test/test_utzc_unreachable_sink.jl` — the `:__unreachable__` sink itself.
#   * `test/test_3vf2_dead_use_global_load.jl` — the hand-written-`.ll`-through-
#     the-real-front-end E2E idiom reused here.

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _BVJ = BennettVM
const _BNJ = Bennett

# Both routines build a `{ptr,ptr}` "MemoryRef" in the arena holding
# `(buf, buf)`, capture a pointer as a plain `i64` cell, then rebuild the
# aggregate the way Julia's codegen does (load both halves -> insertvalue ->
# extractvalue) and run the two-halved guard: the `.ptr_or_offset` half through
# the jbko coercion, the `.mem` half through the untouched Bennett-8g7m
# pointer-typed `icmp eq`.
#
#   guard_match    — captures `%buf`: the guard PASSES, the `ok` arm returns x+1.
#   guard_mismatch — captures `%alt`, a DIFFERENT allocation: the guard FAILS
#                    and the utzc sink traps. The two mallocs get distinct
#                    arena bases, which is exactly the injectivity the
#                    determinism argument requires.
const _IRJBKO = """
declare ptr @malloc(i64)
declare void @ijl_throw(ptr)

define i64 @guard_match(i64 %x) {
entry:
  %buf = call ptr @malloc(i64 32)
  %alt = call ptr @malloc(i64 32)
  %refslot = call ptr @malloc(i64 16)
  %capslot = call ptr @malloc(i64 8)
  %f0 = getelementptr {ptr, ptr}, ptr %refslot, i32 0, i32 0
  %f1 = getelementptr {ptr, ptr}, ptr %refslot, i32 0, i32 1
  store ptr %buf, ptr %f0
  store ptr %buf, ptr %f1
  store ptr %buf, ptr %capslot
  %cap = load i64, ptr %capslot
  %d0 = load ptr, ptr %f0
  %d1 = load ptr, ptr %f1
  %a0 = insertvalue {ptr, ptr} zeroinitializer, ptr %d0, 0
  %ref = insertvalue {ptr, ptr} %a0, ptr %d1, 1
  %po = extractvalue {ptr, ptr} %ref, 0
  %pm = extractvalue {ptr, ptr} %ref, 1
  %c = ptrtoint ptr %po to i64
  %e1 = icmp eq i64 %cap, %c
  %e2 = icmp eq ptr %d1, %pm
  %ok = and i1 %e1, %e2
  br i1 %ok, label %L93, label %L90
L93:
  %r = add i64 %x, 1
  ret i64 %r
L90:
  call void @ijl_throw(ptr %buf)
  unreachable
}

define i64 @guard_mismatch(i64 %x) {
entry:
  %buf = call ptr @malloc(i64 32)
  %alt = call ptr @malloc(i64 32)
  %refslot = call ptr @malloc(i64 16)
  %capslot = call ptr @malloc(i64 8)
  %f0 = getelementptr {ptr, ptr}, ptr %refslot, i32 0, i32 0
  %f1 = getelementptr {ptr, ptr}, ptr %refslot, i32 0, i32 1
  store ptr %buf, ptr %f0
  store ptr %buf, ptr %f1
  store ptr %alt, ptr %capslot
  %cap = load i64, ptr %capslot
  %d0 = load ptr, ptr %f0
  %d1 = load ptr, ptr %f1
  %a0 = insertvalue {ptr, ptr} zeroinitializer, ptr %d0, 0
  %ref = insertvalue {ptr, ptr} %a0, ptr %d1, 1
  %po = extractvalue {ptr, ptr} %ref, 0
  %pm = extractvalue {ptr, ptr} %ref, 1
  %c = ptrtoint ptr %po to i64
  %e1 = icmp eq i64 %cap, %c
  %e2 = icmp eq ptr %d1, %pm
  %ok = and i1 %e1, %e2
  br i1 %ok, label %L93, label %L90
L93:
  %r = add i64 %x, 1
  ret i64 %r
L90:
  call void @ijl_throw(ptr %alt)
  unreachable
}
"""

# BVM's arena base — the value the DETERMINISTIC bump allocator hands to the
# first allocation. Pinned here (not imported) so the test states the constant
# the determinism argument names.
const _JBKO_ARENA_BASE = Int64(1) << 40

_jbko_build(entry) = mktempdir() do dir
    path = joinpath(dir, "jbko.ll")
    write(path, _IRJBKO)
    p = _BNJ.extract_parsed_ir_from_ll(path; entry_function=entry, ptr_cells=true)
    return (p, _BVJ.lower_vm(p))
end

_jbko_insts(pir) = [i for b in pir.blocks for i in b.instructions]

@testset "Bennett-jbko — identity-coerced pointer guard runs and reverses on the VM" begin

    # ==================================================================
    # (1) the handoff shape: the ParsedIR BVM receives really carries the
    #     jbko emission, the 8g7m sibling, and the utzc sink.
    # ==================================================================
    @testset "(1) the ParsedIR BVM receives carries the jbko :or identity" begin
        pir, _ = _jbko_build("guard_match")

        @test [b.label for b in pir.blocks] == [:entry, :L93, :L90]

        insts = _jbko_insts(pir)
        # the jbko emission — a REAL SSA def (the iwo9 consensus-3 shape), not
        # a zero-IR const-prop.
        ors = [i for i in insts if i isa _BNJ.IRBinOp && i.op === :or]
        @test length(ors) == 1
        @test ors[1] == _BNJ.IRBinOp(:c, :or, _BNJ.SSAOperand(:po),
                                     _BNJ.ConstOperand(0), 64)
        # its source is the width-64 `extractvalue` of the ptr struct field
        po = only([i for i in insts if i isa _BNJ.IRExtractValue && i.dest === :po])
        @test po.agg == _BNJ.SSAOperand(:ref)
        @test po.index == 0
        @test po.field_widths == [64, 64]
        # the jbko-admitted comparison, and the UNTOUCHED 8g7m sibling
        e1 = only([i for i in insts if i isa _BNJ.IRICmp && i.dest === :e1])
        @test e1 == _BNJ.IRICmp(:e1, :eq, _BNJ.SSAOperand(:cap),
                                _BNJ.SSAOperand(:c), 64)
        e2 = only([i for i in insts if i isa _BNJ.IRICmp && i.dest === :e2])
        @test e2 == _BNJ.IRICmp(:e2, :eq, _BNJ.SSAOperand(:d1),
                                _BNJ.SSAOperand(:pm), 64)
        # the throw arm is the Bennett-utzc sink shape (a faithful reversible
        # throw), NOT a converted body.
        @test isempty(pir.blocks[3].instructions)
        @test pir.blocks[3].terminator ==
              _BNJ.IRBranch(nothing, :__unreachable__, nothing)
    end

    # ==================================================================
    # (2) lower_vm: BOTH the identity and the compare become `Define`s —
    #     ordinary non-destructive SSA creates. ZERO BVM src changes.
    # ==================================================================
    @testset "(2) lower_vm: :or identity and :eq compare are both Defines" begin
        _, prog = _jbko_build("guard_match")
        defs = [i for b in prog.blocks for i in b.instructions
                if i isa _BVJ.Define]
        @test any(d -> d.target === :c, defs)
        @test any(d -> d.target === :e1, defs)
        @test any(d -> d.target === :e2, defs)
    end

    # ==================================================================
    # (3)+(5)+(6) GUARD MATCH — the `ok` arm, the oracle, exact reversal
    #             under both history regimes, per-step inverse at K in {1,4}.
    # ==================================================================
    @testset "(3)+(5)+(6) guard MATCH: ok arm, oracle, exact reversal" begin
        pir, prog = _jbko_build("guard_match")
        regimes = (("L2 (compute_must_cache)", _BVJ.compute_must_cache(prog)),
                   ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))
        for (rlabel, mcs) in regimes, x in Int64[0, 7, -3, typemax(Int64) - 1]
            s = _BVJ.initial_state(prog, Dict(:x => x))
            init = deepcopy(s.current)
            _BVJ.run!(s, prog; max_steps=10_000, checkpoint_interval=4,
                      must_cache_set=mcs)
            # ANCHOR ($rlabel, x = $x): the guard PASSES, so this is a normal
            # `:halted` exit — never the sink's `:error`.
            @test _BVJ.is_halted(s)
            @test s.current.status === :halted
            res = _BVJ.result(s)
            @test res[:r] == x + 1                 # the ok-arm oracle
            @test res[:x] == x                     # input preserved
            @test res[:e1] == 1                    # the coerced compare fired
            @test res[:e2] == 1                    # the 8g7m sibling fired
            # THE DETERMINISM CLAIM, operational: the coerced integer is a VM
            # CELL VALUE the bump allocator chose (the FIRST allocation, hence
            # exactly ARENA_BASE), not a host address — and it equals the
            # captured cell verbatim, which is why `eq` is the right predicate
            # and `ult` is not (see the upstream arm's comment block).
            @test res[:c] == _JBKO_ARENA_BASE
            @test res[:cap] == res[:c]
            @test res[:buf] == _JBKO_ARENA_BASE
            @test res[:alt] != res[:buf]           # allocator INJECTIVITY
            _BVJ.unrun!(s, prog; max_unsteps=20_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end

        for K in (1, 4)
            @test per_step_inverse_check(prog, Dict(:x => Int64(7));
                                         checkpoint_interval=K,
                                         label="jbko/match/L3/K=$K") === nothing
            @test per_step_inverse_check(prog, Dict(:x => Int64(7));
                                         checkpoint_interval=K,
                                         must_cache_set=_BVJ.compute_must_cache(prog),
                                         label="jbko/match/L2/K=$K") === nothing
        end
    end

    # ==================================================================
    # (4)+(5) GUARD MISMATCH — the throw arm. This is the failure mode the
    #         determinism argument leans on: if the modelled guard ever
    #         disagrees with the native oracle, the program HALTS LOUD at
    #         the `:__unreachable__` sink rather than silently producing a
    #         wrong value (Rule 1). And it STILL reverses exactly from the
    #         trapped mid-run state.
    # ==================================================================
    @testset "(4)+(5) guard MISMATCH: :__unreachable__ trap, still reversible" begin
        pir, prog = _jbko_build("guard_mismatch")
        regimes = (("L2 (compute_must_cache)", _BVJ.compute_must_cache(prog)),
                   ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))
        for (rlabel, mcs) in regimes, x in Int64[0, 7, -3]
            s = _BVJ.initial_state(prog, Dict(:x => x))
            init = deepcopy(s.current)
            err = nothing
            try
                _BVJ.run!(s, prog; max_steps=10_000, checkpoint_interval=4,
                          must_cache_set=mcs)
            catch e
                e isa InterruptException && rethrow()
                err = e
            end
            # ANCHOR ($rlabel, x = $x): the guard FAILS ⇒ the dead arm is
            # TAKEN ⇒ the sink traps loudly.
            @test err !== nothing
            @test err isa ErrorException
            msg = sprint(showerror, err)
            @test occursin("__unreachable__", msg)
            @test occursin("status=:error", msg)
            @test s.current.status === :error
            @test !_BVJ.is_halted(s)
            # ... and the trapped state still reverses EXACTLY (the sink is
            # L1-injective: it touches only `status` and `pc`).
            _BVJ.unrun!(s, prog; max_unsteps=20_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end
    end

end

# test/test_memory_floor_cll.jl — THE EMITTER-AGNOSTIC GATE (bead
# `bennettvm-x9j`, ADR 0014 §D5; ADR 0013 §D-1).
#
# # What this gate proves, and why it is the case's reason to exist
#
# This file proves BennettVM round-trips a **C** program — the executable
# demonstration of emitter-agnosticism (ADR 0013 §D-1 / project-lead
# directive 2026-05-28: BennettVM must be a reversible VM over LLVM opcodes,
# useful to ANY emitter — C, Rust, Julia — and sensible without Bennett.jl).
# Not Julia. C. Compiled with `clang-18 -O0`, flowing through Bennett's
# LANGUAGE-AGNOSTIC `extract_parsed_ir_from_ll` (the same `.ll` entry point a
# Rust or hand-written `.ll` would use), through the real `lower_vm`, to a
# forward run matching the C semantics AND a full L3 round-trip to empty
# history (P0.6).
#
# The C source (`test/reference/through_mem.c`):
#
#     int through_mem(int n) { int s; s = n + 1; return s; }
#
# compiled `-O0` does NOT mem2reg the local `s`, so the LLVM IR is genuine
# heap traffic — two `alloca`s, two `store`s, two `load`s — exactly the
# scalar memory floor this build adds. Before this build `lower_vm` raised at
# `IRAlloca`; this gate is the witness that it now lowers and round-trips.
#
# # Clang-free at test time (committed `.ll`)
#
# The verified clang-18 output is committed alongside the source at
# `test/reference/through_mem.ll`, so the test needs NO clang on the test
# machine (CLAUDE.md Rule 12: local gates, no toolchain assumptions). The
# `.c` is committed too, as provenance — the human-readable source the `.ll`
# was compiled from. The test reads ONLY the `.ll` (via
# `extract_parsed_ir_from_ll`); the `.c` is documentation.
#
# # The extracted ParsedIR (verified this session)
#
#   args = [(:__v1, 32)]      ret_elem_widths = [32]    1 block
#     IRAlloca(:__v2, 32, ConstOperand(1))      # pointer __v2 → bump addr 1
#     IRAlloca(:__v3, 32, ConstOperand(1))      # pointer __v3 → bump addr 2
#     IRStore(ptr=__v2, val=__v1, 32)           # M[1] := n
#     IRLoad(:__v5, ptr=__v2, 32)               # __v5 := M[1]
#     IRBinOp(:__v6, :add, __v5, Const(1), 32)  # __v6 := __v5 + 1
#     IRStore(ptr=__v3, val=__v6, 32)           # M[2] := n + 1
#     IRLoad(:__v8, ptr=__v3, 32)               # __v8 := M[2]
#     IRRet(__v8, 32)                           # return __v8
#
# # The result KEY (pinned empirically)
#
# The IRRet operand is `SSAOperand(:__v8)`, so the routine result lives in
# `result(rs)[:__v8]`. Verified empirically in a REPL probe: `:__v8` is the
# key in `result(rs)` whose value equals the oracle `n + 1` across every
# input (the other live keys — `:__v1` (n), `:__v2` (addr 1), `:__v3`
# (addr 2), `:__v5`, `:__v6` — do not). The argument key is `:__v1`. Both are
# PINNED here so a future extractor renaming surfaces as a failed assertion,
# not a silent miss.
#
# Oracle: `through_mem_ref(n) = n + 1` (the C function's semantics).
#
# # Width caveat (ADR 0014 §D4, ADR 0012 R1)
#
# `IState` cells are `Int64`; the lowering does not mask to the i32 width.
# Oracle agreement holds for inputs whose result fits — every input below is
# small. The round-trip invariant is width-independent (L3 snapshots the raw
# `Int64`).
#
# # Mutation-proof (Rule 5) — performed manually, reverted, NOT in tree
#
# Perturbing the oracle `through_mem_ref` from `n + 1` to `n + 2` makes the
# oracle-anchored forward assertion go RED (VM produced n+1, mutated oracle
# wanted n+2). Confirmed RED, then restored. This pins the gate to a
# known-correct value, not just self-consistency. (The MemoryLoad-forward
# mutation RED is captured in test_memory_floor.jl's testset (7).)
#
# Ref: test/reference/through_mem.c / .ll — the C source + committed clang-18
#      `.ll` (the emitter-agnostic input).
# Ref: docs/adr/0014-memory-floor-lowering.md §D5 (this gate), §D1 (bump
#      allocator), §D2 (L3 baseline).
# Ref: docs/adr/0013-reversible-memory-architecture.md §D-1 (emitter-
#      agnosticism — the load-bearing reason this gate exists).
# Ref: ../Bennett.jl/src/extract/entry.jl — `extract_parsed_ir_from_ll`
#      (the language-agnostic `.ll` entry point).
# Ref: test/test_per_step_inverse.jl — the `per_step_inverse_check` scaffold.
# Ref: CLAUDE.md Rule 4 (known-correct values), Rule 11 (literate), Rule 12
#      (local gates, no toolchain at test time).

using Test
using BennettVM
import Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

# The committed clang-18 `.ll` (no clang at test time — Rule 12).
const _CLL_PATH = joinpath(@__DIR__, "reference", "through_mem.ll")

# Pinned IR keys (verified this session — see the file docstring).
const _CLL_ARG_KEY    = :__v1   # the i32 argument's SSA name
const _CLL_RESULT_KEY = :__v8   # the IRRet operand — the routine result

# The C function's semantics, as the irreversible oracle (Rule 4 / P0.5).
through_mem_ref(n::Integer) = n + 1

@testset "C through_mem round-trips (emitter-agnostic gate; ADR 0014)" begin
    # (0) The committed `.ll` exists (the gate's input). A missing file would
    #     otherwise surface as a confusing extractor error.
    @test isfile(_CLL_PATH)

    # (1) Extract the ParsedIR from the C-emitted `.ll` via Bennett's
    #     LANGUAGE-AGNOSTIC entry point. This is the emitter-agnostic step:
    #     a C `.ll` (or Rust, or hand-written) flows through the SAME
    #     converter as the Julia-function path. The Julia GC-frame reject
    #     never fires on a C `.ll` (ADR 0013 §D-1).
    p = Bennett.extract_parsed_ir_from_ll(_CLL_PATH;
                                          entry_function="through_mem")

    @testset "extracted ParsedIR shape (pins the verified dump)" begin
        @test p.args == [(_CLL_ARG_KEY, 32)]
        @test p.ret_elem_widths == [32]
        @test length(p.blocks) == 1
        # The body must contain the memory quintet the floor handles: two
        # allocas, two stores, two loads (a binop between them).
        body = p.blocks[1].instructions
        @test count(i -> i isa Bennett.IRAlloca, body) == 2
        @test count(i -> i isa Bennett.IRStore,  body) == 2
        @test count(i -> i isa Bennett.IRLoad,   body) == 2
        # The terminator returns the pinned result key.
        @test p.blocks[1].terminator isa Bennett.IRRet
        @test p.blocks[1].terminator.op == Bennett.SSAOperand(_CLL_RESULT_KEY)
    end

    # (2) Lower to a runnable VMProgram via the real `lower_vm` (the path
    #     that previously RAISED at IRAlloca — this is the gap this build
    #     closes).
    vm = lower_vm(p; opts=:through_mem)
    @test vm isa VMProgram

    # The trajectory-pinned inputs: each REPL-confirmed `vm_result == oracle`
    # and round-trip-clean. Includes 0, 1, a mid value, and a negative.
    # The i32 add now computes in i32 semantics (ADR 0012 R1, bead
    # bennettvm-bgc): `result` carries the LOW-32-BIT representation, so the
    # negative case (n=-3 → -2) is the zero-extended `(n+1) & 0xFFFFFFFF`, not
    # the sign-extended Int64 (the oracle anchor below masks accordingly).
    cll_inputs = (Int64(0), Int64(1), Int64(5), Int64(41), Int64(100),
                  Int64(-3))
    # Low-32-bit mask: the i32 carrier the VM stores/returns (ADR 0012 R1).
    _cll_m32 = (Int64(1) << 32) - 1

    # ------------------------------------------------------------------
    # (3) Forward result matches the C oracle, then round-trips (P0.6).
    # ------------------------------------------------------------------
    @testset "forward == oracle (n+1) and round-trips to empty history" begin
        for n in cll_inputs
            rs = initial_state(vm, Dict(_CLL_ARG_KEY => n))
            initial_snap = deepcopy(rs.initial)

            run!(rs, vm; checkpoint_interval=4)
            @test is_halted(rs)
            # ANCHOR: the VM's forward result is bit-for-bit the C oracle in
            # the i32 low-32-bit carrier (ADR 0012 R1 — masking is now active).
            @test result(rs)[_CLL_RESULT_KEY] == (through_mem_ref(n) & _cll_m32)

            unrun!(rs, vm)
            @test rs.current == rs.initial      # P0.6 — reversed to start
            @test isempty(rs.history)           # P0.6 — history drained
            @test rs.step_count == 0            # P0.6 — step counter reset
            @test rs.initial == initial_snap    # rs.initial never mutated
        end
    end

    # ------------------------------------------------------------------
    # (4) Per-step inverse (L3) — the finer-grained reversal gate.
    # ------------------------------------------------------------------
    # Empty must_cache_set → pure L3 path (the only path that reverses the
    # non-injective store/load). Two checkpoint densities (K=1 push-every-
    # step, K=4 sparse multi-step replay). A mid-program store/load reversal
    # bug surfaces as a step-indexed mismatch, not a masked aggregate pass.
    @testset "per-step inverse (L3, empty must_cache)" begin
        for K in (1, 4)
            @test per_step_inverse_check(
                vm, Dict(_CLL_ARG_KEY => Int64(41));
                checkpoint_interval = K,
                label = "through_mem/K=$K") === nothing
        end
    end

    # ------------------------------------------------------------------
    # (5) THE headline assertion — one clearly-named claim.
    # ------------------------------------------------------------------
    # A C function (compiled clang-18 -O0, NOT Julia) round-trips through
    # BennettVM: through_mem(41) == 42, reversed to empty history. This is
    # the emitter-agnostic proof (ADR 0013 §D-1) as a single executable line.
    @testset "headline: a C program round-trips through BennettVM" begin
        rs = initial_state(vm, Dict(_CLL_ARG_KEY => Int64(41)))
        run!(rs, vm; checkpoint_interval=4)
        @test is_halted(rs)
        @test result(rs)[_CLL_RESULT_KEY] == 42        # through_mem(41) == 42
        @test result(rs)[_CLL_RESULT_KEY] == through_mem_ref(41)
        unrun!(rs, vm)
        @test rs.current == rs.initial
        @test isempty(rs.history)
        @test rs.step_count == 0
    end
end

# test/test_fast_mode.jl — B1 (bd `bennettvm-zr7x`): `run!(...; record=false)`
# forward-only fast mode, the Track-B framerate baseline
# (`docs/design/emulator-on-bennettvm.md` §9.2).
#
# # What this pins (Rule 4 — known-correct values, not "didn't throw")
#
#   1. Fast-mode forward result is bit-for-bit identical to a normal
#      (recording) forward run on the SAME program/input — fast mode only
#      removes the reversibility TAPE, it never changes `forward()`'s
#      dispatch. Checked on the collatz one-liner (SC9 Case D, unbounded
#      loop) via `test/reference/collatz.jl`'s `collatz_vm()`.
#   2. `isempty(rs.history)` after a fast-mode run to halt — the tape was
#      never recorded, not merely truncated.
#   3. `unrun!` (AND its `unstep!` primitive) on a fast-mode `RState` FAILS
#      LOUD with a descriptive `ErrorException`, and does so WITHOUT
#      mutating the RState (the guard in `src/history/Replay.jl` fires
#      before any restore/pop happens) — never a silent corrupt-and-
#      continue, and never a silent "it happens to still work by fully
#      replaying from `s.initial`" (see `src/ir/RState.jl` §"Why
#      `fast_mode` must participate" for why that fallback would otherwise
#      fire and why it would be a correctness-shaped performance trap, not
#      a real fix).
#   4. A normal (`record=true`, the default) run still round-trips exactly
#      as before B1 — confirms the `record` kwarg didn't regress the
#      existing recording path (`replay_mode` is now OR'd with `!record`
#      instead of used bare; this test is the regression gate for that
#      change).
#
# # Why the collatz one-liner (not the E0 MVP) is the default-suite check
#
# `docs/design/emulator-mvp/mos6502.O0.ll` ingestion costs ~30-40s
# (`extract_parsed_ir_set_from_ll` + `lower_vm`, per
# `docs/design/emulator-mvp/README.md` and this bead's own measurement) —
# the E0 MVP has never been wired into `test/runtests.jl` (it lives under
# `docs/design/`, run manually via `run_mvp.jl`). Paying that cost on
# every `Pkg.test()` for a mode-equivalence check the cheap collatz
# program already exercises identically (same `step!`/`run!` dispatch,
# same `replay_mode` suppression machinery) would slow the whole suite
# for redundant signal. The E0 MVP invariant is still REQUIRED by the B1
# brief, so it lives in this file too, gated behind
# `BENNETTVM_MVP_TESTS=1` (opt-in, mirrors Bennett.jl's `BENNETT_T5_TESTS`
# slow-corpus convention) — `Pkg.test()` skips it by default;
# `BENNETTVM_MVP_TESTS=1 julia --project test/test_fast_mode.jl` runs it.
#
# # Ref
#
#   * `src/interpreter/Interpreter.jl` `run!` §"B1 … `record::Bool` fast
#     mode" — the mechanism under test.
#   * `src/history/Replay.jl` `unstep!` §(0) fast-mode guard.
#   * `src/ir/RState.jl` `fast_mode::Bool` field docstring.
#   * `docs/design/emulator-on-bennettvm.md` §9.2 — Track B, the framerate
#     baseline this mode measures.
#   * `test/reference/collatz.jl`, `test/test_collatz_forward.jl` — the
#     program + round-trip pattern this file mirrors for the fast path.
#   * `docs/design/emulator-mvp/run_mvp.jl` — the E0 MVP ingest pattern
#     reused (unchanged) for the opt-in sub-testset.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (known-correct values), Rule 11
#     (literate docstring).

using Test
using BennettVM
import Bennett

include(joinpath("reference", "collatz.jl"))

@testset "B1 — run!(record=false) fast mode" begin
    vm = collatz_vm()
    arg_key = Symbol("x::Int8")
    ret_key = Symbol("value_phi1.lcssa")

    # Width caveat (ADR 0012 R1, same as test_collatz_forward.jl): IState
    # locals are Int64 but collatz is i8, so oracle agreement (and hence
    # fast==normal agreement against a KNOWN value) only holds for inputs
    # whose trajectory stays in i8 range. x=1 (loop not entered), x=7 (16
    # steps), x=9 (19 steps, one below the 20-step cap) match
    # test_collatz_forward.jl exactly.
    @testset "fast == normal forward result, x=$x" for x in Int64[1, 7, 9]
        oracle = Int64(collatz_steps(Int8(x)))

        rs_fast = initial_state(vm, Dict(arg_key => x))
        run!(rs_fast, vm; max_steps = 10_000, checkpoint_interval = 8,
             record = false)

        @test is_halted(rs_fast)
        @test rs_fast.fast_mode                       # taint set (B1)
        @test isempty(rs_fast.history)                 # invariant (2)
        @test result(rs_fast)[ret_key] == oracle        # Rule 4 oracle anchor

        rs_norm = initial_state(vm, Dict(arg_key => x))
        run!(rs_norm, vm; max_steps = 10_000, checkpoint_interval = 8)

        @test is_halted(rs_norm)
        @test !rs_norm.fast_mode
        @test result(rs_norm)[ret_key] == oracle

        # Invariant (1): fast-mode forward result == normal-mode forward
        # result, bit-for-bit, over the FULL locals dict (not just the
        # return symbol) — fast mode must not perturb any other local.
        @test result(rs_fast) == result(rs_norm)

        # Both runs took the same number of forward steps (fast mode
        # still counts steps — `run!`'s docstring — it just never
        # records them), which is itself part of "fast == normal": the
        # dispatch trace length is unaffected by `record`.
        @test rs_fast.step_count == rs_norm.step_count

        # Invariant (3): unrun!/unstep! on the fast-mode RState FAIL LOUD,
        # and do so WITHOUT mutating it (the guard fires before any
        # restore/pop). Snapshot first so we can assert "unchanged".
        pre_history_len = length(rs_fast.history)
        pre_step_count = rs_fast.step_count
        pre_status = rs_fast.current.status
        @test_throws ErrorException unrun!(rs_fast, vm)
        @test length(rs_fast.history) == pre_history_len
        @test rs_fast.step_count == pre_step_count
        @test rs_fast.current.status === pre_status
        # The primitive (`unstep!`) raises identically — `unrun!` isn't
        # papering over anything by, e.g., catching and re-raising.
        @test_throws ErrorException unstep!(rs_fast, vm)

        # Invariant (4): the NORMAL run's round-trip is untouched by the
        # B1 change (the `record` kwarg defaults to `true`, and
        # `replay_mode || !record` reduces to `replay_mode` when
        # `record=true`).
        initial_snap = deepcopy(rs_norm.initial)
        unrun!(rs_norm, vm)
        @test rs_norm.current == rs_norm.initial
        @test isempty(rs_norm.history)
        @test rs_norm.step_count == 0
        @test rs_norm.initial == initial_snap
    end

    @testset "record=true is the default (unchanged call sites keep recording)" begin
        rs = initial_state(vm, Dict(arg_key => Int64(7)))
        run!(rs, vm; max_steps = 10_000, checkpoint_interval = 8)
        @test !rs.fast_mode
        unrun!(rs, vm)   # must NOT raise
        @test isempty(rs.history)
    end

    # ------------------------------------------------------------------
    # Opt-in: the E0 MVP (mos6502.O0.ll). See top-of-file §"Why the
    # collatz one-liner … is the default-suite check" for the cost
    # rationale. Mirrors `docs/design/emulator-mvp/run_mvp.jl`'s ingest
    # pattern verbatim (unchanged there — this file only adds the
    # `record=false` comparison on top of it).
    # ------------------------------------------------------------------
    if get(ENV, "BENNETTVM_MVP_TESTS", "0") == "1"
        @testset "E0 MVP (mos6502): fast == normal forward result" begin
            ll = joinpath(@__DIR__, "..", "docs", "design", "emulator-mvp",
                          "mos6502.O0.ll")
            @test isfile(ll)

            set = Bennett.extract_parsed_ir_set_from_ll(ll; ptr_cells = true)
            prog = lower_vm(set; entry = :mos6502)

            ret_sym = nothing
            for b in prog.blocks
                if b.exit isa BennettVM.EndInstruction &&
                   b.exit.label === :mos6502 && !isempty(b.exit.returns)
                    ret_sym = b.exit.returns[1]
                end
            end
            @test ret_sym !== nothing

            # n ∈ {1, 3, 5}: all < 256 (no wraparound edge case — see
            # mos6502.c's header comment), so the closed-form
            # `result == 5*n` holds without consulting GOLDEN.txt.
            for n in (1, 3, 5)
                rs_fast = initial_state(prog, Dict(:n => Int64(n)))
                run!(rs_fast, prog; max_steps = 200_000_000,
                     checkpoint_interval = 32, record = false)
                @test is_halted(rs_fast)
                @test rs_fast.fast_mode
                @test isempty(rs_fast.history)
                @test result(rs_fast)[ret_sym] == 5 * n

                rs_norm = initial_state(prog, Dict(:n => Int64(n)))
                run!(rs_norm, prog; max_steps = 200_000_000,
                     checkpoint_interval = 32)
                @test result(rs_norm)[ret_sym] == 5 * n

                @test result(rs_fast) == result(rs_norm)   # invariant (1)
                @test_throws ErrorException unrun!(rs_fast, prog)  # invariant (3)
            end
        end
    else
        @info "test_fast_mode.jl: skipping E0 MVP sub-testset " *
              "(opt-in via BENNETTVM_MVP_TESTS=1; ~30-40s LLVM-IR ingest cost)"
    end
end

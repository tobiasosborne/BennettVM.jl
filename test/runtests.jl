# test/runtests.jl — canonical Julia test entry for BennettVM.jl.
#
# Per CLAUDE.md Rule 4 ("'Runs without errors' is not a passing test"),
# every included file must assert against known-correct values, not just
# "didn't throw". Per Rule 7, the entire suite runs in a single Julia
# process — no parallelism between test files.
#
# Currently only the M0.3 Handoff-A smoke is wired up. M0.4 will add the
# remaining motivating-case smokes (fdict, frtN, matrix_sum) once their
# Bennett.jl `ParsedIR`s are nailed down for the ADR.

using Test
using BennettVM

@testset "BennettVM" begin
    include("test_handoff_smoke.jl")
    include("test_istate.jl")
    include("test_rstate.jl")
    include("test_dispatch.jl")
    include("test_operators.jl")
    include("test_arithmetic_assignment.jl")
    include("test_swap_instruction.jl")
    include("test_control_instructions.jl")
    include("test_memory_instructions.jl")
    include("test_call_instruction.jl")
    include("test_basic_block.jl")
    include("test_label_table.jl")
    include("test_vmprogram.jl")
    include("test_ir_types.jl")
    include("test_injective.jl")
    include("test_injective_inverse.jl")
    # M6.4 capstone (bennettvm-moa). Integration test that composes
    # M6.1 (`is_injective` trait), M6.2 (`step!` gate), M6.3 (per-
    # instruction inverse contract): all-injective VM programs must
    # produce zero history at every step and round-trip via the
    # `s.initial` fallback path in Replay.jl.
    include("test_zero_history_roundtrip.jl")
    include("test_interpreter.jl")
    include("test_forward_interpreter.jl")
    # M7.5 — stub liveness / min-cut analysis (`bennettvm-46p`).
    # Sits AFTER `test_forward_interpreter.jl` so `build_countdown_vm`
    # is already a top-level definition when the multi-block testset
    # runs. Pure analysis tests — no `step!` integration (that's M7.6).
    include("test_liveness.jl")
    include("test_checkpoint_entry.jl")
    # M7.2 — DeltaEntry{T} unit tests (`bennettvm-c4m`). L2 history
    # entry type for non-injective instructions; mirrors
    # test_checkpoint_entry.jl's pattern.
    include("test_delta_entry.jl")
    include("test_checkpoint_push.jl")
    include("test_unstep.jl")
    # M7.4 — unstep! L2 DeltaEntry fast-path tests (`bennettvm-bk5`).
    # Sits after test_unstep.jl so the M4.3 baseline tests run first;
    # the M7.4 tests build on `build_countdown_vm` (defined in
    # test_forward_interpreter.jl) and the M7.2/M7.3 fixtures.
    include("test_unstep_delta.jl")
    # M7.6 — L2 delta push integration into `step!` (`bennettvm-7e7`).
    # Sits after `test_unstep_delta.jl` because the M7.6 round-trip
    # test (`L2 suppressed in replay`) exercises the M7.4 unstep!
    # fast-path; that fast-path's baseline tests run first. Also
    # depends on `build_countdown_vm` from test_forward_interpreter.jl
    # and on `compute_must_cache` from test_liveness.jl's M7.5
    # subject.
    include("test_delta_push.jl")
    include("test_unrun.jl")
    include("test_roundtrip.jl")
end

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
    # M7.5 — stub liveness / min-cut analysis (`bennettvm-46p`). Pure
    # analysis tests — no `step!` integration (that's M7.6). Pulls in
    # the multi-block `countdown_program` fixture via its own
    # `include("reference/countdown.jl")` (M8.1 — no transitive
    # include-order dependency).
    include("test_liveness.jl")
    include("test_checkpoint_entry.jl")
    # M7.2 — DeltaEntry{T} unit tests (`bennettvm-c4m`). L2 history
    # entry type for non-injective instructions; mirrors
    # test_checkpoint_entry.jl's pattern.
    include("test_delta_entry.jl")
    include("test_checkpoint_push.jl")
    include("test_unstep.jl")
    # M7.4 — unstep! L2 DeltaEntry fast-path tests (`bennettvm-bk5`).
    # Sits after test_unstep.jl so the M4.3 baseline tests run first.
    include("test_unstep_delta.jl")
    # M7.6 — L2 delta push integration into `step!` (`bennettvm-7e7`).
    # Sits after `test_unstep_delta.jl` because the M7.6 round-trip
    # test (`L2 suppressed in replay`) exercises the M7.4 unstep!
    # fast-path; that fast-path's baseline tests run first. Also
    # depends on `compute_must_cache` from test_liveness.jl's M7.5
    # subject.
    include("test_delta_push.jl")
    # M7.7 — milestone capstone (`bennettvm-94m`). Integration test
    # composing M7.2-M7.6 (delta entries, push site, liveness stub) with
    # M6 (L1 trait) and M4 (L3 checkpoint replay) — proves delta-
    # history correctness, sub-linear history scaling (PRD v4 §Part VI
    # SC4), and composition with the M6 L1 gate. Sits after
    # `test_delta_push.jl` because it builds on the same M7.6 push-site
    # contract.
    include("test_delta_roundtrip.jl")
    include("test_unrun.jl")
    include("test_roundtrip.jl")
    # M8.2 — per-step inverse test scaffold (`bennettvm-3d8`).
    # Sits AFTER test_delta_roundtrip.jl because the scaffold's M7
    # driver-layer testset depends on `compute_must_cache` (M7.5) and
    # the M7.6 push-site integration both being exercised first. The
    # scaffold itself is reusable infrastructure consumed by M8.3
    # (`bennettvm-2kl`, mutation-proof harness), M8.4
    # (`bennettvm-bii`, seeded random program generator), and M8.5
    # (`bennettvm-tnp`, 100-random-programs property test).
    include("test_per_step_inverse.jl")
    # M8.3 — mutation-proof harness for per-instruction inverse
    # (`bennettvm-2kl`). Sits AFTER test_per_step_inverse.jl because
    # the harness depends on the `per_step_inverse_check` scaffold
    # exposed by M8.2 for its non-injective L2 cycles
    # (ArithmeticAssignment, MemoryAssignment). The three injective
    # kinds (SwapInstruction, MemoryInterchange, MemorySwap) use a
    # direct forward+inverse round-trip (the M6.3 pattern) because
    # the M7.6 L1 short-circuit makes `inverse()` unreachable for
    # them via `unstep!`'s L2 fast-path.
    include("test_mutation_proof.jl")
    # M8.4 — seeded random control-flow program generator
    # (`bennettvm-bii`). Sits AFTER test_mutation_proof.jl because the
    # generator's "scaffold compatibility" testset drives every shape
    # (linear/conditional/looping) through the M8.2 scaffold
    # (`per_step_inverse_check`) in both L3 and L2 regimes — those
    # primitives must already be exercised. Produces (VMProgram, inputs)
    # pairs the M8.5 (`bennettvm-tnp`) 100-program property test will
    # consume from a single seeded MersenneTwister(0xBE171973).
    include(joinpath("generators", "random_program.jl"))
    # M8.5 — 100-random-program property test (`bennettvm-tnp`), the M8
    # capstone. Sits LAST in the M8 family because it composes M8.2's
    # `per_step_inverse_check` scaffold, M8.4's seeded generator
    # (`default_rng`, `random_program`, `_structural_eq`,
    # `_classify_shape`), and M8.3's eval+delete_method+invokelatest
    # mutation discipline — all three must already be in scope. Walks a
    # single seeded RNG 100× asserting full round-trip + per-step
    # inverse at both L3 and L2 regimes, determinism, and a mutation-
    # proof RED-then-GREEN on `inverse(::ArithmeticAssignment)`.
    include("test_property_roundtrip.jl")
end

# runtests.jl — entry point for the Phase-0 spike test suite.
# PRD v3 §5.4; CLAUDE.md Rules 4 (no "didn't throw" tests), 5
# (mutation-proof discipline), P0.5 (golden master), P0.6 (round-trip).
#
# Files registered, in deliberate order:
#   1. test_countdown.jl  — the canonical example program (§5.4.1).
#                           Establishes golden-master agreement with
#                           the reference irreversible Julia executor.
#   2. test_history.jl    — history-tape invariants (§5.4.3, §5.4.4).
#                           Documents the discard-pop convention.
#   3. test_roundtrip.jl  — round-trip on countdown + 100 random
#                           bounded programs (§5.4.2).
#   4. test_maxsteps.jl   — max_steps guard fires (§5.4.5).

using Test
using BennettVMSpike

# Shared oracles & helpers — included once here so the individual
# test files can refer to `countdown`, `countdown_reference`,
# `random_bounded_program`, `program_reference` without re-including
# (which would generate "Method definition ... overwritten" warnings).
include("reference/countdown.jl")
include("reference/property_programs.jl")

@testset "BennettVMSpike — Phase-0 spike test suite" begin
    @testset "countdown program (PRD §5.4.1)" begin
        include("test_countdown.jl")
    end

    @testset "history-tape invariants (PRD §5.4.3, §5.4.4)" begin
        include("test_history.jl")
    end

    @testset "round-trip (PRD §5.4.2, P0.6)" begin
        include("test_roundtrip.jl")
    end

    @testset "max_steps guard (PRD §5.4.5)" begin
        include("test_maxsteps.jl")
    end
end

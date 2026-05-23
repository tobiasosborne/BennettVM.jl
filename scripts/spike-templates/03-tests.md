# Sub-agent 3 — Tests

You are the tests sub-agent for the BennettVM Phase-0 spike.

**Read first:**
1. `bennettvm_prd.md` §5.4 (the five required tests, plus stretch
   goals).
2. `CLAUDE.md` — esp. Rule 4 ("'runs without errors' is not a passing
   test"), Rule 5 (TDD discipline), Phase-0 gating P0.5–P0.6
   (golden master + round-trip).
3. The interpreter and instruction-set sub-agents' output.

**Your scope:**
- `test/runtests.jl` (registration order).
- `test/test_countdown.jl` — the required example program (PRD §5.4.1).
- `test/test_roundtrip.jl` — random-program round-trip property (§5.4.2).
- `test/test_history.jl` — `length(history) == steps_taken` invariant
  (§5.4.3) AND `isempty(history)` after `unrun!` (§5.4.4).
- `test/test_maxsteps.jl` — `max_steps` guard fires (§5.4.5).
- `test/reference/countdown.jl` — the reference irreversible Julia
  function that the golden-master assertion compares against.
- `test/reference/property_programs.jl` — a small `Random` corpus of
  100 short bounded programs with their reference implementations.

**Your scope-does-NOT-include:**
- The interpreter or instruction set (sub-agents 1, 2).
- Fixed-point or gcd (gcd is a stretch goal per PRD §5.4 — only if
  the rest is green and time remains).
- Bennett.jl integration tests. Out of scope.

**Test patterns (binding — Rule 4 is load-bearing):**

Every test asserts an invariant against a known-correct value. Forbidden
patterns:
```julia
# ✗ "didn't throw"
@test (run!(s, prog); true)

# ✗ existence check that's tautological
@test isa(s, RState)
```

Required patterns:
```julia
# Countdown — golden master comparison
@testset "countdown(5) forward" begin
    s = initial_state(countdown(5))
    run!(s)
    @test result(s) == countdown_reference(5)        # golden master
    @test s.current.status == :halted
end

# Round-trip — the load-bearing Phase-0 invariant
@testset "countdown(n) round-trip" for n in (0, 1, 2, 5, 10)
    s = initial_state(countdown(n))
    s0 = deepcopy(s.current)
    run!(s)
    unrun!(s)
    @test s.current == s0
    @test isempty(s.history)
end

# Property-based round-trip on small random programs
using Random
@testset "round-trip on random programs" begin
    rng = MersenneTwister(0xBE171973)              # explicit seed
    for trial in 1:100
        prog = random_bounded_program(rng; max_len=20, max_vars=3)
        s = initial_state(prog)
        s0 = deepcopy(s.current)
        run!(s; max_steps=200)
        unrun!(s)
        @test s.current == s0
        @test isempty(s.history)
    end
end

# History length invariant
@testset "history length tracks step count" begin
    s = initial_state(countdown(10))
    @test isempty(s.history)
    n = 0
    while s.current.status == :running
        step!(s)
        n += 1
        @test length(s.history) == n
    end
end

# Max-steps guard
@testset "max_steps guard triggers" begin
    s = initial_state(countdown(1000))
    @test_throws ErrorException run!(s; max_steps=10)
end
```

**Mutation-proof at least the round-trip test** (Rule 5, port-and-verify
shape). Briefly: perturb one inverse in `src/Instructions.jl` (e.g.,
swap `prev` and `current` in `BinaryOp.inverse`), confirm the round-trip
test goes RED, restore. Record the mutation and the failure mode in
the retrospective Q2. **If the perturbed code doesn't fail the test,
the test is broken — fix the test, not the suite.**

**Stretch goals (only if main suite is green):**
- gcd loop (PRD §5.4 §6) — adds a second program to the corpus.
- Fixed-point Taylor in Q-format (§5.4 §7) — only if Q-format itself
  is trivial; otherwise defer to Phase 2.

**Constraints:**
- ≤ 200 LOC per file.
- Explicit seeds (`MersenneTwister(0xBE171973)`) for reproducibility.
- Random programs must be **bounded** in length and variable count
  so that `max_steps` is never the natural termination.

**Output:**
- The test files above.
- A 5-line summary: count of passing tests, mutation-proof outcome,
  anything that needed to be revised in the interpreter/instructions
  to make tests pass (this is data for the retrospective Q3).

When done, hand off to the reviewer sub-agent for the final pass.

# test/test_delta_roundtrip.jl — M7.7 milestone capstone (bd `bennettvm-94m`).
#
# # What this milestone integration-tests
#
# M7.7 is the **M7 milestone capstone**: it composes the M7.2–M7.6
# layers (DeltaEntry type, per-instruction make_delta, unstep! L2
# fast-path, compute_must_cache liveness stub, step!/run! integration)
# with the M6 L1 trait and the M4 L3 checkpoint replay machinery, and
# pins the three load-bearing post-M7 invariants:
#
#   1. **Delta-history correctness.** Running a non-trivially-non-
#      injective program (countdown(N)) with the M7.5 compute_must_cache
#      set populated produces DeltaEntries during forward execution and
#      round-trips bit-for-bit under `unrun!`. The post-unrun state must
#      match the pre-run state on every observable field (current ==
#      initial; history empty; step_count zero). The per-step inverse
#      pattern (PRD v4 §3.13) is exercised on a small N so that an
#      aggregate-only-passing inverse bug (forward landing one step
#      short, then unrun masking it via the s.initial replay) cannot
#      hide.
#
#   2. **Sub-linear history scaling.** This is THE PRD v4 §Part VI SC4
#      deliverable — "sublinear-in-T peak history bytes for the
#      injective-dominated subset". For an injective-dominated program
#      (the >50% injective subset called out in ADR 0002 §Design
#      decision 6), the ratio `length(rs.history) / rs.step_count`
#      MUST be `<= 0.5` after `run!`. The threshold is the floor; for a
#      90% injective program the realised ratio approaches the
#      non-inj fraction (≈ 0.09 for the 18-Swap / 2-Arith hand-built
#      program below). The scaling property — ratio invariant under T —
#      is exercised by sweeping the program across multiple sizes
#      (Swap count S ∈ {9, 18, 45} with 1, 2, 5 Arith respectively).
#
#   3. **Composition with M6.** The all-injective program from M6.4
#      (Begin + ArithAssign(:xor) + End) MUST still produce a strictly
#      empty history under M7.6's integration when must_cache_set is
#      passed. This is the load-bearing M6→M7 compatibility check: the
#      L1 gate fires BEFORE the L2 lookup at the push site (ADR 0002
#      §Composition rule), so even a populated must_cache_set cannot
#      cause a push at an injective step. For an all-injective program
#      `compute_must_cache(vm)` returns the empty set anyway (M7.5
#      stub iterates only non-injective slots per
#      `src/analysis/liveness.jl:166-170`); both routes converge on
#      zero history.
#
# # Absence of the `bennettvm-ack` follow-up: why a hand-built program
#
# Per ADR 0002 §"Worked example: countdown(3)" the canonical countdown
# is 50% non-injective by static count and ~56% non-injective by
# dispatched-step count (10 Arith vs 18 total dispatched steps for
# countdown(5)). It is therefore the WRONG canonical for SC4: at the
# stub-liveness level, every Arith pushes a DeltaEntry, so the ratio
# for countdown(5) is 10/18 ≈ 0.555 — over the 0.5 threshold. ADR 0002
# §Design decision 6 explicitly flags this: SC4's correct framing is
# "the injective-dominated subset must scale sub-linearly", not "every
# program must".
#
# Once the open bd `bennettvm-ack` lands (broadening `is_injective` to
# all three modop choices, since the empty-payload finding shows the
# inverse for `:add`/`:sub` needs no captured state), countdown(N)
# would itself become 100% injective — every Arith would be L1-gated
# out, and the ratio would collapse to 0. M7.7 lands BEFORE `ack`, so
# it builds a hand-crafted injective-dominated program (heavy on
# SwapInstruction, light on ArithAssign(:add)) to exercise the
# sub-linear assertion correctly.
#
# # Mutation matrix (Rule 5)
#
# Each testset cites a specific production mutation that would turn
# its asserts RED. The mutations are chosen to be in M7.2–M7.6 code
# paths (the M7 milestone surface) rather than M2.x/M3.x baseline:
#
#  (i)   `compute_must_cache` returns the FULL set of all (label, idx)
#        pairs (including injective ones) → testset 2 RED because the
#        L1 gate runs first, but the empty-set assertion in testset 4
#        (cross-K invariance) RED on the inj-program path because
#        L2 would now fire on Swap steps. (Note: the L1 gate at
#        `Interpreter.jl` line 965 is BEFORE the L2 lookup, so testset
#        2 stays mostly green; testset 3's "all-injective produces zero
#        history" stays GREEN because `compute_must_cache` only iterates
#        non-injective slots — see the M7.5 stub. To exercise this
#        mutation: skip the `!is_injective(instr)` filter in
#        `src/analysis/liveness.jl:167` so every slot is included →
#        testset 3 RED because the L2 path WOULD fire on the xor
#        Arith despite is_injective=true at the value level. But that
#        ALSO requires bypassing the L1 gate; see (ii) for a cleaner
#        single-mutation hit.)
#
#  (ii)  Drop the L1 `is_injective(instr)` gate in `step!` (i.e.,
#        unconditionally fall through to the L2/L3 selector) →
#        testset 3 RED because the L1 gate is the *only* reason an
#        all-injective program produces zero history; bypass that, and
#        even with empty must_cache_set the L3 branch would fire at
#        K-multiples for what should be injective steps.
#
#  (iii) `make_delta` for ArithmeticAssignment swaps target/source
#        roles when reconstructing the inverse (e.g., `dual_modop`
#        wired wrong on `:add` → `:add` instead of `:sub`) → testset 1
#        RED on `rs.current == initial_current` after unrun!. The
#        DeltaEntry is pushed correctly but the *inverse* mutates the
#        wrong field, corrupting the round-trip.
#
#  (iv)  `compute_must_cache` returns the SAME set for all programs
#        (e.g., includes every (label, idx) regardless of injectivity)
#        → testset 4 RED because the all-injective sub-test would see
#        a non-empty must_cache_set, exercising the L2 path on Swap
#        steps (after the L1 gate is somehow bypassed; see (ii)).
#
#  (v)   `unrun!` in the L2 fast-path applies the DeltaEntry's
#        `instruction` reference to the wrong block context → testset
#        1's `unrun!` would corrupt locals on countdown(5) at the
#        Arith :add step, breaking the round-trip equality. M7.4's
#        unstep! does NOT need block context for the per-instruction
#        inverse (the instruction is self-describing), so this
#        mutation would actually require breaking M7.4's
#        `inverse(instr, s, payload)` dispatch — a deeper bug.
#
# # Hard constraints
#
# Per the M7.7 instructions:
#   - The sub-linear assertion ≤ 0.5 is pinned numerically (the SC4
#     floor); the realised ratio is tighter (≈ 0.09) and is recorded
#     in the testset's literal comment for future regression context.
#   - No src/ edits — M7.7 is test-only.
#   - No new exports — every M7.x symbol stays internal-access via
#     `BennettVM.<Name>` per M7.6's "M7.6 settles the public API" note.
#
# # Ref
#
#   * `docs/adr/0002-enzyme-min-cut-mapping.md`:
#       - §"Design decisions that ripple to M7.2–M7.7" decision 6 —
#         the sub-linear threshold formula and the choice of a hand-
#         built injective-dominated program pre-`ack`.
#       - §"Composition with M6's injective gate" — L1-before-L2 at
#         the push site.
#       - §"DeltaEntry payload schema" — empty-payload finding for
#         the ArithmeticAssignment modop set.
#       - §"Worked example: countdown(3)" — the 50/56% non-injective
#         finding that justifies the hand-built fixture.
#   * `bennettvm_prd.md` (PRD v4):
#       - §3.3 layer 2 ("delta entries with min-cut selection") — L2
#         mandate.
#       - §3.13 — per-step inverse / round-trip invariant.
#       - §Part VI SC4 — "sublinear-in-T peak history bytes for the
#         injective-dominated subset" target.
#   * M6.4 commit `cb4db75` worklog reference (per HANDOFF.md "M4
#     closed 2026-05-26") — the all-injective zero-history pattern
#     M7.7 testset 3 reuses.
#   * M7.6 commit `281414a` — the integration this test exercises;
#     `must_cache_set` and `replay_mode` kwargs, the three-way push
#     gate, the `_block_index_at` helper.
#   * M4.5 commit `61c47cd` — the round-trip capstone on countdown(5)
#     that M7.7 testset 1 mirrors at the L2-active layer.
#   * `test/test_delta_push.jl` (M7.6) — the L2 push assertion
#     pattern; M7.7 reuses fixtures' shape but builds round-trip
#     assertions on top.
#   * `test/test_zero_history_roundtrip.jl` (M6.4) — the milestone
#     capstone structure M7.7 mirrors (load-bearing invariants,
#     per-step inverse, mutation matrix).
#   * `test/test_forward_interpreter.jl` — defines `build_countdown_vm`
#     at top level; this file consumes that fixture without re-include.
#   * `test/reference/countdown.jl` — the `countdown_ref` golden master
#     this file's round-trip assertion compares against (Rule 4).
#   * CLAUDE.md Rule 4 (every test pins a known-correct value), Rule 5
#     (mutation-proof), Rule 11 (literate test docstrings).

using Test
using BennettVM

# ---------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------

"""
    _m7_injective_dominated_program(n_swap_pairs, n_arith) -> VMProgram

Build a single-block injective-dominated program parameterised by:

  * `n_swap_pairs` — number of `SwapInstruction`s. Each Swap consumes
    two SSA names and creates two fresh ones, so the program threads
    a 2-register pair through `n_swap_pairs` permutations.

  * `n_arith` — number of `ArithmeticAssignment(modop=:add)` steps,
    interleaved roughly uniformly between the swap chunks. Each Arith
    consumes one SSA name (the side-channel `:c` register) and creates
    a fresh one. The Arith register is NEVER read by any Swap, so the
    two chains are independent — the swaps cannot interact with the
    Arith chain even when interleaved.

The SSA name discipline:
  * Swap chain: `:a0, :b0` initial; after k swaps the live pair is
    `:a{k}, :b{k}`. The k-th swap is
    `Swap(:a{k}, :b{k}, :b{k-1}, :a{k-1})` (a positional swap that
    exchanges values).
  * Arith chain: `:c0` initial; after j Arith steps the live name is
    `:c{j}`. The j-th Arith is
    `ArithAssign(:c{j}, :c{j-1}, :add, 1, :and, 1)`.

The two chains are independent: Swap reads/writes only `:a*, :b*`;
Arith reads/writes only `:c*`. The interleaving order is
"emit n_swap_pairs swaps, then emit one Arith, then emit n_swap_pairs
more swaps, then emit one Arith, ..." — but to keep the build linear,
we simply emit `n_swap_pairs` total swaps in one chain, then
`n_arith` arith steps. The interleaving doesn't matter for the
sub-linear assertion (the ratio depends only on the counts), and
keeping the two chains contiguous keeps the SSA-name accounting
trivially verifiable.

Dispatched-step count for this program (single basic block):

  * step 1: BeginInstruction (injective)
  * steps 2 .. 1+n_swap_pairs: n_swap_pairs Swaps (each injective)
  * steps 2+n_swap_pairs .. 1+n_swap_pairs+n_arith: n_arith
    ArithAssign(:add) (each NON-injective per M6.1)
  * step 2+n_swap_pairs+n_arith: EndInstruction (injective)

→ Total step_count = `n_swap_pairs + n_arith + 2`.
→ Non-injective step count = `n_arith`.
→ Injective fraction = `(n_swap_pairs + 2) / (n_swap_pairs + n_arith + 2)`.

For (n_swap_pairs=18, n_arith=2): step_count=22, non-inj=2,
injective fraction = 20/22 ≈ 0.909 (>0.5; injective-dominated per
ADR 0002 §Design decision 6).

# Why initial values 0 and 1 for `:a0, :b0`

So the swap chain produces deterministic outputs (a0=0, b0=1
exchanged repeatedly: after 1 swap (a1,b1)=(1,0); after 2 swaps
(a2,b2)=(0,1); after k swaps (a_k, b_k) = ((k % 2 == 0) ? (0,1) :
(1,0)). The expected output is straightforward to assert as a
golden master.
"""
function _m7_injective_dominated_program(n_swap_pairs::Int, n_arith::Int)
    n_swap_pairs >= 0 ||
        error("_m7_injective_dominated_program: n_swap_pairs >= 0 required")
    n_arith >= 0 ||
        error("_m7_injective_dominated_program: n_arith >= 0 required")

    body = BennettVM.Instruction[]
    # Swap chain: (:a0, :b0) -> (:a1, :b1) -> ... -> (:a{n_swap_pairs},
    # :b{n_swap_pairs}). Each swap exchanges the pair positionally.
    for k in 1:n_swap_pairs
        push!(body, BennettVM.SwapInstruction(
            Symbol("a", k), Symbol("b", k),
            Symbol("b", k - 1), Symbol("a", k - 1),
        ))
    end
    # Arith chain on the side-channel :c. j-th Arith reads :c{j-1},
    # writes :c{j}.
    for j in 1:n_arith
        push!(body, BennettVM.ArithmeticAssignment(
            Symbol("c", j), Symbol("c", j - 1),
            :add, Int64(1), :and, Int64(1),
        ))
    end

    # Returned-from-End names: the final live swap pair plus the
    # final arith name. Empty body case (n_swap_pairs=0, n_arith=0)
    # returns the inputs unchanged.
    last_a = Symbol("a", n_swap_pairs)
    last_b = Symbol("b", n_swap_pairs)
    last_c = Symbol("c", n_arith)
    return_syms = Symbol[last_a, last_b, last_c]

    bb = BennettVM.BasicBlock(
        :m,
        BennettVM.BeginInstruction(:m, [:a0, :b0, :c0]),
        body,
        BennettVM.EndInstruction(:m, return_syms),
    )
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64, 64, 64],
                     [64, 64, 64])
end

"""
    _m7_inj_dominated_input() -> Dict{Symbol, Int64}

Canonical initial locals for `_m7_injective_dominated_program`.
`:a0 = 0, :b0 = 1` makes the swap-chain output deterministic and
distinguishable; `:c0 = 0` makes the Arith chain produce `:c{j} = j`
under the mask `(1 & 1) == 1`.
"""
_m7_inj_dominated_input() = Dict(:a0 => Int64(0),
                                 :b0 => Int64(1),
                                 :c0 => Int64(0))

"""
    _m7_inj_dominated_expected(n_swap_pairs, n_arith) -> Dict{Symbol, Int64}

Golden-master computation of the program's output. Used to pin
`result(rs)` against an independent (irreversible-Julia) reference,
per Rule 4.
"""
function _m7_inj_dominated_expected(n_swap_pairs::Int, n_arith::Int)
    # Swap chain effect on (:a0=0, :b0=1):
    #   k-th swap takes (a_{k-1}, b_{k-1}) -> (b_{k-1}, a_{k-1})
    #   so the parity of n_swap_pairs determines the final order.
    if iseven(n_swap_pairs)
        (final_a, final_b) = (Int64(0), Int64(1))
    else
        (final_a, final_b) = (Int64(1), Int64(0))
    end
    # Arith chain effect on :c0=0 with mask=(1 & 1)=1, modop=:add:
    #   c_j = c_{j-1} + 1 → c_j = j.
    final_c = Int64(n_arith)
    return Dict(Symbol("a", n_swap_pairs) => final_a,
                Symbol("b", n_swap_pairs) => final_b,
                Symbol("c", n_arith)      => final_c)
end

"""
    _m7_all_injective_program() -> (VMProgram, Dict, Dict)

Mirror of M6.4's `_single_block_xor_program` but local to this file
(so M7.7 doesn't import M6.4 fixtures across the test-include
boundary). Begin + 1 ArithAssign(:xor) + End. The single Arith is
value-level-injective per M6.1's `:xor`-specialisation; the
program is entirely L1.
"""
function _m7_all_injective_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:x0]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:x1, :x0, :xor,
                Int64(0b1111), :and, Int64(0b1010)),
        ],
        BennettVM.EndInstruction(:m, [:x1]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
    input = Dict(:x0 => Int64(0b0110))
    # Golden master: x1 = x0 ⊻ (0b1111 & 0b1010) = 0b0110 ⊻ 0b1010 = 0b1100
    expected = Dict(:x1 => Int64(0b0110) ⊻ (Int64(0b1111) & Int64(0b1010)))
    return vm, input, expected
end

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

@testset "M7.7 — delta-history round-trip on countdown(5)" begin
    # Mutation cited: (iii) make_delta for ArithmeticAssignment wired
    # with the wrong dual_modop (e.g., `:add` → `:add` instead of
    # `:sub`). The DeltaEntry payload is empty so a wrong-direction
    # inverse via `dual_modop` would silently increment `:n*` on the
    # backward step instead of decrementing-the-decrement (i.e.,
    # re-incrementing). The forward result would be the golden-master
    # n=0 / steps=5; the backward unrun would land at locals like
    # n0=10, steps0=-5 instead of n0=5, steps0=0 → RED at the
    # `rs.current == initial_current` line below.
    #
    # Also mutation (v) (unstep!'s L2 fast-path dispatch broken) would
    # surface here on the per-step assertion.

    vm = build_countdown_vm(5)
    rs = initial_state(vm, Dict(:n0 => Int64(5), :steps0 => Int64(0)))
    initial_current = deepcopy(rs.current)

    set = BennettVM.compute_must_cache(vm)
    # countdown(5) layout: 5 decrement blocks, each with 2 non-inj body
    # steps → 10 entries in the must_cache_set. None on b_start or
    # b_done (both have empty body).
    @test length(set) == 10
    @test (:b_step1, 1) in set
    @test (:b_step5, 2) in set

    run!(rs, vm; must_cache_set=set)

    # Forward correctness (Rule 4: pin against the golden master).
    @test is_halted(rs)
    @test result(rs)[:steps5] == countdown_ref(Int64(5))
    @test result(rs)[:steps5] == Int64(5)
    @test result(rs)[:n5] == Int64(0)

    # L2 must have fired on every non-inj step: 10 DeltaEntries, zero
    # CheckpointEntries (the L2 branch starves L3 under the M7.5 stub).
    # countdown(5) dispatched step count = 2 (b_start) + 5*3 + 1 (b_done
    # has its UncondEntry skipped by cross-block dispatch, leaving only
    # the End) = 18; see the trace in test_delta_push.jl line 257.
    @test rs.step_count == 18
    @test length(rs.history) == 10
    @test all(e -> e isa BennettVM.DeltaEntry, rs.history)
    @test !any(e -> e isa BennettVM.CheckpointEntry, rs.history)
    # All payloads are empty NamedTuples per ADR 0002 §"DeltaEntry
    # payload schema" row 1.
    @test all(e -> e.payload === NamedTuple(), rs.history)

    # Round-trip: unrun! must restore the exact initial state. This is
    # the M4.5 capstone assertion re-exercised at the L2 layer.
    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
    @test rs.current == rs.initial
    @test rs.current.status === :running          # NOT :halted post-unrun!
    @test rs.current.locals[:n0] == Int64(5)
    @test rs.current.locals[:steps0] == Int64(0)
end

@testset "M7.7 — per-step inverse on countdown(3) with delta history (PRD §3.13)" begin
    # The per-step inverse pattern: capture a deepcopy of rs.current
    # after every forward step, then unstep! one at a time and confirm
    # each intermediate matches its snapshot. Catches an aggregate-
    # round-trip-masking bug per spike Q3 — a buggy unstep! that lands
    # one step further back than expected but happens to converge on
    # rs.initial by step 0 would pass the aggregate test but fail per-
    # step. Small N=3 keeps test runtime bounded.

    vm = build_countdown_vm(3)
    rs = initial_state(vm, Dict(:n0 => Int64(3), :steps0 => Int64(0)))
    initial_current = deepcopy(rs.current)

    set = BennettVM.compute_must_cache(vm)
    # countdown(3): 6 entries (3 blocks * 2 non-inj per block).
    @test length(set) == 6

    # Forward sweep, capturing per-step snapshots.
    forward_snapshots = BennettVM.IState[]
    while !is_halted(rs)
        step!(rs, vm; must_cache_set=set)
        push!(forward_snapshots, deepcopy(rs.current))
    end
    @test length(forward_snapshots) == 12          # countdown(3) total
    @test rs.step_count == 12

    # Backward sweep, asserting per-step state equality.
    while rs.step_count > 0
        prev_count = rs.step_count
        unstep!(rs, vm)
        @test rs.step_count == prev_count - 1
        if rs.step_count > 0
            @test rs.current == forward_snapshots[rs.step_count]
        else
            @test rs.current == initial_current
            @test rs.current == rs.initial
        end
    end

    # Final state: completely cleaned up.
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current.status === :running
end

@testset "M7.7 — sub-linear scaling on injective-dominated program (ADR 0002 §6)" begin
    # THE M7 SC4 deliverable. For an injective-dominated program,
    # `length(rs.history) / rs.step_count <= 0.5` after run!. The 0.5
    # threshold is the floor per ADR 0002 §"Design decisions that
    # ripple to M7.2–M7.7" decision 6 — a tighter ratio is achievable
    # and is recorded here for regression context.
    #
    # The hand-built program is 18 Swap + 2 Arith(:add):
    #   step_count        = 18 + 2 + 2 (Begin + End) = 22
    #   non-inj steps     = 2
    #   ratio (realised)  = 2/22 ≈ 0.0909
    #   ratio (threshold) = 0.5 (ADR floor)
    #
    # Mutation cited: (i) `compute_must_cache` returning the full set
    # (i.e., dropping the `!is_injective(instr)` filter at
    # `src/analysis/liveness.jl:167`) → set would contain all 20 body
    # slots → L2 push for every Swap step → length(history) = 20 →
    # ratio = 20/22 ≈ 0.909 > 0.5 → RED.

    n_swap_pairs = 18
    n_arith = 2
    vm = _m7_injective_dominated_program(n_swap_pairs, n_arith)
    input = _m7_inj_dominated_input()
    expected = _m7_inj_dominated_expected(n_swap_pairs, n_arith)
    rs = initial_state(vm, input)
    initial_current = deepcopy(rs.current)

    set = BennettVM.compute_must_cache(vm)
    # M7.5 stub: only the `n_arith` Arith slots are in the set. The
    # `n_swap_pairs` Swap slots are excluded by L1 (injective).
    @test length(set) == n_arith
    for j in 1:n_arith
        # Body indices: 1..n_swap_pairs are Swap, n_swap_pairs+1..
        # n_swap_pairs+n_arith are Arith.
        @test (:m, n_swap_pairs + j) in set
    end

    run!(rs, vm; must_cache_set=set)

    # Golden master on forward output.
    @test is_halted(rs)
    @test rs.step_count == n_swap_pairs + n_arith + 2
    res = result(rs)
    @test res[Symbol("a", n_swap_pairs)] == expected[Symbol("a", n_swap_pairs)]
    @test res[Symbol("b", n_swap_pairs)] == expected[Symbol("b", n_swap_pairs)]
    @test res[Symbol("c", n_arith)] == expected[Symbol("c", n_arith)]

    # THE sub-linear assertion (ADR 0002 §Design decision 6).
    @test length(rs.history) == n_arith            # exact count
    ratio = length(rs.history) / rs.step_count
    @test ratio <= 0.5                              # SC4 floor
    @test ratio < 0.1                               # tighter realised bound
    @test isapprox(ratio, n_arith / (n_swap_pairs + n_arith + 2);
                   atol=1e-12)

    # All entries are DeltaEntries; no CheckpointEntry under the
    # M7.5 stub (the L2 branch covers every non-inj step).
    @test all(e -> e isa BennettVM.DeltaEntry, rs.history)
    @test !any(e -> e isa BennettVM.CheckpointEntry, rs.history)

    # Round-trip closure: unrun! restores initial state, history
    # cleared.
    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
    @test rs.current == rs.initial
end

@testset "M7.7 — sub-linear scaling holds as T grows (ratio invariance)" begin
    # Scaling property, not just threshold. Build the same fixture at
    # increasing sizes and assert the ratio stays below the threshold
    # AND stays approximately constant (the program shape is fixed —
    # 10% non-inj — so the ratio should track that fraction modulo
    # the +2 Begin/End overhead).
    #
    # Mutation cited: a bug in `step!`'s push gate that pushes a delta
    # PER STEP (instead of per non-inj step) would make ratio → 1.0 at
    # large T, breaking ALL three subcases. Or a bug that pushed at the
    # `_block_index_at` boundaries (e.g., on UncondEntry/Exit markers
    # too) would inflate ratio specifically for multi-block programs —
    # this single-block fixture would not catch it, hence we ALSO
    # verify the cross-block dispatch in testset 1's countdown(5).
    #
    # Sizes: 9 Swap / 1 Arith; 18 Swap / 2 Arith; 45 Swap / 5 Arith.
    # In each case non-inj fraction is exactly n_arith /
    # (n_swap_pairs + n_arith + 2), which approaches 0.1 from above as
    # the +2 overhead becomes negligible. All three must be ≤ 0.5 and
    # all three must be ≤ 0.15 (tighter bound capturing the 10%
    # design point).
    sizes = [(9, 1), (18, 2), (45, 5)]
    realised_ratios = Float64[]
    for (n_swap_pairs, n_arith) in sizes
        vm = _m7_injective_dominated_program(n_swap_pairs, n_arith)
        input = _m7_inj_dominated_input()
        rs = initial_state(vm, input)
        initial_current = deepcopy(rs.current)

        set = BennettVM.compute_must_cache(vm)
        run!(rs, vm; must_cache_set=set)

        @test is_halted(rs)
        @test rs.step_count == n_swap_pairs + n_arith + 2
        @test length(rs.history) == n_arith
        ratio = length(rs.history) / rs.step_count
        push!(realised_ratios, ratio)
        @test ratio <= 0.5                          # SC4 floor
        @test ratio <= 0.15                         # tighter realised bound

        # Round-trip per size.
        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
    end
    # The realised ratios INCREASE monotonically toward the asymptotic
    # 10% as T grows. This is because the fixed +2 Begin/End overhead
    # dilutes the ratio more at small T than at large T:
    #   (9, 1):   1/12  ≈ 0.0833
    #   (18, 2):  2/22  ≈ 0.0909
    #   (45, 5):  5/52  ≈ 0.0962
    # i.e., n_arith / (n_swap+n_arith+2) approaches n_arith/(n_swap+n_arith)
    # from below as T = n_swap+n_arith+2 grows. That is the correct
    # sub-linear-with-fixed-fraction signature: the ratio approaches
    # the design point (n_arith / total) from below. Pin this
    # monotonicity as an additional regression check.
    @test realised_ratios[1] < realised_ratios[2] < realised_ratios[3]
    @test realised_ratios[3] < 0.1                 # asymptote < 10%
end

@testset "M7.7 — composition with M6: all-injective produces zero history" begin
    # Mutation cited: (ii) drop the L1 `is_injective(instr)` gate in
    # `step!` (i.e., bypass the `if is_injective(instr)` branch at
    # `Interpreter.jl:965`). Then with must_cache_set empty (which it
    # IS for an all-injective program — `compute_must_cache` returns
    # ∅), the code would fall through to the L3 branch and push a
    # CheckpointEntry at every K-multiple of the modop=:xor step. The
    # default K=64 means no push fires on a 3-step program; but on
    # K=1 (the most aggressive setting in M6.4's _K_VALUES), the
    # Arith step would push → length(history) > 0 → RED.

    vm, input, expected = _m7_all_injective_program()

    # The M7.5 stub MUST return the empty set: the only non-control
    # body instruction is `ArithmeticAssignment(:xor)`, which M6.1
    # classifies value-level injective (`is_injective(::Type{
    # ArithmeticAssignment}) = false` at the type level is overridden
    # by the value-level `is_injective(x::ArithmeticAssignment) =
    # x.modop === :xor` at `src/history/Injective.jl`).
    set = BennettVM.compute_must_cache(vm)
    @test isempty(set)

    # Run with the (empty) set passed explicitly. The L1 gate fires
    # on every instruction (Begin, xor-Arith, End all injective); the
    # L2 lookup never happens (the L1 short-circuit); the L3 lookup
    # never fires (would only on non-inj K-multiples, and the L1 gate
    # makes that branch unreachable).
    rs = initial_state(vm, input)
    initial_current = deepcopy(rs.current)
    run!(rs, vm; must_cache_set=set)

    @test is_halted(rs)
    @test rs.step_count == 3                        # Begin + xor + End
    @test result(rs)[:x1] == expected[:x1]          # golden master
    @test isempty(rs.history)                       # M6.4 invariant preserved

    # Round-trip via s.initial fallback (M6.4 / Replay.jl L3 absence
    # path). M7.6's integration leaves this path bit-for-bit
    # unchanged.
    unrun!(rs, vm)
    @test rs.step_count == 0
    @test isempty(rs.history)
    @test rs.current == initial_current
    @test rs.current == rs.initial
    @test rs.current.status === :running
end

@testset "M7.7 — cross-K invariance: L2 push pattern is K-insensitive" begin
    # The L2 push pattern depends on must_cache_set membership only;
    # K affects ONLY the L3 branch (which is starved by the L2 branch
    # under the M7.5 stub). Therefore the number of DeltaEntry pushes
    # MUST be identical across K, and the number of CheckpointEntry
    # pushes MUST be zero across K. The sub-linear ratio MUST satisfy
    # ≤ 0.5 across K.
    #
    # Mutation cited: a bug at the push site that swapped the L2 / L3
    # branch order (L3 first, L2 second; the inverse of the
    # composition rule) would make small-K runs prefer L3 at K-
    # multiples, breaking history-length identity across K.

    n_swap_pairs = 18
    n_arith = 2
    expected_history_len = n_arith               # one delta per non-inj
    expected_step_count = n_swap_pairs + n_arith + 2

    # K values: 1 (most aggressive L3 trigger; would push at EVERY
    # step under M4.2 alone), 4 (canonical M4.5 sweep value), and
    # typemax(Int) (L3 effectively disabled — every non-inj must come
    # from L2).
    for K in (1, 4, typemax(Int))
        vm = _m7_injective_dominated_program(n_swap_pairs, n_arith)
        input = _m7_inj_dominated_input()
        rs = initial_state(vm, input)
        initial_current = deepcopy(rs.current)

        set = BennettVM.compute_must_cache(vm)
        run!(rs, vm; checkpoint_interval=K, must_cache_set=set)

        @test is_halted(rs)
        @test rs.step_count == expected_step_count

        # Identical L2 count regardless of K (the load-bearing
        # assertion).
        @test length(rs.history) == expected_history_len
        @test all(e -> e isa BennettVM.DeltaEntry, rs.history)
        @test !any(e -> e isa BennettVM.CheckpointEntry, rs.history)

        # Sub-linear ratio under every K.
        ratio = length(rs.history) / rs.step_count
        @test ratio <= 0.5

        # Round-trip per K.
        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
    end
end

@testset "M7.7 — mid-run unrun! composes L2 fast-path with L3 fallback" begin
    # Run forward N/2 steps (mid-run; NOT to halt) on the injective-
    # dominated program; then unrun! the partial trace. M4.4's
    # `unrun!` must compose the M7.4 L2 fast-path (pop a DeltaEntry,
    # apply per-instruction inverse) with the M4.3 L3 fallback (when
    # no DeltaEntry is at the top of history because the most recent
    # forward step was injective and pushed nothing, unstep! falls
    # back to s.initial + forward replay).
    #
    # The fixture's structure (18 Swap then 2 Arith) puts BOTH non-
    # injective steps near the END of the trace, so a mid-trace cut
    # falls in the middle of the Swap chain — every backward step
    # uses the L3 fallback (no L2 entries to pop). Sliding the cut
    # past step 20 forces L2 entries into play.
    #
    # Mutation cited: dropping the s.initial fallback at
    # `src/history/Replay.jl:259-265` would error "no checkpoint at
    # step 0" on the very first backward unstep! in the mid-Swap cut
    # below, where no DeltaEntry exists yet.

    n_swap_pairs = 18
    n_arith = 2
    vm = _m7_injective_dominated_program(n_swap_pairs, n_arith)
    input = _m7_inj_dominated_input()
    set = BennettVM.compute_must_cache(vm)

    # Sub-case A: cut at step 10 (deep inside Swap chain; no L2
    # entries yet in history).
    let
        rs = initial_state(vm, input)
        initial_current = deepcopy(rs.current)
        for _ in 1:10
            step!(rs, vm; must_cache_set=set)
        end
        @test rs.step_count == 10
        @test !is_halted(rs)
        @test isempty(rs.history)                 # all Swaps so far; L1 only

        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
    end

    # Sub-case B: cut at step 21 (one Arith pushed; one Swap remains
    # between the Arith and the End — but the body order is "Swap*N
    # then Arith*M", so steps 2..19 are Swap, 20..21 are Arith, 22
    # is End). Wait — let me recount: step 1 = Begin, steps 2..19 =
    # 18 Swaps, steps 20..21 = 2 Arith, step 22 = End. Cut at 21
    # leaves 2 DeltaEntries in history.
    let
        rs = initial_state(vm, input)
        initial_current = deepcopy(rs.current)
        for _ in 1:21
            step!(rs, vm; must_cache_set=set)
        end
        @test rs.step_count == 21
        @test !is_halted(rs)
        @test length(rs.history) == 2             # both Arith steps pushed
        @test all(e -> e isa BennettVM.DeltaEntry, rs.history)

        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
    end

    # Sub-case C: cut at step 20 (one Arith pushed; mid-Arith).
    let
        rs = initial_state(vm, input)
        initial_current = deepcopy(rs.current)
        for _ in 1:20
            step!(rs, vm; must_cache_set=set)
        end
        @test rs.step_count == 20
        @test length(rs.history) == 1
        @test rs.history[1] isa BennettVM.DeltaEntry

        unrun!(rs, vm)
        @test rs.step_count == 0
        @test isempty(rs.history)
        @test rs.current == initial_current
    end
end

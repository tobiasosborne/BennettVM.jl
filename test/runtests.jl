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
    # M_UNBOUNDED (ADR 0012 §D1) — `Define`, the reversible SSA-create
    # instruction (`bennettvm-d3p`). Unit tests for forward (arithmetic +
    # comparison families), the operands-survive / overwrite-at-forward
    # properties, constructor validation, the load-bearing
    # `is_injective(Define) == false` pin, the deferred-`inverse` raise,
    # and an end-to-end two-block `run!`. Sits with the other M2.x
    # instruction unit tests; depends only on already-loaded symbols.
    include("test_define.jl")
    # M_UNBOUNDED (ADR 0012 §D3) — `SelectInstruction`, the reversible
    # 2-to-1 multiplexer (`bennettvm-8wj`). Unit tests for forward (arm
    # selection under cond=0/1/nonzero, literal operand), the
    # operands-survive / overwrite-at-forward properties, constructor
    # validation, the load-bearing `is_injective(SelectInstruction) ==
    # false` pin, the deferred-`inverse` raise, and an end-to-end
    # single-block `run!` (Define-builds-cond + SelectInstruction).
    # Sits right after `test_define.jl` — its sibling; depends only on
    # already-loaded symbols.
    include("test_select.jl")
    # M_OPCODE (ADR 0013 §D-5 step 1, ADR 0012 §D1 template) —
    # `CastInstruction`, the reversible width-cast SSA-create
    # (`bennettvm-hek`). Unit tests for forward (sext/zext/trunc with
    # hand-computed LLVM-semantics expected values, incl. high-bit-set
    # zext, negative-from-width sext, high-bit-dropping trunc), operand-
    # survives / overwrite-at-forward, literal operand, constructor
    # validation (op domain + width range + SSA single-assignment), the
    # load-bearing `is_injective(CastInstruction) == false` pin, and the
    # deferred-`inverse` raise. Sits right after `test_select.jl` — its
    # sibling create; depends only on already-loaded symbols.
    include("test_cast_instruction.jl")
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
    # M_UNBOUNDED.1 — the real `lower_vm` ParsedIR ingest (`bennettvm-c39`,
    # ADR 0012). Lowers `collatz_steps(::Int8)` (PRD v4 §3.6.2 Case D) to a
    # VMProgram and asserts FORWARD `run!` reproduces the irreversible
    # oracle bit-for-bit on three non-overflowing inputs, plus a single
    # round-trip smoke (run! → unrun! → initial + empty history). Sits
    # after the M4/M7 round-trip family because the smoke exercises the L3
    # checkpoint-replay `unrun!` those milestones land; pulls in the
    # oracle + `collatz_vm` factory via `test/reference/collatz.jl`.
    include("test_collatz_forward.jl")
    # SC9 Case C — matrix_sum (nested loops) forward gate (`bennettvm-k7b`,
    # ADR 0010). The nested-loop analogue of test_collatz_forward.jl:
    # lowers `matrix_sum_while(::Int8)` (PRD v4 §3.6.2 Case C) — a
    # doubly-nested counting `while` — to a 12-block VMProgram and asserts
    # FORWARD `run!` reproduces the irreversible oracle bit-for-bit on five
    # in-range inputs (headline: matrix_sum_while(3) == 9). The existing
    # M_UNBOUNDED ingest lowers the multi-level BasicBlock CFG with ZERO
    # `src/` changes (bead `bennettvm-720`). Sits after the collatz forward
    # gate; pulls in the oracles + `matrix_sum_vm` factory via
    # `test/reference/matrix_sum.jl`.
    include("test_matrix_sum_forward.jl")
    # M8.2 — per-step inverse test scaffold (`bennettvm-3d8`).
    # Sits AFTER test_delta_roundtrip.jl because the scaffold's M7
    # driver-layer testset depends on `compute_must_cache` (M7.5) and
    # the M7.6 push-site integration both being exercised first. The
    # scaffold itself is reusable infrastructure consumed by M8.3
    # (`bennettvm-2kl`, mutation-proof harness), M8.4
    # (`bennettvm-bii`, seeded random program generator), and M8.5
    # (`bennettvm-tnp`, 100-random-programs property test).
    include("test_per_step_inverse.jl")
    # M_UNBOUNDED.3 — collatz round-trip / SC9 Case D acceptance gate
    # (`bennettvm-hvx`, ADR 0012). The definitive round-trip proof for
    # the unbounded `while` the circuit backend cannot compile: per-step
    # inverse (L3) across multiple non-overflowing inputs at two K
    # densities, aggregate run!/unrun! anchored to the oracle, the SC9
    # headline assertion, and the L2-raises boundary documenting the
    # L3-only reversal contract. Sits AFTER test_per_step_inverse.jl
    # because it consumes the M8.2 `per_step_inverse_check` scaffold;
    # pulls in the oracle + `collatz_vm` factory via
    # `test/reference/collatz.jl` (re-include-guarded).
    include("test_collatz_roundtrip.jl")
    # SC9 Case C — matrix_sum (nested loops) round-trip acceptance gate
    # (`bennettvm-k7b`, ADR 0010). The nested-loop analogue of
    # test_collatz_roundtrip.jl: the definitive round-trip proof for the
    # doubly-nested counting loop the circuit backend cannot represent —
    # per-step inverse (L3) across six inputs at two K densities, aggregate
    # run!/unrun! anchored to the oracle (the nested run unwinds BOTH inner-
    # and outer-loop history under L3, bead `bennettvm-of5`), the SC9
    # headline assertion (n=3 → 9 → empty history), and the L2-raises
    # boundary. Sits AFTER test_per_step_inverse.jl (consumes the M8.2
    # `per_step_inverse_check` scaffold) and after the collatz round-trip
    # gate; pulls in the oracles + `matrix_sum_vm` factory via
    # `test/reference/matrix_sum.jl` (re-include-guarded).
    include("test_matrix_sum_roundtrip.jl")
    # matrix_tri (triangular nested loops) round-trip acceptance gate
    # (bead `bennettvm-e4l`, the IRCast end-to-end gate of `bennettvm-hek`;
    # ADR 0012 §D5 / ADR 0013). The NON-RECTANGULAR-nest analogue of
    # test_matrix_sum_roundtrip.jl: `matrix_tri_while(::Int8)` is a
    # doubly-nested `while` whose inner trip count varies with the outer
    # index (triangular sum `sum_{i=1}^n i(i+1)/2`). It is the program that
    # surfaced the within-edge synthetic-constant φ-name collision (e4l):
    # its `top → L7.preheader` edge sends the same constant into two φ-param
    # slots, which the pre-fix by-value-only dedup collapsed into a
    # duplicate `UnconditionalExit` arg. This gate is the end-to-end witness
    # that the cross-edge-share + within-edge-fresh-create fix
    # (`src/ir/ingest.jl`) lets the triangular nest lower, run forward
    # matching the oracle, and round-trip — and that the IRCast lowering
    # (`bennettvm-hek`) handles its sign-extended counters. Per-step inverse
    # (L3) across eight inputs at two K densities, aggregate run!/unrun!
    # anchored to the oracle, the headline (n=3 → 10 → empty history), and
    # the L2-raises boundary. Sits AFTER test_per_step_inverse.jl (consumes
    # the M8.2 `per_step_inverse_check` scaffold) and after the matrix_sum
    # round-trip gate; pulls in the oracles + `matrix_tri_vm` factory via
    # `test/reference/matrix_tri.jl` (re-include-guarded).
    include("test_matrix_tri_roundtrip.jl")
    # Memory floor (scalar IRAlloca/IRStore/IRLoad) unit + lowering tests
    # (bead `bennettvm-x9j`, ADR 0014 §D1–D4; ADR 0013 §D-2). Pins the new
    # `MemoryStore` / `MemoryLoad` instructions (`src/ir/memory_floor.jl`):
    # forward semantics (store-then-load, zero-init absent read), the
    # non-injective L3 classification, the deferred per-instruction inverse,
    # the bump-allocator addressing (distinct base addresses per scalar
    # alloca), the v1 scope guard (array / dynamic-N raise), and a hand-built
    # scalar ParsedIR lowered + run + round-tripped under L3 via the
    # `per_step_inverse_check` scaffold. Sits after the matrix_tri gate
    # (consumes the same M8.2 scaffold).
    include("test_memory_floor.jl")
    # Memory floor — THE EMITTER-AGNOSTIC GATE (bead `bennettvm-x9j`, ADR
    # 0014 §D5; ADR 0013 §D-1). Proves BennettVM round-trips a **C** program:
    # `int through_mem(int n){int s; s=n+1; return s;}` compiled clang-18 -O0
    # to a committed `.ll` (clang-free at test time), extracted via Bennett's
    # language-agnostic `extract_parsed_ir_from_ll`, lowered via the real
    # `lower_vm`, run forward matching the C oracle (n+1), and round-tripped
    # to empty history under L3 (P0.6). The executable demonstration that
    # BennettVM is useful to ANY LLVM emitter, not just Julia.
    include("test_memory_floor_cll.jl")
    # SC9 Case A Unit 1 — static-size array floor (bead precursor to
    # `bennettvm-ekc`; ADR 0009 Decisions 2b & 4). The array analogue of
    # test_memory_floor.jl: pins the new `VarGEP` instruction
    # (`src/ir/array_index.jl`, `dest := base + index*stride`, stride in
    # CELLS) and the `_lower_alloca!` lift to `ConstOperand(N>=1)` (bump
    # allocator reserves N consecutive cells). A hand-built static-array
    # ParsedIR (alloca N=4; arr[0..3]=…; gep arr[idx]; load; ret) lowered via
    # the real `lower_vm`, run forward matching an irreversible oracle
    # bit-for-bit across all in-range indices, and round-tripped under L3 via
    # the `per_step_inverse_check` scaffold at K ∈ {1, 4}. Also pins the
    # VarGEP forward arithmetic (base=5,index=3,stride=1 → 8), the
    # non-injective L3 classification, the deferred per-instruction inverse,
    # and the dynamic-N (SSAOperand) v1→v2 guard (still deferred, bead 0zn).
    # Sits right after the scalar memory-floor gates (consumes the same M8.2
    # scaffold and the same MemoryStore/MemoryLoad floor).
    include("test_array_floor.jl")
    # SC9 Case A Unit 2 — indexed lossy store + (addr, old_value) L2 delta
    # (bead `bennettvm-ekc`; ADR 0009 Decision 2b/4.4). The FIRST L2 delta
    # that needs PRE-`forward()` state: a `MemoryStore` reverses via the
    # cheap M7.4 delta fast-path (capturing the overwritten cell's value +
    # presence BEFORE forward()) instead of an L3 full-state checkpoint.
    # Lands the `step!` `predelta_payload` pre-state hook
    # (`src/interpreter/Interpreter.jl`, capturing O(1) per store — NO full
    # IState deepcopy), `MemoryStore`'s `predelta_payload` +
    # `inverse(::MemoryStore, s, ::NamedTuple)` (`src/ir/memory_floor.jl`),
    # and the absent-cell delete branch (the ADR 0008 Dict missing-sentinel
    # trap). Sits right after the Unit-1 array floor it builds on; reuses
    # the same hand-built array `ParsedIR` shape and the M8.2 scaffold.
    include("test_store_delta.jl")
    # SC9 Case A — dynamic-N alloca + (base, n) L2 delta (bead
    # `bennettvm-0zn`; ADR 0009 Decision 2a). The runtime-sized allocation
    # rung: an `IRAlloca` with an `SSAOperand` n_elems (a C VLA / Julia
    # `Vector(undef, n)`) lowers to a `DynAlloca` (`src/ir/alloca.jl`) whose
    # `forward` materialises the pointer at a FROZEN compile-time base (no
    # runtime bump state in IState) and whose L2 `(base, n)` delta retracts
    # the whole region on reverse — UNCONDITIONALLY deleting `base..base+n-1`,
    # sound under L2/L3 store interleave (the soundness lemma). Lands the
    # ingest dynamic-N dispatch + the single-dynamic-array fail-loud guard
    # (`src/ir/ingest.jl`) and the `is_injective(::Type{DynAlloca}) = false`
    # pin (`src/history/Injective.jl`). Sits right after the Unit-2 store
    # delta it composes with (the region's element stores) and reuses the same
    # hand-built array `ParsedIR` shape + the M8.2 `per_step_inverse_check`.
    include("test_alloca_delta.jl")
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

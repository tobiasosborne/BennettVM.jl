# test/test_mutation_proof.jl — M8.3 mutation-proof harness for the
# per-instruction `inverse()` methods (bd `bennettvm-2kl`).
#
# # Why mutation testing matters here
#
# The Phase-0 spike retrospective (`spike/RETROSPECTIVE.md` Q4 §"Test
# patterns worth keeping") identified mutation-proof discipline —
# "perturb the impl, confirm RED, restore" — as the only test pattern
# that distinguishes "tests exist" from "tests have caught a real
# regression." PRD v4 §3.13 binds this discipline at the per-step
# inverse layer: every `inverse(::T, s, prev)` method is a load-bearing
# contract whose silent breakage would corrupt the M4.5 round-trip
# invariant but only at instruction kinds the round-trip happens to
# exercise — and the M8.2 scaffold's worst failure mode pre-fix
# (`test/test_per_step_inverse.jl` file-level docstring §"Mutation-
# proof evidence") was exactly this: a no-op'd
# `inverse(::ArithmeticAssignment, ...)` left every countdown test
# GREEN because the M4.5/empty-must_cache path falls through to L3
# forward replay, never calling `inverse()`.
#
# This file is the systematic per-instruction `inverse()` audit. For
# each of the five required kinds, it (1) deliberately replaces the
# production `inverse()` body with a wrong-refactor mutation, (2)
# confirms the per-step inverse contract fires RED with a step-indexed
# + field-named diagnostic message, and (3) restores the original
# method with airtight `try/finally` semantics and a post-restore
# GREEN assertion.
#
# # Why this mutation strategy (option (a): eval + Base.delete_method
# # with try/finally + post-restore GREEN assertion)
#
# Julia 1.12.3 has no production-clean method-overlay mechanism that
# fits the BennettVM harness shape:
#
#   * Option (b) (re-define from a verbatim body captured in the
#     harness): would silently drift when production source changes.
#   * Option (c) (subprocess per mutation): O(precompile-cost) per
#     cycle in this 2018-test suite — prohibitive in single-process
#     runtests.jl, and CLAUDE.md Rule 7 forbids parallel Julia.
#   * Option (d) (kwarg injection of an `inverse_fn`): would change
#     the production `inverse` dispatch surface for test purposes
#     only, violating the "no backwards-compat shims" smell test.
#   * Option (e) (`Base.Experimental.@MethodTable` + `@overlay`,
#     Julia 1.10+): production-API-clean in principle, but coverage of
#     how `compute_must_cache` / `unstep!` interact with overlaid
#     dispatch is undocumented in the Julia manual entry
#     `https://docs.julialang.org/en/v1/devdocs/method-overlay/`
#     (consulted 2026-05-27; experimental, no stability guarantee).
#
# Option (a) wins on directness. `BennettVM.eval(body)` shadows the
# canonical method (Julia adds the new method to the table; same
# signature → it wins on dispatch); `Base.delete_method(m)` on the
# mutation reference restores the canonical. The cycle cost is bounded
# (microseconds per cycle); the failure mode is **restoration failure
# → corrupted method table → cascade failure on every subsequent
# test**. The guard is a **post-restore GREEN assertion** wrapped in
# `try/finally`: if restoration silently fails, the GREEN assertion
# goes RED and the test process aborts immediately. The mutation-
# identification step uses a *set-diff snapshot* — capture the method-
# table state before mutation, compute `after \ before` to find the
# mutation method — which is robust to any number of identical-
# signature methods being added by the mutation block.
#
# # World-age caveat (the gotcha discovered empirically)
#
# Julia's world-age semantics make a freshly-`eval`'d method INVISIBLE
# to any call from inside a function whose compilation predates the
# `eval` (the function's dynamic frame captured a world age at entry).
# Mid-implementation, every mutation cycle silently returned GREEN
# because `run_mutation_cycle` is a function, and the `eval(body)`
# inside it does not advance the world age visible to subsequent calls
# from that same frame. The fix is `Base.invokelatest(f, args...)`,
# which forces dynamic dispatch at the current world. **Every call
# into the mutated production code in this file goes through
# `Base.invokelatest`.** Without it, the harness is silently broken;
# with it, mutations are correctly observed by every call site through
# `unstep!` → `inverse()`. Reference: Julia manual §Methods,
# "Redefining Methods" (consulted 2026-05-27).
#
# The honest failure mode I am accepting: per Julia 1.12.3
# `base/runtime_internals.jl:1317` (`delete_method`, read 2026-05-27),
# the only documented failure mode is calling it on a default-defined
# method (e.g., one defined in Base itself); every method in the
# set-diff is one we just defined via `BennettVM.eval`, so this cannot
# fire here. A `delete_method` Julia upstream bug would surface as the
# post-restore GREEN assertion going RED — loud and obvious, not silent
# corruption (Rule 1).
#
# # What the harness does NOT cover
#
#   * **Mutations to `forward()`.** Wrong-forward would corrupt the
#     captured snapshots themselves; per-step inverse check would
#     compare a corrupted forward path against itself and stay GREEN.
#     Forward correctness is a distinct audit (gold-master oracle
#     agreement in `test/reference/countdown.jl`); the M8.3 brief
#     scopes mutation-proof to `inverse()` only.
#   * **Mutations to `make_delta()`.** L2 payload is empty for all
#     five kinds (per ADR 0002 §DeltaEntry payload schema); a
#     non-empty-payload mutation would not corrupt the inverse
#     delegation path. Out of scope; future bead if non-empty payloads
#     appear.
#   * **`CallInstruction.inverse()` — NOW partially audited (bd
#     `bennettvm-7cg`).** Its pc-only dispatch-level `inverse()`
#     (`src/ir/call_instruction.jl`) IS exercised here via a `:direct`
#     pc-symmetry round-trip (the `CallInstruction/no-pc` manifest
#     entry): `forward` bumps pc, the canonical `inverse` un-bumps, and
#     the mutation that drops the un-bump fires RED. What stays out of
#     scope: the **L2-scaffold path remains impossible** because the
#     M7.3 `make_delta(::CallInstruction)` still raises unconditionally
#     (v5-deferred per ADR 0002 §Open Questions item 4) — no delta is
#     ever pushed, so `unstep!` never delegates to this inverse via the
#     M7.4 fast-path. Only the pc-only dispatch-level inverse is
#     covered; the recursive-callee audit (destruction of `args`,
#     creation of `targets`, sub-execution of the callee) is
#     intrinsically a v5 concern and is NOT exercised by this entry.
#   * **Cross-kind interactions.** Each mutation cycle is independent.
#
# # Operational warning
#
# If the post-restore GREEN assertion in `run_mutation_cycle` ever
# raises, the Julia process method-table is corrupted. DO NOT attempt
# to continue the test suite — restart `julia` and investigate the
# most recent mutation cycle. The harness is designed so this can
# only happen if `Base.delete_method` semantics changed under us (a
# Julia upstream bug); file a `bennettvm-` bead and escalate per
# CLAUDE.md "Stop conditions".
#
# # L1-injective short-circuit (the L2-path-only constraint)
#
# The M7.6 push site (`src/interpreter/Interpreter.jl:743-748`) checks
# `is_injective(instr)` BEFORE the must_cache check, so the L1
# short-circuit always wins on injective instructions — they never
# reach L2 push, and their `inverse()` is therefore never called by
# `unstep!` via the L2 fast-path. The three injective kinds in the
# required-coverage list (SwapInstruction, MemoryInterchange,
# MemorySwap) are therefore tested via the **M6.3 direct-invocation
# pattern** (forward + inverse round-trip, no scaffold) — the actual
# call site for their `inverse()` per `test/test_injective_inverse.jl`.
# The two non-injective kinds (ArithmeticAssignment :sub modop in
# countdown; MemoryAssignment :add modop in a tiny custom program) are
# tested via the M8.2 scaffold's L2 path with `must_cache_set =
# compute_must_cache(vm)`. Both shapes share the eval+delete_method +
# try/finally + post-GREEN structure; only the driver differs.
#
# # Ref
#
#   * `bennettvm_prd.md` (PRD v4) §3.13 (per-step inverse), §3.15
#     (property-test discipline; M8 family).
#   * `spike/RETROSPECTIVE.md` Q4 — mutation-proof discipline's origin.
#   * `test/test_per_step_inverse.jl` (M8.2) — the scaffold this
#     harness drives for non-injective L2 cycles.
#   * `test/test_injective_inverse.jl` (M6.3) — the direct-invocation
#     pattern this harness drives for injective cycles.
#   * `src/interpreter/Interpreter.jl:743-748` — the L1/L2/L3 push-
#     site triage that makes injective `inverse()` unreachable via
#     `unstep!`.
#   * `src/history/Injective.jl` (M6.1) — the trait pinning which
#     kinds short-circuit at L1.
#   * `bd bennettvm-2kl` (M8.3) — this milestone.
#   * CLAUDE.md Rule 1 (fail loud on restoration failure); Rule 4
#     (assert specific expected red signal); Rule 5 (mutation-prove
#     the tests catch regressions); Rule 7 (single Julia process);
#     Rule 11 (literate top-of-file docstring).

using Test
using BennettVM

include(joinpath(@__DIR__, "reference", "countdown.jl"))

# ---------------------------------------------------------------------
# 1. Fixtures
# ---------------------------------------------------------------------

# countdown(3): exercises ArithmeticAssignment(:sub, ...) and
# ArithmeticAssignment(:add, ...) through L2 (6 non-injective body
# steps in compute_must_cache).
_arith_vm() = (countdown_program(3),
               Dict(:n0 => Int64(3), :steps0 => Int64(0)))

# Single-block VM: Begin + MemoryAssignment(:add) + End. The smallest
# program that drives inverse(::MemoryAssignment, s, prev) via L2.
function _memassign_vm()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:a, :b]),
        BennettVM.Instruction[
            BennettVM.MemoryAssignment(Int64(100), :add, :a, :and, :b)],
        BennettVM.EndInstruction(:m, [:a, :b]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64, 64], [64, 64])
    return vm, Dict(:a => Int64(5), :b => Int64(7))
end

# Direct-path fixtures for the three injective kinds.
const _SWAP_INSTR = BennettVM.SwapInstruction(:p, :q, :a, :b)
const _SWAP_PRE   = BennettVM.IState(0,
    Dict(:a => Int64(11), :b => Int64(22)),
    :running, Dict{Int64,Int64}())
const _MI_INSTR   = BennettVM.MemoryInterchange(:x, Int64(50), :z)
const _MI_PRE     = BennettVM.IState(0,
    Dict(:z => Int64(77)),
    :running, Dict{Int64,Int64}(50 => Int64(33)))
const _MS_INSTR   = BennettVM.MemorySwap(Int64(10), Int64(20))
const _MS_PRE     = BennettVM.IState(0,
    Dict{Symbol,Int64}(), :running,
    Dict{Int64,Int64}(10 => Int64(111), 20 => Int64(222)))
# Direct-path fixture for CallInstruction (bd `bennettvm-7cg`). The L2-
# scaffold path is impossible to drive (its `make_delta` raises v5-
# deferred; see src/ir/call_instruction.jl), but the pc-only forward/
# inverse stubs ARE exercisable via the M6.3 direct round-trip: forward
# bumps pc 0→1, the canonical inverse un-bumps 1→0. A `:direct` mutation
# that drops the un-bump leaves pc stale → RED. `:sub` is a label-ish
# callee symbol; targets/args/callee are pairwise disjoint, so the
# constructor's SSA-overlap checks pass.
const _CALL_INSTR = BennettVM.CallInstruction([:x], :sub, [:y], :call)
const _CALL_PRE   = BennettVM.IState(0,
    Dict(:y => Int64(1)),
    :running, Dict{Int64,Int64}())

# Type-tuple lookup for the inverse method signature per kind. Used
# by both the snapshot/restore primitives and the run driver.
const _TYPES = Dict(s => (getfield(BennettVM, s), BennettVM.IState, Any)
    for s in (:ArithmeticAssignment, :MemoryAssignment, :SwapInstruction,
              :MemoryInterchange, :MemorySwap, :CallInstruction))

# ---------------------------------------------------------------------
# 2. Mutation lifecycle primitives + drivers
# ---------------------------------------------------------------------

# Set-diff snapshot/restore: capture method-table state before
# mutation; restore by deleting any method present in `after \ before`.
# Robust to identical-signature shadowing.
_snapshot(kind) = Set{Method}(methods(BennettVM.inverse, _TYPES[kind]))
function _restore!(kind, before)
    n = 0
    for m in methods(BennettVM.inverse, _TYPES[kind])
        if !(m in before)
            Base.delete_method(m); n += 1
        end
    end
    return n
end

# RED + GREEN drivers. CRITICAL: every call into the mutated production
# code is wrapped in `Base.invokelatest(...)`. Without it, Julia's
# world-age semantics make the mutation INVISIBLE to any call from
# inside a function whose compilation predates the mutation — including
# `run_mutation_cycle` itself (the surrounding `function ... end`
# captures world age at entry and the `BennettVM.eval` inside is
# unobserved by direct calls in the same dynamic frame). Discovered
# empirically 2026-05-27 during M8.3 implementation: without invokelatest,
# every mutation cycle silently returned GREEN. The invokelatest wrapper
# forces dynamic dispatch at the current world, picking up the mutation.
# See `https://docs.julialang.org/en/v1/manual/methods/#Redefining-Methods`
# (consulted 2026-05-27) on world-age semantics.

# RED driver — scaffold path (L2 via per_step_inverse_check). The
# `label` flows into the diagnostic via `[$label]` (per
# `_assert_istate_eq` in `test/test_per_step_inverse.jl`); making it
# kind/style-specific lets the per-mutation @test occursin check pin
# the *intended* mutation rather than match any unrelated MISMATCH
# (Rule 4 — kind-specific RED fragments).
function _red_scaffold(vm_factory, label::AbstractString)
    vm, inputs = vm_factory()
    set = BennettVM.compute_must_cache(vm)
    try
        Base.invokelatest(per_step_inverse_check, vm, inputs;
            checkpoint_interval=typemax(Int),
            must_cache_set=set, label=label)
        return (false, "")
    catch e
        e isa ErrorException || rethrow()
        return (true, e.msg)
    end
end

# RED driver — direct path (M6.3 forward+inverse round-trip). The L1
# short-circuit makes this the only call site for inverse() on
# injective kinds. The `label` prefixes the emitted MISMATCH message
# so the per-mutation @test occursin pins the intended mutation
# (Rule 4).
function _red_direct(fixture, label::AbstractString)
    (instr, s_pre) = fixture
    try
        s_after = Base.invokelatest(BennettVM.forward, instr, deepcopy(s_pre))
        s_rec = Base.invokelatest(BennettVM.inverse, instr, s_after, nothing)
        s_rec == s_pre && return (false, "")
        return (true, "[$label] direct-inverse MISMATCH: expected $(repr(s_pre)) got $(repr(s_rec))")
    catch e
        # Mutation may raise (e.g., KeyError if it deletes the wrong
        # local). That's also RED — pass the message through.
        return (true, "[$label] direct-inverse RAISED MISMATCH: $(sprint(showerror, e))")
    end
end

# GREEN re-runners (post-restore, load-bearing).
function _green_scaffold(vm_factory)
    vm, inputs = vm_factory()
    set = BennettVM.compute_must_cache(vm)
    Base.invokelatest(per_step_inverse_check, vm, inputs;
        checkpoint_interval=typemax(Int), must_cache_set=set,
        label="POST_RESTORE_GREEN")
end
function _green_direct(fixture)
    (instr, s_pre) = fixture
    s_after = Base.invokelatest(BennettVM.forward, instr, deepcopy(s_pre))
    s_rec = Base.invokelatest(BennettVM.inverse, instr, s_after, nothing)
    s_rec == s_pre || error("POST_RESTORE_GREEN: direct-inverse round-trip ",
        "failed; method table not restored. expected=$(repr(s_pre)) ",
        "actual=$(repr(s_rec))")
end

# ---------------------------------------------------------------------
# 3. Mutation manifest
# ---------------------------------------------------------------------
#
# Each entry: (kind, label, body::Expr, mode, fixture). Mode :scaffold
# drives the L2 path via per_step_inverse_check; mode :direct drives
# the M6.3 forward+inverse pattern. The expected RED-message fragment
# is `"M8.3/$(kind)/$(label)"` (computed at use site, threaded as the
# `label` kwarg into both drivers — keeps fragments kind/style-specific
# per Rule 4 with zero per-entry duplication). Mutations cover the
# most common wrong-refactor failure modes (no-op pc-only; skipped
# dual_modop flip; one-sided exchange).

const _MANIFEST = Any[
(:ArithmeticAssignment, "no-op", quote
    function inverse(instr::ArithmeticAssignment, s::IState, prev)::IState
        s.pc -= 1; return s
    end
end, :scaffold, _arith_vm),

(:ArithmeticAssignment, "skip-dual-modop", quote
    function inverse(instr::ArithmeticAssignment, s::IState, prev)::IState
        lv = BennettVM._resolve(instr.lhs, s)
        rv = BennettVM._resolve(instr.rhs, s)
        e  = BennettVM._apply_binop(instr.op, lv, rv)
        xval = s.locals[instr.target]
        # BUG: should be dual_modop(instr.modop); uses raw modop instead.
        yval = BennettVM._apply_modop(instr.modop, xval, e)
        delete!(s.locals, instr.target)
        s.locals[instr.source] = yval
        s.pc -= 1; return s
    end
end, :scaffold, _arith_vm),

(:MemoryAssignment, "no-op", quote
    function inverse(instr::MemoryAssignment, s::IState, prev)::IState
        s.pc -= 1; return s
    end
end, :scaffold, _memassign_vm),

(:MemoryAssignment, "skip-dual-modop", quote
    function inverse(instr::MemoryAssignment, s::IState, prev)::IState
        a   = BennettVM._resolve(instr.addr, s)
        lv  = BennettVM._resolve(instr.lhs,  s)
        rv  = BennettVM._resolve(instr.rhs,  s)
        e   = BennettVM._apply_binop(instr.op, lv, rv)
        # BUG: should be dual_modop(instr.modop); uses raw modop instead.
        new_val = BennettVM._apply_modop(instr.modop, s.memory[a], e)
        new_val == Int64(0) ? delete!(s.memory, a) : (s.memory[a] = new_val)
        s.pc -= 1; return s
    end
end, :scaffold, _memassign_vm),

(:SwapInstruction, "no-op", quote
    function inverse(instr::SwapInstruction, s::IState, prev)::IState
        s.pc -= 1; return s
    end
end, :direct, (_SWAP_INSTR, _SWAP_PRE)),

(:SwapInstruction, "one-sided", quote
    function inverse(instr::SwapInstruction, s::IState, prev)::IState
        # BUG: only restores source1; target2 left in locals and
        # source2 never restored.
        v1 = s.locals[instr.target1]
        delete!(s.locals, instr.target1)
        s.locals[instr.source1] = v1
        s.pc -= 1; return s
    end
end, :direct, (_SWAP_INSTR, _SWAP_PRE)),

(:MemoryInterchange, "no-op", quote
    function inverse(instr::MemoryInterchange, s::IState, prev)::IState
        s.pc -= 1; return s
    end
end, :direct, (_MI_INSTR, _MI_PRE)),

(:MemoryInterchange, "one-sided", quote
    function inverse(instr::MemoryInterchange, s::IState, prev)::IState
        a    = BennettVM._resolve(instr.addr, s)
        xval = s.locals[instr.target]
        xval == Int64(0) ? delete!(s.memory, a) : (s.memory[a] = xval)
        # BUG: destroys target but never restores source.
        delete!(s.locals, instr.target)
        s.pc -= 1; return s
    end
end, :direct, (_MI_INSTR, _MI_PRE)),

(:MemorySwap, "no-op", quote
    function inverse(instr::MemorySwap, s::IState, prev)::IState
        s.pc -= 1; return s
    end
end, :direct, (_MS_INSTR, _MS_PRE)),

# MemorySwap "one-sided": restores addr1 from the post-forward swap
# value but leaves addr2 stale. Catches the refactor mistake of
# editing the inverse and forgetting one cell. Fixture `_MS_PRE`
# (M[10]=111, M[20]=222) has different values at addr1 vs addr2, so
# the one-sidedness produces an observable divergence at addr2.
(:MemorySwap, "one-sided", quote
    function inverse(instr::MemorySwap, s::IState, prev)::IState
        a = BennettVM._resolve(instr.addr1, s)
        b = BennettVM._resolve(instr.addr2, s)
        vb = get(s.memory, b, Int64(0))
        vb == Int64(0) ? delete!(s.memory, a) : (s.memory[a] = vb)
        # BUG: addr2 (b) never written; left at post-forward value.
        s.pc -= 1; return s
    end
end, :direct, (_MS_INSTR, _MS_PRE)),

# CallInstruction "no-pc" (bd `bennettvm-7cg`): the pc-only dispatch
# inverse must un-bump the pc that `forward` bumped. Dropping `s.pc -= 1`
# leaves pc stale, so forward∘inverse != identity (pc diverges). The
# only audit reachable at this milestone — the L2-scaffold path is
# impossible (make_delta v5-deferred) and the recursive-callee audit is
# intrinsically v5. This `(CallInstruction, IState, Any)` method shadows
# the canonical pc-only inverse; `_red_direct` then runs forward (pc→1)
# and the mutated inverse (pc stays 1), giving s_rec != s_pre → RED.
(:CallInstruction, "no-pc", quote
    function inverse(instr::CallInstruction, s::IState, prev)::IState
        # BUG: omit s.pc -= 1 — forward bumped pc, inverse must un-bump.
        # Leaving pc stale makes forward∘inverse != identity (pc diverges).
        return s
    end
end, :direct, (_CALL_INSTR, _CALL_PRE)),
]

# ---------------------------------------------------------------------
# 4. The mutation cycle driver
# ---------------------------------------------------------------------

"""
    run_mutation_cycle(entry) -> (red::Bool, message::String)

Apply the mutation in `entry`, run the appropriate RED driver
(:scaffold or :direct), then **always** restore via `try/finally`
and verify by re-running the GREEN driver. Raises descriptively if
restoration silently fails (the load-bearing safety mechanism).

The label `"M8.3/<kind>/<label>"` is threaded into both RED drivers
so the emitted MISMATCH message is mutation-specific (Rule 4): a
future regression that emits "MISMATCH" for a *different* mutation
will not match this entry's `occursin` check at the @test site.
"""
function run_mutation_cycle(entry)
    (kind, label, body, mode, fixture) = entry
    diag = "M8.3/$(kind)/$(label)"
    before = _snapshot(kind)
    result = (false, "")
    try
        BennettVM.eval(body)
        result = mode === :scaffold ? _red_scaffold(fixture, diag) :
                 mode === :direct   ? _red_direct(fixture, diag) :
                 error("run_mutation_cycle: unknown mode $(mode)")
    finally
        n = _restore!(kind, before)
        # n>=1 check runs FIRST: if it fails (mutation eval added no
        # methods, e.g., signature drift), the cycle is meaningless and
        # the subsequent GREEN check would silently succeed on the
        # untouched original. Raising here surfaces the structural bug
        # before GREEN can mask it. Post-restore GREEN runs second: the
        # load-bearing safety mechanism for method-table corruption; if
        # this raises, the Julia process method table is corrupted and
        # the test suite should abort (per the file-level "Operational
        # warning" docstring). Both checks always fire in this order.
        n >= 1 || error("[$diag] mutation eval added no methods ",
            "(n_deleted=0); cycle is meaningless. Check mutation signature.")
        mode === :scaffold ? _green_scaffold(fixture) :
                             _green_direct(fixture)
    end
    return result
end

# ---------------------------------------------------------------------
# 5. Per-mutation testsets + manifest-coverage testset
# ---------------------------------------------------------------------

@testset "M8.3 — mutation-proof harness for per-instruction inverse" begin
    for entry in _MANIFEST
        (kind, label, _, _, _) = entry
        expected_fragment = "M8.3/$(kind)/$(label)"
        @testset "$(kind) — $(label)" begin
            (red, msg) = run_mutation_cycle(entry)
            @test red == true                              # (a) RED fired
            @test occursin(expected_fragment, msg)         # (b) Rule 4
        end
    end
end

@testset "M8.3 — mutation manifest coverage" begin
    # Defensive: prevent accidental coverage shrink.
    kinds = Set(entry[1] for entry in _MANIFEST)
    @test :ArithmeticAssignment in kinds
    @test :SwapInstruction      in kinds
    @test :MemoryAssignment     in kinds
    @test :MemoryInterchange    in kinds
    @test :MemorySwap           in kinds
    @test :CallInstruction      in kinds
    @test length(kinds) == 6
    # Each of the five L2/injective kinds contributes >=2 *distinct*
    # mutations (Defect 1 post-fix: the prior manifest had MemorySwap
    # with two textually identical "skip-swap" entries; the one-sided
    # body adds genuine coverage). CallInstruction (bd `bennettvm-7cg`)
    # contributes ONE entry — its only auditable surface is the pc-only
    # `no-pc` direct round-trip (the L2 path is v5-deferred), so a second
    # distinct mutation would have to fabricate v5 semantics (scope
    # creep). The per-kind distinctness loop below only requires unique
    # bodies per kind (1==1 holds for CallInstruction), not >=2.
    # Distinctness = unique (kind, label) pairs AND unique mutation
    # bodies per kind (catches a future copy-paste regression that lifts
    # the same body under two labels).
    @test length(_MANIFEST) == 11
    pairs = Set((entry[1], entry[2]) for entry in _MANIFEST)
    @test length(pairs) == 11
    for k in kinds
        bodies = [entry[3] for entry in _MANIFEST if entry[1] === k]
        @test length(Set(string(b) for b in bodies)) == length(bodies)
    end
end

# test/test_3vf2_dead_use_global_load.jl — the BennettVM (downstream) half of
# Bennett.jl bead `Bennett-3vf2`.
#
# # What upstream changed
#
# Julia's codegen HOISTS `load ptr, ptr @jl_diverror_exception` into the LIVE
# predecessor of a divisor-validity guard diamond whose throwing arm is
# `unreachable`-terminated, so the load SURVIVES the Bennett-utzc dead-block
# pruner even though its sole consumer (`call void @ijl_throw(ptr %exc)`) does
# not. It hit the `bennettvm-416r.13` unrecognised-JIT-global reject — wall 3 of
# the `bennettvm-xkl` (P0) `push!`-Vector chain.
#
# 3vf2's rule is name-agnostic: under `ptr_cells`, a non-volatile / non-atomic
# `load ptr, ptr @GlobalVariable` with >= 1 use, ALL of whose uses lie in the
# pruner's `dead_blocks` set, is DROPPED — no `IRInst`, no `.globals` entry, no
# SSA alias. Soundness is a theorem about the pruner (it empties every dead
# block's body, so nothing emitted can reference the load), not a claim about
# Julia's naming conventions.
#
# # Why BVM has ZERO src changes (and what this file is for)
#
# 3vf2's entire VM-facing effect is SUBTRACTIVE: one live-block instruction is
# no longer emitted. The surviving shape — kept conditional branch + empty dead
# block + `IRBranch(nothing, :__unreachable__, nothing)` — is byte-identical to
# what Bennett-utzc already produces and `test_utzc_unreachable_sink.jl` already
# pins. So there is no new BVM mechanism under test here.
#
# What HAS never been executed is the end-to-end claim: a 3vf2-extracted body
# runs and reverses. That is what this file adds, and it is deliberately scoped
# as end-to-end confidence, NOT as a gate on 3vf2 (whose contract is
# extraction-side). It is also the first time a KEPT, STRUCTURALLY-CONSTANT
# guard (`and(true, or(true, X))` — Julia's literal-divisor idiom, which neither
# Bennett nor the pruner constant-folds) is fed to the VM from this path: the
# branch is real at VM run time and must always take the live arm.
#
# # What this pins (Rule 4 — known values, never "didn't throw")
#
#   (1) the upstream drop actually happened in the ParsedIR BVM receives (no
#       IRLoad, no `.globals` key, no `:exc` operand);
#   (2) `lower_vm` + `run!` reach `:halted` (NOT the `:__unreachable__` sink's
#       `:error`) for every probe, with `result[:q] == div(n, 4)` and the input
#       preserved, under BOTH history regimes (L2 must-cache and L3 empty);
#   (3) `unrun!` returns the EXACT initial state with a drained history.
#
# # Ref
#   * `../Bennett.jl/test/test_3vf2_dead_use_global_load.jl` — the upstream gate
#     (same fixture; the extraction-side assertions live there).
#   * `../Bennett.jl/src/extract/vector_vm_cfg.jl` — `_all_uses_in_dead_blocks`
#     and the drop-soundness theorem / φ corollary.
#   * `test/test_utzc_unreachable_sink.jl` — the sink mechanism itself.
#   * `test/test_tl1l_a70z_shapes.jl` — the hand-written-`.ll`-through-the-real-
#     front-end fixture idiom reused here.

using Test
using BennettVM
import Bennett

const _BV3 = BennettVM
const _BN3 = Bennett

# The load-bearing shape, verbatim from the upstream fixture: the load is
# hoisted into the LIVE `%top`, its sole use is the `ijl_throw` in the DEAD
# `%fail`, and `%divisor_valid` is Julia's structurally-true literal-divisor
# guard.
const _IR3VF2 = """
@jl_diverror_exception = external constant ptr
declare void @ijl_throw(ptr)
define i64 @f3vf2(i64 signext %n) {
top:
  %c0 = icmp ne i64 4, 0
  %c1 = or i1 true, %c0
  %divisor_valid = and i1 true, %c1
  %exc = load ptr, ptr @jl_diverror_exception, align 8
  br i1 %divisor_valid, label %pass, label %fail
fail:
  call void @ijl_throw(ptr %exc)
  unreachable
pass:
  %q = sdiv i64 %n, 4
  ret i64 %q
}
"""

@testset "Bennett-3vf2 — dead-use-dropped body runs and reverses on the VM" begin
    pir, prog = mktempdir() do dir
        path = joinpath(dir, "f3vf2.ll")
        write(path, _IR3VF2)
        p = _BN3.extract_parsed_ir_from_ll(path; entry_function="f3vf2",
                                           ptr_cells=true)
        return (p, _BV3.lower_vm(p))
    end

    # (1) the ParsedIR BVM receives really is the DROPPED one.
    @testset "(1) upstream drop is visible in the ingested ParsedIR" begin
        @test [b.label for b in pir.blocks] == [:top, :fail, :pass]
        insts = [i for b in pir.blocks for i in b.instructions]
        @test !any(i -> i isa _BN3.IRLoad, insts)
        @test isempty(pir.globals)
        # no dangling alias for the dropped load
        names = Symbol[]
        for i in insts, fld in fieldnames(typeof(i))
            v = getfield(i, fld)
            v isa _BN3.SSAOperand && push!(names, v.name)
        end
        @test !(:exc in names)
        # the dead arm is the utzc sink shape
        @test isempty(pir.blocks[2].instructions)
        @test pir.blocks[2].terminator ==
              _BN3.IRBranch(nothing, :__unreachable__, nothing)
    end

    # (2)+(3) forward to :halted (never the sink) and reverse exactly, under
    #         both history regimes.
    @testset "(2)+(3) run! → :halted with the oracle; unrun! exact" begin
        regimes = (("L2 (compute_must_cache)", _BV3.compute_must_cache(prog)),
                   ("L3 (empty must_cache)",   Set{Tuple{Symbol,Int}}()))
        for (rlabel, mcs) in regimes, n in Int64[0, 1, 4, 7, 100, -9, -12]
            s = _BV3.initial_state(prog, Dict(:n => n))
            init = deepcopy(s.current)
            _BV3.run!(s, prog; max_steps=10_000, checkpoint_interval=8,
                      must_cache_set=mcs)
            # the structurally-true guard ALWAYS takes the live arm: a normal
            # :halted exit, never the sink's :error ($rlabel, n = $n).
            @test _BV3.is_halted(s)
            @test s.current.status === :halted
            res = _BV3.result(s)
            @test res[:q] == div(n, 4)      # LLVM sdiv == Julia div (toward 0)
            @test res[:n] == n              # input preserved
            _BV3.unrun!(s, prog; max_unsteps=10_000)
            @test s.current == init
            @test isempty(s.history)
            @test s.step_count == 0
        end
    end
end

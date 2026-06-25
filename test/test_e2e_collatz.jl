# test_e2e_collatz.jl — M13.4 / bennettvm-vw8 — the user-approved capstone.
#
# The end-to-end public-API one-liner:
#
#     Bennett.reversible_compile(f, Int64; target = :reversible_vm)
#
# routes — via the load-time registration hook BennettVM installs at
# `__init__` (`Bennett._REVERSIBLE_VM_BACKEND[] = lower_vm`, ADR 0003 /
# bennettvm-a5j) — to `lower_vm`, producing a `VMProgram` that the
# interpreter runs forward to the irreversible oracle AND reverses
# (`unrun!`) to the exact initial state (P0.6).
#
# This is SC9 Case D (unbounded while loop, statically-unknown length) driven
# entirely through the public Bennett.jl surface (NOT the internal
# `collatz_vm() = lower_vm(collatz_parsed())` factory the other collatz tests
# use). It is the integration proof: dispatch arm + lower_vm + run!/unrun! all
# wired, for a real plain-Int64 program, with zero hand-built ParsedIR.
#
# Oracle: the capped Collatz step-count (cap at 20 steps), the documented
# golden master in test/reference/collatz.jl — widened to Int64. The cap keeps
# the run bounded and the oracle unambiguous; e.g. x=27 reaches the cap → 20
# (the uncapped Collatz-of-27 is far longer). The forward result is anchored
# bit-for-bit against the native Julia function (Rule 4), so a miscompile
# cannot hide behind a self-consistent round-trip.

using Test
using BennettVM
import Bennett

const _BVF_E2E = BennettVM

# The irreversible Int64 oracle — structurally identical to
# test/reference/collatz.jl::collatz_steps, widened to Int64 so the public
# one-liner specialises on an Int64 argument.
function _collatz_steps_i64(x::Int64)
    steps = Int64(0)
    val = x
    while val > Int64(1) && steps < Int64(20)
        if val % Int64(2) == Int64(0)
            val = val >> Int64(1)
        else
            val = Int64(3) * val + Int64(1)
        end
        steps += Int64(1)
    end
    return steps
end

@testset "M13.4 / vw8 — reversible_compile(collatz, Int64; target=:reversible_vm) e2e" begin
    # `using BennettVM` above has run __init__, registering lower_vm with
    # Bennett, so the dispatch arm reaches the VM backend rather than failing
    # loud.
    vm = Bennett.reversible_compile(_collatz_steps_i64, Int64;
                                    target = :reversible_vm)
    @test vm isa VMProgram

    # Derive the entry-arg and return SSA names from the Begin/End markers of
    # the lowered program rather than hard-coding the extractor's
    # `x::Int64` / `value_phi1.lcssa` (robust to extraction renames — the same
    # pattern test_fp_roundtrip.jl uses for the FP capstone).
    begin_inst = nothing
    end_inst = nothing
    for b in vm.blocks
        b.entry isa _BVF_E2E.BeginInstruction && (begin_inst = b.entry)
        b.exit isa _BVF_E2E.EndInstruction && (end_inst = b.exit)
    end
    @test begin_inst !== nothing && length(begin_inst.params) == 1
    @test end_inst !== nothing && length(end_inst.returns) == 1
    arg_key = begin_inst.params[1]
    ret_key = end_inst.returns[1]

    # Oracle-anchored forward result + full P0.6 reverse invariant, over a
    # spread of inputs (even/odd, short/long, cap-hitting).
    @testset "forward == oracle + round-trip (P0.6)" begin
        for x in Int64[1, 2, 3, 6, 7, 9, 12, 15, 27]
            oracle = _collatz_steps_i64(x)

            rs = initial_state(vm, Dict(arg_key => x))
            initial_snap = deepcopy(rs.initial)
            run!(rs, vm; max_steps = 10_000, checkpoint_interval = 8)

            @test is_halted(rs)
            @test result(rs)[ret_key] == oracle          # Rule 4 oracle anchor

            unrun!(rs, vm)
            @test rs.current == rs.initial                # P0.6 — reversed to start
            @test isempty(rs.history)                     # P0.6 — history drained
            @test rs.step_count == 0                      # P0.6 — counter reset
            @test rs.initial == initial_snap              # initial never mutated
        end
    end

    # Headline: x=27 hits the 20-step cap (the documented golden-master value).
    @testset "headline x=27 → 20 (capped)" begin
        rs = initial_state(vm, Dict(arg_key => Int64(27)))
        run!(rs, vm; max_steps = 10_000, checkpoint_interval = 8)
        @test result(rs)[ret_key] == 20
        @test result(rs)[ret_key] == _collatz_steps_i64(Int64(27))
    end
end

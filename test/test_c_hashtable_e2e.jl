# test/test_c_hashtable_e2e.jl — THE STORY DEMO (CW-C3; bead `bennettvm-416r.10`).
#
# # What this file is
#
# The first full end-to-end proof of BennettVM's language-agnostic claim: a
# normal C program with a hash map — `test/reference/c/hashtable.c`, an
# open-addressing (linear-probing) int64→int64 table with tombstone deletes —
# compiled by clang 18.1.3 to ONE self-contained LLVM module, ingested by
# Bennett.jl's `extract_parsed_ir_set_from_ll` (ptr_cells=true), lowered by
# `lower_vm`, EXECUTED forward on the reversible VM, and REVERSED bit-for-bit.
# Forward agrees with the NATIVE C run (the golden master in `GOLDEN.txt`);
# `unrun!` restores the initial state exactly (history empty, frame depth 1,
# the arena / call-stack cursors retracted to 0).
#
# # Provenance of the oracle (Law 1)
#
#   * `test/reference/c/GOLDEN.txt` — the native answer, produced by compiling
#     `hashtable.c` + `main_golden.c` with clang `-O2` and again with
#     `-O0 -fsanitize=address,undefined`; ALL opt levels produce IDENTICAL
#     output (`test/reference/c/BUILD.md` §1). Each line is `<driver> <n>
#     <checksum>`. These are the stable contract (the `.ll` SHA256 is
#     toolchain-specific; the GOLDEN values are not).
#   * Controlling decisions: `docs/adr/0017-closed-world-execution.md`
#     §Sequencing CW-C (the C-validation track), `docs/adr/0019-reversible-
#     calls.md` §3–§4 (the call/return ABI — CW-C3 adapts §3's MOVE to a COPY
#     and §6c's single-assignment landing to an OVERWRITE for LLVM-derived IR;
#     see `src/interpreter/Interpreter.jl` / `src/ir/call_transitions.jl`),
#     and `docs/adr/0020-c-track-frontend-contract.md` (the front-end surface).
#   * The CW-C3 frame-disjoint stack: `src/ir/IState.jl` `stack_top` +
#     `src/ir/stack_alloca.jl` — without it a nested C `-O0` call clobbers its
#     caller's memory-backed locals (the wall this milestone cleared).
#
# # What this pins (Rule 4 — invariants, not "didn't throw")
#
#   1. FORWARD golden master: for BOTH drivers (ht_demo_basic, ht_demo_grow)
#      and EVERY tested n, the VM's returned i64 == the EXACT GOLDEN.txt value.
#      A single bit off is a failure (the splitmix64 hash + tombstone probe +
#      grow/rehash control flow must reverse-execute identically to native C).
#   2. ROUND-TRIP: after `unrun!`, `rs.current == initial`, history empty,
#      frame depth back to 1, `arena_top` and `stack_top` retracted to 0.
#   3. Per-step inverse (spike lesson 4) ON the C program at small n — the
#      aggregate round-trip alone can mask a middle-instruction inverse bug.
#
# # Mutation-proof (Rule 5 — the e2e CATCHES these; verified RED→restore→GREEN)
#
# Both target the CW-C3 frame-disjoint-stack machinery that unblocked this
# milestone, and both surface on the FORWARD golden master (gate 1) — the
# strongest signal, because a forward miscompile means the VM and native C
# disagree on the answer. (The reverse runs at K=32, so L3 checkpoint-replay
# recovers state regardless of any single L2-inverse bug — an L2-inverse
# mutation is therefore NOT a reliable e2e signal at this K; the L2 inverses
# are mutation-proved separately in `test_call_roundtrip.jl` /
# `test_arena_roundtrip.jl` at K=typemax, where the L2 path is the sole
# reversal.)
#
#   M1. Drop `+ s.stack_top` from `StackAlloca.forward`
#       (`src/ir/stack_alloca.jl`) — i.e. make every static alloca land at its
#       absolute compile-time cell. Gate 1 goes RED on basic n≥1: a nested
#       `ht_get` / `ht_third_pass` clobbers `ht_demo_basic`'s table pointer, so
#       `ht_free(t)` fails loud on a garbage address (the EXACT pre-CW-C3 wall).
#       Verified 2026-06-10: perturbed → RED → restored → GREEN.
#   M2. Drop the caller-frame `stack_top` advance in `_handle_call_dispatch!`
#       (`s.current.stack_top += stack_delta`, `src/interpreter/Interpreter.jl`).
#       Gate 1 goes RED on basic n≥1: every callee's allocas alias the caller's
#       stack region, so the checksum comes out wrong (basic n=1 returned
#       -2098182294528 vs golden 23131069394). Verified 2026-06-10: perturbed →
#       RED → restored → GREEN.
#
# # checkpoint_interval choice
#
# K = 32 (`_K` below). The reverse is L3 checkpoint-replay (`unstep!` restores
# the nearest CheckpointEntry and replays forward), so reverse cost trades off
# against checkpoint memory: smaller K ⇒ more checkpoints, faster replay. A
# sweep on basic n=64 (438k-step n=1000 down to 70k-step n=64) found K∈[20,50]
# minimises wall time (K=32 ≈ 4.5s total for n=64); K=1000 was ~40s. 32 is the
# sweet spot — small enough that replay is cheap, large enough that checkpoint
# memory stays modest. (The L2 `must_cache_set` additionally records the heap-
# intrinsic / ReturnExit deltas so those reverse via O(1) L2 inverse, not
# replay.)

using Test
using BennettVM
import Bennett
const _BV = BennettVM
const _B = Bennett

include(joinpath(@__DIR__, "test_per_step_inverse.jl"))

const _LL = joinpath(@__DIR__, "reference", "c", "hashtable.O0.ll")
const _K = 32   # checkpoint_interval — see the header's "checkpoint_interval choice".

# GOLDEN.txt, parsed to (driver, n) => checksum. Re-read from the file so the
# test and the oracle never drift (the file is the contract).
function _load_golden()
    g = Dict{Tuple{String,Int},Int}()
    for line in eachline(joinpath(@__DIR__, "reference", "c", "GOLDEN.txt"))
        isempty(strip(line)) && continue
        drv, n, v = split(line)
        g[(String(drv), parse(Int, n))] = parse(Int, v)
    end
    return g
end

# The entry function's single i64 return SSA name (the EndInstruction.returns
# of the entry block). `result(rs)` is keyed by SSA name, so we read this slot.
function _return_symbol(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BV.EndInstruction && b.exit.label === entry &&
           !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

# Ingest ONCE (the extraction is the slow part); lower per driver.
const _SET = _B.extract_parsed_ir_set_from_ll(_LL; ptr_cells = true)

const _DRIVERS = (("basic", :ht_demo_basic), ("grow", :ht_demo_grow))

# n=1000 is GOLDEN-pinned and projects well under the ~120s/driver budget
# (basic ≈ 40s, grow ≈ 60s round-trip at K=32, measured 2026-06-10), so it is
# included. The small set drives the forward + round-trip + per-step gates; the
# large n drives the full ht_put/ht_get/ht_del branch cover (BUILD.md §"Branch
# liveness at n=1000").
const _SMALL_N = (0, 1, 7, 64)
const _LARGE_N = 1000

@testset "CW-C3 — C hash-table e2e (golden master vs native C)" begin
    golden = _load_golden()
    @test length(_SET) == 12   # the 12 in-module functions (BUILD.md §Defined functions)

    for (drv, entry) in _DRIVERS
        prog = _BV.lower_vm(_SET; entry = entry)
        mc = _BV.compute_must_cache(prog)
        ret = _return_symbol(prog, entry)

        @testset "$drv — forward golden master + round-trip" begin
            for n in (_SMALL_N..., _LARGE_N)
                rs = _BV.initial_state(prog, Dict(:n => Int64(n)))
                init = deepcopy(rs.current)
                _BV.run!(rs, prog; max_steps = 2_000_000_000,
                         checkpoint_interval = _K, must_cache_set = mc)
                # (1) FORWARD golden master — exact bit-for-bit vs native C.
                @test _BV.is_halted(rs)
                @test _BV.result(rs)[ret] == golden[(drv, n)]
                # (2) ROUND-TRIP — restore initial exactly.
                _BV.unrun!(rs, prog; max_unsteps = 2_000_000_000)
                @test isempty(rs.history)
                @test length(rs.current.frames) == 1
                @test rs.current.arena_top == 0
                @test rs.current.stack_top == 0
                @test rs.current == init
            end
        end

        # (3) Per-step inverse at small n (spike lesson 4): catches a middle-
        # instruction inverse bug the aggregate round-trip can mask. Run only at
        # the smallest non-trivial n that exercises the call/return + heap path
        # (n=1: one insert, the third-pass del-miss, one lookup) to keep the
        # per-step deepcopy sweep affordable.
        @testset "$drv — per-step inverse (n=1)" begin
            @test per_step_inverse_check(prog, Dict(:n => Int64(1));
                checkpoint_interval = _K, must_cache_set = mc,
                label = "CW-C3/$drv/n=1") === nothing
        end
    end
end

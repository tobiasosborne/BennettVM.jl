# test/test_tghl_forward_oracle.jl — `bennettvm-tghl`: the forward-semantics
# oracle the random-program property gate was missing.
#
# # The defect this file exists for (Astra VM-ingest F16)
#
# The M8 property gate walked 100 seeded random programs through
# run/unrun round-trips and per-step inverse checks. Not one of those
# checks asks whether the RUN was correct. A VM whose forward step
# computes a deterministic wrong answer passes all of them, because the
# wrong answer reverses just as faithfully as a right one. The review
# proved it by execution against the real `_full_roundtrip!`: a program
# with oracle 11 and VM result 2 was ACCEPTED
# (`reviews/2026-09-26-astra/VM-ingest.verification.md` §F16:
# `known wrong result=2 oracle=11`, `property helper accepted=true`).
# CLAUDE.md Rule 4 forbids that shape of test — "runs without errors" is
# not a passing test, and neither is "reverses what it computed".
#
# # What this file pins, in four layers
#
#   1. **The oracle's own arithmetic** — `sem_binop`'s whole op table is
#      checked against NATIVE Julia `Int8` on all 65 536 (a, b) pairs
#      per op. The gate's oracle is only as good as its binop table, and
#      at the width the M8 generator runs (64) the sign/zero-extension
#      discipline is invisible — this is the only place the model's
#      narrow-width arms are exercised, so it is where they are proved.
#      The three LLVM-poison inputs native Julia cannot express
#      (division by zero; i8-typemin ÷ -1) are excluded by an exact,
#      counted exclusion, not waved away.
#
#   2. **The evaluator's own semantics** — zero-init cell reads, the
#      cell/register exchange, the cell/cell exchange, modop, and the
#      predicate arm choice, each against a HAND-COMPUTED expected
#      value. A model that is internally consistent but wrong is not an
#      oracle.
#
#   3. **The gate's agreement leg** — the same 100 seeded programs the
#      M8.5 capstone walks, each run forward and compared to the model
#      (registers AND memory) BEFORE it is reversed, then reversed. The
#      capstone in `test/test_property_roundtrip.jl` composes this leg
#      with the L3/L2 per-step scaffold; this file pins the leg itself
#      and the oracle's independence.
#
#   4. **The mutation proof (Rule 5, port-and-verify)** — two
#      reproductions of F16, both in-process and deterministic:
#        (a) a hand-built two-block program whose description says
#            `y := x ⊕xor (1 xor 2)` while the VM instruction says
#            `:or`. Oracle 2, VM 3. The pre-tghl check (round-trip
#            only) accepts it; the gate rejects it with the register
#            named.
#        (b) the same check over the seeded sweep, with ONE binop opcode
#            flipped in place in each generated program: the
#            round-trip-only check must stay GREEN on every one of them
#            (that IS the F16 blindness, on control-flow-rich programs),
#            and the gate must go RED on the very first one with the
#            expected-vs-actual pair named.
#
# # Why the mutation flips an OPCODE instead of shadowing `_apply_binop`
#
# The M8.3/M8.5 in-process discipline (`eval` a same-signature method,
# then delete the methods that were not in a pre-`eval` snapshot) does
# not work for `_apply_binop`. Julia's `methods(f, sig)` returns ONE
# entry after a same-signature re-`eval`, and it is not the entry the
# snapshot holds: the redefinition REPLACES the method table slot, so
# the "restore" would `delete_method` the mutant and leave the VM with
# no `_apply_binop` at all. (Verified empirically before choosing this
# shape — see the report.) The instruction-level flip gives the same
# defect class — a VM that computes a wrong forward value and reverses
# it faithfully — with a restoration that is exact by construction (the
# program is discarded, never repaired) and with a hand-computable
# oracle. The src/-level version of the same mutation (edit
# `_apply_binop`'s `:xor` arm, run the gate, restore) was executed by
# hand for the RED/GREEN evidence and is quoted in the report.
#
# # `verify_reversibility`
#
# This repo has no `verify_reversibility` (grep: it is not in `src/` or
# `test/`; the Bennett.jl circuit backend's helper has no BennettVM
# counterpart). The reversal oracle here is `unrun!` + the M8.2
# `per_step_inverse_check` scaffold, and the gate calls both — in the
# mutation testsets below (round-trip only) and, in the capstone, at
# both the L3 and L2 history regimes.
#
# # Ref
#
#   * `reviews/2026-09-26-astra/VM-ingest.md` F16;
#     `VM-ingest.verification.md` §F16.
#   * `bennettvm-tghl` — this bead.
#   * `test/generators/semantic_model.jl` — `sem_binop`, `sem_modop`,
#     `sem_eval`, `sem_check`, `SemDesc` (the code under test here).
#   * `test/generators/random_program.jl` — `default_rng`,
#     `random_program` (the seeded programs, now with descriptions).
#   * `test/test_property_roundtrip.jl` — the capstone gate that
#     consumes this oracle.
#   * `test/test_per_step_inverse.jl` (M8.2) — `per_step_inverse_check`,
#     the per-step reversal scaffold.
#   * `test/test_mutation_proof.jl` (M8.3) / `test_property_roundtrip.jl`
#     §3 (M8.5) — the eval+delete_method+invokelatest mutation
#     discipline, and the reason the opcode flip was used instead
#     (above).
#   * `docs/adr/0012-collatz-lowering.md` §D2 / R1 — the i`w` semantics
#     the model implements and this file checks against native Julia.
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (assert against a
#     known-correct value), Rule 5 (mutation-prove), Rule 10 (≤200 LOC
#     excluding docstrings), Rule 11 (literate docstring).

using Test
using Random
using BennettVM

# The generator (which ships the descriptions) and the model itself.
# Include-guarded, per the project's per-file autonomy idiom. The M8.2
# scaffold comes first: the generator's own "scaffold compatibility"
# testset drives programs through `per_step_inverse_check`, so the
# generator cannot be loaded without it.
isdefined(@__MODULE__, :per_step_inverse_check) ||
    include(joinpath(@__DIR__, "test_per_step_inverse.jl"))
isdefined(@__MODULE__, :random_program) ||
    include(joinpath(@__DIR__, "generators", "random_program.jl"))
isdefined(@__MODULE__, :sem_eval) ||
    include(joinpath(@__DIR__, "generators", "semantic_model.jl"))

# The seeded sweep, mirrored from the M8.5 capstone so this file pins
# the SAME programs the capstone gates.
const _TGHL_N_PROGRAMS = 100
const _TGHL_SIZE_HINT  = 6

# ---------------------------------------------------------------------
# 1. The oracle's own arithmetic vs native Julia `Int8`, exhaustively
# ---------------------------------------------------------------------

# Every op `sem_binop` claims to implement, with the op family it
# belongs to. The sets are compared against the VM's own declared op
# domains below, so an op added to the VM (or to the model) without an
# exhaustive native-Julia reference here goes RED instead of sailing
# through the sweep untested.
const _TGHL_ARITH_OPS =
    (:add, :sub, :mul, :and, :or, :xor, :shl, :lshr, :ashr,
     :udiv, :sdiv, :urem, :srem)
const _TGHL_CMP_OPS = (:eq, :ne, :ult, :ule, :ugt, :uge, :slt, :sle,
                       :sgt, :sge)

"""
    _native_i8(op::Symbol, a::Int64, b::Int64) -> Union{Nothing,Int64}

Native-Julia `Int8` reference for one model op on the low 8 bits of
`a` and `b`, in the model's own representation: an arithmetic result is
returned as its low-8-bit UNSIGNED pattern (`Int64(reinterpret(UInt8,
·))`), a predicate as `0` / `1`.

`nothing` means "native Julia cannot express this input":
  * any division or remainder by zero — Julia raises `DivideError`,
  * `sdiv` of i8-typemin by -1 — Julia raises `DivideError` and LLVM
    calls the input poison.
Both are counted and pinned below, so the exclusion stays visible.
"""
function _native_i8(op::Symbol, a::Int64, b::Int64)
    # `reinterpret` (not `Int8(·)`): Julia's integer conversion is
    # CHECKED — `Int8(128)` raises — while an i8 bit pattern is a
    # reinterpretation, which is exactly what is modelled here.
    #
    # Shift amounts are taken UNSIGNED (`ub8`), because that is how an
    # LLVM `shl`/`lshr`/`ashr` reads its i8 shift operand (LLVM
    # zero-extends it; a negative i8 count is poison, not a right
    # shift). Julia's `Int8 << Int8(-1)` would right-shift instead, so
    # feeding it the raw `b8` would test Julia's convention rather than
    # the modelled one.
    a8, b8 = reinterpret(Int8, UInt8(a)), reinterpret(Int8, UInt8(b))
    ua8, ub8 = UInt8(a), UInt8(b)
    v = if op === :add
        a8 + b8
    elseif op === :sub
        a8 - b8
    elseif op === :mul
        a8 * b8
    elseif op === :and
        a8 & b8
    elseif op === :or
        a8 | b8
    elseif op === :xor
        a8 ⊻ b8
    elseif op === :shl
        # UNSIGNED shift amount (see the note above the `reinterpret`).
        a8 << ub8
    elseif op === :lshr
        ua8 >> ub8
    elseif op === :udiv
        b8 == 0 ? nothing : ua8 ÷ ub8
    elseif op === :urem
        b8 == 0 ? nothing : ua8 % ub8
    elseif op === :sdiv
        # i8-typemin ÷ -1: Julia raises, LLVM calls it poison.
        (b8 == 0 || (a8 == typemin(Int8) && b8 == Int8(-1))) ?
            nothing : a8 ÷ b8
    elseif op === :srem
        b8 == 0 ? nothing : a8 % b8
    elseif op === :ashr
        a8 >> ub8
    elseif op === :eq
        a8 == b8
    elseif op === :ne
        a8 != b8
    elseif op === :ult
        ua8 < ub8
    elseif op === :ule
        ua8 <= ub8
    elseif op === :ugt
        ua8 > ub8
    elseif op === :uge
        ua8 >= ub8
    elseif op === :slt
        a8 < b8
    elseif op === :sle
        a8 <= b8
    elseif op === :sgt
        a8 > b8
    elseif op === :sge
        a8 >= b8
    else
        error("_native_i8: no native reference for :", op)
    end
    v === nothing && return nothing
    return v isa Bool ? Int64(v) : Int64(reinterpret(UInt8, v))
end

@testset "tghl — model op table == native Julia Int8 (all 65 536 pairs/op)" begin
    # The signed/unsigned split is the whole content of the model, and
    # at width 64 it is the identity — so this is where it is proved.
    for op in (_TGHL_ARITH_OPS..., _TGHL_CMP_OPS...)
        mismatches = String[]        # the first few, named — not a count alone
        n_bad     = 0
        checked   = 0
        skipped   = 0
        for a in Int64(0):255, b in Int64(0):255
            want = _native_i8(op, a, b)
            want === nothing && (skipped += 1; continue)
            checked += 1
            got = sem_binop(op, a, b, 8)
            got == want && continue
            n_bad += 1
            length(mismatches) < 3 &&
                push!(mismatches, "($a,$b): model=$got native=$want")
        end
        @test n_bad == 0
        @test isempty(mismatches)
        @test checked == 65_536 - skipped
        # Pin the exclusions: a sweep that silently stopped testing a
        # case would still be "green" with the above.
        expected_skips = op in (:udiv, :urem, :srem) ? 256 :
                         op === :sdiv ? 257 : 0
        @test skipped == expected_skips
    end
    # Every op the VM can evaluate, and the model can, must be swept
    # above — and the model must not carry an op the VM lacks (a
    # description using it would be describing something the VM cannot
    # express). Compared against the VM's own declared op domains
    # (`src/ir/operators.jl`, which the ADR 0012 R1 test pins against
    # upstream), so this is a domain check, not a hand-counted total.
    @test Set(_TGHL_ARITH_OPS) == Set(BennettVM.BINARY_OPERATORS)
    @test Set(_TGHL_CMP_OPS) == Set(BennettVM.COMPARISON_OPERATORS)
end

# ---------------------------------------------------------------------
# 2. The evaluator's own semantics, against hand-computed values
# ---------------------------------------------------------------------

@testset "tghl — sem_eval semantics (hand-computed, no VM in the loop)" begin
    # `y := x ⊕xor (1 xor 2)`: e = 1 ⊻ 2 = 3, so y = x ⊻ 3. With
    # modop :sub and e = 2 * 3 = 6 the next step is y' = y - 6.
    d1 = SemDesc(:linear, nothing,
                 [[SemArith(:y1, :x, :xor, 1, :xor, 2),
                   SemArith(:y2, :y1, :sub, 2, :mul, 3)]],
                 :y2, 64)
    o1 = sem_eval(d1, Dict(:x => Int64(5)))
    @test o1.registers[:y1] == 6          # 5 ⊻ 3
    @test o1.registers[:y2] == 0          # 6 - (2 * 3)
    @test isempty(o1.memory)

    # Zero-init memory: an unwritten cell reads as 0, so the first
    # `M[10] ⊕add (3 + 5)` writes exactly 8 — not 8 + garbage. The
    # second step folds in `1 or 1 = 1` by XOR: 8 ⊻ 1 = 9.
    d2 = SemDesc(:linear, nothing,
                 [[SemMemAssign(10, :add, 3, :add, 5),
                   SemMemAssign(10, :xor, 1, :or, 1)]],
                 :y, 64)
    o2 = sem_eval(d2, Dict(:x => Int64(0)))
    @test o2.memory[10] == 9
    @test get(o2.memory, 11, Int64(0)) == 0   # untouched cells read 0

    # `nxt := M[20] := src` with M[20] untouched: the register receives
    # the OLD cell (0) and the cell receives the register.
    d3 = SemDesc(:linear, nothing,
                 [[SemMemExchg(:n1, 20, :x)]], :n1, 64)
    o3 = sem_eval(d3, Dict(:x => Int64(7)))
    @test o3.registers[:n1] == 0
    @test o3.memory[20] == 7
    # Exchanging twice — the second reading the register the first
    # produced — restores the (register, cell) pair: x = 7 goes back
    # into M[20] under a fresh name and the cell is 0 again.
    d3b = SemDesc(:linear, nothing,
                  [[SemMemExchg(:n1, 20, :x), SemMemExchg(:n2, 20, :n1)]],
                  :n2, 64)
    o3c = sem_eval(d3b, Dict(:x => Int64(7)))
    @test o3c.registers[:n2] == 7
    @test o3c.memory[20] == 0

    # `M[30] <-> M[40]`: both cells are read before either is written.
    d4 = SemDesc(:linear, nothing,
                 [[SemMemAssign(30, :add, 1, :xor, 0),    # M[30] = 1
                   SemMemAssign(40, :add, 2, :xor, 0),    # M[40] = 2
                   SemMemSwap(30, 40)]],
                 :y, 64)
    o4 = sem_eval(d4, Dict(:x => Int64(0)))
    @test o4.memory[30] == 2
    @test o4.memory[40] == 1

    # Arm selection: nonzero predicate takes arm 1, zero takes arm 2 —
    # the "nonzero = true" convention the interpreter's `ConditionalExit`
    # uses, and the one the description must mirror.
    arms = [SemOp[SemArith(:y, :x, :add, 0, :add, 1)],
            SemOp[SemArith(:y, :x, :add, 0, :add, 2)]]
    d5 = SemDesc(:conditional, :c, arms, :y, 64)
    @test sem_eval(d5, Dict(:x => Int64(10), :c => Int64(1))).registers[:y] == 11
    @test sem_eval(d5, Dict(:x => Int64(10), :c => Int64(0))).registers[:y] == 12
    @test sem_eval(d5, Dict(:x => Int64(10), :c => Int64(7))).arm_taken
    @test !sem_eval(d5, Dict(:x => Int64(10), :c => Int64(0))).arm_taken
end

@testset "tghl — sem_check reports the mismatch (diagnostic contract)" begin
    # `sem_check` is what makes the oracle load-bearing in the gate, so
    # its failure surface is a contract like the M8.2 scaffold's: it must
    # name the bead, the observable, and the expected-vs-actual pair.
    # y := x ⊕add (1 + 2) = 0 + 3 = 3, by hand.
    outcome = sem_eval(SemDesc(:linear, nothing,
                               [[SemArith(:y, :x, :add, 1, :add, 2)]],
                               :y, 64),
                       Dict(:x => Int64(0)))
    @test outcome.registers[:y] == 3
    err = try
        sem_check(outcome, [:y], Dict(:y => Int64(99)), Dict{Int64,Int64}();
                  label="DIAG")
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("bennettvm-tghl", err.msg)
    @test occursin("DIAG", err.msg)
    @test occursin("expected 3, got 99", err.msg)
    # Zero-init representation: an absent cell and a 0-valued cell are
    # the same observable, and must not be reported as a mismatch. The
    # description writes M[10] = 0 ⊕add (0 + 0) = 0 and leaves y = x ⊻ 0
    # = 0 behind, so both memory spellings of "0" are exercised.
    mem_only_in_vm = sem_eval(SemDesc(:linear, nothing,
                                       [[SemMemAssign(10, :add, 0, :add, 0),
                                         SemArith(:y, :x, :xor, 0, :xor, 0)]],
                                       :y, 64), Dict(:x => Int64(0)))
    @test mem_only_in_vm.memory[10] == 0
    @test mem_only_in_vm.registers[:y] == 0
    @test sem_check(mem_only_in_vm, [:y], Dict(:y => Int64(0)),
                    Dict(10 => Int64(0)); label="ZERO-INIT") === nothing
    @test sem_check(mem_only_in_vm, [:y], Dict(:y => Int64(0)),
                    Dict{Int64,Int64}(); label="ABSENT") === nothing
    # A cell the VM touched and the model did NOT is a mismatch.
    err2 = try
        sem_check(mem_only_in_vm, [:y], Dict(:y => Int64(0)),
                  Dict(99 => Int64(5)); label="EXTRA")
        nothing
    catch e
        e
    end
    @test err2 isa ErrorException
    @test occursin("memory[99]: expected 0, got 5", err2.msg)
end

# ---------------------------------------------------------------------
# 3. + 4. The gate drivers (round-trip only, and round-trip + oracle)
# ---------------------------------------------------------------------

# The observable set: the `returns` of the program's unique
# `EndInstruction` block. Same read as
# `test/test_property_roundtrip.jl::_declared_returns` (kept local so
# this file runs without the capstone's test sets).
_tghl_returns(vm::VMProgram) =
    only(filter(bb -> bb.exit isa BennettVM.EndInstruction, vm.blocks)).exit.returns

"""
    _tghl_roundtrip_only!(vm, inputs, label) -> Nothing

The pre-`bennettvm-tghl` gate, verbatim in contract: run to halt,
`unrun!`, assert the state is restored and the history is empty. It
never looks at the RESULT. A forward-semantics bug that passes this is
invisible to the old gate — which is the claim the mutation testsets
below demonstrate rather than assert.
"""
function _tghl_roundtrip_only!(vm::VMProgram, inputs::Dict{Symbol,Int64},
                              label::AbstractString)
    rs = initial_state(vm, inputs)
    captured = deepcopy(rs.current)
    Base.invokelatest(run!, rs, vm; max_steps=10_000)
    is_halted(rs) || error("[$label] did not halt")
    Base.invokelatest(unrun!, rs, vm)
    rs.current == captured ||
        error("[$label] post-unrun! state differs from the initial one")
    isempty(rs.history) || error("[$label] post-unrun! history non-empty")
    return nothing
end

"""
    _tghl_gate!(vm, inputs, desc, label) -> Nothing

The gate leg: run to halt, compare the forward result (declared returns
+ observable memory) against `sem_eval(desc, inputs)`, and only then
reverse and assert restoration. The oracle comparison happens while the
result is on screen; the un-run below never re-examines it.
"""
function _tghl_gate!(vm::VMProgram, inputs::Dict{Symbol,Int64},
                     desc::SemDesc, label::AbstractString)
    rs = initial_state(vm, inputs)
    captured = deepcopy(rs.current)
    Base.invokelatest(run!, rs, vm; max_steps=10_000)
    is_halted(rs) || error("[$label] did not halt")
    sem_check(sem_eval(desc, inputs), _tghl_returns(vm), result(rs),
              rs.current.memory; label="$label forward oracle")
    Base.invokelatest(unrun!, rs, vm)
    rs.current == captured ||
        error("[$label] post-unrun! state differs from the initial one")
    isempty(rs.history) || error("[$label] post-unrun! history non-empty")
    return nothing
end

@testset "tghl — 100 seeded programs: forward == model, then reversed" begin
    # The same walk the M8.5 capstone runs, minus the L3/L2 per-step
    # scaffold (that is the capstone's job; this file pins the forward
    # leg). Seeded, so the 100 programs are the capstone's 100 programs.
    rng = default_rng()
    n_desc = 0
    for i in 1:_TGHL_N_PROGRAMS
        (vm, inputs, desc) = random_program(rng; size_hint=_TGHL_SIZE_HINT)
        @test _tghl_gate!(vm, inputs, desc, "tghl/program-$i") === nothing
        n_desc += 1
    end
    @test n_desc == _TGHL_N_PROGRAMS
end

@testset "tghl — MUTATION (a): hand-built wrong-forward program" begin
    # The F16 evidence, in miniature and hand-computed. One block:
    # Begin → `y := x ⊕xor (3 xor 1)` → End. The DESCRIPTION says `:xor`
    # (so the oracle is `1 ⊻ 2 = 3`); the VM INSTRUCTION carries the
    # wrong opcode `:or` (so the VM computes `1 ⊻ 3 = 2`) — the "meaning
    # and implementation drifted apart" shape a lowering or a
    # constants-drift regression produces. With x = 1: oracle 3, VM 2,
    # the same wrong-result-vs-oracle shape the review reported as
    # "result=2, oracle=11".
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:x]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:y, :x, :xor, 3, :or, 1)],
        BennettVM.EndInstruction(:m, [:y]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
    inputs = Dict(:x => Int64(1))
    desc = SemDesc(:linear, nothing,
                   [[SemArith(:y, :x, :xor, 3, :xor, 1)]], :y, 64)

    # The oracle is the hand-computed 1 ⊻ (3 ⊻ 1) = 3 …
    @test sem_eval(desc, inputs).registers[:y] == 3
    # … and the VM really does produce something else.
    rs = initial_state(vm, inputs)
    Base.invokelatest(run!, rs, vm; max_steps=10_000)
    @test result(rs)[:y] == 2
    Base.invokelatest(unrun!, rs, vm)

    # (i) The pre-tghl check ACCEPTS the wrong result: round-trip exact,
    #     history empty. This is F16, reproduced.
    @test _tghl_roundtrip_only!(vm, inputs, "tghl/MUT-A/roundtrip-only") === nothing
    # (ii) The gate REJECTS it, naming the register and both values.
    err = try
        _tghl_gate!(vm, inputs, desc, "tghl/MUT-A")
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("forward result disagrees", err.msg)
    @test occursin("register :y: expected 3, got 2", err.msg)
    # (iii) Restoring the opcode restores GREEN (Rule 1: the fix is
    #       load-bearing, the mutation is not sticky).
    bb.instructions[1] = BennettVM.ArithmeticAssignment(:y, :x, :xor, 3, :xor, 1)
    @test _tghl_gate!(vm, inputs, desc, "tghl/MUT-A/restored") === nothing
end

"""
    _tghl_flip_one_binop!(vm::VMProgram) -> Union{Nothing,String}

Flip ONE binary opcode in a freshly generated program, in place, to
the first of `(:or, :and, :xor)` that CHANGES the value of the
operation on that instruction's operands. The candidate is chosen with
the model's own `sem_binop`, so a flip that would be a no-op (e.g.
`:xor` → `:or` on `1` and `2`, where `1 | 2 == 1 ⊻ 2`) is skipped
rather than silently producing a GREEN-but-vacuous mutant. Returns a
human-readable description of what was flipped, or `nothing` when the
program has no arithmetic instruction to flip.

The flip is safe for a mutation proof precisely because the VM's
`inverse` recomputes the SAME `e` from the SAME (mutated) instruction:
the program keeps reversing exactly while computing the wrong value —
the F16 failure mode, on real control-flow programs. Restoration is by
discarding the program, so there is nothing to repair.
"""
function _tghl_flip_one_binop!(vm::VMProgram)
    for bb in vm.blocks, (i, instr) in enumerate(bb.instructions)
        instr isa BennettVM.ArithmeticAssignment || continue
        (instr.lhs isa Int64 && instr.rhs isa Int64) || continue
        was = sem_binop(instr.op, instr.lhs, instr.rhs, 64)
        for cand in (:or, :and, :xor)
            cand === instr.op && continue
            sem_binop(cand, instr.lhs, instr.rhs, 64) == was && continue
            bb.instructions[i] = BennettVM.ArithmeticAssignment(
                instr.target, instr.source, instr.modop, instr.lhs, cand,
                instr.rhs)
            return "block :$(bb.label) instr $i — :$(instr.op) → :$cand"
        end
    end
    return nothing
end

@testset "tghl — MUTATION (b): one flipped opcode per seeded program" begin
    # Walk the seeded sweep, flip one binop in each program that admits
    # one, and assert BOTH halves of the F16 claim over the WHOLE walk
    # (no early exit — the point of (a) is that it holds for every
    # mutant, not just the first):
    #   * the pre-tghl check (round-trip only) stays GREEN on every one
    #     of them — the old gate cannot see this class of bug;
    #   * the gate goes RED with an expected-vs-actual pair — the new
    #     one can.
    rng = default_rng()
    n_flipped  = 0
    n_rt_green = 0
    red_msg     = ""
    red_ordinal = 0        # which MUTANT (1st, 2nd, …) the gate rejected
    for i in 1:_TGHL_N_PROGRAMS
        (vm, inputs, desc) = random_program(rng; size_hint=_TGHL_SIZE_HINT)
        _tghl_flip_one_binop!(vm) === nothing && continue
        n_flipped += 1
        _tghl_roundtrip_only!(vm, inputs, "tghl/MUT-B/program-$i")
        n_rt_green += 1
        red_ordinal > 0 && continue      # one RED is enough; keep walking
        try
            _tghl_gate!(vm, inputs, desc, "tghl/MUT-B/program-$i")
        catch e
            e isa ErrorException || rethrow()
            red_msg = e.msg
            red_ordinal = n_flipped
        end
    end
    # Every program in today's sweep admits a flip; pinned at ≥50 so a
    # palette change that made flips rarer would degrade this coverage
    # loudly instead of silently.
    @test n_flipped >= 50
    @test n_rt_green == n_flipped     # (a) reversal is untouched by the flip
    @test red_ordinal == 1            # (b) the gate caught the very first
    @test occursin("forward result disagrees", red_msg)
    @test occursin("expected", red_msg)
    @test occursin("got", red_msg)
end

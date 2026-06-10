# test/test_interpreter.jl — M3.1 `initial_state` + M3.2 `is_halted` /
# `result` unit tests (bd `bennettvm-afj`, `bennettvm-3ch`).
#
# # What this file pins
#
# `src/interpreter/Interpreter.jl` introduces `initial_state(prog,
# input)::RState` — the gateway function for the forward-only
# interpreter milestone (M3). The tests below pin:
#
#   1. **Happy path** — a single-block VMProgram with a `BeginInstruction`
#      entry slot produces an `RState` whose `current.pc` equals the
#      entry block's `fwd_address` (= 1 for the first block); whose
#      `locals` carry the input verbatim; whose `status` is `:running`;
#      whose `memory` is empty; and whose `history` is an empty vector.
#   2. **Empty-program rejection (PRD v4 §3.16)** — the M0.2
#      digest-stub `VMProgram(arg_widths, return_widths)` produces an
#      empty-`blocks` program; `initial_state` MUST raise on it
#      descriptively.
#   3. **Missing entry_label rejection** — this is enforced by
#      `VMProgram`'s inner constructor (M2.17), not by `initial_state`
#      itself, because an unstartable `VMProgram` is never legal to
#      construct. The test verifies the constructor's raise.
#   4. **BeginInstruction.params name validation** — when the entry
#      block's `entry` slot is a `BeginInstruction`, the input keys
#      MUST exactly match its `params` list (both missing-key and
#      extra-key mismatches raise).
#   5. **Non-Begin entry fallback** — when the entry slot is an
#      `UnconditionalEntry` (or any other non-`BeginInstruction`),
#      name validation is skipped and the input is installed verbatim.
#      This is the lowering-pass escape hatch for basic-block-rooted
#      main routines that don't carry an explicit `Begin`.
#   6. **Int64 coercion** — `IState.locals` is declared
#      `Dict{Symbol,Int64}`; narrower input types (`Int32`) are
#      coerced via `Int64(v)` at the boundary, not deferred to the
#      first arithmetic instruction.
#   7. **M3.2 `is_halted` truth table** — running/halted/error
#      dispatch through identity comparison on `status`.
#   8. **M3.2 `result` copy semantics** — returned dict equals the
#      halted locals BUT is identity-distinct; mutating it must not
#      reach the RState.
#   9. **M3.2 `result` non-halted raise (Rule 1)** — error message
#      names both the "not halted" marker and the actual status.
#
# Per CLAUDE.md Rule 4, every test asserts an invariant against a
# known-correct value (not just "didn't throw").
#
# # Ref
#
#   * `src/interpreter/Interpreter.jl` (M3.1) — the function under
#     test.
#   * `src/ir/VMProgram.jl` (M2.17) — `VMProgram` constructor and the
#     digest-stub 2-arg form.
#   * `src/ir/label_table.jl` (M2.16) — `LabelEntry.fwd_address` is
#     what `current.pc` ends up holding.
#   * `bennettvm_prd.md` (PRD v4) §3.9 (`initial_state` signature),
#     §3.16 (empty-program validation is binding).
#   * CLAUDE.md Rule 1 (constructor-validation tests fail loud);
#     Rule 4 (every test asserts a known-correct value).

using Test
using BennettVM

@testset "initial_state happy path (M3.1)" begin
    # Hand-build a single-block program that mimics a no-arg-aware main:
    # the BeginInstruction names `:n` as the formal parameter, the body
    # is a single ArithmeticAssignment touching `:n`, and the
    # EndInstruction names `:s` as the return. The body's actual
    # semantics are irrelevant for M3.1 — we only check that
    # initial_state wires up pc / locals / status / memory / history.
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.BeginInstruction(:main, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:main, [:s]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64], [64])

    rs = initial_state(vm, Dict(:n => Int64(7)))
    @test rs isa BennettVM.RState
    # fwd_address of the first block is 1 (the entry instruction is the
    # first instruction in the flat stream).
    @test rs.current.pc == 1
    @test BennettVM.active_locals(rs.current)[:n] == 7
    @test rs.current.status === :running
    @test isempty(rs.history)
    @test isempty(rs.current.memory)
end

@testset "initial_state validation: empty program (M3.1)" begin
    # The M0.2 digest-stub `VMProgram(arg_widths, return_widths)`
    # constructor produces an empty-`blocks` program. PRD v4 §3.16
    # makes the empty-program rejection binding.
    vm = VMProgram(Int[], Int[])
    @test_throws ErrorException initial_state(vm, Dict{Symbol,Int64}())
end

@testset "initial_state validation: missing entry_label (M3.1)" begin
    # Construct a candidate VMProgram with an entry_label (`:gone`)
    # that is absent from the LabelTable. The M2.17 inner constructor
    # rejects this directly — `initial_state` never sees the bad
    # program because it cannot be constructed in the first place.
    # This test verifies that gate.
    bb = BennettVM.BasicBlock(
        :onlyblock,
        BennettVM.BeginInstruction(:onlyblock, Symbol[]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:onlyblock, Symbol[]),
    )
    @test_throws ErrorException VMProgram(
        [bb],
        BennettVM.LabelTable([bb]),
        :gone,
        Int[],
        Int[],
    )
end

@testset "initial_state validation: input matches BeginInstruction.params (M3.1)" begin
    # Two-parameter Begin: input keys MUST equal {:n, :m}. Both
    # missing-key and extra-key mismatches raise.
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.BeginInstruction(:main, [:n, :m]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:main, [:n, :m]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64, 64], [64, 64])

    # Missing :m — the params Set is {:n, :m}, the input Set is {:n}.
    @test_throws ErrorException initial_state(vm, Dict(:n => Int64(1)))
    # Extra key :extra — the input Set is a superset of params.
    @test_throws ErrorException initial_state(
        vm,
        Dict(:n => Int64(1), :m => Int64(2), :extra => Int64(3)),
    )
    # Exact match — succeeds and binds both names.
    rs = initial_state(vm, Dict(:n => Int64(1), :m => Int64(2)))
    @test BennettVM.active_locals(rs.current)[:n] == 1
    @test BennettVM.active_locals(rs.current)[:m] == 2
end

@testset "initial_state fallback when entry isn't Begin (M3.1)" begin
    # When the entry slot is an `UnconditionalEntry` (the basic-block-
    # rooted main shape Phase-2 lowering MAY produce), the param-name
    # validation is skipped and `input` is installed verbatim — even if
    # its keys don't match the entry's `params` list. This is the
    # documented escape hatch from `initial_state`'s docstring.
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.UnconditionalEntry(:main, [:x]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:next, [:x]),
    )
    # NOTE: this VMProgram has `:next` referenced by the exit but no
    # `:next` block in the LabelTable. That's M2.18's cross-block
    # validation pass to enforce, not M2.17's inner constructor —
    # which only checks length(label_table) == length(blocks) and
    # haskey(label_table, entry_label). Both pass here.
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64], [64])

    rs = initial_state(vm, Dict(:anything => Int64(42)))
    @test BennettVM.active_locals(rs.current)[:anything] == 42
    @test rs.current.status === :running
end

@testset "initial_state input coercion to Int64 (M3.1)" begin
    # Narrower input types (Int32 here) MUST be coerced to Int64 at
    # the construction site so the produced `IState.locals` matches
    # its declared element type.
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.BeginInstruction(:main, [:n]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:main, [:n]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64], [64])

    rs = initial_state(vm, Dict(:n => Int32(5)))
    @test BennettVM.active_locals(rs.current)[:n] == Int64(5)
    @test BennettVM.active_locals(rs.current)[:n] isa Int64
end

# ---------------------------------------------------------------------
# M3.2 — `is_halted` and `result` accessors (bd `bennettvm-3ch`).
#
# `is_halted(s)` is the predicate the M3.4 `run!` loop terminates on;
# `result(s)` is the terminal accessor that extracts a defensive copy
# of the halted RState's locals dict and raises descriptively
# otherwise.
#
# The tests below pin:
#
#   1. `is_halted` returns the three-status truth table (running:
#      false, halted: true, error: false) on a freshly-built IState
#      whose `status` is mutated in place between assertions.
#   2. `result` on a halted RState returns a dict EQUAL to the
#      halted-IState locals but DISTINCT in identity — i.e., mutating
#      the returned dict must NOT propagate back to the RState. The
#      copy semantics are load-bearing per the function's docstring.
#   3. `result` on a non-halted RState raises an `ErrorException`
#      whose message names both the marker "not halted" and the
#      actual status symbol (`:running` / `:error`), so the failure
#      mode is diagnosable from the message alone (Rule 1).
# ---------------------------------------------------------------------

@testset "is_halted (M3.2)" begin
    s = BennettVM.IState(0, Dict{Symbol,Int64}(), :running)
    r = BennettVM.RState(s, BennettVM.AbstractHistoryEntry[])
    @test !is_halted(r)
    s.status = :halted
    @test is_halted(r)
    s.status = :error
    @test !is_halted(r)
end

@testset "result accessor — halted (M3.2)" begin
    s = BennettVM.IState(0, Dict(:x => Int64(42), :y => Int64(7)), :halted)
    r = BennettVM.RState(s, BennettVM.AbstractHistoryEntry[])
    res = result(r)
    @test res == Dict(:x => Int64(42), :y => Int64(7))
    # Returned dict is a COPY — mutations don't reach the RState.
    res[:x] = Int64(999)
    @test BennettVM.active_locals(r.current)[:x] == 42   # unchanged
end

@testset "result accessor — non-halted errors (M3.2)" begin
    for status in (:running, :error)
        s = BennettVM.IState(0, Dict(:x => Int64(1)), status)
        r = BennettVM.RState(s, BennettVM.AbstractHistoryEntry[])
        err = try; result(r); nothing; catch e; e; end
        @test err isa ErrorException
        @test occursin("not halted", err.msg)
        @test occursin(string(status), err.msg)
    end
end

# ---------------------------------------------------------------------
# M3.3 — `step!` single-instruction dispatch (bd `bennettvm-1hn`).
#
# `step!(s::RState, prog::VMProgram)::RState` advances the interpreter
# one instruction forward. The tests below pin:
#
#   1. **Three-step arithmetic walk** — a single-block program with a
#      `BeginInstruction` entry, one `ArithmeticAssignment` body, and
#      an `EndInstruction` exit. Each `step!` is asserted to advance
#      pc by exactly 1; the arithmetic body's destroy-source /
#      create-target / pc-bump semantics are visible mid-walk; the
#      End step transitions status to `:halted`; calling `step!` once
#      more on the halted state is a silent no-op (idempotency
#      contract).
#   2. **Flat-stream resolver `_instruction_at`** — a two-block program
#      lets us verify the resolver returns the correct concrete
#      `Instruction` subtype at every address in the flat
#      `[entry, body..., exit]` layout and that out-of-range pc
#      (both pc<1 and pc>n_instructions) raises descriptively
#      (Rule 1).
#   3. **Halted no-op** — `step!` called on an RState whose status is
#      already `:halted` does NOT touch pc, status, or locals — the
#      M3.4 run! loop relies on this idempotent shape.
#
# Per CLAUDE.md Rule 4, every test asserts an invariant against a
# known-correct value (not just "didn't throw").
# ---------------------------------------------------------------------

@testset "step! single arithmetic instruction (M3.3)" begin
    # A minimal one-block program: Begin → ArithAssign → End.
    # The ArithmeticAssignment computes `x := n ⊕ (n ⊕ 0)` — i.e.,
    # n XOR (n XOR 0) = 0 — chosen because the value is structurally
    # forced and the lhs/source aliasing on `:n` exercises the
    # destroy-source path explicitly (forward resolves lhs from
    # `BennettVM.active_locals(s)[:n]` BEFORE deleting `:n` per the M2.6 forward order).
    bb = BennettVM.BasicBlock(
        :main,
        BennettVM.BeginInstruction(:main, [:n]),
        BennettVM.Instruction[
            # x := n ⊕ (n ⊕ 0); destroys :n, creates :x.
            BennettVM.ArithmeticAssignment(:x, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:main, [:x]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64], [64])
    rs = initial_state(vm, Dict(:n => Int64(7)))

    # Step 1: BeginInstruction at pc=1 — pc → 2; locals unchanged;
    # status stays :running.
    step!(rs, vm)
    @test rs.current.pc == 2
    @test BennettVM.active_locals(rs.current)[:n] == 7
    @test rs.current.status === :running

    # Step 2: ArithmeticAssignment at pc=2 — destroys :n, creates :x;
    # pc → 3; status stays :running.
    step!(rs, vm)
    @test rs.current.pc == 3
    @test !haskey(BennettVM.active_locals(rs.current), :n)
    @test BennettVM.active_locals(rs.current)[:x] == 7 ⊻ (7 ⊻ 0)
    @test rs.current.status === :running

    # Step 3: EndInstruction at pc=3 — pc → 4 (past the end of the
    # 3-instruction flat stream); status transitions to :halted.
    step!(rs, vm)
    @test rs.current.pc == 4
    @test rs.current.status === :halted

    # Idempotency contract: step! on a halted state is a silent no-op.
    pc_before = rs.current.pc
    locals_before = copy(BennettVM.active_locals(rs.current))
    step!(rs, vm)
    @test rs.current.pc == pc_before
    @test rs.current.status === :halted
    @test BennettVM.active_locals(rs.current) == locals_before

    # `result` works on the halted RState — defensive copy of locals.
    @test result(rs)[:x] == 7 ⊻ (7 ⊻ 0)
end

@testset "_instruction_at — flat stream resolution (M3.3)" begin
    # Two-block program. Flat-stream layout:
    #   pc=1: bb1.entry  (BeginInstruction)
    #   pc=2: bb1.instructions[1]  (ArithmeticAssignment)
    #   pc=3: bb1.exit   (UnconditionalExit)
    #   pc=4: bb2.entry  (UnconditionalEntry)
    #   pc=5: bb2.exit   (EndInstruction)
    # Total flat-stream count = 5.
    bb1 = BennettVM.BasicBlock(
        :b1,
        BennettVM.BeginInstruction(:b1, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:s, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.UnconditionalExit(:b2, [:s]),
    )
    bb2 = BennettVM.BasicBlock(
        :b2,
        BennettVM.UnconditionalEntry(:b2, [:s]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:b1, [:s]),
    )
    vm = VMProgram([bb1, bb2], BennettVM.LabelTable([bb1, bb2]), :b1,
                   [64], [64])

    @test BennettVM._instruction_at(vm, 1) isa BennettVM.BeginInstruction
    @test BennettVM._instruction_at(vm, 2) isa BennettVM.ArithmeticAssignment
    @test BennettVM._instruction_at(vm, 3) isa BennettVM.UnconditionalExit
    @test BennettVM._instruction_at(vm, 4) isa BennettVM.UnconditionalEntry
    @test BennettVM._instruction_at(vm, 5) isa BennettVM.EndInstruction
    # Out-of-range bounds: pc < 1 and pc > flat count both raise
    # descriptively (Rule 1).
    @test_throws ErrorException BennettVM._instruction_at(vm, 0)
    @test_throws ErrorException BennettVM._instruction_at(vm, 6)
    @test_throws ErrorException BennettVM._instruction_at(vm, -1)
end

@testset "step! no-op on halted (M3.3)" begin
    # RState whose status is already :halted — step! short-circuits
    # without touching pc, status, or locals. The VMProgram passed in
    # doesn't matter (step! never resolves the pc when status is
    # non-running); we pass a minimal one-block program to satisfy
    # the type contract.
    s = BennettVM.IState(5, Dict(:x => Int64(1)), :halted)
    r = BennettVM.RState(s, BennettVM.AbstractHistoryEntry[])
    bb = BennettVM.BasicBlock(
        :m,
        BennettVM.BeginInstruction(:m, Symbol[]),
        BennettVM.Instruction[],
        BennettVM.EndInstruction(:m, Symbol[]),
    )
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, Int[], Int[])

    step!(r, vm)
    @test r.current.pc == 5         # unchanged (pc=5 is past program end;
                                    # but step! never tried to resolve it)
    @test r.current.status === :halted
    @test BennettVM.active_locals(r.current)[:x] == 1

    # Same idempotency holds for :error status — Rule 1 / PRD v4 §3.16
    # silent-no-op-when-not-:running contract.
    s2 = BennettVM.IState(99, Dict{Symbol,Int64}(), :error)
    r2 = BennettVM.RState(s2, BennettVM.AbstractHistoryEntry[])
    step!(r2, vm)
    @test r2.current.pc == 99
    @test r2.current.status === :error
end

# ---------------------------------------------------------------------
# M3.4 — `run!` loop with max-steps guard (bd `bennettvm-fbh`).
#
# `run!(s::RState, prog::VMProgram; max_steps=10_000)::RState` is the
# canonical forward driver: a while-loop calling `step!` until
# `is_halted(s)`, with a max-steps guard that errors descriptively on
# divergence (PRD v4 §3.16; Rule 1).
#
# The tests below pin:
#
#   1. **Simple straight-line program** — Begin → Arith → End runs to
#      halt and the locals dict shows the arithmetic actually happened
#      (not just "didn't throw"). Rule 4 discipline.
#   2. **Chaining contract** — the same RState passed in is the RState
#      returned (`===`), matching PRD v4 §3.11's "mutated in place;
#      return value for chaining" convention.
#   3. **Max-steps guard fires loudly** — a program with more flat-
#      stream instructions than the guard allows raises an
#      `ErrorException` whose message names the max_steps value, the
#      current pc, and the status (so the failure mode is diagnosable
#      from the message alone; Rule 1). NOT a silent return.
#   4. **Pre-halted no-op** — running `run!` on an already-`:halted`
#      RState changes nothing: same pc, still halted. The loop's
#      `!is_halted` head-check returns immediately without entering
#      the body.
#
# Per CLAUDE.md Rule 4, every test asserts an invariant against a
# known-correct value, not just "didn't throw".
# ---------------------------------------------------------------------

@testset "run! simple straight-line program (M3.4)" begin
    bb = BennettVM.BasicBlock(:main,
        BennettVM.BeginInstruction(:main, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:x, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:main, [:x]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :main, [64], [64])
    rs = initial_state(vm, Dict(:n => Int64(42)))

    run!(rs, vm)
    @test is_halted(rs)
    @test BennettVM.active_locals(rs.current)[:x] == 42 ⊻ (42 ⊻ 0)
end

@testset "run! returns same RState for chaining (M3.4)" begin
    bb = BennettVM.BasicBlock(:m, BennettVM.BeginInstruction(:m, Symbol[]),
                              BennettVM.Instruction[],
                              BennettVM.EndInstruction(:m, Symbol[]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, Int[], Int[])
    rs = initial_state(vm, Dict{Symbol,Int64}())
    rs2 = run!(rs, vm)
    @test rs === rs2
    @test is_halted(rs)
end

@testset "run! max_steps guard fires loudly (M3.4)" begin
    # A program that never halts: build a tiny "loop" by hand with
    # a single block whose UnconditionalExit points back to itself.
    # The interpreter at M3.3 doesn't yet implement cross-block
    # dispatch (that's M3.5+), so step! will keep advancing pc
    # through the flat stream until it falls off the end —
    # _instruction_at will then throw, NOT max_steps.
    #
    # To exercise the max-steps guard cleanly, we cheat: pre-set
    # max_steps to a tiny value and use a program that has more
    # instructions than the guard, but no End in the path traversed
    # before the guard fires.
    # NOTE: the Begin must declare `:a` as a formal param — M3.1's
    # name-validation pass rejects an input key that isn't in the
    # Begin's params list. The chained arithmetic below produces
    # :b/:c/:d as fresh locals while keeping the destroy-source
    # discipline (each arith destroys its lhs source).
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:a]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:b, :a, :xor, :a, :xor, Int64(0)),
            BennettVM.ArithmeticAssignment(:c, :b, :xor, :b, :xor, Int64(0)),
            BennettVM.ArithmeticAssignment(:d, :c, :xor, :c, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:m, [:d]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
    rs = initial_state(vm, Dict(:a => Int64(1)))

    # The program has 5 flat instructions (Begin + 3 Arith + End);
    # with max_steps=2 we halt mid-arithmetic before reaching End.
    # Guard MUST fire (not silently return).
    err = try
        run!(rs, vm; max_steps=2)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("max_steps=2", err.msg)
    @test occursin("pc=", err.msg)
    @test occursin("status=", err.msg)
end

@testset "run! pre-halted no-op (M3.4)" begin
    bb = BennettVM.BasicBlock(:m, BennettVM.BeginInstruction(:m, Symbol[]),
                              BennettVM.Instruction[],
                              BennettVM.EndInstruction(:m, Symbol[]))
    vm = VMProgram([bb], BennettVM.LabelTable([bb]), :m, Int[], Int[])
    rs = initial_state(vm, Dict{Symbol,Int64}())
    rs.current.status = :halted   # manually halt
    pc_before = rs.current.pc
    run!(rs, vm)  # should not change anything
    @test rs.current.pc == pc_before
    @test is_halted(rs)
end

# ---------------------------------------------------------------------
# M3.6 — cross-block dispatch (bd `bennettvm-yx3`).
#
# `step!` extension: after `forward(::UnconditionalExit, ...)` or
# `forward(::ConditionalExit, ...)`, the pc is relocated to the
# destination block's first body instruction (i.e., one past the entry
# marker), and the sender's `args` are positionally renamed into the
# receiver's `params`.
#
# The tests below pin:
#
#   1. **Unconditional cross-block dispatch** — a two-block program
#      where bb1 exits unconditionally to bb2 (with args=[:m] →
#      params=[:m_in]) runs to halt, the args/params rename
#      destroys the sender's names and creates the receiver's, and
#      the final result is well-defined.
#   2. **Conditional cross-block dispatch — both branches** — a
#      three-block program (start + tbr + fbr) where `start` exits
#      to `tbr` if the condition is nonzero and `fbr` otherwise.
#      Run twice with the predicate set to each value; verify the
#      correct branch's body is the one executed.
#   3. **`_rename_args_to_params!` identity case** — args == params
#      passes through unchanged. The two-phase rename's capture-
#      delete-assign is exactly the discipline that makes this work
#      (a one-phase implementation would silently lose values when
#      the same Symbol appears on both sides).
#   4. **`_rename_args_to_params!` rename case** — args != params
#      destroys old names and creates new ones with the same values.
#   5. **`_rename_args_to_params!` arity mismatch** — Rule 1 raise
#      on `length(args) != length(params)`.
#
# Per CLAUDE.md Rule 4, every test asserts an invariant against a
# known-correct value (not just "didn't throw").
# ---------------------------------------------------------------------

@testset "cross-block UnconditionalExit (M3.6)" begin
    # bb1: Begin(:b1, [:n]) → ArithAssign(:m := :n ⊕ (:n ⊕ 0)) → UncondExit(:b2, [:m])
    # bb2: UncondEntry(:b2, [:m_in]) → ArithAssign(:r := :m_in ⊕ (:m_in ⊕ 0)) → End(:b1, [:r])
    # The rename :m → :m_in fires across the cross-block edge.
    bb1 = BennettVM.BasicBlock(:b1,
        BennettVM.BeginInstruction(:b1, [:n]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:m, :n, :xor, :n, :xor, Int64(0)),
        ],
        BennettVM.UnconditionalExit(:b2, [:m]))
    bb2 = BennettVM.BasicBlock(:b2,
        BennettVM.UnconditionalEntry(:b2, [:m_in]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:r, :m_in, :xor, :m_in, :xor, Int64(0)),
        ],
        BennettVM.EndInstruction(:b1, [:r]))
    vm = VMProgram([bb1, bb2], BennettVM.LabelTable([bb1, bb2]), :b1,
                   [64], [64])
    rs = initial_state(vm, Dict(:n => Int64(99)))

    run!(rs, vm)
    @test is_halted(rs)
    # :n was renamed to :m via the body of bb1 (xor identity), then
    # :m → :m_in across the cross-block edge, then :m_in → :r via
    # bb2's body (xor identity again). Final result preserves 99.
    @test BennettVM.active_locals(rs.current)[:r] == 99 ⊻ (99 ⊻ 0)
    @test !haskey(BennettVM.active_locals(rs.current), :n)
    @test !haskey(BennettVM.active_locals(rs.current), :m)
    @test !haskey(BennettVM.active_locals(rs.current), :m_in)
end

@testset "cross-block ConditionalExit — true and false branches (M3.6)" begin
    # Three-block program. `start` exits conditionally on :c:
    #   :c != 0 → :tbr (true branch)
    #   :c == 0 → :fbr (false branch)
    # Each branch performs a different arithmetic operation so the
    # final result distinguishes which branch ran.
    #
    # Note on ConditionalEntry constructor: predecessor_true and
    # predecessor_false MUST differ (M2.10 constructor invariant);
    # the runtime does not enforce predecessor labels exist as
    # blocks (that's M2.18's cross-block validation pass), so we
    # use distinct labels (`:start` and a sentinel `:nonexistent_b`)
    # to satisfy the constructor without needing a third upstream
    # block.
    bb_start = BennettVM.BasicBlock(:start,
        BennettVM.BeginInstruction(:start, [:n, :c]),
        BennettVM.Instruction[],
        BennettVM.ConditionalExit(:c, :tbr, :fbr, [:n]))
    # The two branches produce DISTINCT output values so the test
    # discriminates which branch actually ran (a true/false swap in
    # the dispatch would invert the observed value at the @test):
    #   true branch:  r := n_in ⊕ (n_in ⊕ 100) = 100
    #   false branch: r := n_in ⊕ (n_in ⊕ 200) = 200
    bb_t = BennettVM.BasicBlock(:tbr,
        BennettVM.ConditionalEntry(:tbr, [:n_in], :start, :nonexistent_b, :c),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:r, :n_in, :xor, :n_in, :xor, Int64(100)),
        ],
        BennettVM.EndInstruction(:tbr, [:r]))
    bb_f = BennettVM.BasicBlock(:fbr,
        BennettVM.ConditionalEntry(:fbr, [:n_in], :start, :nonexistent_b, :c),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:r, :n_in, :xor, :n_in, :xor, Int64(200)),
        ],
        BennettVM.EndInstruction(:fbr, [:r]))

    vm = VMProgram([bb_start, bb_t, bb_f],
                   BennettVM.LabelTable([bb_start, bb_t, bb_f]),
                   :start, [64, 64], [64])

    # Branch :c = 1 (true) — should go to :tbr; expected r == 100.
    rs_t = initial_state(vm, Dict(:n => Int64(42), :c => Int64(1)))
    run!(rs_t, vm)
    @test is_halted(rs_t)
    @test BennettVM.active_locals(rs_t.current)[:r] == 100

    # Branch :c = 0 (false) — should go to :fbr; expected r == 200.
    rs_f = initial_state(vm, Dict(:n => Int64(42), :c => Int64(0)))
    run!(rs_f, vm)
    @test is_halted(rs_f)
    @test BennettVM.active_locals(rs_f.current)[:r] == 200

    # Sanity: the predicate :c is NOT consumed by the dispatch —
    # it should still be in locals after the branch fires.
    # (Per M3.6 _handle_cross_block_dispatch! docstring: the
    # predicate remains live to preserve RSSA invertibility.)
    @test BennettVM.active_locals(rs_t.current)[:c] == 1
    @test BennettVM.active_locals(rs_f.current)[:c] == 0
end

@testset "_rename_args_to_params! identity case (M3.6)" begin
    # args == params: net-no-op on the dict's key set, values
    # preserved. The two-phase capture-delete-assign discipline is
    # what makes this work (a one-phase delete-then-assign would
    # KeyError because the values are gone before the assign reads
    # them).
    locals = Dict(:x => Int64(1), :y => Int64(2))
    BennettVM._rename_args_to_params!(locals, [:x, :y], [:x, :y])
    @test locals == Dict(:x => Int64(1), :y => Int64(2))
end

@testset "_rename_args_to_params! rename case (M3.6)" begin
    # Distinct args/params: old names destroyed, new names created
    # with values preserved positionally.
    locals = Dict(:a => Int64(7), :b => Int64(11))
    BennettVM._rename_args_to_params!(locals, [:a, :b], [:x, :y])
    @test locals == Dict(:x => Int64(7), :y => Int64(11))
    @test !haskey(locals, :a)
    @test !haskey(locals, :b)
end

@testset "_rename_args_to_params! permutation case (M3.6)" begin
    # Cross-permutation (args = [:x,:y], params = [:y,:x]) is the
    # case the two-phase rename specifically protects: a one-phase
    # implementation would stomp :x when params[1] = :y is assigned
    # because :y was already a key. The capture-then-assign shape
    # avoids the stomp.
    locals = Dict(:x => Int64(10), :y => Int64(20))
    BennettVM._rename_args_to_params!(locals, [:x, :y], [:y, :x])
    @test locals == Dict(:y => Int64(10), :x => Int64(20))
end

@testset "_rename_args_to_params! arity mismatch (M3.6)" begin
    # Rule 1: arity mismatch fails loud, not silent. M2.18's
    # validate pass (when it lands) will catch this at construction
    # time; until then, the dispatch layer is the last line of
    # defense.
    locals = Dict(:a => Int64(1))
    @test_throws ErrorException BennettVM._rename_args_to_params!(
        locals, [:a], [:x, :y])
end

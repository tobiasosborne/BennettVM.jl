# test/test_jpb_generator_hardening.jl — `bennettvm-jpb`: the generator
# hardening the s9c hostile review surfaced.
#
# # What this bead is
#
# `test/generators/random_program.jl` (M8.4) had two unchecked claims:
#
#   (1) **The determinism comparator compared TYPES only.**
#       `_structural_eq` walked blocks, entries, exits and instructions
#       and compared `typeof`, never a single field. Two programs
#       computing different functions — `Define(:r,1,:add,0)` vs
#       `Define(:r,999,:add,0)`, `:add` vs `:mul` — compared EQUAL.
#       Astra VM-ingest F17 executed it: `_structural_eq(p1,p2)=true`
#       with `p1 result=1` and `p2 result=999`. Same-seed generation
#       makes it invisible today (no live defect), but the contract the
#       determinism test backs is "same RNG state in → same program
#       out", a claim about programs, not about shapes.
#
#   (2) **The construction-time invariant was label-resolution only.**
#       `_assert_vm_invariants` checked that every edge target resolves,
#       and nothing else. Two properties the generator silently relied
#       on were unasserted: edge ARITY alignment (`exit.args` vs
#       destination `params`, both sides of a `ConditionalEntry`), and
#       PREDICATE LIVENESS (the `:c` symbol is an input, is never the
#       target of an instruction, and appears in no `args` / `params`
#       list — the diamond's backward predecessor recovery re-reads it
#       at the join, and `_bind_args_to_params!` renames only the names
#       a list mentions).
#
# # How each is proved here, and why the old code is kept
#
# Both claims are "this check is stronger than it looks", so a test that
# only exercises the new code proves nothing about the gap. Each
# testset therefore keeps the PRE-bead check verbatim next to the new
# one and asserts the split: the old check accepts the fixture (that is
# the defect), the new one rejects it. Deleting the old check would
# delete the evidence.
#
#   * `_jpb_structural_eq_types_only` — `_structural_eq` before this
#     bead.
#   * `_jpb_assert_labels_only` — `_assert_vm_invariants` before this
#     bead.
#
# Both are verbatim copies of the pre-bead bodies (git:
# `test/generators/random_program.jl` at the `bennettvm-jpb` commit's
# parent) and are never used to gate anything.
#
# # Where the model helps, and where it does not
#
# For a perturbation of a SEMANTIC field (a literal, an opcode, a
# modop) the independent model (`test/generators/semantic_model.jl`)
# is the adjudicator: it says the two programs compute different
# values, so "the comparator must call them different" is a fact and
# not a preference. For a perturbation of a STRUCTURAL field (a label,
# a target, a block's arg count, a declared width) the two programs
# compute the SAME value — the model has nothing to say, and the
# requirement is the weaker but still real one that the determinism
# comparator must notice the difference. Those cases are marked
# `nothing` (no desc) rather than given a fake adjudication.
#
# # Ref
#
#   * `bd bennettvm-jpb` — this bead. Item (1) is its NOTES entry from
#     the M8.5 Sonnet review, corroborated as F17 by
#     `reviews/2026-09-26-astra/VM-ingest.md` / `…verification.md`.
#     Item (2) is its DESCRIPTION, from the s9c hostile review.
#   * `test/generators/random_program.jl` — `_structural_eq`,
#     `_node_eq`, `_assert_vm_invariants` (the code under test here).
#   * `test/generators/semantic_model.jl` — the independent evaluator
#     used as adjudicator.
#   * `src/interpreter/Interpreter.jl` — `_bind_args_to_params!` (the
#     arity / rename contract the invariant now asserts statically) and
#     `_handle_cross_block_dispatch!` (the predicate read that must stay
#     live across the split).
#   * `src/ir/control_instructions.jl` — the entry / exit field names
#     (`args`, `params`, `condition`, `predecessor_*`).
#   * CLAUDE.md Rule 1 (fail loud), Rule 4 (assert a known-correct
#     value, not "did not throw"), Rule 5 (mutation-prove the new check
#     catches what the old one missed).

using Test
using Random
using BennettVM

# The generator under test. Include-guarded, per the project's
# per-file autonomy idiom; the M8.2 scaffold comes first because the
# generator's own testsets drive programs through it.
isdefined(@__MODULE__, :per_step_inverse_check) ||
    include(joinpath(@__DIR__, "test_per_step_inverse.jl"))
isdefined(@__MODULE__, :random_program) ||
    include(joinpath(@__DIR__, "generators", "random_program.jl"))

# ---------------------------------------------------------------------
# The pre-bead checks, kept as evidence (never used to gate anything)
# ---------------------------------------------------------------------

# `_structural_eq` as it stood before this bead: labels, types, and
# counts — never a field value. Kept so the testset below can show the
# blind spot rather than merely assert the absence of one.
function _jpb_structural_eq_types_only(a::VMProgram, b::VMProgram)
    length(a.blocks) == length(b.blocks) || return false
    a.entry_label === b.entry_label || return false
    for (ba, bb) in zip(a.blocks, b.blocks)
        ba.label === bb.label || return false
        typeof(ba.entry) === typeof(bb.entry) || return false
        typeof(ba.exit)  === typeof(bb.exit)  || return false
        length(ba.instructions) == length(bb.instructions) || return false
        all(typeof(ia) === typeof(ib) for (ia, ib) in
            zip(ba.instructions, bb.instructions)) || return false
    end
    return true
end

# `_assert_vm_invariants` as it stood before this bead: label
# resolution only. Kept for the same reason.
function _jpb_assert_labels_only(vm::VMProgram)
    for bb in vm.blocks
        ex = bb.exit
        if ex isa BennettVM.UnconditionalExit
            haskey(vm.label_table, ex.target) ||
                error("generator: block :$(bb.label) UnconditionalExit ",
                      "→ :$(ex.target) — unknown label")
        elseif ex isa BennettVM.ConditionalExit
            haskey(vm.label_table, ex.target_true) ||
                error("generator: block :$(bb.label) ConditionalExit ",
                      "→ :$(ex.target_true) (true) — unknown label")
            haskey(vm.label_table, ex.target_false) ||
                error("generator: block :$(bb.label) ConditionalExit ",
                      "→ :$(ex.target_false) (false) — unknown label")
        end
        en = bb.entry
        if en isa BennettVM.ConditionalEntry
            haskey(vm.label_table, en.predecessor_true) ||
                error("generator: block :$(bb.label) ConditionalEntry ",
                      "← :$(en.predecessor_true) (true) — unknown label")
            haskey(vm.label_table, en.predecessor_false) ||
                error("generator: block :$(bb.label) ConditionalEntry ",
                      "← :$(en.predecessor_false) (false) — unknown label")
        end
    end
    return nothing
end

# ---------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------

# One block, one arithmetic instruction: the smallest program that has
# a semantic field worth perturbing.
function _jpb_base_program()
    bb = BennettVM.BasicBlock(:m,
        BennettVM.BeginInstruction(:m, [:x]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:y, :x, :xor, 1, :xor, 3)],
        BennettVM.EndInstruction(:m, [:y]))
    return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
end

# Same program, one block replaced. `LabelTable` and the block list are
# rebuilt together, so the result is a legal `VMProgram` (the property
# under test is the *invariant check*, which must fire on structurally
# legal but semantically wrong programs).
function _jpb_with_block(vm::VMProgram, label::Symbol,
                         bb::BennettVM.BasicBlock)
    blocks = [b.label === label ? bb : b for b in vm.blocks]
    VMProgram(blocks, BennettVM.LabelTable(blocks), vm.entry_label,
              vm.arg_widths, vm.return_widths)
end

# ---------------------------------------------------------------------
# 1. (1) The determinism comparator is field-level (F17)
# ---------------------------------------------------------------------

@testset "jpb — _structural_eq sees fields, not just types" begin
    base = _jpb_base_program()
    # x = 2, e = 1 ⊻ 3 = 2, so y = 2 ⊻ 2 = 0. The operands are chosen
    # so that EVERY semantic perturbation below changes the answer: a
    # fixture whose mutants computed the same value would make the
    # model's adjudication vacuous.
    inputs = Dict(:x => Int64(2))
    base_desc = SemDesc(:linear, nothing,
                        [[SemArith(:y, :x, :xor, 1, :xor, 3)]], :y, 64)
    @test sem_eval(base_desc, inputs).registers[:y] == 0

    # (name, mutant program, mutant desc or `nothing` when the model
    # cannot adjudicate — a structural perturbation leaves the VALUE
    # unchanged, and pretending otherwise would be a fake oracle).
    function with_instr(instr)
        bb = BennettVM.BasicBlock(:m,
            BennettVM.BeginInstruction(:m, [:x]),
            BennettVM.Instruction[instr],
            BennettVM.EndInstruction(:m, [:y]))
        return VMProgram([bb], BennettVM.LabelTable([bb]), :m, [64], [64])
    end
    cases = [
        # --- semantic fields: the model says the VALUE differs -------
        #  y = 2 ⊻ (5 ⊻ 3) = 2 ⊻ 6 = 4
        (:lhs_literal, with_instr(BennettVM.ArithmeticAssignment(:y, :x, :xor, 5, :xor, 3)),
         SemDesc(:linear, nothing, [[SemArith(:y, :x, :xor, 5, :xor, 3)]], :y, 64)),
        #  y = 2 ⊻ (1 ⊻ 2) = 2 ⊻ 3 = 1
        (:rhs_literal, with_instr(BennettVM.ArithmeticAssignment(:y, :x, :xor, 1, :xor, 2)),
         SemDesc(:linear, nothing, [[SemArith(:y, :x, :xor, 1, :xor, 2)]], :y, 64)),
        #  y = 2 ⊻ (1 | 3) = 2 ⊻ 3 = 1
        (:op, with_instr(BennettVM.ArithmeticAssignment(:y, :x, :xor, 1, :or, 3)),
         SemDesc(:linear, nothing, [[SemArith(:y, :x, :xor, 1, :or, 3)]], :y, 64)),
        #  y = 2 + (1 ⊻ 3) = 2 + 2 = 4
        (:modop, with_instr(BennettVM.ArithmeticAssignment(:y, :x, :add, 1, :xor, 3)),
         SemDesc(:linear, nothing, [[SemArith(:y, :x, :add, 1, :xor, 3)]], :y, 64)),
        # --- structural fields: the value is unchanged, the program is
        #     not — the comparator must still notice -------------------
        (:source_operand,
         with_instr(BennettVM.ArithmeticAssignment(:y, :q, :xor, 1, :xor, 3)), nothing),
        (:target_name,
         with_instr(BennettVM.ArithmeticAssignment(:w, :x, :xor, 1, :xor, 3)), nothing),
        (:entry_params,
         VMProgram([BennettVM.BasicBlock(:m,
            BennettVM.BeginInstruction(:m, [:q]),
            BennettVM.Instruction[
                BennettVM.ArithmeticAssignment(:y, :x, :xor, 1, :xor, 3)],
            BennettVM.EndInstruction(:m, [:y]))],
            BennettVM.LabelTable([BennettVM.BasicBlock(:m,
                BennettVM.BeginInstruction(:m, [:q]),
                BennettVM.Instruction[
                    BennettVM.ArithmeticAssignment(:y, :x, :xor, 1, :xor, 3)],
                BennettVM.EndInstruction(:m, [:y]))]), :m, [64], [64]),
         nothing),
    ]
    for (name, mutant, mdesc) in cases
        # (a) F17, reproduced: the pre-bead comparator calls every one
        #     of these EQUAL — including the ones that compute a
        #     different answer.
        @test _jpb_structural_eq_types_only(base, mutant)
        # (b) the comparator under test does not.
        @test !_structural_eq(base, mutant)
        # (c) for the semantic cases, the independent model says the
        #     answers really do differ.
        if mdesc !== nothing
            @test sem_eval(base_desc, inputs).registers[:y] !=
                  sem_eval(mdesc, inputs).registers[:y]
        end
    end
    # Reflexivity and the same-seed contract, now field-level.
    @test _structural_eq(base, _jpb_base_program())
    rng_a = default_rng(); rng_b = default_rng()
    for _ in 1:10
        (vm_a, in_a, d_a) = random_program(rng_a; size_hint=6)
        (vm_b, in_b, d_b) = random_program(rng_b; size_hint=6)
        @test _structural_eq(vm_a, vm_b)
        @test in_a == in_b
        @test _sem_desc_eq(d_a, d_b)      # the oracle is deterministic too
    end
    # Block-level and program-level metadata: a program with a different
    # declared width, or a different entry label, is a different
    # program even when every instruction matches.
    narrow = VMProgram(base.blocks, base.label_table, :m, [32], [64])
    @test !_structural_eq(base, narrow)
    @test _jpb_structural_eq_types_only(base, narrow)
end

# ---------------------------------------------------------------------
# 2. (2) Construction-time invariant: arity + predicate liveness
# ---------------------------------------------------------------------

# One generated diamond, and four broken copies of it. Each broken copy
# is a LEGAL `VMProgram` (the constructor does not check these), which
# is exactly why the generator's own invariant helper has to.
function _jpb_diamond_fixtures()
    (vm, _, _) = random_program(default_rng(); shape=:conditional,
                                size_hint=6)
    branch = only(filter(b -> b.exit isa BennettVM.ConditionalExit,
                         vm.blocks))
    join   = only(filter(b -> b.entry isa BennettVM.ConditionalEntry,
                         vm.blocks))
    ex, jen = branch.exit, join.entry
    # (a) arity: the split carries two args into a one-param join entry.
    #     (`ConditionalExit`'s own constructor rejects a DUPLICATE arg
    #     name, so the extra one is fresh — the arity slip this catches
    #     is the one no constructor can see.)
    arity_exit = BennettVM.ConditionalExit(ex.condition, ex.target_true,
                                           ex.target_false,
                                           [ex.args..., :extra])
    arity = _jpb_with_block(vm, branch.label,
        BennettVM.BasicBlock(branch.label, branch.entry, branch.instructions,
                             arity_exit))
    # (b) predicate carried across an UNCONDITIONAL edge: `:c` rides
    #     `:b_start → :b_branch` and is rebound by
    #     `_bind_args_to_params!`, so the backward join dispatch would
    #     read whatever that edge left under `:c`. Note the split's own
    #     `ConditionalExit` CANNOT be the vehicle — the M2.10
    #     constructor already forbids the condition in its `args` (and
    #     `ConditionalEntry` in its `params`); the hole this closes is
    #     the unconditional edges in the same diamond, which no
    #     constructor checks. The destination's params are widened to
    #     match, so the ARITY is right and the aliasing is the only
    #     defect — a fixture that tripped both would prove less.
    start = only(filter(b -> b.label === :b_start, vm.blocks))
    carried = _jpb_with_block(_jpb_with_block(vm, start.label,
        BennettVM.BasicBlock(start.label, start.entry, start.instructions,
            BennettVM.UnconditionalExit(:b_branch, [start.exit.args[1],
                                                      ex.condition]))),
        :b_branch,
        BennettVM.BasicBlock(:b_branch,
            BennettVM.UnconditionalEntry(:b_branch,
                [ex.args[1], ex.condition]),
            branch.instructions, branch.exit))
    # (c) predicate destroyed: the branch body writes `:c`.
    killed_body = BennettVM.Instruction[
        BennettVM.ArithmeticAssignment(ex.condition, ex.args[1], :xor,
                                       Int64(1), :xor, Int64(1))]
    killed = _jpb_with_block(vm, branch.label,
        BennettVM.BasicBlock(branch.label, branch.entry, killed_body,
                             branch.exit))
    # (d) predicate never bound: the split reads a symbol no input
    #     provides.
    unbound_exit = BennettVM.ConditionalExit(:not_an_input, ex.target_true,
                                             ex.target_false, ex.args)
    unbound_join = BennettVM.ConditionalEntry(jen.label, jen.params,
                                               jen.predecessor_true,
                                               jen.predecessor_false,
                                               :not_an_input)
    unbound = _jpb_with_block(_jpb_with_block(vm, join.label,
        BennettVM.BasicBlock(join.label, unbound_join, join.instructions,
                             join.exit)),
        branch.label,
        BennettVM.BasicBlock(branch.label, branch.entry, branch.instructions,
                             unbound_exit))
    return ((:arity, arity, "arity mismatch"),
            (:carried, carried, "carried in a parameter list"),
            (:killed, killed, "is also the target"),
            (:unbound, unbound, "is not an entry-block parameter"))
end

@testset "jpb — _assert_vm_invariants checks arity and predicate liveness" begin
    for (name, bad, verb) in _jpb_diamond_fixtures()
        # (a) the pre-bead check accepted all four: the labels resolve,
        #     the constructor is happy, and the defect is invisible
        #     until the interpreter hits it.
        @test _jpb_assert_labels_only(bad) === nothing
        # (b) the check under test rejects each one, naming why.
        err = try
            _assert_vm_invariants(bad)
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin(verb, err.msg)
    end
    # The unbroken diamond still passes — the added checks must not be
    # vacuously firing.
    (good, _, _) = random_program(default_rng(); shape=:conditional,
                                  size_hint=6)
    @test _assert_vm_invariants(good) === nothing
    # And the arity check sees BOTH sides of the join: a join whose
    # `params` are one longer than a predecessor's `args` is caught even
    # though the split's own edge is well-formed.
    (vm, _, _) = random_program(default_rng(); shape=:conditional,
                                size_hint=6)
    join = only(filter(b -> b.entry isa BennettVM.ConditionalEntry,
                       vm.blocks))
    jen = join.entry
    long_params = BennettVM.ConditionalEntry(jen.label,
        [jen.params..., :extra], jen.predecessor_true,
        jen.predecessor_false, jen.condition)
    bad_join = _jpb_with_block(vm, join.label,
        BennettVM.BasicBlock(join.label, long_params, join.instructions,
                             join.exit))
    @test _jpb_assert_labels_only(bad_join) === nothing
    err = try
        _assert_vm_invariants(bad_join)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("arity mismatch", err.msg)
end

# test/test_label_table.jl — M2.16 `LabelEntry` + `LabelTable` tests.
#
# Pins the four LabelEntry constructor-invariant checks (Rule 1), the
# `LabelTable(::Vector{BasicBlock})` flat-stream address computation
# (the load-bearing scan that lays out forward + backward addresses
# per block), duplicate-label rejection, and the descriptive-error
# behaviour of `Base.getindex` on absent labels. Each `@test` asserts
# a known-correct value (Rule 4); no "didn't throw" tests.
#
# Per CLAUDE.md Rule 7, this file runs in the single Julia process
# spawned by `runtests.jl`; no parallel Julia invocations.

@testset "LabelEntry struct (M2.16)" begin
    le = BennettVM.LabelEntry(1, 1, 5)
    @test le.block_index == 1
    @test le.fwd_address == 1
    @test le.bwd_address == 5
end

@testset "LabelEntry constructor validation (M2.16)" begin
    @test_throws ErrorException BennettVM.LabelEntry(0, 1, 5)   # block_index < 1
    @test_throws ErrorException BennettVM.LabelEntry(1, 0, 5)   # fwd_address < 1
    @test_throws ErrorException BennettVM.LabelEntry(1, 1, 0)   # bwd_address < 1
    @test_throws ErrorException BennettVM.LabelEntry(1, 5, 3)   # bwd < fwd
    # Equal fwd == bwd is legal — degenerate single-instruction block
    # (a program-level start/halt sentinel, in the simplest case). See
    # `src/ir/label_table.jl` top-of-module docstring "Equal-address
    # case".
    @test BennettVM.LabelEntry(1, 5, 5) isa BennettVM.LabelEntry
end

@testset "LabelTable from Vector{BasicBlock} (M2.16)" begin
    bb1 = BennettVM.BasicBlock(:B1,
        BennettVM.UnconditionalEntry(:B1, Symbol[]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:y, :x, :xor, :a, :and, :b),
            BennettVM.ArithmeticAssignment(:z, :y, :xor, :a, :and, :b),
        ],
        BennettVM.UnconditionalExit(:B2, Symbol[]))
    bb2 = BennettVM.BasicBlock(:B2,
        BennettVM.UnconditionalEntry(:B2, Symbol[]),
        BennettVM.Instruction[
            BennettVM.ArithmeticAssignment(:w, :z, :xor, :a, :and, :b),
        ],
        BennettVM.UnconditionalExit(:B3, Symbol[]))

    lt = BennettVM.LabelTable([bb1, bb2])
    # bb1: entry at 1, body at 2..3, exit at 4 → fwd=1, bwd=4
    @test lt[:B1].block_index == 1
    @test lt[:B1].fwd_address == 1
    @test lt[:B1].bwd_address == 4
    # bb2: entry at 5, body at 6, exit at 7 → fwd=5, bwd=7
    @test lt[:B2].block_index == 2
    @test lt[:B2].fwd_address == 5
    @test lt[:B2].bwd_address == 7
    @test length(lt) == 2
    @test haskey(lt, :B1)
    @test haskey(lt, :B2)
    @test !haskey(lt, :B3)
end

@testset "LabelTable duplicate labels rejected (M2.16)" begin
    bb1 = BennettVM.BasicBlock(:B,
        BennettVM.UnconditionalEntry(:B, Symbol[]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:B2, Symbol[]))
    bb2 = BennettVM.BasicBlock(:B,
        BennettVM.UnconditionalEntry(:B, Symbol[]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:B3, Symbol[]))
    @test_throws ErrorException BennettVM.LabelTable([bb1, bb2])
end

@testset "LabelTable missing-label error message (M2.16)" begin
    bb1 = BennettVM.BasicBlock(:Only,
        BennettVM.UnconditionalEntry(:Only, Symbol[]),
        BennettVM.Instruction[],
        BennettVM.UnconditionalExit(:Gone, Symbol[]))
    lt = BennettVM.LabelTable([bb1])
    err = try
        lt[:NotThere]
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("NotThere", err.msg)
    @test occursin("Only", err.msg)   # the "known labels" list
end

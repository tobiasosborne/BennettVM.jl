# test/test_memory_instructions.jl — M2.11 unit tests for the
# `MemoryAssignment` instruction (bd `bennettvm-jew`).
#
# # What this file pins
#
# `src/ir/memory_instructions.jl` defines `MemoryAssignment`, the
# third concrete `Instruction` subtype in BennettVM's twelve-class
# RSSA taxonomy (row 3 in `docs/adr/0001-rc3-rvm-smoke.md`
# §Observations). The tests below pin:
#
#   1. **Forward semantics** for each modop (`:xor`, `:add`, `:sub`):
#      a specific input state — including a *populated* memory Dict —
#      maps to a specific output state with a hand-computed value
#      (Rule 4). XOR uses bit-pattern operands so the result is
#      verifiable by hand.
#   2. **Round-trip invariant** — the load-bearing Phase-2 property:
#      `inverse(forward(s), nothing) == s` for every modop. The
#      `deepcopy` capture before `forward` is what makes the
#      assertion meaningful for `IState`'s mutable struct.
#   3. **Locals are untouched** by `MemoryAssignment.forward` — this
#      is the SSA-vs-non-SSA distinction (addresses are not SSA
#      variables; the address operand and the value operands are
#      *read*, never destroyed).
#   4. **Zero-init delete-on-inverse** — the load-bearing Phase-2
#      memory-model rule. A first-time write to an unset address,
#      followed by an inverse that produces `0`, must remove the key
#      from `s.memory` rather than leaving `memory[addr] = 0`. This
#      is what makes the round-trip a true bijection on the heap
#      Dict (see `src/ir/memory_instructions.jl` `inverse` docstring,
#      "delete-on-zero rule").
#   5. **Constructor validation** (Rule 1): bad modop and bad op both
#      raise `ErrorException`.
#
# Ref: src/ir/memory_instructions.jl (the implementation; full
#      rationale in its top-of-module docstring).
# Ref: src/ir/IState.jl (the `memory` field paragraph; the zero-init
#      convention from the IState side — both halves must agree).
# Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations — twelve-subclass
#      table row 3 (`MemAssign`); the modop-invertibility decision
#      row that fixes {:xor, :add, :sub}.
# Ref: CLAUDE.md Rule 1 (constructor validates inputs), Rule 4
#      (every @test pins a specific value).

using Test
using BennettVM

@testset "MemoryAssignment :xor round-trip (M2.11)" begin
    # M[100] := 0xff XOR (0x0f AND 0x33) = 0xff XOR 0x03 = 0xfc.
    # Bit-pattern operands so the answer is verifiable by hand.
    instr = BennettVM.MemoryAssignment(:addr, :xor, :a, :and, :b)
    s = BennettVM.IState(0, Dict(:addr => Int64(100),
                                 :a => Int64(0x0f),
                                 :b => Int64(0x33)),
                         :running,
                         Dict{Int64,Int64}(100 => Int64(0xff)))
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.memory[100] == 0xfc
    @test s2.pc == 1
    # SSA-vs-non-SSA: addresses are NOT consumed; the locals dict
    # is unchanged by a MemoryAssignment forward.
    @test s2.locals == s_before.locals
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "MemoryAssignment :add and :sub round-trip (M2.11)" begin
    # :add — M[50] := 10 + (3 * 4) = 22.
    instr_add = BennettVM.MemoryAssignment(:addr, :add, :a, :mul, :b)
    s = BennettVM.IState(0, Dict(:addr => Int64(50),
                                 :a => Int64(3),
                                 :b => Int64(4)),
                         :running,
                         Dict{Int64,Int64}(50 => Int64(10)))
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr_add, s)
    @test s2.memory[50] == 22
    @test s2.pc == 1
    s3 = BennettVM.inverse(instr_add, s2, nothing)
    @test s3 == s_before

    # :sub — M[50] := 50 - (3 * 4) = 38.
    instr_sub = BennettVM.MemoryAssignment(:addr, :sub, :a, :mul, :b)
    s = BennettVM.IState(0, Dict(:addr => Int64(50),
                                 :a => Int64(3),
                                 :b => Int64(4)),
                         :running,
                         Dict{Int64,Int64}(50 => Int64(50)))
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr_sub, s)
    @test s2.memory[50] == 38
    @test s2.pc == 1
    s3 = BennettVM.inverse(instr_sub, s2, nothing)
    @test s3 == s_before
end

@testset "MemoryAssignment zero-init address (M2.11)" begin
    # First write to an unset address: old value defaults to 0.
    # Then inverse produces 0 again, which must DELETE the key so
    # the round-trip is a true bijection on `s.memory`.
    #
    # Concretely: forward computes 0 XOR (7 + 0) = 7, so `memory[999]`
    # is `7` post-forward. Inverse computes 7 XOR (7 + 0) = 0, which
    # under the delete-on-zero rule removes the key entirely.
    instr = BennettVM.MemoryAssignment(:addr, :xor, :a, :add, Int64(0))
    s = BennettVM.IState(0, Dict(:addr => Int64(999), :a => Int64(7)),
                         :running)   # 3-arg ctor: empty memory.
    s_before = deepcopy(s)
    @test isempty(s.memory)                # precondition pin.
    s2 = BennettVM.forward(instr, s)
    @test s2.memory[999] == 7              # 0 XOR (7 + 0) = 7.
    @test haskey(s2.memory, 999)
    s3 = BennettVM.inverse(instr, s2, nothing)
    # The load-bearing assertion: post-inverse memory has NO key
    # for address 999 — the delete-on-zero rule fired. If the rule
    # were absent, s3.memory would be `Dict(999 => 0)` and the next
    # assertion would go RED (Dict content-equality treats absence
    # vs `=> 0` as distinct).
    @test !haskey(s3.memory, 999)
    @test isempty(s3.memory)
    @test s3 == s_before                   # round-trip bijection.
end

@testset "MemoryAssignment delete-on-zero with prior writes (M2.11)" begin
    # A sibling scenario: address `999` is being inverted to zero,
    # but address `500` carried a prior value that survives. The
    # delete-on-zero rule must fire on `999` ALONE — not wipe the
    # whole memory.
    instr = BennettVM.MemoryAssignment(:addr, :xor, :a, :add, Int64(0))
    s = BennettVM.IState(0, Dict(:addr => Int64(999), :a => Int64(7)),
                         :running,
                         Dict{Int64,Int64}(500 => Int64(42)))
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.memory[999] == 7
    @test s2.memory[500] == 42             # untouched neighbour.
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test !haskey(s3.memory, 999)
    @test s3.memory[500] == 42             # neighbour still present.
    @test s3 == s_before
end

@testset "MemoryAssignment literal address (M2.11)" begin
    # The `addr` field admits Int64 literals as well as Symbols.
    # M[200] += a * b — addr resolved as literal 200.
    instr = BennettVM.MemoryAssignment(Int64(200), :add, :a, :mul, :b)
    s = BennettVM.IState(0, Dict(:a => Int64(5), :b => Int64(6)),
                         :running,
                         Dict{Int64,Int64}(200 => Int64(1)))
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.memory[200] == 31             # 1 + (5 * 6).
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "MemoryAssignment constructor validation (M2.11)" begin
    # Bad modop — :mul is not in {:xor, :add, :sub}.
    @test_throws ErrorException BennettVM.MemoryAssignment(:a, :mul, :b,
                                                           :add, :c)
    # Bad op — :nonsense is not in ALL_BINARY_OPERATORS.
    @test_throws ErrorException BennettVM.MemoryAssignment(:a, :xor, :b,
                                                           :nonsense, :c)
    # FP op (:fadd) IS in ALL_BINARY_OPERATORS but NOT in
    # BINARY_OPERATORS — same M_FP-routing restriction as
    # ArithmeticAssignment.
    @test_throws ErrorException BennettVM.MemoryAssignment(:a, :xor, :b,
                                                           :fadd, :c)
end

# M2.12 — `MemoryInterchange` testsets. The Pendulum-style reversible
# load `x := M[y] := z`: an atomic register-memory exchange. Tests
# pin (1) forward semantics and round-trip on a populated cell,
# (2) zero-init delete-on-inverse symmetry with M2.11, (3) literal
# address operand support, and (4) constructor-time rejection of
# degenerate name overlaps (Rule 1). Ref: src/ir/memory_instructions.jl
# (the `MemoryInterchange` block), RC3
# `MemoryInterchangeInstruction.java`.

@testset "MemoryInterchange forward + round-trip (M2.12)" begin
    instr = BennettVM.MemoryInterchange(:x, :y, :z)
    s = BennettVM.IState(0,
        Dict(:y => Int64(100), :z => Int64(42)),
        :running,
        Dict{Int64,Int64}(100 => Int64(7)))
    s_before = deepcopy(s)

    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:x] == 7                   # x got old M[100]
    @test !haskey(s2.locals, :z)               # z destroyed
    @test s2.locals[:y] == 100                 # y untouched (just read for address)
    @test s2.memory[100] == 42                 # M[100] := z's old value
    @test s2.pc == 1

    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "MemoryInterchange with zero-init address (M2.12)" begin
    # M[y] starts UNSET. Forward writes z's value; x receives 0.
    # Inverse must restore the unset (no key) state.
    instr = BennettVM.MemoryInterchange(:x, :y, :z)
    s = BennettVM.IState(0,
        Dict(:y => Int64(999), :z => Int64(77)),
        :running)   # no memory entry at 999
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:x] == 0                   # zero-init read
    @test s2.memory[999] == 77
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test !haskey(s3.memory, 999)              # zero-init delete on inverse
    @test s3 == s_before
end

@testset "MemoryInterchange with literal address (M2.12)" begin
    instr = BennettVM.MemoryInterchange(:x, Int64(50), :z)
    s = BennettVM.IState(0, Dict(:z => Int64(11)), :running,
                          Dict{Int64,Int64}(50 => Int64(99)))
    s_before = deepcopy(s)
    s2 = BennettVM.forward(instr, s)
    @test s2.locals[:x] == 99
    @test s2.memory[50] == 11
    s3 = BennettVM.inverse(instr, s2, nothing)
    @test s3 == s_before
end

@testset "MemoryInterchange constructor validation (M2.12)" begin
    @test_throws ErrorException BennettVM.MemoryInterchange(:x, :y, :x)   # target === source
    @test_throws ErrorException BennettVM.MemoryInterchange(:x, :x, :z)   # addr shadows target
    @test_throws ErrorException BennettVM.MemoryInterchange(:x, :z, :z)   # addr shadows source
    # literal address: target===source still rejected
    @test_throws ErrorException BennettVM.MemoryInterchange(:x, Int64(5), :x)
    # legal cases
    @test BennettVM.MemoryInterchange(:x, :y, :z) isa BennettVM.MemoryInterchange
    @test BennettVM.MemoryInterchange(:x, Int64(5), :z) isa BennettVM.MemoryInterchange
end

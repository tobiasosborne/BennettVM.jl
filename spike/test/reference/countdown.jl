# test/reference/countdown.jl — golden-master reference for the
# countdown program. PRD v3 §5.4.1, CLAUDE.md P0.5.
#
# This is the *irreversible* Julia transliteration of the bytecode
# program in `test_countdown.jl`'s `countdown(n)` factory. The
# bytecode VM's forward execution must agree bit-for-bit with this
# reference (Rule 4: every test asserts against a known-correct
# value). The reference is the oracle; the spike is being verified
# against the reference.
#
# Tested-files: spike/src/Interpreter.jl, spike/src/Instructions.jl
# Produces: a Dict{Symbol,Int64} matching the locals dict at halt.

using BennettVMSpike

"""
    countdown(n_init::Integer) -> Program

Build the canonical 8-instruction countdown bytecode program (the
Pass-2R-accepted form). Halts at pc=5.

  pc=1  Const(:n, n_init)               # n  := n_init
  pc=2  Const(:zero, 0)                  # zero := 0
  pc=3  BinaryOp(:gt, :cond, :n, :zero)  # cond := n > zero (loop test)
  pc=4  JumpIf(:cond, 6)                 # if cond goto pc=6 else fall through
  pc=5  Halt()                           # terminate
  pc=6  Const(:one, 1)                   # one := 1
  pc=7  BinaryOp(:sub, :n, :n, :one)     # n   := n - one
  pc=8  Jump(3)                          # goto loop test

The factory lives next to its irreversible-Julia oracle so any
edit to one immediately calls the other into review.
"""
function countdown(n_init::Integer)
    Program(AbstractInstruction[
        Const(:n, Int64(n_init)),
        Const(:zero, 0),
        BinaryOp(:gt, :cond, :n, :zero),
        JumpIf(:cond, 6),
        Halt(),
        Const(:one, 1),
        BinaryOp(:sub, :n, :n, :one),
        Jump(3),
    ])
end

"""
    countdown_reference(n::Integer) -> Dict{Symbol,Int64}

Plain irreversible Julia implementation of the countdown bytecode
program in `test_countdown.jl`. At halt:

  * `:n` has been decremented to 0.
  * `:zero` is 0 (the loop-bound constant).
  * `:one` is 1 (the decrement constant); absent if n == 0.
  * `:cond` is the most recent loop-test outcome:
      - for n == 0: 0 (loop body never executed).
      - for n >= 1: 0 (last test, which exits the loop).

Note that `:one` is only ever defined when the loop body executes
at least once. The bytecode program agrees: for n == 0, control
goes Const(:n,0); Const(:zero,0); BinaryOp(:gt,...); JumpIf(:cond,6)
[falls through]; Halt — Const(:one, 1) is never reached.
"""
function countdown_reference(n::Integer)
    locals = Dict{Symbol,Int64}()
    locals[:n] = Int64(n)        # pc=1
    locals[:zero] = Int64(0)     # pc=2
    while true
        locals[:cond] = Int64(locals[:n] > locals[:zero])   # pc=3
        if locals[:cond] == 0    # pc=4: JumpIf falls through on false
            break                # pc=5: Halt
        end
        locals[:one] = Int64(1)  # pc=6
        locals[:n] = locals[:n] - locals[:one]  # pc=7
        # pc=8: Jump back to pc=3
    end
    return locals
end

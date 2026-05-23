# test/reference/property_programs.jl — bounded random programs
# plus their reference irreversible Julia executors. PRD v3 §5.4.2.
#
# Design: **straight-line random programs**. No jumps, no conditionals.
# The instruction sequence is:
#
#   1. A prelude of `Const` instructions initialising every variable
#      in the pool (`:a, :b, :c`) to a small random Int64. This is the
#      only way to read a variable safely — `Move`/`UnaryOp`/`BinaryOp`
#      on an unset key raises `KeyError` (Interpreter.jl Q2.5,
#      Instructions.jl Move/UnaryOp/BinaryOp comments).
#   2. A body of `max_len - 4` random `Const`/`Move`/`UnaryOp`/
#      `BinaryOp` instructions, with arguments drawn only from the
#      pool that has already been initialised.
#   3. A terminating `Halt`.
#
# Termination is trivial: the program has no jumps, so the pc
# advances monotonically and `run!` terminates in ≤ length(prog) steps.
# Therefore a sane `max_steps=200` (with len ≤ 20) is impossible to
# trip, and the round-trip test cannot hang on a malformed program.
#
# Tested-files: spike/src/Interpreter.jl, spike/src/Instructions.jl
# Used-by: test/test_roundtrip.jl, test/test_history.jl (indirectly).

using Random
using BennettVMSpike

const VAR_POOL = (:a, :b, :c)

const BINARY_OPS = (:add, :sub, :mul, :and, :or, :xor, :lt, :gt, :eq)
const UNARY_OPS  = (:neg, :not)

"""
    random_bounded_program(rng; max_len=20, max_vars=3) -> Program

A straight-line bytecode program. Length is between `4 + max_vars` and
`max_len`. Always terminated by a `Halt`. Variables come from the
fixed pool `(:a, :b, :c)` truncated to `max_vars`.

The body draws uniformly from `Const`, `Move`, `UnaryOp`, `BinaryOp`.
By construction every read targets a variable that the prelude (or an
earlier body `Const`) has already written, so no `KeyError` can fire.
"""
function random_bounded_program(rng::AbstractRNG; max_len::Int=20, max_vars::Int=3)
    @assert 1 <= max_vars <= length(VAR_POOL)
    @assert max_len >= max_vars + 1   # room for prelude + Halt
    vars = VAR_POOL[1:max_vars]

    body_len = rand(rng, (max_vars + 1):max_len) - max_vars - 1
    # body_len ∈ 0 : (max_len - max_vars - 1)

    instrs = AbstractInstruction[]
    # Prelude: initialise every variable to a random small Int.
    for v in vars
        push!(instrs, Const(v, Int64(rand(rng, -8:8))))
    end
    # Body: random Const / Move / UnaryOp / BinaryOp; no jumps.
    for _ in 1:body_len
        kind = rand(rng, 1:4)
        if kind == 1
            push!(instrs, Const(rand(rng, vars), Int64(rand(rng, -8:8))))
        elseif kind == 2
            dst = rand(rng, vars); src = rand(rng, vars)
            push!(instrs, Move(dst, src))
        elseif kind == 3
            push!(instrs, UnaryOp(rand(rng, UNARY_OPS),
                                  rand(rng, vars), rand(rng, vars)))
        else
            push!(instrs, BinaryOp(rand(rng, BINARY_OPS),
                                   rand(rng, vars), rand(rng, vars),
                                   rand(rng, vars)))
        end
    end
    push!(instrs, Halt())
    return Program(instrs)
end

# Reference application of one instruction onto a plain Dict.
# Bit-for-bit mirror of `forward` in src/Instructions.jl — that is
# the whole point of the oracle (Rule 4, P0.5).
_apply_unary_ref(op, x) =
    op === :neg ? -x :
    op === :not ? ~x :
    error("ref unary: :$op")

function _apply_binary_ref(op, a, b)
    op === :add ? a + b :
    op === :sub ? a - b :
    op === :mul ? a * b :
    op === :and ? a & b :
    op === :or  ? a | b :
    op === :xor ? xor(a, b) :
    op === :lt  ? Int64(a < b) :
    op === :gt  ? Int64(a > b) :
    op === :eq  ? Int64(a == b) :
    error("ref binary: :$op")
end

"""
    program_reference(prog::Program) -> Dict{Symbol,Int64}

Run the straight-line program in plain Julia, returning the locals
at the final `Halt`. The VM's `result(run!(initial_state(prog), prog))`
must equal this Dict.
"""
function program_reference(prog::Program)
    locals = Dict{Symbol,Int64}()
    for instr in prog.instructions
        if instr isa Const
            locals[instr.reg] = instr.val
        elseif instr isa Move
            locals[instr.dst] = locals[instr.src]
        elseif instr isa UnaryOp
            locals[instr.dst] = _apply_unary_ref(instr.op, locals[instr.src])
        elseif instr isa BinaryOp
            locals[instr.dst] = _apply_binary_ref(instr.op, locals[instr.a], locals[instr.b])
        elseif instr isa Halt
            break
        else
            error("program_reference: unsupported instruction $(typeof(instr))")
        end
    end
    return locals
end

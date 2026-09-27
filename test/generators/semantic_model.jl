# test/generators/semantic_model.jl — `bennettvm-tghl`: the INDEPENDENT
# forward-semantics oracle for the M8 seeded random-program gate
# (`test/test_property_roundtrip.jl`).
#
# # Why this file exists (Astra VM-ingest F16)
#
# The M8.5 property gate checked run → unrun round-trips and per-step
# inverses, but never asked the VM's forward step to be CORRECT. A VM
# that computes a deterministic-but-wrong answer and reverses that
# wrong answer faithfully satisfies every check the gate made. The
# review demonstrated it by mutation: a synthetic program whose oracle
# is 11 and whose VM result is 2 was accepted by the real
# `_full_roundtrip!` (`reviews/2026-09-26-astra/VM-ingest.verification.md`
# §F16: `known wrong result=2 oracle=11` / `property helper
# accepted=true`).
#
# CLAUDE.md Rule 4 states the invariant this file restores: every test
# asserts against a known-correct value, and for a forward run the
# known-correct value is an oracle, not the code under test. PRD v4
# §3.14's golden-master leg is the same requirement.
#
# # Why the oracle is a *description*, not a re-run of the VM
#
# The generator (`test/generators/random_program.jl`) now emits, beside
# each `VMProgram`, a `SemDesc`: a plain-Julia description of what the
# program MEANS — its input register names, the sequence of arithmetic
# / memory updates in each arm, which arm the predicate selects, and
# which name the program returns. `sem_eval` interprets that description
# with a register file and a memory dict it owns itself.
#
# The description deliberately does NOT mirror VM IR naming: the
# conditional shape's arms run under VM-side entry-parameter names
# (`:x0_t` / `:x0_f`) that exist only because of the interpreter's
# cross-block `_bind_args_to_params!` rename, so the description names
# the SOURCE-level input (`:x0`) on both arms. The two artefacts are
# built from the same rng draw but share no evaluation path, which is
# the whole point: a bug in `_apply_binop`, in a `forward`, in the
# cross-block rename or in the branch predicate shows up as a mismatch
# instead of cancelling out.
#
# # Independence is structural, not a promise
#
# This file does not `using BennettVM` and calls no VM function — not
# `forward`, not `step!`, not `_apply_binop`, not `_resolve`. It is
# plain `Int64` arithmetic plus a `Dict{Symbol,Int64}` / `Dict{Int64,
# Int64}` state, and it would load and run with the VM package absent.
# `test/test_tghl_forward_oracle.jl` additionally mutation-proves the
# oracle is load-bearing (a wrong `_apply_binop` turns the gate RED).
#
# # The op table: LLVM `i`w`` semantics, written out
#
# `sem_binop(op, a, b, w)` is the i`w` model documented in ADR 0012
# §D2 and R1, implemented here in the *unsigned-view* style: every
# operand is first reduced to its low `w` bits (`sem_mask`), which is
# the i`w` UNSIGNED value, and every result is masked back to `w` bits.
# The signed arms sign-extend first (`sem_sext`). The split is
# per-operation and is the load-bearing part:
#
#   * sign-agnostic — `:add :sub :mul :and :or :xor :shl` (two's
#     complement low bits do not depend on interpretation),
#   * unsigned-interpreting — `:udiv :urem :lshr` (operands are
#     already the non-negative i`w` value, so the arithmetic IS the
#     unsigned arithmetic),
#   * signed-interpreting — `:sdiv :srem :ashr` (operands sign-extended
#     to i64 first),
#   * predicates — `:eq :ne` compare low bits; `:ult :ule :ugt :uge`
#     compare the unsigned view; `:slt :sle :sgt :sge` compare the
#     sign-extended view. Each yields `Int64(0)`/`Int64(1)`, never
#     masked (an i1 is 0 or 1).
#
# `w == 64` is the identity case (`sem_mask(64) == typemax(Int64)`,
# `sem_sext` returns its argument), which is the width the M8
# generator's programs run at. The narrow-width arms are exercised for
# real by the exhaustive `Int8` oracle in the test file.
#
# # Poison inputs: shift amount ≥ `w`, and i`w`-typemin ÷ -1
#
# Both are LLVM poison. The model is deterministic and loud on them:
# a shift by ≥ `w` yields `0` (or the sign fill, for `:ashr`) and
# division / remainder by `0` RAISES `DivideError` — the same failure
# native Julia (and the VM) produces, so a program that hits it fails
# loudly in both rather than being compared against invented numbers.
# `i8`-typemin ÷ -1 is the one input the test's exhaustive oracle
# cannot express at all (native Julia throws `DivideError` there, LLVM
# calls it poison); it is excluded from the sweep and recorded here as
# a decision. The generator's palette (`:xor :and :or` over literal
# operands) reaches none of the three.
#
# # The memory model: zero-init, representation-free comparison
#
# `sem_eval` reads an unwritten cell as `Int64(0)` — the zero-init
# convention of `src/ir/IState.jl` — and keeps a cell at its computed
# value whether or not that value is `0`. The VM's own dict may or may
# not carry a key whose value is `0` (the delete-on-zero rule in
# `src/ir/memory_instructions.jl` is a REPRESENTATION choice for the
# same value). `sem_check` therefore compares both sides through the
# same zero-init accessor over the UNION of the two address sets, so
# "absent" and "present with value 0" are indistinguishable and no
# representation detail leaks into the gate.
#
# `sem_eval` also does not delete a destroyed SSA source. The gate
# compares (a) the values the program DECLARES it returns and (b) the
# cells it touched — never the whole register file — because the
# interpreter's register file legitimately carries stale names (the
# cross-block rename is non-destructive by design since ADR 0022 /
# `bennettvm-rnhv`). Asserting the full dict would pin an
# implementation detail and hide the real signal.
#
# # Ref
#
#   * `reviews/2026-09-26-astra/VM-ingest.md` F16 and
#     `VM-ingest.verification.md` §F16 — the executed evidence this
#     file answers.
#   * `bennettvm-tghl` — this bead.
#   * `docs/adr/0012-collatz-lowering.md` §D2 (predicate semantics,
#     i1 → Int64) and R1 (per-`width` masking; `bennettvm-bgc`) — the
#     specification the op table implements, written from the ADR and
#     the LLVM `i`w`` definitions rather than from `src/`'s code.
#   * `src/ir/IState.jl` — the zero-init memory convention
#     `sem_eval` mirrors.
#   * `docs/adr/0022-phi-edge-binding.md` — why the register file's
#     shape is not an observable.
#   * CLAUDE.md Rule 1 (fail loud, never a plausible wrong answer),
#     Rule 4 (assert against a known-correct value), Rule 10 (≤200 LOC
#     excluding docstrings), Rule 11 (literate docstring).

# ---------------------------------------------------------------------
# 1. Width discipline (model-local; no VM helper is consulted)
# ---------------------------------------------------------------------

"""
    sem_mask(w::Int) -> Int64

The low-`w`-bit mask: `2^w - 1`, or all-ones at `w == 64` so that
64-bit calls are byte-identical to unmasked `Int64` arithmetic.
"""
function sem_mask(w::Int)
    (1 ≤ w ≤ 64) || error("sem_mask: width $w outside 1:64")
    return w == 64 ? typemax(Int64) : (Int64(1) << w) - Int64(1)
end

"""
    sem_sext(v::Int64, w::Int) -> Int64

The i`w` → i64 SIGN extension of `v`: reduce to its low `w` bits, then
subtract `2^w` when the top of those bits is set. Identity at
`w == 64`.
"""
function sem_sext(v::Int64, w::Int)
    w == 64 && return v
    m   = sem_mask(w)
    low = v & m
    return low - (((low >> (w - 1)) & Int64(1)) * (m + Int64(1)))
end

# ---------------------------------------------------------------------
# 2. The op table
# ---------------------------------------------------------------------

"""
    sem_binop(op::Symbol, a::Int64, b::Int64, w::Int = 64) -> Int64

Evaluate the i`w` binary operator `op` on `a` and `b`. `op` is an
integer opcode (`:add … :srem`) or an integer-comparison predicate
(`:eq … :sge`); predicates return `Int64(0)` / `Int64(1)`.

An unrecognised `op` raises: the generator palette and the model's
vocabulary must be kept in step, and a silently-skipped operation
would make the oracle agree with a wrong VM (Rule 1). Division and
remainder by zero raise `DivideError`, as native Julia does.
"""
function sem_binop(op::Symbol, a::Int64, b::Int64, w::Int = 64)::Int64
    m  = sem_mask(w)
    ua = a & m          # i`w` UNSIGNED value of `a` (never negative)
    ub = b & m          # i`w` UNSIGNED value of `b`
    # -- sign-agnostic family -------------------------------------------
    op === :add && return (ua + ub) & m
    op === :sub && return (ua - ub) & m
    op === :mul && return (ua * ub) & m
    op === :and && return (ua & ub) & m
    op === :or  && return (ua | ub) & m
    op === :xor && return (ua ⊻ ub) & m
    op === :shl && return (ub >= w) ? Int64(0) : (ua << ub) & m
    # -- unsigned-interpreting family -----------------------------------
    # `ua` / `ub` are already the non-negative i`w` values, so the
    # arithmetic below IS the unsigned arithmetic — no reinterpret.
    op === :lshr && return (ua >> ub) & m        # ua ≥ 0 ⇒ logical shift
    op === :udiv && return div(ua, ub) & m
    op === :urem && return rem(ua, ub) & m
    # -- signed-interpreting family -------------------------------------
    sa, sb = sem_sext(a, w), sem_sext(b, w)
    op === :sdiv && return div(sa, sb) & m
    op === :srem && return rem(sa, sb) & m
    op === :ashr && return ((ub >= w) ? (sa < 0 ? Int64(-1) : Int64(0)) :
                                      ((sa >> ub) & m)) & m
    # -- predicates ------------------------------------------------------
    op === :eq  && return Int64(ua == ub)
    op === :ne  && return Int64(ua != ub)
    op === :ult && return Int64(ua <  ub)
    op === :ule && return Int64(ua <= ub)
    op === :ugt && return Int64(ua >  ub)
    op === :uge && return Int64(ua >= ub)
    op === :slt && return Int64(sa <  sb)
    op === :sle && return Int64(sa <= sb)
    op === :sgt && return Int64(sa >  sb)
    op === :sge && return Int64(sa >= sb)
    error("sem_binop (bennettvm-tghl): unknown op :", op,
          "; the model's vocabulary is out of step with the generator — ",
          "refusing to guess (a skipped operation would make the oracle ",
          "agree with a wrong VM)")
end

"""
    sem_modop(m::Symbol, y::Int64, e::Int64) -> Int64

The modification operator `y ⊕ e` for `m ∈ (:xor, :add, :sub)`. Any
other `m` raises (Rule 1).
"""
function sem_modop(m::Symbol, y::Int64, e::Int64)::Int64
    m === :xor && return y ⊻ e
    m === :add && return y + e
    m === :sub && return y - e
    error("sem_modop (bennettvm-tghl): unknown modop :", m,
          "; refusing to guess (Rule 1)")
end

# ---------------------------------------------------------------------
# 3. The description vocabulary
# ---------------------------------------------------------------------

"""
    SemOp

One step of a `SemDesc`, in SOURCE-level terms. Four shapes, one per
stepping form the M8 generator emits; a new generator instruction
needs a new `SemOp` subtype here, and `sem_eval` raises until it has
one.
"""
abstract type SemOp end

# `nxt := src ⊕ (a op b)` — destructive register update.
struct SemArith <: SemOp
    nxt::Symbol
    src::Symbol
    modop::Symbol      # :xor | :add | :sub
    a::Int64
    op::Symbol
    b::Int64
end

# `M[addr] ⊕ (a op b)` — destructive cell update, no register effect.
struct SemMemAssign <: SemOp
    addr::Int64
    modop::Symbol
    a::Int64
    op::Symbol
    b::Int64
end

# `nxt := M[addr] := src` — cell/register exchange.
struct SemMemExchg <: SemOp
    nxt::Symbol
    addr::Int64
    src::Symbol
end

# `M[addr1] <-> M[addr2]` — cell/cell exchange (self-inverse).
struct SemMemSwap <: SemOp
    addr1::Int64
    addr2::Int64
end

"""
    SemDesc

A complete source-level description of one generated program:
`kind` (`:linear` / `:looping` / `:conditional`, for diagnostics),
`predicate` (the input name whose nonzero-ness selects the arm —
`nothing` when the program is unconditional), `arms` (`arms[1]` is
taken when the predicate is `nothing` or nonzero, `arms[2]` when it is
zero), `output` (the name the program returns) and `width` (the
register-file bit width, 64 for the M8 generator).
"""
struct SemDesc
    kind::Symbol
    predicate::Union{Nothing,Symbol}
    arms::Vector{Vector{SemOp}}
    output::Symbol
    width::Int
end

# ---------------------------------------------------------------------
# 4. The evaluator
# ---------------------------------------------------------------------

"""
    sem_eval(desc::SemDesc, inputs::Dict{Symbol,Int64})
        -> (registers = Dict{Symbol,Int64}, memory = Dict{Int64,Int64},
            arm_taken = Bool)

Interpret `desc` on `inputs` with a model-owned register file and
memory dict, and return the produced values, the cells written, and
which arm ran.

Unbound register reads, an unknown `SemOp` subtype and an unknown
`modop` all raise with the offending step named (Rule 1: never return
a plausible-looking wrong answer).
"""
function sem_eval(desc::SemDesc, inputs::Dict{Symbol,Int64})
    regs = Dict{Symbol,Int64}(k => Int64(v) for (k, v) in inputs)
    mem  = Dict{Int64,Int64}()
    w    = desc.width
    arm_taken = desc.predicate === nothing ? true : (regs[desc.predicate] != 0)
    for (i, op) in enumerate(desc.arms[arm_taken ? 1 : 2])
        _sem_step!(regs, mem, op, w, desc, i, arm_taken)
    end
    return (registers = regs, memory = mem, arm_taken = arm_taken)
end

# One description step. Split out of `sem_eval` so every error message
# can name the step index without repeating the dispatch.
function _sem_step!(regs, mem, op::SemOp, w::Int, desc::SemDesc,
                    i::Int, arm_taken::Bool)
    if op isa SemArith
        y = _sem_get(regs, op.src, desc, op, i, arm_taken)
        regs[op.nxt] = sem_modop(op.modop, y, sem_binop(op.op, op.a, op.b, w))
    elseif op isa SemMemAssign
        e = sem_binop(op.op, op.a, op.b, w)
        mem[op.addr] = sem_modop(op.modop, get(mem, op.addr, Int64(0)), e)
    elseif op isa SemMemExchg
        # `nxt := M[addr] := src`: save the old cell BEFORE overwriting
        # it, exactly as the VM's `forward(::MemoryInterchange)` does.
        old = get(mem, op.addr, Int64(0))
        mem[op.addr] = _sem_get(regs, op.src, desc, op, i, arm_taken)
        regs[op.nxt] = old
    elseif op isa SemMemSwap
        # `M[addr1] <-> M[addr2]`: both reads before either write.
        va = get(mem, op.addr1, Int64(0))
        vb = get(mem, op.addr2, Int64(0))
        mem[op.addr1], mem[op.addr2] = vb, va
    else
        error("sem_eval (bennettvm-tghl): no model for description op ",
              typeof(op), " at step $i of the ",
              arm_taken ? "taken" : "zero", " arm — add a SemOp subtype and ",
              "a _sem_step! arm before letting the generator emit it")
    end
    return nothing
end

# Register read that fails loud and names the symbol and the step.
function _sem_get(regs, name::Symbol, desc::SemDesc, op, i::Int,
                  arm_taken::Bool)
    haskey(regs, name) && return regs[name]
    error("sem_eval (bennettvm-tghl): unbound register :", name,
          " at step $i of the ", arm_taken ? "taken" : "zero", " arm of the ",
          desc.kind, " description. Known registers: ",
          sort!(collect(keys(regs))), ". Either the description does not ",
          "match the inputs it is evaluated on, or a description step ",
          "reads a value no earlier step produced.")
end

# ---------------------------------------------------------------------
# 5. The comparison (the oracle's load-bearing half)
# ---------------------------------------------------------------------

"""
    sem_check(outcome, returns::Vector{Symbol},
              actual_registers, actual_memory; label) -> Nothing

Compare a `sem_eval` outcome against what the VM actually produced, and
raise — naming every mismatch — if they differ. This is the forward leg
of the property gate: it runs BEFORE any reversal, so a wrong forward
result cannot be cancelled out by a faithful reverse.

`actual_registers` is the VM's halted register file and
`actual_memory` its memory dict; both are read through the zero-init
accessor, so an absent key and a `0` are the same observable. Only the
names in `returns` (the program's declared outputs) are compared — the
register file's shape is an interpreter representation detail
(ADR 0022), not part of the program's meaning.
"""
function sem_check(outcome, returns::Vector{Symbol},
                   actual_registers, actual_memory;
                   label::AbstractString = "sem_check")
    bad = String[]
    for name in returns
        want = get(outcome.registers, name, nothing)
        got  = get(actual_registers, name, nothing)
        want === nothing &&
            push!(bad, "register :$name is not produced by the " *
                       "description, so the gate has no oracle for it")
        (want === nothing || want == got) && continue
        push!(bad, "register :$name: expected $want, got $got")
    end
    for addr in sort!(collect(union(keys(outcome.memory),
                                    keys(actual_memory))))
        want = get(outcome.memory, addr, Int64(0))
        got  = get(actual_memory, addr, Int64(0))
        want == got ||
            push!(bad, "memory[$addr]: expected $want, got $got")
    end
    isempty(bad) && return nothing
    error("[$label] forward result disagrees with the independent ",
          "semantic model (bennettvm-tghl): ", length(bad),
          " mismatch(es) — ", join(bad, "; "), ". The VM's forward step ",
          "computes something the description does not say it computes.")
end

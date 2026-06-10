"""
    SoftCall (M_FP.2 / ADR 0011 §D1, ADR 0012 §D1 template)

The reversible **SoftFloat-dispatch SSA-create**: it materialises a
fresh SSA name by calling one of Bennett.jl's `soft_f*` IEEE-754
primitives on integer bit-patterns that are *read but not destroyed*.
This is the lowering target for LLVM `IRCall` (`call @j_soft_fadd`,
`call @j_soft_fmul`, …) — the floating-point body-instruction gap
(`docs/coverage-matrix.md` row 13, the M_FP P1 gap). A Float64 program
arrives at BennettVM as an integer program over `UInt64` bit-patterns,
every Float64 op being an `IRCall` to a registered `soft_f*` callee
(ADR 0011 §D1, §"Ground truth" Finding 1).

    dest := callee_name(args...)     # args READ, never destroyed
    callee_name ∈ {:soft_fadd, :soft_fmul, …}  (the _SOFT_DISPATCH keys)

# Why a dedicated `SoftCall`, distinct from every existing instruction

A `soft_f*` call is a **non-destructive SSA-create over integer
bit-patterns** — `dest := f(args...)`, with `args` surviving in
`locals` for later instructions in the same iteration. That shape is
semantically a `Define` / `CastInstruction` (the non-destructive
create), NOT any of:

  * **`ArithmeticAssignment`** (M2.6, `src/ir/arithmetic_assignment.jl`)
    — a *destructive transform* `x := y ⊕ (lhs op rhs)` that DELETES
    its `source`. A SoftFloat call has no source to consume; its inputs
    are surviving live values, and it has a variadic arity (`soft_fma`
    takes three operands) the binary `ArithmeticAssignment` cannot
    express. The `operators.jl` `FP_BINARY_OPERATORS` docstring's
    aspirational "lower to ArithmeticAssignment" note is *imprecise*:
    that form would (a) destroy an operand and (b) cap arity at two and
    (c) lose the conversion ops (`soft_fpext` / `soft_sitofp`) that are
    unary width/signedness casts, not binary arithmetic. We reject it
    per ADR 0012 §D1's reasoning, exactly as `Define` rejected
    `assignWithoutDestroy`.

  * **`CallInstruction`** (M2.14, `src/ir/call_instruction.jl`) — the
    RSSA *reversible-subroutine* call `(x,…) := call/uncall l(y,…)`,
    whose body is a VM routine reversed by uncalling. A `soft_f*` is an
    OPAQUE black-box host primitive (a compiled SoftFloat function),
    not a reversible VM subroutine; it has no `:call`/`:uncall`
    direction and no in-VM body to uncall. Reusing `CallInstruction`
    would wrongly promise structural reversibility.

So `SoftCall` is its own struct following the `Define` /
`CastInstruction` L3-create template: own `forward`, own
`is_injective(::Type{SoftCall}) = false`, a deferred raising `inverse`.

# Language-neutral: store the callee NAME (Symbol), not the Function

`callee_name::Symbol` (e.g. `:soft_fadd`), NOT the Julia `Function`
object. This mirrors ADR 0013's `callee_name::Symbol` direction and
keeps `SoftCall` serialisable and language-neutral: the VM instruction
records *which* IEEE-754 primitive to call by name, and the forward
executor resolves the name through the module-level `_SOFT_DISPATCH`
registry to the actual Bennett.jl host function. The registry doubles
as the **allowlist**: an unknown `callee_name` is a Rule-1 fail-loud
error (an arbitrary host call is not a recognised reversible-by-replay
SoftFloat primitive — see the constructor and `forward`).

# Forward semantics — integer bit-patterns through SoftFloat

`IState.locals` are `Int64`, but the `soft_f*` functions take/return
*unsigned* bit-patterns (`soft_fadd(a::UInt64, b::UInt64)::UInt64`;
`soft_fpext(a::UInt32)::UInt64`; `soft_fptrunc(a::UInt64)::UInt32`).
The Float64 bit-pattern of e.g. `2.0` is `0x4000000000000000`, which as
an `Int64` is `4611686018427387904` (positive here, but a bit-pattern
with the sign bit set — any negative double — would be a *negative*
`Int64`). `forward` therefore:

  1. Resolves each arg from `active_locals(s)` (or a literal `Int64`).
  2. **Reinterprets** the stored `Int64` to the unsigned type of the
     arg's `arg_widths[i]` (32 → `UInt32`, 64 → `UInt64`) via a
     mask-then-`%`-unsigned, so a sign-extended-on-arrival `Int64`
     yields the correct low-`w`-bit unsigned value the soft function
     expects (Rule 1 fail-safe: mask before reinterpreting).
  3. Calls the registered soft function with those unsigned args.
  4. **Reinterprets the unsigned result back to `Int64`**, masked to
     `ret_width` (32 → low-32-bit zero-extended into the `Int64` slot;
     64 → the full bit-pattern reinterpreted), and stores it in
     `active_locals(s)[dest]`.

The mask-and-reinterpret is the one place width matters (the same
`_low_mask` discipline `CastInstruction` uses): the rest of the VM
treats the value as an opaque `Int64` bit-pattern flowing between
`soft_f*` calls until a `soft_fptosi` / `soft_fptrunc` converts it out.

# is_injective = false (conservative) — and L3-ONLY reversal

FP operations are generally **not invertible from the result alone**
(`soft_fadd(a,b)` does not determine `a` and `b`; `soft_fmul` by a
non-unit loses bits to rounding; `soft_fptrunc` is lossy by
construction). Moreover, in a loop the same SSA `dest` is redefined
every iteration, so a `SoftCall` may OVERWRITE a prior value (the
cross-iteration crux shared with `Define` / `CastInstruction` /
`MemoryLoad`, ADR 0012). The static type-level trait cannot see runtime
freshness and cannot recover the discarded information, so per Rule 1
("fail safe — push when in doubt") it is conservatively `false` (wired
in `src/history/Injective.jl`).

`SoftCall` therefore reverses EXCLUSIVELY via **L3 checkpoint-replay**
(`src/history/Replay.jl`): the M6.2/M7.6 push gate emits L3
`CheckpointEntry`s around it, and `unstep!` restores the nearest full
`IState` snapshot and replays forward — never calling per-instruction
`inverse()`. There is NO `make_delta` and NO `predelta_payload` for
`SoftCall` (it inherits the raising / `nothing` defaults from
`history/delta.jl`, so `is_l2_capable(SoftCall) == false` and
`compute_must_cache` never selects it for an L2 delta). Its
per-instruction `inverse()` raises descriptively (the `Define` /
`CastInstruction` deferral pattern) rather than silently no-op'ing
(which would falsely report a successful reverse while the lost FP
information went unrestored — silent reversibility corruption, Rule 1).

# Float32 (ADR 0011 §D2) — inherited rejection, ENFORCED at ingest

Float32 is rejected upstream in Bennett.jl (double-rounding through
`soft_fpext → f64-op → soft_fptrunc` is NOT bit-exact, Bennett-3rph).
BennettVM inherits the rejection through a TWO-LAYER upstream barrier —
`_SUPPORTED_SCALAR_ARGS` (no Float32 entry type) and the per-intrinsic
`w == 64` guards in the FP-intrinsic lowering (the fcmp/conversion arms
lack one, but the SoftFloat wrapper keeps accepted f64 IR f32-free) — so a
pure-Float64 program (the SC10 gate) never emits an f32-touching soft op at all.

As of bead `bennettvm-h0t` (M_FP.5) the rejection is ALSO **ENFORCED at
the BennettVM ingest boundary** as the belt-and-suspenders mirror: the
`IRCall` arm of `_lower_body_inst` (`src/ir/ingest.jl`) rejects any soft
op that *touches f32* — `ret_width == 32 || any(==(32), arg_widths)` —
which catches `soft_fptrunc` (f64→f32, ret 32), `soft_fpext` (f32→f64,
arg 32), and any f32-operand soft op. This is unreachable-by-construction
on accepted f64 IR (per the upstream barrier above), so it fires only if a
mixed-precision `.ll` reaches ingest. It does NOT over-reject any legal
f64→intN conversion: that is emitted upstream with `ret_width == 64` plus
a separate `IRCast(:trunc, 64→32)`, so the SoftCall keeps width 64
(`../Bennett.jl/src/extract/instructions.jl:2322-2345`).

The `SoftCall` DATA TYPE deliberately still supports the f32 widths (the
constructor accepts `ret_width`/`arg_widths` ∈ {32, 64}): `test_softcall.jl`
constructs `soft_fpext` / `soft_fptrunc` SoftCalls directly to unit-test
the dispatch mechanism. Only the accepted-program *ingest boundary*
rejects f32, never the constructor.

# Constructor validation (Rule 1)

The constructor rejects: an unknown `callee_name` (not in
`_SOFT_DISPATCH` — an arbitrary host call is not a SoftFloat
primitive); a `dest` that also appears among `args` (RSSA
single-assignment — an SSA name cannot be both defined and read by the
same instruction); a `length(args) != length(arg_widths)` mismatch
(mirrors `IRCall`'s own check, Bennett.jl `ir_types.jl:219`); an
`arg_widths[i]` or `ret_width` outside `1..64` (`IState.locals` are
`Int64`); and a `width ∉ {32, 64}` (the only two SoftFloat operand
widths — f32 carried as `UInt32`, f64 as `UInt64`; a soft_f* call with
a 17-bit operand is malformed IR).

# pc symmetry

`forward` sets `s.pc += 1`, matching every M2.x instruction. There is
no symmetric `inverse` pc decrement — the inverse is the L3 replay
path, not a per-step `inverse()` call; the deferred `inverse` raises
before touching `pc`.

# Ref

  * `docs/adr/0011-fp-inheritance.md` §D1 (inherit SoftFloat wholesale;
    Float64 as UInt64 bit-patterns; every FP op an IRCall to soft_f*),
    §D2 (Float32 rejection), §"Ground truth" Finding 1 (the dispatch
    mechanism), Finding 2 (60 exported soft_* primitives).
  * `docs/adr/0012-collatz-lowering.md` §D1 + §"cross-iteration
    reversibility crux" — the dedicated-create + non-injective +
    deferred-inverse design this file mirrors from `Define`.
  * `../Bennett.jl/src/ir_types.jl:206-237` — the `IRCall` struct
    (`dest` / `callee::Function` / `args` / `arg_widths` / `ret_width`)
    this lowers. Field shapes verified against the live type.
  * `../Bennett.jl/src/callees.jl:17-19` (`_CALLEES_FP_BINARY`:
    soft_fadd/fsub/fmul/fdiv/fma), `:22-24` (`_CALLEES_FP_UNARY`:
    soft_fneg/fsqrt), `:64-66` (`_CALLEES_FP_CONV`:
    soft_fpext/fptrunc/fptosi/fptoui/sitofp) — the callee groups whose
    `nameof` populate `_SOFT_DISPATCH`.
  * `../Bennett.jl/src/softfloat/softfloat.jl:53-69` — the
    `SoftFloatLib` export block (the soft_* surface), re-exported into
    `Bennett` (`../Bennett.jl/src/Bennett.jl:24` `using .SoftFloatLib`,
    `:79` re-export). Signatures verified: `soft_fadd(::UInt64,
    ::UInt64)::UInt64`, `soft_fpext(::UInt32)::UInt64`,
    `soft_fptrunc(::UInt64)::UInt32`, `soft_sitofp(::UInt64)::UInt64`.
  * `src/ir/define_instruction.jl` / `src/ir/cast_instruction.jl` — the
    SSA-create templates this file follows.
  * `src/ir/arithmetic_assignment.jl` — `_resolve`, reused here (Law 2).
  * `src/history/Injective.jl` — where `is_injective(::Type{SoftCall})
    = false` is wired.
  * `src/history/Replay.jl` — the L3 checkpoint-replay `unstep!` that
    actually reverses a `SoftCall`.
  * CLAUDE.md Laws 1 & 2, Rule 1 (fail loud), Rule 11 (literate).
"""

# ---------------------------------------------------------------------
# The SoftFloat dispatch registry / allowlist (built once at load time).
# ---------------------------------------------------------------------
#
# Keyed by the callee NAME (`nameof(f)`, a `Symbol`) → the host
# `soft_f*` function. Populated from Bennett.jl's FP callee groups
# (`../Bennett.jl/src/callees.jl`) so the BennettVM allowlist tracks the
# upstream SoftFloat surface declaratively (Law 2 — reuse Bennett's
# grouping, do not re-list the names): adding a soft_* callee upstream
# and to the matching group makes it resolvable here on the next load
# with no edit. We pull the four FP groups that lower to a non-
# destructive create over UInt32/UInt64 bit-patterns:
#
#   * arithmetic (fadd/fsub/fmul/fdiv/fma) — `_CALLEES_FP_BINARY`
#   * unary (fneg/fsqrt)                   — `_CALLEES_FP_UNARY`
#   * rounding (floor/ceil/trunc/round…)   — `_CALLEES_FP_ROUND`
#   * conversion (fpext/fptrunc/fptosi/    — `_CALLEES_FP_CONV`
#     fptoui/sitofp)
#
# The transcendental / cmp / min-max / mux-exch / persistent groups are
# deliberately EXCLUDED at M_FP.2: `soft_fcmp_*` return i1 and route to a
# different VM shape (a `Define`-carried predicate, not an SSA bit-
# pattern); the transcendentals are a wider surface deferred past the
# SC10 polynomial gate; the mux-exch / persistent callees are memory
# primitives, not scalar FP. They can be folded in by adding their group
# to `_SOFT_DISPATCH_GROUPS` once their VM lowering is specified — the
# narrow allowlist is the Rule-1 fail-loud boundary, not an accident.
const _SOFT_DISPATCH_GROUPS = (
    Bennett._CALLEES_FP_BINARY,
    Bennett._CALLEES_FP_UNARY,
    Bennett._CALLEES_FP_ROUND,
    Bennett._CALLEES_FP_CONV,
)

const _SOFT_DISPATCH = let d = Dict{Symbol,Function}()
    for group in _SOFT_DISPATCH_GROUPS, f in group
        d[nameof(f)] = f
    end
    d
end

# The two legal SoftFloat operand/result bit-widths: f32 carried as a
# UInt32, f64 as a UInt64. Any other width on a soft_f* call is malformed
# IR (Rule 1). A tuple (membership is a two-element scan).
const _SOFT_WIDTHS = (32, 64)

struct SoftCall <: Instruction
    dest::Symbol
    callee_name::Symbol               # ∈ keys(_SOFT_DISPATCH)
    args::Vector{Union{Symbol,Int64}}
    arg_widths::Vector{Int}
    ret_width::Int

    function SoftCall(dest::Symbol, callee_name::Symbol,
                      args::AbstractVector{<:Union{Symbol,Int64}},
                      arg_widths::AbstractVector{<:Integer},
                      ret_width::Integer)
        haskey(_SOFT_DISPATCH, callee_name) ||
            error("SoftCall: unknown callee_name :", callee_name,
                  " (dest=", dest, ") — not a recognised SoftFloat ",
                  "primitive. The allowlist (built from Bennett.jl's ",
                  "_CALLEES_FP_BINARY / _UNARY / _ROUND / _CONV groups, ",
                  "src/callees.jl) is the Rule-1 fail-loud boundary: an ",
                  "arbitrary host call is not reversible-by-replay. Known: ",
                  sort!(collect(keys(_SOFT_DISPATCH))), ".")
        length(args) == length(arg_widths) ||
            error("SoftCall: length(args)=", length(args),
                  " != length(arg_widths)=", length(arg_widths),
                  " (dest=", dest, ", callee=", callee_name, ") — mirrors ",
                  "IRCall's own arity check (Bennett.jl ir_types.jl:219).")
        1 <= ret_width <= 64 ||
            error("SoftCall: ret_width=", ret_width, " out of range 1..64 ",
                  "(dest=", dest, ", callee=", callee_name,
                  "; IState.locals are Int64).")
        ret_width in _SOFT_WIDTHS ||
            error("SoftCall: ret_width=", ret_width, " must be one of ",
                  _SOFT_WIDTHS, " (f32 carried as UInt32 / f64 as UInt64; ",
                  "dest=", dest, ", callee=", callee_name, ").")
        for (i, w) in enumerate(arg_widths)
            1 <= w <= 64 ||
                error("SoftCall: arg_widths[", i, "]=", w, " out of range ",
                      "1..64 (dest=", dest, ", callee=", callee_name, ").")
            w in _SOFT_WIDTHS ||
                error("SoftCall: arg_widths[", i, "]=", w, " must be one of ",
                      _SOFT_WIDTHS, " (f32/f64 only; dest=", dest,
                      ", callee=", callee_name, ").")
        end
        for a in args
            a === dest &&
                error("SoftCall: SSA single-assignment violation — dest ",
                      dest, " also appears among args; an SSA name cannot ",
                      "be both defined and read by the same instruction ",
                      "(RSSA: every name has exactly one defining ",
                      "instruction).")
        end
        return new(dest, callee_name,
                   convert(Vector{Union{Symbol,Int64}}, args),
                   convert(Vector{Int}, arg_widths), Int(ret_width))
    end
end

# Reinterpret a stored `Int64` value to the unsigned bit-pattern of
# width `w` (32 → UInt32, 64 → UInt64). Mask to the low `w` bits FIRST
# (a sign-extended-on-arrival negative Int64 would otherwise carry
# spurious high bits past the soft function's width) — Rule 1 fail-safe,
# the same `_low_mask` discipline `CastInstruction._apply_cast` uses.
# `_low_mask` is defined in `cast_instruction.jl` (included earlier).
function _to_soft_unsigned(v::Int64, w::Int)
    masked = v & _low_mask(w)
    return w == 32 ? (masked % UInt32) : (masked % UInt64)
end

# Reinterpret an unsigned `soft_f*` result back to the `Int64` `locals`
# slot, masked to `ret_width` (32 → the low 32 bits zero-extended into
# the Int64; 64 → the full 64-bit pattern as an Int64, sign bit and
# all). The result is an opaque bit-pattern; downstream soft_f* calls
# re-extract the width they need.
function _from_soft_unsigned(u::Unsigned, w::Int)::Int64
    return w == 32 ? Int64(u % UInt32) : ((u % UInt64) % Int64)
end

"""
    forward(instr::SoftCall, s::IState) -> IState

Execute `dest := callee_name(args...)` in-place on `s`. Resolves each
arg against `active_locals(s)` (or uses the literal `Int64`) via the reused
`_resolve`, reinterprets each to its `arg_widths[i]` unsigned bit-
pattern, calls the registered `soft_f*` host function, reinterprets the
unsigned result back to `Int64` masked to `ret_width`, writes it into
`active_locals(s)[dest]`, and bumps `pc`. The args are **read, never deleted**
— the non-destructive create property (contrast `ArithmeticAssignment.
forward`, which `delete!`s its `source`).

If `dest` already exists in `active_locals(s)` (the loop / cross-iteration
case), it is **overwritten** without error — reversibility of the
overwrite (and of the lossy FP op) is the L3 checkpoint-replay layer's
responsibility (see this file's top-of-module docstring). The `callee_
name` is re-validated against `_SOFT_DISPATCH` here (belt-and-
suspenders Rule 1: the constructor already guaranteed it, but a
hand-mutated instance must not silently call an arbitrary function).
"""
function forward(instr::SoftCall, s::IState)::IState
    f = get(_SOFT_DISPATCH, instr.callee_name, nothing)
    f === nothing &&
        error("SoftCall.forward: callee_name :", instr.callee_name,
              " is not in the SoftFloat dispatch registry (dest=",
              instr.dest, ") — should be impossible after the constructor ",
              "check; a hand-mutated SoftCall reached forward (Rule 1).")
    uargs = Any[_to_soft_unsigned(_resolve(instr.args[i], s),
                                  instr.arg_widths[i])
                for i in eachindex(instr.args)]
    u = f(uargs...)
    active_locals(s)[instr.dest] = _from_soft_unsigned(u, instr.ret_width)
    s.pc += 1
    return s
end

"""
    inverse(instr::SoftCall, s::IState, prev) -> IState

**Always raises `ErrorException`.** `SoftCall`'s reverse is via the L3
checkpoint-replay layer (`src/history/Replay.jl`), which never calls
per-instruction `inverse()`. Direct L1/L2 inverse is deferred:
`soft_f*` ops are generally not locally invertible (the result does not
determine the operands; rounding/truncation lose bits), and a loop
re-definition of any op loses the overwritten prior `dest`. Reaching
this method means `unstep!` tried an L1/L2 path on a `SoftCall`, which
should not happen — `SoftCall` is not L2-capable (`is_l2_capable ==
false`, the raising `make_delta` / `nothing` `predelta_payload`
defaults), so `compute_must_cache` never selects it. This mirrors the
`Define` / `CastInstruction` / `CallInstruction` deferral pattern.
Rule 1: fail loud rather than silently no-op (which would falsely
report a successful reverse while the lost FP information went
unrestored).
"""
function inverse(instr::SoftCall, s::IState, prev)::IState
    error("SoftCall reverse is via L3 checkpoint-replay at M_FP.2; ",
          "direct L1/L2 inverse is deferred (ADR 0011 §D1, ADR 0012 R3) — ",
          "soft_f* ops are generally not locally invertible (rounding / ",
          "truncation lose bits; the result does not determine the ",
          "operands) and a loop re-definition loses the overwritten prior ",
          "dest. Reaching this means unstep! tried an L1/L2 path on a ",
          "SoftCall, which should not happen (not l2-capable). callee=",
          instr.callee_name, ", dest=", instr.dest, ", pc=", s.pc, ".")
end

"""
Instructions.jl — The eight concrete bytecodes of the Phase-0 spike.

Each instruction is a tiny immutable struct subtyping
`AbstractInstruction`, paired with one `forward` method (post-step
`IState`) and one `inverse` method. In Phase 0 every `inverse` is a
single line: `return prev`. The pre-step snapshot pushed by the
interpreter (`step!`, see Interpreter.jl) is by construction the
exact inverse image of the step, regardless of how lossy the forward
operation was. This is the wasteful end of the Bennett time-space
trade-off curve (PRD v3 §3.3) and the spike exists to confirm we
hate it (CLAUDE.md P0.7).

Ground truth (per PHASE.md user override, 2026-05-23, Bennett-1973
PDF is off-disk; substitute sources only):

  * `references/foundational/vitanyi-time-space-energy.pdf` §2 — the
    three-tape construction restated: "the new 6-tuple rules have the
    effect that the machine keeps a record on the auxiliary history
    tape consisting of the sequence of quadruples executed". Our
    history-tape entry is the full `IState` snapshot; the per-step
    "quadruple" record degenerates to "the entire pre-state",
    which is strictly more than enough to invert any of the eight
    instructions below.

  * `references/foundational/Bennett1989_time_space_tradeoffs.pdf`
    §1–2 Lemma 1 ("Untidy Stage"): each step appends an entry
    sufficient to undo it. The lemma's per-step entry is a
    quintuple index; ours is the full IState. The information
    content of our entry strictly dominates Bennett 1989's, so the
    invertibility argument carries over a fortiori.

  * `references/foundational/buhrman-tromp-vitanyi-2001.pdf` §1 —
    "the auxiliary history tape […] consisting of the sequence of
    quadruples executed on the original tape". Same point, modern
    formalism.

Phase-2 replacements (PRD v3 §3.2, §3.3):

  * **Injective instructions** (Pendulum/PISA, BobISA — Vieri 1995/99,
    Axelsen-Yokoyama 2011): push nothing. `Move` becomes an exchange
    (memory access is always an exchange — Pendulum rule). `UnaryOp`
    becomes self-inverse primitives. The full-snapshot crutch goes
    away for these.
  * **Non-injective instructions**: deltas with Enzyme-style min-cut
    recompute-vs-cache (PRD v3 §3.3). The `inverse(instr, s, prev)`
    signature persists into Phase 2 — `prev` becomes a delta payload
    rather than an `IState`, but the method bodies become genuine
    work.
  * **Reversible control flow** (BobISA, Axelsen-Yokoyama 2011):
    reversible jumps encode the source label, so the predecessor pc
    is recoverable from local state without a history entry. Phase 0
    `Jump`/`JumpIf` carry no such encoding and rely on the snapshot.
  * **Reversible IR** (Mogensen 2016 RSSA): the Phase-2 IR will
    replace this flat bytecode entirely.

Rule 11 (literate). Rule 1 (fail-fast): unsupported op symbols
`error()` with the offending symbol. Rule 10: ≤200 LOC.

P0.4 reminder: eight instructions. Not nine. If a future change
seems to need a ninth, see CLAUDE.md P0.4 — stop and file a retro
item instead.
"""

# Bring the abstract type and forward/inverse generic functions into
# scope so we can subtype and add methods. These are defined in
# BennettVMSpike.jl + Types.jl which `include` this file.

# ──────────────────────────────────────────────────────────────────────
# Helper: copy locals and bump pc. Every non-control-flow instruction
# uses this so the "fresh dict" discipline (Interpreter.jl Q2.2) is
# centralised in one place.
# ──────────────────────────────────────────────────────────────────────
@inline _copy_locals(s::IState) = copy(s.locals)

# ──────────────────────────────────────────────────────────────────────
# 1. Const(reg, val) — write `val` to `reg`.
#    Forward semantics: locals'[reg] = val; pc' = pc+1; status' = status.
#    Pre-state `locals[reg]` (which may be absent) is overwritten;
#    full-snapshot history restores it on inverse. Phase 2 will only
#    permit `Const` on a fresh register (injective) and push nothing.
# ──────────────────────────────────────────────────────────────────────
struct Const <: AbstractInstruction
    reg::Symbol
    val::Int64
end

function forward(instr::Const, s::IState)
    locals = _copy_locals(s)
    locals[instr.reg] = instr.val
    IState(s.pc + 1, locals, s.status)
end

inverse(::Const, ::IState, prev::IState) = prev

# ──────────────────────────────────────────────────────────────────────
# 2. Move(dst, src) — copy locals[src] into locals[dst]. `src`
#    is left untouched (non-exchange semantics). This is information-
#    losing in `dst` and would not be admissible as a Phase-2 injective
#    primitive; Phase 2 will replace this with Pendulum-style
#    `LoadExchange` (PRD v3 §3.2). Reads from missing `src` raise
#    `KeyError` (Rule 1: no silent zero).
# ──────────────────────────────────────────────────────────────────────
struct Move <: AbstractInstruction
    dst::Symbol
    src::Symbol
end

function forward(instr::Move, s::IState)
    locals = _copy_locals(s)
    locals[instr.dst] = locals[instr.src]  # KeyError on missing src
    IState(s.pc + 1, locals, s.status)
end

inverse(::Move, ::IState, prev::IState) = prev

# ──────────────────────────────────────────────────────────────────────
# 3. UnaryOp(op, dst, src) — dst ← op(src).
#    Supported ops:
#      :neg — arithmetic negation (involutory on Int64).
#      :not — *bitwise* complement on Int64 (involutory).
#    The PRD wording "for Bool-typed regs" is moot here: the spike's
#    locals are all Int64 (PRD §5.1; Types.jl). We document the
#    bitwise reading explicitly so retro Q1 can flag it.
#    Both ops are involutions, so a Phase-2 injective-primitive
#    rewrite would push nothing; in Phase 0 we still pay the full
#    snapshot.
# ──────────────────────────────────────────────────────────────────────
struct UnaryOp <: AbstractInstruction
    op::Symbol
    dst::Symbol
    src::Symbol
end

function _apply_unary(op::Symbol, x::Int64)
    op === :neg ? -x :
    op === :not ? ~x :
    error("UnaryOp: unsupported op :$op")
end

function forward(instr::UnaryOp, s::IState)
    locals = _copy_locals(s)
    locals[instr.dst] = _apply_unary(instr.op, locals[instr.src])
    IState(s.pc + 1, locals, s.status)
end

inverse(::UnaryOp, ::IState, prev::IState) = prev

# ──────────────────────────────────────────────────────────────────────
# 4. BinaryOp(op, dst, a, b) — dst ← op(a, b).
#    Supported ops (PRD §5.1): :add :sub :mul :and :or :xor :lt :gt :eq.
#    Comparison ops return Int64 0/1 (no Bool in the locals dict).
#    All of these except :sub and :xor are information-losing in `dst`;
#    Phase 2 will distinguish injective vs non-injective in the ISA
#    classification (PRD §3.2). In Phase 0 every BinaryOp pays the
#    full snapshot uniformly — which is exactly the wasteful baseline
#    the spike is here to feel the cost of.
# ──────────────────────────────────────────────────────────────────────
struct BinaryOp <: AbstractInstruction
    op::Symbol
    dst::Symbol
    a::Symbol
    b::Symbol
end

function _apply_binary(op::Symbol, a::Int64, b::Int64)
    op === :add ? a + b :
    op === :sub ? a - b :
    op === :mul ? a * b :
    op === :and ? a & b :
    op === :or  ? a | b :
    op === :xor ? xor(a, b) :
    op === :lt  ? Int64(a < b) :
    op === :gt  ? Int64(a > b) :
    op === :eq  ? Int64(a == b) :
    error("BinaryOp: unsupported op :$op")
end

function forward(instr::BinaryOp, s::IState)
    locals = _copy_locals(s)
    locals[instr.dst] = _apply_binary(instr.op, locals[instr.a], locals[instr.b])
    IState(s.pc + 1, locals, s.status)
end

inverse(::BinaryOp, ::IState, prev::IState) = prev

# ──────────────────────────────────────────────────────────────────────
# 5. Jump(target) — pc' = target.
#    No locals change; status unchanged. Phase-0 inverse uses the
#    snapshot to restore pc. Phase 2 (BobISA) will encode the source
#    label so the predecessor pc is recoverable locally and no
#    history entry is needed (PRD §3.2).
#    Out-of-range `target` is not checked here; Interpreter.step!
#    catches it on the next dispatch (its pc-range error).
# ──────────────────────────────────────────────────────────────────────
struct Jump <: AbstractInstruction
    target::Int
end

forward(instr::Jump, s::IState) = IState(instr.target, _copy_locals(s), s.status)
inverse(::Jump, ::IState, prev::IState) = prev

# ──────────────────────────────────────────────────────────────────────
# 6. JumpIf(cond, target) — if locals[cond] != 0 then pc' = target
#    else pc' = pc + 1. Truthiness on Int64 is "nonzero", consistent
#    with the comparison ops in BinaryOp returning 0/1.
#    Reads from missing `cond` raise KeyError (Rule 1).
# ──────────────────────────────────────────────────────────────────────
struct JumpIf <: AbstractInstruction
    cond::Symbol
    target::Int
end

function forward(instr::JumpIf, s::IState)
    locals = _copy_locals(s)
    new_pc = locals[instr.cond] != 0 ? instr.target : s.pc + 1
    IState(new_pc, locals, s.status)
end

inverse(::JumpIf, ::IState, prev::IState) = prev

# ──────────────────────────────────────────────────────────────────────
# 7. Return — status ← :halted. pc unchanged.
# 8. Halt   — status ← :halted. pc unchanged.
#
# In Phase 0 these are functionally identical: the spike has no
# subroutines, so a `Return` cannot return *to* anything. We keep
# both types so callers writing PRD §5.1 programs can use the
# semantically-intended one; the interpreter's discard-pop predicate
# (Interpreter.jl Q2.4) means an idempotent status flip with no pc
# or locals change does not retain a history entry — so the
# round-trip invariant is undisturbed by either.
#
# RETRO Q1: are eight instructions actually needed, given Return ≡
# Halt in the spike? See final report.
# ──────────────────────────────────────────────────────────────────────
struct Return <: AbstractInstruction end
struct Halt   <: AbstractInstruction end

forward(::Return, s::IState) = IState(s.pc, _copy_locals(s), :halted)
inverse(::Return, ::IState, prev::IState) = prev

forward(::Halt,   s::IState) = IState(s.pc, _copy_locals(s), :halted)
inverse(::Halt,   ::IState, prev::IState) = prev

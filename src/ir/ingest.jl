"""
    ParsedIR ingest pass (M_UNBOUNDED.1, ADR 0012 §D1–D5)

The real `lower_vm` body: translate a Bennett.jl `ParsedIR` — a CFG of
`IRBasicBlock`s carrying the six `IRInst` types `IRBinOp`, `IRICmp`,
`IRPhi`, `IRSelect`, `IRBranch`, `IRRet` — into a runnable `VMProgram`
of paired-Entry/Exit `BasicBlock`s whose **forward** `run!` reproduces
the irreversible Julia oracle bit-for-bit. This is the keystone of the
collatz vertical slice (bd `bennettvm-c39`, ADR 0012), but it is written
**generically** over the six IRInst types — it is the M_OPCODE
foundation, not a collatz transcription.

# The four sub-problems and how this file solves each

## 1. φ-nodes become block parameters (ADR 0012 §D4, Mogensen RSSA §3)

An `IRPhi(dest, incoming=[(value, pred_label), …])` is NOT a body
instruction — it is a *block parameter* bound on entry. The args→params
positional rename at the M3.6 cross-block-dispatch layer
(`Interpreter.jl:_rename_args_to_params!`) **is** φ-resolution: the φ
at a join "remembers" which predecessor supplied each value because the
predecessor's edge sends exactly that value into the join's param slot.
`_collect_phi_params(block)` gathers each block's `IRPhi.dest`s, in
block order, as that block's entry `params`; `_phi_incoming_for_edge`
reads the matching incoming value for a given predecessor.

## 2. Critical-edge splitting (the load-bearing technique)

A `ConditionalExit` carries ONE `args` list but its two successors are
φ-joins that need DIFFERENT incoming values (collatz: `top`→`L46` sends
`[steps_init]`, `top`→`L8` sends `[steps_init, x]`). The interpreter
cannot send per-target arg lists from a single Exit, so we **split every
branch edge into a trampoline block**. The conditional carries only the
predicate (empty args); each edge `:e_<src>_<dst>` is an
`UnconditionalEntry(:e_src_dst, [])` → `UnconditionalExit(:dst, <that
edge's φ args, in dst's φ-param order>)`. The destination block's entry
then has exactly as many predecessors as it has incoming trampoline
edges. This is the textbook "critical edge split" that classical SSA
back-ends use to place φ-copies; here it lets each edge own its own
arg list. `_edge_label(src, dst)` synthesises the trampoline label.

## 3. Predecessor arity selects the entry marker (ADR 0012 §D4)

A destination block reached by ≥2 trampoline edges is a φ-join and gets
a `ConditionalEntry(label, params, pred_true, pred_false, condition)`;
the two predecessors are the two incoming trampoline labels. A block
reached by exactly one edge gets an `UnconditionalEntry`. The entry
block (`top`) gets a `BeginInstruction(routine, [arg names])`. Under L3
checkpoint-replay (ADR 0012 "cross-iteration crux") backward dispatch
is never taken — `_dispatch_to_block!` does NOT consult a
`ConditionalEntry.condition` on forward arrival — so the `condition`
field is **vestigial** here; we pass any symbol not in `params` to
satisfy the constructor (`ConditionalEntry` rejects `condition ∈ params`).

## 4. Constant φ-incomings need a synthetic create (ADR 0012 §D5, bead e4l)

`*Exit.args::Vector{Symbol}` is symbol-only, but a φ incoming may be a
literal (collatz: `value_phi17`'s incoming from `top` is `Const(0)`;
`value_phi1.lcssa`'s incoming from `top` is `Const(0)`). We materialise
each distinct constant `v` flowing out of a predecessor block with a
synthetic `Define(:_phi_const_<src>_<v>, Int64(v), :add, Int64(0))`
appended to that predecessor's body, and pass the synthetic name as the
edge arg. The `Define` reads two literals (no operand collision) and is
non-injective (so L3 checkpoints around it — harmless, it is a fresh
create).

**Cross-edge sharing vs. within-edge uniqueness (bead e4l, ADR 0012
§D5).** Two *different* out-edges of a predecessor that both send the
same constant `v` SHARE one synthetic name: only one out-edge runs at
runtime, so a single create feeding whichever edge fires is correct, and
sharing keeps the emitted `Define` count (hence the pinned dispatch/step
counts of collatz and matrix_sum) untouched. But a *single* edge
`src → dst` can have TWO distinct φ-param slots both receiving the SAME
constant `v` from `src` (the triangular nested loop's `top →
L7.preheader` edge: `0` flows into both `indvars.iv14` and `value_phi18`,
`1` into both `indvars.iv10` and `value_phi7`). args→params binds
positionally and DESTRUCTIVELY at the trampoline, so one created value
cannot feed two param slots — each slot needs its own create. We
therefore share the by-value name across edges but, within one edge's
arg list, mint a FRESH counter-based name (and an ADDITIONAL `Define` in
`src`'s body) for every repeat occurrence. The `UnconditionalExit`
`allunique(args)` check (`control_instructions.jl`) stays — it is the
correct SSA single-assignment-within-sender invariant; this fix supplies
distinct names rather than relaxing the check.

# Routine framing (ADR 0012 §D4)

The entry block gets `BeginInstruction(routine, [param names from
parsed.args])`; the block holding the `IRRet` gets
`EndInstruction(routine, [ret value name])` as its exit. The ret value
is the lowered `IRRet.op` (an `SSAOperand` whose `.name` is the routine
result). `VMProgram(blocks, LabelTable(blocks), entry_label, arg_widths,
return_widths)` assembles the artifact; `arg_widths` / `return_widths`
preserve the ParsedIR handoff metadata (`parsed.args` widths /
`parsed.ret_elem_widths`).

# Why forward-only correctness is the gate (not round-trip)

ADR 0012's reversibility decision is **trace-tape via L3 checkpoint-
replay**: `Define` / `SelectInstruction` are non-injective, so the
M6.2/M7.6 push gate emits L3 checkpoints around them and `unstep!`
reverses the loop by restoring a snapshot and replaying forward — no
per-instruction inverse needed. The lowering pass therefore only has to
get **forward** semantics right; the round-trip is the interpreter's
job. The forward gate: `run!` on the lowered collatz reproduces the
irreversible oracle bit-for-bit on non-overflowing inputs (ADR 0012 R1).

# Width note (ADR 0012 R1, RESOLVED — bead `bennettvm-bgc`)

`IState.locals` are `Int64`, but the lowering now THREADS the IRInst
`width` field into the `Define` it builds for `IRBinOp` / `IRICmp`, and
`Define.forward` computes the op in i`width` semantics (extract low-`width`
bits, re-extend per the op's signedness, mask the result —
`_apply_binop`'s docstring). Oracle agreement therefore holds for ANY
input, including ones whose trajectory OVERFLOWS the source width (the
golden-master test `test/test_width_masking.jl` pins an overflowing i8
input). The round-trip invariant was already width-independent; masking is
part of the deterministic forward function, so it does not perturb the L3
checkpoint-replay reversal. `width` defaults to 64 in the `Define`
constructor, so the synthetic φ-incoming-constant `Define`s (always 64)
and every hand-built test `Define` are byte-identical (the width-64 no-op).

# Ref

  * `docs/adr/0012-collatz-lowering.md` §D1–D5 (the lowering decisions),
    §"The cross-iteration reversibility crux" (trace-tape / L3).
  * `/home/tobias/Projects/Bennett.jl/src/ir_types.jl` (pin `877341e`) —
    `ParsedIR`, `IRBasicBlock`, the six `IRInst` structs, `SSAOperand` /
    `ConstOperand`. Field names verified against the live dump.
  * `src/ir/define_instruction.jl` (§D1) / `src/ir/select_instruction.jl`
    (§D3) — the create instructions this pass emits.
  * `src/ir/control_instructions.jl` (M2.8–M2.10) — Begin/End,
    Uncond/Cond Entry/Exit; their constructor invariants drive the
    edge-split + entry-marker choices.
  * `src/interpreter/Interpreter.jl` (M3.6) — `_dispatch_to_block!` /
    `_rename_args_to_params!`, the args→params rename that realises
    φ-resolution; backward dispatch (vestigial `condition`) deferred.
  * `references/implementations/RC3/.../BasicBlock.java` — the RSSA
    block / paired-entry-exit shape this targets (Law 2).
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse RSSA), Rule 11 (literate).
"""

# ---------------------------------------------------------------------
# Operand lowering: Bennett IROperand → BennettVM operand (Symbol|Int64).
# ---------------------------------------------------------------------

"""
    _lower_operand(op::Bennett.IROperand) -> Union{Symbol,Int64}

`SSAOperand(name)` → its `name::Symbol`; `ConstOperand(value)` → the
literal coerced to `Int64`. Any other `IROperand` subtype (the extractor
sentinels) is rejected loudly (Rule 1) — none arise in the collatz slice,
and a sentinel reaching here means an unhandled IR shape, not a value.
"""
function _lower_operand(op::Bennett.IROperand)::Union{Symbol,Int64}
    if op isa Bennett.SSAOperand
        return op.name
    elseif op isa Bennett.ConstOperand
        return Int64(op.value)
    else
        error("lower_vm: unsupported IROperand subtype ", typeof(op),
              " — only SSAOperand / ConstOperand are handled in the ",
              "M_UNBOUNDED slice (ADR 0012). A sentinel operand here ",
              "indicates an unhandled IR shape (Rule 1).")
    end
end

"""
    _lower_bool_operand(op, width) -> Union{Symbol,Int64}

Lower a binop operand, masking an i1 (`width == 1`) `ConstOperand` to its low
bit. LLVM renders the i1 literal `true` as the sign-extended `-1`; the unmasked
Int64 VM needs the 1-bit value (`-1 → 1`) so the boolean-NOT idiom `%c ⊻ true`
computes the logical NOT for `%c ∈ {0,1}`. For `width > 1`, or for an SSA
operand, this is identical to `_lower_operand`. See `_lower_body_inst`'s i1 note
(full-width masking — bead `bennettvm-bgc` — now threads `inst.width` into the
`Define`; for `width == 1` the in-op `& mask` collapses to `& 1`, agreeing with
this const-operand mask).
"""
function _lower_bool_operand(op::Bennett.IROperand, width::Int)::Union{Symbol,Int64}
    lowered = _lower_operand(op)
    (width == 1 && lowered isa Int64) ? (lowered & Int64(1)) : lowered
end

# ---------------------------------------------------------------------
# Nondeterminism guard: callees that have NO deterministic forward and so
# can never be reversed by replay (the doubly-fatal class).
# ---------------------------------------------------------------------

# Callee `nameof`s whose result is NOT a deterministic function of the VM
# state — a fresh random draw, a process-/time-/identity-derived value, or
# a pointer-identity hash. The whole L3 reversal mechanism is *periodic
# checkpoint + deterministic forward REPLAY* (ADR 0012; rr's lesson —
# O'Callahan–Huey 2017, "record nondeterminism, replay determinism"). A
# nondeterministic callee breaks the replay leg outright: re-running the
# forward step from a checkpoint would draw a DIFFERENT value, so the
# pre-image is unrecoverable. It is *doubly* fatal here — there is also no
# deterministic forward to begin with, so even plain re-execution diverges
# (docs/opcode-coverage-plan.md "Genuinely impossible", Nondeterminism row:
# "objectid/identity hashing …, rand/RDRAND, pointer-identity. (Doubly
# fatal for reversibility — no replay.)").
#
# Identity-based hashing (`objectid`, `pointer_from_objref`) is the
# specific CLAUDE.md hallucination-callout case: `objectid` is a hash of
# the *runtime allocation address*, not of the value, so it is
# nondeterministic across runs and aliases distinct values that happen to
# share an address slot — the Dict-key-determinism guard (`bennettvm-90l` /
# Bennett-`klgz`) handles the in-program Dict-key surface; THIS guard is the
# ingest-boundary catch for any such callee arriving as a raw `IRCall`.
#
# Bennett.jl's `extract` already refuses these upstream (U14 atomic/volatile,
# U15 inline-asm/opaque-call, U4eu indirectbr) so they never reach a
# `ParsedIR`; this is the belt-and-suspenders defensive MIRROR on the
# BennettVM ingest side, with a SPECIFIC diagnostic (Rule 1) so a future
# regression that lets one through fails loud and *legibly*, not as the
# generic "unknown SoftFloat callee" message.
const _NONDETERMINISTIC_CALLEES = Set{Symbol}((
    :rand, :rand!, :randn, :randexp,                # PRNG draws (hardware
                                                    # RDRAND surfaces as one of
                                                    # these Julia callees, not
                                                    # a bare `rdrand` Function)
    :objectid, :pointer_from_objref,                # identity / pointer hash
    :time, :time_ns, :getpid,                       # wall-clock / process id
))

# ---------------------------------------------------------------------
# Body-instruction translation: the six IRInst types, generically.
# ---------------------------------------------------------------------

"""
    _lower_body_inst(inst::Bennett.IRInst) -> Union{Instruction,Nothing}

Translate one non-terminator `IRInst` to a BennettVM body `Instruction`,
or `nothing` for `IRPhi` (which becomes a block parameter, not a body
instruction — see this file's docstring §1).

  * `IRBinOp(dest, op, op1, op2)`  → `Define(dest, lower(op1), op, lower(op2))`.
  * `IRICmp(dest, predicate, …)`   → `Define(dest, lower(op1), predicate, lower(op2))`
    (the predicate is a valid `_apply_binop` comparison op — ADR 0012 §D2).
  * `IRSelect(dest, cond, op1, op2)`→ `SelectInstruction(dest, cond.name,
    lower(op1), lower(op2))` (cond is an `SSAOperand`, ADR 0012 §D3).
  * `IRCast(dest, op, operand, fw, tw)`→ `CastInstruction(dest, op,
    lower(operand), fw, tw)` (`op ∈ {:sext,:zext,:trunc}`, ADR 0013 §D-5).
  * `IRStore(ptr, val, width)`     → `MemoryStore(ptr.name, lower(val))`
    (the scalar memory floor, ADR 0014 §D2; `ptr` is an `SSAOperand` naming
    an alloca dest — a pointer is an `Int64` address in `locals`). IRStore
    produces NO SSA value (void), so this arm returns a real `Instruction`,
    NOT `nothing` — the caller appends it unconditionally.
  * `IRLoad(dest, ptr, width)`     → `MemoryLoad(dest, ptr.name)` (the scalar
    memory floor, ADR 0014 §D2).
  * `IRVarGEP(dest, base, index, elem_width)` → `VarGEP(dest, base.name,
    lower(index), stride=1)` (the array element-address create, ADR 0009
    Decision 2b). `base` is an `SSAOperand` naming an alloca dest. The cell
    stride is `1` (the VM is CELL-addressed, one `Int64` per cell, so
    `elem_width` (in BITS) does NOT enter the address) — it matches the bump
    allocator's `+N` cursor step. The produced pointer flows unchanged into a
    downstream `MemoryStore` / `MemoryLoad`. `IRVarGEP` produces an SSA value
    (`dest`), so this returns a real `Instruction`, NOT `nothing`.
  * `IRPhi`                         → `nothing` (handled as a param).

`IRAlloca` is NOT handled here — it needs the bump-allocator state threaded
through `_lower_parsed_ir` (ADR 0014 §D1), so it is lowered at the call site,
not in this pure per-instruction dispatch.

Any other `IRInst` subtype is rejected loudly (Rule 1).
"""
function _lower_body_inst(inst::Bennett.IRInst)::Union{Instruction,Nothing}
    if inst isa Bennett.IRBinOp
        # i1 (width==1) boolean algebra: a `ConstOperand` operand of an i1 op
        # is a 1-bit literal, but LLVM renders `true` as the SIGN-EXTENDED `-1`
        # (`xor i1 %c, true` — the boolean-NOT idiom). The cell-addressed VM is
        # unmasked Int64, so `%c ⊻ -1` would yield `-2` (a spurious "true" under
        # the nonzero=true branch convention) instead of the logical NOT. Mask
        # an i1 const operand to its low bit (`& 1`): `-1→1`, `0`/`1` unchanged,
        # so `%c ⊻ 1` is the correct NOT for `%c ∈ {0,1}`. This is the targeted
        # i1-boolean fix the multi-block Julia-O0 CFG needs. (Full per-`width`
        # masking — bead `bennettvm-bgc` — is now done via the `inst.width`
        # threaded into the `Define` below; for a true i1 op `width == 1`, the
        # `_apply_binop` `& mask` collapses to `& 1`, so this const-operand mask
        # and the in-op mask agree.) It is sound because an i1 value is always
        # 0/1 and i1 algebra over {0,1} is exact in Int64.
        return Define(inst.dest, _lower_bool_operand(inst.op1, inst.width),
                      inst.op, _lower_bool_operand(inst.op2, inst.width),
                      inst.width)
    elseif inst isa Bennett.IRICmp
        # IRICmp.width is the OPERAND width (the i1 result is never masked);
        # `_apply_binop` extends the operands per the predicate's signedness
        # at this width, then returns the unmasked 0/1 i1 result (ADR 0012
        # R1 / §D2, bead `bennettvm-bgc`).
        return Define(inst.dest, _lower_operand(inst.op1), inst.predicate,
                      _lower_operand(inst.op2), inst.width)
    elseif inst isa Bennett.IRSelect
        inst.cond isa Bennett.SSAOperand ||
            error("lower_vm: IRSelect cond is ", typeof(inst.cond),
                  " (dest=", inst.dest, "); ADR 0012 §D3 requires an ",
                  "SSAOperand predicate produced by an upstream IRICmp.")
        # op1 is the TRUE arm, op2 the FALSE arm — Bennett.jl pins this
        # (Bennett.jl/src/ir_types.jl:89-93: `op1::IROperand # true value`,
        # `op2::IROperand # false value`), matching LLVM `select i1 c, t, f`
        # and SelectInstruction's `val_true`/`val_false` (ADR 0012 §D3). A
        # swap here would invert collatz's even/odd branch and fail the
        # forward golden-master — so this mapping is also empirically pinned.
        return SelectInstruction(inst.dest, inst.cond.name,
                                 _lower_operand(inst.op1),
                                 _lower_operand(inst.op2))
    elseif inst isa Bennett.IRCast
        # LLVM width cast (sext/zext/trunc) → the non-destructive width-cast
        # SSA-create (ADR 0013 §D-5 step 1). The operand is READ, never
        # destroyed (mirrors Define/SelectInstruction); the per-op bit
        # semantics live in CastInstruction._apply_cast. The op symbol is
        # validated against `_CAST_OPS` by the CastInstruction constructor.
        return CastInstruction(inst.dest, inst.op,
                               _lower_operand(inst.operand),
                               inst.from_width, inst.to_width)
    elseif inst isa Bennett.IRStore
        # LLVM `store value, ptr` → the plain non-injective heap write (ADR
        # 0014 §D2). `ptr` is an SSAOperand naming an alloca dest (a pointer
        # is an Int64 address in `locals`, materialised by the bump allocator
        # — `_lower_alloca!`). IRStore is void (no SSA dest), so this returns
        # a real `Instruction`, not `nothing`. The value may be an SSAOperand
        # or a ConstOperand (LLVM stores constants), handled by `_lower_operand`.
        inst.ptr isa Bennett.SSAOperand ||
            error("lower_vm: IRStore ptr is ", typeof(inst.ptr),
                  " — the memory floor (ADR 0014 §D1) requires an SSAOperand ",
                  "pointer naming an alloca dest or a GEP create (a pointer is ",
                  "an Int64 address in locals; IRVarGEP / IRPtrOffset both ",
                  "produce an SSAOperand-named pointer). A non-SSA ptr means a ",
                  "malformed store (Rule 1 fail-loud).")
        return MemoryStore(inst.ptr.name, _lower_operand(inst.val))
    elseif inst isa Bennett.IRLoad
        # LLVM `dest = load ptr` → the plain non-injective heap read (ADR
        # 0014 §D2). `ptr` is an SSAOperand naming an alloca dest. Zero-init
        # convention: a load of a never-stored address reads as 0
        # (`MemoryLoad.forward`).
        inst.ptr isa Bennett.SSAOperand ||
            error("lower_vm: IRLoad ptr is ", typeof(inst.ptr),
                  " (dest=", inst.dest, ") — the memory floor (ADR 0014 §D1) ",
                  "requires an SSAOperand pointer naming an alloca dest or a ",
                  "GEP create (a pointer is an Int64 address in locals; ",
                  "IRVarGEP / IRPtrOffset both produce an SSAOperand-named ",
                  "pointer). A non-SSA ptr means a malformed load (Rule 1 ",
                  "fail-loud).")
        return MemoryLoad(inst.dest, inst.ptr.name)
    elseif inst isa Bennett.IRVarGEP
        # LLVM `getelementptr` → the runtime element-address create (ADR 0009
        # Decision 2b, SC9 Case A Unit 1). `dest := base + index*stride`,
        # stride in CELLS. `base` is an SSAOperand naming an alloca dest (a
        # pointer is an Int64 cell address in `locals`, materialised by the
        # bump allocator — `_lower_alloca!`). `index` is the 0-based element
        # index (a runtime SSAOperand or an LLVM constant index), lowered via
        # `_lower_operand`. The VM is CELL-addressed (one Int64 per cell), and
        # the bump allocator reserves one cell per element, so the cell stride
        # is `1` REGARDLESS of `inst.elem_width` (which is in BITS and does NOT
        # enter the address) — it matches `_lower_alloca!`'s `+N` cursor step
        # so `gep(arr, i)` lands on the cell the alloca reserved for element i
        # (see `src/ir/array_index.jl` "stride is in cells"). The produced
        # pointer flows unchanged into a downstream MemoryStore / MemoryLoad
        # (whose `resolve_ptr` accepts any Int64 ptr value — no store/load
        # change, Law 2). The `dest` SSA value is the produced pointer, so this
        # returns a real `Instruction`, not `nothing`.
        inst.base isa Bennett.SSAOperand ||
            error("lower_vm: IRVarGEP base is ", typeof(inst.base),
                  " (dest=", inst.dest, ") — the array floor (ADR 0009 ",
                  "Decision 2b) requires an SSAOperand base naming an alloca ",
                  "dest (a pointer is an Int64 cell address in locals). A ",
                  "non-SSA base means a malformed or unsupported GEP shape ",
                  "(Rule 1 fail-loud).")
        return VarGEP(inst.dest, inst.base.name,
                      _lower_operand(inst.index), Int64(1))
    elseif inst isa Bennett.IRCall
        # LLVM `call @j_soft_f*` → the SoftFloat-dispatch SSA-create (ADR
        # 0011 §D1; M_FP.2, bead `bennettvm-8ox`). A Float64 program arrives
        # at BennettVM as an INTEGER program over UInt64 bit-patterns, every
        # FP op being an `IRCall` to a registered `soft_f*` callee — BennettVM
        # inherits Bennett.jl's bit-exact SoftFloat dispatch wholesale and
        # writes NO FP-reversibility code of its own (ADR 0011 D1). The callee
        # is stored language-neutrally as `nameof(inst.callee)` (a Symbol),
        # NOT the Function (ADR 0013 callee_name direction); the SoftCall
        # constructor validates it against the `_SOFT_DISPATCH` allowlist
        # (built from Bennett.jl's FP callee groups). A NON-soft callee (a
        # general host call) is NOT a recognised reversible-by-replay
        # primitive — the SoftCall constructor's `haskey(_SOFT_DISPATCH, …)`
        # check FAILS LOUD on it (Rule 1), so this arm does not silently
        # accept an arbitrary `IRCall`. The args are READ, never destroyed —
        # the non-destructive create property (the `Define` template, NOT the
        # destructive `ArithmeticAssignment`; NOT the RSSA reversible-
        # subroutine `CallInstruction`, a soft_f* being an opaque host
        # primitive). Operands may be SSA refs or LLVM constants, handled by
        # `_lower_operand`. arg_widths / ret_width carry the f32(UInt32) /
        # f64(UInt64) bit-width metadata `SoftCall.forward` reinterprets with.
        # Float32 (the double-rounding case, ADR 0011 D2) is rejected upstream
        # in Bennett.jl (two-layer barrier: `_SUPPORTED_SCALAR_ARGS` + the
        # per-intrinsic `w==64` FP-intrinsic guards) AND, as the belt-and-
        # suspenders BennettVM mirror, ENFORCED at this ingest boundary by the
        # f32-touching guard below (bead `bennettvm-h0t`): any soft op with a
        # 32-bit result or operand is rejected. A pure-Float64 program (the SC10
        # gate) emits none, so the guard is unreachable-by-construction on
        # accepted f64 IR; it fires only if a mixed-precision `.ll` arrives.
        #
        # Nondeterminism guard (bead `bennettvm-0kl`, F1): a genuinely
        # nondeterministic callee (rand / RDRAND / objectid / time / getpid …)
        # has NO deterministic forward, so the L3 checkpoint-REPLAY reversal
        # cannot recover its pre-image — it is doubly fatal for reversibility
        # (docs/opcode-coverage-plan.md "Genuinely impossible", Nondeterminism
        # row). Reject it HERE with a SPECIFIC Rule-1 diagnostic, BEFORE the
        # `SoftCall` constructor, so it does not fall through to the generic
        # "unknown SoftFloat callee" message (which would misdescribe the
        # cause). A soft_f* callee is not in `_NONDETERMINISTIC_CALLEES`, so
        # the soft path is unaffected; a non-soft, non-nondeterministic callee
        # still reaches the SoftCall allowlist reject below.
        if nameof(inst.callee) in _NONDETERMINISTIC_CALLEES
            error("lower_vm: IRCall to nondeterministic callee :",
                  nameof(inst.callee), " (dest=", inst.dest, ") cannot be ",
                  "ingested — it has no deterministic forward, so the L3 ",
                  "checkpoint-replay reversal (ADR 0012; rr's record-",
                  "nondeterminism/replay-determinism lesson) cannot recover ",
                  "its pre-image. This is DOUBLY FATAL for reversibility: no ",
                  "deterministic forward AND no replay (docs/opcode-coverage-",
                  "plan.md \"Genuinely impossible\", Nondeterminism row). ",
                  "Rejected callees: ", sort!(collect(_NONDETERMINISTIC_CALLEES)),
                  " (Rule 1 fail-loud).")
        end
        # Float32-touching soft op guard (bead `bennettvm-h0t`; ADR 0011 §D2,
        # Bennett-3rph). A soft op "touches f32" iff its result OR any operand
        # is 32-bit (`ret_width == 32 || any(==(32), arg_widths)`). This catches
        # exactly the double-rounding surface: `soft_fptrunc` (f64→f32, ret 32),
        # `soft_fpext` (f32→f64, arg 32), and any f32-OPERAND soft op. f32
        # arithmetic in mixed-precision IR is routed `soft_fpext → f64-op →
        # soft_fptrunc`, which DOUBLE-ROUNDS (rounds once at the f64 op, again at
        # the f32 mantissa boundary) and is therefore NOT bit-exact against
        # hardware f32 — a correctness defect, not a performance tradeoff (ADR
        # 0011 §D2; `../Bennett.jl/src/softfloat/fpconv.jl:1-37`; CLAUDE.md
        # rule 13). The bit-exact contract extends only to Float64.
        #
        # An ACCEPTED pure-Float64 program (the SC10 gate) emits NONE of these:
        # the SoftFloat wrapper carries f64 as UInt64 and yields integer-only IR
        # over 64-bit bit-patterns, and Bennett.jl rejects f32 at TWO upstream
        # barriers — `_SUPPORTED_SCALAR_ARGS` (no Float32 entry type) and the
        # per-intrinsic `w == 64` guards in the FP-intrinsic lowering. So this
        # guard is UNREACHABLE-BY-CONSTRUCTION on any accepted f64 program; it
        # is the fail-loud belt-and-suspenders if a MIXED-PRECISION `.ll` (the
        # `.bc` route) ever delivers an f32-touching soft op to ingest.
        #
        # No legitimate f64→intN conversion is over-rejected: a `fptosi`/`fptoui`
        # to a narrow width (e.g. f64→i32) is emitted upstream as an `IRCall`
        # with `ret_width = 64` PLUS a SEPARATE `IRCast(:trunc, 64→32)` — the
        # SoftCall keeps `ret_width = 64` and `arg_widths = [64]`, never a
        # 32-width soft op (`../Bennett.jl/src/extract/instructions.jl:2322-2345`,
        # verified). The guard fires ONLY on a genuine f32 width, never on a
        # legal f64 op nor on the f64-side of a conversion.
        #
        # Placed at INGEST (not the SoftCall constructor): `test/test_softcall.jl`
        # constructs `soft_fpext` / `soft_fptrunc` SoftCalls DIRECTLY to unit-test
        # the dispatch mechanism, and the SoftCall data type must keep supporting
        # the f32 widths for those tests (only the accepted-program ingest
        # BOUNDARY rejects them). See `src/ir/softcall_instruction.jl` §"Float32".
        if inst.ret_width == 32 || any(==(32), inst.arg_widths)
            error("lower_vm: IRCall to soft op :", nameof(inst.callee),
                  " (dest=", inst.dest, ") touches Float32 (ret_width=",
                  inst.ret_width, ", arg_widths=", inst.arg_widths, ") — ",
                  "REJECTED at the BennettVM ingest boundary (ADR 0011 §D2, ",
                  "Bennett-3rph). f32 arithmetic routes soft_fpext → f64-op → ",
                  "soft_fptrunc, which DOUBLE-ROUNDS and is NOT bit-exact ",
                  "against hardware f32; BennettVM's bit-exact contract extends ",
                  "only to Float64. An accepted pure-Float64 program (the SC10 ",
                  "gate) emits no f32-touching soft op (the SoftFloat wrapper ",
                  "yields integer-only f64 IR; Bennett.jl rejects f32 at ",
                  "_SUPPORTED_SCALAR_ARGS + the per-intrinsic w==64 guards), so ",
                  "this is unreachable-by-construction on accepted f64 IR — it ",
                  "fails loud only if a mixed-precision `.ll` reaches ingest ",
                  "(Rule 1 fail-loud).")
        end
        return SoftCall(inst.dest, nameof(inst.callee),
                        Union{Symbol,Int64}[_lower_operand(a)
                                            for a in inst.args],
                        inst.arg_widths, inst.ret_width)
    elseif inst isa Bennett.IRMapInsert
        # Bennett.jl `IRMapInsert(key, value)` → the VM-side reversible-map
        # insert (`src/ir/revmap.jl`; ADR 0008; SC9 Case B). The Dict is an
        # OPAQUE `RevMap` register — BennettVM does NOT model its hash-table
        # memory (contrast IRStore/IRVarGEP element traffic); the front-end
        # `mem=:vm` recogniser already dropped the Dict GC alloc + frame
        # skeleton and emitted this language-neutral op (ADR 0013 §D-3). The
        # Bennett-side struct field order is the logical (key, value) — the
        # value-before-key permutation of the Julia `setindex!(d, v, k)` callee
        # is un-done by the recogniser, NOT here. v1 RevMap is `Dict{Int64,
        # Int64}`, so key/value lower to `Union{Symbol,Int64}` via
        # `_lower_operand`; per-`width` masking is the documented follow-on
        # (bead `bennettvm-bgc`), and in-range i8 values (fdict's 3,7) store /
        # round-trip exactly without it. IRMapInsert is void (no SSA dest), so
        # this returns a real `Instruction`, not `nothing`.
        return IRMapInsert(_lower_operand(inst.key), _lower_operand(inst.value))
    elseif inst isa Bennett.IRMapGet
        # Bennett.jl `IRMapGet(dest, key)` → the VM-side reversible-map read
        # (`src/ir/revmap.jl`; ADR 0008 Finding 4). `dest` is the SSA name the
        # map value flows into (the MemoryLoad-style L3-reversed create — its
        # SSA dest is non-injective on a loop re-definition). The key lowers via
        # `_lower_operand`.
        return IRMapGet(inst.dest, _lower_operand(inst.key))
    elseif inst isa Bennett.IRMapDelete
        # Bennett.jl `IRMapDelete(key)` → the VM-side reversible-map delete
        # (`src/ir/revmap.jl`; ADR 0008 Finding 4, with the senior-grade
        # missing-sentinel hardening for absent-key delete). Void (no SSA dest).
        return IRMapDelete(_lower_operand(inst.key))
    elseif inst isa Bennett.IRExtractValue
        # RELOCATED to the body loop (bead `bennettvm-acq`, Rule 1/2 fix). The
        # aggregate-membership guard (`agg.name ∈ agg_dests`) needs the routine-
        # scope `agg_dests` registry, which is NOT visible from this pure per-
        # instruction dispatch — only from the body loop in `_lower_parsed_ir`,
        # where `IRExtractValue` (alongside `IRInsertValue`) is now handled. So
        # `extractvalue` must NOT reach here. If it does, the body loop missed a
        # branch — fail loud rather than emit an unguarded slot read (Rule 1).
        error("lower_vm: IRExtractValue reached _lower_body_inst (dest=",
              inst.dest, ") — it is handled in the body loop of ",
              "`_lower_parsed_ir` (where `agg_dests` is in scope for the ",
              "aggregate-membership guard), NOT here. Reaching this arm means ",
              "the body-loop branch was bypassed; that is a wiring bug (bead ",
              "`bennettvm-acq`, Rule 1 fail-loud).")
    elseif inst isa Bennett.IRPtrOffset
        # Cell-addressed STATIC GEP (ADR 0009 Decision 2b; bead bennettvm-b5x).
        # `IRPtrOffset(dest, base, offset_bytes, elem_width)` is a constant-
        # offset pointer create: `dest := base + element_index`. A pointer is an
        # Int64 CELL address in `locals`, and the bump allocator reserves one
        # cell per ELEMENT (VarGEP stride 1), so the cell offset is the ELEMENT
        # INDEX, not the byte offset. Bennett.jl stores the offset in BYTES
        # (`offset_bytes`, the circuit-backend unit) plus the source element bit
        # width (`elem_width`, the additive Bennett-xv0u field); the element
        # index is `offset_bytes ÷ (elem_width ÷ 8)`. This MIRRORS the IRVarGEP
        # arm above (`VarGEP(..., stride=1)`) for the constant-index case — both
        # land `dest` on the cell the alloca reserved for element `index`. The
        # produced pointer flows unchanged into a downstream MemoryStore /
        # MemoryLoad (no store/load change, Law 2). Returns a real `Instruction`.
        #
        # BVM only ingests `mem=:vm` ParsedIR, whose IRPtrOffset sites (the
        # integer-source constant-index GEP and vector-load lane offsets) store
        # TRUE BYTE offsets, so the `÷` is exact. Sub-element / struct offsets
        # (non-even division) are out of scope (BG3 / U16): fail loud rather than
        # silently misaddress (Rule 1, Rule 2 — never paper over).
        inst.base isa Bennett.SSAOperand ||
            error("lower_vm: IRPtrOffset base is ", typeof(inst.base),
                  " (dest=", inst.dest, ") — the array floor (ADR 0009 ",
                  "Decision 2b) requires an SSAOperand base naming an alloca ",
                  "dest (a pointer is an Int64 cell address in locals). A ",
                  "non-SSA base means a malformed or unsupported GEP shape ",
                  "(Rule 1 fail-loud).")
        ew_bits = inst.elem_width
        (ew_bits >= 8 && ew_bits % 8 == 0) ||
            error("lower_vm: IRPtrOffset elem_width=", ew_bits, " (dest=",
                  inst.dest, ") is not a whole positive byte count — cannot ",
                  "recover an element index from the byte offset (ADR 0009 ",
                  "Decision 2b; bead bennettvm-b5x, field Bennett-xv0u). ",
                  "Rule 1 fail-loud.")
        ew_bytes = ew_bits ÷ 8
        inst.offset_bytes >= 0 ||
            error("lower_vm: IRPtrOffset offset_bytes=", inst.offset_bytes,
                  " (dest=", inst.dest, ") is negative — a GEP below the alloca ",
                  "base is malformed under mem=:vm (no production site emits a ",
                  "negative offset; Rule 1 fail-loud rather than misaddress).")
        inst.offset_bytes % ew_bytes == 0 ||
            error("lower_vm: IRPtrOffset offset_bytes=", inst.offset_bytes,
                  " (dest=", inst.dest, ") is not evenly divisible by the ",
                  "element byte width ", ew_bytes, " (elem_width=", ew_bits,
                  " bits) — a sub-element / struct offset is out of scope ",
                  "(BG3 / U16). The cell-addressed VM addresses whole ",
                  "elements only; fail loud rather than silently misaddress ",
                  "(Rule 1, Rule 2).")
        return Define(inst.dest, inst.base.name, :add,
                      Int64(inst.offset_bytes ÷ ew_bytes))
    elseif inst isa Bennett.IRPhi
        return nothing   # φ → block parameter; not a body instruction.
    else
        error("lower_vm: unsupported IRInst body subtype ", typeof(inst),
              " — the slice handles IRBinOp / IRICmp / IRSelect / IRPhi ",
              "(ADR 0012), IRCast (ADR 0013 §D-5), IRStore / IRLoad (the ",
              "scalar memory floor, ADR 0014 §D2), IRVarGEP (the array ",
              "element-address create, ADR 0009 Decision 2b), IRCall to a ",
              "soft_f* callee (the SoftFloat-dispatch create, ADR 0011 §D1), ",
              "IRMapInsert / IRMapGet / IRMapDelete (the reversible-map ",
              "ops, ADR 0008 / 0013 §D-3, SC9 Case B), and IRExtractValue / ",
              "IRInsertValue (the ArrayType aggregate slot model, bead ",
              "`bennettvm-acq`; BOTH are lowered at the call site — insert ",
              "emits N slot Defines, and extract needs the `agg_dests` registry ",
              "for its aggregate-membership guard, in scope only there), and ",
              "IRPtrOffset (the cell-addressed STATIC GEP, ADR 0009 Decision ",
              "2b, bead bennettvm-b5x). ",
              "IRAlloca is lowered at the ",
              "call site via the bump allocator (ADR 0014 §D1). (Rule 1.)")
    end
end

"""
    _lower_alloca!(inst::Bennett.IRAlloca, next_addr::Int64, saw_dynamic::Bool)
        -> Tuple{Instruction, Int64, Bool}

Lower one `IRAlloca(dest, elem_width, n_elems)` via the bump allocator
(ADR 0014 §D1 / ADR 0009 Decision 2a). Returns the lowered instruction, the
(possibly advanced) allocator cursor, and a flag recording whether THIS alloca
was dynamic-N (so the caller can enforce the static-after-dynamic invariant —
a STATIC alloca after a dynamic one still fails loud; bead `bennettvm-uil`).

**Static-size path (ADR 0014 §D1 + ADR 0009 Decision 4 rung 2):** when `n_elems`
is `ConstOperand(N)` with `N >= 1`, assign `dest` the current `next_addr` as its
`Int64` base, materialise that address into `locals` via a constant-create
`Define(dest, base, :add, 0)` (a pointer is just an `Int64`), and advance the
cursor by `N` cells, reserving cells `base … base+N-1` (one cell per element —
the VM is CELL-addressed, one `Int64` per cell, so `elem_width` (in bits) does
NOT enter the address; the cell stride a downstream `VarGEP` uses is `1`,
matching this `+N` step — `src/ir/array_index.jl` "stride is in cells").
`N == 1` is the scalar case (ADR 0014; `through_mem` allocates `__v2`→1,
`__v3`→2) — the `+N` advance specialises to `+1`. Cells default to `0` by the
zero-init convention; the allocator does not pre-populate `s.memory`. Returns
the `Define`, `next_addr + N`, and `false` (not dynamic).

**Dynamic-N path (ADR 0009 Decision 2a; beads `bennettvm-0zn` + `bennettvm-uil`):**
when `n_elems` is an `SSAOperand` (a C VLA / Julia `Vector{T}(undef, n)`), the
region size is unknown at lowering time, so the COMPILE-TIME cursor CANNOT
advance over it. Emit a `DynAlloca(dest, n_operand, base = next_addr)`
(`src/ir/alloca.jl`): `forward` materialises the pointer at `base +
s.heap_top` at runtime (the frozen compile-time base PLUS the runtime bump
offset), and an L2 `(base, n)` delta retracts the region on reverse. The cursor
is RETURNED UNCHANGED (all dynamic allocas anchor at the SAME frozen base and
offset apart at runtime via `s.heap_top`); the returned flag is `true`.

**≥2 dynamic arrays are admitted (bead `bennettvm-uil`).** The runtime
`IState.heap_top` offset (advanced by each alloca's runtime `n` in
`DynAlloca.forward`, retracted on reverse) distinguishes the disjoint regions of
multiple dynamic allocas, so a dynamic alloca AFTER a dynamic one is NOT
rejected. This is the gate for Case B's Dict (two `GenericMemory` backings). But
a STATIC alloca after a dynamic one STILL fails loud (`saw_dynamic == true` on
the static arm): a static alloca uses the compile-time cursor, which is frozen
at the first dynamic region's base and cannot step past a runtime-sized region —
mixed static/dynamic layout is the deferred bead (ADR 0009 §Consequences).

A non-positive `ConstOperand(N<=0)` is malformed IR and fails loud (an alloca
reserves at least one cell).
"""
function _lower_alloca!(inst::Bennett.IRAlloca,
                        next_addr::Int64,
                        saw_dynamic::Bool)::Tuple{Instruction,Int64,Bool}
    n = inst.n_elems
    if n isa Bennett.SSAOperand
        # Dynamic-N: emit a DynAlloca; do NOT advance the COMPILE-TIME cursor.
        # A dynamic-after-dynamic alloca IS now admitted (bead `bennettvm-uil`):
        # all dynamic allocas share the SAME frozen compile-time `base`
        # (next_addr); the RUNTIME `s.heap_top` offset (advanced by each
        # alloca's runtime `n` in `DynAlloca.forward`) distinguishes their
        # disjoint regions. So `saw_dynamic` does NOT gate a dynamic alloca, and
        # the cursor is NOT advanced — every dynamic alloca anchors at the same
        # frozen base and offsets apart at runtime (ADR 0009 Decision 2a multi-
        # array refinement). The returned flag stays `true` so a later STATIC
        # alloca still fails loud (below).
        return (DynAlloca(inst.dest, n.name, next_addr), next_addr, true)
    end
    # Static-after-dynamic invariant (Rule 1): a STATIC alloca may NOT follow a
    # dynamic-N one. A static alloca uses the COMPILE-TIME cursor (`next_addr`),
    # which is frozen at the first dynamic region's base and CANNOT step past a
    # runtime-sized region — so a static region placed there would ALIAS the
    # dynamic windows. (A dynamic alloca after a dynamic one IS admitted — it
    # rides the runtime `heap_top` offset; bead `bennettvm-uil`.) Mixed
    # static/dynamic layout needs the static cursor to advance past a
    # runtime-sized region, which is the deferred bead (ADR 0009 §Consequences).
    # Checked AFTER the dynamic arm so only the static-after-dynamic case fails.
    saw_dynamic &&
        error("lower_vm: STATIC IRAlloca(", inst.dest, ", elem_width=",
              inst.elem_width, ", n_elems=", inst.n_elems, ") follows a ",
              "dynamic-N alloca. A static alloca uses the COMPILE-TIME bump ",
              "cursor, frozen at the first dynamic region's base; it cannot ",
              "step past a runtime-sized region, so its region would ALIAS the ",
              "dynamic windows. Multi-DYNAMIC-array support landed (bead ",
              "`bennettvm-uil`, the runtime heap_top offset), but a STATIC ",
              "alloca after a dynamic one (mixed layout) is still deferred. ",
              "Rule 1 fail-loud — do not miscompile.")
    n isa Bennett.ConstOperand ||
        error("lower_vm: IRAlloca(", inst.dest, ", elem_width=",
              inst.elem_width, ", n_elems=", n, ") — n_elems must be a ",
              "ConstOperand (static-N) or SSAOperand (dynamic-N); a sentinel ",
              "operand here indicates an unhandled IR shape (Rule 1).")
    nelems = Int64(n.value)
    nelems >= 1 ||
        error("lower_vm: IRAlloca(", inst.dest, ", elem_width=",
              inst.elem_width, ", n_elems=ConstOperand(", nelems, ")) — a ",
              "static alloca must reserve at least one cell (N >= 1); ",
              "N=", nelems, " is malformed IR (Rule 1 fail-loud).")
    base = next_addr
    # Materialise the pointer as an Int64 in `locals`: `dest := base + 0`.
    # A constant-create Define (the same form the φ-incoming constants use,
    # `Define(name, value, :add, 0)`), so `dest` holds `base` and downstream
    # MemoryStore / MemoryLoad / VarGEP resolve it as the cell base address.
    # The cursor advances by `N` cells (CELL-addressed: one Int64 per element,
    # cells base … base+N-1), so a VarGEP with cell stride 1 lands on exactly
    # the cell this alloca reserved for element i (ADR 0009 Decision 2b).
    return (Define(inst.dest, base, :add, Int64(0)), next_addr + nelems, false)
end

# ---------------------------------------------------------------------
# φ-parameter collection + per-edge incoming lookup.
# ---------------------------------------------------------------------

"""
    _collect_phi_params(block::Bennett.IRBasicBlock) -> Vector{Symbol}

The block's entry parameters: the `IRPhi.dest`s, in block (source) order.
Mogensen RSSA places φ at joins; the param order here IS the positional
contract every predecessor edge's arg list must match.
"""
function _collect_phi_params(block::Bennett.IRBasicBlock)::Vector{Symbol}
    return Symbol[inst.dest for inst in block.instructions
                  if inst isa Bennett.IRPhi]
end

"""
    _edge_label(src::Symbol, dst::Symbol) -> Symbol

The synthetic trampoline-block label for the critical edge `src → dst`
(`:e_<src>_<dst>`). Distinct per edge, so a φ-join's two predecessors
get two distinct trampoline labels (the `ConditionalEntry`
`predecessor_true !== predecessor_false` invariant depends on this).
"""
_edge_label(src::Symbol, dst::Symbol) = Symbol("e_", src, "_", dst)

"""
    _successors(term::Bennett.IRInst) -> Vector{Symbol}

The CFG successor labels of a terminator. `IRBranch` with a `cond`
yields `[true_label, false_label]` (a 2-way split); an unconditional
`IRBranch` (`cond === nothing`) yields `[true_label]`; `IRRet` yields
`[]` (the routine exit, no successor). Distinct labels are NOT required
here — a degenerate branch with `true == false` would be rejected later
by the `ConditionalExit` constructor (Rule 1).
"""
function _successors(term::Bennett.IRInst)::Vector{Symbol}
    if term isa Bennett.IRBranch
        if term.cond === nothing || term.false_label === nothing
            return Symbol[term.true_label]
        else
            return Symbol[term.true_label, term.false_label]
        end
    elseif term isa Bennett.IRRet
        return Symbol[]
    else
        error("lower_vm: unsupported terminator subtype ", typeof(term),
              " — the M_UNBOUNDED slice (ADR 0012) handles IRBranch / ",
              "IRRet only (Rule 1).")
    end
end

"""
    _phi_incoming_for_edge(dst::Bennett.IRBasicBlock, src::Symbol)
        -> Vector{Bennett.IROperand}

The φ-incoming values that predecessor `src` supplies to join block
`dst`, in `dst`'s φ-param order. For each `IRPhi` in `dst`, scan its
`incoming::Vector{(value, pred_label)}` for the entry whose label is
`src`. A missing entry is a Rule-1 failure: a well-formed φ has one
incoming per predecessor (Mogensen RSSA §3 — φ records every predecessor).
"""
function _phi_incoming_for_edge(dst::Bennett.IRBasicBlock,
                                src::Symbol)::Vector{Bennett.IROperand}
    vals = Bennett.IROperand[]
    for inst in dst.instructions
        inst isa Bennett.IRPhi || continue
        idx = findfirst(p -> p[2] === src, inst.incoming)
        idx === nothing &&
            error("lower_vm: IRPhi :", inst.dest, " in block :", dst.label,
                  " has no incoming from predecessor :", src,
                  " (incoming preds: ", [p[2] for p in inst.incoming],
                  "). A φ must record every predecessor (Mogensen RSSA ",
                  "§3); a missing edge means a malformed CFG (Rule 1).")
        push!(vals, inst.incoming[idx][1])
    end
    return vals
end

"""
    _phi_const_name(src::Symbol, value::Int64) -> Symbol

The synthetic SSA name for a constant φ-incoming `value` materialised in
predecessor block `src` (ADR 0012 §D5): `:_phi_const_<src>_<value>`.
This is the *cross-edge-shared* name: keyed by `(src, value)` so two
DIFFERENT out-edges of `src` that send the same constant share one
materialised `Define` (only one runs at runtime — see this file's
docstring §4). Negative values render with a leading `-`, which is a
legal `Symbol` character.

NOTE (bead `bennettvm-3ah` DEF-3): the `_<src>_<value>` form can collide
for general block labels with numeric suffixes (e.g. `(src=:a_1, value=3)`
vs `(src=:a, value=13)` both render `:_phi_const_a_1_3`). Collatz /
matrix_sum / matrix_tri labels are collision-free, so this is retained as
the shared name for byte-for-byte stability of their pinned counts; the
*within-edge duplicate* names (`_phi_const_dup_name`) are counter-based
and collision-proof, hardening the worst case the e4l fix introduces.
"""
_phi_const_name(src::Symbol, value::Int64) = Symbol("_phi_const_", src, "_", value)

"""
    _phi_const_dup_name(src::Symbol, value::Int64, k::Int) -> Symbol

A FRESH, collision-proof synthetic name for the `k`-th *within-one-edge*
repeat of constant `value` flowing out of `src` (bead `bennettvm-e4l`,
ADR 0012 §D5). When a single edge's arg list would otherwise repeat a
by-value-shared `_phi_const_name`, each repeat slot gets its own create
named `:_phi_const_<src>_<value>_dup<k>` with a monotonically increasing
per-occurrence counter `k`. The counter guarantees uniqueness regardless
of label/value shape (it also sidesteps the `bennettvm-3ah` DEF-3 numeric-
suffix collision noted on `_phi_const_name`): two distinct occurrences
never collide because their `k` differs.
"""
_phi_const_dup_name(src::Symbol, value::Int64, k::Int) =
    Symbol("_phi_const_", src, "_", value, "_dup", k)

"""
    _phi_ssa_dup_name(src::Symbol, name::Symbol, k::Int) -> Symbol

A FRESH, collision-proof synthetic name for the `k`-th *within-one-edge* repeat
of SSA value `name` flowing out of `src` (bead `bennettvm-e4l`, generalised
from `ConstOperand` to `SSAOperand`). Surfaced by the Case-A Julia `Vector` O0
IR (ADR 0016): Julia duplicates a loop-induction φ, so one edge sends the same
SSA name into two φ-param slots. args→params binds positionally + destructively,
so each repeat slot needs its own non-destructive copy (`Define(dup, name, :add,
0)`); the monotone counter `k` guarantees uniqueness regardless of name shape.
"""
_phi_ssa_dup_name(src::Symbol, name::Symbol, k::Int) =
    Symbol("_phi_ssadup_", src, "_", name, "_", k)

"""
    _agg_slot_name(agg::Symbol, k::Int) -> Symbol

The synthetic per-slot SSA name for element `k` of aggregate SSA value
`agg` (bead `bennettvm-acq`, OPCODE G2): `:_agg_<agg>_slot<k>`.

`IState.locals` is a FLAT `Dict{Symbol,Int64}` — one key cannot hold the
N scalar elements of an ArrayType aggregate (`[N x iW]`, which is the only
aggregate shape Bennett.jl emits `IRExtractValue` / `IRInsertValue` for;
StructType fails loud UPSTREAM in extract — `../Bennett.jl/src/extract/
instructions.jl:1954-1957,1971-1974`). So an aggregate is modelled as a
FAMILY of N synthetic per-slot keys, one per element, reusing the scalar
`Define`-copy machinery — NO change to the IState type (hence no
equality/hash/checkpoint ripple). `extractvalue agg, k` reads slot `k`;
`insertvalue agg, v, k` rebuilds the family (slot `k` := `v`, the rest
copied from `agg`'s slots).

NOTE (lexical-collision caveat, mirroring `_phi_const_name`'s
`bennettvm-3ah` DEF-3 note): the `_<agg>_slot<k>` form could in principle
collide with a real SSA name a frontend happened to spell that way (e.g.
a user value literally named `_agg_a0_slot0`). Acceptable for v1: Bennett
SSA names are numeric (`%17`, `value_phi6`), never `_agg_…`-prefixed, so
the synthetic namespace is disjoint from the emitted one. A frontend that
ever emits an `_agg_`-prefixed name would need a counter-based mint (cf.
`_phi_const_dup_name`); filed as the follow-on if it arises.
"""
_agg_slot_name(agg::Symbol, k::Int) = Symbol("_agg_", agg, "_slot", k)

# ---------------------------------------------------------------------
# Main assembly: ParsedIR → VMProgram.
# ---------------------------------------------------------------------

"""
    _lower_parsed_ir(parsed::Bennett.ParsedIR, routine::Symbol) -> VMProgram

Assemble the `VMProgram`. Three phases (see this file's docstring):

  1. **Resolve φ args + register constants per edge.** For each CFG edge
     `src → dst` (from `src`'s terminator successors), read `dst`'s
     φ-incomings for `src` (`_phi_incoming_for_edge`); each `SSAOperand`
     becomes its name, each `ConstOperand` becomes a synthetic name to be
     materialised in `src`. A `ConstOperand` value is *shared across
     edges* (one `Define` per `(src, value)`, registered in `shared[src]`)
     but made *unique within one edge*: if a by-value-shared name already
     appears in the CURRENT edge's arg list, a fresh counter-based name
     (`_phi_const_dup_name`) and an EXTRA `Define` are minted so each
     param slot gets its own destructively-bound create (bead
     `bennettvm-e4l`). Every `(name, value)` to materialise in `src` is
     appended to `const_defs[src]` in registration order; the resulting
     `Symbol` arg list is stored under the edge label.
  2. **Build original blocks.** entry marker by predecessor arity
     (Begin for the entry block, ConditionalEntry for a ≥2-pred join,
     else UnconditionalEntry); body = lowered non-φ instructions + one
     synthetic constant `Define` per `(name, value)` registered for this
     block in `const_defs` (in registration order); exit marker
     from the terminator (End for IRRet, Conditional/Unconditional Exit
     to the trampoline(s) for IRBranch).
  3. **Build trampoline blocks** — one `UnconditionalEntry([]) →
     UnconditionalExit(dst, edge_args)` per edge.

Block emission order: entry block first (so `VMProgram` / `LabelTable`
see it as `blocks[1]`-resolvable via `entry_label`), then the remaining
original blocks, then all trampolines.
"""
function _lower_parsed_ir(parsed::Bennett.ParsedIR, routine::Symbol)::VMProgram
    blocks = parsed.blocks
    by_label = Dict{Symbol,Bennett.IRBasicBlock}(b.label => b for b in blocks)
    entry_label = first(blocks).label

    # --- Phase 1: edge args + per-source constant registry. ---
    # edge_args[(src,dst)]  :: Vector{Symbol}        — φ args in dst's φ order.
    # shared[src][value]    :: Symbol                — CROSS-EDGE-shared
    #     synthetic name for a const (one per (src,value); only one of
    #     `src`'s out-edges runs, so sharing is safe and keeps the pinned
    #     collatz/matrix_sum Define counts byte-identical).
    # const_defs[src]       :: Vector{Tuple{Symbol,Int64}} — every (name,
    #     value) to emit as a `Define` in `src`'s body (Phase 2), in
    #     registration order: the by-value-shared creates AND the extra
    #     per-occurrence creates minted for within-edge duplicates (e4l).
    # preds[dst]            :: Vector{Symbol}        — incoming trampoline labels.
    edge_args = Dict{Tuple{Symbol,Symbol},Vector{Symbol}}()
    shared = Dict{Symbol,Dict{Int64,Symbol}}(b.label => Dict{Int64,Symbol}()
                                             for b in blocks)
    const_defs = Dict{Symbol,Vector{Tuple{Symbol,Int64}}}(
        b.label => Tuple{Symbol,Int64}[] for b in blocks)
    # ssa_copy_defs[src] :: Vector{(dup_name, source_name)} — the within-edge
    # SSA-duplicate copies (bead e4l, generalised to SSAOperand): each is a
    # non-destructive `Define(dup, source, :add, 0)` materialised in `src`'s
    # body so a single edge sending the same SSA name into two φ-param slots
    # gets a distinct name per slot.
    ssa_copy_defs = Dict{Symbol,Vector{Tuple{Symbol,Symbol}}}(
        b.label => Tuple{Symbol,Symbol}[] for b in blocks)
    preds = Dict{Symbol,Vector{Symbol}}(b.label => Symbol[] for b in blocks)
    dup_counter = 0  # monotone, collision-proof across all within-edge dups.
    for src_block in blocks
        src = src_block.label
        for dst in _successors(src_block.terminator)
            incoming = _phi_incoming_for_edge(by_label[dst], src)
            args = Symbol[]
            used = Set{Symbol}()  # names already bound IN THIS edge's args.
            for op in incoming
                if op isa Bennett.SSAOperand
                    if op.name in used
                        # Within-THIS-edge SSA duplicate (bead e4l, generalised
                        # from ConstOperand to SSAOperand — surfaced by the
                        # Case-A Julia `Vector` O0 IR, where Julia duplicates a
                        # loop induction φ so one edge sends the SAME SSA name
                        # into two param slots). args→params binds positionally
                        # and DESTRUCTIVELY, so this slot needs its OWN copy:
                        # mint a fresh name + an extra non-destructive copy
                        # `Define(dup, op.name, :add, 0)` in `src`'s body. The
                        # original `op.name` is READ, never consumed.
                        dup_counter += 1
                        dup = _phi_ssa_dup_name(src, op.name, dup_counter)
                        push!(ssa_copy_defs[src], (dup, op.name))
                        push!(args, dup)
                        push!(used, dup)
                    else
                        push!(args, op.name)
                        push!(used, op.name)
                    end
                else  # ConstOperand — materialise in `src`.
                    v = Int64(op.value)
                    # Cross-edge-shared name (one Define per (src,value)).
                    name = get!(shared[src], v) do
                        nm = _phi_const_name(src, v)
                        push!(const_defs[src], (nm, v))
                        nm
                    end
                    if name in used
                        # Within-THIS-edge duplicate: the shared name is
                        # already bound to a prior param slot of this same
                        # edge. args→params binds positionally and
                        # destructively, so this slot needs its OWN create
                        # (bead e4l). Mint a fresh collision-proof name +
                        # an EXTRA Define in src's body.
                        dup_counter += 1
                        name = _phi_const_dup_name(src, v, dup_counter)
                        push!(const_defs[src], (name, v))
                    end
                    push!(args, name)
                    push!(used, name)
                end
            end
            edge_args[(src, dst)] = args
            push!(preds[dst], _edge_label(src, dst))
        end
    end

    out = BasicBlock[]

    # Bump-allocator cursor for `IRAlloca` (ADR 0014 §D1). Monotone across
    # ALL blocks — every static alloca anywhere in the routine gets a fresh
    # `Int64` base address (start at 1; advance by N per static alloca). A
    # pointer is just that `Int64` in `locals`, materialised by the `Define`
    # `_lower_alloca!` returns. Threaded through the body loop below by
    # closure over these bindings.
    #
    # `saw_dynamic_alloca` (ADR 0009 Decision 2a; beads `bennettvm-0zn` +
    # `bennettvm-uil`): tracks whether a dynamic-N `IRAlloca` (a VLA /
    # `Vector(undef, n)`) has been lowered to a `DynAlloca`. A dynamic alloca
    # does NOT advance the COMPILE-TIME cursor — all dynamic allocas anchor at
    # the same frozen base and offset apart at RUNTIME via `IState.heap_top`
    # (bead `bennettvm-uil`), so ≥2 dynamic allocas ARE admitted. A STATIC
    # alloca after a dynamic one STILL fails loud in `_lower_alloca!` (the
    # compile-time cursor cannot step past a runtime-sized region; Rule 1).
    alloca_cursor = Int64(1)
    saw_dynamic_alloca = false

    # Aggregate-dest registry (bead `bennettvm-acq`, OPCODE G2). Every
    # `IRInsertValue.dest` is an SSA name bound to an aggregate VALUE that this
    # pass DECOMPOSES into a per-slot `Define` family (no scalar key of its own
    # ever holds the aggregate). PRE-SCANNED over ALL blocks here — BEFORE the
    # per-block Phase-2 loop — so a cross-block aggregate (built in one block,
    # returned in another) is caught by the IRRet guard regardless of the
    # block-emission order (which is `entry first, then original order`, NOT
    # dominance order — populating during the loop could miss a return whose
    # aggregate is defined in a later-emitted block). Read only by the `IRRet`
    # aggregate-return reject (a decomposed aggregate name must NOT dangle into
    # the single-symbol `EndInstruction.returns` — the multi-key return is the
    # follow-on bead).
    agg_dests = Set{Symbol}(inst.dest for b in blocks
                            for inst in b.instructions
                            if inst isa Bennett.IRInsertValue)

    # --- Phase 2: original blocks (entry block first). ---
    ordered = vcat(by_label[entry_label],
                   [b for b in blocks if b.label !== entry_label])
    for b in ordered
        params = _collect_phi_params(b)
        # Entry marker by predecessor arity.
        if b.label === entry_label
            # Out-of-slice fail-loud (Rule 1): an entry block that is ALSO a
            # φ-join (a back-edge targets the entry directly) would need a
            # ConditionalEntry, but the Begin frame takes priority here and
            # would silently drop the φ-param binding. Collatz's entry (`top`)
            # has no incoming edge, so preds is empty. A non-empty preds means
            # an entry-as-loop-header CFG, which the M_UNBOUNDED slice does not
            # lower — error rather than miscompile (deferred past the slice).
            isempty(preds[b.label]) ||
                error("lower_vm: entry block :", b.label, " is also a φ-join ",
                      "(predecessors ", preds[b.label], ") — an entry-as-loop-",
                      "header shape needs a Begin+ConditionalEntry merge not in ",
                      "the M_UNBOUNDED slice (ADR 0012; Rule 1 fail-loud). ",
                      "Bennett.jl typically emits a separate preheader, so this ",
                      "is rare; file a follow-up if a real program hits it.")
            entry = BeginInstruction(routine, Symbol[n for (n, _w) in parsed.args])
        elseif length(preds[b.label]) >= 2
            # `ConditionalEntry` is a 2-predecessor join (true/false).
            # A ≥3-predecessor join would need a nested-merge lowering
            # not in the M_UNBOUNDED slice; fail loud (Rule 1) rather
            # than silently dropping the extra predecessors. Collatz has
            # no 3-way join (max in-degree 2).
            length(preds[b.label]) == 2 ||
                error("lower_vm: block :", b.label, " has ",
                      length(preds[b.label]), " predecessors (",
                      preds[b.label], "); ConditionalEntry models a ",
                      "2-way join only. A ≥3-predecessor join needs a ",
                      "nested-merge lowering, deferred past the ",
                      "M_UNBOUNDED slice (ADR 0012; Rule 1 fail-loud).")
            # Vestigial condition under L3 replay (ADR 0012 §D4):
            # `_dispatch_to_block!` does NOT read a ConditionalEntry's
            # `condition` on forward arrival, and backward dispatch is
            # never taken under checkpoint-replay — so any symbol ∉ params
            # satisfies the constructor. A per-block synthetic sentinel
            # `:_cond_<label>` is guaranteed fresh (φ params are LLVM SSA
            # names, never `_cond_`-prefixed) regardless of arg count or
            # naming — robust where `parsed.args[1]` would fail for a
            # zero-arg routine or collide with a φ param.
            cond = Symbol("_cond_", b.label)
            entry = ConditionalEntry(b.label, params, preds[b.label][1],
                                     preds[b.label][2], cond)
        else
            entry = UnconditionalEntry(b.label, params)
        end
        # Body: lowered non-φ instructions, then synthetic constant creates.
        body = Instruction[]
        for inst in b.instructions
            if inst isa Bennett.IRAlloca
                # Alloca needs the bump-allocator state (ADR 0014 §D1 / ADR
                # 0009 Decision 2a), so it is lowered here, not in the pure
                # per-instruction dispatch. A static `ConstOperand(N)` alloca
                # emits a `Define(dest, base, :add, 0)` and advances the cursor
                # by N; a dynamic `SSAOperand` alloca emits a `DynAlloca` (with
                # an L2 (base, n) delta), leaves the COMPILE-TIME cursor frozen
                # (dynamic regions offset apart at runtime via heap_top), and
                # sets the flag so a later STATIC alloca fails loud (bead
                # `bennettvm-uil`; a later DYNAMIC alloca is admitted).
                ainstr, alloca_cursor, was_dyn =
                    _lower_alloca!(inst, alloca_cursor, saw_dynamic_alloca)
                saw_dynamic_alloca = saw_dynamic_alloca || was_dyn
                push!(body, ainstr)
            elseif inst isa Bennett.IRInsertValue
                # LLVM `insertvalue agg, val, index` → N slot `Define`s rebuilding
                # the aggregate family (bead `bennettvm-acq`, OPCODE G2). Because
                # it emits N instructions it does NOT fit the single-instruction
                # `_lower_body_inst` contract, so it is special-cased HERE,
                # mirroring the `IRAlloca` branch. The aggregate `dest` is modelled
                # as a family of per-slot keys (`_agg_slot_name`); after the build
                # every slot j holds the correct scalar:
                #
                #   * slot `index` := the inserted `val` (an SSAOperand or a
                #     ConstOperand, lowered via `_lower_operand` — the same helper
                #     `_lower_body_inst` uses for every binop/store/etc. operand);
                #   * every other slot j := `agg`'s slot j, copied non-
                #     destructively (`agg` is READ, never consumed — SSA values
                #     persist for later use of the same aggregate).
                #
                # Two base shapes for `agg`:
                #   - `Bennett.ZERO_AGG` (a `ZeroAggSentinel` = an all-zero
                #     `[N x iW]` `zeroinitializer`, `../Bennett.jl/src/ir_types.jl:
                #     36,49`): the base of an insertvalue build-up chain. The
                #     un-inserted slots are zero-CREATES (`Define(slot, 0, :add,
                #     0)`), there being no prior aggregate to copy from.
                #   - a prior aggregate `SSAOperand`: copy each un-inserted slot
                #     from `agg.name`'s slot family.
                #
                # Each emitted `Define` is the non-destructive copy/create idiom
                # (`Define(t, src_or_const, :add, 0)`) — non-injective, reversed by
                # L3 checkpoint-replay like every other `Define`, so NO new delta
                # and a clean round-trip to empty history. `dest` was registered
                # in `agg_dests` by the pre-scan above so a later aggregate-return
                # IRRet fails loud (the decomposed family must not dangle into a
                # single-symbol End).
                #
                # Bennett.jl emits `IRInsertValue` ONLY for homogeneous ArrayType
                # `[N x iW]` (StructType fails loud upstream — `../Bennett.jl/src/
                # extract/instructions.jl:1971-1974`), so `n_elems` slots is the
                # full, well-defined element count.
                n = inst.n_elems
                # SILENT-MISCOMPILE guard (bead `bennettvm-acq`, Rule 2). The
                # slot loop is `for j in 0:(n-1)`; if `index ∉ [0, n_elems)` the
                # loop NEVER hits `j == index`, so the inserted `val` is silently
                # DROPPED — every slot would be a copy/zero and `val` vanishes
                # with zero error at lower- or run-time. And `n_elems == 0` emits
                # ZERO Defines (no slot family at all). Both are miscompiles, not
                # crashes, so they must fail loud HERE before the loop runs.
                # Reproducer: `IRInsertValue(:a, ZERO_AGG, x, 2, 32, 2)` — index
                # 2 with n_elems 2 has no slot 2, so `x` would be dropped silently.
                (n >= 1 && 0 <= inst.index < n) ||
                    error("lower_vm: IRInsertValue index=", inst.index,
                          " out of range for n_elems=", n, " (dest=", inst.dest,
                          ") — a `[N x iW]` insert must target slot index ",
                          "∈ [0, n_elems) with n_elems ≥ 1. An out-of-range ",
                          "index would SILENTLY DROP the inserted value (the ",
                          "slot loop never hits `j == index`) and n_elems=0 ",
                          "would emit zero slot Defines; both are silent ",
                          "miscompiles (bead `bennettvm-acq`, Rule 2 fail-loud).")
                lowered_val = _lower_operand(inst.val)
                for j in 0:(n - 1)
                    slot = _agg_slot_name(inst.dest, j)
                    if j == inst.index
                        push!(body, Define(slot, lowered_val, :add, Int64(0)))
                    elseif inst.agg === Bennett.ZERO_AGG
                        # No prior aggregate — zeroinitializer base. Zero-create.
                        # `width=64` (default) is correct for a pure create: it
                        # is an identity at the Int64 carrier (`_apply_binop(:add,
                        # 0, 0, 64) == 0`); width-masking is the downstream
                        # consumer's job (the i32 carrier invariant, beads
                        # `kmpg`/`bgc`), not the slot copy's.
                        push!(body, Define(slot, Int64(0), :add, Int64(0)))
                    else
                        # Copy from the prior aggregate's slot j (READ, not
                        # consumed). `inst.agg` must be an SSAOperand here.
                        inst.agg isa Bennett.SSAOperand ||
                            error("lower_vm: IRInsertValue agg is ",
                                  typeof(inst.agg), " (dest=", inst.dest,
                                  ") — the aggregate slot model (bead ",
                                  "`bennettvm-acq`) requires the base to be the ",
                                  "ZERO_AGG sentinel or an SSAOperand naming a ",
                                  "prior aggregate; any other operand is an ",
                                  "unhandled IR shape (Rule 1 fail-loud).")
                        # `width=64` (default) is correct for a pure slot COPY:
                        # `_apply_binop(:add, v, 0, 64) == v` is the identity at
                        # the Int64 carrier precision, so the copied scalar is
                        # bit-preserved; width-masking is the downstream
                        # consumer's responsibility (the i32 carrier invariant,
                        # beads `kmpg`/`bgc`), not this copy's.
                        push!(body, Define(slot,
                                           _agg_slot_name(inst.agg.name, j),
                                           :add, Int64(0)))
                    end
                end
            elseif inst isa Bennett.IRExtractValue
                # LLVM `extractvalue agg, index` → ONE non-destructive slot COPY
                # (bead `bennettvm-acq`, OPCODE G2). Relocated HERE (out of
                # `_lower_body_inst`) to sit alongside `IRInsertValue`: the
                # symmetry is the point (insert BUILDS the slot family, extract
                # READS one slot), and the aggregate-membership guard below needs
                # `agg_dests` — only in scope in this loop, not in the pure
                # per-instruction dispatch. The slot key is READ, never destroyed
                # (`Define(dest, slot, :add, 0)`, the same non-destructive copy
                # idiom the φ-incoming constants and alloca-pointer create use).
                #
                # Two fail-loud guards (Rule 1 / Rule 2), both lower-time:
                #   (a) BOUNDS — `index ∈ [0, n_elems)`. An out-of-range index
                #       names a slot key (`_agg_<agg>_slot<index>`) NO insertvalue
                #       ever defined, so forward `run!` would hit a bare KeyError
                #       with no context. Fail loud here, named.
                #   (b) MEMBERSHIP — `agg.name ∈ agg_dests`. An `extractvalue`
                #       whose `agg` is an ordinary scalar SSA name (never produced
                #       by any `insertvalue`) would emit `Define(dest, _agg_<sc>_
                #       slot…)` against a slot family that does not exist → another
                #       contextless runtime KeyError. The pre-scanned `agg_dests`
                #       registry (every IRInsertValue.dest) is the authority.
                #
                # `agg` MUST be an `SSAOperand` (an extractvalue of a bare
                # zeroinitializer is constant-folded upstream and never reaches
                # ingest). Bennett.jl emits this ONLY for homogeneous ArrayType
                # `[N x iW]` (StructType fails loud upstream — `../Bennett.jl/src/
                # extract/instructions.jl:1954-1957`), so the slot model is sound.
                inst.agg isa Bennett.SSAOperand ||
                    error("lower_vm: IRExtractValue agg is ", typeof(inst.agg),
                          " (dest=", inst.dest, ") — the aggregate slot model ",
                          "(bead `bennettvm-acq`) requires an SSAOperand ",
                          "aggregate naming a prior insertvalue build-up; an ",
                          "extractvalue of a bare zeroinitializer/sentinel is ",
                          "constant-folded upstream and should never reach ",
                          "ingest (Rule 1 fail-loud).")
                # (a) BOUNDS — index must name a real slot of the family.
                (inst.n_elems >= 1 && 0 <= inst.index < inst.n_elems) ||
                    error("lower_vm: IRExtractValue index=", inst.index,
                          " out of range for n_elems=", inst.n_elems, " (dest=",
                          inst.dest, ", agg=", inst.agg.name, ") — a `[N x iW]` ",
                          "extract must read slot index ∈ [0, n_elems). An ",
                          "out-of-range index names a `_agg_<agg>_slot` key no ",
                          "insertvalue ever defined → a contextless runtime ",
                          "KeyError (bead `bennettvm-acq`, Rule 1 fail-loud).")
                # (b) MEMBERSHIP — `agg` must be a known aggregate (insertvalue
                #     dest), not an ordinary scalar SSA name.
                inst.agg.name in agg_dests ||
                    error("lower_vm: IRExtractValue agg=:", inst.agg.name,
                          " (dest=", inst.dest, ") is NOT a known aggregate — ",
                          "no `insertvalue` defines it, so it has no per-slot ",
                          "`_agg_<agg>_slot` family; extracting from it would ",
                          "emit a Define against a never-defined slot key → a ",
                          "contextless runtime KeyError. Only an SSA value built ",
                          "by `insertvalue` is a valid extractvalue source (bead ",
                          "`bennettvm-acq`, Rule 1 fail-loud).")
                # `width=64` (default) is correct for a pure slot COPY:
                # `_apply_binop(:add, v, 0, 64) == v` is the identity at the
                # Int64 carrier precision (bit-preserving); width-masking is the
                # downstream consumer's job (the i32 carrier invariant, beads
                # `kmpg`/`bgc`), not this read's.
                push!(body, Define(inst.dest,
                                   _agg_slot_name(inst.agg.name, inst.index),
                                   :add, Int64(0)))
            else
                li = _lower_body_inst(inst)
                li === nothing || push!(body, li)
            end
        end
        # One Define per registered (name, value), in registration order:
        # the by-value-shared creates AND the within-edge-duplicate extras
        # (bead e4l). Each materialises `value` into a distinct SSA name so
        # every param slot the edge feeds gets its own destructive create.
        for (name, v) in const_defs[b.label]
            push!(body, Define(name, Int64(v), :add, Int64(0)))
        end
        # One non-destructive copy per within-edge SSA duplicate (bead e4l,
        # SSAOperand case): `Define(dup, source, :add, 0)` reads `source` and
        # writes the fresh `dup` so two φ-param slots fed the same SSA name from
        # one edge each get their own create. `source` is READ, never consumed.
        for (dup, source) in ssa_copy_defs[b.label]
            push!(body, Define(dup, source, :add, Int64(0)))
        end
        # Exit marker from the terminator.
        term = b.terminator
        if term isa Bennett.IRRet
            retval = _lower_operand(term.op)
            retval isa Symbol ||
                error("lower_vm: IRRet of a literal (", retval, ") is ",
                      "unsupported — End.returns is symbol-only; a const ",
                      "return would need a synthetic create (Rule 1).")
            # Aggregate-return guard (bead `bennettvm-acq`, OPCODE G2 — the
            # fatal-flaw fix). If the returned SSA name is an aggregate `dest`
            # this pass DECOMPOSED into a per-slot family, it has NO single
            # scalar key — emitting `EndInstruction(routine, [name])` would key
            # the output off a symbol that never holds a value (`result(rs)` is
            # keyed by the End's single return symbol). This bead scopes
            # scalar-CONSUMED extract/insert only (every aggregate fully decays
            # into scalar slots before return); the multi-key return
            # (`EndInstruction.returns = [name_slot0, …]`, keyed off Bennett's
            # `ret_elem_widths`) is a follow-on bead. Fail loud rather than let a
            # decomposed aggregate name dangle into a single-symbol End (Rule 1).
            retval in agg_dests &&
                error("lower_vm: IRRet returns aggregate SSA value :", retval,
                      " — returning a `[N x iW]` aggregate is DEFERRED (bead ",
                      "`bennettvm-acq` scopes scalar-CONSUMED extract/insert ",
                      "only). This pass decomposed :", retval, " into a per-slot ",
                      "`_agg_<name>_slot<k>` family (no single scalar key holds ",
                      "the aggregate), so it cannot flow into the symbol-only ",
                      "`EndInstruction.returns`. The multi-key aggregate return ",
                      "(End.returns = [", retval, "_slot0, …], keyed off ",
                      "ret_elem_widths) is a follow-on bead. Rule 1 fail-loud — ",
                      "do not dangle a decomposed aggregate into a scalar End.")
            exit = EndInstruction(routine, Symbol[retval])
        else  # IRBranch
            succs = _successors(term)
            if length(succs) == 1
                exit = UnconditionalExit(_edge_label(b.label, succs[1]), Symbol[])
            else
                exit = ConditionalExit(term.cond.name,
                                       _edge_label(b.label, term.true_label),
                                       _edge_label(b.label, term.false_label),
                                       Symbol[])
            end
        end
        push!(out, BasicBlock(b.label, entry, body, exit))
    end

    # --- Phase 3: trampoline blocks (one per edge). ---
    for ((src, dst), args) in edge_args
        lbl = _edge_label(src, dst)
        push!(out, BasicBlock(lbl,
                              UnconditionalEntry(lbl, Symbol[]),
                              Instruction[],
                              UnconditionalExit(dst, args)))
    end

    arg_widths = Int[w for (_n, w) in parsed.args]
    return VMProgram(out, LabelTable(out), entry_label,
                     arg_widths, copy(parsed.ret_elem_widths))
end

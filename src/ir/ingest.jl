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

# Width note (ADR 0012 R1, deferred)

`IState.locals` are `Int64`; collatz is i8. The lowering does NOT mask
to the IRInst `width` field — full per-`width` masking is a follow-up
bead. Oracle agreement therefore holds only for inputs whose trajectory
stays in i8 range (the forward test picks such inputs); the round-trip
invariant is width-independent.

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
(the deferred full-width bead `bennettvm-bgc`).
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
        # i1-boolean fix the multi-block Julia-O0 CFG needs (full per-`width`
        # masking is the deferred bead `bennettvm-bgc`); it is sound because an
        # i1 value is always 0/1 and i1 algebra over {0,1} is exact in Int64.
        return Define(inst.dest, _lower_bool_operand(inst.op1, inst.width),
                      inst.op, _lower_bool_operand(inst.op2, inst.width))
    elseif inst isa Bennett.IRICmp
        return Define(inst.dest, _lower_operand(inst.op1), inst.predicate,
                      _lower_operand(inst.op2))
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
                  "pointer naming an alloca dest (a pointer is an Int64 ",
                  "address in locals). Address arithmetic (IRPtrOffset / ",
                  "IRVarGEP) is deferred to v2 (Rule 1).")
        return MemoryStore(inst.ptr.name, _lower_operand(inst.val))
    elseif inst isa Bennett.IRLoad
        # LLVM `dest = load ptr` → the plain non-injective heap read (ADR
        # 0014 §D2). `ptr` is an SSAOperand naming an alloca dest. Zero-init
        # convention: a load of a never-stored address reads as 0
        # (`MemoryLoad.forward`).
        inst.ptr isa Bennett.SSAOperand ||
            error("lower_vm: IRLoad ptr is ", typeof(inst.ptr),
                  " (dest=", inst.dest, ") — the memory floor (ADR 0014 §D1) ",
                  "requires an SSAOperand pointer naming an alloca dest. ",
                  "Address arithmetic (IRPtrOffset / IRVarGEP) is deferred ",
                  "to v2 (Rule 1).")
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
        # Float32-as-OUTPUT (the double-rounding case, ADR 0011 D2) is rejected
        # upstream in Bennett.jl; a pure-Float64 program (the SC10 gate) never
        # emits an f32-result `soft_fptrunc` as its output (the conversion
        # callees are recognised as legal intermediates; full f32-output
        # rejection at the program boundary is a documented follow-on, not
        # silently wrong here).
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
    elseif inst isa Bennett.IRPhi
        return nothing   # φ → block parameter; not a body instruction.
    else
        error("lower_vm: unsupported IRInst body subtype ", typeof(inst),
              " — the slice handles IRBinOp / IRICmp / IRSelect / IRPhi ",
              "(ADR 0012), IRCast (ADR 0013 §D-5), IRStore / IRLoad (the ",
              "scalar memory floor, ADR 0014 §D2), IRVarGEP (the array ",
              "element-address create, ADR 0009 Decision 2b), IRCall to a ",
              "soft_f* callee (the SoftFloat-dispatch create, ADR 0011 §D1), ",
              "and IRMapInsert / IRMapGet / IRMapDelete (the reversible-map ",
              "ops, ADR 0008 / 0013 §D-3, SC9 Case B). IRAlloca is lowered at ",
              "the call site via the bump allocator (ADR 0014 §D1). ",
              "IRPtrOffset / IRExtractValue are deferred (Rule 1).")
    end
end

"""
    _lower_alloca!(inst::Bennett.IRAlloca, next_addr::Int64, saw_dynamic::Bool)
        -> Tuple{Instruction, Int64, Bool}

Lower one `IRAlloca(dest, elem_width, n_elems)` via the bump allocator
(ADR 0014 §D1 / ADR 0009 Decision 2a). Returns the lowered instruction, the
(possibly advanced) allocator cursor, and a flag recording whether THIS alloca
was dynamic-N (so the caller can enforce the single-dynamic-array invariant).

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

**Dynamic-N path (ADR 0009 Decision 2a; bead `bennettvm-0zn`):** when `n_elems`
is an `SSAOperand` (a C VLA / Julia `Vector{T}(undef, n)`), the region size is
unknown at lowering time, so the cursor CANNOT advance over it. Emit a
`DynAlloca(dest, n_operand, base = next_addr)` (`src/ir/alloca.jl`): `forward`
materialises the pointer at this FROZEN compile-time base at runtime, and an L2
`(base, n)` delta retracts the region on reverse. The cursor is RETURNED
UNCHANGED (the runtime-sized region owns the open-ended tail `[base, ∞)`); the
returned flag is `true`. There is no runtime bump-allocator state in `IState`,
so only ONE dynamic array per routine is sound: a SECOND allocation after a
dynamic one would alias the frozen base — `saw_dynamic == true` therefore FAILS
LOUD (Rule 1) before any further alloca is lowered (the caller passes the
running flag in).

A non-positive `ConstOperand(N<=0)` is malformed IR and fails loud (an alloca
reserves at least one cell). A dynamic-N alloca AFTER a previous dynamic-N
alloca (`saw_dynamic == true`) fails loud regardless of `n_elems` kind.
"""
function _lower_alloca!(inst::Bennett.IRAlloca,
                        next_addr::Int64,
                        saw_dynamic::Bool)::Tuple{Instruction,Int64,Bool}
    # Single-dynamic-array invariant (Rule 1): no alloca may follow a dynamic-N
    # alloca — the frozen-base strategy cannot admit a second region without a
    # runtime bump pointer (deferred; see ADR 0009 §Consequences / the impl
    # bead). Checked FIRST so both a static and a dynamic alloca after a dynamic
    # one fail loud (not just a second dynamic one).
    saw_dynamic &&
        error("lower_vm: IRAlloca(", inst.dest, ", elem_width=",
              inst.elem_width, ", n_elems=", inst.n_elems, ") follows a ",
              "dynamic-N alloca. The single-dynamic-array fixed-base strategy ",
              "(ADR 0009 Decision 2a) freezes the bump cursor at the dynamic ",
              "region's base, which owns the open-ended address tail; a second ",
              "allocation would ALIAS that frozen base. Multi-dynamic-array ",
              "support needs a runtime bump pointer threaded through IState ",
              "(deferred bead). Rule 1 fail-loud — do not miscompile.")
    n = inst.n_elems
    if n isa Bennett.SSAOperand
        # Dynamic-N: emit a DynAlloca; do NOT advance the cursor.
        return (DynAlloca(inst.dest, n.name, next_addr), next_addr, true)
    end
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
    # `saw_dynamic_alloca` (ADR 0009 Decision 2a; bead `bennettvm-0zn`):
    # tracks whether a dynamic-N `IRAlloca` (a VLA / `Vector(undef, n)`) has
    # been lowered to a `DynAlloca`. A dynamic alloca does NOT advance the
    # cursor (its runtime-sized region owns the open-ended address tail), so
    # the single-dynamic-array fixed-base strategy admits exactly one — any
    # alloca AFTER a dynamic one fails loud in `_lower_alloca!` (Rule 1).
    alloca_cursor = Int64(1)
    saw_dynamic_alloca = false

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
                # an L2 (base, n) delta), leaves the cursor frozen, and sets the
                # single-dynamic-array flag so any further alloca fails loud.
                ainstr, alloca_cursor, was_dyn =
                    _lower_alloca!(inst, alloca_cursor, saw_dynamic_alloca)
                saw_dynamic_alloca = saw_dynamic_alloca || was_dyn
                push!(body, ainstr)
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

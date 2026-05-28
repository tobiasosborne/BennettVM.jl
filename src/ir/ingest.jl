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

## 4. Constant φ-incomings need a synthetic create (ADR 0012 §D5)

`*Exit.args::Vector{Symbol}` is symbol-only, but a φ incoming may be a
literal (collatz: `value_phi17`'s incoming from `top` is `Const(0)`;
`value_phi1.lcssa`'s incoming from `top` is `Const(0)`). We materialise
each distinct constant `v` flowing out of a predecessor block with a
synthetic `Define(:_phi_const_<src>_<v>, Int64(v), :add, Int64(0))`
appended to that predecessor's body, and pass the synthetic name as the
edge arg. The `Define` reads two literals (no operand collision) and is
non-injective (so L3 checkpoints around it — harmless, it is a fresh
create). Distinct `(src, v)` pairs share one synthetic name within a
predecessor, so a predecessor that sends `0` on two edges materialises
`0` once.

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
  * `IRPhi`                         → `nothing` (handled as a param).

Any other `IRInst` subtype is rejected loudly (Rule 1).
"""
function _lower_body_inst(inst::Bennett.IRInst)::Union{Instruction,Nothing}
    if inst isa Bennett.IRBinOp
        return Define(inst.dest, _lower_operand(inst.op1), inst.op,
                      _lower_operand(inst.op2))
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
    elseif inst isa Bennett.IRPhi
        return nothing   # φ → block parameter; not a body instruction.
    else
        error("lower_vm: unsupported IRInst body subtype ", typeof(inst),
              " — the M_UNBOUNDED slice (ADR 0012) handles IRBinOp / ",
              "IRICmp / IRSelect / IRPhi and IRCast (ADR 0013 §D-5) ",
              "only (Rule 1).")
    end
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
Keyed by `(src, value)` so a predecessor that sends the same constant on
two edges materialises it once. Negative values render with a leading
`-`, which is a legal `Symbol` character.
"""
_phi_const_name(src::Symbol, value::Int64) = Symbol("_phi_const_", src, "_", value)

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
     materialised in `src` (registered in `consts[src]`). The resulting
     `Symbol` arg list is stored under the edge label.
  2. **Build original blocks.** entry marker by predecessor arity
     (Begin for the entry block, ConditionalEntry for a ≥2-pred join,
     else UnconditionalEntry); body = lowered non-φ instructions + the
     synthetic constant `Define`s registered for this block; exit marker
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
    # edge_args[(src,dst)] :: Vector{Symbol}  — φ args in dst's φ order.
    # consts[src][value]   :: Symbol          — synthetic name for a const.
    # preds[dst]           :: Vector{Symbol}   — incoming trampoline labels.
    edge_args = Dict{Tuple{Symbol,Symbol},Vector{Symbol}}()
    consts = Dict{Symbol,Dict{Int64,Symbol}}(b.label => Dict{Int64,Symbol}()
                                              for b in blocks)
    preds = Dict{Symbol,Vector{Symbol}}(b.label => Symbol[] for b in blocks)
    for src_block in blocks
        src = src_block.label
        for dst in _successors(src_block.terminator)
            incoming = _phi_incoming_for_edge(by_label[dst], src)
            args = Symbol[]
            for op in incoming
                if op isa Bennett.SSAOperand
                    push!(args, op.name)
                else  # ConstOperand — materialise in `src`, share by value.
                    v = Int64(op.value)
                    name = get!(consts[src], v) do
                        _phi_const_name(src, v)
                    end
                    push!(args, name)
                end
            end
            edge_args[(src, dst)] = args
            push!(preds[dst], _edge_label(src, dst))
        end
    end

    out = BasicBlock[]

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
            li = _lower_body_inst(inst)
            li === nothing || push!(body, li)
        end
        for (v, name) in consts[b.label]
            push!(body, Define(name, Int64(v), :add, Int64(0)))
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

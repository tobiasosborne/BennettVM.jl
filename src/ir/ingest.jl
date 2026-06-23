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
# Sub-module includes (bead `bennettvm-u110` / Rule 10 — the ~200-LOC
# split of the original single `ingest.jl`). These are PURE MOVES of the
# helper layers this driver (`_lower_parsed_ir`, below) calls; they are
# `include`d into the SAME `BennettVM` module (the `intrinsics.jl` /
# `intrinsics_bulk.jl` pattern — sibling includes, not nested), so every
# function/const name is unchanged and reachable as before. Order is by
# dependency: operands → call-dispatch → body/alloca → φ/edge helpers,
# each consuming only names defined above it.
#   * ingest_operands.jl — `_lower_operand` / `_lower_bool_operand` /
#     `_lower_ptr_operand` (the IROperand → Symbol|Int64 layer).
#   * ingest_call.jl — `_lower_intrinsic_call` + `_NONDETERMINISTIC_CALLEES`
#     + `_HEAP_DISPATCH` (the IRCall dispatch tables, kept INTACT as a unit
#     because the ADR 0018 §C guard ordering is load-bearing; the future
#     ADR 0019 §8 guard-5 `functions`-table resolution slots into the
#     IRCall arm in `ingest_body.jl` after the Float32 guard, with any new
#     dispatch table beside `_HEAP_DISPATCH` here).
#   * ingest_body.jl — `_lower_body_inst` (the six-arm per-instruction
#     dispatch, incl. the IRCall arm) + `_lower_alloca!` (the bump lift).
#   * ingest_phi.jl — `_collect_phi_params` / `_edge_label` / `_successors`
#     / `_phi_incoming_for_edge` + the synthetic-name minters.
# ---------------------------------------------------------------------
include("ingest_operands.jl")
include("ingest_call.jl")
include("ingest_body.jl")
include("ingest_phi.jl")

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
function _lower_parsed_ir(parsed::Bennett.ParsedIR, routine::Symbol;
                          label_prefix::Union{Nothing,Symbol} = nothing,
                          functions::Dict{Symbol,FunctionEntry} =
                              Dict{Symbol,FunctionEntry}(),
                          frame::Bool = true)::VMProgram
    blocks = parsed.blocks
    # CW-B2 (ADR 0019 §2) — `#`-label qualifier for multi-function lowering.
    # `_q` prefixes every BLOCK-IDENTITY label (and every cross-block target,
    # which derives from a block label via `_edge_label`) with
    # `Symbol(string(prefix), "#", string(label))` (the ADR §2 scheme; `#` is
    # collision-proof against the `e_`/`_phi_const_` synthetic conventions,
    # which use `_`, never `#`). When `label_prefix === nothing` (the
    # single-function path) `_q` is the identity, so single-function lowering is
    # byte-identical. Begin/End MARKER labels carry `routine` (already
    # function-unique since names are validated unique) and are NOT `_q`'d — the
    # LabelTable keys off `BasicBlock.label`, not the marker label.
    _q(lbl::Symbol) = label_prefix === nothing ? lbl :
        Symbol(string(label_prefix), "#", string(lbl))
    by_label = Dict{Symbol,Bennett.IRBasicBlock}(b.label => b for b in blocks)
    # `raw_entry_label` keys the RAW-`b.label` internal lookups (`by_label`,
    # `b.label === raw_entry_label`); `entry_label` is the QUALIFIED label that
    # becomes the VMProgram's `entry_label` (and the `FunctionEntry.entry_label`
    # in the multi-function table).
    raw_entry_label = first(blocks).label
    entry_label = _q(raw_entry_label)

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
            push!(preds[dst], _q(_edge_label(src, dst)))
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

    # Constant-call-arg counter (CW-C3, ADR 0019 §3). A reversible VM call
    # passes args by MOVE, so a `ConstOperand` arg (the C idiom `ht_new(2048)`)
    # has no SSA name to MOVE — it is materialised into a fresh synthetic name
    # via a `Define(name, value, :add, 0)` emitted BEFORE the `CallEnter`
    # (mirroring the alloca-pointer/φ-incoming const-create idiom). The counter
    # is monotone across ALL in-module IRCalls of the routine so distinct
    # constant args never collide (`_call_const_arg_name`, ingest_phi.jl).
    call_const_counter = 0

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
    # Internal lookups use RAW `b.label` (`raw_entry_label`); the VMProgram-
    # facing labels are `_q`-qualified at the BasicBlock-construction site below.
    ordered = vcat(by_label[raw_entry_label],
                   [b for b in blocks if b.label !== raw_entry_label])
    for b in ordered
        params = _collect_phi_params(b)
        # Entry marker by predecessor arity.
        if b.label === raw_entry_label
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
        elseif length(preds[b.label]) == 2
            # `ConditionalEntry` is the canonical 2-predecessor join
            # (true/false). Retained as the 2-pred shape for byte-for-byte
            # stability of the pinned collatz / matrix_sum / matrix_tri
            # dispatch+step counts (which all have max in-degree 2).
            #
            # Vestigial condition under L3 replay (ADR 0012 §D4):
            # `_dispatch_to_block!` does NOT read a ConditionalEntry's
            # `condition` (NOR its `predecessor_true/false`) on forward
            # arrival, and backward dispatch is never taken under
            # checkpoint-replay — so any symbol ∉ params satisfies the
            # constructor. A per-block synthetic sentinel `:_cond_<label>`
            # is guaranteed fresh (φ params are LLVM SSA names, never
            # `_cond_`-prefixed) regardless of arg count or naming —
            # robust where `parsed.args[1]` would fail for a zero-arg
            # routine or collide with a φ param.
            cond = Symbol("_cond_", b.label)
            entry = ConditionalEntry(_q(b.label), params, preds[b.label][1],
                                     preds[b.label][2], cond)
        elseif length(preds[b.label]) >= 3
            # ≥3-predecessor join (CW-C3, ADR 0019; the C open-addressing
            # `ht_put` `for.end` block has THREE predecessors — the loop-exit
            # plus two early-return paths — converging on `ret void`). Under L3
            # checkpoint-replay, forward dispatch into a join block consults ONLY
            # the entry marker's `params` for the positional args→params rename
            # (`_dispatch_to_block!`, Interpreter.jl:1287-1326) — it reads
            # NEITHER a `ConditionalEntry.condition` NOR its `predecessor_*`
            # labels, and backward stepping is never per-instruction (the M4.3
            # checkpoint-replay path re-runs forward). So the predecessor labels
            # a `ConditionalEntry` carries are VESTIGIAL on forward; an N-way
            # join needs only a marker that (a) binds the φ params positionally
            # and (b) imposes no fixed predecessor arity. `UnconditionalEntry`
            # (no predecessor fields, just `label` + `params`) is exactly that
            # marker — each of the N trampoline edges sends its own arg list (the
            # critical-edge split, this file's §2), and `_rename_args_to_params!`
            # binds whichever edge fired. This is NOT the "nested-merge lowering"
            # the old reject deferred — it is the correct, minimal N-way merge
            # under the replay reversal model (Law 1: grounded in the dispatch
            # code that ignores predecessor labels, not a guess). A future
            # per-instruction backward-dispatch path (ADR 0019 §3 normative note,
            # bead `xtb` territory) that DID consult predecessor labels would
            # need the full predecessor set here; it does not exist yet, and the
            # join arity is recoverable from the LabelTable when it lands.
            entry = UnconditionalEntry(_q(b.label), params)
        else
            entry = UnconditionalEntry(_q(b.label), params)
        end
        # Body: lowered non-φ instructions, then synthetic constant creates.
        body = Instruction[]
        for inst in b.instructions
            if inst isa Bennett.IRAlloca
                # Alloca needs the bump-allocator state (ADR 0014 §D1 / ADR
                # 0009 Decision 2a), so it is lowered here, not in the pure
                # per-instruction dispatch. A static `ConstOperand(N)` alloca
                # emits a `StackAlloca(dest, base)` (frame-relative create; CW-C3) and advances the cursor
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
                # Bennett.jl emits `IRInsertValue` for homogeneous ArrayType
                # `[N x iW]` AND (Bennett-6bu3) ptr_cells StructType `{ptr,ptr}`
                # / fixed-width-integer tuples. In BOTH cases `n_elems` is the
                # full, well-defined element count (for the struct case it equals
                # `length(field_widths)`), and this index-keyed slot loop is
                # width-AGNOSTIC — it never reads `elem_width`/`field_widths`, so
                # the `{ptr,ptr}` shape ingests UNCHANGED. (i1 `{i64,i1}` overflow
                # structs and float/nested fields still fail loud upstream in the
                # Bennett.jl extractor `_struct_field_widths`.)
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
                # ingest). Bennett.jl emits this for homogeneous ArrayType
                # `[N x iW]` AND (Bennett-6bu3) ptr_cells StructType `{ptr,ptr}`
                # / fixed-width-integer tuples; this index-keyed slot COPY is
                # width-agnostic (`n_elems == length(field_widths)` for the struct
                # case), so the slot model is sound for both.
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
            elseif inst isa Bennett.IRCall &&
                   haskey(functions, _callee_sym(inst.callee)) &&
                   any(a -> a isa Bennett.ConstOperand, inst.args)
                # In-module IRCall with one or more CONSTANT args (CW-C3, ADR
                # 0019 §3). A reversible VM call passes args by MOVE (Vieri 1995
                # p.22 — the arg SSA name is consumed out of the caller frame and
                # rebound under the callee's param), so a `ConstOperand` arg (the
                # C idiom `ht_new(2048)`, `ht_put(t, k, 3)`) has no SSA name to
                # MOVE — guard-5 in `_lower_body_inst` fails loud on it. Because
                # the fix EMITS MULTIPLE instructions (one synthetic `Define` per
                # constant arg, then the `CallEnter`), it does not fit the single-
                # instruction `_lower_body_inst` contract, so it is special-cased
                # HERE, mirroring the `IRAlloca` / `IRInsertValue` branches.
                #
                # For each constant arg, mint a fresh collision-proof name
                # (`_call_const_arg_name`, counter-based) and materialise the
                # constant into it with `Define(name, value, :add, 0)` — the same
                # const-create idiom the φ-incoming constants and the alloca
                # pointer use (non-injective, L3-reversed, no new delta, clean
                # round-trip to empty history). The synthetic name is then passed
                # as the call arg, MOVEd like any SSA arg. Already-SSA args pass
                # through unchanged. The rewritten `IRCall` then flows through the
                # SAME guard-5 path in `_lower_body_inst` (now with all-SSA args),
                # so the void/dest target derivation and arity stay single-sourced
                # there (Law 2 — no duplicated CallEnter-construction logic).
                callee_sym = _callee_sym(inst.callee)
                new_args = Bennett.IROperand[]
                for a in inst.args
                    if a isa Bennett.ConstOperand
                        call_const_counter += 1
                        nm = _call_const_arg_name(callee_sym, call_const_counter)
                        push!(body, Define(nm, Int64(a.value), :add, Int64(0)))
                        push!(new_args, Bennett.SSAOperand(nm))
                    else
                        push!(new_args, a)
                    end
                end
                rewritten = Bennett.IRCall(inst.dest, inst.callee, new_args,
                                           inst.arg_widths, inst.ret_width)
                li = _lower_body_inst(rewritten, functions)
                li === nothing || push!(body, li)
            else
                li = _lower_body_inst(inst, functions)
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
        if term isa Bennett.IRRet && term.op === nothing
            # Void-return form (Bennett-nd45 / BVM ADR 0020 D5b; CW-C2 chunk C):
            # a C `ret void` (`ht_free`/`ht_put`) lowers to `IRRet()` with
            # `op === nothing` + `width == 0` (no value). It becomes an
            # `EndInstruction` with EMPTY returns — `result(rs)` keys off no
            # symbol, and a void callee's `ReturnExit` lands nothing (the empty
            # `CallEnter.targets` shape, ingest_body.jl guard-5). The matching
            # `_declared_returns` (ingest_multi.jl) already returns `Symbol[]`
            # for this terminator, so the function table's `FunctionEntry.returns`
            # is empty and a caller emits empty targets. Placed BEFORE the
            # value-bearing `IRRet` arm so `_lower_operand(nothing)` is never hit.
            exit = EndInstruction(routine, Symbol[])
        elseif term isa Bennett.IRRet
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
                exit = UnconditionalExit(_q(_edge_label(b.label, succs[1])),
                                         Symbol[])
            else
                exit = ConditionalExit(term.cond.name,
                                       _q(_edge_label(b.label, term.true_label)),
                                       _q(_edge_label(b.label, term.false_label)),
                                       Symbol[])
            end
        end
        push!(out, BasicBlock(_q(b.label), entry, body, exit))
    end

    # --- Phase 3: trampoline blocks (one per edge). The trampoline's own
    # label AND its exit target (`dst`) are `_q`-qualified so a multi-function
    # module's edge labels never collide across functions (ADR 0019 §2).
    for ((src, dst), args) in edge_args
        lbl = _q(_edge_label(src, dst))
        push!(out, BasicBlock(lbl,
                              UnconditionalEntry(lbl, Symbol[]),
                              Instruction[],
                              UnconditionalExit(_q(dst), args)))
    end

    arg_widths = Int[w for (_n, w) in parsed.args]
    return VMProgram(out, LabelTable(out), entry_label,
                     arg_widths, copy(parsed.ret_elem_widths),
                     functions, routine)
end

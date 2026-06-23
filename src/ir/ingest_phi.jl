"""
    ParsedIR ingest — φ-parameter collection, CFG edges, synthetic names
    (M_UNBOUNDED.1, ADR 0012 §D4–D5; bead `bennettvm-acq` OPCODE G2)

Split out of `src/ir/ingest.jl` per bead `bennettvm-u110` / Rule 10 (the
~200-LOC ceiling): a PURE MOVE of the φ-resolution + edge-split support
layer — the φ-parameter collector, the per-edge incoming lookup, the CFG
successor reader, the trampoline-label synthesiser, and the synthetic-name
minters (`_phi_const_name` / `_phi_const_dup_name` / `_phi_ssa_dup_name`
for the e4l within-edge duplicates, `_agg_slot_name` for the acq aggregate
slot family).

Included into the same `BennettVM` module before `ingest.jl`'s driver
(`_lower_parsed_ir`), which calls all of these in its three-phase
assembly. Controlling decisions: `docs/adr/0012-collatz-lowering.md` §D4
(φ as block param, Mogensen RSSA §3), §D5 (constant φ-incomings, bead
`bennettvm-e4l`); bead `bennettvm-acq` (the aggregate slot model). See the
original `ingest.jl` docstring for the φ-resolution / critical-edge-split
framing the whole pass rests on.
"""

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

the active register file `active_locals(s)` is a FLAT `Dict{Symbol,Int64}` per frame — one key cannot hold the
N scalar elements of an aggregate. Bennett.jl emits `IRExtractValue` /
`IRInsertValue` for homogeneous ArrayType `[N x iW]` AND (Bennett-6bu3)
ptr_cells StructType `{ptr,ptr}` / fixed-width-integer tuples (per-field layout
via the additive `field_widths::Vector{Int}`); i1 (`{i64,i1}`) and float/
nested fields still fail loud UPSTREAM in extract (`_struct_field_widths`). In
BOTH the array and struct cases `n_elems` is the well-defined element count
(`== length(field_widths)` for structs), so the slot model below is sound. An
aggregate is modelled as a FAMILY of N synthetic per-slot keys, one per element,
reusing the scalar
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

"""
    _call_const_arg_name(callee::Symbol, k::Int) -> Symbol

A FRESH, collision-proof synthetic SSA name for the `k`-th constant
argument of an in-module `IRCall` to `callee` (CW-C3, ADR 0019 §3). A
reversible VM call passes args by MOVE (Vieri 1995 p.22 — the arg SSA name
is consumed out of the caller frame and rebound under the callee's param),
so a `ConstOperand` arg (the C idiom `ht_new(2048)`, `ht_put(t, k, 3)`)
has no SSA name to MOVE. We materialise each constant into its own
synthetic name via a `Define(name, value, :add, 0)` (the same const-create
idiom the φ-incoming constants and alloca-pointer create use,
`ingest.jl`/`_lower_alloca!`) emitted in the caller's body immediately
before the `CallEnter`, then pass the synthetic name as the arg.

`k` is the per-CALLEE monotone occurrence counter threaded through the body
loop (`call_const_counter` in `_lower_parsed_ir`): every distinct constant
arg across the whole routine gets a distinct `k`, so two calls to the same
callee in one function never collide. The `_callconst_` prefix is
collision-proof against the existing synthetic-name conventions — `e_` /
`_phi_const_` / `_phi_ssadup_` / `_agg_` (the `#`-qualifier uses `#`; LLVM
SSA names are numeric / `value_phi*`, never `_callconst_`-prefixed). It
mirrors the counter-based `_phi_const_dup_name` discipline (the
`bennettvm-3ah` DEF-3 lexical-collision hardening): a monotone counter
sidesteps any label/value-shape collision.
"""
_call_const_arg_name(callee::Symbol, k::Int) =
    Symbol("_callconst_", callee, "_", k)

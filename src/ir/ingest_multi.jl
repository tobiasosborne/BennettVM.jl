"""
    Multi-function lowering (CW-B2, ADR 0019 §2 + §8 "Impact")

`lower_vm(funcs::Vector{Pair{Symbol,Bennett.ParsedIR}}; entry)` — the
multi-function entry point. `Bennett.ParsedIR` is SINGLE-FUNCTION (one
`args`, one `blocks`, one `ret_width`; verified
`../Bennett.jl/src/ir_types.jl:438`), so a multi-function MODULE is a vector
of `(name, ParsedIR)` pairs (the Bennett.jl-side multi-function ParsedIR is
CW-C2/CW-D territory — NOT touched here, Rule 14). The lowering:

  1. **Pre-scan the function table.** For each `(name, parsed)` build a
     `FunctionEntry(name, #-qualified entry label, params from `parsed.args`,
     returns from the IRRet terminator)`. The table is complete BEFORE any
     body is lowered, so guard-5 (`ingest_body.jl`) can resolve a forward
     reference (a function calling one declared later in the vector) and can
     read a callee's return arity to set `CallEnter.targets` (void ⇒ empty).
  2. **Lower each function** with `_lower_parsed_ir(parsed, name;
     label_prefix=name, functions=table)` — `#`-qualified block/edge labels
     (ADR 0019 §2) and guard-5 enabled.
  3. **Merge** every function's qualified `BasicBlock`s into ONE flat vector
     with ONE `LabelTable` (ADR 0019 §2 — single flat stream, single label
     table, flat global pc preserved). The module `entry_label` is the entry
     function's qualified entry label; `entry_function` is its name.

# Fail-loud (ADR 0019 §2)

  * No incoming label or function name may contain `#` (the qualification
    separator — a `#` in a raw label would make qualified labels ambiguous).
  * Function names must be unique across the module.
  * `entry` must name a function in the module.

Ref: docs/adr/0019-reversible-calls.md §2 (function table; #-qualification;
     the two fail-loud validations), §8 (Impact: multi-function lowering).
"""

# Content-addressed Julia-set keys (Bennett `extract_parsed_ir_set_from_julia`,
# `../Bennett.jl/src/extract/julia_set.jl:120-121/338`) have the shape
# `<barename>#<8hex-digest>` — the digest disambiguates argtype specialisations
# of one generic function. BennettVM keys its function table by the BARE VM name,
# because the in-set call sites carry only a bare `nameof` (a digest-free
# `Function` callee), so guard-5 (`ingest_body.jl`) resolves against the bare
# name, not the digested key. `_vm_funcname` maps a table KEY to that VM name:
#
#   * digest-shaped (`…#<8hex>`): strip the 9-char `#<digest>` tail, then
#     sanitise any RESIDUAL '#' (a closure barename like `#9` → `.9`) to '.'.
#     '.' is chosen PRECISELY because Julia's `nameof` can NEVER produce '.', so
#     a sanitised closure name can NEVER alias a genuine function name
#     (structurally impossible — not merely detected). This converges with the
#     call-site `_vm_dispatch_name` in `ingest_body.jl`.
#   * '#'-bearing but NOT digest-shaped: malformed — keep the old fail-loud
#     reject ('#' is reserved for label qualification, ADR 0019 §2; Rule 1).
#   * '#'-free (C-track / bare `nameof`): identity — a fixed point.
#
# Ref: docs/adr/0019-reversible-calls.md §2; `../Bennett.jl/src/extract/julia_set.jl`.
const _CONTENT_DIGEST_RE = r"#[0-9a-fA-F]{8}$"

function _vm_funcname(key::Symbol)::Symbol
    s = String(key)
    if occursin(_CONTENT_DIGEST_RE, s)
        # strip `#<8hex>` (9 chars, all ASCII single-byte), sanitise residual '#'.
        return Symbol(replace(s[1:end-9], '#' => '.'))
    elseif occursin('#', s)
        error("lower_vm(multi): function name :", key, " contains '#' but is ",
              "not content-addressed (`<barename>#<8hex-digest>`) — the '#' ",
              "separator is reserved for label qualification (ADR 0019 §2; ",
              "Rule 1 fail-loud).")
    else
        return key
    end
end

# Derive a function's declared returns from its `ParsedIR`, keyed off the
# BY-VALUE return ARITY (`length(parsed.ret_elem_widths)`; bead
# `bennettvm-x3t0`). Mirrors `_lower_parsed_ir`'s End-building:
#   * void (op not an SSAOperand) ⇒ `Symbol[]` (the C `ret void` shape).
#   * scalar (arity ≤ 1) ⇒ `[op.name]` (unchanged — the pre-x3t0 behaviour).
#   * multi-key (arity ≥ 2) ⇒ the `_agg_slot_name` FAMILY of the returned
#     aggregate. The arity is load-bearing (guard-5 reads `length(returns)`);
#     the member NAMES are nominal (this scan reads the FIRST exit's op, so for
#     a multi-exit-block function they name the first exit's family — the
#     per-block `EndInstruction.returns` is authoritative at runtime, see
#     `call_frames.jl` `returns` CAVEAT). `_agg_slot_name` lives in
#     `ingest_phi.jl` (included by `ingest.jl` before this file); it is reached
#     at call time, so include order is satisfied.
function _declared_returns(parsed::Bennett.ParsedIR)::Vector{Symbol}
    n = length(parsed.ret_elem_widths)
    for b in parsed.blocks
        term = b.terminator
        if term isa Bennett.IRRet
            op = term.op
            op isa Bennett.SSAOperand || return Symbol[]           # void
            n <= 1 && return Symbol[op.name]                       # scalar
            return Symbol[_agg_slot_name(op.name, k) for k in 0:n-1]  # multi-key
        end
    end
    return Symbol[]
end

# Total STATIC stack-alloca cells of a function — its activation-record size in
# the global stack segment (CW-C3, ADR 0019; see `src/ir/IState.jl` `stack_top`).
# Sums `n_elems` over every STATIC `IRAlloca` (a `ConstOperand` n_elems), the
# cells the per-function `alloca_cursor` reserves (`_lower_alloca!`). Dynamic-N
# allocas (`SSAOperand` n_elems) ride the SEPARATE `heap_top` offset and do NOT
# count toward the static frame (the hashtable fixture has none; a function
# mixing static + dynamic allocas across a call boundary is out of the O0
# fixture surface — `_lower_alloca!` already fails loud on static-after-dynamic).
# This MUST equal `alloca_cursor - 1` after `_lower_parsed_ir` lowers the same
# function (cursor starts at 1, advances by N per static alloca), which is the
# invariant CallEnter's `stack_top` advance depends on.
function _static_frame_size(parsed::Bennett.ParsedIR)::Int64
    total = Int64(0)
    for b in parsed.blocks
        for inst in b.instructions
            if inst isa Bennett.IRAlloca && inst.n_elems isa Bennett.ConstOperand
                n = Int64(inst.n_elems.value)
                n >= 1 || error("_static_frame_size: IRAlloca(", inst.dest,
                    ") has n_elems=", n, " < 1 — malformed (matches ",
                    "`_lower_alloca!`'s N>=1 guard; Rule 1 fail-loud).")
                total += n
            end
        end
    end
    return total
end

function lower_vm(funcs::Vector{<:Pair{Symbol,Bennett.ParsedIR}};
                  entry::Symbol = first(funcs).first)::VMProgram
    isempty(funcs) &&
        error("lower_vm(multi): empty function vector — a module must have ",
              "at least one function (Rule 1 fail-loud).")

    # (1) Validation + function-table pre-scan (ADR 0019 §2). Table keys are the
    # BARE VM name (`_vm_funcname`), NOT the raw content-addressed key, so the
    # call-site `_vm_dispatch_name` (bare `nameof`) resolves against them.
    seen = Dict{Symbol,Symbol}()   # vmname → originating (raw) key
    table = Dict{Symbol,FunctionEntry}()
    for (name, parsed) in funcs
        vmname = _vm_funcname(name)
        haskey(seen, vmname) &&
            error("lower_vm(multi): content-addressed keys :", seen[vmname],
                  " and :", name, " collide on their bare VM name :", vmname,
                  " — same generic function, different argtype specialisations; ",
                  "call sites carry only a bare `nameof` so cannot disambiguate ",
                  "(ADR 0019 §2; mirrors Bennett julia_set.jl ",
                  "`_closed_world_check!`'s ambiguity guard; Rule 1 fail-loud).")
        seen[vmname] = name
        for b in parsed.blocks
            occursin('#', string(b.label)) &&
                error("lower_vm(multi): block label :", b.label, " in function :",
                      name, " contains '#' — incoming labels may not contain the ",
                      "qualification separator (ADR 0019 §2; Rule 1 fail-loud).")
        end
        params = Symbol[n for (n, _w) in parsed.args]
        entry_label = Symbol(string(vmname), "#", string(first(parsed.blocks).label))
        table[vmname] = FunctionEntry(vmname, entry_label, params,
                                      _declared_returns(parsed),
                                      _static_frame_size(parsed),
                                      copy(parsed.ret_elem_widths))  # x3t0 ABI widths
    end
    # Entry may be passed as the raw digested key OR the pre-de-digested VM name;
    # both map to the same internal name (`_vm_funcname` is a fixed point on the
    # bare name).
    entry_internal = _vm_funcname(entry)
    haskey(table, entry_internal) ||
        error("lower_vm(multi): entry function :", entry, " (VM name :",
              entry_internal, ") is not in the module (functions: ",
              sort!(collect(keys(table))), "; Rule 1 fail-loud).")
    # Entry multi-return guard (CW-D blocker 4, bead `bennettvm-x3t0`). An INNER
    # multi-return (a callee returning an aggregate into a caller's slot family)
    # is x3t0's scope, but the ENTRY routine's return has no caller slot family
    # to land into: `result(rs)` keys the halted frame's registers by their
    # single SSA names, and a by-value multi-register entry return has no such
    # single key. Fail loud rather than key the output off an ambiguous register
    # set; the entry-return ABI is a follow-on (Rule 1).
    length(table[entry_internal].ret_elem_widths) <= 1 ||
        error("lower_vm(multi): entry function :", entry, " (VM name :",
              entry_internal, ") returns a ",
              length(table[entry_internal].ret_elem_widths),
              "-element by-value aggregate (ret_elem_widths=",
              table[entry_internal].ret_elem_widths, ") — entry multi-return is ",
              "DEFERRED: result() keys single registers, so a multi-register ",
              "entry return has no single output key. Bead bennettvm-x3t0 scopes ",
              "INNER multi-returns (a callee landing into a caller's slot family); ",
              "the entry-return ABI is a follow-on. Rule 1 fail-loud.")

    # (2) Lower each function under its bare VM name (`_lower_parsed_ir`'s
    # `routine` + `#`-qualified `label_prefix`), so its qualified block labels
    # (`<vmname>#<label>`) match the `FunctionEntry.entry_label` a CallEnter
    # resolves through.
    # Module-wide const-global segments (bead `bennettvm-416r.13`, Design B D7;
    # subsumes `bennettvm-h6c3`). REPLACES the old single-function-only fail-loud
    # guard. Each function's globals occupy a fresh CONTIGUOUS window based at
    # `GLOBAL_BASE + global_cursor`; after lowering a function the cursor advances
    # by that function's cell count, so windows are DISJOINT by construction — no
    # cross-function base collision (the exact hazard the old guard deferred).
    # The per-function `GlobalROM.cells` are merged into ONE module ROM carried
    # into the merged `VMProgram` below (the old guard also warned the merged
    # program DROPPED per-function globals → silent read-0; both closed here).
    # Globals-free functions contribute zero cells (cursor unmoved), so every
    # existing multi-function fixture (collatz / hashtable) is byte-identical.
    merged = BasicBlock[]
    merged_global_cells = Dict{Int64,Int64}()
    global_cursor = Int64(0)
    for (name, parsed) in funcs
        vmname = _vm_funcname(name)
        prog = _lower_parsed_ir(parsed, vmname; label_prefix = vmname,
                                functions = table,
                                global_base_offset = global_cursor)
        for (addr, val) in prog.globals.cells
            merged_global_cells[addr] = val
        end
        global_cursor += Int64(length(prog.globals.cells))
        append!(merged, prog.blocks)
    end

    # CW-D4 (bead `bennettvm-9n3y`): heap-tier enforcement over the WHOLE
    # merged module — mixed C+Julia allocs fail loud; a Julia-tier module's
    # word-granular memset is rewritten to the byte-exact
    # `IntrinsicMemsetBytes`, and Julia-tier memcpy/memmove fail loud
    # (`src/ir/intrinsics_genericmemory.jl`). Module-wide because the tier is
    # a property of the ONE shared arena, not of any single function.
    _enforce_julia_heap_tier!(merged)

    # (3) Merge into ONE flat stream + ONE LabelTable (ADR 0019 §2). The
    # entry function's qualified entry label is the module entry; the merged
    # LabelTable computes correct flat-stream addresses across all functions
    # because it walks `merged` in order.
    entry_idx = findfirst(p -> _vm_funcname(p.first) === entry_internal, funcs)
    return VMProgram(merged, LabelTable(merged), table[entry_internal].entry_label,
                     Int[w for (_n, w) in funcs[entry_idx].second.args],
                     copy(funcs[entry_idx].second.ret_elem_widths),
                     table, entry_internal, GlobalROM(merged_global_cells))
end

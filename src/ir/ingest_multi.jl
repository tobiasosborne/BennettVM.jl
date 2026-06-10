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

# Derive a function's declared returns from its `ParsedIR` (the IRRet op
# name). Mirrors `_lower_parsed_ir`'s End-building (`retval =
# _lower_operand(term.op)`). A non-SSA / aggregate return is out of scope
# here (the single-function path already fails loud on those); this scan only
# needs the scalar return name for the `FunctionEntry`.
function _declared_returns(parsed::Bennett.ParsedIR)::Vector{Symbol}
    for b in parsed.blocks
        term = b.terminator
        if term isa Bennett.IRRet
            op = term.op
            return op isa Bennett.SSAOperand ? Symbol[op.name] : Symbol[]
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

    # (1) Validation + function-table pre-scan (ADR 0019 §2).
    seen = Set{Symbol}()
    table = Dict{Symbol,FunctionEntry}()
    for (name, parsed) in funcs
        occursin('#', string(name)) &&
            error("lower_vm(multi): function name :", name, " contains '#' — ",
                  "the '#' separator is reserved for label qualification (ADR ",
                  "0019 §2; Rule 1 fail-loud).")
        name in seen &&
            error("lower_vm(multi): duplicate function name :", name,
                  " — function names must be unique across the module (ADR ",
                  "0019 §2; Rule 1 fail-loud).")
        push!(seen, name)
        for b in parsed.blocks
            occursin('#', string(b.label)) &&
                error("lower_vm(multi): block label :", b.label, " in function :",
                      name, " contains '#' — incoming labels may not contain the ",
                      "qualification separator (ADR 0019 §2; Rule 1 fail-loud).")
        end
        params = Symbol[n for (n, _w) in parsed.args]
        entry_label = Symbol(string(name), "#", string(first(parsed.blocks).label))
        table[name] = FunctionEntry(name, entry_label, params,
                                    _declared_returns(parsed),
                                    _static_frame_size(parsed))
    end
    haskey(table, entry) ||
        error("lower_vm(multi): entry function :", entry, " is not in the ",
              "module (functions: ", sort!(collect(keys(table))),
              "; Rule 1 fail-loud).")

    # (2) Lower each function with qualified labels + the full table.
    merged = BasicBlock[]
    for (name, parsed) in funcs
        prog = _lower_parsed_ir(parsed, name; label_prefix = name,
                                functions = table)
        append!(merged, prog.blocks)
    end

    # (3) Merge into ONE flat stream + ONE LabelTable (ADR 0019 §2). The
    # entry function's qualified entry label is the module entry; the merged
    # LabelTable computes correct flat-stream addresses across all functions
    # because it walks `merged` in order.
    return VMProgram(merged, LabelTable(merged), table[entry].entry_label,
                     Int[w for (_n, w) in funcs[findfirst(p -> p.first === entry,
                                                          funcs)].second.args],
                     copy(funcs[findfirst(p -> p.first === entry,
                                          funcs)].second.ret_elem_widths),
                     table, entry)
end

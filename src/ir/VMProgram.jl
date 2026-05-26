"""
    VMProgram (M2.17)

Phase-2 BennettVM program artifact. **Real shape, no longer a stub.**

# What this is now

`VMProgram` is the concrete RSSA-derived program representation that the
lowering pass (M3.x onward) produces and the interpreter (M3.x) consumes.
The 12-instruction RSSA taxonomy and the eight Phase-2 decisions that
shape this struct are locked in `docs/adr/0001-rc3-rvm-smoke.md`
§Observations (decision table).

```julia
struct VMProgram
    blocks::Vector{BasicBlock}    # M2.15 — RSSA basic blocks (paired
                                  # Conditional{Entry,Exit} dispatch).
    label_table::LabelTable       # M2.16 — maps label → dual-address
                                  # `LabelEntry`; the `lastLabel`-style
                                  # runtime resolver for paired-entry
                                  # dispatch (ADR §Obs divergence: no
                                  # source-label-encoded jumps, per RC3
                                  # Mogensen pattern).
    entry_label::Symbol           # the `main` block label.
    arg_widths::Vector{Int}       # Bennett.jl handoff metadata: width
                                  # in bits of each formal argument of
                                  # the ParsedIR being lowered.
    return_widths::Vector{Int}    # same: width per return element.
end
```

# Why `arg_widths` and `return_widths` are real fields, not stub residue

`arg_widths` and `return_widths` survive the M2.17 reshape because they
are **authentic VMProgram-level metadata** — the signature widths of
the `ParsedIR` that was lowered into this program. They are NOT a
digest artifact from M0.2; they are the Handoff-A boundary's typed
shape information that Bennett.jl provides and BennettVM must preserve
for:

  * round-trip equality with Bennett.jl's external view of a program
    (the caller of `lower_vm` reads these to know what to feed in and
    what to expect out);
  * future width-aware lowering (M3.x needs to know how many bits each
    formal argument occupies when allocating slots);
  * Lean formalization of abstract VM semantics (the typing context
    must include argument and return widths).

The two M0.2 fields that **were** stub residue (`n_blocks`,
`n_instructions`) are removed in this milestone — their values are
derivable from `blocks` rather than independently stored.

# Counts are derived, not stored

  * `Base.length(p::VMProgram) = length(p.blocks)` — number of blocks.
  * `n_instructions(p)` — total instruction count across the flat
    layout `[entry, body..., exit]` per block. Exported as a top-level
    function for tests and for future consumers (the interpreter's pc
    upper bound, the pebble-game scheduler's input size, etc.).

This matches the flat-stream layout convention from
`src/ir/label_table.jl` (M2.16): each block contributes
`1 + length(instructions) + 1` to the total. Storing the count as a
field would create a synchronization burden — any future
`push!(blocks, ...)` rewrite would have to remember to update the
count, with no compiler help — and would duplicate information that
the structure already carries.

# Inner-constructor invariants (Rule 1)

The cross-field invariants that can be checked at construction time
(without traversing instruction streams or re-computing addresses)
are:

  1. `length(label_table) == length(blocks)` — every block must have
     an entry in the table. Mismatch indicates a `LabelTable` /
     `Vector{BasicBlock}` construction race (e.g. a block was added
     after the table was built); fail loud per Rule 1.
  2. `haskey(label_table, entry_label)` — the entry label must
     resolve. A `VMProgram` whose `entry_label` is not in its own
     label table cannot be started by the interpreter; failure here
     would otherwise surface as a confusing `KeyError` at the first
     dispatch step.

More stringent invariants — that every label appearing in a block's
`UnconditionalExit.target`, `ConditionalExit.target_true/false`, or
`ConditionalEntry.predecessor_true/false` exists in the label table —
require traversing instruction streams and are M2.18's job (a
dedicated `validate(::VMProgram)` pass). Keeping the inner constructor
fast is the right tradeoff: heavy validation belongs in an explicit
analysis pass that the caller can opt into.

# Backward-compatibility constructor for M0.2 lower_vm digest

`lower_vm` (M0.2, `src/lower_vm.jl`) is still a digest-only stub that
walks a Bennett.jl `ParsedIR` and reports four shape numbers. It does
NOT yet build `BasicBlock`s or a `LabelTable` — that work lands at
M3.x when the full RSSA lowering pass arrives.

To let `lower_vm` continue producing a `VMProgram` value without
materializing blocks it cannot yet produce, we add a convenience
constructor:

```julia
VMProgram(arg_widths, return_widths)
```

This produces a program with empty `blocks`, an empty `LabelTable`,
and `entry_label = :main`. The handoff-smoke regression anchor lives
in the digest STDOUT (printed by `lower_vm`), not in the struct
fields; this constructor is the bridge that keeps the M0.3 test
meaningful while M3.x is still pending. When M3.x lands, callers
will switch to the full-arity constructor and this convenience form
will remain for tests and for direct ParsedIR-digest experiments.

# Show — single-line summary

The `Base.show` method renders `VMProgram(blocks=N, instructions=M,
entry=:L)`. The single-line form is intentional: at the REPL during
M3.x development we want to print programs frequently, so a multi-line
listing (per-block breakdown) would dominate the output. A future
pretty-printer (M3.x or later) can opt into a `MIME"text/plain"`
overload for verbose rendering; the bare `show` stays terse.

# Fields deliberately NOT here yet

| Future field            | Introducing bead / milestone                       |
|-------------------------|----------------------------------------------------|
| `direction::Direction`  | M3.x — per-VM direction flag (RC3 RSSAVM pattern). |
| `history::HistoryTape`  | M4.x — Julia-source history layer (§3.3).          |

Promoting any of these into this struct before its bead lands violates
Phase-2 milestone ordering and the Reuse Map (Law 2).

# Ref

  * `docs/adr/0001-rc3-rvm-smoke.md` §Observations (decision table)
  * `src/ir/basic_block.jl` (M2.15) — `BasicBlock` field layout.
  * `src/ir/label_table.jl` (M2.16) — `LabelTable` construction and
    the flat-stream layout the `n_instructions` helper sums.
  * `/home/tobias/Projects/Bennett.jl/src/ir_types.jl:347-372`
    (ParsedIR shape) — the source of `arg_widths` / `return_widths`.
  * CLAUDE.md Rule 1 (constructor validates inputs); Rule 10 (LOC
    budget — this file stays under 200 code-LOC); Rule 11 (literate
    docstrings).
"""
struct VMProgram
    blocks::Vector{BasicBlock}
    label_table::LabelTable
    entry_label::Symbol
    arg_widths::Vector{Int}
    return_widths::Vector{Int}

    function VMProgram(blocks::Vector{BasicBlock},
                       label_table::LabelTable,
                       entry_label::Symbol,
                       arg_widths::Vector{Int},
                       return_widths::Vector{Int})
        length(label_table) == length(blocks) ||
            error("VMProgram: label_table has ", length(label_table),
                  " entries but blocks has ", length(blocks),
                  "; every block must have exactly one LabelTable entry ",
                  "(M2.17 inner-constructor invariant — likely a ",
                  "LabelTable / Vector{BasicBlock} construction race)")
        # Allow the empty-blocks digest-stub case: when `blocks` is empty
        # the entry_label cannot resolve, but that's the expected shape
        # for M0.2's lower_vm output. Enforce haskey only when there is
        # at least one block to enforce it against.
        if !isempty(blocks)
            haskey(label_table, entry_label) ||
                error("VMProgram: entry_label :", entry_label,
                      " is not in label_table (known labels: ",
                      collect(keys(label_table.entries)),
                      "); a VMProgram whose entry_label is absent from ",
                      "its own LabelTable cannot be started by the ",
                      "interpreter (M2.17 inner-constructor invariant)")
        end
        return new(blocks, label_table, entry_label, arg_widths, return_widths)
    end
end

"""
    VMProgram(arg_widths::Vector{Int}, return_widths::Vector{Int})

Convenience constructor for ParsedIR-digest-only VMPrograms (used by
M0.2's `lower_vm`). Produces an empty-blocks program with a default
empty `LabelTable` and `entry_label = :main`. The real block
population happens at M3.x when the full lowering pass lands.

The empty-blocks shape is what makes the M0.3 handoff-smoke meaningful
while M3.x is still pending: the digest STDOUT carries the
regression-anchor numbers, and this constructor lets `lower_vm`
return a typed `VMProgram` value rather than a placeholder.
"""
function VMProgram(arg_widths::Vector{Int}, return_widths::Vector{Int})
    return VMProgram(BasicBlock[],
                     LabelTable(Dict{Symbol,LabelEntry}()),
                     :main,
                     arg_widths,
                     return_widths)
end

"""
    n_instructions(p::VMProgram) -> Int

Total instruction count across the flat layout `[entry, body..., exit]`
per block in `p.blocks`. Each block contributes
`1 + length(b.instructions) + 1` (M2.16 flat-stream convention).

Derived, not stored — see this file's top-of-module docstring on "Counts
are derived, not stored". Exported as a top-level function so tests, the
M3.x interpreter (for `pc` upper bound), and the M9 pebble scheduler
(for program-size input) can read it uniformly.
"""
function n_instructions(p::VMProgram)::Int
    total = 0
    for b in p.blocks
        total += 1 + length(b.instructions) + 1
    end
    return total
end

"""
    Base.length(p::VMProgram) -> Int

Number of blocks in the program. The block count IS the program's
"length" in the RSSA sense: a program is a sequence of basic blocks.
"""
Base.length(p::VMProgram) = length(p.blocks)

"""
    Base.show(io::IO, p::VMProgram)

Single-line summary of a VMProgram: block count, total instruction
count (via `n_instructions`), and entry label. Terse by design so
REPL printing during M3.x development is readable; a verbose
`MIME"text/plain"` overload can land later if needed.
"""
function Base.show(io::IO, p::VMProgram)
    print(io, "VMProgram(blocks=", length(p.blocks),
              ", instructions=", n_instructions(p),
              ", entry=:", p.entry_label, ")")
end

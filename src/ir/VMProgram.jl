"""
    VMProgram

Phase-2 BennettVM program artifact. **M0.2 stub** — the real struct lands at
M2.17 (bd `bennettvm-tot`).

# What this will become

At M2.17 `VMProgram` will be the concrete RSSA-derived program representation
that the lowering pass produces and the interpreter consumes:

```julia
struct VMProgram
    blocks::Vector{BasicBlock}        # M2.7: RSSA basic blocks with paired
                                      # Conditional{Entry,Exit} dispatch.
    label_table::LabelTable           # M2.10: maps label → block index; the
                                      # `lastLabel`-style runtime resolver
                                      # for paired-entry dispatch (ADR §Obs
                                      # divergence: no source-label-encoded
                                      # jumps, per RC3 Mogensen pattern).
    entry_label::Symbol               # M2.11: the `main` block label.
end
```

The 12-instruction RSSA taxonomy and the eight Phase-2 decisions that
shape this struct are locked in
`docs/adr/0001-rc3-rvm-smoke.md` §Observations (decision table).

# Why a stub now (M0.2)

The Handoff A milestone (PRD v4 §3.7) needs a non-trivial smoke before any
IR design is finalised: M0.4's ADR will run `lower_vm` on
`collatz_steps` and the other three motivating-case `ParsedIR`s, and
M0.3's test must assert *something concrete* about the returned value.
A unit struct (`struct VMProgram end`) would let the smoke pass with no
signal; a four-field digest carrier ensures the test can distinguish
"lowering walked the input" from "lowering returned a placeholder".

The four fields here are exactly the digest payload the bead
(`bennettvm-i61`) names — number of blocks, total instruction count,
argument widths, return widths. They are the *output*, not the *state*,
of the future lowering pass.

# Fields deliberately absent

Each row maps to the introducing bead (see ADR §Observations decision
table for the design source):

| Future field            | Introducing bead / milestone                       |
|-------------------------|----------------------------------------------------|
| `blocks::Vector{...}`   | M2.7 — `BasicBlock` struct (paired Entry/Exit).    |
| `label_table::...`      | M2.10 — `LabelTable` for runtime label resolution. |
| `entry_label::Symbol`   | M2.11 — main-block discovery during lowering.      |
| `direction::Direction`  | M3.x — per-VM direction flag (RC3 RSSAVM pattern). |
| `history::HistoryTape`  | M4.x — Julia-source history layer (§3.3).          |

Promoting any of these into this struct before its bead lands violates
Phase-2 milestone ordering and the Reuse Map (Law 2).

Ref: docs/adr/0001-rc3-rvm-smoke.md §Observations
     /home/tobias/Projects/Bennett.jl/src/ir_types.jl:347-372 (ParsedIR shape)
"""
struct VMProgram
    # M0.2 stub fields — the digest payload, not the future IR state.
    # The real struct (M2.17) replaces these with `blocks`, `label_table`,
    # `entry_label`. Keeping these four lets M0.3's test assert on something
    # concrete without locking in an IR-layer choice.
    n_blocks::Int
    n_instructions::Int
    arg_widths::Vector{Int}
    return_widths::Vector{Int}
end

# Minimal show — single-line summary so REPL probing during M0.3/M0.4 is
# readable. The full multi-line `Base.show` (with block listing and label
# table summary) lands at M2.17 alongside the real struct.
function Base.show(io::IO, p::VMProgram)
    print(io, "VMProgram(blocks=", p.n_blocks,
              ", instructions=", p.n_instructions, ")")
end

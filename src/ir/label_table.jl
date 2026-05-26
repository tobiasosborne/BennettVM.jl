"""
    LabelEntry + LabelTable (M2.16)

The dual-address label table — the key RSSA data structure that
enables reverse execution **without control-flow history**. Phase 2's
load-bearing claim (PRD v4 §3.1) is that an RSSA program is
control-flow-reversible by construction: the interpreter never records
a "which way did we branch" tape, because for every block label the
table carries two distinct program-counter targets — one for forward
arrival, one for backward arrival — and the entry/exit control-flow
markers (M2.8/M2.9/M2.10) carry enough predecessor / successor metadata
that the right one is always selectable from local state.

Concretely:

  * `LabelEntry.fwd_address` — the 1-based instruction index of the
    block's `entry` instruction in the flat instruction stream that
    `VMProgram` (M2.17) materialises from the per-block
    `[entry, instructions..., exit]` layout. The interpreter (M3.x)
    sets `pc` to this value when control transfers **forward** to the
    block.
  * `LabelEntry.bwd_address` — the 1-based instruction index of the
    block's `exit` instruction in that same flat stream. The
    interpreter sets `pc` to this value when control transfers
    **backward** to the block (i.e. arrives via `inverse`-direction
    execution from the block's successor).

`fwd_address` and `bwd_address` are computed once, at table-build
time, from the cumulative instruction count across the
`Vector{BasicBlock}`; the table is then read-only for the program's
lifetime. The two-field layout *is* the data-structure-level
distinction between RSSA control flow and the conditional-stack /
trace-tape control flow that the Phase-0 spike used (and that the
Phase-2 design explicitly rejects). See PRD v4 §3.1.

# Flat-instruction layout

`VMProgram` (M2.17) lays out the blocks as a single flat
`Vector{Instruction}`:

```
[block 1: entry, body[1], …, body[k₁], exit,
 block 2: entry, body[1], …, body[k₂], exit,
 …
 block n: entry, body[1], …, body[kₙ], exit]
```

If block `i` has `nᵢ = 1 + length(body) + 1` total instructions
(entry + body + exit), the cumulative offsets give the per-block
addresses. The first block lives at `fwd=1, bwd=nᵢ`; the second at
`fwd=n₁+1, bwd=n₁+n₂`; etc. `LabelTable(::Vector{BasicBlock})`
implements exactly this scan.

# Why a `Dict{Symbol, LabelEntry}`, not a `Vector` keyed by index

Block lookup is by label (the `Symbol` identity of the block in the
program-level callgraph), not by ordinal. Control-flow instructions
(`UnconditionalExit.target`, `ConditionalEntry.predecessor_true`,
etc.) carry labels — not block indices — because the IR is
constructed before the flat-layout pass runs. A `Dict` is the only
shape that survives reordering of blocks during pebble-game
lowering (M9) and during any future RSSA-level rewrites without
invalidating every cross-block reference. The `block_index` field
on `LabelEntry` is a separate, redundant hint kept available for
the (rare) callers that legitimately need the position in
`VMProgram.blocks`.

# Constructor validation (Rule 1)

`LabelEntry`'s inner constructor rejects four malformed inputs:

  1. `block_index < 1` — Julia is 1-indexed; a 0 or negative index
     is non-physical and almost certainly an off-by-one bug at the
     call site.
  2. `fwd_address < 1` — same reasoning for the flat-stream index.
  3. `bwd_address < 1` — likewise.
  4. `bwd_address < fwd_address` — within any block the exit
     instruction cannot precede the entry instruction; the smallest
     legal value is `bwd_address == fwd_address`, which corresponds
     to the degenerate (and legal — see "Equal-address case" below)
     block whose entry IS its exit.

`LabelTable(::Vector{BasicBlock})` additionally rejects duplicate
block labels at scan time: two blocks sharing a label make the
callgraph ambiguous, and the underlying `Dict{Symbol,…}` would
silently overwrite the first entry with the second otherwise. Fail
loud per Rule 1.

`Base.getindex(::LabelTable, ::Symbol)` raises an `ErrorException`
(not the bare `KeyError` Julia's `Dict` would raise) when a label
is absent, and the error message enumerates the known labels. This
is the diagnostic the interpreter (M3.x) and the lowering pass
(M9) will hit first on a malformed IR; the "known labels" list
short-circuits the inevitable next "which labels DOES the table
hold?" debug step.

# Equal-address case

`bwd_address == fwd_address` is **legal**. It models a block of
length 1 — i.e. a block whose entry IS its exit, which arises when
a block has no body instructions AND its entry/exit pair is
representable by a single physical instruction (the program-level
start/halt marker, in the simplest case). The `LabelEntry`
constructor accepts this; only the strictly-decreasing case is
rejected.

In current Phase-2 IR practice every block has BOTH an `entry`
control-flow marker and an `exit` control-flow marker (M2.15
`BasicBlock` constructor enforces it), so a real-world
`LabelEntry` produced by `LabelTable(::Vector{BasicBlock})` will
always have `bwd_address >= fwd_address + 1`. The
`LabelEntry(_, fwd, bwd)` constructor itself stays permissive so
that a future "single-instruction sentinel" entry (a possibility
the Phase-2 sketch leaves open for the start/halt boundary) can
be represented without changing the inner constructor's contract.

# Why no `Base.setindex!`

The table is built once, at `VMProgram` construction time, and is
read-only thereafter. Exposing `setindex!` would invite the
mistake of mutating addresses after the flat-stream layout is
committed — at which point every prior-cached address goes stale.
`Base.getindex` / `Base.haskey` / `Base.length` are the only
sanctioned access methods.

# Ref

  * `bennettvm_prd.md` (PRD v4) §3.1 — "RSSA IR: per-label dual-address
    table" as the structural alternative to a control-flow history
    tape.
  * `bennettvm_prd.md` (PRD v4) §3.2 — control flow is reversible by
    construction; the table is the data-structure-level expression of
    that property.
  * `references/implementations/RC3/src/LabelEntry.java` — RC3's
    `LabelEntry.java:7` is the direct port template; the Java field
    layout `{int forwardAddress, int backwardAddress}` is mirrored
    here with the additional `block_index` hint.
  * `src/ir/basic_block.jl` (M2.15) — defines `BasicBlock`, whose
    `entry` / `instructions` / `exit` slots dictate the `1 + length(body) + 1`
    per-block instruction count that drives address assignment here.
  * `src/ir/control_instructions.jl` (M2.8/M2.9/M2.10) — defines the
    entry/exit control-flow markers; their `label` / `target` /
    `predecessor_*` fields are what `LabelTable` resolves at dispatch.
  * CLAUDE.md Rule 1 (fail-fast / fail-loud constructors); Rule 10
    (LOC budget — this file stays under 200 code-LOC); Rule 11
    (literate docstrings).
"""

# ============================================================================
# LabelEntry
# ============================================================================

"""
    LabelEntry

The dual-address record for a single block. Three fields:

  * `block_index::Int` — 1-based position of the block in
    `VMProgram.blocks`. A redundant hint relative to the label-keyed
    `LabelTable` lookup, but cheap to keep and useful at the (rare)
    sites that genuinely need the ordinal position (debug printing,
    block-order-sensitive lowering passes).
  * `fwd_address::Int` — 1-based instruction index of the block's
    `entry` instruction in `VMProgram`'s flat instruction stream.
    Forward arrival point.
  * `bwd_address::Int` — 1-based instruction index of the block's
    `exit` instruction in that same flat stream. Backward arrival
    point.

Inner constructor validates `block_index >= 1`, `fwd_address >= 1`,
`bwd_address >= 1`, and `bwd_address >= fwd_address`. Fails loud per
Rule 1.

# Ref

  * `references/implementations/RC3/src/LabelEntry.java:7` — RC3's
    `LabelEntry` record (Java); this struct is the direct port.
"""
struct LabelEntry
    block_index::Int
    fwd_address::Int
    bwd_address::Int

    function LabelEntry(block_index::Int, fwd_address::Int, bwd_address::Int)
        block_index >= 1 ||
            error("LabelEntry: block_index = ", block_index,
                  " < 1; Julia is 1-indexed, every block index must be >= 1")
        fwd_address >= 1 ||
            error("LabelEntry: fwd_address = ", fwd_address,
                  " < 1; the flat instruction stream is 1-indexed, ",
                  "every address must be >= 1")
        bwd_address >= 1 ||
            error("LabelEntry: bwd_address = ", bwd_address,
                  " < 1; the flat instruction stream is 1-indexed, ",
                  "every address must be >= 1")
        bwd_address >= fwd_address ||
            error("LabelEntry: bwd_address = ", bwd_address,
                  " < fwd_address = ", fwd_address,
                  "; within a block, the exit instruction cannot ",
                  "precede the entry instruction (the smallest legal ",
                  "value is bwd_address == fwd_address)")
        return new(block_index, fwd_address, bwd_address)
    end
end

# ============================================================================
# LabelTable
# ============================================================================

"""
    LabelTable

A read-only `Dict{Symbol, LabelEntry}` mapping each block's label to
its dual-address record. Built once, at `VMProgram` construction time
(M2.17), via `LabelTable(::Vector{BasicBlock})`.

Inner constructor performs no validation beyond the `Dict`-level
guarantee that keys are `Symbol`s — the four address-shape checks
live on `LabelEntry`, and the outer `LabelTable(::Vector{BasicBlock})`
constructor handles duplicate-label rejection at scan time.

Sanctioned access methods:

  * `lt[label]` (= `Base.getindex(lt, label)`) — resolve a label to
    its `LabelEntry`; errors descriptively (not a bare `KeyError`) if
    the label is absent.
  * `haskey(lt, label)` — predicate form of the same lookup.
  * `length(lt)` — number of blocks tracked.

Mutation is deliberately not exposed; see this file's top-of-module
docstring "Why no `Base.setindex!`".
"""
struct LabelTable
    entries::Dict{Symbol, LabelEntry}

    LabelTable(entries::Dict{Symbol, LabelEntry}) = new(entries)
end

"""
    LabelTable(blocks::Vector{BasicBlock}) -> LabelTable

Build the `LabelTable` for a vector of blocks. Scans the blocks once,
accumulating per-block instruction counts to compute each block's
`fwd_address` (the index of its `entry` instruction in the flat
stream) and `bwd_address` (the index of its `exit` instruction).

The flat-instruction layout is `[entry, instructions..., exit]` per
block, concatenated in block-index order. A block with body-length
`k` therefore contributes `n = 1 + k + 1` instructions to the flat
stream; `fwd = pos`, `bwd = pos + n - 1`, then `pos += n` for the
next block.

Rejects duplicate block labels at scan time (Rule 1). Two blocks
sharing a label would make the underlying `Dict` overwrite silently;
fail loud instead.

# Ref

  * `src/ir/basic_block.jl` (M2.15) — `BasicBlock` field layout
    (`label`, `entry`, `instructions`, `exit`); the
    `1 + length(instructions) + 1` count comes from this layout.
  * PRD v4 §3.1 — RSSA flat-stream layout convention.
"""
function LabelTable(blocks::Vector{BasicBlock})
    entries = Dict{Symbol, LabelEntry}()
    pos = 1
    for (i, bb) in enumerate(blocks)
        haskey(entries, bb.label) &&
            error("LabelTable: duplicate block label :", bb.label,
                  " (blocks[", i, "] collides with an earlier block); ",
                  "every block in a VMProgram must have a unique label")
        n = 1 + length(bb.instructions) + 1   # entry + body + exit
        fwd = pos
        bwd = pos + n - 1
        entries[bb.label] = LabelEntry(i, fwd, bwd)
        pos += n
    end
    return LabelTable(entries)
end

# ============================================================================
# Lookup methods
# ============================================================================

"""
    Base.getindex(lt::LabelTable, label::Symbol) -> LabelEntry

Resolve `label` to its `LabelEntry`. Raises a descriptive
`ErrorException` (Rule 1) if the label is not in the table; the
message enumerates the known labels to short-circuit the inevitable
next "which labels DOES the table hold?" debug step.

This is the canonical lookup the interpreter (M3.x) and the
lowering pass (M9) use; bare `KeyError`s from the underlying
`Dict` are deliberately suppressed so that an absent label gives
the user a useful failure mode on the first try.
"""
function Base.getindex(lt::LabelTable, label::Symbol)
    haskey(lt.entries, label) ||
        error("LabelTable: no entry for label :", label,
              " (known labels: ", collect(keys(lt.entries)), ")")
    return lt.entries[label]
end

"""
    Base.haskey(lt::LabelTable, label::Symbol) -> Bool

Predicate form of the `getindex` lookup. Returns `true` iff `label`
is in the table. Does not raise on absence.
"""
Base.haskey(lt::LabelTable, label::Symbol) = haskey(lt.entries, label)

"""
    Base.length(lt::LabelTable) -> Int

Number of blocks tracked by the table. Equal to the length of the
`Vector{BasicBlock}` passed to `LabelTable(::Vector{BasicBlock})`
(assuming no duplicates, which the constructor enforces).
"""
Base.length(lt::LabelTable) = length(lt.entries)

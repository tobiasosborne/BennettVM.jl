"""
    Heap intrinsics — bulk memory ops (`memset` / `memcpy` / `memmove`)
    (CW-A, ADR 0018 §B/§D; bead `bennettvm-416r.3`)

The three runtime-length bulk-memory intrinsics, split out of `intrinsics.jl`
(Rule 10 — the arena allocs + these bulk ops together exceeded the ~200 LOC
cap; ADR 0018 §H anticipated the split). They share `intrinsics.jl`'s helpers
(`_cell_count`, `_cell_pattern`, `_range_deltas`, `_restore_deltas!`,
`CELL_BYTES`), which is why this file is `include`d immediately AFTER
`intrinsics.jl` (both into the same `BennettVM` module).

All three OVERWRITE a runtime-length **dest** range, so all three reverse by an
**L2 vector of per-cell `(addr, old, was_present)`** deltas — the `MemoryStore`
schema repeated `cells` times, captured PRE-`forward` via `predelta_payload`.
Post-change-7 the memset payload carries NO `fill` field: the inverse restores
purely from the triples, and each triple is independent so it needs no
`reverse()` (`_restore_deltas!`, `src/ir/intrinsics.jl`). The missing-sentinel
guard (a cell ABSENT pre-overwrite is `delete!`d, not written `0`) is in
`_restore_deltas!` — the same `MemoryStore` `was_present`→`delete!` branch.

`memcpy` requires dest/src DISJOINT (C UB on overlap) — fail loud (Rule 1,
ADR 0018 §E), never silently miscopy. `memmove` permits overlap; the
read-before-write snapshot in `_copy_range!` is overlap-safe in both
directions (the simplest correct realisation). For an overlapping memmove the
DEST-range delta still captures every overwritten cell (the clobbered src cells
are a subset of the dest range), so the L2 reversal is complete.

# Ref

  * `docs/adr/0018-heap-floor.md` §B (memset/memcpy/memmove rows), §D (memset
    runtime-n pseudocode, post-change-7), §E (overlapping-memcpy fail-loud).
  * `src/ir/intrinsics.jl` — the shared helpers + the arena allocs; this
    file's sibling.
  * `src/ir/memory_floor.jl` — the `MemoryStore` per-cell delta + missing-
    sentinel guard the dest-range delta repeats.
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse MemoryStore schema), Rule 10
    (the split), Rule 11 (literate).
"""

# ===========================================================================
# IntrinsicMemset — runtime-n fill; L2 per-cell (addr, old, was_present) delta.
# ===========================================================================

struct IntrinsicMemset <: Instruction
    ptr_operand::Symbol             # dest pointer SSA name (an Int64 addr)
    byte_operand::Union{Symbol,Int64}    # fill byte (low 8 bits used)
    nbytes_operand::Union{Symbol,Int64}  # length in BYTES
end

function predelta_payload(instr::IntrinsicMemset, s::IState)
    base = _resolve(instr.ptr_operand, s)
    cells = _cell_count(_resolve(instr.nbytes_operand, s))
    return (deltas = _range_deltas(s, base, cells),)   # NO fill (change-7)
end

function forward(instr::IntrinsicMemset, s::IState)::IState
    base = _resolve(instr.ptr_operand, s)
    cells = _cell_count(_resolve(instr.nbytes_operand, s))
    fill = _cell_pattern(_resolve(instr.byte_operand, s))
    for a in base:(base + cells - 1)
        s.memory[a] = fill
    end
    s.pc += 1
    return s
end

inverse(::IntrinsicMemset, s::IState, p::NamedTuple)::IState =
    (_restore_deltas!(s, p.deltas); s.pc -= 1; s)

inverse(instr::IntrinsicMemset, s::IState, prev)::IState =
    error("IntrinsicMemset reverses via its L2 per-cell delta, not the L3-prev ",
          "path (ADR 0018 §B). Rule 1 fail-loud.")

# ===========================================================================
# IntrinsicMemcpy / IntrinsicMemmove — runtime-n copy; L2 dest-range delta.
# ===========================================================================

struct IntrinsicMemcpy <: Instruction
    dest_ptr::Symbol                # dest pointer SSA name
    src_ptr::Symbol                 # src  pointer SSA name
    nbytes_operand::Union{Symbol,Int64}  # length in BYTES
end

struct IntrinsicMemmove <: Instruction
    dest_ptr::Symbol
    src_ptr::Symbol
    nbytes_operand::Union{Symbol,Int64}
end

const _MemCopy = Union{IntrinsicMemcpy,IntrinsicMemmove}

# Capture the DEST range only (ADR 0018 §B): src is READ, never overwritten, so
# the src cells need no delta. (For overlapping memmove the dest-range delta
# still fully captures every overwritten cell, since the src cells that get
# clobbered are a subset of the dest range.)
function predelta_payload(instr::_MemCopy, s::IState)
    d = _resolve(instr.dest_ptr, s)
    cells = _cell_count(_resolve(instr.nbytes_operand, s))
    return (deltas = _range_deltas(s, d, cells),)
end

# Shared copy: snapshot the src cells FIRST, then write into dest — the
# read-before-write snapshot is overlap-safe in BOTH directions (the simplest
# correct realisation, used by memmove and by the disjoint memcpy alike).
function _copy_range!(s::IState, d::Int64, src::Int64, cells::Int64)
    vals = [get(s.memory, src + i, Int64(0)) for i in 0:(cells - 1)]
    for i in 0:(cells - 1)
        s.memory[d + i] = vals[i + 1]
    end
    return s
end

# memcpy: dest/src MUST be disjoint (C UB on overlap) — fail loud (Rule 1,
# ADR 0018 §E), never silently miscopy.
function forward(instr::IntrinsicMemcpy, s::IState)::IState
    d = _resolve(instr.dest_ptr, s); src = _resolve(instr.src_ptr, s)
    cells = _cell_count(_resolve(instr.nbytes_operand, s))
    (d + cells <= src || src + cells <= d || cells == 0) ||
        error("IntrinsicMemcpy.forward: dest [", d, ", ", d + cells,
              ") and src [", src, ", ", src + cells, ") OVERLAP — C `memcpy` ",
              "is UB on overlap; use memmove. Rule 1 fail-loud (never ",
              "silently miscopy). nbytes_operand=", instr.nbytes_operand, ".")
    _copy_range!(s, d, src, cells)
    s.pc += 1
    return s
end

# memmove: overlap permitted (the snapshot in `_copy_range!` makes it safe).
function forward(instr::IntrinsicMemmove, s::IState)::IState
    d = _resolve(instr.dest_ptr, s); src = _resolve(instr.src_ptr, s)
    cells = _cell_count(_resolve(instr.nbytes_operand, s))
    _copy_range!(s, d, src, cells)
    s.pc += 1
    return s
end

inverse(instr::IntrinsicMemcpy, s::IState, p::NamedTuple)::IState =
    (_restore_deltas!(s, p.deltas); s.pc -= 1; s)
inverse(instr::IntrinsicMemmove, s::IState, p::NamedTuple)::IState =
    (_restore_deltas!(s, p.deltas); s.pc -= 1; s)

inverse(instr::IntrinsicMemcpy, s::IState, prev)::IState =
    error("IntrinsicMemcpy reverses via its L2 dest-range delta, not the ",
          "L3-prev path (ADR 0018 §B). Rule 1 fail-loud.")
inverse(instr::IntrinsicMemmove, s::IState, prev)::IState =
    error("IntrinsicMemmove reverses via its L2 dest-range delta, not the ",
          "L3-prev path (ADR 0018 §B). Rule 1 fail-loud.")

"""
    GenericMemory allocation model + the byte-granular Julia heap tier
    (CW-D4, bead `bennettvm-9n3y`)

The Julia closed-world heap tier's object model, split out of `intrinsics.jl`
(Rule 10 — the struct + `_ArenaAlloc` union membership stay THERE because the
union definition must see the type; this file holds the specialized `forward`,
the byte-exact `IntrinsicMemsetBytes`, and the tier-enforcement pass).

# The wall this closes (scratchpad/scout-cwd4-element-traffic.md)

`jl_alloc_genericmemory_unchecked` used to lower to a bare bump alloc that
wrote NOTHING — but a Julia `GenericMemory` is a self-describing `{length,
data-ptr}` whose data-ptr the native *runtime* sets (no emitted-IR store site
exists — verified: callee_rehash!.ll stores the LENGTH at field 0, line 737,
and never field 1). Every element access reads that field, got absent = 0, and
slots/keys/vals collapsed onto one shared cell (`vals` overwrote `keys`,
read-back missed, `__unreachable__`).

# The model (design-cwd4-A, architecture ruling; mechanics from design-cwd4-B)

    base = ARENA_BASE + arena_top                (deterministic bump)
    reserve GM_HEADER_CELLS(16) + nbytes_data    (byte-granular cells)
    M[base + 8] = base + 16                      (data-ptr := inline data base)
    length (M[base+0]) is NOT written — the program's own explicit
    `store i64 nelems, {i64,ptr}#0` owns it (callee_rehash!.ll:737).

BYTE granularity is FORCED, not chosen: the data-ptr field is read through TWO
GEP shapes — the word-shaped `getelementptr {i64,ptr}, ptr %m, i32 0, i32 1`
(element path) AND the byte-shaped `getelementptr i8, ptr %m, i32 8` (the
fill!/memset `.ptr_ptr` path, RUNTIME length, live — callee_rehash!.ll:755-769)
— and the shipped 416r.13 `jl_global#NNN` singleton headers already fixed
length@byte-cell 0 / data-ptr@byte-cell 8. The Bennett.jl front-end re-stamps
the `{i64,ptr}` header GEP to `elem_width = 8` (scoped to the LITERAL Julia
header shape; named C `%struct.T` keeps 64), so BOTH shapes land on cell +8.

# Reversibility

The data-ptr write rides the EXISTING `_ArenaAlloc` L2 `(base, cells)` delta:
`base+8 ∈ [base, base+cells)` and was ABSENT pre-alloc (fresh region — the
disjoint-window invariant, asserted fail-loud in `forward`), so the inverse's
unconditional region-`delete!` restores absent-ness exactly (the
`IntrinsicCalloc` precedent; the `alloca.jl` unconditional-delete lemma applies
verbatim). Round-trips `arena_top 0→…→0`, `memory {}→…→{}`, history empty.

# The tier split (C untouched)

  * C/malloc tier (`IntrinsicMalloc/Calloc/Realloc`): word-granular `÷8`,
    SWAR memset, wide loads — BYTE-IDENTICAL to pre-CW-D4.
  * Julia tier (`IntrinsicGCAlloc` / `IntrinsicGenericMemoryAlloc`):
    byte-granular reservations; `memset` rewritten to the byte-exact
    `IntrinsicMemsetBytes`; `memcpy`/`memmove` fail loud (unmodeled byte-tier
    span); mixing the two tiers in ONE program fails loud.
    Dispatch is on the INTRINSIC KIND (malloc… = C; gc_alloc_obj /
    genericmemory = Julia), never on heuristics (the CW-D4 ruling).

# Still-unmodeled (fail-loud completeness, Rule 1)

  * Non-bitstype / boxed Memory elements (`Memory{String}`) — element traffic
    would carry pointers into an unallocated object graph; the extractor's
    walls reject upstream (no VM-side surface reaches here).
  * GenericMemory GROW/copy (`jl_genericmemory_copy*`, the 2nd-insert rehash)
    — not in `_HEAP_DISPATCH` → the ingest allowlist miss already fails loud.
  * Wide elements (elsize > 1): element `i` lives at byte-cell
    `data-ptr + i·elsize`, ONE cell holding the full value — self-consistent
    for whole-element loads/stores; PARTIAL-overlap access (sub-element
    aliasing) remains the VM-wide sub-cell limitation (unchanged here).

# Ref

  * scratchpad/design-cwd4-A.md (architecture) / design-cwd4-B.md (mechanics).
  * scratchpad/callee_rehash!.ll:716,734 (nbytes = smul(nelems, elsize) — DATA
    bytes, header-exclusive), :736-737 (length store), :755-769 (byte-shaped
    data-ptr read + runtime-length memset).
  * `src/ir/intrinsics.jl` — struct, `GM_HEADER_CELLS`, `_byte_cells`,
    `_alloc_cells`, `_ArenaAlloc` union (predelta/inverse inherited).
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse the L2 region-delete),
    Rule 11 (literate).
"""

# The ONE method that differs from the `_ArenaAlloc` union: reserve header +
# data, then write the data-ptr header cell (the native runtime's job). More
# specific than `forward(::_ArenaAlloc, s)` — Julia dispatch picks this one.
function forward(instr::IntrinsicGenericMemoryAlloc, s::IState)::IState
    cells = _alloc_cells(instr, s)
    base = ARENA_BASE + s.arena_top
    # Disjoint-window guard (Rule 1): the fresh region must be ABSENT — a
    # present data-ptr cell means a prior allocation's granularity regressed
    # into this window (the exact CW-D4 header-clobber bug class).
    haskey(s.memory, base + 8) &&
        error("IntrinsicGenericMemoryAlloc.forward: header data-ptr cell ",
              base + 8, " is already PRESENT pre-alloc — the fresh arena ",
              "region [", base, ", ", base + cells, ") must be absent ",
              "(disjoint-window invariant; a prior allocation overlapping ",
              "this window is the CW-D4 header-clobber bug class). ",
              "Rule 1 fail-loud.")
    active_locals(s)[instr.dest] = base
    s.memory[base + 8] = base + GM_HEADER_CELLS   # data-ptr := inline data base
    s.arena_top += cells
    s.pc += 1
    return s
end

# ===========================================================================
# IntrinsicMemsetBytes — the Julia-tier byte-exact fill (CW-D4).
# ===========================================================================
#
# The C `IntrinsicMemset` is WORD-granular: `nbytes ÷ 8` cells, each filled
# with the SWAR pattern (byte smeared across 8 cell bytes) — correct for the C
# tier's wide loads, WRONG for the byte-granular Julia tier twice over (span ÷8
# too short; a nonzero fill would smear). The Julia tier's `fill!(mem, v)` →
# `llvm.memset` (rehash!'s slots fill, runtime length) instead fills `nbytes`
# byte-cells each holding the byte VALUE — exact for any fill byte and any
# prior cell state. Same L2 per-cell `(addr, old, was_present)` reversal as
# `IntrinsicMemset` (the `MemoryStore` schema; `_restore_deltas!`).
struct IntrinsicMemsetBytes <: Instruction
    ptr_operand::Symbol                  # dest pointer SSA name (an Int64 addr)
    byte_operand::Union{Symbol,Int64}    # fill byte (low 8 bits used)
    nbytes_operand::Union{Symbol,Int64}  # length in BYTES == byte-cells
end

function predelta_payload(instr::IntrinsicMemsetBytes, s::IState)
    base = _resolve(instr.ptr_operand, s)
    cells = _byte_cells(_resolve(instr.nbytes_operand, s))
    return (deltas = _range_deltas(s, base, cells),)
end

function forward(instr::IntrinsicMemsetBytes, s::IState)::IState
    base = _resolve(instr.ptr_operand, s)
    cells = _byte_cells(_resolve(instr.nbytes_operand, s))
    fill = Int64(_resolve(instr.byte_operand, s) & 0xff)   # byte VALUE, no smear
    for a in base:(base + cells - 1)
        s.memory[a] = fill
    end
    s.pc += 1
    return s
end

inverse(::IntrinsicMemsetBytes, s::IState, p::NamedTuple)::IState =
    (_restore_deltas!(s, p.deltas); s.pc -= 1; s)

inverse(instr::IntrinsicMemsetBytes, s::IState, prev)::IState =
    error("IntrinsicMemsetBytes reverses via its L2 per-cell delta, not the ",
          "L3-prev path (CW-D4; the IntrinsicMemset row). Rule 1 fail-loud.")

# ===========================================================================
# _enforce_julia_heap_tier! — the whole-program tier pass (CW-D4).
# ===========================================================================

"""
    _enforce_julia_heap_tier!(blocks) -> blocks

(`blocks::Vector{BasicBlock}` — untyped in the signature because this file is
included BEFORE `ir/basic_block.jl`; the two call sites, `lower_vm.jl` and
`ingest_multi.jl`, both pass the concrete `Vector{BasicBlock}`.)

Post-lowering pass over the (merged) block list, called by BOTH `lower_vm`
entry points. Classifies the program's heap tier by INTRINSIC KIND (the CW-D4
ruling — never heuristics): `IntrinsicMalloc/Calloc/Realloc` ⇒ C tier;
`IntrinsicGCAlloc/GenericMemoryAlloc` ⇒ Julia byte tier.

  * BOTH tiers in one program → fail loud (their reservation granularities
    would alias in one arena — impossible under closed-world single-source,
    defended anyway; design-cwd4-A D9).
  * Julia tier: every `IntrinsicMemset` is REWRITTEN to the byte-exact
    `IntrinsicMemsetBytes` (same operands — the fill!/llvm.memset path);
    `IntrinsicMemcpy`/`IntrinsicMemmove` fail loud (their `÷8` span is not a
    byte-tier op; the rehash-grow copy is the predicted next wall, and it must
    arrive loudly, not as a silently-eighth-length copy).
  * C tier / no allocs: byte-identical no-op.
"""
function _enforce_julia_heap_tier!(blocks)
    _is_julia_alloc(i) = i isa IntrinsicGCAlloc || i isa IntrinsicGenericMemoryAlloc
    _is_c_alloc(i) = i isa IntrinsicMalloc || i isa IntrinsicCalloc ||
                     i isa IntrinsicRealloc
    has_julia = any(b -> any(_is_julia_alloc, b.instructions), blocks)
    has_c     = any(b -> any(_is_c_alloc, b.instructions), blocks)
    if has_julia && has_c
        error("lower_vm: mixed-tier program — the C/malloc heap tier ",
              "(word-granular ÷8 reservations: malloc/calloc/realloc) and the ",
              "Julia heap tier (byte-granular reservations: gc_alloc_obj / ",
              "jl_alloc_genericmemory_unchecked) may not share ONE program: ",
              "the two granularities would alias in one arena (CW-D4, bead ",
              "bennettvm-9n3y; design-cwd4-A D9). Rule 1 fail-loud.")
    end
    has_julia || return blocks
    for b in blocks
        for (k, i) in pairs(b.instructions)
            if i isa IntrinsicMemset
                b.instructions[k] = IntrinsicMemsetBytes(
                    i.ptr_operand, i.byte_operand, i.nbytes_operand)
            elseif i isa IntrinsicMemcpy || i isa IntrinsicMemmove
                error("lower_vm: ", typeof(i), " in a JULIA-tier program ",
                      "(byte-granular cells) is unmodeled — its word-granular ",
                      "÷8 span would silently copy an eighth of the byte range ",
                      "(CW-D4, bead bennettvm-9n3y; the rehash-grow element ",
                      "copy is the predicted next wall). Rule 1 fail-loud.")
            end
        end
    end
    return blocks
end

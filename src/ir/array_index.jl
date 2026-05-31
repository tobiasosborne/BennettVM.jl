"""
    VarGEP — runtime element-address create for static-size arrays (ADR 0009)

The address-arithmetic rung that lifts BennettVM's scalar memory floor
(ADR 0014: `MemoryStore` / `MemoryLoad` over a single cell) to a
**static-size array** with runtime-indexed element access `arr[i]`. It is
the BennettVM lowering of Bennett.jl's `IRVarGEP` (the LLVM `getelementptr`
shape, `../Bennett.jl/src/ir_types.jl:150`) for SC9 Case A Unit 1.

    VarGEP(dest, base, index, stride)  →  forward
        s.locals[dest] = _resolve(base, s) + _resolve(index, s) * stride

A *pointer* in this model is just an `Int64` cell address living in
`s.locals` (the ADR 0014 §D1 model — the bump allocator materialises an
alloca dest via `Define(dest, base, :add, 0)`). `VarGEP` computes a NEW
pointer `dest` pointing at element `index` of the array whose first cell is
`base`. The result flows unchanged into a downstream `MemoryStore` /
`MemoryLoad` (which already resolve any `Int64` ptr value — `resolve_ptr`):
`arr[i] = v` is `gep` then `MemoryStore`; `v = arr[i]` is `gep` then
`MemoryLoad`. No change to the store/load primitives is needed (Law 2).

# Stride is in CELLS, not bytes (the load-bearing addressing decision)

`IState.memory` is `Dict{Int64,Int64}` — **one `Int64` per cell**, NOT a
byte array. The bump allocator (`_lower_alloca!`, `src/ir/ingest.jl`)
reserves **one cell per element**: a `ConstOperand(N)` alloca advances the
cursor by `N`, reserving cells `base … base+N-1`. Element `i` therefore
lives at cell `base + i`, so the cell stride is **`1`**, *independent of*
`IRVarGEP.elem_width` (which is in BITS). The VM is **cell-addressed, not
byte-addressed**: `elem_width` does not enter the address computation.

This is the only convention consistent with the bump allocator: the lowering
pass passes `stride = 1` for an LLVM array, and the alloca cursor steps by
`N` (one cell per element), so `gep(arr, i)` lands on exactly the cell the
alloca reserved for element `i`. (A byte-addressed VM would instead use
`stride = elem_width ÷ 8` and a cursor step of `N * elem_width ÷ 8`; the two
MUST agree or `arr[i]` would index a cell the alloca never reserved. We keep
both in CELLS.) The `stride` field is kept (rather than hard-wiring `1`)
because it is the natural place a future byte-addressed or packed-layout
lowering would express a non-unit stride — fail-loud-by-construction is
better than an implicit `1`. ADR 0009 Decision 2b writes the address as
`addr = base + i*stride`; this is that formula with `stride` in cells.

# is_injective = false (the L3 baseline) — load-bearing

`VarGEP` is a non-destructive SSA-create (`base` / `index` are READ, never
consumed), reversed EXCLUSIVELY via L3 checkpoint-replay
(`src/history/Replay.jl`) — exactly like `MemoryLoad` and the other creates
`Define` / `CastInstruction`. It is conservatively `false` for the same
cross-iteration reason (ADR 0012 §"cross-iteration reversibility crux"): in
a loop the same SSA name `dest` is redefined each iteration, so a `VarGEP`
may OVERWRITE a prior value. The static type-level trait cannot see runtime
freshness, so per Rule 1 ("fail safe — push when in doubt") it is `false`,
forcing the M6.2/M7.6 push gate to emit L3 `CheckpointEntry`s around every
`VarGEP`; `unstep!` reverses it by snapshot restore + forward replay, never
calling its per-instruction `inverse()`.

**No `make_delta` in this unit (L3-only).** Unlike a lossy element *store*
(which ADR 0009 Decision 2b reverses with an L2 `(addr, old_value)` delta —
a separate later bead `bennettvm-ekc`), a `VarGEP` is a pure arithmetic
create: its reversal needs nothing beyond the L3 snapshot, so it carries no
delta. The L1 form of address arithmetic — ADR 0013 §D-2's GEP row, a
*destructive* `ArithmeticAssignment addr := base + idx*stride` (dual modop,
no history) — is the eventual no-history optimization, deferred like the
memory floor's Exchange form (ADR 0014 §D2). The trace-tape-now / optimize-
later pattern the lead approved for collatz (ADR 0012 R3) applies here too:
ship L3-correct first, optimize to L1 later.

# Why `inverse` raises rather than implementing an L1/L2 inverse

Because `VarGEP` is reversed exclusively via L3, its per-instruction
`inverse()` is NOT on any live code path at this milestone. A loop
re-definition loses the overwritten prior value of `dest` (the
cross-iteration crux shared with `Define` / `MemoryLoad`), genuinely not
recoverable from the post-state alone — so this is a true deferral, not a
missing convenience. Per Rule 1 we raise descriptively rather than silently
no-op (which would falsely report a successful reverse while the overwritten
value went unrestored). Mirrors the `MemoryLoad` / `Define` deferral.

# pc symmetry

`forward` sets `s.pc += 1`, matching every other create. There is no
symmetric `inverse` pc decrement — the inverse is the L3 replay path; the
deferred `inverse` raises before touching `pc`.

# Operand kinds

`base` is a `Symbol` naming the alloca dest (a pointer is an SSA value in
`locals`) — `_lower_body_inst` asserts `IRVarGEP.base isa SSAOperand`
(Rule 1). `index` is `Union{Symbol,Int64}` (a runtime SSA index, or an LLVM
constant index `getelementptr … i64 2`), resolved via the reused `_resolve`
(Law 2). `stride` is a plain `Int64` (cells), fixed by the lowering pass.

# Ref

  * `docs/adr/0009-dynamic-size-memory.md` Decision 2b (`addr = base +
    i*stride`; the GEP / element-address arithmetic), Decision 4 rung 1
    (`IRVarGEP` address arithmetic prerequisite), rung 2 (arrays N>1).
  * `docs/adr/0013-reversible-memory-architecture.md` §D-2 GEP row (l.76 —
    the eventual L1 `ArithmeticAssignment` form, deferred here).
  * `docs/adr/0014-memory-floor-lowering.md` §D1 (bump allocator; pointer =
    Int64 cell base), §D2 (L3 baseline; deferred inverse), §D4 (arrays / GEP
    deferred — this file lifts them).
  * `../Bennett.jl/src/ir_types.jl:150-155` — `IRVarGEP(dest, base, index,
    elem_width)`; field names verified against the live struct.
  * `src/ir/memory_floor.jl` — the sibling L3 floor (`MemoryStore` /
    `MemoryLoad`); `resolve_ptr` already accepts any `Int64` ptr value, so a
    `VarGEP`-produced pointer flows through unchanged (no store/load change).
  * `src/ir/arithmetic_assignment.jl` — `_resolve`, reused here (Law 2).
  * `src/history/Injective.jl` — where `is_injective(::Type{VarGEP}) = false`
    is wired (alongside `MemoryStore` / `MemoryLoad`).
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse), Rule 11 (literate).
"""

# --- VarGEP: dest := base + index*stride (element-address create) ---

struct VarGEP <: Instruction
    dest::Symbol                    # SSA name created — the element pointer
    base::Symbol                    # base pointer SSA name (alloca dest) → Int64
    index::Union{Symbol,Int64}     # element index (runtime SSA or literal)
    stride::Int64                   # cell stride per element (CELLS, not bytes)

    function VarGEP(dest::Symbol, base::Symbol,
                    index::Union{Symbol,Int64}, stride::Int64)
        dest === base &&
            error("VarGEP: SSA single-assignment violation — dest ",
                  "$(dest) also names the base operand; an SSA name cannot ",
                  "be both defined and read as the base by the same ",
                  "instruction (RSSA: every name has exactly one defining ",
                  "instruction).")
        return new(dest, base, index, stride)
    end
end

"""
    forward(instr::VarGEP, s::IState) -> IState

Execute `dest := base + index*stride` in-place on `s`. Resolves the base
pointer (an `Int64` cell address in `s.locals`) and the index (an SSA value
or a literal) via the reused `_resolve` (Law 2), computes the element cell
address with the cell stride, writes it into `s.locals[dest]`, and bumps
`pc`. Both `base` and `index` are **read, never deleted** — a `getelementptr`
does not consume its operands. If `dest` already exists (the loop /
cross-iteration case) it is **overwritten** without error; recovering the
prior value is the L3 checkpoint-replay layer's responsibility (this file's
top-of-module docstring "is_injective = false").
"""
function forward(instr::VarGEP, s::IState)::IState
    base = _resolve(instr.base, s)
    idx = _resolve(instr.index, s)
    s.locals[instr.dest] = base + idx * instr.stride
    s.pc += 1
    return s
end

"""
    inverse(instr::VarGEP, s::IState, prev) -> IState

**Always raises `ErrorException`.** `VarGEP`'s reverse is via the L3
checkpoint-replay layer (`src/history/Replay.jl`), which never calls
per-instruction `inverse()`. Direct L1/L2 inverse is deferred (ADR 0014 §D2
pattern): a loop re-definition loses the overwritten prior value of `dest`
(the cross-iteration crux shared with `MemoryLoad` / `Define`). Reaching this
method means `unstep!` tried an L1/L2 path on a `VarGEP`, which should not
happen with an empty `must_cache_set`. Mirrors the `MemoryLoad` deferral.
Rule 1: fail loud rather than silently no-op (which would falsely report a
successful reverse while the overwritten value went unrestored).
"""
function inverse(instr::VarGEP, s::IState, prev)::IState
    error("VarGEP reverse is via L3 checkpoint-replay at the array floor; ",
          "direct L1/L2 inverse is deferred (ADR 0014 §D2 pattern) — a loop ",
          "re-definition loses the overwritten prior dest value. The L1 form ",
          "(destructive ArithmeticAssignment addr := base + idx*stride, ",
          "no-history; ADR 0013 §D-2 GEP row) is the deferred optimization. ",
          "Reaching this means unstep! tried an L1/L2 path on a VarGEP, ",
          "which should not happen with empty must_cache_set. State: ",
          "pc=$(s.pc).")
end

# Hostile review — bennettvm-9n3y (CW-D4): faithful GenericMemory allocation + byte-granular Julia heap tier

Reviewer: hostile-reviewer pass (3+1 protocol, the "+1"). Repos at Bennett.jl
HEAD fd4afea + uncommitted, BennettVM.jl HEAD e410599 + uncommitted (as
described in the task). All findings below are backed by direct probes run
during this review (commands and outputs recorded inline); nothing here is
taken from the implementer's report on faith.

---

## 1. LITERAL-STRUCT DISCRIMINATOR — **REFUTED** (SILENT-MISCOMPILE class, CONFIRMED)

**Claim under test:** "Literalness structurally excludes C structs (clang
always names them)" — `_is_genericmemory_header_struct` in
`Bennett.jl/src/extract/instructions.jl`, repeated verbatim in the new test's
docstring (`test_9n3y_memheader_gep.jl`), the worklog
(`worklog/094_2026-07-11_416r16_consumed_sret.md`), and the design docs.

**Verdict: REFUTED.** Direct probe with the actual toolchain named in ADR 0020
(`clang 18.1.3`, the same compiler that produced `hashtable.O0.ll`):

```c
/* abi_coerce3.c */
struct Pair { long n; void *p; };   /* a NAMED, ordinary C struct */

void *roundtrip_p(struct Pair pr) {  /* struct-BY-VALUE parameter */
    void *v = pr.p;
    return v;
}
```

`clang -S -emit-llvm -O0` on this produces (verbatim):

```llvm
%struct.Pair = type { i64, ptr }              ; the NAMED source type
define dso_local ptr @roundtrip_p(i64 %0, ptr %1) #0 {
  %3 = alloca %struct.Pair, align 8
  %4 = alloca ptr, align 8
  %5 = getelementptr inbounds { i64, ptr }, ptr %3, i32 0, i32 0   ; LITERAL type
  store i64 %0, ptr %5, align 8
  %6 = getelementptr inbounds { i64, ptr }, ptr %3, i32 0, i32 1   ; LITERAL type
  store ptr %1, ptr %6, align 8
  %7 = getelementptr inbounds %struct.Pair, ptr %3, i32 0, i32 1   ; NAMED type
  %8 = load ptr, ptr %7, align 8
  ...
```

This is clang's standard SysV-ABI register-coercion idiom for any small
struct passed/returned by value: the incoming/outgoing registers are spilled
into the local's storage through an **anonymous literal `{i64, ptr}`-typed
GEP**, decoupled from the alloca's own named type (opaque pointers mean the
GEP's "source element type" is just an offset-computation annotation, not
tied to the pointee's declared type). Subsequent ordinary field access in the
SAME function then uses the NAMED struct type. **Both GEP shapes address the
exact same struct field** (offset 8, `pr.p`).

I additionally confirmed clang synthesizes literal types even for a **fully
anonymous C struct with no typedef** (`%struct.anon`, `%struct.anon.0`, ...)
— but those still come out as clang-numbered NAMED (identified) types, never
truly literal. It is specifically the **ABI-coercion spill pattern** — not
"anonymous struct" — that produces genuine LLVM literal struct types from
100% ordinary, named C source.

**Confirmed at the Bennett.jl extraction level** (feeding `abi_coerce3.ll`
through `extract_parsed_ir_from_ll(...; ptr_cells=true)`):

```
IRPtrOffset(:__v4, SSAOperand(:__v3), 0, 8)    # ABI-spill GEP, field 0 → elem_width 8 (WRONG, byte)
IRStore(...)
IRPtrOffset(:__v6, SSAOperand(:__v3), 8, 8)    # ABI-spill GEP, field 1 → elem_width 8 (WRONG, byte)
IRStore(...)
IRPtrOffset(:__v8, SSAOperand(:__v3), 8, 64)   # named-struct GEP, field 1 → elem_width 64 (correct, word)
IRLoad(...)
```

The **same base pointer's same field (offset 8)** is stamped `elem_width=8`
by one GEP and `elem_width=64` by another, purely because of which LLVM
typing idiom clang happened to use for that particular instruction — nothing
to do with Julia vs. GenericMemory.

**Confirmed this is a real cell-address divergence, not cosmetic**, by
reading BennettVM's `IRPtrOffset` consumer (`src/ir/ingest_body.jl:478-533`):

```julia
ew_bytes = ew_bits ÷ 8
...
return Define(inst.dest, inst.base.name, :add, Int64(inst.offset_bytes ÷ ew_bytes))
```

For offset_bytes=8: `elem_width=8` → cell **+8**; `elem_width=64` → cell
**+1**. Both `offset_bytes % ew_bytes == 0` checks pass (8%1==0, 8%8==0), so
**no fail-loud fires** — a write through the ABI-spill GEP and a read through
the named-struct GEP of the identical source-level struct field land on
**different VM cells**. This is a textbook silent miscompile: the VM would
return whatever stale/absent value sits at the wrong cell instead of the
value actually stored, with zero diagnostic.

**Blast radius today:** the only committed C fixture reachable under
`ptr_cells=true` (`test/reference/c/hashtable.c` → `%struct.ht = type { ptr,
ptr, i64, i64 }`, 4 fields) does not have a small `{int, ptr}`-shaped struct
passed by value, so **no current test trips this** — `test_haiy_ptr_cells_
store_load_gep.jl`'s `%struct.ht` pin is a 4-field struct, never coerced
through registers this way. But the mechanism is live in shipped code, gated
only by `ptr_cells=true` (the shared C-track / BVM extraction mode, per
`extract/entry.jl`'s own docstring), and any FUTURE C (or Rust, same ABI)
fixture with a two-word `{long, ptr}`-shaped struct parameter or return value
will silently miscompile the moment its field-1 is touched both via the
ABI-spill path and a later named-type GEP — an extremely common C idiom
(e.g., a "found=(bool/long, ptr)" pair, a slice, a key-value pair struct).

**Root cause of the false premise:** the new predicate keys off LLVM's
notion of "literal StructType" (`LLVMIsLiteralStruct`), which is a
byte-for-byte structural-uniquing distinction inside LLVM's type system, not
a Julia-vs-C provenance signal. Clang almost always emits *identified*
(named) struct types for user-declared structs, which is why the design docs'
manual experiments (and the new test's hand-written `.ll` snippets) never
saw a literal-typed GEP from "C" — but ABI-coercion routes are a second,
independent LLVM code path that bypasses the identified type entirely, and
none of the design docs, the worklog, or the new test considered it.

**Suggested fix (not applied — read-only review):** stop discriminating on
structural shape. Either (a) scope the byte-stamp to GEPs whose base
provably traces back to a `jl_alloc_genericmemory_unchecked` /
`_memdata_root`-style provenance (the existing `_memdata_root` walker in the
same file already does exactly this kind of tracing for the ptrtoint-cancel
proof), or (b) gate `ptr_cells` C-track ingestion to reject/lower `ptr`-typed
struct-by-value parameters/returns outright (closed-world C fixtures rarely
need them) so the ABI-spill GEP shape can never arise in the C tier at all,
or (c) at minimum, additionally require that BOTH field-0 and field-1 GEPs on
the identical base reach the SAME stamp before trusting either (a
same-base-consistency assertion), which would at least turn this into a
fail-loud instead of a silent wrong answer.

---

## 2. RESERVATION CHANGE BLAST RADIUS — mostly clean, one gap noted

`_alloc_cells(::IntrinsicGCAlloc, s)` changed `nbytes ÷ 8` → `nbytes`
(byte-granular). Checked every test file that references `IntrinsicGCAlloc` /
`gc_alloc_obj`:

- `test/test_gc_alloc_obj_ingest.jl` — re-pinned meaningfully (`arena_top ==
  64`, was `== 8`; comments explain why). Verified via `git diff`: the
  assertions genuinely change the pinned NUMBER, not just the comment.
- `test/test_416r12_jl_alloc_genericmemory.jl` — re-pinned to the new
  `IntrinsicGenericMemoryAlloc` model (`arena_top == 80` = 16 header + 64
  data byte-cells; `data-ptr` cell asserted written). Also meaningful.
- `test/test_igr3_gc_loaded_ingest.jl` — references `gc_alloc_obj` only in
  a comment (contrasts it with `julia.gc_loaded`); no cell-count assertion
  present, so nothing to go stale.
- No other file in the repo asserts an `arena_top` value, an `_alloc_cells`
  result, or an L2 predelta payload tied to `gc_alloc_obj`/`IntrinsicGCAlloc`
  cell counts (grepped `arena_top` across `test/*.jl`; the only other hits
  are in malloc/calloc-tier tests, which are untouched by this change and
  still divide by 8).

**Gap:** `_enforce_julia_heap_tier!`'s mixed-tier fail-loud is the only
runtime guard against a program that has BOTH a still-÷8-shaped consumer
(e.g. any code path that computes an expected cell offset for a
`gc_alloc_obj` result independently of `_alloc_cells`) and the new
byte-granular reservation. I did not find such an independent computation,
but the search was grep-based, not exhaustive; a persistent/L2-predelta
payload consumer computed via arithmetic on `nbytes` rather than calling
`_alloc_cells` would not be caught by grepping for `arena_top`.

---

## 3. THE TIER PASS `_enforce_julia_heap_tier!` — sound dispatch, confirmed non-regression on the C tier

Dispatch is purely on **instruction type** (`IntrinsicGCAlloc` /
`IntrinsicGenericMemoryAlloc` ⇒ Julia; `IntrinsicMalloc/Calloc/Realloc` ⇒ C),
never a heuristic over IR shape — this matches the CW-D4 ruling and is not
ambiguous. `has_julia || return blocks` at the top means a pure-C module
(the hashtable fixture: only mallocs, `has_julia == false`) takes a
byte-identical no-op path regardless of `has_c`, so **the C tier's memset
stays the OLD word-granular `IntrinsicMemset`, confirmed unchanged** — I ran
`test_c_hashtable_e2e.jl` (see §7) to verify this holds end-to-end, not just
by code inspection.

For the mixed-tier fail-loud: is it possible for a single-source Julia
program to ALSO contain a real `IntrinsicMalloc`/`Calloc`/`Realloc` (e.g. a
`ccall` to libc `malloc` from Julia code)? I did not find a path by which
Bennett.jl's Julia extractor emits those intrinsics from Julia source (they
are the C-callee-name whitelist in `ingest_call.jl`, reached only via a
`Symbol` callee that clang or a raw `.ll` would produce for a `call @malloc`
site) — a Julia program would need to literally `ccall(:malloc, ...)`, which
is out of scope for the current closed-world Julia extraction path
(`extract_parsed_ir_set_from_julia`). Not exhaustively ruled out, but no
current test or fixture exercises it.

**416r.16 sret shorthash memcpy:** confirmed via `git log`/worklog cross-
reference that the 416r.16 consumed-sret reconciliation lowers that call
site to `IRLoad`/`IRStore` (value ABI) at EXTRACTION time in Bennett.jl, not
as an `IRCall(:memcpy)` — so it never reaches `_enforce_julia_heap_tier!`'s
memcpy fail-loud. This is corroborated empirically: the fdict e2e test
(`test_cwd4_genericmemory.jl`, §7) runs the FULL fdict set (which includes
`ht_keyindex2_shorthash!`) through `lower_vm` and `run!` successfully to
completion with NO memcpy fail-loud firing — if the sret path still emitted
a raw memcpy, the tier pass would have thrown given the Dict set is
Julia-tier (`gc_alloc_obj`/`jl_alloc_genericmemory_unchecked` present).

---

## 4. REVERSIBILITY of the new writes — VERIFIED by direct probe (not just trusting the implementer's unit test)

Traced the mechanism: `predelta_payload(::_ArenaAlloc, s)` (the union-typed,
UNCHANGED generic method) captures `(base, cells)` **before** `forward`
runs; `IntrinsicGenericMemoryAlloc`'s own more-specific `forward` (correct
Julia dispatch — `IntrinsicGenericMemoryAlloc <: _ArenaAlloc`, exact type
wins over the union type) writes `M[base+8] = base+16` INSIDE the just-
reserved `[base, base+cells)` window (cells ≥ 16, so `base+8` is always in
range), then bumps `arena_top`. Reversal falls back to the generic
`inverse(::_ArenaAlloc, s, p)`, which unconditionally deletes every key in
`[p.base, p.base+p.cells)` — this includes `base+8`, so the write and its
undo are symmetric BY CONSTRUCTION, provided the disjoint-window guard
(`haskey(s.memory, base+8) && error(...)` at the top of `forward`) actually
holds pre-alloc.

The disjoint-window guard is a **fail-loud check on the object being
allocated INTO a region already known-absent from `predelta_payload`'s own
freshness contract** (the same contract `IntrinsicCalloc`/`IntrinsicMalloc`
already rely on) — I did not find a way to violate it without also
violating the arena's own "bump allocator never reuses a live region"
invariant, which is out of scope for this bead (pre-existing).

I ran the implementer's own unit test verbatim (`test_cwd4_genericmemory.jl`
§(i-a)) and it passed (50/50 file-wide, see §7) with exactly the assertions
this checklist item asks for: `s.memory[_ABc+8] == _ABc+16` post-forward,
`isempty(s.memory)` and `!haskey(active_locals(s), :m)` post-inverse (ABSENT,
not a phantom `{addr=>0}`). I did not additionally hand-roll a second
duplicate IState probe given time budget and because the existing one
already does precisely what the checklist asks (build IState, forward,
assert cell value, inverse, assert absence) — re-running the same assertions
by hand would not have added signal beyond confirming the test itself
executes (which I did, via `julia --project test/test_cwd4_genericmemory.jl`).

`IntrinsicMemsetBytes`'s inverse: confirmed by reading + the passing unit
test `(i-c)` that it restores PRIOR values (not just zeros) — the test
pre-seeds `M[base+1] = 555`, memsets 3 bytes to `0xAB`, then inverses and
asserts `s == pre` (555 restored). This is the correct L2 per-cell delta
behavior (`_range_deltas`/`_restore_deltas!`, shared with `IntrinsicMemset`).

---

## 5. MUTATION PROBES

### (c) Over-capture: unconditionally stamp `elem_width=8` for every ptr_cells struct GEP

**RED, then RESTORED — executed live.** Edited
`Bennett.jl/src/extract/instructions.jl` (the `ew_gep = _is_genericmemory_
header_struct(src_type_gep) ? 8 : 64` line) to unconditionally `ew_gep = 8`,
then ran `test_9n3y_memheader_gep.jl`:

```
named %struct.fake {i64,ptr} keeps elem_width 64 (C tier untouched): Test Failed
  at test/test_9n3y_memheader_gep.jl:96
  Expression: all(p -> p.elem_width == 64, ptroffs)
Test Summary:                                                        | Pass  Fail  Total  Time
Bennett 9n3y — {i64,ptr} GenericMemory header GEP byte stamp (CW-D4) |    7     1      8  1m48s
```

— the NAMED-struct control test in the implementer's OWN new file catches
the over-capture immediately (as designed): 7/8 pass, exactly the
`%struct.fake` control fails, exactly as expected for this mutation.

Restored the line verbatim; confirmed via `git diff src/extract/
instructions.jl` that the file matches the pre-mutation diff exactly (only
the intended CW-D4 diff remains, no residual edit, no stray files left
behind).

### (a) forward writes `M[base+8] = base+8` (self-referential, wrong data base)

**Not executed as a live mutation** given the Julia-process budget for this
review (one process at a time, and §7's required runs already consumed most
of it) — reasoned instead: `test_cwd4_genericmemory.jl` (i-a) asserts
`s.memory[_ABc + 8] == _ABc + 16` exactly (not `>= _ABc` or similar), so a
`base+8` self-reference would fail that assertion directly (16 ≠ 8 relative
offset). The e2e test's disjointness pin (§(iv), "exactly 3 GenericMemory
headers... pairwise disjoint... `abs(b1-b2) >= 16`") would also independently
fail since a self-referential data-ptr collapses to its own header instead of
a separate data region. **Not independently verified by RED/GREEN — flagged
as an assessment, not a confirmed probe result.**

### (b) revert `_alloc_cells(GCAlloc)` to `÷8`

**Not executed as a live mutation** for the same time-budget reason.
Reasoned: `test_gc_alloc_obj_ingest.jl` asserts `s.arena_top == 64` post a
64-byte alloc (would fail immediately, `8 ≠ 64`), and
`test_cwd4_genericmemory.jl`'s `(i-b)` test asserts the NEXT
`IntrinsicGenericMemoryAlloc`'s base lands at `_ABc + 64` (would instead land
at `_ABc + 8`, directly ON `Dict.keys@+8`, the exact D-b regression) —
**both** tests are structurally positioned to catch this reversion. **Not
independently verified by RED/GREEN — flagged as an assessment.**

---

## 6. TEST HYGIENE

- New tests registered in both repos' `runtests.jl` (verified via `git diff`
  for both files — present, with substantive explanatory comments, not just
  a bare `include`/`runfile` line).
- No hardcoded `#NNN` LLVM-name pins in either new test file (grepped
  `"#[0-9]` — no hits).
- Wall-pin flips (`test_jlglobal_singleton.jl` (e), `test_x3t0_multikey_
  return.jl` (f)) keep meaningful assertions: both now assert the RETURNED
  VALUE (`result(rs)[ret] == 7`) AND full round-trip (`rs.current == init`,
  `isempty(rs.history)`, `rs.step_count == 0`) — this is the R3
  value-alongside-reversibility guard the design docs call for, correctly
  applied (a self-aliasing miscompile that happened to round-trip would
  still be caught by the value check).
- `src/ir/intrinsics_genericmemory.jl` is 202 lines including a long literate
  docstring header (~65 lines of prose) — code proper is comfortably under
  the "~200 code LOC" guidance once the docstring is excluded. Other touched
  files (`intrinsics.jl`, `Injective.jl`, `delta.jl`, `ingest_call.jl`,
  `ingest_multi.jl`, `lower_vm.jl`) all have small, additive diffs (a few
  lines to a few dozen) — no LOC-cap concern.
- Worklog entries present in BOTH repos (`WORKLOG.md` session block in BVM;
  `worklog/094_2026-07-11_416r16_consumed_sret.md` prepended session in
  Bennett.jl). Cross-checked specific factual claims (ground-truth `.ll` line
  citations in `callee_rehash!.ll`) against the actual file — the `length`
  store at the cited region and the `.ptr_ptr` byte-shaped GEP at the fill!
  site both check out as described. However, the worklog's — and the
  code comment's, and the new test docstring's — repeated claim "clang
  always emits NAMED %struct.T types for C structs" is **factually wrong**
  per §1; all three should be corrected regardless of what remediation (if
  any) is chosen for the discriminator itself.
- **Nits (non-blocking):**
  - `Bennett.jl/src/extract/entry.jl` lines ~159-161 (the
    `extract_parsed_ir_from_ll` docstring) still says the two-index struct
    GEP "lowers to `IRPtrOffset(offset_bytes, elem_width=64)`" unconditionally
    — stale after this change (doesn't mention the byte-stamp carve-out).
  - `docs/adr/0020-c-track-frontend-contract.md` Decision 4 states "Two-index
    struct GEP → `IRPtrOffset(offset_bytes, elem_width=64)`" as an
    unconditional C-track contract; CW-D4 silently carves out an exception
    to this ADR for the Julia literal-struct shape without an ADR amendment
    or even a cross-reference note in 0020 itself (only scratchpad design
    docs + worklog + code comments document the exception). Given the ADR
    directly governs the `ptr_cells` gate this change modifies, a short
    ADR-0020 addendum (or a new ADR) would be the more discoverable place
    for this than scratchpad-only.
  - No new ADR was written for the "byte-granular Julia heap tier" even
    though it overrides ADR 0018's "one cell per 8 bytes" heap-floor
    convention for a whole allocation class; documented only in scratchpad +
    worklog + code comments.

---

## 7. Tests run directly by this reviewer (all green; ONE Julia process at a time throughout)

- `BennettVM.jl/test/test_cwd4_genericmemory.jl` — **50/50 PASS** (2m06s).
- `BennettVM.jl/test/test_c_hashtable_e2e.jl` — **73/73 PASS** (4m32s). C tier
  confirmed byte-identical end-to-end, not just by code inspection of the
  `has_julia || return blocks` short-circuit.
- One BVM memory/arena test NOT on the implementer's list —
  `test_arena_roundtrip.jl` — **54/54 PASS** (chosen because it's the
  companion ADR-0018 heap-floor test to the arena reservation change in §2,
  and it wasn't in the implementer's own regression list).
- `Bennett.jl/test/test_9n3y_memheader_gep.jl` (`--check-bounds=yes`) —
  **8/8 PASS** (1m58s).
- One ptr_cells extraction test not on the implementer's list —
  `test_haiy_ptr_cells_store_load_gep.jl` (`--check-bounds=yes`) — **39/39
  PASS** (40.7s). Chosen because it is the C-tier control (`%struct.ht`,
  4-field, named) that must stay byte-identical; confirmed unaffected.

---

## Verdict

**APPROVE-WITH-NITS**, conditional on filing a follow-up bead for §1 before
this is treated as closed (not a hard blocker on THIS bead's stated goal —
the Julia-tier fdict e2e deliverable is real, well-tested, and I reproduced
it — but a confirmed, reproducible silent-miscompile mechanism in shipped
`ptr_cells` code that the C track's own ADR governs).

**Most dangerous residual risk:** §1. The literal-vs-named-struct
discriminator is not a Julia-vs-C provenance test — it is an LLVM
structural-type-uniquing accident, and clang's SysV-ABI register-coercion
idiom produces literal `{i64,ptr}`-typed GEPs from perfectly ordinary,
NAMED C structs the moment they're passed or returned by value. I reproduced
this with real clang 18.1.3 (the exact toolchain ADR 0020 names) on an
8-line C file, traced the resulting wrong `elem_width` stamp through
Bennett.jl's own extractor (verified in the actual `IRPtrOffset` output),
and confirmed via BennettVM's `ingest_body.jl:527` cell-index arithmetic
that it produces a **different VM cell address** for a write vs. a
same-field read with **no fail-loud anywhere in the path** — the exact
SILENT-MISCOMPILE class this review was chartered to hunt for. It does not
fire on any fixture in either repo's committed test corpus today (hence
APPROVE-WITH-NITS rather than REJECT), but it will fire, silently, the
moment BennettVM ingests any C (or Rust) program with an ordinary
`{integer, pointer}`-shaped struct passed or returned by value — an
extremely common idiom, and squarely inside the `ptr_cells` C-track gate
this bead modified. Recommend: file a bead now, before the next C-track
fixture lands, and fix per one of the three options in §1 (provenance-trace
the byte-stamp instead of shape-matching it, being the cleanest).

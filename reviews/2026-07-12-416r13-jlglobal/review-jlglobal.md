# Hostile review — bennettvm-416r.13 (`jl_global#NNN` singleton-data globals)

Reviewer role: 3+1 orchestrator (+1), hostile-reviewer pass. Verified against
the actual uncommitted diff in both repos, ground-truth docs
(`scratchpad/scout-jlglobal-census.md`, `design-jlglobal-A.md`,
`design-jlglobal-B.md`), and live test runs / mutation probes. No edits made
except this file (probe mutations were applied and reverted; `git diff --stat`
confirmed byte-identical to pre-probe state after each revert).

## What actually landed (correcting the task framing)

The task description attributes the adopted design to "design-jlglobal-A.md
(adopted: fail-loud fall-through, poison→rejected as incompatible, read-window
trap)". Reading both design docs and the actual diff: the landed mechanism is
**Design B's** core architecture (reuse `ParsedIR.globals`, no new field,
name-based aliasing of drifting load results, `_referenced_global_names`
operand-reflection in `_global_segment`) with **Design A's** D2 fail-loud
tightening and (a variant of) D5's read-window trap folded in. Design A's
POISON data-ptr sub-mechanism was explicitly dropped (confirmed in BVM
WORKLOG.md's "POISON" paragraph and `src/ir/ingest_call.jl`/`memory_floor.jl`
— no poison band exists; only the read-window `haskey` trap + a TLS carve-out).
This is a documentation/attribution nit, not a code defect — flagging it
because the task brief itself slightly misstates which design shipped.

## Per-claim signoffs

**1. RECOGNIZER OVER-CAPTURE — REFUTED (no over-capture found).**
`_is_singleton_data_global_name` (`^jl_global#\d+$`) is consulted only inside
`_extract_const_globals`'s `init === nothing` arm (module_walk.jl:952-980,
reached only when `LLVM.initializer(g)` **throws** — i.e. the aliasee is an
unrepresentable `GlobalAlias`/`inttoptr`) and in a belt-and-suspenders `else`
fallback that additionally requires `LLVM.value_type(init) isa
LLVM.PointerType`. Both arms run strictly *after* the `ConstantDataArray` /
`ConstantStruct` / `ConstantAggregateZero` / `ConstantInt` dispatch chain
(sequential `if...elseif...else`), so a `jl_global#NNN`-named global with a
genuinely readable initializer (struct/array/int) is captured by the matching
real-data arm and **never reaches** the singleton fallback — verified by
reading the full function body (module_walk.jl:917-1080) end to end. Traced
one concrete non-singleton `jl_global#77` case in the census (an empty-String
literal fed to `AssertionError(::String)` on a dead path) — it also throws the
same GlobalAlias signature and is correctly modelled as a zero header (Julia's
empty String is itself an empty-Memory-backed singleton, so this is not a
counterexample). Residual: the empirical claim "every `jl_global#NNN` that
throws here is an empty singleton" is not exhaustively proven for all possible
Julia programs, but the *fail-loud fall-through* (claim 3) and the *VM
read-window trap* (claim 5) jointly bound the blast radius of a future
counterexample to a loud crash, not a silent miscompile — this is the design's
own stated mitigation (D6) and it holds up under inspection.

**2. ALIASING OVER-CAPTURE — REFUTED.**
The singleton arm only fires when `ptr isa LLVM.GlobalVariable` where `ptr =
ops[1]` is the **raw, unprocessed pointer operand** of the `load`
instruction (instructions.jl:3459). A GEP'd interior load (`load i64, ptr
getelementptr(..., @"jl_global#N", i32 8)`) has a `LLVM.ConstantExpr` or
`GetElementPtrInst` operand, not a bare `GlobalVariable` — the arm cannot
fire, and such a load falls through to the pre-existing constant-GEP /
IRPtrOffset handling untouched by this change. Verified this is exactly the
shape Julia emits for the singleton case (`%p = load ptr, ptr
@"jl_global#71"`, no GEP) per the census. A width mismatch (e.g. a
hypothetical `load i64, ptr @"jl_global#N"` instead of `load ptr, ...`) would
still be captured by the singleton arm (it doesn't gate on
`LLVM.value_type(inst)`, unlike the later fail-loud arm which explicitly
does) — but since the VM's aliasing target is always just an Int64 *address*
cell, aliasing an i64-typed load to the same address value is not a
soundness gap, only an asymmetry with the fail-loud arm's guard. Nit, not a
bug (see Nits below).

**3. FAIL-LOUD TIGHTENING — VERIFIED, no regression found.**
Ran `test_416r13_jlglobal_singleton.jl` (new, 16/16 pass), `test_qal5`
(10/10), `test_iwo9_typetag.jl` (30/30 — **not** on the implementer's list),
`test_r92o_gc_alloc_obj.jl` (22/22 — **not** on the implementer's list), and
`test_d1b_julia_set.jl` (33 pass / 1 `@test_broken`, matching the worklog's
"33/34 (1 pre-existing broken)" claim exactly — the broken test is a
pre-existing, explicitly-tracked `@test_broken` gated on CW-D2, confirmed by
reading the test file's own comments, not a regression). The new fail-loud is
scoped tightly (`ptr_cells && ptr isa GlobalVariable && result-type is
Pointer`), so a scalar `load iN, ptr @global` (the shape every existing
non-Dict ptr_cells fixture uses for readable const data) keeps its
pre-existing silent skip. `ptr_cells=false` callers are provably unaffected
(the whole tightened arm and the singleton arm are `ptr_cells`-gated; the one
non-gated call site, `test_vbv9_arena_memcpy.jl:196`, uses the 1-arg
`_extract_const_globals(mod)` form which defaults `ptr_cells=false`).

**4. THE DELETED GUARD — VERIFIED disjoint, cross-function drift handled correctly.**
Read `ingest_multi.jl`'s replacement: `global_cursor` starts at 0, each
function calls `_lower_parsed_ir(...; global_base_offset = global_cursor)`,
then `global_cursor += length(prog.globals.cells)`. Each function's own
`_global_segment` call gets a **fresh** local `name_to_base` Dict (it's a
local variable inside `_global_segment`, re-created per call) — so even if
two functions coincidentally share the literal name `jl_global#71` for
*different* underlying singletons (numbering drift), they are never
conflated: each function's globals are seeded independently at
`GLOBAL_BASE + base_offset + local_offset`, and `base_offset` strictly
increases per function, guaranteeing disjoint windows with no off-by-one (
verified by the `(b) two functions → disjoint module-wide singleton windows`
test: 32 cells total, `GB`, `GB+16`, `GB+31` all present — confirmed by
running it, 25/25 pass). The complementary risk — the *same* runtime
singleton referenced by *different* drifting names in two functions — is
real but explicitly bounded in Design B D7/WORKLOG: only the root `fdict_d1b`
PIR references singleton data pointers directly; `rehash!`/`setindex!`/
`ht_keyindex2` only reference `+Type#N` tags. Two distinct zeroed headers for
the "same" singleton would be behaviourally identical for the empty-Memory
case (both length=0) and only diverge under a pointer-identity `==`
comparison, which the current closed-world path never performs. Documented,
not hand-waved — acceptable for the current 4-function set; a residual risk
for a *future* wider closed-world set the reviewer should keep in mind.

**5. READ-WINDOW TRAP + TLS CARVE-OUT — VERIFIED correct for current scope; one residual gap flagged below.**
Boundary check: `GLOBAL_BASE = 2^48`, `TLS_BASE = 2^56`,
`_TLS_TIER_GUARD = 2^32`. The carve-out fires for `a >= TLS_BASE -
_TLS_TIER_GUARD ≈ 2^56 - 2^32`, which is ~2^24× above any realistic
`GLOBAL_BASE`-relative ROM address (would require billions of seeded cells
to collide) — confirmed by reading `ingest_call.jl`'s own derivation
comment and doing the arithmetic. `current_task = TLS_BASE - 152` and
`ptls_field = TLS_BASE + 16` both fall inside `[TLS_BASE - 2^32, ∞)`. No
off-by-one at either boundary (`>=` consistently, both edges checked in the
right order: seeded-cell hit first, then TLS band, then error). **However**:
the TLS carve-out is an *unbounded-above* address band
(`[TLS_BASE - guard, ∞)`, no upper limit) that silently returns 0 for *any*
address in that band, not just the two known GC-preamble offsets. See "Most
dangerous residual risk" below — this is real but narrow given current
scope.

**6. REVERSIBILITY — VERIFIED for the synthetic paths, PARTIAL for the real fdict path (documented, not a defect).**
`test_jlglobal_singleton.jl` (a) and (b) both assert full round-trip:
`unrun!` restores `rs.current == init` *and* `isempty(rs.history)` — this is
a real inverse-check, not a "runs without errors" test, satisfying BVM Rule 4.
Confirmed by running: 25/25 pass. Testset (e), the REAL fdict(3,7) path, does
**not** assert round-trip — it asserts the run advances past construction and
then hits a *specific* documented successor wall (`__unreachable__`), which
is honest: the implementer does not claim full reversibility on the real
program, only that this bead's target wall is cleared. This matches the
worklog's own "NEXT WALL" section. Not a finding — the test correctly scopes
its claim to what actually works.

**7. MUTATION PROBES — all three fired RED as expected, then were restored exactly.**
- (a) Shrunk the header from 16→1 cells in `module_walk.jl` (Bennett.jl) →
  `test_416r13_jlglobal_singleton.jl` went 13/16 (3 failures, `length(data)
  == 16` / `1 == 16`). Reverted; `git diff --stat` confirmed byte-identical
  to the pre-probe 48-line diff.
- (b) Removed the `names[inst.ref] = Symbol(pname)` re-aliasing line in
  `instructions.jl` (Bennett.jl), keeping only `return nothing` → went
  15/16 (1 failure): `isempty(dangling)` caught a dangling
  `jl_global#270241` — exactly the "loaded-twice" second-load-result case
  Design B D3 calls out as load-bearing. Reverted; diff confirmed
  byte-identical (47-line diff restored).
- (c) Reverted the BVM read-window trap in `memory_floor.jl` to the old
  unconditional `get(..., 0)` → `test_jlglobal_singleton.jl` went 24/25 (1
  failure): the adversarial "read past header fails loud" test expected an
  `ErrorException` and got none. Reverted; diff confirmed byte-identical
  (41-line diff restored).

All three probes demonstrate the tests are load-bearing, not decorative.

**8. TEST HYGIENE — VERIFIED.**
No test pins a literal `jl_global#NNN` number in either repo (both new test
files explicitly assert count/shape, or extract names programmatically —
confirmed by reading both files in full). Both new tests are registered in
their respective `runtests.jl` (Bennett.jl line 244; BennettVM.jl in the
const-global block, `include("test_jlglobal_singleton.jl")`). BVM file LOC:
the touched files (`ingest.jl` 490 code-LOC, `memory_floor.jl` 309 code-LOC
excluding blank/comment lines) already exceeded the project's own ~200-LOC
cap **before** this diff — this change grows already-oversized files further
without splitting them, which is a hygiene nit but not something this diff
introduced (pre-existing violation). Worklog entries are present in both
repos (Bennett.jl `worklog/094_...md`, BennettVM.jl `WORKLOG.md`) and their
factual claims (cell counts, test counts, pass/fail splits, the d1b
1-broken-test figure) were spot-verified against live runs and matched
exactly.

**9. THE FLIPPED test_x3t0 (f) — VERIFIED, pins a meaningful new wall, not a tautology.**
The diff changes the assertion from `occursin("jl_global", rmsg)` to BOTH
`!occursin("jl_global", rmsg)` AND `occursin("__unreachable__", rmsg)` — the
second assertion pins a *specific, named* successor wall (the dead-code
throw sink), not a generic "some other error occurred." Ran the full test
file: 6/6 pass for testset (f), and the whole file's other testsets (a)-(e)
also pass (all green), confirming no other regression was introduced
alongside the flip.

## Nits (non-blocking)

1. The singleton load-handler arm (`instructions.jl:3564-3566`) doesn't gate
   on `LLVM.value_type(inst) isa LLVM.PointerType` the way the later
   tightened fail-loud arm does. Not a soundness bug (both a pointer load
   and a same-width scalar load alias to the same Int64 address value under
   the VM's cell model), but it's an asymmetry worth a one-line comment or
   guard for defensive symmetry.
2. `ParsedIR.globals`'s docstring (`ir_types.jl:571-574`) still describes the
   field purely as "compile-time-constant arrays" and doesn't mention the
   new singleton-header producer. Doc-only.
3. Task-brief attribution nit (see "What actually landed" above) — the
   shipped design is Design B's architecture with A's D2/D5 folded in, not
   "Design A adopted."

## Verdict: **APPROVE**

All nine checklist claims verified against the live diff, ground-truth docs,
and running tests (not just the implementer's report). Three targeted
mutation probes on the most load-bearing mechanisms (header size, the
"loaded-twice" aliasing wrinkle, the read-window trap) all failed red when
broken and were cleanly restored. The fail-loud tightening was checked
against two extraction test files the implementer did not cite
(`test_iwo9_typetag.jl`, `test_r92o_gc_alloc_obj.jl`), both green. The
multi-function module-wide ROM cursor is provably disjoint by construction.
The work honestly scopes its claim (clears the jl_global KeyError wall;
does not claim full Dict-semantics correctness) and the worklog's specific
numeric claims (test pass counts, the 1-broken d1b test) all matched live
runs exactly — no overclaiming detected.

## Single most dangerous residual risk (even while approving)

The TLS-tier carve-out in `MemoryLoad.forward`
(`memory_floor.jl:276-277`) is an **unbounded-above** address band: any read
at `a >= TLS_BASE - 2^32` (i.e. `a >= 2^56 - 2^32`, extending to infinity)
silently returns 0, with no upper bound and no check that the address is
actually one of the two known GC-preamble derived addresses
(`current_task`, `ptls_field`). This reintroduces exactly one instance of the
silent-zero-read class the whole read-window trap was built to eliminate —
just relocated to a currently-unreachable address band. Today this is inert
because (a) nothing in the closed-world fdict set computes an address in
that band except the two known GC-preamble reads, and (b) the gap to
`GLOBAL_BASE` is astronomically large. But if a *future* bug anywhere in the
front-end or VM ever computed a stray address that happened to land at or
above `2^56 - 2^32` (e.g. an unrelated overflow, a bad pointer-arithmetic
lowering, or a new intrinsic reusing address space near that band), it would
silently read 0 instead of failing loud — precisely the miscompile class
this bead exists to close, just moved one tier over. Worth a follow-up bead
to narrow the carve-out to the *specific* known offsets
(`{TLS_BASE - 152, TLS_BASE + 16}` or a tight `[TLS_BASE - 200, TLS_BASE +
200]` window) rather than an open-ended half-line.

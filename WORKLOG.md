# WORKLOG — BennettVM.jl

> Chronological session log. Prepend new sessions to the top. Capture
> what was done, what was decided, and what surprised us — anything a
> future agent or human would wish it knew, that's not derivable from
> `git log` or the retrospective.

---

## Session 2026-08-07 — bd RESTORE: 35 beads (incl. the ENTIRE emulator DAG) lost by the 2026-07-21 export

A north-star status query ("where does the NES emulator sit?") found
`bennettvm-v5eb`, `1is3`, and every A/B/T/E emulator bead missing from
the tracker: the 2026-07-21 "truth-up" export (`4ca1f1f`) DELETED 35
rows instead of only updating closes — the emulator DAG (open planned
work AND closed E0/E1/B1 history), the July CW-D landing history
(416r.14–17, p81t, 5m1t, 9n3y, g501, h6c3), open walls bsng/san3, and
jb6w/9sqy/6dko/6vp9/bc08. Recovered verbatim from git (`df5b2b9`, the
pre-loss parent), `bd import`-ed, re-exported (266 issues + 1 memory),
committed `48cb30b`. Dependency edges survived: `bd ready` again
surfaces hahl (A1 ROM loader) as the Track-A entry point and 9xla/eqz5
for Track B. **Lesson (third strike for lossy exports):** after ANY
`bd export`, diff the id set against the previous jsonl before
committing — a "truth-up" that shrinks the row count is a deletion,
not a truth-up.

## Session 2026-08-07 (part 7, WIND-DOWN) — 5viz (wall 11) landed UNREVIEWED-WIP upstream; session retrospective

User-directed graceful wind-down. Upstream: the wall-11 arm landed
UNREVIEWED-WIP (Bennett-gcf7 tracks completion — the BVM E2E gate for
5viz was NOT written; its spec is in the 5viz bead notes: singleton-src
memcpy through the real front end, length lands in the env cell,
runs+reverses, L2+L3, per-step inverse, non-vacuity; zero src changes
expected). BVM totals unchanged this part (10963 green as of the 57hd
landing). Session total: six arcs, five walls, two ADR contracts, ten
zero-src-change beads. Priorities for the next session, in order:
bennettvm-ciff/Bennett-hk5i (P0 docs epics, user directive) →
Bennett-gcf7 (P1) → walls 12-14 → bennettvm-rxgy (the full-corpus RUN).

## Session 2026-08-07 (part 6) — Bennett-57hd (xkl wall 10): ADR 0017 gains §4b VALUE-IDENTITY CONTRACT — the strongest of the three; ZERO BVM src changes (tenth in a row)

Upstream landed the third admission contract (full 3+1: scout upgrade →
two blind proposers CONVERGED on the α family → adjudication merged
their correct halves + added clause (iv) → hostile review FAIL (an
EXECUTED counterexample: a self-store escape made the admitted sub
evaluate to 64 where the contract guarantees 0) → prescribed fix cycle →
green. Arc: Bennett.jl worklogs 104-106 + docs/design/57hd*.) BVM side:

- **docs/adr/0017 gains §4b** (+42/−1, doc-only): oracle-match admission
  for a ptrtoint whose every use is a sub of two PROVABLY IDENTICAL
  pointers (single-block canonicalisation; attribute-checked effect
  analysis, fail-closed incl. operand bundles and negative lengths;
  clause (iv) p06b-certified forwarded stores). φ(p)−φ(p)=0 under ANY
  address map — no arena premise, both failure columns bounded, §4a's
  conditioning clause SATISFIED not voided. The §4a proved-guards
  parenthetical now lists 57hd.
- New test_57hd_value_identity_vm.jl (107): the difference EXECUTED and
  == 0 on the VM, escape exercised into an IntrinsicGCAlloc size and a
  VarGEP address, non-vacuity mandatory (coerced cells non-zero, equal,
  and equal to the stored address), L2+L3, exact unrun!, per-step
  inverse. ZERO src changes — streak at ten.
- **F1 lesson (recorded upstream)**: the scout's coverage framing never
  evaluated foz5 on %L21/%L43 — they were ALREADY §4a-admitted. Measure
  the shipped predicates on every cluster before designing coverage.
- Frontier: wall 10 CLEARED → wall 11 = Bennett-8bys territory (corpus
  site #4 memcpy; reject text IDENTICAL to wall 9's — operand-name
  discriminator, see the 8bys bead note); wall 12 = p06b alloca
  {ptr,ptr} silent-skip (Bennett-1zow; its message does NOT contain the
  bead tag); wall 13 = second 8bys memcpy; wall 14 = bvmd
  SCALE-COHERENCE on the 9×i64 closure alloca. bennettvm-rxgy still
  gates _growend! at lower_vm.

## Session 2026-08-07 (part 5) — Bennett-sy29 (xkl wall 9): arena-src memcpy decomposition; ZERO BVM src changes (ninth in a row)

Upstream landed the const-N arena-src memcpy capability (RATIFIED reduced
pass — scout with tripwire, all four upgrade triggers measured non-firing,
vau9 precedent; hostile review FAILED it once, prescribed fixes landed;
arc in Bennett.jl worklog/103). BVM side:

- **ZERO src changes (ninth consecutive).** New test_sy29_arena_src_vm.jl
  (118): K=2 arena↔alloca round-trips BOTH directions + arena→arena,
  oracle match, exact unrun!, per-step inverse, L2+L3, and a
  lowered-kinds-as-a-set gate (⊆ {Define, IntrinsicGCAlloc, MemoryLoad,
  MemoryStore, StackAlloca}) that goes red if upstream ever reaches for a
  new node kind.
- **The review's executed miscompile matters to the VM contract**: the
  upstream overlap guard REPLACES the VM's runtime overlap check for
  decomposed memcpys, and its "distinct roots ⇒ disjoint" claim was a
  FALSE THEOREM (a GEP leaving its own object reached the next
  allocation: s=222 vs oracle 333, executed). Fixed upstream by
  Predicate 6d (in-object range certification via _root_byte_offset);
  the corpus is exactly FLUSH on both sides, so the <=/< boundary is
  corpus-mutation-verified. bennettvm-9uds documents the related
  IntrinsicMemcpy byte-tier landmine (fenced today).
- Frontier: wall 9 CLEARED → **Bennett-57hd** (wall 10): the
  base-cancelling difference ESCAPES as a live element index via
  udiv exact — foz5 §4a clause (iii) fails; needs a THIRD admission
  contract; scout-with-tripwire recommended. bennettvm-rxgy still gates
  _growend! at lower_vm.

## Session 2026-08-06/07 (part 4) — Bennett-bvmd (xkl wall 8): root-scale coherence + byte-tier admission; ZERO BVM src changes (eighth in a row); foz5 §4a debt discharged FOR THE MECHANISM

Upstream landed the byte-tier granularity discipline (full 3+1 after scout
upgrade; hostile review PASS-WITH-CONCERNS + prescribed fixes; arc in
Bennett.jl worklog/101+102). BVM-relevant:

- **ZERO src changes (eighth consecutive bead).** New
  test/test_bvmd_byte_tier_vm.jl (96): the six-leg synthetic §4a-debt gate
  — gc_alloc box + decomposed aggregate store + class-D struct-GEP read +
  closure-env alloca + confined guard; oracle match, exact unrun!,
  per-step inverse, :__unreachable__ on OOB. HONEST SCOPE: this
  discharges the foz5 §4a validation debt for the MECHANISM only — the
  bead's "full push! corpus runnable" premise was false (walls 9/10/11 +
  bennettvm-rxgy remain; the OOB probe exists only in the fixture).
- **Route-(iii) tombstone, a VM-semantics lesson (Bennett-1p2v):** an
  extraction-side ACCESS re-stamp variant was built, measured, and
  REVERTED — per-function re-stamping is not closed under call
  boundaries; a caller wrote word cell +1 while the callee (scale-unknown
  pointer parameter) read byte cell +8: test_40ys_closure_callee_vm went
  155/183 with 30 wrong-vs-oracle answers. The shipped design widens
  RESERVATIONS only (size, never addressing) — no such hazard by
  construction. Any future access-re-stamp must first solve
  cross-function scale propagation.
- **Bennett-4y0d root-caused and FIXED upstream** (address/value
  conflation in the vbv9 arena-memcpy dst stamp); the K>=2 case
  independently E2E-verified on the VM (reviewer's own K=3 fixture:
  oracle 111/222/333, exact unrun!).
- Frontier: wall 8 CLEARED → wall 9 = Bennett-37mt arena-src memcpy;
  wall 10 = udiv-exact element-index escape (needs a THIRD contract
  beyond §4a); wall 11 = Bennett-1zow territory. bennettvm-rxgy still
  gates _growend! at lower_vm.

## Session 2026-08-06 (part 3) — Bennett-foz5 (xkl wall 7): ADR 0017 gains §4a CONFINED-VALUE CONTRACT; ZERO BVM src changes (seventh in a row)

Upstream landed the confined-value admission for _growend!'s @boundscheck
cluster (full 3+1 after a scout upgrade; adjudicated route A-hardened;
hostile review PASS-WITH-CONCERNS + prescribed fix cycle; Bennett.jl
worklog/100 has the arc including the adjudication matrix). BVM side:

- **docs/adr/0017-closed-world-execution.md gains §4a** (+31, doc-only):
  a second, strictly weaker admission contract for values whose entire
  influence is a dead-throw branch condition — "on native-returning
  inputs, exact match or loud halt at :__unreachable__", BOTH violation
  directions explicitly unproven. Oracle-match proofs keep first refusal;
  the Bennett-lbot fabrication ruling is REAFFIRMED, not narrowed
  (rationale cites bennettvm-pdqx: a missed throw is an undetectable
  adjacent-allocation clobber, so no guard bit is ever fabricated — the
  bit is computed from emitted operands, a provenance claim, not a
  correctness claim).
- **Validation debt, disclosed in three places**: no runtime evidence
  about either unproven direction is constructible until wall 8
  (Bennett-bvmd — the ROOT body's gc_alloc_obj byte-granular store)
  clears; clearing it also discharges this debt.
- ZERO src changes (seventh consecutive bead). All BVM E2E suites green;
  full Pkg.test green on the landing tree.
- Frontier: wall 7 CLEARED; next **Bennett-bvmd** (wall 8, upstream) and
  **bennettvm-rxgy** (IntrinsicMemmoveBytes) on the VM side.

## Session 2026-08-06 (part 2) — Bennett-p06b: aggregate {ptr,ptr} store decomposition (xkl wall 6) — ZERO BVM src changes (sixth in a row); pdqx spec found WRONG by measurement

Upstream landed the p06b arm (CORE 3+1, THREE review rounds: FAIL → FAIL →
PASS-WITH-CONCERNS; Bennett.jl worklog/099 has the full arc). BVM side:

- **ZERO src changes.** New `test/test_p06b_aggregate_store_vm.jl` (179):
  decomposed aggregate-store program through the real front end — `:halted`
  with hand oracle, `unrun!` exact + drained history, L2 AND L3,
  per_step_inverse_check K∈{1,4}, distinct-cell non-vacuity witness.
- **bennettvm-pdqx's spec is WRONG and the bead was amended**: a "target
  cell ∈ live reserved regions" check CANNOT catch the D1 clobber class —
  every executed repro writes into an ADJACENT LIVE allocation, inside the
  union of reservations. There is no region table; ownership is three
  monotone cursors + a flat cell Dict (src/ir/IState.jl:315-398, verified
  independently by two reviewers). Catching cross-allocation clobbers needs
  pointer PROVENANCE — plain-Int64 locals can't express it without
  false-rejecting stack-tier integer arithmetic. pdqx retains narrower
  merits (wild-address escapes) and is unclaimed.
- **Bennett-khb2 (upstream)**: the corpus `:load` target's capacity is a
  disclosed well-formedness assumption, pinned KNOWN-ADMITTED in both
  repos' test files (flip-don't-delete banners). The BVM E2E header carries
  the matching KNOWN CLOBBER note.
- New BVM beads: bennettvm-pdqx (amended, open), bennettvm-p4r4 (IRInsertValue
  base lacks the agg_dests guard IRExtractValue has → contextless KeyError;
  the upstream D4 chain-root fix closes the current entry path).
- Frontier: wall 6 CLEARED; next Bennett-foz5 (wall 7, upstream) and
  bennettvm-rxgy (IntrinsicMemmoveBytes) on the VM side.

## Session 2026-08-06 — Bennett-a8nw hostile review RUN → PASS-WITH-CONCERNS; jbko + a8nw CLOSED; ZERO BVM changes (review-only session)

The upstream review debt is paid: the jbko ptrtoint arm survived ~30
adversarial probes (report in the Bennett-a8nw bead trail; Bennett.jl
worklog/098 top entry). BVM-relevant findings:

- **The trapped-program reversal claim in test_jbko_ptr_identity_vm.jl is
  real and non-vacuous** (reviewer re-derived it independently: mismatch
  path runs 28 steps, halts at `:__unreachable__` with `status=:error`,
  state genuinely differs from init, and `unrun!` restores `s.current ==
  init` with drained history). First independent confirmation of the
  L1-injective-sink property.
- **One P1-class residual upstream (filed as Bennett-sku0, P2)**: the arm's
  icmp-sibling check is SSA-ness, not cell-ness — a pointer-unrelated
  integer sibling yields an i1 that diverges native-vs-VM. No BVM change
  needed; in corpus shapes the i1 feeds a throw diamond (loud halt). Watch
  for it if a jbko-admitted compare ever feeds a VALUE (select) in a future
  corpus program — the loud-halt mitigation is corpus-shape, not enforced.
- prop-A R5 (corpus guard's truth value ON THE VM) remains honestly
  UNTESTED — blocked behind walls 6/7 as the test file header states.
- Upstream landed a comment/message-only disclosure diff; no BVM src or
  test changes. Frontier unblocked: Bennett-p06b (wall 6) next on the
  extraction side; **bennettvm-rxgy** (IntrinsicMemmoveBytes) is the VM-side
  gate before the real `_growend!` grow-copy can RUN.

## Session 2026-08-03/04 (part 5, WIND-UP) — Bennett-jbko: ptr-identity ptrtoint arm lands UNREVIEWED (hostile review = Bennett-a8nw); ZERO BVM src changes a fifth time

⚠️ jbko's implementation is committed with IMPLEMENTER-run full suites green
(BVM **10379/10379** 4m10.8s; Bennett 690955/3B 30m20s) but the hostile-review
step was NOT run (user wind-up) — **Bennett-a8nw (P1) tracks it; do not build
on the arm or close Bennett-jbko until it passes.**

- Bennett.jl admits `ptrtoint` of certified cell-valued pointers when every
  use is `icmp eq/ne` (the MemoryRef concurrent-mutation guard in
  `_growend!`). BVM needed nothing: IRICmp on two cells was always fine.
- New `test/test_jbko_ptr_identity_vm.jl` (175): guard-match runs the ok
  branch; guard-MISMATCH runs into the ConcurrencyViolationError diamond and
  HALTS at the `:__unreachable__` sink — and `unrun!` still returns the exact
  initial state with drained history. **A trapped program is fully
  reversible** (L1-injective sink); first time pinned anywhere. Allocator
  injectivity is a runnable assertion (first malloc == ARENA_BASE == the
  captured cell).
- Frontier after jbko (both proposers, real gated path): **Bennett-p06b**
  (wall 6: two live `store {ptr,ptr}` at L93 — extraction side) and
  **Bennett-foz5** (wall 7: %idxend 583s root extension), plus
  **bennettvm-rxgy** (BVM byte-tier memmove) before the real grow-copy RUNS.
  Bennett-kvdv closed stale (583s subsumed it).

## Session 2026-08-03/04 (part 4) — Bennett-vau9: memmove routes to the VM's IntrinsicMemmove; xkl wall 4 cleared; walls 5 (jbko) + 6 (rxgy) located; ZERO BVM src changes a fourth time

Reduced pass (design settled by the Bennett-8bys memset 3+1; scout verified
the mirror; hostile review ran a revert-worktree experiment + its own
adversarial overlap fixtures).

- Bennett.jl now routes `llvm.memmove` under ptr_cells to
  `IRCall(:memmove,[dst,src,nbytes])` — and BVM needed NOTHING:
  `IntrinsicMemmove` (intrinsics_bulk.jl) was already overlap-safe BY
  CONSTRUCTION (`_copy_range!` snapshots the whole src range before writing
  dest — direction-agnostic, self-move fine) with L2 dest-range delta
  reversal, and `:memmove` was already in `_HEAP_DISPATCH`.
- New `test/test_vau9_memmove_vm.jl` (267 + the 21 M8.2-scaffold self-tests
  it includes): FORWARD- and BACKWARD-overlapping memmoves through the REAL
  front-end vs hand-computed oracles, disjoint + variable-length, L2+L3,
  per-step inverse at K ∈ {1,4}. Deliberately malloc/C-TIER — the real
  Julia-tier grow-copy is blocked by wall 6:
- **bennettvm-rxgy (wall 6) — the FIRST BVM src change of the arc, filed**:
  `_enforce_julia_heap_tier!` fails loud on cell-granular IntrinsicMemmove in
  byte-granular Julia-tier programs; needs IntrinsicMemmoveBytes (sibling of
  IntrinsicMemsetBytes). NOTE: comments/error messages across both repos cite
  "bennettvm-9n3y" for this gap — that ID exists in NEITHER tracker (dangling;
  sweep bead filed). rxgy is the real bead.
- **Bennett-jbko (wall 5)**: push! extraction now lands at a `ptrtoint` of a
  MemoryRef data pointer feeding an `icmp eq` concurrent-mutation guard —
  needs a new equality arm on the Bennett.jl side.
- Gates (orchestrator-run): BVM full `Pkg.test` **10183/10183** (4m01s; +21
  over arithmetic attributed exactly to the included M8.2 scaffold
  self-tests); Bennett.jl 690874/3B.

## Session 2026-08-03/04 (part 3) — Bennett-3vf2: dead-use global-load drop; xkl wall 3 cleared; frontier is now memmove (Bennett-8bys); ZERO BVM src changes a third time

Third bead, first genuinely DIVERGENT 3+1 of the arc. Bennett.jl gains a
name-agnostic "dead-use drop": a `GlobalVariable` ptr load that would hit the
UNRECOGNIZED-JIT-global reject is dropped iff EVERY use's parent block is in
the utzc dead_blocks set (the pruner empties those blocks — nothing emitted
can reference the def; hostile review found the stronger argument: SSA
domination alone makes dead-def→live-use structurally impossible). This clears
`@jl_diverror_exception` in `_growend!` (4 structurally-dead div-guard
diamonds, load hoisted into the live block). Atomic loads declined (fence ≠
value semantics); zero-use loads still reject. Correction chain: proposer B's
"addrspacecast direct use" sighting was a DUMP ARTIFACT — IR claims are only
valid for the exact pipeline configuration that produced them.

- **BVM: zero src changes.** New `test/test_3vf2_dead_use_global_load.jl`
  (104): the benign dead-diamond fixture runs through the REAL front-end to
  `:halted` (never the `:__unreachable__` error sink), `div(n,4)` for 7 values
  incl. negatives, exact `unrun!` + empty history under L2 AND L3 — proving
  the drop is invisible at the VM level, which is the point.
- **xkl frontier is now `llvm.memmove.p0.p0.i64`** (Bennett-8bys / 37mt,
  already-tracked memmove lowering) — the push! corpus lands there with the
  callee named. Root separately at pgcstack (Bennett-5oyt/U15).
- Gates (orchestrator-run): BVM full `Pkg.test` **9895/9895** (4m01s).

## Session 2026-08-03/04 (part 2) — Bennett-7wsz: ptr-typed sret fields land; xkl closure frontier advances to the 416r.13 JIT-global wall; ZERO BVM src changes again

Second bead of the same orchestrated session (3+1; proposers converged again;
hostile review ACCEPT-WITH-CONDITIONS, zero claims falsified).

- **Capability**: under `ptr_cells=true`, Bennett.jl now admits ptr-typed sret
  struct fields as 64-bit cells (`{ptr,ptr}` MemoryRef returns et al.). Julia's
  split-roots ABI finding (both proposers, independently): the callee stores
  the GC-tracked field into the `return_roots` out-param and a literal `i64 -1`
  sentinel into the matching sret slot; the jfptr wrapper reassembles. Modeled
  VERBATIM — **fusing return_roots into the aggregate would be a silent pointer
  miscompile**; anti-fusion tests + a SEMANTICS block in Bennett.jl sret.jl pin
  the evidence (incl. a dat+mem-1 arithmetic witness on the VM).
- **BVM: zero src changes** — guard-5's `ret_width == sum(ret_elem_widths)`
  (128==128) takes the value-ABI branch (read, not trusted). New
  `test/test_7wsz_ptr_sret_vm.jl` (160): sret({ptr,i64}) fixture E2E
  (extract → lower_vm → run == native oracle → unrun! exact, L2+L3, per-step
  inverse) + a hand-built split-roots `.ll` pair proving the cross-frame
  return_roots store reverses and IRInsertBits+ConstOperand(-1) lowers.
- **Frontier walls after 7wsz** (measured, gated): the push! CLOSURE
  (the xkl chain) lands at unrecognized JIT global `@jl_diverror_exception`
  (bennettvm-416r.13 family); the push! ROOT lands at the pgcstack inline-asm
  wall (Bennett-5oyt/U15) — NOT the forecast U114, because clearing the
  416r.16 PRE-WALK wall exposed the body walk's FIRST instruction. Lesson:
  "advances to the next wall" is not monotone in program order, and wall
  forecasts made with ungated monkey-patches lie about gated behavior.
- **Gates (orchestrator-run)**: BVM full `Pkg.test` **9791/9791** (4m02s);
  Bennett.jl full suite green (see Bennett.jl worklog/097 session entry).

## Session 2026-08-03 (part 1) — xkl frontier: instance-less closure callees (Bennett-40ys) land cross-repo; ZERO BVM src changes; next wall named (Bennett-7wsz)

Orchestrated (Fable orchestrator; Sonnet scout + hostile reviewer, 2 blind Opus
proposers + Opus implementer, strictly serial Julia). Target: `bennettvm-xkl`
(P0, push!-built Vector) via its 2026-07-21 closed-world re-scope.

- **Diagnosis**: every push! shape died at tier-1 EXTRACTION — Julia 1.12.3
  outlines `_growend!`'s slow path into a NON-SINGLETON closure reached via a
  real `:invoke` (`argtypes=Tuple{}`; captures ride in the closure struct);
  Bennett.jl's `_callable_of_key` (`.instance`) crashed with a bare
  `UndefRefError` in the registration loop, unrescuable by `on_extract_error`.
  New capability class — the Dict corpus never hit it (rehash!/setindex! do
  alloc/copy inline via foreigncalls, invisible to the `:invoke`-only walker).
- **Fix (Bennett.jl side, 3+1, both proposers converged)**: by-SIGNATURE IR
  emission (`Base._which → specialize_method → typeinf_code →
  _dump_function_llvm`; `src/extract/sig_llvm.jl`), total callee-key classifier
  with loud errors (incl. explicit OpaqueClosure rejection), full-specTypes
  digest (argtypes-only digest PROVABLY collided: Int32-vs-Int64 push! closures
  got identical keys), `mi.def.name` barenames (`nameof(ClosureType)` is a trap),
  name-only callee registry for call-site binding.
- **BVM: ZERO source changes.** `_vm_funcname`/`_vm_dispatch_name` and ADR-0023
  CallEnter semantics carry closure callees unchanged. New
  `test/test_40ys_closure_callee_vm.jl` (183 asserts): 1-field AND 2-field
  functor callees extracted from TYPE alone run to native-oracle values and
  `unrun!` to exact initial state + empty history, L2 AND L3, per-step inverse.
  The 2-field fixture is the tripwire for Bennett-ce9t (caller `arg_widths
  [64,64]` vs callee `ParsedIR.args [128,64]` — inert because CallEnter drops
  widths, `ingest_multi.jl:153` params are names-only; oracle mixes both fields
  so a wrong field-crossing changes the answer).
- **push! now fails LOUD at the named next wall**: ptr-typed sret struct fields
  (`{ptr,ptr}` MemoryRef) under ptr_cells — filed as **Bennett-7wsz** (P1); the
  old dv1z bead is closed history, don't reopen it. After 7wsz expect walls
  INSIDE the closure body (`jl_genericmemory_copy_slice` etc. — scout forecast).
- **Beads**: Bennett-40ys closed; filed Bennett-wh1p (case-folding, P2),
  Bennett-9tg3 (`:skip` silently drops the ROOT — confirmed live, pinned as
  known-gap testset), Bennett-ce9t (width metadata, P3), bare_to_key >1-candidate
  guard (P3), Bennett-7wsz (P1). `bennettvm-m9i` annotated STALE (pre-ADR-0017
  framing); `xkl` annotated with diagnosis.
- **Gates (orchestrator-run)**: BVM full `Pkg.test` **9631/9631** (4m04s;
  +183 over 9448 baseline; clang still absent so ~2000 asserts self-skip,
  `bennettvm-5o86`). Bennett.jl full `Pkg.test` green (implementer run) +
  orchestrator re-gate: see Bennett.jl worklog/097.
- **Gotcha bank**: `@noinline` in body position is load-bearing for closure
  fixtures (else inlining empties `transitive_callees`); `string(hash;base=16)`
  drops leading zeros (`lpad` or p≈2⁻²⁸ BoundsError); a 1-field functor passes
  width checks by COINCIDENCE (8-byte self) — always test ≥2-field captures.

---

## 2026-07-30 (part 2) — `Bennett-tl1l`: the two a70z emission shapes the Dict corpus never produces

**Test-only, both repos. No `src/` change, no defect found — this was a coverage
bead and it stayed one.** New file `test/test_tl1l_a70z_shapes.jl` (1149
assertions, ~20 s), registered right after `test_a70z_dict64_roundtrip.jl`.
Upstream half: `../Bennett.jl/test/test_a70z_overflow_const_bit.jl` 206 → 348
assertions (N ∈ {16, 32} sweeps).

**The lesson: "the real corpus exercises it" answers a narrower question than it
looks like.** `test_a70z_dict64_roundtrip.jl` runs the genuine
`Dict{Int64,Int64}` closed-world set and was written as *the* downstream proof
of a70z. It is — of ONE of the front-end's THREE emission shapes.
`_fuse_overflow_extractvalue` emits two `IRICmp` + a width-1 `:or` only when
BOTH interval bounds land strictly inside the iN domain. Drop one bound and it
emits a **single `IRICmp` carrying the extractvalue's own dest, with no `:or`
and zero `__vN` counter consumption**; make both operands constant and it emits
`IRBinOp(:o,:add,bit,0,1)` with no comparison at all. The Dict corpus hits only
the two-sided shape, for a reason that is easy to state and was nobody's
intention: `rehash!`'s site is `smul(%value_phi, 8)`, and **signed mul is the
only generically two-sided arm**. `_ovf_admissible_range` drops the low arm for
*every* unsigned op (`L = 0` is the unsigned floor) and drops exactly one arm
for *every* `sadd`/`uadd`. The shape the corpus never reaches is the shape most
programs would produce.

**Research step (Bennett.jl Rule 9) — both from-source routes are CLOSED, and
the reason is instructive.** The obvious one-sided Julia fixture is
`Base.Checked.add_with_overflow(x, 5)` / `checked_add`. It does not extract:

```
ir_extract.jl: UndefValue operand: { i64, i8 } undef
```

That is the **`Bennett-bjdg` / U80** wall, and it fires on the `Tuple{T,Bool}`
**return** — Julia builds it by `insertvalue` into an undef aggregate — not on
anything to do with the overflow bit. Which is precisely why the Dict corpus
never meets it: there the intrinsic's fields are consumed in-body and the tuple
is never materialised. Reproduced at i16/i32/i64, `add` and `mul`, signed and
unsigned. The both-constant route is closed one stage earlier still: Julia's own
inference constant-folds `add_with_overflow(Int64(3), Int64(4))[2]` away, so the
extracted body has **zero instructions** and no intrinsic ever reaches LLVM.
Both are now pinned as tripwires in testset (0) — if either route opens, the
test goes RED and the next agent knows to switch to from-source fixtures.

**Fallback chosen: hand-written `.ll` through the REAL front-end, not hand-built
`ParsedIR`.** The bead offered a hand-built `ParsedIR` as the cheap option, with
a docstring argument that it byte-matches the emitter. Driving `.ll` through
`Bennett.extract_parsed_ir_from_ll` → `_fuse_overflow_extractvalue` costs the
same and removes the argument entirely: the shape under test is whatever
`instructions.jl` emits *today*, so a front-end drift fails the shape pin
instead of silently invalidating a transcription. Same fixture shapes as the
upstream `_a70z_fixture` / `_a70z_fixture_cc`, continued one stage further.
Widths 64/32/16; all three one-sided causes (`sadd` c>0 → `sgt`; `smul` c=-1 →
`slt`, the `x == typemin` bit; `uadd` i16 → `ugt` with the SEXT-encoded bound
`-2` for `0xFFFE`); six both-constant fixtures in both bit polarities.

**Two BVM facts this surfaced, worth reusing:**

* **`result(rs)` returns the whole halted frame's locals**, not just the declared
  returns. So the a70z bit `:o` can be asserted DIRECTLY rather than inferred
  from which arm the control flow took — the strongest available downstream
  statement of the contract, and it sidesteps the two-`EndInstruction`
  ambiguity of a fixture that returns from both arms of a `br i1 %o`.
* **At `W < 64`, `_apply_binop` masks results to the low `W` bits** (ADR 0012 R1
  / `bennettvm-bgc`). An i32 `x + 5` at `x = 2147483643` reads back as
  `2147483648` — a NON-NEGATIVE `Int64` in `[0, 2^32)`, not the sign-extended
  `Int32` value `-2147483648`. Any narrow-width value oracle must be written in
  that convention (`reinterpret(UInt32, ·)`). This is a storage choice, not a
  bug, and the new file states it as an honest boundary rather than quietly
  encoding it.

**Hostile review found one MAJOR, and the generalisation is worth keeping.** The
first cut of the both-constant table carried `uadd` at **bit 0 only**. But the
`bit == 0` emission is BYTE-IDENTICAL to the pre-existing Bennett-lbot
fold-to-zero shape (a70z D3, deliberately) — so a `uadd` fixture at bit 0 would
have passed unchanged **even with `_ovf_const_bit` deleted**. It was coverage in
name only, and the file's own honest-boundary paragraph had *stated* the
principle while the table violated it. **When two code paths emit the same bytes
for one value of a flag, only the other value is a test.** Fixed: all four arms
(`sadd`/`smul`/`umul`/`uadd`) now appear at BOTH polarities — added
`uadd i16 65534+3 → 1`, `uadd i64 (2^64-1)+1 → 1`, `umul i16 200*300 → 0` — and
the coverage rule is now itself an assertion in the testset, so a future edit
that drops an arm fails loudly instead of silently shrinking the discriminating
half. Also strengthened per the same review: the expected bit was a
hand-computed literal; `_tl1l_cbit` now recomputes it from the fixture's own
`.ll` constants through `Base.Checked` at the fixture's native width and
signedness (unsigned arms re-decode by masking, exactly as `_ovf_const_bit`
does), with the table's stated intent cross-checked against it so a typo in
either cannot agree with itself.

**Honest residual.** Nothing here claims a Julia program emitting these shapes
exists — testset (0) pins the opposite.

**Gate:** `test_tl1l_a70z_shapes.jl` 1149/1149 and
`test_a70z_dict64_roundtrip.jl` 347/347 green individually. Full `Pkg.test()` is
the orchestrator's gate.

---

## 2026-07-30 — `bennettvm-0fw7`: duplicate `CallEnter` args are legal (ADR 0023)

**The bead's own title was wrong, and that is the lesson.** It was filed as
"for-loop multi-insert Dict dies at LOWERING", and everyone (including the rnhv
session that filed it, and the comment it left at
`test_rnhv_phi_multiuse.jl:398`) read the loop as the cause. The 0fw7 diagnosis
scout reproduced the failure with **no loop at all**:

```julia
@noinline g(a, b) = 3a + b
f(x) = g(x, x)     # CallEnter: duplicate arg names in [x::Int64, x::Int64]
```

`d[i] = i` lowers to `setindex!(d, i, i)`: LLVM CSEs the key and the value onto
one `%value_phi`, so ONE call passes one value in TWO argument positions. A loop
body `d[i] = v` — two distinct names — does not trip it. The loop was
incidental; it merely made `d[i] = i` the natural way to write 14 inserts.
Whenever a wall is first seen through an expensive fixture, reduce it to the
cheapest program that still fails BEFORE theorising about the fixture's
distinguishing feature.

**The guard outlived its semantics by six weeks.** The message —
"an SSA name cannot be moved into a callee twice" — is a correct statement about
ADR 0019 §3's MOVE. But ADR 0019 **Amendment A.1** (2026-06-10,
hostile-review-ratified) had already replaced that MOVE with a COPY, for exactly
the same reason (multi-use LLVM SSA). A.1 changed the transfer and updated the
docstrings; it did not touch the constructor, and the constructor is what runs.
So the codebase carried a check whose error text taught every reader a model the
project had abandoned. **When superseding a design, grep for the RATIONALE TEXT,
not only the code that implements it.**

**It was also self-inconsistent, which is the tell.** `g(3, 3)` — duplicate
CONSTANT args — passed, because `src/ir/ingest.jl` mints a fresh per-position
`_callconst_<callee>_<n>` name for every constant operand. `g(m, m)` was
rejected. Identical program shape, opposite verdicts, decided by whether the
front-end happened to have renamed. A guard that fires on the SSA form of a
program but not its constant form is not enforcing an invariant of the machine.

**Decision (F1, orchestrator-adjudicated before implementation).** Remove
`allunique(args)` from `CallEnter`; mirror it on the superseded
`CallInstruction` stub so the two constructors cannot diverge. Rejected: F2, an
ingest-side duplicating `Define` per repeated arg (ADR 0022 already adjudicated
this trade at the φ-edge — a duplicating `Define` does not restore linearity, it
launders it, and here it would also cost an L3-reversed non-injective create
plus a `ReturnExit` residual entry per duplication); F3, front-end renaming in
Bennett.jl (violates the LLVM-transcription discipline, breaks the guyl
width-per-position contract, and needs a Rule-14 exception to edit
`../Bennett.jl/src/`).

**Empirics came before the fix, not after.** With the guard bypassed and nothing
else changed, the 14-insert for-loop `Dict{Int8,Int8}` lowered to 334 blocks,
ran to the native-oracle value and `unrun!`ed to empty history + exact initial
state under BOTH L2 and L3, `rehash!` GROW path included. That is what turned
"relax the guard" from a hypothesis into a decision.

**Guard-family audit (the part that keeps this surgical).** Four sites carry the
MOVE-model guard family; only one was touched.

| site | verdict |
|---|---|
| `call_transitions.jl` `allunique(args)` | **REMOVED** (this bead) |
| `call_transitions.jl` `t in args` overlap | retained; stale rationale filed as `bennettvm-p3j2` |
| `call_instruction.jl` `allunique(args)` | removed in lockstep (dead path, but must not diverge) |
| `control_instructions.jl` exit `allunique(args)` | retained — DIFFERENT list (block-exit args); ingest dedups upstream and removal would perturb pinned `Define` counts (ADR 0022) |

Both retained sites now carry a one-line cross-reference explaining why they are
NOT this bead, so the next reader does not assume 0023 settled them.

**One asymmetry, deliberate.** `structural_inverse(::CallInstruction)`
(`basic_block.jl`) swaps `targets` ↔ `args`, so a dup-arg instance inverts to a
dup-TARGET one and is rejected by `allunique(targets)` — correctly: two returns
cannot land on one name. A dup-arg call is therefore constructible but not
structurally invertible *in that class*. Harmless (dead path; `CallEnter` /
`ReturnExit` do not use `structural_inverse`), recorded in the docstring.

**RED-GREEN, and the RED had to be staged.** `test/test_0fw7_dup_call_args.jl`
was written and run against unmodified `src/` first. Note for future test
authors: a top-level `@testset` that ERRORS aborts the file, so the first RED
run showed only §(1). Re-running the file from a driver script that wraps the
include in an outer `@testset` collects all five sections — that is how the
"(1),(2),(3),(4') RED with the exact message / (4) 13-13 GREEN" split was
captured, and that split is what makes the RED attributable to the guard rather
than to the harness. GREEN: 76/72/56/13/8 = 225 assertions.

**Two neighbour test files asserted the OLD behaviour** and were dead-lettered
in place (`test_call_roundtrip.jl` (e'), `test_call_instruction.jl`), following
the (c') / ADR 0019 A.2 supersession pattern already established in
`test_call_roundtrip.jl`: keep the line, invert the assertion, write the
rationale inline. Do not delete a superseded assertion silently — the
replacement is what tells the next reader the change was intentional.

### Follow-through the same day — `bennettvm-p3j2`: the sibling guard STAYS (ADR 0023 §Amendment)

0fw7's follow-up list filed `bennettvm-p3j2` on the sentence "the `t in args`
guard carries the same stale MOVE-era rationale; `x = g(x)` is routine at
`-O0`." The first clause was right. **The second was wrong, and it is the more
interesting error.**

`x = g(x)` is routine at *source* level and **never survives into IR**. SSA
renames every definition (`%x.1 = call @g(%x.0)`), and more strongly the LLVM
verifier's **dominance rule forbids a call being its own operand** — an operand
must be dominated by its definition, and an instruction does not dominate
itself. So `dest ∉ operands` is not a lucky property of our front-end; it is a
property of well-formed LLVM. The diagnosis measured it rather than asserting
it: **135/135 raw call sites** and **105/105 extracted `IRCall`s** across the
C / Rust / Julia corpora, plus sret synthesis and the `_agg_*` / `_callconst_*`
name-minting namespaces, which allocate fresh names by construction.

Empirically the overlap would ALSO round-trip if allowed — A.1 copies the arg
before anything lands, A.2's `target_olds` restores the clobbered pre-call
value — so the printed rationale ("cannot be simultaneously moved-out and
landed-into") was just as false as the dup-arg one. But **relaxing buys zero
capability**, because no reachable program has the shape, and it would spend a
check with a *measured* zero false-positive rate. **F2: keep the behaviour,
delete the false story.** Bead downgraded P2 → P3. Permanent successor is the
dominance validator (`bennettvm-axfr`), now annotated with the `_agg_*`
fresh-name invariant this sweep established. Also filed: `bennettvm-xl1q`, and
`Bennett-ms0o` upstream (stale `.ll` fixtures found during the sweep).

**The rule these two beads jointly establish — write it on the wall:**
*a guard whose rationale is obsolete is not automatically a guard whose
behaviour is wrong.* 0fw7's guard blocked reachable programs and had to go;
p3j2's blocks nothing and stays. The common defect is the **sentence**, not the
`error()`. Diagnose reachability before reaching for the previous bead's fix
shape — "same family" is a hypothesis about the rationale, not about the
verdict.

Two mechanical notes for whoever touches this next. (a) The message pin in
`test_0fw7_dup_call_args.jl` §(4') asserts `occursin("appears in BOTH", …)`;
that clause is the FACTUAL half and was deliberately preserved through the
rewrite, so no test needed updating and the assertion counts are unchanged.
(b) **Do not generalise ADR 0023's `structural_inverse` asymmetry.** For
duplicate ARGS the `targets` ↔ `args` swap maps dup-arg → dup-target (rejected;
a real asymmetry). For the OVERLAP case the same swap maps overlap → overlap,
so the guard fires identically in both directions — no asymmetry at all.

## 2026-07-24 — `bennettvm-rnhv`: the φ-edge stops destroying its args (ADR 0022)

**Orchestrator/reviewer note (added at session close).** This landed through a
full Core-tier cycle: a diagnosis scout (classified the wall (C) BVM-ingest, not
front-end, by watching the SSA's lifetime frame-exactly rather than by name — the
name-collision trap from the a70z session made a name-only read untrustworthy),
then **two independent design proposers who DIVERGED**, then orchestrator
adjudication, then implementer, then a mandatory hostile reviewer (Rule 6).

The divergence is the part worth remembering. Proposer 1 wanted to PRESERVE
linearity by inserting an explicit duplicating `Define` at every non-linear
φ-incoming (generalising the e4l hatch). Proposer 2 wanted to RELAX the transfer
(delete the `delete!`). The adjudication turned on two things proposer 2 proved
that proposer 1 missed: (i) inserting a duplication **does not actually restore
linearity** — the original is still never destroyed by anything, so it just
launders the non-linearity while paying a step + an instruction; and (ii) it
would rewrite the lowering of collatz/matrix_tri/matrix_sum (2 hazards each),
i.e. perturb currently-green fixtures to fix a bug they don't have. The decisive
evidence was **ADR 0019 Amendment A.1** — the project had already hit this exact
bug at the `CallEnter` boundary (multi-use LLVM SSA, MOVE deleted a live caller
value, `KeyError`), already chosen COPY over MOVE, and already hostile-ratified
that "the zero-history claim is *stronger* under COPY — nothing is erased." rnhv
is that same decision at the φ-edge; we were inconsistent, not undecided.

Hostile reviewer verdict: **ACCEPT**, 2 non-blocking. The reviewer hand-built two
adversarial VMPrograms specifically to open a reversibility hole — an injective
`UnconditionalExit` overwriting a *live* param with no history entry, and a
name-collision survivor read after the join — and both round-tripped exactly
under L2 and L3. The reason the attack can't work, worth internalising: reversal
here is **checkpoint + deterministic forward replay**, so `is_injective=true`
suppresses only the per-step *log*, never the invertibility — a clobbered value
is always reconstructed by replaying forward from the nearest checkpoint. Two
accuracy fixes from the review applied to ADR 0022: the collatz/matrix count
table is a one-time MEASUREMENT, not a suite-pinned invariant (nothing asserts
exact step counts today), and the deferred dominance validator is now filed as
`bennettvm-axfr` rather than described in prose only.

The single most important fact for a future agent: **this bug was LATENT in
programs the suite already asserted green.** The identical 32 static hazards live
in the 1-insert `Dict{Int8,Int8}` and `Dict{Int64,Int64}` (both green e2e); 14
inserts only made the grow branch reachable so the fatal use executed. A green
suite is not proof a φ-edge relaxation is unnecessary — `test_rnhv_phi_multiuse.jl`
§(5) therefore guards the invariant with a trajectory-INDEPENDENT static hazard
scan on the cheap 1-insert fixture, not only the expensive 14-insert e2e.

Core-tier change to `src/interpreter/Interpreter.jl`. Design phase was 2
independent analyses (they DIVERGED) + reviewer adjudication; this session is
the implementation of the adjudicated design.

**The one-line fix.** `_rename_args_to_params!` ran `delete!(locals, a)` for
every cross-block edge arg. Removed. Renamed `_bind_args_to_params!`; two-phase
capture-then-assign and the arity guard kept.

**RED, verbatim, at `2efd6bc`.** 14-insert `Dict{Int8,Int8}` — extracts (4
bodies), lowers (552 blocks), dies at step 4603 of ~10790:

```
KeyError: key :__v327 not found
instruction: Define(:__v76, :value_phi135, :sub, :__v327, 64)
frames:      [(:__entry), (:setindex!), (:rehash!)]
```

and the 2-block hand-built witness dies with `KeyError: key :v not found`.
Both green after. `Dict{Int64,Int64}` at 14 inserts failed identically — the
wall is width-INDEPENDENT.

### The three things worth knowing

**1. The bug was LATENT in programs the suite already asserted GREEN.** This is
the headline. A static scan of the *lowered* `VMProgram` finds the identical
hazard shape (an exit arg with a use that outlives the edge) in the ONE-insert
`Dict{Int8,Int8}` / `Dict{Int64,Int64}` fixtures — including inside `rehash!`,
the exact body that died — and 2 each in collatz, matrix_tri, matrix_sum.
Fourteen inserts merely make the grow branch REACHABLE. So the natural test
("run a 14-insert Dict") is trajectory-dependent and stops discriminating the
moment the front-end changes which edge runs.
`test/test_rnhv_phi_multiuse.jl` §(5) therefore asserts the hazard count
statically on the CHEAP one-insert fixture. If you ever touch φ lowering, that
is the assertion that will tell you.

**2. Mogensen note 2 was imported without its precondition.** Opened the local
PDF (`references/reversible-ir/mogensen-2016-rssa.pdf`, §4 p. 210 — verified,
not recalled). Note 2 says "uses of variables as parameters to labels in exit
points also destroy these variables". That is well-typed **because RSSA blocks
are parameterized**: p. 209 — "we just add a parameter to the labels in the
join point and in the jumps to the join point" — every value live across a
boundary is threaded through the param list, so exit-arg ⟺ last-use. BennettVM's
register file is a flat `Dict{Symbol,Int64}` per FRAME; non-φ values cross
blocks *implicitly*, by dict persistence, and never appear in any args/params
list. So an exit arg carries zero information about deadness. Note 3 on the same
page corroborates that RSSA is not fully linear anyway: in `x := y ⊕ R1 ⊙ R2`
only `y` is destroyed — `R1`/`R2` must survive for the inverse.

Generalise the lesson: **an imported rule from a reversible-by-construction
source language needs its precondition checked against our IR, every time.**
This is now the SECOND instance of the same class — ADR 0019 Amendment A.1
(2026-06-10) hit it at the CALL edge (`KeyError: :found`) and replaced
`CallEnter`'s MOVE with a COPY for exactly this reason. `rnhv` is that bug one
boundary over. If a third shows up, look for a MOVE.

**3. Conservativity was MEASURED, not argued.** The `π ∘ N` factoring proves
injectivity can only strengthen (`D = π ∘ N`, so `D` injective ⟹ `N`
injective), but the reviewer asked for byte-identical trajectory shapes.
Probed collatz {1,2,3,6,7,11} / matrix_sum {0..4} / matrix_tri {0..4} with the
`delete!` in and out: **steps, history length, checkpoint count and delta count
are identical in every row**. The ONLY delta is the residual local count —
collatz 13→16, matrix_sum 10→15, matrix_tri 22→30 — which is the predicted
bounded cost (one per distinct φ-edge arg name per frame; NOT a function of
trip count). All three fixtures record zero `DeltaEntry`s, so today that cost
lands only on L3 checkpoint size.

### Also landed

* **`bennettvm-35yn`** — `src/ir/unbound_ssa.jl`. `_resolve` no longer lets a
  bare `KeyError` out; it names the symbol, the full instruction, the pc, the
  frame stack as `fname@pc=N` per activation, and a bound-name sample. This is
  not a nicety: it is the mitigation for this change's one real risk (a
  malformed lowering can now find a STALE binding and read it silently instead
  of failing loud). `ctx` is threaded from `Define` and `ArithmeticAssignment`
  only — the ~25 other `_resolve` sites pass `nothing` and get symbol + pc +
  frames, which the pc already localises. Threading the rest is mechanical and
  was deliberately not bundled into a correctness fix.
  Gotcha for whoever writes the next assertion against that message: the bottom
  frame is named **`:__entry`**, not the routine name — only a `CallEnter`-pushed
  frame carries the callee's `fname`.
* **The deferred optimization is real work, not a hedge.** Liveness-gated MOVE:
  restore `delete!` for args a backward liveness pass proves dead. That is the
  same tier ADR 0019 §7 already promises for call args, so they should land as
  ONE liveness pass. Trigger condition recorded in ADR 0022.

### Traps hit while writing the test

* A `for i in Int8(1):Int8(14); d[i] = i; end` loop does NOT reach the runtime
  wall — it dies at LOWERING with `CallEnter: duplicate arg names in
  [new::Dict, :value_phi, :value_phi]` (Julia passes one SSA value twice to
  `setindex!`). That is a genuinely separate wall; the fixture writes the 14
  inserts out straight-line to avoid conflating them. Worth a bead if anyone
  wants loop-driven Dict fills.
* The static hazard scanner's first version keyed blocks by their `func#label`
  prefix and mapped an UNQUALIFIED label to itself — which put every hand-built
  test block in its own "function" and made the scan silently blind. Testset (1)
  caught it. Unqualified labels now map to one shared sentinel.
* Mutation-proof needs the file included INSIDE an outer `@testset`, otherwise
  the first failing top-level testset throws and you never see whether the
  control stayed green.

**Mutation-proof result** (Rule 5): re-inserting `delete!` → §(1) straight-line
witness, §(2) loop witness and §(4) the 14-insert Dict gate all ERROR with
`unbound SSA name`; the §(3) control stays **41/41 green**, which is what makes
the three failures attributable to the hazard rather than the harness. §(5) and
§(6) stay green by design (structural claim; diagnostic).

**Files**: `src/interpreter/Interpreter.jl` (the fix + docstring),
`src/ir/unbound_ssa.jl` (new), `src/ir/arithmetic_assignment.jl` (`_resolve`),
`src/ir/define_instruction.jl`, `src/history/Injective.jl` (comment),
`src/BennettVM.jl` (include), `docs/adr/0022-phi-edge-binding.md` (new),
`test/test_rnhv_phi_multiuse.jl` (new, 251 assertions), `test/test_interpreter.jl`
(4 testsets renamed + the `!haskey(:m)` assertion flipped to `haskey`),
`test/runtests.jl`. `src/ir/ingest.jl` / `ingest_phi.jl`: **untouched, on
purpose** — that is what keeps the pinned Define counts byte-identical.

---

## 2026-07-24 — `Dict{Int64,Int64}` runs and reverses on the VM (Bennett-a70z, downstream half)

Cross-repo verification session. Bennett.jl branch `a70z-overflow-bit` @ `d4b4fa1`
checked out (BennettVM's `Manifest.toml` path-deps `../Bennett.jl`, so BVM built
against it automatically). **BVM needed ZERO source changes** — the prediction in
the 2026-07-21 HANDOFF ("BVM needs no changes for a70z; emitted opcodes already
ingestable") held exactly. One new test file, one `runtests.jl` registration.

**The result: `Dict{Int64,Int64}` is end-to-end green.** `fdict64(a,b) = (d =
Dict{Int64,Int64}(); d[a]=b; d[a])` extracts as a 4-body closed-world set
(`fdict64`, `setindex!`, `rehash!`, `ht_keyindex2_shorthash!`), lowers to a
552-block / 4-function `VMProgram`, runs in **664 steps** to `fdict64(3,7) == 7`
and `fdict64(5,9) == 9`, and `unrun!`s to the exact initial state with empty
history under BOTH the L2 and L3 regimes. Per-step inverse holds across the whole
trajectory. i8 non-regression re-verified first: `test_dict_roundtrip.jl` 34/34,
`test_x3t0_multikey_return.jl` 100/100, both `--check-bounds=yes`.

New gate: `test/test_a70z_dict64_roundtrip.jl` (347 assertions,
`--check-bounds=yes`), registered after `test_jlglobal_singleton.jl`. ~45 s,
dominated by the one-time closed-world extraction (done once at module scope and
shared across the five testsets — the sibling files re-extract per testset, which
we deliberately did not copy).

### What surprised us / what a future agent should know

* **The i64 path went further than the i8 path did on its first day.** No new
  wall at all: extract → lower → run → round-trip on the first attempt. The
  known next frontier, `bennettvm-rnhv` (Dict GROWTH, ≥14 inserts → the
  rehash-grow copy loop, `KeyError: :__v96`), did **not** arrive early — a
  single-insert `Dict{Int64,Int64}` never enters the grow-copy path. i64-vs-i8 is
  purely an *element-size* axis (elsize 8 vs 1); `rnhv` is an orthogonal
  *element-count* axis. Don't conflate them.

* **`__vN` SSA names COLLIDE across the four extracted bodies.** The first probe
  scanned `active_locals` by name and reported the a70z fuse bit `__v152` taking
  the value `1099511628136` — which is `ARENA_BASE (2^40) + 360`, i.e. a *heap
  pointer* held by a different frame's identically-named SSA value, not a
  corrupt i1. Any per-name inspection of a multi-body closed-world run is
  frame-ambiguous. The fix, and the idiom the new test uses: resolve
  `_instruction_at(prog, rs.current.pc)` **before** `step!`, and only then read
  `active_locals` — that pins the record to the executing frame.

* **The a70z sites really execute, and only 2 of 4 do.** On the single-insert
  trajectory the fuse fires twice inside `rehash!` with `%value_phi == 16` (the
  `Dict{Int64,Int64}()` initial slot count → `16*8 = 128` bytes, no overflow);
  the other two sites sit on `rehash!` paths this program never takes. The
  overflow bit is 0 at both, so `Dict` control flow takes the no-overflow arm.

* **Consequence for the runtime check: the only operand value ever observed is
  16.** Asserting `(v < -2^60) | (v > 2^60-1) == mul_with_overflow(v,8)[2]` on
  the observed values is therefore nearly vacuous — 16 is 57 binades from either
  boundary. The overflowing arm is *unreachable* from any terminating `Dict`
  program (a Dict with > 2^60 slots cannot be allocated), so it can never be
  covered dynamically. The test covers the bounds **arithmetically** instead
  (testset (d0): both boundaries, the adjacent rejects, the type extremes, a
  256-value random sweep, and tightness on both sides). Mutation-proof: `_A70Z_HI
  + 1` turns testsets (a), (b), (d0) and (d) RED (11 failures) — the a70z
  assertions are load-bearing, not decorative.

* **`Define` carries the icmp predicate; `IRICmp.width` is the OPERAND width.**
  The a70z compares ingest as `Define(dest, %value_phi, :slt, -2^60, 64)` —
  width 64, not 1, because the i1 result is never masked (ADR 0012 R1 / §D2).
  The fuse ingests as `Define(bit, lo, :or, hi, 1)`. Both are pre-existing arms
  in `src/ir/ingest_body.jl`; nothing new was needed.

---

## 2026-07-24 — beads sync: the local dolt DB had silently rolled back the 7xa close

Operational session, no source change. `git` was already at `origin/master`
(0 ahead / 0 behind) — but that says **nothing** about bead state in this repo,
and this session is the cleanest demonstration yet of why.

**Symptom.** `bd stats` read **216 issues / 129 closed / 2 in_progress**, while
the git-tracked `.beads/issues.jsonl` (committed 2026-07-21 in `4ca1f1f`) held
**217 issues + 1 memory / 143 closed**. Concretely, `bd show bennettvm-7xa`
printed **OPEN** — the local DB still believed the P0 SC9-Case-B gate was open,
five weeks after the milestone entry below records it CLOSED. An agent trusting
`bd` over the jsonl would have re-litigated finished work.

**Cause — the sync model, working as designed.** BennettVM is **jsonl-ONLY**:
`.beads/embeddeddolt/` is not git-tracked (`git ls-files .beads/` lists exactly
9 files, none under `embeddeddolt/`), so the dolt DB is per-machine scratch and
bead state crosses machines *only* through `.beads/issues.jsonl`. `git pull`
moves the jsonl and leaves the DB untouched. This differs from Bennett.jl, where
the dolt store itself is committed and the jsonl is the secondary export — so
the two repos fail in **opposite** directions and need opposite fixes.

**Fix.** `bd import` → "Imported 217 issues and 1 memories"; DB now 217 / 143
closed / 74 open, `7xa` CLOSED, `case-b-closed-world-settled` memory intact.
Nothing to commit — `git status .beads/` was clean afterwards. (Note: bd did NOT
auto-re-export and re-dirty the jsonl this time, unlike the 2026-06-25 session;
don't assume — check `git status` after every import.)

**Rule for future agents in this repo: after any `git pull`, run `bd import`
before trusting `bd ready` / `bd show`.** It is load-bearing, not cosmetic.

Sibling side, same session: Bennett.jl had the mirror-image problem — its dolt
store was current (595 issues + 9 memories) but its `issues.jsonl` was 5 weeks
stale, missing `Bennett-a70z`/`zdd6` and three closes. Refreshed and committed
there (`73b796c`). Full write-up in `Bennett.jl/worklog/095`.

Left untouched: the eight untracked `references/*` literature directories
(ad-and-checkpointing, foundational, implementations, quantum-uncomputation,
reverse-debugging, reversible-ir, reversible-isa, reversible-languages) — owner's
call whether they belong in git.

---

## 🎯 MILESTONE — 2026-07-12 — bennettvm-7xa CLOSED: SC9 Case B (reversible Julia Dict) COMPLETE

With `90l`/`klgz` landing below, EVERY dependency of the P0 e2e gate `7xa` is
closed and the bead is closed: **`fdict(Int8(3),Int8(7))` from plain Julia
source compiles, runs (==7; also (5,9) and a two-key no-grow variant), and
round-trips to the exact initial state with EMPTY history + full-trajectory
per-step inverse.** One session (2026-07-12, three orchestrated 3+1/2+1
cycles) cleared the last three walls: jl_global singleton materialization
(`416r.13`/`416r.4`), the GenericMemory element-traffic semantics +
byte-granular Julia tier (`9n3y`), and the determinism guard (`90l`/`klgz`).
Bounded successors: `bsng` (elsize>1), `san3` (Dict growth), `jb6w`
(literalness-spill discriminator). Suites at close: BVM 9848/9848; Bennett.jl
689671+ / 2 pre-existing broken.

## Session — 2026-07-12 — bennettvm-90l: determinism-denylist mirror of the Bennett.jl klgz classifier

**Bead:** bennettvm-90l (paired with Bennett.jl `Bennett-klgz`). Last open
dependency of P0 `bennettvm-7xa`. Scoped as implementer + hostile-reviewer on
the RATIFIED scout design (`scratchpad/scout-90l-determinism.md`, Q5), NOT a
2-proposer pass — no new construct, no new lowering.

**What landed.** Extended `_NONDETERMINISTIC_CALLEES`
(`src/ir/ingest_call.jl`) with the RESOLVED identity-hash callee Symbols the
Bennett.jl front-end classifier demangles from `@"jlplt_<callee>_<N>_got"`
GOT stubs: `:ijl_object_id` (the live-verified stub name, 2026-07-12),
`:jl_object_id`, `:object_id`, `:jl_pointer_from_objref`,
`:ijl_pointer_from_objref` — alongside the pre-existing `:objectid` /
`:pointer_from_objref`. `memhash_seed` is deliberately NOT added (deterministic
content hash — in-scope for the reversible floor, walled front-end only as a
not-yet-modeled MODELING GAP, not a determinism reason). This is the
defense-in-depth MIRROR: an identity-hasher arriving as a raw `IRCall(Symbol)`
hits the same specific "nondeterministic" reject as `:objectid`, never the
generic SoftCall message.

**Mirror test.** Extended `test_fail_loud_completeness.jl` F1 with a
`bennettvm-90l mirror` testset iterating the new Symbols — asserts each rejects
naming "nondeterministic" and its own name, and NOT the generic SoftFloat
message. Keeps the two repos' identity-hash sets in sync (a front-end name added
without the VM mirror, or vice versa, trips it).

**OUT OF SCOPE (documented in the test + this log).** The bead's "inlined
no-callee" extension — the `load ptr @jlplt_*_got` + INDIRECT-call-through-SSA
shape — CANNOT reach VM ingest today: the Bennett.jl front-end 416r.13
classifier walls the load before any `ParsedIR` is produced (scout Q4). No such
`IRCall` is ever constructed, so there is nothing for the denylist to catch on
that path. The indirect shape is blocked-by front-end runtime-callee GOT-stub
modeling (depends-on, not do-now). Per ADR 0017 corollary, the guard's
long-term home is the circuit-lowering boundary (address hashing is
deterministic INSIDE the deterministic virtual heap); this VM denylist remains
a worthwhile belt-and-suspenders at ingest.

**Regression:** `test_fail_loud_completeness.jl`, `test_cwd4_genericmemory.jl`,
`test_jlglobal_singleton.jl` green — the fdict e2e stays green + bit-identical.

---

## Session — 2026-07-12 — bennettvm-9n3y (CW-D4): faithful GenericMemory model + byte-granular Julia heap tier — **fdict WORKS e2e**

**Bead:** bennettvm-9n3y. Implementer in a 3+1 (architecture = design-cwd4-A
per the orchestrator's ruling; mechanics — blast-radius table, R3
value-alongside-round-trip guard — from design-cwd4-B). Front-end half
(header-GEP byte-stamp) in Bennett.jl worklog chunk 094. **SC9 Case B lands:
fdict(3,7) == 7 AND fdict(5,9) == 9 with full round-trip to the exact initial
state + EMPTY history + per-step inverse over the whole trajectory — the
first end-to-end Julia Dict program through the reversible VM.**

**The two interlocked defects (scout-cwd4-element-traffic.md).** (D-a)
`jl_alloc_genericmemory_unchecked` lowered to a bare bump alloc that wrote
NOTHING — but a GenericMemory's data-ptr is set by the native RUNTIME (no IR
store site exists; rehash!.ll stores only the length, line 737). Every element
access read data-ptr = absent = 0 → slots/keys/vals collapsed onto ONE cell →
vals(7) overwrote keys(3) → lookup missed → `__unreachable__`. (D-b)
`gc_alloc_obj` reserved `nbytes÷8` cells while Julia struct fields are
BYTE-offset i8 GEPs — a 64-byte Dict reserved 8 cells, so the next Memory
header landed ON Dict.keys@+8.

**Decisive ground truth (why byte-granular, not cell+1).** The data-ptr is
read through TWO shapes (callee_rehash!.ll:755-769): word-shaped `{i64,ptr}`
field-1 GEP (→ cell +1 under the old stamp) AND byte-shaped `gep i8 %m, 8`
(fill!/memset, runtime length, LIVE → cell +8). Design B's "write at +1, no
front-end change" is refuted by the memset path (it would memset address 0).
The 416r.13 singletons already fixed data-ptr@byte-cell 8 — byte-granular is
the committed convention; the front-end re-stamps the `{i64,ptr}` header GEP
to elem_width 8 (LITERAL-struct-scoped; named C structs keep 64).

**Changes.** `src/ir/intrinsics.jl`: `_byte_cells` (no ÷8, no %8 check);
`IntrinsicGenericMemoryAlloc` struct + `GM_HEADER_CELLS=16` + `_ArenaAlloc`
union membership; `_alloc_cells(GCAlloc)` → byte-granular. NEW
`src/ir/intrinsics_genericmemory.jl`: the specialized `forward` (reserve
16+nbytes; write `M[base+8] = base+16`; fail-loud if the data-ptr cell is
already present — the disjoint-window guard); `IntrinsicMemsetBytes` (byte-
exact fill: `nbytes` cells each = the byte VALUE — the C SWAR memset is wrong
twice in the byte tier: span ÷8 and smear); `_enforce_julia_heap_tier!`
(mixed C+Julia allocs fail loud; Julia-tier memset REWRITTEN to MemsetBytes;
Julia-tier memcpy/memmove fail loud — the grow-copy must arrive loudly).
Wired into BOTH lower_vm entry points (lower_vm.jl + ingest_multi.jl, on the
merged module — tier is a property of the ONE arena). `ingest_call.jl`: the
genericmemory arm emits the new intrinsic. Trait rows in Injective.jl (false)
+ delta.jl (L2). Reversal: the inherited `_ArenaAlloc` L2 (base,cells)
region-delete — the data-ptr cell was absent pre-alloc, so the unconditional
delete restores absent-ness (IntrinsicCalloc precedent); verified by the unit
round-trip (`isempty(s.memory)` — no phantom cell).

**Length is NOT written by the alloc** — the program's own
`store i64 nelems, {i64,ptr}#0` owns it. Pinned (`!haskey(memory, base+0)`).

**Tests.** NEW test_cwd4_genericmemory.jl (RED→GREEN, 50/50): unit alloc
round-trip, gc_alloc byte-span (next alloc lands at +64, NOT on Dict.keys@+8
— the exact regression), MemsetBytes semantics, ingest shapes, mixed-tier /
memcpy / negative-size fail-louds, the fdict e2e battery (two input pairs, R3
value guard, 3-data-ptr disjointness pin, per-step inverse). Wall-pins
FLIPPED to success: test_jlglobal_singleton (e) 28/28, test_x3t0 (f) 8/8 —
comments keep the chain history (static chain → jl_global → CW-D4).
test_416r12 re-pinned to the NEW model (26/26); test_gc_alloc_obj_ingest
arena_top 8→64 (23/23).

**Blast radius (per-fixture):** C tier BYTE-IDENTICAL — test_c_hashtable_e2e
73/73 (~4.4 min), test_arena_roundtrip 54/54, test_global_array_vm 2375/2375,
test_memory_floor 63/63, test_igr3 8/8, test_6bu3 28/28, test_416r16-bridge
29/29. Legitimately changed: test_416r12 (pinned the OLD bare-bump model),
test_gc_alloc_obj_ingest (pinned the ÷8 reservation — defect D-b), the two
wall-pin flips (the deliverable).

**Next walls (probed, NOT fixed):** (1) `Dict{Int64,Int64}` — EXTRACT wall in
Bennett.jl (`smul.with.overflow` overflow bit not provably zero for elsize 8).
(2) Dict GROWTH (14 inserts → rehash-grow copy loop) — RUN wall in the VM:
`KeyError: key :__v96 not found` (undefined SSA on the grow path). Two-key
fdict2 (no grow) already works e2e. Gotcha for future agents: the tier pass
runs POST-merge, so a Julia-set function containing memset gets MemsetBytes
even if the memset lives in a different function than the allocs.

---

## Session — 2026-07-12 — bennettvm-416r.13: clear the `jl_global#NNN` runtime wall (VM half)

**Bead:** bennettvm-416r.13 (+ tail of 416r.4). Implementer in a 3+1 (base
Design B; adopted A's D2 fail-loud + A's D5 read-window trap). Front-end half in
Bennett.jl's worklog (chunk 094).

**The wall.** `run!` on the lowered fdict set threw `KeyError:
Symbol("jl_global#NNN")` in `Define.forward` at Dict construction — the front-end
dropped the empty-`GenericMemory` singleton load and left a dangling operand. The
front-end now models each singleton as a zeroed 16-cell header in
`ParsedIR.globals`; the VM half seeds it and lifts the multi-function guard.

**VM change (this repo).** 3 files, ~55 LOC:
- `src/ir/ingest.jl`: new `_referenced_global_names(inst, globals)` — reflects
  over every field so a global referenced as an `IRPtrOffset.base`/`IRStore.val`
  (the singleton shape) is detected, not just an `IRVarGEP.base` (D8). Generalises
  the old scan; the `_j_const#N` memcpy-source literals stay excluded (never an
  SSAOperand). `_global_segment` gains `base_offset` (module-wide cursor, D7);
  `_lower_parsed_ir` threads `global_base_offset`.
- `src/ir/ingest_multi.jl`: **DELETED** the single-function-only fail-loud guard;
  replaced with a monotone `global_cursor` giving each function a DISJOINT window
  + a merged module ROM carried into the merged VMProgram (D7; subsumes h6c3).
- `src/ir/memory_floor.jl`: `MemoryLoad.forward` read-window trap (D5) — a
  globals-tier read of an UNSEEDED cell now fails loud (was silent absent=0).

**GROUND-TRUTH SURPRISE (the read-window trap vs the TLS tier).** Designs A/B
assumed `>= GLOBAL_BASE` (2^48) cleanly identifies the globals ROM. It does NOT:
the Julia GC preamble's `julia.get_pgcstack` walk lives in a SECOND tier at
`TLS_BASE = 2^56` (`ingest_call.jl`), and its one `MemoryLoad` (`ptls_field ≈
TLS_BASE+16`) is DESIGNED to read an absent cell → zero-init (structurally dead,
ADR 0021 D3). My initial trap broke it (`rehash!` trapped at 2^56+16). Fix:
carve out the TLS tier — added `_TLS_TIER_GUARD = 2^32`; a read `>= TLS_BASE -
_TLS_TIER_GUARD` keeps serving 0. The tiers are 2^24× further apart than the
guard, so no real globals read is swallowed. Mechanical adaptation, documented
(contradiction clause). `test_p81t_pgcstack` 29/29 confirms.

**CELL ADDRESSING (settled empirically).** The construction GEP is `i8, …, 8`
→ 1-byte cells → data-ptr at **cell base+8**, length at base+0. 16-cell header
correct. (Census Q1's `:add,1` was wrong; Design B's `:add,8` confirmed.)

**POISON.** Fell back to 0 (documented): A's D5 poison needs either a VM address
in the front-end (breaks the layer split) or a new channel (breaks B's "reuse
.globals, no new field"). The data-ptr@8 read is inert anyway (len-0 memset).
The read-window trap covers the miscompile class instead.

**Tests.** `test/test_jlglobal_singleton.jl` (new, 25 assertions): hand-built
single-function singleton (seed + Define-prepend + length-0 read + round-trip);
two functions → DISJOINT module-wide windows (32 cells, the ex-guard path);
store-onto-singleton fails loud; read-past-header fails loud; TLS read serves 0;
the REAL fdict set lowers + `run!` gets PAST construction. `test_x3t0` (f)
FLIPPED: the jl_global KeyError is gone; now pins `!jl_global` +
`__unreachable__` (the successor wall). Registered after `test_global_array_vm`.

**Regressions (default mode):** x3t0 all green incl. flipped (f); global_array
2375/2375 (trap + TLS carve-out safe); 416r16 29/29; gc_alloc_obj 23/23; arena
54/54; p81t 29/29.

**NEXT WALL (successor bead).** fdict(3,7) now runs past construction + the TLS
read + into setindex!/rehash!/ht_keyindex2, returns to the root, and the final
`d[a]` lookup's key-index comes back NEGATIVE (not-found) → the provably-dead
`:__unreachable__` throw sink (`fdict_d1b#__unreachable__`, pc≈233). A **Dict
element-traffic SEMANTICS gap**: the empty-singleton header + genericmemory-alloc
model does not yet round-trip a stored key. Successor: the rehash!/setindex!
element traffic — NOT global materialization.

---

## Session — 2026-07-11 — bennettvm-416r.16: caller-side consumed-sret reconciliation (CW-D blocker 5, LAST static wall)

**The wall.** Downstream of x3t0, the closed fdict set died at guard-5's
sret_box MEMORY-ABI gate (`src/ir/ingest_body.jl`): `setindex!` calls
`ht_keyindex2_shorthash!` with `ret_width = 64 ≠ 72 = sum([64,8])` — a call
using the sret_box result-buffer ABI (an explicit local box the callee writes,
whose fields the caller reads back), which BVM's value-ABI slot-family path
cannot land. This was the LAST static wall.

**Resolution is FRONT-END, not BVM.** The chosen design (Proposer A) reconciles
the ABI in the Bennett extractor (`../Bennett.jl/src/extract/sret.jl`,
`_collect_consumed_sret` + `_apply_consumed_sret_loads!`): a consumed sret-out
box call is rewritten to the VALUE ABI at extraction — the box `alloca` is
suppressed, the call becomes `IRCall(dest, callee, [h,key], [64,8], 72)`
(`ret_width == sum(field widths)`), and the box field reads become
`IRExtractValue` off the call's aggregate. BVM then ingests it through the
EXISTING x3t0 value-ABI path (CallEnter lands the `_agg_slot_name` slot family,
IRExtractValue slot-copies it) with ZERO new BVM lowering. Why front-end: the
field byte offsets `{0,8}` are `{i64,i8}`'s SysV layout — front-end ground truth
via `LLVMOffsetOfElement`. A BVM-side reconstruction would re-derive offsets from
widths, but hetero structs have PADDING (offset ≠ Σwidths) → silent-miscompile-
prone. Reconcile where the datalayout is live.

**BVM changes (small).**
1. `src/ir/ingest_body.jl` guard-5 message RETARGETED: was "DEFERRED … blocker-5
   follow-up bead bennettvm-416r.16"; now defense-in-depth — "the front-end
   consumed-sret reconciliation (Bennett extract/sret.jl, bennettvm-416r.16) did
   not fire … unreconciled sret_box ABI (Rule 1 fail-loud)". Kept "sret_box" in
   the text. The gate now catches an UNRECONCILED box-ABI call leaking to ingest
   (a front-end bug), not a deferred feature. It no longer fires for the REAL
   fdict set (the front-end rewrites it), but still trips on a hand-built
   ret_width≠sum call (test_x3t0 (d)).
2. Six wall-pin testsets FLIPPED from "advances to sret_box gate (blocker 5)" to
   "lowers to a VMProgram (static-wall chain DONE)": test_5m1t (b), test_p81t
   (f), test_416r14 (e), test_416r15 (e), test_x3t0 (f), test_416r12 (5)-comment.
   Each now asserts `prog isa VMProgram`, `haskey(prog.functions,
   :ht_keyindex2_shorthash!)`, and `length(...returns) == 2`.
3. test_x3t0 (d) sret-ABI static-wall testset re-purposed as guard-5 DEFENSE-IN-
   DEPTH (hand-built box-ABI call still trips it); its message asserts flipped
   from "blocker-5" to "416r.16"/"did not fire".
4. New synthetic test `test_416r16_consumed_sret_bridge.jl`: a hand-built 2-body
   set — callee returning {i64,i8} by-value (IRInsertBits chain), caller reading
   the value-ABI result's fields via IRExtractValue ACROSS THREE BLOCKS (field 0
   in `top` and `mid`, field 1 in `fin`) — pins cross-block slot-family liveness,
   full run!/unrun! round-trip vs oracle (104n+100).

**lower_vm(fdict set) NOW COMPLETES → VMProgram.** THE CW-D STATIC-WALL CHAIN IS
DONE. Verified: 4 functions (:fdict_d1b, :setindex!, :rehash!,
:ht_keyindex2_shorthash!); ht_keyindex2 returns arity 2, ret_elem_widths [64,8].

**The first RUNTIME wall is jl_global.** `run!` on the lowered program throws
`KeyError: Symbol("jl_global#23403")` in Define.forward (const-global
materialization) — reached quickly and deterministically. Pinned in test_x3t0
(f). Successor beads: bennettvm-416r.13 / 416r.4 (const-global materialization).

**SURPRISE (front-end): field 1 is read by a memcpy, not a load.** The design
census said "5 box loads." Reality: field 0 read 4× via `load i64`, field 1 read
by a 1-byte `llvm.memcpy` SOURCE (copying the shorthash byte into the Dict). The
extractor's memcpy handler lowers it to `IRLoad + IRStore`, so at ParsedIR level
it IS a load — but the front-end rewrite had to move to a by-NAME ParsedIR
post-pass to catch it (a memcpy reader has no LLVM `load` ref). Full detail in
the Bennett worklog chunk 094.

---

## Session — 2026-07-10 — bennettvm-x3t0: multi-key aggregate RETURN (CW-D blocker 4)

**The wall.** Downstream of 416r.15, the closed fdict set died at the
aggregate-RETURN reject (`src/ir/ingest.jl`: "IRRet returns aggregate SSA value
… DEFERRED", bead acq). This bead lands the multi-key return: a callee returning
a `{i64,i8}` by VALUE lands into the caller's per-slot `_agg_slot_name` family.

**THE RUNTIME IS ALREADY FULLY N-ARY — zero interpreter changes.** `ReturnExit`
(struct + `predelta_payload` + `forward` + `inverse`, `call_transitions.jl`) and
the End→ReturnExit synthesis (`Interpreter.jl` ~974, `rets = instr.returns`,
`fr.targets`) already loop over N returns/targets. Verified by testset (a) of
`test_x3t0_multikey_return.jl`: a HAND-BUILT 2-value CallEnter/ReturnExit module
round-trips (result correct, `unrun!` → empty history, frames==1, current==init)
— GREEN before any change. The whole bead is ingest/lowering only. Comment-only
touch at the synthesis site records it's now exercised with N=2.

**The uniform slot-family rule.** An aggregate SSA value is a family of N
`_agg_slot_name(name, k)` keys (the acq model). x3t0 extends the family to CALL
TOKENS: a value-ABI `IRCall` dest whose callee returns N>1 elements acquires slot
structure AT THE CALL SITE (`agg_dests` admits it via
`_is_value_abi_multiret_call`), so a caller `extractvalue`s the token and a
forwarding function `IRRet`s it directly (the __v207 shape, testset (c)).

**The `ret_width == sum(ret_elem_widths)` discriminator (NOT arg arity).**
Guard-5 (`ingest_body.jl`) splits the VALUE-return ABI (ret_width == sum → land
into slot family) from the sret_box MEMORY ABI (ret_width ≠ sum → blocker 5,
fail loud). It keys off the RETURN width, NOT argument arity — the self-recursive
`ht_keyindex2` call passes 1 arg vs 2 params (a separate frontend gap; the
orchestrator filed it as `bennettvm-416r.17`), so an arg-arity discriminator would false-wall it.

**Static, not runtime, sret wall (Rule 1: fail at the cause).** The sret_box
caller is rejected STATICALLY at ingest guard-5, not as a downstream runtime
arity symptom. `FunctionEntry` gained `ret_elem_widths::Vector{Int}` (last field,
back-compat `Int[]` default for the ~12 hand-built test sites) to carry the ABI
widths; `returns` still carries only arity/void-detection (its members are the
slot family, nominal for multi-exit functions — per-block End is authoritative).

**Entry multi-return is DEFERRED (both paths).** `result()` keys the halted
frame's registers by single SSA names, so a by-value multi-register ENTRY return
has no output key. Rejected in `lower_vm(multi)` (`ingest_multi.jl`) AND the
single-function `lower_vm(::ParsedIR)` (`lower_vm.jl`). `_lower_parsed_ir` builds
slot-family Ends for INNER callees only and cannot tell entry from callee, so the
entry-reject lives at the two entry points, not in the shared driver. This
superseded the old acq "returns aggregate SSA value" wall for the two
single-function test cases (test_aggregate_extract_insert (4),
test_fail_loud_completeness F2) — updated to pin the x3t0 entry wall.

**The real fdict set now stops at the sret gate during setindex! lowering.**
Merge order `[fdict, setindex!, rehash!, ht_keyindex2]`: fdict (scalar entry)
lowers, then setindex! calls `ht_keyindex2_shorthash!` with
`ret_width=64 ≠ 72=sum([64,8])` → guard-5 sret_box reject (captured: "IRCall to
multi-return :ht_keyindex2_shorthash! (dest=__v1) has ret_width=64 …"). The four
CW-D wall-pin tests (5m1t, p81t, 416r14, 416r15) flipped from the acq wall to the
blocker-5 `sret_box` substring; ht_keyindex2's own value-ABI return + self-call
are never lowered (4th, unreached).

**Discovery for the orchestrator (re-confirmed):** the L171 self-recursive
`IRCall(ht_keyindex2, [key], [8], ret_width=72)` passes 1 arg vs the callee's 2
params (frontend drops `h`) — a separate runtime-blocking gap, out of x3t0 scope (filed as `bennettvm-416r.17`).

---

## Session — 2026-07-10 — bennettvm-416r.15: IRInsertBits bits-struct sret packing (the {i64,i8} wall)

**The wall.** Downstream of 416r.14, the closed fdict set
(`extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8}; ptr_cells=true)`)
cleared the const-cond IRSelect wall and died at
`lower_vm: unsupported IRInst body subtype Bennett.IRInsertBits` — the
`_lower_body_inst` catch-all in `src/ir/ingest_body.jl`.

**The bead hypothesis was FALSIFIED (no IRExtractBits).** The 416r.12 / 416r.14
handoff notes predicted an `IRExtractBits` wall "right behind" IRInsertBits.
There is NO IRExtractBits anywhere in Bennett — packing only. Unpacking a
bits-struct return happens at the RETURN ABI via `ret_elem_widths` (Bennett's
`_read_output` consumes the widths contiguously in field order), never as an
instruction. So the successor is NOT IRExtractBits; it is the aggregate-RETURN
reject (see below).

**The 5-chain census.** All 10 IRInsertBits sites live in ONE function,
`ht_keyindex2_shorthash!`: five identical ZERO_AGG-rooted 2-insert chains,
`(off=0, vw=64, tw=72)` then `(off=64, vw=8, tw=72)` — a `{i64, i8}` = `(hash,
slot)` tuple. Each terminal dest is consumed by exactly one `IRRet(dest, 72)`
with `ret_elem_widths = [64, 8]`. The values are never stored / passed /
re-extracted. All bit offsets are compile-time `Int` fields. (A sixth return
site forwards a 72-bit value from a self-recursive call — `IRRet(__v207, 72)`,
NOT an InsertBits site; out of scope.)

**Why per-field slots dissolve the `total_width > 64` crux.** `IState.locals`
are `Int64`; a naive "pack 72 bits into one cell" would truncate. But
IRInsertValue (bead `bennettvm-acq`) already models an aggregate as a FAMILY of
per-field `_agg_slot_name(dest, k)` keys, one Int64 cell per field. IRInsertBits
reuses that family verbatim: field 0 (i64) → `_agg_<dest>_slot0`, field 1 (i8) →
`_agg_<dest>_slot1`. The packed 72-bit value is NEVER materialised — only the two
per-field scalars are — so `total_width > 64` is a non-issue. Confirmed by test
(c): a `{i8,i8}` tw=16 chain decomposes through the SAME path with no ≤64 special
case.

**Chain-follower vs global-partition (the design trade).** The dense field index
`k` is recovered by FOLLOWING THE CHAIN (`ZERO_AGG ⇒ k=0`; `SSAOperand naming a
prior IRInsertBits dest ⇒ k = prior k + 1`), NOT by parsing the bit-offset
arithmetic into a global bit→field partition. Ground truth (Law 1):
`_synthesize_sret_bits` (`../Bennett.jl/src/extract/sret.jl:947`) guarantees
ZERO_AGG-rooted, ascending-contiguous chains that tile `[0, total_width)` in
field order, `bit += w` after each field. The arm asserts BOTH invariants
fail-loud: a ZERO_AGG insert with `bit_offset ≠ 0` ("must start at bit 0") and a
non-contiguous next insert ("not contiguous"), plus an `agg` that is an
SSAOperand not naming a prior IRInsertBits dest ("unmodelled bits-struct shape").
A PARTIAL chain (higher fields never inserted) leaves higher slots undefined and
a downstream `resolve!` fails loud rather than silently zero-filling — acceptable
because the sret synthesizer NEVER emits partial chains (Rule 1).

**Slot / ret_elem_widths field-order alignment.** `k` matches `ret_elem_widths`
field order (field0-low / field1-high), so the eventual multi-key return (bead
`bennettvm-x3t0`) will treat IRInsertBits and IRInsertValue slot families
identically — one `EndInstruction.returns = [slot0, slot1, …]` keyed off the
widths. Test (d) pins the field order structurally: `_agg_b_slot0` copies from
`_agg_a_slot0` (inherited), `_agg_b_slot1` receives `:y` (the k=1 insert) — a
swapped-k bug flips these.

**IRExtractValue interop (the load-bearing reuse).** IRInsertBits dests are added
to the `agg_dests` pre-scan alongside IRInsertValue, so the EXISTING
IRExtractValue arm reads a bits-struct family with zero new code — test (a) builds
via IRInsertBits and reads both fields via IRExtractValue, round-tripping to empty
history. This is the proof the two slot families are one abstraction.

**Confirmed successor = the aggregate-RETURN reject (bead `bennettvm-x3t0`).**
After the fix the real set advances (empirically, ~2 min) to
`lower_vm: IRRet returns aggregate SSA value :__vNNN — returning a [N x iW]
aggregate is DEFERRED (bead bennettvm-acq …)`: the terminal IRInsertBits dest is
in `agg_dests` and dangles into the single-symbol `EndInstruction.returns`. This
is the PRE-EXISTING acq return guard (returns are out of scope here; the
orchestrator re-scoped x3t0 for the multi-key return). Beyond that, the
caller-side `setindex!` uses a 2-cell `sret_box` memory ABI (alloca + loads at
cell 0 / byte 8) — a DIFFERENT, later wall (blocker 5).

**Files.** `src/ir/ingest.jl` (agg_dests pre-scan +IRInsertBits; `bits_index` /
`bits_endbit` registries; the new body arm after IRExtractValue),
`src/ir/ingest_body.jl` (catch-all litany), `test/test_416r15_insertbits.jl`
(new, 48 assertions), three wall-pin flips (`test_5m1t` / `test_p81t` /
`test_416r14`) IRInsertBits → "returns aggregate SSA value", `test_416r12`
point-(5) comment, `test_opcode_coverage` taxonomy N/A→DONE prose (count stays
20), `test/runtests.jl` registration.

## Session — 2026-07-10 — bennettvm-416r.14: const-cond IRSelect fold (the optimize=false unfolded-select wall)

**The wall.** Downstream of p81t, the closed fdict set
(`extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8}; ptr_cells=true)`)
cleared the GC-preamble walls and died at
`lower_vm: IRSelect cond is Bennett.ConstOperand (dest=__v30)` — the IRSelect arm
in `src/ir/ingest_body.jl` required an `SSAOperand` predicate.

**The census.** 42 const-cond selects across the closed set (root 10, rehash! 9,
ht_keyindex2 23; setindex! 0) vs **69 SSA-cond selects** (untouched by this fix).
Cond encoding in-corpus: `ConstOperand(0)` ×41 (LLVM i1 `false` → false arm op2)
and `ConstOperand(-1)` ×1 (LLVM sign-extended i1 `true` → true arm op1, whose taken
arm is itself `ConstOperand(0)`). A bare `1` never appears in-corpus, but `1` MUST
be accepted (i1 `true`). All widths 64.

**Origin — the optimize=false caveat (Bennett Rule 5).** These are literal
`select i1 false, i64 0, i64 %x` in the −O0 IR of Base `Dict` internals.
instcombine would fold them at `optimize=true`, but the project mandates
`optimize=false` for predictable IR (Bennett Rule 5). Bennett does NO IR-level fold:
its **circuit** path folds these DOWNSTREAM at the GATE level via `_fold_constants`
(the utzc pruner only touches dead-block terminators). BVM is an interpreter with
**no gate layer**, so the const-cond select reaches ingest un-folded — hence the wall.
Consequence for the fold: it must be a **no-op when absent** (an SSA-cond select is
byte-identical to before; only the `ConstOperand`-cond branch is new).

**The fold.** Single touch point: the IRSelect arm gets a `ConstOperand`-cond branch
BEFORE the `SSAOperand` requirement. It statically resolves the taken arm
(`(c & 1) == 1 ? op1 : op2`) and emits the established non-injective
`Define(dest, lowered(taken), :add, 0)` — the same p81t Define idiom.

  * **Reversibility-neutral.** Both `Define` and `SelectInstruction` are
    `is_injective == false` (`src/history/Injective.jl`), reversed by the SAME L3
    checkpoint-replay. Swapping one non-injective create for another changes nothing
    about the reversal machinery.
  * **The `(c & 1) == 1` predicate ≡ the interpreter's `cond != 0`.** On the i1
    whitelist {0,1,−1}: `c != 0` → {false,true,true}; `(c & 1)==1` → {false,true,true}.
    Identical — so the fold is behaviorally identical to the select it replaces
    (proven directly by testset (c): the folded `Define` and a hand-built
    `SelectInstruction` with the cond materialised into a local write the same dest
    value for every `c ∈ {0,1,−1}`).
  * **NO width masking.** `SelectInstruction.forward` never masks its arms, so the
    fold must not either — it emits a default-width-64 identity copy. (Also correct
    for the width==0 pointer sentinel: pointers are Int64 cells.)
  * **False-path-safe by construction.** The UNTAKEN arm is NEVER `_lower_operand`'d
    — if it names a dead SSA value on a pruned edge, this fold references nothing.
  * **Fail-loud (Rule 1):** a cond value outside {0,1,−1} (e.g. `ConstOperand(2)`)
    errors with "not a valid i1 constant" — a non-boolean select cond is malformed
    or unmodelled IR.

**The TWICE-corrected successor wall.** The 416r.12 handoff predicted the successor
would be a const-globals guard. Empirically it was the const-cond IRSelect (this
bead). After THIS fold, the real set advances to
`lower_vm: unsupported IRInst body subtype Bennett.IRInsertBits` — the CONFIRMED
successor (filed as bennettvm-416r.15; bits-struct sret packing, Bennett-dv1z; `IRExtractBits` likely right
behind, const-globals later if at all). Do NOT trust wall predictions; run the set.

**Tests.** New `test/test_416r14_const_cond_select.jl` (56 asserts): fold-to-Define
unit (0/1/−1 + SSA-cond untouched), invalid-i1-const fail-loud, fold≡materialised-select
behavioral equivalence, a micro round-trip (P0.6), and the real set advancing to the
IRInsertBits wall. Flipped the two existing wall-pins (`test_5m1t` (b), `test_p81t` (f))
from `occursin("IRSelect cond is")` → `occursin("IRInsertBits")`, and updated the
`test_416r12` point-(5) comment.

**Gotcha for the next agent.** BVM test files that lack a top-of-file `using Test`
(e.g. `test_select.jl`) or that reference helpers defined in `runtests.jl`
(`per_step_inverse_check` in `test_collatz_roundtrip.jl`) CANNOT be run standalone —
they error with `@testset not defined` / `UndefVarError`. That is a harness artifact,
NOT a regression. `test_collatz_forward.jl` (26/26) and `test_opcode_coverage.jl`
(86/86) DO run standalone and were the SSA-cond-select regression witnesses here.

---

## Session — 2026-07-10 — bennettvm-p81t: the Julia GC-preamble walls (get_pgcstack + negative-offset GEP)

**Two co-located walls, one bead.** Downstream of 5m1t, the closed fdict set
(`extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8}; ptr_cells=true)`,
`fdict_d1b(a,b) = (d=Dict{Int8,Int8}(); d[a]=b; d[a])`) cleared the '#'-key wall and
died in the Julia GC preamble, which needs TWO fixes that are useless apart:

  1. **`julia.get_pgcstack` SoftCall reject.** A NULLARY named intrinsic returning
     the per-task pgcstack pointer, appearing in 2 of 4 bodies (root + `rehash!`),
     always a bare Symbol callee, 0 args, ret_width 64. Fell through to the SoftCall
     allowlist: `SoftCall: unknown callee_name :julia.get_pgcstack (dest=pgcstack)`.
  2. **Negative-offset IRPtrOffset guard.** Immediately after get_pgcstack the preamble
     walks the current-task struct: `current_task = gep i8 %pgcstack, -152` →
     `ptls_field = gep +168` (= pgcstack+16). The old `_lower_body_inst` IRPtrOffset arm
     hard-errored on `offset_bytes < 0` ("no production site emits a negative offset") —
     falsified by this exact site. A bare pgcstack fix alone just trips this next.

**The dead-value proof (why a fixed constant is sound).** In `rehash!` the chain is
`get_pgcstack → gep -152 → gep +168 → ptls_load = load(ptls_field)`, and `ptls_load`
feeds ONLY `jl_alloc_genericmemory_unchecked`'s arg[1]=ptls, which `_lower_intrinsic_call`
DROPS (ADR 0021 D3). No IRStore ever targets a pgcstack descendant. So the entire chain
is STRUCTURALLY DEAD — any constant base value is sound. In the root body `current_task`
has no consumer at all.

**The TLS sentinel tier.** `TLS_BASE = 2^56` — a FIFTH address tier continuing the
ascending convention (stack < 2^40 ≤ arena < 2^48 ≤ globals), with a 2^48-cell margin
above GLOBAL_BASE so no real global can collide. `julia.get_pgcstack` → `Define(dest,
TLS_BASE, :add, 0)`. Derived addresses stay in-tier: `current_task = TLS_BASE-152`,
`ptls_field = TLS_BASE+16`. Since `TLS_BASE+16 ≥ GLOBAL_BASE`, the one surviving IRLoad
reads the read-only globals ROM (`s.globals.cells`, NOT `s.memory`) with the absent=0
convention — confirmed by the micro round-trip (test d): `pl == 0`, and the ROUND-TRIP
still drains to empty history because the load is reversed by L3 checkpoint-replay.

**The gc_loaded arm lift.** The old inline `julia.gc_loaded` arm (`ingest_body.jl`) had
a comment: "A lone launder callee — lift to a set beside `_HEAP_DISPATCH` if more such
callees arrive." `julia.get_pgcstack` IS that second callee. Lifted both to
`_BENIGN_CELL_DISPATCH` (a Set of NON-heap runtime callees that lower to a non-injective
`Define`, contrast `_HEAP_DISPATCH`'s `Intrinsic*` ops) + a shared `_lower_benign_cell_call`
dispatcher, in `ingest_call.jl` beside `_HEAP_DISPATCH`. Guard ORDER preserved exactly
(ADR 0018 §C): nondeterminism → `_HEAP_DISPATCH` → `_BENIGN_CELL_DISPATCH` → Float32 →
SoftCall. The gc_loaded body moved VERBATIM (arity-2 + `Define(dest, _lower_ptr_operand(
args[2]), :add, 0)`), so `test_igr3_gc_loaded_ingest.jl` stays byte-green.

**Negative-offset relaxation.** Deleted the `offset_bytes >= 0` hard error; KEPT the
whole-byte + divisibility guards (both sign-agnostic: `-152 % 1 == 0` lowers,
`-3 % 2 != 0` still fails loud). `Define(dest, base, :add, idx)` is exact signed pointer
arithmetic. A taint-scoped tightening (reject negative EXCEPT on a pgcstack-derived ptr)
was considered and DEFERRED until a second negative-GEP source appears — a single blanket
relaxation is the senior-grade choice while this is the only producer. This INVERTED the
old `test_ptroffset.jl` (7) THROW assertion → rewrote it to pin the lower (element -2)
plus a kept negative-sub-element divisibility reject.

**Directional coupling check (rationale).** BennettVM MODELS `_BENIGN_CELL_DISPATCH`;
Bennett's `_D1B_BENIGN_INTRINSIC_PREFIXES` (`julia_set.jl:45-74`, a PREFIX tuple carrying
both `"julia.gc_"` and `"julia.get_pgcstack"`) must TOLERATE each modeled callee for the
closed-world completeness check to accept the surviving IRCall. Test (e) asserts
`any(startswith(String(c), p) for p in prefixes)` for each `c` — a DIRECTIONAL subset:
Bennett tolerates MORE (genuinely dropped intrinsics), so equality would be wrong.

**The successor wall — empirically corrected.** After BOTH fixes the set advances and
dies at `lower_vm: IRSelect cond is ConstOperand (dest=__v30)` — a const-cond IRSelect (filed as bennettvm-416r.14),
its own successor bead. NOTE: the 416r.12 handoff predicted const-globals as the next
wall; empirically the const-cond IRSelect wall precedes it. Test (f) pins the current
message and flips when the IRSelect bead lands.

**Surprise for future agents.** The micro round-trip load hits `s.globals.cells` (the
globals ROM), NOT `s.memory` — because `TLS_BASE+16 ≥ GLOBAL_BASE` classifies as a
globals-tier read (`memory_floor.jl` `MemoryLoad.forward`). It still returns 0 (absent)
and still reverses cleanly, but if you ever seed a real global near 2^56 you'd alias the
TLS tier — the 2^48-cell margin is what keeps them disjoint.

**Files.** `src/ir/ingest_call.jl` (+`TLS_BASE`, `_BENIGN_CELL_DISPATCH`,
`_lower_benign_cell_call`); `src/ir/ingest_body.jl` (set-dispatch arm replacing the inline
gc_loaded arm; relaxed IRPtrOffset guard); `test/test_p81t_pgcstack.jl` (new, 31 asserts);
flipped pins in `test_5m1t_content_addressed_keys.jl` (b), `test_ptroffset.jl` (7),
`test_416r12_jl_alloc_genericmemory.jl` (5) comment; registered in `runtests.jl`.

---

## Session — 2026-07-10 — bennettvm-5m1t: content-addressed Julia-set keys (CW-D, blocker 0 cleared)

**The wall.** `lower_vm(::Vector{Pair{Symbol,ParsedIR}})` could not ingest a Bennett
closed-world Julia set. `extract_parsed_ir_set_from_julia` (Bennett
`src/extract/julia_set.jl:120-121/338`) emits CONTENT-ADDRESSED keys of the shape
`<barename>#<8hex-digest>` (e.g. `setindex!#cfbb045b`, `fdict_d1b#4a8d3eda`) — the
digest disambiguates argtype specialisations. Two layers broke:
  1. **Reject** — `ingest_multi.jl` fail-loud-rejected any '#'-bearing key ('#'
     reserved for label qualification, ADR 0019 §2). This was blocker 0.
  2. **Guard-5 miss** (deeper, latent behind the reject) — the table was keyed by the
     DIGESTED key, but the in-set call sites carry a BARE `nameof` (a digest-free
     `Function` callee). So even past the reject, every cross-body `CallEnter` would
     miss the table.

**Fix (two converging helpers).**
  * `ingest_multi.jl` `_vm_funcname(key)` — de-digests a table key to its bare VM name:
    strip the 9-char `#<8hex>` tail, then sanitise any RESIDUAL '#' to '.'. Closure
    barenames are themselves '#'-bearing (key `#9#<digest>` → `.9`). '#'-free keys
    (C-track / bare) are fixed points. Non-digest '#'-bearing keys keep the old
    fail-loud reject.
  * `ingest_body.jl` `_vm_dispatch_name(callee)` — sanitises the call-site closure '#'
    to '.' (no digest to strip; call sites are bare). Rewrites guard-5 ONLY; every
    other guard (nondeterminism / heap / gc_loaded / Float32) stays on raw
    `_callee_sym` byte-identically.

**Why '.' not '_'.** '.' is chosen PRECISELY because Julia's `nameof` can NEVER
produce '.', so a sanitised closure name (`.9`) can never structurally alias a genuine
function name — it's impossible-by-construction, not merely collision-detected. ('_'
is a legal `nameof` char and would risk aliasing.)

**Collision guard.** Two keys de-digesting to the same bare name (`f#aaaa1111` +
`f#bbbb2222` → `:f`) fail loud naming BOTH originating keys — same generic function,
different specialisations, and bare call sites can't disambiguate (mirrors Bennett
`julia_set.jl` `_closed_world_check!`).

**The successor wall (verified, NOT this bead).** With blocker 0 cleared, the REAL
fdict set (`extract_parsed_ir_set_from_julia(fdict_d1b, Tuple{Int8,Int8};
ptr_cells=true)`; keys `fdict_d1b#…, setindex!#…, rehash!#…, ht_keyindex2_shorthash!#…`)
now advances past the '#' wall and walls at `julia.get_pgcstack` (a SoftCall allowlist
reject — bead `bennettvm-p81t`). Test (b) pins this exact successor message; when p81t
lands that assertion flips (intended).

**Test.** `test/test_5m1t_content_addressed_keys.jl` (registered after
`test_symbol_callee_ingest.jl`), 51 assertions: de-digest helper unit, real fdict set
clearing the wall → get_pgcstack, hand-built digested 2-body lower + full forward/reverse
round-trip, closure-barename sanitise (`#9` ↔ `.9`), same-bare collision fail-loud,
entry-kwarg dual-form (digested key AND bare name agree). RED first (helper undefined +
'#' wall everywhere), then GREEN 51/51.

**Regression.** Fast set (test_symbol_callee_ingest, test_call_roundtrip,
test_416r12_jl_alloc_genericmemory) all green; full `Pkg.test()` green. Comment-only
edit to test_416r12 point-(5) (blocker 0 now cleared; successor = get_pgcstack).

**Gotcha for the next agent.** The fdict extraction itself (Bennett side) is SLOW
(~2 min inside test (b)) — that dominates this test file's wall-clock, not the lowering.

---

## Session — 2026-07-07 — bennettvm-416r.12 LANDED (cross-repo): close the fdict closed-world set (CW-D2) — EXTRACTION COMPLETE

**What (BVM half).** `src/ir/ingest_call.jl`: add `:jl_alloc_genericmemory_unchecked`
to `_HEAP_DISPATCH` + a `_lower_intrinsic_call` arm → `IntrinsicGCAlloc(inst.dest,
_lower_operand(a[2]), _lower_operand(a[3]))`. Bennett's generic C-call arm carries
`[ptls, nbytes, typ]` (3 args, ptls NOT dropped upstream — contrast gc_alloc_obj's
task); drop a[1]=ptls, size=a[2] (the lbot-fused smul product), tag=a[3] (metadata,
structurally unread, ADR 0021 D3). Reuses `IntrinsicGCAlloc`/`_ArenaAlloc` → deterministic
arena bump + L2 retract, reverses for free. No name normalization (Bennett emits bare
`:jl_alloc_genericmemory_unchecked`; `_callee_sym` is identity on Symbols).

**Coupling.** `Bennett._D1B_MODELED_HEAP_INTRINSICS` (the front-end closed-world
whitelist) and `BennettVM._HEAP_DISPATCH` are MIRRORED Sets; a BVM-side test asserts
`Set(Bennett._D1B_MODELED_HEAP_INTRINSICS) == BennettVM._HEAP_DISPATCH`. Only a BVM test
can see both (BVM path-depends on Bennett, no back-dep). This machine-checks the
tolerate-here ⟺ ingest-there invariant so a future drift is a red test, not a silent
false-extraction-pass.

**MILESTONE.** Cross-repo close of the fdict EXTRACTION chain (6 walls: yd4f, 583s,
utzc/g501, lbot, 8bys, 416r.12 — Bennett.jl commit `8ee16bd`). The closed 4-body set
(fdict_d1b, setindex!, rehash!, ht_keyindex2_shorthash!) extracts under ptr_cells=true.

**lower_vm(fdict_set) next blockers (observed, IN ORDER — the assembly walls ahead; filed).**
  0. **`#`-in-key reject** at `src/ir/ingest_multi.jl:89` — BVM reserves `#` for label
     qualification (ADR 0019 §2), but Bennett's content-addressed set keys are
     `<bare>#<digest>`. Cross-repo key normalization at the set boundary.
  1. **`julia.get_pgcstack` SoftCall reject** at `src/ir/softcall_instruction.jl:253`
     (via `ingest_body.jl:361`) — a Bennett-side MODELED cell IRCall (feeds the current-task
     GEP chain, `julia_set.jl:66-73`, can't be dropped) with no BVM ingest home. Mirror
     `julia.gc_loaded`'s handling at `ingest_body.jl:270`.
  2. **Const-globals collision** at `ingest_multi.jl:129` — the multi-function const-global
     un-deferral (`bennettvm-416r.4`). Then byte/cell + aggregate-ABI round-trip debug.

**Process.** 3+1 (2 concise blind proposers → 1 cross-repo implementer → orchestrator
review + independent re-run). New `test/test_416r12_jl_alloc_genericmemory.jl` (23, incl.
the coupling cross-check); `test_dict_roundtrip` 34/34 + arena/ingest regression green.

---

## Session — 2026-07-07 — bennettvm-g501 LANDED via 3+1: reversible `:__unreachable__` halt sink (UnreachableHalt) — BVM half of Bennett-utzc / ADR 0017 §4

**What.** The BennettVM half of the cross-repo Bennett-utzc throw-block work. The
Bennett.jl frontend dead-block pruner (bead Bennett-utzc, landing next) emits a
provably-dead Julia throw arm (`@boundscheck`/`@assert` failure block) as an empty
block terminated `IRBranch(nothing, :__unreachable__, nothing)` — an unconditional
branch to the reserved sentinel `:__unreachable__`, a dangling TARGET with no source
block. Three pieces:
  - `src/ir/unreachable_halt.jl` — new `UnreachableHalt <: Instruction`, a non-control
    body instr that HALTS ON ENTRY: `forward` sets `status = :error`, bumps pc, mutates
    no locals/memory/cursor; `inverse` restores `:running`+pc; `is_injective=true` (no
    history push). FIRST producer of `:error` anywhere in `src`.
  - `src/ir/ingest.jl` `_lower_parsed_ir` — materialise a synthetic per-function sink
    block into a LOCAL `blocks` copy (BEFORE the `by_label` build, so the Phase-1 edge
    loop doesn't KeyError on the dangling target), `IRRet()` void leaf, `UnreachableHalt()`
    injected in Phase 2. `_q`-qualified per function so multi-function sinks never collide.
  - `src/interpreter/Interpreter.jl` `run!` — `while !is_halted` → `while status ===
    :running`, plus a loud fail on a post-loop `:error` (a taken dead abort = Rule 1 trap).

**Why `:error` not `:halted`.** A normal `End` → `:halted` (run! returns a result).
Reaching the sink means a provably-dead arm was TAKEN — a contradiction — so `run!`
must fail loud, not return a spurious result. The third status (`:error`, reserved
since M2.1 but never produced) distinguishes it.

**Gotchas (next agent).**
1. `while !is_halted` was `status !== :halted`, true for BOTH `:running` and `:error`
   — a sink setting `:error` would spin to `max_steps`. Changed to `status === :running`.
   Behaviourally identical for every existing program (`:error` was unproducible in src).
2. The sink MUST be materialised into a LOCAL `blocks` copy, NOT `parsed.blocks` — the
   multi-function `_declared_returns`/`_static_frame_size`/`#`-label validators read the
   ORIGINAL `parsed.blocks` and must not see the synthetic sink.
3. `:__unreachable__` is a branch TARGET only — the Bennett.jl `_expand_switches` FORBIDS
   a block literally so labelled, so the frontend keeps the dead block's own label and
   leaves `:__unreachable__` dangling; BVM is the side that materialises the real block.

**Tests.** `test/test_utzc_unreachable_sink.jl` (36): not-taken → round-trips to empty
history; taken → halts loud `:error` (distinct from `:halted`); multi-function
per-function sinks. Regression `test_dict_roundtrip.jl` 34/34 — the `run!` change is inert.

**3+1.** 2 blind proposers (cross-repo design) → implementer → orchestrator review +
independent re-run. Cross-repo sibling: Bennett-utzc (the Bennett.jl frontend pruner,
landing next as the second sub-step).

---

## Session — 2026-07-06 — 416r.4 LANDED via 3+1: const globals as read-only VM memory (unblocks real ROMs; closes dzd)

**What.** `bennettvm-416r.4` (const globals as initialized read-only VM memory
segments) — the prerequisite for loading a real NES ROM. Done via the CORE 3+1
protocol (2 opus proposers → 1 opus implementer → orchestrator review), because
it touches Bennett.jl's extractor AND BennettVM's IState/memory-floor.

**The scoping finding that shaped it.** A `const uint8_t rom[]` read at a runtime
index (`rom[i&7]`) breaks at the FRONT-END, not the VM: `getelementptr [8 x i8],
ptr @rom, i64 0, i64 %idx` is the SAME 2-index array GEP wall as C stack arrays
(dzd / qal5 / U16), just with a global base. So 416r.4 = front-end 2-index-array-
GEP support + VM globals materialization, and the front-end half ALSO closes dzd.

**Design decision (the 3+1 divergence I ruled on).** Both proposers converged
(reuse `IRVarGEP`, one-element-per-cell — VERIFIED against `_extract_const_globals`
which stores one zero-extended element per cell — `GLOBAL_BASE=2^48` tier). They
split on ROM storage: Proposer B seeded it into `IState.memory` (→ deep-copied
into EVERY L3 checkpoint — a 16KB ROM × thousands of checkpoints = scale-killer);
Proposer A used a read-only segment excluded from checkpoints. **Ruled for A** —
semantically correct (ROM is immutable) and essential for 16KB scale.

**Implementation (verified green by orchestrator, not trusted).**
- Front-end (Bennett.jl `src/extract/instructions.jl`): new "Case C" arm before
  the qal5 reject — 2-index array GEP on a const-global OR local-alloca integer
  array → `IRVarGEP(base, idx, elem_width)`. Fails loud on non-integer element /
  first-index≠0 / >3 operands. Handles BOTH bases → **closes dzd** (the C-stack-
  array wall E1 dodged with calloc).
- VM: `GlobalROM` wrapper with `deepcopy_internal(g,_)=g` — the override lives on
  the SMALL type, so IState's default field-by-field deepcopy stays safe (no
  fragile custom IState deepcopy; a future field can't be silently dropped). ROM
  is shared across all checkpoints, excluded from `==`/`hash`, seeded once at
  `initial_state`. `MemoryStore` to `>=GLOBAL_BASE` FAILS LOUD (const write =
  miscompile). `_global_segment` materializes only REFERENCED globals; a
  `Define(name,base)` prepended to the entry block binds the ROM pointer
  (reversible like any create).
- Verified: `test_global_array_vm.jl` 2375/2375 (gtest all 0:255 fwd==native +
  round-trip; store-to-global fails loud; dzd stack-array round-trip; 256B + 16KB
  arrays + ROM-NOT-in-checkpoint assertion). BennettVM full suite 9328/9328.
  Bennett.jl front-end (qal5/haiy updated legitimately, not weakened) green.

**Two touched Bennett.jl fail-loud tests (reviewed, legit).** qal5's original
fixture (`[4 x i32], ptr @tbl, 0, %i`) IS the 416r.4 goal and now extracts — the
test now positively checks that + rejects a genuine multi-dim `[2x[2xi32]]` and a
non-integer `[4xdouble]`. haiy swapped its now-supported `[4xi64]` local case for
`[4xdouble]` (still rejected). Fail-loud coverage preserved.

**CRITICAL follow-up for the roadmap.** Multi-function const globals are DEFERRED
behind a fail-loud guard (`ingest_multi.jl`): per-function `_lower_parsed_ir`
assigns bases from `GLOBAL_BASE+0`, so two functions referencing globals collide;
the merged VMProgram also drops per-function globals. **This is on the nestest
critical path** — `cpu6502.c` is multi-function and `cpu6502_core` (a callee)
reads the ROM. Filed as a follow-up bead + wired as a dep for A1/E2.

---

## Session — 2026-07-06 — E1 LANDED: full hardware-faithful 6502 core, all 151 opcodes green on the VM

**What.** E1 (`zbeg`, CLOSED) — `emulator/cpu6502.c`, a complete MOS 6502
fetch-decode-execute core, extracts + lowers + runs on BennettVM. Built by an
opus subagent; orchestrator-reviewed (code read + independent harness runs).

**THE DISPATCH VERDICT (E1's central de-risk).** A C `switch(op)` over the 151
sparse official opcodes, compiled at -O0, **survived extraction as 1 plain LLVM
`switch`, 0 `@switch.table` lookups** — no qal5/dzd lookup-table wall. So the
full opcode decode is a mechanical `switch`; the wall I feared (dense
if/elseif → jump table) does NOT materialize for sparse real 6502 encodings at
-O0. This is the key reusable finding for anyone extending the core.

**Verification (orchestrator ran these, did NOT trust the agent's report — which
was in fact a non-report; see gotcha).**
- Subset (5 representative groups: loads, ALU+flags, ALL addr modes, JSR/RTS +
  hardware stack, known-answer loop): **57/57, full fwd+rev round-trip** (VM==
  native, history empty, frames==1, cursors 0, current==initial).
- Full sweep (all 23 groups, forward-only via new `BENNETT_CPU_FWDONLY=1`):
  **273/273** — every opcode VM==native bit-for-bit + 6 known-answer semantic
  groups match closed-form 6502. Round-trip is a generic VM property (proven on
  the sample + hashtable/collatz), so forward-only all-opcode + round-trip-sample
  is the efficient-but-rigorous split.

**Code review — hardware-faithful, not a toy.** Correct ADC/SBC overflow; the
**JMP-indirect (0x6C) page-boundary bug** modeled; TXS sets no flags (TSX does);
PHP/PLP B/U handling; JSR pushes return-1, RTS +1, RTI no +1. **NES-correct: no
BCD** (the 2A03 disables decimal mode). mode-0 observable = xorshift64 checksum
over regs + \$0000-\$01FF so any reg/cell error avalanches (Rule 4).

**Gotchas worth knowing.**
- **The opus agent never reported.** Its final messages were "I'll wait for the
  monitor's completion event on the full run" — it had launched its OWN full
  fwd+rev sweep (~28min, pid 73232) in the background and idled on it, so the
  task-notification carried no summary. Lesson: a subagent that kicks off a long
  background job can complete with an empty report; the orchestrator MUST verify
  from artifacts, not the agent's final message. I killed the stale pid (and,
  clumsily, `pkill -f test_cpu6502` also killed my OWN verification run once —
  match patterns carefully when self-running the same harness).
- **Reverse cost makes full fwd+rev impractical to iterate:** ~5s/seed L3 replay
  → ~28min for all 23 groups. Added `BENNETT_CPU_FWDONLY` (uses B1 `record=false`)
  → same forward result, ~3min. This is why B1 landing first paid off immediately.
- Build artifacts (`cpu6502.O0.ll` 393KB, `cpu6502_golden`) are regenerated by
  `build!()` every run → gitignored (unlike the committed `test/reference/c/*.ll`
  fixtures, whose harness does NOT rebuild). Follow-up `bennettvm-6vp9`: clang-
  gate + suite-register a small FWDONLY smoke subset.

**Semantic-validation scope (honest).** E1 validates via known-answer programs +
hardware-faithful review + native-consistency — NOT against an independent 6502
reference. Full conformance is E2/nestest's job (that IS what nestest is for);
noted on `bc08`. The core is nestest-ready by structure (`cpu6502_core(mem,pc,
budget,mode)` runs from any PC over preloaded memory).

---

## Session — 2026-07-06 — Orchestrated build begins: B1 fast mode LANDED (E1 6502 core in flight)

**What.** Started orchestrating the emulator build: claimed E1 (`zbeg`, 6502
core) + B1 (`zr7x`, fast mode), delegated both to subagents in parallel (E1→opus,
B1→sonnet), orchestrator reviews each. **B1 landed + reviewed green + committed.**
E1 still running at time of this entry (`emulator/cpu6502.c` grew to ~58KB — a
full core).

**B1 — forward-only fast mode (`run!(...; record=false)`), CLOSED.**
- Mechanism: `record=false` ORs into the existing M7.6 `replay_mode` push-
  suppression (no new suppression logic) → no L1/L2/L3 tape recorded.
- **The non-obvious part (why it's more than a one-line kwarg):** a fast-mode
  RState ends with `isempty(history) && step_count>0`, which is *structurally
  identical* to the legitimate "normal run, no checkpoint pushed yet" case that
  `unstep!` reverses via its `s.initial`-replay fallback. Without a marker,
  `unrun!` after fast mode would **silently succeed** by full-replaying from
  `s.initial` on every backward step — O(n²), correct-but-catastrophic, exactly
  the Rule-4 "runs, just slowly" trap. Fix: a monotonic `fast_mode` taint bit on
  `RState`, checked FIRST in `unstep!` → fail loud. The agent (sonnet) caught
  this itself; good judgment.
- **Review (orchestrator = the +1):** read all 3 core-file diffs line-by-line;
  ran `test_fast_mode.jl` (56/56, suite mode), `test_delta_push.jl` (the
  legitimate empty-history replay the guard must NOT break — green), and
  `test_rstate.jl` (the `==`/`hash`/constructor change — 10/10). **Judgment call
  logged:** the `fast_mode` field is on `RState` (core-adjacent, `src/ir/`), NOT
  in the CLAUDE.md Rule-2 enumerated core list (ir_types/gates/lower/etc.). I
  accepted it WITHOUT full 3+1 — it's a defaulted bookkeeping field with direct
  precedent (`step_count`/`initial` were added post-hoc the same way), fully
  back-compat, thoroughly reviewed. Future agents: if the RState surface keeps
  growing ad hoc, revisit whether it warrants the 3+1 gate.

**The framerate baseline (this is the number that matters).** ~**67.7 VM-steps
per guest 6502-instruction** (stable across input sizes). → ~8.6–10k
guest-instr/s recording, ~18–24k fast. SMB needs ~500k/s. So the **toy** CPU core
is already ~50× short before any PPU — quantitative confirmation that Track B (C
port `eqz5` / native codegen `3h9u`) is mandatory for framerate, and that fast
mode buys only ~2.3×. Recorded on `zr7x` + design doc §9.1.

**No new beads needed for B1** — clean landing, no issues arising. The benchmark
data feeds existing B2 (`9xla`) / B3 (`eqz5`).

---

## Session — 2026-07-06 — North star raised: SMB @ NES framerate — two-track strategy + full bead DAG

**What.** The emulator north star was raised from "nestest headless" to **play
Super Mario Bros at actual NES framerate (60.0988 Hz), loading speedrun
scripts.** Assessed bead coverage (answer: existing beads cover *only* the
CPU-correctness trophy — zero PPU/APU/timing/loader/TAS/perf), specced a
two-track strategy into `docs/design/emulator-on-bennettvm.md` §9, and filed the
full DAG (16 beads + 1 new epic).

**The load-bearing finding (§9.1).** Framerate is UNREACHABLE on the current
Julia tree-walking VM interpreter — ~2–4 orders of magnitude short — because of
**double interpretation** (Julia interprets the VMProgram which interprets 6502;
1 guest instr ≈ 20–80 VM `step!`). Budget: SMB needs ~500k 6502-instr/s +
~5.4M PPU-dot/s; E0 measured ~28,500 guest-opcodes/s forward on a *toy* core.
**Reversibility is NOT the blocker** — `rr` does native reversible execution at
~1.2–2× overhead. The interpreter is. So framerate ⇒ get off the Julia
interpreter.

**Strategy (correctness first, user-directed).**
- **Track A** (epic `v5eb`, P2): full reversible NES, correct-but-slow, on the
  VM. Beads `hahl`(ROM/NROM loader) → `6sma`(PPU bg) → `tsjq`(sprites+sprite-0)
  / `pldf`(scroll+NMI) ; `jm77`(controller→InputRef) ; `87sk`(APU) ;
  `nxpa`(.fm2 parser) ; `ikow`(framebuffer golden vs FCEUX) ; capstone
  `ztz7`(SMB boots→1-1 under TAS). E1 `zbeg` bumped P3→P2 (gates all of Track A).
- **Track B** (NEW epic `1is3`, P2–P4): faster reversible execution. **Lead
  approach = PORT THE VM INTERPRETER TO C** (`eqz5`) — the user's directive; a
  fast C `run!`/`unrun!` reimplementing L1/L2/L3, ~10–50× over the Julia
  tree-walker, reversibility semantics port directly. `zr7x` forward-only fast
  mode lands first (baseline + decouples speed from reversibility). `9xla` Julia
  hot-loop opt ; `vspu` bounded rewind horizon (can't keep ~51M deltas/level) ;
  `3b70` real-time frame scheduler ; `3h9u` (stretch) native codegen + rr-style
  delta instrumentation.

**Gotchas / decisions worth knowing.**
- **SMB is genuinely the easy NES target for mappers**: Mapper 0 / NROM, no bank
  switching, and it uses only official opcodes. The hard parts are PPU
  sprite-0 hit (HUD/playfield split — load-bearing) + NMI timing, not the CPU.
- **A `.fm2` TAS movie is BOTH the speedrun-loader AND the PPU oracle** —
  per-frame framebuffer hashes vs FCEUX are the golden master (Rule 4).
- **`bd ready` after wiring** correctly surfaces exactly two entry points:
  `zbeg` (E1 core) and `zr7x` (B1 fast mode) — the intended parallel starts.
- **Beads-sync (again):** every `bd create` re-triggered the lossy auto-export
  that drops the 4 memory records; restored with `bd export --include-memories`
  before commit (per `reference_beads_sync_models` gotcha 1).

---

## Session — 2026-07-03 — Side quest: run an emulator (NES/6502) on the VM, reversibly — feasibility PROVEN + MVP

**What.** Investigated "decompile Super Mario Bros → LLVM → run on BennettVM,
log side effects to a tape." Split into two ideas: (1) *lift the ROM's 6502 to
LLVM* — dead end (undecidable statically: indirect jumps, self-modifying code,
mappers; jamulator abandoned); (2) *compile an emulator to LLVM, ROM as data,
side effects to a tape* — the right architecture, and it fits the VM. Built a
working MVP of (2), wrote `docs/design/emulator-on-bennettvm.md` + reproducible
`docs/design/emulator-mvp/`, filed epic `bennettvm-v5eb` (+ E0/E1/E2/InputRef).

**MVP (E0, `bennettvm-33bf`, CLOSED).** A genuine 8-opcode 6502 fetch-decode-
execute core in C (`docs/design/emulator-mvp/mos6502.c`) running hand-assembled
guest machine code (a BNE-driven loop computing 5·n), through the **C path**
(clang -O0 .ll → `extract_parsed_ir_set_from_ll(ptr_cells=true)` →
`lower_vm(entry=:mos6502)` → 406 VM instrs). Forward == native-C golden AND
`unrun!` to exact initial state, every input. GREEN + reproducible from the repo.

**Surprises / gotchas worth knowing (not in any diff):**
- **RAM was the easy part.** Dynamic array read/write at a *runtime index*
  round-trips today — better than the capability audit implied. Requirements
  1–3 (unbounded loop, runtime-index RAM, opcode dispatch) are all green NOW.
- **The Julia path can't back a real emulator yet.** `zeros(Int64,64)` +
  runtime-indexed loop → Julia heap-allocs via the GC, emitting `call ptr asm
  "movq %fs:0"` (thread-ptr for GC state) → rejected (Bennett-5oyt/U15). A
  *small* array (`zeros(Int64,8)`) is SROA'd away so it slips through — which
  is why a naive Julia smoke test misleads. **Use the C path** (this is exactly
  why the frontier e2e is a C hashtable, not Julia). Julia array path =
  `bennettvm-m9i` + the fdict/gc-alloc CW-D workstream.
- **C stack arrays are rejected; heap arrays pass.** `uint8_t mem[64]` emits a
  two-index GEP `[64 x i8], ptr, 0, %idx` → rejected (Bennett-qal5/U16, already
  bead `bennettvm-dzd`). Fix: `calloc`'d pointer RAM → single-index `i8, ptr,
  %idx` GEP, the shape the hashtable path handles. The MVP does this.
- **Dense if/elseif over small opcodes {0,1,2} → LLVM switch.table lookup GEP →
  rejected.** But *sparse real 6502 opcodes* (0xA9/0xE8/…), binary-tree, and
  control-divergent dispatch all pass. Real 6502 decode is sparse, so this is a
  non-issue in practice (verified: `smoke_dispatch.jl` D1/D2/D3).
- **Perf is the wall, as expected.** Reverse ≈ 570 guest-opcodes/s at K=32
  (L3-replay-bound); forward ~50×. Projected: forward ~0.5 s/NES-frame (~1–2 fps
  slideshow), reverse ~20–25 s/frame. Not a correctness blocker; `bennettvm-uom`
  (L1/L2 memory-delta lowering) is the lever. Cross-ref `bennettvm-w0a0`.

**Validation.** The spike independently rediscovered the exact known frontier —
every obstacle already had a bead (dzd, m6c/6ox/rlx/agm, 416r.4, m9i, uom, w0a0).
The one genuine gap with no bead: *recording* nondeterministic input (controller
reads) — filed `bennettvm-6dko` (InputRef, a TAS-movie input tape dual to
OutputRef). Trophy target: `nestest.nes` headless CPU conformance, reversible.

---

## Session — 2026-06-30 — Documentation round: production README rewrite + new docs/src site

**What.** Replaced the README (which was frozen at the Phase-1→2 transition — it called
the project "Phase 2 gated / M0", `bennettvm_prd.md` "PRD v3", and `src/`/`test/` "empty",
and spent ~90% of its body on the archived spike) with a public-facing front door for the
**production** VM: the `run!`/`unrun!` round-trip, the three-layer history model, the
instruction set, the registration-hook integration, and the four motivating cases (A–D).
Added a Diátaxis `docs/src` site from scratch — `index.md`, `getting_started/quickstart`,
`explanation/{what_is_bennettvm, instruction_set, reversibility_model, integration}`,
`reference/api` — plus `docs/make.jl` and `docs/Project.toml`.

**Method.** A mapping workflow (6 subagents) produced subsystem maps + a doc-staleness
audit; a write-then-adversarially-verify workflow authored the pages grounded in a
verified-facts block + source. The verify pass **empirically confirmed** facts by reading
source and compiling: e.g. the collatz entry-parameter key is `Symbol("n::Int64")` (not
`:n`) — the quickstart and README now use the correct key.

**Facts pinned in the new docs (from source).** Public API = exactly the 10 exports
(`VMProgram, lower_vm, n_instructions, initial_state, is_halted, result, step!, run!,
unstep!, unrun!`). `initial_state(prog, input::AbstractDict)` takes **two** args. IState
has **no flat `locals` field** — the active register file is `active_locals(s) =
frames[end].locals`. History is L1 injective / L2 `DeltaEntry` min-cut / L3 `CheckpointEntry`
(K=64) + replay; injective L1-skipped steps reverse via the **L3 replay fall-through**, not
a per-instruction inverse. Heap is **cell-addressed** `Int64`. There is no `:circuit`
symbol in Bennett.jl (the circuit target is `:gate_count`/`:depth`).

**Gotchas / follow-ups (unfiled — ran no `bd` to keep the jsonl export clean).**
- `BENNETT_JL_PIN.md`, `src/lower_vm.jl`, and `bennettvm_prd.md` §3.7 cite four divergent
  Bennett.jl SHAs — reconcile to one canonical pin.
- `src/BennettVM.jl` "Status" docstring is frozen at "M0.1 package skeleton only"; several
  PRD §3.x signatures (`initial_state(prog)`, the immutable-IState `step!` ordering, the
  `locals` field) describe abandoned designs. All catalogued in the session's subsystem maps.
- `docs/make.jl` uses `doctest=false` (the VM examples are plain ```julia blocks).

## Session — 2026-06-26 — Bennett-igr3: ingest julia.gc_loaded data-ptr launder (Small-tier)

**Bennett-igr3 landed** (the BVM ingest half; downstream of Bennett.jl `qmv7`). Bennett.jl's
qmv7 extraction emits the heap-Memory base of a `setindex!` value-store as
`IRCall(:d, Symbol("julia.gc_loaded"), [mem, data], [64,64], 64)` — Julia's GC-rooting
launder, which RETURNS the data pointer (args[2]); `mem` (args[1]) only keeps the Memory
GC-rooted and is STRUCTURALLY UNREAD. Before this arm, the IRCall fell through to the
SoftCall allowlist and failed loud ("unknown callee_name :julia.gc_loaded").

Added one arm in `src/ir/ingest_body.jl` (`_lower_body_inst`), right after the
`_HEAP_DISPATCH` check and before the Float32 guard / SoftCall constructor: it aliases
`dest := data` via the established pointer-identity create `Define(dest, data, :add, 0)`
(the cell-addressed VM treats the laundered data ptr AS the Memory virtual base — the base
qmv7's IRVarGEP/IRLoad/IRStore re-root onto). Reversed by L3 checkpoint-replay (`Define` is
non-injective, ADR 0012 §D1). Arg-count≠2 fails loud (Rule 1). `data` lowered via
`_lower_ptr_operand` (SSA-ptr discipline, matching IRStore/IRLoad/IRVarGEP).

Test `test/test_igr3_gc_loaded_ingest.jl` (8 @tests, registered beside its `gc_alloc_obj`
sibling): ingest shape `Define(:d,:data,:add,0)`, forward binding `:d==data`, the
mem-invariance soundness witness (vary `:mem` → bit-identical `:d`, mirroring gc_alloc
tag-invariance), and the fail-loud arity guard. Full suite **6897/6897**.

**Process** (BVM Rule 6 Small-tier: one file, ≤30 LOC, existing `Define`): TDD red→green
(Rule 5) + a hostile reviewer subagent → APPROVE_WITH_NITS (operand order + reversibility +
dispatch ordering all confirmed correct against ground truth; nit applied: use
`_lower_ptr_operand` not `_lower_operand` for the ptr arg). No full `run!`/`unrun!`
round-trip needed — gc_loaded emits a bog-standard `Define`, whose reversal is already
covered by the generic Define round-trip tests; it adds no new reversal mechanism.

**Symbol gotcha:** Bennett.jl emits the UN-canonicalised LLVM name `Symbol("julia.gc_loaded")`
(via the generic call path `Symbol(cname)`), NOT a canonical `:gc_loaded` — contrast
`:gc_alloc_obj`, which Bennett.jl DOES canonicalise (`instructions.jl:2636`). Verified
empirically against the qmv7 `GCL_I8` fixture (operand order `[mem, data]` per
`test/reference/fdict_O0.ll`).

**Next:** pairs with `Bennett-jfw6` (closed today, Bennett.jl side) toward the full fdict
e2e (`bennettvm-7xa`). The downstream BVM cell-index bug `Bennett-eln6` (i8 GEP byte-offset
mapped directly as cell-index) is the next CW-D item.

---

## Session — 2026-06-25 — M13 COMPLETE: vw8 e2e collatz capstone (target=:reversible_vm one-liner)

**bennettvm-vw8 landed; M13.1–M13.4 closed.** Added `test/test_e2e_collatz.jl`
(59/59 green; full suite 6889/6889) proving the user-approved capstone — the
public Bennett.jl one-liner

    Bennett.reversible_compile(collatz_steps, Int64; target = :reversible_vm)

— compiles, runs forward to the irreversible Int64 collatz oracle (capped-at-20
golden master), and `unrun!`s to the P0.6 exit invariant across 9 inputs (incl.
x=27→20). Routed via the **a5j load-time registration hook** (`__init__` sets
`Bennett._REVERSIBLE_VM_BACKEND[] = lower_vm`); arg/ret keys derived from the
Begin/End markers (robust to extraction renames, à la `test_fp_roundtrip.jl`).

**Bead-bookkeeping correction (recon-driven):** zg5/fu5/kl3 (M13.1–3) described a
STALE design — a `driver.jl` validator edit + a Project.toml extension dep — that
was **superseded by a5j's registration hook** (no `lower()` edit, no extension,
no circular dep; the dispatch arm in `reversible_compile` intercepts
`:reversible_vm` BEFORE `lower()` is reached). All three closed as superseded;
vw8 `--force`-closed (it was blocked by kl3 + the 7xa Dict / xkl Vector cases,
but scalar collatz is Case D — independent of those). The user had ALREADY
approved emitting `target=:reversible_vm`; the "REQUIRES USER APPROVAL" flags
were stale. **M13 is functionally complete** — the VM backend is reachable from
Bennett.jl's public API end-to-end.

NB cross-repo: this session also landed two Bennett.jl CW-D extraction walls
(Bennett-59zi sret call→memcpy; Bennett-qmv7 setindex! gc_loaded heap-store) that
feed the fdict path; see Bennett.jl worklog/090. Downstream BVM beads filed:
`Bennett-igr3` (ingest `julia.gc_loaded` IRCall — the next BVM-side fdict step).

---

## Session — 2026-06-23 — Bennett-6bu3 (consumer side): StructType {ptr,ptr} aggregate ingest + IRInsertBits pin reconciliation

**Cross-repo 3+1 driven from Bennett.jl** (bead `Bennett-6bu3`); this is the
BennettVM CONSUMER half. Bennett.jl's extractor now supports StructType
`insertvalue`/`extractvalue` (Julia's `{ptr,ptr}` GenericMemoryRef body) via an
additive `field_widths::Vector{Int}` on `IRInsertValue`/`IRExtractValue`
(Option 1 — chosen over a new IR node precisely BECAUSE BVM's slot model already
handles it).

**BVM change is essentially nil — by design.** The insertvalue/extractvalue
ingest (`src/ir/ingest.jl`) decomposes an aggregate into a FAMILY of per-slot
`Define`s keyed by field INDEX (`_agg_<dest>_slotK`), each an Int64 cell —
**index-keyed and width-agnostic**. Because the extractor sets
`n_elems == length(field_widths)`, the existing slot loop + bounds guards handle
`{ptr,ptr}` (two 64-bit cells) UNCHANGED. So `ingest.jl`/`ingest_phi.jl` got
COMMENT-ONLY updates (the stale "StructType fails loud upstream" claim is now
false). This is the payoff of Option 1 over Option 2 (a new `IRExtractBits` would
have needed a brand-new bit-offset→slot ingest arm here).

**Pre-existing drift reconciled.** `test/test_opcode_coverage.jl:171` pinned
`length(filter(isconcretetype, subtypes(Bennett.IRInst))) == 19`, but Bennett.jl
has had **20** concrete subtypes since `Bennett-dv1z` added `IRInsertBits` — so
this testset (0) was **silently RED** (84 pass / 1 FAIL) against the live tree,
unnoticed since dv1z. Bumped the pin 19→20 and added `Bennett.IRInsertBits` to
the canonical list + a `coverage-matrix.md` row marking it **N/A** (it is
synthesised only by Bennett.jl's sret bits-chain and never reaches BVM — sret
aggregate returns are rejected upstream). The pin now moves in lockstep with
Bennett.jl's `test_q04a` (==20).

**New test:** `test/test_6bu3_struct_agg_ingest.jl` (28/28) — hand-built
`{ptr,ptr}`-shaped ParsedIR (`IRInsertValue`/`IRExtractValue` with
`field_widths=[64,64]`) → `lower_vm` → `run!` matches oracle → `unrun!` to EMPTY
history (P0.6) → per-step inverse check; slot-family Defines present.

**Verified.** BVM full `Pkg.test()`: green (test_opcode_coverage now 86/86 at
count 20; test_aggregate_extract_insert 50/50 unchanged). Bennett.jl full suite
also green (689198 pass / 0 fail / 3 broken). The fdict root (Bennett.jl side)
advances past the insertvalue wall to the `ptrtoint ptr %memory_data… (iwo9 /
CW-D3 Lever 1)` GenericMemory data-pointer wall → next is the GenericMemory
recognizer (`Bennett-jfw6` / `bennettvm-m9i`), NOT a standalone iwo9 extension.

## Session — 2026-06-23 — CW-D3 Lever 3: gc_alloc_obj → IntrinsicGCAlloc arena ingest

**Agent:** Opus 4.8 (1M) implementer (Lever-3 half of the gc_alloc_obj capability,
bead `bennettvm-416r.12` gc_alloc_obj PART only). Cross-repo design pre-decided in
`../Bennett.jl/docs/design/Bennett-iwo9-CW-D3-typetag-consensus.md` decision 5. Serial Julia
(Rule 7). Red-green TDD (Rule 5 spec-from-scratch shape).

**What landed.** BennettVM now ingests Bennett.jl's (Lever-2) `IRCall(:obj, :gc_alloc_obj,
[size_op, tag_op], [64,64], 64)` as a deterministic arena bump-allocation, mirroring
`IntrinsicMalloc` verbatim, with the Julia type tag IGNORED (ADR 0021 D3 floor).

- `src/ir/intrinsics.jl`: new `struct IntrinsicGCAlloc <: Instruction` with fields
  `dest`, `nbytes_operand`, `type_tag`. Added to the `_ArenaAlloc` union so it inherits
  `predelta_payload` / `forward` / `inverse` / L3-raise verbatim — ZERO new state-transition
  code. New `_alloc_cells(::IntrinsicGCAlloc, s)` resolves cell count from `nbytes_operand`
  alone.
- `src/history/Injective.jl`: `is_injective(::Type{IntrinsicGCAlloc}) = false` (same shape
  as IntrinsicMalloc — materialises a pointer + opens a region).
- `src/history/delta.jl`: `is_l2_capable(::Type{IntrinsicGCAlloc}) = true` (inherits the
  `(base, cells)` L2 path via the union). VERIFIED (per consensus R6) that BOTH traits
  dispatch per-CONCRETE-type, not on the union — that's why the two one-liners are needed
  even though forward/inverse come free from the union membership.
- `src/ir/ingest_call.jl`: `:gc_alloc_obj` added to `_HEAP_DISPATCH`; new
  `_lower_intrinsic_call` arm (`_need(2)` → size, tag; both via `_lower_operand`).

**The tag-ignored-by-construction guarantee.** The `type_tag` field is STRUCTURALLY UNREAD:
the ONLY methods that touch the field at all are the constructor and the ingest arm that
stores it. `_alloc_cells` / `predelta_payload` / `forward` / `inverse` read only `dest` and
`nbytes_operand`. The tag-invariance test is the soundness witness: the same alloc with tags
0/1/99 (and an SSA-bound tag whose locals value is junk `123456789`) yields a bit-identical
post-forward IState (asserted via BennettVM's `IState` ==/hash override over
pc/locals/memory/arena_top). No JIT type-tag address can reach the VM.

**Red→green.** RED: `UndefVarError: IntrinsicGCAlloc not defined` + the ingest arm absent
(gc_alloc_obj fell through to the `else` memmove `_need(3)` → "expects 3 args, got 2").
GREEN after the four edits: `test/test_gc_alloc_obj_ingest.jl` 23/23.

**Regression.** `test_arena_roundtrip.jl` 54/54, `test_symbol_callee_ingest.jl` 8/8 — no
regression. (Full suite NOT run per instruction — long; targeted files only, one julia at a
time.)

**LOC.** `intrinsics.jl` code-only LOC (excl blank/comment/docstring) ~135 after the add —
comfortably under the ~200 Rule-10 cap; no split needed.

**Scope discipline.** Did ONLY the gc_alloc_obj ingest. The other `416r.12` whitelist parts
(jl_alloc_genericmemory, throw→halt, write_barrier audit) stay OPEN. No Bennett.jl mutation.

---

## Session — 2026-06-15 — CW-D1b landed (closed-world producer) + Case-B path re-confirmed SETTLED

**Agents:** Opus 4.8 (1M) orchestrator, autonomous. 3+1 design pass → Opus implementer
→ +1 + hostile review. Serial Julia (Rule 7).

**Course-correction first (the lead caught it):** mid-D1b I surfaced a closed-world-vs-RevMap
"fork" as if open. It is NOT — the worklog/ADR record settles it: **ADR-0017 (lead, 2026-06-10)
chose CLOSED-WORLD execution OVER RevMap**, knowing RevMap was the easier "tractable floor";
RevMap is demoted to quantum-tier (`o1y`). DO NOT RELITIGATE. Recorded as bd memory
`case-b-closed-world-settled`. The U14/dv1z extractor walls are the **accepted closed-world
runway**, not a pivot trigger.

**Landed: CW-D1b** (`bennettvm-416r.11` chunk b) — `extract_parsed_ir_set_from_julia` in
**Bennett.jl** (`src/extract/julia_set.jl`, commit `06c1ed91`; additive). Drives D1a's
`transitive_callees`, extracts root + helper bodies, keys by drift-free canonical
`<barename>#<digest>` Symbols, and `_closed_world_check!` fails loud on any IRCall escaping
the closed world (the completeness `transitive_callees` defers). `test_d1b` 30 Pass / 1 Broken.

**Ground truth (the blocker, honestly handled):** 0/4 `fdict` callee bodies extract today —
`setindex!`/`rehash!` hit the **U81** ptr-width wall, `ht_keyindex2_shorthash!` the **dv1z**
heterogeneous-sret wall. ADR-0021 confirmed the IR is *recoverable* (`code_llvm`); D1b found
that *lowering it through `extract_parsed_ir`* walls. So D1b ships the producer machinery
proven on a synthetic extractable root, with `fdict` as an HONEST `@test_throws` (`:fail_loud`)
+ `@test_broken` (`:skip ≥4`) tripwire that auto-flips when CW-D2 clears the walls.

**Hardening + hostile-review fixes (pre-commit):** the producer `register_callee!`s live
callees to clear the U15 guard, but was permanently polluting the process-global
`_known_callees` — a real interlock with `test_bd5f_heap_m4` (pins Dict-rejection, runs later
in `runtests`, needs `setindex!` UNregistered). Fixed: SNAPSHOT + SCOPED restore in a `finally`
(race-tolerant — only touches keys this call added; Gate G guards it). Plus S1 (closure-`#`
barename `rsplit`), S3 (Gate E asserts a real wall), N2 (within-process digest determinism).
Hostile review: no BLOCKER; the bd5f interlock independently verified.

**Gates (orchestrator-run, fresh subprocess):** test_d1b 30 Pass/1 Broken; `using Bennett`
clean; Bennett.jl gate-count 39/39. Full `Pkg.test` deferred to the CW-D1 pre-push. **Pin:**
repin still deferred to D1c (BVM doesn't consume the producer yet).

**Follow-ups:** `bennettvm-2k1k` (P3, unify benign-intrinsic const). **Next (the runway to a
real `fdict`):** the extractor extensions — ptr_cells-for-Julia (ADR-0021 D2) + U14 atomic-load
collapse + dv1z heterogeneous-sret — each a core 3+1; then D1c (hand-stitched set ok first) →
CW-D2 whitelist → CW-D3 globals → `7xa`. Full ground-truth in Bennett.jl worklog 082.

---

## Session — 2026-06-14 — CW-D1a landed (transitive_callees walker) + ADR-0021 Decision-1 corrected

**Agents:** Opus 4.8 (1M) orchestrator, foreground, autonomous directive ("keep
working; Opus coders, Sonnet summarization; what would a senior expert demand?").
3+1 design pass (fresh ground-truth → 2 blind Opus proposers → synthesis) → Opus
implementer → +1 + hostile review. Serial Julia (Rule 7).

**Landed:** **CW-D1a** (`bennettvm-416r.11` chunk a) — the `transitive_callees`
typed call-graph walker, in **Bennett.jl** front-end (`src/extract/callgraph.jl`,
commit `0c2a7f87`; additive, Rule-14 crossing under standing approval). Returns the
transitive `:invoke` callee closure (root excluded) toward per-callee body
extraction (D1b) + BVM linkage (D1c). `test_d1a_transitive_callees.jl` 15/15.

**MATERIAL finding (Law 1, the design pass earned its keep):** ADR-0021 Decision 1
said edges come from the "same O0 inference run." **FALSE on Julia 1.12.5** — at
`optimize=false` there are ZERO `:invoke`s; edges materialize only at
`optimize=true`. Walker harvests **edges@optimize=true**, bodies@optimize=false
(D1b). ADR-0021 **Amendment A** records the correction; Gate 5 is a permanent
O0-regression tripwire. Closure for `fdict` = {setindex!, ht_keyindex2_shorthash!
(self-rec), rehash!, AssertionError}; the Case-B length witness IS in `rehash!`
(`jl_alloc_genericmemory_unchecked`, i64 length arg) — the 2026-06-08 blocker
dissolves one level down the callgraph, as ADR predicted.

**Closed-world boundary (hostile-review S1):** walker is `:invoke`-only;
`:foreigncall`/dynamic-`:call`/Builtin intentionally dropped — a typed-callgraph
closure, NOT a complete leaf inventory. Runtime-intrinsic COMPLETENESS is CW-D2's
job, fail-loud at D1b/D2 set-assembly (ADR-0021 Decision 2). Documented as a
contract in `_invoke_callees` so D1b can't silently miss alloc/`_growat!` helpers.

**Gates (orchestrator-run, fresh subprocess):** test_d1a 15/15; `using Bennett`
clean precompile; Bennett.jl gate-count regression 39/39. Full `Pkg.test` deferred
to pre-push (additive + caller-less). **Pin:** repin deferred to D1c (BVM doesn't
consume the walker yet — don't bump the tested-against SHA before testing against
it). Full ground-truth record in Bennett.jl worklog 081.

**Next:** CW-D1b — per-callee O0 extraction + `extract_parsed_ir_set_from_julia` →
`Vector{Pair{Symbol,ParsedIR}}` (mirror the ADR-0020 `extract_parsed_ir_set_from_ll`
producer). D1b risk: `_extract_parsed_ir_cached`'s key is `f::Function`-typed; the
`Type{AssertionError}` constructor callee needs the untyped `extract_parsed_ir` path
or a cache-key widening.

---

## Session — 2026-06-08 — opcode-coverage: acq + b5x/xv0u landed; Case B ground-truth blocker surfaced (lead decision pending)

**Agents:** Opus 4.8 (1M) orchestrator, foreground. Directive: Opus coders, Sonnet
hostile reviewers/scouts, serial Julia (Rule 7), commit/push BOTH repos per unit,
raise beads, "what would a senior expert say", verify-don't-rubber-stamp, cross-repo
explicitly allowed. Suite 6308 → 6450.

### Landed (both pushed)
- **`acq`** (BVM `f77aade`): ingest `IRExtractValue`/`IRInsertValue` (ArrayType
  aggregates) via a per-slot synthetic-name model reusing `Define`-copy (no IState
  change). Hostile review caught a SILENT MISCOMPILE (`insertvalue index≥n_elems`
  silently dropped the value) — closed with lower-time fail-loud guards + tests.
  Aggregate `IRRet` (sret) fails loud (deferred → bead filed). 6308→6376.
- **`b5x`/`xv0u`** (Bennett `31b63a6` + BVM `c7d1016`; repin 231bde6→31b63a6): additive
  `IRPtrOffset.elem_width` so the cell-addressed VM recovers element index =
  `offset_bytes÷(elem_width÷8)` (a hardcoded ÷8 silently miscompiled non-i64 — Rule 2).
  The bead said "1 construction site"; there were **8** (positional ctor → all-or-build-
  breaks). Circuit backend IGNORES `elem_width`, so a wrong UNIT at any site is invisible
  to Bennett.jl's 688k suite — verified bits-not-bytes at all 8 by hand + hostile review.
  6376→6450.

### THE finding (Case B / `tu9`/`7xa`) — lead decision pending
Captured the REAL `code_llvm(fdict, Tuple{Int8,Int8}; optimize=false)` IR
(`test/reference/fdict_O0.ll`, Julia 1.12.5). It REFUTES ADR 0015 / ADR 0016 D8's
route-(b) premise: NO in-body `jl_alloc_genericmemory` (the keys/vals/slots backings are
interned globals `@jl_global#146/#147`, the empty-Dict singleton); the key/value WRITE is
the opaque `@j_setindex!_149` callee (not inlined). So "two GenericMemory backings → two
DynAlloca regions over the store floor" has nothing to anchor on (no alloc, no length
witness), and a pure floor can't reverse the opaque write. Two independent Opus proposers
converged. ADR 0015 now carries a finding banner; HANDOFF + this entry have the 3 options
(A recognize-inlined-getindex→RevMap / B defer+prove-machinery / C Design-G) and my
recommendation (A — the ground truth inverts which route is the tractable correctness
floor). Escalated; lead chose to STOP and hand off.

### Lessons (not derivable from git)
- **Bennett.jl `.git/hooks/pre-push` runs the FULL `Pkg.test` (~65min, --check-bounds=yes)**
  before allowing a push. After manually gating, push with `SKIP_PUSH_TESTS=1 git push`.
  I tripped it 3× (3 concurrent suites — Rule 7 violation); orphaned julia children survive
  a kill of the git-push parent → kill by PID. BennettVM has no such hook. (`bd remember
  bennett-prepush-hook-runs-full-suite`.)
- **A substring `grep` for "genericmemory" gave a FALSE "2 allocs"** — they were
  `; @ genericmemory.jl:NNN` source-location comments. Grep `call.*alloc_genericmemory`
  for real alloc calls. This near-miss is exactly why the proposers re-checked and found
  the blocker; Rule-3 skepticism (verify the scout, verify your own grep) paid off twice
  this session (also: the scout wrongly claimed Case A's Julia-source e2e is unproven —
  `test_vec_vm_roundtrip.jl` proves it, in the green suite).
- The orchestration loop (design-scout → Opus coder → my-own fresh `Pkg.test` gate →
  Sonnet hostile review → fix → commit/push) caught a real silent miscompile in BOTH acq
  and b5x. Worth the cost. Never trust a subagent's test count (false-143 trap).

### Follow-up beads filed
Multi-key aggregate `IRRet` return; split `src/ir/ingest.jl` (~1262 LOC, Rule 10);
Bennett.jl reconcile `IRPtrOffset.offset_bytes` (mem=:heap stores element index, P3);
Case B lead-decision bead (blocks `tu9`/`7xa`).

---

## Session — 2026-06-04 (PM) — opcode-coverage epic: BVM-only front cleared + dynamic-memory keystone (5 beads; 4722→6308)

**Agents:** Opus 4.8 (1M) orchestrator, foreground. Directive: Opus coders, Sonnet
hostile reviewers/scouts, serial Julia (Rule 7), commit/push per bead, raise beads,
"what would a senior expert say", verify-don't-rubber-stamp. Pin unchanged (`231bde6`).
Epic `bennettvm-x49`. Every change: ground-truth read → (design pass where Core) →
Opus coder → Sonnet hostile review w/ per-item signoff → orchestrator verifies the
diff + the soundness-critical parts → full `Pkg.test()` gate → commit + push.

### What landed (5 beads, all committed + pushed; suite 4722 → 6308)
1. **`ftz` — coverage matrix** (`docs/coverage-matrix.md`): 19 IRInst, 15 COVERED /
   3 GAP (IRPtrOffset, IRExtractValue, IRInsertValue — all the shared `else` at
   ingest.jl:370) / 1 N/A (IRSwitch). Corrected stale bead line-numbers (244/346).
2. **`0kl` — clean-fail-loud completeness** (`9a8d2b8`→`16ec63d`): the north-star's
   "fail loud cleanly" half. `_NONDETERMINISTIC_CALLEES` guard in the IRCall arm
   (rand/objectid/time/getpid… → a SPECIFIC "nondeterministic — no replay, doubly
   fatal" error before the generic SoftCall allowlist) + `test_fail_loud_completeness.jl`
   pinning every representable impossible construct to a cause-naming error, and
   honestly documenting atomic/volatile/indirectbr/opaque as upstream-rejected
   (unrepresentable in ParsedIR). Reviewer caught a phantom `:rdrand` (not a Julia
   Function name) → removed.
3. **`h0t` — Float32 ingest-boundary rejection** (`8e2fd67`; ADR 0011 D2). A research
   pass settled reachability: f32 soft ops are UNREACHABLE from accepted Float64
   programs (SoftFloat wrapper → integer-only IR; Bennett bars f32 upstream). Sound
   LOCAL guard: reject a soft op that touches f32 (`ret_width==32 || any(==(32),
   arg_widths)`) — catches soft_fptrunc/fpext, over-rejects nothing (f64→int yields
   ret_width=64 + a separate IRCast :trunc). Witness: SC10 gate lowers to 4 SoftCalls,
   zero f32. Placed at INGEST (test_softcall.jl's direct-construction unit tests
   untouched).
4. **`bgc` — width-aware integer ops** (`526173d`; ADR 0012 R1). The ingest dropped
   IRBinOp/IRICmp `width`, so narrow programs diverged from a native-width oracle on
   overflow. `_apply_binop` gains `width::Int=64`: each op extracts low-`w` bits and
   RE-EXTENDS per the op's OWN signedness (sext for sdiv/srem/ashr/signed-cmp; mask
   for udiv/urem/lshr/unsigned-cmp; low-bits for add/sub/mul/…), masks arithmetic
   results, returns 0/1 for compares. **Key insight: because every op re-extracts,
   the stored representation's high bits never matter** → NO IState/Cast/Select/input-
   binding change. `Define` gains a `width` field (default 64 ⇒ byte-identical no-op;
   ArithmeticAssignment stays width-64 ⇒ injective ops unchanged). Golden-master vs
   native Int8: `f(50)=(3·50)÷2` → 203 (was 75). 3 existing i32 tests' oracles moved
   to the low-32-bit carrier (`& 0xFFFFFFFF`) — branch outcomes verified unchanged
   (the `:sgt` diamond still takes the same arm).
5. **`uil` — runtime bump pointer (Case B KEYSTONE)** (`55bb84e`; ADR 0009). Lifts the
   dynamic-array floor from ONE dynamic alloca to ≥2 (Dict = keys+vals = 2 backings).
   **Offset design** (chosen for zero churn): `IState.heap_top::Int64` (default 0) is a
   running OFFSET; `DynAlloca` base = `instr.base + s.heap_top`; forward `heap_top+=n`,
   inverse `heap_top-=n` (round-trips 0→…→0). Single alloca: `base = instr.base + 0`
   = byte-identical to pre-uil ⇒ NO VMProgram/initial_state change, no churn to ~111
   IState call sites. Ingest now admits dynamic-after-dynamic, still fails loud on
   static-after-dynamic. Two allocas get disjoint offset windows. Reviewer's latent
   n<0 cursor-corruption defect fixed pre-commit (predelta fail-loud).

### Beads filed this session (follow-ups)
- **Bennett.jl** (P3, bug): `extract` f32 `fptosi/fptoui/sitofp` fall through to a
  SILENT `IRCast` (instructions.jl:2344/2367) instead of fail-loud — latent .ll-path
  miscompile. Found in h0t research.
- `bennettvm-kmpg` (P3): document/expose the narrow-width `result()` carrier contract
  (i32 -2 surfaces as 4294967294 post-bgc) + a Select wide-literal note.
- `bennettvm-9v84` (P3): in-loop / back-edge dynamic alloca (offset model makes it
  tractable — remove the forward haskey guard + LIFO retract). Blocked-by uil.
- `bennettvm-s3xr` (P3): static alloca after a dynamic one (mixed layout). Blocked-by uil.

### Load-bearing lessons (not in git)
- **Resolve design forks at the orchestrator, not in a coder prompt.** bgc looked like
  "mask Define results" but a native-Int8 golden-master needs sign-AWARE narrow ops
  (sdiv on a wrapped-negative value) — derived the full LLVM-faithful width/sign model
  + the "re-extract ⇒ stored form doesn't matter" simplification BEFORE delegating, so
  the coder got an unambiguous spec. Same for uil: derived the OFFSET design (`base =
  instr.base + heap_top`) which the scoping agent had left as the absolute-cursor
  design — the offset form eliminated ALL the test churn the scope feared.
- **Ground the spec + establish RED empirically first.** A Sonnet probe compiled
  `f(x::Int8)=(3x)÷2`, dumped the real lowered ops (`:mul`/`:sdiv` width=8), and showed
  the concrete divergence (VM 75 vs native -53) — the failing test bgc had to turn green.
- **The collatz-Int8 overflow test is a trap** — a wrapped Int8 collatz trajectory may
  CYCLE (never reach 1) and hang the oracle; bgc used a straight-line `(3x)÷2` instead.
- **uil offset insight:** an absolute runtime cursor breaks the heap_top round-trip
  (advance ≠ n under a `max`); an OFFSET from the frozen base makes advance == n exactly
  and keeps single-array byte-identical. The disjointness + LIFO-retract was the
  soundness crux the hostile reviewer proved with worked windows.

### What's next — the cross-repo phase (epic x49 continues)
The BVM-only correctness/completeness front is DONE. Remaining epic work is cross-repo
(Bennett.jl recognizers, Rule 14) + each warrants its own design pass:
- **Case A part-2 (`xkl`):** `6db` push!/pop! lowering (build on uil's heap_top; needs a
  push! model design pass — length/capacity/topmost-region) + a Bennett.jl push!/growend!
  recognizer + the e2e gate.
- **Case B (`tu9`/`90l`/`7xa`):** NOW UNBLOCKED by uil. Generalize the mem=:vm Memory
  recognizer to the Dict keys/vals backing (Bennett.jl) + the objectid/identity
  determinism guard (`90l`) + the e2e `fdict` round-trip.
- **`acq`** (aggregate IRExtractValue/IRInsertValue → multi-slot IState) — BVM-only but a
  new state model. **`b5x`** blocked on Bennett `xv0u` (IRPtrOffset elem_width).
  **`4dn`/`01w`** blocked on Bennett soft_fdim/soft_frem/soft_uitofp.

---

## Session — 2026-06-04 — SC9 CASE A LANDED (dynamic Julia Vector e2e) + route-(b) Dict decision + opcode-coverage plan

**Agents:** Opus 4.8 (1M) orchestrator, foreground. User directive: Opus coders,
Sonnet hostile reviewers/scouts, serial Julia, commit/push regularly, raise beads,
"what would a senior expert say". Bennett.jl `src/` write access standing (Rule 14).
Pin bumped `b234496` → `231bde6` (Case A recognizer; see BENNETT_JL_PIN.md).

### What landed (all committed + pushed, both repos)
1. **Route-(b) Dict decision — ADR 0015** (+ ADR 0013 §D-3 amendment banner).
   Lead call: correctness floor first, optimize on top. A `Dict` compiles by
   reversibly EXECUTING its inlined isbits opcodes over the store-level memory
   floor + L3 (route b) — NO in-principle blocker for value-semantic keys (live
   `code_llvm` probe: deterministic hash; no objectid/pointer/rdrand). Route (a)
   recognize→`IRMap*`/`RevMap` DEMOTED to a quantum-circuit-lowering optimization
   (`o1y`, supersedes `9i1`). Recorded in both repos (Bennett-800b + reversible-VM PRD).
2. **Opcode-coverage stocktake + granular plan** — epic `bennettvm-x49`,
   `docs/opcode-coverage-plan.md` (P1–P7 + cross-repo bead map + the
   genuinely-impossible fail-loud set). Full bead reconciliation across both repos:
   created the missing gap beads; fixed a contradictory dep (`zg5` was gated on the
   whole Lean chain `7zl` — decoupled); un-deferred `Bennett-tfx` (soft_frem);
   retitled the stale `Bennett-800b`.
3. **SC9 CASE A LANDED** — a dynamic Julia `Vector{T}(undef,n)`+indexed loop
   round-trips e2e from source under `target=:reversible_vm`. ADR 0016 (2+1 design
   pass vs the real `/tmp/fvec_O0.ll`) → recognizer `Bennett.jl/src/extract/vector_vm*.jl`
   (reuses heap.jl M2/M3 partition) → hostile review → regression caught+fixed →
   `Pkg.test` **4722/4722**. Two BennettVM ingest root-cause fixes (i1 boolean mask
   for the `xor i1 %c,true` NOT-idiom; within-edge SSA-dup φ). Commits `9933d27`,
   `233d193` (+ Bennett.jl `1d574f2`, `231bde6`).

### Load-bearing lessons (not in git)
- **Caught a silent-miscompile blueprint (b5x).** The IRPtrOffset scout proposed
  `offset_bytes ÷ 8` → cell offset. WRONG: the VM is cell-addressed (1 cell/element),
  so for an i32 array `p[2]` (offset_bytes=8) ÷8 gives cell 1 but the element is at
  cell 2, and `8%8==0` so no guard fires. b5x is therefore cross-repo: Bennett.jl
  IRPtrOffset must carry `elem_width` (additive; `Bennett-xv0u`). Same stride trap
  is handled in the Case A recognizer (ADR 0016 D6: recover the index by the
  RECOGNIZED stride, never a constant).
- **A false-green from a stale precompile cache.** A coder's standalone
  `julia test/file.jl` reported 143/143 while the hardening was actually broken; the
  fresh-subprocess `Pkg.test()` exposed it (the new P-callee guard over-rejected the
  dead `ijl_bounds_error_int` throw — the allowlist missed the unmangled runtime
  throw entries). **GATE ON `Pkg.test()`, NEVER a standalone file run.** Also: a
  background `julia … | tail` masks the real exit code — capture to a file with
  `; echo $?`.
- **Case A ships on a SINGLE dynamic array; Case B needs `uil` first** (a `Dict` has
  TWO GenericMemory backings keys+vals; ADR 0016 D8). `tu9` re-wired onto `uil`.

### Open / next (epic x49)
push!-grown Vector (`xkl` + `6db`/`ehp`); FP `soft_frem`→`frem` (`Bennett-tfx`→`01w`);
`b5x` (needs `Bennett-xv0u`); aggregates (`acq`, `dzd`/`Bennett-8e1f`, `Bennett-6bu3`);
Case B (`tu9`/`7xa`) behind `uil`. Low: `bennettvm-2lgo`, `bennettvm-5js9`.

---

## Session — 2026-06-02 — FP/SC10 landed; Case B write-side e2e; Case A plumbing; Bennett.jl repinned

**Agents:** Opus 4.8 (1M) orchestrator, foreground. User directive: Opus coders,
Sonnet hostile reviewers, serial Julia, commit/push regularly, **escalate at
forks / "what would a senior expert say"**. User granted **Bennett.jl `src/`
write access** (Rule 14 satisfied at orchestration level). Bennett.jl repinned
`f73a5ed` → `b234496`. Commits: `b0ee45a` (FP, BennettVM), `b234496` (Bennett.jl
mem=:vm Dict arm), `985f104` (Case B ingest, BennettVM). Suites at close:
Bennett.jl 688504/1-Broken; BennettVM 4497→4558.

### The load-bearing lessons (not derivable from git)

1. **Ground-truth probes beat blueprints — twice.** I sent two read-only
   investigators + Opus coders armed with a file/line "blueprint." Both coders
   came back with the blueprint's *premise falsified by a live `code_llvm`/IR
   probe*. Always probe the actual IR on the live Julia (1.12.5) before trusting
   a recognition plan. The two surprises:
   - **Case A:** `Vector{undef,n}` does NOT lower to a clean `frtN`-shaped
     ParsedIR. Julia 1.12 drags the full `Memory` ABI: `jl_alloc_genericmemory_unchecked`,
     `julia.gc_loaded` data-pointer launder, MemoryRef `{ptr,ptr,size}` chains,
     inexact/bounds throw diamonds, **SIMD-vectorised at -O2**. The `mem=:heap`
     recogniser is hardwired for the opposite (constant-N, loop-free,
     single-block-collapse). The `:vm` Memory recogniser is a *distinct Core
     build* (`M_DYN.7`), not a small interception.
   - **Case B:** the prior "research-grade because `optimize=true` inlines
     `setindex!`" framing (ADR 0008 Finding 1 / Bennett-800b) is **half-wrong on
     1.12.5**. The WRITE `setindex!` survives as a clean callee `@j_setindex!_NNN`
     at *both* opt levels (recognisable). It's the READ `getindex` (`d[k]`) that
     is fully inlined to raw Int8 hash arithmetic + a `Memory` probe loop + a
     KeyError diamond — *no* `@j_getindex` callee for an isbits key (verified the
     IR dump directly; `-O0` doesn't help — inlined at both levels). String keys
     keep `getindex` as a callee, but aren't RevMap-compatible. → answered
     Bennett-800b's own "first research step." The bare-`fdict` is blocked on the
     read, not the write (`9i1`).

2. **A purely-subtractive recogniser is how you avoid silent miscompiles.**
   `dict_vm.jl` drops *only* proven-dead skeleton (forward-taint closure from
   GC/alloc/asm/memset/global-load seeds, reusing `heap.jl` helpers), rewrites
   recognised callees, and **fails loud on everything else** (surviving call,
   non-skeleton branch, computed instr, a `ret` whose operand isn't a recognised
   callee result = the inlined-getindex blocker). Hostile review found no
   silent-miscompile path. This posture is the template for `M_DYN.7`.

3. **Orchestration recovery: a coder hit an API rate-limit on its FINAL report**
   (after ~30 min / 62 tool-uses of real work). The edits were in the working
   tree (coders don't commit). I recovered by verifying the tree directly —
   running the gate (`test_dict_roundtrip.jl` 34/34), reading the recogniser,
   hostile review, full suites — rather than re-running the coder. Lesson: a
   killed subagent ≠ lost work; verify the tree.

4. **Pre-push hooks flake under N-way Julia contention.** Bennett.jl's pre-push
   `Pkg.test()` hook FAILED-FAST during a push while the user's NJOY + PadeTaylor
   suites were also running Julia — yet the same tree had just passed the full
   suite (688504/1) and a clean diagnostic re-run showed no error. Rule 7
   (no-parallel-Julia) is **per-project**; cross-project Julia doesn't violate it
   but DOES cause precompile-cache contention that can flake a hook. Re-push once
   contention clears rather than `SKIP_PUSH_TESTS=1`.

5. **Two milestones now bottleneck on hard frontend recognisers** — escalated to
   the lead (see HANDOFF "The fork"). Case A = hard engineering; Case B read =
   research-grade + an architecture-directive call (LLVM-opcode core vs a
   Julia-frontend typed-IR adapter for Dict ops).

---

## Session — 2026-06-01 — Case B VM-side (RevMap) + opcode coverage + FP ADR

**Agents:** Opus 4.8 (1M) orchestrator, foreground. Per-bead delegation: Opus
coding subagents + Sonnet hostile reviewers. Serial Julia (Rule 7); the one
non-Julia task (the FP ADR) ran concurrently with a Julia test agent — the only
permitted parallelism. (Note: this WORKLOG had drifted — its previous top was
Session 4; Sessions 5–11, incl. the M5–M8 milestones, the collatz keystone, and
the `target=:reversible_vm` dispatch arm + Case A `frtN`, are recorded in git +
HANDOFF.md, not here.)

**Result:** **Suite 3694 → 3942** (clean baseline confirmed at session start).
6 commits pushed. **SC9 Case B VM-side is complete.**

### Bead-by-bead
- **`jrc` — RevMap ADT + IRMap* ops** (commit `3025464`). ADR 0008's child-bead 1.
  `const RevMap = Dict{Int64,Int64}` as a dedicated `IState` field (Finding 3 — it
  MUST live in IState so the round-trip `==`/L3-checkpoint can see it; an external
  map would spuriously pass and corrupt replay). `IRMapInsert`/`IRMapDelete` mirror
  `MemoryStore` (L2 predelta, NamedTuple inverse, the `was_present`/`missing`
  sentinel — hardened so a delete of an absent key round-trips, a senior-grade
  improvement over ADR Finding 4's bare `(key,old_val)`). `IRMapGet` mirrors
  `MemoryLoad` (L3-only, `is_injective=false`); absent-key forward fails loud (a
  Dict get is not zero-init heap). 68 tests, 2 mutation probes RED→GREEN, hostile
  APPROVE-WITH-NITS (loop-body coverage correctly owned by `l49`).
- **M_DICT reconciliation** (commit `d48bd90`). Closed `8i5`/`usf`/`l19`
  (M_DICT.3/.4/.5, written pre-ADR-0008) as superseded: their VM-side ops landed in
  `jrc`; their "intercept the reject in ingest" framing was debunked by ADR 0008
  Finding 2; the ingest recognition is owned solely by `0do`. `usf`'s
  `is_injective(getindex)=true` was factually wrong (ADR 0008 Finding 4 → false).
- **`l49` — hand-built round-trip gate** (commit `b1789a4`). Part A straight-line
  `fdict` (both L2 must_cache + L3 paths); Part B a **genuine back-edge loop CFG**
  (not the documented fallback) proving insert L2 deltas interleave with L3
  control-flow/get checkpoints across iterations, incl. the `{0=>0}` missing-sentinel
  case end-to-end. Hostile review caught that the coder's mutation-proof docstring
  misattributed the RED signal to the aggregate `current==initial` — which STAYS
  GREEN because `unstep!`'s `s.initial` fallback masks a broken per-op inverse (the
  M8.2 blind-spot); `per_step_inverse_check` is the real catch. Docstring corrected.
- **`81y` — ADR 0011, FP inheritance** (commit `6fe925b`). FP = inherited Bennett.jl
  SoftFloat dispatch (UInt64 + `IRCall` to `soft_f*`); resolves PRD §8.1. Honest:
  decision only, `IRCall` is a GAP, wiring is `8ox` (unblocked). Surfaced two PRD
  inaccuracies (`soft_uitofp` absent; 60 exports not ~30) — fold into `278`/`bk9`.
- **`d7t` — executable opcode-coverage matrix** (commit `32b4b7d`). 16 IRInst rows
  asserted vs live `lower_vm`; `testset 0` pins the taxonomy via `subtypes(IRInst)`
  (needs `InteractiveUtils` in the test target — Pkg.test sandbox only sees declared
  deps). No discrepancy vs `docs/coverage-matrix.md`.

### Beads filed / lessons
- Filed **`gqd`** (P3): unvalidated ConditionalEntry predecessor labels — latent
  landmine for future backward-dispatch/pebble.
- Rule 3 paid off repeatedly: a subagent confabulated that ADR 0011 "already
  existed" (it was new/untracked); another found a broken untracked WIP
  `test_opcode_coverage.jl`. Verify subagent claims and untracked files.
- `bd create` flag is `--type`, not `--issue-type` (stale CLAUDE.md example).

### Stopped (user request)
Stopped cleanly after letting two in-flight independent agents (`d7t`, `81y`)
finish rather than stranding their work. The cross-repo "both repos together"
unblocks (`0do` Dict recognition; Case A `mem=:vm` Vector arm) are Rule-14
Bennett.jl `src/` changes awaiting per-diff user approval — NOT started.

---

## Session 4 — 2026-05-26 — M4 closed (history layer L3 complete)

**Agents:** Opus 4.7 orchestrator; per-bead delegation pattern — Opus for
coding passes, Sonnet for hostile review passes. Sequential Julia per
Rule 7.

**Result:** All five M4 sub-beads closed in one session. M4 (history layer
L3: checkpoint-replay) is complete. **Tests: 565 → 990 passing (+425).**
Five atomic commits, each fully provenanced.

### Bead-by-bead

- **M4.1 (`bennettvm-v1t`) — `CheckpointEntry` history entry type.**
  Commit `cbd6644`. New file `src/history/CheckpointEntry.jl`. Immutable
  struct, deep-copy constructor (encapsulates spike Q2.2 lesson at the
  type boundary), explicit `Base.==` and `Base.hash` overrides. 31 new
  tests. Hostile review caught a Q2.1↔Q2.2 citation defect (the
  orchestrator's brief had propagated the same error); fixed pre-commit.
  Memory-isolation test added as a non-blocking observation fix.

- **M4.2 (`bennettvm-n26`) — `step!` pushes CheckpointEntry every K steps.**
  Commit `a325be5`. RState gains `step_count::Int` field (3-arg
  constructor for M4.3's replay arithmetic). `step!` and `run!` gain
  `checkpoint_interval::Int = 64` kwarg. Push fires post-forward,
  post-cross-block, post-halt-detection (the spike Q3 ordering preserved).
  84 new tests. Hostile review caught TWO blocking defects: D1 missing
  `&& step_count > 0` guard (which would have broken M4.3's replay),
  D2 missing sentinel test for the documented mutation-proof claim.
  Both fixed pre-commit; 3 non-blocking observations also addressed.

- **M4.3 (`bennettvm-3do`) — `unstep!` via checkpoint restore + replay.**
  Commit `9f6cda7`. New file `src/history/Replay.jl`. RState gains
  `initial::IState` field (chosen over phantom step-0 anchor to preserve
  PRD invariant `isempty(history)` post-full-reversal). Five-step
  algorithm: precondition → find-nearest ≤ target → restore-with-
  deepcopy → truncate-future-history → replay forward with
  `checkpoint_interval=typemax(Int)`. 103 new tests. Hostile review
  ACCEPT no blocking defects. Filed `bennettvm-kuq` as P2 follow-up
  for an asymmetric dispatch between search and truncation loops
  (`isa CheckpointEntry` vs `_entry_step` polymorphism) — only
  matters when M6/M7 entry types land.

- **M4.4 (`bennettvm-5jb`) — `unrun!` full reversal.**
  Commit `36e2cd3`. Added to `src/history/Replay.jl`. Loop predicate is
  `s.step_count > 0` (Phase-2 design property: the "fully reversed"
  signal moved from history-emptiness to step_count, because L3's
  s.initial fallback means empty-history-but-step_count>0 is reachable).
  Max-iterations guard mirrors `run!`'s pattern. Post-loop structural
  assertion `isempty(s.history) || error(...)` per bead spec. Explicitly
  rejects manual status-reset to `:running` (pinned by a "corrupted
  initial.status" test). 66 new tests. Hostile review CONDITIONALLY
  ACCEPT — 3 cosmetic observations (typo, stale file docstring title,
  missing spike Q3 citation) — all fixed pre-commit.

- **M4.5 (`bennettvm-n2g`) — M4 milestone capstone round-trip test.**
  Commit `61c47cd`. New file `test/test_roundtrip.jl`. Tests-only; no
  production code touched. 10 testsets, 141 new assertions, including
  the load-bearing per-step inverse pattern (spike Q3 lesson:
  after-each-unstep! state must match the forward-captured snapshot at
  that step_count, catching mid-stream corruption the aggregate test
  would mask). K values exercised: {1, 2, 4, 7, 16, 64, typemax(Int)}.
  Test 1 vs golden-master countdown_ref. Test 8 diversifies with a
  single-block program (no cross-block dispatch). M4.1-M4.4 holds up
  on FIRST RUN — no integration bug surfaced.

### Decisions / load-bearing design points

- **`initial::IState` field on RState, NOT phantom step-0 anchor in
  history.** Considered both. The phantom-anchor approach would have
  contaminated `isempty(history)` post-reversal — a PRD invariant the
  spike's `unrun!` already pins. The separate field keeps the structural
  signal clean: unstep! at step_count=1 → fall through to s.initial,
  no special-case handling in unrun!'s loop predicate.

- **Replay during unstep! uses `checkpoint_interval = typemax(Int)`** to
  suppress spurious checkpoint pushes mid-replay. Safe because M4.2's
  `% K == 0 && step_count > 0` guard never fires when K = typemax.

- **K=1 is documented as forensic-test mode, not production.** A K=1
  configuration reproduces the §3.3-prohibited per-step snapshot
  pattern. Documented in `step!`'s docstring and exercised in the M4.5
  K-sweep so the system PROVES it works at K=1 without invoking K=1
  in any production code path.

- **Double-defended deepcopy.** Both ends of the snapshot lifecycle
  deep-copy: M4.1's constructor (push side) and M4.3's restore step
  (pop/read side). A future maintainer who drops one defense still
  has the other. The hostile reviewer verified this via a probe that
  removed the restore-side deepcopy — the per-step inverse test (M4.5
  test 4) turned RED as the mutation-proof matrix predicted.

### Tracker reconciliation at session start

At the top of the session, `bd ready` was lying: M5.1 was surfacing
ready, but the HANDOFF and git log showed M5/M0/M2/M3 all closed in the
prior session (2026-05-26 day-1). 31 stale beads — closed them in a
batch with reasoned reasons before claiming M4.1. The takeaway: closing
beads is not optional at session end; orchestrators must enforce.

### What's next

M4 closes the L3 history strategy. **M6 is up next** — history layer L1
(injective no-log). M6.1 introduces an `is_injective(::Type{<:Instruction})`
trait; injective instructions (SwapInstruction, control-flow markers,
MemoryInterchange/MemorySwap, ArithmeticAssignment when modop=`:xor`)
skip the history push entirely. Then M7 (L2 delta min-cut) gates on
M6. M8 (per-step inverse property test) gates on M7.

After the history layers are complete, the four SC9 motivating cases
(M_DICT, M_DYN, M_NESTED, M_UNBOUNDED — all P0) become the acceptance
gate.

---

## Session 2 — 2026-05-25 — Phase 1 close: PRD v4 authored

**Agents:** Opus 4.7 orchestrator; 4 parallel Sonnet research subagents
(literature survey, Bennett.jl integration boundary, spike retrospective
deep-read, RC3+Janus prior-art) plus 1 Sonnet hostile reviewer. All
research subagents were read-only (no `julia` invocation; CLAUDE.md Rule 7
permits parallel here).

**Result:** PRD v4 ratified. Phase 1 closed. `PHASE.md` flipped to `Phase 2
(production)`. v3 archived at `docs/prd/bennettvm_prd_v3.md` (582 LOC,
frozen). v4 at root `bennettvm_prd.md` (1223 LOC). bd issue
`bennettvm-pb2` closed.

### Timeline

#### 1. Bennett 1973 PDF acquired (the v3 blocker)

User supplied `bennett1973.pdf` from their Windows downloads folder mid-
session. Copied to `references/foundational/bennett-1973-logical-reversibility.pdf`,
SHA256 `e61ad668…0687`. Verified against IBM JRD 17(6) Nov 1973: confirmed
three-stage Compute/Output/Cleanup construction (Table 1, p. 528), 7-stage
input-from-output construction (Table 2, p. 530), `2√(νs)` segmentation
bound and `ν²` log-ν nested-segmentation bound at p. 530 lower right. v4
§2.1 cites these directly. Manifest and PHASE.md updated to mark blocker
resolved. **TIB ILL not required.**

#### 2. Parallel Sonnet research subagents (4 agents, all read-only)

Per CLAUDE.md Rule 7, only Julia-touching agents must be serial; literature
review and codebase reading can parallelize. Dispatched four:

- **A. Literature survey** (`references/`, all 8 §2 subdirectories).
  Verified citation pages by opening PDFs; produced ~2800-word per-pillar
  table; flagged hallucination risks (Bennett 1973 vs 1989, RSSA φ on
  splits AND joins, BobISA jump source-label encoding, Unqomp/Reqomp/Qurts
  design-point differences).
- **B. Bennett.jl boundary** (`../Bennett.jl/` at pin `5731cec`). Mapped
  pipeline: `Julia → code_llvm → ParsedIR → lower() → LoweringResult →
  bennett()`. Identified `ParsedIR` (`Bennett.jl/src/ir_types.jl:347`,
  exported at `Bennett.jl/src/Bennett.jl:88`) as the natural Phase-2
  handoff. Documented three handoff alternatives; recommended Handoff A
  (consume `ParsedIR` externally; no Bennett.jl source mutation needed at
  Phase-2 start).
- **C. Spike retrospective deep-read.** Cross-referenced all Q1–Q9 findings
  + 6 "elevated" findings beyond the retrospective into proposed v4
  normative wording with file:line citations.
- **D. RC3 + Janus implementations.** Mapped RC3's RSSA taxonomy (12
  concrete instruction subclasses in `references/implementations/RC3/.../instances/`),
  TOPPS-janus `Invert.hs` `invertStmt` pattern for injective inversion,
  janus-vesta's `MOV` violation of the memory-as-exchange rule (an explicit
  non-reuse). Produced the §Part IV reuse matrix.

#### 3. PRD v4 written (1191 LOC pre-review)

Structure: §0 executive summary; §1 phase context (what survived from v3,
what v4 changes); §2 prior-art with corrected citations (BobISA →
Thomsen-Axelsen-Glück 2012, RIL → Mogensen 2015 §3); §3 Phase-2 design
spec (17 normative subsections; §3.9–§3.17 are spike-derived); §4 reuse
map with file:line; §5 Phase-1 retrospective summary; §6 8 success
criteria; §7 risks; §8 reduced open questions + ADR queue; §9 milestone
work breakdown M0–M12; appendices.

#### 4. Hostile reviewer pass (Sonnet, per CLAUDE.md Rule 6)

Verdict: REQUEST CHANGES (most severe finding was BLOCKER).

- **2 BLOCKERS:** (1) `IRBasicBlock` and `IRInst` not exported from
  Bennett.jl — `using` example was broken; fixed to qualified access and
  noted Rule-14 constraint. (2) §3.7 missing `IRLoad`/`IRStore` →
  `Exchange` lowering pass; v4 §3.2 mandates memory-as-exchange but §3.7
  silently admitted classical loads/stores via `ParsedIR`. Added
  pre-RSSA normalization-pass requirement.
- **5 MAJORS:** `step!`/`unstep!` signature claim wrong (spike uses
  `(s, prog)`, not `(s, instr)`); two citations to nonexistent
  retrospective §6.x sections (correct path is Q-numbered); wrong
  file:line for uniform-bound analysis (`cfg.jl:81–83` →
  `driver.jl:79–82`); Part VI vs Part IX milestone-numbering mismatch
  + broken `§6.1–§6.8` cross-ref; "15 instruction classes" → "12
  concrete subclasses (22 files)".
- **6 MINORS + 1 NIT:** small citation corrections (Bennett 1973
  resource-bound page, Bennett 1989 Theorem 1 page, Meuli 2019 section
  numbering, `collatz_step` → `collatz_steps`, `LabelTable.java:12` →
  `LabelEntry.java:7` for dual-address, Appendix A.4 missing file paths,
  Bennett.jl boundary §8.2 oversells resolution).

All 14 defects fixed before commit. Final v4 LOC: 1223.

#### 5. Phase transition + close

- `git mv bennettvm_prd.md → docs/prd/bennettvm_prd_v3.md`.
- v4 installed at `bennettvm_prd.md`.
- `PHASE.md` flipped to `Phase 2 (production)` with ratification date.
- `README.md` status table updated.
- This worklog entry.
- bd: `bennettvm-pb2` closed.

### Findings worth recording (will outlive PRD v4)

**Parallel research subagents are massively load-bearing for PRD work.**
Four agents covered ~10,000 words of structured output in ~10 min wall-
time across literature, Bennett.jl, spike, and prior-art implementations.
Serial would have taken ~40 min and the cross-references between domains
would have been weaker (each agent's report assumed cold context, which
sharpened the per-domain summaries). Pattern to repeat for v5.

**Hostile-reviewer subagent caught 14 defects in 1191 LOC.** Two were
BLOCKERS that would have shipped if not caught (`IRBasicBlock` non-export;
missing `IRLoad`/`IRStore` translation pass). The reviewer's per-axis
signoff structure (12 named axes, verdict + evidence per finding, positive
notes section) is the right format — vague "looks ok" reviews are useless;
this format is actionable. Keep the format for Phase-2 reviewer subagents.

**Citation page numbers drift between sub-agents and reality.** Agent A
claimed several page numbers that were close but wrong (Bennett 1989
Theorem 1 location; Meuli 2019 §III-B vs §III). The hostile reviewer
caught all of these. Lesson: page-precise citations need a separate
verification pass; agents won't self-correct.

**Bennett 1973 user-supply path beats TIB ILL.** The user had the PDF on
their personal machine; we burned half a session of Subagent D in pre-
Phase-0 trying to get it through TIB VPN and exhausted 30+ mirrors. For
future hard-to-acquire PDFs, **ask the user first** before launching an
acquisition subagent.

**RC3 is the right pre-read, not just a reference.** The implementations-
survey agent found that RC3's instruction taxonomy is the canonical RSSA
embedding and that Phase 2's IR MUST be structurally isomorphic to it.
This is the strongest Law-2 reuse in v4: not "consult RC3" but "match its
taxonomy, with deviations requiring an ADR." The pre-read criterion is
elevated to M5 (gating M0).

### Decisions for future-me

- **Don't ship Bennett.jl mutations as part of Phase 2 M0.** v4 §3.7
  Handoff A ensures Phase 2 starts with zero Bennett.jl source mutation.
  Handoff B (`target=:reversible_vm` dispatch arm) is deferred to ADR 0003
  with the 3+1 protocol and explicit user approval (CLAUDE.md Rule 14).
- **The Phase-2 first action is the RC3 `rvm` smoke test**, NOT writing
  Phase-2 IR code. v4 §6 SC6 and §9 M5 codify this.
- **The straight-line property test gap (Q9 of the retrospective + §6.5
  of the deep-read report) is now binding for Phase 2** as v4 §3.15:
  random control-flow programs are required, not just straight-line. M7
  exercises this.

---

## Session 1 — 2026-05-23 — Pre-Phase-0 prep + Phase-0 spike + close

**Agents:** Opus 4.7 orchestrator; 11 serial sub-agent passes (Opus for
code, Sonnet for review/summarization, per user directive).

**Result:** Phase 0 complete. Spike at `spike/` with 789/789 tests
passing, `spike-0-archived` git tag, chmod -w. PRD v4 bead filed as
`bennettvm-pb2`. Phase 1 (PRD v4 authoring) is the next session.

### Timeline

#### 1. Greenfield arrival → CLAUDE.md synthesis

- Read `bennettvm_prd.md` (PRD v3, 582 LOC).
- Cross-read CLAUDE.md from `../Bennett.jl`, `../Feynfeld.jl`,
  `../PadeTaylor.jl`, `../cft-anyons`.
- Synthesized BennettVM-specific CLAUDE.md: Three Laws (Ground truth,
  Reuse before reinvention, Phase discipline), 16 numbered Rules,
  Phase-0 gating P0.1–P0.8, hallucination callouts specialized for
  reversible-computing literature, reuse-map enforcement template.

#### 2. Ground-truth acquisition (parallel research subagents)

User directive: "It is nonnegotiable to obtain all ground truth
locally before anything else." Discovered:

- `Bennett.jl/docs/literature/memory/` already had ~13 PDFs (Unqomp,
  Reqomp, Qurts, Meuli, Spooky pebble, Enzyme, …).
- `research-notebook/raw/literature/` had Bennett 1989, Knill 1995,
  RFUN/Thomsen 2012, PRS15, more.
- `playwright-cli` v1.59 installed system-wide; cached Chromium 1217
  at `~/.cache/ms-playwright/`.

Dispatched 3 parallel Sonnet subagents (A: foundational/rr/AD; B:
languages/IR; C: ISAs/quantum-reg-machine + source clones). Then
dispatched Subagent D (paywall pass via headed Chromium + TIB VPN)
after the first three returned. Total: 43 paper PDFs + 5 source
clones (RC3 ✓, TOPPS-janus, jana, janus-vesta, evincarofautumn-janus)
+ Enzyme symlinks. ~126 MB in `references/`.

**Acquisition findings worth recording:**

- Bennett 1973 PDF cannot be obtained via TIB VPN. The IBM JRD
  historical archive (IEEE Xplore volume 5288520) is on a separate
  IBM subscription not included in TIB's IEEE bundle. Recommended:
  TIB ILL via `fernleihe@tib.eu`, DOI 10.1147/rd.176.0525.
- ACM DL papers (Griewank revolve, James-Sabry Π, etc.) are
  inaccessible via playwright-cli even with headed Chromium because
  `page.request` doesn't share Cloudflare clearance cookies with the
  browser context. Known limitation; future subagents should
  skip-fast on `dl.acm.org`.
- `frank-reversible-cmos.pdf` pre-existing in `Bennett.jl/docs/literature/`
  was *misidentified* — it's a 2020 IEEE CMOS paper, NOT Frank 1999
  PhD. Acquired the real 406-page Frank 1999 thesis separately from
  MIT DSpace. Bennett.jl may want a heads-up.

**PRD v3 errata surfaced during acquisition** (logged in
`references/manifest/SOURCES.md §Citation-errata`):

- **BobISA citation correction.** PRD §2.5 cites "Axelsen-Yokoyama
  2011 LATA". Actual paper is **Thomsen-Axelsen-Glück 2012** (RC
  2012, DOI 10.1007/978-3-642-29517-1_3). The 2011 LATA paper by
  Axelsen-Glück is a different artifact (universal reversible TM).
  Confirmed by Mogensen 2022's own reference list.
- **Mogensen RIL ghost.** No standalone RIL paper exists. RIL is
  introduced inside Mogensen 2015 LNCS 9138 §3 ("Garbage Collection
  for Reversible Functional Languages"). The "Mogensen RIL" line in
  PRD v3 §2.3 misled subagent B for ~10 min before they discovered
  this.

#### 3. Bennett 1973 user override

Subagent D's escalation: Bennett 1973 PDF was a strict P0 blocker per
PRD §5.5 ("Ground truth from local PDFs only (Bennett 1973,
Yokoyama-Glück 2007)"). User elected to proceed without it:

> "we have to move on without bennett. flip to phase 0"

This is a Law 1 / PRD §5.5 override. Documented in PHASE.md
"Substitute ground truth" table:

- `references/foundational/vitanyi-time-space-energy.pdf` §2
- `references/foundational/Bennett1989_time_space_tradeoffs.pdf` §1–2
- `references/foundational/buhrman-tromp-vitanyi-2001.pdf` §1

The spike sub-agent prompts (`scripts/spike-templates/0[1-4]-*.md`)
were updated to cite the substitute sources, not the off-disk PDF.
The retrospective Q7 was pre-populated to ask whether the
substitution actually hurt.

The substitute sources turned out to be entirely sufficient for
Phase 0 Stage 1 (forward + reverse). Bennett 1989 §1 Lemma 1
restates the 1973 three-tape construction with explicit per-step
quintuple-index history entries — *cleaner* than the 1973 original
is reputed to be. Bennett 1989 also splits the construction into
three stages (Compute / Output / Cleanup), of which Phase 0
implements only Stage 1.

**Per the Phase-0 close retrospective:** Phase 2 Stage 2 and Stage 3
(Output channel, Cleanup) WILL need the Bennett 1973 original. TIB
ILL should be pursued before Phase-2 design begins.

#### 4. Phase-0 spike — 11 serial sub-agent passes

User directive: "orchestrate this serially: delegate each coding
step to an opus subagent, research and summarisation to sonnet. no
more than one subagent at a time. you monitor progress and raise
beads as issues arise."

Beads epic: `bennettvm-ua7`. Sub-issues `ua7.1` through `ua7.11`.

| # | Pass | Agent | Outcome |
|---|---|---|---|
| 1 | interpreter | Opus | written |
| 1R | review | Sonnet | REQUEST CHANGES (4 findings: exception-safety, missing `@assert`, Q2.3 docstring inaccuracy, missing `private=true`) |
| 1F | revise | Opus | 4 fixes (~14 LOC) |
| 1R2 | re-review | Sonnet | ACCEPT, raised Q2.4 docstring as new finding |
| 1F2 | mechanical | Opus | Q2.4 docstring rewritten |
| 2 | 8 instructions | Opus | written, smoke test passes |
| 2R | review | Sonnet | ACCEPT, flagged Q4 history-length convention complexity for Pass 3 |
| 3 | tests | Opus | 789 tests, mutation-proof exposed real weakness, added per-step inverse test |
| 3R | review | Sonnet | ACCEPT, mutation-proof reproduced (19 RED on perturbation, 0 after revert) |
| 3F | mechanical | Opus | 2 doc errors fixed |
| close | retrospective | Sonnet | `spike/RETROSPECTIVE.md` written, Q6 cross-check done |

#### 5. Findings worth recording (will outlive the spike)

**The Julia `==` footgun (Q2.1).** Default `Base.==` on a struct with
a `Dict` field does identity-compare on the `Dict`. Two `IState`
values with equal content but distinct `Dict` objects fail `==`.
Without overriding `Base.==` on `IState`, the entire round-trip
invariant silently never holds. This is the #1 finding from the
spike and should be a CLAUDE.md rule or a Julia-pattern memory.

**Exception-safety in `step!`.** Pass-1 originally pushed the
history snapshot BEFORE calling `forward()`. If `forward` threw,
the snapshot was orphaned and the VM was inconsistent. Reorder
(call `forward` first, push only on success) fixes it cleanly.
The Pass-1F reorder is the right pattern for any trace VM.

**The per-step inverse test (Pass 3).** Pass-3's brief-prescribed
mutation (swap `prev` for `s` in `inverse(::BinaryOp, ...)`) did NOT
initially break the aggregate round-trip test, because the LEADING
`Const` inverse restores `s.current` regardless of corruption left
by mid-stream inverses. Mutation-proof failed quietly. Solution:
snapshot every pre-step `IState` during forward execution; then
during `unrun!`, assert `s.current == pre_states[i]` at each step.
This catches per-instruction-kind inverse bugs because the mutated
inverse leaves `s.current` at the post-step state, which is detected
before any later inverse can mask it. **Phase 2 must keep this
pattern.**

**Return/Halt collapse (RETRO Q1).** PRD §5.1 lists `Return` and
`Halt` as distinct opcodes, but the spike has no subroutines, so
they degenerate to identical implementations. Both are kept per P0.4
(no ninth instruction, but also no opcode removal). PRD v4 must
decide: keep both (for forward compat with subroutines), unify, or
reuse the slot.

**`UnaryOp :not` ambiguity (RETRO Q3).** PRD §5.1 wording "Bool-typed
regs" is moot when locals are `Dict{Symbol,Int64}` (no Bool type).
The spike's `:not` is bitwise `~` on Int64 (so `:not 1 = -2`). Not
boolean negation. PRD v4 must either widen the local-value type to
include Bool or rename the op (e.g., `:bnot`).

**History-length convention (Q4).** With discard-pop on idempotent
terminal transitions, `length(history) == steps_with_observable_effect`,
which for countdown(3) is 19 (not 20 — the Halt step is popped).
Test 3 (history invariant) uses convention (c): step-by-step counting,
`length(history) == n_calls` for non-terminal steps, `n_calls - 1`
after terminal. The top-of-file comment in `test_history.jl` is the
most detailed documentation of this design choice in the spike.

**Q6 cross-check (Law 2 evidence):** none of RC3, TOPPS-janus, jana,
janus-vesta, or evincarofautumn-janus has a history-tape +
round-trip property test in the BennettVM sense. RC3 has an `rvm`
(RSSA VM) but compiler-level reversal, not runtime trace.
TOPPS-janus does syntactic `invertStmt` (the Yokoyama-Glück 2007
"no history for reversible source" structural lesson). Therefore
BennettVM IS distinct work, not a rebuild. Phase 2 must continue to
justify each design decision against published prior art per Law 2
but is not displaced by any existing artifact.

#### 6. Phase-0 close

- `spike/RETROSPECTIVE.md` written (264 LOC, 9 questions answered).
- `chmod -R -w spike/` (filesystem read-only marker).
- `git tag spike-0-archived`.
- `PHASE.md` flipped to "Phase 1 (archive; PRD v4 pending)" with 8
  numbered sharpest items for v4.
- `bennettvm-pb2` filed (PRD v4 epic).
- Three commits:
  - `0c7425d` bd init.
  - `5c611c4` Phase-0 spike complete: 789/789 tests, retrospective.
  - `bcc49c5` Phase 0 → Phase 1 transition.

### Decisions for future-me

- **Don't promote spike code into Phase 2.** PRD §1.4 / §7.8 / CLAUDE.md
  P0.7 — Phase 2 starts from an empty `src/`+`test/`. The spike's
  type names and API shapes are *patterns* to consult, not source to
  fork.
- **The 3+1 reviewer pattern from Bennett.jl was overkill for Phase
  0** but produced load-bearing findings (Pass 1R's 4 findings, Pass
  3R's mutation-proof reproduction). Keep it for Phase 2. The
  overhead is worth the structural integrity.
- **PRD v3 was wrong in ~5 places** that we caught (BobISA citation,
  RIL ghost, RState mutability, :not Bool wording, Return/Halt
  semantics). Expect more in Phase 2; budget time to log them.

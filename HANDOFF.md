# HANDOFF — BennettVM.jl

> What the next session needs to know. Read top to bottom; do not skim.

## 📌 SESSION CLOSE 2026-08-03/04 (orchestrator) — where to pick up

**Two beads landed cross-repo this session** (WORKLOG top two entries +
Bennett.jl worklog/097), both with ZERO BVM src changes:

1. **Bennett-40ys** — instance-less closure/functor callees extract from their
   TYPE alone (the capability class every `push!`-based program needs).
   `test_40ys_closure_callee_vm.jl` (183): 1- and 2-field functor callees run
   + reverse exactly on the VM (L2/L3, per-step inverse).
2. **Bennett-7wsz** — ptr-typed sret struct fields admitted as 64-bit cells
   under `ptr_cells=true` (`{ptr,ptr}` MemoryRef returns). Split-roots ABI
   modeled VERBATIM (i64 -1 sentinel; NEVER fuse return_roots into the
   aggregate — silent pointer miscompile; anti-fusion tests pin it).
   `test_7wsz_ptr_sret_vm.jl` (160) incl. a hand-built split-roots `.ll` pair
   round-tripping on the VM. BVM full suite **9791/9791** (orchestrator-run).

**The xkl (P0) frontier is now the closure-body wall chain** (clear
wall-by-wall, xrd6→u2kk→8g7m style). FOUR walls cleared this session
(40ys closure callees → 7wsz ptr sret fields → 3vf2 dead-use global-load
drop → vau9 memmove routing):
- NEXT (Bennett.jl side): **`Bennett-jbko` (wall 5)** — `ptrtoint` of a
  MemoryRef data pointer feeding an `icmp eq` concurrent-mutation guard in
  `_growend!` L84; matches neither the iwo9 type-tag nor 583s memdata arms.
  Needs a new equality-comparison arm with an explicit determinism argument
  (klgz discipline). CORE 3+1.
- NEXT (BVM side): **`bennettvm-rxgy` (wall 6, the arc's FIRST BVM src
  change)** — `IntrinsicMemmoveBytes`, byte-exact sibling of
  IntrinsicMemsetBytes, for Julia-tier byte-granular programs
  (`_enforce_julia_heap_tier!` currently rejects cell-granular
  IntrinsicMemmove there, loudly). NOTE: comments citing "bennettvm-9n3y"
  for this gap are a DANGLING ID (neither tracker); rxgy is real; sweep bead
  filed.
- After jbko: the L93 success path is an 8-byte sret-reassembly memcpy,
  plausibly already supported post-7wsz — runway to full `_growend!`
  extraction is plausibly short but unverified.
- The push! ROOT separately walls at the pgcstack inline-asm read
  (Bennett-5oyt/U15) — a DIFFERENT axis from the closure chain. Wall
  forecasts made with ungated monkey-patches (or non-pipeline IR dumps — the
  3vf2 addrspacecast artifact) are unreliable; measure gated on the real
  extraction path.

Watch-outs carried forward: `bennettvm-m9i` bead text is STALE (pre-ADR-0017
recognizer framing — the closed-world route owns xkl now; re-scope or close it
when xkl lands). `:skip` on a walled ROOT silently returns a rootless set
(Bennett-9tg3, pinned known-gap). 1-field functors pass width checks by
coincidence — 2-field fixture is the tripwire (Bennett-ce9t). Wall-marker
occursin pins use bare numerals (Bennett-0ncn). No clang on this box (suite
undercounts ~2000, `bennettvm-5o86`). One Julia process at a time; gate on a
`Pkg.test()` you run yourself.

## 📌 SESSION CLOSE 2026-07-30 (orchestrator) — where to pick up

Three beads landed this session, gated and pushed: `bennettvm-0fw7`
(BVM `0c6b1e4`, full suite 8299/8299), `bennettvm-p3j2` (BVM `87dc572`,
8299/8299 — includes the FIXUP for `test_0fw7_dup_call_args.jl`, which
`0c6b1e4` registered in runtests.jl but never staged), and `Bennett-tl1l`
(both repos; BVM full suite 9448/9448 with the new
`test_tl1l_a70z_shapes.jl`). **Gate caveat for tl1l's Bennett.jl half:** the
Bennett.jl full `Pkg.test` was CUT SHORT at the user's request (~20 min in,
all green to that point); the change there is test-only
(`test_a70z_overflow_const_bit.jl` 206→348) and is per-file green under
`--check-bounds=yes` in two independent runs (implementer + hostile
reviewer). First agent to run the full Bennett.jl suite: treat any failure
in that file as unverified-tail risk from this session. Orchestration
shape: Opus diagnosis/implementation, Sonnet hostile review (caught 1
MAJOR: the missing uadd bit=1 both-constant fixture), strictly serial Julia.

**Next-frontier ranking (orchestrator's read, not binding):**
1. **`bennettvm-axfr`** (P2, Core) — the SSA-dominance validator, now MORE
   load-bearing: it is the named successor of both relaxed/retained guards
   (ADR 0023 + p3j2 Amendment) and should also assert the
   `_agg_`/`_callconst_`/`_phi_` synthetic-namespace invariant (bead notes).
   Core ⇒ design pass + hostile review.
2. **`bennettvm-m9i`** (P1) — M_DYN.7 Memory recognizer, the long-standing
   linchpin for the P0 `xkl` (push!-built Vector) chain.
3. **`bennettvm-xl1q` / `Bennett-ms0o` / `Bennett-qt6o`** (P3) — stale `.ll`
   fixtures + the undef-aggregate return wall blocking from-source
   checked-arithmetic fixtures (tl1l residual; tripwired in
   `test_tl1l_a70z_shapes.jl` testset (0)).

Watch-outs carried forward: no clang on this box (suite undercounts ~2000
assertions, `bennettvm-5o86`); `__vN` names are frame-ambiguous in
multi-body runs; one Julia process at a time; gate on a `Pkg.test()` you
run yourself.

## ✅ SESSION 2026-07-30 — `bennettvm-0fw7` FIXED: duplicate `CallEnter` args are legal; for-LOOP Dict inserts run

`bennettvm-0fw7` is **CLOSED**. A `for`-loop multi-insert `Dict` died at
LOWERING on `CallEnter: duplicate arg names`. **The cause was not the loop.**
`d[i] = i` lowers to `setindex!(d, i, i)` — LLVM CSEs the key and the value
onto ONE SSA name — so a single call legally passes one value in two argument
positions; a straight-line `f(x) = g(x, x)` trips it identically, and a loop
body `d[i] = v` (two names) does not. The `allunique(args)` guard stated the
pre-Amendment-A MOVE of ADR 0019 §3 ("cannot be moved into a callee twice"),
but **A.1 had already replaced that MOVE with a COPY**: `_handle_call_dispatch!`
only READS the caller's args and zips them onto distinct `FunctionEntry.params`.
The guard was self-inconsistent besides — duplicate CONSTANT args already
passed, via ingest's per-position `_callconst_*` renaming. **Fix: remove the
guard** (and the identical one on the superseded `CallInstruction` stub, in
lockstep). New **ADR 0023**; ADR 0019 carries an amendment banner pointing at
it. Same relax-don't-duplicate adjudication as ADR 0022 at the φ-edge — the
fourth time an ISA rule imported from a reversible-BY-CONSTRUCTION source
language failed to survive contact with irreversible-source LLVM IR.

### State of the world

- **`for i in 1:14; d[i] = i; end` Dicts run and reverse**, at `Int8` AND
  `Int64`: extract → `lower_vm` → run to the native-oracle value → `unrun!` to
  empty history + exact initial state, under L2 and L3, including the `rehash!`
  GROW path. Regression test `test/test_0fw7_dup_call_args.jl` (225
  assertions), written RED against unmodified `src/` first.
- **Guard family audited, not blanket-relaxed.** Surviving and pinned by §(4):
  `allunique(targets)`, the `t in args` overlap check, both callee-shadow
  checks, and the run-time §6a/§6b/§6f checks. The block-exit `allunique(args)`
  in `control_instructions.jl` is a DIFFERENT list and is untouched (ingest
  dedups it upstream); both sites now carry a cross-ref saying so.
- **Two neighbour test files dead-lettered, not deleted**:
  `test_call_roundtrip.jl` (e') and `test_call_instruction.jl` asserted the old
  rejection; both now pin the NEW behaviour with the rationale inline (the same
  pattern as (c') / ADR 0019 A.2).
- **Gate:** new file + `test_rnhv_phi_multiuse.jl` (251) +
  `test_a70z_dict64_roundtrip.jl` (347) + `test_call_instruction.jl` /
  `test_call_roundtrip.jl` (162 together) all green individually. Full
  `Pkg.test()` is the orchestrator's gate.

### `bennettvm-p3j2` — same session, OPPOSITE verdict (F2: keep behaviour, fix rationale)

The sibling guard (`t in args`) was diagnosed straight after 0fw7 and
**downgraded P2 → P3**. Its rationale was stale in exactly the same way
("cannot be simultaneously moved-out and landed-into" — false under A.1 COPY +
A.2 `target_olds`; the overlap empirically round-trips). But the follow-up's
premise, "`x = g(x)` is routine at `-O0`", was **WRONG**: routine at *source*
level, never in IR — SSA renames every dest, and the verifier's dominance rule
forbids a call being its own operand. Measured: **135/135 raw call sites and
105/105 extracted `IRCall`s** across the C / Rust / Julia corpora have
`dest ∉ operands`; sret synthesis and the `_agg_*` / `_callconst_*` namespaces
preserve it by construction. Relaxing therefore buys **zero capability** while
giving up a check with a measured zero false-positive rate. **F2 landed:
behaviour unchanged; rationale rewritten** in `CallEnter`, in the mirrored
`CallInstruction` stub, in the §(4) test comments, and in a new ADR 0023
Amendment section. Beads filed: `bennettvm-xl1q`; `Bennett-ms0o` (stale `.ll`
fixtures, upstream); `bennettvm-axfr` annotated with the `_agg_*` fresh-name
invariant. Docs/comments only — the only executable lines touched are two
`error()` string literals.

**The transferable rule: a guard whose rationale is obsolete is not
automatically a guard whose behaviour is wrong.** 0fw7's blocked reachable
programs and had to go; p3j2's blocks nothing and stays. Fix the sentence.

### `Bennett-tl1l` — same session, TEST-ONLY: the two a70z shapes the Dict corpus never emits

Upstream `Bennett-a70z` left three argued-not-proven residuals; the downstream
two are now closed by **`test/test_tl1l_a70z_shapes.jl`** (1149 assertions,
~20 s, registered right after `test_a70z_dict64_roundtrip.jl`). No `src/`
change, no defect found.

**The finding worth carrying forward:** `_fuse_overflow_extractvalue`
(`../Bennett.jl/src/extract/instructions.jl:2523`) has **three** emission
shapes, and `test_a70z_dict64_roundtrip.jl` only reaches ONE of them —

* **TWO-SIDED** (2 `IRICmp` + width-1 `IRBinOp(:or)`) — the only shape the real
  `Dict{Int64,Int64}` corpus emits, because `rehash!`'s `smul(%value_phi, 8)`
  is a *signed mul* and signed mul is the only generically two-sided arm;
* **ONE-SIDED** (a SINGLE `IRICmp` carrying the extractvalue's own dest, no
  `:or`, zero `__vN` churn) — the **MAJORITY** shape in general: every unsigned
  op drops the low arm (`L = 0` is the unsigned floor) and every `sadd`/`uadd`
  drops exactly one arm;
* **BOTH-CONSTANT** (`IRBinOp(:o,:add,bit,0,1)`, no `IRICmp` at all).

**Both plain-Julia source routes to the latter two are CLOSED today** (probed
2026-07-30; pinned as tripwires in the new file's testset (0)):

1. `Base.Checked.add_with_overflow` / `checked_add` does NOT extract — it dies
   on the **`Bennett-bjdg` / U80** `{iN,i8} undef` wall, because Julia builds
   the `Tuple{T,Bool}` RETURN by `insertvalue` into an undef aggregate. That
   wall is upstream of the overflow bit entirely, which is why the Dict corpus
   (intrinsic consumed in-body) never meets it. Reproduced at i16/i32/i64,
   add and mul, signed and unsigned.
2. A both-constant call is folded away by **Julia's own inference** — the
   extracted body has ZERO instructions.

So the fixtures are hand-written `.ll` driven through the REAL front-end
(`Bennett.extract_parsed_ir_from_ll` → `_fuse_overflow_extractvalue`) and then
`lower_vm` → `run!` → `unrun!` — deliberately NOT hand-built `ParsedIR`, so the
shape under test is whatever `instructions.jl` emits today. Widths 64/32/16,
shape pinned at BOTH the `ParsedIR` and the `Define` level, values vs the native
`Base.Checked` oracle under L2 and L3, per-step inverse.

**Hostile review caught one MAJOR here, worth internalising:** the first cut had
`uadd` in the both-constant table at **bit 0 only**. The `bit == 0` emission is
byte-identical to the pre-existing lbot fold-to-zero shape, so an arm present at
bit 0 alone would pass unchanged **even if `_ovf_const_bit` were deleted** — it
was coverage in name only. All four arms now carry a `bit == 1` fixture (added
`uadd i16 65534+3` and `uadd i64 (2^64-1)+1`), and the coverage rule itself is
asserted in the testset so a future edit that drops an arm fails loudly. The
expected bit is also no longer a hand-computed literal: `_tl1l_cbit` recomputes
it from the fixture's own `.ll` constants through `Base.Checked` at the
fixture's native width and signedness, cross-checked against the table's stated
intent. **General rule: when two code paths emit the SAME bytes for one value of
a flag, only the other value is a test.**

**Two BVM facts this surfaced, useful beyond a70z:**

* `result(rs)` returns the **whole** halted frame's locals, not just the
  declared returns — so a derived flag like the a70z bit can be asserted
  directly, and a fixture that returns from both arms of a `br i1` needs no
  return-symbol disambiguation.
* At `W < 64`, `_apply_binop` masks results to the low `W` bits (ADR 0012 R1 /
  `bennettvm-bgc`), so an i32 `x + 5` reads back as a **non-negative** `Int64`
  in `[0, 2^32)`, not a sign-extended `Int32`. Any test asserting narrow-width
  arithmetic must write its oracle in that convention
  (`reinterpret(UInt32, ·)`); the new file says so in its honest boundary.

Upstream half (Bennett.jl, test-only): `test_a70z_overflow_const_bit.jl`
206 → 348 assertions — N=16 curated-constant × all-65536-input sweeps, N=32
boundary + seeded-random sweeps, and full-extraction-path i16/i32 shape pins.

### NEXT — pick one

1. **`bennettvm-axfr` (P2, Core)** — the deferred SSA-dominance validator
   (`validate(::VMProgram)`, M2.18). It is the proportionate replacement for
   the construction-time strictness both 0022 and 0023 gave up, and p3j2 just
   handed it a corpus-measured invariant to assume.
2. **`bennettvm-guyl` (P3)** — one arg NAME can now carry TWO widths at one
   call site (`[64, 8, 8]` in the i8 loop-Dict fixture). Benign today (no VM
   width masking exists); a future masking pass must key on POSITION, not name.
3. **`bennettvm-xl1q` / `Bennett-ms0o`** — filed out of the p3j2 corpus sweep
   (the latter is upstream: stale `.ll` fixtures).

### Watch out for (carried from this session)

- **`structural_inverse(::CallInstruction)` swaps `targets` ↔ `args`**, so a
  dup-arg instance inverts to a dup-TARGET one and is (correctly) rejected. A
  dup-arg call is constructible but not structurally invertible in that class.
  Dead path today; noted in the docstring so a revival does not do a naive list
  swap. **Do not generalise that asymmetry**: for the *overlap* case the same
  swap maps overlap → overlap, so the guard fires identically in both
  directions (ADR 0023 §Amendment).
- **A guard that states a model must be deleted WITH the model.** A.1 changed
  the transfer and the docstrings but not the constructor, and six weeks later
  the constructor was still teaching readers the MOVE. When superseding a
  design, grep for the *rationale text*, not only the code.

## ✅ SESSION 2026-07-24 (part 2) — `bennettvm-rnhv` FIXED: φ-edge is a non-destructive BIND; Dict GROWTH runs

**This is the newer half of 2026-07-24. Part 1 (a70z) is the section below it.**

`bennettvm-rnhv` is **CLOSED** (commit `c8ff59f`). A 14-insert `Dict` died at VM
RUN with `KeyError` because the φ-edge args→params transfer
(`_rename_args_to_params!` in `src/interpreter/Interpreter.jl`) **destructively
deleted** the sender's edge args — Mogensen RSSA note 2 — but LLVM-derived
φ-incomings legally have uses that outlive the edge, so `rehash!`'s grow loop
orphaned a live SSA. **Fix: remove the `delete!`, making the transfer a
non-destructive BIND** (`_bind_args_to_params!`). This is the exact MOVE→COPY
decision **ADR 0019 A.1** already ratified at the `CallEnter` boundary; we were
inconsistent, not undecided. New **ADR 0022**.

### State of the world

- **Dict GROWTH runs and reverses.** 14-insert `Dict{Int8,Int8}` AND
  `Dict{Int64,Int64}` (straight-line inserts): extract → `lower_vm` → run to
  the native-oracle result → `unrun!` to empty history under L2 and L3.
  Regression test `test/test_rnhv_phi_multiuse.jl`.
- **The bug was LATENT** — the same 32 static hazards sit in the 1-insert Dicts
  the suite already asserted green; 14 inserts only made the grow branch
  reachable. A green suite did NOT prove this fix unnecessary. The test guards
  the invariant with a trajectory-independent static hazard scan on the cheap
  1-insert fixture, not only the 14-insert e2e.
- **Gate: full `Pkg.test` 8071/8071** (was 7820 + 251 new). Trajectory
  step/checkpoint counts byte-identical on collatz/matrix_sum/matrix_tri (only
  the bounded residual-locals count grew — a dead arg lingers until its frame
  pops). Hostile reviewer ACCEPT: hand-built adversarial live-param-overwrite
  VMPrograms all round-trip under L2+L3, because reversal is checkpoint+replay
  (an injective exit suppresses only the per-step log, never invertibility).
- **`bennettvm-35yn` also CLOSED** (shipped alongside): the bare `KeyError` from
  `_resolve` is now a context-bearing error naming the SSA, instruction, pc and
  frame stack (`src/ir/unbound_ssa.jl`) — mitigates the one real risk of the
  relaxation (a malformed lowering reading stale instead of crashing).

### NEXT — pick one

1. **`bennettvm-0fw7` (P2)** — a `for`-LOOP multi-insert Dict dies EARLIER, at
   *lowering*, on `CallEnter: duplicate arg names` (the `allunique(args)` guard,
   `call_transitions.jl:108`). Separate pre-existing wall, NOT touched by rnhv.
   This is the loop analogue of ADR 0019 A.2 on the *arg* side, and it is the
   next Dict-growth wall if loop-lowered inserts are in scope. Diagnosis-first.
2. **`bennettvm-axfr` (P2, Core)** — the deferred SSA-**dominance validator**
   (`validate(::VMProgram)`, M2.18): make an unbound-operand read a build-time
   error. ADR 0022 defers it with a Rule-9 forcing condition; it is the proper
   permanent fix for the stale-read risk and is now EXPRESSIBLE (it was
   unsatisfiable under the old destructive semantics).
3. **Still open from part 1: `Bennett-tl1l` (P3, Bennett.jl)** — a70z's
   one-sided + both-constant emission shapes unproven downstream; widths 16/32
   unswept.

### Watch out for (carried from this session)

- **`__vN` SSA names COLLIDE across bodies in a multi-body closed-world run.**
  Name-only inspection of a running trajectory is frame-ambiguous (a probe read
  a *different frame's* heap pointer). Resolve `_instruction_at(prog, pc)` and
  read frame-exactly. This is what let the rnhv diagnosis correctly rule out a
  cross-frame collision and localise a genuine live-then-deleted SSA.
- **No clang on this box** → the suite reports ~2000 fewer assertions than the
  pinned-machine number (clang-gated e2e self-skips). Tracked `bennettvm-5o86`.

## ✅ SESSION 2026-07-24 (part 1) — a70z LANDED AND VERIFIED BOTH SIDES; `Dict{Int64,Int64}` RUNS ON THE VM

**Supersedes the "impl parked UNVERIFIED on `wip/a70z-overflow-bit`" note in the
2026-07-21 section below — that is now STALE.** The parked WIP (`1f521d3d`) had
never been observed green; it was re-verified from scratch, three defects were
fixed, and it landed on Bennett.jl `main` (rebased to `6953ceb`/`d4b4fa1`; main
now `e15ea23`). `origin/wip/a70z-overflow-bit` still exists but is the
SUPERSEDED pre-rebase copy — its content is in `main`. Don't work from it.

### State of the world

- **`Bennett-a70z` is CLOSED and overshot its exit criterion.** It asked to clear
  the `smul`-elsize-8 wall and *document the next wall*. **There is no next
  extraction wall** — the whole `Dict{Int64,Int64}` closed-world set extracts
  clean (4 bodies: `fdict64`, `setindex!`, `rehash!`, `ht_keyindex2_shorthash!`).
- **`Dict{Int64,Int64}` RUNS AND REVERSES ON THE VM, with ZERO BVM source
  changes.** Extract → `lower_vm` (552-block `VMProgram`) → 664 steps to
  `fdict64(3,7) == 7` → `unrun!` to the exact initial state with empty history,
  under **both** L2 and L3. Regression test
  `test/test_a70z_dict64_roundtrip.jl` (347 assertions, mutation-proved,
  registered at `runtests.jl:681`). Commit `571c54b`.
- **Mechanism** (front-end, for context): when exactly one operand of
  `llvm.{s,u}{mul,add}.with.overflow.iN` is a compile-time `ConstantInt`, the
  overflow bit is now COMPUTED as a constant-folded admissible-interval test
  `bit = (x<L)|(x>U)` — up to 2 `IRICmp` + 1 width-1 `IRBinOp(:or)`. **BVM
  ingests these as ordinary `Define`s; nothing new was needed on this side.**
- **Gates:** Bennett.jl full `Pkg.test` **690398 Pass / 3 Broken** (all
  pre-existing), 28m37s, heavy tests ON. BVM full `Pkg.test` **7820/7820**.
  Pin revalidated (`BENNETT_JL_PIN.md`, 2026-07-24).

### Two things that will bite the next agent

1. **`__vN` SSA names COLLIDE across bodies in a multi-body closed-world run.**
   Reading a value by SSA name from a running closed-world trajectory is
   FRAME-AMBIGUOUS. A probe for the fuse bit `__v152` returned `1099511628136`
   = `ARENA_BASE (2^40) + 360` — a heap pointer belonging to a *different
   frame's* identically-named value. Resolve `_instruction_at(prog, pc)` and
   read frame-exactly instead.
2. **This box has NO clang**, so the clang-gated e2e blocks self-skip and the
   suite reports **7820** where the other box reported **9848**. A "full suite
   green" here is ~20 % weaker and announces that only via two easily-missed
   `@info` lines. Filed as **`bennettvm-5o86`** (install clang, and/or make the
   suite print a loud end-of-run skipped-block banner).

### NEXT — the frontier is `bennettvm-rnhv` (P1, Dict GROWTH)

**Scope was corrected this session:** `rnhv` did NOT arrive early at i64, and it
is NOT the same axis as a70z. **a70z is the element-SIZE axis (elsize 8 vs 1);
`rnhv` is the element-COUNT axis (≥14 inserts → the rehash-grow copy loop).**
They are orthogonal. Since single-insert `Dict{Int64,Int64}` now runs end-to-end,
`rnhv` should be re-probed at **both** widths, not just the Int8 shape it was
originally hit at. Original symptom to reproduce: 14 inserts → `KeyError:
:__v96` undefined SSA at VM run.

Also opened this session: **`Bennett-tl1l`** (P3, front-end) — a70z's
*one-sided* and *both-constant* emission shapes remain unproven downstream (the
real Dict corpus only produces the two-sided shape), and
`_ovf_admissible_range` is total-swept only at N=8.

## ✅ SESSION 2026-07-21 — TRACKER TRUTH-UP; SC9 CASE B FORMALLY CLOSED; a70z design done, impl parked

**No BVM source changes this session** — this was an orchestrated cross-repo
reconciliation + design session (Fable orchestrator, serial subagents). NOTE:
the sessions 2026-06-29 → 2026-07-12 (CW-D arc through SC9 Case B completion)
never updated this HANDOFF — for that period read `WORKLOG.md` top-down from
the 2026-07-12 milestone block, and Bennett.jl `worklog/090–095`.

### State of the world

- **SC9 Case B is COMPLETE and now closed in beads** (`bennettvm-7xa`):
  fdict(3,7) from plain Julia extracts (4-body closed-world set), runs to 7,
  round-trips to exact initial state, empty history. Re-verified live
  2026-07-21: `test/test_dict_roundtrip.jl` 34/34. Epic `416r` closed 13/13.
- **Tracker truth-up** (beads were ~5 weeks behind git): closed 7xa, 90l,
  416r.11/.12/.13/.4, 6db/ehp (superseded by ADR 0017 — no recognized-op
  vec lowering will ever exist), nm0 (stale umbrella), M13 chain
  zg5/fu5/kl3/vw8 (shipped long ago; force-closed past stale dep edges).
  `xkl` re-scoped to the closed-world route. Bennett.jl side: 44dg, eln6,
  800b closed (see Bennett.jl worklog chunk 095, session 2026-07-21).
- **The WORKLOG's unfiled successors are now real beads**: `bennettvm-rnhv`
  (was "san3": Dict GROWTH — 14 inserts → rehash-grow copy loop dies at VM
  run, `KeyError: :__v96` undefined SSA; first run-tier wall past SC9),
  `Bennett-a70z` (was "bsng": Dict{Int64,Int64} EXTRACT wall — smul overflow
  bit, elsize 8), `Bennett-zdd6` (was "jb6w": SysV coercion-spill mis-stamp
  landmine).

### In flight (Bennett.jl side): Bennett-a70z

Scout + 2 blind proposers CONVERGED (exact constant-folded interval-test
overflow-bit emission; designs in `../Bennett.jl/docs/design/a70z/`).
Implementation parked **UNVERIFIED** on `../Bennett.jl` branch
`wip/a70z-overflow-bit` (1f521d3d) — implementer was stopped mid-first-test-run.
Next session: re-verify red-green from scratch. **BVM needs no changes for
a70z** (emitted opcodes already ingestable; byte-granular heap ready for
elsize>1). After a70z: `bennettvm-rnhv` (Dict growth) is the frontier.

### Blockers / gotchas

- `bd` dolt auto-push is broken in BOTH repos (`git-remote-cache/.../repo.git`
  "not a git repository"). Local dolt state is correct; remote bead sync needs
  repair.
- Concurrent Julia runs corrupt the shared precompile cache — `pgrep -af julia`
  before ANY julia invocation; this laptop runs single test files only.

## ✅ SESSION 2026-06-10 — OPTION C DECIDED + CW-A/B/C COMPLETE: C-on-the-VM story demo GREEN

**The lead resolved e67u as OPTION C** (closed-world reversible execution,
ADR 0017) and the entire CW-A/B/C arc landed in one orchestrated session
(Fable orchestrator; Opus coders, Sonnet hostile reviewers, serial Julia).
**Suite 6450 → 6757. BVM: 8 commits pushed (HEAD `7634c0f`). Bennett.jl:
3 commits pushed (HEAD `67f9107`), gated by the full 63m45s suite
(688655 green; pinned gate-count baselines byte-identical throughout).**

### What landed (controlling docs: ADR 0017 → 0018 → 0019+Amendment A → 0020)

- **ADR 0017** — Option C as four capabilities (closed-world IR, reversible
  calls, heap floor, intrinsic whitelist). `tu9` superseded; `90l` re-scoped
  to the circuit boundary; route (a)/RevMap stays quantum-tier (`o1y`).
- **CW-A (heap floor)** — ADR 0018; `IState.arena_top` + 7 `Intrinsic*`
  (malloc/calloc/realloc/free/memset/memcpy/memmove); free = L1 no-op
  (monotone cursor); bulk ops = L2 per-cell deltas.
- **CW-B (calls)** — ADR 0019 (2 independent proposers → synthesis →
  REJECT → fix → ACCEPT); frames in `IState` (locals field REMOVED,
  wrap-at-construction); `CallEnter` zero-history L1; `ReturnExit`
  unconditional L2 (residual + `end_pc` + `target_olds`); multi-function
  `VMProgram` + `#`-qualified labels; recursion proven (factorial depth 5);
  `u110` ingest split done en route (5 files).
- **CW-C2 (front end, Bennett.jl)** — ADR 0020; `IRCall.callee::Union{
  Function,Symbol}`; `ptr_cells=false` gate (Julia paths byte-identical);
  C ptr params/store/load/ret + struct-GEP→IRPtrOffset + call emission +
  void `IRRet()` + `extract_parsed_ir_set_from_ll` (12 ParsedIRs from the
  fixture). Beads Bennett-k3ej/haiy/nd45.
- **CW-C3 (THE STORY DEMO)** — `test/test_c_hashtable_e2e.jl`:
  `hashtable.c` (clang -O0, 148 LOC, malloc-backed open addressing)
  **executes AND reverses on the VM bit-for-bit vs `GOLDEN.txt`**, both
  drivers, n ∈ {0,1,7,64,1000}; full `unrun!` → initial state, empty
  history. **ADR 0019 Amendment A** (hostile-review-ratified): COPY-args,
  OVERWRITE-targets (`target_olds` L2), per-frame `stack_top`/`StackAlloca`,
  ≥3-pred `UnconditionalEntry`.

### Process notes that mattered

- Hostile review caught: a REJECT-grade pc-recovery hole in the call design
  BEFORE implementation (B1 `end_pc`); the `IState.locals` staleness trap
  (B2); a dead-condition `free` bounds bug; the false pgcstack comment
  (swiftcc fixtures DO reach the D2 loop); the `nameof(::Symbol)` cross-repo
  time bomb; aggregate-round-trip MASKING of a broken `target_olds` (M4.3
  replay reconstructs the value — per-step inverse is the load-bearing
  assertion; documented in test_call_roundtrip.jl).
- The references PDFs were absent on this machine (never committed) —
  re-acquired the open ones; `mogensen-2016-rssa.pdf` + `mogensen-ril.pdf`
  still need user sync (bead `v5em`).

### What's next (CW-D — the Julia track, ends at bare-fdict e2e = 7xa)

1. **CW-D1** (`416r.11`): recursive callee extraction (opaque `j_*` calls →
   MethodInstance IR → multi-function ParsedIR set). Design pass first.
2. **CW-D2** (`416r.12`): Julia runtime intrinsic whitelist
   (`jl_alloc_genericmemory`, `gc_alloc_obj`, memcpy/move, throw).
3. **CW-D3** (`416r.13`): interned-global initializer extraction → CW-A3
   globals-as-segments (re-scoped onto this track; fixture is globals-free).
4. Deferred from reviews: `347o` (non-entry alloca guard), `zuem`
   (recursion+allocas test), `hyi6` (stack/heap cursor overlap guard),
   `r8nc` (≥3-pred backward dispatch), `w0a0` (e2e reverse perf), `r5c0`
   (O1 track), `h4q4` (liveness COPY→MOVE shrink), `8e7t`
   (FunctionEntry.returns void-flag), `efl2`/`7y2` (LOC splits), `lwhz`
   (include guard).

## ⏸ SESSION 2026-06-08 — acq + b5x/xv0u landed; Case B BLOCKED ON LEAD DECISION

**2 opcode beads landed + pushed (both repos); suite 6308 → 6450.** Then SC9 Case B
hit a verified ground-truth blocker and the lead chose to STOP. Orchestrated (Opus 4.8;
Opus coders, Sonnet hostile reviewers/scouts, serial Julia, verify-don't-rubber-stamp,
cross-repo explicitly allowed).

### Landed
- **`acq` ✅** (BVM `f77aade`): `IRExtractValue`/`IRInsertValue` (ArrayType) ingest →
  per-slot `Define` family. Aggregate `IRRet` (sret) deferred (bead filed). 6308→6376.
- **`b5x`/`xv0u` ✅** (Bennett `31b63a6` + BVM `c7d1016`; repinned 231bde6→31b63a6):
  additive `IRPtrOffset.elem_width`; cell-index ingest arm; fixed a non-i64 silent ÷8
  miscompile. **8** construction sites (the bead said 1). 6376→6450.

### 🚨 CASE B (`tu9`/`90l`/`7xa`) — LEAD DECISION PENDING (do NOT build until decided)
**The route-(b) premise of ADR 0015 / ADR 0016 D8 is FALSE against the real IR.** I
captured `code_llvm(fdict, Tuple{Int8,Int8}; optimize=false)` → `test/reference/fdict_O0.ll`
(Julia 1.12.5). Verified:
- **No in-body `jl_alloc_genericmemory`** — keys/vals/slots backings are interned GLOBALS
  (`@jl_global#146/#147`, the empty-Dict singleton, lines 9/28/29).
- **The write is the OPAQUE `@j_setindex!_149` callee** (line 59) — not inlined.
- The getindex READ is inlined: deterministic hash arithmetic (lines 102-157, NO
  ptrtoint/objectid), open-addressing probe (ordinary CFG), KeyError/AssertionError
  `unreachable` diamonds. Only real allocs are 3 `gc_alloc_obj` (Dict struct + 2 dead
  throw-boxes); the 3 ptrtoint are type-object tagging (provably NOT in the key-hash cone).

So a pure store-floor route (b) can't reverse a write it never executed, and there's no
in-body alloc to model as a `DynAlloca` (no length witness). **Two independent design
proposers converged on this** (full reports in this session's transcript). The 3 options
(ADR 0015 carries a banner; my rec = **A**):
- **A** — recognize the inlined `getindex` → the PROVEN `RevMap`/`IRMapGet` via decidable
  positive obligations (return traces to `.vals` offset-16; probe key SSA-identical to the
  `setindex!` key; ptr-free hash cone). Delivers bare `fdict` from source NOW, but uses
  route-(a) primitives + revives the `9i1` recognizer ADR 0015 called undecidable. Ground
  truth INVERTS the roles: RevMap = tractable correctness floor; raw-opcode execution = the
  deferred optimization (it's the one needing `setindex!` inlined).
- **B** — defer bare-`fdict`; prove the multi-backing DynAlloca machinery on hand-built IR +
  fail loud on bare `fdict` from source.
- **C** — Design G: extract/inline `setindex!` + model the global Memory singletons
  (research-grade; ADR 0015 demoted this).

### Buildable REGARDLESS of the Case B decision (next agent can start here)
1. **The determinism guard `90l`/`klgz`** — durable under any option. Reject
   `ptrtoint`/`inttoptr`/`objectid`/`pointer_from_objref` in the KEY-HASH provenance cone
   (the 3 benign ptrtoint in `fdict` are type-tagging, provably outside it). Front-end
   (Bennett `klgz`, `dict_vm.jl`) + BVM ingest mirror (`90l`, extend `_NONDETERMINISTIC_CALLEES`
   to the inlined no-callee case). Adversarial: `Dict{MutableStruct,V}` must fail loud.
2. **Case A part-2 push!/pop!** (`6db`/`ehp`/`xkl`): design pass (push! model on `uil`
   `heap_top`) → lowering → Bennett push!/growend! recognizer → e2e. (Case A from-source
   e2e IS proven: `test_vec_vm_roundtrip.jl`, green — the scout was WRONG that it's unproven.)
3. **FP** (`01w` frem needs Bennett `soft_frem`/`Bennett-tfx`; `4dn` fdim + uitofp audit).
4. **`dzd`** multi-index GEP (needs Bennett `Bennett-8e1f`).

### Process lessons (READ before pushing Bennett.jl)
- **Bennett.jl `.git/hooks/pre-push` runs the full ~65-min `Pkg.test`.** After manually
  gating, push with `SKIP_PUSH_TESTS=1 git push`. NEVER fire multiple pushes (each spawns a
  concurrent suite, Rule 7). Orphaned julia survive killing the git-push parent → kill by PID.
  (`bd remember bennett-prepush-hook-runs-full-suite`.)
- **Gate on a fresh-subprocess `Pkg.test()` you run yourself**, never a subagent's claim
  (false-143). Hostile review caught a real silent miscompile in BOTH acq and b5x.
- BVM↔Bennett.jl is a **path dep** (`../Bennett.jl`) → BVM tests see Bennett.jl edits live;
  `BENNETT_JL_PIN.md` is documentation only.
- `grep` for real alloc calls (`call.*alloc_genericmemory`), not the substring (matches
  `genericmemory.jl` comments — the near-miss that almost hid the Case B blocker).

### Beads
Closed: `acq`, `b5x`, `Bennett-xv0u`. Filed: Case B decision bead (blocks `tu9`/`7xa`);
multi-key aggregate `IRRet`; `ingest.jl` Rule-10 split; Bennett.jl `offset_bytes` reconcile.
`tu9`/`90l`/`7xa` annotated with the finding.

---

## ✅ SESSION 2026-06-04 (PM) — opcode-coverage BVM-only front cleared + dynamic-memory keystone

**5 beads landed (all pushed), suite 4722 → 6308.** Orchestrated (Opus coders, Sonnet
hostile reviewers, serial Julia, per-bead commit/push). Epic `bennettvm-x49`. Pin
unchanged (`231bde6`). See WORKLOG.md session entry for full detail.

- **`ftz`** — `docs/coverage-matrix.md` (19 IRInst; 15 COVERED / 3 GAP / 1 N/A).
- **`0kl`** — clean-fail-loud completeness: `_NONDETERMINISTIC_CALLEES` ingest guard +
  `test_fail_loud_completeness.jl` (the north-star's "fail loud cleanly" half).
- **`h0t`** — Float32 ingest-boundary rejection (ADR 0011 D2); guard on f32-touching
  soft ops; SC10 witness proves 0 f32 SoftCalls.
- **`bgc`** — width-aware integer ops (ADR 0012 R1): `_apply_binop(…, width)` extracts
  low-`w` bits + re-extends per op signedness; `Define.width` (default 64 = no-op).
  Full i8 fidelity (golden-master vs native Int8 on overflow). **Carrier-contract
  change:** narrow negative results now surface as the low-`w` zero-extended form
  (i32 -2 → 4294967294) — see bead `kmpg`.
- **`uil`** — runtime bump pointer `IState.heap_top` (OFFSET design): ≥2 dynamic
  allocas → disjoint windows; round-trips 0→…→0; single-array byte-identical.
  **This is the Case B keystone (Dict = keys+vals = 2 backings) — Case B is now
  unblocked.**

**Follow-up beads filed:** Bennett.jl f32-`fptosi/sitofp` silent-`IRCast` bug (P3);
`kmpg` (result() carrier contract); `9v84` (in-loop alloca); `s3xr` (static-after-
dynamic). All P3, blocked-by uil where relevant.

**NEXT — the cross-repo phase (each needs a design pass + Bennett.jl Rule-14 work):**
1. **Case B (`tu9`/`90l`/`7xa`) — now unblocked by uil.** Generalize the mem=:vm Memory
   recognizer (Bennett.jl) to the Dict keys/vals backing; add the objectid/identity
   determinism guard (`90l`); e2e `fdict` round-trip (`7xa`).
2. **Case A part-2 (`6db`→`xkl`):** push!/pop! lowering on top of uil's heap_top (needs
   a push! model design pass — length/capacity/topmost-region) + a Bennett.jl
   push!/growend! recognizer + e2e.
3. BVM-only: `acq` (aggregate → multi-slot IState model). Bennett-blocked: `b5x`
   (needs Bennett `xv0u` IRPtrOffset elem_width), `4dn`/`01w` (soft_fdim/frem/uitofp).

---

## DECISION (2026-06-04 — Dict via route (b); DO NOT RELITIGATE) — ADR 0015

> Lead decision, recorded in `docs/adr/0015-dict-route-b-correctness-floor.md`
> (amends ADR 0013 §D-3, which now carries an amendment banner). Grounded in a
> 3-agent codebase sweep + a live `code_llvm` probe (2026-06-04).

**Principle: correctness first, optimize on top.** SC9 Case B (`Dict`) goes via
**route (b)** — reversibly *execute* the inlined isbits-`Dict` LLVM opcodes (hash
= `IRBinOp`, open-addressing probe = ordinary control flow, `keys`/`vals`
`Memory` backing = the store-level memory floor, `KeyError` = dead branch) over
the floor + L3 checkpoint-replay, **exactly like Case A (Vector)**. There is **no
in-principle blocker** for value-semantic keys (the probe confirmed deterministic
hash arithmetic — no `objectid`/`pointer`/`rdrand`; L3 reverses any deterministic
instruction). **Route (a)** (recognize `Dict` ops → `IRMap*`/`RevMap`) is RETAINED
but **DEMOTED to a quantum-circuit-lowering optimization** — it was treating
route (a) as *the* path that made Case B read "research-grade."

What this changed (beads reconciled):
- `bennettvm-9i1` (route-a inlined-`getindex` recognizer, "research-grade") —
  **CLOSED / superseded** by `bennettvm-o1y` (route-a as a deferred P3 quantum
  optimization; `RevMap`/`IRMap*` stay built & proven, do not delete).
- `bennettvm-tu9` (NEW, P1) — **the SC9 Case B correctness gate**: generalize the
  `m9i` Memory recognizer to the Dict's `keys`/`vals` backing. Depends on `m9i`.
- `bennettvm-90l` (NEW, P1) — **determinism guard** (part of the correctness
  floor): fail loud (Rule 1) on non-deterministic-hash (`objectid`/identity) keys
  — the ONE genuine in-principle blocker. The 2026-06-04 sweep found no such
  guard in `dict_vm.jl` today; verify and add.
- `bennettvm-7xa` (e2e `fdict` gate) re-pointed off `9i1` → onto `tu9` + `90l`.
- `bennettvm-m9i` is the **shared prerequisite for both Case A and Case B**
  route (b) (annotated). It is the single highest-leverage next build.
- Bennett.jl side recorded: `Bennett-800b` note + `Bennett-ReversibleVM-PRD.md`.

The `heap.jl` "Dict irreversible by construction" reject is correct for
`mem=:heap` but is **not** a statement about reversibility in principle — the
`mem=:vm` route-(b) path makes an isbits `Dict` reversible.

## PLAN (2026-06-04 — full LLVM-opcode coverage) — epic `bennettvm-x49`

> All future Bennett.jl + BennettVM work is focused on this until the pipeline
> covers every reversibly-possible LLVM opcode. Granular plan + cross-repo bead
> map: **`docs/opcode-coverage-plan.md`**. Tracking epic **`bennettvm-x49`**.

Phases P1–P7. **Critical path: `m9i` / `Bennett-jfw6`** (the mem=:vm Memory
recognizer) — the single linchpin unlocking Case A (`xkl`) *and* Case B
(`tu9`→`7xa`). Beads created/reconciled this session:
- BVM: epic `x49`; `b5x` (IRPtrOffset), `acq` (aggregate ingest), `0kl`
  (fail-loud completeness), `4dn` (fdim/uitofp); `9i1` superseded by `o1y`;
  `7xa` reframed; **`zg5` decoupled from the Lean chain (`↛7zl`)**.
- Bennett.jl: `Bennett-jfw6` (BG1 Case A recognizer), `Bennett-klgz` (BG2
  determinism guard), `Bennett-8e1f` (BG3 GEP fill), `Bennett-6bu3` (BG4 struct
  fill); `Bennett-tfx` un-deferred → BG5 `soft_frem`; `Bennett-800b` retitled to
  route-(b). Each Bennett.jl src bead carries **Rule 14 (per-diff approval)**.

Out of this goal's scope (separate tracks): min-cut quality (M1), pebble (M9),
Lean (M11/M12), route-(a) RevMap (`o1y`).

## ✅ SC9 CASE A LANDED (2026-06-04) — dynamic Julia `Vector` round-trips e2e from source

**`Vector{T}(undef,n)` + indexed write/read loop now compiles and reverses under
`target=:reversible_vm` directly from Julia source** (the linchpin `m9i`/`jfw6`).
Orchestrated: 2+1 design pass → ADR 0016 → Opus coder → Sonnet hostile review →
orchestrator caught + fixed a regression → full `Pkg.test()` **4722/4722**.

- **Recognizer** (`Bennett.jl/src/extract/vector_vm*.jl`, 5 files; routed from
  `module_walk.jl` `mem=:vm` Case A branch, gated so `:auto`/`:heap`/Case-B
  untouched). Reuses heap.jl's M2/M3 partition + soundness proofs (Law 2). Design:
  `docs/adr/0016-case-a-mem-vm-recognizer.md`. Extract at `optimize=false`.
- **Two BennettVM ingest root-cause fixes** surfaced by the real multi-block O0
  CFG: i1 boolean masking (the `xor i1 %c,true` NOT-idiom; `_lower_bool_operand`)
  and within-edge SSA-duplicate φ.
- **Commits:** BennettVM `9933d27` (Case A) + `233d193` (ADR-0016 test plan:
  Int32/n=0/committed-mutation-proof + adversarial guards); Bennett.jl `1d574f2`
  (recognizer) + `231bde6` (cond_skel + P-callee fail-loud hardening). Beads
  `m9i` impl done; `Bennett-jfw6/bal6/msob`, `bennettvm-1z0/y3f2/p1vv` closed.
- **Process lesson (recorded):** a subagent's standalone `julia test/file.jl`
  gave a FALSE 143/143 (stale precompile cache) while the hardening was actually
  broken; the fresh-subprocess `Pkg.test()` caught it (P-callee over-rejected the
  dead `ijl_bounds_error_int` throw). **Always gate on `Pkg.test()`, never a
  standalone file run.**

### What's left on Case A / next milestones (epic `x49`)
- **`xkl` (Case A part 2): `push!`-grown Vector** — the recognizer handles
  `undef`+index; `push!`/`growend!` + `6db`/`ehp` push!/pop! lowering remain.
- **Case B (`tu9`/`7xa`):** route-(b) Dict — **blocked on `uil`** (multi-dynamic
  array: keys+vals = 2 backings; ADR 0016 D8).
- **FP:** `Bennett-tfx` (BG5 `soft_frem`) → `01w` (frem dispatch); `4dn`
  (fdim/uitofp).
- **`b5x` (IRPtrOffset):** blocked on `Bennett-xv0u` (additive `elem_width` — the
  byte-offset is width-lossy for the cell-addressed VM; `÷8` silently miscompiles
  non-i64). `acq` (aggregate ingest), `dzd`/`Bennett-8e1f` (multi-index GEP),
  `Bennett-6bu3` (struct aggregates).
- Low: `bennettvm-2lgo` (φ-dup multi-edge latent), `bennettvm-5js9` (bool-mask doc).

## Current state (2026-06-02 — FP/SC10 landed; Case B write-side end-to-end; Case A plumbing)

> Orchestrated session (user directive: Opus coders, Sonnet hostile reviewers,
> serial Julia, commit/push regularly, escalate at forks). **User granted
> Bennett.jl `src/` write access** for the Case A/B end-to-end unblocks (Rule 14
> satisfied). Bennett.jl repinned `f73a5ed` → **`b234496`**. Three commits pushed:
> BennettVM `b0ee45a` (FP) + `985f104` (Case B ingest); Bennett.jl `b234496`
> (mem=:vm Dict arm). Suites at close: **Bennett.jl 688504 Pass / 1 pre-existing
> Broken; BennettVM 4497 → 4558.**

### ✅ FP / SC10 — DONE (`b0ee45a`; beads `8ox`, `yc6` closed)
New `SoftCall` instruction (`src/ir/softcall_instruction.jl`) lowers Bennett.jl
`IRCall`-to-`soft_f*` nodes: a non-destructive bit-pattern SSA-create executed by
calling the host `soft_f*` fn via a `_SOFT_DISPATCH` allowlist (non-soft callees
fail loud, Rule 1); `is_injective=false` → L3 reversal. **`reversible_compile(x->x*x+3x+1,
Float64; target=:reversible_vm)` round-trips bit-exact to empty history (SC10).**
No Bennett.jl change needed. Hostile-reviewed APPROVE. `frem`/M_FP.3 (`01w`) stays
blocked — `soft_frem` genuinely doesn't exist. Filed `h0t` (Float32-rejection
follow-on), `9i1`... see below.

### 🟡 SC9 Case B / Dict — machinery + WRITE side DONE; read side BLOCKED (`985f104` + `b234496`; `0do` closed, `7xa` open)
The big empirical finding (probe, Julia 1.12.5; memory `sc9-case-b-dict-is-tractable-on-julia` + its correction): **`setindex!` WRITE survives as a clean callee `@j_setindex!_NNN` at both opt levels (recognisable); the `getindex` READ `d[k]` is fully INLINED to raw Int8 hash arithmetic + a `Memory` probe loop + KeyError diamond — NO `@j_getindex` callee.** So:
- **DONE:** Bennett.jl `mem=:vm` arm (`src/extract/dict_vm.jl`) recognises `setindex!`, drops the GC/Dict skeleton (reusing `heap.jl` dead-skeleton-taint helpers), emits language-neutral `IRMapInsert/IRMapGet/IRMapDelete` (new `IRInst` types in `ir_types.jl`, 16→19 subtypes). BennettVM `ingest.jl` consumes them → VM-side RevMap (already proven). `test/test_dict_roundtrip.jl`: Part A drives REAL `lower_vm` to `fdict(3,7)=7` round-trip (L2+L3+per-step-inverse); Part B proves `setindex!` extraction; **Part C asserts the bare-`fdict` reject is LOUD** (no miscompile). Hostile-reviewed APPROVE — **no silent-miscompile path** in the recogniser's purely-subtractive taint closure.
- **BLOCKED (`9i1`, research-grade):** the bare-`fdict(Int8,Int8)` end-to-end (`7xa`) needs an **inlined-getindex recogniser** — pattern-match the hash-probe subgraph as `M[k]` + prove the KeyError branch dead (statically undecidable in general; version-fragile). This is Bennett-800b's read-side. `getindex` DOES survive as a callee for **String** keys (not RevMap-compatible). The recogniser FAILS LOUD on it today.

### 🟡 SC9 Case A / dynamic Vector — `mem=:vm` plumbing landed; Memory recogniser is Core (`b234496`; `xkl` open, `M_DYN.7` filed)
Probe killed the blueprint's premise: on Julia 1.12 `Vector{undef,n}` drags the full `Memory`/GC skeleton (`jl_alloc_genericmemory_unchecked`, `julia.gc_loaded` data-pointer launder, MemoryRef chains, throw diamonds, SIMD-vectorised at `-O2`). The `:heap` recogniser is hardwired for the OPPOSITE (constant-N, loop-free, single-block). **What landed:** the `mem=:vm` mode + TLS-wall handling (additive plumbing in `entry.jl`/`module_walk.jl`). **What's left (`M_DYN.7`, Core):** a recogniser that strips that skeleton → `IRAlloca(dyn)+IRVarGEP+IRStore/IRLoad` (BennettVM already ingests this shape — `frtN.ll` proves it). The C/`.ll` `frtN` remains the near-term Case A proof.

### 🔭 The fork for next session (escalation-worthy — lead's call)
Both remaining pieces are hard Julia-frontend recognisers:
- **Case A Memory recogniser (`M_DYN.7`):** hard *engineering*, not undecidable; the sanctioned LLVM-opcode approach. Buildable incrementally with heavy verification (silent-miscompile risk → reuse `heap.jl` liveness-proof discipline + hostile review).
- **Case B inlined-getindex (`9i1`):** genuinely *research-grade* AND touches the PRD-deferred boundary question (§VIII.2) + ADR 0013's "LLVM-opcode core, no `code_typed`-only path" directive. Options: (a) pattern-match the inlined probe (fragile — advise against); (b) a **Julia-frontend typed-IR adapter** recognising Dict ops *before* LLVM inlining (sound, sidesteps inlining; the output is still language-neutral `IRMap*` so emitter-agnosticism is preserved — but it's the lead's architecture call); (c) accept the partial + an `@noinline`-barrier demonstrator. **Recommend (b) for Case B, pending lead approval; build (a-for-CaseA) the Memory recogniser.**

### Open beads (ready / blocked)
`9i1` (Case B inlined-getindex, research), `M_DYN.7` (Case A Memory recogniser, Core), `7xa` (e2e fdict — blocked on `9i1`), `xkl` (Case A push!/Vector — blocked on `M_DYN.7`), `01w` (frem — blocked, no `soft_frem`), `h0t` (Float32 rejection), `bgc` (width-masking, still open). Bennett.jl `Bennett-800b` updated with the write-recognisable/read-inlined finding.

---

## Current state (2026-06-01 — Case B VM-side + opcode coverage + FP ADR)

> Orchestrated session: Opus coders + Sonnet hostile reviewers, serial Julia
> (Rule 7); the FP ADR (no Julia) ran concurrently with a Julia test agent.
> Bennett.jl pin `f73a5ed` (unchanged). **Suite 3694 → 3942.** 6 commits
> pushed this session (`00a5bff..` → HEAD).

### What landed (all pushed, reviewed)
- **SC9 Case B VM-side is COMPLETE.**
  - **`jrc`** — `RevMap` reversible-map ADT (`const RevMap = Dict{Int64,Int64}`,
    a dedicated `IState` field so it rides `==`/`hash`/`deepcopy`/L3-checkpoint,
    ADR 0008 Finding 3) + `IRMapInsert`/`IRMapGet`/`IRMapDelete` (`src/ir/revmap.jl`).
    Insert/Delete = L2-predelta non-injective (MemoryStore template, missing-sentinel
    hardened so absent-key ops round-trip); Get = L3-only (MemoryLoad template),
    absent-key forward fails loud. 68 unit tests, mutation-proved, hostile APPROVE.
  - **`l49`** — hand-built round-trip gate (`test/test_revmap_roundtrip.jl`):
    straight-line `fdict` (oracle `fdict_ref(3,7)==7`, round-trips on BOTH the L2
    must_cache path and the L3 path) + a **genuine back-edge loop CFG** (insert L2
    deltas ×n interleaved with L3 control-flow/get checkpoints; n=3 hits the
    `{0=>0}` missing-sentinel absent-key insert inverse end-to-end). Hostile APPROVE
    (caught a docstring RED-signal misattribution — the aggregate round-trip is
    blind to a broken per-op inverse; `per_step_inverse_check` is the real catch,
    the M8.2 lesson; corrected).
- **`81y`** — **ADR 0011** (`docs/adr/0011-fp-inheritance.md`): Float64 via inherited
  Bennett.jl SoftFloat dispatch (UInt64 bit patterns + `IRCall` to `soft_f*`);
  **resolves PRD §8.1's deferred FP question** (3 v3 schemes rejected, Law 2).
  Honest scope: decision only — `IRCall` is still a GAP (`ingest.jl` raises); the
  VM-side `IRCall→soft_f*` wiring is **`8ox` (now unblocked)**.
- **`d7t`** — executable opcode-coverage matrix (`test/test_opcode_coverage.jl`):
  16 IRInst rows asserted vs live `lower_vm` (11 DONE + 2 e2e witnesses, 4 GAP
  fail-loud, IRSwitch N/A; `testset 0` pins the taxonomy via live `subtypes(IRInst)`).
  No discrepancy vs `docs/coverage-matrix.md`.

### Tracker reconciliation + beads filed
- Closed **`8i5`/`usf`/`l19`** (M_DICT.3/.4/.5) as **superseded by ADR 0008** —
  their VM-side op semantics landed in `jrc`; the "intercept the reject in ingest"
  framing was debunked by ADR 0008 Finding 2; residual ingest recognition is owned
  by `0do`. (`usf`'s `is_injective(getindex)=true` was WRONG — corrected to false.)
- Filed **`gqd`** (P3): ConditionalEntry predecessor labels aren't validated vs the
  LabelTable — sound today (forward-only/L3 never dereference them), latent landmine
  for a future backward-dispatch/pebble pass. From `l49` review.

### Findings to fold into the existing PRD-patch beads (`278`/`bk9`)
ADR 0011 surfaced two PRD inaccuracies (verified vs Bennett.jl src): PRD §3.6 l.544
cites **`soft_uitofp` which does NOT exist** (only `soft_sitofp`); and SoftFloatLib
exports **60** `soft_*` symbols, not the "~30"/"32 primitives" the stale comment says.

### The cross-repo "both repos together" gate (Rule 14 — needs USER approval)
The Case A/B *end-to-end* unblocks are Bennett.jl `src/` changes I did NOT touch:
- **`0do`** — Bennett.jl `Dict→IRMap*` recognition arm (`mem=:vm`). Unblocks
  `7xa` (e2e `fdict`, SC9 Case B). **Research-grade** (Bennett-800b: `optimize=true`
  inlines Dict ops to raw hash arithmetic, no callee boundary — no known solution).
- **Case A `mem=:vm` Vector arm** (Julia `push!`/`Vector`, bead `xkl`/task#11): drop
  the GC-TLS inline-asm, emit dynamic-N `IRAlloca`/load/store past the GC wall.
The C/`.ll` `frtN` form of Case A already round-trips (`xld`, done). Surface the
specific diff for per-diff approval before any Bennett.jl `src/` edit.

### Next ready BennettVM work (no approval needed)
- **`8ox`** (M_FP.2, **now unblocked** by ADR 0011) — wire `IRCall→soft_f*` dispatch
  in ingest; the gate to FP-in-VM (SC10).
- **`m6c`** (OutputRef nominal type, PRD §3.5) — but verify it has a consumer
  (no `run_oracle!` yet; may be premature).
- **`6r6`** (M1 bench harness), **`5ii`** (Lean toolchain bootstrap — independent,
  SC7), **`uom`** (L1 Exchange opt), plus P2/P3 cleanups (`ack`, `c0e`, `kuq`, `b5g`, `3ah`).
- **`bgc`** (width-masking) — NOT a clean pickup: 3 undecided options + de-prioritized
  ("frtN round-trips without it"); needs a design decision first, not a straight code bead.

### Gotchas this session
- `bd create` wants **`--type`**, NOT `--issue-type` (the CLAUDE.md Rules-section
  example is stale; the Quick-Reference block is right).
- Three pre-existing **untracked WIP files** from prior sessions were found this
  session (the broken `test_opcode_coverage.jl`; the references/ dirs). Treat
  untracked files as untrusted WIP and verify before adopting (Rule 3).

---

## Current state (2026-05-28 — Session 9 close)

- **Phase 2.** Bennett.jl pin `877341e` (current; unchanged). **Suite 3330/3330.**
  6 commits pushed (`e9dfd7f..a4815a1`).
- **🧭 ARCHITECTURE PIVOT (ADR 0013, lead-approved incl. Dict model D3).**
  The recon that drove it: **Cases A (dynamic `Vector`) and B (`Dict`) cannot
  reach BennettVM through Bennett.jl's Julia-function extractor** — GC
  allocation emits a TLS GC-frame inline-asm rejected at
  `Bennett.jl/src/extract/instructions.jl:2103` (`Bennett-5oyt/U15`) BEFORE
  any `ParsedIR` exists; `Dict` is additionally rejected by design
  (`Bennett-800b`). Verified across `mem=:auto/:persistent`, `optimize=false`.
  The bead-chain "intercept the reject in ingest" framing is therefore
  **empirically impossible**. Lead directive: **BennettVM must be a
  reversible VM over LLVM opcodes — useful to ANY emitter (C/Rust/Julia),
  sensible without Bennett.jl; Bennett.jl changes are welcome/anticipated.**
  (Saved to auto-memory: `bennettvm-language-agnostic`, `bennettvm-raison-detre`.)
- **ADR 0013** = the architecture: contract = LLVM-opcode IR (`ParsedIR` /
  `.ll`/`.bc`); reversible heap = a **store-level floor** (PRD §3.2/§3.7
  exchange mandate); **Dict = D3** (Bennett.jl recognizes Dict ops → neutral
  `IRMap*` ops → a BennettVM reversible-map ADT it controls; no rehash gap).
- **ADR 0014** = memory-floor lowering (L3 baseline; bump-allocator
  addressing; **defers the PRD §3.7 L1 Exchange optimization** to bead `uom`,
  same trace-tape-now pattern as collatz/pebble-game).

### What landed this session (all pushed, hostile-reviewed where Core)
- **SC9 Case C (nested loops)** — `matrix_sum_while(Int8(3))==9` round-trips.
  The PRD's `for i,j` form folds to `n*n`; the `while`-form is a genuine
  nested CFG the EXISTING ingest lowers with zero src changes (ADR 0010).
  `bennettvm-720/of5` satisfied by existing ingest + L3.
- **`IRCast`** (sext/zext/trunc) — `CastInstruction`, Define-templated
  (`bennettvm-hek`). + **`matrix_tri`** (triangular nested `while`) round-trips.
- **e4l ingest fix** — within-edge synthetic φ-const name collision
  (two φ-params taking the same constant on one edge → duplicate exit arg).
  Fix preserves cross-edge sharing (collatz/matrix_sum counts byte-identical).
- **Memory floor v1** (`bennettvm-x9j`, ADR 0014) — `MemoryStore`/`MemoryLoad`
  (scalar, L3) + bump-allocator `IRAlloca`. **EMITTER-AGNOSTIC PROOF:** a **C**
  function (`clang-18 -O0`) round-trips end-to-end via
  `extract_parsed_ir_from_ll` (committed `test/reference/through_mem.{c,ll}`).
- **M_OPCODE.1** audit → `docs/coverage-matrix.md` (16 IRInst subtypes).

### SC9 scorecard
- ✅ **D** (collatz) · ✅ **C** (nested loops) · 🔨 **A** (dynamic memory —
  memory floor v1 scalar done) · ⏳ **B** (Dict — D3 ADT, not started).

### What's next (Session 10) — and the Bennett.jl dependency
Cases A & B BOTH ultimately need **Bennett.jl-side work** (lead pre-approved
in principle; per Rule 14 show the specific diff before editing
`../Bennett.jl/src`):
- **A (Julia `Vector`)** needs the **`mem=:vm` arm** (ADR 0013 D-4 / task#11):
  (1) trivial — drop the `movq %fs:0` TLS inline-asm; (2) core — emit
  dynamic-N `IRAlloca` + `IRLoad`/`IRStore` for Julia heap past the GC wall;
  (3) small — `IRCall.callee_name::Symbol`. Plus the **U16** 2-index aggregate
  GEP reject (`bennettvm-dzd`) blocks even C arrays — needs a Bennett.jl GEP
  extension.
- **BennettVM-side autonomous runway** before that fork: **v2 GEP**
  (`IRPtrOffset`/`IRVarGEP` → Define address arithmetic), testable via a
  pointer-arg C function (the SUPPORTED 1-index GEP form; aggregate arrays are
  U16-blocked). Then v3 dynamic-N alloca.
- **B (Dict)** = D3 reversible-map ADT (reframes `bennettvm-jrc`) + Bennett.jl
  Dict→`IRMap*` recognition.

### Key open beads
`uom` (L1 Exchange, P2), `dzd` (v2 GEP reach / U16, P2), `b5g` (resolve_ptr
polish, P3), the SSA-dup latent gap (P2), `3ah` (_phi_const collision, P3),
task#11/`zg5`/`kl3`/`fu5` (Bennett.jl mem=:vm + M13 dispatch — all need
user approval). ADRs 0008/0009 (per-case) subsumed by ADR 0013.

## Current state (2026-05-28 — Session 8 close)

- **Phase:** **Phase 2 (production).** **Bennett.jl pin:** `877341e` (matches this device's Bennett.jl HEAD; `bennettvm-18b` pin-mismatch resolved).
- **Test suite:** **2872 / 2872 passing** (`julia --project=. -e 'using Pkg; Pkg.test()'`), up from 2108 at Session 7.
- **M8 milestone — CLOSED.** M8.5 (`012f6cd`, the 100-random-program property capstone, +510 assertions) + the two deferred follow-ups: `s9c` (M8.4 generator hostile review — generator verified SOUND; reviewer's "blocker" was already covered by existing tests) and `7cg` (`1ce192a`, CallInstruction.inverse :direct pc-symmetry audit). Generator-hardening follow-up `bennettvm-jpb` (P3) filed.
- **🎯 M_UNBOUNDED milestone — CLOSED. `collatz_steps` (SC9 Case D, the load-bearing motivating case) ROUND-TRIPS END-TO-END.** This is the first of the four P0 motivating cases to land.
  - **ADR 0012** (`docs/adr/0012-collatz-lowering.md`, `7ea1e7c`) — the keystone lowering design, synthesized from a 2+1 independent design pass. Decisions: dedicated `Define` instruction for SSA-creates (D1), `COMPARISON_OPERATORS` (D2), `SelectInstruction` MUX (D3), IRPhi→ConditionalEntry / IRBranch→ConditionalExit+critical-edge-split / IRRet→End (D4), synthetic zero-creates for constant φ-incomings (D5).
  - **The crux** (both design proposals missed it; orchestrator-caught): collatz's loop reuses SSA temporary names every iteration → each iteration OVERWRITES the last → NOT zero-history. **User chose trace-tape = the existing L3 checkpoint-replay** (`unstep!` restores a full-IState snapshot + replays forward, never calling per-instruction `inverse()`, so overwrites are captured automatically). `Define`/`Select` are therefore `is_injective=false`. **Pebble-game (zero-history loops) deferred to M9.**
  - **Landed (each Opus coder + review, pushed):** `3vj` comparison ops (`2d3b587`), `d3p` Define (`d04e8cc`), `8wj` Select (`ee2fad3`), `c39` the real `lower_vm` ingest (`127fe57`, `src/ir/ingest.jl` — generic over the 6 IRInst types via critical-edge splitting; hostile-reviewed), `hvx` the SC9 Case D round-trip gate (`523d0c1`, `test/test_collatz_roundtrip.jl`). `h7f` (M_UNBOUNDED.2) closed as superseded-by-L3.
  - **Key scope finding (in test docstring):** the L3 round-trip invariant alone catches *reversal* bugs but NOT *forward-semantic* bugs (L3 replays a deterministic-but-wrong forward and still closes); the **oracle anchor** (forward result == irreversible Julia `collatz_steps`) is the complementary half. Both mutation-proved.

### What's next (Session 9)

- **The other three P0 motivating cases** (`M_DICT`, `M_DYN`, `M_NESTED`) — but note ALL of them, like collatz, need a real `ParsedIR→VMProgram` ingest. `c39` built the *collatz-shaped* generic ingest (`src/ir/ingest.jl`); generalizing it is **`M_OPCODE`** (audit `lower_vm` vs all 17 IRInst subtypes + fill gaps). M_OPCODE is the natural next foundation before the remaining cases. The motivating-case beads' "intercept the reject" framing is inaccurate — `extract_parsed_ir` already yields the symbolic loop (see `bennettvm-c39` notes); the work is lowering, not interception.
- **Collatz follow-ups (filed):** `bennettvm-bgc` (P1, ADR R1 — width-masking: the ingest doesn't mask to i8, so oracle agreement holds only for non-overflowing inputs; round-trip is width-independent), `bennettvm-3ah` (P3, ingest hardening: `_phi_const_name` collision for numeric-suffix labels + entry-as-loop-header now fail-loud), `bennettvm-jpb` (P3, generator hardening).
- **Orchestration note:** another agent was touching beads early in this session; cross-device sync is via `.beads/issues.jsonl` import (no conflicts arose — remote stayed in sync throughout).

## Current state (2026-05-27 — Session 7 close, partial)

- **Phase:** **Phase 2 (production).**
- **PRD:** `bennettvm_prd.md` is v4.
- **Bennett.jl pin:** `877341e` (unchanged this session).
- **Test suite:** **2108 / 2108 passing.** `julia --project=. -e 'using Pkg; Pkg.test()'`.
- **M8 (per-step inverse + property-test family) — 4 of 5 sub-beads CLOSED.**
  Session was cut short before M8.5 (100-program property capstone).
  All four landings orchestrated as Opus coder + Sonnet hostile reviewer
  pairs (M8.4 hostile review deferred — see below):
  - **M8.1** `adf12a9` — `test/reference/countdown.jl` gains
    `countdown_program(n)` factory + include-time `@assert` self-check
    (two clauses: `result[:steps_N] == countdown_ref(N)` AND
    `result[:n_N] == 0`; clause 2 pins `:sub`/`:add` direction —
    reviewer-caught defect: clause 1 alone is theatre against the
    n-decrement mutation because the unrolled layout always runs
    exactly N blocks regardless of body arithmetic). Refactor hoists
    `build_countdown_vm` (→ `countdown_program`) and `_decrement_block`
    from `test/test_forward_interpreter.jl` to the reference file;
    updates 7 consumer tests to include directly instead of leaning
    on transitive include order. Updates ADR 0002 citation.
  - **M8.2** `107aad9` — `test/test_per_step_inverse.jl` —
    `per_step_inverse_check(vm, inputs; checkpoint_interval,
    must_cache_set, label, _forward_snapshots_override)`. Reusable
    parameterized check that snapshots post-step IState, walks back
    via `unstep!`, asserts equality at every position; mismatch raises
    `ErrorException` pinning step index + offending IState field.
    Also asserts `rs.current == rs.initial` post-sweep (catches
    `rs.initial`-mutation bugs in the M4.3 L3 restore site).
    **Architectural finding (reviewer-caught, fixed):** when
    `must_cache_set` is empty, the L3 fallback path is
    `forward()`-driven (`Replay.jl`'s `_restore_to_checkpoint` reads
    nearest CheckpointEntry snapshot and replays forward) and
    BYPASSES `inverse()` entirely. So countdown(N)/empty-must_cache
    testsets are blind to per-instruction `inverse()` regressions.
    The M4.5 anchor inherits the same blind spot. Fix: extended the
    M7-delta testset to cover countdown(5)/K=4 with `must_cache_set =
    compute_must_cache(vm)` so the L2 path (M7.4 fast-path, the
    actual `inverse()` call site) is driven on the anchor. Docstring
    rewritten to honestly bound what each shape catches.
  - **M8.3** `f0435a9` — `test/test_mutation_proof.jl` — 5 instruction
    kinds × 2 mutations × 2 paths (L2 scaffold for non-injective;
    M6.3 direct `forward+inverse` round-trip for L1-short-circuited
    injective kinds — the M6.2 push gate prevents `unstep!` from
    reaching `inverse()` for SwapInstruction, MemoryInterchange,
    MemorySwap). Strategy (a) chosen: `BennettVM.eval(body)` shadows
    canonical method; `Base.delete_method` inside `try/finally`
    restores; `n>=1` signature-drift check + post-restore GREEN
    scaffold assertion form the double safety net.
    **World-age trap finding:** Julia world-age semantics make a
    freshly-`eval`'d method invisible to calls from any function
    whose compilation predates the eval. First implementation gave
    20/20 false GREEN. Fix: every call into mutated production code
    is wrapped in `Base.invokelatest(...)`. Documented in file
    docstring §"World-age caveat".
    `CallInstruction.inverse()` excluded — its `make_delta` raises
    unconditionally (v5-deferred per ADR 0002 §Open Questions item
    4) so the L2 path cannot be driven. Audit-trail cross-reference
    added at `src/ir/call_instruction.jl` (17-line docstring,
    pure documentation, no behavior change) pointing at follow-up
    `bennettvm-7cg` (P2).
  - **M8.4** `989c6a9` — **UNREVIEWED** —
    `test/generators/random_program.jl` — seeded random RSSA program
    generator. `random_program(rng; shape=:any, size_hint=4)` with
    three shape constructors (linear chain, conditional reconvergent
    diamond, unrolled loop) + `default_rng() =
    MersenneTwister(0xBE171973)` (BE1 = Bennett + 1973). Excludes
    CallInstruction (same exclusion M8.3 took). Hostile reviewer NOT
    RUN — session was cut short. Self-mutation-proof on the
    determinism test passed (global-RNG injection → 20/20 RED →
    restored). Follow-up `bennettvm-s9c` (P2) tracks the deferred
    review. Do NOT re-open `bennettvm-bii` unless a regression is
    found.

## What you (next session) are picking up

**M8.5 — 100-random-programs property test capstone — is the next bead.**

`bennettvm-tnp` (P1). Consumes M8.2's scaffold + M8.4's generator:
loop `default_rng()` 100 times, call `random_program(rng)`, push the
program through `per_step_inverse_check` at multiple K and
must_cache_set settings. The capstone for the M8 milestone. Note
that M8.4 isn't externally reviewed — M8.5's full-suite green is
itself a strong validation signal for the generator (100 random
programs exercising scaffold+history+IR end-to-end), but flag any
suspicious failure as a candidate generator bug first.

Also outstanding before M8 milestone close:
- `bennettvm-s9c` (P2) — deferred hostile review of M8.4 generator.
- `bennettvm-7cg` (P2) — direct round-trip audit of
  `CallInstruction.inverse()` (M8.3 follow-up).

After M8: the four P0 SC9 motivating cases (M_DICT, M_DYN, M_NESTED,
M_UNBOUNDED) which are the load-bearing acceptance gate before M13
(Bennett.jl `target=:reversible_vm` dispatch arm).

## Session 7 orchestration notes (partial)

Same Opus + Sonnet pattern as Sessions 5 and 6. Orchestrator
(opus[1m]) ran in foreground; each sub-bead spawned one Opus coder
(general-purpose subagent) then one Sonnet hostile reviewer
(general-purpose subagent). Reviewer per-claim signoff + mutation
probes uncovered the load-bearing findings (M8.1 weak self-check,
M8.2 L3 blind spot, M8.3 MemorySwap-duplicate + generic fragment).
M8.4 review skipped due to time pressure — see `bennettvm-s9c`.

**Stale untracked dirs**: the 8 `references/<topic>/` dirs (foundational,
ad-and-checkpointing, implementations, quantum-uncomputation,
reverse-debugging, reversible-ir, reversible-isa, reversible-languages)
are local PDF stashes carried across sessions; they are NOT in
`.gitignore` but also NOT committed yet. No effect on suite.

### Earlier session marker (Session 6 close: 1997/1997)
- **M7 (history layer L2: delta with min-cut) — CLOSED this session.**
  All seven sub-beads, orchestrated as Opus coder + Sonnet hostile
  reviewer pairs:
  - **M7.1** `cd911b6` — ADR 0002 `docs/adr/0002-enzyme-min-cut-mapping.md`.
    Six binding design decisions for M7.2-M7.7. Key finding from
    source cross-check: all three ArithmeticAssignment modops AND
    MemoryAssignment are structurally injective via `dual_modop`;
    strengthens `bennettvm-ack` and `bennettvm-c0e` follow-ups.
  - **M7.2** `400593b` — `DeltaEntry{T<:Instruction} <: AbstractHistoryEntry`
    at `src/history/delta.jl`. Parametric on T, NamedTuple payload,
    step::Int field. Structural ==/hash. Julia 1.12 dispatch quirk
    documented: do NOT add cross-T `==` method (shadows same-T).
  - **M7.3** `9d1b374` — `make_delta(instr, s_pre, step)` per-instruction
    in `src/ir/<instr>.jl` files. Per ADR finding: empty NamedTuple
    payload for ArithmeticAssignment + MemoryAssignment;
    CallInstruction errors v5-deferred. Generic fallback errors loudly.
  - **M7.4** `c7edd6b` — `unstep!` DeltaEntry fast-path:
    pop-and-inverse when top of history is a DeltaEntry whose step
    matches step_count. Existing M4.3 path byte-preserved as
    fallback. `inverse(::T, s, payload::NamedTuple)` specialisations
    coexist with existing `prev::Any` methods (no ambiguity).
  - **M7.5** `ecabb78` — `compute_must_cache(prog)::Set{Tuple{Symbol,Int}}`
    + `must_cache(set, label, idx)::Bool` at `src/analysis/liveness.jl`
    (new dir). Stub: returns all non-injective body positions.
  - **M7.6** `281414a` — INTEGRATION. New kwargs on step!/run!:
    `must_cache_set` (default empty) and `replay_mode` (default false).
    Push gate is the ADR composition rule: replay_mode → L1 → L2 → L3.
    `_block_index_at(prog, pc)` private helper. unstep!'s replay loop
    sets replay_mode=true. **ADR deviation accepted**: kwarg, not
    VMProgram field — avoids 18-file test cascade; default-empty
    reproduces M6.2 behaviour bit-for-bit. Zero pre-existing regressions.
  - **M7.7** `d29c9b2` — M7 milestone capstone. Seven testsets, 150
    new assertions. **Sub-linear ratio achieved: 0.0909** on
    18-Swap + 2-Arith program (well below 0.5 ADR floor, < 0.1
    design target). Scaling sweep confirms ratio approaches the 10%
    asymptote monotonically from below. L2 path matches L3 path on
    countdown(5). Composition with M6 (all-injective → zero history)
    preserved.

## Session 6 orchestration notes

Same Opus + Sonnet pattern as Session 5. The seven sub-beads ran
sequentially per Rule 7 (no parallel Julia). Highlights:

- **M7.1's ADR was binding**: subsequent coders deferred to ADR §
  references rather than the (sometimes outdated) bead text. M7.3 in
  particular ignored the bead's "capture pre-target value" wording
  and followed the ADR's empty-payload finding.
- **M7.6's ADR deviation**: `must_cache_set` ships as a kwarg, not a
  VMProgram field. Hostile reviewer accepted this as an
  optional-capability parameter (Rule 13 is about toggling competing
  behaviours; the default here is a strict subset).
- **M7.7 mutation-provability gap (informational)**: testset 3's
  sub-linear ratio assertion is architecturally double-enforced by
  L1 + L2, so no single-line mutation can drive ratio above 0.5.
  Reviewer flagged this as a strength of the architecture, not a
  defect.

No follow-up beads filed this session (the existing `bennettvm-ack`,
`bennettvm-c0e`, `bennettvm-xtb` from Sessions 4–5 were strengthened
with ADR-derived rationale; nothing new emerged).
- **Setup gotcha:** Manifest.toml is gitignored (per-machine). Fresh
  clones MUST run `julia --project=. -e 'using Pkg; Pkg.develop(path="../Bennett.jl"); Pkg.instantiate()'`
  before tests pass.
- **M6 (history layer L1: injective no-log) — CLOSED this session.**
  All four sub-beads orchestrated through Opus coder + Sonnet hostile
  reviewer pairs:
  - **M6.1** `6b59824` — `is_injective` trait at `src/history/Injective.jl`.
    Type-level true for `SwapInstruction`, all `ControlInstruction`
    subtypes (Begin/End, Uncond Entry/Exit, Cond Entry/Exit),
    `MemoryInterchange`, `MemorySwap`. Value-level true for
    `ArithmeticAssignment` iff `modop === :xor`. Conservative on
    `:xor` only — broaden-to-`:add`/`:sub` filed as follow-up
    `bennettvm-ack`. 30 new assertions.
  - **M6.2** `e9eb994` — `step!` push site AND-gated by
    `!is_injective(instr)`. `step_count` increments unconditionally;
    only the L3 push is gated. Cascading test updates to
    `test_unstep.jl`, `test_checkpoint_push.jl`, `test_unrun.jl`,
    `test_roundtrip.jl` for the new push patterns (net -7 assertions
    from removed out-of-bounds `history[i]` checks; +7 new in
    `test_injective.jl`). Round-trip invariant preserved via
    Replay.jl's `s.initial` fallback.
  - **M6.3** `44dfdca` — contract tests pinning `inverse(i, _, nothing)
    == s_pre` for every M6.1-injective type. New file
    `test/test_injective_inverse.jl`. **Audit result: no bugs in any
    existing inverse() method.** 81 new assertions. Identified gap
    `bennettvm-xtb` (P3) — `_handle_backward_cross_block_dispatch!`
    missing; non-blocking because Replay.jl's `s.initial` fallback
    handles empty-history cross-block backward traversal.
  - **M6.4** `fa90ee1` — M6 milestone capstone integration test. Five
    all-injective programs (xor-chain, swap-chain, two-block-uncond,
    memory-ops, mixed) under K ∈ {1, 4, 64, typemax(Int)}. 14
    testsets, 490 new assertions. `isempty(rs.history)` asserted
    after EVERY step, not just at end. Confirms M6 architecture
    composes correctly.

## Session 5 orchestration notes

Orchestrated as four Opus coding subagents (one per sub-bead) + four
Sonnet hostile reviewers, serial (Rule 7 — no parallel Julia). Each
reviewer produced per-claim signoff with hostile mutation probes
(Rule 6 — "Core" change tier for M6.1/M6.2; "Small" + reviewer for
M6.3/M6.4). M6.2 coder hit a 529 Overloaded mid-edit on
`test_roundtrip.jl` and `test_injective.jl`; orchestrator finished
those manually using the coder's partial state, then sent the
combined diff through the reviewer.

Follow-up beads filed this session (do not block M7):

- `bennettvm-ack` (P2) — broaden `is_injective(::ArithmeticAssignment)`
  to `:add`/`:sub` modops (PRD v4 §3.2 reconciliation).
- `bennettvm-c0e` (P2) — `MemoryAssignment` value-level
  discrimination (modop===:xor case).
- `bennettvm-xtb` (P3) — `_handle_backward_cross_block_dispatch!`
  for future direct-inverse `unstep!` optimization.

## What you (next session) are picking up

**M8 — per-step inverse property test — is the next milestone.**

Per PRD v4 §3.13 (per-step inverse pattern) + §3.15 (property test
discipline). M8 is mostly testing infrastructure that exercises the
M2/M4/M6/M7 layers under randomised programs. M8.x sub-beads are in
`bd ready`.

After M8: the four P0 SC9 motivating cases (M_DICT, M_DYN, M_NESTED,
M_UNBOUNDED) which are the load-bearing acceptance gate before M13
(Bennett.jl `target=:reversible_vm` dispatch arm).

**Parallel-startable alternatives** (independent of M8):
- `bennettvm-ack` (P2): broaden `is_injective(ArithmeticAssignment)`
  to `:add`/`:sub`. ADR 0002 source cross-check confirmed all three
  modops are structurally injective via `dual_modop`. Small,
  low-risk simplification that reduces M7.6's must_cache set.
- `bennettvm-c0e` (P2): MemoryAssignment value-level injectivity.
  Same shape as bennettvm-ack.
- `bennettvm-6r6` (P1): M1.1 benchmark harness for history strategies.
- `bennettvm-34c` (P1): M_OPCODE audit of lower_vm vs Bennett.jl's
  17 IRInst subtypes.
- `bennettvm-81y` (P1): M_FP.1 ADR for SoftFloat-dispatch FP
  inheritance.

### Open observation carried over from Session 4

- `bennettvm-kuq` (P2): `unstep!` search loop uses
  `entry isa CheckpointEntry` while the truncation loop uses the
  polymorphic `_entry_step()` helper. **Still asymmetric.** M6 did
  not introduce a new entry type (M6's no-push semantics meant the
  L3 entry type set didn't grow). When M7 introduces a delta entry
  type, resolve this asymmetry — the search loop should use the
  polymorphic helper too.

### Open observation flagged this session

- `bennettvm-kuq` (P2): `unstep!` search loop uses
  `entry isa CheckpointEntry` while the truncation loop uses the
  polymorphic `_entry_step()` helper. Asymmetric. Only matters when
  M6/M7 entry types arrive; the M6 implementer should resolve when
  they touch Replay.jl.

### Session 4 notes

- 31 stale beads (M5/M0/M2/M3 sub-beads) were closed at session start
  to reconcile the tracker with `git log` reality.
- M4.5's hostile review was in progress in the background when the
  session was paused. The reviewer's mutation probe to
  `src/history/Replay.jl` (removing the restore-side deepcopy) was
  caught and reverted on `git status` BEFORE the M4.5 commit. The
  probe DID empirically confirm one matrix entry (restore-side
  deepcopy → M4.5 test 4 RED). Full M4.5 hostile review can be
  resumed next session if any latent doubt remains.

### Earlier state (preserved for history)

## Old state (pre-Session-4, retained for diff context)

- **Phase:** **Phase 2 (production).**
- **PRD:** `bennettvm_prd.md` is v4. v3 archived at `docs/prd/bennettvm_prd_v3.md`.
- **Bennett.jl pin:** `877341e` (repinned 2026-05-26 from `5731cec`,
  docs-only diff).
- **Test suite:** **565 / 565 passing.** Single `julia --project=. -e
  'using Pkg; Pkg.test()'`.
- **Milestones complete (2026-05-26 orchestration session):**
  - **M5** — RC3 `rvm` pre-read (build + sample run + instruction
    taxonomy). ADR at `docs/adr/0001-rc3-rvm-smoke.md`.
  - **M0** — Bennett.jl handoff smoke (Project.toml, src/BennettVM.jl
    skeleton, lower_vm digest, regression-anchor test). ADR at
    `docs/adr/0000-handoff-smoke.md`.
  - **M2** — IR foundation (18 sub-beads): all 12 RSSA instruction
    types (ArithmeticAssignment, SwapInstruction, MemoryAssignment,
    MemoryInterchange, MemorySwap, CallInstruction, BeginInstruction,
    EndInstruction, UnconditionalEntry/Exit, ConditionalEntry/Exit)
    with forward/inverse + constructor validation + round-trip tests;
    BasicBlock with structural_inverse + reversed(); LabelTable
    with dual-address layout; VMProgram with cross-block container.
  - **M3** — forward-only interpreter (8 sub-beads): initial_state,
    is_halted, result, step!, run! with max-steps guard, cross-block
    dispatch via LabelTable, args→params two-phase rename,
    countdown(N) golden-master integration test against an
    irreversible Julia reference (countdown_ref).
- **Most recent commit:** see `git log -1`.
- **Git tag:** `spike-0-archived` still marks the end of Phase 0. No new
  tag created for v4 ratification.
- **Test suite:** spike `spike/` is frozen (789/789 passing, chmod -w);
  Phase-2 `test/` is empty.

## What you (next session) are picking up

**M3 (forward interpreter) closed. M4 is the next milestone** — history
layer 3 (checkpoint-replay), which is the first step toward `unrun!`
and the reverse direction. After M4 comes M6 (history L1 — injective
no-log), M7 (history L2 — delta min-cut), M8 (per-step inverse +
property test).

After the history layer is in, the four motivating cases (M_DICT,
M_DYN, M_NESTED, M_UNBOUNDED — all P0) become the SC9 acceptance
gate.

Parallel-startable independent tracks:

- **M1.1** (P1) — benchmark harness for history strategies. Independent
  of M4-M8.
- **M_OPCODE** (P1) — audit lower_vm against Bennett.jl's 17 IRInst
  subtypes (only 6 are exercised so far via collatz_steps).
- **M_FP.1** (P1) — ADR documenting SoftFloat-dispatch FP inheritance.

### Earlier handoff (Phase-2 first session: M5 + M0) — DONE

This section is preserved for historical reference; M5 and M0 closed
2026-05-26.

### A. Phase-2 first session: M5 + M0 (recommended)

This is `bennettvm-phase2-epic` first child issues (M5 then M0).

1. **M5 — RC3 `rvm` pre-read** (gates everything).
   - Build `rc3` and `rvm` from `references/implementations/RC3/`. The
     repo uses Maven/CUP; build instructions in its README. **Java
     toolchain required.**
   - Run at least one RSSA program through `rvm`. Sample programs in
     `references/implementations/RC3/compiler/programs/rssa/vm/`.
   - File `docs/adr/0001-rc3-rvm-smoke.md` capturing: (a) build steps;
     (b) the sample RSSA program; (c) `rvm` output; (d) verbatim
     observations about RSSA semantics that should inform Phase-2 IR.
   - The literature pre-read (Mogensen 2016 §3, Deworetzki-Meyer 2021
     §2.2 pp. 66–67) should happen before or during this milestone.

2. **M0 — Bennett.jl handoff smoke** (PRD §6 SC1, §9 M0).
   - Initialize Phase-2 Julia package: `Project.toml` at root,
     `src/BennettVM.jl`, `test/runtests.jl`.
   - Implement a stub `lower_vm(parsed::ParsedIR) :: VMProgram` that
     returns an empty `VMProgram` and prints a digest of the input
     `ParsedIR` (number of blocks, instructions, args).
   - Call it on `collatz_steps(::Int8)` from
     `Bennett.jl/test/test_y986_loop_header_dispatch.jl:129`. Goal:
     verify the import works at pin `5731cec` and the type signature is
     correct.
   - File `docs/adr/0000-handoff-smoke.md` with the digest output.

### B. Alternative first session: M1 (cost measurement)

Independent of M5/M0. Could be done in parallel by a separate session.

- Benchmark, on the spike's countdown(10_000) program (the spike is
  read-only — `chmod -R u+w spike/` first, restore after):
  - Full-snapshot history (the spike baseline).
  - A delta-history sketch (just record `(register, old_value)` tuples).
  - A periodic-checkpoint sketch (snapshot every K steps; replay forward
    from nearest checkpoint to reach an arbitrary step).
- Write up in `docs/measurements/m1-history-cost.md`. Use the data to
  set the default checkpoint interval in v4 §3.3.

### What to NOT do

- **Do NOT promote spike code into Phase 2.** PRD v4 §1.1, §5.3, §7.7.
  Phase 2 starts from an empty `src/`+`test/` tree. The spike is tagged
  `spike-0-archived` and `chmod -R -w`. Use as a *pattern source*, not
  source to fork. The reviewer specifically called this out as
  load-bearing.
- **Do NOT modify Bennett.jl source.** CLAUDE.md Rule 14. v4 §3.7
  Handoff A is specifically designed so that Phase-2 M0 does not require
  any Bennett.jl mutation. If you find yourself wanting to add an export
  to Bennett.jl (e.g., for `IRBasicBlock`), STOP and ask the user. The
  qualified-access pattern (`Bennett.IRBasicBlock`) suffices.
- **Do NOT skip the RC3 pre-read.** PRD v4 §3.1 and SC6 are explicit.
  Writing Phase-2 IR before reading RC3's `instances/` directory is a
  Law-2 violation.
- **Do NOT add a `target=:reversible_vm` dispatch arm to Bennett.jl
  unilaterally.** That is Handoff B (v4 §3.7), ADR 0003, requires user
  approval and 3+1 protocol.
- **Do NOT introduce floating-point support.** v4 §3.6: out of scope for
  Phase-2 initial release. Emit a clear "FP not supported" error if a
  `ParsedIR` carries an FP `IRBinOp`.

## Key v4 normative requirements (cheat sheet)

Sections to re-read often:

- **§3.1** RSSA IR; isomorphic to RC3 taxonomy (12 concrete subclasses).
  φ-equivalents on BOTH joins AND splits. Variable-destroying uses.
- **§3.2** Injective / non-injective / control-flow partition. Memory =
  exchange. Jumps = source-label-encoded.
- **§3.3** Three-layer history: no-log / delta-min-cut / checkpoint-replay.
  Full snapshots forbidden.
- **§3.7** Consume `Bennett.ParsedIR` (`Bennett.jl/src/ir_types.jl:347`).
  `IRBasicBlock`/`IRInst` not exported; access qualified. `IRLoad`/`IRStore`
  → `Exchange` translation pass required pre-RSSA.
- **§3.9–§3.17** Spike-derived API + invariants (mutable RState, structural
  `==`, forward-before-push, discard-pop predicate, per-step inverse test,
  golden master co-location, seeded random programs WITH control flow).

## Tools you should know about

- **`bd ready`** — find available work. After Phase-2 epic opens, M0/M5
  will appear.
- **References are not in git.** `references/` is ~127 MB and intentionally
  untracked. SHA256 manifest at `references/manifest/SOURCES.md`.
- **Bennett 1973 PDF on disk** at `references/foundational/bennett-1973-logical-reversibility.pdf`
  (user-supplied 2026-05-25; SHA256 `e61ad668…0687`). v3's blocker is
  resolved.
- **`playwright-cli` with `--browser chromium --headed`** still works for
  paywall acquisition. ACM DL still blocked.
- **`spike/`** is `chmod -w`. If you need to re-run a probe (e.g., for M1
  cost measurement), `chmod -R u+w spike/`, run, then `chmod -R -w spike/`.

## Bennett.jl pin

- Pinned SHA: `5731cec22a1fd29efe02d4dc21c2a57e655ecb47`.
- Pin date: 2026-05-23. Confirmed still current 2026-05-25.
- See [`BENNETT_JL_PIN.md`](./BENNETT_JL_PIN.md) for repinning policy.
- Phase 2's Handoff A (v4 §3.7) is designed to be insensitive to most
  Bennett.jl changes; only `ParsedIR` struct breakage requires repinning.

## Open questions for the user (deferred from v3 §VIII)

(Reduced from six to two genuine items; see v4 §8.1.)

1. **Floating-point reversibility scheme.** Residual tape vs posit-with-
   sticky vs opaque snapshots. v4 defers to v5 after a Phase-2 prototype.
2. **Divergence handling.** Whether Phase 2 inherits Bennett.jl's
   `max_loop_iterations` style or implements a separate termination
   analysis.

## Quick session-start checklist

When the next agent arrives:

- [ ] `cat PHASE.md` — confirm Phase 2.
- [ ] `bd ready` — what's claimable. Expect Phase-2 milestones.
- [ ] Read `bennettvm_prd.md` (v4) §0, §1, §3, §6, §9 at minimum.
- [ ] Read this `HANDOFF.md` top to bottom.
- [ ] Read `CLAUDE.md` top to bottom (Rule 16: re-read after every context
      compression).
- [ ] Skim `WORKLOG.md` Session 2 for what landed.
- [ ] Read `spike/RETROSPECTIVE.md` if not done in prior session.
- [ ] Only then start work — and start with M5, not M0.

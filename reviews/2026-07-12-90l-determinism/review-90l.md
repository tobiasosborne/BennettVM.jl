# Hostile review — Bennett-klgz / bennettvm-90l determinism-guard classifier

Reviewed: Bennett.jl (uncommitted, HEAD e7454fd) + BennettVM.jl (uncommitted,
HEAD 838e2da). All findings below are evidence-backed by ground-truth probes
run in this session (Julia 1.12.5), not by reading the diff alone.

## 1. NOTHING-ADMITTED invariant — HOLDS

`_ir_error(inst, reason) = error(_ir_error_msg(inst, reason))` — `error()`
never returns, so every branch of the new if/elseif in
`src/extract/instructions.jl:3643-3670` is a hard throw. The unconditional
generic `_ir_error` call immediately after the if/elseif (line 3671) is
reached **only** when `got_callee === nothing` or `got_callee` is in neither
set — i.e. every code path still rejects. Confirmed structurally and by the
mutation probes below.

Regex `^jlplt_(.+)_\d+_got$` (greedy `.+`) probed directly:

| input | demangled |
|---|---|
| `jlplt_ijl_object_id_161_got` | `ijl_object_id` (correct) |
| `jlplt_foo_123_456_got` (nested digit groups) | `foo_123`, N=456 (correct — greedy backtracking always peels the *last* `_\d+_got`) |
| `jlplt_hash64_2_got` (callee itself ends in a digit) | `hash64` — **the discriminator and a trailing name-digit are inherently ambiguous from the string alone**; not a bug for the current sets (no entry ends in a digit) but a sharp edge worth a one-line comment |
| `jlplt_ijl_object_id_161_got.1` (LLVM name-uniquification suffix) | `nothing` → falls to the generic message, safe but loses precision |
| `jlplt__got`, `jlplt_x_got` (no discriminator digits) | `nothing` → safe fallback |
| `weird_global#5` | `nothing` → safe fallback (matches the pre-existing pinned test `test_416r13_jlglobal_singleton.jl`) |

No input produces an admit-instead-of-reject outcome. **Verdict: safe.**

## 2. CLASSIFIER CORRECTNESS (determinism of `memhash_seed`) — code is correct, but the shipped message overclaims "Symbol"

Checked `~/.julia/juliaup/julia-1.12.5+0.x64.linux.gnu/share/julia/base/hashing.jl:195-201`:

```julia
const memhash_seed = UInt === UInt64 ? 0x71e729fd56419c81 : 0x56419c81
hash(s::String, h::UInt) = (h += memhash_seed; ccall(memhash, ...))
```

`memhash_seed` is a **fixed compile-time literal**, not a per-process random
salt (unlike Python's hash randomization). Empirically verified
`hash("hello")` identical across 3 separate `julia` processes. So the
classifier's core claim — String-key content hashing is deterministic and
in-scope — is **correct**, and stronger than the "only within one process"
caveat the task brief worried about: it's deterministic across processes too
(same Julia version/arch).

**However**, both the `_CONTENT_HASH_GOT_CALLEES` comment (constexpr.jl:198-199)
and the shipped `_ir_error` message text (instructions.jl:3661, literally:
`"the \`String\`/\`Symbol\` byte hash"`) claim Symbol keys are covered by this
same `memhash_seed` content-hash bucket. **This is false**, confirmed three ways:

- `hash(x::Symbol) = objectid(x)` (hashing.jl:39) — Symbol hashing is `objectid`,
  not `memhash_seed`, by Base's own definition.
- `code_llvm(Base.ht_keyindex, Tuple{Dict{Symbol,Int8},Symbol}; optimize=false)`
  shows **no ccall and no GOT stub at all** for the hash — it's a raw
  `getelementptr`+`load i64` off a fixed offset in the `jl_sym_t` struct (the
  hash is precomputed and cached at intern time in the C runtime). Symbol
  hashing can therefore never reach the `jlplt_*_got` classifier by construction.
- Live probe: `extract_parsed_ir_set_from_julia` on a `Dict{Symbol,Int8}`
  function throws — but on an **unrelated** wall (`@jl_undefref_exception`,
  generic message), never touching this classifier at all.
- ADR 0015 Decision 3 (`docs/adr/0015-dict-route-b-correctness-floor.md:116-122`,
  the design basis this diff cites) only scopes "isbits keys (Int8, Int, Float
  bit-patterns) and content-hashed keys (`String` via `memhash_seed`)" as
  in-scope; it never mentions Symbol. So the "Symbol" addition in the shipped
  message/comments isn't even grounded in the cited ADR — it's an unforced
  overclaim.

Net effect: **not a functional bug** (nothing is mis-admitted; if a Symbol
`objectid` call ever did surface via a GOT stub in some future Julia/LLVM
version, it would hit `ijl_object_id`/`object_id` in
`_IDENTITY_HASH_GOT_CALLEES` and get the determinism-floor message, which is
at least consistent with ADR 0015's "objectid-hashed keys are out" — not the
content-hash message the current comments imply). But the shipped
**user-facing error text and the source comments both assert something false
about Symbol** that a future agent/dev could take at face value. Recommend
dropping "`/`Symbol`" from the `_CONTENT_HASH_GOT_CALLEES` comment
(constexpr.jl:198-199) and the `_ir_error` message (instructions.jl:3661), or
gating it behind an explicit "Symbol is NOT currently reachable here" caveat.

## 3. FALSE-POSITIVE RISK — none found

- `code_llvm(Base.ht_keyindex, Tuple{Dict{Int8,Int8},Int8}; optimize=false)`
  emits **zero** `jlplt_*_got` stubs — isbits key hashing is pure integer
  arithmetic, no runtime callee at all.
- Live re-run of `test_klgz_determinism_guard.jl` testset (c) confirms the
  fdict `Tuple{Int8,Int8}` set extracts unchanged, `length(set) >= 4`, no throw.
- Grepped the full test suite for `ijl_object_id` / `objectid` / `memhash` /
  `UNRECOGNIZED` outside the new file: only `test_416r13_jlglobal_singleton.jl`
  (uses `weird_global#5`, doesn't match `jlplt_*`, unaffected) and two
  compile-cache tests whose "objectid" hits are `objectid(parsed)` cache-key
  comments, unrelated to this code path. No existing pinned test collides with
  the new classifier's message text.

## 4. VM MIRROR — style-consistent, correctly scoped, test hardcodes rather than iterates

- `_NONDETERMINISTIC_CALLEES` in `src/ir/ingest_call.jl` gets exactly 5 new
  bare `Symbol`s (`:ijl_object_id, :jl_object_id, :object_id,
  :jl_pointer_from_objref, :ijl_pointer_from_objref`), same bare-Symbol style
  as the pre-existing `:objectid, :pointer_from_objref`. Combined with those 2,
  the VM set now has exactly the same 7 names as Bennett.jl's
  `_IDENTITY_HASH_GOT_CALLEES` — verified by direct enumeration, no drift.
- `memhash_seed` is correctly **not** added to the VM's nondeterministic
  denylist (it's deterministic) — consistent design.
- The mirror testset (`test_fail_loud_completeness.jl` F1) is a **hardcoded
  literal tuple** of the 5 names, not `for nm in _NONDETERMINISTIC_CALLEES`
  diffed against a baseline — so a *future* addition to the set without a
  matching test update would not be caught by this file alone. It does,
  however, drive the real `lower_vm` pipeline via `_faillow_raise` (not a
  mock), so it is a genuine behavioral check for the 5 names it does list, and
  removal-type drift (probe (a)/(b) direction) is caught. Minor nit only.

## 5. MUTATION PROBES — both fire correctly, both restored and verified clean

Ran sequentially (one Julia process at a time), full file restore + `git diff`
byte-comparison after each:

**(a) Commented out the identity-hash arm** (`if false && got_callee !== nothing
&& got_callee in _IDENTITY_HASH_GOT_CALLEES` in instructions.jl): re-ran
`test_klgz_determinism_guard.jl` → **6 of 29 failures**, all exactly on the
determinism-message assertions (`occursin("determinism floor", msg)`,
`!occursin("UNRECOGNIZED", msg)`, and the hand-built-IR unit-test analogues).
Restored; `git diff` after restoration is byte-identical to the pre-mutation
diff.

**(b) Added `"memhash_seed"` to `_IDENTITY_HASH_GOT_CALLEES`**
(constexpr.jl): re-ran the same file → **6 of 29 failures**, this time on the
String-key testset (`!occursin("OBJECT IDENTITY", msg)` now fails because the
String key gets the identity/determinism-floor message instead of the
modeling-gap message) plus the hand-built-IR unit-test analogue. Restored;
`git diff` byte-identical to pre-mutation.

Both probes behave exactly as the task brief predicted — the test file is
load-bearing in both directions, not decorative.

## 6. TESTS + hygiene

- `test/test_klgz_determinism_guard.jl` (Bennett.jl), run standalone with
  `--check-bounds=yes`: **29/29 pass**, ~2m10s.
- `test/test_fail_loud_completeness.jl` (BennettVM.jl), run standalone with
  `--check-bounds=yes`: **47/47 pass** (includes the new F1 mirror testset).
- `test/runtests.jl` registration: `runfile("test_klgz_determinism_guard.jl")`
  correctly placed immediately after
  `runfile("test_416r13_jlglobal_singleton.jl")` (line 245).
- Worklog hygiene: Bennett.jl `worklog/095_2026-07-12_klgz_determinism_guard.md`
  exists and its content matches the diff (verified line-by-line: ground-truth
  GOT-stub table, VM mirror description, RED/GREEN evidence all check out
  against my own independent probes). `WORKLOG.md` index line present and
  accurate. BennettVM.jl uses a flat (non-sharded) `WORKLOG.md`; its new
  2026-07-12 session entry is present and matches the diff.
- No LLVM-format pins found — the tests assert only the guard's own diagnostic
  prose (`occursin("OBJECT IDENTITY", ...)` etc.) and the drift-invariant
  callee stem, never the drifting `_<N>_` discriminator or raw LLVM IR
  formatting, consistent with CLAUDE.md Rule 5.
- Protocol note (implementer + hostile-reviewer, not 2-proposer) is
  transparently documented in both worklogs and the test file's leading
  comment, with justification (no new construct, no new lowering) — consistent
  with the CLAUDE.md Rule-2 carve-out reasoning.

## Most dangerous residual risk

The classifier demangles by **callee name alone**, with no way to see the
*key type* that produced the call. That's fine today because Symbol hashing
happens to be inlined away (no GOT stub at all) rather than routed through
`objectid`'s GOT stub — but that's an LLVM-inlining accident of Julia
1.12.5/`optimize=false`, not a guaranteed invariant (Rule 5: "LLVM IR is not
stable"). If a future Julia/LLVM version ever *does* emit
`jlplt_ijl_object_id_N_got` for `objectid(::Symbol)` (e.g. a change in
inlining heuristics, or a different optimization level reaching this code
path), that call would land in `_IDENTITY_HASH_GOT_CALLEES` and produce the
"determinism floor / heap ADDRESS / mutable-struct key" message for a Symbol
key — which is a defensible outcome per ADR 0015's literal "objectid-hashed
keys are out" but flatly contradicts the shipped CONTENT-hash arm's own prose
claiming Symbol is deterministic-and-in-scope. Nothing is silently admitted
either way (Rule 1 holds), so this is a latent **message-accuracy / future
self-contradiction** risk, not a correctness hole — but it's the one place
where this diff's own internal documentation doesn't agree with itself, and it
should be tightened (drop "Symbol" from the CONTENT-hash comment/message, or
add a one-line note that Symbol is not currently reachable here) before it
misleads whoever eventually implements the "model `jlplt_<name>_got` stubs"
follow-up work the CONTENT arm's message explicitly invites.

## Verdict

**APPROVE-WITH-NITS.**

Nothing-admitted invariant verified structurally and via two independent
mutation probes (removal + misclassification), both restored cleanly. Regex
edge cases all fail safe. No false positives against any existing fixture or
pinned test. VM mirror is name-for-name consistent with the front-end set. All
cited tests pass standalone with `--check-bounds=yes`. Worklogs are truthful.

The one real defect is documentation/message-text scope creep: the
`_CONTENT_HASH_GOT_CALLEES` comment and its `_ir_error` message both claim
Symbol keys are covered by the deterministic `memhash_seed` content-hash
family. Ground truth (Base `hashing.jl`, live `code_llvm`, and a live
extraction attempt on `Dict{Symbol,Int8}`) shows Symbol hashing is `objectid`-
based and inlined away entirely — it never reaches this classifier, under
either bucket, today. Fix is a one-line wording change, not a design change.

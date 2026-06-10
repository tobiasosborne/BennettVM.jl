# BUILD.md — CW-C C closed-world hash-table fixture

Provenance and reproduction record for the `test/reference/c/` fixture
(bead `bennettvm-416r.8`, "CW-C1"). Controlling decision:
`docs/adr/0017-closed-world-execution.md` §Sequencing CW-C.

This fixture is **one translation unit** (`hashtable.c`) plus a separate,
non-fixture golden-master harness (`main_golden.c`). The point of the
single-TU constraint is that `clang -S -emit-llvm` produces a self-contained
LLVM module with no opaque callees — every `call` resolves to a function
defined in the same module or to a member of the ADR 0017 intrinsic
whitelist. That is the closed-world property CW-C2/CW-C3 depend on.

## Toolchain

```
$ /usr/bin/clang --version
Ubuntu clang version 18.1.3 (1ubuntu1)
Target: x86_64-pc-linux-gnu
Thread model: posix
InstalledDir: /usr/bin
```

`target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"`
`target triple = "x86_64-pc-linux-gnu"`

## Exact commands (run from `test/reference/c/`)

### 1. Native golden master (must agree across opt levels)

```bash
# -O2 build (the recorded golden values)
/usr/bin/clang -O2 -std=c11 -Wall -Wextra hashtable.c main_golden.c -o /tmp/ht_o2
/tmp/ht_o2 > GOLDEN.txt

# -O0 + sanitizers (UB / ASan cross-check; must match GOLDEN.txt line-for-line)
/usr/bin/clang -O0 -std=c11 -Wall -Wextra -fsanitize=address,undefined \
    hashtable.c main_golden.c -o /tmp/ht_san
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
    /tmp/ht_san            # clean: no ASan/UBSan diagnostics, exit 0
```

Result: `-O2`, `-O0+san`, and a plain `-O0` build all produce **identical**
output. GOLDEN.txt is that output. (ASan leak detection is ON; the fixture
`ht_free`s every table it allocates, so there are no leaks even though the
*VM* floor treats `free` as a no-op — the C fixture itself is leak-clean.)

### 2. LLVM IR for ingestion (fixture alone, no main)

```bash
/usr/bin/clang -O0 -S -emit-llvm -fno-discard-value-names -std=c11 \
    hashtable.c -o hashtable.O0.ll
/usr/bin/clang -O1 -S -emit-llvm -fno-discard-value-names -std=c11 \
    hashtable.c -o hashtable.O1.ll
```

`-fno-discard-value-names` keeps `%keys`, `%cap`, `%probe`, etc. readable.
`main_golden.c` is **deliberately excluded** — the IR must not contain
`printf`/`main`, only the fixture module.

## SHA256

```
8cbd5a3698aea0da1f7187b97be34a0ed33743394f045c49c943323f94abd4b9  hashtable.c
2d6721479ba0ffdedd60b6d5d0ebf09bb4fe281f10627dc9600b2d07c76dc38f  hashtable.O0.ll
e34234c3940a83cf0909dbd60d188bdf7aa1d2dc0ec778e62d99c2d0f6aec63d  hashtable.O1.ll
83c6d020567460b10e0f70aec25399b34f5dda8e2c2feb47f157f71fff0e8820  main_golden.c
43ccba00b7d45df239a18a12509db75aeec1a72ba25731f10dcc507cf2f44c9e  GOLDEN.txt
```

(IR hashes are clang-18.1.3-specific; re-emit on a different toolchain and
the hashes will move — the GOLDEN.txt *values* are the stable contract.)

## CLOSED-WORLD AUDIT (ADR 0017 §Decision item 4)

Whitelist (ADR 0017 §Decision 4): `malloc`/`calloc`/`realloc`/`free`,
`memcpy`/`memmove`/`memset`, plus pure-data `llvm.*` intrinsics
(`llvm.memcpy`/`llvm.memset`), `jl_alloc_genericmemory`, `gc_alloc_obj`,
throw/`unreachable`. ANYTHING outside fails loud.

### Every `declare` line, with verdict

**hashtable.O0.ll** (2 declares):

| `declare` | verdict |
|---|---|
| `declare noalias ptr @malloc(i64 noundef)` | WHITELISTED (malloc) |
| `declare void @free(ptr noundef)` | WHITELISTED (free) |

**hashtable.O1.ll** (3 declares):

| `declare` | verdict |
|---|---|
| `declare noalias noundef ptr @malloc(i64 noundef)` | WHITELISTED (malloc) |
| `declare void @free(ptr allocptr nocapture noundef)` | WHITELISTED (free) |
| `declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)` | WHITELISTED (llvm.memset — pure-data intrinsic, the array-zeroing loop in `ht_new`/`ht_grow` got idiom-recognized) |

**No non-whitelisted `declare` in either file.** No `printf`, no `memmove`,
no `calloc`/`realloc` symbols, no `__ubsan_*`/`__asan_*` (sanitizers were not
used for the emitted IR), no `llvm.trap`/`llvm.*.with.overflow`.

### Call-target closure (every `call` resolves)

A script checked that every `@sym` appearing as a `call` target is either
`define`d in the same module or one of the whitelisted `declare`s above.

- **O0:** all call targets resolve. Calls reach
  `@ht_new @ht_put @ht_get @ht_del @ht_grow @ht_free @ht_hash @ht_third_pass
  @demo_key @demo_val` (all `define internal` in-module) + `@malloc @free`.
- **O1:** all *leaf* helpers were inlined, but `@ht_third_pass` survives as a
  `define internal fastcc` (it has two call sites — one per driver — and is
  too large to inline at both, so clang keeps it out-of-line). Each driver
  reaches it via `tail call fastcc void @ht_third_pass(...)`, an in-module
  call that resolves. The only *external* call targets are
  `@malloc @free @llvm.memset.p0.i64`, all whitelisted. So O1 has exactly
  one in-module non-entry callee (`@ht_third_pass`) plus the three
  whitelisted externals.

### Defined functions

- **O0:** `ht_demo_basic`, `ht_demo_grow` (`dso_local`, the entry points)
  plus `ht_new ht_put ht_get ht_del ht_grow ht_free ht_hash ht_third_pass
  demo_key demo_val` (`internal`). The full call graph is visible as separate
  functions — the friendliest possible CW-C2 ingest surface.
- **O1:** `ht_demo_basic`, `ht_demo_grow` (entry points) **and**
  `ht_third_pass` (`internal fastcc`) survive; every *leaf* helper is inlined.
  Three defined functions, not two — `ht_third_pass` is shared by both drivers
  and stays out-of-line. Both entry points still present (required by the spec).

## LLVM instruction surface (for CW-C2 ingest planning)

### Counting method (read before trusting the histograms)

An earlier version of this section was **wrong**: it used a naive
`grep -c '<mnemonic>'` that counted the mnemonic *anywhere on the line*,
including inside SSA value names. `%call.i = add ...` was counted as a
`call`; `%sub.i = add ...` was counted as a `sub`; `%or.cond = select ...`
as an `or`. The result over-counted `call`/`sub`/`or` and several others.

The opcode of an LLVM instruction is **position-determined**, not a
substring: it is the first token of the instruction *body*, where the body
is whatever follows `%name = ` for a value-producing instruction, or the
whole (trimmed) line for a void/terminator instruction. The histograms below
are produced by an opcode-position-aware pass that, for each indented
non-label non-comment line, strips a leading `%name = ` and any `tail`/
`musttail`/`notail` call modifier, then reads the first remaining word as the
opcode. `call` is therefore counted only when `call` is the real opcode
(`%x = tail call …` or `tail call void …`), never when "call" appears inside
a value name. Reproduce with:

```bash
# opcode = first token of the instruction body (after stripping "%name = "
# and any tail-call modifier). Counts the actual opcode, not substrings.
awk '
  $0 !~ /^[ \t]+/ {next}                 # only indented instruction lines
  { l=$0; sub(/^[ \t]+/,"",l) }
  l ~ /^;/        {next}                  # comment
  l ~ /^[A-Za-z0-9._]+:/ {next}           # basic-block label
  { sub(/^%[A-Za-z0-9._]+[ \t]*=[ \t]*/,"",l) }   # drop "%result = "
  { sub(/^(tail|musttail|notail)[ \t]+/,"",l) }   # tail call -> call
  { n=split(l,a,/[ \t]/); op=a[1] }
  op ~ /^(add|sub|mul|udiv|sdiv|urem|srem|shl|lshr|ashr|and|or|xor|icmp|fcmp|load|store|getelementptr|alloca|br|switch|ret|call|phi|select|sext|zext|trunc|bitcast|ptrtoint|inttoptr|unreachable|fadd|fmul|fsub|fdiv|invoke)$/ {
    c[op]++; if (op=="call" && $0 ~ /tail[ \t]+call/) t++
  }
  END { for (k in c) printf "%s %d\n", k, c[k]; if (t) printf "tail_call %d\n", t }
' hashtable.O1.ll | sort -k2,2nr -k1,1
```

`getelementptr` is always `inbounds` here (every GEP in both files carries
`inbounds`), so the `getelementptr` count == `getelementptr inbounds` count.

### Mnemonic histograms (opcode-position-aware, regenerated after the
### N2 third-pass change)

**O0** (memory-SSA, alloca-heavy):
`load 230, store 110, br 87, alloca 59, getelementptr inbounds 52, call 42,
add 30, icmp 28, mul 15, ret 12, and 6, xor 6, sub 5, lshr 3, phi 1, shl 1`.

**O1** (register-promoted, phi/select-heavy):
`br 111, phi 98, icmp 66, add 63, load 55, getelementptr inbounds 46,
store 39, mul 33, xor 31, lshr 24, call 21 (tail call 21), select 21,
and 20, switch 6, ret 3, shl 2, or 1`.

Notes on the rows that the old (broken) histogram got wrong, and on the
rows the N2 change moved:

- **O1 has ZERO `sub`.** clang strength-reduces every `x - 1` to
  `add nsw x, -1` (e.g. `mask = cap - 1` becomes `add nsw %cap, -1`). The
  old `sub 12` was the naive grep matching `%sub.i` value *names* on
  `add` lines. O0 keeps 5 real `sub` instructions.
- **O1 `or` is exactly 1 — and it is a REAL `or`, not a phantom.** The old
  `or 12` was the naive grep matching `%or.cond` select/br value names. With
  the N2 third pass, `demo_val(j) + 1` where the low bit of `j ^ 0x5a5a` is
  known clears makes clang emit a single `or disjoint i64 %add.i15, 1`
  (`%add = or disjoint …`) instead of an `add` — so there is now exactly one
  genuine `or` opcode. (Without the third pass there would be zero.) All the
  `%or.cond*` short-circuit conditions remain `select`/`br`, not `or`.
- **O1 `call` is 21, ALL of them `tail call`.** Breakdown by target:
  `@malloc` ×8, `@free` ×8, `@llvm.memset.p0.i64` ×3, `@ht_third_pass` ×2
  (the two driver→helper tail calls). The old note said "19 tail calls";
  the third-pass helper adds the two `tail call fastcc @ht_third_pass`
  sites, bringing both the call total and the tail-call total to 21.
- **O1 `switch` is 6 (was 3).** The sentinel ladder
  `if (k==HT_EMPTY) … else if (k==HT_TOMB) …` lowers to a `switch i64` on the
  two sentinels, one per inlined `ht_put` body. The six sites by enclosing
  function: **1 in `@ht_demo_basic`** (its insert loop), **2 in
  `@ht_demo_grow`** (its insert loop + the rehash `ht_put` inside inlined
  `ht_grow`), and **3 in `@ht_third_pass`** (the helper is out-of-line, and
  the leaf `ht_put` was inlined into each of its three put paths). `ht_del`
  has no sentinel ladder, so it contributes no switch.
- **O0 `shl` is 1** (the single `old_cap << 1` in `ht_grow`; at O0 the
  constant multiplies are *not* strength-reduced to shifts, so no other
  `shl`). The old `shl 3` was naive over-counting.

No vector/SIMD ops (`<N x …>`) in either file. No `fadd`/`fmul`/`fsub`/`fdiv`
(int64 only). No `udiv`/`sdiv`/`urem`/`srem` (the hash uses shifts+mul; the
mask uses `and`). No `unreachable`, no `llvm.*.with.overflow` (verified by
grep in both files).

### What CW-C2 (the `.ll` ingester) will trip over — read this

1. **Two GEP shapes.** (a) **Struct-field**: `getelementptr inbounds
   %struct.ht, ptr %p, i32 0, i32 K` with K∈{0,1,2,3} selecting
   `keys/vals/cap/len` (`%struct.ht = type { ptr, ptr, i64, i64 }`).
   (b) **Array-index**: `getelementptr inbounds i64, ptr %base, i64 %idx`
   for `keys[i]`/`vals[i]`. Both are `inbounds`. The ingester must
   distinguish the two-index struct GEP from the one-index array GEP and
   compute element offsets from the datalayout (i64 = 8 bytes; struct
   fields at 0,8,16,24).

2. **`switch` from chained equality (O1 only, 6 sites).** The C
   `if (k==HT_EMPTY) … else if (k==HT_TOMB) …` ladder was lowered to a
   **`switch i64`** on the two sentinel constants
   `-9223372036854775808` (INT64_MIN) and `-9223372036854775807`
   (INT64_MIN+1), with a default. CW-C2 needs `switch` support, not just
   `icmp`+`br`, to ingest O1. O0 keeps these as `icmp`+`br` chains
   (no switch) — so **O0 is the easier first target**; bring up `switch`
   when moving to O1.

3. **`phi` and `select` (O1).** 98 phis, 21 selects. The loop induction
   variables (`probe`, `i`, `j`, `checksum`, `first_tomb`) and the
   `first_tomb>=0 ? first_tomb : i` ternary become phis/selects. RSSA
   φ-handling (Mogensen) is the relevant machinery. **O0 has essentially
   no phis** (1 total — the `first_tomb>=0?…` ternary, which clang lowers to
   a `phi` even at O0) because everything else is alloca/load/store — for the
   first round-trip, ingest **O0** and let memory model the SSA.

4. **`llvm.memset` with both constant and runtime length (O1).** Three
   sites: two with constant byte-counts (`i64 16384` = 2048×8 for the
   `ht_demo_basic` fixed table; `i64 32` = 4×8 for the initial grow
   table) and **one with a runtime length** `i64 %mul.i` (the grown
   table, size = new_cap×8). All are `memset …, i8 0, …` (zero-fill,
   value byte 0). The whitelisted reversible `memset` semantics must
   accept a non-constant length argument. O0 emits the zeroing as an
   explicit `store`-in-a-loop instead (no memset) — another reason O0 is
   the gentler first target.

5. **i64 throughout; i32 only in GEP index slots.** Keys/vals/cap/len and
   all arithmetic are `i64`. The literal `i32 0, i32 K` constants inside
   struct GEPs are the only i32s of note (plus `i1` switch/br conditions
   and the `i1 immarg` memset tail). No i32↔i64 result-affecting
   truncation; the few `sext`/`trunc` are GEP-index housekeeping.

6. **`tail call` marker (O1).** All 21 O1 calls are `tail call`:
   `@malloc`/`@free`/`@llvm.memset` *and* the two
   `tail call fastcc @ht_third_pass` driver→helper calls. Semantically
   identical to `call` for the VM; the ingester should treat
   `tail call` == `call` (and `fastcc` == default cc for a closed-world
   in-module call — there is no ABI boundary).

7. **`nsw`/`nuw` flags.** Present on most `add`/`mul`. The C is UB-free
   (verified under `-fsanitize=undefined`), so these no-overflow
   assumptions hold; the VM can ignore the flags (it computes exact i64
   two's-complement) but must not *rely* on them for reversibility.

8. **No `unreachable`, no `trap`, no overflow intrinsics.** The control
   flow is total — every loop is bounded by `cap`, every function returns
   normally. No exception/abort path to model.

## Branch liveness at n=1000 (full cover of ht_put / ht_get / ht_del)

The bare insert→delete→lookup workload never exercised the structurally
interesting paths of `ht_put` (tombstone reuse, update-in-place) or the
miss path of `ht_del` — they were **dead code** in both drivers. A third
pass (`ht_third_pass`, called by both drivers after the delete pass) revives
them: it re-inserts every 6th key (a subset of the deleted `j≡0 (mod 3)` set,
whose slots are now tombstones) with value `demo_val(j)+1`, re-puts one
never-deleted key (`demo_key(1)`) to trigger update-in-place, and deletes a
key value no `demo_key(j)` ever produces (the constant `3`) to trigger the
delete-miss. Re-inserted keys flow into the checksum lookup pass automatically
(they are now live with a distinguishable value).

Per-branch liveness, **measured** with a temporary instrumented native build
(`-O0`, branch counters; instrumentation removed afterward), at `n=1000`:

| function | branch | basic | grow | status |
|---|---|---|---|---|
| `ht_put` | EMPTY → fresh slot (`first_tomb<0`) | 1000 | 2426 | LIVE |
| `ht_put` | EMPTY → **TOMB reuse** (`first_tomb>=0`) | 167 | 167 | LIVE (N2) |
| `ht_put` | TOMB seen → record `first_tomb` | 167 | 167 | LIVE (N2) |
| `ht_put` | **update-in-place** (`k==key`) | 1 | 1 | LIVE (N2) |
| `ht_get` | EMPTY → miss | 167 | 167 | LIVE |
| `ht_get` | `k==key` → hit | 833 | 833 | LIVE |
| `ht_get` | loop-exhaustion miss (post-`for`) | 0 | 0 | defensive¹ |
| `ht_del` | EMPTY → miss | 1 | 1 | LIVE (N2) |
| `ht_del` | `k==key` → hit (tombstone) | 334 | 334 | LIVE |
| `ht_del` | loop-exhaustion miss (post-`for`) | 0 | 0 | defensive¹ |

¹ The two post-loop `return 0` arms (`ht_get`, `ht_del`) are reached only if a
probe walks all `cap` slots without hitting `HT_EMPTY` — impossible while the
load factor stays `< 1`, which the drivers guarantee (basic: ≤ ~833 live in
cap 2048; grow: grows before load 0.7). They are **intentional defensive
fallthroughs** (Rule 1, fail-loud floor), not reachable behavior; the VM must
model them for totality but they carry zero traffic at any tested `n`. Every
*reachable* branch of all three functions is exercised; the grow driver also
exercises `ht_grow`'s rehash, which re-runs `ht_put`'s full branch set.

## UB scope (what the sanitizer run does and does not prove)

The `-O0 -fsanitize=address,undefined` build is **clean at exit 0 with no
diagnostics** for the tested set `n ∈ {0,1,7,64,1000}`. That validates
UB-freedom for the *tested inputs only*; it is not a universal proof. The
relevant overflow bounds (all `nsw` arithmetic clang emits is exact i64
two's-complement in the VM, which never relies on the no-overflow flags):

- **Key derivation** `demo_key(j) = j*2654435761 + 7` is the widest term. It
  stays inside `int64` (no signed-overflow UB) only for `j < ~3.47e9`
  (`≈ (2^63−1−7)/2654435761`). The largest tested `j` is 999 — nine orders of
  magnitude inside the bound. For `n` beyond ~3.47e9 the `nsw` multiply would
  be UB; the fixture is never run there. (Same comment lives at `demo_key`.)
- **Capacity doubling** `new_cap = old_cap << 1` in `ht_grow` is UB
  (left-shift of a signed value that overflows) only for `old_cap ≥ 2^62`.
  Unreachable at tested `n`: the grow driver starts at cap 4 and at `n=1000`
  tops out at cap 2048.
- **`uint64 → int64` casts** in `ht_hash` (the `(int64_t)z` on the splitmix64
  result, and `(uint64_t)key` going in) are **implementation-defined** before
  C23, not UB. On the pinned toolchain (clang 18 / x86-64) the conversion is
  the two's-complement reinterpretation, which is exactly what the VM's i64
  semantics compute; the GOLDEN.txt values bake in that choice. (C23 makes
  this conversion well-defined as modular reduction, matching the same
  behavior — so the contract is stable across the C11→C23 move.)

These bounds are documented so a future maintainer who raises `n` past the
tested ceiling knows the sanitizer's clean bill of health does not
automatically extend.

## House-style notes

- Delete strategy is **tombstones** (documented in `hashtable.c` header):
  simpler IR, exercises the probe-skip path CW-C3 must reverse, and the
  resulting dead-slot leak is acceptable under ADR 0017's correctness-first
  floor (free is a VM no-op anyway).
- The hash is the **splitmix64 mix13 finalizer** with fixed constants
  (`0xbf58476d1ce4e5b9`, `0x94d049bb133111eb`); it hashes the key *value*,
  never a pointer, so results are a pure function of `n` and the VM's
  deterministic virtual heap reproduces GOLDEN.txt (ADR 0017 §Corollary).

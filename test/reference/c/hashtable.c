/* hashtable.c — canonical C closed-world fixture for the CW-C validation track.
 *
 * WHAT THIS IS
 *   A small open-addressing (linear-probing) hash table mapping int64 keys to
 *   int64 values, plus two pure driver functions (ht_demo_basic, ht_demo_grow)
 *   that are the *future VM entry points*. The whole thing is ONE translation
 *   unit so that `clang -S -emit-llvm` yields a single self-contained LLVM
 *   module with no external code dependencies beyond a tiny libc whitelist.
 *
 * WHY IT EXISTS
 *   docs/adr/0017-closed-world-execution.md, §Sequencing CW-C: "A small
 *   open-addressing hash table in C, compiled by clang (18.1.3 local) to one
 *   `.ll` module — no opaque callees, no GC, no interned singletons. Bennett.jl
 *   `from_ll` grows multi-function + globals + intrinsic-call support; e2e
 *   round-trip on the VM, golden master against native execution. This is the
 *   first full demonstration of the story's language-agnostic claim."
 *   This file is that fixture. CW-C2 ingests it; CW-C3 round-trips it on the
 *   BennettVM; GOLDEN.txt pins the native answer.
 *
 * CLOSED-WORLD CONSTRAINTS (these make it a reversible-VM fixture)
 *   - No I/O of any kind here (no printf/puts). main() lives in main_golden.c,
 *     which is NOT part of this module.
 *   - No rand, no time, no seeding: every result is a pure function of n.
 *   - The hash is the splitmix64 finalizer (fixed constants below) — it hashes
 *     the *key value*, never a pointer/address. Allocation addresses never
 *     leak into a result, so the VM's deterministic virtual heap reproduces
 *     the native answer (ADR 0017 §Decision item 3, §Corollary).
 *   - libc calls are restricted to the ADR 0017 intrinsic whitelist:
 *     malloc, free (and the compiler may emit llvm.memset/llvm.memcpy for the
 *     struct/array zeroing below — both are pure-data intrinsics on the
 *     whitelist). No memmove, no calloc, no realloc symbol (grow rehashes by
 *     hand into a fresh malloc, so the data path is visible to the VM).
 *   - No undefined behavior: validated under -fsanitize=address,undefined.
 *
 * DELETE STRATEGY: TOMBSTONES (not backward-shift).
 *   A deleted slot is marked TOMB (a second sentinel). Lookups skip past TOMB
 *   while probing; inserts may reuse a TOMB. Rationale: (1) backward-shift
 *   deletion needs a re-probe loop with conditional moves that bloats both the
 *   LOC budget (Rule 10) and the IR ingest surface for no fixture benefit;
 *   (2) tombstones exercise the "probe continues past a non-matching,
 *   non-empty slot" path, which is exactly the open-addressing control flow
 *   CW-C3 must reverse. Correctness-first (ADR 0017): tombstones never shrink
 *   the table, so this floor leaks deleted slots — acceptable for a fixture.
 *
 * Ref: docs/adr/0017-closed-world-execution.md §Sequencing CW-C, §Decision (3,4).
 * Ref: splitmix64 finalizer constants — Guy L. Steele Jr., Doug Lea, and
 *   Christine H. Flood, "Fast Splittable Pseudorandom Number Generators",
 *   OOPSLA 2014 (the mix13 finalizer); used here purely as a fixed integer
 *   hash, no PRNG state. (NOT Flajolet — a frequent misattribution; Philippe
 *   Flajolet died in 2011 and is not an author of this paper.)
 */

#include <stdint.h>
#include <stdlib.h>

/* Sentinels. Real keys must avoid these two values; the drivers below never
 * produce them (keys are derived from small non-negative arithmetic on n). */
#define HT_EMPTY ((int64_t)INT64_MIN)        /* slot never used            */
#define HT_TOMB  ((int64_t)(INT64_MIN + 1))  /* slot used then deleted     */

typedef struct {
    int64_t *keys;   /* malloc'd, length cap, each entry HT_EMPTY/HT_TOMB/key */
    int64_t *vals;   /* malloc'd, length cap                                  */
    int64_t  cap;    /* power of two                                          */
    int64_t  len;    /* live entries (excludes tombstones)                    */
} ht;

/* splitmix64 finalizer: a fixed bijective mix of the key's bits. Pure data,
 * no globals, no seeding. Masked to [0, cap) by the caller via cap-1. */
static int64_t ht_hash(int64_t key) {
    uint64_t z = (uint64_t)key;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    z = z ^ (z >> 31);
    return (int64_t)z;
}

/* Allocate an empty table of the given power-of-two capacity. */
static ht *ht_new(int64_t cap) {
    ht *t = (ht *)malloc(sizeof(ht));
    t->keys = (int64_t *)malloc((size_t)cap * sizeof(int64_t));
    t->vals = (int64_t *)malloc((size_t)cap * sizeof(int64_t));
    t->cap = cap;
    t->len = 0;
    for (int64_t i = 0; i < cap; i++) {
        t->keys[i] = HT_EMPTY;
        t->vals[i] = 0;
    }
    return t;
}

static void ht_free(ht *t) {
    free(t->keys);
    free(t->vals);
    free(t);
}

/* Insert or update key->val. Linear probing; reuses the first TOMB seen.
 * Assumes load factor < 1 (the drivers keep it < ~0.7 by growing). */
static void ht_put(ht *t, int64_t key, int64_t val) {
    int64_t mask = t->cap - 1;
    int64_t i = ht_hash(key) & mask;
    int64_t first_tomb = -1;
    for (int64_t probe = 0; probe < t->cap; probe++) {
        int64_t k = t->keys[i];
        if (k == HT_EMPTY) {
            int64_t dst = (first_tomb >= 0) ? first_tomb : i;
            t->keys[dst] = key;
            t->vals[dst] = val;
            t->len++;
            return;
        }
        if (k == HT_TOMB) {
            if (first_tomb < 0) first_tomb = i;
        } else if (k == key) {
            t->vals[i] = val;          /* update in place */
            return;
        }
        i = (i + 1) & mask;
    }
}

/* Look up key. Returns the value; sets *found to 1/0. On miss returns 0. */
static int64_t ht_get(const ht *t, int64_t key, int64_t *found) {
    int64_t mask = t->cap - 1;
    int64_t i = ht_hash(key) & mask;
    for (int64_t probe = 0; probe < t->cap; probe++) {
        int64_t k = t->keys[i];
        if (k == HT_EMPTY) {
            *found = 0;
            return 0;
        }
        if (k == key) {
            *found = 1;
            return t->vals[i];
        }
        i = (i + 1) & mask;   /* skip TOMB and collisions alike */
    }
    *found = 0;
    return 0;
}

/* Delete key by tombstoning. Returns 1 if a live entry was removed, else 0. */
static int64_t ht_del(ht *t, int64_t key) {
    int64_t mask = t->cap - 1;
    int64_t i = ht_hash(key) & mask;
    for (int64_t probe = 0; probe < t->cap; probe++) {
        int64_t k = t->keys[i];
        if (k == HT_EMPTY) return 0;
        if (k == key) {
            t->keys[i] = HT_TOMB;
            t->len--;
            return 1;
        }
        i = (i + 1) & mask;
    }
    return 0;
}

/* Grow into a fresh table of double capacity, rehashing live entries by hand
 * (no realloc symbol — the copy is explicit so the VM sees every store). */
static void ht_grow(ht *t) {
    int64_t old_cap = t->cap;
    int64_t *old_keys = t->keys;
    int64_t *old_vals = t->vals;
    int64_t new_cap = old_cap << 1;
    t->keys = (int64_t *)malloc((size_t)new_cap * sizeof(int64_t));
    t->vals = (int64_t *)malloc((size_t)new_cap * sizeof(int64_t));
    t->cap = new_cap;
    t->len = 0;
    for (int64_t i = 0; i < new_cap; i++) {
        t->keys[i] = HT_EMPTY;
        t->vals[i] = 0;
    }
    for (int64_t i = 0; i < old_cap; i++) {
        int64_t k = old_keys[i];
        if (k != HT_EMPTY && k != HT_TOMB) ht_put(t, k, old_vals[i]);
    }
    free(old_keys);
    free(old_vals);
}

/* Derive a non-trivial key/value pair from an index j (pure in j, n).
 *
 * UB SCOPE (clang lowers these `*`/`+` to `nsw` arithmetic): the widest term
 * is `j*2654435761 + 7`, which stays inside int64 (no signed overflow, no UB)
 * only for j < ~3.47e9 (≈ (2^63-1-7)/2654435761). The largest tested n is
 * 1000, so every exercised j is far inside that bound. The
 * -fsanitize=address,undefined validation therefore proves UB-freedom for the
 * *tested* range only (n ≤ 1000); it is NOT a universal proof for arbitrary n.
 * The VM computes exact i64 two's-complement and never relies on the nsw
 * no-overflow assumption (see BUILD.md §UB scope, ht_grow's `<<` note, and
 * the uint64→int64 cast note in ht_hash). */
static int64_t demo_key(int64_t j) { return j * 2654435761LL + 7LL; }
static int64_t demo_val(int64_t j) { return (j ^ 0x5a5aLL) + 3LL * j; }

/* Third pass shared by both drivers: revive the structurally interesting
 * branches that an insert+delete+lookup workload never touches. Exercising
 * these makes the n=1000 run a full branch cover of ht_put/ht_get/ht_del
 * (per-branch liveness table in BUILD.md):
 *   (i)   ht_put TOMBSTONE REUSE — re-insert every 6th key (a subset of the
 *         deleted j≡0 mod 3 set, so its slot is now a TOMB). The probe meets
 *         the TOMB, records first_tomb, and on reaching EMPTY reuses it:
 *         the `first_tomb >= 0 ? first_tomb : i` true-arm fires. New value is
 *         demo_val(j)+1 so insert is distinguishable from update in the sum.
 *   (ii)  ht_put UPDATE-IN-PLACE — re-put one never-deleted key (demo_key(1),
 *         which survives the j%3 delete); the probe finds k==key live and
 *         takes the `t->vals[i] = val; return;` arm. Value demo_val(1)+1.
 *   (iii) ht_del MISS — delete a key value no demo_key(j) ever produces
 *         (demo_key(j) ≡ 7 mod 2654435761 and ≥ 7; the constant 3 is never a
 *         key), so ht_del walks to HT_EMPTY and returns 0 (the miss arm). */
static void ht_third_pass(ht *t, int64_t n) {
    for (int64_t j = 0; j < n; j += 6) ht_put(t, demo_key(j), demo_val(j) + 1);
    if (n > 1) ht_put(t, demo_key(1), demo_val(1) + 1);   /* update in place */
    ht_del(t, 3LL);                                        /* miss: never a key */
}

/* Driver A: fixed-capacity table (no growth). Insert n entries, delete every
 * third, re-insert a deterministic subset (third pass), then sum surviving
 * lookups into a checksum. Pure function of n. */
int64_t ht_demo_basic(int64_t n) {
    ht *t = ht_new(2048);                 /* fixed cap; drivers keep n small */
    for (int64_t j = 0; j < n; j++) ht_put(t, demo_key(j), demo_val(j));
    for (int64_t j = 0; j < n; j += 3) ht_del(t, demo_key(j));
    ht_third_pass(t, n);
    int64_t checksum = 0;
    for (int64_t j = 0; j < n; j++) {
        int64_t found = 0;
        int64_t v = ht_get(t, demo_key(j), &found);
        if (found) checksum += v ^ (j * 131LL);
        else checksum -= (j + 1LL);
    }
    checksum = checksum * 1000003LL + t->len;
    ht_free(t);
    return checksum;
}

/* Driver B: same shape but the table GROWS. Start small (cap 4) and grow
 * whenever load factor would exceed ~0.7, exercising rehash/realloc-by-hand. */
int64_t ht_demo_grow(int64_t n) {
    ht *t = ht_new(4);
    for (int64_t j = 0; j < n; j++) {
        if ((t->len + 1) * 10 > t->cap * 7) ht_grow(t);
        ht_put(t, demo_key(j), demo_val(j));
    }
    for (int64_t j = 0; j < n; j += 3) ht_del(t, demo_key(j));
    ht_third_pass(t, n);
    int64_t checksum = 0;
    for (int64_t j = 0; j < n; j++) {
        int64_t found = 0;
        int64_t v = ht_get(t, demo_key(j), &found);
        if (found) checksum += v ^ (j * 131LL);
        else checksum -= (j + 1LL);
    }
    checksum = checksum * 1000003LL + t->len * 7LL + t->cap;
    ht_free(t);
    return checksum;
}

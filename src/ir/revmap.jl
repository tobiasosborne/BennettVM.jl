"""
    RevMap + IRMapInsert / IRMapDelete / IRMapGet — the reversible-map ADT
    (ADR 0008; SC9 Case B; bead `bennettvm-jrc`)

BennettVM's reversible hash-table register. PRD v4 §3.6.2 Case B asserts
the load-bearing claim that a Julia `Dict` is reversible in the VM model
"if the history is preserved" (l.624–625), via "**the Bennett-1973
history-tape mechanism applied to heap mutation, not to control flow**"
(l.628–629). This file is the BennettVM-side, Bennett.jl-independent half
of that case: the runtime ADT plus three IR ops that mutate it, with the
delta-history capture that makes the mutations reversible. The end-to-end
Julia `Dict` path (`fdict` via `target=:reversible_vm`) is blocked
elsewhere on a Bennett.jl front-end recognition arm (`Bennett-800b`,
ADR 0008 Decision 4b); the hand-built `VMProgram` round-trip gate is a
separate bead (`bennettvm-l49`). This bead is scoped to the ADT, the
three ops, their forward/inverse/delta/injectivity, and per-op unit tests.

# `RevMap` is `Dict{Int64,Int64}`, mirroring `memory` exactly

`RevMap` is a plain `const` alias for `Dict{Int64,Int64}` (ADR 0008
Decision 3 / Finding 5: the name "PersistentDictRef" was rejected because
reversibility here is via *explicit history-tape undo*, not a persistent
/ structurally-shared data structure). The alias is preferred over a thin
wrapper struct for three reasons (ADR 0008 Finding 5; `IState.jl`
docstring "Why we override it"):

  * It inherits `Dict`'s **content-level** `==` / `hash`
    (`base/abstractdict.jl`: two dicts are `==` iff same key set with
    `==`-equal values, regardless of slot layout) with zero extra
    machinery — exactly the discipline `memory` relies on, so a rehash
    on growth is invisible to the round-trip invariant (ADR 0008 Finding
    5: "A rehash is thus invisible to the content-level invariant").
  * A wrapper struct would re-open the spike's Dict-identity trap
    (`IState.jl` "Why we override it"): it would need its own
    content-level `==`/`hash`, or distinct-but-equal-content maps would
    compare unequal and silently break round-trip `==`.
  * It reads as the runtime *value* type while `IRMap*` names the IR
    *ops*, keeping op-level and value-level names visibly distinct.

The map lives as a **dedicated `IState` field** (`src/ir/IState.jl`), NOT
in `locals` — ADR 0008 Decision 1 / Finding 3. That placement is what
makes `RevMap` participate in `IState.==`/`hash`/`deepcopy` and the L3
`CheckpointEntry` snapshot **automatically**, the same way `memory` does;
an external map would make a `Dict` round-trip test spuriously pass and
corrupt L3 replay.

v1 models a SINGLE map per `IState` (the canonical `fdict` body has one
`Dict`), so the three ops operate on `s.revmap` with no map-handle
operand. Multi-map (several distinct `Dict`s live at once) is OUT OF
SCOPE here — it would need a map-id keyspace on the field and a handle
operand on each op; the orchestrator files a follow-up bead.

v1 keys/values are concrete `Int64` (ADR 0008 Decision 4 width scope),
so `missing` (Julia's `Missing`) is an unambiguous "key was absent"
sentinel: no stored value can be `Missing`.

# The three ops partition by injectivity exactly as the memory floor does

`IRMapInsert` / `IRMapDelete` ≅ `MemoryStore` (`src/ir/memory_floor.jl`):
**non-injective in the map**, reversed by an **L2 delta** captured
PRE-`forward()` via `predelta_payload` (the `MemoryStore` template, Law
2), whose `inverse(::T, s, p::NamedTuple)` reverses from the payload. The
catch-all `inverse(::T, s, prev::Any)` RAISES (the never-reached L3 path).
`is_injective = false`.

`IRMapGet` ≅ `MemoryLoad`: **map-injective** (a pure read leaves the map
unchanged → no map delta) but its SSA `dest` write is **non-injective**
on a loop re-definition (the cross-iteration crux shared with `Define` /
`MemoryLoad`, ADR 0012). So `is_injective = false`, there is NO
`predelta_payload` / NamedTuple inverse, and the `inverse(::IRMapGet, s,
prev)` catch-all RAISES descriptively — reversed ONLY by L3
checkpoint-replay (ADR 0008 Decision 2; ADR 0008 Finding 4 "the
*reversal* follows the MemoryLoad L3 pattern").

# The missing-sentinel trap (shared with `MemoryStore`, ADR 0008)

`Base.:(==)(::IState, ::IState)` compares `a.revmap == b.revmap` by Dict
CONTENT, so `{k=>0}` is NOT equal to the empty `{}`. If `IRMapInsert`'s
inverse wrote a captured value back into a key that was ABSENT before the
insert, it would leave a phantom `{k=>0}` and break round-trip equality.
`IRMapInsert` therefore captures `prior = haskey(s.revmap,k) ?
s.revmap[k] : missing` and its inverse, on `prior === missing`,
`delete!`s the key rather than writing it back — the SAME trap, and the
SAME `delete!`-on-absent fix, that `MemoryStore.inverse`'s `was_present`
branch documents (`memory_floor.jl` "ABSENT-CELL is load-bearing"). ADR
0008 Finding 4 specifies exactly this `prior === missing` encoding for
insert.

# `IRMapDelete`'s missing-sentinel is a senior-grade hardening over ADR Finding 4

ADR 0008 Finding 4 gives `IRMapDelete`'s payload as a bare `(key,
old_val = M[k])`, assuming the key is PRESENT. That is unsound for a
`delete!` of an ABSENT key: `delete!(d, k)` on an absent key is a no-op,
so its inverse must ALSO be a no-op — but a bare `old_val` payload would
spuriously re-insert `{k => old_val}` (or fail to capture anything to
re-insert). We harden the payload to the SAME `(key, prior =
haskey ? M[k] : missing)` shape as `IRMapInsert`: on reverse, `prior ===
missing` (the key was absent, the forward `delete!` was a no-op) does
NOTHING to the map; otherwise it restores `s.revmap[key] = prior`. This
deviation from Finding 4 is deliberate and documented per Rule 9 (no
"good enough" corners): the absent-key delete is a real edge a hand-built
program can hit, and silently re-inserting would corrupt the round-trip.

# `IRMapGet`'s absent-key forward semantics — fail loud, NOT zero-init

DESIGN CALL (Rule 9; ADR 0008 Finding 4). `MemoryLoad` zero-inits an
absent heap cell (`get(s.memory, addr, 0)`) because an LLVM `alloca`-
then-`load`-uninitialised genuinely reads `0`. A `Dict` `getindex` of an
absent key is NOT zero-initialised memory — Julia raises a `KeyError`.
Silently returning `0` would (a) diverge from the `fdict` oracle (a real
`Dict` would throw, not return 0) and (b) mask malformed IR. So
`IRMapGet.forward` fails LOUD (Rule 1) on a genuinely-absent key with a
descriptive `error`, rather than inventing a zero. ADR 0008 Finding 4's
"reversal follows the MemoryLoad L3 pattern" is about
is_injective / inverse-raises / L3 — NOT about absent-key forward
semantics, which this op decides here.

# `is_l2_capable` (the L2 vs L3 routing trait)

`IRMapInsert` / `IRMapDelete` are marked `is_l2_capable = true` in
`src/history/delta.jl` (alongside `MemoryStore` / `DynAlloca`) because
they have a working L2 path: a non-`nothing` `predelta_payload` + a
matching NamedTuple `inverse`. `IRMapGet` keeps the default `false` (no
L2 path; L3-only, like `MemoryLoad`).

# pc symmetry

`forward` sets `s.pc += 1`; the NamedTuple `inverse`s set `s.pc -= 1`,
the per-step ±1 symmetry every L2 inverse follows
(`src/ir/arithmetic_assignment.jl`, `src/ir/memory_floor.jl`). The
raising catch-all `inverse`s never touch `pc`.

# Operand kinds

`key` / `value` are `Union{Symbol,Int64}` (an SSA ref looked up in
`active_locals(s)`, or an `Int64` literal), resolved via the reused `_resolve`
(Law 2; `src/ir/arithmetic_assignment.jl`) — exactly the
`MemoryStore.value` operand convention.

# Reuse (Law 2)

Reuse: the **Bennett-1973 history tape** applied to heap mutation
(`references/foundational/bennett-1973-logical-reversibility.pdf` §3
(p. 528); PRD Case B l.628–629); the **Enzyme min-cut** "cache the
minimum needed to invert" principle for the `(key, prior)` payload
(`references/ad-and-checkpointing/enzyme-2020.pdf`; ported in ADR 0002);
the **`MemoryStore` / `MemoryLoad` L3-floor template**
(`src/ir/memory_floor.jl`) for op structure; `_resolve`
(`src/ir/arithmetic_assignment.jl`). Why not reuse further: declined
Bennett.jl's CF / persistent maps (`../Bennett.jl/src/persistent/`) — they
are the circuit backend's lowering target, not a VM runtime type, and an
owned `Dict` + history tape is simpler (ADR 0008 Finding 5 / Decision 3).

# Ref

  * `docs/adr/0008-dict-reversibility.md` Decisions 1–6, Findings 3–5.
  * `bennettvm_prd.md` (PRD v4) §3.6.2 Case B (l.621–634).
  * `src/ir/memory_floor.jl` — `MemoryStore` (the L2 `predelta_payload`
    template + missing-sentinel trap) / `MemoryLoad` (the L3-only template).
  * `src/ir/arithmetic_assignment.jl` — `_resolve`, reused (Law 2).
  * `src/ir/IState.jl` — `revmap::Dict{Int64,Int64}` field + the
    `==`/`hash` participation that makes L3 reverse the map.
  * `src/history/delta.jl` — `predelta_payload` default + `is_l2_capable`.
  * `src/history/Injective.jl` — where the three `is_injective = false`
    pins are wired.
  * CLAUDE.md Rule 1 (fail loud), Rule 2 (reuse), Rule 9 (senior bar),
    Rule 11 (literate).
"""

# RevMap is `Dict{Int64,Int64}` exactly like `memory` (ADR 0008 Decision
# 3 / Finding 5). `IState.revmap` is declared as `Dict{Int64,Int64}` (the
# const is unavailable at IState definition time, since this file is
# included after `IState.jl`); the alias names the same concrete type.
const RevMap = Dict{Int64,Int64}

# --- IRMapInsert: revmap[key] := value (overwrite-or-create, non-injective) ---

struct IRMapInsert <: Instruction
    key::Union{Symbol,Int64}      # SSA ref or literal → resolved to an Int64 key
    value::Union{Symbol,Int64}    # SSA ref or literal → resolved to an Int64 value

    # No SSA single-assignment check: IRMapInsert produces NO SSA value
    # (it mutates the map register; void, like MemoryStore), so there is
    # no `dest` to collide with `key`/`value`.
    IRMapInsert(key::Union{Symbol,Int64}, value::Union{Symbol,Int64}) =
        new(key, value)
end

# --- IRMapDelete: delete!(revmap, key) (non-injective) ---

struct IRMapDelete <: Instruction
    key::Union{Symbol,Int64}      # SSA ref or literal → resolved to an Int64 key

    IRMapDelete(key::Union{Symbol,Int64}) = new(key)
end

# --- IRMapGet: dest := revmap[key] (read into a fresh local, non-injective dest) ---

struct IRMapGet <: Instruction
    dest::Symbol                  # SSA name created — receives the map value
    key::Union{Symbol,Int64}      # SSA ref or literal → resolved to an Int64 key

    function IRMapGet(dest::Symbol, key::Union{Symbol,Int64})
        # SSA single-assignment guard, mirroring MemoryLoad: an SSA name
        # cannot be both defined (dest) and read as the key by the same
        # instruction (RSSA: every name has exactly one defining instruction).
        dest === key &&
            error("IRMapGet: SSA single-assignment violation — dest ",
                  "$(dest) also names the key operand; an SSA name cannot ",
                  "be both defined and read as the key by the same ",
                  "instruction (RSSA: every name has exactly one defining ",
                  "instruction).")
        return new(dest, key)
    end
end

"""
    forward(instr::IRMapInsert, s::IState) -> IState

Execute `revmap[key] := value` in-place. Resolves both operands via the
reused `_resolve` (Law 2), writes the binding, and bumps `pc`. The prior
binding (if any) is **overwritten** without error; recovering it is the
L2 delta's job (`predelta_payload` below). Captures NOTHING in `forward`
itself — the pre-state capture is the separate `predelta_payload` hook,
called by `step!` BEFORE this runs (the `MemoryStore` pattern).
"""
function forward(instr::IRMapInsert, s::IState)::IState
    k = _resolve(instr.key, s)
    v = _resolve(instr.value, s)
    s.revmap[k] = v
    s.pc += 1
    return s
end

"""
    forward(instr::IRMapDelete, s::IState) -> IState

Execute `delete!(revmap, key)` in-place. A `delete!` of an absent key is
a Julia no-op (NOT an error) — the inverse must mirror that (see
`predelta_payload` / the NamedTuple `inverse`). Bumps `pc`.
"""
function forward(instr::IRMapDelete, s::IState)::IState
    k = _resolve(instr.key, s)
    delete!(s.revmap, k)
    s.pc += 1
    return s
end

"""
    forward(instr::IRMapGet, s::IState) -> IState

Execute `dest := revmap[key]` in-place. **Fails loud on an absent key**
(Rule 1; ADR 0008 design call): a `Dict` `getindex` of a missing key is a
`KeyError`, NOT zero-initialised memory, so we do not invent a `0` (which
would diverge from the `fdict` oracle and mask malformed IR). Writes the
value into `active_locals(s)[dest]` (overwriting a prior `dest` value on a loop
re-definition without error — recovering it is the L3 layer's job) and
bumps `pc`.
"""
function forward(instr::IRMapGet, s::IState)::IState
    k = _resolve(instr.key, s)
    haskey(s.revmap, k) ||
        error("IRMapGet: key $(k) absent from revmap (a Dict getindex of ",
              "an absent key is a KeyError, NOT zero-init memory — see ADR ",
              "0008 IRMapGet absent-key design call). dest=$(instr.dest), ",
              "pc=$(s.pc).")
    active_locals(s)[instr.dest] = s.revmap[k]
    s.pc += 1
    return s
end

"""
    predelta_payload(instr::IRMapInsert, s::IState)
        -> @NamedTuple{key::Int64, prior::Union{Int64,Missing}}

PRE-`forward()` L2 capture for `IRMapInsert`. Records the resolved `key`
and the `prior` binding — `s.revmap[key]` if present, else `missing` (the
"key was absent" sentinel; safe because no stored value can be `Missing`
in the `Int64` v1, ADR 0008 Decision 4). The `MemoryStore`
`predelta_payload` template (Law 2).
"""
function predelta_payload(instr::IRMapInsert, s::IState)
    k = _resolve(instr.key, s)
    return (key = k, prior = haskey(s.revmap, k) ? s.revmap[k] : missing)
end

"""
    inverse(instr::IRMapInsert, s::IState, p::NamedTuple) -> IState

L2 reverse of an `IRMapInsert` from the `(key, prior)` payload captured
PRE-`forward()`. If `prior === missing` the key was ABSENT before the
insert → `delete!` it (do NOT write a value back; the missing-sentinel
trap — `{key=>0}` would break round-trip `==`, exactly as `MemoryStore`'s
`was_present` branch documents). Otherwise restore `s.revmap[key] =
prior`. Decrements `pc` (the per-step ±1 symmetry the M7.4 fast-path
relies on). More specific than the raising `prev::Any` catch-all, so the
`unstep!` L2 fast-path dispatches HERE.
"""
function inverse(instr::IRMapInsert, s::IState, p::NamedTuple)::IState
    if p.prior === missing
        delete!(s.revmap, p.key)        # key was ABSENT → delete, NOT {k=>0}
    else
        s.revmap[p.key] = p.prior       # key held a value → restore it
    end
    s.pc -= 1
    return s
end

"""
    predelta_payload(instr::IRMapDelete, s::IState)
        -> @NamedTuple{key::Int64, prior::Union{Int64,Missing}}

PRE-`forward()` L2 capture for `IRMapDelete`. Uses the SAME
missing-sentinel shape as `IRMapInsert` (a senior-grade hardening over
ADR 0008 Finding 4's bare `(key, old_val)`, which assumed presence): a
`delete!` of an ABSENT key is a no-op whose inverse must also be a no-op,
so `prior === missing` records "nothing to restore." See this file's
top-of-module docstring "`IRMapDelete`'s missing-sentinel is a
senior-grade hardening."
"""
function predelta_payload(instr::IRMapDelete, s::IState)
    k = _resolve(instr.key, s)
    return (key = k, prior = haskey(s.revmap, k) ? s.revmap[k] : missing)
end

"""
    inverse(instr::IRMapDelete, s::IState, p::NamedTuple) -> IState

L2 reverse of an `IRMapDelete` from the `(key, prior)` payload. If
`prior === missing` the key was ABSENT (the forward `delete!` was a
no-op) → do NOTHING to the map (re-inserting would corrupt the
round-trip). Otherwise restore the deleted binding `s.revmap[key] =
prior`. Decrements `pc`.
"""
function inverse(instr::IRMapDelete, s::IState, p::NamedTuple)::IState
    if p.prior !== missing
        s.revmap[p.key] = p.prior       # restore the deleted binding
    end                                  # missing → was absent → no-op
    s.pc -= 1
    return s
end

"""
    inverse(instr::IRMapInsert, s::IState, prev) -> IState
    inverse(instr::IRMapDelete, s::IState, prev) -> IState

**Always raise `ErrorException`.** The L1/L2 catch-all for the two
mutating map ops. Their reverse is the L2 NamedTuple `inverse` above
(via the M7.4 `unstep!` fast-path) or, when not L2-marked, the L3
checkpoint-replay layer — never this `prev::Any` method. Reaching it
means `unstep!` tried an L1/L2 path without a `predelta_payload`
NamedTuple, which should not happen. Rule 1: fail loud rather than
silently no-op (which would falsely report a successful reverse while
the overwritten / deleted binding went unrestored).
"""
function inverse(instr::IRMapInsert, s::IState, prev)::IState
    error("IRMapInsert reverse is via the L2 (key, prior) delta fast-path ",
          "(predelta_payload + the NamedTuple inverse) or L3 checkpoint-",
          "replay; the prev::Any path loses the prior binding and is not ",
          "live. Reaching this means unstep! took an L1/L2 path without a ",
          "predelta NamedTuple. State: pc=$(s.pc).")
end

function inverse(instr::IRMapDelete, s::IState, prev)::IState
    error("IRMapDelete reverse is via the L2 (key, prior) delta fast-path ",
          "(predelta_payload + the NamedTuple inverse) or L3 checkpoint-",
          "replay; the prev::Any path cannot restore the deleted binding ",
          "and is not live. Reaching this means unstep! took an L1/L2 path ",
          "without a predelta NamedTuple. State: pc=$(s.pc).")
end

"""
    inverse(instr::IRMapGet, s::IState, prev) -> IState

**Always raises `ErrorException`.** `IRMapGet` is map-injective (a pure
read) but its SSA `dest` write is non-injective on a loop re-definition
(the cross-iteration crux shared with `MemoryLoad` / `Define`), so it has
NO per-instruction L2 inverse and is reversed EXCLUSIVELY via L3
checkpoint-replay (`IState.locals` is in the snapshot and in `==`/`hash`,
so the overwritten prior `dest` value is restored automatically). This
mirrors `MemoryLoad`'s deferred-`inverse` raise (ADR 0008 Decision 2 /
Finding 4: "the reversal follows the MemoryLoad L3 pattern"). Rule 1:
fail loud rather than silently no-op.
"""
function inverse(instr::IRMapGet, s::IState, prev)::IState
    error("IRMapGet reverse is via L3 checkpoint-replay — its SSA dest ",
          "write is non-injective on a loop re-definition (the MemoryLoad ",
          "pattern, ADR 0008 Finding 4), so there is no per-instruction L2 ",
          "inverse. Reaching this means unstep! tried an L1/L2 path on an ",
          "IRMapGet, which should not happen with empty must_cache_set. ",
          "dest=$(instr.dest), pc=$(s.pc).")
end

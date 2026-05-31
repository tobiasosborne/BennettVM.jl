# BennettVM.jl

> A reversible-VM backend for [Bennett.jl][bennett], built on 50 years of
> reversible-computing literature. **Phase 1: the throwaway spike has shipped
> its retrospective. Phase 2 (production) is gated on PRD v4.**

[bennett]: ../Bennett.jl

## What this is

[Bennett.jl][bennett] compiles plain Julia functions to *fixed reversible
circuits* — the right artifact for a quantum oracle, but it cannot represent
unbounded loops or runtime-sized memory. BennettVM is the second lowering
target (`target = :reversible_vm`) that closes that gap: a reversible
interpreter for terminating computations of statically-unknown length.

```
                 ┌──────────── target=:circuit ──────►  fixed permutation circuit
Julia source ──► │ Bennett.jl frontend (LLVM IR, lowering, gates)
                 └──────────── target=:reversible_vm ─►  BennettVM  ◄── you are here
```

The two backends are semantically distinct (see [`bennettvm_prd.md`][prd] §3.7).

[prd]: ./bennettvm_prd.md

## Project status

| Phase | State | Artifact |
|---|---|---|
| Pre-Phase-0 | ✅ Done | `references/` (47+ paper PDFs incl. Bennett 1973 + 5 source clones), `CLAUDE.md`, `PHASE.md`, `references/manifest/SOURCES.md` |
| Phase 0 (throwaway spike) | ✅ Done | `spike/` (789/789 tests, tagged `spike-0-archived`, chmod -w) |
| Phase 0 retrospective | ✅ Done | `spike/RETROSPECTIVE.md` (264 LOC, 9 questions answered) |
| Phase 1 (PRD v4 authoring) | ✅ Done 2026-05-25 | `bennettvm_prd.md` (v4, 1223 LOC); v3 archived at `docs/prd/bennettvm_prd_v3.md` |
| Phase 2 (production) | 🟢 Open | First milestone M0 + gating M5 (RC3 `rvm` pre-read); see v4 §Part IX |

See [`PHASE.md`](./PHASE.md) for the current phase and gates.

## The two-phase methodology

Per [`bennettvm_prd.md`][prd] (PRD v3):

- **Phase 0** — *Deliberately throwaway* spike. One Claude Code session,
  Bennett-1973 trace VM, eight bytecodes, `Int64` only, countdown program,
  full-state history. Goal: surface concrete decisions the PRD cannot
  anticipate.
- **Phase 1** — Archive the spike. Write [`spike/RETROSPECTIVE.md`][retro].
  Author PRD v4 from the retrospective.
- **Phase 2** — Production VM. RSSA-style IR (Mogensen 2016),
  Pendulum/BobISA-style ISA, Enzyme-style min-cut history selection,
  Bennett-1989 pebble-game lowering for quantum oracle synthesis, optional
  Unqomp/Reqomp/Qurts integration. Lean 4 formalization of *abstract VM
  semantics only*.

[retro]: ./spike/RETROSPECTIVE.md

## Read order (for new agents and humans)

1. [`bennettvm_prd.md`][prd] — PRD v3, the controlling document.
2. [`CLAUDE.md`](./CLAUDE.md) — Laws, Rules, Phase-0 gating, hallucination
   callouts.
3. [`PHASE.md`](./PHASE.md) — current phase and what's blocked.
4. [`spike/RETROSPECTIVE.md`][retro] — the actual Phase-0 deliverable.
5. [`references/manifest/SOURCES.md`](./references/manifest/SOURCES.md) —
   what literature is on disk + acquisition status.
6. [`WORKLOG.md`](./WORKLOG.md) and [`HANDOFF.md`](./HANDOFF.md) — session
   history + next-agent brief.

## What the spike actually does

The spike implements the Bennett-1973 three-tape reversible TM construction
(Stage 1 only), narrowed to:

- `Int64` and `Bool` scalars, no fixed-point, no FP.
- Eight bytecodes: `Const`, `Move`, `UnaryOp`, `BinaryOp`, `Jump`, `JumpIf`,
  `Return`, `Halt`.
- Full-state snapshot history (the deliberately-wasteful Phase-0 mechanism).
- `step!` / `unstep!` / `run!` / `unrun!`.

Smoke demonstration — countdown(3) forward, then `unrun!` to initial state:

```julia
using BennettVMSpike

prog = Program([
    Const(:n, 3),                            # locals[:n] = 3
    Const(:zero, 0),
    BinaryOp(:gt, :cond, :n, :zero),         # cond = (n > 0)
    JumpIf(:cond, 6),                        # if cond, jump to loop body
    Halt(),                                  # else terminate
    Const(:one, 1),
    BinaryOp(:sub, :n, :n, :one),            # n -= 1
    Jump(3),                                 # back to test
])

s = initial_state(prog)
s0 = deepcopy(s.current)

run!(s, prog; max_steps=100)
@assert is_halted(s)
@assert result(s)[:n] == 0

unrun!(s, prog)
@assert s.current == s0
@assert isempty(s.history)
```

### Is it Turing-complete?

**No** — each program has a finite register namespace and finite-precision
`Int64` cells, so the per-program state space is bounded. Control flow IS
Turing-equivalent (`Jump` + `JumpIf` + arithmetic), but state is not.

That's intentional and scoped: PRD §5.2 explicitly excludes RAM, arrays, and
arbitrary-precision arithmetic from Phase 0. Phase 2 adds them via Pendulum-
style memory-as-exchange primitives and gets actual Turing completeness.

## File map

```
bennettvm_prd.md          # PRD v3 — controlling document
CLAUDE.md / AGENTS.md     # rules of engagement for agents
PHASE.md                  # current phase + gates
README.md                 # this file
WORKLOG.md                # session-by-session log
HANDOFF.md                # what next agent needs
BENNETT_JL_PIN.md         # Bennett.jl SHA pin (5731cec)

references/               # 43 paper PDFs + 5 source clones — untracked by git
  manifest/SOURCES.md     #   canonical inventory with SHA256s
  foundational/           #   Bennett 1989, Knill 1995, BTV 2001, …
  reversible-languages/   #   Yokoyama-Glück 2007, Janus, RFUN, …
  reversible-ir/          #   Mogensen RSSA 2016, Deworetzki 2021–2024, …
  reversible-isa/         #   Vieri 1995/1999, BobISA 2012, Frank 1999, …
  quantum-uncomputation/  #   Unqomp, Reqomp, Qurts, Meuli, Spooky, …
  reverse-debugging/      #   rr (Mozilla) papers
  ad-and-checkpointing/   #   Enzyme 2020, Enzyme-GPU 2021
  implementations/        #   RC3, TOPPS-janus, jana, janus-vesta, evincaro/Janus

spike/                    # THROWAWAY, tagged spike-0-archived, chmod -w
  Project.toml            #   BennettVMSpike, private=true
  src/                    #   Types.jl, Interpreter.jl, Instructions.jl, BennettVMSpike.jl
  test/                   #   789/789 tests, mutation-proof verified
  RETROSPECTIVE.md        #   THE Phase-0 deliverable

scripts/spike-templates/  # the 4 sequential sub-agent prompts (interpreter/
                          # instructions/tests/reviewer) + RETROSPECTIVE.md skeleton

.beads/                   # beads issue tracker (Dolt-backed)
src/, test/               # Phase-2 trees — empty until PRD v4 lands
```

## Notable findings from the spike

1. **Julia's default `==` does identity-compare on `Dict` fields.** `Base.==` and
   `Base.hash` overrides on `IState` are MANDATORY — without them round-trip
   equality silently never holds. Real footgun.
2. **`step!` must call `forward()` BEFORE pushing the history snapshot**, not
   after. Original ordering corrupted history on `forward()` exception.
3. **The aggregate round-trip test is not mutation-proof for middle-instruction
   inverses** — the leading `Const` inverse restores `s.current` regardless of
   corruption left by mid-stream inverses. A per-step inverse test pattern
   (snapshot every pre-step `IState`, then `unstep!` and assert per-step
   equality) catches this; the spike's test suite includes it. Phase 2 must
   keep this pattern.
4. **PRD v3 errata logged** (`references/manifest/SOURCES.md §Citation-errata`):
   the BobISA citation should be **Thomsen-Axelsen-Glück 2012** (RC 2012), not
   "Axelsen-Yokoyama 2011 LATA". The Mogensen RIL "paper" is a ghost — RIL is
   introduced inside Mogensen 2015 LNCS 9138.
5. **Law 2 cross-check**: none of RC3, TOPPS-janus, jana, janus-vesta, or
   evincarofautumn-janus has a history-tape + round-trip property test in the
   BennettVM sense. RC3 does compiler-level RSSA reversal (no runtime trace);
   TOPPS-janus does syntactic `invertStmt` (the Yokoyama-Glück 2007 "no history
   for reversible source" lesson). BennettVM IS distinct, not a rebuild.

Full retrospective: [`spike/RETROSPECTIVE.md`][retro].

## Issue tracking

Beads (`bd`) with Dolt backend, embedded in `.beads/`. Open issues:

```bash
bd ready
```

The current open issue is `bennettvm-pb2` — PRD v4 epic.

## Reproducing the spike

```bash
cd spike
julia --project=. -e 'using Pkg; Pkg.test()'      # 789/789 should pass
```

If `chmod -w` on `spike/` is in your way (e.g., to re-run a probe), restore
write permissions with `chmod -R u+w spike/`. Do NOT modify the spike;
`spike-0-archived` is the canonical artifact.

## Acknowledgements

Builds on five decades of reversible-computing literature — see
[`bennettvm_prd.md`][prd] Part II for the full reading list. The closest
existing analogue to this project is [RC3 (THM)][rc3] (Janus toolchain),
which BennettVM does not rebuild but learns from.

[rc3]: https://git.thm.de/thm-rc3/release

Phase 0 orchestrated by Claude Code (Opus 4.7 for code, Sonnet for review).
Eleven sequential sub-agent passes; the throughline is captured in
[`WORKLOG.md`](./WORKLOG.md).

## License

MIT (see [`LICENSE`](./LICENSE) — to be added). Inherits dependency licenses
from referenced literature and tools (Bennett.jl, Enzyme, RC3, the cited
papers).

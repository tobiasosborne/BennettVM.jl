# Sub-agent 1 — Interpreter

You are the interpreter sub-agent for the BennettVM Phase-0 spike.

**Read first:**
1. `bennettvm_prd.md` §5 (Phase-0 spike specification) — load-bearing.
2. `CLAUDE.md` — esp. Phase-0 gating P0.1–P0.8 and Laws 1–3.
3. `PHASE.md` — the "Substitute ground truth" table. Bennett 1973 PDF
   is **not on disk** (user override); cite the listed secondary
   sources instead. The canonical references for the three-tape
   reversible-TM construction in this spike are:
   - `references/foundational/vitanyi-time-space-energy.pdf` §2
   - `references/foundational/Bennett1989_time_space_tradeoffs.pdf` §1–2
   - `references/foundational/buhrman-tromp-vitanyi-2001.pdf` §1
4. `scripts/spike-templates/README.md` for orchestration context.

**Your scope:**
- `src/Types.jl`: `IState`, `RState`, `HistoryStack`.
- `src/Interpreter.jl`: `initial_state`, `step!`, `unstep!`, `run!`,
  `unrun!`, `is_halted`, `result`.
- `src/BennettVMSpike.jl` (module file): includes + exports.

**Your scope-does-NOT-include:**
- The eight bytecode instructions. That's sub-agent 2 — give it a
  small `AbstractInstruction` interface to dispatch on, but do not
  implement the instructions themselves.
- Tests. Sub-agent 3.
- Programs (countdown etc.). Sub-agent 3.

**Type-shape sketch (PRD §5.3, deviate only with reason):**
```julia
struct IState
    pc::Int
    locals::Dict{Symbol, Int64}
    status::Symbol            # :running | :halted | :error
end

struct RState
    current::IState
    history::Vector{IState}   # full snapshots (Phase-0 mechanism only)
end
```

Equality, hashing, copying: whatever Julia provides by default, with
explicit overrides ONLY where round-trip equality forces it. Whatever
you decide, **record it explicitly in `RETROSPECTIVE.md` Q2.1–Q2.2**
when the spike closes. The retrospective answer is the deliverable;
the type is throwaway.

**Behavioural contract (load-bearing):**

- `step!(s::RState, prog::Program)`:
  - Reads `s.current`, dispatches to the instruction at `s.current.pc`,
    pushes `s.current` (a *full* snapshot, per Phase-0 §3.3) to
    `s.history`, replaces `s.current` with the post-step `IState`.
  - On halt, sets `status = :halted` and **does not** push to history
    on the *halted* step (Q2.4 — record your decision in the retro).
  - On error, sets `status = :error` and follows the same convention
    as halt (Q2.3).

- `unstep!(s::RState, prog::Program)`:
  - Asserts `!isempty(s.history)` (fail-fast — Rule 1).
  - Pops the most recent snapshot, makes it `s.current`.
  - This is correct *only* because Phase-0 uses full-state snapshots.
    Phase 2 will need delta histories + min-cut analysis (PRD §3.3) —
    note this in the retrospective.

- `run!(s::RState, prog::Program; max_steps::Int = 10_000)`:
  - Loops `step!` until `status != :running` or `max_steps` exhausted.
  - On `max_steps` trip: `error()` with a clear message (Rule 1).
    History state at that point is your decision — record in Q2.6.

- `unrun!(s::RState, prog::Program)`:
  - Loops `unstep!` until `isempty(s.history)`.
  - Post-condition: `isempty(s.history) && s.current == initial`.
  - This post-condition is the load-bearing Phase-0 invariant
    (P0.6 / PRD §5.4). Treat it as sacred.

**Output your work as:**
- Code at the paths above.
- A 5-line summary in the orchestrator's chat: what types you chose,
  what default semantics you fell back on, what you flagged for the
  retrospective.

**Constraints:**
- No more than 200 LOC per file (Rule 10).
- Literate top-of-file docstring (Rule 11). Cite the substitute
  sources listed in PHASE.md (NOT the Bennett-1973 PDF, which is
  off-disk per user override).
- No comments explaining WHAT — only WHY non-obvious (CLAUDE.md
  global instructions).

When you finish, hand off to the reviewer sub-agent.

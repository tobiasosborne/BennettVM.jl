# Sub-agent 2 — Instruction set

You are the instruction-set sub-agent for the BennettVM Phase-0 spike.

**Read first:**
1. `bennettvm_prd.md` §5.1 (eight instructions) and §5.3 (API).
2. `CLAUDE.md` — esp. Laws 1–3, Rules 1, 4, 11 (literate code),
   Phase-0 gating P0.4 (do not add a ninth instruction).
3. `PHASE.md` substitute-ground-truth table — Bennett 1973 PDF is
   off-disk; verify each instruction's reversibility against the
   secondary descriptions in:
   - `references/foundational/vitanyi-time-space-energy.pdf` §2
   - `references/foundational/Bennett1989_time_space_tradeoffs.pdf` §1–2
   - `references/foundational/buhrman-tromp-vitanyi-2001.pdf` §1
4. The interpreter sub-agent's output (`src/Types.jl`,
   `src/Interpreter.jl`) — your instructions plug into its
   `AbstractInstruction` interface.

**Your scope:**
- `src/Instructions.jl`: the eight bytecode instructions and their
  forward + inverse semantics:
  1. `Const(reg::Symbol, val::Int64)` — write `val` to `reg`. Inverse
     requires recording the previous value (push to history). Or
     deciding `Const` is only valid when `reg` is fresh — make a call,
     log in retro Q2.
  2. `Move(dst::Symbol, src::Symbol)` — `dst ← src`, optionally with
     `src` cleared (Janus-style `<=>` swap) or not (cf. PRD §3.2's
     Pendulum exchange rule, which Phase 2 will adopt). For Phase 0,
     `Move` with full-state history is fine — just be clear about
     semantics.
  3. `UnaryOp(op::Symbol, dst::Symbol, src::Symbol)` — `dst ←
     op(src)`. Supported ops: `:neg`, `:not` for `Bool`-typed regs.
     Inverse: re-apply `op` (involutory) OR push old `dst` — pick
     and document.
  4. `BinaryOp(op::Symbol, dst::Symbol, a::Symbol, b::Symbol)` — `dst
     ← op(a, b)`. Supported ops: `:add`, `:sub`, `:mul`, `:and`,
     `:or`, `:xor`, `:lt`, `:gt`, `:eq`. Most lose information; the
     inverse pushes the previous value of `dst`.
  5. `Jump(target::Int)` — `pc ← target`. Reversible because the
     predecessor pc is `current.pc` from before the jump — recoverable
     from history (Phase 0) or from a BobISA-style source label
     encoding (Phase 2 — out of scope here, but note in retro Q5).
  6. `JumpIf(cond::Symbol, target::Int)` — `if locals[cond] then pc
     ← target`. Same reversibility argument as `Jump`.
  7. `Return` — `status ← :halted`, `pc ← -1` (or any sentinel).
     `unstep!` on a return must restore the pre-return pc.
  8. `Halt` — like `Return` but at the program counter rather than a
     subroutine boundary. The spike has no subroutines, so functionally
     `Return` and `Halt` may collapse — if they do, document why and
     consider whether 7 instructions would have sufficed (retro Q1).

**Your scope-does-NOT-include:**
- The interpreter loop. Sub-agent 1 owns that.
- Tests. Sub-agent 3.
- Any ninth instruction. P0.4 is a hard rule.
- Fixed-point, FP, RAM, arrays, oracle. PRD §5.2 — all out of scope.
- Q-format reals. The spike is `Int64` + `Bool` only.

**Interface contract (negotiate with sub-agent 1 if needed):**

Each instruction exposes:
```julia
forward(instr, s::IState) -> IState
inverse(instr, s::IState, prev::IState) -> IState
```

`prev` is the snapshot the interpreter pushed before `forward`. Most
inverses just `return prev` for Phase-0 (full-state snapshots make
this trivial). The reason this interface exists is to keep the API
shape compatible with Phase 2's delta-history mechanism (where
`prev` will be a delta, not a snapshot) without locking us in.

**Reversibility check (per instruction, before committing):**
- Open the substitute sources in PHASE.md — Vitanyi CF'05 §2 has the
  cleanest restatement of Bennett's three-tape mechanics; BTV 2001 §1
  is the formal version.
- For each instruction: which "tape" entry would record this step's
  history in Bennett's construction? Verify your `prev` carries the
  same information.

**Constraints:**
- ≤ 200 LOC (Rule 10). The eight instructions are small; this should
  be comfortable.
- Literate top-of-file docstring citing the PHASE.md substitute
  sources (NOT Bennett 1973 directly — it is off-disk per user
  override).
- No silent fallbacks on unsupported ops (Rule 1) — `error()` with
  the offending op name.

**Output:**
- `src/Instructions.jl`.
- Updated `src/BennettVMSpike.jl` exports.
- A 5-line summary: which instructions collapsed, which had
  surprising inverse semantics, what got flagged for retro.

When done, hand off to the reviewer sub-agent.

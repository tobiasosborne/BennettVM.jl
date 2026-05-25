# Phase-2 Implementation Plan — BennettVM.jl

> **Granular impl plan for the Phase-2 production VM, derived from PRD v4
> §Part IX and §Part VI.** Each step is 50–200 LOC, atomic, individually
> testable. Each step is filed as a bead with chained dependencies. The
> beads/bd-ID assignments are made by the filing subagents and recorded in
> a table at the end of this document once filed.

**Total: ~95 chained steps across 17 milestones.**

The plan respects PRD v4's three commandments:

1. **Inherit, don't reinvent (Law 2).** Bennett.jl ships ~38 LLVM opcodes,
   ~30-function SoftFloat library, a persistent-tree heap, a complete
   `ParsedIR` extractor. BennettVM consumes all of these. The only Phase-2
   "from scratch" code is what closes the four motivating-case gaps (Dict,
   dynamic-N, nested loops, unbounded while) and the IR-/history-/pebble-game
   layer above `ParsedIR`.
2. **Maximum LLVM opcode coverage is the north-star** (§3.6.1). A Julia
   function that compiles for `target=:circuit` MUST also compile for
   `target=:reversible_vm`.
3. **The four motivating cases are the user-facing value prop** (§3.6.2 +
   §6 SC9). `fdict`, `frtN`, `matrix_sum`, `collatz_steps` MUST round-trip
   under the VM target; if SC9 fails, BennettVM has no reason to exist.

---

## Milestone DAG (deps overview)

```
M5 (RC3 pre-read; gates everything)
  └─ M0 (Bennett.jl handoff smoke)
       └─ M2 (IR foundation: 18 steps)
            ├─ M3 (forward-only interpreter)
            │    ├─ M4 (history L3: checkpoints)
            │    │    └─ M6 (history L1: injective no-log)
            │    │         └─ M7 (history L2: delta min-cut)
            │    │              └─ M8 (per-step inverse + property test)
            │    ├─ M9 (pebble-game lowering)
            │    └─ M_FP (FP inheritance + fpext/fptrunc/frem gaps)
            ├─ M10 (OutputRef + non-aliasing)
            ├─ M_OPCODE (opcode coverage audit + gap fixes)
            ├─ M_DICT (Dict-as-reversible-map) [needs M7]
            ├─ M_DYN  (dynamic-size memory)    [needs M7]
            └─ M_NESTED (nested loops)          [needs M3]

M1 (cost measurement) — independent of M5/M0; can run in parallel

M11 (Lean baseline: theorems 1–3) [needs M3 — semantics stable]
  └─ M12 (Lean output channel + pebble correctness)

M13 (Bennett.jl target=:reversible_vm dispatch arm; USER APPROVAL REQUIRED)
     [needs M_DICT, M_DYN, M_NESTED, M_FP — i.e. the four motivating cases live]
```

---

## Conventions

- Each step has: **title**, **scope** (1–2 sentence summary), **LOC estimate**,
  **deps** (within milestone), **exit criteria**, **key files** touched.
- Where a step's exit criterion is a test, the test MUST pass for the bead
  to close.
- All beads have priority `P1` unless tagged P0 (motivating-case work) or
  P2 (Lean / Bennett.jl-integration).
- Filing subagents create the beads with `bd create --title=... --description=... --type=task --priority=N`
  and wire deps with `bd dep add <next> <prev>`. Cross-milestone deps are
  wired in a final pass.

---

## M5 — RC3 `rvm` pre-read (3 steps, ~250 LOC of ADR/notes)

**Goal:** Read the canonical RSSA reference implementation before any
Phase-2 IR code. PRD v4 §3.1 + SC6.

- **M5.1** Build `rc3` + `rvm` from `references/implementations/RC3/`.
  Document Java toolchain version (likely OpenJDK 17+), Maven invocation,
  any build flags. Capture build output in `docs/adr/0001-rc3-rvm-smoke.md`
  §Build. ~80 LOC ADR.
- **M5.2** Run a sample RSSA program (suggest `programs/rssa/vm/factorial.rssa`)
  through `rvm` in both forward and backward direction. Record observations
  about: how `rvm` dispatches conditional entry vs exit, how the dual-address
  label table is populated, how `reverseDirection()` works without unwinding
  history. ADR §Observations. ~120 LOC ADR.
- **M5.3** Map RC3's 12 concrete instruction subclasses to Phase-2 Julia
  naming + signature sketch (text only, no Julia code yet). Add to ADR
  §Mapping table. ~80 LOC ADR. **Exit:** `docs/adr/0001-rc3-rvm-smoke.md`
  committed.

---

## M0 — Bennett.jl handoff smoke (4 steps, ~330 LOC)

**Goal:** Confirm Bennett.jl `ParsedIR` ingest works end-to-end. PRD v4
§3.7 Handoff A + §6 SC1. Gated by M5.

- **M0.1** `Project.toml` at repo root. Name `BennettVM`, julia 1.10+,
  `[deps] Bennett = <pinned 5731cec>`, `[extras] Test`. `src/BennettVM.jl`
  module skeleton: empty exports, top-of-file literate docstring naming
  the four motivating cases. ~60 LOC.
- **M0.2** Stub `VMProgram` struct (empty for now — placeholder for M2's
  full struct). Stub `lower_vm(parsed::Bennett.ParsedIR; opts=nothing) ::
  VMProgram` that returns an empty `VMProgram` and prints a digest of the
  input (block count, instruction count, arg widths, return widths). ~80
  LOC + literate docstring citing v4 §3.7.
- **M0.3** `test/runtests.jl` + `test/test_handoff_smoke.jl`: import
  Bennett, extract `ParsedIR` for `collatz_steps(::Int8)` from
  `Bennett.jl/test/test_y986_loop_header_dispatch.jl:129`, call `lower_vm`,
  assert non-null `VMProgram` result. ~120 LOC.
- **M0.4** Write `docs/adr/0000-handoff-smoke.md` capturing: the
  `ParsedIR` digest output from M0.3, the Bennett.jl pin SHA used
  (`5731cec`), any surprises about the actual `ParsedIR` shape vs the v4
  §3.7 assumptions. ~80 LOC ADR. **Exit:** `Pkg.test()` passes, ADR
  committed.

---

## M2 — IR foundation (18 steps, ~1700 LOC)

**Goal:** Define the Phase-2 RSSA IR taxonomy structurally isomorphic to
RC3's 12 concrete subclasses (PRD v4 §3.1). All instruction types defined,
hand-built `VMProgram` round-trips through `.reversed()`. Gated by M0.

- **M2.1** Define `IState`: `pc::Int`, `locals::Dict{Symbol,Int64}`,
  `status::Symbol`. Mutable. Top-of-file docstring citing Mogensen 2016
  §3 + spike RETROSPECTIVE Q1. **MUST be `mutable struct`**. ~60 LOC.
- **M2.2** Implement `Base.==(::IState, ::IState)` and `Base.hash(::IState, ::UInt)`
  with structural dict equality. Cite spike retrospective Q2.1 + PRD v4
  §3.10. Test: two equal-content but distinct-dict IStates compare ==. ~60 LOC.
- **M2.3** Define `mutable struct RState`: `current::IState`,
  `history::Vector{AbstractHistoryEntry}`. Define abstract type
  `AbstractHistoryEntry`. Cite v4 §3.9. ~50 LOC.
- **M2.4** Define generic `forward(instr, s::IState)::IState` and
  `inverse(instr, s::IState, prev)::IState` stubs that raise on missing
  method. Define abstract types `Instruction` (sealed by RC3 convention)
  and `RValue`. ~70 LOC.
- **M2.5** Define `BinaryOperator` symbol set matching RC3 + Bennett.jl
  `IRBinOp` ops: `:add, :sub, :mul, :and, :or, :xor, :shl, :lshr, :ashr,
  :udiv, :sdiv, :urem, :srem`. Plus `:fadd, :fsub, :fmul, :fdiv` registered
  as integer-call-routed (these arrive in `ParsedIR` as `IRCall` to
  `soft_f*`, not as `IRBinOp`). ~50 LOC.
- **M2.6** Define `ArithmeticAssignment <: Instruction`: target, source,
  modop (default `:xor`), lhs, op, rhs. Mogensen form `x := y ⊕ (l ⊙ r)`.
  `forward()`/`inverse()` symmetric. Cite RC3 `ArithmeticAssignment.java:115`.
  ~140 LOC.
- **M2.7** Define `SwapInstruction <: Instruction`: target1, target2.
  Self-inverse. ~80 LOC.
- **M2.8** Define `ControlInstruction <: Instruction` abstract type.
  Define `BeginInstruction`/`EndInstruction <: ControlInstruction`
  marker instructions for basic-block entry/exit. ~80 LOC.
- **M2.9** Define `UnconditionalEntry`/`UnconditionalExit <: ControlInstruction`.
  Each carries a single label. ~80 LOC.
- **M2.10** Define `ConditionalEntry`/`ConditionalExit <: ControlInstruction`.
  Each carries two labels + a condition expression. **The φ-on-splits-AND-joins
  is here.** Cite Mogensen 2016 §3 + RC3 `ConditionalEntry.java:23`. ~160 LOC.
- **M2.11** Define `MemoryAssignment <: Instruction`: `M[addr] ⊕= (l ⊙ r)`.
  Forward/inverse symmetric (modop is its own inverse). ~110 LOC.
- **M2.12** Define `MemoryInterchangeInstruction <: Instruction`: Pendulum
  exchange `x := M[y] := z`. Cite Vieri 1995 §4.2.1. ~120 LOC.
- **M2.13** Define `MemorySwapInstruction <: Instruction`: `M[l] ⇔ M[r]`. ~80 LOC.
- **M2.14** Define `CallInstruction <: Instruction`: `(out) := call/uncall
  proc (in)`. Mostly unused at Phase-2 start because Bennett.jl's
  `lower_call!` inlines; placeholder for Phase-2.x cross-procedure. ~120 LOC.
- **M2.15** Define `BasicBlock`: `label::Symbol`,
  `instructions::Vector{Instruction}`, `entry::ControlInstruction`,
  `exit::ControlInstruction`. Add `reversed(::BasicBlock)::BasicBlock`
  per RC3 `BasicBlock.reversed()`. ~150 LOC.
- **M2.16** Define `LabelEntry` (`fwd_address::Int, bwd_address::Int`) and
  `LabelTable` (dict label→entry). RC3 `LabelEntry.java:7` port. ~140 LOC.
- **M2.17** Define `VMProgram`: `blocks::Vector{BasicBlock}`,
  `label_table::LabelTable`, `entry_label::Symbol`. ~80 LOC.
- **M2.18** IR-type tests: construct a hand-built countdown analogue,
  verify the shape, verify `.reversed()` on each block produces inverse
  instructions in reverse order. ~180 LOC.

---

## M3 — Forward-only interpreter (8 steps, ~830 LOC)

**Goal:** A working forward-only interpreter for hand-built `VMProgram`s.
No history yet. PRD v4 §3.9 + §3.11 + §3.16. Gated by M2.

- **M3.1** `initial_state(prog::VMProgram, input)::RState`: validate
  program non-empty (cite spike `Interpreter.jl:119`), set pc to entry
  label's start, initialize locals from input. ~80 LOC.
- **M3.2** `is_halted(s::RState)::Bool` + `result(s::RState)`: result MUST
  error with status name on non-halted (cite spike `Interpreter.jl:138` +
  v4 §3.16). ~60 LOC.
- **M3.3** `step!(s::RState, prog::VMProgram)::RState`: dispatch via
  `forward()` based on current instruction; forward-before-push ordering;
  silent no-op if `status !== :running`. Cite spike Q3 + v4 §3.11. ~120 LOC.
- **M3.4** `run!(s::RState, prog::VMProgram; max_steps=10_000)::RState`:
  while loop, max-steps guard (cite v4 §3.16 — history preserved on trip). ~80 LOC.
- **M3.5** Per-instruction forward methods batch 1: `ArithmeticAssignment`,
  `SwapInstruction`, `MemoryAssignment`. ~150 LOC.
- **M3.6** Per-instruction forward methods batch 2 — control flow:
  `BeginInstruction`, `EndInstruction`, `UnconditionalEntry/Exit`,
  `ConditionalEntry/Exit`. Label-dispatch via `LabelTable`. ~180 LOC.
- **M3.7** Per-instruction forward methods batch 3:
  `MemoryInterchangeInstruction`, `MemorySwapInstruction`,
  `CallInstruction` (stub). ~120 LOC.
- **M3.8** Forward-only countdown test: hand-built `VMProgram` for
  `countdown(5)`, `run!` to halt, result matches reference Julia. ~120 LOC.
  **Exit:** countdown forward test passes.

---

## M4 — History layer 3 (periodic checkpoints, 5 steps, ~480 LOC)

**Goal:** Round-trip via periodic full-state checkpoints + replay (rr
pattern). No delta selection yet. PRD v4 §3.3 layer 3. Gated by M3.

- **M4.1** `CheckpointEntry <: AbstractHistoryEntry`: `snapshot::IState`,
  `step::Int`. ~50 LOC.
- **M4.2** Modify `step!` to push a `CheckpointEntry` every K steps
  (default K=64 per v4 §3.3 placeholder). ~80 LOC.
- **M4.3** `unstep!(s::RState, prog::VMProgram)::RState`: find nearest
  checkpoint ≤ target step, restore, replay forward to target-1. Cite
  rr-style architecture. ~150 LOC.
- **M4.4** `unrun!(s::RState, prog::VMProgram)::RState`: loop `unstep!`
  until history empty + status reset to `:running` at pc 1. Cite Bennett
  1973 stage-3 retrace. ~80 LOC.
- **M4.5** Test: countdown round-trip with checkpoint history (K=4 for
  test reproducibility). Per-step inverse pattern (cite spike
  `test_roundtrip.jl:80–135`). ~120 LOC. **Exit:** round-trip test passes.

---

## M6 — History layer 1 (injective no-log, 4 steps, ~330 LOC)

**Goal:** Suppress history push for injective instructions. PRD v4 §3.2
+ §3.3 layer 1. Gated by M4.

- **M6.1** Define `is_injective(::Type{<:Instruction})::Bool` trait.
  Default `false`. Specialize `true` for `SwapInstruction`, all
  `ControlInstruction` subtypes, `MemoryInterchangeInstruction`,
  `MemorySwapInstruction`, `ArithmeticAssignment` when `modop === :xor`. ~80 LOC.
- **M6.2** Modify `step!` to skip checkpoint/history push for injective
  instructions. ~50 LOC.
- **M6.3** `inverse()` for injective instructions is recomputable without
  history (e.g., `SwapInstruction.inverse(s, _)` = swap again). ~100 LOC.
- **M6.4** Test: a program of all-injective instructions round-trips with
  zero history entries. ~100 LOC. **Exit:** zero-history round-trip passes.

---

## M7 — History layer 2 (delta min-cut, 7 steps, ~930 LOC)

**Goal:** Per-instruction delta payload with min-cut selection per Enzyme.
PRD v4 §3.3 layer 2 + ADR 0002. Gated by M6.

- **M7.1** Write `docs/adr/0002-enzyme-min-cut-mapping.md`: map LLVM IR
  value-dependency graph edges to Phase-2 RSSA dataflow edges. Cite
  Enzyme 2020 §2 "Cache". ~150 LOC ADR.
- **M7.2** `DeltaEntry{T} <: AbstractHistoryEntry`: `instruction::T`,
  `payload::NamedTuple`. Per-instruction payload type via dispatch. ~100 LOC.
- **M7.3** Per-non-injective-instruction `make_delta(instr, s_pre)`
  capturing minimum needed for inverse. For `ArithmeticAssignment` with
  non-`:xor` modop: capture pre-target value. For `IRLoad`-derived: capture
  loaded value if needed. ~180 LOC.
- **M7.4** Modify `unstep!` to dispatch `inverse(instr, s, delta.payload)`
  on `DeltaEntry`. ~80 LOC.
- **M7.5** Stub min-cut analysis pass: liveness over RSSA SSA values to
  identify which writes must be cached. ~200 LOC.
- **M7.6** Integrate min-cut output into delta selection: instructions
  whose dst is recomputable from later values don't push delta. ~120 LOC.
- **M7.7** Test: delta history round-trip; assert peak history bytes
  scale sub-linearly in T for injective-dominated programs. ~100 LOC.
  **Exit:** sub-linear-history round-trip test passes.

---

## M8 — Per-step inverse + property tests (5 steps, ~670 LOC)

**Goal:** Mutation-proof test coverage for every instruction kind +
seeded random property tests with control flow. PRD v4 §3.13 + §3.15.
Gated by M7.

- **M8.1** `test/reference/countdown.jl`: reference irreversible Julia
  function for countdown, co-located with program factory. Cite spike
  pattern. ~80 LOC.
- **M8.2** Per-step inverse test scaffold: snapshot pre-step IStates,
  walk back, assert at each step. ~120 LOC.
- **M8.3** Mutation-proof: per-instruction-kind mutation harness;
  perturb `inverse()` for each kind, confirm RED across the test suite,
  restore. ~180 LOC.
- **M8.4** Seeded random control-flow program generator
  (`MersenneTwister(0xBE171973)`). Generates RSSA with bounded loops,
  conditionals, swap chains. Termination-bounded. ~200 LOC.
- **M8.5** Property test: 100 random programs round-trip. ~120 LOC.
  **Exit:** 100/100 pass; mutation-proof RED reproduced.

---

## M9 — Pebble-game lowering (7 steps, ~1050 LOC)

**Goal:** Bennett-1989 pebble-game pass for the quantum-oracle subset.
PRD v4 §3.4 + SC5. Gated by M3 (semantics) + M_OPCODE (full opcode
coverage so lowering can analyze arbitrary programs).

- **M9.1** Uniform-bound analysis on `VMProgram`: reject programs with
  no static loop bound. Cite `Bennett.jl/src/lowering/driver.jl:79–82`. ~150 LOC.
- **M9.2** Knill 1995 `F(n,S)` recursion. Memoized. ~80 LOC.
- **M9.3** Knill table oracle: `Knill 1995 Tables 1–2` (n=10..100, S=2..20)
  as a fixed test resource at `test/reference/knill_table.jl`. ~100 LOC data.
- **M9.4** Linear-chain pebble scheduler that uses `F(n,S)` to choose
  segment lengths and emit compute/uncompute sequence on a linear program.
  Cite Bennett 1989 Theorem 1. ~200 LOC.
- **M9.5** Meuli 2019 SAT encoding for the DAG case. Z3.jl binding;
  variables `p_{v,i}`, three clause types (initial/final, move,
  cardinality). Cite Meuli 2019 §III. ~200 LOC.
- **M9.6** Emit compute/uncompute as a `VMProgram` transformation. ~150 LOC.
- **M9.7** ISCAS benchmark agreement with Meuli 2019 Table I (52.77%
  qubit reduction target at 2.68× step overhead). ~170 LOC.
  **Exit:** ISCAS benchmark test passes.

---

## M10 — OutputRef + non-aliasing (5 steps, ~510 LOC)

**Goal:** Nominally-typed OutputRef external to RState; static
non-aliasing analysis. PRD v4 §3.5. Gated by M3.

- **M10.1** `OutputRef` nominal type. External to `IState`/`RState`. ~60 LOC.
- **M10.2** Non-aliasing analysis pass (port of RC3
  `AliasingAnalysisPass.java:30`). Forbids RHS=LHS and same-variable-twice
  in calls. ~150 LOC.
- **M10.3** `result(s)` returns `OutputRef`-typed output, not the full
  locals dict. ~80 LOC.
- **M10.4** `run_oracle!(prog, input, ::OutputRef)` API. Sole unrecorded
  write is the OutputRef. ~100 LOC.
- **M10.5** Test: OutputRef survives `unrun!`; static non-aliasing check
  rejects an aliased-output bad program. ~120 LOC. **Exit:** alias check
  test passes.

---

## M_FP — Float64 inheritance + Bennett.jl FP gaps (4 steps, ~430 LOC)

**Goal:** Inherit Bennett.jl's SoftFloat dispatch for Float64; wire the
two missing LLVM-opcode dispatches (`fpext`/`fptrunc`, `frem`). PRD v4
§3.6 + SC10. Gated by M0.

- **M_FP.1** `docs/adr/0011-fp-inheritance.md`: document the
  SoftFloat-dispatch reuse pattern. BennettVM does nothing special for FP
  *by design* — Bennett.jl wraps user functions in UInt64-typed lambdas
  before LLVM IR extraction, so `ParsedIR` arrives integer-only with
  `IRCall` to `soft_f*`. ~100 LOC ADR.
- **M_FP.2** Wire `fpext`/`fptrunc` LLVM-opcode dispatch in BennettVM's
  ingest path (closes Bennett.jl gap; `soft_fpext`/`soft_fptrunc`
  functions exist in `Bennett.jl/src/softfloat/` but the dispatch hook is
  missing in `Bennett.jl/src/extract/instructions.jl`). Replicate the
  dispatch in BennettVM ingest. ~120 LOC.
- **M_FP.3** Wire `frem` LLVM-opcode dispatch. ~80 LOC.
- **M_FP.4** Test: `reversible_compile(x::Float64 -> x*x + 3x + 1, Float64;
  target=:reversible_vm)` round-trips on the same input set Bennett.jl
  uses in `test/test_float_poly.jl`. Bit-for-bit match with Bennett.jl
  circuit target. ~130 LOC. **Exit:** FP round-trip test passes; SC10 met.

---

## M_OPCODE — Maximum opcode coverage audit (4 steps, ~530 LOC)

**Goal:** Verify every Bennett.jl `IRInst` subtype is handled by BennettVM
ingest; mirror the v4 §3.6.1 coverage matrix as a runtime test. Gated by M2.

- **M_OPCODE.1** Audit `BennettVM.lower_vm` against the Bennett.jl
  `IRInst` subtype list (17 types at pin 5731cec). For each: confirm a
  Phase-2 IR construct exists. ~100 LOC.
- **M_OPCODE.2** Implement Phase-2 lowerings for any `IRInst` missed in
  M2/M3 (likely `IRPhi` resolution into RSSA split-φ, `IRSwitch` into a
  cascade of `ConditionalEntry`s, `IRSelect` into MUX-via-CNOT). ~180 LOC.
- **M_OPCODE.3** Test program covering every `IRInst` subtype in a single
  program (synthetic). ~150 LOC.
- **M_OPCODE.4** Coverage matrix doc at `docs/coverage-matrix.md` mirroring
  v4 §3.6.1. ~100 LOC doc. **Exit:** every-IRInst test passes.

---

## M_DICT — Dict-as-reversible-map (Case B, 7 steps, ~970 LOC)

**Goal:** Compile and round-trip `fdict(k, v) = let d = Dict{Int8,Int8}();
d[k] = v; d[k] end`. PRD v4 §3.6.2 Case B + SC9. Gated by M7.

- **M_DICT.1** `docs/adr/0008-dict-reversibility.md`: design — Dict
  reversibility via history-tape capture (NOT persistent tree).
  `setindex!(d, k, v)` pushes `(k, old_v_or_missing)` to delta history;
  `delete!(d, k)` pushes `(k, old_v)`. Cite Bennett 1973 history-tape
  applied to heap mutation. ~150 LOC ADR.
- **M_DICT.2** Define `PersistentDictRef` Phase-2 IR type (live Dict
  reference threaded through RState; not in `IState.locals`). ~100 LOC.
- **M_DICT.3** `setindex!` Phase-2 lowering: capture `(k,
  old_value_or_missing)` to `DeltaEntry`. Inverse: restore. ~150 LOC.
- **M_DICT.4** `getindex` Phase-2 lowering: pure read, injective, no
  history (uses Phase-2 §3.2 injective classification). ~80 LOC.
- **M_DICT.5** `delete!` Phase-2 lowering: capture `(k, old_v)`. Inverse:
  re-insert. ~120 LOC.
- **M_DICT.6** Bennett.jl boundary: intercept the rejection at
  `Bennett.jl/src/extract/heap.jl:313–320` (under `mem=:heap`) and
  `instructions.jl:2106–2110` (under `mem=:auto`, no registered callee).
  In BennettVM ingest, register Dict's `setindex!`/`getindex`/`delete!`
  as known callees, replacing the rejection signpost. ~250 LOC.
- **M_DICT.7** Test: `fdict(Int8(3), Int8(7))` compiles under
  `target=:reversible_vm`, runs forward to result `7`, `unrun!`s to empty
  history. ~120 LOC. **Exit:** SC9 case B met.

---

## M_DYN — Dynamic-size memory (Case A, 6 steps, ~810 LOC)

**Goal:** Compile and round-trip `frtN(n) = let v = Array{Int8}(undef, n);
v[1] = Int8(7); v[1] end` and `push!`-built Vectors. PRD v4 §3.6.2 Case A
+ SC9. Gated by M7.

- **M_DYN.1** `docs/adr/0009-dynamic-size-memory.md`: strategy — inherit
  Bennett.jl's `:persistent_tree` (`Bennett.jl/src/lowering/memory.jl:75–98`)
  for dynamic-N allocation; extend to handle the in-place-mutation case
  via delta history. ~120 LOC ADR.
- **M_DYN.2** BennettVM ingest path: when `IRAlloca.n_elems` is `SSAOperand`,
  route to `_lower_alloca_dynamic_n!` (Bennett.jl's existing function) and
  ingest the resulting persistent-tree shape into Phase-2 IR. ~150 LOC.
- **M_DYN.3** `push!` Phase-2 lowering: capture pre-push length to delta;
  inverse pops. ~120 LOC.
- **M_DYN.4** `pop!` Phase-2 lowering: capture popped value to delta;
  inverse re-pushes. ~120 LOC.
- **M_DYN.5** Test: `frtN(Int8(5))` compiles, runs, round-trips. ~150 LOC.
- **M_DYN.6** Test: a `push!`-built Vector round-trips. ~150 LOC.
  **Exit:** SC9 case A met.

---

## M_NESTED — Nested loops (Case C, 4 steps, ~590 LOC)

**Goal:** Compile and round-trip `matrix_sum(n) = (s = 0; for i in 1:n, j
in 1:n; s += 1; end; s)`. PRD v4 §3.6.2 Case C + SC9. Gated by M3.

- **M_NESTED.1** `docs/adr/0010-nested-loops.md`: strategy — lift each
  inner loop body to its own basic block with its own continuation.
  Address Bennett.jl reject at `cfg.jl:111` by handling the back-edge
  pattern explicitly in BennettVM. ~120 LOC ADR.
- **M_NESTED.2** BennettVM ingest: intercept the nested-loop reject and
  instead emit a multi-level `BasicBlock` structure with nested
  ConditionalEntry/Exit pairs. ~180 LOC.
- **M_NESTED.3** Nested-loop CFG lowering pass: produce BB structure
  preserving nesting; verify each inner loop's history is independent. ~150 LOC.
- **M_NESTED.4** Test: `matrix_sum(Int8(3))` compiles, runs to result `9`,
  round-trips. ~140 LOC. **Exit:** SC9 case C met.

---

## M_UNBOUNDED — Unbounded while loops (Case D, 3 steps, ~330 LOC)

**Goal:** Compile and round-trip `collatz_steps(n)`. PRD v4 §3.6.2 Case D
+ SC9. **This is M0's smoke-test program made round-trippable.** Gated by M3.

- **M_UNBOUNDED.1** BennettVM ingest: intercept the
  `max_loop_iterations`-required reject at `Bennett.jl/src/lowering/driver.jl:80–83`
  and instead emit a `BasicBlock` with a `ConditionalExit` whose back edge
  is encoded natively (no unrolling). ~150 LOC.
- **M_UNBOUNDED.2** Loop history: each iteration's loop variable update
  pushes its delta to the history; `unstep!` walks the iterations in
  reverse. ~120 LOC.
- **M_UNBOUNDED.3** Test: `collatz_steps(Int64(27))` (97 iterations)
  compiles, runs to halt, round-trips to empty history. ~80 LOC.
  **Exit:** SC9 case D met. **THE LOAD-BEARING MILESTONE.**

---

## M1 — Cost measurement (5 steps, ~530 LOC) — independent

**Goal:** Set the default checkpoint interval in §3.3 from data. PRD v4
SC2. Independent of M5/M0/M2.

- **M1.1** `bench/m1-history-cost.jl`: benchmark harness. ~100 LOC.
- **M1.2** Full-snapshot history baseline (the spike's approach) on
  countdown(10_000) + synthetic 10_000-step program. ~100 LOC.
- **M1.3** Delta-history sketch (record `(register, old_value)` tuples). ~100 LOC.
- **M1.4** Periodic-checkpoint sketch (K=64 default). ~120 LOC.
- **M1.5** `docs/measurements/m1-history-cost.md`: results, default K
  recommendation. ~110 LOC doc. **Exit:** doc committed; v4 §3.3 default
  K updated if recommendation diverges.

---

## M11 — Lean baseline: theorems 1–3 (6 steps, ~820 LOC)

**Goal:** Lean 4 formalization of abstract VM semantics + the round-trip
theorem. PRD v4 §3.8 (5 targets bounded). `0 sorry, 0 axiom` from first
commit. Gated by M3 (semantics must be stable).

- **M11.1** `lakefile.lean` + `Formalisation/BennettVM.lean` skeleton.
  Lean 4 toolchain (`lean-toolchain` file pinning the version). ~50 LOC.
- **M11.2** `docs/adr/0004-lean-tractability.md`: single-theorem
  feasibility probe — prove `unstep_step` for one instruction (e.g.,
  `SwapInstruction`). Use Mathlib if needed. ~120 LOC ADR + Lean.
- **M11.3** Abstract VM semantics in Lean: `IState`, `RState`, `step`,
  `unstep`. ~200 LOC Lean.
- **M11.4** Theorem 1: trace simulation. ∀ prog, abstract `step` agrees
  with reference irreversible step modulo history. ~150 LOC Lean.
- **M11.5** Theorem 2: round-trip. `unstep (step s instr) = s` for every
  instruction kind. ~150 LOC Lean.
- **M11.6** Theorem 3: RAM-primitive equivalences. `Exchange` is an
  `Equiv` on the memory component of `IState`. ~150 LOC Lean.
  **Exit:** `lake build` succeeds with 0 sorry, 0 axiom.

---

## M12 — Lean output channel + pebble correctness (3 steps, ~400 LOC)

**Goal:** PRD v4 §3.8 targets 4–5. Gated by M11.

- **M12.1** Theorem 4: OutputRef non-aliasing. `OutputRef ⊥ IState`. ~150 LOC Lean.
- **M12.2** Theorem 5: pebble-game correctness. Knill recursion `F(n,S)`
  produces a valid pebbling. ~200 LOC Lean.
- **M12.3** `lake build` script verifies 0 sorry, 0 axiom across the full
  `Formalisation/`. ~50 LOC build script. **Exit:** SC7 met.

---

## M13 — Bennett.jl `target=:reversible_vm` dispatch (4 steps, ~360 LOC)

**Goal:** End-to-end `reversible_compile(f, T; target=:reversible_vm)`
calls into BennettVM. **REQUIRES USER APPROVAL per CLAUDE.md Rule 14.**
Gated by M_DICT, M_DYN, M_NESTED, M_UNBOUNDED, M_FP (i.e., SC9 + SC10 met).

- **M13.1** `docs/adr/0003-bennett-target-vm-dispatch.md`: design — one
  line to Bennett.jl's `driver.jl` validator + one dispatch arm in
  `Bennett.lower()`. **REQUIRES USER APPROVAL** before any Bennett.jl
  edit. ~100 LOC ADR + user-approval gate.
- **M13.2** Bennett.jl `driver.jl` validator: accept `:reversible_vm`.
  **DEPENDS ON M13.1 USER APPROVAL.** ~30 LOC Bennett.jl edit.
- **M13.3** Bennett.jl `lower()` one-arm dispatch to `BennettVM.lower_vm`.
  **DEPENDS ON M13.1 USER APPROVAL.** ~80 LOC Bennett.jl edit.
- **M13.4** End-to-end test: `reversible_compile(collatz_steps, Int64;
  target=:reversible_vm)`. ~150 LOC. **Exit:** Phase 2 complete.

---

## Cross-milestone deps summary

To be wired by a final pass once all beads filed:

| From (first bead of …) | Depends on (last bead of …) |
|---|---|
| M0 | M5 |
| M2 | M0 |
| M3 | M2 |
| M4 | M3 |
| M6 | M4 |
| M7 | M6 |
| M8 | M7 |
| M9 | M3 + M_OPCODE |
| M10 | M3 |
| M_FP | M0 |
| M_OPCODE | M2 |
| M_DICT | M7 |
| M_DYN | M7 |
| M_NESTED | M3 |
| M_UNBOUNDED | M3 |
| M11 | M3 |
| M12 | M11 |
| M13 | M_DICT + M_DYN + M_NESTED + M_UNBOUNDED + M_FP |

M1 has no dependencies.

---

## Bead-ID assignments (filed 2026-05-25 by 5 parallel Sonnet subagents)

**Total: 112 chained beads filed, 0 cycles, 3 ready entry points
(M5.1 = `bennettvm-zoe`; epic = `bennettvm-nm0`; M1.1 = `bennettvm-6r6`).**

### Foundation chunk (M5 + M0 + M2)

| Step | Bead ID | Priority |
|---|---|---|
| M5.1 Build rc3+rvm | `bennettvm-zoe` | P0 |
| M5.2 Run rvm sample, observe RSSA dispatch | `bennettvm-7jm` | P0 |
| M5.3 Map RC3 subclasses → Phase-2 naming | `bennettvm-7bl` | P0 |
| M0.1 Project.toml + module skeleton | `bennettvm-fgd` | P0 |
| M0.2 Stub VMProgram + lower_vm digest | `bennettvm-i61` | P0 |
| M0.3 test/runtests.jl + handoff smoke test | `bennettvm-c72` | P0 |
| M0.4 ADR 0000 handoff smoke | `bennettvm-8g1` | P0 |
| M2.1 IState | `bennettvm-e7o` | P1 |
| M2.2 Base.== / hash IState | `bennettvm-6b4` | P1 |
| M2.3 RState + AbstractHistoryEntry | `bennettvm-teu` | P1 |
| M2.4 forward/inverse stubs + Instruction/RValue abs | `bennettvm-qkd` | P1 |
| M2.5 BinaryOperator symbol set | `bennettvm-msl` | P1 |
| M2.6 ArithmeticAssignment | `bennettvm-lff` | P1 |
| M2.7 SwapInstruction | `bennettvm-ti3` | P1 |
| M2.8 ControlInstruction + Begin/End | `bennettvm-n3c` | P1 |
| M2.9 Unconditional Entry/Exit | `bennettvm-08q` | P1 |
| M2.10 Conditional Entry/Exit (φ on splits AND joins) | `bennettvm-du4` | P1 |
| M2.11 MemoryAssignment | `bennettvm-jew` | P1 |
| M2.12 MemoryInterchangeInstruction (Pendulum) | `bennettvm-0zr` | P1 |
| M2.13 MemorySwapInstruction | `bennettvm-wcb` | P1 |
| M2.14 CallInstruction | `bennettvm-dp1` | P1 |
| M2.15 BasicBlock + reversed() | `bennettvm-jvh` | P1 |
| M2.16 LabelEntry + LabelTable (dual-address) | `bennettvm-vab` | P1 |
| M2.17 VMProgram struct | `bennettvm-tot` | P1 |
| M2.18 IR-type tests (hand-built countdown) | `bennettvm-p8n` | P1 |

### Execution chunk (M3 + M4 + M6 + M1)

| Step | Bead ID | Priority |
|---|---|---|
| M3.1 initial_state | `bennettvm-afj` | P1 |
| M3.2 is_halted + result | `bennettvm-3ch` | P1 |
| M3.3 step! single-instruction dispatch | `bennettvm-1hn` | P1 |
| M3.4 run! with max_steps | `bennettvm-fbh` | P1 |
| M3.5 forward batch 1 (arith/swap/mem-assign) | `bennettvm-1zb` | P1 |
| M3.6 forward batch 2 (control flow) | `bennettvm-yx3` | P1 |
| M3.7 forward batch 3 (exchange/swap/call) | `bennettvm-82h` | P1 |
| M3.8 forward-only countdown integration test | `bennettvm-mqh` | P1 |
| M4.1 CheckpointEntry type | `bennettvm-v1t` | P1 |
| M4.2 Periodic checkpoint push in step! | `bennettvm-n26` | P1 |
| M4.3 unstep! via restore + replay | `bennettvm-3do` | P1 |
| M4.4 unrun! | `bennettvm-5jb` | P1 |
| M4.5 Round-trip test (K=4) | `bennettvm-n2g` | P1 |
| M6.1 is_injective trait | `bennettvm-9hf` | P1 |
| M6.2 Skip history push for injective | `bennettvm-b9h` | P1 |
| M6.3 inverse() for injective | `bennettvm-1cg` | P1 |
| M6.4 Zero-history round-trip test | `bennettvm-moa` | P1 |
| M1.1 bench harness | `bennettvm-6r6` | P1 |
| M1.2 full-snapshot baseline | `bennettvm-p44` | P1 |
| M1.3 delta sketch | `bennettvm-vez` | P1 |
| M1.4 checkpoint sketch | `bennettvm-xf3` | P1 |
| M1.5 m1-history-cost.md + K default | `bennettvm-d3l` | P1 |

### History + lowering chunk (M7 + M8 + M9 + M10)

| Step | Bead ID | Priority |
|---|---|---|
| M7.1 ADR 0002 Enzyme min-cut mapping | `bennettvm-80a` | P1 |
| M7.2 DeltaEntry type | `bennettvm-c4m` | P1 |
| M7.3 make_delta per-instruction | `bennettvm-vk8` | P1 |
| M7.4 unstep! DeltaEntry arm | `bennettvm-bk5` | P1 |
| M7.5 Min-cut analysis stub (liveness) | `bennettvm-46p` | P1 |
| M7.6 Min-cut integration into delta selection | `bennettvm-7e7` | P1 |
| M7.7 Delta history round-trip + sub-linear assert | `bennettvm-94m` | P1 |
| M8.1 Golden master countdown.jl | `bennettvm-do7` | P1 |
| M8.2 Per-step inverse test scaffold | `bennettvm-3d8` | P1 |
| M8.3 Mutation-proof harness | `bennettvm-2kl` | P1 |
| M8.4 Seeded random CFG generator | `bennettvm-bii` | P1 |
| M8.5 Property test 100 programs | `bennettvm-tnp` | P1 |
| M9.1 Uniform-bound analysis | `bennettvm-02g` | P1 |
| M9.2 Knill F(n,S) recursion | `bennettvm-9s2` | P1 |
| M9.3 Knill table oracle | `bennettvm-g0a` | P1 |
| M9.4 Linear-chain pebble scheduler | `bennettvm-22m` | P1 |
| M9.5 Meuli SAT encoding | `bennettvm-pjb` | P1 |
| M9.6 Compute/uncompute emission | `bennettvm-0tg` | P1 |
| M9.7 ISCAS benchmark | `bennettvm-zlq` | P1 |
| M10.1 OutputRef nominal type | `bennettvm-m6c` | P1 |
| M10.2 Non-aliasing analysis | `bennettvm-e7c` | P1 |
| M10.3 result(s) → OutputRef | `bennettvm-6ox` | P1 |
| M10.4 run_oracle! API | `bennettvm-rlx` | P1 |
| M10.5 Alias-check tests | `bennettvm-agm` | P1 |

### BennettVM-distinct value chunk (M_FP + M_OPCODE + M_DICT + M_DYN + M_NESTED + M_UNBOUNDED)

| Step | Bead ID | Priority |
|---|---|---|
| M_FP.1 ADR 0011 FP inheritance | `bennettvm-81y` | P1 |
| M_FP.2 Wire fpext/fptrunc | `bennettvm-8ox` | P1 |
| M_FP.3 Wire frem | `bennettvm-01w` | P1 |
| M_FP.4 Float64 polynomial round-trip (SC10) | `bennettvm-yc6` | P1 |
| M_OPCODE.1 Audit IRInst coverage | `bennettvm-34c` | P1 |
| M_OPCODE.2 Phase-2 IRInst gap fills | `bennettvm-hek` | P1 |
| M_OPCODE.3 Every-IRInst test program | `bennettvm-d7t` | P1 |
| M_OPCODE.4 Coverage matrix doc | `bennettvm-ftz` | P1 |
| M_DICT.1 ADR 0008 Dict reversibility | `bennettvm-t4c` | **P0** |
| M_DICT.2 PersistentDictRef type | `bennettvm-jrc` | **P0** |
| M_DICT.3 setindex! lowering | `bennettvm-8i5` | **P0** |
| M_DICT.4 getindex lowering | `bennettvm-usf` | **P0** |
| M_DICT.5 delete! lowering | `bennettvm-l19` | **P0** |
| M_DICT.6 Intercept Bennett.jl Dict reject | `bennettvm-0do` | **P0** |
| M_DICT.7 **fdict test (SC9 Case B)** | `bennettvm-7xa` | **P0** |
| M_DYN.1 ADR 0009 dynamic memory | `bennettvm-s4r` | **P0** |
| M_DYN.2 Dynamic-N IRAlloca route | `bennettvm-0zn` | **P0** |
| M_DYN.3 push! lowering | `bennettvm-6db` | **P0** |
| M_DYN.4 pop! lowering | `bennettvm-ehp` | **P0** |
| M_DYN.5 **frtN test (SC9 Case A part 1)** | `bennettvm-xld` | **P0** |
| M_DYN.6 **push! Vector test (SC9 Case A part 2)** | `bennettvm-xkl` | **P0** |
| M_NESTED.1 ADR 0010 nested loops | `bennettvm-b76` | **P0** |
| M_NESTED.2 Intercept Bennett.jl nested reject | `bennettvm-720` | **P0** |
| M_NESTED.3 Nested CFG lowering | `bennettvm-of5` | **P0** |
| M_NESTED.4 **matrix_sum test (SC9 Case C)** | `bennettvm-k7b` | **P0** |
| M_UNBOUNDED.1 Intercept max_loop_iterations reject | `bennettvm-c39` | **P0** |
| M_UNBOUNDED.2 Loop variable delta history | `bennettvm-h7f` | **P0** |
| M_UNBOUNDED.3 **collatz_steps test (SC9 Case D — LOAD-BEARING)** | `bennettvm-hvx` | **P0** |

### Lean + Bennett.jl integration chunk (M11 + M12 + M13)

| Step | Bead ID | Priority |
|---|---|---|
| M11.1 lakefile + Formalisation/ skeleton | `bennettvm-5ii` | P2 |
| M11.2 ADR 0004 Lean tractability probe (SwapInstruction) | `bennettvm-yc2` | P2 |
| M11.3 Lean abstract VM semantics | `bennettvm-pkv` | P2 |
| M11.4 Theorem 1 trace simulation | `bennettvm-1az` | P2 |
| M11.5 Theorem 2 round-trip | `bennettvm-cc8` | P2 |
| M11.6 Theorem 3 RAM-primitive Equivs | `bennettvm-tug` | P2 |
| M12.1 Theorem 4 OutputRef non-aliasing | `bennettvm-0xj` | P2 |
| M12.2 Theorem 5 pebble-game correctness | `bennettvm-bk7` | P2 |
| M12.3 lake build verifies 0 sorry / 0 axiom | `bennettvm-7zl` | P2 |
| M13.1 ADR 0003 dispatch (**REQUIRES USER APPROVAL**) | `bennettvm-zg5` | **P0** |
| M13.2 Bennett.jl driver.jl validator (**REQUIRES USER APPROVAL**) | `bennettvm-fu5` | **P0** |
| M13.3 Bennett.jl lower() dispatch arm (**REQUIRES USER APPROVAL**) | `bennettvm-kl3` | **P0** |
| M13.4 End-to-end reversible_compile target=:reversible_vm | `bennettvm-vw8` | **P0** |

### Cross-chunk deps wired (17 total)

```
M3.1 (afj)          ← M2.18 (p8n)
M7.1 (80a)          ← M6.4 (moa)
M9.1 (02g)          ← M3.8 (mqh) + M_OPCODE.4 (ftz)
M10.1 (m6c)         ← M3.8 (mqh)
M_FP.1 (81y)        ← M0.4 (8g1)
M_OPCODE.1 (34c)    ← M2.18 (p8n)
M_DICT.1 (t4c)      ← M7.7 (94m)
M_DYN.1 (s4r)       ← M7.7 (94m)
M_NESTED.1 (b76)    ← M3.8 (mqh)
M_UNBOUNDED.1 (c39) ← M3.8 (mqh)
M11.1 (5ii)         ← M3.8 (mqh)
M13.1 (zg5)         ← M_DICT.7 (7xa) + M_DYN.6 (xkl) + M_NESTED.4 (k7b) + M_UNBOUNDED.3 (hvx) + M_FP.4 (yc6)
```

`bd dep cycles` confirms no cycles. `bd ready` shows three entry points:
**M5.1 (`bennettvm-zoe`)** is the load-bearing first step.
**M1.1 (`bennettvm-6r6`)** is the independent cost-measurement chain.
**`bennettvm-nm0`** is the Phase-2 epic (parent tracker).

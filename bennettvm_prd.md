# Product Requirements Document v3: BennettVM.jl

**A two-phase plan for a reversible VM target for Bennett.jl, informed by 50 years of reversible computing literature.**

## Revision history

- **v1.** Initial draft. Bennett-1973 trace VM as the entire roadmap.
- **v2.** Addressed prior-art positioning, quantum-applicability claims, output-channel invariant, floating-point reversibility, cost model.
- **v3 (this).** Reframed around a deliberately throwaway smoke-test spike followed by a production implementation informed by an explicit literature review and reuse map. The spike is one Claude Code session; the production VM is the actual deliverable. v3 also corrects a number of structural mistakes in v2 that would have led to reinventing well-published work.

---

## 0. Executive summary

This document specifies **BennettVM.jl** as a reversible execution target for Bennett.jl, developed in two phases:

- **Phase 0 — Spike.** One Claude Code session (multi-agent orchestration). Bennett-1973 trace VM, full-state history, single toy program (e.g. countdown loop or fixed-point Taylor in Q-format). Deliberately throwaway. Goal: surface concrete issues that cannot be anticipated from this document.
- **Phase 1 — Learnings.** Spike is archived; a retrospective updates this PRD into v4.
- **Phase 2 — Production.** Feature-complete reversible VM. Built on a reversible SSA-style IR (RSSA-influenced), with Pendulum/BobISA-style reversible instructions, Enzyme-style min-cut recompute-vs-cache analysis for delta histories, Bennett-1989 pebble-game lowering for quantum oracle synthesis, and integration with existing uncomputation tools (Unqomp/Reqomp/Qurts) where applicable.

The methodological thesis: implementation cost for the spike has collapsed to a few hours of agent-orchestrated coding; we use that to extract genuine learnings rather than to relitigate decisions a priori. Phase 2 then reuses as much published infrastructure as possible.

---

## 1. Development model

### 1.1 Why a deliberate throwaway?

Two reasons:

1. **PRDs encode plausible decisions, not actual constraints.** Several v1 and v2 sections turned out to be wrong on inspection of the literature. A working spike, even one that gets discarded, will surface concrete decisions that the PRD cannot anticipate — equality semantics for stacks, halt-state propagation, error-state reversibility, what the cost-report actually wants to measure, what Bennett.jl's lowering can reliably emit.
2. **Agent capabilities make this cheap.** A single Claude Code session orchestrating ~3–5 sub-agents (interpreter, instruction-set, test, reviewer, golden-master) can produce a runnable Bennett-1973 trace VM with a small test corpus in hours. The cost of doing this *before* committing to Phase 2 design is negligible compared to the cost of getting Phase 2 wrong.

This is the same methodology Tobias has been applying elsewhere in the Scientist Workbench stack (NJOY port, TensorGR.jl, QVLS-Sturm): aggressive variation under selection pressure, with golden masters and punishing benchmarks rather than upfront design lock-in.

### 1.2 Phase 0 — Spike

**Duration.** One Claude Code session. Hard stop at session end regardless of completeness.

**Methodology.**
- Multi-agent orchestration. Suggested split: interpreter agent, instruction-set agent, test/property-test agent, reviewer agent. Reviewer engages after core changes per the Wild Brains / Scientist Workbench convention.
- Sequential, not parallel, sub-agents (Julia precompilation cache conflicts; established constraint from Tobias's prior work).
- Golden master = a reference irreversible Julia interpreter of the same bytecode subset. Property: VM forward result agrees with reference Julia result.
- Punishing benchmarks = round-trip equality after `unrun!`, history-length equals step count, history-empty after full unrun, max-steps guard triggers correctly.
- Fail-fast / fail-loud. No silent fallbacks.
- Ground truth from local PDFs only (Bennett 1973, Yokoyama-Glück 2007, Mogensen 2016 RSSA). No hallucinated APIs.
- Beads as sole issue tracker.

**Scope.** Exactly the Bennett-1973 trace VM from PRD v2, narrowed to scalars only, integers only (no Q-format yet), one example program, no Bennett.jl integration. This is the minimum that exercises the design.

**Deliverables.**
1. `BennettVM-spike/` Julia package (named "spike" to flag throwaway status).
2. `IState`, `RState`, `HistoryStack` (full-state snapshots only).
3. Eight bytecode instructions: `Const`, `Move`, `UnaryOp`, `BinaryOp`, `Jump`, `JumpIf`, `Return`, `Halt`.
4. `step!`, `unstep!`, `run!`, `unrun!`.
5. One hand-written program (countdown loop is sufficient; gcd is a stretch goal).
6. Round-trip property test on small random programs.
7. A 1–2 page **spike retrospective** capturing what was harder/easier/different than expected.

**Explicit non-deliverables (Phase 0).**
- No Bennett.jl integration.
- No fixed-point or floating-point types.
- No reversible RAM primitives.
- No oracle mode.
- No Lean.
- No performance work.
- No documentation beyond the retrospective.

**Success criterion.** A countdown loop forward-runs to halt, `unrun!`s to the initial state with empty history, and the retrospective document exists. Failure on the retrospective means we did not learn anything and should redo Phase 0.

### 1.3 Phase 1 — Archive and learnings

The spike repository is archived (read-only branch or separate repository, prefixed `spike-`). The retrospective answers at minimum:

1. Which assumptions in PRD v3 turned out wrong or underspecified?
2. What were the actual decisions Claude Code converged on for ambiguous points (equality, error handling, halt semantics, history representation)?
3. What were the surprises in cost, complexity, or Julia idioms?
4. What tooling, library, or design choices made the implementation easier and should carry over to Phase 2?
5. What was *not* learned by doing this spike — i.e., what does Phase 2 still need to design from scratch?

The output is **PRD v4**, which supersedes v3 for Phase 2. v4 is written after the spike, not before.

### 1.4 Phase 2 — Production

This is the actual artifact. It is *not* an extension of the spike; the spike is discarded. v4 will specify it in detail; this document specifies the *constraints* it must satisfy (Part III below) and the *prior art* it must build on (Part II).

The high-level intent of Phase 2:

- Reversible SSA-style IR (informed by Mogensen's RSSA).
- Reversible instruction set with Pendulum/PISA and BobISA influence.
- Mixed history strategy: injective instructions push nothing; non-injective instructions use delta entries with Enzyme-style min-cut analysis to choose recompute-vs-cache; rr-style periodic checkpoints for long-running regions.
- Bennett-1989 pebble-game lowering pass for quantum oracle synthesis subset.
- Integration with Bennett.jl's existing circuit backend and frontend.
- Optional integration with Unqomp/Reqomp/Qurts for quantum uncomputation synthesis on programs that admit it.
- Lean formalization of the abstract VM semantics, not the Julia implementation.

---

## Part II: Prior art and literature review

This section is the substance most missing from v1–v2. It exists so that Phase 2 does not reinvent published work.

### 2.1 The classical foundations

**Bennett 1973.** *Logical reversibility of computation.* IBM J. Res. Dev. 17(6), 525–532. The three-tape reversible TM with a history tape. v0 / Phase-0 spike is literally this construction.

**Bennett 1989.** *Time/space trade-offs for reversible computation.* SIAM J. Comput. 18(4), 766–776. Recursive pebble-game simulation: T irreversible steps in O(T^{1+ε}) time and O(log T) space, or O(T) time and O(T^ε) space. The right asymptotic target for any production reversible VM.

**Lange–McKenzie–Tapp (LMT).** Exponential-time, O(S)-extra-space reversible simulation. The other endpoint of the time-space tradeoff.

**Knill 1995.** *An analysis of Bennett's pebble game.* LANL LAUR-95-2258, arXiv:math/9508218. Recursion for the time-optimal solution given a space bound. Explicit asymptotic expression for the best time-space product. Direct input for any pebble-game implementation.

**Buhrman–Tromp–Vitanyi 2001.** *Time and space bounds for reversible simulation.* Established the tradeoff family; characterizes the space of choices between Bennett-1973 and LMT.

**Li–Vitanyi.** Lower bounds for reversible pebbling on lines (chains). The bound that Phase-2 pebbling must aspire to.

### 2.2 Reversible imperative languages

**Janus.** Lutz–Derby 1986 (Caltech class notes, "Janus86"); Yokoyama–Glück 2007 PEPM (modern formalization with invertible self-interpreter). The canonical reversible imperative language. Self-inverse statements (`+=`, `-=`, `swap`), reversible conditionals with postconditions, reversible `from-until` loops. The Yokoyama–Glück 2007 result that matters: **the Janus self-interpreter is reversible without a computation history.** If the source language is reversible by construction, no trace tape is required. This is the structural lesson Phase 2 must absorb.

Implementations:
- TOPPS at DIKU: official reference interpreter.
- Jana (mbudde, GitHub): Haskell interpreter.
- evincarofautumn/Janus: another Haskell.
- janus-cpu/janus-vesta: Rust VM emulating a Janus CISC instruction set.
- RC3 (THM): the most actively-developed Janus toolchain, with optimizing compiler to RSSA and reversible C output.

**R-CORE / R-WHILE.** Glück–Yokoyama 2016. *A linear-time self-interpreter of a reversible imperative language.* Structured reversible programming. The reversible loop is `from a until b ... loop t end` rather than `while`. Phase-2 question: which subset of Julia `while` loops admits an R-WHILE-style lowering?

**RC3 (Reversible Computing Compiler Collection).** Technische Hochschule Mittelhessen. https://git.thm.de/thm-rc3/release. Active project. Optimizing compiler for Janus, virtual machine for RSSA, output to reversible C. This is the closest existing analogue to what BennettVM is. **Read the RC3 source before writing Phase-2 code.** Listed dependency in the production phase.

**ROOPL.** Haulund 2017 (MS thesis, U. Copenhagen). Reversible OOP with classes, inheritance, subtyping. Out of scope for BennettVM but worth knowing exists.

**Hermes.** Mogensen 2022. *Hermes: a reversible language for lightweight encryption.* Sci. Comput. Program. 215. Domain-specific reversible language. Demonstrates that reversibility can pay off for specific application classes (here, encryption primitives).

**Reversing Erlang and other concurrent imperative work.** Multiple recent papers reversing concurrent imperative programs by identifier tracking. Not directly applicable to a serial VM but indicates the active extent of the field.

### 2.3 Reversible functional languages

**Π and Π°.** James–Sabry. Combinator calculus for reversible computation, type isomorphisms.

**Theseus.** James–Sabry. *Isomorphic interpreters from logically reversible abstract machines.* High-level reversible language with abstract-machine semantics.

**RFUN.** Yokoyama–Axelsen–Glück 2012; Thomsen et al. First-order reversible functional language. First-match policy for pattern matching to maintain reversibility. Symmetric pattern matching and data construction with linearity.

**CoreFun.** Jacobsen–Kaarsgaard–Thomsen 2018 (RC 2018). Typed reversible functional core language. Type system based on combined logic of unrestricted and relevantly-typed terms. Special support for ancillary (read-only) variables. Provides static reversibility checking. Should be examined when designing Phase-2 type-level annotations for ancilla-like data.

**Sparcl.** Matsuda–Wang 2020 (ICFP, *PACMPL* 4). *A language for partially-invertible computation.* Linear-typed, with a type constructor distinguishing invertible from non-invertible data. Allows ordinary computation to coexist with invertible parts. This is structurally similar to what Bennett.jl wants: ordinary Julia coexisting with reversible-compiled subroutines.

**Qurts.** Hirata–Heunen 2025 (POPL 9). *Automatic Quantum Uncomputation by Affine Types with Lifetime.* Programs interpreted as reversible pebble games. Affine types with lifetimes drive ancilla management. Recent and directly relevant.

### 2.4 Reversible intermediate languages

**RIL.** Mogensen. Reversible Intermediate Language. Used for memory usage analysis of reversible functional languages.

**RSSA.** Mogensen 2016, PSI 2015. *RSSA: A Reversible SSA Form.* Reversible variant of SSA. Two key design points:
- Selected uses of a variable *destroy* the variable (substitute for traditional reversible exchange).
- φ-nodes appear on **both** joins **and splits** of control flow (forward AND backward control flow needs reconciliation).

This is the IR Phase 2 should be based on. There is published work on compiling Janus to RSSA, register allocation for RSSA, copy/constant propagation in RSSA, and optimizations of reversible control flow on top of RSSA (Deworetzki–Meyer 2023). **Use RSSA. Do not reinvent it.**

**CRIL / CRSSA.** Oguchi–Yuen 2024 (RC 2024). Concurrent extension of RIL/RSSA with synchronization. Out of scope for Phase 2 but worth knowing.

**Hybrid SSA.** Deworetzki–Schlecht–Meyer 2024. Connects reversible and classical SSA. Relevant for Bennett.jl, which has *both* reversible and irreversible code regions.

### 2.5 Reversible ISAs

**PISA / Pendulum.** Vieri 1995 (MIT MS), 1999 (MIT PhD). *Reversible Computer Engineering and Architecture.* 18-instruction reversible ISA. 12-bit data and address. Fabricated in 0.5μm CMOS. **Memory access is always an exchange.** This single design rule eliminates a large class of reversibility violations and should be adopted directly in Phase 2.

**BobISA.** Axelsen–Yokoyama 2011 (LATA). Reversible ISA inspired by PISA, with improved branch and address-calculation handling. Reversible jumps encode the source label so the predecessor is recoverable. This is the right model for Phase-2 control flow.

**Storrs Hall 1994.** *A reversible instruction set architecture and algorithms.* PhysComp '94. Earlier reversible ISA work.

**Fast Control for Reversible Processors.** Mogensen et al. (LNCS RC 2022). Analysis of PISA/BobISA control mechanisms and proposed improvements. Relevant for Phase-2 reversible control flow design.

### 2.6 Quantum uncomputation: the modern stack

The Phase-2 quantum lift target lives in this body of work, not in our heads.

**Unqomp.** Paradis–Bichsel–Cohen–Vechev 2021 (PLDI). *Synthesizing uncomputation in quantum circuits.* First procedure to automatically synthesize uncomputation. Circuit-graph formalism. Distinguishes qfree gates (those describable on computational basis states) from non-qfree.

**Reqomp.** Paradis–Bichsel–Vechev 2024 (*Quantum* 8, 1258). *Space-constrained uncomputation for quantum circuits.* Builds on Unqomp. Trade qubits for gates. Up to 96% ancilla reduction. **For any classical reversible function with a known circuit, Reqomp is the production tool.**

**Reversible pebbling game for quantum memory management.** Meuli–Soeken–De Micheli 2019 (DATE). SAT-based pebble game for quantum oracle synthesis. Reduces pebbles by 52.77% on average versus Bennett's method.

**Spooky pebble game.** Gidney; tight bounds by Quist et al 2025 (*Quantum*). Extends Bennett's reversible pebble game with mid-circuit measurements. Allows irreversible steps at a "phase price" paid later. For quantum oracle synthesis where measurement is available, this strictly dominates pure reversible pebbling.

**Qrisp + Unqomp integration.** Seidel et al. Integration of automatic uncomputation into the Qrisp high-level quantum programming framework. Reference for how to expose automatic uncomputation to end users.

**Qurts.** Already cited (§2.3). Type-driven uncomputation.

**Quantum Register Machine.** Zhang–Ying 2025 (PLDI 9, art. 180). *Quantum Register Machine: Efficient Implementation of Quantum Recursive Programs.* First purely-quantum architecture with quantum control flow and recursive procedure calls at the instruction-set level. Stores programs and data in QRAM, executes on quantum registers. Directly relevant if Bennett.jl ever wants quantum recursion as a target. For BennettVM Phase 2, the relevance is structural: a quantum analogue exists, and the classical reversible VM and the quantum register machine probably want to share IR-level concepts.

### 2.7 Reverse-time debugging (the engineering lesson)

The reversibility-for-debugging community has been deploying this in production for a decade. The lessons are real.

**rr (Mozilla).** O'Callahan–Huey, 2014+. https://rr-project.org/. https://github.com/rr-debugger/rr. ACM Queue article, 2020. The dominant design: **record nondeterministic inputs only, replay deterministically.** Most computation is deterministic; only the boundary (syscalls, scheduler decisions, RDTSC, RDRAND, signals) needs recording. Reverse execution = restore previous checkpoint + replay forward. Periodic checkpoints amortize the cost.

**For BennettVM, the rr lesson is decisive.** Our VM is fully deterministic (no I/O, no concurrency, no nondeterminism). Therefore, in Phase 2:
- Logging *every* step is wasteful even with delta histories.
- The right base mechanism is **periodic full-state checkpoints + deterministic forward replay** to land at any intermediate step.
- Between checkpoints, no per-step logging is needed *at all* for purely-deterministic regions.
- This is orthogonal to and composes with Bennett-1989 pebbling. Pebbling gives sublinear space asymptotically; rr-style checkpointing gives concrete constant-factor speedups.

**UndoDB**, **WinDbg time travel**, **Simics**, **DrDebug**, **Microsoft Intellitrace.** Commercial and academic reverse debuggers. Various points on the record/replay vs. instrumentation tradeoff curve. Background reading, not direct input.

### 2.8 Compiler-based reverse-mode AD

**Enzyme.** Moses–Churavy et al. https://enzyme.mit.edu. LLVM/MLIR AD plugin. Tobias works adjacent to this and has called BennettIR "the Enzyme of reversible computing." The critical reusable concept:

> Using a minimum-cut recompute vs cache analysis, Enzyme determines a minimal set of values that must be preserved in order to satisfy the dependencies of the reverse pass.

This is **the Bennett-1989 pebbling problem specialized to dataflow graphs**, solved heuristically at the LLVM IR level. Enzyme's min-cut analysis should be adapted directly for Phase 2's delta-history selection. We are not reinventing this in BennettVM; we are porting a known-good algorithm.

**CoDiPack, Tapenade, ADOL-C.** Other AD tools with reverse-mode and various checkpointing strategies (Griewank's revolve algorithm being the classic). Griewank's revolve is itself a special case of Bennett-1989 pebbling for dataflow graphs.

### 2.9 What is not in the literature

A few things this PRD assumes do not yet exist in published form. If they do, this PRD is wrong and should be revised.

1. **A Julia-native reversible VM with Bennett.jl-style frontend integration.** RC3 exists for Janus, not for Julia. Bennett.jl appears to be the only Julia reversible-compilation effort at this scale.
2. **A reversible VM with both classical execution and quantum-oracle-synthesis lowering.** Reqomp/Unqomp work at the circuit level; RC3 works at the classical level; nobody seems to be running both off a shared IR.
3. **Lean 4 formalization of a reversible VM with pebble-game lowering.** Lean formalization of reversible flowcharts exists (Kaarsgaard et al, join inverse categories); a full VM does not appear to be formalized.

The Phase-2 contribution is (1) + (2) + (3), built by reusing the above.

---

## Part III: Phase-2 design constraints (informed by Part II)

This is *not* the Phase-2 design. The Phase-2 design is in v4, written after the spike. What this section gives is the hard constraints that Phase 2 must satisfy.

### 3.1 IR

The Phase-2 IR is based on **RSSA (Mogensen 2016)**, with:

- φ-nodes on both joins and splits.
- Variable-destroying uses (as in Mogensen's design).
- Three-address form derived from RIL.
- Extensions for Bennett.jl-specific lowering needs (to be decided in v4).

We do not invent a new reversible SSA form. We extend Mogensen's.

### 3.2 Instruction classes

Following Pendulum/BobISA, the Phase-2 ISA distinguishes:

- **Injective primitives.** `NOT`, `CNOT`, `Toffoli`, `Swap`, `AddMod`/`SubMod` on fixed-width integers, `LoadExchange`/`StoreExchange` (memory access is always an exchange, per Pendulum). Each is self-inverse or has a fixed paired inverse. Push nothing to history.

- **Reversible control flow.** Following BobISA: reversible jumps encode the source label, so the predecessor pc is recoverable from local state. No history entry needed.

- **Non-injective ops.** Whatever cannot be expressed in the injective subset (e.g., Julia operations that genuinely lose information, or interfaces to irreversible foreign code). Use Enzyme-style min-cut delta history.

### 3.3 History mechanism

Three-layered, in order of preference:

1. **No log.** For injective instructions and reversible jumps.
2. **Delta entries with min-cut selection.** For non-injective ops in deterministic regions. Algorithm: Enzyme's recompute-vs-cache analysis ported to the BennettVM IR.
3. **Periodic full-state checkpoints + deterministic replay.** For long-running regions and as a safety net. The rr design pattern.

Full per-step state snapshots (the Phase-0 mechanism) **must not appear in Phase 2**. They are the worst point on the time-space tradeoff curve and the Phase-0 spike exists to confirm that we hate them.

### 3.4 Pebble-game lowering pass

For programs targeting quantum oracle synthesis, the Phase-2 compiler includes a Bennett-1989 pebble-game lowering pass. This pass:

- Takes a uniformly-bounded program in the RSSA-extended IR.
- Produces a sequence of compute / uncompute steps satisfying a configurable space bound.
- Optionally uses SAT-based pebbling (Meuli et al 2019) for small programs where optimal pebbling matters.
- Optionally uses spooky pebbling (Gidney; Quist et al 2025) if mid-circuit measurement is available in the target backend.

For programs that fit Unqomp/Reqomp/Qurts directly, we emit to those tools rather than reimplementing.

### 3.5 Output channel invariant

(Carried forward from v2 §12.) `run_oracle!` writes to an `OutputRef` that is **external to the reversible state**. This is the unique unrecorded write. Implementation enforces this with a distinct nominal type, statically checked.

### 3.6 Numeric types

Phase 2 supports:
- `Bool`, fixed-width integers.
- Fixed-point Q m.n reals.
- Floating point only via one of: residual-tape FP, posit-with-sticky, or opaque snapshots. Decision deferred to v4.

### 3.7 Frontend integration

Phase 2 integrates with Bennett.jl as a backend target:

```julia
reversible_compile(f, argtypes...; target = :vm)
```

But `:circuit` and `:vm` are semantically distinct backends, not interchangeable. The circuit backend yields a fixed permutation on finite Hilbert space (suitable for quantum). The VM backend yields a classical reversible interpreter; for quantum, run the pebble-game pass to extract a uniform-circuit family.

### 3.8 Lean formalization

Phase 2 includes Lean 4 formalization scoped to:

- Abstract VM semantics on `IState` and `RState`.
- Trace simulation theorem (Bennett-1973 baseline).
- Reversible RAM primitives as `Equiv`s on `IState`.
- Output-channel non-aliasing theorem.
- Bennett-1989 pebble-game correctness for the lowering pass.
- *Not* the Julia implementation. *Not* Bennett.jl. *Not* the LLVM frontend.

Existing Lean work on reversible flowcharts (Kaarsgaard et al, join inverse categories) is the starting point.

---

## Part IV: Reuse map

This is what we take from where, concretely.

| What we need | Where it comes from | Notes |
|---|---|---|
| Reversible SSA IR | Mogensen RSSA 2016 + Deworetzki–Meyer 2023 optimizations | Read RSSA paper and RC3 source first |
| Reversible instruction set | Pendulum/PISA (Vieri 1995/1999) + BobISA (Axelsen-Yokoyama 2011) | Memory-as-exchange rule; reversible jumps with source labels |
| Self-interpreter design (no-history) | Janus self-interpreter (Yokoyama–Glück 2007) | Structural lesson; aspirational for Phase-2 injective subset |
| Reversible loop construct | R-WHILE from-until (Glück–Yokoyama 2016) | For the subset of Julia `while` that admits it |
| Min-cut delta-history selection | Enzyme recompute-vs-cache analysis | Direct algorithm port from LLVM IR to BennettVM IR |
| Periodic checkpointing | rr (Mozilla) design pattern | For deterministic regions in Phase 2 |
| Pebble-game lowering | Bennett 1989; Knill 1995 recursion; Meuli et al 2019 SAT | Phase-2 pass, not v0 |
| Quantum uncomputation synthesis | Unqomp (Paradis et al 2021), Reqomp (Paradis et al 2024) | For programs we emit as quantum circuits |
| Mid-circuit-measurement uncomputation | Spooky pebble game (Gidney; Quist et al 2025) | Optional, for quantum backends supporting measurement |
| Type-driven uncomputation | Qurts (Hirata–Heunen 2025), CoreFun (Jacobsen et al 2018) | Reference for Phase-2 type-level annotations |
| Lean baseline | Kaarsgaard et al, join inverse categories | Starting point for VM formalization |
| Reverse-mode AD bridge | Enzyme.jl (Moses–Churavy) | Tobias's existing stack; integration point |
| Bennett.jl frontend | Bennett.jl (existing) | Julia→IR lowering, type analysis, finite-circuit backend |
| Existing Janus toolchain to read | RC3 (THM), TOPPS DIKU, janus-vesta | Existence proofs and design references |

### 4.1 What Phase 2 reuses from Bennett.jl specifically

- Julia frontend / IR extraction.
- Type analysis for the supported numeric subset.
- Existing reversible gate library (`NOT`, `CNOT`, `Toffoli`, etc.) and its primitive semantics.
- Finite-circuit backend for the `target = :circuit` case.
- Test infrastructure and CI.

### 4.2 What Phase 2 reuses from outside Bennett.jl

- Mogensen RSSA as the basis for the Phase-2 IR (with extensions).
- Pendulum/BobISA design principles for the ISA (with adaptations for Julia-derived programs).
- Enzyme's min-cut analysis ported to the BennettVM IR for delta-history selection.
- Existing quantum uncomputation tools as alternative backends for the quantum oracle target.

---

## Part V: Phase-0 spike specification

This is the only part of the document that gets implemented before v4 is written.

### 5.1 Spike scope

Implement, in Julia, the Bennett-1973 trace VM described in v1/v2 §8, narrowed to:

- Integer scalars (`Int64`, `Bool`) only. No fixed-point. No arrays.
- Eight bytecode instructions (§9.1 of v2).
- Full-state history (`Vector{IState}` or equivalent).
- `step!`, `unstep!`, `run!`, `unrun!`.
- One hand-written program: countdown loop.
- Round-trip property test.

### 5.2 Spike non-scope

- No Bennett.jl integration.
- No injective-instruction optimization.
- No reversible RAM primitives.
- No output channel / oracle mode.
- No fixed-point or floating-point.
- No Lean.
- No serialization.
- No documentation beyond the retrospective.

### 5.3 Spike API

```julia
module BennettVMSpike

export Program, IState, RState
export initial_state, step!, unstep!, run!, unrun!
export is_halted, result

# all standard types
struct IState; pc::Int; locals::Dict{Symbol,Int64}; status::Symbol; end
struct RState; current::IState; history::Vector{IState}; end

end
```

Equality, hashing, copying: whatever Julia provides by default, with explicit overrides only where round-trip equality forces it. Document any non-default choices in the retrospective.

### 5.4 Test corpus

1. **Countdown.** `while n > 0; n -= 1; acc += 1; end`. T = n. Required.
2. **Round-trip property.** For 100 small random programs (bounded length, bounded variable count), forward then backward equals initial state.
3. **History invariant.** `length(st.history) == steps_taken` during forward execution.
4. **Empty-after-unrun.** `isempty(st.history)` after `unrun!`.
5. **Max-steps guard.** `run!(st, prog; max_steps=10)` errors on a program that needs more.

Stretch goals (only if time):
6. gcd loop.
7. fixed-point Taylor (if Q-format is trivial enough; otherwise defer).

### 5.5 Spike methodology

- One Claude Code session. Hard stop.
- Sub-agents: interpreter, instruction-set, tests, reviewer. Sequential, not parallel.
- Golden master: a reference irreversible Julia function for each test program.
- Property tests with explicit seeds for reproducibility.
- Reviewer agent engages after every core change.
- Ground truth from local PDFs (Bennett 1973, Yokoyama–Glück 2007).

### 5.6 Spike retrospective (the actual deliverable)

A short document — 1–2 pages — answering:

1. Which v3 assumptions were wrong or underspecified? (Concrete list.)
2. What ambiguities did Claude Code resolve, and how? (Equality, copy, error handling, halt semantics, history representation.)
3. What was unexpectedly hard or easy?
4. What carries over to Phase 2?
5. What does Phase 2 still need to design from scratch?
6. **Was anything the spike implemented already exists in RC3, janus-vesta, or elsewhere?** Honest cross-check.

The retrospective is the input to PRD v4. If we cannot write it, Phase 0 failed.

---

## Part VI: Phase-2 success criteria (target)

Specified at the level of constraints; details deferred to v4.

1. Compiles a Julia function with a dynamic `while` loop (e.g. fixed-point Taylor in Q-format) to a Phase-2 reversible program with no per-step full-state history.
2. Forward execution matches the reference irreversible Julia implementation under the same numeric semantics.
3. `unrun!` restores initial state with empty history *and* sublinear-in-T peak history bytes for programs in the injective-dominated subset.
4. Pebble-game lowering pass produces, on a uniformly-bounded program, a quantum-oracle-suitable uniform circuit family. For at least one example, this circuit family is accepted by Reqomp/Qrisp/Quipper and runs in simulation.
5. Lean formalization mechanically verifies the abstract trace simulation, the round-trip theorem, the output-channel non-aliasing theorem, and the Bennett-1989 pebble-game correctness theorem for the lowering pass.
6. Reads through RC3 source and Mogensen RSSA paper occurred before any line of Phase-2 code was written. (Documented in v4.)

---

## Part VII: Risks and mitigations

### 7.1 Phase-0 produces no useful learnings

**Mitigation.** Retrospective is the success criterion, not the working VM. If the retrospective is empty, the time was wasted; we accept that risk because the cost is one session.

### 7.2 v4 retreads ground that should have been settled in v3

**Mitigation.** Part II of v3 is the literature backstop. v4's primary author (post-spike) must read every reference in §2 before writing v4.

### 7.3 Phase 2 reinvents RSSA, BobISA, or Enzyme min-cut

**Mitigation.** Reuse map (Part IV) is explicit. Every Phase-2 design decision must answer "what published work does this replace, and why?" before being accepted.

### 7.4 Quantum oracle synthesis claim is overpromised

**Mitigation.** v2 §6.2 obstruction analysis carried forward. Quantum applicability requires the pebble-game lowering pass. Documented explicitly in Phase-2 success criteria.

### 7.5 Bennett.jl frontend changes break BennettVM integration

**Mitigation.** Phase 2 depends on Bennett.jl through a documented IR interface, not internal API surfaces. Pinned versions during initial development.

### 7.6 Lean formalization scope creeps

**Mitigation.** Lean targets are explicit (§3.8). Anything else is out of scope and gets deferred.

### 7.7 We discover the entire design is published in some 2019 paper we missed

**Mitigation.** Part II is the cross-check. If a published artifact subsumes a major piece of Phase 2, we fork or wrap it rather than rebuild. The default response to discovering prior art is reuse, not reimplementation.

### 7.8 The throwaway spike becomes load-bearing

**Mitigation.** Archive immediately on Phase-0 completion. Mark repository read-only. Phase 2 starts from an empty directory.

---

## Part VIII: Open questions for v4

These cannot be answered before Phase 0 and the literature review by Phase-2 author:

1. Exact form of the Phase-2 IR extensions to RSSA — Bennett.jl-specific operations, type-level ancilla annotations, etc.
2. Integration boundary with Bennett.jl: which IR does Bennett.jl emit; does it emit RSSA directly or does BennettVM lower a less-reversible IR?
3. Default numeric subset for Phase 2 — does Q-format suffice, or is FP needed earlier than expected?
4. Whether to ship a pebble-game implementation in BennettVM directly or to bind to Reqomp/Qurts via FFI.
5. Lean 4 vs Coq vs Agda for formalization. Default: Lean 4 per Tobias's existing stack.
6. Whether to publish at RC (Reversible Computation conference) — likely yes if Phase 2 lands; the audience is small but exactly the right audience.

---

## Appendix A: References

### A.1 Foundational reversible computation
- Bennett, C.H. *Logical reversibility of computation.* IBM J. Res. Dev. 17(6), 525–532 (1973).
- Bennett, C.H. *Time/space trade-offs for reversible computation.* SIAM J. Comput. 18(4), 766–776 (1989).
- Knill, E. *An analysis of Bennett's pebble game.* arXiv:math/9508218 (1995). LANL LAUR-95-2258.
- Buhrman, H., Tromp, J., Vitanyi, P. *Time and space bounds for reversible simulation.* arXiv:quant-ph/0101133 (2001).
- Landauer, R. *Irreversibility and heat generation in the computing process.* IBM J. Res. Dev. 5(3), 183–191 (1961).

### A.2 Reversible imperative languages
- Lutz, C., Derby, H. *Janus: a time-reversible language.* Caltech, 1986.
- Yokoyama, T., Glück, R. *A reversible programming language and its invertible self-interpreter.* PEPM 2007.
- Glück, R., Yokoyama, T. *A linear-time self-interpreter of a reversible imperative language.* Computer Software 33(3), 2016. (R-WHILE.)
- Haulund, T. *Design and implementation of a reversible object-oriented programming language.* MS thesis, U. Copenhagen, 2017. (ROOPL.)
- Mogensen, T.Æ. *Hermes: a reversible language for lightweight encryption.* Sci. Comput. Program. 215, 102746 (2022).

### A.3 Reversible functional languages and type systems
- Yokoyama, T., Axelsen, H.B., Glück, R. *Towards a reversible functional language.* RC 2011. (RFUN.)
- Thomsen, M.K. et al. *Interpretation and programming of the reversible functional language RFUN.* IFL 2015.
- Jacobsen, P.A.H., Kaarsgaard, R., Thomsen, M.K. *CoreFun: A Typed Functional Reversible Core Language.* RC 2018.
- Matsuda, K., Wang, M. *Sparcl: a language for partially-invertible computation.* PACMPL 4(ICFP), 2020.
- James, R.P., Sabry, A. *Theseus: A high level language for reversible computing.* RC 2014.
- James, R.P., Sabry, A. *Information effects.* POPL 2012. (Π.)
- Hirata, K., Heunen, C. *Qurts: Automatic Quantum Uncomputation by Affine Types with Lifetime.* PACMPL 9(POPL), 2025.

### A.4 Reversible intermediate languages
- Mogensen, T.Æ. *RSSA: A Reversible SSA Form.* PSI 2015, LNCS 9609 (2016).
- Mogensen, T.Æ. *Partial evaluation of the reversible language Janus.* PEPM 2011.
- Deworetzki, N., Meyer, U. *Compiling Janus to RSSA.* 2021.
- Deworetzki, N. *Optimizing Reversible Programs.* RC 2022.
- Deworetzki, N. *Optimization of Reversible Control Flow Graphs.* RC 2023.
- Oguchi, S., Yuen, S. *Concurrent RSSA for CRIL.* RC 2024.
- Deworetzki, N., Schlecht, M., Meyer, U. *Connecting Reversible and Classical Computing Through Hybrid SSA.* RC 2024.

### A.5 Reversible ISAs
- Vieri, C.J. *Pendulum: A reversible computer architecture.* MS thesis, MIT, 1995.
- Vieri, C.J. *Reversible Computer Engineering and Architecture.* PhD thesis, MIT, 1999.
- Frank, M.P. *Reversibility for efficient computing.* PhD thesis, MIT, 1999.
- Axelsen, H.B., Yokoyama, T. *A simple and efficient universal reversible Turing machine.* LATA 2011. (BobISA.)
- Hall, J.S. *A reversible instruction set architecture and algorithms.* PhysComp '94.
- Mogensen, T.Æ. *Fast Control for Reversible Processors.* RC 2022.

### A.6 Quantum uncomputation tooling
- Paradis, A., Bichsel, B., Cohen, A., Vechev, M. *Unqomp: synthesizing uncomputation in quantum circuits.* PLDI 2021.
- Paradis, A., Bichsel, B., Vechev, M. *Reqomp: Space-constrained Uncomputation for Quantum Circuits.* Quantum 8, 1258 (2024). arXiv:2212.10395.
- Meuli, G., Soeken, M., De Micheli, G. *Reversible pebbling game for quantum memory management.* DATE 2019.
- Gidney, C. *Spooky pebble games and irreversible uncomputation.* algassert.com (2019+).
- Quist, N. et al. *Tight Bounds on the Spooky Pebble Game.* Quantum (2025). arXiv:2110.08973.
- Seidel, R. et al. *Qrisp.* Higher-level quantum programming framework.
- Zhang, Z., Ying, M. *Quantum Register Machine: Efficient Implementation of Quantum Recursive Programs.* PACMPL 9(PLDI), art. 180 (2025). arXiv:2408.10054.

### A.7 Reverse-time debugging
- O'Callahan, R., Jones, C., Froyd, N., Huey, K. *Engineering Record And Replay For Deployability.* USENIX ATC 2017.
- O'Callahan, R., Huey, K. *To Catch a Failure: The Record-and-Replay Approach to Debugging.* ACM Queue 18(1), 2020.
- rr-project. https://rr-project.org. https://github.com/rr-debugger/rr.

### A.8 Compiler-based AD (relevant to delta histories)
- Moses, W., Churavy, V. *Instead of Rewriting Foreign Code for Machine Learning, Automatically Synthesize Fast Gradients.* NeurIPS 2020. (Enzyme.)
- Moses, W.S. et al. *Reverse-mode automatic differentiation and optimization of GPU kernels via Enzyme.* SC 2021.
- Griewank, A., Walther, A. *Algorithm 799: revolve.* ACM TOMS 26(1), 2000. (Checkpointing for AD.)

### A.9 Implementations to read
- RC3 (Reversible Computing Compiler Collection), Technische Hochschule Mittelhessen. https://git.thm.de/thm-rc3/release.
- TOPPS (DIKU) Janus interpreter. https://topps.diku.dk/pirc/.
- jana (mbudde). https://github.com/mbudde/jana.
- janus-vesta. https://github.com/janus-cpu/janus-vesta.
- Enzyme. https://github.com/EnzymeAD/Enzyme. https://enzyme.mit.edu.

---

## Appendix B: Phase-0 spike checklist

A one-page checklist for the Claude Code session. Print before starting.

- [ ] Read Bennett 1973 PDF cover-to-cover. Local copy only.
- [ ] Read Yokoyama-Glück 2007 PEPM PDF. Note the *no-history* self-interpreter point.
- [ ] Initialize `BennettVM-spike/` Julia package. Mark as `private = true` in TOML.
- [ ] Sub-agent assignments: interpreter / instruction-set / tests / reviewer.
- [ ] `IState`, `RState`, `HistoryStack`.
- [ ] Eight bytecode instructions. No more.
- [ ] `step!` / `unstep!` / `run!` / `unrun!`.
- [ ] Countdown program runs forward to halt.
- [ ] Countdown program `unrun!`s to initial state.
- [ ] `length(history) == steps_taken` invariant.
- [ ] `isempty(history)` after `unrun!`.
- [ ] Round-trip property test (100 random programs).
- [ ] `max_steps` guard test.
- [ ] **Retrospective document written.** (Hard requirement.)
- [ ] Repository archived / marked read-only.
- [ ] PRD v4 ticket opened in beads, with retrospective attached.

# Product Requirements Document v4: BennettVM.jl

**A reversible VM target for Bennett.jl — Phase-2 production specification, written after the Phase-0 spike closed.**

---

## Revision history

- **v1.** Initial draft. Bennett-1973 trace VM as the entire roadmap.
- **v2.** Added prior-art positioning, quantum-applicability claims, output-channel
  invariant, floating-point reversibility, cost model.
- **v3.** Reframed around a deliberately throwaway smoke-test spike followed by a
  production implementation informed by an explicit literature review and reuse
  map. Archived at `docs/prd/bennettvm_prd_v3.md` once v4 is ratified.
- **v4 (this).** Written 2026-05-25 after Phase-0 close. Inputs: (a) the spike
  retrospective `spike/RETROSPECTIVE.md` (frozen artifact, all nine questions
  answered); (b) full read of every §2 reference in `references/` (47 papers and
  five source clones — see §2 reuse rows for citations); (c) survey of the
  Bennett.jl pipeline at pinned SHA `5731cec` for the integration boundary
  (see §3.7). v4 supersedes v3 for Phase-2 work; v3 remains the historical
  record of pre-spike intent.

---

## 0. Executive summary

This document specifies **Phase 2 — Production** of BennettVM.jl, a reversible
execution target for [Bennett.jl][bennett]. Bennett.jl compiles plain Julia
functions to *fixed reversible circuits* — the right artifact for a quantum
oracle, but it cannot represent unbounded loops or runtime-sized memory.
BennettVM is the second lowering target (`target = :reversible_vm`) that closes
that gap: a reversible interpreter for terminating computations of statically-
unknown length.

[bennett]: ../Bennett.jl

The two-phase methodology of v3 has executed once:

- **Phase 0 — Spike.** Closed 2026-05-23. Bennett-1973 trace VM in `spike/`
  with full-state history, eight bytecodes, `Int64`-only locals, countdown
  program, 789/789 tests, mutation-proof verified. Tagged `spike-0-archived`,
  chmod -w.
- **Phase 1 — Archive and learnings.** `spike/RETROSPECTIVE.md` is the surviving
  deliverable (264 LOC, nine questions answered). This v4 PRD is its synthesis.
- **Phase 2 — Production.** Starts when v4 ratifies. RSSA-based IR ported from
  Mogensen 2016 / RC3, Pendulum/BobISA-style ISA, Enzyme-style min-cut delta
  histories with rr-style periodic checkpoints, Bennett-1989 pebble-game
  lowering for the quantum-oracle subset, optional Reqomp/Unqomp/Qurts
  integration, Lean 4 formalization of *abstract VM semantics only*. **Phase 2
  starts from an empty `src/` + `test/` tree.** No code from `spike/` is
  promoted. Spike code is consulted as a pattern source for naming and API
  shape, not forked.

The methodological thesis from v3 is unchanged: the cost of a Phase-0 spike was
hours; the cost of a wrong Phase-2 design would be months. The spike retired
genuine ambiguities (equality semantics, exception ordering, discard-pop
predicate, per-step inverse test) that v3 could not have anticipated. v4 codifies
those resolutions as Phase-2 normative requirements (§3.9 onward).

---

## 1. Phase context

### 1.1 Where we are

- `PHASE.md` reads `Phase 1 (archive; PRD v4 pending)` until v4 ratifies, then
  flips to `Phase 2 (production)` with the v4 ratification date.
- The Phase-0 spike repository is at `spike/`, tagged `spike-0-archived`, with
  filesystem permissions `-w` recursively. The spike test suite (789/789
  passing) is the frozen Phase-0 artifact.
- The Phase-2 production tree is empty: `src/BennettVM.jl` does not yet exist;
  `test/runtests.jl` does not yet exist.
- The Bennett.jl pin remains `5731cec22a1fd29efe02d4dc21c2a57e655ecb47`. Phase 2
  consumes the `ParsedIR` type defined at `Bennett.jl/src/ir_types.jl:347`,
  which is already exported. No Bennett.jl source mutation is required to
  *start* Phase 2 (see §3.7).

### 1.2 What survived from v3

v3 Parts II (prior art), III (Phase-2 design constraints), IV (reuse map), VI
(success criteria), VII (risks) are carried into v4 with updates. v3 Part V
(Phase-0 spike specification) is **retired**: Phase 0 closed; v4 §5 replaces it
with the Phase-1 retrospective summary keyed to v3 §V's deliverables.

### 1.3 What v4 changes

In order of impact on Phase-2 work:

1. **Bennett 1973 acquired.** The PDF blocker noted in v3 §5.5 and in the
   retrospective Q7 has been resolved: `references/foundational/bennett-1973-logical-reversibility.pdf`
   (SHA256 `e61ad668…0687`, 496 KB, user-supplied 2026-05-25). The
   Stage 1/Stage 2/Stage 3 construction and the `2√(νs)` segmentation bound
   are now citable directly (Bennett 1973 Table 1, p. 528; Table 2, p. 530;
   the nested-segmentation paragraph at p. 530, lower right). Phase-2
   Stage 2/3 design is no longer blocked.

2. **BobISA citation corrected.** v3 §2.5 cited "Axelsen–Yokoyama 2011 LATA".
   No such paper exists. The actual reference is Thomsen–Axelsen–Glück 2012
   (RC 2012, DOI 10.1007/978-3-642-29517-1_3). Applied throughout §2.4 and
   Appendix A.

3. **Mogensen RIL citation corrected.** v3 §2.4 implied a standalone RIL
   paper. RIL is introduced in §3 of Mogensen 2015 RC (LNCS 9138, DOI
   10.1007/978-3-319-20860-2_5, "Garbage Collection for Reversible Functional
   Languages"). Applied.

4. **Spike-derived normative requirements.** §3.9 through §3.15 are new and
   binding: mutable-struct `RState`, mandatory `Base.==`/`Base.hash` on
   `IState`, forward-before-push step ordering, discard-pop predicate, per-step
   inverse test, golden-master co-location, seeded property tests. Each is
   sourced from a specific spike artifact and retrospective Q-section.

5. **Bennett.jl integration boundary specified.** §3.7 now names
   `Bennett.jl ParsedIR` (defined at `Bennett.jl/src/ir_types.jl:347–398`) as
   the Phase-2 input type. Bennett.jl is not modified at Phase-2 start. The
   handoff is the maximum-decoupling option of the three considered.

6. **Open questions reduced.** v3 §VIII had six open items. Four are now
   resolved or moved to §3 normative statements (Bennett.jl boundary, pebble
   game in-tree vs FFI, Lean choice, BobISA correction). Two genuinely
   remain: floating-point reversibility scheme and divergence handling.
   See §8.

7. **Deferred items table.** §8 introduces a queue of Phase-2 ADRs that must
   be filed before specific Phase-2 milestones. The first ADR is the
   Bennett.jl handoff smoke-test.

---

## Part II: Prior art and literature review (revised)

This section supersedes v3 Part II. Every claim cites a local file path. v4
adds: (a) Bennett 1973 (now on disk); (b) BobISA correction; (c) Mogensen RIL
correction; (d) Hybrid SSA (Deworetzki-Schlecht-Meyer 2024); (e) tightened
prose where Phase-0 work surfaced ambiguity.

### 2.1 The classical foundations

**Bennett 1973** (`references/foundational/bennett-1973-logical-reversibility.pdf`,
IBM JRD 17(6):525–532, Nov 1973). The three-tape reversible TM. Table 1 (p. 528)
shows the canonical three-stage construction:

- Stage 1 (Compute): split each irreversible quintuple `AT → T'σA'` into a
  pair of quadruples `A_j[T/b] → [T'/b]A_m'`, `A_m'[/b/] → [σm 0]A_k`, with
  the index `m` recorded on a history tape that is "out of phase" with the
  working tape (p. 529, col. 1).
- Stage 2 (Copy output): a sequence of B-state quadruples (Table 1, middle)
  that copies the output to a third tape without writing the history tape.
- Stage 3 (Retrace): C-state quadruples (the first-stage quadruples with
  C's substituted for A's and inverses applied) that undo Stage 1's history.

Resource bounds (p. 527, lower right; p. 529 back-references the same
statement): if S takes ν steps and
uses s tape squares, R takes `4ν + 4λ + 5` steps and uses `s + ν + 1` working-
tape squares, `ν + 1` history squares, and `λ + 2` output squares. The
nested-segmentation paragraph (p. 530, lower right) sketches the bound
`2√(νs)` total temporary storage at the cost of doubling time, and a `log ν`
space limit at the cost of `ν²` time — this is the precursor to Bennett 1989's
recursive pebble game. Phase-0 implements Stage 1 only with full-snapshot
history; Phase 2 implements all three stages plus the recursion.

**Bennett 1989** (`references/foundational/Bennett1989_time_space_tradeoffs.pdf`,
SIAM JC 18(4):766–776). Theorem 1 (p. 768; Table 2 on p. 769) is the pebble-game
recursion: `RS(z,x,n,m,d)` hierarchically breaks computation into `n` segments
of length `m`, achieving `O(T^{1+ε})` time and `O(S log T)` space; the
Corollary on p. 770 gives `O(S²)` space-optimal simulation. Phase 2's lowering
pass implements Theorem 1, not Lemma 1 (the linear-time / `O(S+T)` space form
that is the spike).

**Knill 1995** (`references/foundational/Knill1995_bennett_pebble_analysis.pdf`,
LANL LAUR-95-2258, arXiv:math/9508218). Theorem 2.1 (p. 3) is the exact
recursive formula `F(n,S) = min_{1≤m<n} [F(m,S) + F(m,S-1) + F(n-m,S-1)]`.
Tables 1–2 (pp. 7–8) tabulate `F(n,S)` up to `n=100`, `S=20` — usable as test
oracles for the Phase-2 lowering pass.

**Buhrman–Tromp–Vitanyi 2001** (`references/foundational/buhrman-tromp-vitanyi-2001.pdf`,
arXiv:quant-ph/0101133). Establishes the tradeoff family characterizing the
design space between Bennett-1973 and LMT.

**Vitanyi CF'05** (`references/foundational/vitanyi-time-space-energy.pdf`,
arXiv:cs/0504088). Survey. The §4 summary of Bennett 1973 and 1989 is the safe
disambiguation reference when memory drifts. (Note: `vitanyi-reversible.pdf` is
a duplicate of this file; the manifest tracks the dedup.)

### 2.2 Reversible imperative languages

**Janus / Yokoyama–Glück 2007 PEPM** (`references/reversible-languages/yokoyama-glueck-2007-pepm.pdf`).
The modern formalization. §2 defines Janus; §3 implements the self-interpreter
SINT in Janus itself. Theorem 4 establishes that SINT is reversible **without a
runtime computation history** — because Janus is reversible-by-construction
(Figure 5: per-statement inverter), the interpreter can flip direction by
swapping `call` and `uncall`. *Phase-2 lesson:* this property is not directly
inheritable — BennettVM's source language is irreversible Julia bytecode, not
Janus — but it bounds the design space for the *injective-instruction subset*
of Phase 2 IR (§3.2): for that subset, no history is needed.

**Glück–Yokoyama 2016 R-WHILE** (`references/reversible-languages/glueck-yokoyama-2016-rwhile.pdf`).
Structured reversible programming with `from a until b ... loop t end`. The
question Phase 2 leaves open: which subset of Julia `while` loops admits this
lowering? See §8.

**Lutz–Derby 1986** (`references/reversible-languages/lutz-derby-1986-janus.pdf`).
The original Janus notes. Historical record; not load-bearing for Phase 2.

**Hermes (Mogensen 2022), ROOPL (Haulund 2017), RFUN, CoreFun, Sparcl,
Theseus.** Cited in Appendix A. Phase 2 does not implement any of these; they
inform taste.

### 2.3 Reversible intermediate languages

**Mogensen 2016 RSSA** (`references/reversible-ir/mogensen-2016-rssa.pdf`,
PSI 2015 / LNCS 9609, DOI 10.1007/978-3-319-41579-6_16). The IR Phase 2 is
based on. Two structural commitments from §3:

- φ-equivalents appear on **both joins and splits** of control flow.
  Forward execution needs a join-φ (conditional entry, form `L1(x,...) L2 ← c`);
  backward execution needs a split-φ (conditional exit, form `c → L1(y,...) L2`).
  Classical-SSA φ on joins-only is *wrong* in RSSA and produces un-invertible IR.
- Selected uses of a variable are **variable-destroying**, substituting for the
  traditional reversible-architecture exchange.

**Mogensen 2015 RIL** (`references/reversible-ir/mogensen-ril.pdf`,
LNCS 9138 §3, DOI 10.1007/978-3-319-20860-2_5, "Garbage Collection for
Reversible Functional Languages"). **RIL is not a standalone paper** — it is
introduced in §3 of this 2015 work. v3 §2.4's framing as a standalone RIL paper
was incorrect.

**Deworetzki–Meyer 2021 (Janus-to-RSSA)** (`references/reversible-ir/deworetzki-meyer-2021-janus-to-rssa.pdf`,
RC 2021, DOI 10.1007/978-3-030-79837-6_4). The RC3 compiler design: Janus source
→ RSSA → four backends (AST interpreter, three-address-code C, RSSA C, RSSA
VM). §2.2 (pp. 66–67) is the most accessible RSSA exposition; Phase 2 reads
this before reading Mogensen 2016.

**Deworetzki 2022, 2023; Deworetzki–Schlecht–Meyer 2024 Hybrid SSA**
(`references/reversible-ir/deworetzki-{2022-optimizing,2023-cfg-opt,2024-hybrid-ssa}.pdf`).
Optimization passes and the mixed-classical-reversible SSA form. Hybrid SSA is
directly relevant because BennettVM consumes Bennett.jl's *classical* SSA
(`ParsedIR` — §3.7) and produces a reversible form: the boundary is precisely
what Hybrid SSA models.

**Oguchi–Yuen 2024 CRIL/CRSSA** (`references/reversible-ir/oguchi-yuen-2024-cril-crssa.pdf`,
arXiv:2309.07310). Concurrent extension. Out of scope for Phase 2.

### 2.4 Reversible ISAs

**Pendulum / Vieri 1995 MS, 1999 PhD** (`references/reversible-isa/vieri-{1995-pendulum-ms,1999-reversible-arch-phd}.pdf`).
MS Chapter 4 §4.2 (pp. 30–38) defines the 18-instruction ISA; §4.2.1 (p. 32)
states the **memory-as-exchange** rule: every memory access preserves the
prior register value. A load that does not store back is irreversible.
PhD Chapter 4 §4.4 (pp. 50–60 SCRL) establishes that multiplexing is a
many-to-one mapping and therefore illegal in a reversible ISA. Phase 2's
memory model adopts both rules: §3.2.

**BobISA / Thomsen–Axelsen–Glück 2012** (`references/reversible-isa/axelsen-yokoyama-2011-bobisa.pdf`
— the filename predates the citation correction). RC 2012, DOI 10.1007/978-3-642-29517-1_3.
"A Reversible Processor Architecture and Its Reversible Logic Design." Key
property for Phase 2: **reversible jumps encode the source label** so the
predecessor pc can be recovered from local state. A classical-style jump to
address D from address P loses P and is therefore irreversible. Phase-2
control flow adopts this encoding (§3.2).

**Frank 1999 MIT PhD** (`references/reversible-isa/frank-1999-thesis.pdf`).
406-page thesis. The thermodynamic backing for the reversible-computing
argument. Phase 2 cites this for the negative constraint: any instruction
that destroys information is thermodynamically irreversible and must be
either excluded or routed through a designated garbage output.

**Mogensen 2022 Fast Control** (`references/reversible-isa/mogensen-2022-fast-control.pdf`,
RC 2022). Analysis of PISA/BobISA control mechanisms. Reference [5] of this
paper is what confirmed the BobISA citation correction. Relevant for Phase 2
control-flow refinements.

### 2.5 Quantum uncomputation

**Unqomp (Paradis et al 2021)** (`references/quantum-uncomputation/unqomp-2021.pdf`,
PLDI 2021). Synthesizes uncomputation on a circuit-graph DAG with no space
budget. Theorem 3.1: synthesized circuit resets ancilla qubits to `|0⟩`
without measurement.

**Reqomp (Paradis et al 2024)** (`references/quantum-uncomputation/Reqomp2024_uncomputation.pdf`,
Quantum 8:1258, arXiv:2212.10395). Extends Unqomp with a qubit budget,
trading qubits for gates via `evolveVertex` (§3.2). Up to 96% ancilla
reduction. For Phase 2, Reqomp is an FFI binding *candidate* for the
quantum-oracle subset, not a substitute for the pebble-game pass.

**Qurts (Hirata–Heunen 2025 POPL)** (`references/quantum-uncomputation/qurts-2024.pdf`,
arXiv:2411.10835). Affine types with lifetimes for automatic uncomputation in
a Rust-like quantum language. Programs interpreted as reversible pebble games.
*Not directly applicable to BennettVM* — Qurts is a source-language type
system, not a runtime tool — but Table 1 (p. 3) is the authoritative
comparison table for the design space (Qurts vs Unqomp vs Reqomp vs ReQWire
vs Silq).

**Meuli–Soeken–De Micheli 2019** (`references/quantum-uncomputation/Meuli2019_reversible_pebbling.pdf`,
DATE 2019, arXiv:1904.02121). SAT-based pebble game. Generalizes Knill's
linear-chain recursion to arbitrary DAGs. Table I (p. 4) reports 52.77%
qubit reduction vs naive Bennett at 2.68× step overhead. For Phase 2: this
is the practical tool for the DAG case; the Knill recursion handles
straight-line programs.

**Quist et al 2025 spooky pebbling** (`references/quantum-uncomputation/spooky-pebble.pdf`,
Quantum, arXiv:2110.08973). Bennett's pebble game extended with mid-circuit
measurements. Tight bounds: time `O(T/ε)`, qubits `O(T^ε · S^{1-ε})`,
exponentially better than reversible at the same qubit count. Out of scope
for Phase-2 initial design (the VM backend is classical-reversible per §3.7);
flagged in §8 as a Phase-2.x option for quantum-MCM-capable hardware.

**Quantum Register Machine / Zhang–Ying 2025** (`references/quantum-uncomputation/zhang-ying-2025-qrm.pdf`,
PLDI 9:180, arXiv:2408.10054). Quantum control flow at the ISA level. Out of
scope for Phase 2; relevant if BennettVM ever targets quantum recursion.

### 2.6 Reverse-time debugging

**rr (O'Callahan et al 2017)** (`references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`,
USENIX ATC, arXiv:1705.05937). §2.1 (p. 2): "record all sources of
nondeterminism within the boundary and all inputs crossing into the boundary,
and re-execute by replaying the nondeterminism and inputs." For BennettVM
(fully deterministic — no I/O, no concurrency, no nondeterminism inside the
VM), the rr architecture implies: **periodic full-state checkpoints + replay
within segments**, not per-step logging. Phase 2 §3.3 adopts this as the base
mechanism for deterministic regions.

### 2.7 Compiler-based reverse-mode AD

**Enzyme (Moses–Churavy 2020 NeurIPS)** (`references/ad-and-checkpointing/enzyme-2020.pdf`,
arXiv:2010.01709). §2 "Cache" (p. 4): Enzyme decides per-instruction whether
to cache or recompute, using alias analysis, activity analysis, and a cost
model. The min-cut analysis is the Bennett-1989 pebble problem specialized
to dataflow graphs, solved heuristically at LLVM IR. Phase 2 ports this for
delta-history selection (§3.3).

**Enzyme GPU 2021** (`references/ad-and-checkpointing/enzyme-gpu-2021.pdf`,
SC 2021). Extension to GPU kernels. Reference, not direct input.

### 2.8 What is still not in the literature

Three genuine gaps (down from v3's three; one of v3's items — "Julia-native
reversible VM with Bennett.jl-style frontend integration" — is now what we
are building):

1. **RSSA-over-Julia.** All RSSA work assumes statically-typed first-order
   programs (Janus, RIL). Julia has dynamic dispatch, multiple return values,
   and heap mutation with aliasing. How to embed Julia IR into RSSA without
   losing reversibility guarantees in the presence of aliased heap mutation
   is unaddressed. Phase 2 §3.7 handles this only at the surface — Bennett.jl
   has already rejected dynamic-`Dict` and dynamic-`Array` allocation
   (`Bennett.jl/README.md:247`), narrowing the problem.

2. ~~**Floating-point reversibility scheme.**~~ **Resolved in v4.1.**
   Bennett.jl's SoftFloat dispatch (`Bennett.jl/src/softfloat_dispatch.jl` +
   `Bennett.jl/src/softfloat/`) is bit-exact IEEE 754 binary64 reversibility,
   inherited wholesale by BennettVM. See §3.6.

3. **Divergent-program handling.** All reversible-simulation results assume
   the simulated machine halts. BennettVM must handle divergence gracefully
   (max-steps trip is reversible; provably divergent loops are not). Phase 2
   §3.x handles only the max-steps case; structural divergence detection is
   out of scope.

---

## Part III: Phase-2 design specification (normative)

This section is binding. Every MUST/SHOULD is RFC-2119-conformant. Citations
of the form `spike/Interpreter.jl:103–109` refer to the frozen Phase-0
artifact; citations of the form `Bennett.jl/src/ir_types.jl:347` refer to the
Bennett.jl pin `5731cec`.

### 3.1 IR

**Phase 2 IR MUST be Mogensen-style RSSA (Mogensen 2016).** Specifically:

- Basic blocks. Each block has an *entry point* (`UnconditionalEntry` or
  `ConditionalEntry` — Mogensen 2016 §3) and an *exit point*
  (`UnconditionalExit` or `ConditionalExit`).
- **φ-equivalents on both joins AND splits.** `ConditionalEntry L1(x,...) L2 ← c`
  reconciles incoming control from `L1` (if `c` holds) and `L2` (otherwise).
  `ConditionalExit c → L1(y,...) L2` enables backward execution to determine
  which predecessor was taken without a history entry.
- **Variable-destroying uses**, substituting for the classical reversible
  exchange.
- Three-address form for assignments: `x := y ⊕ (l ⊙ r)` per Mogensen 2016
  §3 (where `⊕` is the modification operator and `⊙` is the binary op).

**Reference implementation:** the IR taxonomy in `references/implementations/RC3/compiler/src/main/java/rc3/rssa/instances/`
(12 concrete instruction subclasses out of 22 files in that directory; the
other 10 are interface/support types `Atom`, `BinaryOperand`, `Constant`,
`ControlInstruction`, `Instruction`, `MemoryAccess`, `Program`, `RValue`,
`Value`, `Variable`). The concrete subclasses — `ArithmeticAssignment`,
`SwapInstruction`, `MemoryAssignment`, `MemoryInterchangeInstruction`,
`MemorySwapInstruction`, `CallInstruction`, `BeginInstruction`,
`EndInstruction`, `UnconditionalEntry`, `UnconditionalExit`,
`ConditionalEntry`, `ConditionalExit` — are the authoritative
representations of Mogensen 2016 §3. **Phase 2's IR taxonomy MUST be structurally
isomorphic to this set.** Departures require an ADR citing the published
justification.

**Reference-implementation pre-read criterion:** before any Phase-2 IR code is
written, the `rc3` and `rvm` binaries MUST be built and a sample RSSA program
executed through `rvm`. The result MUST be documented in `docs/adr/0001-rc3-rvm-smoke.md`.
This is Phase-2 success criterion 6 (§6) operationalized as a milestone gate.

**Extensions to RSSA for Bennett.jl ingestion** (Phase-2-specific):

- Julia-integer width annotations on operands. Bennett.jl's `ParsedIR` already
  carries bit-widths on `args` and `ret_elem_widths` (`Bennett.jl/src/ir_types.jl:347–356`);
  these are propagated into RSSA operands without loss.
- A `Bennett.PendingVecLane`-equivalent placeholder for sub-instruction lane
  reconciliation. (See `Bennett.jl/src/ir_types.jl` for the existing sentinel
  set.)
- An explicit `Halt` / `Return` distinction (§3.9.10).

### 3.2 Instruction classes

Following Pendulum (Vieri 1995 §4.2.1) and BobISA (Thomsen–Axelsen–Glück 2012):

- **Injective primitives.** `NOT`, `CNOT`, `Toffoli`, `Swap`, fixed-width
  `AddMod`/`SubMod`/`XorMod`, `Exchange` (memory access). Each is self-inverse
  or has a fixed paired inverse. **Push nothing to history.**
- **Reversible control flow.** `ConditionalEntry`/`ConditionalExit` per RSSA
  (§3.1); BobISA-encoded jumps that recover the source label from local state.
  **Push nothing to history.**
- **Non-injective ops.** Operations that genuinely lose information (e.g., a
  Julia `div`-with-rounding where the residue is not recovered). MUST be
  represented as an injective core (the function's mathematical bijection
  extended with explicit ancilla outputs) wrapped in an *ancilla-allocation*
  protocol. The history payload is the ancilla value(s), not a full snapshot.

**Memory access MUST always be an exchange** (Vieri 1995 §4.2.1).
Specifically: `MemoryInterchangeInstruction x := M[y] := z` reads `M[y]` into
`x` AND writes `z` into `M[y]`, in a single reversible step. A load that does
not store back is forbidden — Phase 2 IR generation MUST emit an explicit
zero-write paired with every effective load.

**Reversible jumps MUST encode the source label.** A jump from address P to
address D MUST embed P (or a derivative recoverable from local state) in the
target's incoming-edge condition. This is the RC3 `LabelTable` dual-address
mechanism (`references/implementations/RC3/compiler/src/main/java/rc3/rssa/pass/LabelTable.java:12`):
each label has a forward-entry address and a backward-entry address.

**Anti-pattern (from spike, do NOT carry over):** the spike's `Const`, `Move`,
`UnaryOp`, `BinaryOp` are uniform non-injective primitives that incur a full-
snapshot history entry each. Phase 2 MUST partition by injectivity per the
list above and pay the history cost only for the non-injective subset.
(Justification: `spike/RETROSPECTIVE.md` Q4 §"Anti-patterns the spike
surfaced".)

### 3.3 History mechanism

The Phase-2 history strategy is **three-layered**, applied in order of
preference:

1. **No log.** Injective instructions and reversible jumps (§3.2) push
   nothing.
2. **Delta entries with min-cut selection.** For non-injective ops in
   deterministic regions, the history payload is the minimal information
   required to invert the step (typically: the destroyed value(s), not a
   snapshot). The decision of *which* values to cache vs recompute is the
   Enzyme min-cut analysis (Moses–Churavy 2020 NeurIPS §2 "Cache") ported to
   the Phase-2 IR.
3. **Periodic full-state checkpoints + deterministic replay.** For long-
   running regions and as a safety net. The rr architecture (O'Callahan et al
   2017 §2.1): record nondeterminism, replay determinism. Since BennettVM is
   fully deterministic inside the VM boundary, only checkpoint state and
   replay forward.

**Full per-step `IState` snapshots (the Phase-0 mechanism) MUST NOT appear in
Phase 2.** They are the worst point on the time-space curve and exist in the
spike specifically so that the Phase-0 retrospective could refute them.
Justification: `spike/RETROSPECTIVE.md` Q4 §"Anti-patterns".

**Enzyme min-cut adaptation ADR.** Before the delta-history selector is
implemented, an ADR MUST identify which Phase-2 RSSA dataflow constructs
correspond to Enzyme's LLVM-IR value-dependency graph edges. Filed as
`docs/adr/0002-enzyme-min-cut-mapping.md`. See §8.

**Checkpoint interval.** Configurable. Default is set after the measurement
task in §6.M1 produces concrete cost data; until then, the default is
"every 64 retained-snapshot-equivalent steps" as a placeholder.

### 3.4 Pebble-game lowering pass

For programs targeting **quantum oracle synthesis**, Phase 2 includes a
Bennett-1989 pebble-game lowering pass. This pass:

- **Input.** A uniformly-bounded program in the Phase-2 RSSA IR. Uniform
  bounding means: every loop has a static iteration cap; every memory region
  has a static size. Programs failing uniform-bound analysis MUST be rejected
  with a clear error message (the analysis is the same one Bennett.jl
  applies for the `:circuit` target — `Bennett.jl/src/lowering/driver.jl:79–82`,
  where `lower()` throws `ArgumentError` for back-edge loops without an
  explicit `max_loop_iterations`).
- **Algorithm for straight-line / chain programs.** Knill 1995 Theorem 2.1
  recursion `F(n,S) = min_m [F(m,S) + F(m,S-1) + F(n-m,S-1)]`. Knill Tables 1–2
  (pp. 7–8) usable as test oracles.
- **Algorithm for DAG programs.** Meuli et al 2019 SAT encoding. Z3 (or a
  Julia-native SAT backend if available) as the solver.
- **Output.** A sequence of compute/uncompute steps satisfying a configurable
  space bound. Optionally a uniform-circuit family for the quantum-oracle
  backend.
- **Optional integration:** for programs that fit Reqomp / Unqomp directly,
  emit a circuit-graph in their input format and shell out. Decision in
  `docs/adr/0005-pebble-vs-reqomp.md` (§8). v3's §VIII open-question #4
  is *resolved* in principle: implement Knill recursion + Meuli SAT in tree;
  bind to Reqomp for the qubit-budgeted quantum-oracle subset only.

### 3.5 Output channel invariant

(Carried from v2 §12 / v3 §3.5, strengthened.) `run_oracle!` writes to an
`OutputRef` that is **external to the reversible state**. The `OutputRef`
MUST:

1. Be a distinct nominal type, not a `Symbol` key into `IState.locals`.
2. Be statically prevented from aliasing any field of `IState` or `RState`.
3. Be the **sole unrecorded write** in `run_oracle!`. Every other state
   change is reversible.

**Static check reference:** RC3's aliasing analysis (`references/implementations/RC3/compiler/src/main/java/rc3/januscompiler/pass/AliasingAnalysisPass.java:30`)
forbids RHS = LHS in assignment and same-variable-twice in call arguments.
Phase 2 MUST implement an equivalent pass for `OutputRef` non-aliasing
specifically.

**Type-theoretic reference:** Qurts (Hirata–Heunen 2025) affine types with
lifetimes; Sparcl (Matsuda–Wang 2020) `pin` operator. Phase 2 does not adopt
these wholesale but their distinction between invertible and non-invertible
data is the design model.

### 3.6 Numeric types

Phase 2 inherits Bennett.jl's numeric universe. The full supported set:

1. `Bool`, fixed-width signed and unsigned integers (`Int8…Int64`,
   `UInt8…UInt64`). Direct ingestion from `ParsedIR`.
2. Fixed-point Q m.n reals. Wrapper over fixed-width integers; reversibility
   inherited.
3. **`Float64` — via Bennett.jl's SoftFloat dispatch.** This corrects v3
   §3.6 and the initial v4 draft (which incorrectly listed FP as out of
   scope). Bennett.jl ships a complete, production-quality, bit-exact IEEE
   754 binary64 reversibility mechanism at `Bennett.jl/src/softfloat_dispatch.jl`
   and `Bennett.jl/src/softfloat/` (~30 files implementing `soft_fadd`,
   `soft_fmul`, `soft_fdiv`, `soft_fma`, `soft_fsqrt`, the 14 non-trivial
   `fcmp` predicates, `soft_exp`/`log`/`pow`/`sin`/`cos`/`tan`/`tanh` and
   inverses, `soft_floor`/`ceil`/`trunc`/`round`, `soft_fpext`/`soft_fptrunc`,
   `soft_fptosi`/`soft_fptoui`/`soft_sitofp`/`soft_uitofp`,
   `soft_fmin`/`soft_fmax`). Mechanism: `reversible_compile(f, Float64)`
   wraps the user function in a UInt64-typed lambda so Float64 values are
   carried as `UInt64` bit patterns through LLVM IR; every Float64 arithmetic
   op becomes a registered-callee `IRCall` with integer operand widths in
   `ParsedIR`. **BennettVM inherits this mechanism wholesale** — no
   FP-reversibility code is written in BennettVM; the integer-only Phase-2
   RSSA representation handles SoftFloat-dispatched Float64 transparently.
4. `Float32` — deferred to Phase-2.x, tracking upstream `Bennett-3rph`.
   Bennett.jl currently widens Float32 → Float64 via `soft_fpext`/`soft_fptrunc`
   (not bit-exact); BennettVM inherits the same widening until upstream lands
   a Float32-direct path.

**v3 → v4 change rationale on FP.** v3 §3.6 listed three candidate schemes
(residual tape, posit-with-sticky, opaque snapshots). Between v3 and v4
author confirmation, Bennett.jl shipped a fourth scheme — bit-exact
SoftFloat dispatch — that obviates the choice. BennettVM reuses it under
Law 2.

### 3.6.1 Maximum LLVM opcode coverage (north-star)

**Phase 2 SHALL handle every LLVM opcode and intrinsic Bennett.jl's
`_convert_instruction` (`Bennett.jl/src/extract/instructions.jl`, ~2516
LOC) accepts.** This is the north-star: a Julia function that compiles for
`target=:circuit` in Bennett.jl MUST also compile for
`target=:reversible_vm` in BennettVM, modulo the four motivating-case
constraints in §3.6.2.

Coverage matrix at pin `5731cec`:

| LLVM opcode family | Bennett.jl status | Phase 2 inheritance | BennettVM-distinct work |
|---|---|---|---|
| Integer binary (13 ops: `add/sub/mul/and/or/xor/shl/lshr/ashr/udiv/sdiv/urem/srem`) | ✅ | inherit | — |
| Integer compare (10 preds: `eq/ne/ult/ule/ugt/uge/slt/sle/sgt/sge`) | ✅ | inherit | — |
| Integer cast (`sext/zext/trunc`) | ✅ | inherit | — |
| Pointer/value cast (`bitcast/fptosi/fptoui/sitofp/uitofp`) | ✅ via direct dispatch | inherit | — |
| Float compare (14 non-trivial `fcmp` preds) | ✅ | inherit | — |
| Float arithmetic (via SoftFloat dispatch as integer calls) | ✅ | inherit | — |
| Float math intrinsics (~30 functions, `llvm.sqrt/exp/log/pow/sin/cos/tan/tanh/...`) | ✅ via SoftFloat | inherit | — |
| Memory (`alloca/load/store`, static `n_elems`) | ✅ | inherit (with `IRLoad/IRStore` → `Exchange` pre-RSSA normalization, §3.7) | — |
| Aggregate (`extractvalue/insertvalue`) | ✅ | inherit | — |
| GEP constant + variable index | ✅ | inherit | — |
| Control flow (`br/switch/phi/ret`) | ✅ | inherit | — |
| Memcpy/memset intrinsics | ✅ | inherit | — |
| Bit intrinsics (`ctpop/ctlz/cttz/bitreverse/bswap/fshl/fshr`) | ✅ | inherit | — |
| Min/max intrinsics (`umax/umin/smax/smin/abs/...`) | ✅ | inherit | — |
| **Memory (alloca with dynamic `n_elems`)** | ❌ rejected (`:auto` path) / ✅ via `:persistent` | **distinct** | §3.6.2 case A |
| **Dict / hash-table mutation** | ❌ rejected (Bennett-800b) | **distinct** | §3.6.2 case B |
| **Nested loops at LLVM level** | ❌ rejected (Bennett-httg, `cfg.jl:111`) | **distinct** | §3.6.2 case C |
| **Unbounded `while` (no `max_loop_iterations`)** | ❌ rejected (`driver.jl:80–83`) | **distinct** | §3.6.2 case D |
| FP ext/trunc opcodes (`fpext/fptrunc`) | ⚠️ gap (`soft_*` exist, dispatch missing in `_convert_instruction`) | gap | wire missing dispatch in BennettVM ingest (or upstream fix) |
| `frem` opcode | ⚠️ gap | gap | wire missing dispatch |
| Vector ops (`extractelement/insertelement/shufflevector`) | ❌ rejected | deferred | Phase-2.x |
| Exception handling (`invoke/landingpad/...`) | ❌ rejected | NEVER | — |
| Atomics (`atomicrmw/cmpxchg/fence`) | ❌ rejected | NEVER | atomics require nondeterminism the VM is built to avoid |
| Overflow intrinsics (`smul.with.overflow/...`) | ❌ rejected (struct returns) | deferred | requires `{iN,i1}` struct returns |
| Float32 direct | ❌ rejected (`Bennett-3rph`) | deferred | tracked upstream |

The "BennettVM-distinct work" column is the actual Phase-2 implementation
backlog beyond inheriting Bennett.jl.

### 3.6.2 Why BennettVM is the desirable target for Bennett.jl

The four motivating cases — what makes a Julia user *choose*
`target=:reversible_vm` over `target=:circuit`:

**Case A. Dynamic-size memory.** `Vector{T}(undef, n)`, `push!`-grown
collections where the final size is data-dependent, `IRAlloca` whose
`n_elems` operand is `SSAOperand` rather than `ConstOperand`. Bennett.jl's
circuit target rejects these at extract (`Bennett.jl/src/extract/heap.jl`)
or at lower (`Bennett.jl/src/lowering/memory.jl:182–184`: "dynamic n_elems
alloca encountered under mem=:auto"). Bennett.jl's `:persistent_tree`
strategy partially handles dynamic-N allocas under `mem=:persistent`;
`target=:reversible_vm` MUST handle dynamic-size memory in full generality,
reusing the `:persistent_tree` mechanism where applicable and extending it
otherwise.

**Case B. `Dict{K,V}` and other hash-table mutations.** Bennett.jl rejects
these (`Bennett-800b` — "hash-table mutation is irreversible by
construction") at `Bennett.jl/src/extract/heap.jl:313–320`. **This rejection
is false in the VM model**: a `Dict` with a history of `setindex!`/`delete!`
operations IS reversible if the history is preserved. Implementation
pattern: every `setindex!(d, k, v)` captures `(k, old_v_or_missing)` to
delta history (§3.3); every `delete!(d, k)` captures `(k, old_v)`;
`unstep!` reverses by restoring or re-inserting. This is the Bennett-1973
history-tape mechanism applied to heap mutation, not to control flow.
Canonical motivating program (currently rejected by Bennett.jl, MUST
succeed under BennettVM):
```julia
fdict(k::Int8, v::Int8) = let d = Dict{Int8,Int8}(); d[k] = v; d[k] end
```

**Case C. Nested loops at the LLVM level.** Bennett.jl's `lower_loop!` at
`Bennett.jl/src/lowering/cfg.jl:111` rejects: "nested loop header inside
body — nested loops not supported (Bennett-httg / U05 scope)". The VM
target lifts each nested loop body into its own basic block with its own
continuation; no syntactic unrolling is required. Canonical motivating
program:
```julia
matrix_sum(n::Int8) = (s = Int8(0); for i in 1:n, j in 1:n; s += Int8(1); end; s)
```

**Case D. Unbounded `while` loops.** Bennett.jl requires
`max_loop_iterations=N` (`Bennett.jl/src/lowering/driver.jl:80–83`); the
circuit target unrolls each loop N times. The VM target runs loops
dynamically — `while n != 1; ...; end` simply runs as many times as the
input demands. Canonical motivating program:
```julia
collatz_steps(n::Int64)   # while n != 1 with data-dependent trip count
```

**Phase-2 success criterion subsuming all four** (see §6 SC9, added by
v4.1): every one of the four programs (`fdict`, `frtN`, `matrix_sum`,
`collatz_steps`) compiles under `reversible_compile(..., target=:reversible_vm)`
and round-trips correctly.

### 3.7 Frontend integration

Phase 2 consumes Bennett.jl's `ParsedIR` type (`Bennett.jl/src/ir_types.jl:347–398`),
already exported from the Bennett.jl module (`Bennett.jl/src/Bennett.jl:88`).
No Bennett.jl source mutation is required at Phase-2 start.

**Entry-point API (Phase-2 surface):**

```julia
module BennettVM

# `ParsedIR` is exported from Bennett.jl (`Bennett.jl/src/Bennett.jl:88`).
# `IRBasicBlock` and `IRInst` are NOT exported at pin 5731cec; access them
# qualified as `Bennett.IRBasicBlock`, `Bennett.IRInst`. Phase 2 SHOULD NOT
# request export changes during the M0 milestone (Rule 14: no Bennett.jl
# source mutation without explicit user approval); the qualified-access
# pattern is sufficient.
using Bennett: ParsedIR

export VMProgram, lower_vm, simulate_vm, verify_vm_reversibility

# Lower a classical-SSA ParsedIR to a reversible VM program.
lower_vm(parsed::ParsedIR; opts::VMCompileOptions=VMCompileOptions()) :: VMProgram

# Forward execution.
simulate_vm(prog::VMProgram, input) :: NamedTuple   # output + intermediate state

# Round-trip check.
verify_vm_reversibility(prog::VMProgram) :: Bool
end
```

**Handoff alternatives considered (§Part IX milestone M0):**

| Handoff | Input shape | Decoupling | Verdict |
|---|---|---|---|
| A. `ParsedIR` (recommended) | Classical SSA, exported type | Max | **Adopted** |
| B. New `target=:reversible_vm` arm in `Bennett.lower()` | Same; called via dispatch | Medium | Deferred; requires Bennett.jl `lower.jl` mutation under 3+1 protocol and user approval (Rule 14). Filed as `docs/adr/0003-bennett-target-vm-dispatch.md`. |
| C. Post-SSA-liveness IR | Tighter coupling to internal helper | Low | Rejected; couples to a non-exported function. |

**Bennett.jl-side constraints inherited at the boundary:**

- `IRPhi` is classical-SSA (joins only). Phase 2 MUST add the symmetric
  split-φ when lowering to RSSA. The Hybrid SSA (Deworetzki-Schlecht-Meyer
  2024) construction is the model.
- `IRLoad` and `IRStore` are classical non-exchange memory operations
  (`Bennett.jl/src/ir_types.jl:157–179`). They violate the §3.2
  memory-as-exchange rule and therefore MUST NOT pass through into Phase-2
  RSSA unchanged. Phase 2 MUST include an `IRLoad`/`IRStore` → `Exchange`
  lowering pass that pairs every effective load with an explicit zero-write
  (and every store with a paired snapshot of the old value), per Vieri 1995
  §4.2.1. This pass is the Phase-2 equivalent of the "explicit zero-write
  paired with every effective load" rule in §3.2; it lives in a Phase-2
  pre-RSSA normalization phase between `ParsedIR` ingestion and RSSA
  emission.
- `IRCall` is inlined by Bennett.jl's `lower_call!`. Phase 2 receives an
  inlined single-function CFG. Cross-procedure analysis is out of scope for
  Phase 2.
- `IRAlloca` with dynamic `n_elems` is currently rejected by Bennett.jl's
  circuit target. Phase 2 *consumes* such allocas — they are precisely the
  unbounded-memory case the VM target exists to handle.
- `LoopGuard` is a `LoweringResult`-level concept, not a `ParsedIR` concept.
  Phase 2 does NOT receive `LoopGuard` data; loops are natively executed.

**Pin contract.** Phase 2 binds against `Bennett.jl` at SHA
`5731cec22a1fd29efe02d4dc21c2a57e655ecb47`. Repinning requires repeating the
M0 smoke test and updating `BENNETT_JL_PIN.md`.

### 3.8 Lean formalization

Phase 2 Lean targets, **bounded to abstract VM semantics only**:

1. Trace simulation theorem (Bennett-1973 baseline restated as a structural
   bisimulation between the abstract `step!/unstep!` semantics and the
   irreversible reference).
2. Round-trip theorem (`unrun!(run!(s, prog)) = s ∧ history(s) = []`).
3. Reversible RAM primitive equivalences (`Exchange` is an `Equiv` on the
   memory component of `IState`).
4. Output-channel non-aliasing theorem (`OutputRef ⊥ IState`).
5. Bennett-1989 pebble-game correctness for the lowering pass.

**Out of scope:** the Julia implementation, the LLVM frontend, Bennett.jl, the
RC3 reference compiler, the SAT solver behind the Meuli encoding. Scope creep
here has eaten months in adjacent repos (CLAUDE.md Rule 15).

**`0 sorry, 0 axiom`** applies from the first Lean commit.

**Tractability ADR.** Before any Lean code is written,
`docs/adr/0004-lean-tractability.md` MUST attempt a single-theorem proof
(theorem 2 above, restricted to a single-instruction subset) as a feasibility
probe. The Kaarsgaard et al. join-inverse-category Lean library is the prior-
art starting point. v3 §VIII open-question #5 (Lean 4 vs Coq vs Agda) is
*resolved* per CLAUDE.md Rule 15: **Lean 4.**

### 3.9 API and naming conventions (binding)

The following types and operations MUST appear in Phase 2 with these exact
names and signatures. Sources are spike artifacts; the spike's choices
survived the retrospective Q4 review.

- **`IState`** — instantaneous description. MUST contain at minimum `pc`,
  `locals` (an associative structure keyed by IR variable name), and `status`.
  Other fields permitted.
- **`RState`** — reversible wrapper. MUST be declared `mutable struct`. MUST
  contain `current::IState` and `history::Vector{T}` for an
  implementation-defined history element type `T`.
- **`step!(s::RState, prog) :: RState`** — forward one instruction. (Spike
  signature; Phase 2 MAY refactor to `step!(s::RState, instr)` by lifting
  pc-dispatch into the caller — that decision is a Phase-2 ADR, not a v4
  normative requirement.)
- **`unstep!(s::RState, prog) :: RState`** — backward one instruction. (Same
  ADR caveat.)
- **`run!(s::RState, prog; max_steps=…) :: RState`** — forward to halt or
  `max_steps`.
- **`unrun!(s::RState, prog) :: RState`** — backward to empty history.
- **`forward(instr, s::IState) :: IState`** — generic function dispatched
  per-instruction-type.
- **`inverse(instr, s::IState, prev) :: IState`** — generic function. `prev`
  is a history payload; its concrete type is per-instruction-type (Phase 2
  ADR `docs/adr/0006-inverse-prev-type.md` resolves whether `prev` is a
  single union type, an associated type per instruction, or `Any`).
- **`initial_state(prog) :: RState`** — construct from a program. MUST
  validate that the program is non-empty.
- **`is_halted(s::RState) :: Bool`** — terminal-status query.
- **`result(s::RState)`** — output query. MUST raise on non-halted state.

**Justification:** retrospective Q4 §"Naming conventions worth keeping";
spike artifacts `Types.jl`, `Interpreter.jl`, `BennettVMSpike.jl`.

### 3.10 Equality and hashing semantics (binding)

`IState` MUST override `Base.==` and `Base.hash` to compare **structurally**
across all fields. Specifically: `pc == pc`, `status === status`, and
`locals == locals` with structural dict equality (not `===` on the dict
object).

**Rationale.** Julia's default `==` on a struct containing a `Dict` field
reduces to `===` (identity) on the dict component. Without the override,
`unrun!(run!(s, prog)).current == initial_state(prog).current` silently
returns `false` regardless of implementation correctness, making the round-
trip invariant untestable. The override was added in spike Pass 1 at
`spike/src/Interpreter.jl:103–109`. v3 §5.3's "explicit overrides only where
round-trip equality forces it" is *always* triggered; v4 makes the override
unconditional.

### 3.11 Step ordering and exception safety (binding)

`step!` MUST compute `new_state = forward(instr, s.current)` BEFORE mutating
`s.history` or `s.current`. If `forward` raises an exception, `s.history` and
`s.current` MUST be unchanged.

**Rationale.** The Phase-0 Pass-1 implementation pushed the history snapshot
before calling `forward`. A `forward` exception left the history one entry
ahead of the state. Pass-1F reordered to compute-then-mutate; this is the
correct pattern. (Source: `spike/RETROSPECTIVE.md` Q3 "Unexpectedly hard";
spike `Interpreter.jl:175–187`.)

### 3.12 Discard-pop predicate (binding)

After a successful `forward`, if the resulting `IState` satisfies

```
new_state.status !== :running
  && new_state.pc == snapshot.pc
  && new_state.locals == snapshot.locals
```

then the pre-step snapshot MUST NOT be retained in `s.history`. This is the
*discard-pop predicate*: a step whose only observable effect is the status
bit carries no information worth preserving.

**Generalization for Phase 2.** Injective instructions (§3.2) push nothing
*by classification*, not via the predicate. The predicate handles the special
case of a status-only transition for non-injective instructions. Both rules
coexist.

**Consequence for the history-length invariant.** `length(s.history)` counts
only steps that retained a snapshot — NOT the total number of `step!` calls.
For the canonical countdown(n) program with a pure-status-flip `Halt`, this
means `length(history) == steps − 1` after termination. (Source: spike
`Interpreter.jl:182–186`; `test_history.jl:16–37,46–80`;
`spike/RETROSPECTIVE.md` Q1, Q2.3, Q2.4.)

### 3.13 Per-step inverse test (binding)

The Phase-2 test suite MUST include, for every new instruction kind added, a
*per-step inverse test*: snapshot every pre-step `IState` during forward
execution; during `unrun!`, assert `s.current == pre_states[i]` at each
backward step.

**Rationale.** Aggregate round-trip tests can mask middle-instruction inverse
bugs because a correct leading-instruction inverse later in the sequence
restores `s.current` regardless of corruption in the middle. The spike's
Pass 3 mutation-proof exposed this: swapping `prev` for `s` in
`inverse(::BinaryOp, ...)` did not initially break the aggregate round-trip
test, but did break the per-step test (19 RED on perturbation, 0 after
revert). (Source: `spike/test/test_roundtrip.jl:80–135`;
`spike/RETROSPECTIVE.md` Q3, Q4 §"Test patterns worth keeping".)

### 3.14 Golden master co-location (binding)

Every Phase-2 test program factory MUST be co-located with a *reference
irreversible Julia oracle* in the same file (or sibling file under
`test/reference/`). Forward execution of the Phase-2 program MUST agree
bit-for-bit with the oracle on the same inputs.

**Rationale.** The spike's `test/reference/countdown.jl` co-locates the
program factory and the oracle. This ensures any edit to the program factory
puts the oracle in immediate view. (Source: spike retrospective Q4 §"Test
patterns worth keeping".)

### 3.15 Property test discipline (binding)

Phase-2 property tests MUST use explicit seeds (e.g.,
`MersenneTwister(0xBE171973)`) and MUST include randomly-generated programs
*with control flow* (jumps, conditionals, bounded loops) — not only straight-
line programs. The spike's property tests were straight-line-only for
termination simplicity; Phase 2's RSSA-level CFG and uniform-loop-bound
analysis (§3.4) make termination-bounded random CFG generation tractable.

(Source: `spike/test/reference/property_programs.jl:1–24`; spike
retrospective Q4 §"Test patterns worth keeping" and Q9 — the straight-line
limitation is implicit in what Q9 flags as not-learned by the spike.)

### 3.16 Initial-state validation and result-query safety (binding)

- `initial_state(prog)` MUST raise a descriptive error if `prog` is empty.
- `result(s)` MUST raise an error if `s.current.status !== :halted`. The
  error message MUST include the actual status value.
- `unstep!(s, ...)` on empty history MUST raise `ErrorException` with a
  clear message. No silent no-op, no default state.

(Source: `spike/src/Interpreter.jl:119, 138, 206–214`; spike
retrospective Q2.7 — "`step!` on a halted or error state: silent no-op";
"`result(s)` on a non-halted state: throws ErrorException"; Q4 §"Test
patterns worth keeping" — fail-fast on empty `unstep!` history is the
"load-bearing correctness check for the round-trip invariant.")

### 3.17 Return / Halt distinction (binding for v5)

**For initial Phase-2:** `Return` and `Halt` MAY be unified or kept distinct.
The spike merged them because no call stack exists.

**For Phase-2.x (when subroutines land):** `Return` MUST pop a call frame
(restoring caller's `pc` and the caller's locals), and is NOT semantically
equivalent to `Halt`. A pure-status-flip `Halt` triggers the discard-pop
predicate; `Return` does NOT (because `pc` changes), so its snapshot MUST be
retained.

ADR `docs/adr/0007-return-vs-halt.md` records the decision when call stacks
land. (Source: spike retrospective Q4, Q8.3, §9.3.)

---

## Part IV: Reuse map (revised — file:line citations)

Every Phase-2 design decision answers "what published work does this replace,
and why?" before being accepted. The default response to discovering prior
art is **reuse or wrap**, not reimplement.

| Phase-2 component | Reuse from | Source path | Notes |
|---|---|---|---|
| RSSA IR taxonomy | RC3 (Java) | `references/implementations/RC3/compiler/src/main/java/rc3/rssa/instances/` (15 files) | Structurally isomorphic port to Julia. Cite Mogensen 2016 §3 per RC3's `@implSpec` annotations. |
| RSSA basic-block reversal | RC3 | `rc3/rssa/blocks/BasicBlock.java:23` | `BasicBlock.reversed()` = reverse list + per-instruction `.reverse()`. Algorithm verbatim. |
| RSSA label dispatch | RC3 | `rc3/rssa/pass/LabelEntry.java:7` (dual-address `DirectionVar<Integer>`); `rc3/rssa/pass/LabelTable.java` (dispatch class) | Dual-address (forward + backward) per label. |
| Aliasing analysis | RC3 | `rc3/januscompiler/pass/AliasingAnalysisPass.java:30` | Forbids RHS=LHS and same-var-twice in calls. Model for §3.5 output-channel pass. |
| Syntactic inversion for injective subset | TOPPS-janus | `references/implementations/TOPPS-janus/src/Jana/Invert.hs:23–69` | `invertStmt` pattern. Applies to Phase-2 injective instructions only. |
| Reversible if-fi / from-until inversion | TOPPS-janus | `Invert.hs:28–31` | Model for Phase-2 RSSA conditional inversion. |
| Pendulum exchange semantics | Vieri 1995 MS | `references/reversible-isa/vieri-1995-pendulum-ms.pdf` §4.2.1 (p. 32) | Memory-as-exchange rule (§3.2). |
| BobISA jump encoding | Thomsen–Axelsen–Glück 2012 | `references/reversible-isa/axelsen-yokoyama-2011-bobisa.pdf` | Source-label-encoding jumps (§3.2). NOTE: file misnamed; manifest §Citation-errata. |
| Min-cut delta-history selection | Enzyme (Moses–Churavy 2020) | `references/ad-and-checkpointing/enzyme-2020.pdf` §2 "Cache" (p. 4) | Port from LLVM IR to Phase-2 IR; algorithm verbatim. ADR 0002. |
| Periodic checkpoint + replay | rr (O'Callahan et al 2017) | `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf` §2.1 (p. 2) | Architecture model for deterministic regions (§3.3). |
| Pebble-game recursion (chains) | Bennett 1989; Knill 1995 | `references/foundational/Bennett1989_time_space_tradeoffs.pdf` Thm 1 (p. 768); `Knill1995_bennett_pebble_analysis.pdf` Thm 2.1 (p. 3) + Tables 1–2 (pp. 7–8) | Direct implementation; Knill tables as test oracles. |
| Pebble-game SAT (DAGs) | Meuli–Soeken–De Micheli 2019 | `references/quantum-uncomputation/Meuli2019_reversible_pebbling.pdf` §III (pp. 2–4); Table I (p. 4) | SAT encoding; Z3 or Julia-native solver. Table I (p. 4) as benchmark target (52.77% qubit reduction vs naive Bennett at 2.68× step overhead). |
| Quantum uncomputation (qubit-bounded) | Reqomp (Paradis et al 2024) | `references/quantum-uncomputation/Reqomp2024_uncomputation.pdf` | FFI binding for the quantum-oracle subset. Not in-tree. |
| Three-stage construction (Compute/Output/Cleanup) | Bennett 1973 | `references/foundational/bennett-1973-logical-reversibility.pdf` Table 1 (p. 528), Table 2 (p. 530) | Stage-1 implemented by spike; Stage-2/3 by Phase-2. |
| Output-channel type-theoretic model | Qurts (Hirata–Heunen 2025), Sparcl (Matsuda–Wang 2020) | `references/quantum-uncomputation/qurts-2024.pdf`; `references/reversible-languages/matsuda-wang-2020-sparcl.pdf` | Affine types / `pin` operator. Reference, not adopted wholesale. |
| Hybrid classical+reversible IR boundary | Deworetzki–Schlecht–Meyer 2024 | `references/reversible-ir/deworetzki-2024-hybrid-ssa.pdf` | Model for Bennett.jl classical-SSA → Phase-2 RSSA lowering. |
| Bennett.jl frontend / IR extraction | Bennett.jl | `Bennett.jl/src/extract/`, `Bennett.jl/src/ir_types.jl:347` | Consumed as `ParsedIR`. Pin SHA `5731cec`. §3.7. |
| **Float64 reversibility (SoftFloat dispatch)** | Bennett.jl | `Bennett.jl/src/softfloat_dispatch.jl` + `Bennett.jl/src/softfloat/` (~30 files) | **Wholesale inheritance.** No FP-reversibility code in BennettVM. §3.6 §3. |
| Persistent-tree heap strategy (for dynamic-N alloca) | Bennett.jl | `Bennett.jl/src/lowering/memory.jl:75–98` (`_lower_alloca_dynamic_n!`) | Reused for §3.6.2 case A; extended in BennettVM for full generality. |
| Maximum LLVM opcode dispatch | Bennett.jl | `Bennett.jl/src/extract/instructions.jl` (~2516 LOC) | Inherited via `ParsedIR`; BennettVM wires the two gaps (`fpext`/`fptrunc` LLVM-opcode dispatch and `frem`). §3.6.1. |

### 4.1 Explicit non-reuse

- **janus-vesta** (`references/implementations/janus-vesta/`) is NOT a model
  for Phase-2 ISA: its `MOV` is a destructive non-exchange (`execute.rs:618`,
  violating Vieri 1995 §4.2.1), and its jumps do not encode source labels
  (`execute.rs:765`). The "Janus ISA" name is misleading.
- **jana** and **evincarofautumn-janus** offer nothing beyond TOPPS-janus for
  Phase-2 purposes; included only for completeness.
- **Quantum Register Machine (Zhang–Ying 2025)** is out of scope for Phase 2.

---

## Part V: Phase-1 retrospective summary

This section replaces v3 Part V (Phase-0 spike specification). The spike
closed 2026-05-23 with 789/789 tests; the retrospective is at
`spike/RETROSPECTIVE.md` and remains the authoritative artifact. v4 § cross-
references below.

### 5.1 Spike result

Bennett-1973 trace VM, Stage 1 only, in `spike/`. Eight bytecode instructions
(`Const`, `Move`, `UnaryOp`, `BinaryOp`, `Jump`, `JumpIf`, `Return`, `Halt`).
`Int64` locals. Full-snapshot history. 789/789 tests including a per-step
inverse test that was mutation-proof verified. Git tag `spike-0-archived`,
filesystem chmod -w.

### 5.2 What carried into Phase 2

| Spike artifact | v4 normative location |
|---|---|
| `IState`/`RState` partition | §3.9 |
| `step!`/`unstep!`/`run!`/`unrun!` naming | §3.9 |
| `inverse(instr, s, prev)` signature | §3.9 |
| Discard-pop predicate | §3.12 |
| Fail-fast on empty `unstep!` history | §3.16 |
| Per-step inverse test pattern | §3.13 |
| Golden master co-location | §3.14 |
| Seeded property tests | §3.15 |
| `mutable struct RState` | §3.9 |
| `Base.==` / `Base.hash` overrides on `IState` | §3.10 |
| Forward-before-push step ordering | §3.11 |
| `initial_state` empty-program validation | §3.16 |

### 5.3 What was rejected from the spike

| Spike artifact | Reason rejected | v4 replacement |
|---|---|---|
| Full-snapshot history per step | Worst point on time-space tradeoff; spike existed to confirm | §3.3 three-layer history |
| Flat `Vector{AbstractInstruction}` + integer pc | Not a compiler IR | §3.1 RSSA basic blocks |
| Non-injective `Const`/`Move`/`UnaryOp`/`BinaryOp` as uniform primitives | All pay full snapshot regardless of information loss | §3.2 injective/non-injective partition |
| Spike `Move` (destructive copy) | Information-losing on `dst` | Pendulum `Exchange` (§3.2) |
| `Return ≡ Halt` equivalence | Acceptable for no-call-stack spike | §3.17 distinct in v5 |

### 5.4 Errata applied from spike retrospective Q7

1. BobISA citation: Axelsen–Yokoyama 2011 LATA → Thomsen–Axelsen–Glück 2012
   RC. Applied throughout §2.4 and Appendix A.
2. Mogensen RIL: standalone-paper framing → Mogensen 2015 LNCS 9138 §3.
   Applied to §2.3 and Appendix A.
3. "Bool-typed regs" wording in v3 §5.1: removed; locals are uniformly
   `Int64` in the spike; v4 §3.6 specifies the Phase-2 type universe.
4. `struct RState`: v3 §5.3 template code corrected to `mutable struct
   RState`. v4 §3.9.

### 5.5 What the retrospective surfaced beyond Q1–Q9

(From the spike code itself, elevated by the deep-read agent during v4
synthesis.)

- The `_copy_locals` helper at `spike/src/Instructions.jl:74` enforces fresh-
  dict discipline at a single point; Phase 2 SHOULD consider whether
  `IState.locals` should be an immutable persistent map so that this
  discipline is type-enforced rather than convention. (See §8 Q-FP for the
  related v5 deferral.)
- Property tests are straight-line-only. v4 §3.15 mandates control-flow
  random programs in Phase 2.
- The countdown program exercises 5 of 8 instruction kinds. v4 §3.13
  requires per-step inverse coverage for every instruction kind, closing
  the gap.

---

## Part VI: Phase-2 success criteria

The full ordered work breakdown is in §Part IX (M0–M12). This Part VI
extracts the **eight load-bearing success criteria** — the subset of M0–M12
whose completion defines "Phase 2 is done." Cross-references to §Part IX
milestone numbers are explicit.

- **SC1 — Bennett.jl handoff smoke** (§Part IX M0). `lower_vm(parsed)`
  accepts a Bennett.jl `ParsedIR` for `collatz_steps(::Int8)` and produces
  a Phase-2 RSSA program without error. *Gated by §Part IX M5 (RC3 pre-read).*
- **SC2 — Cost measurement** (§Part IX M1). Benchmark full-snapshot vs delta
  vs checkpoint-replay; default checkpoint interval set in §3.3.
- **SC3 — Forward correctness** (§Part IX M3). A Julia function with a
  dynamic `while` loop (fixed-point Taylor in Q-format or Collatz) compiles
  and forward-executes bit-for-bit against the reference irreversible Julia
  implementation.
- **SC4 — Round-trip correctness** (§Part IX M4, M7). `unrun!` restores
  initial state with empty history AND sublinear-in-T peak history bytes
  for the injective-dominated subset.
- **SC5 — Pebble-game lowering** (§Part IX M8). The Bennett-1989 pebble-game
  pass produces, on a uniformly-bounded program, a quantum-oracle-suitable
  uniform circuit family. At least one example accepted by Reqomp or
  simulated correctly.
- **SC6 — RC3 `rvm` pre-read documented** (§Part IX M5; ADR 0001).
  Required before any Phase-2 IR code is written.
- **SC7 — Lean formalization** (§Part IX M10, M11). All five §3.8 targets
  discharged with `0 sorry, 0 axiom`.
- **SC8 — Per-step inverse coverage** (§Part IX M7). Per-step inverse test
  (§3.13) passes for every Phase-2 instruction kind.
- **SC9 — Four motivating programs compile and round-trip** (§3.6.2; §Part
  IX M_DICT, M_DYN, M_NESTED, plus inherited FP). Each of `fdict`, `frtN`,
  `matrix_sum`, `collatz_steps` (the canonical programs in §3.6.2) MUST
  compile under `reversible_compile(..., target=:reversible_vm)` and pass a
  round-trip test. **This is the load-bearing user-facing milestone — if
  SC9 fails, BennettVM has no reason to exist.**
- **SC10 — Float64 round-trip via inherited SoftFloat dispatch** (§3.6).
  `reversible_compile(x -> x*x + 3x + 1, Float64; target=:reversible_vm)`
  matches the equivalent Bennett.jl circuit-target output bit-for-bit on a
  representative input set, by virtue of inheriting Bennett.jl's
  `softfloat_dispatch.jl`. No FP-reversibility code is written in
  BennettVM.

---

## Part VII: Risks and mitigations

Carried from v3 §7 with updates:

7.1 **Phase-0 retrospective is insufficiently load-bearing.** *Mitigation:*
already executed; retrospective is comprehensive (264 LOC, nine questions);
v4 §3.9–§3.17 codify its findings.

7.2 **v4 retreads ground that should have been settled in v3.** *Mitigation:*
Part II is the literature backstop; the four parallel research subagents
(literature, Bennett.jl, spike, implementations) that produced the input for
v4 have already run.

7.3 **Phase 2 reinvents RSSA, BobISA, or Enzyme min-cut.** *Mitigation:*
§Part IV is the binding reuse map; every Phase-2 commit cites it.

7.4 **Quantum oracle synthesis overpromise.** *Mitigation:* §3.4 ties the
quantum-oracle subset to a uniform-bound analysis; programs failing the
bound are rejected with a clear error rather than producing a wrong
"circuit family".

7.5 **Bennett.jl frontend changes break BennettVM integration.**
*Mitigation:* `ParsedIR` is exported and stable at pin `5731cec`. Repinning
requires repeating M0. §3.7.

7.6 **Lean formalization scope creeps.** *Mitigation:* §3.8 enumerates the
five targets exhaustively. The tractability ADR (`docs/adr/0004`) gates the
first Lean commit.

7.7 **The throwaway spike becomes load-bearing.** *Mitigation:* already
archived (`spike-0-archived`, chmod -w). Phase 2 starts from empty `src/`+
`test/`. CLAUDE.md P0.7.

7.8 **Bennett.jl integration requires `lower.jl` mutation prematurely.**
*Mitigation:* §3.7 specifies Handoff A (`ParsedIR` consumed externally);
Handoff B (target dispatch arm) is a later integration milestone with the
3+1 protocol and user approval.

7.9 **A subset of Bennett.jl `ParsedIR` constructs are not yet supported by
Phase 2.** *Mitigation:* Phase 2 emits clear "not supported" errors with
the offending instruction kind, not silent acceptance with wrong results.
The supported subset grows monotonically across Phase-2.x releases.

---

## Part VIII: Open questions for v5

Reduced from v3 §VIII's six items to two genuine open questions plus a
deferred-decision ADR queue.

### 8.1 Genuinely open

1. **Divergence handling.** Reversible simulation results assume halting
   computations. BennettVM uses a `max_steps` guard for the trivial case,
   but structural divergence detection (proving that a Julia loop with a
   data-dependent condition halts on all inputs) is unresolved. v5 may
   inherit Bennett.jl's existing termination-bound machinery
   (`max_loop_iterations` in `Bennett.jl/src/lowering/driver.jl`) or commit
   to a separate analysis.

   (v3 §VIII item #1 — FP reversibility scheme — was open in v3, deferred
   in the v4 initial draft, and resolved in v4.1 by Bennett.jl's SoftFloat
   dispatch. No longer open.)

### 8.2 Resolved by v4 (no longer open)

| v3 §VIII item | v4 disposition |
|---|---|
| #1 IR extensions to RSSA | §3.1: structurally isomorphic to RC3 taxonomy + listed extensions |
| #2 Bennett.jl integration boundary | §3.7: `ParsedIR` consumed externally (Handoff A). Caveat: resolved in the sense that Phase 2 consumes `ParsedIR` (classical SSA) and lowers it to RSSA internally; the deeper question of whether a future Bennett.jl version could emit RSSA directly is deferred to Handoff B / ADR 0003. |
| #3 Default numeric subset | §3.6: integers and Q-format; FP deferred |
| #4 Pebble-game in-tree vs FFI | §3.4: Knill recursion + Meuli SAT in-tree; Reqomp FFI for qubit-budgeted quantum subset |
| #5 Lean 4 vs Coq vs Agda | §3.8: Lean 4 per CLAUDE.md Rule 15 |
| #6 Publish at RC | Deferred to user; not a PRD-blocking decision |

### 8.3 ADR queue (filed during Phase 2, not v5)

| ADR | Title | Gates |
|---|---|---|
| 0000 | Handoff smoke test (Bennett.jl `ParsedIR` consumed end-to-end) | M0 |
| 0001 | RC3 `rvm` pre-read documented | M0 (precedes IR code) |
| 0002 | Enzyme min-cut mapping (LLVM IR → Phase-2 RSSA dataflow) | Delta-history selector |
| 0003 | Bennett.jl `target=:reversible_vm` dispatch arm (requires user approval per Rule 14) | Phase-2.x integration |
| 0004 | Lean formalization tractability (one-theorem feasibility probe) | First Lean commit |
| 0005 | Pebble-game pass vs Reqomp FFI (per-subprogram routing rule) | M4 |
| 0006 | `inverse(instr, s, prev)` `prev` type — union, associated, or `Any` | Phase-2 IR codegen |
| 0007 | `Return` vs `Halt` distinction (when call stacks land) | Phase-2.x subroutines |

---

## Part IX: Phase-2 work breakdown (initial)

Ordered milestones. Each is a beads epic. The first beads epic at Phase-2 open
is `bennettvm-phase2-epic` (created when v4 ratifies and `PHASE.md` flips).

M0. **Bennett.jl handoff smoke test.** ADR 0001 first (RC3 `rvm` built and
exercised), then ADR 0000 (`lower_vm(parsed::ParsedIR)` accepts a trivial
program end-to-end). Output: an empty `VMProgram` type, a stub `lower_vm`,
and a passing smoke test.

M1. **Cost measurement.** Benchmark history strategies. Output: a measurement
report and a default checkpoint interval.

M2. **IR design and basic-block infrastructure.** Port RC3 RSSA taxonomy to
Julia. No Lean yet. ADR 0006 first.

M3. **Forward-only interpreter.** Run a Bennett.jl `ParsedIR` for an integer
arithmetic program in Phase-2 IR. No history. No `unrun!`.

M4. **History layer 3 (periodic checkpoints).** rr-style. No min-cut yet.
`unrun!` works for short programs.

M5. **History layer 1 (no log for injective).** Partition the ISA; remove
checkpoints for injective instructions.

M6. **History layer 2 (delta with min-cut).** ADR 0002 first. Port Enzyme
min-cut analysis. Default checkpoint interval validated against M1.

M7. **Per-step inverse and golden master.** Phase-2 test suite reaches
parity with the spike's mutation-proof coverage.

M8. **Pebble-game lowering pass.** ADR 0005 first. Knill recursion for
chains; Meuli SAT for DAGs. M4 success criterion checked.

M9. **Output-channel `OutputRef`.** Static non-aliasing pass. RC3 aliasing-
analysis port.

M10. **Lean baseline.** ADR 0004 first. Theorems 1–3 (trace simulation,
round-trip, RAM equivs).

M11. **Lean output-channel and pebble-game theorems.** §3.8 targets 4–5.

M12. **Bennett.jl target dispatch arm.** ADR 0003 (requires user approval
per CLAUDE.md Rule 14). `Bennett.lower(parsed; target=:reversible_vm)`
calls into BennettVM.

Each milestone produces a closeable beads epic. Phase 2 is *complete* when
M0–M12 close and the eight load-bearing success criteria SC1–SC8 (§Part VI)
are met.

---

## Appendix A: References (errata applied)

### A.1 Foundational reversible computation

- Bennett, C.H. *Logical reversibility of computation.* IBM J. Res. Dev.
  17(6), 525–532 (1973). `references/foundational/bennett-1973-logical-reversibility.pdf`
  SHA256 `e61ad668…0687`.
- Bennett, C.H. *Time/space trade-offs for reversible computation.* SIAM
  J. Comput. 18(4), 766–776 (1989). `references/foundational/Bennett1989_time_space_tradeoffs.pdf`.
- Knill, E. *An analysis of Bennett's pebble game.* arXiv:math/9508218
  (1995). LANL LAUR-95-2258. `references/foundational/Knill1995_bennett_pebble_analysis.pdf`.
- Buhrman, H., Tromp, J., Vitanyi, P. *Time and space bounds for reversible
  simulation.* arXiv:quant-ph/0101133 (2001). `references/foundational/buhrman-tromp-vitanyi-2001.pdf`.
- Vitanyi, P. *Time, space, and energy in reversible computing.*
  arXiv:cs/0504088 (2005). `references/foundational/vitanyi-time-space-energy.pdf`.
- Landauer, R. *Irreversibility and heat generation in the computing
  process.* IBM J. Res. Dev. 5(3), 183–191 (1961). [TIB ILL pending.]

### A.2 Reversible imperative languages

- Yokoyama, T., Glück, R. *A reversible programming language and its
  invertible self-interpreter.* PEPM 2007. `references/reversible-languages/yokoyama-glueck-2007-pepm.pdf`.
- Glück, R., Yokoyama, T. *A linear-time self-interpreter of a reversible
  imperative language.* IEICE Trans. Inf. Syst. 2016. `references/reversible-languages/glueck-yokoyama-2016-rwhile.pdf`.
- Lutz, C., Derby, H. *Janus: a time-reversible language.* Caltech, 1986.
  `references/reversible-languages/lutz-derby-1986-janus.pdf`.
- Haulund, T. *ROOPL.* MS thesis, U. Copenhagen, 2017.
  `references/reversible-languages/haulund-2017-roopl.pdf`.

### A.3 Reversible functional languages and type systems

- Yokoyama, T., Axelsen, H.B., Glück, R. *Towards a reversible functional
  language.* RC 2011, LNCS 7165 ch.2. `references/reversible-languages/yokoyama-axelsen-glueck-2011-rfun.pdf`.
- Jacobsen, P.A.H., Kaarsgaard, R., Thomsen, M.K. *CoreFun.* RC 2018.
  `references/reversible-languages/jacobsen-2018-corefun.pdf`.
- Matsuda, K., Wang, M. *Sparcl.* JFP 34, 2024 (definitive version of
  ICFP 2020 PACMPL 4). `references/reversible-languages/matsuda-wang-2020-sparcl.pdf`.
- James, R.P., Sabry, A. *Theseus.* RC 2014. `references/reversible-languages/james-sabry-2014-theseus.pdf`.
- Hirata, K., Heunen, C. *Qurts.* POPL 2025 (arXiv:2411.10835).
  `references/quantum-uncomputation/qurts-2024.pdf`.

### A.4 Reversible intermediate languages

- Mogensen, T.Æ. *RSSA: A Reversible SSA Form.* PSI 2015, LNCS 9609 (2016).
  `references/reversible-ir/mogensen-2016-rssa.pdf`.
- Mogensen, T.Æ. *Garbage Collection for Reversible Functional Languages.*
  RC 2015, LNCS 9138 (RIL introduced in §3, not as a standalone paper).
  `references/reversible-ir/mogensen-ril.pdf`.
- Deworetzki–Meyer 2021, *Compiling Janus to RSSA*, RC 2021.
  `references/reversible-ir/deworetzki-meyer-2021-janus-to-rssa.pdf`.
- Deworetzki 2022, *Optimizing Reversible Programs*, RC 2022.
  `references/reversible-ir/deworetzki-2022-optimizing.pdf`.
- Deworetzki 2023, *Optimization of Reversible Control Flow Graphs*, RC 2023.
  `references/reversible-ir/deworetzki-2023-cfg-opt.pdf`.
- Deworetzki, Schlecht, Meyer 2024, *Connecting Reversible and Classical
  Computing Through Hybrid SSA*, RC 2024.
  `references/reversible-ir/deworetzki-2024-hybrid-ssa.pdf`.

### A.5 Reversible ISAs

- Vieri, C.J. *Pendulum: A reversible computer architecture.* MS thesis,
  MIT, 1995. `references/reversible-isa/vieri-1995-pendulum-ms.pdf`.
- Vieri, C.J. *Reversible Computer Engineering and Architecture.* PhD
  thesis, MIT, 1999. `references/reversible-isa/vieri-1999-reversible-arch-phd.pdf`.
- Frank, M.P. *Reversibility for efficient computing.* PhD thesis, MIT,
  1999. `references/reversible-isa/frank-1999-thesis.pdf`.
- **Thomsen, M.K., Axelsen, H.B., Glück, R.** *A Reversible Processor
  Architecture and Its Reversible Logic Design.* RC 2012, DOI
  10.1007/978-3-642-29517-1_3. (BobISA. v3 §2.5 incorrectly cited "Axelsen–
  Yokoyama 2011 LATA"; no such paper exists. v4 corrects this.)
  `references/reversible-isa/axelsen-yokoyama-2011-bobisa.pdf` (filename
  predates correction).
- Mogensen, T.Æ. *Fast Control for Reversible Processors.* RC 2022.
  `references/reversible-isa/mogensen-2022-fast-control.pdf`.

### A.6 Quantum uncomputation

- Paradis, A., Bichsel, B., Cohen, A., Vechev, M. *Unqomp.* PLDI 2021.
  `references/quantum-uncomputation/unqomp-2021.pdf`.
- Paradis, A., Bichsel, B., Vechev, M. *Reqomp.* Quantum 8:1258 (2024),
  arXiv:2212.10395. `references/quantum-uncomputation/Reqomp2024_uncomputation.pdf`.
- Meuli, G., Soeken, M., De Micheli, G. *Reversible pebbling game for
  quantum memory management.* DATE 2019, arXiv:1904.02121.
  `references/quantum-uncomputation/Meuli2019_reversible_pebbling.pdf`.
- Quist, N. et al. *Tight Bounds on the Spooky Pebble Game.* Quantum (2025),
  arXiv:2110.08973. `references/quantum-uncomputation/spooky-pebble.pdf`.
- Zhang, Z., Ying, M. *Quantum Register Machine.* PACMPL 9(PLDI), art. 180
  (2025), arXiv:2408.10054. `references/quantum-uncomputation/zhang-ying-2025-qrm.pdf`.

### A.7 Reverse-time debugging

- O'Callahan, R., Jones, C., Froyd, N., Huey, K. *Engineering Record And
  Replay For Deployability.* USENIX ATC 2017, arXiv:1705.05937.
  `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf`.

### A.8 Compiler-based AD

- Moses, W., Churavy, V. *Instead of Rewriting Foreign Code for Machine
  Learning, Automatically Synthesize Fast Gradients.* NeurIPS 2020,
  arXiv:2010.01709. `references/ad-and-checkpointing/enzyme-2020.pdf`.
- Moses, W.S. et al. *Reverse-mode automatic differentiation and
  optimization of GPU kernels via Enzyme.* SC 2021.
  `references/ad-and-checkpointing/enzyme-gpu-2021.pdf`.

### A.9 Implementations consulted (source clones, not papers)

- RC3, `references/implementations/RC3/` (SHA 1b4c357). **Required pre-read
  per §3.1 / M5.**
- TOPPS-janus, `references/implementations/TOPPS-janus/` (kirkedal/Jana, SHA f1330f4).
- jana, `references/implementations/jana/` (SHA 5b51b57). Pedagogical only.
- janus-vesta, `references/implementations/janus-vesta/` (SHA b798194). **Do
  NOT model Phase-2 ISA on this** (§4.1).
- evincarofautumn-janus, `references/implementations/evincarofautumn-janus/` (SHA e5fe853). Pedagogical only.
- Enzyme, `references/implementations/Enzyme-src` (symlink to Bennett.jl's external Enzyme). **Required pre-read for ADR 0002.**

---

## Appendix B: Phase-2 ADR queue (initial)

See §8.3 table. ADRs land in `docs/adr/` as filed.

---

## Appendix C: Errata applied from v3

| v3 Locus | Defect | v4 Correction |
|---|---|---|
| §2.5 | BobISA cited as Axelsen–Yokoyama 2011 LATA | Thomsen–Axelsen–Glück 2012 RC, DOI 10.1007/978-3-642-29517-1_3. §2.4. |
| §2.4 | RIL implied as standalone paper | Mogensen 2015 LNCS 9138 §3. §2.3. |
| §5.1 | "Bool-typed regs for `:not`" | Removed; spike locals are uniformly `Int64`; v4 §3.6 specifies the v4 type universe. |
| §5.3 | `struct RState` (immutable) | `mutable struct RState`. §3.9. |
| §5.3 | "explicit equality overrides only where round-trip forces it" | Unconditional `Base.==`/`Base.hash` overrides on `IState`. §3.10. |
| §5.4.3 | `length(history) == steps_taken` (ambiguous) | Discard-pop predicate explicit; `length(history)` counts retained snapshots only. §3.12. |
| §VIII | Six open questions | Two open; four resolved; ADR queue filed. §8. |

---

## Closing note

This PRD is the input to Phase 2, not the output. Phase 2's deliverable is
a working production reversible VM with the milestones in §Part IX
discharged and the success criteria in §Part VI met. v5 is written when
Phase 2 closes or when v4 is found wanting in a way that warrants
re-ratification, whichever comes first.

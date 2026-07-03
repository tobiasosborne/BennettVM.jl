# Design note — Running an emulator (NES / 6502) on BennettVM, reversibly

> **Status: EXPLORATORY / feasibility proven.** 2026-07-03. Not an accepted
> architecture decision — a scoped feasibility study with a working MVP. The
> north-star workstream is tracked by epic `bennettvm-v5eb` (see §8). Every
> technical obstacle named here already has a bead (§6); this note ties them to
> a concrete, motivating target and adds the one genuinely missing piece (an
> input tape, §5).

## 0. TL;DR

The pitch was: *"decompile Super Mario Bros to LLVM IR and run it on BennettVM,
logging graphics/sound/input to a side tape."* There are **two** ideas hiding in
that sentence with wildly different verdicts:

- **Lift the ROM's 6502 code → LLVM** — **dead end.** Undecidable statically
  (indirect jumps, self-modifying code, bank-switching); the one serious attempt
  (jamulator) was abandoned. Don't.
- **Compile an *emulator* to LLVM, feed the ROM as data, log side effects to a
  tape** — **not crazy; it's the right architecture,** it fits BennettVM's model,
  and reversibility buys frame-perfect rewind *for free*.

**We built a working MVP of the second path.** A genuine (tiny) MOS 6502 core —
fetch-decode-execute over hand-assembled machine code, RAM load/store, a
data-dependent backward branch — compiled through Bennett.jl's C front-end,
**executed forward on BennettVM matching native C bit-for-bit, and un-ran to its
exact initial state.** Reproducer in [`emulator-mvp/`](emulator-mvp/).

The gap from this MVP to running `nestest.nes` (the canonical NES CPU test ROM)
is **legible, not fundamental**: it is a handful of already-filed front-end/VM
beads plus one new input-tape design, with a known performance wall (reverse is
L3-replay-bound). This note specs that path.

---

## 1. Why lifting the ROM is the wrong path

Static binary→LLVM lifting is barely solved even for x86 (McSema, rev.ng both
fail to lift-and-recompile SPEC CPU 2006). For the NES specifically it is
**structurally impossible to do statically**, because on the NES "the program"
is not the ROM bytes — it is the runtime co-execution trajectory of CPU + PPU +
APU + mapper. Concrete blockers (all from Andrew Kelley's *jamulator*
post-mortem, the only serious 6502→LLVM static recompiler, abandoned):

| Blocker | Why it kills static lifting |
|---|---|
| Indirect / computed jumps (`JMP ($1234)`, jump tables) | Targets resolve at runtime; jump tables are indistinguishable from data. Can't emit code for targets you can't enumerate. |
| Self-modifying code | SMB1 writes into and re-executes its own ROM range; abuses `BIT abs` as a 3-byte NOP. Static lifting assumes code is immutable. |
| Bank switching (mappers) | The same CPU address holds *different* code depending on runtime mapper state. No single static address→instruction map exists. |
| Cycle-accurate MMIO timing | PPU/APU run in parallel with the CPU via memory-mapped registers. The semantics are incomplete without a concurrent hardware model. |

Every practical NES tool — and even the one academic "6502→LLVM" thesis (a
dynamic JIT, not a static lifter) — is an **emulator**. So are we.

## 2. The right architecture: emulator-as-the-program

Keep the ROM as **data**. Compile a small emulator (6502 core + RAM + mapper +,
later, PPU/APU) to LLVM IR; the ROM is an input byte array. Every static
obstacle above evaporates into ordinary runtime dataflow: indirect jumps become
a `switch` on a PC variable, self-modifying code becomes an array write,
bank-switching becomes an index change.

```
 ROM bytes (data)  ─┐
 input movie (data) ┼─►  emulator.c ──clang──► LLVM IR ──Bennett.jl──► VMProgram ──run!──► forward run
                    ┘                          (front-end)  (lower_vm)      │             + history tape
                                                                            └──unrun!──►  exact rewind
                                                                     side effects ──►  output tape (video/audio)
```

A bare 6502 core is small: **~500–1000 LOC** (reference: `fake6502` /
`MyLittle6502`, ~971-line single-file public-domain C). `nestest.nes` needs
*only* CPU + 2 KB RAM + mapper-0 — no PPU, no APU, no input, no rendering — and
**self-reports pass/fail by leaving `$00` in RAM `$0002`/`$0003`**. It is the
ideal first target.

## 3. The MVP we built (E0 — DONE)

[`emulator-mvp/mos6502.c`](emulator-mvp/mos6502.c) is a real fetch-decode-execute
6502 subset (8 sparse opcodes: `LDA# STA-zp LDA-zp ADC# INC-zp CMP-zp BNE BRK`).
ROM + RAM share one `calloc`'d byte array; the ROM is written in, then *fetched
at a runtime PC*. A hand-assembled guest program computes `acc += 5, n times`
via the guest's **own backward relative branch** (BNE), returning `5·n`.

**Pipeline** (mirrors the proven `test_c_hashtable_e2e.jl` exactly):

```
clang -O0 -S -emit-llvm -fno-discard-value-names mos6502.c -o mos6502.O0.ll
SET  = Bennett.extract_parsed_ir_set_from_ll("mos6502.O0.ll"; ptr_cells=true)
prog = BennettVM.lower_vm(SET; entry=:mos6502)      # → 406 VM instructions
run!(rs, prog; checkpoint_interval=32); unrun!(rs, prog)
```

**Result** — every input passes forward (vs native-C golden) **and** round-trips:

| n | VM result | native C | forward | reverse | round-trip |
|---|---|---|---|---|---|
| 1 | 5 | 5 | 0.00 s | 0.06 s | ✓ |
| 10 | 50 | 50 | 0.01 s | 0.23 s | ✓ |
| 51 | 255 | 255 | 0.04 s | 1.20 s | ✓ |
| 0 (budget-cap, 4000 ops) | 0 | 0 | 1.98 s | 6.97 s | ✓ |

`rs.current == rs.initial`, history empty, arena/stack cursors retracted to 0.
Run it yourself: `julia --project docs/design/emulator-mvp/run_mvp.jl`.

## 4. Feasibility matrix — empirically measured, not inferred

Each requirement was probed with a minimal reproducer on this repo's live
toolchain (`emulator-mvp/smoke6502.jl`, `smoke_dispatch.jl`):

| # | Requirement (what a 6502 core needs) | Status TODAY | Evidence |
|---|---|---|---|
| 1 | **Unbounded, data-dependent main loop** | ✅ **MET** | Collatz-style `while` round-trips; the MVP's fetch-decode loop runs a runtime # of iterations. This is the make-or-break, and it passes. |
| 2 | **Mutable RAM, read/write at a runtime index, reversible** | ✅ **MET (heap)** | MVP `calloc`'d RAM with `mem[pc]`, `mem[addr]` at runtime indices round-trips bit-for-bit. |
| 3 | **256-way opcode dispatch** | ✅ **MET (sparse)** | Sparse real-6502 opcodes, binary-tree, and control-divergent dispatch all pass. *Only* dense-tabulatable arms trip LLVM's switch-lookup-table transform (→ #6a). |
| 4 | **Output side-effect tape** (video/audio) | 🔴 **MISSING** | `OutputRef` is PRD-only (`bennettvm-m6c` et al., open). |
| 5 | **Input tape** (controller reads = nondeterministic input) | 🔴 **MISSING + actively rejected** | Nondeterministic callees fail loud at ingest today; no recording mechanism. **The one gap with no existing bead** — see §5. |

The headline: **requirements 1–3, the "can a CPU even run" core, are green
today.** 4 and 5 are the I/O model, which is exactly the interesting new design.

## 5. The I/O tape design (the genuinely novel piece)

The user's instinct — "log the syscalls on another tape" — is right for
**output** and half-right for **input**. The subtlety:

- **Output** (framebuffer, audio samples) is a *pure function of state*; it flows
  *out* and never needs to be un-done. Model it as `OutputRef` (already specced,
  `bennettvm-m6c`/`6ox`/`rlx`/`agm`): a typed, single-use, **unrecorded** write
  channel, external to `IState`. `unrun!` simply doesn't replay it. Emulator
  `ppu_write(x)` / `apu_sample(x)` → append to the output tape. ✅ fits.

- **Input** (controller reads) is the hard part: it is *nondeterministic data
  flowing IN*, and a reversible replay engine must be **deterministic**. Raw
  `read_controller()` would crash ingest (nondeterminism is rejected). The fix is
  the model speedrunning already invented — a **recorded input movie (TAS
  tape)**: a pre-recorded, append-only byte stream of per-frame controller
  states. Then:

  > emulator + fixed input tape = a fully deterministic closed function.
  > Forward = play the movie (advance an input-tape cursor, a monotone counter
  > that IS recordable/reversible). Reverse = retract the cursor. Output =
  > logged, discarded on reverse.

  This is a new, small, well-scoped primitive: an **`InputRef`** dual to
  `OutputRef` — a typed, append-only, *cursor-reversible* read channel. Filed as
  `bennettvm-6dko` (§8). It is the conceptual counterpart of "record
  nondeterminism once, replay determinism" — BennettVM already cites that
  philosophy but only implements the *reject* half.

**The payoff worth stating:** with both tapes, a **reversible** NES emulator makes
`unrun!` *be* a frame-perfect savestate/rewind — a TAS engine where rewind is a
theorem, not a feature.

## 6. Frontier obstacles → existing beads (validation)

The spike independently rediscovered the exact known frontier. Nothing here is a
surprise; everything is already tracked:

| Obstacle hit in the spike | Existing bead |
|---|---|
| a. C stack array `[64 x i8]` → unsupported 2-index GEP (`…,0,%idx`); dense Julia `switch`→lookup-table GEP is the same wall (Bennett-qal5/U16) | **`bennettvm-dzd`** (P2) — "C aggregate arrays (int a[N]) emit 2-index GEP rejected by Bennett.jl (U16)". *Workaround today: use `calloc`'d pointer RAM (single-index GEP), as the MVP does.* |
| b. Pure-**Julia** emulator: `zeros()` heap-alloc emits `movq %fs:0` GC thread-ptr **inline asm** → rejected (Bennett-5oyt/U15) | Julia array path: **`bennettvm-m9i`** (GenericMemory recognizer) + the `fdict`/gc-alloc CW-D workstream. *Workaround today: use the **C path**, as the MVP does.* |
| c. ROM image / static lookup tables as initialized memory | **`bennettvm-416r.4`** (P1) — globals as initialized VM memory segments. |
| d. Output side-effect channel | **`bennettvm-m6c`/`6ox`/`rlx`/`agm`** (M10 OutputRef). |
| e. Reverse cost dominated by L3 replay | **`bennettvm-uom`** (L1 Exchange lowering → zero-history memory ops) + **`bennettvm-w0a0`** (the perf wall itself). |
| f. Input recording (nondeterministic input) | **none — new** → `bennettvm-6dko` (§8). |

## 7. Performance — the honest wall

Measured on the MVP: reverse throughput ≈ **570 guest-opcodes/sec** at K=32
(the n=0 case: 4000 opcodes reversed in ~7 s), because reverse is L3
checkpoint-replay. Forward is ~50× faster.

Projected to a real NES frame (~10–15k CPU instructions):

- **forward** ≈ 0.5 s/frame → ~1–2 fps forward-only (a slideshow, but it *runs*).
- **reverse** ≈ 20–25 s/frame at today's L3-only reversal.

So: **this will not play Mario at 60 fps, and that is not the goal.** The goal is
a *reversible* execution artifact. `bennettvm-uom` (L1/L2 memory-delta lowering)
is the lever that turns the memory-heavy emulator inner loop from full-state
checkpoints into O(1)-inverse deltas, which is where the reverse cost mainly
lives. Performance is a known optimization axis, not a correctness blocker.

## 8. Roadmap & milestones

Epic **`bennettvm-v5eb`** — *"Run an emulator on the VM (NES/6502 north-star)."*

| Milestone | Deliverable | Blocked on |
|---|---|---|
| **E0** ✅ | MVP: hand-assembled 8-opcode 6502, C path, forward==native + round-trip | — (DONE, this note) |
| **E1** (`bennettvm-zbeg`) | Full 6502 core (all official opcodes, flags, addressing modes) in C; unit-test each opcode vs a golden 6502 (`fake6502`) — *still headless, no I/O* | E0 |
| **E2** (`bennettvm-bc08`) | Run **`nestest.nes`** (mapper-0) headless; assert RAM `$0002`/`$0003`==`$00`; reversible round-trip | E1, `bennettvm-416r.4` (ROM-as-memory) |
| **E3** | `bennettvm-6dko` **InputRef** (input-movie tape) + wire `OutputRef` (`m6c`) — the two-tape I/O model (§5) | E2, `m6c` |
| **E4** | blargg `instr_test_v5` (headless, writes `$6000`) — per-instruction coverage | E2 |
| **E5** *(stretch)* | Minimal PPU + a permissive homebrew (e.g. *Alter Ego*, Apache-2.0) → framebuffer on the output tape; perf pass via `uom` | E3, E4, `uom` |

Beads filed 2026-07-03: epic **`bennettvm-v5eb`**; **E0** `bennettvm-33bf`
(closed — done); **E1** `bennettvm-zbeg`; **E2** `bennettvm-bc08`; **InputRef**
`bennettvm-6dko`. Deps wired (E2→E1→E0, E2→`416r.4`). E3/E4/E5 reference existing
beads and are filed as the work approaches (avoid speculative backlog).

## 9. Recommendation

**Pursue the emulator path; drop ROM-lifting entirely.** The CPU core is green
today; the remaining work is (i) breadth (all opcodes — mechanical), (ii) the
already-specced globals/output beads, and (iii) one new small primitive (the
input tape). The `nestest.nes` trophy — *"a real NES CPU-conformance ROM executed
on a reversible VM, then run backwards bit-for-bit to boot state"* — is a
legitimately publishable curiosity that dodges every genuinely hard NES problem
(graphics, audio, timing, mappers). Recommended next concrete step: **E1**, grow
the MVP to a complete 6502 core, opcode-by-opcode against a golden reference.

## Appendix — reproduce

```bash
cd docs/design/emulator-mvp
clang -O0 -S -emit-llvm -fno-discard-value-names -std=c11 mos6502.c -o mos6502.O0.ll
julia --project=../../.. run_mvp.jl          # → E0 MVP: forward==native + round-trip
julia --project=../../.. smoke6502.jl        # → requirements 1-3 probes (A/B/C)
julia --project=../../.. smoke_dispatch.jl   # → dispatch-encoding probes (D1-D3)
```

**Sources** (research provenance, 2026-07-03): jamulator post-mortem
(andrewkelley.me); NESdev wiki *Emulator tests*; `christopherpow/nes-test-roms`
(nestest, blargg); `fake6502`/`MyLittle6502`; Ada Logics binary-to-LLVM
comparison; LeanBin (arXiv:2406.16162). Capability audit grounded in
`src/interpreter/Interpreter.jl`, `src/ir/{IState,memory_floor,call_transitions}.jl`,
`src/extract/instructions.jl` (Bennett.jl), and this repo's
`test/test_c_hashtable_e2e.jl` / `test_e2e_collatz.jl`.

# ADR 0001 — RC3 `rc3` + `rvm` Smoke

**Status:** In progress (M5.1 § Build complete; M5.2 § Sample-run and M5.3 § Observations pending).

**Date:** 2026-05-26.

**Bead:** `bennettvm-zoe` (M5.1). Downstream: `bennettvm-7jm` (M5.2), `…` (M5.3).

**PRD anchor:** PRD v4 §3.1 (RSSA IR foundation), §6 SC6 (RC3 pre-read).

**Motivation.** Per PRD v4 §3.1 and SC6, RC3 (THM) is the canonical
RSSA reference implementation and the closest existing analogue to
BennettVM. M5 gates **all** subsequent Phase-2 work: no IR code is
written until RC3 has been built, exercised, and its dispatch
behavior observed in our own ADR. The point is not to transcribe
RC3 — Phase 2 starts from an empty `src/`+`test/` tree — but to read
its design lessons with our own hands on the keyboard, so that
Law 2 ("Reuse before reinvention", CLAUDE.md) is honored against an
artifact we have personally exercised rather than a paper alone.

This file is the journal of that exercise. §Build (this ADR) captures
the toolchain, the manifest pin, and the build invocation that
produced runnable `rc3` and `rvm` binaries from the manifest-pinned
RC3 source.

---

## § Build

### Repository pin

| Field | Value |
|---|---|
| Upstream | `https://git.thm.de/thm-rc3/release` |
| Local path | `references/implementations/RC3/` |
| Pinned SHA | `1b4c3572d1e7bfed44fd50f646dc1d8be9a79aef` |
| Manifest entry | `references/manifest/SOURCES.md` §2.8 row "RC3 (THM)" |
| Manifest short SHA | `1b4c357` (matches) |
| Pin commit subject | `Add missing sources` |
| Pin date (upstream) | tagged in upstream history; not re-stamped here |

Verified with `git rev-parse HEAD` against the manifest entry on
2026-05-26 immediately after cloning. **No checkout was required**:
the default branch tip on `master` already matches the manifest pin.

### Toolchain

| Tool | Version | Source | Why this version |
|---|---|---|---|
| Java JDK | OpenJDK 17.0.19 (Temurin build 17.0.19+10) | `sdkman` → `~/.sdkman/candidates/java/17.0.19-tem` | `compiler/pom.xml:161-163` sets `<source>17</source> <target>17</target> <compilerArgs>--enable-preview</compilerArgs>`. `--enable-preview` is `release`-specific (JEP 12) — Java 21 in preview mode requires `release=21`, not `17`. Java 17 is the version RC3 was written and tested against. |
| Maven | Apache Maven 3.8.7 (Ubuntu Noble `maven` package) | `sudo apt install -y maven` | Maven 3.8.x is the floor for Java 17 preview support. RC3's `rc3`/`rvm` launcher scripts shell out to `mvn` directly to package the JAR on first run. |
| OS | Linux 6.6.114.1 WSL2 | host environment | — |

Initial install attempt used the system-default Temurin Java 21.0.5,
which is already configured via `sdkman`. RC3's `pom.xml` rejects
Java 21 with `invalid source release 17 with --enable-preview / (preview language features are only supported for release 21)`. Switching the
session JDK to 17.0.19-tem via `PATH` / `JAVA_HOME` overrides resolved
this. No `pom.xml` modification was made to RC3: the manifest pin is
preserved bit-for-bit.

Maven was not present on this device prior to M5.1. Installation
proceeded via Ubuntu's `maven` package after user authorization
(2026-05-26 session).

### Build invocation

RC3 ships two launcher scripts (`./rc3`, `./rvm`) at the repository
root. Both check for the presence of their target JAR and trigger a
`mvn package` build under the `compiler/` Maven module if absent.
The reproducible standalone equivalent — used here so the build is
explicit rather than a launcher side effect — is:

```bash
# From references/implementations/RC3/
export JAVA_HOME=$HOME/.sdkman/candidates/java/17.0.19-tem
export PATH=$JAVA_HOME/bin:$PATH
(cd compiler && mvn package -P janus-compiler) | tee /tmp/rc3-build.log
```

The `janus-compiler` Maven profile builds the `rc3` JAR
(`janus-compiler-<version>.jar`). The `rssa-vm` profile builds the
`rvm` JAR (`rssa-vm-<version>.jar`). The `rvm` launcher script
triggers the second build automatically on first invocation; we
observed it doing so during smoke-test of `./rvm --help`.

### Build output (excerpted, ANSI-stripped)

Phase summary, `mvn package -P janus-compiler`, from `/tmp/rc3-build.log`:

```
[INFO] Scanning for projects...
[INFO] Building rc3 1.6.0-dev-2023.06.27
[INFO] --- git-commit-id-plugin:4.0.0:revision (get-the-git-infos) @ rc3 ---
[INFO] --- jflex-maven-plugin:1.7.0:generate (default) @ rc3 ---
[INFO] --- cup-maven-plugin:11b-20160615-1:generate (default) @ rc3 ---
[INFO] --- maven-resources-plugin:2.6:resources (default-resources) @ rc3 ---
[INFO] --- maven-compiler-plugin:3.8.0:compile (default-compile) @ rc3 ---
[INFO] --- maven-resources-plugin:2.6:testResources (default-testResources) @ rc3 ---
[INFO] --- maven-compiler-plugin:3.8.0:testCompile (default-testCompile) @ rc3 ---
[INFO] --- maven-surefire-plugin:3.0.0-M5:test (default-test) @ rc3 ---
[INFO] --- maven-jar-plugin:2.4:jar (default-jar) @ rc3 ---
[INFO] Building jar: …/compiler/target/janus-compiler-1.6.0-dev-2023.06.27.jar
[INFO] --- maven-shade-plugin:3.1.0:shade (default) @ rc3 ---
[INFO] Including com.github.vbmacher:java-cup-runtime:jar:11b-20160615-1 in the shaded jar.
[INFO] Including org.fusesource.jansi:jansi:jar:2.4.0 in the shaded jar.
[INFO] Including info.picocli:picocli:jar:4.6.3 in the shaded jar.
[INFO] Including org.jline:jline:jar:3.20.0 in the shaded jar.
[INFO] BUILD SUCCESS
[INFO] Total time:  14.387 s
[INFO] Finished at: 2026-05-26T09:35:42+02:00
```

`mvn` reported `BUILD SUCCESS` and exit 0. No `[WARNING]` or `[ERROR]`
lines appeared in the captured log; tests were `skipped` per the
`janus-compiler` profile configuration. The full 57-line log is at
`/tmp/rc3-build.log` (host-local, not committed); the entries above
are the load-bearing phase markers.

### Produced artifacts

After both profiles built (`janus-compiler` explicit, `rssa-vm`
triggered by the `./rvm --help` smoke):

| Path (under `references/implementations/RC3/`) | Size | SHA256 |
|---|---|---|
| `compiler/target/janus-compiler-1.6.0-dev-2023.06.27.jar` | 2.4 MB | `fc6697c73e8f0b1df74744ee70217fe3a7637acb60ccf98af396ba6534993002` |
| `compiler/target/rssa-vm-1.6.0-dev-2023.06.27.jar` | (untracked size) | `e35bbf98104b6e844e176cf7e82efb27fa4973de66782630655cc264b3ba5cb8` |

These hashes are device-local provenance: they let a future agent
on a different machine confirm an identical build before drawing
design conclusions from `rvm` output. They are **not** committed as
authoritative — Maven shade JARs include build timestamps and are
not bit-reproducible across machines without further configuration.

### Smoke-launch verification

`./rc3 --help` and `./rvm --help` both exit 0 and print usage text
referencing RC3 1.6.0-dev-2023.06.27 (the Maven project version).
`rc3 --help` documents four backends: `tac`, `interpreter`, `rssa`,
`rrssa`. `rvm --help` advertises an RSSA-source-file → execute path
with optional `--print-main`. This confirms the binaries are
runnable end-to-end; semantic exercise is deferred to §Sample-run
(M5.2) and design observations to §Observations (M5.3).

### Deviations from the README

The README §Build instructs:

> Before building this repository, make sure our version of the
> *CUP Maven Plugin* is installed.
>
> ```
> cd cup-maven-plugin/cup-maven-plugin ; mvn --quiet install
> ```

This step is **not required** at pin `1b4c357`. The pinned
`compiler/pom.xml:107-130` consumes the upstream
`com.github.vbmacher:cup-maven-plugin:11b-20160615-1`, which Maven
Central resolves directly. No `cup-maven-plugin/` subdirectory
exists in this commit. The README is referring to an internal THM
mirror that is not part of the release tarball. **Future M5.x
agents: do not attempt the `cd cup-maven-plugin/…` step; it will
fail with "no such directory" and waste a debug cycle.** A skip
note has been added to PHASE.md's M5 entry (pending its next
revision) and to the bead `bennettvm-7jm` description (M5.2).

### Reproducibility for future sessions

Pinned recipe (for a fresh clone on any device):

```bash
# 1. Ensure the manifest-pinned RC3 source is on disk.
mkdir -p references/implementations
git clone https://git.thm.de/thm-rc3/release.git \
  references/implementations/RC3
( cd references/implementations/RC3 && \
  git rev-parse HEAD | grep -q '^1b4c357' || \
  git checkout 1b4c3572d1e7bfed44fd50f646dc1d8be9a79aef )

# 2. Ensure Java 17 + Maven are available.
#    On Ubuntu Noble: `sudo apt install -y maven`.
#    For Java 17 via sdkman: `sdk install java 17.0.19-tem`.
#    Sdkman's interactive-default-prompt does not run in non-TTY
#    sub-shells; if extraction stalls, the .bin in ~/.sdkman/tmp/
#    can be `tar -xzf`'d directly into ~/.sdkman/candidates/java/.
export JAVA_HOME=$HOME/.sdkman/candidates/java/17.0.19-tem
export PATH=$JAVA_HOME/bin:$PATH

# 3. Build both JARs explicitly (avoiding launcher side effects).
( cd references/implementations/RC3/compiler && \
  mvn package -P janus-compiler && \
  mvn package -P rssa-vm )

# 4. Verify both binaries respond.
( cd references/implementations/RC3 && ./rc3 --help && ./rvm --help )
```

### Exit criterion (M5.1)

Per the bead `bennettvm-zoe`: "`docs/adr/0001-rc3-rvm-smoke.md`
§Build section committed with build invocation and output captured."
**Met.**

---

## § Sample-run

**Bead:** `bennettvm-7jm` (M5.2). **Date:** 2026-05-26.

### Goal

Run an RSSA program through `rvm` forward, then backward, and confirm
the dispatch behavior. The point is not "does the math work" — RC3 is
a published, tested artifact — but to *observe with our own keyboard*
the property that motivates BennettVM's existence:

> **A program whose source language is reversible-by-construction can
> be executed forward AND backward by the same VM with no history
> tape.** (Yokoyama–Glück 2007 PEPM.)

BennettVM's Phase-2 source language (Julia subset, via Bennett.jl
`ParsedIR`) is NOT reversible-by-construction. Hence Phase-2 needs a
history layer (§3.3) that RC3 does not need. Confirming this contrast
in the smoke run grounds the entire history-layer design.

### Setup

```bash
export JAVA_HOME=$HOME/.sdkman/candidates/java/17.0.19-tem
export PATH=$JAVA_HOME/bin:$PATH
export JAVA_TOOL_OPTIONS="--enable-preview"     # see §Notes below
cd references/implementations/RC3
```

Without `JAVA_TOOL_OPTIONS="--enable-preview"`, the runtime aborts
with `UnsupportedClassVersionError: Preview features are not enabled
for rc3/rssa/pass/LabelTable (class file version 61.65535)`. The
`rc3`/`rvm` launcher scripts pass `--enable-preview` at *compile* time
(via `compiler/pom.xml:163`) but not at *runtime* (the scripts
invoke `java -jar …`). Setting the env var is the cleanest
non-mutation workaround. **Future M5.x agents: this is permanent for
RC3 at this pin; do not rediscover this from the stack trace.**

### Program under test

`programs/rssa/factorial.rrssa` (R-RSSA, the conditional-as-XOR
variant). The program computes `factorial(5) = 120` via a single
backward-counted loop over `n`, with `result` accumulating the
product. Parameter annotations bake the input: `x=5, result=0`.

### Forward run

```
$ ./rvm --print-main --count-instructions programs/rssa/factorial.rrssa
```

```
Variables at end of 'forward.main' subroutine:
x = 0
result = 120

Listing called subroutines/labels and number of executed instructions:
- fw.factorial: 3
- fw.main: 3
- fw.Lfactorial_1: 6
- fw.Lfactorial_2: 8
- fw.Lfactorial_3: 24
- fw.Lfactorial_4: 2
Total executed instructions: 46
```

End-state: `x=0, result=120`. Janus uses **variable-destroying
moves**: `x` is consumed by the loop and ends at `0` after counting
down; `result` accumulates the answer. This is RSSA's hallmark — not
just SSA reversibility, but the eraser-free use-discipline that makes
RSSA invertible without a history tape.

### Backward run

```
$ ./rvm --bw --print-main --count-instructions programs/rssa/factorial.rrssa
```

```
Variables at end of 'backward.main' subroutine:
x = 5
result = 0

Listing called subroutines/labels and number of executed instructions:
- bw.factorial: 2
- bw.main: 3
- bw.Lfactorial_1: 3
- bw.Lfactorial_2: 24
- bw.Lfactorial_3: 8
- bw.Lfactorial_4: 6
Total executed instructions: 46
```

End-state: `x=5, result=0`. The original input is exactly recovered.

### Observations from the transcript

1. **Round-trip exactness.** Forward (`x=5, result=0`) → final
   (`x=0, result=120`) → backward final (`x=5, result=0`). Bit-exact.
   No history tape exists in `rvm`'s state; reverse-direction
   execution is *the same code interpreted by the dual transition
   relation*. This is the Yokoyama–Glück 2007 property.

2. **Identical total instruction count: 46 forward, 46 backward.**
   RSSA has no "undo" instructions — the same instructions execute in
   the opposite order under the dual relation. The work is symmetric.
   *Lesson for BennettVM:* History-layer-3 (checkpoint-replay) should
   target this property as the ceiling — at most 2× forward work to
   reach an arbitrary step backward, *not* a per-step inverse-op cost.

3. **Block-level instruction count swap.** The leading blocks of the
   forward dispatch (Lfactorial_3: 24 fw / 8 bw) and the trailing
   blocks (Lfactorial_2: 8 fw / 24 bw) swap their instruction counts.
   This is the dual-direction control-flow dispatch: RSSA
   `conditional-entry` and `conditional-exit` instructions consult
   the LabelTable to determine the predecessor block in either
   direction. The "from-label" of forward execution becomes the
   "to-label" of backward, and vice-versa. *Lesson for BennettVM:*
   our IR must carry the dual-address label information for every
   joining/splitting block (Mogensen 2016 §3 — φ on splits AND joins).

4. **Conditional-entry/exit dispatch is the load-bearing primitive.**
   `Lfactorial_3 <- result_2 == 1` (from the source) is the
   conditional entry: backward into Lfactorial_3 from Lfactorial_1
   when `result == 1`. `n_2 == 0 -> Lfactorial_4(...)Lfactorial_2` is
   the conditional exit: forward from current block to Lfactorial_4
   when `n == 0`, otherwise Lfactorial_2. The dispatcher uses these
   predicates symmetrically — the predicate value at each transition
   is what makes the LabelTable resolve unambiguously in *both*
   directions. This is the design pattern PRD v4 §3.1 references and
   M5.3 will map into Phase-2 Julia naming.

5. **No allocations growth proportional to step count.** The
   `--count-instructions` output enumerates per-block tallies but the
   VM state is just register slots + the heap. There is no `History`
   structure of size O(steps). Contrast with the Phase-0 spike, which
   pushed a full `IState` snapshot per instruction.

### Notes

- The R-RSSA variant (file extension `.rrssa`) is RC3's
  conditional-as-XOR encoding of RSSA. The differences from plain
  `.rssa` matter for instruction-level reading (M5.3) but not for the
  round-trip property; both variants are reversible-by-construction.
- `rvm` reports wall time around 138/142 ms for fw/bw on factorial(5);
  most of this is JVM startup, not interpretation. Not a meaningful
  performance signal; included only for transparency.
- `programs/rssa/instructions/` contains one-instruction-per-file
  samples that will be used in M5.3 for the dispatch taxonomy.

### Exit criterion (M5.2)

Per `bennettvm-7jm`: "Run rvm forward+backward on a sample RSSA
program; capture verbatim transcript; observe dispatch behavior; file
§Sample-run."  **Met.**

## § Observations

**Bead:** `bennettvm-7bl` (M5.3). **Date:** 2026-05-26.

### Goal

The §Build and §Sample-run sections proved RC3 runs and round-trips.
§Observations is the design-lessons section: enumerate the
authoritative RSSA instruction taxonomy as RC3 implements it, map
each subclass to a candidate Phase-2 Julia name, and flag the
divergence points that BennettVM's IR (M2) must consciously decide
about — *with our own keyboard*, not just from the papers.

Source-survey was performed by a read-only Sonnet research subagent
on 2026-05-26 (transcript appended to bead `bennettvm-7bl` for
audit). All paths and line numbers below were verified.

### Authoritative RSSA instruction taxonomy

**RC3 exposes 12 concrete instruction subclasses** (confirming the
impl plan and PRD v4 §3.1's "~12" claim — exact). The abstract
parent is `rc3.rssa.instances.Instruction` (sealed, file
`compiler/src/main/java/rc3/rssa/instances/Instruction.java:18-19`).
Control-flow subclasses extend the sealed abstract
`ControlInstruction` (in `instances/ControlInstruction.java`).
Dispatch lives in the `RSSAExecutor` inner class of
`compiler/src/main/java/rc3/rssa/vm/RSSAVM.java:531-735`.

| # | RC3 class | Category | Form (verbatim from samples) | Reversible via | Candidate Phase-2 Julia name |
|---|---|---|---|---|---|
| 1 | `ArithmeticAssignment` | Arithmetic update | `x := y ⊕ (R1 ⊙ R2)` | Operator inversion (XOR↔XOR, ADD↔SUB) on `reverse()` | `ArithAssign` |
| 2 | `SwapInstruction` | Register exchange | `x, y := z, w` | Self-inverse via target↔source swap | `RegSwap` |
| 3 | `MemoryAssignment` | Memory in-place update | `M[x] ⊕= y ⊙ z` | Modification-operator invert on `reverse()` | `MemAssign` |
| 4 | `MemoryInterchangeInstruction` | Register ↔ memory exchange | `x := M[y] := z` | `left`↔`right` swap on `reverse()` | `MemExchange` |
| 5 | `MemorySwapInstruction` | Memory ↔ memory swap | `M[x] <-> M[y]` | Self-inverse | `MemSwap` |
| 6 | `CallInstruction` | Procedure call | `(x,...) := call/uncall l(y,...)` | `Direction` field flips; one class for both | `Call` |
| 7 | `BeginInstruction` | Subroutine entry | `begin l(x,...)` | `reverse() → EndInstruction` | `SubBegin` |
| 8 | `EndInstruction` | Subroutine exit | `end l(y,...)` | `reverse() → BeginInstruction` | `SubEnd` |
| 9 | `UnconditionalEntry` | Block entry | `l(x,...) <-` | `reverse() → UnconditionalExit` | `UncondEntry` |
| 10 | `UnconditionalExit` | Block jump-out | `-> l(y,...)` | `reverse() → UnconditionalEntry` | `UncondExit` |
| 11 | `ConditionalEntry` | Block φ-merge with predicate | `l1(x,...)l2 <- c` | `reverse() → ConditionalExit` | `CondEntry` |
| 12 | `ConditionalExit` | Block branch with predicate | `c -> l1(y,...)l2` | `reverse() → ConditionalEntry` | `CondExit` |

The candidate Julia names are tentative — to be locked at M2.1 (the
first IR-type bead). They preserve RC3's "Entry/Exit" duality and
the "Cond/Uncond" prefix, dropping `Instruction` from each name
(Julia idiom: the struct type already encodes "this is an X").

The visitor / operand classes — `BinaryOperand`, `Atom`, `Constant`,
`Variable`, `MemoryAccess`, `RValue`, `Value` — are **operands**, not
instructions. They appear in `RSSAVisitor` for tree traversal but
`RSSAExecutor.visitVoid(BinaryOperand)` (RSSAVM.java:551-553) is a
no-op; evaluation is delegated to `EvaluationVisitor`. **Future M2.x
agents: do not add an "instruction-13" for BinaryOperand.**

### Structural pattern (the load-bearing design lessons)

1. **Reversibility is structural, not historical.** Every concrete
   instruction class implements `reverse()` by constructing a fresh
   instance with role-swapped fields and (where applicable) an
   inverted modification operator. The inverse is cached lazily via
   `invert()`. There is **no history tape inside RSSA semantics**.
   The instruction list is always stored in forward orientation; the
   VM flips a `Direction` flag and calls `instr.invert()` before
   dispatch. **Lesson for BennettVM:** the IR layer can use this same
   trick. The history tape (§3.3) is a *Julia-source* concession, not
   an RSSA-layer requirement.

2. **φ-nodes appear at BOTH splits AND joins** (Mogensen 2016 §3 —
   directly confirmed). `ConditionalExit` is the split: predicate +
   two target labels. `ConditionalEntry` is the join: predicate +
   two **source** labels, and **the entry asserts** which source the
   control came from. The assertion is what makes RSSA invertible —
   join points are not "lossy" because they record the predicate.

3. **Memory access is exchange-only** (Vieri 1995 / Pendulum — also
   confirmed). There is no destructive load class. Memory access is
   one of: `MemoryAssignment` (in-place reversible update;
   modification operator must be invertible — `XOR ↔ XOR`,
   `ADD ↔ SUB`); `MemoryInterchangeInstruction` (register
   ↔ memory exchange — destroys one source register, creates one
   fresh register from the old cell); or `MemorySwapInstruction`
   (memory ↔ memory swap, self-inverse). Phase-2 IR must enforce
   the same.

4. **Procedure calls unify call and uncall under one class** with a
   `Direction` field. Reverse-of-call is reverse-of-uncall — a single
   structural primitive. This is cleaner than spike-style separate
   `Call` / `Uncall` opcodes; Phase-2 should follow RC3 here.

5. **Arithmetic doesn't store its source value.** `ArithmeticAssignment`
   `x := y ⊕ (R1 ⊙ R2)` is reversed by `y := x ⊖ (R1 ⊙ R2)` — the
   destination becomes the new source on reversal. No per-instruction
   log entry is needed. The reason no history is needed *inside*
   RSSA: every instruction destroys exactly as many SSA variables as
   it creates, in a use-discipline-controlled way; the values needed
   to reverse are always live in registers at the moment of reversal.

### Divergences from the textbook callouts (CLAUDE.md hallucination risks)

These are the points where RC3's actual design contradicts the
shorthand callouts in `CLAUDE.md`'s "Hallucination-risk callouts".
**Read carefully — these are exactly the items where future M2.x
sub-agents could pattern-match a textbook lesson incorrectly.**

- **Unconditional jumps do NOT encode the source label.** CLAUDE.md
  callout: *"BobISA jumps encode the source label."* True in BobISA
  (Axelsen-Yokoyama 2011 / Thomsen-Axelsen-Glück 2012). **Not true in
  RC3.** `UnconditionalExit` carries only the target label `l`; the
  predecessor recovery is delegated to the paired `Entry` instruction
  at the destination, which checks `lastLabel` in the VM (RSSAVM.java
  lines 595-597 and 720-721). RC3 is following **Mogensen RSSA**, not
  BobISA. **Phase-2 must decide explicitly** which design to inherit.
  Recommendation (carry to M2.x design): inherit RSSA's
  paired-entry/exit pattern, because BennettVM consumes Julia's
  irreversible control-flow graph and lowering to source-label-encoded
  jumps would require a much larger transformation pass. File:
  `instances/UnconditionalExit.java`.

- **`MemoryInterchangeInstruction` is register ↔ memory, NOT memory
  ↔ memory.** CLAUDE.md callout: *"PISA memory access is always an
  exchange."* True in spirit (no destructive load) but the operand
  asymmetry — variable ↔ memory cell — is a Mogensen-specific design
  point. Memory ↔ memory swap is a separate instruction
  (`MemorySwapInstruction`, #5). Phase-2 IR should preserve this
  separation rather than unifying under one "exchange" primitive.

- **`MemoryAssignment` has NO SSA variable lifecycle** — it
  reads/writes a memory cell in place via a reversible modification
  operator (XOR, ADD, …). The reversibility is *operator-level*, not
  *variable-level*. Phase-2 must ensure the modification operators
  exposed are all invertible; RC3 enforces this via
  `ModificationOperator.invert()`. **Concretely:** Phase-2 cannot
  expose a `MemAssign` with `op = MUL` unless mul-by-constant is
  guaranteed (and even then, only for known-invertible constants).

- **No surprises around Bennett-1973 vs 1989, "VM is not the quantum
  target", or floating-point. ** RC3's `Int`-only memory and lack of
  pebble-game lowering keep it well clear of the Phase-2 risk surface
  for those callouts.

### Phase-2 design implications (load-bearing for M2.x)

These are the concrete decisions M2.1 (the first IR-type bead) must
make, derived from this survey:

| Decision | Recommendation | Source |
|---|---|---|
| Instruction abstract hierarchy | `abstract type Instruction end` with `abstract type ControlInstruction <: Instruction end` mirroring RC3's sealed hierarchy. | RC3 `instances/Instruction.java`, `ControlInstruction.java` |
| Inverse representation | Lazy structural `Base.inv(::Instruction)` returning a fresh struct with role-swapped fields. NO history-tape entry per arithmetic op. | RC3 `instr.invert()` cache pattern |
| Direction flag | One per-VM `Direction` enum (`Forward`/`Backward`); flipped at run start, not per-instruction. | RC3 RSSAVM.java `direction` field |
| Φ-node placement | At joins AND splits. `CondEntry` carries source labels + predicate; `CondExit` carries target labels + predicate. | Mogensen 2016 §3 / RC3 `Conditional{Entry,Exit}` |
| Memory access primitives | Three distinct types — `MemAssign`, `MemExchange`, `MemSwap`. Do NOT unify. | RC3 `Memory{Assignment, Interchange, Swap}Instruction` |
| Modification operator invertibility | Enum of invertible operators only (`XOR`, `ADD`, `SUB`). Reject `MUL`/`DIV` unless statically invertible. | RC3 `ModificationOperator.invert()` |
| Call/Uncall unification | One `Call` struct with `direction::Direction` field. | RC3 `CallInstruction` |
| Source-label jumps | NO. Use paired entry/exit with `lastLabel`-style runtime check. | RC3 `Unconditional{Entry,Exit}`; diverges from BobISA |

### Exit criterion (M5.3)

Per `bennettvm-7bl`: "Map RC3 instruction subclasses to Phase-2 Julia
naming; identify divergence points." **Met.** The taxonomy is
locked, divergences are documented, and M2.x has a concrete decision
table to work from. M5 (RC3 pre-read) is complete; M0 (Bennett.jl
handoff smoke) is unblocked.

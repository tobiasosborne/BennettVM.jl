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

*To be authored by M5.2 (`bennettvm-7jm`).*

## § Observations

*To be authored by M5.3.*

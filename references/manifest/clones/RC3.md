# CLONE-INFO — RC3 (THM)

> Per-clone provenance record. The `references/implementations/RC3/`
> directory is itself a nested git clone, so its contents cannot be
> tracked by the parent BennettVM.jl repo (a parent never sees inside
> a child `.git`). This file lives at `references/manifest/clones/`
> instead, alongside the global `SOURCES.md`, and is tracked normally.

## Upstream

- **URL:** `https://git.thm.de/thm-rc3/release`
- **Default branch:** `master`
- **Project home:** Reversible Computing Compiler Collection (RC3),
  Technische Hochschule Mittelhessen, Dept. MNI.

## Pin

- **Pinned SHA:** `1b4c3572d1e7bfed44fd50f646dc1d8be9a79aef`
- **Short SHA:** `1b4c357`
- **Pin commit subject:** `Add missing sources`
- **Manifest cross-reference:** `references/manifest/SOURCES.md` §2.8
  row "RC3 (THM)" — status ✅ HAVE, same short SHA.

## Acquisition history

- **2026-05-26** — cloned on a new device by Claude Code during M5.1
  (bead `bennettvm-zoe`). HEAD already matched the manifest pin; no
  `git checkout` needed.

## Build prerequisites

See `docs/adr/0001-rc3-rvm-smoke.md` §Build for the full recipe:

- OpenJDK 17 (preview features enabled at compile via
  `compiler/pom.xml`; required at runtime via
  `JAVA_TOOL_OPTIONS=--enable-preview` because the launcher scripts
  omit the flag).
- Apache Maven 3.8.x.

The README's "build the CUP Maven Plugin first" step is **not
required** at this pin; the pom consumes
`com.github.vbmacher:cup-maven-plugin:11b-20160615-1` from Maven
Central.

## Used by

- **M5.1** (`bennettvm-zoe`) — toolchain + build smoke.
- **M5.2** (`bennettvm-7jm`) — `rvm` forward/backward run of
  `programs/rssa/factorial.rrssa`.
- **M5.3** (`bennettvm-7bl`) — RSSA instruction taxonomy survey via
  `compiler/src/main/java/rc3/rssa/instances/` and the dispatcher in
  `vm/RSSAVM.java`.
- **M_OPCODE / M2.x** (future) — design reference; no code is
  copied from RC3 (Java) into BennettVM.jl (Julia).

## License note

RC3 is © 2021 Technische Hochschule Mittelhessen. We do not
redistribute its source — BennettVM.jl's `.gitignore` excludes the
clone tree below this `CLONE-INFO.md`. Reproducibility is via the
upstream URL + pinned SHA recorded here.

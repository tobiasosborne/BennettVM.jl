# SOURCES.md — BennettVM.jl ground-truth manifest

Every paper listed in PRD v3 Part II that BennettVM may eventually cite.
Acquisition is a hard prerequisite for Phase-0 spike (per PRD §5.5) and
for Phase-2 production (per PRD Law 1 and §3.x).

**Acquisition status legend:**
- ✅ HAVE — file on disk at the listed path.
- ⏳ NEED — to be acquired; subagent assignment in the rightmost column.
- ⏸ DEFER — out of scope for Phase 0/2 minimum, acquire only if cited.

**Priority legend:**
- **P0** — required before the Phase-0 spike session opens (PRD §5.5).
- **P2** — required before any Phase-2 design subagent runs (Law 2).
- **R** — recommended; informs taste but not load-bearing.

**Format preference:** arXiv `.tex` source over `.pdf` over `.djvu`.
`.tex` saves us a marker pass. For arXiv: prefer
`https://arxiv.org/e-print/<id>` (tar.gz of source) over the PDF.

**Citation convention** (use in code comments and commit messages):
```
# Ref: references/<topic>/<file>.pdf, §<section> (page <n>)
#   "<verbatim quote>"
```

---

## §2.1 Classical foundations

| Citation | Priority | Path | Status | Assigned |
|---|---|---|---|---|
| Bennett 1973, *Logical reversibility of computation*, IBM JRD 17(6):525–532 | **P0** | `references/foundational/bennett-1973-logical-reversibility.pdf` | ✅ HAVE SHA256:e61ad66840e45bec4b67fa839cf3f89edd733b8e60c86b0c8fd03129de960687 (496K; source: user-supplied 2026-05-25, was TIB-ILL pending) | A |
| Bennett 1989, *Time/space trade-offs for reversible computation*, SIAM JC 18(4):766–776 | **P2** | `references/foundational/Bennett1989_time_space_tradeoffs.pdf` | ✅ HAVE | — |
| Knill 1995, *An analysis of Bennett's pebble game*, LANL LAUR-95-2258, arXiv:math/9508218 | **P2** | `references/foundational/Knill1995_bennett_pebble_analysis.pdf` | ✅ HAVE | — |
| Buhrman–Tromp–Vitanyi 2001, *Time and space bounds for reversible simulation*, arXiv:quant-ph/0101133 | **P2** | `references/foundational/buhrman-tromp-vitanyi-2001.pdf` + `-tex/icalp01.tex` | ✅ HAVE | A |
| Vitanyi, *Time, space, and energy in reversible computing* (arXiv:cs/0504088, CF'05) | R | `references/foundational/vitanyi-time-space-energy.pdf` | ✅ HAVE | — |
| Landauer 1961, *Irreversibility and heat generation in the computing process*, IBM JRD 5(3):183–191 | R | `references/foundational/landauer-1961.pdf` | ⏸ DEFER | A |
| Lange–McKenzie–Tapp, exponential-time O(S)-space reversible simulation | R | `references/foundational/LMT.pdf` | ⏸ DEFER | A |
| Li–Vitanyi, lower bounds on reversible pebbling of chains | R | `references/foundational/li-vitanyi-pebble-chain.pdf` | ⏸ DEFER | A |

## §2.2 Reversible imperative languages

| Citation | Priority | Path | Status | Assigned |
|---|---|---|---|---|
| Yokoyama–Glück 2007 PEPM, *A reversible programming language and its invertible self-interpreter* | **P0** | `references/reversible-languages/yokoyama-glueck-2007-pepm.pdf` | ✅ HAVE SHA256:78fdff901d1db11e2551e27ccfea4a161f16e63ab49d1797d1877c4a072e4497 (304K; source: isidore.co Zotero mirror) | B |
| Lutz–Derby 1986, *Janus: a time-reversible language* (Caltech class notes) | R | `references/reversible-languages/lutz-derby-1986-janus.pdf` | ✅ HAVE SHA256:7f9f7a50ad01e2507e36899ff998b558a00e72db665e192fe89c57ecc9879a5a (44K; source: tetsuo.jp/ref/janus.pdf) | B |
| Glück–Yokoyama 2016, *A linear-time self-interpreter of a reversible imperative language* (R-WHILE) | **P2** | `references/reversible-languages/glueck-yokoyama-2016-rwhile.pdf` | ✅ HAVE SHA256:759361fbc9e9e27eba150eec4b52dda4f4a99ce0d8e49966b90e2e0107d1758e (568K; source: J-STAGE IEICE free-access DOI:10.1587/transinf.2016EDP7274) | B |
| Haulund 2017, *Design and impl. of a reversible OOP language* (ROOPL MS thesis) | R | `references/reversible-languages/haulund-2017-roopl.pdf` | ✅ HAVE SHA256:af7f02c1c01389be03fa8b1940558071c09175da33738d80e1adab657a73481e (1.8M; source: arXiv:1707.07845) | B |
| Mogensen 2022, *Hermes: a reversible language for lightweight encryption*, SCP 215 | R | `references/reversible-languages/mogensen-2022-hermes.pdf` | ⏸ DEFER — Elsevier SCP paywall; PMC open copy requires browser auth; no preprint found | B |
| Thomsen 2012 + RFUN follow-ups | **P2** | `references/reversible-languages/Thomsen2012_reversible_functional_lang.pdf` | ✅ HAVE | — |
| Yokoyama–Axelsen–Glück 2011, RFUN (RC 2011) | **P2** | `references/reversible-languages/yokoyama-axelsen-glueck-2011-rfun.pdf` | ✅ HAVE SHA256:9845c37b0a1cae229ff97159398fbef553a1cade3071bd8e27b1b98294d7c60d (262K; source: Springer TIB VPN DOI:10.1007/978-3-642-29517-1_2; LNCS 7165 = 978-3-642-29517-1; chapter 2 "Towards a Reversible Functional Language") | D |
| Jacobsen–Kaarsgaard–Thomsen 2018, *CoreFun* (RC 2018) | **P2** | `references/reversible-languages/jacobsen-2018-corefun.pdf` | ✅ HAVE SHA256:d15713796bcd8c699740a330f385f38f92073865654a6d2b1368a97e0cd30105 (512K; source: Springer TIB VPN DOI:10.1007/978-3-319-99498-7_21) | D |
| Matsuda–Wang 2020, *Sparcl* (ICFP, PACMPL 4) | **P2** | `references/reversible-languages/matsuda-wang-2020-sparcl.pdf` | ✅ HAVE SHA256:2e6a21816bc662ea128338eddbb2ac4b1e3482dd9dca95373cb5deb578807869 (417K; source: Cambridge Core OA DOI:10.1017/S0956796823000126) | B |
| James–Sabry 2014, *Theseus* (RC 2014) | R | `references/reversible-languages/james-sabry-2014-theseus.pdf` | ✅ HAVE SHA256:a2b64ffd954fbe63969e98f386087336313cd86a0718cc01e317d3146089397c (137K; source: homes.luddy.indiana.edu/sabry/files/theseus.pdf) | B |
| James–Sabry 2012, *Information effects* / Π (POPL 2012) | R | `references/reversible-languages/james-sabry-2012-pi.pdf` | ⏸ DEFER — ACM DL paywall; legacy.cs.indiana.edu unreachable from this host; no open copy found | B |
| Axelsen–Glück 2013, reversible heap | R | `references/reversible-languages/AxelsenGluck2013_reversible_heap.pdf` | ✅ HAVE | — |
| Axelsen–Glück 2018, reversible GC | R | `references/reversible-languages/AxelsenGluck2018_reversible_gc.pdf` | ✅ HAVE | — |

## §2.3 Reversible intermediate languages

| Citation | Priority | Path | Status | Assigned |
|---|---|---|---|---|
| Mogensen 2016 (PSI 2015 LNCS 9609), *RSSA: A Reversible SSA Form* | **P2** | `references/reversible-ir/mogensen-2016-rssa.pdf` | ✅ HAVE SHA256:94e7dc88a91a9104d8e9957e9eb1a1434a39c780d46a48bf46a03fc53822fb95 (275K; source: Springer TIB VPN DOI:10.1007/978-3-319-41579-6_16) | D |
| Mogensen 2011, *Partial evaluation of the reversible language Janus*, PEPM 2011 | R | `references/reversible-ir/mogensen-2011-janus-pe.pdf` | ⏸ DEFER — ACM PEPM 2011 paywall DOI:10.1145/1929501.1929506; ACM DL returns 403 even via TIB VPN; no preprint found | B |
| Mogensen, *RIL (Reversible Intermediate Language)* | R | `references/reversible-ir/mogensen-ril.pdf` | ✅ HAVE SHA256:2be72912dcb96aeef87c18bdff9aba6b1308091ae4ef44313af90e452ded7072 (207K; source: Springer TIB VPN, Mogensen 2015 RC "Garbage Collection for Reversible Functional Languages" LNCS 9138 DOI:10.1007/978-3-319-20860-2_5; NOTE: RIL introduced in §3 of this paper, no standalone RIL document) | D |
| Deworetzki–Meyer 2021, *Compiling Janus to RSSA* | **P2** | `references/reversible-ir/deworetzki-meyer-2021-janus-to-rssa.pdf` | ✅ HAVE SHA256:19e81160e209fb704f72df2e47f517bb8b8e9499344fdfa9a74c41179d9b9c12 (444K; source: Springer TIB VPN DOI:10.1007/978-3-030-79837-6_4) | D |
| Deworetzki 2022, *Optimizing Reversible Programs*, RC 2022 | **P2** | `references/reversible-ir/deworetzki-2022-optimizing.pdf` | ✅ HAVE SHA256:3107039a9431814e3c615539f6760c8e406092d185d72b9155bc3e7b33c06e6b (300K; source: Springer TIB VPN DOI:10.1007/978-3-031-09005-9_16) | D |
| Deworetzki 2023, *Optimization of Reversible Control Flow Graphs*, RC 2023 | **P2** | `references/reversible-ir/deworetzki-2023-cfg-opt.pdf` | ✅ HAVE SHA256:1d9b0d8bca7afe41ec21f2d04df13ee9238d2cc080b2f732a6cca786ba682122 (544K; source: Springer TIB VPN DOI:10.1007/978-3-031-38100-3_5) | D |
| Oguchi–Yuen 2024, *Concurrent RSSA for CRIL*, RC 2024 | R | `references/reversible-ir/oguchi-yuen-2024-cril-crssa.pdf` | ✅ HAVE SHA256:3dc91dd5de8ca9a9dc7670f2ba1840351e82b4bd6dd2f66b50911baf3f48c896 (412K; source: arXiv:2309.07310; TeX source also in oguchi-yuen-2024-tex/) | B |
| Deworetzki–Schlecht–Meyer 2024, *Hybrid SSA*, RC 2024 | **P2** | `references/reversible-ir/deworetzki-2024-hybrid-ssa.pdf` | ✅ HAVE SHA256:117887974040b201ad949ea2bae6500533684dad4d7ef175061a68718c056fa4 (539K; source: Springer TIB VPN DOI:10.1007/978-3-031-62076-8_11) | D |

## §2.4 Reversible ISAs

| Citation | Priority | Path | Status | Assigned |
|---|---|---|---|---|
| Vieri 1995 (MIT MS), *Pendulum: A reversible computer architecture* | **P2** | `references/reversible-isa/vieri-1995-pendulum-ms.pdf` | ✅ HAVE | C |
| Vieri 1999 (MIT PhD), *Reversible Computer Engineering and Architecture* | **P2** | `references/reversible-isa/vieri-1999-reversible-arch-phd.pdf` | ✅ HAVE | C |
| Frank 1999 (MIT PhD), *Reversibility for efficient computing* | R | `references/reversible-isa/frank-1999-thesis.pdf` | ✅ HAVE | C |
| Axelsen–Yokoyama 2011 LATA, *A simple and efficient universal reversible TM* (BobISA) | **P2** | `references/reversible-isa/axelsen-yokoyama-2011-bobisa.pdf` | ✅ HAVE (NOTE: see §Citation-errata below) | C |
| Hall 1994 PhysComp, *A reversible instruction set architecture and algorithms* | R | `references/reversible-isa/hall-1994-reversible-isa.pdf` | ⏸ DEFER — IEEE Xplore paywall, not openly accessible | C |
| Mogensen 2022, *Fast Control for Reversible Processors*, RC 2022 | R | `references/reversible-isa/mogensen-2022-fast-control.pdf` | ✅ HAVE | C |

## §2.5 Quantum uncomputation

| Citation | Priority | Path | Status | Assigned |
|---|---|---|---|---|
| Paradis–Bichsel–Cohen–Vechev 2021 PLDI, *Unqomp* | **P2** | `references/quantum-uncomputation/unqomp-2021.pdf` | ✅ HAVE | — |
| Paradis–Bichsel–Vechev 2024 Quantum 8:1258, *Reqomp*, arXiv:2212.10395 | **P2** | `references/quantum-uncomputation/Reqomp2024_uncomputation.pdf` | ✅ HAVE | — |
| Meuli–Soeken–De Micheli 2019 DATE, *Reversible pebbling game for quantum memory mgmt* | **P2** | `references/quantum-uncomputation/Meuli2019_reversible_pebbling.pdf` | ✅ HAVE | — |
| Quist et al 2025 Quantum, *Tight bounds on the spooky pebble game*, arXiv:2110.08973 | **P2** | `references/quantum-uncomputation/spooky-pebble.pdf` | ✅ HAVE | — |
| Gidney, spooky pebble blog series, algassert.com | R | `references/quantum-uncomputation/gidney-spooky-blog.md` (extract) | ✅ HAVE | C |
| Parent–Roetteler–Svore 2015, *Reversible circuit compilation with space constraints* | R | `references/quantum-uncomputation/ParentRoettelerSvore2015_space_constraints.pdf` | ✅ HAVE | — |
| Hirata–Heunen 2025 POPL 9, *Qurts: Automatic Quantum Uncomputation by Affine Types with Lifetime* | **P2** | `references/quantum-uncomputation/qurts-2024.pdf` | ✅ HAVE | — |
| Seidel et al., Qrisp framework | R | `references/quantum-uncomputation/seidel-qrisp.pdf` | ✅ HAVE | C |
| Zhang–Ying 2025 PLDI 9 art. 180, *Quantum Register Machine*, arXiv:2408.10054 | **P2** | `references/quantum-uncomputation/zhang-ying-2025-qrm.pdf` | ✅ HAVE | C |

## §2.6 Reverse-time debugging

| Citation | Priority | Path | Status | Assigned |
|---|---|---|---|---|
| O'Callahan et al 2017 USENIX ATC, *Engineering Record And Replay For Deployability* (rr) | **P2** | `references/reverse-debugging/ocallahan-2017-rr-deployability.pdf` | ✅ HAVE | A |
| O'Callahan–Huey 2020 ACM Queue 18(1), *To Catch a Failure* | R | `references/reverse-debugging/ocallahan-huey-2020-acm-queue.pdf` | ⏸ DEFER | A |
| rr-project documentation | R | `references/reverse-debugging/rr-docs.md` (extract) | ✅ HAVE | A |

## §2.7 Compiler-based AD

| Citation | Priority | Path | Status | Assigned |
|---|---|---|---|---|
| Moses–Churavy 2020 NeurIPS, *Instead of Rewriting Foreign Code...* (Enzyme) | **P2** | `references/ad-and-checkpointing/enzyme-2020.pdf` | ✅ HAVE | — |
| Moses et al 2021 SC, *Reverse-mode AD and optimization of GPU kernels via Enzyme* | R | `references/ad-and-checkpointing/enzyme-gpu-2021.pdf` | ✅ HAVE | A |
| Griewank–Walther 2000 ACM TOMS 26(1), *Algorithm 799: revolve* | **P2** | `references/ad-and-checkpointing/griewank-walther-2000-revolve.pdf` | ⏸ DEFER | A |

## §2.8 Implementations to read (source clones, not papers)

| Project | Priority | Path | Status | Assigned |
|---|---|---|---|---|
| RC3 (THM), git.thm.de/thm-rc3/release | **P2** | `references/implementations/RC3/` | ✅ HAVE (SHA: 1b4c357) | C |
| TOPPS DIKU Janus, topps.diku.dk/pirc/ | **P2** | `references/implementations/TOPPS-janus/` | ✅ HAVE (kirkedal/Jana-JanusInterp, SHA: f1330f4) | C |
| jana (mbudde), github.com/mbudde/jana | R | `references/implementations/jana/` | ✅ HAVE (SHA: 5b51b57) | C |
| janus-vesta, github.com/janus-cpu/janus-vesta | R | `references/implementations/janus-vesta/` | ✅ HAVE (SHA: b798194) | C |
| evincarofautumn/Janus | R | `references/implementations/evincarofautumn-janus/` | ✅ HAVE (SHA: e5fe853) | C |
| Enzyme, github.com/EnzymeAD/Enzyme | **P2** | `references/implementations/Enzyme-src` (symlink → ../../../Bennett.jl/external/Enzyme) | ✅ HAVE (symlink) | — |
| Enzyme.jl | R | `references/implementations/Enzyme.jl-src` (symlink) | ✅ HAVE (symlink) | — |

---

## Acquisition workflow (for subagents)

1. **First check existing local mirrors.** Before fetching anything,
   grep across these locations:
   - `/home/tobiasosborne/Projects/Bennett.jl/docs/literature/`
   - `/home/tobiasosborne/Projects/research-notebook/raw/literature/`
   - `/home/tobiasosborne/Projects/Sturm.jl/docs/`
   - `/home/tobiasosborne/Projects/Feynfeld.jl/refs/papers/`
   - `/home/tobiasosborne/Projects/archivum/stores/` (if it indexes PDFs)

2. **Format preference order:**
   - arXiv source: `curl -L https://arxiv.org/e-print/<id> -o <name>.tar.gz`
     then unpack to `<name>-tex/`.
   - arXiv PDF: `curl -L https://arxiv.org/pdf/<id> -o <name>.pdf`.
   - Publisher PDF via playwright-cli (paywall via TIB VPN).
   - DJVU / OCR'd image PDF (last resort — needs marker).

3. **TIB VPN + playwright-cli pattern.** Pattern lifted from
   `/home/tobiasosborne/Projects/FQHE/scripts/fetch_via_browser.sh`:
   ```bash
   playwright-cli run-code "async page => {
     const resp = await page.request.get('<URL>', { timeout: 30000 });
     if (resp.status() !== 200) return 'ERROR:' + resp.status();
     const body = await resp.body();
     return body.toString('base64');
   }"
   ```
   Requires headed Chrome open and authenticated to the publisher
   (TIB VPN does the network part; Cloudflare bypass requires the
   session). If the browser session is not active, mark the item ⏸
   and report back instead of guessing.

4. **Naming.** Use the path listed in this manifest. If you must
   deviate, update the manifest in the same commit.

5. **Verify.** After each acquisition:
   - `file <path>` must report `PDF document` (not `HTML` and not 0
     bytes — those are paywall pages).
   - For arXiv: `pdfinfo <path> | head` to confirm not a 404 page.
   - Append SHA256 to this file in a "Sources hash log" section at
     the end (created on first append).

6. **Stop conditions.** If a paper is genuinely not retrievable
   (broken DOI, Caltech 1986 notes that were never digitized, etc.),
   mark ⏸ DEFER with a one-line reason rather than burning the
   session on it. The PRD does not require *every* §2 item — only
   those flagged P0 and P2.

---

## Sources hash log

Appended by Acquisition Subagent A, 2026-05-23. Format: `<sha256>  <path>`

```
75376370dad386515c13e604cdfc477528a978d473c64023246e87d58d9f118a  references/foundational/buhrman-tromp-vitanyi-2001.pdf
5a7a3de0ee75305071e98e6f29a34ac92962dc0d8d5069d92b492c12a690c539  references/foundational/buhrman-tromp-vitanyi-2001-tex/icalp01.tex
f348cc0a1fea3665edab4310208b57b896cf7fbac763e502a51fa7e688794e21  references/reverse-debugging/ocallahan-2017-rr-deployability.pdf
49dced8ce4eca783f44754961ab280337622be4c12a86f63b3402610c0a15427  references/reverse-debugging/rr-docs.md
a91a10676754f484e5c2b5958765c13316d18f64db13893d772ac1bbc5021b01  references/ad-and-checkpointing/enzyme-gpu-2021.pdf
e61ad66840e45bec4b67fa839cf3f89edd733b8e60c86b0c8fd03129de960687  references/foundational/bennett-1973-logical-reversibility.pdf
```

### Identity notes

- `references/foundational/vitanyi-reversible.pdf` (SHA256: `0f2183d98441f64f1e6ba4a5f395b0e7aef5e49d9290e4cab8f0c3315485f244`):
  This is **NOT** the Buhrman–Tromp–Vitanyi 2001 paper. It is the Vitanyi CF'05 survey
  "Time, Space, and Energy in Reversible Computing" (arXiv:cs/0504088v1, 2005). Same file
  as `vitanyi-time-space-energy.pdf` from Bennett.jl/docs/literature.
  The actual BTV 2001 paper (arXiv:quant-ph/0101133) is now at
  `references/foundational/buhrman-tromp-vitanyi-2001.pdf`.

### Deferred items and reasons

| Item | Reason deferred |
|---|---|
| ~~Bennett 1973 (P0)~~ | **RESOLVED 2026-05-25**: user supplied PDF (Windows downloads → `references/foundational/bennett-1973-logical-reversibility.pdf`). SHA256 `e61ad66840e45bec4b67fa839cf3f89edd733b8e60c86b0c8fd03129de960687`. Verified pages 1-3 against IBM JRD 17(6) Nov 1973: confirmed C.H. Bennett "Logical Reversibility of Computation", pp 525-532, three-tape construction with quintuples-to-quadruples standardization, three-stage Compute/Output/Cleanup theorem with explicit step/space bounds `4ν + 4λ + 5` steps and `s + ν + 1` work-tape squares (cite for Phase-2 Stage 2/3 design). |
| Landauer 1961 (R) | Same situation as Bennett 1973 was — IBM JRD on IEEE Xplore (doc 5392446, pdfPath /iel5/5288520/5392444/05392446.pdf), TIB VPN denied. Acquisition path: TIB ILL `fernleihe@tib.eu`, DOI `10.1147/rd.53.0183`. |
| LMT (Lange–McKenzie–Tapp) (R) | Pre-arXiv; SIAM and ACM DL both return 403 via TIB VPN; ECCC TR IDs not found; no open access version located. |
| Li–Vitanyi pebble chain lower bounds (R) | Pre-arXiv; no open access version found. arXiv cs/0602071 was a different paper. |
| O'Callahan–Huey 2020 ACM Queue (R) | ACM Queue returns 403 even via TIB VPN with browser session cookies. |
| Griewank–Walther 2000 revolve (P2) | ACM DL returns 403 via page.request despite browser navigation succeeding; page.request does not carry the Cloudflare clearance cookie. Author personal page 404. SIAM 403. |
| Hall 1994 PhysComp (R) | IEEE Xplore paywall; IEEE doc IDs searched exhaustively but IEEE JRD/PhysComp content denied same as IBM JRD. |
| Mogensen 2011 PEPM (R) | ACM DL returns 403 via TIB VPN; no preprint found. |
| Mogensen 2022 Hermes (R) | Elsevier ScienceDirect returns 403 via page.request even after browser nav; HAL preprint at hal-03177291 returned HTML not PDF. |
| James–Sabry 2012 Pi (R) | ACM DL returns 403 via TIB VPN; Indiana University legacy.cs.indiana.edu DNS failed. |

---

## Sources hash log — Subagent C acquisitions (2026-05-23)

```
3ea76a0c3cd0d067e92018486a3f0faa9ede3fafc357f8859f62c5953ef09bbb  references/reversible-isa/vieri-1995-pendulum-ms.pdf
8b4ef21105f8aeb560278e36353e70613b474cba3d2e29f481238967fc556141  references/reversible-isa/vieri-1999-reversible-arch-phd.pdf
325e0836602640020659fd61f63a5abe70fffa86b0490d5751833a6b735eec93  references/reversible-isa/axelsen-yokoyama-2011-bobisa.pdf
0f77a6c8b2bffccd9caf04a73c3e983d58292332ba5fc17bd2fcebd3e06516d7  references/reversible-isa/mogensen-2022-fast-control.pdf
b631ebca62513639b89f1ad5cd45397830557abf48033e2b688f2d52971ce22c  references/reversible-isa/frank-1999-thesis.pdf
add57a112a00aef176072ab287eec6503f8f2286cbbd473cfa794063c20edc7d  references/quantum-uncomputation/zhang-ying-2025-qrm.pdf
916ade819aace9a946071ede4eb0b9e8adfd4728f0f6d33b0a2b7c63948256c7  references/quantum-uncomputation/seidel-qrisp.pdf
```

### Citation-errata (Subagent C, 2026-05-23)

**frank-reversible-cmos.pdf is NOT Frank 1999 MIT PhD.**
`pdfinfo` shows: "Reversible Computing with Fast, Fully Static, Fully Adiabatic CMOS" (8 pages,
IEEE paper by M.P. Frank, Word-created 2020). The actual Frank 1999 MIT PhD thesis
("Reversibility for efficient computing", 406 pages, MIT DSpace 1721.1/9464) is now at
`references/reversible-isa/frank-1999-thesis.pdf`.

**"Axelsen–Yokoyama 2011 LATA" (BobISA) — PRD citation is incorrect.**
No Axelsen+Yokoyama paper on a reversible ISA from LATA 2011 exists. The actual BobISA paper is:
  Thomsen, Axelsen, Glück. "A Reversible Processor Architecture and Its Reversible Logic Design."
  RC 2012. DOI: 10.1007/978-3-642-29517-1_3.
Confirmed by Mogensen 2022 (Fast Control) reference [5].
PRD v4 should correct this citation. The file `axelsen-yokoyama-2011-bobisa.pdf` contains
the Thomsen+Axelsen+Glück 2012 paper.

---

## Sources hash log — Subagent D acquisitions (2026-05-23)

```
94e7dc88a91a9104d8e9957e9eb1a1434a39c780d46a48bf46a03fc53822fb95  references/reversible-ir/mogensen-2016-rssa.pdf
19e81160e209fb704f72df2e47f517bb8b8e9499344fdfa9a74c41179d9b9c12  references/reversible-ir/deworetzki-meyer-2021-janus-to-rssa.pdf
3107039a9431814e3c615539f6760c8e406092d185d72b9155bc3e7b33c06e6b  references/reversible-ir/deworetzki-2022-optimizing.pdf
1d9b0d8bca7afe41ec21f2d04df13ee9238d2cc080b2f732a6cca786ba682122  references/reversible-ir/deworetzki-2023-cfg-opt.pdf
117887974040b201ad949ea2bae6500533684dad4d7ef175061a68718c056fa4  references/reversible-ir/deworetzki-2024-hybrid-ssa.pdf
2be72912dcb96aeef87c18bdff9aba6b1308091ae4ef44313af90e452ded7072  references/reversible-ir/mogensen-ril.pdf
9845c37b0a1cae229ff97159398fbef553a1cade3071bd8e27b1b98294d7c60d  references/reversible-languages/yokoyama-axelsen-glueck-2011-rfun.pdf
d15713796bcd8c699740a330f385f38f92073865654a6d2b1368a97e0cd30105  references/reversible-languages/jacobsen-2018-corefun.pdf
```

### Acquisition notes (Subagent D, 2026-05-23)

**Springer LNCS access via TIB VPN confirmed working.**
The pattern `https://link.springer.com/content/pdf/10.1007/<DOI>.pdf` works directly
via `page.request.get()` once the browser has been opened with `--headed` Chromium and
the TIB VPN is active. No intermediate navigation to the chapter page is required —
the direct PDF URL returns HTTP 200 with `application/pdf` content-type immediately.
Page.request carries the TIB institutional credentials automatically.

**Yokoyama–Axelsen–Glück 2011 RFUN DOI correction.**
SOURCES.md listed "LNCS 7165" without a DOI. The correct DOI is
10.1007/978-3-642-29517-1_2 (chapter 2 in the RC 2011 proceedings, which is
978-3-642-29517-1). Chapter 3 in the same volume is the BobISA paper (already acquired
by Subagent C as axelsen-yokoyama-2011-bobisa.pdf). These are distinct papers.

**ACM DL inaccessible via TIB VPN + playwright.**
Even with the browser navigated to an ACM DL page (which renders the PDF correctly
in-browser), subsequent `page.request.get()` calls to the PDF URL return HTTP 403.
The Cloudflare clearance cookie is not forwarded by playwright-cli's request context.
Affected: Griewank revolve, Mogensen PEPM 2011, James-Sabry Pi, O'Callahan Queue.

**Bennett 1973 and Landauer 1961 (IBM JRD) hard-blocked.**
TIB VPN provides access to IEEE Xplore abstract pages (confirmed: TIB logo shows "Access
provided by: Technische Informationsbibliothek (TIB)"), but access to old IBM Journal of
Research and Development content (volume 5288520 on IEEE Xplore, from the 2009 IEEE
digitization of IBM JRD) is denied — redirects to `?denied=`. This is a separate
publisher-level entitlement not covered by standard IEEE subscription. Recommendation:
request via TIB ILL (https://www.tib.eu/de/suchen-finden/tib-portal-de-suche/ or
mailto:fernleihe@tib.eu) using DOI 10.1147/rd.176.0525 (Bennett) and 10.1147/rd.53.0183
(Landauer). Both are 8 pages; ILL delivery typically 1-3 days.

---

## Re-acquisition addendum (2026-06-10, this machine)

The PDFs marked HAVE above were never committed (licensed sources); on this
machine they were re-acquired per ADR 0017 CW-0 (bead bennettvm-416r.1):

| Path | SHA256 (this machine) | Note |
|---|---|---|
| `reversible-isa/vieri-1995-pendulum-ms.pdf` | matches manifest | MIT DSpace (archive.org mirror) |
| `reversible-isa/vieri-1999-reversible-arch-phd.pdf` | matches manifest | MIT DSpace (archive.org mirror) |
| `reversible-isa/frank-1999-thesis.pdf` | matches manifest | MIT DSpace (archive.org mirror) |
| `reversible-isa/axelsen-yokoyama-2011-bobisa.pdf` | `28bda96d…` DIFFERS | aggregate.org open copy of Thomsen–Axelsen–Glück RC 2012 (the actual BobISA paper per §Citation-errata); manifest hash was the Springer PDF |
| `foundational/bennett-1973-logical-reversibility.pdf` | `ad73fb54…` DIFFERS | UCSD Math course mirror; same paper, different scan than the user-supplied 496K copy |
| `reversible-languages/AxelsenGluck2013_reversible_heap.pdf` | `4415c987…` | local mirror: ../Bennett.jl/docs/literature/memory/ |
| `reversible-languages/Mogensen2018_reversible_gc.pdf` | `91edc495…` | NEW — Mogensen, "Reversible Garbage Collection for Reversible Functional Languages", NGC 36 (2018); local mirror ../Bennett.jl/docs/literature/memory/ (note: the §2.2 row says "AxelsenGluck2018_reversible_gc.pdf" — that row's attribution appears to be this Mogensen paper) |
| `reversible-ir/mogensen-2016-rssa.pdf` | — STILL MISSING | Springer paywall; sync from acquisition machine or TIB (bead filed) |
| `reversible-ir/mogensen-ril.pdf` | — STILL MISSING | Springer paywall; sync from acquisition machine or TIB (bead filed) |

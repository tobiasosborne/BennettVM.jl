# emulator/bench_forward.jl — B1 (bd `bennettvm-zr7x`): forward-throughput
# benchmark, fast (`record=false`) vs normal (recording) mode.
#
# # What this measures
#
# The Track-B framerate baseline (`docs/design/emulator-on-bennettvm.md`
# §9.2): "A forward-only fast mode (drop the tape) lands first to benchmark
# raw speed and decouple 'plays at speed' from 'is reversible'." This script
# runs the E0 MVP 6502 core (`docs/design/emulator-mvp/mos6502.c` — the
# same asset `run_mvp.jl` proves correct/reversible; this script does NOT
# duplicate that proof, it times the forward pass) at a few input sizes,
# in both modes, and reports:
#
#   * VM-steps/sec   — `RState.step_count` / wall-time. The interpreter-
#     dispatch-level throughput (`step!` calls/sec).
#   * guest-instr/sec — 6502-opcode-level throughput, using the CLOSED-FORM
#     instruction count for this fixed guest program (see `guest_instrs`
#     below) rather than trying to instrument the C-sourced VMProgram's
#     locals — the guest program's `budget` counter lives inside `mem`-
#     backed C state, not a stable Julia-visible local name.
#   * the fast/normal speedup, and the measured VM-steps-per-guest-instr
#     ratio (a sanity cross-check against the design note's estimated
#     "20-80 VM step! calls per guest 6502 instruction", §9.1).
#
# `record=false` (fast mode, `src/interpreter/Interpreter.jl` B1) skips
# ALL L1/L2/L3 history bookkeeping (reuses the M7.6 `replay_mode`
# suppression machinery — see that file's docstring); `record=true`
# (default) is the normal path this repo's round-trip tests already
# exercise. Both modes are validated to produce IDENTICAL forward results
# before any number is reported (Rule 4) — a speed number from a run that
# silently diverged from the recording path would be worse than useless.
#
# # Why the E0 MVP asset, not the in-progress E1 full core
#
# `emulator/cpu6502.c` (E1, bd `bennettvm-zbeg`) is a separate, larger,
# still-in-development core. The E0 MVP (`docs/design/emulator-mvp/`) is
# the smallest STABLE, already-proven-correct guest program available,
# which is exactly what a throughput baseline needs — the number this
# script reports is "how fast is the interpreter", not "how fast is a
# work-in-progress 6502 core".
#
# Run (from repo root):
#
#     julia --project emulator/bench_forward.jl

using BennettVM
import Bennett
const _BV = BennettVM
const _B  = Bennett

const HERE = @__DIR__
const LL   = joinpath(HERE, "..", "docs", "design", "emulator-mvp",
                      "mos6502.O0.ll")
const K    = 32       # checkpoint_interval; moot in fast mode (see B1 docs)
const REPS = 5        # per (mode, n) timing: report the MINIMUM of REPS runs
                       # (standard microbenchmark practice — the minimum is
                       # the closest single measurement gets to "no GC / no
                       # scheduler noise", per BenchmarkTools' own rationale;
                       # avoided as a hard dependency here to keep this
                       # script standalone per the B1 brief).

isfile(LL) || error("bench_forward.jl: $LL not found. Regenerate via ",
                     "`cd docs/design/emulator-mvp && clang -O0 -S ",
                     "-emit-llvm -fno-discard-value-names -std=c11 ",
                     "mos6502.c -o mos6502.O0.ll` (see that dir's README.md).")

# The entry's single-i64 return SSA name (mirrors run_mvp.jl's helper —
# NOT hard-coding the extractor's rename so this script survives an
# unrelated ir_extract.jl naming-convention change; CLAUDE.md Rule 5
# analogue for Bennett.jl, cited in run_mvp.jl).
function _return_symbol(prog, entry::Symbol)
    for b in prog.blocks
        if b.exit isa _BV.EndInstruction && b.exit.label === entry &&
           !isempty(b.exit.returns)
            return b.exit.returns[1]
        end
    end
    error("no EndInstruction with returns for entry :$entry")
end

# Closed-form guest-6502-instruction count for `mos6502(n)`, n ∈ [1,255]
# (no `& 0xFF` wraparound — see mos6502.c's header comment). Prologue
# (LDA #0/STA ×2 = 4 opcodes) + n loop-body executions (LDA/ADC/STA/INC/
# LDA/CMP/BNE = 7 opcodes each) + epilogue (LDA/BRK = 2 opcodes).
guest_instrs(n::Int) = 4 + 7 * n + 2

println("=== ingest mos6502.O0.ll (ptr_cells=true) ===")
t_ext = @elapsed const SET = _B.extract_parsed_ir_set_from_ll(LL; ptr_cells = true)
println("  extracted $(length(SET)) function(s) in $(round(t_ext, digits = 1))s")

println("=== lower_vm(entry=:mos6502) ===")
t_low = @elapsed const PROG = _BV.lower_vm(SET; entry = :mos6502)
const RET = _return_symbol(PROG, :mos6502)
println("  lowered in $(round(t_low, digits = 1))s → " *
        "$(_BV.n_instructions(PROG)) instrs; ret=$RET")

# One forward run at the given `n`, in fast (`record=false`) or normal
# (`record=true`) mode. Returns the halted RState.
function forward_run(n::Int; record::Bool)
    rs = _BV.initial_state(PROG, Dict(:n => Int64(n)))
    _BV.run!(rs, PROG; max_steps = 200_000_000, checkpoint_interval = K,
             record = record)
    return rs
end

# Minimum wall-time over REPS repetitions, plus the LAST rep's halted
# RState (for the correctness cross-check below — every rep produces an
# identical result since the VM is deterministic, so "last" is as good
# as "first").
function time_min(n::Int; record::Bool, reps::Int = REPS)
    best = Inf
    local rs
    for _ in 1:reps
        rs = _BV.initial_state(PROG, Dict(:n => Int64(n)))
        t = @elapsed _BV.run!(rs, PROG; max_steps = 200_000_000,
                              checkpoint_interval = K, record = record)
        best = min(best, t)
    end
    return best, rs
end

println("\n=== warm-up (untimed, n=1, both modes — pays one-time JIT compile) ===")
forward_run(1; record = true)
forward_run(1; record = false)

const NS = (10, 50, 100, 200)

println("\n=== forward throughput: fast (record=false) vs normal (record=true) ===")
println("(minimum wall-time over $REPS reps per cell; VM-steps = interpreter ",
        "step! dispatches; guest-instr = 6502 opcodes, closed-form)")
println()
hdr = ["n", "VM steps", "guest instr", "fast(s)", "norm(s)",
       "fast VM/s", "fast gi/s", "norm VM/s", "norm gi/s", "speedup",
       "VM/guest-instr"]
println(join(rpad.(hdr, 14)))

for n in NS
    t_fast, rs_fast = time_min(n; record = false)
    t_norm, rs_norm = time_min(n; record = true)

    # Rule 4: never report a speed number from a run that might have
    # silently diverged. Both modes must (a) halt, (b) agree bit-for-bit
    # on every local (not just the return value), (c) take the same
    # number of VM steps, and (d) fast mode must have an empty tape.
    _BV.is_halted(rs_fast) || error("bench: fast run n=$n did not halt")
    _BV.is_halted(rs_norm) || error("bench: normal run n=$n did not halt")
    _BV.result(rs_fast) == _BV.result(rs_norm) ||
        error("bench: fast/normal result MISMATCH at n=$n — refusing to ",
              "report a speed number for a possibly-miscompiled run ",
              "(Rule 4).")
    rs_fast.step_count == rs_norm.step_count ||
        error("bench: fast/normal step_count MISMATCH at n=$n ",
              "($(rs_fast.step_count) vs $(rs_norm.step_count)).")
    isempty(rs_fast.history) ||
        error("bench: fast-mode history non-empty at n=$n — B1 regression.")
    rs_fast.fast_mode || error("bench: fast_mode flag not set at n=$n.")

    steps = rs_fast.step_count
    ginstr = guest_instrs(n)
    row = [string(n), string(steps), string(ginstr),
           string(round(t_fast; sigdigits = 3)),
           string(round(t_norm; sigdigits = 3)),
           string(round(Int, steps / t_fast)),
           string(round(Int, ginstr / t_fast)),
           string(round(Int, steps / t_norm)),
           string(round(Int, ginstr / t_norm)),
           string(round(t_norm / t_fast; digits = 2)) * "x",
           string(round(steps / ginstr; digits = 1))]
    println(join(rpad.(row, 14)))
end

println()
println("=== done — Track-B framerate baseline. See ",
        "docs/design/emulator-on-bennettvm.md §9 for the SMB-at-60fps ",
        "gap these numbers are measured against. ===")

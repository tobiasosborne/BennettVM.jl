# smoke6502.jl — escalating feasibility probe for "6502 core on BennettVM".
# Each test stresses ONE of the 5 requirements from the capability audit.
# Every test is wrapped so one failure doesn't abort the rest — the goal is a
# feasibility MAP, not a pass/fail. Run:  julia --project /path/smoke6502.jl
using Bennett, BennettVM
import Bennett

const OK  = "\e[32m[PASS]\e[0m"
const BAD = "\e[31m[FAIL]\e[0m"

function probe(name, f, ArgType, inputs; oracle=f)
    println("\n=== $name ===")
    local vm
    try
        vm = Bennett.reversible_compile(f, ArgType; target = :reversible_vm)
    catch e
        println("$BAD compile threw: ", sprint(showerror, e)[1:min(end,400)])
        return false
    end
    println("  compiled → $(typeof(vm)); $(BennettVM.n_instructions(vm)) instrs")
    # recover arg/ret SSA keys from Begin/End markers
    binst = einst = nothing
    for b in vm.blocks
        b.entry isa BennettVM.BeginInstruction && (binst = b.entry)
        b.exit  isa BennettVM.EndInstruction   && (einst = b.exit)
    end
    (binst === nothing || einst === nothing) && (println("$BAD no Begin/End markers"); return false)
    argk = binst.params[1]; retk = einst.returns[1]
    allgood = true
    for x in inputs
        try
            rs = initial_state(vm, Dict(argk => x))
            snap = deepcopy(rs.initial)
            run!(rs, vm; max_steps = 100_000, checkpoint_interval = 8)
            got = result(rs)[retk]; want = oracle(x)
            fwd_ok = got == want
            unrun!(rs, vm)
            rev_ok = (rs.current == rs.initial) && isempty(rs.history) && (rs.initial == snap)
            mark = (fwd_ok && rev_ok) ? OK : BAD
            println("  x=$x  fwd=$got want=$want $(fwd_ok ? "✓" : "✗")  roundtrip=$(rev_ok ? "✓" : "✗")  $mark")
            allgood &= (fwd_ok && rev_ok)
        catch e
            println("  x=$x  $BAD run threw: ", sprint(showerror, e)[1:min(end,300)])
            allgood = false
        end
    end
    return allgood
end

# ── A. BASELINE: scalar unbounded loop (reproduces the known-good Collatz) ──
function collatz_i64(x::Int64)
    steps = Int64(0); val = x
    while val > Int64(1) && steps < Int64(20)
        if val % Int64(2) == Int64(0); val = val >> Int64(1)
        else; val = Int64(3)*val + Int64(1); end
        steps += Int64(1)
    end
    return steps
end
probe("A. baseline collatz (loop + branch, scalar)", collatz_i64, Int64,
      Int64[1,2,3,6,7,27])

# ── B. OPCODE DISPATCH: a fetch-decode-execute loop over a program encoded ──
#    in the input's bytes. Register-only (A accumulator), no RAM. This is the
#    heart of a 6502 core: a `while` over an opcode `switch`.
#    Program = 4 nibbles of `prog`; op 0:+1  1:*2(ASL)  2:^0xF(EOR)  3:halt.
function tinycpu(prog::Int64)
    A = Int64(0); pc = Int64(0); running = Int64(1)
    while running == Int64(1) && pc < Int64(4)
        op = (prog >> (pc*Int64(4))) & Int64(0xF)
        if op == Int64(0);     A = (A + Int64(1)) & Int64(0xFF)
        elseif op == Int64(1); A = (A << Int64(1)) & Int64(0xFF)
        elseif op == Int64(2); A = xor(A, Int64(0xF)) & Int64(0xFF)
        else; running = Int64(0); end
        pc += Int64(1)
    end
    return A
end
probe("B. fetch-decode-execute (opcode switch, register-only)", tinycpu, Int64,
      Int64[0x0000, 0x0001, 0x0010, 0x0210, 0x3000, 0x1111])

# ── C. DYNAMIC MEMORY (the RAM question): allocate a small array, write and ──
#    read it at a RUNTIME-computed index. This is the make-or-break for RAM.
function ramtest(seed::Int64)
    ram = zeros(Int64, 8)
    i = seed & Int64(7)
    ram[i + Int64(1)] = seed & Int64(0xFF)
    j = (seed >> Int64(3)) & Int64(7)
    ram[j + Int64(1)] = (ram[j + Int64(1)] + Int64(1)) & Int64(0xFF)
    return ram[i + Int64(1)]
end
probe("C. dynamic array read/write @ runtime index (RAM)", ramtest, Int64,
      Int64[0x00, 0x09, 0x1A, 0x3F])

println("\n=== smoke complete ===")

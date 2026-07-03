# smoke_dispatch.jl — find an opcode-dispatch encoding that survives extraction.
# Test B failed because LLVM turned a flat if/elseif over DENSE small opcodes
# {0,1,2} into a switch.table lookup GEP. Hypotheses:
#   D1 sparse real-6502 opcodes  → stays a `switch` instr (not a dense table)?
#   D2 nested binary-tree of ifs → comparison chain, no table?
#   D3 dense but arms with divergent control flow (write pc/running per arm)?
#   D4 the ORIGINAL dense arithmetic-only arms (control: should FAIL again)
using Bennett, BennettVM
import Bennett
const OK="\e[32mPASS\e[0m"; const BAD="\e[31mFAIL\e[0m"

function probe(name, f, inputs)
    println("\n=== $name ===")
    local vm
    try
        vm = Bennett.reversible_compile(f, Int64; target=:reversible_vm)
    catch e
        s = sprint(showerror, e)
        println("  $BAD compile: ", s[1:min(end,220)]); return
    end
    binst=einst=nothing
    for b in vm.blocks
        b.entry isa BennettVM.BeginInstruction && (binst=b.entry)
        b.exit  isa BennettVM.EndInstruction   && (einst=b.exit)
    end
    argk=binst.params[1]; retk=einst.returns[1]
    ok=true
    for x in inputs
        try
            rs=initial_state(vm, Dict(argk=>x)); snap=deepcopy(rs.initial)
            run!(rs,vm;max_steps=100_000,checkpoint_interval=8)
            got=result(rs)[retk]; want=f(x)
            unrun!(rs,vm)
            rt=(rs.current==rs.initial)&&isempty(rs.history)&&(rs.initial==snap)
            ok &= (got==want && rt)
        catch e; println("  x=$x run: ",sprint(showerror,e)[1:min(end,160)]); ok=false end
    end
    println("  ", ok ? OK : BAD, "  ($(BennettVM.n_instructions(vm)) instrs, $(length(inputs)) inputs)")
end

# D1 — SPARSE real 6502 opcodes (LDA# A9, INX E8, EOR# 49, ASL-A 0A, NOP EA).
# Program is 3 opcode bytes packed into `prog` (LSB first). Sparse switch.
function cpu_sparse(prog::Int64)
    A=Int64(0); pc=Int64(0); run=Int64(1)
    while run==Int64(1) && pc<Int64(3)
        op=(prog >> (pc*Int64(8))) & Int64(0xFF)
        if op==Int64(0xE8);     A=(A+Int64(1)) & Int64(0xFF)   # INX-ish
        elseif op==Int64(0x0A); A=(A<<Int64(1)) & Int64(0xFF)  # ASL A
        elseif op==Int64(0x49); A=xor(A,Int64(0x0F)) & Int64(0xFF) # EOR #$0F
        elseif op==Int64(0xEA); A=A                            # NOP
        else; run=Int64(0); end
        pc+=Int64(1)
    end
    return A
end
probe("D1 sparse real-6502 opcodes", cpu_sparse,
      Int64[0xE8, 0x0AE8, 0x49E8, 0xEAEA, 0x0A0A0A, 0xE8E8E8])

# D2 — nested binary tree of comparisons (defeats dense-table heuristic).
function cpu_tree(prog::Int64)
    A=Int64(0); pc=Int64(0); run=Int64(1)
    while run==Int64(1) && pc<Int64(4)
        op=(prog >> (pc*Int64(4))) & Int64(0xF)
        if op < Int64(2)
            if op==Int64(0); A=(A+Int64(1))&Int64(0xFF) else A=(A<<Int64(1))&Int64(0xFF) end
        else
            if op==Int64(2); A=xor(A,Int64(0xF))&Int64(0xFF) else run=Int64(0) end
        end
        pc+=Int64(1)
    end
    return A
end
probe("D2 nested binary-tree dispatch", cpu_tree,
      Int64[0x0000,0x0001,0x0210,0x3000,0x1111])

# D3 — dense opcodes but each arm perturbs control (pc/run) divergently.
function cpu_divergent(prog::Int64)
    A=Int64(0); pc=Int64(0); run=Int64(1)
    while run==Int64(1) && pc<Int64(4)
        op=(prog >> (pc*Int64(4))) & Int64(0xF)
        if op==Int64(0);     A=(A+Int64(1))&Int64(0xFF); pc+=Int64(1)
        elseif op==Int64(1); A=(A<<Int64(1))&Int64(0xFF); pc+=Int64(1)
        elseif op==Int64(2); A=xor(A,Int64(0xF))&Int64(0xFF); pc+=Int64(2)  # 2-byte op
        else; run=Int64(0); pc+=Int64(1); end
    end
    return A
end
probe("D3 dense arms w/ divergent pc advance", cpu_divergent,
      Int64[0x0000,0x0001,0x0210,0x3000,0x1111])

println("\n=== dispatch smoke complete ===")

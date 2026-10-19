module smedja.arch.x86_64;

import smedja.ir;
import smedja.arch;
import smedja.errors : CodeGenerationException, InvalidIRException,
    UnsupportedOperationException;

enum : RegId
{
    RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15
}

enum ushort AMD64Rel32 = 0x0004;

private RegSet amd64Regs = {
    regs: [
        Reg(RAX, RegClass.gpr, 8, "rax"),
        Reg(RCX, RegClass.gpr, 8, "rcx"),
        Reg(RDX, RegClass.gpr, 8, "rdx"),
        Reg(RBX, RegClass.gpr, 8, "rbx"),
        Reg(RSP, RegClass.gpr, 8, "rsp"),
        Reg(RBP, RegClass.gpr, 8, "rbp"),
        Reg(RSI, RegClass.gpr, 8, "rsi"),
        Reg(RDI, RegClass.gpr, 8, "rdi"),
        Reg(R8, RegClass.gpr, 8, "r8"),
        Reg(R9, RegClass.gpr, 8, "r9"),
        Reg(R10, RegClass.gpr, 8, "r10"),
        Reg(R11, RegClass.gpr, 8, "r11"),
        Reg(R12, RegClass.gpr, 8, "r12"),
        Reg(R13, RegClass.gpr, 8, "r13"),
        Reg(R14, RegClass.gpr, 8, "r14"),
        Reg(R15, RegClass.gpr, 8, "r15"),
    ],
    stackPtr: RSP,
    framePtr: RBP,
    calleeSaved: [RBX, RBP, RSI, RDI, R12, R13, R14, R15],
    callerSaved: [RAX, RCX, RDX, R8, R9, R10, R11],
};

private struct BranchFixup
{
    uint displacement;
    uint target;
}

private struct X64Codegen
{
    private Func* func;
    private MachFunc machineFunc;
    private int[] valueOffsets;
    private uint[] blockOffsets;
    private BranchFixup[] branches;
    private uint frameBytes;

    this(ref Func func)
    {
        this.func = &func;
        machineFunc.name = func.name;
        valueOffsets = new int[](func.values.length);
        blockOffsets = new uint[](func.blocks.length);
        foreach (index, value; func.values)
        {
            requireInteger(value.type);
            frameBytes += 8;
            valueOffsets[index] = -cast(int) frameBytes;
        }
        frameBytes += 32;
        frameBytes = (frameBytes + 15) & ~15u;
        machineFunc.frameSize = frameBytes;
    }

    private void requireInteger(Type type)
    {
        if ((type.kind != TypeKind.i32 && type.kind != TypeKind.i64 &&
             type.kind != TypeKind.bool_) &&
            type.kind != TypeKind.ptr && type.kind != TypeKind.func)
            throw new UnsupportedOperationException(
                    "x86-64 Windows backend supports i32, i64, bool, and pointers");
    }

    private bool wide(Type type)
    {
        return type.kind == TypeKind.i64 || type.kind == TypeKind.ptr ||
            type.kind == TypeKind.func;
    }

    private void emit(ubyte value)
    {
        machineFunc.code ~= value;
    }

    private void emit32(uint value)
    {
        foreach (shift; 0 .. 4)
            emit(cast(ubyte)(value >> (shift * 8)));
    }

    private int offset(Value value)
    {
        if (value.isNone || value.id >= valueOffsets.length)
            throw new InvalidIRException("invalid value used by x86-64 code generation");
        return valueOffsets[value.id];
    }

    private Type typeOf(Value value)
    {
        if (value.isNone || value.id >= func.values.length)
            throw new InvalidIRException("invalid value used by x86-64 code generation");
        return func.values[value.id].type;
    }

    private void loadRax(Value value)
    {
        if (wide(typeOf(value)))
            emit(0x48);
        emit(0x8B);
        emit(0x85);
        emit32(cast(uint) offset(value));
    }

    private void loadRcx(Value value)
    {
        if (wide(typeOf(value)))
            emit(0x48);
        emit(0x8B);
        emit(0x8D);
        emit32(cast(uint) offset(value));
    }

    private void storeRax(Value value)
    {
        if (wide(typeOf(value)))
            emit(0x48);
        emit(0x89);
        emit(0x85);
        emit32(cast(uint) offset(value));
    }

    private void storeRegister(Value value, ubyte reg)
    {
        auto type = typeOf(value);
        ubyte rex = wide(type) ? 0x48 : 0x40;
        if (reg >= 8)
            rex |= 0x04;
        if (rex != 0x40)
            emit(rex);
        emit(0x89);
        emit(cast(ubyte)(0x85 | ((reg & 7) << 3)));
        emit32(cast(uint) offset(value));
    }

    private void loadArgumentRegister(Value value, ubyte reg)
    {
        if (wide(typeOf(value)))
            emit(0x48);
        emit(0x8B);
        emit(0x85);
        emit32(cast(uint) offset(value));
        ubyte rex = 0x48;
        if (reg >= 8)
            rex |= 0x01;
        emit(rex);
        emit(0x89);
        emit(cast(ubyte)(0xC0 | ((RAX & 7) << 3) | (reg & 7)));
    }

    private void branchTo(uint target, ubyte opcode)
    {
        emit(opcode);
        auto displacement = cast(uint) machineFunc.code.length;
        emit32(0);
        branches ~= BranchFixup(displacement, target);
    }

    private void patchBranches()
    {
        foreach (branch; branches)
        {
            if (branch.target >= blockOffsets.length)
                throw new InvalidIRException("branch target is outside the function");
            auto relative = cast(int) blockOffsets[branch.target] -
                cast(int)(branch.displacement + 4);
            auto bits = cast(uint) relative;
            foreach (shift; 0 .. 4)
                machineFunc.code[branch.displacement + shift] =
                    cast(ubyte)(bits >> (shift * 8));
        }
    }

    private void emitConstant(Instr instruction)
    {
        if (instruction.dst.isNone)
            throw new InvalidIRException("x86-64 constant requires a result");
        if (instruction.symbol.length)
        {
            if (!wide(typeOf(instruction.dst)))
                throw new InvalidIRException("symbol constant requires a pointer result");
            emit(0x48); emit(0x8D); emit(0x05);
            auto relocationOffset = cast(uint) machineFunc.code.length;
            emit32(0);
            machineFunc.relocs ~= MachReloc(relocationOffset,
                    instruction.symbol, AMD64Rel32);
        }
        else
        {
            if (instruction.imm.kind != Const.Kind.i)
                throw new UnsupportedOperationException(
                        "x86-64 backend only supports integer constants");
            if (wide(typeOf(instruction.dst)))
            {
                emit(0x48); emit(0xB8);
                auto bits = cast(ulong) instruction.imm.i;
                foreach (shift; 0 .. 8)
                    emit(cast(ubyte)(bits >> (shift * 8)));
            }
            else
            {
                emit(0xB8);
                emit32(cast(uint) instruction.imm.i);
            }
        }
        storeRax(instruction.dst);
    }

    private void emitBinary(Instr instruction)
    {
        if (instruction.uses.length != 2)
            throw new InvalidIRException("x86-64 binary operation requires two values");
        if (instruction.type.kind != TypeKind.i32 &&
            instruction.type.kind != TypeKind.i64)
            throw new UnsupportedOperationException(
                    "x86-64 arithmetic supports i32 and i64 values");
        auto lhs = instruction.uses[0];
        auto rhs = instruction.uses[1];
        if (typeOf(lhs).kind != instruction.type.kind ||
            typeOf(rhs).kind != instruction.type.kind)
            throw new InvalidIRException(
                    "x86-64 arithmetic operands must match the result type");
        loadRax(lhs);
        loadRcx(rhs);
        if (wide(instruction.type))
            emit(0x48);
        final switch (instruction.op)
        {
        case Op.add: emit(0x01); emit(0xC8); break;
        case Op.sub: emit(0x29); emit(0xC8); break;
        case Op.mul: emit(0x0F); emit(0xAF); emit(0xC1); break;
        case Op.and_: emit(0x21); emit(0xC8); break;
        case Op.or_: emit(0x09); emit(0xC8); break;
        case Op.xor_: emit(0x31); emit(0xC8); break;
        case Op.const_, Op.sdiv, Op.udiv, Op.srem, Op.urem, Op.fadd,
             Op.fsub, Op.fmul, Op.fdiv, Op.shl, Op.ashr, Op.lshr,
             Op.icmp, Op.fcmp, Op.sext, Op.zext, Op.trunc, Op.sitofp,
             Op.uitofp, Op.fptosi, Op.fptoui, Op.bitcast, Op.alloca,
             Op.load, Op.store, Op.gep, Op.br, Op.condbr, Op.ret,
             Op.unreachable, Op.call, Op.phi:
            throw new UnsupportedOperationException(
                    "unsupported x86-64 binary operation");
        }
        storeRax(instruction.dst);
    }

    private ubyte conditionCode(Pred pred)
    {
        final switch (pred)
        {
        case Pred.eq: return 0x94;
        case Pred.ne: return 0x95;
        case Pred.slt, Pred.lt: return 0x9C;
        case Pred.sle, Pred.le: return 0x9E;
        case Pred.sgt, Pred.gt: return 0x9F;
        case Pred.sge, Pred.ge: return 0x9D;
        case Pred.ult: return 0x92;
        case Pred.ule: return 0x96;
        case Pred.ugt: return 0x97;
        case Pred.uge: return 0x93;
        }
    }

    private void emitCompare(Instr instruction)
    {
        if (instruction.uses.length != 2)
            throw new InvalidIRException("x86-64 comparison requires two values");
        auto lhs = instruction.uses[0];
        auto rhs = instruction.uses[1];
        if ((typeOf(lhs).kind != TypeKind.i32 &&
             typeOf(lhs).kind != TypeKind.i64) ||
            typeOf(lhs).kind != typeOf(rhs).kind)
            throw new InvalidIRException(
                    "x86-64 comparisons require matching i32 or i64 values");
        loadRax(lhs);
        loadRcx(rhs);
        if (wide(typeOf(lhs)))
            emit(0x48);
        emit(0x39); emit(0xC8);
        emit(0x0F); emit(conditionCode(instruction.pred)); emit(0xC0);
        emit(0x0F); emit(0xB6); emit(0xC0);
        storeRax(instruction.dst);
    }

    private void emitCall(Instr instruction)
    {
        if (!instruction.symbol.length)
            throw new UnsupportedOperationException(
                    "x86-64 Windows backend requires a direct call symbol");
        if (instruction.uses.length > 4)
            throw new UnsupportedOperationException(
                    "x86-64 Windows backend supports at most four call arguments");
        immutable ubyte[4] argumentRegisters = [RCX, RDX, R8, R9];
        foreach (index, argument; instruction.uses)
            loadArgumentRegister(argument, argumentRegisters[index]);
        emit(0xE8);
        auto relocationOffset = cast(uint) machineFunc.code.length;
        emit32(0);
        machineFunc.relocs ~= MachReloc(relocationOffset,
                instruction.symbol, AMD64Rel32);
        if (!instruction.dst.isNone)
            storeRax(instruction.dst);
    }

    private void emitInstruction(Instr instruction)
    {
        final switch (instruction.op)
        {
        case Op.const_:
            emitConstant(instruction);
            break;
        case Op.add, Op.sub, Op.mul, Op.and_, Op.or_, Op.xor_:
            emitBinary(instruction);
            break;
        case Op.icmp:
            emitCompare(instruction);
            break;
        case Op.br:
            branchTo(instruction.target, 0xE9);
            break;
        case Op.condbr:
            if (instruction.uses.length != 1)
                throw new InvalidIRException(
                        "x86-64 conditional branch requires one condition");
            loadRax(instruction.uses[0]);
            emit(0x85); emit(0xC0);
            emit(0x0F); emit(0x85);
            auto displacement = cast(uint) machineFunc.code.length;
            emit32(0);
            branches ~= BranchFixup(displacement, instruction.target);
            branchTo(instruction.altTarget, 0xE9);
            break;
        case Op.ret:
            if (instruction.uses.length > 1)
                throw new InvalidIRException(
                        "x86-64 return accepts at most one value");
            if (instruction.uses.length)
                loadRax(instruction.uses[0]);
            emit(0x48); emit(0x89); emit(0xEC);
            emit(0x5D); emit(0xC3);
            break;
        case Op.call:
            emitCall(instruction);
            break;
        case Op.unreachable:
            emit(0x0F); emit(0x0B);
            break;
        case Op.sdiv, Op.udiv, Op.srem, Op.urem, Op.fadd, Op.fsub,
             Op.fmul, Op.fdiv, Op.shl, Op.ashr, Op.lshr, Op.fcmp,
             Op.sext, Op.zext, Op.trunc, Op.sitofp, Op.uitofp,
             Op.fptosi, Op.fptoui, Op.bitcast, Op.alloca, Op.load,
             Op.store, Op.gep, Op.phi:
            throw new UnsupportedOperationException(
                    "unsupported operation in x86-64 Windows backend");
        }
    }

    MachFunc compile()
    {
        if (!func.blocks.length)
            throw new InvalidIRException(
                    "cannot generate x86-64 code for a function without blocks");
        if (func.params.length > 4)
            throw new UnsupportedOperationException(
                    "x86-64 Windows backend supports at most four parameters");

        emit(0x55);
        emit(0x48); emit(0x89); emit(0xE5);
        emit(0x48); emit(0x81); emit(0xEC); emit32(frameBytes);
        immutable ubyte[4] parameterRegisters = [RCX, RDX, R8, R9];
        foreach (index, param; func.params)
        {
            requireInteger(param.type);
            storeRegister(param.value, parameterRegisters[index]);
        }

        foreach (blockIndex, block; func.blocks)
        {
            if (block.id != blockIndex)
                throw new InvalidIRException(
                        "basic block ids must match their function indices");
            blockOffsets[blockIndex] = cast(uint) machineFunc.code.length;
            machineFunc.blocks ~= MachBlock(block.name);
            foreach (instruction; block.instrs)
                emitInstruction(instruction);
        }
        patchBranches();
        return machineFunc;
    }
}

final class Win64ABI : ABI
{
    CallingConv conv() { return CallingConv.win64; }
    uint shadowSpace() { return 32; }

    Allocation[] classify(Type[] params)
    {
        immutable RegId[4] registers = [RCX, RDX, R8, R9];
        Allocation[] result;
        foreach (index, type; params)
        {
            if ((type.kind != TypeKind.i32 && type.kind != TypeKind.i64 &&
                 type.kind != TypeKind.bool_) &&
                type.kind != TypeKind.ptr && type.kind != TypeKind.func)
                throw new UnsupportedOperationException(
                        "Win64 ABI classification supports i32, i64, bool, and pointers");
            if (index < registers.length)
                result ~= Allocation(Allocation.Kind.reg, registers[index],
                        0, type, 0);
            else
                result ~= Allocation(Allocation.Kind.stack, 0,
                        40 + cast(uint)(index - registers.length) * 8,
                        type, 0);
        }
        return result;
    }

    Allocation returnSlot(Type ret)
    {
        if ((ret.kind != TypeKind.i32 && ret.kind != TypeKind.i64 &&
             ret.kind != TypeKind.bool_) &&
            ret.kind != TypeKind.ptr && ret.kind != TypeKind.func &&
            !ret.isVoid)
            throw new UnsupportedOperationException(
                    "Win64 ABI returns only i32, i64, bool, pointers, or void");
        return Allocation(Allocation.Kind.reg, RAX, 0, ret, 0);
    }
}

final class X86_64Target : Target
{
    string name() { return "x86_64-windows"; }
    uint pointerSize() { return 8; }
    uint stackAlign() { return 16; }
    RegSet registers() { return amd64Regs; }

    ABI abi(CallingConv cc)
    {
        if (cc != CallingConv.win64)
            throw new UnsupportedOperationException(
                    "x86-64 Windows target only supports win64 calling convention");
        return new Win64ABI();
    }

    MachFunc selectAndAlloc(ref Func func)
    {
        return X64Codegen(func).compile();
    }
}

unittest
{
    auto target = new X86_64Target();
    assert(target.name == "x86_64-windows");
    assert(target.pointerSize == 8);
    assert(target.stackAlign == 16);
    assert(target.abi(CallingConv.win64).shadowSpace == 32);

    auto abi = cast(Win64ABI) target.abi(CallingConv.win64);
    auto allocations = abi.classify([
        Type.i64(), Type.i32(), Type.ptr(), Type.i64(), Type.i32()
    ]);
    assert(allocations[0].reg == RCX);
    assert(allocations[1].reg == RDX);
    assert(allocations[2].reg == R8);
    assert(allocations[3].reg == R9);
    assert(allocations[4].kind == Allocation.Kind.stack);
    assert(allocations[4].offset == 40);
}

unittest
{
    auto func = Func();
    func.name = "sum";
    func.newBlock("entry");
    auto lhs = func.newValue(Type.i64());
    auto rhs = func.newValue(Type.i64());
    auto sum = func.newValue(Type.i64());
    func.blocks[0].instrs ~= Instr(op: Op.const_, dst: lhs,
            type: Type.i64(), imm: Const.int_(20));
    func.blocks[0].instrs ~= Instr(op: Op.const_, dst: rhs,
            type: Type.i64(), imm: Const.int_(22));
    func.blocks[0].instrs ~= Instr(op: Op.add, dst: sum,
            type: Type.i64(), uses: [lhs, rhs]);
    func.blocks[0].instrs ~= Instr(op: Op.ret, uses: [sum]);

    auto machineFunc = (new X86_64Target()).selectAndAlloc(func);
    assert(machineFunc.code.length > 20);
    assert(machineFunc.code[$ - 1] == 0xC3);
}

unittest
{
    auto func = Func();
    func.name = "branch";
    func.newBlock("entry");
    func.newBlock("yes");
    func.newBlock("no");
    auto condition = func.newValue(Type.bool_());
    func.blocks[0].instrs ~= Instr(op: Op.const_, dst: condition,
            type: Type.bool_(), imm: Const.int_(1));
    func.blocks[0].instrs ~= Instr(op: Op.condbr, uses: [condition],
            target: 1, altTarget: 2);
    func.blocks[1].instrs ~= Instr(op: Op.ret);
    func.blocks[2].instrs ~= Instr(op: Op.ret);

    auto machineFunc = (new X86_64Target()).selectAndAlloc(func);
    bool hasConditionalBranch;
    foreach (index; 0 .. machineFunc.code.length - 1)
        if (machineFunc.code[index] == 0x0F &&
            machineFunc.code[index + 1] == 0x85)
            hasConditionalBranch = true;
    assert(hasConditionalBranch);
    assert(machineFunc.blocks.length == 3);
}

unittest
{
    auto func = Func();
    func.name = "printf_call";
    func.newBlock("entry");
    auto format = func.newValue(Type.ptr());
    auto value = func.newValue(Type.i32());
    auto result = func.newValue(Type.i32());
    func.blocks[0].instrs ~= Instr(op: Op.const_, dst: format,
            type: Type.ptr(), symbol: "format");
    func.blocks[0].instrs ~= Instr(op: Op.const_, dst: value,
            type: Type.i32(), imm: Const.int_(42));
    func.blocks[0].instrs ~= Instr(op: Op.call, dst: result,
            type: Type.i32(), symbol: "printf", uses: [format, value]);
    func.blocks[0].instrs ~= Instr(op: Op.ret, uses: [result]);

    auto machineFunc = (new X86_64Target()).selectAndAlloc(func);
    assert(machineFunc.relocs.length == 2);
    assert(machineFunc.relocs[0].symbol == "format");
    assert(machineFunc.relocs[1].symbol == "printf");
    assert(machineFunc.relocs[0].type == AMD64Rel32);
    assert(machineFunc.relocs[1].type == AMD64Rel32);
}

unittest
{
    import std.exception : assertThrown;

    auto func = Func();
    func.name = "unsupported";
    func.newBlock("entry");
    auto pointer = func.newValue(Type.ptr());
    auto value = func.newValue(Type.i32());
    func.blocks[0].instrs ~= Instr(op: Op.load, dst: value,
            type: Type.i32(), uses: [pointer]);
    func.blocks[0].instrs ~= Instr(op: Op.ret, uses: [value]);
    assertThrown!UnsupportedOperationException(
            (new X86_64Target()).selectAndAlloc(func));
}

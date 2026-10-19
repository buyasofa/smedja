module smedja.arch.x86;

import smedja.ir;
import smedja.arch;
import smedja.errors : CodeGenerationException, UnsupportedOperationException;
import std.algorithm.searching : canFind;

enum : RegId { EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI, ST0 }

private RegSet x86Regs = {
    regs: [
        Reg(EAX, RegClass.gpr, 4, "eax"),
        Reg(ECX, RegClass.gpr, 4, "ecx"),
        Reg(EDX, RegClass.gpr, 4, "edx"),
        Reg(EBX, RegClass.gpr, 4, "ebx"),
        Reg(ESP, RegClass.gpr, 4, "esp"),
        Reg(EBP, RegClass.gpr, 4, "ebp"),
        Reg(ESI, RegClass.gpr, 4, "esi"),
        Reg(EDI, RegClass.gpr, 4, "edi"),
        Reg(ST0, RegClass.fpr, 8, "st0"),
    ],
    stackPtr:    ESP,
    framePtr:    EBP,
    calleeSaved: [EBX, ESI, EDI, EBP],
    callerSaved: [EAX, ECX, EDX],
};

enum ushort X86Rel32 = 0x0014;
enum ushort X86Dir32 = 0x0006;

private MachFunc selectFunc(ref Func f) {
    return X86Codegen(f).compile();
}

private struct BranchFixup
{
    uint displacement;
    uint target;
}

private struct X86Codegen
{
    private Func* func;
    private MachFunc machineFunc;
    private int[] valueOffsets;
    private int[][] allocaOffsets;
    private uint[] blockOffsets;
    private BranchFixup[] branches;
    private int phiTemporary;
    private int conversionScratch;
    private int hiddenReturnPointer;
    private uint frameBytes;

    this(ref Func func)
    {
        this.func = &func;
        machineFunc.name = func.name;
        valueOffsets = new int[](func.values.length);
        allocaOffsets = new int[][](func.blocks.length);
        blockOffsets = new uint[](func.blocks.length);

        foreach (valueIndex, value; func.values)
            valueOffsets[valueIndex] = allocate(slotSize(value.type));

        if (func.retType.kind == TypeKind.struct_)
            hiddenReturnPointer = allocate(4);

        foreach (blockIndex, block; func.blocks)
        {
            allocaOffsets[blockIndex] = new int[](block.instrs.length);
            foreach (instructionIndex, instruction; block.instrs)
            {
                if (instruction.op == Op.alloca)
                    allocaOffsets[blockIndex][instructionIndex] =
                        allocate(alignedSize(typeWidth(instruction.type)));
            }
        }
        uint maxPhiBytes;
        foreach (block; func.blocks)
        {
            uint phiBytes;
            foreach (instruction; block.instrs)
            {
                if (instruction.op != Op.phi)
                    break;
                phiBytes += alignedSize(typeWidth(instruction.type));
            }
            if (phiBytes > maxPhiBytes)
                maxPhiBytes = phiBytes;
        }
        bool needsConversionScratch;
        foreach (block; func.blocks)
            foreach (instruction; block.instrs)
                if (instruction.op == Op.sitofp || instruction.op == Op.uitofp ||
                    instruction.op == Op.fptosi || instruction.op == Op.fptoui)
                    needsConversionScratch = true;
        if (needsConversionScratch)
            conversionScratch = allocate(24);
        if (maxPhiBytes)
            phiTemporary = allocate(maxPhiBytes);
        frameBytes = (frameBytes + 3) & ~3u;
        machineFunc.frameSize = frameBytes;
    }

    private uint slotSize(Type type)
    {
        return alignedSize(typeWidth(type));
    }

    private uint typeWidth(Type type)
    {
        if (type.kind == TypeKind.ptr || type.kind == TypeKind.func)
            return 4;
        if (type.kind == TypeKind.struct_)
        {
            uint size;
            foreach (field; type.fields)
                size += typeWidth(field);
            return size;
        }
        return type.width;
    }

    private uint alignedSize(uint size)
    {
        return ((size < 4 ? 4 : size) + 3) & ~3u;
    }

    private int allocate(uint size)
    {
        frameBytes += size;
        return -cast(int) frameBytes;
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

    private void emitDisp(int offset)
    {
        emit32(cast(uint) offset);
    }

    private int offset(Value value)
    {
        if (value.isNone || value.id >= valueOffsets.length)
            throw new CodeGenerationException("invalid value used by x86 code generation");
        return valueOffsets[value.id];
    }

    private void loadEax(Value value, uint part = 0)
    {
        emit(0x8B);
        emit(0x85);
        emitDisp(offset(value) + cast(int)(part * 4));
    }

    private void normalizeEax(Type type)
    {
        if (type.kind == TypeKind.i8)
        {
            emit(0x0F); emit(0xBE); emit(0xC0);
        }
        else if (type.kind == TypeKind.i16)
        {
            emit(0x0F); emit(0xBF); emit(0xC0);
        }
        else if (type.kind == TypeKind.bool_)
        {
            emit(0x0F); emit(0xB6); emit(0xC0);
        }
    }

    private void loadEcx(Value value, uint part = 0)
    {
        emit(0x8B);
        emit(0x8D);
        emitDisp(offset(value) + cast(int)(part * 4));
    }

    private void storeEax(Value value, uint part = 0)
    {
        emit(0x89);
        emit(0x85);
        emitDisp(offset(value) + cast(int)(part * 4));
    }

    private void storeEcx(Value value, uint part = 0)
    {
        emit(0x89);
        emit(0x8D);
        emitDisp(offset(value) + cast(int)(part * 4));
    }

    private void storeEdx(Value value, uint part = 0)
    {
        emit(0x89);
        emit(0x95);
        emitDisp(offset(value) + cast(int)(part * 4));
    }

    private void storeEaxAt(int destination)
    {
        emit(0x89); emit(0x85); emitDisp(destination);
    }

    private void storeEcxAt(int destination)
    {
        emit(0x89); emit(0x8D); emitDisp(destination);
    }

    private void storeEdxAt(int destination)
    {
        emit(0x89); emit(0x95); emitDisp(destination);
    }

    private void moveStackWord(int source, int destination)
    {
        emit(0x8B);
        emit(0x85);
        emitDisp(source);
        emit(0x89);
        emit(0x85);
        emitDisp(destination);
    }

    private void copyValue(Value source, Value destination, uint size)
    {
        foreach (part; 0 .. (size + 3) / 4)
        {
            loadEax(source, cast(uint) part);
            storeEax(destination, cast(uint) part);
        }
    }

    private void requireUses(Instr instruction, size_t count)
    {
        if (instruction.uses.length < count)
            throw new CodeGenerationException(
                    "instruction has too few operands for x86 code generation");
    }

    private uint valueSize(Value value)
    {
        if (value.isNone || value.id >= func.values.length)
            throw new CodeGenerationException("invalid value used by x86 code generation");
        return typeWidth(func.values[value.id].type);
    }

    private void emitPrologue()
    {
        emit(0x55);
        emit(0x89);
        emit(0xE5);
        if (frameBytes)
        {
            emit(0x81);
            emit(0xEC);
            emit32(frameBytes);
        }

        uint argumentOffset = func.retType.kind == TypeKind.struct_ ? 12 : 8;
        if (func.retType.kind == TypeKind.struct_)
        {
            emit(0x8B); emit(0x85); emitDisp(8);
            emit(0x89); emit(0x85); emitDisp(hiddenReturnPointer);
        }
        foreach (parameter; func.params)
        {
            auto size = valueSize(parameter.value);
            auto parameterType = func.values[parameter.value.id].type;
            if (size == 1 || size == 2)
            {
                emit(0x0F);
                if (size == 1)
                    emit(parameterType.kind == TypeKind.i8 ? 0xBE : 0xB6);
                else
                    emit(parameterType.kind == TypeKind.i16 ? 0xBF : 0xB7);
                emit(0x85);
                emitDisp(cast(int) argumentOffset);
                storeEax(parameter.value);
            }
            else
            {
                foreach (part; 0 .. (size + 3) / 4)
                {
                    emit(0x8B);
                    emit(0x85);
                    emitDisp(cast(int)(argumentOffset + part * 4));
                    storeEax(parameter.value, cast(uint) part);
                }
            }
            argumentOffset += alignedSize(size);
        }
    }

    private void emitEpilogue()
    {
        emit(0x89);
        emit(0xEC);
        emit(0x5D);
        emit(0xC3);
    }

    private void branchTo(uint target, ubyte opcode)
    {
        if (target >= blockOffsets.length)
            throw new CodeGenerationException("branch target is outside the function");
        if (opcode == 0xE9)
            emit(opcode);
        else
        {
            emit(0x0F);
            emit(opcode);
        }
        branches ~= BranchFixup(cast(uint) machineFunc.code.length, target);
        emit32(0);
    }

    private void emitConstant(Instr instruction)
    {
        auto destination = instruction.dst;
        if (instruction.symbol.length)
        {
            if (func.values[destination.id].type.kind != TypeKind.ptr)
                throw new CodeGenerationException("symbol constant requires a pointer result");
            emit(0xB8);
            auto relocationOffset = cast(uint) machineFunc.code.length;
            emit32(0);
            machineFunc.relocs ~= MachReloc(relocationOffset,
                    instruction.symbol, X86Dir32);
            storeEax(destination);
            return;
        }
        auto size = valueSize(destination);
        ulong bits;
        final switch (instruction.imm.kind)
        {
        case Const.Kind.i:
            bits = cast(ulong) instruction.imm.i;
            break;
        case Const.Kind.f:
            if (size == 4)
            {
                union FloatBits
                {
                    float floating;
                    uint integer;
                }
                FloatBits floatBits;
                floatBits.floating = cast(float) instruction.imm.f;
                bits = floatBits.integer;
            }
            else
            {
                union FloatBits
                {
                    double floating;
                    ulong integer;
                }
                FloatBits floatBits;
                floatBits.floating = instruction.imm.f;
                bits = floatBits.integer;
            }
            break;
        case Const.Kind.undef:
        case Const.Kind.null_:
            bits = 0;
            break;
        }
        auto destinationType = func.values[destination.id].type;
        if (destinationType.kind == TypeKind.bool_)
            bits &= 0xFF;
        else if (destinationType.kind == TypeKind.i8)
            bits = cast(ulong) cast(long) cast(byte) bits;
        else if (destinationType.kind == TypeKind.i16)
            bits = cast(ulong) cast(long) cast(short) bits;
        foreach (part; 0 .. (size + 3) / 4)
        {
            emit(0xB8);
            emit32(cast(uint)(bits >> (part * 32)));
            storeEax(destination, cast(uint) part);
        }
    }

    private void emitIntegerBinary(Instr instruction)
    {
        requireUses(instruction, 2);
        auto lhs = instruction.uses[0];
        auto rhs = instruction.uses[1];
        auto size = typeWidth(instruction.type);

        if (size == 8)
        {
            if (instruction.op == Op.mul || instruction.op == Op.sdiv ||
                instruction.op == Op.udiv || instruction.op == Op.srem ||
                instruction.op == Op.urem)
            {
                emitRuntime64Operation(instruction);
                return;
            }
            if (instruction.op == Op.shl || instruction.op == Op.ashr ||
                instruction.op == Op.lshr)
            {
                emitShift64(instruction);
                return;
            }
            if (instruction.op != Op.add && instruction.op != Op.sub &&
                instruction.op != Op.and_ && instruction.op != Op.or_ &&
                instruction.op != Op.xor_)
                throw new UnsupportedOperationException(
                        "unsupported 64-bit integer operation");
        }

        loadEax(lhs);
        loadEcx(rhs);
        final switch (instruction.op)
        {
        case Op.add: emit(0x01); emit(0xC8); break;
        case Op.sub: emit(0x29); emit(0xC8); break;
        case Op.mul: emit(0x0F); emit(0xAF); emit(0xC1); break;
        case Op.sdiv:
        case Op.srem:
            emit(0x99);
            emit(0xF7);
            emit(0xF9);
            if (instruction.op == Op.srem)
            {
                emit(0x89);
                emit(0xD0);
            }
            break;
        case Op.udiv:
        case Op.urem:
            emit(0x31); emit(0xD2);
            emit(0xF7);
            emit(0xF1);
            if (instruction.op == Op.urem)
            {
                emit(0x89);
                emit(0xD0);
            }
            break;
        case Op.and_: emit(0x21); emit(0xC8); break;
        case Op.or_: emit(0x09); emit(0xC8); break;
        case Op.xor_: emit(0x31); emit(0xC8); break;
        case Op.shl: emit(0xD3); emit(0xE0); break;
        case Op.ashr: emit(0xD3); emit(0xF8); break;
        case Op.lshr: emit(0xD3); emit(0xE8); break;
        case Op.const_, Op.fadd, Op.fsub, Op.fmul, Op.fdiv, Op.icmp, Op.fcmp,
             Op.sext, Op.zext, Op.trunc, Op.sitofp, Op.uitofp, Op.fptosi,
             Op.fptoui, Op.bitcast, Op.alloca, Op.load, Op.store, Op.gep,
             Op.br, Op.condbr, Op.ret, Op.unreachable, Op.call, Op.phi:
            throw new CodeGenerationException("invalid integer arithmetic operation");
        }
        if (size < 4)
            normalizeEax(instruction.type);
        storeEax(instruction.dst);
        if (size == 8)
        {
            loadEax(lhs, 1);
            loadEcx(rhs, 1);
            final switch (instruction.op)
            {
            case Op.add: emit(0x11); emit(0xC8); break;
            case Op.sub: emit(0x19); emit(0xC8); break;
            case Op.and_: emit(0x21); emit(0xC8); break;
            case Op.or_: emit(0x09); emit(0xC8); break;
            case Op.xor_: emit(0x31); emit(0xC8); break;
            case Op.const_, Op.mul, Op.sdiv, Op.udiv, Op.srem, Op.urem,
                 Op.fadd, Op.fsub, Op.fmul, Op.fdiv, Op.shl, Op.ashr,
                 Op.lshr, Op.icmp, Op.fcmp, Op.sext, Op.zext, Op.trunc,
                 Op.sitofp, Op.uitofp, Op.fptosi, Op.fptoui, Op.bitcast,
                 Op.alloca, Op.load, Op.store, Op.gep, Op.br, Op.condbr,
                 Op.ret, Op.unreachable, Op.call, Op.phi:
                throw new CodeGenerationException("invalid 64-bit integer operation");
            }
            storeEax(instruction.dst, 1);
        }
    }

    private void emitRuntime64Operation(Instr instruction)
    {
        string helper;
        final switch (instruction.op)
        {
        case Op.mul: helper = "__allmul"; break;
        case Op.sdiv: helper = "__alldiv"; break;
        case Op.udiv: helper = "__aulldiv"; break;
        case Op.srem: helper = "__allrem"; break;
        case Op.urem: helper = "__aullrem"; break;
        case Op.const_, Op.add, Op.sub, Op.fadd, Op.fsub, Op.fmul, Op.fdiv,
             Op.and_, Op.or_, Op.xor_, Op.shl, Op.ashr, Op.lshr, Op.icmp,
             Op.fcmp, Op.sext, Op.zext, Op.trunc, Op.sitofp, Op.uitofp,
             Op.fptosi, Op.fptoui, Op.bitcast, Op.alloca, Op.load, Op.store,
             Op.gep, Op.br, Op.condbr, Op.ret, Op.unreachable, Op.call, Op.phi:
            throw new CodeGenerationException("invalid 64-bit runtime operation");
        }

        foreach (value; [instruction.uses[1], instruction.uses[0]])
        {
            loadEax(value, 1);
            emit(0x50);
            loadEax(value);
            emit(0x50);
        }
        emit(0xE8);
        auto displacement = cast(uint) machineFunc.code.length;
        machineFunc.relocs ~= MachReloc(displacement, helper, X86Rel32);
        emit32(0xFFFFFFFC);
        emit(0x81); emit(0xC4); emit32(16);
        storeEax(instruction.dst);
        storeEdx(instruction.dst, 1);
    }

    private void patchLocal(uint displacementOffset, uint targetOffset)
    {
        auto displacement = cast(uint)(targetOffset -
                (displacementOffset + 4));
        foreach (shift; 0 .. 4)
            machineFunc.code[displacementOffset + shift] =
                cast(ubyte)(displacement >> (shift * 8));
    }

    private void emitShift64(Instr instruction)
    {
        auto lhs = instruction.uses[0];
        auto rhs = instruction.uses[1];
        loadEax(lhs);
        loadEcx(lhs, 1);
        emit(0x89); emit(0xCA);
        loadEcx(rhs);
        emit(0x83); emit(0xE1); emit(0x3F);
        emit(0xF7); emit(0xC1); emit32(0x20);
        emit(0x0F); emit(0x85);
        auto largeShiftDisplacement = cast(uint) machineFunc.code.length;
        emit32(0);

        if (instruction.op == Op.shl)
        {
            emit(0x0F); emit(0xA5); emit(0xC2);
            emit(0xD3); emit(0xE0);
        }
        else
        {
            emit(0x0F); emit(0xAD); emit(0xD0);
            emit(0xD3);
            emit(instruction.op == Op.ashr ? 0xFA : 0xEA);
        }
        emit(0xE9);
        auto finishDisplacement = cast(uint) machineFunc.code.length;
        emit32(0);
        patchLocal(largeShiftDisplacement,
                cast(uint) machineFunc.code.length);

        if (instruction.op == Op.shl)
        {
            emit(0x89); emit(0xC2);
            emit(0x31); emit(0xC0);
            emit(0x83); emit(0xE9); emit(0x20);
            emit(0xD3); emit(0xE2);
        }
        else
        {
            emit(0x89); emit(0xD0);
            if (instruction.op == Op.ashr)
            {
                emit(0xC1); emit(0xFA); emit(0x1F);
            }
            else
            {
                emit(0x31); emit(0xD2);
            }
            emit(0x83); emit(0xE9); emit(0x20);
            emit(0xD3);
            emit(instruction.op == Op.ashr ? 0xF8 : 0xE8);
        }
        patchLocal(finishDisplacement,
                cast(uint) machineFunc.code.length);
        storeEax(instruction.dst);
        storeEdx(instruction.dst, 1);
    }

    private ubyte setOpcode(Pred pred)
    {
        final switch (pred)
        {
        case Pred.eq: return 0x94;
        case Pred.ne: return 0x95;
        case Pred.slt: case Pred.lt: return 0x9C;
        case Pred.sle: case Pred.le: return 0x9E;
        case Pred.sgt: case Pred.gt: return 0x9F;
        case Pred.sge: case Pred.ge: return 0x9D;
        case Pred.ult: return 0x92;
        case Pred.ule: return 0x96;
        case Pred.ugt: return 0x97;
        case Pred.uge: return 0x93;
        }
    }

    private void emitComparison(Instr instruction)
    {
        requireUses(instruction, 2);
        if (instruction.op == Op.icmp)
        {
            if (valueSize(instruction.uses[0]) == 8)
            {
                emitComparison64(instruction);
                return;
            }
            loadEax(instruction.uses[0]);
            loadEcx(instruction.uses[1]);
            emit(0x39);
            emit(0xC8);
        }
        else
        {
            auto operandType = func.values[instruction.uses[0].id].type;
            emit(operandType.width == 8 ? 0xDD : 0xD9);
            emit(0x85);
            emitDisp(offset(instruction.uses[0]));
            emit(operandType.width == 8 ? 0xDC : 0xD8);
            emit(0x9D);
            emitDisp(offset(instruction.uses[1]));
            emit(0xDF);
            emit(0xE0);
            emit(0x9E);
            emitFloatSetResult(instruction.pred, instruction.dst);
            return;
        }
        emit(0x0F);
        emit(setOpcode(instruction.pred));
        emit(0xC0);
        emit(0x0F);
        emit(0xB6);
        emit(0xC0);
        storeEax(instruction.dst);
    }

    private void emitFloatSetResult(Pred pred, Value destination)
    {
        ubyte condition;
        bool unorderedIsTrue;
        bool unorderedIsFalse;
        final switch (pred)
        {
        case Pred.eq: condition = 0x94; unorderedIsFalse = true; break;
        case Pred.ne: condition = 0x95; unorderedIsTrue = true; break;
        case Pred.slt: case Pred.lt: case Pred.ult:
            condition = 0x92; unorderedIsFalse = true; break;
        case Pred.sle: case Pred.le: case Pred.ule:
            condition = 0x96; unorderedIsFalse = true; break;
        case Pred.sgt: case Pred.gt: case Pred.ugt: condition = 0x97; break;
        case Pred.sge: case Pred.ge: case Pred.uge: condition = 0x93; break;
        }
        emit(0x0F); emit(condition); emit(0xC0);
        if (unorderedIsTrue || unorderedIsFalse)
        {
            emit(0x0F); emit(unorderedIsTrue ? 0x9A : 0x9B); emit(0xC1);
            emit(unorderedIsTrue ? 0x08 : 0x20);
            emit(0xC8);
        }
        emit(0x0F); emit(0xB6); emit(0xC0);
        storeEax(destination);
    }

    private void emitSetResult(ubyte opcode, Value destination)
    {
        emit(0x0F); emit(opcode); emit(0xC0);
        emit(0x0F); emit(0xB6); emit(0xC0);
        storeEax(destination);
    }

    private void emitComparison64(Instr instruction)
    {
        auto lhs = instruction.uses[0];
        auto rhs = instruction.uses[1];
        loadEax(lhs, 1);
        loadEcx(rhs, 1);
        emit(0x39); emit(0xC8);
        emit(0x0F); emit(0x84);
        auto equalDisplacement = cast(uint) machineFunc.code.length;
        emit32(0);
        emitSetResult(setOpcode(instruction.pred), instruction.dst);
        emit(0xE9);
        auto finishDisplacement = cast(uint) machineFunc.code.length;
        emit32(0);
        patchLocal(equalDisplacement,
                cast(uint) machineFunc.code.length);

        loadEax(lhs);
        loadEcx(rhs);
        emit(0x39); emit(0xC8);
        auto lowPred = instruction.pred;
        final switch (instruction.pred)
        {
        case Pred.slt: lowPred = Pred.ult; break;
        case Pred.sle: lowPred = Pred.ule; break;
        case Pred.sgt: lowPred = Pred.ugt; break;
        case Pred.sge: lowPred = Pred.uge; break;
        case Pred.lt: lowPred = Pred.ult; break;
        case Pred.le: lowPred = Pred.ule; break;
        case Pred.gt: lowPred = Pred.ugt; break;
        case Pred.ge: lowPred = Pred.uge; break;
        case Pred.eq, Pred.ne, Pred.ult, Pred.ule, Pred.ugt, Pred.uge:
            break;
        }
        emitSetResult(setOpcode(lowPred), instruction.dst);
        patchLocal(finishDisplacement,
                cast(uint) machineFunc.code.length);
    }

    private void emitFloatBinary(Instr instruction)
    {
        requireUses(instruction, 2);
        auto size = typeWidth(instruction.type);
        bool isDouble = size == 8;
        emit(isDouble ? 0xDD : 0xD9);
        emit(0x85);
        emitDisp(offset(instruction.uses[0]));
        emit(isDouble ? 0xDC : 0xD8);
        auto rhs = offset(instruction.uses[1]);
        ubyte group;
        final switch (instruction.op)
        {
        case Op.fadd: group = 0; break;
        case Op.fmul: group = 1; break;
        case Op.fsub: group = 4; break;
        case Op.fdiv: group = 6; break;
        case Op.const_, Op.add, Op.sub, Op.mul, Op.sdiv, Op.udiv, Op.srem,
             Op.urem, Op.and_, Op.or_, Op.xor_, Op.shl, Op.ashr, Op.lshr,
             Op.icmp, Op.fcmp, Op.sext, Op.zext, Op.trunc, Op.sitofp,
             Op.uitofp, Op.fptosi, Op.fptoui, Op.bitcast, Op.alloca, Op.load,
             Op.store, Op.gep, Op.br, Op.condbr, Op.ret, Op.unreachable,
             Op.call, Op.phi:
            throw new CodeGenerationException(
                    "invalid floating-point arithmetic operation");
        }
        emit(cast(ubyte)(0x85 | (group << 3)));
        emitDisp(rhs);
        emit(isDouble ? 0xDD : 0xD9);
        emit(0x9D);
        emitDisp(offset(instruction.dst));
    }

    private void emitUnsignedToFloat(Instr instruction, uint sourceWidth,
            uint targetWidth)
    {
        auto scratch = conversionScratch;
        auto bitScratch = scratch + 8;
        if (sourceWidth == 8)
        {
            loadEax(instruction.uses[0]);
            emit(0x89); emit(0xC1);
            emit(0x83); emit(0xE1); emit(0x01);
            storeEcxAt(bitScratch);
            loadEcx(instruction.uses[0], 1);
            emit(0x0F); emit(0xAC); emit(0xC8); emit(0x01);
            emit(0xD1); emit(0xE9);
            emit(0x89); emit(0xCA);
            storeEaxAt(scratch);
            storeEdxAt(scratch + 4);
            emit(0xDF); emit(0x85); emitDisp(scratch);
        }
        else if (sourceWidth <= 4)
        {
            if (sourceWidth == 1 || sourceWidth == 2)
            {
                emit(0x0F);
                emit(sourceWidth == 1 ? 0xB6 : 0xB7);
                emit(0x85);
                emitDisp(offset(instruction.uses[0]));
            }
            else
                loadEax(instruction.uses[0]);
            emit(0x89); emit(0xC1);
            emit(0x83); emit(0xE1); emit(0x01);
            storeEcxAt(bitScratch);
            emit(0xD1); emit(0xE8);
            storeEaxAt(scratch);
            emit(0xDB); emit(0x85); emitDisp(scratch);
        }
        else
        {
            throw new UnsupportedOperationException(
                    "unsigned x86 conversion requires a 32-bit or 64-bit integer");
        }
        emit(0xD8); emit(0xC0);
        emit(0xDB); emit(0x85); emitDisp(bitScratch);
        emit(0xDE); emit(0xC1);
        emit(targetWidth == 8 ? 0xDD : 0xD9);
        emit(0x9D); emitDisp(offset(instruction.dst));
    }

    private void emitFloatToInteger(Instr instruction, uint sourceWidth,
            uint targetWidth)
    {
        auto scratch = conversionScratch;
        auto constant = scratch + 12;
        auto originalControl = scratch + 20;
        auto modifiedControl = scratch + 22;

        emit(0xB8); emit32(0x80000000);
        storeEaxAt(constant);
        if (targetWidth <= 4)
        {
            emit(sourceWidth == 8 ? 0xDD : 0xD9);
            emit(0x85); emitDisp(offset(instruction.uses[0]));
            emit(0xDB); emit(0x85); emitDisp(constant);
            emit(0xD9); emit(0xE0);
            emit(0xDE); emit(0xE9);
            emit(sourceWidth == 8 ? 0xDD : 0xD9);
            emit(0x9D); emitDisp(scratch);
            emit(sourceWidth == 8 ? 0xF2 : 0xF3);
            emit(0x0F); emit(0x2C); emit(0x85);
            emitDisp(scratch);
            emit(0x81); emit(0xC0); emit32(0x80000000);
            if (targetWidth < 4)
                normalizeEax(instruction.type);
            storeEax(instruction.dst);
            return;
        }
        if (targetWidth != 8)
            throw new UnsupportedOperationException(
                    "unsigned x86 conversion requires a 32-bit or 64-bit result");

        storeEaxAt(constant);
        emit(0x31); emit(0xC0);
        storeEaxAt(constant);
        emit(0xB8); emit32(0x80000000);
        storeEaxAt(constant + 4);
        emit(0xD9); emit(0xBD); emitDisp(originalControl);
        emit(0x8B); emit(0x85); emitDisp(originalControl);
        emit(0x89); emit(0x85); emitDisp(modifiedControl);
        emit(0x80); emit(0x8D); emitDisp(modifiedControl + 1); emit(0x0C);
        emit(0xD9); emit(0xAD); emitDisp(modifiedControl);
        emit(sourceWidth == 8 ? 0xDD : 0xD9);
        emit(0x85); emitDisp(offset(instruction.uses[0]));
        emit(0xDF); emit(0x85); emitDisp(constant);
        emit(0xD9); emit(0xE0);
        emit(0xDE); emit(0xE9);
        emit(0xDF); emit(0xBD); emitDisp(scratch);
        emit(0xD9); emit(0xAD); emitDisp(originalControl);
        emit(0x81); emit(0x85); emitDisp(scratch + 4); emit32(0x80000000);
        moveStackWord(scratch, offset(instruction.dst));
        moveStackWord(scratch + 4, offset(instruction.dst) + 4);
    }

    private void emitCast(Instr instruction)
    {
        requireUses(instruction, 1);
        auto source = instruction.uses[0];
        auto sourceType = func.values[source.id].type;
        auto targetType = instruction.type;
        auto sourceWidth = typeWidth(sourceType);
        auto targetWidth = typeWidth(targetType);

        if (instruction.op == Op.bitcast)
        {
            if (sourceWidth != targetWidth)
                throw new CodeGenerationException(
                        "bitcast requires source and destination types of equal size");
            copyValue(source, instruction.dst, targetWidth);
            return;
        }
        if (instruction.op == Op.trunc)
        {
            loadEax(source);
            if (targetWidth == 1)
            {
                emit(0x0F);
                emit(targetType.kind == TypeKind.i8 ? 0xBE : 0xB6);
                emit(0xC0);
            }
            else if (targetWidth == 2)
            {
                emit(0x0F);
                emit(targetType.kind == TypeKind.i16 ? 0xBF : 0xB7);
                emit(0xC0);
            }
            storeEax(instruction.dst);
            return;
        }
        if ((instruction.op == Op.sext || instruction.op == Op.zext) &&
            sourceWidth >= targetWidth)
        {
            copyValue(source, instruction.dst, targetWidth);
            return;
        }
        if (instruction.op == Op.sitofp || instruction.op == Op.uitofp)
        {
            if (instruction.op == Op.uitofp)
            {
                emitUnsignedToFloat(instruction, sourceWidth, targetWidth);
                return;
            }
            emit(sourceWidth == 8 ? 0xDF : 0xDB);
            emit(0x85); emitDisp(offset(source));
            emit(targetWidth == 8 ? 0xDD : 0xD9);
            emit(0x9D); emitDisp(offset(instruction.dst));
            return;
        }
        if (instruction.op == Op.fptosi || instruction.op == Op.fptoui)
        {
            if (instruction.op == Op.fptoui)
            {
                emitFloatToInteger(instruction, sourceWidth, targetWidth);
                return;
            }
            if (targetWidth == 8)
            {
                auto scratch = conversionScratch;
                auto originalControl = scratch + 20;
                auto modifiedControl = scratch + 22;
                emit(0xD9); emit(0xBD); emitDisp(originalControl);
                emit(0x8B); emit(0x85); emitDisp(originalControl);
                emit(0x89); emit(0x85); emitDisp(modifiedControl);
                emit(0x80); emit(0x8D); emitDisp(modifiedControl + 1); emit(0x0C);
                emit(0xD9); emit(0xAD); emitDisp(modifiedControl);
                emit(sourceWidth == 8 ? 0xDD : 0xD9);
                emit(0x85); emitDisp(offset(source));
                emit(0xDF); emit(0xBD); emitDisp(offset(instruction.dst));
                emit(0xD9); emit(0xAD); emitDisp(originalControl);
                return;
            }
            if (targetWidth > 4)
                throw new UnsupportedOperationException(
                        "x86 floating-point conversion requires a 32-bit or 64-bit integer result");
            emit(sourceWidth == 8 ? 0xF2 : 0xF3);
            emit(0x0F); emit(0x2C); emit(0x85);
            emitDisp(offset(source));
            if (targetWidth < 4)
                normalizeEax(targetType);
            storeEax(instruction.dst);
            return;
        }

        loadEax(source);
        if (sourceWidth == 1)
        {
            emit(0x0F);
            emit(instruction.op == Op.sext ? 0xBE : 0xB6);
            emit(0x85);
            emitDisp(offset(source));
        }
        else if (sourceWidth == 2)
        {
            emit(0x0F);
            emit(instruction.op == Op.sext ? 0xBF : 0xB7);
            emit(0x85);
            emitDisp(offset(source));
        }
        if (targetWidth == 8 && sourceWidth < 8)
        {
            storeEax(instruction.dst);
            if (instruction.op == Op.sext && sourceType.isInt)
            {
                emit(0x99);
                storeEdx(instruction.dst, 1);
            }
            else
            {
                emit(0x31); emit(0xD2);
                storeEdx(instruction.dst, 1);
            }
        }
        else
        {
            storeEax(instruction.dst);
            if (typeWidth(func.values[instruction.dst.id].type) == 8)
                storeEdx(instruction.dst, 1);
        }
    }

    private void emitLoad(Instr instruction)
    {
        requireUses(instruction, 1);
        loadEax(instruction.uses[0]);
        auto size = typeWidth(instruction.type);
        uint offsetInValue;
        while (size - offsetInValue >= 4)
        {
            emit(0x8B); emit(0x88); emitDisp(cast(int) offsetInValue);
            storeEcxAt(offset(instruction.dst) + cast(int) offsetInValue);
            offsetInValue += 4;
        }
        auto remaining = size - offsetInValue;
        if (remaining == 3)
        {
            emit(0x0F); emit(0xB7); emit(0x88);
            emitDisp(cast(int) offsetInValue);
            emit(0x0F); emit(0xB6); emit(0x90);
            emitDisp(cast(int)(offsetInValue + 2));
            emit(0xC1); emit(0xE2); emit(0x10);
            emit(0x09); emit(0xD1);
            storeEcxAt(offset(instruction.dst) + cast(int) offsetInValue);
        }
        else if (remaining == 2)
        {
            emit(0x0F);
            emit(instruction.type.kind == TypeKind.i16 ? 0xBF : 0xB7);
            emit(0x88);
            emitDisp(cast(int) offsetInValue);
            storeEcxAt(offset(instruction.dst) + cast(int) offsetInValue);
        }
        else if (remaining == 1)
        {
            emit(0x0F);
            emit(instruction.type.kind == TypeKind.i8 ? 0xBE : 0xB6);
            emit(0x88);
            emitDisp(cast(int) offsetInValue);
            storeEcxAt(offset(instruction.dst) + cast(int) offsetInValue);
        }
    }

    private void emitStore(Instr instruction)
    {
        requireUses(instruction, 2);
        loadEax(instruction.uses[0]);
        auto size = valueSize(instruction.uses[1]);
        uint offsetInValue;
        while (size - offsetInValue >= 4)
        {
            loadEcx(instruction.uses[1], offsetInValue / 4);
            emit(0x89); emit(0x88);
            emitDisp(cast(int) offsetInValue);
            offsetInValue += 4;
        }
        auto remaining = size - offsetInValue;
        if (remaining == 3)
        {
            loadEcx(instruction.uses[1], offsetInValue / 4);
            emit(0x66); emit(0x89); emit(0x88);
            emitDisp(cast(int) offsetInValue);
            emit(0xC1); emit(0xE9); emit(0x10);
            emit(0x88); emit(0x88);
            emitDisp(cast(int)(offsetInValue + 2));
        }
        else if (remaining == 2)
        {
            loadEcx(instruction.uses[1], offsetInValue / 4);
            emit(0x66); emit(0x89); emit(0x88);
            emitDisp(cast(int) offsetInValue);
        }
        else if (remaining == 1)
        {
            loadEcx(instruction.uses[1], offsetInValue / 4);
            emit(0x88); emit(0x88);
            emitDisp(cast(int) offsetInValue);
        }
    }

    private void emitCall(Instr instruction)
    {
        if (!instruction.symbol.length)
            requireUses(instruction, 1);
        uint stackBytes;
        auto arguments = instruction.symbol.length
            ? instruction.uses[] : instruction.uses[1 .. $];
        foreach_reverse (argument; arguments)
        {
            auto size = valueSize(argument);
            auto alignedArgumentSize = alignedSize(size);
            foreach_reverse (part; 0 .. alignedArgumentSize / 4)
            {
                loadEax(argument, cast(uint) part);
                emit(0x50);
            }
            stackBytes += alignedArgumentSize;
        }
        if (!instruction.dst.isNone &&
            func.values[instruction.dst.id].type.kind == TypeKind.struct_)
        {
            emit(0x8D); emit(0x85); emitDisp(offset(instruction.dst));
            emit(0x50);
            stackBytes += 4;
        }
        if (instruction.symbol.length)
        {
            emit(0xE8);
            auto relocationOffset = cast(uint) machineFunc.code.length;
            emit32(0);
            machineFunc.relocs ~= MachReloc(relocationOffset,
                    instruction.symbol, X86Rel32);
        }
        else
        {
            loadEax(instruction.uses[0]);
            emit(0xFF); emit(0xD0);
        }
        if (stackBytes)
        {
            emit(0x81); emit(0xC4); emit32(stackBytes);
        }
        if (!instruction.dst.isNone)
        {
            if (func.values[instruction.dst.id].type.isFloat)
            {
                auto returnType = func.values[instruction.dst.id].type;
                emit(typeWidth(returnType) == 8 ? 0xDD : 0xD9);
                emit(0x9D);
                emitDisp(offset(instruction.dst));
            }
            else if (func.values[instruction.dst.id].type.kind != TypeKind.struct_)
            {
                storeEax(instruction.dst);
                if (typeWidth(func.values[instruction.dst.id].type) == 8)
                    storeEdx(instruction.dst, 1);
            }
        }
    }

    private void emitInstruction(uint blockIndex, uint instructionIndex, Instr instruction)
    {
        final switch (instruction.op)
        {
        case Op.const_:
            emitConstant(instruction);
            break;
        case Op.add, Op.sub, Op.mul, Op.sdiv, Op.udiv, Op.srem, Op.urem,
             Op.and_, Op.or_, Op.xor_, Op.shl, Op.ashr, Op.lshr:
            emitIntegerBinary(instruction);
            break;
        case Op.fadd, Op.fsub, Op.fmul, Op.fdiv:
            emitFloatBinary(instruction);
            break;
        case Op.icmp:
        case Op.fcmp:
            emitComparison(instruction);
            break;
        case Op.sext, Op.zext, Op.trunc, Op.sitofp, Op.uitofp,
             Op.fptosi, Op.fptoui, Op.bitcast:
            emitCast(instruction);
            break;
        case Op.alloca:
            auto localOffset = allocaOffsets[blockIndex][instructionIndex];
            emit(0x8D); emit(0x85); emitDisp(localOffset);
            storeEax(instruction.dst);
            break;
        case Op.load:
            emitLoad(instruction);
            break;
        case Op.store:
            emitStore(instruction);
            break;
        case Op.gep:
            requireUses(instruction, 1);
            loadEax(instruction.uses[0]);
            if (instruction.uses.length > 1)
            {
                loadEcx(instruction.uses[1]);
                if (instruction.type.width > 1)
                {
                    emit(0x6B); emit(0xC9);
                    emit(cast(ubyte) instruction.type.width);
                }
                emit(0x01); emit(0xC8);
            }
            if (instruction.imm.i)
            {
                emit(0x05);
                emit32(cast(uint) instruction.imm.i);
            }
            storeEax(instruction.dst);
            break;
        case Op.br:
            emitPhiCopies(blockIndex, instruction.target);
            branchTo(instruction.target, 0xE9);
            break;
        case Op.condbr:
            requireUses(instruction, 1);
            loadEax(instruction.uses[0]);
            emit(0x85); emit(0xC0);
            emit(0x0F); emit(0x84);
            auto truePathDisplacement = cast(uint) machineFunc.code.length;
            emit32(0);
            emitPhiCopies(blockIndex, instruction.target);
            branchTo(instruction.target, 0xE9);
            auto falsePath = cast(uint) machineFunc.code.length;
            patchLocal(truePathDisplacement, falsePath);
            emitPhiCopies(blockIndex, instruction.altTarget);
            branchTo(instruction.altTarget, 0xE9);
            break;
        case Op.ret:
            if (func.retType.kind == TypeKind.struct_ && !instruction.uses.length)
                throw new CodeGenerationException("struct return requires a result value");
            if (instruction.uses.length)
            {
                auto returnValue = instruction.uses[0];
                auto returnType = func.values[returnValue.id].type;
                if (func.retType.kind == TypeKind.struct_ &&
                    typeWidth(returnType) != typeWidth(func.retType))
                    throw new CodeGenerationException(
                            "struct return value has the wrong size");
                if (returnType.isFloat)
                {
                    emit(returnType.width == 8 ? 0xDD : 0xD9);
                    emit(0x85); emitDisp(offset(returnValue));
                }
                else if (returnType.kind == TypeKind.struct_)
                {
                    if (!hiddenReturnPointer)
                        throw new CodeGenerationException(
                                "struct return requires a hidden result pointer");
                    auto size = valueSize(returnValue);
                    emit(0x8B); emit(0x85); emitDisp(hiddenReturnPointer);
                    uint copied;
                    while (size - copied >= 4)
                    {
                        loadEcx(returnValue, copied / 4);
                        emit(0x89); emit(0x88); emitDisp(cast(int) copied);
                        copied += 4;
                    }
                    auto remaining = size - copied;
                    if (remaining == 2 || remaining == 3)
                    {
                        loadEcx(returnValue, copied / 4);
                        emit(0x66); emit(0x89); emit(0x88);
                        emitDisp(cast(int) copied);
                    }
                    if (remaining == 1 || remaining == 3)
                    {
                        loadEcx(returnValue, copied / 4);
                        if (remaining == 3)
                        {
                            emit(0xC1); emit(0xE9); emit(0x10);
                            emit(0x88); emit(0x88);
                            emitDisp(cast(int)(copied + 2));
                        }
                        else
                        {
                            emit(0x88); emit(0x88);
                            emitDisp(cast(int) copied);
                        }
                    }
                    emit(0x8B); emit(0x85); emitDisp(hiddenReturnPointer);
                }
                else
                {
                    loadEax(returnValue);
                    if (typeWidth(returnType) == 8)
                    {
                        loadEcx(returnValue, 1);
                        emit(0x89); emit(0xCA);
                    }
                }
            }
            emitEpilogue();
            break;
        case Op.unreachable:
            emit(0x0F); emit(0x0B);
            break;
        case Op.call:
            emitCall(instruction);
            break;
        case Op.phi:
            break;
        }
    }

    private void emitPhiCopies(uint from, uint to)
    {
        if (to >= func.blocks.length)
            throw new CodeGenerationException("branch target is outside the function");

        Value[] sources;
        Value[] destinations;
        foreach (instruction; func.blocks[to].instrs)
        {
            if (instruction.op != Op.phi)
                break;
            bool found;
            foreach (edge; instruction.phiEdges)
            {
                if (edge.blockId == from)
                {
                    sources ~= edge.val;
                    destinations ~= instruction.dst;
                    found = true;
                    break;
                }
            }
            if (!found)
                throw new CodeGenerationException(
                        "phi node has no incoming value for predecessor");
        }
        if (!sources.length)
            return;

        auto temporary = phiTemporary;
        foreach (index, source; sources)
        {
            auto size = valueSize(source);
            if (size != valueSize(destinations[index]))
                throw new CodeGenerationException(
                        "phi incoming value does not match its result size");
            foreach (part; 0 .. (size + 3) / 4)
            {
                loadEax(source, cast(uint) part);
                storeEaxAt(temporary + cast(int)(part * 4));
            }
            temporary += cast(int) alignedSize(size);
        }
        temporary = phiTemporary;
        foreach (index, destination; destinations)
        {
            auto size = valueSize(destination);
            foreach (part; 0 .. (size + 3) / 4)
            {
                emit(0x8B); emit(0x85);
                emitDisp(temporary + cast(int)(part * 4));
                storeEax(destination, cast(uint) part);
            }
            temporary += cast(int) alignedSize(size);
        }
    }

    private void patchBranches()
    {
        foreach (branch; branches)
        {
            auto displacement = cast(int) blockOffsets[branch.target] -
                cast(int)(branch.displacement + 4);
            auto bits = cast(uint) displacement;
            foreach (shift; 0 .. 4)
                machineFunc.code[branch.displacement + shift] =
                    cast(ubyte)(bits >> (shift * 8));
        }
    }

    MachFunc compile()
    {
        if (!func.blocks.length)
            throw new CodeGenerationException(
                    "cannot generate x86 code for a function without blocks");

        emitPrologue();
        foreach (blockIndex, block; func.blocks)
        {
            if (block.id != blockIndex)
                throw new CodeGenerationException(
                        "basic block ids must match their function indices");
            blockOffsets[blockIndex] = cast(uint) machineFunc.code.length;
            machineFunc.blocks ~= MachBlock(block.name);
            foreach (instructionIndex, instruction; block.instrs)
                emitInstruction(cast(uint) blockIndex,
                        cast(uint) instructionIndex, instruction);
        }
        patchBranches();
        return machineFunc;
    }
}

final class CdeclABI : ABI {
    CallingConv conv()        { return CallingConv.cdecl; }
    uint        shadowSpace() { return 0; }

    private uint parameterSize(Type type)
    {
        if (type.kind == TypeKind.ptr || type.kind == TypeKind.func)
            return 4;
        if (type.kind == TypeKind.struct_)
        {
            uint size;
            foreach (field; type.fields)
                size += parameterSize(field);
            return size;
        }
        return type.width;
    }

    Allocation[] classify(Type[] params) {
        Allocation[] r;
        uint off = 4;
        foreach (t; params) {
            auto size = parameterSize(t);
            r   ~= Allocation(Allocation.Kind.stack, 0, off, t, 0);
            off += (size + 3) & ~3u;
        }
        return r;
    }

    Allocation returnSlot(Type ret) {
        if (ret.isFloat) return Allocation(Allocation.Kind.reg, ST0, 0, ret, 0);
        if (ret.kind == TypeKind.i64)
            return Allocation(Allocation.Kind.split, EAX, 0, ret, EDX);
        return Allocation(Allocation.Kind.reg, EAX, 0, ret, 0);
    }
}

final class X86Target : Target {
    string name()        { return "x86-windows"; }
    uint   pointerSize() { return 4; }
    uint   stackAlign()  { return 16; }
    RegSet registers()   { return x86Regs; }

    ABI abi(CallingConv cc) {
        if (cc != CallingConv.cdecl)
            throw new UnsupportedOperationException(
                    "x86-windows target only supports the cdecl calling convention");
        return new CdeclABI();
    }

    MachFunc selectAndAlloc(ref Func f) {
        return selectFunc(f);
    }
}

unittest
{
    auto target = new X86Target();
    assert(target.name == "x86-windows");
    assert(target.pointerSize == 4);
    assert(target.stackAlign == 16);

    auto registers = target.registers;
    assert(registers.stackPtr == ESP);
    assert(registers.framePtr == EBP);
    assert(registers.regs.length == 9);

    auto abi = target.abi(CallingConv.cdecl);
    assert(abi.conv == CallingConv.cdecl);
    assert(abi.shadowSpace == 0);
    auto allocations = abi.classify([Type.i8(), Type.i64(), Type.f32(), Type.ptr()]);
    assert(allocations.length == 4);
    assert(allocations[0].kind == Allocation.Kind.stack);
    assert(allocations[0].offset == 4);
    assert(allocations[1].offset == 8);
    assert(allocations[2].offset == 16);
    assert(allocations[0].type.kind == TypeKind.i8);
    assert(allocations[1].type.kind == TypeKind.i64);
    assert(allocations[2].type.kind == TypeKind.f32);
    assert(allocations[3].offset == 20);

    auto integerReturn = abi.returnSlot(Type.i32());
    assert(integerReturn.kind == Allocation.Kind.reg);
    assert(integerReturn.reg == EAX);
    auto floatReturn = abi.returnSlot(Type.f64());
    assert(floatReturn.kind == Allocation.Kind.reg);
    assert(floatReturn.reg == ST0);
    auto wideReturn = abi.returnSlot(Type.i64());
    assert(wideReturn.kind == Allocation.Kind.split);
    assert(wideReturn.reg == EAX);
    assert(wideReturn.secondReg == EDX);
}

unittest
{
    auto func = Func();
    func.name = "arithmetic";
    func.newBlock("entry");
    auto left = func.newValue(Type.i32());
    auto right = func.newValue(Type.i32());
    auto result = func.newValue(Type.i32());
    func.blocks[0].instrs ~= Instr(op: Op.add, dst: result, type: Type.i32(),
            uses: [left, right]);
    func.blocks[0].instrs ~= Instr(op: Op.ret, uses: [result]);

    auto target = new X86Target();
    auto machineFunc = target.selectAndAlloc(func);
    assert(machineFunc.name == "arithmetic");
    assert(machineFunc.blocks.length == 1);
    assert(machineFunc.blocks[0].label == "entry");
    assert(machineFunc.frameSize == 12);
    assert(machineFunc.code.length > 20);
    assert(machineFunc.code.canFind(0x01));
    assert(machineFunc.code[$ - 1] == 0xC3);
}

unittest
{
    auto func = Func();
    func.name = "direct_call";
    func.newBlock("entry");
    auto format = func.newValue(Type.ptr());
    func.blocks[0].instrs ~= Instr(op: Op.const_, dst: format,
            type: Type.ptr(), symbol: "format_string");
    func.blocks[0].instrs ~= Instr(op: Op.call, type: Type.i32(),
            uses: [format], symbol: "printf");
    func.blocks[0].instrs ~= Instr(op: Op.ret);

    auto machineFunc = (new X86Target()).selectAndAlloc(func);
    assert(machineFunc.relocs.length == 2);
    assert(machineFunc.relocs[0].symbol == "format_string");
    assert(machineFunc.relocs[0].type == X86Dir32);
    assert(machineFunc.relocs[1].symbol == "printf");
    assert(machineFunc.relocs[1].type == X86Rel32);
}

unittest
{
    auto aggregate = Type.struct_("triple", [Type.i32(), Type.i8(), Type.i16()]);
    auto func = Func();
    func.name = "aggregate_memory";
    func.retType = Type.void_();
    func.newBlock("entry");
    auto pointer = func.newValue(Type.ptr());
    auto value = func.newValue(aggregate);
    auto loaded = func.newValue(aggregate);
    func.blocks[0].instrs ~= Instr(op: Op.alloca, dst: pointer, type: aggregate);
    func.blocks[0].instrs ~= Instr(op: Op.store, uses: [pointer, value]);
    func.blocks[0].instrs ~= Instr(op: Op.load, dst: loaded,
            type: aggregate, uses: [pointer]);
    func.blocks[0].instrs ~= Instr(op: Op.ret);

    auto machineFunc = (new X86Target()).selectAndAlloc(func);
    assert(machineFunc.frameSize >= 24);
    assert(machineFunc.code[$ - 1] == 0xC3);

    auto returningFunc = Func();
    returningFunc.name = "aggregate_return";
    returningFunc.retType = aggregate;
    returningFunc.newBlock("entry");
    auto returnValue = returningFunc.newValue(aggregate);
    returningFunc.blocks[0].instrs ~= Instr(op: Op.ret, uses: [returnValue]);
    auto returningMachineFunc = (new X86Target()).selectAndAlloc(returningFunc);
    assert(returningMachineFunc.frameSize >= 12);
    assert(returningMachineFunc.code[$ - 1] == 0xC3);
}

unittest
{
    auto func = Func();
    func.name = "instruction_set";
    func.newBlock("entry");
    auto lhs = func.newValue(Type.i32(), "lhs");
    auto rhs = func.newValue(Type.i32(), "rhs");
    auto fpLhs = func.newValue(Type.f64(), "fpLhs");
    auto fpRhs = func.newValue(Type.f64(), "fpRhs");
    auto callee = func.newValue(Type.ptr(), "callee");
    func.params = [
        Param(Type.i32(), "lhs", lhs),
        Param(Type.i32(), "rhs", rhs),
        Param(Type.f64(), "fpLhs", fpLhs),
        Param(Type.f64(), "fpRhs", fpRhs),
        Param(Type.ptr(), "callee", callee),
    ];

    Value last;
    foreach (op; [Op.add, Op.sub, Op.mul, Op.sdiv, Op.udiv, Op.srem, Op.urem,
            Op.and_, Op.or_, Op.xor_, Op.shl, Op.ashr, Op.lshr])
    {
        last = func.newValue(Type.i32());
        func.blocks[0].instrs ~= Instr(op: op, dst: last, type: Type.i32(),
                uses: [lhs, rhs]);
    }
    foreach (op; [Op.fadd, Op.fsub, Op.fmul, Op.fdiv])
    {
        last = func.newValue(Type.f64());
        func.blocks[0].instrs ~= Instr(op: op, dst: last, type: Type.f64(),
                uses: [fpLhs, fpRhs]);
    }

    auto comparison = func.newValue(Type.bool_());
    func.blocks[0].instrs ~= Instr(op: Op.icmp, dst: comparison,
            type: Type.bool_(), pred: Pred.slt, uses: [lhs, rhs]);
    auto floatComparison = func.newValue(Type.bool_());
    func.blocks[0].instrs ~= Instr(op: Op.fcmp, dst: floatComparison,
            type: Type.bool_(), pred: Pred.ne, uses: [fpLhs, fpRhs]);

    auto wideSigned = func.newValue(Type.i64());
    func.blocks[0].instrs ~= Instr(op: Op.sext, dst: wideSigned,
            type: Type.i64(), uses: [lhs]);
    auto wideUnsigned = func.newValue(Type.i64());
    func.blocks[0].instrs ~= Instr(op: Op.zext, dst: wideUnsigned,
            type: Type.i64(), uses: [rhs]);
    auto narrowed = func.newValue(Type.i32());
    func.blocks[0].instrs ~= Instr(op: Op.trunc, dst: narrowed,
            type: Type.i32(), uses: [wideSigned]);
    auto convertedFloat = func.newValue(Type.f64());
    func.blocks[0].instrs ~= Instr(op: Op.sitofp, dst: convertedFloat,
            type: Type.f64(), uses: [lhs]);
    func.blocks[0].instrs ~= Instr(op: Op.uitofp, dst: convertedFloat,
            type: Type.f64(), uses: [wideUnsigned]);
    auto convertedInt = func.newValue(Type.i64());
    func.blocks[0].instrs ~= Instr(op: Op.fptosi, dst: convertedInt,
            type: Type.i64(), uses: [fpLhs]);
    func.blocks[0].instrs ~= Instr(op: Op.fptoui, dst: convertedInt,
            type: Type.i64(), uses: [fpRhs]);
    auto bitcast = func.newValue(Type.i64());
    func.blocks[0].instrs ~= Instr(op: Op.bitcast, dst: bitcast,
            type: Type.i64(), uses: [fpLhs]);

    auto pointer = func.newValue(Type.ptr());
    func.blocks[0].instrs ~= Instr(op: Op.alloca, dst: pointer, type: Type.i32());
    func.blocks[0].instrs ~= Instr(op: Op.store, uses: [pointer, lhs]);
    auto loaded = func.newValue(Type.i32());
    func.blocks[0].instrs ~= Instr(op: Op.load, dst: loaded,
            type: Type.i32(), uses: [pointer]);
    auto element = func.newValue(Type.ptr());
    func.blocks[0].instrs ~= Instr(op: Op.gep, dst: element, type: Type.i32(),
            uses: [pointer, rhs], imm: Const.int_(4));
    auto called = func.newValue(Type.i32());
    func.blocks[0].instrs ~= Instr(op: Op.call, dst: called,
            type: Type.i32(), uses: [callee, lhs, rhs]);
    func.blocks[0].instrs ~= Instr(op: Op.ret, uses: [called]);

    auto machineFunc = (new X86Target()).selectAndAlloc(func);
    assert(machineFunc.code.length > 400);
    assert(machineFunc.code[$ - 1] == 0xC3);
}

unittest
{
    auto func = Func();
    func.name = "branches";
    func.newBlock("entry");
    func.newBlock("left");
    func.newBlock("right");
    func.newBlock("merge");
    auto condition = func.newValue(Type.bool_());
    auto leftValue = func.newValue(Type.i32());
    auto rightValue = func.newValue(Type.i32());
    auto merged = func.newValue(Type.i32());
    func.blocks[0].instrs ~= Instr(op: Op.condbr, uses: [condition],
            target: 1, altTarget: 2);
    func.blocks[1].instrs ~= Instr(op: Op.br, target: 3);
    func.blocks[2].instrs ~= Instr(op: Op.br, target: 3);
    func.blocks[3].instrs ~= Instr(op: Op.phi, dst: merged, type: Type.i32(),
            phiEdges: [PhiEdge(leftValue, 1), PhiEdge(rightValue, 2)]);
    func.blocks[3].instrs ~= Instr(op: Op.ret, uses: [merged]);

    auto machineFunc = (new X86Target()).selectAndAlloc(func);
    assert(machineFunc.blocks.length == 4);
    assert(machineFunc.blocks[3].label == "merge");
    bool hasConditionalJumpToFalse;
    foreach (i; 0 .. machineFunc.code.length - 1)
        if (machineFunc.code[i] == 0x0F &&
            machineFunc.code[i + 1] == 0x84)
            hasConditionalJumpToFalse = true;
    assert(hasConditionalJumpToFalse);
    assert(machineFunc.code[$ - 1] == 0xC3);
}

unittest
{
    auto func = Func();
    func.name = "floating";
    func.newBlock("entry");
    auto left = func.newValue(Type.f64());
    auto right = func.newValue(Type.f64());
    auto result = func.newValue(Type.f64());
    auto integer = func.newValue(Type.i64());
    auto unsignedFloat = func.newValue(Type.f64());
    auto unsignedInteger = func.newValue(Type.i64());
    func.blocks[0].instrs ~= Instr(op: Op.fdiv, dst: result,
            type: Type.f64(), uses: [left, right]);
    func.blocks[0].instrs ~= Instr(op: Op.sitofp, dst: unsignedFloat,
            type: Type.f64(), uses: [integer]);
    func.blocks[0].instrs ~= Instr(op: Op.uitofp, dst: unsignedFloat,
            type: Type.f64(), uses: [integer]);
    func.blocks[0].instrs ~= Instr(op: Op.fptosi, dst: integer,
            type: Type.i64(), uses: [result]);
    func.blocks[0].instrs ~= Instr(op: Op.fptoui, dst: unsignedInteger,
            type: Type.i64(), uses: [result]);
    func.blocks[0].instrs ~= Instr(op: Op.ret, uses: [result]);

    auto machineFunc = (new X86Target()).selectAndAlloc(func);
    assert(machineFunc.frameSize >= 24);
    assert(machineFunc.code.canFind(0xDE));
    assert(machineFunc.code.canFind(0xDF));
    assert(machineFunc.code[$ - 1] == 0xC3);
}
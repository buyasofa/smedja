module smedja.arch.x86;

import smedja.ir;
import smedja.arch;

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

enum : ushort {
    I_MOV, I_ADD, I_SUB, I_IMUL, I_IDIV,
    I_AND, I_OR,  I_XOR, I_SHL,  I_SAR, I_SHR,
    I_CMP, I_SETE, I_SETL, I_SETLE, I_SETG, I_SETGE,
    I_SETB, I_SETBE, I_SETA, I_SETAE, I_SETNE,
    I_JMP, I_JE, I_JNE,
    I_PUSH, I_POP, I_CALL, I_RET,
    I_ADDSD, I_SUBSD, I_MULSD, I_DIVSD, I_MOVSD,
    I_CVTSI2SD, I_CVTSD2SI,
    I_NOP,
}

private MachLocation reg(RegId r) {
    return MachLocation(MachLocation.Kind.reg, r);
}

private MachLocation spill(int off) {
    return MachLocation(MachLocation.Kind.spill, 0, off);
}

private MachLocation voidLoc() {
    return MachLocation(MachLocation.Kind.reg, EAX);
}

private ushort setFromPred(Pred p) {
    final switch (p) {
        case Pred.eq:  return I_SETE;
        case Pred.ne:  return I_SETNE;
        case Pred.slt: return I_SETL;
        case Pred.sle: return I_SETLE;
        case Pred.sgt: return I_SETG;
        case Pred.sge: return I_SETGE;
        case Pred.ult: return I_SETB;
        case Pred.ule: return I_SETBE;
        case Pred.ugt: return I_SETA;
        case Pred.uge: return I_SETAE;
        case Pred.lt:  return I_SETL;
        case Pred.le:  return I_SETLE;
        case Pred.gt:  return I_SETG;
        case Pred.ge:  return I_SETGE;
    }
}

private MachFunc selectFunc(ref Func f) {
    MachFunc mf;
    mf.name = f.name;

    foreach (ref b; f.blocks) {
        MachBlock mb;
        mb.label = b.name;

        foreach (ref ins; b.instrs) {
            MachLocation d = reg(EAX);

            final switch (ins.op) {
                case Op.const_:
                    mb.instrs ~= MachInstr(I_MOV, d, [d]);
                    break;
                case Op.add:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_ADD, d, [d, reg(ECX)]);
                    break;
                case Op.sub:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_SUB, d, [d, reg(ECX)]);
                    break;
                case Op.mul:
                    mb.instrs ~= MachInstr(I_MOV,  d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_IMUL, d, [d, reg(ECX)]);
                    break;
                case Op.and_:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_AND, d, [d, reg(ECX)]);
                    break;
                case Op.or_:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_OR,  d, [d, reg(ECX)]);
                    break;
                case Op.xor_:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_XOR, d, [d, reg(ECX)]);
                    break;
                case Op.shl:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_SHL, d, [d, reg(ECX)]);
                    break;
                case Op.ashr:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_SAR, d, [d, reg(ECX)]);
                    break;
                case Op.lshr:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_SHR, d, [d, reg(ECX)]);
                    break;
                case Op.icmp:
                    mb.instrs ~= MachInstr(I_CMP, voidLoc, [reg(EAX), reg(ECX)]);
                    mb.instrs ~= MachInstr(setFromPred(ins.pred), d, []);
                    break;
                case Op.br:
                    mb.instrs ~= MachInstr(I_JMP, voidLoc, []);
                    break;
                case Op.condbr:
                    mb.instrs ~= MachInstr(I_CMP, voidLoc, [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_JE,  voidLoc, []);
                    mb.instrs ~= MachInstr(I_JNE, voidLoc, []);
                    break;
                case Op.ret:
                    if (ins.uses.length)
                        mb.instrs ~= MachInstr(I_MOV, reg(EAX), [reg(EAX)]);
                    mb.instrs ~= MachInstr(I_RET, voidLoc, []);
                    break;
                case Op.call:
                    mb.instrs ~= MachInstr(I_CALL, d, [reg(EAX)]);
                    break;
                case Op.alloca:
                    mb.instrs ~= MachInstr(I_SUB, reg(ESP), [reg(ESP)]);
                    break;
                case Op.load:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    break;
                case Op.store:
                    mb.instrs ~= MachInstr(I_MOV, reg(EAX), [reg(ECX)]);
                    break;
                case Op.fadd:
                    mb.instrs ~= MachInstr(I_MOVSD, d, [reg(ST0)]);
                    mb.instrs ~= MachInstr(I_ADDSD, d, [d, reg(ST0)]);
                    break;
                case Op.fsub:
                    mb.instrs ~= MachInstr(I_MOVSD, d, [reg(ST0)]);
                    mb.instrs ~= MachInstr(I_SUBSD, d, [d, reg(ST0)]);
                    break;
                case Op.fmul:
                    mb.instrs ~= MachInstr(I_MOVSD, d, [reg(ST0)]);
                    mb.instrs ~= MachInstr(I_MULSD, d, [d, reg(ST0)]);
                    break;
                case Op.fdiv:
                    mb.instrs ~= MachInstr(I_MOVSD, d, [reg(ST0)]);
                    mb.instrs ~= MachInstr(I_DIVSD, d, [d, reg(ST0)]);
                    break;
                case Op.sitofp:
                    mb.instrs ~= MachInstr(I_CVTSI2SD, d, [reg(EAX)]);
                    break;
                case Op.fptosi:
                    mb.instrs ~= MachInstr(I_CVTSD2SI, d, [reg(ST0)]);
                    break;
                case Op.sext, Op.zext, Op.trunc, Op.bitcast:
                    mb.instrs ~= MachInstr(I_MOV, d, [reg(EAX)]);
                    break;
                case Op.phi, Op.gep, Op.sdiv, Op.udiv,
                     Op.srem, Op.urem, Op.fcmp, Op.uitofp,
                     Op.fptoui, Op.unreachable:
                    mb.instrs ~= MachInstr(I_NOP, voidLoc, []);
                    break;
            }
        }

        mf.blocks ~= mb;
    }

    return mf;
}

final class CdeclABI : ABI {
    CallingConv conv()        { return CallingConv.cdecl; }
    uint        shadowSpace() { return 0; }

    Allocation[] classify(Type[] params) {
        Allocation[] r;
        uint off = 4;
        foreach (t; params) {
            r   ~= Allocation(Allocation.Kind.stack, 0, off, t);
            off += (t.width + 3) & ~3u;
        }
        return r;
    }

    Allocation returnSlot(Type ret) {
        if (ret.isFloat) return Allocation(Allocation.Kind.reg, ST0, 0, ret);
        return Allocation(Allocation.Kind.reg, EAX, 0, ret);
    }
}

final class X86Target : Target {
    string name()        { return "x86-windows"; }
    uint   pointerSize() { return 4; }
    uint   stackAlign()  { return 16; }
    RegSet registers()   { return x86Regs; }

    ABI abi(CallingConv cc) {
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
    auto allocations = abi.classify([Type.i8(), Type.i64(), Type.f32()]);
    assert(allocations.length == 3);
    assert(allocations[0].kind == Allocation.Kind.stack);
    assert(allocations[0].offset == 4);
    assert(allocations[1].offset == 8);
    assert(allocations[2].offset == 16);
    assert(allocations[0].type.kind == TypeKind.i8);
    assert(allocations[1].type.kind == TypeKind.i64);
    assert(allocations[2].type.kind == TypeKind.f32);

    auto integerReturn = abi.returnSlot(Type.i32());
    assert(integerReturn.kind == Allocation.Kind.reg);
    assert(integerReturn.reg == EAX);
    auto floatReturn = abi.returnSlot(Type.f64());
    assert(floatReturn.kind == Allocation.Kind.reg);
    assert(floatReturn.reg == ST0);
}

unittest
{
    auto func = Func();
    func.name = "arithmetic";
    func.newBlock("entry");
    func.blocks[0].instrs ~= Instr(op: Op.add);
    func.blocks[0].instrs ~= Instr(op: Op.ret);

    auto target = new X86Target();
    auto machineFunc = target.selectAndAlloc(func);
    assert(machineFunc.name == "arithmetic");
    assert(machineFunc.blocks.length == 1);
    assert(machineFunc.blocks[0].label == "entry");
    assert(machineFunc.blocks[0].instrs.length == 3);
    assert(machineFunc.blocks[0].instrs[0].opcode == I_MOV);
    assert(machineFunc.blocks[0].instrs[1].opcode == I_ADD);
    assert(machineFunc.blocks[0].instrs[2].opcode == I_RET);
}
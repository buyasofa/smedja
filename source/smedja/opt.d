module smedja.opt;

import smedja.ir;

bool optimize(ref Module mod)
{
    bool changed;
    foreach (ref func; mod.funcs)
        changed |= optimize(func);
    return changed;
}

bool optimize(ref Func func)
{
    auto known = new bool[](func.values.length);
    auto constants = new long[](func.values.length);
    bool changed;

    foreach (ref block; func.blocks)
    {
        foreach (ref instruction; block.instrs)
        {
            if (instruction.op == Op.const_)
            {
                if (!instruction.dst.isNone &&
                    instruction.dst.id < known.length &&
                    instruction.imm.kind == Const.Kind.i)
                {
                    known[instruction.dst.id] = true;
                    constants[instruction.dst.id] = instruction.imm.i;
                }
                continue;
            }

            if (!isFoldable(instruction.op) || !instruction.type.isInt ||
                instruction.uses.length != 2 ||
                instruction.dst.isNone || instruction.dst.id >= known.length)
                continue;

            auto lhs = instruction.uses[0];
            auto rhs = instruction.uses[1];
            if (lhs.isNone || rhs.isNone ||
                lhs.id >= known.length || rhs.id >= known.length ||
                !known[lhs.id] || !known[rhs.id])
                continue;

            ulong bits = instruction.type.width * 8;
            if (!bits)
                continue;
            ulong mask = bits == 64 ? ulong.max : (1UL << bits) - 1;
            ulong left = cast(ulong) constants[lhs.id] & mask;
            ulong right = cast(ulong) constants[rhs.id] & mask;
            ulong result;

            final switch (instruction.op)
            {
            case Op.add: result = left + right; break;
            case Op.sub: result = left - right; break;
            case Op.mul: result = left * right; break;
            case Op.and_: result = left & right; break;
            case Op.or_: result = left | right; break;
            case Op.xor_: result = left ^ right; break;
            case Op.shl:
                if (right >= bits)
                    continue;
                result = left << right;
                break;
            case Op.lshr:
                if (right >= bits)
                    continue;
                result = left >> right;
                break;
            case Op.const_, Op.sdiv, Op.udiv, Op.srem, Op.urem,
                 Op.fadd, Op.fsub, Op.fmul, Op.fdiv, Op.ashr,
                 Op.icmp, Op.fcmp, Op.sext, Op.zext, Op.trunc,
                 Op.sitofp, Op.uitofp, Op.fptosi, Op.fptoui,
                 Op.bitcast, Op.alloca, Op.load, Op.store, Op.gep,
                 Op.br, Op.condbr, Op.ret, Op.unreachable, Op.call, Op.phi:
                continue;
            }

            result &= mask;
            instruction.op = Op.const_;
            instruction.uses = null;
            instruction.imm = Const.int_(cast(long) result);
            constants[instruction.dst.id] = cast(long) result;
            known[instruction.dst.id] = true;
            changed = true;
        }
    }

    return changed;
}

private bool isFoldable(Op op)
{
    final switch (op)
    {
    case Op.add, Op.sub, Op.mul, Op.and_, Op.or_, Op.xor_,
         Op.shl, Op.lshr:
        return true;
    case Op.const_, Op.sdiv, Op.udiv, Op.srem, Op.urem,
         Op.fadd, Op.fsub, Op.fmul, Op.fdiv, Op.ashr,
         Op.icmp, Op.fcmp, Op.sext, Op.zext, Op.trunc,
         Op.sitofp, Op.uitofp, Op.fptosi, Op.fptoui, Op.bitcast,
         Op.alloca, Op.load, Op.store, Op.gep, Op.br, Op.condbr,
         Op.ret, Op.unreachable, Op.call, Op.phi:
        return false;
    }
}

unittest
{
    auto mod = Module();
    mod.newFunc("fold", Type.i32());
    auto lhs = mod.funcs[0].newValue(Type.i32());
    auto rhs = mod.funcs[0].newValue(Type.i32());
    auto sum = mod.funcs[0].newValue(Type.i32());
    mod.funcs[0].entry.instrs ~= Instr(op: Op.const_, dst: lhs, type: Type.i32(),
            imm: Const.int_(12));
    mod.funcs[0].entry.instrs ~= Instr(op: Op.const_, dst: rhs, type: Type.i32(),
            imm: Const.int_(30));
    mod.funcs[0].entry.instrs ~= Instr(op: Op.add, dst: sum, type: Type.i32(),
            uses: [lhs, rhs]);
    mod.funcs[0].entry.instrs ~= Instr(op: Op.ret, uses: [sum]);

    assert(optimize(mod));
    assert(mod.funcs[0].entry.instrs[2].op == Op.const_);
    assert(mod.funcs[0].entry.instrs[2].imm.i == 42);
    assert(!optimize(mod));
}

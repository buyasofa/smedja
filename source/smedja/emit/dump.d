module smedja.emit.dump;

import smedja.ir;
import std.array : Appender;
import std.format : format;

string toDebugString(ref Module mod)
{
    Appender!string output;
    output.put("module ");
    putQuoted(output, mod.name);
    output.put("\n");

    foreach (externFunc; mod.externs)
    {
        output.put("extern @");
        output.put(externFunc.name);
        output.put("(");
        putParams(output, externFunc.params);
        output.put(") -> ");
        putType(output, externFunc.retType);
        output.put("\n");
    }

    foreach (global; mod.globals)
    {
        output.put("global @");
        output.put(global.name);
        output.put(": ");
        putType(output, global.type);
        output.put(" ");
        output.put(linkageName(global.linkage));
        output.put(" = 0x");
        foreach (octet; global.init)
            output.put(format("%02x", octet));
        output.put("\n");
    }

    foreach (func; mod.funcs)
    {
        output.put("func @");
        output.put(func.name);
        output.put("(");
        putParams(output, func.params);
        output.put(") -> ");
        putType(output, func.retType);
        output.put(" {\n");

        foreach (block; func.blocks)
        {
            output.put("  ^");
            output.put(block.name);
            output.put(":\n");
            foreach (instruction; block.instrs)
            {
                output.put("    ");
                putInstruction(output, func, instruction);
                output.put("\n");
            }
        }
        output.put("}\n");
    }

    return output.data;
}

private void putParams(ref Appender!string output, Param[] params)
{
    foreach (index, param; params)
    {
        if (index)
            output.put(", ");
        output.put(valueName(param.value));
        output.put(": ");
        putType(output, param.type);
    }
}

private void putType(ref Appender!string output, Type type)
{
    final switch (type.kind)
    {
    case TypeKind.void_: output.put("void"); break;
    case TypeKind.bool_: output.put("bool"); break;
    case TypeKind.i8: output.put("i8"); break;
    case TypeKind.i16: output.put("i16"); break;
    case TypeKind.i32: output.put("i32"); break;
    case TypeKind.i64: output.put("i64"); break;
    case TypeKind.f32: output.put("f32"); break;
    case TypeKind.f64: output.put("f64"); break;
    case TypeKind.ptr: output.put("ptr"); break;
    case TypeKind.struct_:
        output.put("struct ");
        output.put(type.name);
        output.put(" {");
        foreach (index, field; type.fields)
        {
            if (index)
                output.put(", ");
            putType(output, field);
        }
        output.put("}");
        break;
    case TypeKind.func:
        output.put("func");
        break;
    }
}

private void putInstruction(ref Appender!string output, ref Func func,
        Instr instruction)
{
    if (hasResult(instruction) && !instruction.dst.isNone)
    {
        output.put(valueName(instruction.dst));
        output.put(" = ");
    }

    final switch (instruction.op)
    {
    case Op.const_:
        output.put("const ");
        putType(output, instruction.type);
        output.put(" ");
        if (instruction.symbol.length)
        {
            output.put("@");
            output.put(instruction.symbol);
        }
        else
            putConstant(output, instruction.imm);
        break;
    case Op.add: putBinary(output, "add", instruction); break;
    case Op.sub: putBinary(output, "sub", instruction); break;
    case Op.mul: putBinary(output, "mul", instruction); break;
    case Op.sdiv: putBinary(output, "sdiv", instruction); break;
    case Op.udiv: putBinary(output, "udiv", instruction); break;
    case Op.srem: putBinary(output, "srem", instruction); break;
    case Op.urem: putBinary(output, "urem", instruction); break;
    case Op.fadd: putBinary(output, "fadd", instruction); break;
    case Op.fsub: putBinary(output, "fsub", instruction); break;
    case Op.fmul: putBinary(output, "fmul", instruction); break;
    case Op.fdiv: putBinary(output, "fdiv", instruction); break;
    case Op.and_: putBinary(output, "and", instruction); break;
    case Op.or_: putBinary(output, "or", instruction); break;
    case Op.xor_: putBinary(output, "xor", instruction); break;
    case Op.shl: putBinary(output, "shl", instruction); break;
    case Op.ashr: putBinary(output, "ashr", instruction); break;
    case Op.lshr: putBinary(output, "lshr", instruction); break;
    case Op.icmp:
        output.put("icmp ");
        output.put(predName(instruction.pred));
        output.put(" ");
        putType(output, func.typeOf(instruction.uses[0]));
        output.put(" ");
        putUses(output, instruction.uses);
        break;
    case Op.fcmp:
        output.put("fcmp ");
        output.put(predName(instruction.pred));
        output.put(" ");
        putType(output, func.typeOf(instruction.uses[0]));
        output.put(" ");
        putUses(output, instruction.uses);
        break;
    case Op.sext: putCast(output, "sext", instruction); break;
    case Op.zext: putCast(output, "zext", instruction); break;
    case Op.trunc: putCast(output, "trunc", instruction); break;
    case Op.sitofp: putCast(output, "sitofp", instruction); break;
    case Op.uitofp: putCast(output, "uitofp", instruction); break;
    case Op.fptosi: putCast(output, "fptosi", instruction); break;
    case Op.fptoui: putCast(output, "fptoui", instruction); break;
    case Op.bitcast: putCast(output, "bitcast", instruction); break;
    case Op.alloca:
        output.put("alloca ");
        putType(output, instruction.type);
        break;
    case Op.load:
        output.put("load ");
        putType(output, instruction.type);
        output.put(", ");
        putUses(output, instruction.uses);
        break;
    case Op.store:
        output.put("store ");
        putUses(output, instruction.uses);
        break;
    case Op.gep:
        output.put("gep ");
        putType(output, instruction.type);
        output.put(" ");
        putUses(output, instruction.uses);
        output.put(format(", %d", instruction.imm.i));
        break;
    case Op.br:
        output.put(format("br ^%s", func.blocks[instruction.target].name));
        break;
    case Op.condbr:
        output.put("condbr ");
        putUses(output, instruction.uses);
        output.put(format(", ^%s, ^%s",
                func.blocks[instruction.target].name,
                func.blocks[instruction.altTarget].name));
        break;
    case Op.ret:
        output.put("ret");
        if (instruction.uses.length)
        {
            output.put(" ");
            putUses(output, instruction.uses);
        }
        break;
    case Op.unreachable: output.put("unreachable"); break;
    case Op.call:
        output.put("call ");
        putType(output, instruction.type);
        output.put(" ");
        if (instruction.symbol.length)
        {
            output.put("@");
            output.put(instruction.symbol);
            if (instruction.uses.length)
                output.put("(");
            putUses(output, instruction.uses);
            if (instruction.uses.length)
                output.put(")");
        }
        else
            putUses(output, instruction.uses);
        break;
    case Op.phi:
        output.put("phi ");
        putType(output, instruction.type);
        output.put(" ");
        foreach (index, edge; instruction.phiEdges)
        {
            if (index)
                output.put(", ");
            output.put("[ ");
            output.put(valueName(edge.val));
            output.put(", ^");
            output.put(func.blocks[edge.blockId].name);
            output.put(" ]");
        }
        break;
    }
}

private bool hasResult(Instr instruction)
{
    final switch (instruction.op)
    {
    case Op.store, Op.br, Op.condbr, Op.ret, Op.unreachable:
        return false;
    case Op.call:
        return !instruction.type.isVoid;
    case Op.const_, Op.add, Op.sub, Op.mul, Op.sdiv, Op.udiv,
         Op.srem, Op.urem, Op.fadd, Op.fsub, Op.fmul, Op.fdiv,
         Op.and_, Op.or_, Op.xor_, Op.shl, Op.ashr, Op.lshr,
         Op.icmp, Op.fcmp, Op.sext, Op.zext, Op.trunc, Op.sitofp,
         Op.uitofp, Op.fptosi, Op.fptoui, Op.bitcast, Op.alloca,
         Op.load, Op.gep, Op.phi:
        return true;
    }
}

private void putBinary(ref Appender!string output, string op, Instr instruction)
{
    output.put(op);
    output.put(" ");
    putType(output, instruction.type);
    output.put(" ");
    putUses(output, instruction.uses);
}

private void putCast(ref Appender!string output, string op, Instr instruction)
{
    output.put(op);
    output.put(" ");
    putType(output, instruction.type);
    output.put(" ");
    putUses(output, instruction.uses);
}

private void putUses(ref Appender!string output, Value[] uses)
{
    foreach (index, use; uses)
    {
        if (index)
            output.put(", ");
        output.put(valueName(use));
    }
}

private void putConstant(ref Appender!string output, Const value)
{
    final switch (value.kind)
    {
    case Const.Kind.i: output.put(format("%d", value.i)); break;
    case Const.Kind.f: output.put(format("%.17g", value.f)); break;
    case Const.Kind.undef: output.put("undef"); break;
    case Const.Kind.null_: output.put("null"); break;
    }
}

private string valueName(Value value)
{
    return format("%%v%d", value.id);
}

private string linkageName(Linkage linkage)
{
    final switch (linkage)
    {
    case Linkage.internal: return "internal";
    case Linkage.external: return "external";
    case Linkage.weak: return "weak";
    }
}

private string predName(Pred pred)
{
    final switch (pred)
    {
    case Pred.eq: return "eq";
    case Pred.ne: return "ne";
    case Pred.slt: return "slt";
    case Pred.sle: return "sle";
    case Pred.sgt: return "sgt";
    case Pred.sge: return "sge";
    case Pred.ult: return "ult";
    case Pred.ule: return "ule";
    case Pred.ugt: return "ugt";
    case Pred.uge: return "uge";
    case Pred.lt: return "lt";
    case Pred.le: return "le";
    case Pred.gt: return "gt";
    case Pred.ge: return "ge";
    }
}

private void putQuoted(ref Appender!string output, string value)
{
    output.put("\"");
    foreach (ch; value)
    {
        switch (ch)
        {
        case '"': output.put("\\\""); break;
        case '\\': output.put("\\\\"); break;
        case '\n': output.put("\\n"); break;
        case '\r': output.put("\\r"); break;
        case '\t': output.put("\\t"); break;
        default: output.put(ch); break;
        }
    }
    output.put("\"");
}

unittest
{
    auto mod = Module();
    mod.name = "debug";
    mod.newFunc("sum", Type.i32(),
            [Param(Type.i32(), "left"), Param(Type.i32(), "right")]);
    auto result = mod.funcs[0].newValue(Type.i32());
    mod.funcs[0].entry.instrs ~= Instr(op: Op.add, dst: result, type: Type.i32(),
            uses: [mod.funcs[0].params[0].value, mod.funcs[0].params[1].value]);
    mod.funcs[0].entry.instrs ~= Instr(op: Op.ret, uses: [result]);

    auto text = toDebugString(mod);
    auto expected =
        "module \"debug\"\n" ~
        "func @sum(%v0: i32, %v1: i32) -> i32 {\n" ~
        "  ^entry:\n" ~
        "    %v2 = add i32 %v0, %v1\n" ~
        "    ret %v2\n" ~
        "}\n";
    assert(text == expected, text);
}

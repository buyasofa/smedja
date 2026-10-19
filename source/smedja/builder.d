module smedja.builder;

import smedja.errors : InvalidIRException, UnsupportedOperationException;
import smedja.ir;

/// builds ir instructions for one function. use the free functions below with ufcs.
struct IRBuilder
{
    private Func* func;
    private uint blockIndex;

    /// starts building instructions in the function's entry block.
    this(ref Func func)
    {
        if (!func.blocks.length)
            throw new InvalidIRException("a function builder requires an entry block");
        this.func = &func;
    }

    private uint currentBlock() const
    {
        return blockIndex;
    }

    private uint newBlock(string name = "")
    {
        return func.newBlock(name).id;
    }

    private void positionAt(uint index)
    {
        if (index >= func.blocks.length)
            throw new InvalidIRException("insertion block is outside the function");
        blockIndex = index;
    }

    private Value param(size_t index) const
    {
        if (index >= func.params.length)
            throw new InvalidIRException("parameter index is outside the function");
        return func.params[index].value;
    }

    private Value newValue(Type type, string name = "")
    {
        if (type.isVoid)
            throw new InvalidIRException("cannot create a value of type void");
        return func.newValue(type, name);
    }

    private Value constant(Type type, Const value)
    {
        validateConstant(type, value);
        return appendValue(type, Instr(op: Op.const_, type: type, imm: value));
    }

    private Value floatConstant(Type type, double value)
    {
        if (!type.isFloat)
            throw new InvalidIRException(
                    "floating constant requires a floating-point type");
        return constant(type, Const.fp(value));
    }

    private Value intConstant(Type type, long value)
    {
        if (!type.isInt && type.kind != TypeKind.bool_)
            throw new InvalidIRException("integer constant requires an integer type");
        return constant(type, Const.int_(value));
    }

    private Value symbol(string name)
    {
        if (!name.length)
            throw new InvalidIRException("symbol name cannot be empty");
        return appendValue(Type.ptr(),
                Instr(op: Op.const_, type: Type.ptr(), symbol: name));
    }

    private Value binary(Op op, Type type, Value lhs, Value rhs)
    {
        if (!isBinary(op))
            throw new UnsupportedOperationException(
                    "operation is not a binary operation");
        validateBinaryType(op, type);
        requireOperand(lhs, type);
        requireOperand(rhs, type);
        return appendValue(type, Instr(op: op, type: type, uses: [lhs, rhs]));
    }

    private void binaryInto(Value destination, Op op, Value lhs, Value rhs)
    {
        auto type = valueType(destination);
        if (!isBinary(op))
            throw new UnsupportedOperationException(
                    "operation is not a binary operation");
        validateBinaryType(op, type);
        requireOperand(lhs, type);
        requireOperand(rhs, type);
        append(Instr(op: op, dst: destination, type: type,
                uses: [lhs, rhs]));
    }

    private Value add(Value lhs, Value rhs)
    {
        return binary(Op.add, valueType(lhs), lhs, rhs);
    }

    private Value sub(Value lhs, Value rhs)
    {
        return binary(Op.sub, valueType(lhs), lhs, rhs);
    }

    private Value mul(Value lhs, Value rhs)
    {
        return binary(Op.mul, valueType(lhs), lhs, rhs);
    }

    private Value compare(Pred pred, Value lhs, Value rhs)
    {
        auto type = valueType(lhs);
        requireOperand(rhs, type);
        if (!type.isInt)
            throw new InvalidIRException("integer comparison requires integer operands");
        return appendValue(Type.bool_(), Instr(op: Op.icmp,
                type: Type.bool_(), pred: pred, uses: [lhs, rhs]));
    }

    private Value compareFloat(Pred pred, Value lhs, Value rhs)
    {
        auto type = valueType(lhs);
        requireOperand(rhs, type);
        if (!type.isFloat)
            throw new InvalidIRException(
                    "floating comparison requires floating-point operands");
        return appendValue(Type.bool_(), Instr(op: Op.fcmp,
                type: Type.bool_(), pred: pred, uses: [lhs, rhs]));
    }

    private Value convert(Op op, Type type, Value source)
    {
        if (!isConversion(op))
            throw new UnsupportedOperationException(
                    "operation is not a type conversion");
        validateConversion(op, valueType(source), type);
        return appendValue(type, Instr(op: op, type: type, uses: [source]));
    }

    private Value alloca(Type allocatedType)
    {
        if (allocatedType.isVoid)
            throw new InvalidIRException("cannot allocate void");
        auto result = newValue(Type.ptr());
        append(Instr(op: Op.alloca, dst: result, type: allocatedType));
        return result;
    }

    private Value load(Type type, Value pointer)
    {
        requireOperand(pointer, Type.ptr());
        if (type.isVoid)
            throw new InvalidIRException("cannot load void");
        return appendValue(type, Instr(op: Op.load, type: type,
                uses: [pointer]));
    }

    private void store(Value pointer, Value value)
    {
        requireOperand(pointer, Type.ptr());
        valueType(value);
        append(Instr(op: Op.store, uses: [pointer, value]));
    }

    private Value gep(Value pointer, Type elementType, Value index = Value.none,
            long byteOffset = 0)
    {
        requireOperand(pointer, Type.ptr());
        if (elementType.isVoid)
            throw new InvalidIRException("GEP element type cannot be void");
        Value[] uses = [pointer];
        if (!index.isNone)
        {
            if (!valueType(index).isInt)
                throw new InvalidIRException("GEP index must be an integer");
            uses ~= index;
        }
        return appendValue(Type.ptr(), Instr(op: Op.gep, type: elementType,
                uses: uses, imm: Const.int_(byteOffset)));
    }

    private Value phi(Type type, PhiEdge[] incoming)
    {
        validatePhi(type, incoming);
        auto result = newValue(type);
        phi(result, incoming);
        return result;
    }

    private void phi(Value destination, PhiEdge[] incoming)
    {
        auto type = valueType(destination);
        validatePhi(type, incoming);
        append(Instr(op: Op.phi, dst: destination, type: type,
                phiEdges: incoming));
    }

    private void validatePhi(Type type, PhiEdge[] incoming)
    {
        if (!incoming.length)
            throw new InvalidIRException("phi requires at least one incoming value");
        foreach (edge; incoming)
        {
            requireOperand(edge.val, type);
            if (edge.blockId >= func.blocks.length)
                throw new InvalidIRException("phi predecessor is outside the function");
        }
    }

    private void branch(uint target)
    {
        requireBlock(target);
        append(Instr(op: Op.br, target: target));
    }

    private void condBranch(Value condition, uint thenBlock, uint elseBlock)
    {
        requireOperand(condition, Type.bool_());
        requireBlock(thenBlock);
        requireBlock(elseBlock);
        append(Instr(op: Op.condbr, uses: [condition], target: thenBlock,
                altTarget: elseBlock));
    }

    private Value call(string symbolName, Type returnType, Value[] args = [])
    {
        if (!symbolName.length)
            throw new InvalidIRException("call symbol cannot be empty");
        foreach (arg; args)
            valueType(arg);
        if (!returnType.isVoid && returnType.kind == TypeKind.func)
            throw new InvalidIRException("function type cannot be a call result");
        auto result = Instr(op: Op.call, type: returnType,
                uses: args, symbol: symbolName);
        if (returnType.isVoid)
        {
            append(result);
            return Value.none;
        }
        return appendValue(returnType, result);
    }

    private void ret(Value value = Value.none)
    {
        if (func.retType.isVoid)
        {
            if (!value.isNone)
                throw new InvalidIRException("void function cannot return a value");
        }
        else
        {
            requireOperand(value, func.retType);
        }
        append(Instr(op: Op.ret, uses: value.isNone ? null : [value]));
    }

    private void emit(Instr instruction)
    {
        append(instruction);
    }

    private Value appendValue(Type resultType, Instr instruction)
    {
        if (resultType.isVoid)
            throw new InvalidIRException("value instruction cannot have void type");
        instruction.dst = newValue(resultType);
        append(instruction);
        return instruction.dst;
    }

    private void validateConstant(Type type, Const value) const
    {
        if (type.isVoid)
            throw new InvalidIRException("constant cannot have void type");
        final switch (value.kind)
        {
        case Const.Kind.i:
            if (!type.isInt && type.kind != TypeKind.bool_)
                throw new InvalidIRException("integer constant requires an integer type");
            break;
        case Const.Kind.f:
            if (!type.isFloat)
                throw new InvalidIRException(
                        "floating constant requires a floating-point type");
            break;
        case Const.Kind.undef:
            break;
        case Const.Kind.null_:
            if (type.kind != TypeKind.ptr && type.kind != TypeKind.func)
                throw new InvalidIRException("null constant requires a pointer type");
            break;
        }
    }

    private void append(Instr instruction)
    {
        func.blocks[blockIndex].instrs ~= instruction;
    }

    private Type valueType(Value value)
    {
        if (value.isNone || value.id >= func.values.length)
            throw new InvalidIRException("value is not defined in this function");
        return func.values[value.id].type;
    }

    private void requireOperand(Value value, Type type)
    {
        if (!sameType(valueType(value), type))
            throw new InvalidIRException("operand type does not match instruction type");
    }

    private void validateBinaryType(Op op, Type type) const
    {
        if (isFloatBinary(op))
        {
            if (!type.isFloat)
                throw new InvalidIRException(
                        "floating-point operation requires a floating-point type");
        }
        else if (!type.isInt)
        {
            throw new InvalidIRException("integer operation requires an integer type");
        }
    }

    private bool sameType(Type lhs, Type rhs)
    {
        if (lhs.kind != rhs.kind)
            return false;
        if (lhs.kind != TypeKind.struct_)
            return true;
        if (lhs.name != rhs.name || lhs.fields.length != rhs.fields.length)
            return false;
        foreach (index, field; lhs.fields)
            if (!sameType(field, rhs.fields[index]))
                return false;
        return true;
    }

    private void validateConversion(Op op, Type source, Type destination) const
    {
        bool valid;
        final switch (op)
        {
        case Op.sext, Op.zext:
            valid = source.isInt && destination.isInt &&
                source.width < destination.width;
            break;
        case Op.trunc:
            valid = source.isInt && destination.isInt &&
                source.width > destination.width;
            break;
        case Op.sitofp, Op.uitofp:
            valid = source.isInt && destination.isFloat;
            break;
        case Op.fptosi, Op.fptoui:
            valid = source.isFloat && destination.isInt;
            break;
        case Op.bitcast:
            valid = source.width == destination.width;
            break;
        case Op.const_, Op.add, Op.sub, Op.mul, Op.sdiv, Op.udiv,
             Op.srem, Op.urem, Op.fadd, Op.fsub, Op.fmul, Op.fdiv,
             Op.and_, Op.or_, Op.xor_, Op.shl, Op.ashr, Op.lshr,
             Op.icmp, Op.fcmp, Op.alloca, Op.load, Op.store, Op.gep,
             Op.br, Op.condbr, Op.ret, Op.unreachable, Op.call, Op.phi:
            valid = false;
        }
        if (!valid)
            throw new InvalidIRException("invalid source or destination type for conversion");
    }

    private void requireBlock(uint index) const
    {
        if (index >= func.blocks.length)
            throw new InvalidIRException("branch target is outside the function");
    }
}

/// returns the current insertion block.
@property uint currentBlock(ref IRBuilder builder)
{
    return builder.currentBlock;
}

/// creates a basic block and returns its index.
uint newBlock(ref IRBuilder builder, string name = "")
{
    return builder.newBlock(name);
}

/// selects the block that receives new instructions.
void positionAt(ref IRBuilder builder, uint index)
{
    builder.positionAt(index);
}

/// returns the value for a function parameter.
Value param(ref IRBuilder builder, size_t index)
{
    return builder.param(index);
}

/// creates a value with the given type and optional name.
Value newValue(ref IRBuilder builder, Type type, string name = "")
{
    return builder.newValue(type, name);
}

/// creates a constant value.
Value constant(ref IRBuilder builder, Type type, Const value)
{
    return builder.constant(type, value);
}

/// creates a floating-point constant value.
Value floatConstant(ref IRBuilder builder, Type type, double value)
{
    return builder.floatConstant(type, value);
}

/// creates an integer constant value.
Value intConstant(ref IRBuilder builder, Type type, long value)
{
    return builder.intConstant(type, value);
}

/// creates a value that points to a named symbol.
Value symbol(ref IRBuilder builder, string name)
{
    return builder.symbol(name);
}

/// emits a binary operation with an explicit type.
Value binary(ref IRBuilder builder, Op op, Type type, Value lhs, Value rhs)
{
    return builder.binary(op, type, lhs, rhs);
}

/// writes a binary operation into an existing value.
void binaryInto(ref IRBuilder builder, Value destination, Op op,
        Value lhs, Value rhs)
{
    builder.binaryInto(destination, op, lhs, rhs);
}

/// adds two integer values.
Value add(ref IRBuilder builder, Value lhs, Value rhs)
{
    return builder.add(lhs, rhs);
}

/// subtracts the right value from the left value.
Value sub(ref IRBuilder builder, Value lhs, Value rhs)
{
    return builder.sub(lhs, rhs);
}

/// multiplies two integer values.
Value mul(ref IRBuilder builder, Value lhs, Value rhs)
{
    return builder.mul(lhs, rhs);
}

/// compares two integer values.
Value compare(ref IRBuilder builder, Pred pred, Value lhs, Value rhs)
{
    return builder.compare(pred, lhs, rhs);
}

/// compares two floating-point values.
Value compareFloat(ref IRBuilder builder, Pred pred, Value lhs, Value rhs)
{
    return builder.compareFloat(pred, lhs, rhs);
}

/// converts a value to another type.
Value convert(ref IRBuilder builder, Op op, Type type, Value source)
{
    return builder.convert(op, type, source);
}

/// reserves stack space for a value of the given type.
Value alloca(ref IRBuilder builder, Type type)
{
    return builder.alloca(type);
}

/// loads a value from a pointer.
Value load(ref IRBuilder builder, Type type, Value pointer)
{
    return builder.load(type, pointer);
}

/// stores a value through a pointer.
void store(ref IRBuilder builder, Value pointer, Value value)
{
    builder.store(pointer, value);
}

/// calculates an address using an optional index and byte offset.
Value gep(ref IRBuilder builder, Value pointer, Type elementType,
        Value index = Value.none, long byteOffset = 0)
{
    return builder.gep(pointer, elementType, index, byteOffset);
}

/// creates a value from inputs on predecessor blocks.
Value phi(ref IRBuilder builder, Type type, PhiEdge[] incoming)
{
    return builder.phi(type, incoming);
}

/// writes phi inputs into an existing value.
void phi(ref IRBuilder builder, Value destination, PhiEdge[] incoming)
{
    builder.phi(destination, incoming);
}

/// branches to a block.
void branch(ref IRBuilder builder, uint target)
{
    builder.branch(target);
}

/// branches to one of two blocks based on a boolean value.
void condBranch(ref IRBuilder builder, Value condition, uint thenBlock,
        uint elseBlock)
{
    builder.condBranch(condition, thenBlock, elseBlock);
}

/// calls a named function and returns its result.
Value call(ref IRBuilder builder, string symbolName, Type returnType,
        Value[] args = [])
{
    return builder.call(symbolName, returnType, args);
}

/// returns from the current function.
void ret(ref IRBuilder builder, Value value = Value.none)
{
    builder.ret(value);
}

/// appends an instruction directly.
void emit(ref IRBuilder builder, Instr instruction)
{
    builder.emit(instruction);
}

private bool isFloatBinary(Op op)
{
    return op == Op.fadd || op == Op.fsub ||
        op == Op.fmul || op == Op.fdiv;
}

private bool isConversion(Op op)
{
    final switch (op)
    {
    case Op.sext, Op.zext, Op.trunc, Op.sitofp, Op.uitofp,
         Op.fptosi, Op.fptoui, Op.bitcast:
        return true;
    case Op.const_, Op.add, Op.sub, Op.mul, Op.sdiv, Op.udiv, Op.srem,
         Op.urem, Op.fadd, Op.fsub, Op.fmul, Op.fdiv, Op.and_, Op.or_,
         Op.xor_, Op.shl, Op.ashr, Op.lshr, Op.icmp, Op.fcmp, Op.alloca,
         Op.load, Op.store, Op.gep, Op.br, Op.condbr, Op.ret,
         Op.unreachable, Op.call, Op.phi:
        return false;
    }
}

private bool isBinary(Op op)
{
    final switch (op)
    {
    case Op.add, Op.sub, Op.mul, Op.sdiv, Op.udiv, Op.srem, Op.urem,
         Op.fadd, Op.fsub, Op.fmul, Op.fdiv, Op.and_, Op.or_, Op.xor_,
         Op.shl, Op.ashr, Op.lshr:
        return true;
    case Op.const_, Op.icmp, Op.fcmp, Op.sext, Op.zext, Op.trunc,
         Op.sitofp, Op.uitofp, Op.fptosi, Op.fptoui, Op.bitcast,
         Op.alloca, Op.load, Op.store, Op.gep, Op.br, Op.condbr,
         Op.ret, Op.unreachable, Op.call, Op.phi:
        return false;
    }
}

unittest
{
    import std.exception : assertThrown;

    auto mod = Module();
    mod.newFunc("sum", Type.i32(), [Param(Type.i32(), "lhs"),
            Param(Type.i32(), "rhs")]);
    auto builder = IRBuilder(mod.funcs[0]);
    auto sum = builder.add(builder.param(0), builder.param(1));
    builder.ret(sum);

    assert(mod.funcs[0].entry.instrs.length == 2);
    assert(mod.funcs[0].entry.instrs[0].op == Op.add);
    assert(mod.funcs[0].entry.instrs[1].op == Op.ret);
    assertThrown!InvalidIRException(builder.param(2));
}

unittest
{
    import std.exception : assertThrown;

    auto mod = Module();
    mod.newFunc("memory", Type.void_());
    auto builder = IRBuilder(mod.funcs[0]);
    auto slot = builder.alloca(Type.i32());
    auto value = builder.intConstant(Type.i32(), 42);
    builder.store(slot, value);
    auto loaded = builder.load(Type.i32(), slot);
    builder.ret();

    assert(mod.funcs[0].entry.instrs.length == 5);
    assert(mod.funcs[0].entry.instrs[0].op == Op.alloca);
    assert(mod.funcs[0].entry.instrs[2].op == Op.store);
    assert(mod.funcs[0].entry.instrs[3].op == Op.load);
    assert(loaded == Value(2));
    assertThrown!InvalidIRException(builder.intConstant(Type.ptr(), 1));
}

unittest
{
    import std.exception : assertThrown;

    auto mod = Module();
    mod.newFunc("compare", Type.bool_(),
            [Param(Type.f64(), "lhs"), Param(Type.f64(), "rhs")]);
    auto builder = IRBuilder(mod.funcs[0]);
    auto comparison = builder.compareFloat(Pred.lt,
            builder.param(0), builder.param(1));
    builder.ret(comparison);

    assert(mod.funcs[0].entry.instrs[0].op == Op.fcmp);
    assertThrown!InvalidIRException(
            builder.binary(Op.fadd, Type.i32(), Value(0), Value(1)));
}

unittest
{
    import std.exception : assertThrown;

    auto mod = Module();
    mod.newFunc("casts", Type.f64(), [Param(Type.i32(), "value")]);
    auto builder = IRBuilder(mod.funcs[0]);
    auto converted = builder.convert(Op.sitofp, Type.f64(), builder.param(0));
    builder.ret(converted);
    assert(mod.funcs[0].entry.instrs[0].op == Op.sitofp);
    assertThrown!InvalidIRException(
            builder.convert(Op.sext, Type.i16(), builder.param(0)));
}

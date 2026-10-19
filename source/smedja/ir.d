module smedja.ir;

import std.format : format;

/// the kinds of values supported by the ir.
enum TypeKind : ubyte
{
    void_,
    bool_,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    ptr,
    struct_,
    func,
}

/// describes a value type in the ir.
struct Type
{
    TypeKind kind;
    Type[] fields;
    Type[] params;
    Type* ret;
    string name;

    /// returns the void type.
    static Type void_()
    {
        return Type(TypeKind.void_);
    }

    /// returns the boolean type.
    static Type bool_()
    {
        return Type(TypeKind.bool_);
    }

    /// returns an 8-bit integer type.
    static Type i8()
    {
        return Type(TypeKind.i8);
    }

    /// returns a 16-bit integer type.
    static Type i16()
    {
        return Type(TypeKind.i16);
    }

    /// returns a 32-bit integer type.
    static Type i32()
    {
        return Type(TypeKind.i32);
    }

    /// returns a 64-bit integer type.
    static Type i64()
    {
        return Type(TypeKind.i64);
    }

    /// returns a 32-bit floating-point type.
    static Type f32()
    {
        return Type(TypeKind.f32);
    }

    /// returns a 64-bit floating-point type.
    static Type f64()
    {
        return Type(TypeKind.f64);
    }

    /// returns a pointer type.
    static Type ptr()
    {
        return Type(TypeKind.ptr);
    }

    /// returns a named struct type with the given fields.
    static Type struct_(string name, Type[] fields)
    {
        return Type(TypeKind.struct_, fields, [], null, name);
    }

    /// returns a function type with the given result and parameters.
    static Type func_(Type ret, Type[] params)
    {
        auto t = Type(TypeKind.func);
        t.ret = new Type();
        *t.ret = ret;
        return t;
    }

    /// returns whether this is an integer type.
    bool isInt() const
    {
        return kind >= TypeKind.i8 && kind <= TypeKind.i64;
    }

    /// returns whether this is a floating-point type.
    bool isFloat() const
    {
        return kind == TypeKind.f32 || kind == TypeKind.f64;
    }

    /// returns whether this is a pointer type.
    bool isPtr() const
    {
        return kind == TypeKind.ptr;
    }

    /// returns whether this is the void type.
    bool isVoid() const
    {
        return kind == TypeKind.void_;
    }

    /// returns this type's width in bytes.
    uint width() const
    {
        final switch (kind)
        {
        case TypeKind.void_:
            return 0;
        case TypeKind.bool_:
            return 1;
        case TypeKind.i8:
            return 1;
        case TypeKind.i16:
            return 2;
        case TypeKind.i32:
            return 4;
        case TypeKind.i64:
            return 8;
        case TypeKind.f32:
            return 4;
        case TypeKind.f64:
            return 8;
        case TypeKind.ptr:
            return 8;
        case TypeKind.func:
            return 8;
        case TypeKind.struct_:
            {
                uint s;
                foreach (ref f; fields)
                    s += f.width;
                return s;
            }
        }
    }
}

/// identifies a value inside a function.
struct Value
{
    uint id;
    enum Value none = Value(uint.max);
    bool isNone() const
    {
        return id == uint.max;
    }
}

struct ValueDef
{
    Type type;
    string name;
}

/// stores an integer, floating-point, undefined, or null constant.
struct Const
{
    enum Kind : ubyte
    {
        i,
        f,
        undef,
        null_
    }

    Kind kind;
    union
    {
        long i;
        double f;
    }

    /// creates an integer constant.
    static Const int_(long v)
    {
        Const c;
        c.kind = Kind.i;
        c.i = v;
        return c;
    }

    /// creates a floating-point constant.
    static Const fp(double v)
    {
        Const c;
        c.kind = Kind.f;
        c.f = v;
        return c;
    }

    /// creates an undefined constant.
    static Const undef()
    {
        return Const(Kind.undef);
    }

    /// creates a null constant.
    static Const null_()
    {
        return Const(Kind.null_);
    }
}

/// lists the operations that an ir instruction can perform.
enum Op : ubyte
{
    const_,
    add,
    sub,
    mul,
    sdiv,
    udiv,
    srem,
    urem,
    fadd,
    fsub,
    fmul,
    fdiv,
    and_,
    or_,
    xor_,
    shl,
    ashr,
    lshr,
    icmp,
    fcmp,
    sext,
    zext,
    trunc,
    sitofp,
    uitofp,
    fptosi,
    fptoui,
    bitcast,
    alloca,
    load,
    store,
    gep,
    br,
    condbr,
    ret,
    unreachable,
    call,
    phi,
}

/// lists the comparison predicates used by the ir.
enum Pred : ubyte
{
    eq,
    ne,
    slt,
    sle,
    sgt,
    sge,
    ult,
    ule,
    ugt,
    uge,
    lt,
    le,
    gt,
    ge,
}

/// links a phi input value to its predecessor block.
struct PhiEdge
{
    Value val;
    uint blockId;
}

/// represents one ir instruction.
struct Instr
{
    Op op;
    Value dst;
    Type type;
    Value[] uses;
    Const imm;
    Pred pred;
    uint target;
    uint altTarget;
    PhiEdge[] phiEdges;
    string symbol;
}

/// holds the instructions and control flow for a basic block.
struct Block
{
    uint id;
    string name;
    Instr[] instrs;
    uint[] preds;
    uint[] succs;
}

/// describes a function parameter.
struct Param
{
    Type type;
    string name;
    Value value;
}

/// holds a function's signature, values, and blocks.
struct Func
{
    string name;
    Type retType;
    Param[] params;
    Block[] blocks;
    ValueDef[] values;

    /// creates a named value with the given type.
    Value newValue(Type t, string name = "")
    {
        auto v = Value(cast(uint) values.length);
        values ~= ValueDef(t, name);
        return v;
    }

    /// creates and returns a new block.
    ref Block newBlock(string name = "")
    {
        auto id = cast(uint) blocks.length;
        blocks ~= Block(id, name.length ? name : format("b%d", id));
        return blocks[$ - 1];
    }

    /// returns the function's first block.
    ref Block entry() return
    {
        return blocks[0];
    }

    /// returns the type of a value in this function.
    Type typeOf(Value v)
    {
        return values[v.id].type;
    }
}

/// describes how a global is visible to other code.
enum Linkage : ubyte
{
    internal,
    external,
    weak
}

/// describes a global value and its initial bytes.
struct Global
{
    string name;
    Type type;
    Linkage linkage;
    ubyte[] init;
}

/// holds functions, external declarations, and globals for a program.
struct Module
{
    string name;
    Func[] funcs;
    Func[] externs;
    Global[] globals;

    /// creates a function with an entry block and optional parameters.
    ref Func newFunc(string name, Type ret, Param[] params = [])
    {
        Func f;
        f.name = name;
        f.retType = ret;
        f.params = params;
        f.newBlock("entry");
        foreach (ref p; f.params)
            p.value = f.newValue(p.type, p.name);
        funcs ~= f;
        return funcs[$ - 1];
    }

    /// declares an external function.
    ref Func newExtern(string name, Type ret, Type[] paramTypes = [])
    {
        Func f;
        f.name = name;
        f.retType = ret;
        foreach (i, t; paramTypes)
            f.params ~= Param(t, format("p%d", i));
        externs ~= f;
        return externs[$ - 1];
    }
}

unittest
{
    assert(Type.void_().width == 0);
    assert(Type.bool_().width == 1);
    assert(Type.i8().width == 1);
    assert(Type.i16().width == 2);
    assert(Type.i32().width == 4);
    assert(Type.i64().width == 8);
    assert(Type.f32().width == 4);
    assert(Type.f64().width == 8);
    assert(Type.ptr().width == 8);
    assert(Type.struct_("pair", [Type.i8(), Type.i32()]).width == 5);

    assert(Type.i32().isInt);
    assert(!Type.f32().isInt);
    assert(Type.f64().isFloat);
    assert(!Type.i64().isFloat);
    assert(Type.ptr().isPtr);
    assert(!Type.i32().isPtr);
    assert(Type.void_().isVoid);
    assert(!Type.bool_().isVoid);
}

unittest
{
    auto func = Func();
    func.name = "values";

    auto first = func.newValue(Type.i32(), "first");
    auto second = func.newValue(Type.ptr());
    assert(first == Value(0));
    assert(second == Value(1));
    assert(func.typeOf(first).kind == TypeKind.i32);
    assert(func.values[0].name == "first");
    assert(func.values[1].name == "");
    assert(Value.none.isNone);
    assert(!first.isNone);

    func.newBlock();
    func.newBlock("exit");
    assert(func.blocks.length == 2);
    assert(func.blocks[0].id == 0);
    assert(func.blocks[0].name == "b0");
    assert(func.blocks[1].id == 1);
    assert(func.blocks[1].name == "exit");
}

unittest
{
    auto mod = Module();
    auto param = Param(Type.i32(), "count");
    mod.newFunc("run", Type.i32(), [param]);
    assert(mod.funcs.length == 1);
    assert(mod.funcs[0].name == "run");
    assert(mod.funcs[0].retType.kind == TypeKind.i32);
    assert(mod.funcs[0].blocks.length == 1);
    assert(mod.funcs[0].entry.name == "entry");
    assert(mod.funcs[0].params.length == 1);
    assert(mod.funcs[0].params[0].name == "count");
    assert(mod.funcs[0].params[0].value == Value(0));
    assert(mod.funcs[0].typeOf(mod.funcs[0].params[0].value).kind == TypeKind.i32);

    mod.newExtern("puts", Type.i32(), [Type.ptr(), Type.i8()]);
    assert(mod.externs.length == 1);
    assert(mod.externs[0].name == "puts");
    assert(mod.externs[0].retType.kind == TypeKind.i32);
    assert(mod.externs[0].params.length == 2);
    assert(mod.externs[0].params[0].name == "p0");
    assert(mod.externs[0].params[0].type.kind == TypeKind.ptr);
    assert(mod.externs[0].params[1].name == "p1");
    assert(mod.externs[0].params[1].type.kind == TypeKind.i8);
}

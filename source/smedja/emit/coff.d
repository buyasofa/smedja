module smedja.emit.coff;

import smedja.ir;
import smedja.arch;
import smedja.emit;
import std.array : Appender, appender;
import std.algorithm.searching : canFind;

enum : ushort
{
    MACHINE_I386 = 0x014c,
    MACHINE_AMD64 = 0x8664,
}

enum : uint
{
    SCN_CODE = 0x00000020,
    SCN_IDATA = 0x00000040,
    SCN_UDATA = 0x00000080,
    SCN_EXEC = 0x20000000,
    SCN_READ = 0x40000000,
    SCN_WRITE = 0x80000000,
    SCN_ALIGN1 = 0x00100000,
    SCN_ALIGN16 = 0x00500000,
}

enum : ubyte
{
    SYM_EXTERNAL = 2,
    SYM_STATIC = 3
}

enum : ushort
{
    REL_AMD64_ADDR64 = 0x0001,
    REL_AMD64_ADDR32 = 0x0002,
    REL_AMD64_REL32 = 0x0004,
    REL_I386_DIR32 = 0x0006,
    REL_I386_REL32 = 0x0014,
}

align(1) struct CoffHeader
{
    ushort machine;
    ushort numSections;
    uint timestamp;
    uint symTableOff;
    uint numSymbols;
    ushort optHeaderSize;
    ushort flags;
}

align(1) struct SectionHeader
{
    char[8] name;
    uint virtualSize;
    uint virtualAddr;
    uint rawSize;
    uint rawOff;
    uint relocOff;
    uint lineOff;
    ushort numRelocs;
    ushort numLines;
    uint flags;
}

align(1) struct CoffSymbol
{
    union
    {
        char[8] shortName;
        struct
        {
            uint zeroes;
            uint strOff;
        }
    }

    uint value;
    short section;
    ushort type_;
    ubyte storageClass;
    ubyte numAux;
}

align(1) struct CoffReloc
{
    uint addr;
    uint symIdx;
    ushort type_;
}

private void write(T)(ref Appender!(ubyte[]) buf, auto ref T val) {
    buf.put((cast(ubyte*) &val)[0 .. T.sizeof]);
}

private void write(ref Appender!(ubyte[]) buf, ubyte[] val)
{
    buf.put(val);
}

private void setSymbolName(ref CoffSymbol sym, string name, ref ubyte[] strTab)
{
    sym.shortName[] = 0;
    if (name.length <= 8)
        sym.shortName[0 .. name.length] = name[];
    else
    {
        sym.zeroes = 0;
        sym.strOff = cast(uint)(strTab.length + 4);
        strTab ~= cast(ubyte[]) name ~ 0;
    }
}

private char[8] sectionName(string s)
{
    char[8] r = 0;
    auto n = s.length > 8 ? 8 : s.length;
    r[0 .. n] = s[0 .. n];
    return r;
}

private uint coffTypeWidth(Type type, bool x86_64)
{
    if (type.kind == TypeKind.ptr || type.kind == TypeKind.func)
        return x86_64 ? 8 : 4;
    if (type.kind == TypeKind.struct_)
    {
        uint size;
        foreach (field; type.fields)
            size += coffTypeWidth(field, x86_64);
        return size;
    }
    return type.width;
}

final class CoffEmitter : Emitter
{
    private ushort machine_;
    private ushort relocType32_;

    this(bool x86_64 = false)
    {
        machine_ = x86_64 ? MACHINE_AMD64 : MACHINE_I386;
        relocType32_ = x86_64 ? REL_AMD64_REL32 : REL_I386_REL32;
    }

    void emit(ref Module mod, Target target, ref Appender!(ubyte[]) out_)
    {
        if (target.name == "x86-windows" && machine_ != MACHINE_I386)
            throw new Exception("x86 machine code requires an i386 COFF header");

        auto text = appender!(ubyte[])();
        auto data = appender!(ubyte[])();
        auto relocs = appender!(CoffReloc[])();
        auto syms = appender!(CoffSymbol[])();
        ubyte[] strTab;
        MachFunc[] machineFuncs;
        foreach (ref f; mod.funcs)
            machineFuncs ~= target.selectAndAlloc(f);

        uint[string] symbolIndices;
        bool[string] definedSymbols;
        bool[string] declaredSymbols;
        uint nextSymbol;
        foreach (func; mod.funcs)
        {
            if (!func.name.length || func.name in declaredSymbols)
                throw new Exception("COFF function symbol name is empty or duplicated");
            symbolIndices[func.name] = nextSymbol++;
            definedSymbols[func.name] = true;
            declaredSymbols[func.name] = true;
        }
        foreach (global; mod.globals)
        {
            if (!global.name.length || global.name in declaredSymbols)
                throw new Exception("COFF global symbol name is empty or duplicated");
            symbolIndices[global.name] = nextSymbol++;
            definedSymbols[global.name] = true;
            declaredSymbols[global.name] = true;
        }
        foreach (external; mod.externs)
        {
            if (!external.name.length)
                throw new Exception("COFF external symbol name is empty");
            if (external.name !in declaredSymbols)
            {
                symbolIndices[external.name] = nextSymbol++;
                declaredSymbols[external.name] = true;
            }
        }
        foreach (machineFunc; machineFuncs)
            foreach (relocation; machineFunc.relocs)
                if (relocation.symbol !in symbolIndices)
                    symbolIndices[relocation.symbol] = nextSymbol++;

        foreach (ref mf; machineFuncs)
            encodeFunc(mf, text, relocs, syms, strTab, symbolIndices);

        foreach (ref g; mod.globals)
            encodeGlobal(g, data, syms, strTab, machine_ == MACHINE_AMD64);

        bool[string] writtenSymbols;
        foreach (func; mod.funcs)
            writtenSymbols[func.name] = true;
        foreach (global; mod.globals)
            writtenSymbols[global.name] = true;
        foreach (ref f; mod.externs)
        {
            if (f.name !in writtenSymbols)
            {
                addExtern(f.name, syms, strTab);
                writtenSymbols[f.name] = true;
            }
        }
        foreach (machineFunc; machineFuncs)
            foreach (relocation; machineFunc.relocs)
                if (relocation.symbol !in writtenSymbols)
                {
                    addExtern(relocation.symbol, syms, strTab);
                    writtenSymbols[relocation.symbol] = true;
                }

        if (relocs.data.length > ushort.max)
            throw new Exception("COFF section relocation count exceeds the format limit");
        if (strTab.length > uint.max - 4)
            throw new Exception("COFF string table exceeds the format limit");

        uint symTabOff = cast(uint)(
            CoffHeader.sizeof +
                SectionHeader.sizeof * 2 +
                text.data.length +
                relocs.data.length * CoffReloc.sizeof +
                data.data.length);

        CoffHeader hdr = {
            machine: machine_,
            numSections: 2,
            timestamp: 0,
            symTableOff: symTabOff,
            numSymbols: cast(uint) syms.data.length,
            optHeaderSize: 0,
            flags: 0,
        };

        uint textOff = cast(uint)(CoffHeader.sizeof + SectionHeader.sizeof * 2);
        uint dataOff = cast(uint)(textOff + text.data.length +
                relocs.data.length * CoffReloc.sizeof);

        SectionHeader textHdr = {
            name: sectionName(".text"),
            rawSize: cast(uint) text.data.length,
            rawOff: textOff,
            relocOff: relocs.data.length
                ? cast(uint)(textOff + text.data.length) : 0,
            numRelocs: cast(ushort) relocs.data.length,
            flags: SCN_CODE | SCN_EXEC | SCN_READ | SCN_ALIGN16,
        };

        SectionHeader dataHdr = {
            name: sectionName(".data"),
            rawSize: cast(uint) data.data.length,
            rawOff: dataOff,
            flags: SCN_IDATA | SCN_READ | SCN_WRITE | SCN_ALIGN16,
        };

        write(out_, hdr);
        write(out_, textHdr);
        write(out_, dataHdr);
        write(out_, text.data);
        foreach (ref r; relocs.data)
            write(out_, r);
        write(out_, data.data);
        foreach (ref s; syms.data)
            write(out_, s);
        uint strTabSize = cast(uint)(strTab.length + 4);
        write(out_, strTabSize);
        write(out_, strTab);
    }

    private void encodeFunc(ref MachFunc mf,
        ref Appender!(ubyte[]) text,
        ref Appender!(CoffReloc[]) relocs,
        ref Appender!(CoffSymbol[]) syms,
        ref ubyte[] strTab,
        uint[string] symbolIndices)
    {
        CoffSymbol sym = CoffSymbol.init;
        setSymbolName(sym, mf.name, strTab);
        sym.value = cast(uint) text.data.length;
        sym.section = 1;
        sym.type_ = 0x20;
        sym.storageClass = SYM_EXTERNAL;
        syms.put(sym);

        auto functionOffset = cast(uint) text.data.length;
        text.put(mf.code);
        foreach (relocation; mf.relocs)
        {
            if (relocation.symbol !in symbolIndices)
                throw new Exception("COFF relocation references an unknown symbol");
            relocs.put(CoffReloc(
                    functionOffset + relocation.offset,
                    symbolIndices[relocation.symbol],
                    relocation.type ? relocation.type : relocType32_));
        }
    }

    private void encodeGlobal(ref Global g,
        ref Appender!(ubyte[]) data,
        ref Appender!(CoffSymbol[]) syms,
        ref ubyte[] strTab,
        bool x86_64)
    {
        CoffSymbol sym = CoffSymbol.init;
        setSymbolName(sym, g.name, strTab);
        sym.value = cast(uint) data.data.length;
        sym.section = 2;
        sym.storageClass = g.linkage == Linkage.internal ? SYM_STATIC : SYM_EXTERNAL;
        syms.put(sym);

        auto size = coffTypeWidth(g.type, x86_64);
        if (g.init.length > size)
            throw new Exception("global initializer exceeds its COFF type size");
        if (g.init.length)
            write(data, g.init);
        foreach (_; g.init.length .. size)
            write(data, cast(ubyte) 0);
    }

    private void addExtern(string name,
        ref Appender!(CoffSymbol[]) syms,
        ref ubyte[] strTab)
    {
        CoffSymbol sym = CoffSymbol.init;
        setSymbolName(sym, name, strTab);
        sym.value = 0;
        sym.section = 0;
        sym.storageClass = SYM_EXTERNAL;
        syms.put(sym);
    }
}

unittest
{
    auto emitter = new CoffEmitter();
    auto text = appender!(ubyte[])();
    auto data = appender!(ubyte[])();
    auto relocs = appender!(CoffReloc[])();
    auto syms = appender!(CoffSymbol[])();
    ubyte[] strTab;

    MachFunc mf;
    mf.name = "func";
    uint[string] symbolIndices;
    symbolIndices["func"] = 0;
    emitter.encodeFunc(mf, text, relocs, syms, strTab, symbolIndices);

    Global global;
    global.name = "global";
    global.type = Type.i32();
    global.linkage = Linkage.internal;
    global.init = [1, 2];
    emitter.encodeGlobal(global, data, syms, strTab, false);

    emitter.addExtern("external", syms, strTab);
    emitter.addExtern("long_external_name", syms, strTab);

    assert(syms.data.length == 4);
    assert(syms.data[0].shortName[0 .. 4] == "func");
    assert(syms.data[0].shortName[4] == 0);
    assert(syms.data[0].section == 1);
    assert(syms.data[0].type_ == 0x20);
    assert(syms.data[0].storageClass == SYM_EXTERNAL);
    assert(syms.data[1].shortName[0 .. 6] == "global");
    assert(syms.data[1].section == 2);
    assert(syms.data[1].storageClass == SYM_STATIC);
    assert(syms.data[2].shortName[0 .. 8] == "external");
    assert(syms.data[2].section == 0);
    assert(syms.data[2].storageClass == SYM_EXTERNAL);
    assert(syms.data[3].zeroes == 0);
    assert(syms.data[3].strOff == 4);
    assert(strTab == cast(ubyte[])"long_external_name\0");
    assert(data.data == [1, 2, 0, 0]);
}

unittest
{
    auto mod = Module();
    mod.newFunc("answer", Type.i32());
    auto value = mod.funcs[0].newValue(Type.i32());
    mod.funcs[0].entry.instrs ~= Instr(op: Op.const_, dst: value,
            type: Type.i32(), imm: Const.int_(42));
    mod.funcs[0].entry.instrs ~= Instr(op: Op.ret, uses: [value]);

    auto output = appender!(ubyte[])();
    auto target = new X86Target();
    auto emitter = new CoffEmitter();
    emitter.emit(mod, target, output);

    assert(output.data.length > CoffHeader.sizeof + 2 * SectionHeader.sizeof);
    assert(output.data[0] == 0x4C);
    assert(output.data[1] == 0x01);
    assert(output.data[2] == 2);
    assert(output.data[3] == 0);
    assert(output.data[100] == 0x55);
    assert(output.data.canFind(0xB8));
    assert(output.data[52] == 0);
}

unittest
{
    auto mod = Module();
    mod.newFunc("product", Type.i64(),
            [Param(Type.i64(), "left"), Param(Type.i64(), "right")]);
    auto result = mod.funcs[0].newValue(Type.i64());
    mod.funcs[0].entry.instrs ~= Instr(op: Op.mul, dst: result,
            type: Type.i64(), uses: [Value(0), Value(1)]);
    mod.funcs[0].entry.instrs ~= Instr(op: Op.ret, uses: [result]);

    auto output = appender!(ubyte[])();
    auto target = new X86Target();
    auto emitter = new CoffEmitter();
    emitter.emit(mod, target, output);

    assert(output.data[0] == 0x4C);
    assert(output.data[1] == 0x01);
    assert(output.data[52] == 1);
    assert(output.data[12] == 2);
    assert(output.data[13] == 0);
}

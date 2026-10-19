module smedja.emit.coff;

import smedja.ir;
import smedja.arch;
import smedja.emit;
import std.array : Appender, appender;
import std.string : representation;

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

private void put(T)(ref Appender!(ubyte[]) buf, T val)
{
    buf.put((cast(ubyte*)&val)[0 .. T.sizeof]);
}

private void write(T)(ref Appender!(ubyte[]) buf, auto ref T val) {
    buf.put((cast(ubyte*) &val)[0 .. T.sizeof]);
}

private void putName(ref Appender!(ubyte[]) buf, string name, ref ubyte[] strTab)
{
    CoffSymbol sym;
    if (name.length <= 8)
    {
        sym.shortName[0 .. name.length] = name[];
    }
    else
    {
        sym.zeroes = 0;
        sym.strOff = cast(uint) strTab.length;
        strTab ~= cast(ubyte[]) name ~ 0;
    }
    write(buf, sym.shortName);
}

private char[8] sectionName(string s)
{
    char[8] r = 0;
    auto n = s.length > 8 ? 8 : s.length;
    r[0 .. n] = s[0 .. n];
    return r;
}

final class CoffEmitter : Emitter
{
    private ushort machine_;
    private ushort relocType32_;

    this(bool x86_64 = true)
    {
        machine_ = x86_64 ? MACHINE_AMD64 : MACHINE_I386;
        relocType32_ = x86_64 ? REL_AMD64_REL32 : REL_I386_REL32;
    }

    void emit(ref Module mod, Target target, ref Appender!(ubyte[]) out_)
    {
        auto text = appender!(ubyte[])();
        auto data = appender!(ubyte[])();
        auto relocs = appender!(CoffReloc[])();
        auto syms = appender!(CoffSymbol[])();
        ubyte[] strTab = [0]; // starts with null byte

        foreach (ref f; mod.funcs)
        {
            MachFunc mf = target.selectAndAlloc(f);
            encodeFunc(mf, text, relocs, syms, strTab, cast(uint) syms.data.length);
        }

        foreach (ref g; mod.globals)
            encodeGlobal(g, data, syms, strTab);

        foreach (ref f; mod.externs)
            addExtern(f.name, syms, strTab);

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
            relocOff: cast(uint)(textOff + text.data.length),
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
        uint symIdx)
    {
        CoffSymbol sym;
        if (mf.name.length <= 8)
        {
            sym.shortName[0 .. mf.name.length] = mf.name[];
        }
        else
        {
            sym.zeroes = 0;
            sym.strOff = cast(uint) strTab.length;
            strTab ~= cast(ubyte[]) mf.name ~ 0;
        }
        sym.value = cast(uint) text.data.length;
        sym.section = 1;
        sym.type_ = 0x20;
        sym.storageClass = SYM_EXTERNAL;
        syms.put(sym);

        foreach (ref b; mf.blocks)
            foreach (ref i; b.instrs)
                text.put(cast(ubyte) 0x90);
    }

    private void encodeGlobal(ref Global g,
        ref Appender!(ubyte[]) data,
        ref Appender!(CoffSymbol[]) syms,
        ref ubyte[] strTab)
    {
        CoffSymbol sym;
        if (g.name.length <= 8)
        {
            sym.shortName[0 .. g.name.length] = g.name[];
        }
        else
        {
            sym.zeroes = 0;
            sym.strOff = cast(uint) strTab.length;
            strTab ~= cast(ubyte[]) g.name ~ 0;
        }
        sym.value = cast(uint) data.data.length;
        sym.section = 2;
        sym.storageClass = g.linkage == Linkage.internal ? SYM_STATIC : SYM_EXTERNAL;
        syms.put(sym);

        if (g.init.length)
            write(data, g.init);
        else
            foreach (_; 0 .. g.type.width)
                write(data, cast(ubyte) 0);
    }

    private void addExtern(string name,
        ref Appender!(CoffSymbol[]) syms,
        ref ubyte[] strTab)
    {
        CoffSymbol sym;
        if (name.length <= 8)
        {
            sym.shortName[0 .. name.length] = name[];
        }
        else
        {
            sym.zeroes = 0;
            sym.strOff = cast(uint) strTab.length;
            strTab ~= cast(ubyte[]) name ~ 0;
        }
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
    ubyte[] strTab = [0];

    MachFunc mf;
    mf.name = "func";
    emitter.encodeFunc(mf, text, relocs, syms, strTab, 0);

    Global global;
    global.name = "global";
    global.type = Type.i32();
    global.linkage = Linkage.internal;
    emitter.encodeGlobal(global, data, syms, strTab);

    emitter.addExtern("external", syms, strTab);

    assert(syms.data.length == 3);
    assert(syms.data[0].shortName[0 .. 4] == "func");
    assert(syms.data[0].section == 1);
    assert(syms.data[0].type_ == 0x20);
    assert(syms.data[0].storageClass == SYM_EXTERNAL);
    assert(syms.data[1].shortName[0 .. 6] == "global");
    assert(syms.data[1].section == 2);
    assert(syms.data[1].storageClass == SYM_STATIC);
    assert(syms.data[2].shortName[0 .. 8] == "external");
    assert(syms.data[2].section == 0);
    assert(syms.data[2].storageClass == SYM_EXTERNAL);
    assert(data.data == [0, 0, 0, 0]);
}

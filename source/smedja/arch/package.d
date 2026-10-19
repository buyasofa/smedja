module smedja.arch;

public import smedja.arch.x86;
public import smedja.arch.x86_64;
public import smedja.arch.arm64;

import smedja.ir;

alias RegId = ubyte;

enum RegClass : ubyte
{
    gpr,
    fpr,
    vec,
}

struct Reg
{
    RegId id;
    RegClass cls;
    ubyte width;
    string name;
}

struct RegSet
{
    Reg[] regs;
    RegId stackPtr;
    RegId framePtr;

    RegId[] calleeSaved;
    RegId[] callerSaved;
}

enum CallingConv : ubyte
{
    sysv,
    win64,
    cdecl,
    stdcall,
}

struct Allocation
{
    enum Kind : ubyte
    {
        reg,
        stack,
        split
    }

    Kind kind;
    RegId reg;
    uint offset;
    Type type;
    RegId secondReg;
}

interface ABI
{
    CallingConv conv();
    Allocation[] classify(Type[] params);
    Allocation returnSlot(Type ret);
    uint shadowSpace();
}

struct MachLocation
{
    enum Kind : ubyte
    {
        reg,
        spill
    }

    Kind kind;
    RegId reg;
    int offset;
}

struct MachInstr
{
    ushort opcode;
    MachLocation dst;
    MachLocation[] srcs;
    string comment;
}

struct MachBlock {
    string       label;
    MachInstr[]  instrs;
}

struct MachFunc {
    string      name;
    MachBlock[] blocks;
    uint        frameSize;
    ubyte[]     code;
    MachReloc[] relocs;
}

struct MachReloc {
    uint   offset;
    string symbol;
    ushort type;
}

interface Target {
    string name();

    uint pointerSize();
    uint stackAlign();

    RegSet  registers();
    ABI     abi(CallingConv cc);
    
    MachFunc selectAndAlloc(ref Func f);
}
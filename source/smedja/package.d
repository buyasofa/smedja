module smedja;

public import smedja.ir;
public import smedja.builder;
public import smedja.opt;
public import smedja.analysis;

public import smedja.arch;
public import smedja.emit;
public import smedja.errors;

deprecated("use TargetNotImplementedException")
alias TargetArchNotDone = TargetNotImplementedException;

enum Arch : ubyte
{
    x86_64,
    x86,
    arm64
}

enum ObjFormat : ubyte
{
    elf,
    coff,
    raw
}

enum EmitFormat : ubyte
{
    obj,
    c
}

Target targetFor(Arch arch)
{
    final switch (arch)
    {
        case Arch.x86_64:
            return new X86_64Target();
        case Arch.x86:
            return new X86Target();
        case Arch.arm64:
            throw new TargetNotImplementedException(
                    "arm64 target is not implemented");
    }
}

unittest
{
    import std.exception : assertThrown;

    assert(targetFor(Arch.x86).name == "x86-windows");
    assert(targetFor(Arch.x86_64).name == "x86_64-windows");
    assertThrown!TargetNotImplementedException(targetFor(Arch.arm64));
}
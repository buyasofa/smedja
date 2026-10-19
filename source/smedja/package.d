module smedja;

public import smedja.ir;
public import smedja.builder;
public import smedja.opt;
public import smedja.analysis;

public import smedja.arch;
public import smedja.emit;

enum Arch : ubyte {
    x86_64, // not supported yet
    x86,
    arm64 // not supported yet
}

enum ObjFormat : ubyte {
    elf,
    coff,
    raw
}

enum EmitFormat : ubyte {
    obj,
    c
}

class TargetArchNotDone : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

Target targetFor(Arch arch) {
    final switch (arch) {
        case Arch.x86_64: throw new TargetArchNotDone("x86_64 target not implemented yet");
        case Arch.x86:    return new X86Target();
        case Arch.arm64:  throw new TargetArchNotDone("arm64 target not implemented yet");
    }
}
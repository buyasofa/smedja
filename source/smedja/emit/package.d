module smedja.emit;

public import smedja.emit.elf;
public import smedja.emit.coff;
public import smedja.emit.c;

public import smedja.emit.pdb;
public import smedja.emit.dwarf;


import smedja.ir;
import smedja.arch;
import std.array : Appender;

interface Emitter {
    void emit(ref Module mod, Target target, ref Appender!(ubyte[]) out_);
}
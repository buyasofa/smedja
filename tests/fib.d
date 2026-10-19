import smedja;
import std.array : appender;
import std.file : exists, mkdirRecurse, remove, rmdir, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : execute, thisProcessID;
import std.stdio : stdout;

void main()
{
    auto mod = Module();
    mod.name = "fib";
    Type[] formatFields;
    foreach (_; cast(ubyte[])"fib(%d) = %d\n\0")
        formatFields ~= Type.i8();
    mod.globals ~= Global("fib_format",
            Type.struct_("fib_format_t", formatFields), Linkage.internal,
            cast(ubyte[])"fib(%d) = %d\n\0");
    mod.newExtern("_printf", Type.i32(),
            [Type.ptr(), Type.i32(), Type.i32()]);
    mod.newFunc("fib", Type.i32(), [Param(Type.i32(), "n")]);

    auto func = &mod.funcs[0];
    auto entry = 0u;
    auto loop = cast(uint) func.blocks.length;
    func.newBlock("loop");
    auto body = cast(uint) func.blocks.length;
    func.newBlock("body");
    auto done = cast(uint) func.blocks.length;
    func.newBlock("done");

    auto zero = func.newValue(Type.i32());
    auto one = func.newValue(Type.i32());
    auto index = func.newValue(Type.i32());
    auto previous = func.newValue(Type.i32());
    auto current = func.newValue(Type.i32());
    auto condition = func.newValue(Type.bool_());
    auto nextCurrent = func.newValue(Type.i32());
    auto nextIndex = func.newValue(Type.i32());

    func.blocks[entry].instrs ~= Instr(op: Op.const_, dst: zero,
            type: Type.i32(), imm: Const.int_(0));
    func.blocks[entry].instrs ~= Instr(op: Op.const_, dst: one,
            type: Type.i32(), imm: Const.int_(1));
    func.blocks[entry].instrs ~= Instr(op: Op.br, target: loop);

    func.blocks[loop].instrs ~= Instr(op: Op.phi, dst: index,
            type: Type.i32(), phiEdges: [
                PhiEdge(zero, entry), PhiEdge(nextIndex, body)
            ]);
    func.blocks[loop].instrs ~= Instr(op: Op.phi, dst: previous,
            type: Type.i32(), phiEdges: [
                PhiEdge(zero, entry), PhiEdge(current, body)
            ]);
    func.blocks[loop].instrs ~= Instr(op: Op.phi, dst: current,
            type: Type.i32(), phiEdges: [
                PhiEdge(one, entry), PhiEdge(nextCurrent, body)
            ]);
    func.blocks[loop].instrs ~= Instr(op: Op.icmp, dst: condition,
            type: Type.bool_(), pred: Pred.ult,
            uses: [index, func.params[0].value]);
    func.blocks[loop].instrs ~= Instr(op: Op.condbr, uses: [condition],
            target: body, altTarget: done);

    func.blocks[body].instrs ~= Instr(op: Op.add, dst: nextCurrent,
            type: Type.i32(), uses: [previous, current]);
    func.blocks[body].instrs ~= Instr(op: Op.add, dst: nextIndex,
            type: Type.i32(), uses: [index, one]);
    func.blocks[body].instrs ~= Instr(op: Op.br, target: loop);
    auto formatAddress = func.newValue(Type.ptr());
    func.blocks[done].instrs ~= Instr(op: Op.const_, dst: formatAddress,
            type: Type.ptr(), symbol: "fib_format");
    func.blocks[done].instrs ~= Instr(op: Op.call, type: Type.i32(),
            symbol: "_printf",
            uses: [formatAddress, func.params[0].value, previous]);
    func.blocks[done].instrs ~= Instr(op: Op.ret, uses: [previous]);

    auto object = appender!(ubyte[])();
    auto emitter = new CoffEmitter();
    auto target = new X86Target();
    emitter.emit(mod, target, object);

    auto work = buildPath(tempDir, format("smedja-fib-%d", thisProcessID));
    mkdirRecurse(work);
    scope (exit)
    {
        foreach (name; [
                "fib.obj", "entry.s", "entry.obj", "fib.exe",
                "msvcrt.def", "libmsvcrt.a"
            ])
        {
            auto path = buildPath(work, name);
            if (exists(path))
                remove(path);
        }
        if (exists(work))
            rmdir(work);
    }

    auto objectPath = buildPath(work, "fib.obj");
    auto sourcePath = buildPath(work, "entry.s");
    auto startupPath = buildPath(work, "entry.obj");
    auto executablePath = buildPath(work, "fib.exe");
    auto importDefPath = buildPath(work, "msvcrt.def");
    auto importLibraryPath = buildPath(work, "libmsvcrt.a");
    write(objectPath, object.data);
    write(sourcePath,
            ".text\n" ~
            ".globl _entry\n" ~
            ".extern fib\n" ~
            "_entry:\n" ~
            "  pushl $10\n" ~
            "  calll fib\n" ~
            "  addl $4, %esp\n" ~
            "  retl\n");

    auto assemble = execute([
        "clang", "-target", "i686-w64-windows-gnu", "-c", sourcePath,
        "-o", startupPath
    ]);
    if (assemble.status)
        throw new Exception("clang failed: " ~ assemble.output);

    write(importDefPath, "LIBRARY msvcrt.dll\nEXPORTS\n  printf\n");
    auto importLibrary = execute([
        "llvm-dlltool", "-m", "i386", "-d", importDefPath,
        "-l", importLibraryPath
    ]);
    if (importLibrary.status)
        throw new Exception("dlltool failed: " ~ importLibrary.output);

    auto link = execute([
        "ld", "-mi386pe", "--subsystem", "console", "--entry", "_entry",
        "-o", executablePath, objectPath, startupPath, importLibraryPath
    ]);
    if (link.status)
        throw new Exception("linker failed: " ~ link.output);

    auto run = execute([executablePath]);
    if (run.status < 0)
        throw new Exception(format("Fibonacci executable failed with status %d",
                run.status));
    stdout.write(run.output);
}

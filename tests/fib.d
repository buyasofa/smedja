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

    auto builder = IRBuilder(mod.funcs[0]);
    auto entry = builder.currentBlock;
    auto loop = builder.newBlock("loop");
    auto body = builder.newBlock("body");
    auto done = builder.newBlock("done");
    auto index = builder.newValue(Type.i32());
    auto previous = builder.newValue(Type.i32());
    auto current = builder.newValue(Type.i32());
    auto nextCurrent = builder.newValue(Type.i32());
    auto nextIndex = builder.newValue(Type.i32());

    auto zero = builder.intConstant(Type.i32(), 0);
    auto one = builder.intConstant(Type.i32(), 1);
    builder.branch(loop);

    builder.positionAt(loop);
    builder.phi(index,
            [PhiEdge(zero, entry), PhiEdge(nextIndex, body)]);
    builder.phi(previous,
            [PhiEdge(zero, entry), PhiEdge(current, body)]);
    builder.phi(current,
            [PhiEdge(one, entry), PhiEdge(nextCurrent, body)]);
    auto condition = builder.compare(Pred.ult, index, builder.param(0));
    builder.condBranch(condition, body, done);

    builder.positionAt(body);
    builder.binaryInto(nextCurrent, Op.add, previous, current);
    builder.binaryInto(nextIndex, Op.add, index, one);
    builder.branch(loop);

    builder.positionAt(done);
    auto formatAddress = builder.symbol("fib_format");
    builder.call("_printf", Type.i32(),
            [formatAddress, builder.param(0), previous]);
    builder.ret(previous);

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

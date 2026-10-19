module tests.test_support;

import smedja;
import std.array : appender;
import std.file : copy, exists, mkdirRecurse, remove, rmdir, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : execute, thisProcessID;
import std.stdio : writeln;

string emitWindowsExe(ref Module mod, string name, string targetName,
        long[] arguments = [], bool x64 = false, bool importsPrintf = false)
{
    Func targetFunc;
    bool found;
    foreach (func; mod.funcs)
        if (func.name == targetName)
        {
            targetFunc = func;
            found = true;
            break;
        }
    if (!found)
        throw new Exception(format("function '%s' was not found", targetName));
    if (arguments.length != targetFunc.params.length)
        throw new Exception(format("function '%s' expects %d arguments",
                targetName, targetFunc.params.length));

    auto entryName = x64 ? "entry" : "_entry";
    mod.newFunc(entryName, targetFunc.retType);
    auto builder = IRBuilder(mod.funcs[$ - 1]);
    Value[] values;
    foreach (index, value; arguments)
    {
        auto type = targetFunc.params[index].type;
        if (!type.isInt && type.kind != TypeKind.bool_)
            throw new Exception("test entry arguments must be integers");
        values ~= builder.intConstant(type, value);
    }
    auto result = builder.call(targetName, targetFunc.retType, values);
    builder.ret(result);

    auto object = appender!(ubyte[])();
    auto target = x64 ? cast(Target) new X86_64Target() : new X86Target();
    (new CoffEmitter(x64)).emit(mod, target, object);

    auto work = buildPath(tempDir, format("smedja-%s-%d", name, thisProcessID));
    mkdirRecurse(work);
    auto objectPath = buildPath(work, name ~ ".obj");
    auto executablePath = buildPath(work, name ~ ".exe");
    auto importDefPath = buildPath(work, "msvcrt.def");
    auto importLibraryPath = buildPath(work, "libmsvcrt.a");
    scope (exit)
    {
        foreach (path; [
                objectPath, executablePath,
                importDefPath, importLibraryPath
            ])
            if (exists(path))
                remove(path);
        if (exists(work))
            rmdir(work);
    }

    write(objectPath, object.data);
    string[] linkInputs = [objectPath];
    if (importsPrintf)
    {
        write(importDefPath, "LIBRARY msvcrt.dll\nEXPORTS\n  printf\n");
        auto importLibrary = execute([
            "llvm-dlltool", "-m", "i386", "-d", importDefPath,
            "-l", importLibraryPath
        ]);
        if (importLibrary.status)
            throw new Exception("llvm-dlltool failed: " ~ importLibrary.output);
        linkInputs ~= importLibraryPath;
    }

    auto outputDir = buildPath("tests", "bin");
    mkdirRecurse(outputDir);
    auto outputPath = buildPath(outputDir, name ~ ".exe");
    auto linkArgs = x64
        ? ["ld", "-mi386pep", "--subsystem", "console", "--entry", "entry"]
        : ["ld", "-mi386pe", "--subsystem", "console", "--entry", "_entry"];
    linkArgs ~= "-o";
    linkArgs ~= executablePath;
    linkArgs ~= linkInputs;
    auto link = execute(linkArgs);
    if (link.status)
        throw new Exception("linker failed: " ~ link.output);

    copy(executablePath, outputPath);
    writeln("generated ", outputPath);
    return outputPath;
}

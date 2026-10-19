import smedja;
import test_support : emitWindowsExe;

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

    emitWindowsExe(mod, "fib", "fib", [10],
            false, true);
}

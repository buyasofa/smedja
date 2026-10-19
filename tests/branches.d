import smedja;
import test_support : emitWindowsExe;

void main()
{
    auto mod = Module();
    mod.newFunc("select", Type.i32(), [Param(Type.i32(), "condition")]);
    auto ir = IRBuilder(mod.funcs[0]);
    auto yes = ir.newBlock("yes");
    auto no = ir.newBlock("no");
    auto zero = ir.intConstant(Type.i32(), 0);
    auto positive = ir.intConstant(Type.i32(), 42);
    auto negative = ir.intConstant(Type.i32(), 1);
    auto condition = ir.compare(Pred.ne, ir.param(0), zero);
    ir.condBranch(condition, yes, no);

    ir.positionAt(yes);
    ir.ret(positive);
    ir.positionAt(no);
    ir.ret(negative);

    emitWindowsExe(mod, "branches", "select", [1]);
}

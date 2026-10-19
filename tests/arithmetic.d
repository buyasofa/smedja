import smedja;
import test_support : emitWindowsExe;

void main()
{
    auto mod = Module();
    mod.newFunc("calculate", Type.i32());
    auto ir = IRBuilder(mod.funcs[0]);
    auto six = ir.intConstant(Type.i32(), 6);
    auto seven = ir.intConstant(Type.i32(), 7);
    auto answer = ir.mul(six, seven);
    ir.ret(answer);

    emitWindowsExe(mod, "arithmetic", "calculate");
}

import smedja;
import test_support : emitWindowsExe;

void main()
{
    auto mod = Module();
    mod.newFunc("product", Type.i64(),
            [Param(Type.i64(), "lhs"), Param(Type.i64(), "rhs")]);
    auto ir = IRBuilder(mod.funcs[0]);
    auto product = ir.mul(ir.param(0), ir.param(1));
    ir.ret(product);

    emitWindowsExe(mod, "win64", "product", [6, 7], true);
}

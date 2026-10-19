# smedja

a small compiler backend written in D. still a work in progress.

## goals

- generate code for a few targets
- keep the IR small

## non-goals

- support every platform
- be a full compiler

## ir

```d
mod.newFunc("sum", Type.i32(), [Param(Type.i32(), "a"), Param(Type.i32(), "b")]);
auto ir = IRBuilder(mod.funcs[0]);
auto sum = ir.add(ir.param(0), ir.param(1));
ir.ret(sum);
```

builder operations use UFCS. use `newValue` and `phi` for loop values; `emit` handles other instructions.

## license

[Boost Software License 1.0](LICENSE.txt)

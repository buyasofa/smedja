module smedja.analysis;

import smedja.ir;
import std.algorithm.searching : canFind;

struct ControlFlowGraph
{
    uint[][] predecessors;
    uint[][] successors;
    bool[] reachable;
    bool[][] dominators;

    bool dominates(uint dominator, uint block) const
    {
        return dominator < dominators.length &&
            block < dominators.length &&
            dominators[block][dominator];
    }
}

ControlFlowGraph analyzeCFG(ref Func func)
{
    auto count = cast(uint) func.blocks.length;
    auto cfg = ControlFlowGraph(new uint[][](count), new uint[][](count),
            new bool[](count), new bool[][](count));
    if (!count)
        return cfg;

    foreach (index, block; func.blocks)
    {
        if (block.id != index)
            throw new Exception("basic block ids must match their function indices");
        if (!block.instrs.length)
            continue;

        auto terminator = block.instrs[$ - 1];
        final switch (terminator.op)
        {
        case Op.br:
            addEdge(cfg, cast(uint) index, terminator.target);
            break;
        case Op.condbr:
            if (!terminator.uses.length)
                throw new Exception("conditional branch requires a condition value");
            addEdge(cfg, cast(uint) index, terminator.target);
            addEdge(cfg, cast(uint) index, terminator.altTarget);
            break;
        case Op.const_, Op.add, Op.sub, Op.mul, Op.sdiv, Op.udiv,
             Op.srem, Op.urem, Op.fadd, Op.fsub, Op.fmul, Op.fdiv,
             Op.and_, Op.or_, Op.xor_, Op.shl, Op.ashr, Op.lshr,
             Op.icmp, Op.fcmp, Op.sext, Op.zext, Op.trunc, Op.sitofp,
             Op.uitofp, Op.fptosi, Op.fptoui, Op.bitcast, Op.alloca,
             Op.load, Op.store, Op.gep, Op.ret, Op.unreachable, Op.call,
             Op.phi:
            break;
        }
    }

    uint[] worklist = [0];
    cfg.reachable[0] = true;
    while (worklist.length)
    {
        auto block = worklist[$ - 1];
        worklist.length -= 1;
        foreach (successor; cfg.successors[block])
        {
            if (!cfg.reachable[successor])
            {
                cfg.reachable[successor] = true;
                worklist ~= successor;
            }
        }
    }

    foreach (block; 0 .. count)
    {
        cfg.dominators[block] = new bool[](count);
        if (block == 0)
            cfg.dominators[block][0] = true;
        else if (cfg.reachable[block])
            foreach (candidate; 0 .. count)
                cfg.dominators[block][candidate] = cfg.reachable[candidate];
        else
            cfg.dominators[block][block] = true;
    }

    bool changed = true;
    while (changed)
    {
        changed = false;
        foreach (block; 1 .. count)
        {
            if (!cfg.reachable[block])
                continue;

            bool[] next = new bool[](count);
            bool hasReachablePredecessor;
            foreach (pred; cfg.predecessors[block])
            {
                if (!cfg.reachable[pred])
                    continue;
                if (!hasReachablePredecessor)
                {
                    next[] = cfg.dominators[pred][];
                    hasReachablePredecessor = true;
                }
                else
                {
                    foreach (candidate; 0 .. count)
                        next[candidate] &= cfg.dominators[pred][candidate];
                }
            }
            if (!hasReachablePredecessor)
                next[] = false;
            next[block] = true;
            if (next != cfg.dominators[block])
            {
                cfg.dominators[block] = next;
                changed = true;
            }
        }
    }

    return cfg;
}

private void addEdge(ref ControlFlowGraph cfg, uint from, uint to)
{
    if (to >= cfg.successors.length)
        throw new Exception("branch target is outside the function");
    if (!cfg.successors[from].canFind(to))
    {
        cfg.successors[from] ~= to;
        cfg.predecessors[to] ~= from;
    }
}

unittest
{
    auto func = Func();
    func.newBlock("entry");
    func.newBlock("left");
    func.newBlock("right");
    func.newBlock("join");
    func.newBlock("unreachable");
    func.blocks[0].instrs ~= Instr(op: Op.condbr, uses: [Value(0)], target: 1, altTarget: 2);
    func.blocks[1].instrs ~= Instr(op: Op.br, target: 3);
    func.blocks[2].instrs ~= Instr(op: Op.br, target: 3);
    func.blocks[3].instrs ~= Instr(op: Op.ret);
    func.blocks[4].instrs ~= Instr(op: Op.ret);

    auto cfg = analyzeCFG(func);
    assert(cfg.successors[0] == [1, 2]);
    assert(cfg.predecessors[3] == [1, 2]);
    assert(cfg.reachable == [true, true, true, true, false]);
    assert(cfg.dominates(0, 0));
    assert(cfg.dominates(0, 3));
    assert(!cfg.dominates(1, 3));
    assert(cfg.dominates(4, 4));
}

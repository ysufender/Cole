# Known Bugs

## Illegal Memory Access

Run the raylib demo. The output source.c is garbled when using a non-preserving allocator
such as c_allocator. This indicates there is some overwriting to freed memory when someone
else is holding a reference to the said memory.

## Compile Time Execution Problems

### Unable to Compile Non Compile Time Code

#### Steps to Reproduce

Compile the code below:

```rust
let func = fn (array: []mut u8) -> []mut u8 {
    array[array.len - 1] = 0;
    return array;
};

let main = fn (args: [][]u8) -> i32 {
    let a = func(args[1]);
    return 0;
};
```

#### Expected Output

```
info: Compilation settings:
        Input File  : main.cole
        Output File : test
        Working Dir : /home/joseph/Desktop/proj/Cole/test
        Max Errors  : 5
        Optimize    : O1
        Backend     : C
        Include Dirs: [/home/joseph/Desktop/proj/Cole/stdlib]
        Link Dirs   : []
        Libraries   : []

info: Compilation took 23 milliseconds.
info: Exited successfully.
```

#### Received Output

```
info: Compilation settings:
        Input File  : main.cole
        Output File : test
        Working Dir : /home/joseph/Desktop/proj/Cole/test
        Max Errors  : 5
        Optimize    : O1
        Backend     : C
        Include Dirs: [/home/joseph/Desktop/proj/Cole/stdlib]
        Link Dirs   : []
        Libraries   : []

error: COMPTIME FOLDER: Comptime execution is not possible in this context.
error: .... In /home/joseph/Desktop/proj/Cole/test/main.cole 2:11
error:     array[array.len - 1] = 0;
error:           ^^^^^
error: ........ Required from '/home/joseph/Desktop/proj/Cole/test/main.cole 7:9'
error:     let a = func(args[1]);
error:         ^
error: ........ Required from '/home/joseph/Desktop/proj/Cole/test/main.cole 6:5'
error: let main = fn (args: [][]u8) -> i32 {
error:     ^^^^

error: Compiler exited with code 159 <ComptimeNotPossible>
```

#### Stack Trace

```
/home/joseph/Desktop/proj/Cole/src/typechecker/comptime/folder.zig:100:9: 0x1325eca in eval (cole-debug)
        return Error.ComptimeNotPossible;
        ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:1015:61: 0x12941c1 in typecheckExpression (cole-debug)
        .FunctionDefinition, .Lambda => self.typecheckValue(try self.folder.eval(expressionPtr, maybeExpected), maybeExpected),
                                                            ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:2203:17: 0x12a58ec in typecheckBinary (cole-debug)
    const rhs = try self.typecheckExpression(ast.extra[extraPtr + 2], lhs);
                ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:999:5: 0x12942d0 in typecheckExpression (cole-debug)
    return switch (expr.type) {
    ^
/home/joseph/Desktop/proj/Cole/src/typechecker/lowerer.zig:1281:23: 0x12fa820 in indexing (cole-debug)
    const indexType = try self.typechecker.typecheckExpression(indexPtr, null);
                      ^
/home/joseph/Desktop/proj/Cole/src/typechecker/lowerer.zig:824:5: 0x128ec8f in expression (cole-debug)
    return switch (expr.type) {
    ^
/home/joseph/Desktop/proj/Cole/src/typechecker/lowerer.zig:533:21: 0x1347afa in assignment (cole-debug)
        break :expr try self.expression(vexpr, vt);
                    ^
/home/joseph/Desktop/proj/Cole/src/typechecker/lowerer.zig:317:74: 0x1333f59 in statement (cole-debug)
            if (ast.expressions.items(.type)[stmt.value] == .Assignment) try self.assignment(ast.expressions.items(.value)[stmt.value])
                                                                         ^
/home/joseph/Desktop/proj/Cole/src/typechecker/lowerer.zig:793:20: 0x13486fd in block (cole-debug)
        stmts[i] = try self.statement(ast.extra[@intCast(stmt)]);
                   ^
/home/joseph/Desktop/proj/Cole/src/typechecker/lowerer.zig:315:19: 0x1333d56 in statement (cole-debug)
        .Block => try self.block(stmt.value),
                  ^
/home/joseph/Desktop/proj/Cole/src/typechecker/comptime/folder.zig:342:17: 0x1333218 in evalFunction (cole-debug)
        .body = try self.typechecker.lowerer.statement(bodyPtr),
                ^
/home/joseph/Desktop/proj/Cole/src/typechecker/comptime/folder.zig:155:32: 0x132722d in eval (cole-debug)
        .FunctionDefinition => try self.evalFunction(exprPtr, expr.value),
                               ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:275:37: 0x130aebb in typecheckVariableDef (cole-debug)
            try self.typecheckValue(try self.folder.eval(decl.node, expected), expected)
                                    ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:1916:22: 0x126b188 in typecheckDecl (cole-debug)
    const declType = try switch (decl.kind) {
                     ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:1003:36: 0x1293bcd in typecheckExpression (cole-debug)
            const discoveredType = try self.typecheckDecl(decl, maybeExpected);
                                   ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:1532:21: 0x12d792a in typecheckCall (cole-debug)
    const lhsType = try self.typecheckExpression(ast.extra[extraPtr], null);
                    ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:999:5: 0x12942d0 in typecheckExpression (cole-debug)
    return switch (expr.type) {
    ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:277:13: 0x130afa1 in typecheckVariableDef (cole-debug)
            try self.typecheckExpression(decl.node, expected);
            ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:1916:22: 0x126b188 in typecheckDecl (cole-debug)
    const declType = try switch (decl.kind) {
                     ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:499:9: 0x134cabf in typecheckVarDefStatement (cole-debug)
    _ = try self.typecheckDecl(decl, try self.expectType(signature.type));
        ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:255:32: 0x134a6a3 in typecheckStatement (cole-debug)
        .VariableDefinition => try self.typecheckVarDefStatement(stmt.value),
                               ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:957:9: 0x1359c17 in typecheckBlock (cole-debug)
        try self.typecheckStatement(ast.extra[index], expected);
        ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:244:5: 0x134a791 in typecheckStatement (cole-debug)
    return switch (stmt.type) {
    ^
/home/joseph/Desktop/proj/Cole/src/typechecker/comptime/folder.zig:328:9: 0x1332eec in evalFunction (cole-debug)
        try self.typechecker.typecheckStatement(bodyPtr, returnType);
        ^
/home/joseph/Desktop/proj/Cole/src/typechecker/comptime/folder.zig:155:32: 0x132722d in eval (cole-debug)
        .FunctionDefinition => try self.evalFunction(exprPtr, expr.value),
                               ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:275:37: 0x130aebb in typecheckVariableDef (cole-debug)
            try self.typecheckValue(try self.folder.eval(decl.node, expected), expected)
                                    ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:1916:22: 0x126b188 in typecheckDecl (cole-debug)
    const declType = try switch (decl.kind) {
                     ^
/home/joseph/Desktop/proj/Cole/src/typechecker/typechecker.zig:225:22: 0x125526e in typecheck (cole-debug)
    const mainType = try self.typecheckDecl(mainPtr, entryPointID);
                     ^
/home/joseph/Desktop/proj/Cole/src/main.zig:128:21: 0x1209429 in innerMain (cole-debug)
    var loweredIR = try typechecker.typecheck(allocator);
                    ^
```

# Fixed Bugs

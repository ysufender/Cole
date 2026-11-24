## $open -- Comptime Bugs Again -- #64 -- @ysufender --

Sometimes, comptime paths error out for strictly-comptime values.

### Reproduction --

Try to compile the raylib demo.

### Expected --

Successful compilation.

### Received --

<pre><code>
error: COMPTIME FOLDER: Comptime execution is not possible in this context.
error: .... In /home/yusuf/proj/Cole/stdlib/extra/ini.cole 238:54
error:&emsp;&emsp;et new: mut []mut Section = allocator.alloc(Section)(initial).Ok;
error:&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;^^^^^^
error: ........ Required from '/home/yusuf/proj/Cole/stdlib/extra/ini.cole 237:13'
error:&emsp;pub let init = fn (allocator: Allocator) -> mut SectionList {
error:&emsp;&emsp;   ^^^^
error: ........ Required from '/home/yusuf/proj/Cole/stdlib/extra/ini.cole 104:9'
error:&emsp;let list = SectionList::init(allocator);
error:&emsp;&emsp;^^^
error: ........ Required from '/home/yusuf/proj/Cole/stdlib/extra/ini.cole 103:9'
error: pub let loadStream = fn (allocator: Allocator, stream: Stream::Input) -> INI::LoadResult {
error:&emsp;&emsp;^^^^^^^^^
error: ........ Required from '/home/yusuf/proj/Cole/stdlib/extra/ini.cole 60:9'
error: pub let loadFile = fn (allocator: Allocator, path: []u8) -> INI::LoadResult {
error:&emsp;&emsp;^^^^^^^
error: ........ Required from '/home/yusuf/proj/Cole/demo/raylib/main.cole 34:9'
error:&emsp;let _ini: mut any = INI::loadFile(C::Allocator, "demo/raylib/settings.ini");
error:&emsp;&emsp;^^^
error: ........ Required from '/home/yusuf/proj/Cole/demo/raylib/main.cole 33:5'
error: let main = fn (args: [][]u8) -> i32 {
error:&emsp;^^^^

/home/yusuf/proj/Cole/src/typechecker/comptime/folder.zig:154:9: 0x1425df4 in eval (cole-debug)
&emsp;   return Error.ComptimeNotPossible;
&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/comptime/folder.zig:441:32: 0x13d37c6 in determineComptimeReturnType (cole-debug)
&emsp;onst func = self.getValue(try self.eval(functionExpr, null)).Function;
&emsp;&emsp;&emsp;&emsp;&emsp;&emsp; ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1923:30: 0x13d33ed in typecheckCall (cole-debug)
&emsp;   if (func.isComptime) try self.folder.determineComptimeReturnType(func.returnType, ast.extra[extraPtr], args, func.argTypes)
&emsp;&emsp;&emsp;&emsp;&emsp&emsp;;
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1210:22: 0x138a3ee in typecheckExpression (cole-debug)
&emsp;&emsp;  .Call => try self.typecheckCall(expr.value, maybeExpected, expressionPtr),
&emsp;&emsp;&emsp;&emsp; ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1817:21: 0x13d179c in typecheckCall (cole-debug)
&emsp;onst lhsType = try self.typecheckExpression(ast.extra[extraPtr], null);
&emsp;&emsp;&emsp;&emsp;^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1210:22: 0x138a3ee in typecheckExpression (cole-debug)
&emsp;&emsp;  .Call => try self.typecheckCall(expr.value, maybeExpected, expressionPtr),
&emsp;&emsp;&emsp;&emsp; ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:2836:26: 0x138fdbd in typecheckDot (cole-debug)
&emsp;onst objectTypeID = try self.typecheckExpression(objectExprPtr, null);
&emsp;&emsp;&emsp;&emsp;&emsp;^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1230:21: 0x138a7d2 in typecheckExpression (cole-debug)
&emsp;&emsp;  .Dot => try self.typecheckDot(expr.value, expressionPtr),
&emsp;&emsp;&emsp;&emsp;^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:329:13: 0x1416475 in typecheckVariableDef (cole-debug)
&emsp;&emsp;  try self.typecheckExpression(decl.node, expected);
&emsp;&emsp;  ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:2498:22: 0x1410fe8 in typecheckDecl (cole-debug)
&emsp;onst declType = try switch (decl.kind) {
&emsp;&emsp;&emsp;&emsp; ^
/home/yusuf/proj/Cole/src/typechecker/lowerer.zig:2196:9: 0x136bb7a in identifier (cole-debug)
&emsp;   try self.typechecker.typecheckDecl(declPtr, null)
&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/lowerer.zig:1191:19: 0x133d7fb in expression (cole-debug)
&emsp;onst inner = try switch (expr.type) {
&emsp;&emsp;&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/lowerer.zig:516:21: 0x13f486a in assignment (cole-debug)
&emsp;   break :expr try self.expression(vexpr, vt);
&emsp;&emsp;&emsp;&emsp;^
/home/yusuf/proj/Cole/src/typechecker/lowerer.zig:300:74: 0x132d777 in statement (cole-debug)
&emsp;&emsp;  if (ast.expressions.items(.type)[stmt.value] == .Assignment) try self.assignment(ast.expressions.items(.value)[stmt.value])
&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/lowerer.zig:1164:20: 0x13f5105 in block (cole-debug)
&emsp;   stmts[i] = try self.statement(ast.extra[@intCast(stmt)]);
&emsp;&emsp;&emsp&emsp;;
/home/yusuf/proj/Cole/src/typechecker/lowerer.zig:298:19: 0x132d574 in statement (cole-debug)
&emsp;   .Block => try self.block(stmt.value),
&emsp;&emsp;&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:2357:17: 0x130d08a in lowerFunction (cole-debug)
&emsp;unc.body = try self.lowerer.statement(func.body);
&emsp;&emsp;&emsp; ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:2547:9: 0x14117a4 in typecheckDecl (cole-debug)
&emsp;   try self.lowerFunction(func, decl.token);
&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1614:13: 0x13cee53 in typecheckScoping (cole-debug)
&emsp;&emsp;  return self.typecheckDecl(decl, null);
&emsp;&emsp;  ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1211:25: 0x138a460 in typecheckExpression (cole-debug)
&emsp;&emsp;  .Scoping => try self.typecheckScoping(expressionPtr),
&emsp;&emsp;&emsp;&emsp&emsp;;
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1817:21: 0x13d179c in typecheckCall (cole-debug)
&emsp;onst lhsType = try self.typecheckExpression(ast.extra[extraPtr], null);
&emsp;&emsp;&emsp;&emsp;^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1210:22: 0x138a3ee in typecheckExpression (cole-debug)
&emsp;&emsp;  .Call => try self.typecheckCall(expr.value, maybeExpected, expressionPtr),
&emsp;&emsp;&emsp;&emsp; ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:329:13: 0x1416475 in typecheckVariableDef (cole-debug)
&emsp;&emsp;  try self.typecheckExpression(decl.node, expected);
&emsp;&emsp;  ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:2498:22: 0x1410fe8 in typecheckDecl (cole-debug)
&emsp;onst declType = try switch (decl.kind) {
&emsp;&emsp;&emsp;&emsp; ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:561:9: 0x13fa292 in typecheckVarDefStatement (cole-debug)
&emsp; = try self.typecheckDecl(decl, try self.expectType(signature.type));
&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:313:32: 0x13f8f57 in typecheckStatement (cole-debug)
&emsp;   .VariableDefinition => try self.typecheckVarDefStatement(stmt.value),
&emsp;&emsp;&emsp;&emsp;&emsp;&emsp; ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1152:9: 0x1408fc7 in typecheckBlock (cole-debug)
&emsp;   try self.typecheckStatement(ast.extra[index], expected);
&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:301:5: 0x13f8fc0 in typecheckStatement (cole-debug)
&emsp;eturn switch (stmt.type) {
&emsp;
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:2338:9: 0x130cccc in lowerFunction (cole-debug)
&emsp;   try self.typecheckStatement(func.body, returnType);
&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:2547:9: 0x14117a4 in typecheckDecl (cole-debug)
&emsp;   try self.lowerFunction(func, decl.token);
&emsp;   ^
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1206:40: 0x138a30a in typecheckExpression (cole-debug)
&emsp;&emsp;&emsp; const discoveredType = try self.typecheckDecl(decl, maybeExpected);
&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp&emsp;;
/home/yusuf/proj/Cole/src/typechecker/typechecker.zig:1817:21: 0x13d179c in typecheckCall (cole-debug)
&emsp;onst lhsType = try self.typecheckExpression(ast.extra[extraPtr], null);
&emsp;&emsp;&emsp;&emsp;^
</code></pre>

## $open -- Safety Checks on Debug Builds -- #62 -- @ysufender --

Lowering paths lack safety checks on debug builds.

### Reproduction --

...

### Expected --

...

### Received --

...

## $open -- QBE Backend -- #61 -- @ysufender --

Type name conversion causes errors.

### Reproduction --

<pre><code>
import std::memory::allocator;
import std::c;

let f = fn (a: std::memory::allocator::Allocator) -> i32 { let x = a.alloc(u8)(4).Ok; return 0; };

let main = fn (args: [][]u8) -> i32 {
&emsp;let a: mut any = f(std::c::Allocator);
&emsp;return 0;
};
</code></pre>

### Expected --

Successful compilation.

### Received --

<pre><code>
error: Missing type name for type ID 32 (Void)
error: This is a compiler bug, a part of impossible branch has been reached. Please inform the authors about it.
/home/yusuf/proj/Cole/src/codegen/qbe/jair/builder.zig:644:9: 0x1291fe7 in typeName (cole-debug)
&emsp;emsp;eturn Error.ShouldBeImpossible;
&emsp;   ^
/home/yusuf/proj/Cole/src/codegen/qbe/jair/builder.zig:718:36: 0x1294365 in typeName (cole-debug)
&emsp;&emsp;&emsp; self.strings.items[try self.typeName(ptr.child)],
&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;&emsp;^
/home/yusuf/proj/Cole/src/codegen/qbe/jair/builder.zig:841:25: 0x12bff5d in convertType (cole-debug)
&emsp;&emsp;&emsp; .name = try self.typeName(id),
&emsp;&emsp;&emsp;&emsp&emsp;;
/home/yusuf/proj/Cole/src/codegen/qbe/jair/builder.zig:80:13: 0x1289698 in build (cole-debug)
&emsp;   _ = try self.convertType(@intCast(id));
&emsp;&emsp;  ^
/home/yusuf/proj/Cole/src/main.zig:161:24: 0x123eac3 in innerMain (cole-debug)
&emsp;&emsp;  var jair = try jairBuilder.build();
&emsp;&emsp;&emsp;&emsp;   ^
error: Compiler exited with code 228 <ShouldBeImpossible>
</code></pre>


## $open -- Helper Functions for SOA Ease of Use -- #57 -- @ysufender --

The project uses SOA intensively to reduce memory footprint and increase cache hits. For this
reason, almost every unit of the project uses flattened SOA instead of classic unions (see <a href='https://codeberg.org/ysufender/JASL/src/commit/d950cbde5696f8246efd765418086ed7767d81f8/src/parser/parser.zig#L186'>parser.zig</a>).
The problem with this approach is that it is tedious to write and read the structures (see <a href='https://codeberg.org/ysufender/JASL/src/commit/d950cbde5696f8246efd765418086ed7767d81f8/src/typechecker/typechecker.zig#L619'>typechecker.zig</a>).
Helper functions to do it inline would be nice.

### Reproduction --

...

### Expected --

...

### Received --

...

## $open -- Unit Testing -- #56 -- @casimirknight --

The compiler is currently tested using the Testy framework, which is a custom stdout comparator
written in Lua. Some of the parts of the compiler (mainly the Lexer) can still be unit tested,
otherwise the Testy tests must be improved.

### Reproduction --

<ul>
    <li>TC_10 — Call `Token.errIdentifier` on a token in the final line of a file without a trailing newline.</li>
    <li>TC_12 — Call `Token.toString` on the `let` keyword at line 10000, column 1.</li>
</ul>

### Expected --

<ul>
    <li>TC_10 — The full final line.</li>
    <li>TC_12 — <code>\<Let: let at (10000:1)\></code>.</li>
</ul>

### Received --

<ul>
    <li>TC_10 — An empty string.</li>
    <li>TC_12 — Token formatting panics because the buffer is too small.</li>
</ul>

## $open -- README and Other Documentation Files -- #55 -- @ysufender --

The project lacks documentation, severely. For both the users' and the contributors' sakes, some documentation should be present.

### Reproduction --

...

### Expected --

...

### Received --

...

## $open -- Improve STDLib -- #54 -- @ysufender --

The standard library is lacking, we must improve it.

### Reproduction --

...

### Expected --

- [x] Allocator interface
- [x] Streaming interfaces
- [] Custom buffered IO
- [] Strong typed memory functions (memcpy etc.)

### Received --

...

## $open -- Illegal Memory Access -- #31 -- @ysufender --

When using a non-preserving allocator, the output C code is garbled with trash data.

### Reproduction --

Modify the `main.zig` so that it uses a non-preserving allocator. Then run the raylib demo.

### Expected --

Successful compilation and run.

### Received --

Garbled out parts in the generated C files.

## $closed -- Unable to Compile Non Compile Time Code -- #38 -- @ysufender --
## $closed -- Switch Captures Referencing -- #39 -- @ysufender --
## $closed -- Slice Construction Mixup -- #40 -- @ysufender --
## $closed -- TypeInfo Problems -- #41 -- @ysufender --
## $closed -- Problems With Compile Time Execution -- #42 -- @ysufender --
## $closed -- Comptime Caching -- #43 -- @ysufender --
## $closed -- Initializer List Typechecking Mismatch -- #44 -- @ysufender --
## $closed -- Scoped Definition Access -- #45 -- @ysufender --
## $closed -- Major Performance Issues -- #46 -- @ysufender --
## $closed -- Comptime Definition Lowering -- #47 -- @ysufender --
## $closed -- Switch Capture Folding -- #48 -- @ysufender --
## $closed -- Extern Structs Keep Getting Codegen'd -- #49 -- @ysufender --
## $closed -- Comptime Recursion Bug -- #50 -- @ysufender --
## $closed -- Type Rebinding Bug -- #51 -- @ysufender --
## $closed -- "this" Builtin Bugs -- #52 -- @ysufender --
## $closed -- Generic Definitions Are Last-Call-Win -- #53 -- @ysufender --
## $closed -- Single Field Union Construction Bug -- #58 -- @ysufender --
## $closed -- External C Array Conversion -- #59 -- @ysufender --
## $closed -- Type Deduplication Problems -- #60 -- @ysufender --
## $closed -- Proper Inline Code Syntax -- #63 -- @ysufender --

## $open -- Undefined Aggregate Construction Bug -- #65 -- @ysufender --

When constructing undefined values of aggregate types, the compiler complains about
not being able to infer the type of the undefined value.

### Reproduction --

<pre><code>
import std::memory::allocator::arena as Arena;

let main = fn (args: [][]u8) -> i32 {
&emsp;let a: Arena::Arena = undefined;
&emsp;return 1;
};
</code></pre>

### Expected --

Successful compilation.

### Received --

<pre><code>
error: Unable to resolve the type of undefined value.
error: .... In /home/yusuf/proj/Cole/test/main.cole 5:12
error: &emsp;return 1;
error:&emsp;&emsp;   ^
Cannot print stack trace: stack tracing is disabled
error: Compiler exited with code 129 <MissingTypeSpecifier>
</code></pre>

## $open -- Safety Checks on Debug Builds -- #62 -- @ysufender --

Lowering paths lack safety checks on debug builds.

### Reproduction --

...

### Expected --

...

### Received --

...

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

<ul>
    <li>TC_10 Fixed</li>
    <li>TC_12 Fixed</li>
</ul>

### Reproduction --

...

### Expected --

...

### Received --

...

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
## $closed -- QBE Backend -- #61 -- @ysufender --
## $closed -- Proper Inline Code Syntax -- #63 -- @ysufender --
## $closed -- Comptime Bugs Again -- #64 -- @ysufender --

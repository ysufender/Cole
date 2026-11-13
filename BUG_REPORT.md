## $open -- Helper Functions for SOA Ease of Use -- #57 -- @ysufender --

The project uses SOA intensively to reduce memory footprint and increase cache hits. For this
reason, almost every unit of the project uses flattened SOA instead of classic unions (see
[parser.zig](https://codeberg.org/ysufender/JASL/src/commit/d950cbde5696f8246efd765418086ed7767d81f8/src/parser/parser.zig#L186)).
The problem with this approach is that it is tedious to write and read the structures (see
[typechecker.zig](https://codeberg.org/ysufender/JASL/src/commit/d950cbde5696f8246efd765418086ed7767d81f8/src/typechecker/typechecker.zig#L619)).
Helper functions to do it inline would be nice.

### Reproduction --

...

### Expected --

...

### Received --

...

## $open -- Unit Testing -- #56 -- @ysufender --

The compiler is currently tested using the Testy framework, which is a custom stdout comparator
written in Lua. Some of the parts of the compiler (mainly the Lexer) can still be unit tested,
otherwise the Testy tests must be improved.

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

...

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

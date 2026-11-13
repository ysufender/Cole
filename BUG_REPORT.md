## $open -- Illegal Memory Access -- (31) -- @ysufender --

When using a non-preserving allocator, the output C code is garbled with trash data.

### Reproduction --

Modify the `main.zig` so that it uses a non-preserving allocator. Then run the raylib demo.

### Expected --

Successful compilation and run.

### Received --

Garbled out parts in the generated C files.

## $closed -- Unable to Compile Non Compile Time Code -- (38) -- @ysufender --
## $closed -- Switch Captures Referencing -- (39) -- @ysufender --
## $closed -- Slice Construction Mixup -- (40) -- @ysufender --
## $closed -- TypeInfo Problems -- (41) -- @ysufender --
## $closed -- Problems With Compile Time Execution -- (42) -- @ysufender --
## $closed -- Comptime Caching -- (43) -- @ysufender --
## $closed -- Initializer List Typechecking Mismatch -- (44) -- @ysufender --
## $closed -- Scoped Definition Access -- (45) -- @ysufender --
## $closed -- Major Performance Issues -- (46) -- @ysufender --
## $closed -- Comptime Definition Lowering -- (47) -- @ysufender --
## $closed -- Switch Capture Folding -- (48) -- @ysufender --
## $closed -- Extern Structs Keep Getting Codegen'd -- (49) -- @ysufender --
## $closed -- Comptime Recursion Bug -- (50) -- @ysufender --
## $closed -- Type Rebinding Bug -- (51) -- @ysufender --
## $closed -- "this" Builtin Bugs -- (52) -- @ysufender --
## $closed -- Generic Definitions Are Last-Call-Win -- (53) -- @ysufender --

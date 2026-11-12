## $open -- Illegal Memory Access -- (31) -- @unbound --

Run the raylib demo. The output source.c is garbled when using a non-preserving allocator
such as c_allocator. This indicates there is some overwrite to freed memory when someone
else is holding a reference to the said memory.

### Reproduction --

...

### Expected --

...

### Received --

...

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
## $closed -- "this()" Builtin Bugs -- (52) -- @ysufender --
## $closed -- Generic Definitions Are Last-Call-Win -- (53) -- @ysufender --

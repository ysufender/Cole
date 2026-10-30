# Known Bugs

## Major Performance Issues (46)

The `bug_numeric_traits` test is passing in this commit, but has major performance
issues. The reason is unbeknownst as for now.

### Reproduction

Just run the `bug_numeric_traits` test.

### Expected Output

A build time less than (or equal to) 1 seconds.

### Received Output

Around almost 1 minute build time, terrible.

## Illegal Memory Access (31)

Run the raylib demo. The output source.c is garbled when using a non-preserving allocator
such as c_allocator. This indicates there is some overwrite to freed memory when someone
else is holding a reference to the said memory.

# Fixed Bugs

## Unable to Compile Non Compile Time Code (38)
## Switch Captures Referencing (39)
## Slice Construction Mixup (40)
## TypeInfo Problems (41)
## Problems With Compile Time Execution (42)
## Comptime Caching (43)
## Initializer List Typechecking Mismatch (44)
## Scoped Definition Access (45)
## Comptime Definition Lowering (47)
## Switch Capture Folding (48)
## Extern Structs Keep Getting Codegen'd (49)

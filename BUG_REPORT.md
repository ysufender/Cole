# Known Bugs

## Generic Definitions Are Last-Call-Win (53)

Generic definitions are sometimes (for some reason) last-call-win.

### Reproduction

Try putting the outer defs of AdvancedEntry etc. into the HashMap generic type and
create two different instances. Then try using a member function of the first type.
It should error with a type mismatch.

## Re: "this()" Builtin Bugs (52)

Check `this_plain_struct` test.

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
## Major Performance Issues (46)
## Comptime Definition Lowering (47)
## Switch Capture Folding (48)
## Extern Structs Keep Getting Codegen'd (49)
## Comptime Recursion Bug (50)
## Type Rebinding Bug (51)

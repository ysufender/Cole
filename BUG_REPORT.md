# Known Bugs

## Comptime Recursion Bug (47)

When a comptime function recurses on itself, the arguments get jumbled. The bug can be seen
in the `std::hash::generic` function.

### Reproduction

```rust
import std::debug as debug;
import std::hash as Hash;

let Str = struct {
    a: u32,
    b: float,
};

let main = fn (args: [][]u8) -> i32 {
    let str1 = Str(1, 2);
    let str2 = Str(1, 2);

    let hasher: mut any = Hash::Stateful::init();
    Hash::generic(Str, Hash::Stateful)(str1, hasher.&);
    let h1 = Hash::Stateful::finalize(hasher);

    hasher = Hash::Stateful::init();
    Hash::generic(Str, Hash::Stateful)(str2, hasher.&);
    let h2 = Hash::Stateful::finalize(hasher);

    return 0;
};
```

### Expected Output

Successful compilation.

### Received Output

```bash
error: Argument type mismatch in function call. In argument 0: expected root::Str, received u32
error: .... In /home/mkdude/proj/Cole/stdlib/std/hash.cole 10:54
error:                 generic(fld.valueType, H)(field(arg, fld.name), hasher);
error:                                                      ^^^
error: Compiler exited with code 150 <TypeMismatch>
```

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
## Major Performance Issues (46)

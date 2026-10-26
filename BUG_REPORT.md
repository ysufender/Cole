# Known Bugs

## Comptime Definition Lowering (47)

Because comptime definitions are lowered lazily, some comptime parameters are left as
identifiers instead of being folded.

### Reproduction

```rust
import std::io::console as Console;

let Format = fn (fmt: []u8, T: type) -> type {
    return struct {
        pub let print = fn (args: T) -> void {
            Console::log(fmt);
        };
    };
};

let StrFormat = Format("Hello", []u8);

let main = fn (args: [][]u8) -> i32 {
    StrFormat::print("Hello");
    return 0;
};
```

### Expected Output

```bash
Hello
```

### Received Output

```bash
error: ~/proj/Cole/test/build/c/source.c:134: error: 'fmt' undeclared
error: BACKEND: Failed to compile source file.

error: Compiler exited with code 231 <BackendError>
```

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

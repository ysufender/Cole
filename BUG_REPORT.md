# Known Bugs

## Type Rebinding Bug (51)

When attaching a comtpime returned type to a name, if the type has been attached
previously, it bypasses the concretization and registers as its own.

### Reproduction

```rust
import std::c as C;
import std::collections::hashmap as HashMap;
import std::debug as Debug;
import std::hash as Hash;

let Map = HashMap::HashMap([]u8, []u8, Hash::FNV1a64, 75);

let main = fn (args: [][]u8) -> i32 {
    switch Map::init(C::Allocator) {
        @Some -> |map| {
            _ = Map::put(map.&, C::Allocator, "Hello", "World");
            let msg = switch Map::get(map.&, "Hello") {
                @Some -> |s| s.*,
                @None -> "<not-found>",
            };

            Debug::print("Hello %", ([]u8))((msg));
        }
        @None -> return 1;
    }

    return 0;
};
```

### Expected Output

Successful compilation, followed by a "Hello World".

### Received Output

```bash
error: /home/yusuf/proj/Cole/test/build/c/source.c:188: error: '{' expected (got ';')
error: BACKEND: Failed to compile source file.

Cannot print stack trace: stack tracing is disabled
error: Compiler exited with code 225 <BackendError>
```

Check the generated C source as well.

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

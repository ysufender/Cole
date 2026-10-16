# Known Bugs

## Scoped Definition Access (45)

Referencing definitions inside scopes aborts with an integer overflow.

### Reproduction

```rust
import std::io::console as Console;

let Struct = struct {
    pub let msg = 15;
};

let main = fn (args: [][]u8) -> i32 {
    let a = Struct::msg.&;

    return 0;
};
```

### Expected Output

Successful compilation

### Received Output

```bash
thread 30644 panic: integer overflow
Cannot print stack trace: stack tracing is disabled
zsh: abort (core dumped)  zig-out/debug-linux-x86_64/v0.0.1/cole --working test main.cole -I ../stdlib
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

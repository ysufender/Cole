# Known Bugs

## Initializer List Typechecking Mismatch (44)

Initialization of aggregate types fail with a type mismatch.

### Reproduction

```rust
let Type = struct {
    field: u32,
};

let main = fn (args: [][]u8) -> i32 {
    let a = Type(1);
    return 0;
};
```

### Expected Output

Successful compilation.

### Received Output

```bash
error: Failed to infer type ('root::Type' vs comptime_int')
error: .... In /home/joseph/Desktop/proj/Cole/test/main.cole 6:18
error:     let a = Type(1);
error:                  ^
error: ........ Required from '/home/joseph/Desktop/proj/Cole/test/main.cole 5:5'
error: let main = fn (args: [][]u8) -> i32 {
error:     ^^^^

error: Compiler exited with code 156 <TypeMismatch>
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

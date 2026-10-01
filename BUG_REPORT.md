# Known Bugs

## TypeInfo Problems (41)

When trying to access the fields of the union values from the builtin::TypeInfo, the
types get mangled somehow. I don't have a reproductory snippet sorry. But below is somewhat
a repro:

```rust
let Union = union(enum) {
    Some: float,
    None: void,
};

let main = fn (args: [][]u8) -> i32 {
    return typeInfo(Union).Union.fields.len;
};
```

This should error out something like `can't find field 'len' in type 'bool'`.

## Problems With Compile Time Execution (42)

We are unable to call simple functions, they somewhat go the comptime route
and end up in error `ComptimeNotPossible`. See `repro/b42` for reproduction.

### Reproduction

See the `test/` of this commit folder directly.

## Illegal Memory Access (31)

Run the raylib demo. The output source.c is garbled when using a non-preserving allocator
such as c_allocator. This indicates there is some overwrite to freed memory when someone
else is holding a reference to the said memory.

# Fixed Bugs

## Unable to Compile Non Compile Time Code (38)
## Switch Captures Referencing (39)
## Slice Construction Mixup (40)

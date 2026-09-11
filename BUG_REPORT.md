# Known Bugs

## Illegal Memory Access (31)

Run the raylib demo. The output source.c is garbled when using a non-preserving allocator
such as c_allocator. This indicates there is some overwriting to freed memory when someone
else is holding a reference to the said memory.

## Slice Construction Mixup (40)

### Description

When constructing slices using an expression list, a misunderstanding between codegen and
typechecker happens.

### Reproduction

```rust
let Union = union(enum) {
    Field1: []u8,
    Field2: u32,
}; 

let main = fn (args: [][]u8) -> i32 {
    let uni = Union(@Field1, "Helo");
    return 0;
};
```

### Expected Output

```c
int32_t const root__main(Slice_Slice_uint8_t const args)
{
__anon_Block_16049278749992822981: (void)(0);
    root__Union const uni = (root__Union){.tag = 0, .Field1 = (Slice_uint8_t){(uint8_t*)"Helo", 4}};
    return 0;
}
```

### Received Output

```c
int32_t const root__main(Slice_Slice_uint8_t const args)
{
__anon_Block_16049278749992822981: (void)(0);
    root__Union const uni = (root__Union){.tag = 0, .Field1 = (Slice_uint8_t){(Slice_uint8_t){(uint8_t*)"Helo", 4}}};
    return 0;
}
```

# Fixed Bugs

## Unable to Compile Non Compile Time Code (38)
## Switch Captures Referencing (39)

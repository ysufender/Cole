# Known Bugs

## Illegal Memory Access (31)

Run the raylib demo. The output source.c is garbled when using a non-preserving allocator
such as c_allocator. This indicates there is some overwriting to freed memory when someone
else is holding a reference to the said memory.

## Switch Captures Referencing (39)

### Description

Switch captures have garbled names when you use them in any way. Declaration side is correct but
referencing identifiers get the wrong strings.

### Reproduction

```rust
let Uni = union(enum) {
    Ok: i32,
    Err: void,
};

let main = fn (args: [][]u8) -> i32 {
    let val = Uni(@Ok, 1);

    switch val {
        @Ok -> |v| {
            _ = v;
        }
        else -> { }
    }

    return 0;
};
```

### Expected Output

```c
int32_t const root__main(Slice_Slice_uint8_t const args)
{

__anon_Block_14525175143759077259: (void)(0);
    root__Uni const val = (root__Uni){0, 1};
    {
__anon_Switch_13496431321134511927: (void)(0);

        {
__anon_Case_14525175143759077259: (void)(0);

            if ((val.tag != (__anon_Enum_14394194981965165550){0})) goto __anon_CaseEnd_5035874246014170412;
            int32_t const v = val.Ok;
            {
__anon_Block_16049278749992822981: (void)(0);

                (void)(v);
            }

            goto __anon_SwitchEnd_16049278749992822981;
            __anon_CaseEnd_5035874246014170412: (void)(0);
        }

        {
__anon_Block_5035874246014170412: (void)(0);
        }

        __anon_SwitchEnd_16049278749992822981: (void)(0);
    }

    return 0;
}
```

# Fixed Bugs

### Unable to Compile Non Compile Time Code (38)

# Performance Fixes

Especially seen in `bug_numeric_traits.cole`.

# Comptime Function Calls

Self explanatory.

# Slice Literals

Self explanatory, we need slice literals.

# Sub-Level Imports

Given code:

```rust
let main = fn (args: [][]u8) -> i32 {
    import std;

    let a = std::Option(float)(9);

    return 0;
};
```

Should compile, and std must only be available for the scope of `main`.

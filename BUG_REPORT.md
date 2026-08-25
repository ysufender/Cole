# Known Bugs

## Illegal Memory Access

Run the raylib demo. The output source.c is garbled when using a non-preserving allocator
such as c_allocator. This indicates there is some overwriting to freed memory when someone
else is holding a reference to the said memory.

# Fixed Bugs

### Unable to Compile Non Compile Time Code

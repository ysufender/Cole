# Cole: A Comptime Oriented Language

Cole is a statically typed, ahead of time compiled programming language that transpiles
into a lowered version of C. Cole supports types as values and compile time code execution,
and handles generics through comptime function execution.

Although it is usable as is right now, Cole far from being a completely finished project.
There are a couple bugs with compile time execution, typechecking, and C interop. But I'm
working steadily to fix and implement them as soon as I can.

> Note: Cole is not a cross-compiler, meaning every Cole compiler is only useful for the
> architecture it was compiled for.

## Building From the Source

### Prerequisites

Cole has only two prerequisites:

- The Zig toolchain,
- TinyCC headers and static library on the system library path.

TinyCC is needed for the current C backend. Cole transpiles into human readable lowered C
and uses the embedded TinyCC to compile the source.

### Building

Simpl execute ´zig build <target>´ where ´target´ can be:

´´´
debug-linux-x86_64
debug-windows-x86_64
releasefast-linux-x86_64
releasefast-windows-x86_64
releasesafe-linux-x86_64
releasesafe-windows-x86_64
releasesmall-linux-x86_64
releasesmall-windows-x86_64
debug
´´´

And the Cole compiler will be at ´zig-out/<target>/<version>/cole(.exe)´.

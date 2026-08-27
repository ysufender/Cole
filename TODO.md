# Comptime Function Calls

As of right now, as can be seen from `evalFunction @ src/typechecker/comptime/folder.zig`,
true compile time functions are not lowered to JIR. The reason for this is the Resolver
is designed to create a single instance of everything. So caching the compile-time function
calls will be a headache. So instead of doing that I decided to split the compile time
function execution into two categories: AST and JIR.

JIR execution at `src/typechecker/comptime/executer/jir.zig` executes non-comptime functions
at compile time. Such functions are fully typechecked and fully lowered.

AST execution at `src/typechecker/comptime/executer/jir.zig` executes comptime functions. Such
functions are not typechecked, and instead of a lowered body they store the index to the body AST.
This part of the compile time execution is not finished, because my every attempt resulted in
either garbage named inner struct definitions or caching problems.

All kinds of help is welcome with the AST executer, whether be direct code contribution or
contributing ideas and thoughts.

# Temporary Expression Caching

To enable `let a = someExpression().fieldAccess`, the generated code should be:

```c
SomeType const __tmp__1231534283412987 = someExpression();
int32_t const a = __tmp__1231534283412987.fieldAccess;
```

# Slice Literals

Self explanatory, we need slice literals.

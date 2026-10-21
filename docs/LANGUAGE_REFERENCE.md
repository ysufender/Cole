# Cole Language Reference

This reference is heavily inspired by the [V Language Documentation](https://github.com/vlang/v/blob/master/doc/docs.md)

## Introduction

Cole is a statically typed, ahead of time compiled programming language designed as a recreational attempt for
a Zig-like language.

It's similar to Zig in many places, but it has a couple distinct features as well.

Cole is a very simple language. Going through this documentation will take you about a weekend,
and by the end of it you will have pretty much learned the entire language.

The language promotes writing simple and clear code with minimal abstraction.

Despite being simple, Cole gives the developer a lot of power.
Anything you can do in other languages, you can do it in Cole, probably.

## Notice

Cole is a WIP project, maintained and developed solely by me, @ysufender, so it lacks in
a lot of places. However, it is developing steadily. Rest assured, it will reach v1.0.0
soon enough.

## Installing Cole from source

The best way to get the latest and greatest Cole, is to install it from source.
It is easy, and it takes only a few seconds:
```bash
git clone --depth=1 https://github.com/ysufender/Cole.git
cd v
zig build <build_mode>-<platform>-<architecture>
```

## On The Compiler Structure

The basic compiler structure is described in [CONTRIBUTING.md](../CONTRIBUTING.md). Besides that,
keep in mind that as for now, Cole is transpiled into half-readable C and then compiled using
a bundled TCC.

Many thanks to Fabrice Bellard for his work on the [TCC](https://bellard.org/tcc/).

## Getting started

Cole is a bare-bones compiler. Meaning that it has no built-in package manager, project manager
or other fancy tools. It is simple: You give it a source file and it compiles the source file.

Cole does not support incremental building, and aims to be fast enough to not need it. You also
don't have to compile each source file separately because Cole discovers your codebase on the fly.

## Table of Contents

<table>
<tr><td width=33% valign=top>

* [Hello World](#hello-world)
* [Compiling a Project](#compiling-a-project)
* [Comments](#comments)
* [Functions](#functions)
    * [Hoisting](#hoisting)
    * [Returning multiple values](#returning-multiple-values)
* [Symbol visibility](#symbol-visibility)
* [Variables](#variables)
    * [Mutable variables](#mutable-variables)
    * [Warnings and declaration errors](#warnings-and-declaration-errors)
* [Cole types](#cole-types)
    * [Primitive types](#primitive-types)
    * [Pointer Types](#pointer-types)
        * [Single Pointers](#single-pointers)
        * [C Pointers](#c-pointers)
        * [Slices](#slices)
    * [Strings](#strings)
    * [Numbers](#numbers)
    * [Arrays](#arrays)

</td><td width=33% valign=top>

* [Module imports](#module-imports)
* [Statements & expressions](#statements--expressions)
    * [If](#if)
        * [`If` Expressions](#if-expressions)
    * [Switch](#switch)
        * [`Switch` Expressions](#switch-expressions)
    * [For loop](#for-loop)
    * [While loop](#while-loop)
* [Structs](#structs)
* [Unions](#unions)

</td><td valign=top>

* [Functions 2](#functions-2)
    * [Variable number of arguments](#variable-number-of-arguments)
    * [Function Pointers](#function-pointers)
* [Constants](#constants)
* [Builtin functions](#builtin-functions)

</td></tr>
<tr><td width=33% valign=top>

* [Advanced Topics](#advanced-topics)
    * [Attributes](#attributes)

</td><td valign=top>

* [Appendices](#appendices)
    * [Keywords](#appendix-i-keywords)
    * [Operators](#appendix-ii-operators)

</td></tr>
</table>

<!--
Note: There are several special keywords, which you can put after the code fences for v:
compile, cgen, live, ignore, failcompile, okfmt, oksyntax, badsyntax, wip, nofmt
For more details, do: `v check-md`
-->

## Hello World

```rust
import std::io::console as Console;

let main = fn (args: [][]u8) -> i32 {
	Console::log('hello world');
    return 0;
};
```

Save this snippet into a file named `hello.cole`. Now compile it using: `cole hello.cole -I path/to/stdlib/impl`.

Congratulations! You just compiled your first Cole program! Your executable is waiting for you
under `./build/c/`!

From the example above, you can see that functions are just one type of expression -hence the
semicolon after the function definition- and are declared with the `fn` keyword. The return
type is specified after the function name, explicitly pointed by an arrow.

As in many other languages (such as C, Go, and Rust), `main` is the entry point of your program.
BEWARE! `main` can't be public!

## Compiling a Project

Suppose you have a folder with several `.cole` files in it, where one of them
contains your `main` function, and the other files have other helper
functions. You use some of them in your main function, directly on indirectly,
and some of them are just leftovers of yesterday, and you want to compile them into
an executable.

In other languages, you would have to use a build system
to enumerate all files, compile them separately to object files,
then link them into one final executable.

In Cole however, you can compile the whole project at once,
using just `cole main.cole`.

Cole will iterate through your imports and do a prepass on every used file, and
set them up as compilation units. Then it starts from your `main` function and discovers
every used symbol/expression/statement lazily until you have a complete program.

## Comments

```rust
// This is a single line comment.
/*
This is a multiline comment.
   /* It can be nested. */
*/
```

## Functions

```rust
let main = fn (args: [][]u8) -> i32 {
	println(add(77, 33));
	println(sub(100, 50));

    return 0;
};

let add = fn (x: i32, y: i32) -> int {
	return x + y;
};

let sub = fn (x: i32, y: i32) -> int {
	return x - y;
};
```

Just like in Go and C, functions cannot be overloaded.
This simplifies the code and improves maintainability and readability.

If you wish to mimic overloading, you can have `Comptime Returned Functions`
or `Comptime Returned Types` with `Scoped Definitions`. We'll see them in the future.

### Hoisting

Functions can be used before their declaration:
`add` and `sub` are declared after `main`, but can still be called from `main`.
This is true for all declarations in Cole and eliminates the need for header files
or thinking about the order of files and declarations.

### Returning multiple values

```rust
let foo = fn () -> (i32, i32) {
	return (2, 3);
};

let main = fn (args: [][]u8) -> i32 {
    let tuple = foo();
    let a = tuple._0; // 2
    let b = tuple._1; // 3
    return 0;
};
```

Tuples are just structs with automatically named fields. You can also create tuple types
in-place, but we'll see that later in the reference.

## Symbol visibility

```rust
pub let publicFunction = fn () -> void {
};

let privateFunction = fn () -> void {
};
```

Any symbol is private (not exported) by default.
To allow other [modules](#module-imports) to use them, prepend `pub`.

## Variables

> From now on, for the sake of simplicity, the main function will
> be omitted in some code-snippets. Keep in mind that Cole doesn't
> support top level code!

```rust
let age               = 20;
let name       : []u8 = "Bob";
let largeNumber: any  = i32(999);
```

Variables are declared with `let` keyword and initialized with `=`. This is the only
way to declare variables in Cole. This means that variables always have an initial
value, albeit that value can be undefined.

Undefined values are just zero-initializations of the variable. Pointers are assigned to
`null` if set to `undefined`.

The variable's type is inferred from the value on the right hand side.
To choose a different type, use type initialization `T(expr)`, type annotation `let a: T = expr;`
or type forwarding `as(T, expr)`. Sometimes, a cast might be needed to convert the `expr` to type `T`.
In such cases, use one of the casts available: `cast` or `unsafeCast`.

The `any` type annotation is redundant here, since it means "infer the type from right hand side".

### Mutable variables

```rust
let age   : mut i32 = 20;
let height: mut any = 180;

age = 25;
height = 190;
```

To change the value of the variable use `=`. In Cole, variables are immutable by default.
To be able to change the value of the variable, you have to mark their types as `mut`.
This is because Cole has `Type Level Mutability`.

However this causes a problem: What happens when I have a long named type that I want to mark `mut`?
For such cases, Cole utilizes the `any` type annotation. A definition annotated with `mut any` will
infer its base type from the right hand side, and register a mutable version of it as its type.

### Warnings and Errors

Cole doesn't have a proper warning system just yet, but it has a rich variety of error codes
and messages to help you debug your program better.

Below is the list of possible error codes:

```
MissingFlag
UnknownFlag
InternalError
NoSourceFile
IOError
InvalidToken
UnterminatedComment
UnterminatedStringLiteral
DotPrefixedNumericLiteral
DotPostfixedNumericLiteral
UnexpectedCharacter
AllocatorFailure
MissingBrace
MissingParenthesis
MissingSemicolon
MissingComma
MissingArrow
MissingTypeSpecifier
MissingIdentifier
MissingColon
MissingAssignment
MissingBracket
MissingBranch
MissingStatement
MultipleErrors
ThreadingError
IllegalSyntax
PathNameTooLong
OutOfMemory
EmptyCharLiteral
FileNotFound
IndexOutOfBounds
MissingPipe
UnexpectedScope
InvalidIdentifier
MissingModuleName
DuplicateSymbol
MissingDefinition
NotImplemented
InvalidEnumeration
TypeMismatch
DependencyCycle
TypeNameTooLong
ComptimeNotPossible
IntegerOverflow
UnexpectedNonTypeExpression
InvalidSpecifier
TypecheckingFailure
MemoryViolation
SizeViolation
SizeMismatch
IncompatibleTypes
MutabilityViolation
PointerSizeMismatch
StructuralMismatch
MismatchingSliceChildType
InferenceError
DuplicateCommandLineInput
RedundantTypeForwarding
ArgumentCountMismatch
RedundantCast
UseOfUndefinedValue
CastOfIncastableValue
ModuleNotInScope
FieldNotFound
ShouldBeImpossible
AccessSpecifierMismatch
NamespaceAsValue
InitializerCountMismatch
PointlessUnionDefinition
TypeIsNotCallable
TypeIsNotConstructible
MultivalueCast
ScopingOnNonScopedType
SliceInitializationWithExpressionList
DivergingBranches
RedundantEmptyCaptureList
RedundantDefaultCase
UnreachableCodePath
IndexingOfNonIndexableValue
NonIntegerIndex
SwitchOnPlainUnion
SwitchOnNonSwitchableValue
ExtraSwitchCase
CaptureOnEnumField
DuplicateSwitchCase
UnhandledSwitchCases
InvalidSwitchCase
NegationOfUnsigned
OperationOnZeroBitSize
ArithmeticOnNonNumericType
LogicOnNonBooleanType
BitwiseOnUnsupportedType
ComparisonOnNonComparableType
ComparisonOnIncompatibleTypes
DivisionByZero
SlicingOfNonSliceableValue
IllegalSlicing
RedundantMark
AddressOfTemporaryValue
DereferenceOfNonPointerValue
DereferenceOfSliceType
UnionLayoutViolation
PublicEntryPoint
UserspaceError
ExistentialDilemma
UnexpectedRValue
IllegalGenericType
UncoveredCodePath
ReturnTypeMismatch
LoopControlOutsideLoopScope
DeferOutsideDeferrableScope
MultipleCLIOptions
IllegalNonTopLevelOp
ComptimePointer
BackendError
AssignationOfNonConcreteValue
ExportOfMainFunction
CaptureOnElseProng
CaptureOnSwitchExpression
VoidPointer
UndefinedPointerType
EmptyNonExternalType
EarlyEval
StackOverflow
StackUnderflow
ExternComptime
NonExternVariadicFunction
UnhandledReturnValue
UnnamedVariadic
UnsupportedTarget
MissingCapture
NonIntegerRange
LoopOverNonRange
Terminate
ImportInSubLevel
```

## Cole Types

### Primitive types

```rust
bool

i8 i32
u8 u32

float

void

c_char  c_short  c_int  c_long
c_uchar c_ushort c_uint c_ulong

c_double

c_size

comptime_int comptime_float

type

noreturn

enum_literal

any
```

Any of these types can be made mutable using the form `mut T`.

### Pointer Types

Cole has three pointer types in total: single, slice, and c. Each pointer type has its own use
case, and each one of them has some distinct rules within.

#### Single Pointers

```rust
let a: u32 = 15;
let b = a.&;

std::io::console::log(typeName(typeOf(b))); // *u32
```

Single pointers are denoted in the form of `<mut> *<mut> T`. The inner `mut` denotes the mutability
of the item that the pointer points to, whereas the outer `mut` specifier is for the pointer itself.

Single pointers are, as the name suggests, pointers to a single item. Therefore they can't be indexed.
And as a security policy, pointer arithmetic on single pointers are not supported.

On the backend side, single pointers are plain C pointers, the restrictions exist only in the
typechecking phase.

As you might've noticed, to take the address of a variable, Cole uses a postfix `.&` operator.
This is to make the code reading easier by creating a left-to-right stream of reading.

Similarly, to dereference a pointer, you can use the postfix `.*` operator like so:

```rust
let c = b.*;

std::io::console::log(typeName(typeOf(c))); // u32
```

#### C Pointers

C pointers are denoted in the form of `<mut> [@c]<mut> T`. The inner `mut` and outer `mut` follow
the same rules as a single pointer.

C pointers are raw C style pointers that point to an unknown number of elements. Therefore, they can
be indexed, and they support pointer arithmetics. However, they are unsafe by design.

A single pointer implicitly coerces to a C style pointer. To create a C style pointer, use `unsafeCast`
on a single item pointer, or use type annotation.

Referencing and dereferencing C style pointers follow the same rules as single pointers.

#### Slices

```rust
let a = #(@noComptime) [3]u32(1, 2, 3);
let b = a[0..3];
```

Slices are denoted in the form of `<mut> []<mut> T`. The inner and outer `mut`s follow the
same rules as the other pointer types.

Slices are fat pointers that point to a runtime known sized elements. Therefore, they can be indexed,
but they do not support pointer arithmetics. In debug builds, they have runtime bounds checking enabled
by default.

Slices store a raw C pointer `ptr` and a `u32` typed `len` field under the hood. You can access the
said fields like:

```rust
slice.ptr
slice.len
```

Slices are not initializable using initializer lists, nor they are formed by referencing a variable.
Instead, they are created by slicing an array, or a C style pointer. Slicing requires runtime known
start-end points.

Given all the properties of slices, it is only meaningful that they do not support dereferencing.
However you can use the `ptr` field to dereference manually instead of indexing.

### Strings

```rust
let a = "Hello World";

std::io::console::log(typeName(typeOf(a))); // []u8
```

Strings are not special types in Cole. They are simple slices to `u8` elements.

### Numbers

```v
let a = 123;
let f = 123.0;
```

This will assign the value of 123 to `a`. By default `a` will have the
type `comptime_int`.

Similarly this will assign the value of 123.0 to `f`. By default `f` will have the
type `comptime_float`.

You can use type annotations to change the type of the comptime literal.

In some cases, the Cole Compiler will not allow you to assign some numbers to some others
due to size mismatches. In those cases, you can sign an `I've read the Terms of Aggreement'`
with the compiler using `unsafeCast` and `cast` to crash your program silently.

### Arrays

Arrays are fixed size blobs of memory that contain a series of same typed elements. They have
compile time known sizes, but their values may or may not be comptime known.

Array types follow the form of `<mut> [<size>]<mut> T` where inner and outer `mut`s follow the
same rules as those of the pointers, and `size` is an arbitrary comptime expression that
yields a `comptime_int` value.

Assigning arrays to other arrays implicitly copy the array contents.

#### Array Fields

Arrays have two fields: `len` and `ptr`.

You can access those fields the same way as a slice. However, they are read-only since arrays are
fixed size. If you try something like:

```rust
array.len = 0;
```

You'll get:

```rust
error: Attempt to modify non-mutable value of type 'u32'.
error: .... In Cole/docs/main.cole 5:5
error:     array.len = 0;
error:     ^^^^^

error: Compiler exited with code 168 <MutabilityViolation>
```

#### Array Initialization

To initialize arrays, we use initializer lists:


```rust
let a         = [3]u32(1, 2, 3);
let b: [3]u32 = (1, 2, 3);
```

We'll learn more about the initializer lists later.

## Module imports

Modules are the main structular component of a Cole project. Cole doesn't have fancy keywords
and doesn't do complex mental gymnastics to create and use modules. It utilizes the directory
structure as a ready-to-use module hierarchy.

Every Cole file is a module, and every directory is a module namespace.

Suppose we have a directory structure like:

```bash
std
|_ math.cole
|_ io
  |_ console.cole
```

You can import the modules `std::math` and `std::io::console` like:

```rust
import std::math;
import std::io::console;
```

Any public definitions inside the modules will be available under their namespaces,
respectively `std::math::*` and `std::io::console::*`. If you don't want to write
the tedious namespace resolutions, you can use import aliasing:

```rust
import std:.math as Math;
import std::io::console as Console;
```

Now you can use the public definitions using `Math::*` and `Console::*`!

Cole doesn't have selective imports, to prevent name collisions. Therefore you must
use the whole qualified name of the member or the aliased name of the member every time you use.

However you can alias variables, functions, and types like:

```rust
let log = Console::log;

log("Hello World");
```

Cyclic module imports are allowed, as long as there is no self-dependent declarations.
In such cases, the compiler will show you the whole dependency chain and error out.

## Statements & expressions

### If

```v
let a = 10;
let b = 20;

if a < b {
    ...
}
else if a > b {
    ...
}
else {
    ...
}
```

`if` statements are pretty straightforward and similar to most other languages.
Unlike other C-like languages,
there are no parentheses surrounding the condition and the braces are always required.
However, you can still have parantheses since they are just another kind of expression.

#### `If` expressions

Unlike C, Cole does not have a ternary operator, that would allow you to do: `x = c ? 1 : 2` .
Instead, it has a bit more verbose, but also clearer to read, ability to use `if` as an
expression. The direct translation in Cole of the ternary construct above, assuming `c` is a
boolean condition, would be: `x = if (c) 1 else 2`. Mind the parentheses around the condition.
They are mandatory in this case.

Here is another example:

```v
let num = 777;
let s = if (num % 2 == 0 ) "even" else "odd"; // "odd"
```

The bodies of if expressions must be expressions themselves, and Cole doesn't support
statement expressions, at least not yet.

#### Comptime Elimination

If the condition of an if statement, or an expression, is a comptime known value, the
if expression is eliminated based on the truth value of the known condition. This is useful
in cross-platform code writing. The example below calls different functions depending on the
platform:

```rust
if buildInfo().platform == @Unix {
    _someUnixFunction();
}
else {
    SomeWindowsFunction();
}
```

### Switch

The switch statement is used to switch between different enumeration or union tag possibilities.
Cole switches are strictly exhaustive, and if you don't cover all poissibilities, the compiler
will be very angry.

Below is a small example using a handcrafted optional type, demonstrating switch statements
and captures in switch cases:

```rust
let Option = union(enum) {
    Some: []u8,
    None: void,
};

switch Option(@Some, "Hello") {
    @Some -> |msg| Console::log(msg);
    else -> { }
}
```

The example above prints `Hello`. You can see how the `else` prong is used to handle the rest of
the possibilities, because of that, captures in the else prong is not possible.

A similar code can be written using enums as well.

Keep in mind that the prongs of the switch must be statements themselves, hence the semicolon at the
end of our `Console::log`.

Also, switch statements too don't need parentheses around the switch item.

#### Switch Expressions

Switch expressions are similar to if expressions:

```rust
let someStr = switch Option(@Some, "Hello") {
    @Some -> |msg| msg,
    else -> unreachable(),
};

Console::log(someStr); // Hello
```

Each arm must be an expression, and each expression must yield a suitable type.

### For Loop

For loops in Cole only have a single form, that is range based. It follows the following form:

```rust
for <range>, |<capture>| {
}
```

Typically, you can use it to iterate over:

* a range expression,
* a slice,
* or an array.

In the latter two cases, the capture variable will be an immutable pointer to the item type
the slice or the array holds.

```rust
for 0..10, |i| {
}

for slice, |item| {
}

for array, |item| {
}
```

### While Loop

While loop has a similar, and simple form:

```rust
while <condition> {
}
```

I think it is pretty self explanatory.

## Structs

Structs are not a special case in Cole, they are just a form of expression which happens to
be a one that you can bind to a variable. To define a struct, simply do this:

```rust
let Struct = struct {
    field1: u32,
    field2: i32,
};
```

Struct fields are always public, you can't mark them private. This is because a simple reason,
Cole treats structs as what they are instead of a form of abstraction: a blob of memory. In
the low level world, hiding a blob of memory is meaningless, Cole thinks so too.

Structs also act like containers and namespaces. This is also the case for unions and enums.
You can utilize this feature to create static variables:

```rust
let count = fn () -> void {
    let static = struct {
        pub let counter: mut i32 = 0;
    };

    static::counter = static::counter + 1;
};
```

Oh, yeah as you've just seen, you can have definitions inside structs! Actually you can have
definitions inside anything that has a scope!

> The `PascalCase` is used as a convention, and is not a must.

## Unions

Unions can either be tagged, or untagged:

```rust
let Untagged = union {
    possible: u32,
    alsoPossible: i32,
};

let Tagged = union(enum) {
    tag1: u32,
    tag2: i32,
};
```

You can switch on tagged unions.

## Functions 2

### Variable number of arguments

Varargs are only supported for external C functions as for now, but as soon as I get comptime
execution working properly, I'll implement varargs.

### Function Pointers

Functions are implicitly function pointer types. So you can pass them around.

## Constants

Constants in Cole are anything that is not marked as `mut`. Such values will be aggressively
folded unless marked `@noComptime`. So, doing some unsafe casting magic to modify a constant
is not advised.

## Builtin functions

Here is a list of builtin functions:

```rust
let compileError = #(@comptime) fn (msg: []u8) -> noreturn

let bitSizeOf = #(@comptime) fn (val: any) -> comptime_int

let unreachable = fn () -> noreturn

let typeOf = fn (val: any) -> type

let sizeOf = fn (val: any) -> comptime_int

let cast = fn (val: any) -> T

let as = #(@comptime) fn (T: type, expr: any) -> T

let unsafeCast = fn (val: any) -> T

let compileLog = #(@comptime) fn (msg: []u8) -> void

let typeName = #(@comptime) fn (T: type) -> []u8

let  = #(@variadic) fn (F1: type) -> type

let alignOf = fn (val: any) -> comptime_int

let compileBreak = #(@comptime) fn () -> noreturn

let typeInfo = fn (T: type) -> builtin::TypeInfo

let src = fn () -> builtin::SourceInfo

let buildInfo = fn () -> builtin::ColeInfo

let inComptime = fn () -> bool
```

# Advanced Topics

## Marks

Marks are Cole's way of adding metadata to expressions. You can mark any expression
you want with an arbitrary comptime expression. The compiler provides a couple of
builtin enumerations for attributing purposes. Available ones are:

```bash
@noComptime
@comptime
@export
@extern
@variadic
@opaque
@packed
```

I will not go into detail with marks since they are not completely ready yet. But once done,
I'll update this section.

# Appendices

## Appendix I: Keywords

Cole has 24 reserved keywords (3 are literals):

```rust
and
or
if
else
while
for
fn
return
defer (reserved)
let
import
false
true
struct
enum
union
pub
mut
code
break
continue
switch
# (mark)
_ (discard)
undefined
```

See also [V Types](#v-types).

## Appendix II: Operators

This lists operators for [primitive types](#primitive-types) only.

Boolean values, including aliases of `bool` without an overloaded `<` operator, cannot be ordered
with `<`, `>`, `<=`, or `>=`. The checker currently does not enforce this restriction for
comparisons between generic operands specialized to `bool` or its aliases.

```v ignore
+    sum                    integers, floats, strings
-    difference             integers, floats
*    product                integers, floats
/    quotient               integers, floats
%    remainder              integers

~    bitwise NOT            integers
&    bitwise AND            integers
|    bitwise OR             integers
^    bitwise XOR            integers

!    logical NOT            bools
and  logical AND            bools
or   logical OR             bools
!=   logical XOR            bools

<<   left shift             integer << unsigned integer
>>   right shift            integer >> unsigned integer


Precedence    Operator
    5            *  /  %  <<  >> &
    4            +  -  |  ^
    3            ==  !=  <  <=  >  >=
    2            and
    1            or
```

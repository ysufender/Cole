# The Cole Compiler

The Cole compiler is a multi-pass, demand driven and lazy
compiler written for the Cole programming language, mostly in
Zig programming language. It aims to be simple, lightweight and
fast without sacrificing too much.

This document briefly describes the overall project structure for
potential contributors to make sense of the codebase.

# General Notes on Contribution

The Cole Compiler aims to be a learning project, and a fun one at that. Due to this
goal, AI generated contributions are strongly discouoraged. AI generated tests **MAY**
be accepted depending on the code quality, and other factors. Please respect this decision.

The overall code quality standards are simple: follow the [Zen of Zig](https://ziglang.org/documentation/master/#Zen).

# The Basic Project Structure

The Cole compiler consists of 4 stages:

- Setup
- Lexical Analyzer
- Parser
- Typechecker
- Code Generator (Depending on the backend)
- Backend Call

with each of the stages having no or a couple substeps.
Their structures look like:

- Setup
    - Commandline Parsing
    - Context Creation
    - IO Initialization
- Lexical Analyzer
- Parser
    - Prepass
    - Parser
- Typechecker (substeps intertwined)
    - Resolver
    - Compile Time Executer
    - Compile Time Folder
    - Typechecker
    - Lowering (JIR)
- Codegen
    - C
        - Codegen
    - QBE
        - Loweing (JAIR)
        - Codegen
- Backend Call
    - C
        - TCC Call
    - QBE
        - Assembly Generation
        - Assembler
        - Linking

Typechecker is the biggest stage of the compiler, containing almost %60
of the whole codebase within. Most possibly, according to statistics, it
also is the source of most of the bugs.

# Compilation Pipeline

The compilation pipeline is ordered as follows:

- Setup
- Lexer
- Parser.Parse
- Parser.Prepass
- Typechecker.Resolver
- Typechecker.Typechecker
- Typechecker.Lowerer
- Codegen.Codegen (depending on the backend)
- Codegen.Compile (depending on the backend)

Note that the other steps of the Typechecker are called from within the
Typechecker.Typechecker and are not separate steps.

And the entry points of each stage is as follows:

- Setup                  : init      @ src/core/context.zig
- Lexer                  : lex       @ src/lexer/lexer.zig
- Parser.Parse           : parse     @ src/parser/parser.zig
- Parser.Prepass         : prepass   @ src/parser/prepass.zig
- Typechecker.Resolver   : resolve   @ src/typechecker/resolver.zig
- Typechecker.Typechecker: typechcek @ src/typechecker/typechecker.zig
- Typechecker.Lowerer    : doesn't have a concrete entry, called from the typechecker on the fly
- Codegen.Codegen        : depends on the backend, look under `codegen/`
- Codegen.Compile        : depends on the backend, look under `codegen/`

Currently, there are two backends: QBE and TCC.

# Stage/Step Definitions

## Setup

Reads the commandline, sets up the global context. Everything
the compiler uses that is shared between stages is stored here.

## Lexer

Tokenizes the given file and returns a TokenListPtr which is an
index into the global TokenList list.

Lexer only lexes the main file passed to the commanline at first,
following lexings are calls made from the Parser.Prepass step in which
the dependencies are resolved.

## Parser.Parse

Parses the given file and return an ASTPtr which is an index
into the global AST list.

Parser.Parse only parses the main file passed to the commandline at first,
following parsings are calls made from the Parser.Prepass step in which
the dependencies are resolved.

## Parser.Prepass

Prepasses the given file and returns a ModuleList in which each Module
stores information about the global symbols of itself. New modules are
discovered lazily on demand when met with an import statement.

Parser.Prepass doesn't do any resolving on the discovered modules, it
only finds the depth of the project and registers the global symbols.

## Typechecker.Resoler

Creates Declarations, Scopes and resolves Expressions from the given modules.
Return value is a Resolution which contains of Expression-to-Declaration,
Name-to-Deckaration, Declaration and Scope lists/maps.

Resolving is is done only in the lexical sense, Expressions referring to
declarations within Types are not resolved and are left to the Typechecker.

## Typechecker.Typechecker

Lazily typechecks expression and caches the resulting types of declarations
starting from the entry point of the program. Subsequently lowers any top-level
definitions it discovers and at the end returns a lowered and typed IR.

If allowed, folds any compile time executable expression into literals
by calling to Typechecker.Comptime.Folder and Typechecker.Comptime.Executer.

## Typechecker.Lowerer

This step is intertwined with the typechecking process. It lowers the typechecked
AST into semi-typed JIR for C code generation and, on QBE, JAIR generation.

It may inline for loops, fold constants, and eliminate dead branches.

## Codegen.Codegen

Depending on the backend, this step changes behaviour.

On the C backend, all codegen does is to generate half-readable, lowered C source
from the generated JIR.

On the QBE, codegen converts JIR into fully-typed JAIR, and then generates QBE IR source
from it.

## Codegen.Compile

Depending on the backend, this step changes behaviour.

On the C backend, compilation calls into TCC with the generated source files and compiles the
program into the final executable. This backend requires the user to have standard C headers
on their `PATH`.

On the QBE backend, compilation does more jobs. Firstly, it calls into the bundled QBE to generate
x86_64 assembly source from the QBE IR. Afterwards, it calls into Minias to assemble the generated
x86_64 assembly source into an object file. Lastly, TCC is reused as the linker to create the final
executable. This backend does not require the user to have the C headers, but it does require the
user to have the C standard library to be on their `PATH`.

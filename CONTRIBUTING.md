# The Cole Compiler

The Cole compiler is a multi-pass, demand driven and lazy
compiler written for the Cole programming language, mostly in
Zig programming language. It aims to be simple, lightweight and
fast without sacrificing too much.

This document briefly describes the overall project structure for
potential contributors to make sense of the codebase.

# The Basic Project Structure

The Cole compiler consists of 4 stages:

- Setup
- Lexical Analyzer
- Parser
- Typechecker
- Code Generator

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
- Codegen

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
- Codegen.Codegen
- Codegen.Compile

Note that the other steps of the Typechecker are called from within the
Typechecker.Typechecker and are not separate steps.

And the entry points of each stage is as follows:

- Setup                  : init      @ src/core/context.zig
- Lexer                  : lex       @ src/lexer/lexer.zig
- Parser.Parse           : parse     @ src/parser/parser.zig
- Parser.Prepass         : prepass   @ src/parser/prepass.zig
- Typechecker.Resolver   : resolve   @ src/typechecker/resolver.zig
- Typechecker.Typechecker: typechcek @ src/typechecker/typechecker.zig
- Codegen.Codegen        : codegen   @ src/codegen/c/jir.zig
- Codegen.Compile        : compile   @ src/codegen/c/backend.zig

Note that the current backend is lowered C, using an embedded TCC.
Codegen step may change and this document may be out-of-date.

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
by calling to Typechecker.Folder and Typechecker.Executer.

## Codegen.Codegen

Emits a lowered subset of C code from the resulting IR. Technically, any
errors from now on is the fault of me, the author, and not the programmer.

The C code consists of two files are ´forward_decl.h´ and ´source.c´ under
´./build/c/´.

## Codegen.Compile

Compiles the resulting C code into executable binaries by invoking the embedded
TCC.

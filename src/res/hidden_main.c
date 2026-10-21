/*
 * This file has been automatically generated
 * by the Cole compiler.
 */

#include <stdlib.h>
#include <stdnoreturn.h>
#include <string.h>
#include <signal.h>
#include <stdio.h>

#ifdef COLE_WIN32
#   include <windows.h>
#   include <dbghelp.h>
#else
#   include <execinfo.h>
#   include <unistd.h>
#endif

#include "forward_decl.h"

Slice_uint8_t       _Cole_implicit__executable_path;
Slice_Slice_uint8_t _Cole_implicit__commandline_args;

#ifdef COLE_DEBUG
StackTrace _Cole_implicit__stack_trace;

static void $$print_stack_trace(void) {{
    StackTrace const* node = &_Cole_implicit__stack_trace;
    unsigned depth = 0;

    fprintf(stderr, "Trace (most recent call first):\n");
    for (unsigned guard = 0; node != NULL && guard < 4096; guard++, node = node->next) {{
        if (node->frame.function.len == 0) {{
            continue;
        }}
        fprintf(stderr, "  [%u] %.*s (%.*s:%u:%u)\n",
            depth++,
            (int)node->frame.function.len, (char const*)node->frame.function.ptr,
            (int)node->frame.file.len, (char const*)node->frame.file.ptr,
            (unsigned)node->frame.line, (unsigned)node->frame.col);
    }}
}}
#endif

void __attribute__((noreturn)) $$panic_handler(int const addr) {{
    fprintf(stderr, "General protection handler. %#018lx\n\n", addr);
#ifdef COLE_DEBUG
    $$print_stack_trace();
#else
    fprintf(stderr, "Stack tracing is not available.\n");
#endif
    fflush(stderr);
    exit(EXIT_FAILURE);

    __builtin_unreachable();
}}

void __attribute__((noreturn)) $$unreachable(long const addr) {{
    fprintf(stderr, "Reached unreachable code at address %#018lx\n", addr);
    return $$panic_handler(addr);
}}

#ifdef COLE_DEBUG
void __attribute__((noreturn)) $$invalid_index(long const addr) {{
    fprintf(stderr, "Indexing error at %#018lx\n", addr);
    return $$panic_handler(addr);
}}

void __attribute__((noreturn)) $$null_deref(long const addr) {{
    fprintf(stderr, "Null pointer dereferencing at %#018lx\n", addr);
    return $$panic_handler(addr);
}}

void __attribute__((noreturn)) $$union_access(long const addr, char const* const access) {{
    fprintf(stderr, "Attempt to access inactive union field '%s' at %#018lx\n", access, addr);
    return $$panic_handler(addr);
}}
#endif

int main(int const argc, char const* const* const argv) {{
#if COLE_DEBUG
    _Cole_implicit__stack_trace = (StackTrace){{
        .frame = (StackFrame){{
            .function = (Slice_uint8_t){{(uint8_t*)"main", 4}},
            .file = (Slice_uint8_t){{(uint8_t*)"hidden_main.c", 13}},
            .line = 0,
            .col = 0,
        }},
        .next = (StackTrace*)NULL,
    }};
#endif

    Slice_uint8_t* const strings = (Slice_uint8_t*)malloc(sizeof(Slice_uint8_t) * (argc - 1));
    for (int i = 1; i < argc; i++) {{
        strings[i - 1].ptr = (uint8_t*)argv[i];
        strings[i - 1].len = strlen(argv[i]);
    }}
    Slice_Slice_uint8_t const args = {{
        .ptr = strings,
        .len = argc - 1,
    }};

    _Cole_implicit__executable_path = (Slice_uint8_t){{
        .ptr = (uint8_t*)argv[0],
        .len = strlen(argv[0]),
    }};
    _Cole_implicit__commandline_args = args;

    signal(SIGABRT, $$panic_handler);
    signal(SIGSEGV, $$panic_handler);

    int32_t const err = root__main(args);
    free(strings);
    return err;
}}

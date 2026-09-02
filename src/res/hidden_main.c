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

void __attribute__((noreturn)) __panic_handler(int const addr) {{
    fprintf(stderr, "General protection handler. %#018lx\n\n", addr);
#ifdef COLE_DEBUG
    fprintf(stderr, "Trace:\n");
#   ifdef COLE_WIN32
        HANDLE process = GetCurrentProcess();
        SymInitialize(process, NULL, TRUE);

        void *frames[64];
        WORD n = CaptureStackBackTrace(0, 64, frames, NULL);

        SYMBOL_INFO *sym = (SYMBOL_INFO *)calloc(
            sizeof(SYMBOL_INFO) + 256 * sizeof(char), 1);
        sym->MaxNameLen   = 255;
        sym->SizeOfStruct = sizeof(SYMBOL_INFO);

        for (WORD i = 0; i < n; i++) {{
            SymFromAddr(process, (DWORD64)frames[i], 0, sym);
            fprintf(stderr, "  [%u] %s — 0x%0llX\n",
                    n - i - 1, sym->Name, sym->Address);
        }}
        free(sym);
        SymCleanup(process);
#   else
        const framec = 128;
        void *frames[framec];
        int n = backtrace(frames, framec);
        backtrace_symbols_fd(frames, n, STDERR_FILENO);
#   endif
#else
    fprintf(stderr, "Stack tracing not available.\n");
#endif
    fflush(stderr);
    exit(EXIT_FAILURE);

    __builtin_unreachable();
}}

void __attribute__((noreturn)) __unreachable(long const addr) {{
    fprintf(stderr, "Reached unreachable code at address %#018lx\n", addr);
    return __panic_handler(addr);
}}

void __attribute__((noreturn)) __invalid_index(long const addr) {{
    fprintf(stderr, "Indexing error at %#018lx\n", addr);
    return __panic_handler(addr);
}}

void __attribute__((noreturn)) __null_deref(long const addr) {{
    fprintf(stderr, "Null pointer dereferencing at %#018lx\n", addr);
    return __panic_handler(addr);
}}

void __attribute__((noreturn)) __union_access(long const addr, char const* const access) {{
    fprintf(stderr, "Attempt to access inactive union field '%s' at %#018lx\n", access, addr);
    return __panic_handler(addr);
}}

int main(int const argc, char const* const* const argv) {{
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

    signal(SIGABRT, __panic_handler);
    signal(SIGSEGV, __panic_handler);

    int32_t const err = root__main(args);
    free(strings);
    return err;
}}

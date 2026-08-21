/*
 * This file has been automatically generated
 * by the Cole compiler.
 */

#include <stdlib.h>
#include <string.h>

#include "forward_decl.h"

char const* __implicit__executable_path;
Slice_Slice_uint8_t __implicit_commandline_args;

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

    __implicit__executable_path = argv[0];
    __implicit_commandline_args = args;

    int32_t const err = root__main(args);
    free(strings);
    return err;
}}



/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#include <stdlib.h>
#include <string.h>

#include "forward_decl.h"

int main(int const argc, char const* const* const argv) {{
    const_Slice_uint8_t* const strings = (const_Slice_uint8_t*)malloc(sizeof(const_Slice_uint8_t) * (argc - 1));
    for (int i = 1; i < argc; i++) {{
        strings[i - 1].ptr = (uint8_t*)argv[i];
        strings[i - 1].len = strlen(argv[i]);
    }}
    const_Slice_const_Slice_uint8_t const args = {{
        .ptr = strings,
        .len = argc - 1,
    }};

    return root__main(args);
}}



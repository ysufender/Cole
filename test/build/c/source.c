/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#include "forward_decl.h"

int main() {
    return root__main();
}

void root__println(Slice_uint8_t const msg)
{
$$anon_Block_14394194981965165550: (void)(0);
/*Inserted Code*/

        #include <stdio.h>
        printf("%s\n", msg.ptr);
    }
int32_t const root__main()
{
$$anon_Block_16049278749992822981: (void)(0);
    return 1;
}

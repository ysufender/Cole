/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#include "forward_decl.h"

int main() {
    return root__main();
}


    #include "raylib.h"

void raylib__InitWindow(int32_t const width, int32_t const height, Slice_uint8_t const title)
{
$$anon_Block_14394194981965165550: (void)(0);
/*Inserted Code*/
 InitWindow(width, height, (char const*)title.ptr); 
}

jasl_bool const raylib__WindowShouldClose()
{
$$anon_Block_5035874246014170412: (void)(0);
    jasl_bool res;
/*Inserted Code*/
 res = WindowShouldClose(); 
    return res;
}

void raylib__CloseWindow()
{
$$anon_Block_13496431321134511927: (void)(0);
/*Inserted Code*/
 CloseWindow(); 
}

int32_t const root__main()
{
$$anon_Block_15901871329232600808: (void)(0);
    raylib__InitWindow(500, 600, (Slice_uint8_t){(uint8_t*)"Hello World\0", 11});
    root__Str const f = (root__Str){1};
    goto $$anon_Loop_16233961323067850050_Check;
    $$anon_Loop_16233961323067850050_Start: (void)(0);
    {
$$anon_Block_12731370710357201570: (void)(0);
    }

    $$anon_Loop_16233961323067850050_Check: (void)(0);
    if (!(raylib__WindowShouldClose())) goto $$anon_Loop_16233961323067850050_Start;
    raylib__CloseWindow();
    return 0;
}


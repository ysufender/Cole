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
$$anon_Block_16049278749992822981: (void)(0);
/*Inserted Code*/
 return WindowShouldClose(); 
    return 0;
}

void raylib__CloseWindow()
{
$$anon_Block_14525175143759077259: (void)(0);
/*Inserted Code*/
 CloseWindow(); 
}

float const root__func()
{
$$anon_Block_12882719531207038732: (void)(0);
    float u32 = 1;
    return 1;
}

int32_t const root__main()
{
$$anon_Block_16233961323067850050: (void)(0);
    raylib__InitWindow(300, 300, (Slice_uint8_t){(uint8_t*)"Hello\0", 5});
    goto $$anon_Loop_12731370710357201570_Check;
    $$anon_Loop_12731370710357201570_Start: (void)(0);
    {
$$anon_Block_3971240746043662859: (void)(0);
    }

    $$anon_Loop_12731370710357201570_Check: (void)(0);
    if (!(raylib__WindowShouldClose())) goto $$anon_Loop_12731370710357201570_Start;
    raylib__CloseWindow();
    return 1;
}


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
    jasl_bool res = 0;
/*Inserted Code*/
 res = WindowShouldClose(); 
    return res;
}

float const raylib__GetFrameTime()
{
$$anon_Block_13496431321134511927: (void)(0);
    float res;
/*Inserted Code*/
 res = GetFrameTime(); 
    return res;
}

void raylib__Scale(Vector2 const c, float const f)
{
$$anon_Block_15901871329232600808: (void)(0);
}

void raylib__BeginDrawing()
{
$$anon_Block_12731370710357201570: (void)(0);
/*Inserted Code*/
 BeginDrawing(); 
}

void raylib__ClearBackground(Color const color)
{
$$anon_Block_17599025288361479413: (void)(0);
/*Inserted Code*/
 ClearBackground(color); 
}

Color const Red = (Color){255, 0, 0, 255};
void raylib__DrawText(Slice_uint8_t const text, int32_t const posX, int32_t const posY, int32_t const fontSize, Color const color)
{
$$anon_Block_2417939988112334111: (void)(0);
/*Inserted Code*/
 DrawText(text.ptr, posX, posY, fontSize, color); 
}

Color const Blue = (Color){0, 0, 255, 255};
void raylib__DrawCircle(Vector2 const center, float const radius, Color const color)
{
$$anon_Block_2428034255698430285: (void)(0);
/*Inserted Code*/
 DrawCircle(center, radius, color); 
}

void raylib__EndDrawing()
{
$$anon_Block_8281603307388481355: (void)(0);
/*Inserted Code*/
 EndDrawing(); 
}

void raylib__CloseWindow()
{
$$anon_Block_18097166642412114837: (void)(0);
/*Inserted Code*/
 CloseWindow(); 
}

int32_t const root__main()
{
$$anon_Block_9944550705755129845: (void)(0);
    raylib__InitWindow(600, 500, (Slice_uint8_t){(uint8_t*)"Hello World\0", 11});
    Vector2 pos = (Vector2){160, 160};
    Vector2 const vel = (Vector2){15, 16};
    goto $$anon_Loop_2604486134261187998_Check;
    $$anon_Loop_2604486134261187998_Start: (void)(0);
    {
$$anon_Block_16745735485697338677: (void)(0);
        float const delta = raylib__GetFrameTime();
        raylib__Scale(pos, 5);
        raylib__BeginDrawing();
        {
$$anon_Block_15572651889598128231: (void)(0);
            raylib__ClearBackground((Color){255, 0, 0, 255});
            raylib__DrawText((Slice_uint8_t){(uint8_t*)"Hello World\0", 11}, 275, 240, 20, (Color){0, 0, 255, 255});
            raylib__DrawCircle(pos, 15, (Color){0, 0, 255, 255});
        }

        raylib__EndDrawing();
    }

    $$anon_Loop_2604486134261187998_Check: (void)(0);
    if (!(raylib__WindowShouldClose())) goto $$anon_Loop_2604486134261187998_Start;
    raylib__CloseWindow();
    return 0;
}


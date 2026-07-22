/* Top-level inserted code */


/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#include "forward_decl.h"

int main() {
    return root__main();
}

void raylib__InitWindow(int32_t const width, int32_t const height, Slice_uint8_t const title)
{
$$anon_Block_14394194981965165550: (void)(0);
/* Inserted Code */
 InitWindow(width, height, (char const*)title.ptr); 

}

jasl_bool const raylib__WindowShouldClose()
{
$$anon_Block_5035874246014170412: (void)(0);
    jasl_bool res = 0;
/* Inserted Code */
 res = WindowShouldClose(); 
    return res;

}

float const raylib__GetFrameTime()
{
$$anon_Block_13496431321134511927: (void)(0);
    float res;
/* Inserted Code */
 res = GetFrameTime(); 
    return res;

}

Vector2 const Vector2__Scale(Vector2 const v, float const s)
{
$$anon_Block_15901871329232600808: (void)(0);
    return (Vector2){(v.x * s), (v.y * s)};

}

Vector2 const Vector2__Add(Vector2 const v, Vector2 const v2)
{
$$anon_Block_12731370710357201570: (void)(0);
    return (Vector2){(v.x + v2.x), (v.y + v2.y)};

}

float const root__absf(float const f)
{
$$anon_Block_14931302220966946916: (void)(0);
    return (f > 0) ? f : -(f);

}

void std__io__println(Slice_uint8_t const msg)
{
$$anon_Block_2167914373511376141: (void)(0);
/* Inserted Code */
 printf("%s\n", msg); 

}

void raylib__BeginDrawing()
{
$$anon_Block_8274098387324605808: (void)(0);
/* Inserted Code */
 BeginDrawing(); 

}

void raylib__ClearBackground(Color const color)
{
$$anon_Block_8281603307388481355: (void)(0);
/* Inserted Code */
 ClearBackground(color); 

}

Color const Red = (Color){255, 0, 0, 255};
void raylib__DrawText(Slice_uint8_t const text, int32_t const posX, int32_t const posY, int32_t const fontSize, Color const color)
{
$$anon_Block_18097166642412114837: (void)(0);
/* Inserted Code */
 DrawText(text.ptr, posX, posY, fontSize, color); 

}

Color const Blue = (Color){0, 0, 255, 255};
void raylib__DrawCircle(Vector2 const center, float const radius, Color const color)
{
$$anon_Block_9944550705755129845: (void)(0);
/* Inserted Code */
 DrawCircleV(center, radius, color); 

}

void raylib__EndDrawing()
{
$$anon_Block_16745735485697338677: (void)(0);
/* Inserted Code */
 EndDrawing(); 

}

void raylib__CloseWindow()
{
$$anon_Block_9569422634429357098: (void)(0);
/* Inserted Code */
 CloseWindow(); 

}

int32_t const root__main()
{
$$anon_Block_18149526613876181996: (void)(0);
    raylib__InitWindow(600, 500, (Slice_uint8_t){(uint8_t*)"Hello World\0", 11});
    Vector2 pos = (Vector2){160, 160};
    Vector2 vel = (Vector2){100, 100};
    {
$$anon_Block_16162674634529531010: (void)(0);
        goto $$anon_Loop_1433292512581475656_Check;
        $$anon_Loop_1433292512581475656_Start: (void)(0);
        {
$$anon_Block_11635425079708401102: (void)(0);
            float const delta = raylib__GetFrameTime();
            Vector2 const deltaVel = Vector2__Scale(vel, delta);
            pos = Vector2__Add(pos, deltaVel);
            {
$$anon_Block_11977092954699203250: (void)(0);
                if ((root__absf((pos.x - 280)) >= 265)) goto $$anon_Finally_15809605297042570497;
                {
$$anon_Block_7779630055902864632: (void)(0);
                    std__io__println((Slice_uint8_t){(uint8_t*)"Flip!\0", 5});
                    vel = (Vector2){-(vel.x), vel.y};
                
}

                goto $$anon_Finally_15809605297042570497;
                $$anon_Finally_15809605297042570497: (void)(0);
            
}

            {
$$anon_Block_5408961738284701175: (void)(0);
                if ((root__absf((pos.y - 250)) >= 235)) goto $$anon_Finally_5251505954037444658;
                {
$$anon_Block_13414203536031990682: (void)(0);
                    vel = (Vector2){vel.x, -(vel.y)};
                
}

                goto $$anon_Finally_5251505954037444658;
                $$anon_Finally_5251505954037444658: (void)(0);
            
}

            raylib__BeginDrawing();
            {
$$anon_Block_4868289067183140247: (void)(0);
                raylib__ClearBackground((Color){255, 0, 0, 255});
                raylib__DrawText((Slice_uint8_t){(uint8_t*)"Hello World\0", 11}, 275, 240, 20, (Color){0, 0, 255, 255});
                raylib__DrawCircle(pos, 15, (Color){0, 0, 255, 255});
            
}

            raylib__EndDrawing();
        
}

        $$anon_Loop_1433292512581475656_Check: (void)(0);
        if (!(raylib__WindowShouldClose())) goto $$anon_Loop_1433292512581475656_Start;
    
}

    raylib__CloseWindow();
    return 0;

}


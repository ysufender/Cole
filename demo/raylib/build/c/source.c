/* Top-level inserted code */


/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#include <stdlib.h>
#include <string.h>

#include "forward_decl.h"

int main(int const argc, char const* const* const argv) {
    const_Slice_uint8_t* const strings = (const_Slice_uint8_t*)malloc(sizeof(const_Slice_uint8_t) * (argc - 1));
    for (int i = 1; i < argc; i++) {
        strings[i - 1].ptr = (uint8_t*)argv[i];
        strings[i - 1].len = strlen(argv[i]);
    }
    const_Slice_const_Slice_uint8_t const args = {
        .ptr = strings,
        .len = argc - 1,
    };

    return root__main(args);
}


int32_t const root__WIDTH = 640;
void raylib__InitWindow(int32_t const width, int32_t const height, const_Slice_uint8_t const title)
{
__anon_Block_16049278749992822981: (void)(0);
/* Inserted Code */
 InitWindow(width, height, title.ptr); 
}

int32_t const root__HEIGHT = 480;
void raylib__SetTargetFPS(int32_t const fps)
{
__anon_Block_14525175143759077259: (void)(0);
/* Inserted Code */
 SetTargetFPS(fps); 
}

jasl_bool const raylib__WindowShouldClose()
{
__anon_Block_12882719531207038732: (void)(0);
    jasl_bool res = 0;
/* Inserted Code */
 res = WindowShouldClose(); 
    return res;
}

void raylib__BeginDrawing()
{
__anon_Block_16233961323067850050: (void)(0);
/* Inserted Code */
 BeginDrawing(); 
}

void raylib__ClearBackground(Color const color)
{
__anon_Block_14931302220966946916: (void)(0);
/* Inserted Code */
 ClearBackground(color); 
}

Color const Color__Black = (Color){0, 0, 0, 255};
void raylib__DrawRectangle(int32_t const posX, int32_t const posY, int32_t const width, int32_t const height, Color const color)
{
__anon_Block_2167914373511376141: (void)(0);
/* Inserted Code */
 DrawRectangle(posX, posY, width, height, color); 
}

Color const Color__White = (Color){255, 255, 255, 255};
const_Array_uint8_t_2_t const root__intToChar(uint8_t const a)
{
__anon_Block_8274098387324605808: (void)(0);
    const_Array_uint8_t_2_t const str = (const_Array_uint8_t_2_t){(48 + a), 0};
    return str;
}

void raylib__DrawText(const_Slice_uint8_t const text, int32_t const posX, int32_t const posY, int32_t const fontSize, Color const color)
{
__anon_Block_9546729811265229851: (void)(0);
/* Inserted Code */
 DrawText(text.ptr, posX, posY, fontSize, color); 
}

jasl_bool const root__checkCollision(int32_t const x1, float const x2, int32_t const y1, float const y2, int32_t const w1, int32_t const h1, float const r)
{
__anon_Block_2604486134261187998: (void)(0);
    {
__anon_Block_9944550705755129845: (void)(0);
        if ((!(((((x1 <= (x2 + r)) && (y1 <= (y2 + r))) && (x2 <= (x1 + w1))) && (y2 <= (y1 + h1)))))) goto __anon_Finally_18097166642412114837;
        {
__anon_Block_13076022316524835480: (void)(0);
            return 1;
        }

        goto __anon_Finally_18097166642412114837;
        __anon_Finally_18097166642412114837: (void)(0);
    }

    return 0;
}

void raylib__DrawCircle(int32_t const centerX, int32_t const centerY, float const radius, Color const color)
{
__anon_Block_15572651889598128231: (void)(0);
/* Inserted Code */
 DrawCircle(centerX, centerY, radius, color); 
}

void raylib__EndDrawing()
{
__anon_Block_4907636064931205134: (void)(0);
/* Inserted Code */
 EndDrawing(); 
}

jasl_bool const raylib__IsKeyDown(uint32_t key)
{
__anon_Block_12022879660635692288: (void)(0);
    jasl_bool res = 0;
/* Inserted Code */
 res = IsKeyDown(key); 
    return res;
}

uint32_t raylib__W = 87;
uint32_t raylib__UP = 265;
uint32_t raylib__S = 83;
uint32_t raylib__DOWN = 264;
void raylib__CloseWindow()
{
__anon_Block_7779630055902864632: (void)(0);
/* Inserted Code */
 CloseWindow(); 
}

int32_t const root__main(const_Slice_const_Slice_uint8_t const args)
{
__anon_Block_1707262033473486372: (void)(0);
    root__Player ply = (root__Player){20, 100, 20, 70, 0};
    root__Player cpu = (root__Player){(root__WIDTH - 35), 100, 20, 70, 0};
    root__Ball b = (root__Ball){((root__WIDTH / 2) - 10), 120, -5, -5, 10};
    raylib__InitWindow(root__WIDTH, root__HEIGHT, (const_Slice_uint8_t){(uint8_t*)"Ping pong", 9});
    raylib__SetTargetFPS(60);
    {
__anon_Block_10761808952921467351: (void)(0);
        goto $$anon_Loop_15895234769193670539_Check;
        $$anon_Loop_15895234769193670539_Start: (void)(0);
        {
__anon_Block_12490044124299982418: (void)(0);
            raylib__BeginDrawing();
            raylib__ClearBackground((Color){0, 0, 0, 255});
            raylib__DrawRectangle(0, 0, ((root__WIDTH / 2)), root__HEIGHT, (Color){0, 0, 0, 255});
            raylib__DrawRectangle(((root__WIDTH / 2)), 0, ((root__WIDTH / 2)), root__HEIGHT, (Color){255, 255, 255, 255});
            raylib__DrawRectangle(ply.x, ply.y, ply.w, ply.h, (Color){255, 255, 255, 255});
            raylib__DrawRectangle(cpu.x, cpu.y, cpu.w, cpu.h, (Color){0, 0, 0, 255});
            const_Array_uint8_t_2_t const pscore = root__intToChar((uint8_t){ply.score});
            const_Array_uint8_t_2_t const cscore = root__intToChar((uint8_t){cpu.score});
            raylib__DrawText((const_Slice_uint8_t){(pscore.data + 0), (2 - 0)}, (((root__WIDTH / 2)) - 200), 30, 48, (Color){255, 255, 255, 255});
            raylib__DrawText((const_Slice_uint8_t){(cscore.data + 0), (2 - 0)}, (((root__WIDTH / 2)) + 200), 30, 48, (Color){0, 0, 0, 255});
            {
__anon_Block_4868289067183140247: (void)(0);
                if ((!((root__checkCollision(ply.x, b.x, ply.y, b.y, ply.w, ply.h, b.r) || root__checkCollision(cpu.x, b.x, cpu.y, b.y, cpu.w, cpu.h, b.r))))) goto __anon_Finally_13414203536031990682;
                {
__anon_Block_5408961738284701175: (void)(0);
                    b.bx = (-1 * b.bx);
                }

                goto __anon_Finally_13414203536031990682;
                __anon_Finally_13414203536031990682: (void)(0);
            }

            cpu.y = (int32_t){(b.y * 0.8)};
            {
__anon_Block_16667537678397990474: (void)(0);
                if ((!((b.x < ((root__WIDTH / 2)))))) goto __anon_Else_11635425079708401102;
                {
__anon_Block_18149526613876181996: (void)(0);
                    raylib__DrawCircle((int32_t){b.x}, (int32_t){b.y}, b.r, (Color){255, 255, 255, 255});
                }

                goto __anon_Finally_16162674634529531010;
                __anon_Else_11635425079708401102: (void)(0);
                {
__anon_Block_3655466039184676393: (void)(0);
                    raylib__DrawCircle((int32_t){b.x}, (int32_t){b.y}, b.r, (Color){0, 0, 0, 255});
                }

                __anon_Finally_16162674634529531010: (void)(0);
            }

            raylib__EndDrawing();
            b.x = (b.bx + b.x);
            b.y = (b.by + b.y);
            {
__anon_Block_16899537894403953799: (void)(0);
                if ((!((b.x < 5)))) goto __anon_Else_8935595935260495472;
                {
__anon_Block_15181178797518472446: (void)(0);
                    cpu.score = (cpu.score + 1);
                    b.x = (((root__WIDTH / 2)) - b.r);
                    b.y = 120;
                    b.bx = -5;
                }

                goto __anon_Finally_18091845151842219177;
                __anon_Else_8935595935260495472: (void)(0);
                {
__anon_Block_456733118060990777: (void)(0);
                    if ((!((b.x > (root__WIDTH - 5))))) goto __anon_Finally_3400285954273524107;
                    {
__anon_Block_1809634041445812895: (void)(0);
                        ply.score = (ply.score + 1);
                        b.x = (((root__WIDTH / 2)) - b.r);
                        b.y = 120;
                        b.bx = 5;
                    }

                    goto __anon_Finally_3400285954273524107;
                    __anon_Finally_3400285954273524107: (void)(0);
                }

                __anon_Finally_18091845151842219177: (void)(0);
            }

            {
__anon_Block_9409808868480793454: (void)(0);
                if ((!((b.y < 5)))) goto __anon_Else_2176238421820118170;
                {
__anon_Block_2525148532737194490: (void)(0);
                    b.by = (-(b.by));
                }

                goto __anon_Finally_2682622441863699739;
                __anon_Else_2176238421820118170: (void)(0);
                {
__anon_Block_782751577281147112: (void)(0);
                    if ((!((b.y > (root__HEIGHT - 5))))) goto __anon_Finally_13312278519466678316;
                    {
__anon_Block_15947550236960500865: (void)(0);
                        b.by = (-((b.by)));
                    }

                    goto __anon_Finally_13312278519466678316;
                    __anon_Finally_13312278519466678316: (void)(0);
                }

                __anon_Finally_2682622441863699739: (void)(0);
            }

            {
__anon_Block_17656754144507250444: (void)(0);
                if ((!((raylib__IsKeyDown(87) || raylib__IsKeyDown(265))))) goto __anon_Else_2962505201174496121;
                {
__anon_Block_7713109206643463141: (void)(0);
                    {
__anon_Block_7300511195807837772: (void)(0);
                        if ((!((ply.y >= 5)))) goto __anon_Finally_4484349695907298513;
                        {
__anon_Block_17733290383163642762: (void)(0);
                            ply.y = (ply.y - 5);
                        }

                        goto __anon_Finally_4484349695907298513;
                        __anon_Finally_4484349695907298513: (void)(0);
                    }

                }

                goto __anon_Finally_779881660930942984;
                __anon_Else_2962505201174496121: (void)(0);
                {
__anon_Block_1357782484136285174: (void)(0);
                    if ((!((raylib__IsKeyDown(83) || raylib__IsKeyDown(264))))) goto __anon_Finally_7021554769915681659;
                    {
__anon_Block_7254980031123428613: (void)(0);
                        {
__anon_Block_10353734897147312515: (void)(0);
                            if ((!((ply.y <= ((root__HEIGHT - ply.h)))))) goto __anon_Finally_7861373757187157877;
                            {
__anon_Block_4056369368137485747: (void)(0);
                                ply.y = (ply.y + 5);
                            }

                            goto __anon_Finally_7861373757187157877;
                            __anon_Finally_7861373757187157877: (void)(0);
                        }

                    }

                    goto __anon_Finally_7021554769915681659;
                    __anon_Finally_7021554769915681659: (void)(0);
                }

                __anon_Finally_779881660930942984: (void)(0);
            }

        }

        $$anon_Loop_15895234769193670539_Check: (void)(0);
        if ((!(raylib__WindowShouldClose()))) goto $$anon_Loop_15895234769193670539_Start;
    }

    raylib__CloseWindow();
    return 0;
}


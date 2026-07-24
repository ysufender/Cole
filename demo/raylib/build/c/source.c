/* Top-level inserted code */


/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#include "forward_decl.h"

int main() {
    return root__main();
}

int32_t const WIDTH = 640;
void raylib__InitWindow(int32_t const width, int32_t const height, Slice_uint8_t const title)
{
$$anon_Block_16049278749992822981: (void)(0);
/* Inserted Code */
 InitWindow(width, height, title.ptr); 
}

int32_t const HEIGHT = 480;
void raylib__SetTargetFPS(int32_t const fps)
{
$$anon_Block_14525175143759077259: (void)(0);
/* Inserted Code */
 SetTargetFPS(fps); 
}

jasl_bool const raylib__WindowShouldClose()
{
$$anon_Block_12882719531207038732: (void)(0);
    jasl_bool res = 0;
/* Inserted Code */
 res = WindowShouldClose(); 
    return res;
}

void raylib__BeginDrawing()
{
$$anon_Block_16233961323067850050: (void)(0);
/* Inserted Code */
 BeginDrawing(); 
}

void raylib__ClearBackground(Color const color)
{
$$anon_Block_14931302220966946916: (void)(0);
/* Inserted Code */
 ClearBackground(color); 
}

Color const Black = (Color){0, 0, 0, 255};
void raylib__DrawRectangle(int32_t const posX, int32_t const posY, int32_t const width, int32_t const height, Color const color)
{
$$anon_Block_2167914373511376141: (void)(0);
/* Inserted Code */
 DrawRectangle(posX, posY, width, height, color); 
}

Color const White = (Color){255, 255, 255, 255};
Array_uint8_t_2_t const root__intToChar(uint8_t a)
{
$$anon_Block_8274098387324605808: (void)(0);
    Array_uint8_t_2_t const str = (Array_uint8_t_2_t){a, 0};
    return str;
}

void raylib__DrawText(Slice_uint8_t const text, int32_t const posX, int32_t const posY, int32_t const fontSize, Color const color)
{
$$anon_Block_9546729811265229851: (void)(0);
/* Inserted Code */
 DrawText(text.ptr, posX, posY, fontSize, color); 
}

jasl_bool const root__checkCollision(int32_t const x1, float const x2, int32_t const y1, float const y2, int32_t const w1, int32_t const h1, float const r)
{
$$anon_Block_2604486134261187998: (void)(0);
    {
$$anon_Block_9944550705755129845: (void)(0);
        if (((((x1 <= (x2 + r)) && (y1 <= (y2 + r))) && (x2 <= (x1 + w1))) && (y2 <= (y1 + h1)))) goto $$anon_Finally_18097166642412114837;
        {
$$anon_Block_13076022316524835480: (void)(0);
            return 1;
        }

        goto $$anon_Finally_18097166642412114837;
        $$anon_Finally_18097166642412114837: (void)(0);
    }

    return 0;
}

void raylib__DrawCircle(int32_t const centerX, int32_t const centerY, float const radius, Color const color)
{
$$anon_Block_15572651889598128231: (void)(0);
/* Inserted Code */
 DrawCircle(centerX, centerY, radius, color); 
}

void raylib__EndDrawing()
{
$$anon_Block_4907636064931205134: (void)(0);
/* Inserted Code */
 BeginDrawing(); 
}

jasl_bool const raylib__IsKeyDown(KeyboardKey const key)
{
$$anon_Block_15809605297042570497: (void)(0);
    jasl_bool res = 0;
/* Inserted Code */
 res = IsKeyDown(key); 
    return res;
}

void raylib__CloseWindow()
{
$$anon_Block_11977092954699203250: (void)(0);
/* Inserted Code */
 CloseWindow(); 
}

int32_t const root__main()
{
$$anon_Block_5555585246545764429: (void)(0);
    root__Player ply = (root__Player){20, 100, 20, 70, 0};
    root__Player cpu = (root__Player){(WIDTH - 35), 100, 20, 70, 0};
    root__Ball b = (root__Ball){((WIDTH / 2) - 10), 120, -5, -5, 10};
    raylib__InitWindow(WIDTH, HEIGHT, (Slice_uint8_t){(uint8_t*)"Ping pong\0", 9});
    raylib__SetTargetFPS(60);
    {
$$anon_Block_1707262033473486372: (void)(0);
        goto $$anon_Loop_5251505954037444658_Check;
        $$anon_Loop_5251505954037444658_Start: (void)(0);
        {
$$anon_Block_10761808952921467351: (void)(0);
            raylib__BeginDrawing();
            raylib__ClearBackground((Color){0, 0, 0, 255});
            raylib__DrawRectangle(0, 0, ((WIDTH / 2)), HEIGHT, (Color){0, 0, 0, 255});
            raylib__DrawRectangle(((WIDTH / 2)), 0, ((WIDTH / 2)), HEIGHT, (Color){255, 255, 255, 255});
            raylib__DrawRectangle(ply.x, ply.y, ply.w, ply.h, (Color){255, 255, 255, 255});
            raylib__DrawRectangle(cpu.x, cpu.y, cpu.w, cpu.h, (Color){0, 0, 0, 255});
            Array_uint8_t_2_t const pscore = root__intToChar((uint8_t){ply.score});
            Array_uint8_t_2_t const cscore = root__intToChar((uint8_t){cpu.score});
            raylib__DrawText((Slice_uint8_t){pscore.data, 2}, (((WIDTH / 2)) - 200), 30, 48, (Color){255, 255, 255, 255});
            raylib__DrawText((Slice_uint8_t){cscore.data, 2}, (((WIDTH / 2)) + 200), 30, 48, (Color){0, 0, 0, 255});
            {
$$anon_Block_11635425079708401102: (void)(0);
                if ((root__checkCollision(ply.x, b.x, ply.y, b.y, ply.w, ply.h, b.r) || root__checkCollision(cpu.x, b.x, cpu.y, b.y, cpu.w, cpu.h, b.r))) goto $$anon_Finally_5408961738284701175;
                {
$$anon_Block_4868289067183140247: (void)(0);
                    b.bx = (-1 * b.bx);
                }

                goto $$anon_Finally_5408961738284701175;
                $$anon_Finally_5408961738284701175: (void)(0);
            }

            cpu.y = (int32_t){b.y};
            {
$$anon_Block_8935595935260495472: (void)(0);
                if ((b.x < ((WIDTH / 2)))) goto $$anon_Else_16162674634529531010;
                {
$$anon_Block_3655466039184676393: (void)(0);
                    raylib__DrawCircle((int32_t){b.x}, (int32_t){b.y}, b.r, (Color){255, 255, 255, 255});
                }

                goto $$anon_Finally_18149526613876181996;
                $$anon_Else_16162674634529531010: (void)(0);
                {
$$anon_Block_16667537678397990474: (void)(0);
                    raylib__DrawCircle((int32_t){b.x}, (int32_t){b.y}, b.r, (Color){0, 0, 0, 255});
                }

                $$anon_Finally_18149526613876181996: (void)(0);
            }

            raylib__EndDrawing();
            b.x = (b.bx + b.x);
            b.y = (b.by + b.y);
            {
$$anon_Block_2176238421820118170: (void)(0);
                if ((b.x < 5)) goto $$anon_Else_18091845151842219177;
                {
$$anon_Block_5315383972134294700: (void)(0);
                    cpu.score = (cpu.score + 1);
                    b.x = ((((float){WIDTH} / 2)) - b.r);
                    b.y = 120;
                    b.bx = -5;
                }

                goto $$anon_Finally_15181178797518472446;
                $$anon_Else_18091845151842219177: (void)(0);
                {
$$anon_Block_16899537894403953799: (void)(0);
                    if ((b.x > (WIDTH - 5))) goto $$anon_Finally_1809634041445812895;
                    {
$$anon_Block_456733118060990777: (void)(0);
                        ply.score = (ply.score + 1);
                        b.x = ((((float){WIDTH} / 2)) - b.r);
                        b.y = 120;
                        b.bx = 5;
                    }

                    goto $$anon_Finally_1809634041445812895;
                    $$anon_Finally_1809634041445812895: (void)(0);
                }

                $$anon_Finally_15181178797518472446: (void)(0);
            }

            {
$$anon_Block_2962505201174496121: (void)(0);
                if ((b.y < 5)) goto $$anon_Else_2682622441863699739;
                {
$$anon_Block_8984152290478481302: (void)(0);
                    b.by = -(b.by);
                }

                goto $$anon_Finally_2525148532737194490;
                $$anon_Else_2682622441863699739: (void)(0);
                {
$$anon_Block_9409808868480793454: (void)(0);
                    if ((b.y > (HEIGHT - 5))) goto $$anon_Finally_15947550236960500865;
                    {
$$anon_Block_782751577281147112: (void)(0);
                        b.by = -((b.by));
                    }

                    goto $$anon_Finally_15947550236960500865;
                    $$anon_Finally_15947550236960500865: (void)(0);
                }

                $$anon_Finally_2525148532737194490: (void)(0);
            }

            {
$$anon_Block_12490044124299982418: (void)(0);
                if ((raylib__IsKeyDown((KeyboardKey){40}) || raylib__IsKeyDown((KeyboardKey){58}))) goto $$anon_Else_779881660930942984;
                {
$$anon_Block_10926936045023930734: (void)(0);
                    {
$$anon_Block_7713109206643463141: (void)(0);
                        if ((ply.y >= 5)) goto $$anon_Finally_17733290383163642762;
                        {
$$anon_Block_7300511195807837772: (void)(0);
                            ply.y = (ply.y - 5);
                        }

                        goto $$anon_Finally_17733290383163642762;
                        $$anon_Finally_17733290383163642762: (void)(0);
                    }

                }

                goto $$anon_Finally_4220994239978015479;
                $$anon_Else_779881660930942984: (void)(0);
                {
$$anon_Block_17656754144507250444: (void)(0);
                    if ((raylib__IsKeyDown((KeyboardKey){36}) || raylib__IsKeyDown((KeyboardKey){57}))) goto $$anon_Finally_1067929922617394944;
                    {
$$anon_Block_1357782484136285174: (void)(0);
                        {
$$anon_Block_7254980031123428613: (void)(0);
                            if ((ply.y <= ((HEIGHT - ply.h)))) goto $$anon_Finally_4056369368137485747;
                            {
$$anon_Block_10353734897147312515: (void)(0);
                                ply.y = (ply.y + 5);
                            }

                            goto $$anon_Finally_4056369368137485747;
                            $$anon_Finally_4056369368137485747: (void)(0);
                        }

                    }

                    goto $$anon_Finally_1067929922617394944;
                    $$anon_Finally_1067929922617394944: (void)(0);
                }

                $$anon_Finally_4220994239978015479: (void)(0);
            }

        }

        $$anon_Loop_5251505954037444658_Check: (void)(0);
        if (!(raylib__WindowShouldClose())) goto $$anon_Loop_5251505954037444658_Start;
    }

    raylib__CloseWindow();
    return 0;
}


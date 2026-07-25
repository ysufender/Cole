/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#ifndef JASL_CODEGEN_C_FORWARD_DECL_H
#define JASL_CODEGEN_C_FORWARD_DECL_H

#include <stdint.h>

typedef uint8_t jasl_bool;

/* Top-level inserted code */
#include "raylib.h"


typedef struct { uint8_t* ptr; uint32_t len; } Slice_uint8_t;

typedef struct { uint8_t data[2]; } Array_uint8_t_2_t;

typedef struct {
	int32_t x;
	int32_t y;
	int32_t const w;
	int32_t const h;
	int32_t score;
} root__Player;

extern int32_t const WIDTH;

typedef struct {
	float x;
	float y;
	float bx;
	float by;
	float const r;
} root__Ball;

void raylib__InitWindow(int32_t const, int32_t const, Slice_uint8_t const);

extern int32_t const HEIGHT;

void raylib__SetTargetFPS(int32_t const);

jasl_bool const raylib__WindowShouldClose();

void raylib__BeginDrawing();

void raylib__ClearBackground(Color const);

extern Color const Black;

void raylib__DrawRectangle(int32_t const, int32_t const, int32_t const, int32_t const, Color const);

extern Color const White;

Array_uint8_t_2_t const root__intToChar(uint8_t);

void raylib__DrawText(Slice_uint8_t const, int32_t const, int32_t const, int32_t const, Color const);

jasl_bool const root__checkCollision(int32_t const, float const, int32_t const, float const, int32_t const, int32_t const, float const);

void raylib__DrawCircle(int32_t const, int32_t const, float const, Color const);

void raylib__EndDrawing();

jasl_bool const raylib__IsKeyDown(uint32_t const);

extern uint32_t const W;

extern uint32_t const UP;

extern uint32_t const S;

extern uint32_t const DOWN;

void raylib__CloseWindow();

int32_t const root__main();


#endif /* JASL_CODEGEN_C_FORWARD_DECL_H */

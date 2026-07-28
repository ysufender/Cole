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


typedef struct const_Slice_uint8_t { uint8_t* ptr; uint32_t len; } const_Slice_uint8_t;

typedef struct const_Slice_const_Slice_uint8_t { const_Slice_uint8_t const* ptr; uint32_t len; } const_Slice_const_Slice_uint8_t;

typedef struct const_Array_uint8_t_2_t { uint8_t data[2]; } const_Array_uint8_t_2_t;

typedef struct root__Player {
	int32_t x;
	int32_t y;
	int32_t const w;
	int32_t const h;
	int32_t score;
} root__Player;

extern int32_t const root__WIDTH;

typedef struct root__Ball {
	float x;
	float y;
	float bx;
	float by;
	float const r;
} root__Ball;

void raylib__InitWindow(int32_t const, int32_t const, const_Slice_uint8_t const);

extern int32_t const root__HEIGHT;

void raylib__SetTargetFPS(int32_t const);

jasl_bool const raylib__WindowShouldClose();

void raylib__BeginDrawing();

void raylib__ClearBackground(Color const);

extern Color const Color__Black;

void raylib__DrawRectangle(int32_t const, int32_t const, int32_t const, int32_t const, Color const);

extern Color const Color__White;

const_Array_uint8_t_2_t const root__intToChar(uint8_t);

void raylib__DrawText(const_Slice_uint8_t const, int32_t const, int32_t const, int32_t const, Color const);

jasl_bool const root__checkCollision(int32_t const, float const, int32_t const, float const, int32_t const, int32_t const, float const);

void raylib__DrawCircle(int32_t const, int32_t const, float const, Color const);

void raylib__EndDrawing();

jasl_bool const raylib__IsKeyDown(uint32_t);

extern uint32_t raylib__W;

extern uint32_t raylib__UP;

extern uint32_t raylib__S;

extern uint32_t raylib__DOWN;

void raylib__CloseWindow();

int32_t const root__main(const_Slice_const_Slice_uint8_t const);


#endif /* JASL_CODEGEN_C_FORWARD_DECL_H */

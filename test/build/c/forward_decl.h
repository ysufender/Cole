/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#ifndef JASL_CODEGEN_C_FORWARD_DECLS_H
#define JASL_CODEGEN_C_FORWARD_DECLS_H

#include <stdint.h>

typedef uint8_t jasl_bool;

/* Top-level inserted code */
#include "raylib.h"
#include <stdio.h>


typedef struct { uint8_t* ptr; uint32_t len; } Slice_uint8_t;

void raylib__InitWindow(int32_t const, int32_t const, Slice_uint8_t const);

jasl_bool const raylib__WindowShouldClose();

float const raylib__GetFrameTime();

Vector2 const Vector2__Scale(Vector2 const, float const);

Vector2 const Vector2__Add(Vector2 const, Vector2 const);

float const root__absf(float const);

void std__io__println(Slice_uint8_t const);

void raylib__BeginDrawing();

void raylib__ClearBackground(Color const);

extern Color const Red;

void raylib__DrawText(Slice_uint8_t const, int32_t const, int32_t const, int32_t const, Color const);

extern Color const Blue;

void raylib__DrawCircle(Vector2 const, float const, Color const);

void raylib__EndDrawing();

void raylib__CloseWindow();

int32_t const root__main();


#endif /* JASL_CODEGEN_C_FORWARD_DECLS_H */

/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#ifndef JASL_CODEGEN_C_FORWARD_DECLS_H
#define JASL_CODEGEN_C_FORWARD_DECLS_H

#include <stdint.h>

typedef uint8_t jasl_bool;

/* Top-level inserted code */
#include <stdio.h>
#include "raylib.h"


typedef struct { uint8_t* ptr; uint32_t len; } Slice_uint8_t;

void std__io__InitWindow(int32_t const, int32_t const, Slice_uint8_t const);

jasl_bool const std__io__WindowShouldClose();

float const std__io__GetFrameTime();

Vector2 const std__io__Scale(Vector2 const, float const);

Vector2 const std__io__Add(Vector2 const, Vector2 const);

float const root__absf(float const);

void raylib__println(Slice_uint8_t const);

void std__io__BeginDrawing();

void std__io__ClearBackground(Color const);

extern Color const Red;

void std__io__DrawText(Slice_uint8_t const, int32_t const, int32_t const, int32_t const, Color const);

extern Color const Blue;

void std__io__DrawCircle(Vector2 const, float const, Color const);

void std__io__EndDrawing();

void std__io__CloseWindow();

int32_t const root__main();


#endif /* JASL_CODEGEN_C_FORWARD_DECLS_H */

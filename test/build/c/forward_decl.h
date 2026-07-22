/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#ifndef JASL_CODEGEN_C_FORWARD_DECLS_H
#define JASL_CODEGEN_C_FORWARD_DECLS_H

#include <stdint.h>

typedef uint8_t jasl_bool;

typedef struct { uint8_t* ptr; uint32_t len; } Slice_uint8_t;

void raylib__InitWindow(int32_t const, int32_t const, Slice_uint8_t const);

typedef struct {
	float const x;
	float const y;
} Vector2;

jasl_bool const raylib__WindowShouldClose();

float const raylib__GetFrameTime();

void raylib__BeginDrawing();

typedef struct {
	uint8_t r;
	uint8_t g;
	uint8_t b;
	uint8_t a;
} Color;

void raylib__ClearBackground(Color const);

extern Color const Red;

void raylib__DrawText(Slice_uint8_t const, int32_t const, int32_t const, int32_t const, Color const);

extern Color const Blue;

void raylib__DrawCircle(Vector2 const, float const, Color const);

void raylib__EndDrawing();

void raylib__CloseWindow();

int32_t const root__main();


#endif /* JASL_CODEGEN_C_FORWARD_DECLS_H */

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

jasl_bool const raylib__WindowShouldClose();

void raylib__CloseWindow();

float const root__func();

int32_t const root__main();


#endif /* JASL_CODEGEN_C_FORWARD_DECLS_H */

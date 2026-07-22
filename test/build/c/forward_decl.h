/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#ifndef JASL_CODEGEN_C_FORWARD_DECLS_H
#define JASL_CODEGEN_C_FORWARD_DECLS_H

#include <stdint.h>

typedef uint8_t jasl_bool;

typedef struct { uint8_t* ptr; uint32_t len; } Slice_uint8_t;

void $$anon_Function_3369953658256787066(int32_t const, int32_t const, Slice_uint8_t const);

typedef struct {
	float x;
	float const y;
} Vector2;

jasl_bool const $$anon_Function_14525175143759077259();

float const $$anon_Function_12882719531207038732();

void $$anon_Function_16233961323067850050(Vector2 const, float const);

void $$anon_Function_3971240746043662859();

typedef struct {
	uint8_t r;
	uint8_t g;
	uint8_t b;
	uint8_t a;
} Color;

void $$anon_Function_2167914373511376141(Color const);

extern Color const Red;

void $$anon_Function_8274098387324605808(Slice_uint8_t const, int32_t const, int32_t const, int32_t const, Color const);

extern Color const Blue;

void $$anon_Function_9546729811265229851(Vector2 const, float const, Color const);

void $$anon_Function_9935609684539616145();

void $$anon_Function_13076022316524835480();

int32_t const $$anon_Function_9569422634429357098();


#endif /* JASL_CODEGEN_C_FORWARD_DECLS_H */

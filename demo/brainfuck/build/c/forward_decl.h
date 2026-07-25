/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#ifndef JASL_CODEGEN_C_FORWARD_DECL_H
#define JASL_CODEGEN_C_FORWARD_DECL_H

#include <stdint.h>

typedef uint8_t jasl_bool;

/* Top-level inserted code */
#include <stdio.h>
#include <stdio.h>
#include <stdlib.h>


typedef struct const_Slice_uint8_t { uint8_t* ptr; uint32_t len; } const_Slice_uint8_t;

typedef struct const_Slice_const_Slice_uint8_t { const_Slice_uint8_t const* ptr; uint32_t len; } const_Slice_const_Slice_uint8_t;

void std__io__console__println(const_Slice_uint8_t const);

extern int32_t const root__ArgumentError;

void std__io__console__print(const_Slice_uint8_t const);

typedef enum __attribute__((aligned (sizeof(uint32_t)))) std__io__file__OpenMode {
	std__io__file__OpenMode_Read,
	std__io__file__OpenMode_Write,
	std__io__file__OpenMode_ReadWrite,
} std__io__file__OpenMode;

typedef struct std__io__file__File {
	FILE* const handle;
} std__io__file__File;

std__io__file__File const std__io__file__open(const_Slice_uint8_t const, std__io__file__OpenMode const);

jasl_bool const std__io__file__ok(std__io__file__File const);

int32_t const std__io__file__read(std__io__file__File const);

int32_t const root__countBytecodeSize(const_Slice_uint8_t const);

int32_t const root__main(const_Slice_const_Slice_uint8_t const);


#endif /* JASL_CODEGEN_C_FORWARD_DECL_H */

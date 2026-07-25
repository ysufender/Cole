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


typedef struct { uint8_t* ptr; uint32_t len; } Slice_uint8_t;

typedef enum __attribute__((aligned (sizeof(uint32_t)))) {
	std__io__OpenMode_Read,
	std__io__OpenMode_Write,
	std__io__OpenMode_ReadWrite,
} std__io__OpenMode;

typedef struct {
	FILE* const handle;
	std__io__OpenMode const mode;
} std__io__File;

std__io__File const std__io__File__open(Slice_uint8_t const, std__io__OpenMode const);

jasl_bool const std__io__File__ok(std__io__File const);

void std__io__println(Slice_uint8_t const);

void std__io__File__writeln(std__io__File const, Slice_uint8_t const);

void std__io__File__close(std__io__File const);

int32_t const root__main();


#endif /* JASL_CODEGEN_C_FORWARD_DECL_H */

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

typedef struct const_Slice_void { void* ptr; uint32_t len; } const_Slice_void;

typedef struct const_Array_uint8_t_1000_t { uint8_t data[1000]; } const_Array_uint8_t_1000_t;

typedef struct const_Array_uint8_t_2_t { uint8_t data[2]; } const_Array_uint8_t_2_t;

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

void std__io__file__close(std__io__file__File const);

int32_t const root__countBytecodeSize(const_Slice_uint8_t const);

extern int32_t const root__CompilationError;

extern uint32_t const cpu__maxBytecode;

void* const std__memory__c__alloc(uint32_t const, uint32_t const);

jasl_bool const root__populateBytecode(const_Slice_uint8_t const, const_Slice_uint8_t const);

extern uint32_t const cpu__maxMemory;

typedef struct cpu__CPU {
	const_Array_uint8_t_1000_t const memory;
	const_Slice_uint8_t const bytecode;
	uint32_t ip;
	uint32_t dp;
} cpu__CPU;

cpu__CPU const cpu__init(const_Slice_uint8_t const);

extern int32_t const std__ascii__NULL;

const_Array_uint8_t_2_t const std__ascii__charToStr(uint8_t);

int32_t const std__io__console__read();

jasl_bool const cpu__cycle(cpu__CPU* const);

void std__memory__c__free(void* const);

extern int32_t const root__Ok;

int32_t const root__main(const_Slice_const_Slice_uint8_t const);


#endif /* JASL_CODEGEN_C_FORWARD_DECL_H */

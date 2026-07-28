/* Top-level inserted code */
#ifdef DEBUG
#if defined(WIN32)
#include <intrin.h>
#define BREAKPOINT __debugbreak()
#else
#include <signal.h>
#define BREAKPOINT raise(SIGTRAP)
#endif
#else
#define BREAKPOINT
#endif

/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#include <stdlib.h>
#include <string.h>

#include "forward_decl.h"

int main(int const argc, char const* const* const argv) {
    const_Slice_uint8_t* const strings = (const_Slice_uint8_t*)malloc(sizeof(const_Slice_uint8_t) * (argc - 1));
    for (int i = 1; i < argc; i++) {
        strings[i - 1].ptr = (uint8_t*)argv[i];
        strings[i - 1].len = strlen(argv[i]);
    }
    const_Slice_const_Slice_uint8_t const args = {
        .ptr = strings,
        .len = argc - 1,
    };

    return root__main(args);
}


void std__io__console__println(const_Slice_uint8_t const msg)
{
__anon_Block_14394194981965165550: (void)(0);
/* Inserted Code */
 printf("%s\n", msg.ptr); 
}

int32_t const root__ArgumentError = 1;
void std__io__console__print(const_Slice_uint8_t const msg)
{
__anon_Block_16049278749992822981: (void)(0);
/* Inserted Code */
 printf("%s", msg.ptr); 
}

std__io__file__File const std__io__file__open(const_Slice_uint8_t const path, std__io__file__OpenMode const mode)
{
__anon_Block_15901871329232600808: (void)(0);
    FILE* file;
    {
__anon_Switch_17599025288361479413: (void)(0);
        {
__anon_Case_12731370710357201570: (void)(0);
            if ((mode != (std__io__file__OpenMode){0})) goto __anon_CaseEnd_16233961323067850050;
/* Inserted Code */
 file = fopen(path.ptr, "r"); 
            goto __anon_SwitchEnd_15901871329232600808;
            __anon_CaseEnd_16233961323067850050: (void)(0);
        }

        {
__anon_Case_14931302220966946916: (void)(0);
            if ((mode != (std__io__file__OpenMode){1})) goto __anon_CaseEnd_3971240746043662859;
/* Inserted Code */
 file = fopen(path.ptr, "w"); 
            goto __anon_SwitchEnd_15901871329232600808;
            __anon_CaseEnd_3971240746043662859: (void)(0);
        }

/* Inserted Code */
 file = fopen(path.ptr, "w+"); 
        __anon_SwitchEnd_15901871329232600808: (void)(0);
    }

    return (std__io__file__File){file};
}

jasl_bool const std__io__file__ok(std__io__file__File const file)
{
__anon_Block_12731370710357201570: (void)(0);
    jasl_bool status = 0;
/* Inserted Code */
 status = file.handle == NULL; 
    return (!(status));
}

int32_t const std__io__file__read(std__io__file__File const file)
{
__anon_Block_14931302220966946916: (void)(0);
    int32_t res = -1;
/* Inserted Code */
 res = fgetc(file.handle); 
    return res;
}

void std__io__file__close(std__io__file__File const file)
{
__anon_Block_2167914373511376141: (void)(0);
/* Inserted Code */
 fclose(file.handle); 
}

int32_t const root__countBytecodeSize(const_Slice_uint8_t const path)
{
__anon_Block_13076022316524835480: (void)(0);
    std__io__file__File const source = std__io__file__open(path, (std__io__file__OpenMode){0});
    {
__anon_Block_8281603307388481355: (void)(0);
        if ((!((!(std__io__file__ok(source)))))) goto __anon_Finally_2428034255698430285;
        {
__anon_Block_9546729811265229851: (void)(0);
            std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Failed to read file at path: ", 29});
            std__io__console__println(path);
            return -1;
        }

        goto __anon_Finally_2428034255698430285;
        __anon_Finally_2428034255698430285: (void)(0);
    }

    uint32_t count = 0;
    int32_t ch = std__io__file__read(source);
    __anon_OptimizedLoop_18097166642412114837: (void)(0);
    std__io__file__close(source);
    return count;
}

int32_t const root__CompilationError = 2;
uint32_t const cpu__maxBytecode = 2000;
void* const std__c__memory__create(void* const ctx, uint32_t const size)
{
__anon_Block_16745735485697338677: (void)(0);
    void* res;
/* Inserted Code */
 res = malloc(size); 
    return res;
}

void std__c__memory__destroy(void* const ctx, void* const ptr)
{
__anon_Block_9569422634429357098: (void)(0);
/* Inserted Code */
 free(ptr); 
}

void* const std__c__memory__alloc(void* const ctx, uint32_t const count, uint32_t const sizeByteEach)
{
__anon_Block_1433292512581475656: (void)(0);
    void* res;
/* Inserted Code */
 res = calloc(count, sizeByteEach); 
    return res;
}

void std__c__memory__free(void* const ctx, void* const ptr)
{
__anon_Block_15809605297042570497: (void)(0);
/* Inserted Code */
 free(ptr); 
}

std__memory__allocator__RawAllocator const std__c__memory__Allocator = (std__memory__allocator__RawAllocator){((void* const)NULL), std__c__memory__create, std__c__memory__destroy, std__c__memory__alloc, std__c__memory__free};
std__memory__allocator__RawAllocator const std__c__Allocator = (std__memory__allocator__RawAllocator){((void* const)NULL), std__c__memory__create, std__c__memory__destroy, std__c__memory__alloc, std__c__memory__free};
void* const std__memory__allocator__alloc(std__memory__allocator__RawAllocator const self, uint32_t const count, uint32_t const sizeBytesEach)
{
__anon_Block_11977092954699203250: (void)(0);
    return self.alloc(self.context, count, sizeBytesEach);
}

jasl_bool const root__populateBytecode(const_Slice_uint8_t const bytecode, const_Slice_uint8_t const path)
{
__anon_Block_18149526613876181996: (void)(0);
    std__io__file__File const source = std__io__file__open(path, (std__io__file__OpenMode){0});
    {
__anon_Block_4868289067183140247: (void)(0);
        if ((!((!(std__io__file__ok(source)))))) goto __anon_Finally_13414203536031990682;
        {
__anon_Block_5408961738284701175: (void)(0);
            std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Failed to read file at path: ", 29});
            std__io__console__println(path);
            return 0;
        }

        goto __anon_Finally_13414203536031990682;
        __anon_Finally_13414203536031990682: (void)(0);
    }

    uint32_t idx = 0;
    int32_t ch = std__io__file__read(source);
    __anon_OptimizedLoop_16162674634529531010: (void)(0);
    std__io__file__close(source);
    return 1;
}

uint32_t const cpu__maxMemory = 2000;
cpu__CPU const cpu__init(const_Slice_uint8_t const bytecode)
{
__anon_Block_8935595935260495472: (void)(0);
    return (cpu__CPU){(Array_uint8_t_2000_t){ }, bytecode, 0, 0};
}

int32_t const std__ascii__NULL = 0;
const_Array_uint8_t_2_t const std__ascii__charToStr(uint8_t const ch)
{
__anon_Block_15181178797518472446: (void)(0);
    return (const_Array_uint8_t_2_t){ch, std__ascii__NULL};
}

int32_t const std__io__console__read()
{
__anon_Block_3400285954273524107: (void)(0);
    int32_t res = 0;
/* Inserted Code */
 res = fgetc(stdin); 
    return res;
}

void cpu__skipForward(cpu__CPU* const cpu)
{
__anon_Block_2176238421820118170: (void)(0);
    uint32_t count = 1;
    __anon_OptimizedLoop_16899537894403953799: (void)(0);
}

void cpu__skipBackward(cpu__CPU* const cpu)
{
__anon_Block_13312278519466678316: (void)(0);
    uint32_t count = 1;
    __anon_OptimizedLoop_8984152290478481302: (void)(0);
}

jasl_bool const cpu__cycle(cpu__CPU* const cpu)
{
__anon_Block_10063542700695191050: (void)(0);
    {
__anon_Block_779881660930942984: (void)(0);
        if ((!(((*((&((*(cpu)).ip)))) >= (*((&((*(cpu)).bytecode)))).len)))) goto __anon_Finally_9409808868480793454;
        {
__anon_Block_2962505201174496121: (void)(0);
            return 0;
        }

        goto __anon_Finally_9409808868480793454;
        __anon_Finally_9409808868480793454: (void)(0);
    }

    uint8_t const op = (*(((*(cpu)).bytecode.ptr + (*(cpu)).ip)));
    {
__anon_Block_16174043371978850487: (void)(0);
        if ((!((op == 60)))) goto __anon_Else_4220994239978015479;
        {
__anon_Block_17733290383163642762: (void)(0);
            (*((&((*(cpu)).dp)))) = ((*((&((*(cpu)).dp)))) - 1);
        }

        goto __anon_Finally_4484349695907298513;
        __anon_Else_4220994239978015479: (void)(0);
        {
__anon_Block_7223447032803900159: (void)(0);
            if ((!((op == 62)))) goto __anon_Else_7300511195807837772;
            {
__anon_Block_10926936045023930734: (void)(0);
                (*((&((*(cpu)).dp)))) = ((*((&((*(cpu)).dp)))) + 1);
            }

            goto __anon_Finally_7713109206643463141;
            __anon_Else_7300511195807837772: (void)(0);
            {
__anon_Block_10037347954841597513: (void)(0);
                if ((!((op == 43)))) goto __anon_Else_7021554769915681659;
                {
__anon_Block_7861373757187157877: (void)(0);
                    (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) + 1);
                }

                goto __anon_Finally_1067929922617394944;
                __anon_Else_7021554769915681659: (void)(0);
                {
__anon_Block_17827319149300544814: (void)(0);
                    if ((!((op == 45)))) goto __anon_Else_4056369368137485747;
                    {
__anon_Block_7254980031123428613: (void)(0);
                        (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) - 1);
                    }

                    goto __anon_Finally_10353734897147312515;
                    __anon_Else_4056369368137485747: (void)(0);
                    {
__anon_Block_3722109792914517513: (void)(0);
                        if ((!((op == 46)))) goto __anon_Else_1357782484136285174;
                        {
__anon_Block_12490044124299982418: (void)(0);
                            std__io__console__print((const_Slice_uint8_t){(std__ascii__charToStr((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp)))))))).data + 0), (2 - 0)});
                        }

                        goto __anon_Finally_17656754144507250444;
                        __anon_Else_1357782484136285174: (void)(0);
                        {
__anon_Block_12968851505893108627: (void)(0);
                            if ((!((op == 44)))) goto __anon_Else_10761808952921467351;
                            {
__anon_Block_5248407906120778274: (void)(0);
                                int32_t const input = std__io__console__read();
                                {
__anon_Block_14543955466527005223: (void)(0);
                                    if ((!((input <= 0)))) goto __anon_Finally_11132128381755658996;
                                    {
__anon_Block_7940574305815784789: (void)(0);
                                        std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Unexpected input.", 17});
                                        return 0;
                                    }

                                    goto __anon_Finally_11132128381755658996;
                                    __anon_Finally_11132128381755658996: (void)(0);
                                }

                                (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = (uint8_t){input};
                            }

                            goto __anon_Finally_1707262033473486372;
                            __anon_Else_10761808952921467351: (void)(0);
                            {
__anon_Block_9330174281472529096: (void)(0);
                                if ((!(((op == 91) && ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) == 0))))) goto __anon_Else_10433700267734284823;
                                {
__anon_Block_17074868050639775437: (void)(0);
                                    cpu__skipForward(cpu);
                                }

                                goto __anon_Finally_14718527048455925063;
                                __anon_Else_10433700267734284823: (void)(0);
                                {
__anon_Block_14509286151471457024: (void)(0);
                                    if ((!(((op == 93) && ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) != 0))))) goto __anon_Finally_16425351936864399788;
                                    {
__anon_Block_5035484593033962329: (void)(0);
                                        cpu__skipBackward(cpu);
                                    }

                                    goto __anon_Finally_16425351936864399788;
                                    __anon_Finally_16425351936864399788: (void)(0);
                                }

                                __anon_Finally_14718527048455925063: (void)(0);
                            }

                            __anon_Finally_1707262033473486372: (void)(0);
                        }

                        __anon_Finally_17656754144507250444: (void)(0);
                    }

                    __anon_Finally_10353734897147312515: (void)(0);
                }

                __anon_Finally_1067929922617394944: (void)(0);
            }

            __anon_Finally_7713109206643463141: (void)(0);
        }

        __anon_Finally_4484349695907298513: (void)(0);
    }

    (*((&((*(cpu)).ip)))) = ((*((&((*(cpu)).ip)))) + 1);
    return 1;
}

void std__memory__allocator__free(std__memory__allocator__RawAllocator const self, void* const arr)
{
__anon_Block_14105684737248972149: (void)(0);
    return self.free(self.context, arr);
}

int32_t const root__Ok = 0;
int32_t const root__main(const_Slice_const_Slice_uint8_t const args)
{
__anon_Block_7770213566642548980: (void)(0);
    {
__anon_Block_6338698242424208039: (void)(0);
        if ((!((args.len != 1)))) goto __anon_Finally_4414800504723860026;
        {
__anon_Block_16904812111535952950: (void)(0);
            std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Expected a single input file.", 29});
            return root__ArgumentError;
        }

        goto __anon_Finally_4414800504723860026;
        __anon_Finally_4414800504723860026: (void)(0);
    }

    const_Slice_uint8_t const path = (*((args.ptr + 0)));
    std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Source File: ", 13});
    std__io__console__println(path);
    int32_t const count = root__countBytecodeSize(path);
    {
__anon_Block_2835172486924942143: (void)(0);
        if ((!((count < 0)))) goto __anon_Else_4007520188368829339;
        {
__anon_Block_14706400349020893043: (void)(0);
            return root__CompilationError;
        }

        goto __anon_Finally_1364611354065822616;
        __anon_Else_4007520188368829339: (void)(0);
        {
__anon_Block_4624728463294738839: (void)(0);
            if ((!((count > 2000)))) goto __anon_Finally_16496529113579175292;
            {
__anon_Block_14889743372749128975: (void)(0);
                std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Given code is too big.", 22});
                return root__CompilationError;
            }

            goto __anon_Finally_16496529113579175292;
            __anon_Finally_16496529113579175292: (void)(0);
        }

        __anon_Finally_1364611354065822616: (void)(0);
    }

    std__memory__allocator__RawAllocator const allocator = (std__memory__allocator__RawAllocator){((void* const)NULL), std__c__memory__create, std__c__memory__destroy, std__c__memory__alloc, std__c__memory__free};
    const_Slice_void const tmp = (const_Slice_void){(std__memory__allocator__alloc((std__memory__allocator__RawAllocator){((void* const)NULL), std__c__memory__create, std__c__memory__destroy, std__c__memory__alloc, std__c__memory__free}, count, 1) + 0), (count - 0)};
    const_Slice_uint8_t const bytecode = (const_Slice_uint8_t){tmp.ptr, ((tmp.len * 1) / 1)};
/* Inserted Code */
 if (bytecode.ptr == NULL) 
    {
__anon_Block_14155460233355763534: (void)(0);
        std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Failed to allocate bytecode.", 28});
/* Inserted Code */
 return 2; 
    }

    {
__anon_Block_11068263668926143820: (void)(0);
        if ((!((!(root__populateBytecode(bytecode, path)))))) goto __anon_Finally_8815600990787957646;
        {
__anon_Block_3394227052479976284: (void)(0);
            std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Failed to read bytecode.", 24});
            return root__CompilationError;
        }

        goto __anon_Finally_8815600990787957646;
        __anon_Finally_8815600990787957646: (void)(0);
    }

    cpu__CPU cpu = cpu__init(bytecode);
    __anon_OptimizedLoop_18303282791192187175: (void)(0);
    std__memory__allocator__free((std__memory__allocator__RawAllocator){((void* const)NULL), std__c__memory__create, std__c__memory__destroy, std__c__memory__alloc, std__c__memory__free}, bytecode.ptr);
    return root__Ok;
}


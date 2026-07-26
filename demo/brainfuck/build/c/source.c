/* Top-level inserted code */


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
$$anon_Block_14394194981965165550: (void)(0);
/* Inserted Code */
 printf("%s\n", msg.ptr); 
}

int32_t const root__ArgumentError = 1;
void std__io__console__print(const_Slice_uint8_t const msg)
{
$$anon_Block_16049278749992822981: (void)(0);
/* Inserted Code */
 printf("%s", msg.ptr); 
}

std__io__file__File const std__io__file__open(const_Slice_uint8_t const path, std__io__file__OpenMode const mode)
{
$$anon_Block_15901871329232600808: (void)(0);
    FILE* file;
    {
$$anon_Switch_17599025288361479413: (void)(0);
        {
$$anon_Case_12731370710357201570: (void)(0);
            if ((mode != (std__io__file__OpenMode){0})) goto $$anon_CaseEnd_16233961323067850050;
/* Inserted Code */
 file = fopen(path.ptr, "r"); 
            goto $$anon_SwitchEnd_15901871329232600808;
            $$anon_CaseEnd_16233961323067850050: (void)(0);
        }

        {
$$anon_Case_14931302220966946916: (void)(0);
            if ((mode != (std__io__file__OpenMode){1})) goto $$anon_CaseEnd_3971240746043662859;
/* Inserted Code */
 file = fopen(path.ptr, "w"); 
            goto $$anon_SwitchEnd_15901871329232600808;
            $$anon_CaseEnd_3971240746043662859: (void)(0);
        }

/* Inserted Code */
 file = fopen(path.ptr, "w+"); 
        $$anon_SwitchEnd_15901871329232600808: (void)(0);
    }

    return (std__io__file__File){file};
}

jasl_bool const std__io__file__ok(std__io__file__File const file)
{
$$anon_Block_12731370710357201570: (void)(0);
    jasl_bool status = 0;
/* Inserted Code */
 status = file.handle == NULL; 
    return (!(status));
}

int32_t const std__io__file__read(std__io__file__File const file)
{
$$anon_Block_14931302220966946916: (void)(0);
    int32_t res = -1;
/* Inserted Code */
 res = fgetc(file.handle); 
    return res;
}

void std__io__file__close(std__io__file__File const file)
{
$$anon_Block_2167914373511376141: (void)(0);
/* Inserted Code */
 fclose(file.handle); 
}

int32_t const root__countBytecodeSize(const_Slice_uint8_t const path)
{
$$anon_Block_4907636064931205134: (void)(0);
    std__io__file__File const source = std__io__file__open(path, (std__io__file__OpenMode){0});
    {
$$anon_Block_8281603307388481355: (void)(0);
        if ((!((!(std__io__file__ok(source)))))) goto $$anon_Finally_2428034255698430285;
        {
$$anon_Block_9546729811265229851: (void)(0);
            std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Failed to read file at path: ", 29});
            std__io__console__println(path);
            return -1;
        }

        goto $$anon_Finally_2428034255698430285;
        $$anon_Finally_2428034255698430285: (void)(0);
    }

    uint32_t count = 0;
    int32_t ch = std__io__file__read(source);
    {
$$anon_Block_9569422634429357098: (void)(0);
        goto $$anon_Loop_9935609684539616145_Check;
        $$anon_Loop_9935609684539616145_Start: (void)(0);
        {
$$anon_Block_15572651889598128231: (void)(0);
            uint8_t realCh = (uint8_t){ch};
            {
$$anon_Block_16745735485697338677: (void)(0);
                if ((!(((realCh == 91) || (realCh == 93))))) goto $$anon_Else_18097166642412114837;
                {
$$anon_Block_9944550705755129845: (void)(0);
                    count = (count + 2);
                    std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Loops are not yet supported.", 28});
                    return -1;
                }

                goto $$anon_Finally_13076022316524835480;
                $$anon_Else_18097166642412114837: (void)(0);
                {
$$anon_Block_2604486134261187998: (void)(0);
                    count = (count + 1);
                }

                $$anon_Finally_13076022316524835480: (void)(0);
            }

            ch = std__io__file__read(source);
        }

        $$anon_Loop_9935609684539616145_Check: (void)(0);
        if ((ch > 0)) goto $$anon_Loop_9935609684539616145_Start;
    }

    std__io__file__close(source);
    return count;
}

int32_t const root__CompilationError = 2;
uint32_t const cpu__maxBytecode = 1000;
void* const std__memory__c__alloc(uint32_t const count, uint32_t const sizeByteEach)
{
$$anon_Block_12022879660635692288: (void)(0);
    void* res;
/* Inserted Code */
 res = calloc(count, sizeByteEach); 
    return res;
}

jasl_bool const root__populateBytecode(const_Slice_uint8_t const bytecode, const_Slice_uint8_t const path)
{
$$anon_Block_16667537678397990474: (void)(0);
    std__io__file__File const source = std__io__file__open(path, (std__io__file__OpenMode){0});
    {
$$anon_Block_5251505954037444658: (void)(0);
        if ((!((!(std__io__file__ok(source)))))) goto $$anon_Finally_11977092954699203250;
        {
$$anon_Block_15895234769193670539: (void)(0);
            std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Failed to read file at path: ", 29});
            std__io__console__println(path);
            return 0;
        }

        goto $$anon_Finally_11977092954699203250;
        $$anon_Finally_11977092954699203250: (void)(0);
    }

    uint32_t idx = 0;
    int32_t ch = std__io__file__read(source);
    {
$$anon_Block_3655466039184676393: (void)(0);
        goto $$anon_Loop_13414203536031990682_Check;
        $$anon_Loop_13414203536031990682_Start: (void)(0);
        {
$$anon_Block_18149526613876181996: (void)(0);
            uint8_t realCh = (uint8_t){ch};
            {
$$anon_Block_16162674634529531010: (void)(0);
                if ((!(((realCh == 91) || (realCh == 93))))) goto $$anon_Finally_4868289067183140247;
                {
$$anon_Block_11635425079708401102: (void)(0);
                    std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Loops are not yet supported.", 28});
                    return 0;
                }

                goto $$anon_Finally_4868289067183140247;
                $$anon_Finally_4868289067183140247: (void)(0);
            }

            (*((bytecode.ptr + idx))) = (uint8_t){ch};
            ch = std__io__file__read(source);
            idx = (idx + 1);
        }

        $$anon_Loop_13414203536031990682_Check: (void)(0);
        if ((ch >= 0)) goto $$anon_Loop_13414203536031990682_Start;
    }

    std__io__file__close(source);
    return 1;
}

uint32_t const cpu__maxMemory = 1000;
cpu__CPU const cpu__init(const_Slice_uint8_t const bytecode)
{
$$anon_Block_15181178797518472446: (void)(0);
    return (cpu__CPU){(const_Array_uint8_t_1000_t const){ }, bytecode, 0, 0};
}

int32_t const std__ascii__NULL = 0;
const_Array_uint8_t_2_t const std__ascii__charToStr(uint8_t ch)
{
$$anon_Block_3400285954273524107: (void)(0);
    return (const_Array_uint8_t_2_t){ch, std__ascii__NULL};
}

int32_t const std__io__console__read()
{
$$anon_Block_456733118060990777: (void)(0);
    int32_t res = 0;
/* Inserted Code */
 res = fgetc(stdin); 
    return res;
}

jasl_bool const cpu__cycle(cpu__CPU* const cpu)
{
$$anon_Block_10433700267734284823: (void)(0);
    {
$$anon_Block_8984152290478481302: (void)(0);
        if ((!(((*((&((*(cpu)).ip)))) >= (*((&((*(cpu)).bytecode)))).len)))) goto $$anon_Finally_2682622441863699739;
        {
$$anon_Block_2525148532737194490: (void)(0);
            return 0;
        }

        goto $$anon_Finally_2682622441863699739;
        $$anon_Finally_2682622441863699739: (void)(0);
    }

    uint8_t op = (*(((*(cpu)).bytecode.ptr + (*(cpu)).ip)));
    {
$$anon_Block_5248407906120778274: (void)(0);
        if ((!((op == 60)))) goto $$anon_Else_13312278519466678316;
        {
$$anon_Block_782751577281147112: (void)(0);
            (*((&((*(cpu)).dp)))) = ((*((&((*(cpu)).dp)))) - 1);
        }

        goto $$anon_Finally_15947550236960500865;
        $$anon_Else_13312278519466678316: (void)(0);
        {
$$anon_Block_14543955466527005223: (void)(0);
            if ((!((op == 62)))) goto $$anon_Else_9409808868480793454;
            {
$$anon_Block_779881660930942984: (void)(0);
                (*((&((*(cpu)).dp)))) = ((*((&((*(cpu)).dp)))) + 1);
            }

            goto $$anon_Finally_2962505201174496121;
            $$anon_Else_9409808868480793454: (void)(0);
            {
$$anon_Block_7940574305815784789: (void)(0);
                if ((!((op == 43)))) goto $$anon_Else_4220994239978015479;
                {
$$anon_Block_17733290383163642762: (void)(0);
                    (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) + 1);
                }

                goto $$anon_Finally_4484349695907298513;
                $$anon_Else_4220994239978015479: (void)(0);
                {
$$anon_Block_11132128381755658996: (void)(0);
                    if ((!((op == 45)))) goto $$anon_Else_7300511195807837772;
                    {
$$anon_Block_10926936045023930734: (void)(0);
                        (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) - 1);
                    }

                    goto $$anon_Finally_7713109206643463141;
                    $$anon_Else_7300511195807837772: (void)(0);
                    {
$$anon_Block_5555585246545764429: (void)(0);
                        if ((!((op == 46)))) goto $$anon_Else_7021554769915681659;
                        {
$$anon_Block_7861373757187157877: (void)(0);
                            std__io__console__print((const_Slice_uint8_t){(std__ascii__charToStr((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp)))))))).data + 0), (2 - 0)});
                        }

                        goto $$anon_Finally_1067929922617394944;
                        $$anon_Else_7021554769915681659: (void)(0);
                        {
$$anon_Block_1707262033473486372: (void)(0);
                            if ((!((op == 44)))) goto $$anon_Finally_10353734897147312515;
                            {
$$anon_Block_10761808952921467351: (void)(0);
                                int32_t const input = std__io__console__read();
                                {
$$anon_Block_12490044124299982418: (void)(0);
                                    if ((!((input <= 0)))) goto $$anon_Finally_1357782484136285174;
                                    {
$$anon_Block_17656754144507250444: (void)(0);
                                        std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Unexpected input.", 17});
                                        return 0;
                                    }

                                    goto $$anon_Finally_1357782484136285174;
                                    $$anon_Finally_1357782484136285174: (void)(0);
                                }

                                (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = (uint8_t){input};
                            }

                            goto $$anon_Finally_10353734897147312515;
                            $$anon_Finally_10353734897147312515: (void)(0);
                        }

                        $$anon_Finally_1067929922617394944: (void)(0);
                    }

                    $$anon_Finally_7713109206643463141: (void)(0);
                }

                $$anon_Finally_4484349695907298513: (void)(0);
            }

            $$anon_Finally_2962505201174496121: (void)(0);
        }

        $$anon_Finally_15947550236960500865: (void)(0);
    }

    (*((&((*(cpu)).ip)))) = ((*((&((*(cpu)).ip)))) + 1);
    return 1;
}

void std__memory__c__free(void* const ptr)
{
$$anon_Block_17074868050639775437: (void)(0);
/* Inserted Code */
 free(ptr); 
}

int32_t const root__Ok = 0;
int32_t const root__main(const_Slice_const_Slice_uint8_t const args)
{
$$anon_Block_14706400349020893043: (void)(0);
    {
$$anon_Block_9330174281472529096: (void)(0);
        if ((!((args.len != 1)))) goto $$anon_Finally_5035484593033962329;
        {
$$anon_Block_14509286151471457024: (void)(0);
            std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Expected a single input file.", 29});
            return root__ArgumentError;
        }

        goto $$anon_Finally_5035484593033962329;
        $$anon_Finally_5035484593033962329: (void)(0);
    }

    const_Slice_uint8_t const path = (*((args.ptr + 0)));
    std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Source File: ", 13});
    std__io__console__println(path);
    int32_t const count = root__countBytecodeSize(path);
    {
$$anon_Block_9675375518844286457: (void)(0);
        if ((!((count < 0)))) goto $$anon_Else_12968851505893108627;
        {
$$anon_Block_17827319149300544814: (void)(0);
            return root__CompilationError;
        }

        goto $$anon_Finally_3722109792914517513;
        $$anon_Else_12968851505893108627: (void)(0);
        {
$$anon_Block_10063542700695191050: (void)(0);
            if ((!((count > 1000)))) goto $$anon_Finally_7223447032803900159;
            {
$$anon_Block_16174043371978850487: (void)(0);
                std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Given code is too big.", 22});
                return root__CompilationError;
            }

            goto $$anon_Finally_7223447032803900159;
            $$anon_Finally_7223447032803900159: (void)(0);
        }

        $$anon_Finally_3722109792914517513: (void)(0);
    }

    const_Slice_void const tmp = (const_Slice_void){(std__memory__c__alloc(count, 1) + 0), (count - 0)};
    const_Slice_uint8_t const bytecode = (const_Slice_uint8_t){tmp.ptr, ((tmp.len * 1) / 1)};
/* Inserted Code */
 if (bytecode.ptr == NULL) 
    {
$$anon_Block_14105684737248972149: (void)(0);
        std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Failed to allocate bytecode.", 28});
/* Inserted Code */
 return 2; 
    }

    {
$$anon_Block_16904812111535952950: (void)(0);
        if ((!((!(root__populateBytecode(bytecode, path)))))) goto $$anon_Finally_17798979164330736862;
        {
$$anon_Block_4414800504723860026: (void)(0);
            std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Failed to read bytecode.", 24});
            return root__CompilationError;
        }

        goto $$anon_Finally_17798979164330736862;
        $$anon_Finally_17798979164330736862: (void)(0);
    }

    cpu__CPU cpu = cpu__init(bytecode);
    {
$$anon_Block_1364611354065822616: (void)(0);
        goto $$anon_Loop_6338698242424208039_Check;
        $$anon_Loop_6338698242424208039_Start: (void)(0);
        {
$$anon_Block_4007520188368829339: (void)(0);
        }

        $$anon_Loop_6338698242424208039_Check: (void)(0);
        if (cpu__cycle((&(cpu)))) goto $$anon_Loop_6338698242424208039_Start;
    }

    std__memory__c__free(bytecode.ptr);
    return root__Ok;
}


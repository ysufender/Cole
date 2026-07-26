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
$$anon_Block_9569422634429357098: (void)(0);
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
$$anon_Block_15572651889598128231: (void)(0);
        goto $$anon_Loop_9935609684539616145_Check;
        $$anon_Loop_9935609684539616145_Start: (void)(0);
        {
$$anon_Block_16745735485697338677: (void)(0);
            uint8_t op = (uint8_t){ch};
            {
$$anon_Block_2604486134261187998: (void)(0);
                if ((!(((((((((op == 60) || (op == 91)) || (op == 93)) || (op == 62)) || (op == 43)) || (op == 45)) || (op == 46)) || (op == 44))))) goto $$anon_Finally_13076022316524835480;
                {
$$anon_Block_9944550705755129845: (void)(0);
                    count = (count + 1);
                }

                goto $$anon_Finally_13076022316524835480;
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
uint32_t const cpu__maxBytecode = 2000;
void* const std__memory__c__alloc(uint32_t const count, uint32_t const sizeByteEach)
{
$$anon_Block_1433292512581475656: (void)(0);
    void* res;
/* Inserted Code */
 res = calloc(count, sizeByteEach); 
    return res;
}

jasl_bool const root__populateBytecode(const_Slice_uint8_t const bytecode, const_Slice_uint8_t const path)
{
$$anon_Block_3655466039184676393: (void)(0);
    std__io__file__File const source = std__io__file__open(path, (std__io__file__OpenMode){0});
    {
$$anon_Block_15895234769193670539: (void)(0);
        if ((!((!(std__io__file__ok(source)))))) goto $$anon_Finally_7779630055902864632;
        {
$$anon_Block_11977092954699203250: (void)(0);
            std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Failed to read file at path: ", 29});
            std__io__console__println(path);
            return 0;
        }

        goto $$anon_Finally_7779630055902864632;
        $$anon_Finally_7779630055902864632: (void)(0);
    }

    uint32_t idx = 0;
    int32_t ch = std__io__file__read(source);
    {
$$anon_Block_18149526613876181996: (void)(0);
        goto $$anon_Loop_5251505954037444658_Check;
        $$anon_Loop_5251505954037444658_Start: (void)(0);
        {
$$anon_Block_16162674634529531010: (void)(0);
            uint8_t op = (uint8_t){ch};
            {
$$anon_Block_11635425079708401102: (void)(0);
                if ((!(((((((((op == 60) || (op == 91)) || (op == 93)) || (op == 62)) || (op == 43)) || (op == 45)) || (op == 46)) || (op == 44))))) goto $$anon_Finally_5408961738284701175;
                {
$$anon_Block_4868289067183140247: (void)(0);
                    (*((bytecode.ptr + idx))) = op;
                    idx = (idx + 1);
                }

                goto $$anon_Finally_5408961738284701175;
                $$anon_Finally_5408961738284701175: (void)(0);
            }

            ch = std__io__file__read(source);
        }

        $$anon_Loop_5251505954037444658_Check: (void)(0);
        if ((ch >= 0)) goto $$anon_Loop_5251505954037444658_Start;
    }

    std__io__file__close(source);
    return 1;
}

uint32_t const cpu__maxMemory = 2000;
cpu__CPU const cpu__init(const_Slice_uint8_t const bytecode)
{
$$anon_Block_18091845151842219177: (void)(0);
    return (cpu__CPU){(Array_uint8_t_2000_t){ }, bytecode, 0, 0};
}

int32_t const std__ascii__NULL = 0;
const_Array_uint8_t_2_t const std__ascii__charToStr(uint8_t ch)
{
$$anon_Block_5315383972134294700: (void)(0);
    return (const_Array_uint8_t_2_t){ch, std__ascii__NULL};
}

int32_t const std__io__console__read()
{
$$anon_Block_1809634041445812895: (void)(0);
    int32_t res = 0;
/* Inserted Code */
 res = fgetc(stdin); 
    return res;
}

void cpu__skipForward(cpu__CPU* const cpu)
{
$$anon_Block_4220994239978015479: (void)(0);
    uint32_t count = 1;
    {
$$anon_Block_779881660930942984: (void)(0);
        goto $$anon_Loop_16899537894403953799_Check;
        $$anon_Loop_16899537894403953799_Start: (void)(0);
        {
$$anon_Block_2962505201174496121: (void)(0);
            (*((&((*(cpu)).ip)))) = ((*((&((*(cpu)).ip)))) + 1);
            uint8_t ch = (*(((*((&((*(cpu)).bytecode)))).ptr + (*((&((*(cpu)).ip)))))));
            {
$$anon_Block_9409808868480793454: (void)(0);
                if ((!((ch == 91)))) goto $$anon_Else_2176238421820118170;
                {
$$anon_Block_2525148532737194490: (void)(0);
                    count = (count + 1);
                }

                goto $$anon_Finally_2682622441863699739;
                $$anon_Else_2176238421820118170: (void)(0);
                {
$$anon_Block_782751577281147112: (void)(0);
                    if ((!((ch == 93)))) goto $$anon_Finally_13312278519466678316;
                    {
$$anon_Block_15947550236960500865: (void)(0);
                        count = (count - 1);
                    }

                    goto $$anon_Finally_13312278519466678316;
                    $$anon_Finally_13312278519466678316: (void)(0);
                }

                $$anon_Finally_2682622441863699739: (void)(0);
            }

        }

        $$anon_Loop_16899537894403953799_Check: (void)(0);
        if ((count > 0)) goto $$anon_Loop_16899537894403953799_Start;
    }

}

void cpu__skipBackward(cpu__CPU* const cpu)
{
$$anon_Block_17656754144507250444: (void)(0);
    uint32_t count = 1;
    {
$$anon_Block_1357782484136285174: (void)(0);
        goto $$anon_Loop_17733290383163642762_Check;
        $$anon_Loop_17733290383163642762_Start: (void)(0);
        {
$$anon_Block_7254980031123428613: (void)(0);
            (*((&((*(cpu)).ip)))) = ((*((&((*(cpu)).ip)))) - 1);
            uint8_t ch = (*(((*((&((*(cpu)).bytecode)))).ptr + (*((&((*(cpu)).ip)))))));
            {
$$anon_Block_10353734897147312515: (void)(0);
                if ((!((ch == 91)))) goto $$anon_Else_7300511195807837772;
                {
$$anon_Block_10926936045023930734: (void)(0);
                    count = (count - 1);
                }

                goto $$anon_Finally_7713109206643463141;
                $$anon_Else_7300511195807837772: (void)(0);
                {
$$anon_Block_4056369368137485747: (void)(0);
                    if ((!((ch == 93)))) goto $$anon_Finally_1067929922617394944;
                    {
$$anon_Block_7861373757187157877: (void)(0);
                        count = (count + 1);
                    }

                    goto $$anon_Finally_1067929922617394944;
                    $$anon_Finally_1067929922617394944: (void)(0);
                }

                $$anon_Finally_7713109206643463141: (void)(0);
            }

        }

        $$anon_Loop_17733290383163642762_Check: (void)(0);
        if ((count > 0)) goto $$anon_Loop_17733290383163642762_Start;
    }

}

jasl_bool const cpu__cycle(cpu__CPU* const cpu)
{
$$anon_Block_3394227052479976284: (void)(0);
    {
$$anon_Block_11132128381755658996: (void)(0);
        if ((!(((*((&((*(cpu)).ip)))) >= (*((&((*(cpu)).bytecode)))).len)))) goto $$anon_Finally_1707262033473486372;
        {
$$anon_Block_5555585246545764429: (void)(0);
            return 0;
        }

        goto $$anon_Finally_1707262033473486372;
        $$anon_Finally_1707262033473486372: (void)(0);
    }

    uint8_t op = (*(((*(cpu)).bytecode.ptr + (*(cpu)).ip)));
    {
$$anon_Block_8815600990787957646: (void)(0);
        if ((!((op == 60)))) goto $$anon_Else_7940574305815784789;
        {
$$anon_Block_5248407906120778274: (void)(0);
            (*((&((*(cpu)).dp)))) = ((*((&((*(cpu)).dp)))) - 1);
        }

        goto $$anon_Finally_14543955466527005223;
        $$anon_Else_7940574305815784789: (void)(0);
        {
$$anon_Block_14028012487843577768: (void)(0);
            if ((!((op == 62)))) goto $$anon_Else_10433700267734284823;
            {
$$anon_Block_17074868050639775437: (void)(0);
                (*((&((*(cpu)).dp)))) = ((*((&((*(cpu)).dp)))) + 1);
            }

            goto $$anon_Finally_14718527048455925063;
            $$anon_Else_10433700267734284823: (void)(0);
            {
$$anon_Block_14155460233355763534: (void)(0);
                if ((!((op == 43)))) goto $$anon_Else_8559977782896546461;
                {
$$anon_Block_5035484593033962329: (void)(0);
                    (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) + 1);
                }

                goto $$anon_Finally_16425351936864399788;
                $$anon_Else_8559977782896546461: (void)(0);
                {
$$anon_Block_2835172486924942143: (void)(0);
                    if ((!((op == 45)))) goto $$anon_Else_14509286151471457024;
                    {
$$anon_Block_12968851505893108627: (void)(0);
                        (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) - 1);
                    }

                    goto $$anon_Finally_9330174281472529096;
                    $$anon_Else_14509286151471457024: (void)(0);
                    {
$$anon_Block_4624728463294738839: (void)(0);
                        if ((!((op == 46)))) goto $$anon_Else_3722109792914517513;
                        {
$$anon_Block_10037347954841597513: (void)(0);
                            std__io__console__print((const_Slice_uint8_t){(std__ascii__charToStr((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp)))))))).data + 0), (2 - 0)});
                        }

                        goto $$anon_Finally_17827319149300544814;
                        $$anon_Else_3722109792914517513: (void)(0);
                        {
$$anon_Block_14889743372749128975: (void)(0);
                            if ((!((op == 44)))) goto $$anon_Else_7223447032803900159;
                            {
$$anon_Block_17798979164330736862: (void)(0);
                                int32_t const input = std__io__console__read();
                                {
$$anon_Block_17135741239672107074: (void)(0);
                                    if ((!((input <= 0)))) goto $$anon_Finally_9675375518844286457;
                                    {
$$anon_Block_14105684737248972149: (void)(0);
                                        std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Unexpected input.", 17});
                                        return 0;
                                    }

                                    goto $$anon_Finally_9675375518844286457;
                                    $$anon_Finally_9675375518844286457: (void)(0);
                                }

                                (*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) = (uint8_t){input};
                            }

                            goto $$anon_Finally_16174043371978850487;
                            $$anon_Else_7223447032803900159: (void)(0);
                            {
$$anon_Block_16496529113579175292: (void)(0);
                                if ((!(((op == 91) && ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) == 0))))) goto $$anon_Else_4414800504723860026;
                                {
$$anon_Block_6338698242424208039: (void)(0);
                                    cpu__skipForward(cpu);
                                }

                                goto $$anon_Finally_16904812111535952950;
                                $$anon_Else_4414800504723860026: (void)(0);
                                {
$$anon_Block_17507881688964607934: (void)(0);
                                    if ((!(((op == 93) && ((*(((*((&((*(cpu)).memory)))).data + (*((&((*(cpu)).dp))))))) != 0))))) goto $$anon_Finally_1364611354065822616;
                                    {
$$anon_Block_14706400349020893043: (void)(0);
                                        cpu__skipBackward(cpu);
                                    }

                                    goto $$anon_Finally_1364611354065822616;
                                    $$anon_Finally_1364611354065822616: (void)(0);
                                }

                                $$anon_Finally_16904812111535952950: (void)(0);
                            }

                            $$anon_Finally_16174043371978850487: (void)(0);
                        }

                        $$anon_Finally_17827319149300544814: (void)(0);
                    }

                    $$anon_Finally_9330174281472529096: (void)(0);
                }

                $$anon_Finally_16425351936864399788: (void)(0);
            }

            $$anon_Finally_14718527048455925063: (void)(0);
        }

        $$anon_Finally_14543955466527005223: (void)(0);
    }

    (*((&((*(cpu)).ip)))) = ((*((&((*(cpu)).ip)))) + 1);
    return 1;
}

void std__memory__c__free(void* const ptr)
{
$$anon_Block_6934330156745796889: (void)(0);
/* Inserted Code */
 free(ptr); 
}

int32_t const root__Ok = 0;
int32_t const root__main(const_Slice_const_Slice_uint8_t const args)
{
$$anon_Block_15968992358395932812: (void)(0);
    {
$$anon_Block_6309695915293376712: (void)(0);
        if ((!((args.len != 1)))) goto $$anon_Finally_12654604141755534667;
        {
$$anon_Block_12609902380451393635: (void)(0);
            std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Expected a single input file.", 29});
            return root__ArgumentError;
        }

        goto $$anon_Finally_12654604141755534667;
        $$anon_Finally_12654604141755534667: (void)(0);
    }

    const_Slice_uint8_t const path = (*((args.ptr + 0)));
    std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Source File: ", 13});
    std__io__console__println(path);
    int32_t const count = root__countBytecodeSize(path);
    {
$$anon_Block_12598680759017354249: (void)(0);
        if ((!((count < 0)))) goto $$anon_Else_1009945655364601973;
        {
$$anon_Block_12646100033621404228: (void)(0);
            return root__CompilationError;
        }

        goto $$anon_Finally_8356920768833145104;
        $$anon_Else_1009945655364601973: (void)(0);
        {
$$anon_Block_3929393441632097030: (void)(0);
            if ((!((count > 2000)))) goto $$anon_Finally_9800862614811385960;
            {
$$anon_Block_15620749008848573506: (void)(0);
                std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Given code is too big.", 22});
                return root__CompilationError;
            }

            goto $$anon_Finally_9800862614811385960;
            $$anon_Finally_9800862614811385960: (void)(0);
        }

        $$anon_Finally_8356920768833145104: (void)(0);
    }

    const_Slice_void const tmp = (const_Slice_void){(std__memory__c__alloc(count, 1) + 0), (count - 0)};
    const_Slice_uint8_t const bytecode = (const_Slice_uint8_t){tmp.ptr, ((tmp.len * 1) / 1)};
/* Inserted Code */
 if (bytecode.ptr == NULL) 
    {
$$anon_Block_6682413535436517618: (void)(0);
        std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Failed to allocate bytecode.", 28});
/* Inserted Code */
 return 2; 
    }

    {
$$anon_Block_3469675346843231910: (void)(0);
        if ((!((!(root__populateBytecode(bytecode, path)))))) goto $$anon_Finally_14730816790532107558;
        {
$$anon_Block_2957474504158264498: (void)(0);
            std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Failed to read bytecode.", 24});
            return root__CompilationError;
        }

        goto $$anon_Finally_14730816790532107558;
        $$anon_Finally_14730816790532107558: (void)(0);
    }

    cpu__CPU cpu = cpu__init(bytecode);
    {
$$anon_Block_5531002583840682869: (void)(0);
        goto $$anon_Loop_14210071583308794067_Check;
        $$anon_Loop_14210071583308794067_Start: (void)(0);
        {
$$anon_Block_12415041920294327930: (void)(0);
        }

        $$anon_Loop_14210071583308794067_Check: (void)(0);
        if (cpu__cycle((&(cpu)))) goto $$anon_Loop_14210071583308794067_Start;
    }

    std__memory__c__free(bytecode.ptr);
    return root__Ok;
}


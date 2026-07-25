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
        strings[i - 1].ptr = argv[i];
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
$$anon_Block_2428034255698430285: (void)(0);
    FILE* file;
    {
$$anon_Block_8274098387324605808: (void)(0);
        if (!((mode == (std__io__file__OpenMode){0}))) goto $$anon_Else_15901871329232600808;
        {
$$anon_Block_12731370710357201570: (void)(0);
/* Inserted Code */
 file = fopen(path.ptr, "r"); 
        }

        goto $$anon_Finally_16233961323067850050;
        $$anon_Else_15901871329232600808: (void)(0);
        {
$$anon_Block_2417939988112334111: (void)(0);
            if (!((mode == (std__io__file__OpenMode){1}))) goto $$anon_Else_3971240746043662859;
            {
$$anon_Block_17599025288361479413: (void)(0);
/* Inserted Code */
 file = fopen(path.ptr, "w"); 
            }

            goto $$anon_Finally_14931302220966946916;
            $$anon_Else_3971240746043662859: (void)(0);
            {
$$anon_Block_2167914373511376141: (void)(0);
/* Inserted Code */
 file = fopen(path.ptr, "w+"); 
            }

            $$anon_Finally_14931302220966946916: (void)(0);
        }

        $$anon_Finally_16233961323067850050: (void)(0);
    }

    return (std__io__file__File){file};
}

jasl_bool const std__io__file__ok(std__io__file__File const file)
{
$$anon_Block_8281603307388481355: (void)(0);
    jasl_bool status = 0;
/* Inserted Code */
 status = file.handle == NULL; 
    return !(status);
}

int32_t const std__io__file__read(std__io__file__File const file)
{
$$anon_Block_18097166642412114837: (void)(0);
    int32_t res = -1;
/* Inserted Code */
 res = fgetc(file.handle); 
    return res;
}

int32_t const root__countBytecodeSize(const_Slice_uint8_t const path)
{
$$anon_Block_5251505954037444658: (void)(0);
    std__io__file__File const source = std__io__file__open(path, (std__io__file__OpenMode){0});
    {
$$anon_Block_15572651889598128231: (void)(0);
        if (!(!(std__io__file__ok(source)))) goto $$anon_Finally_2604486134261187998;
        {
$$anon_Block_16745735485697338677: (void)(0);
            std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Failed to read file at path: \0", 29});
            std__io__console__println(path);
            return -1;
        }

        goto $$anon_Finally_2604486134261187998;
        $$anon_Finally_2604486134261187998: (void)(0);
    }

    uint32_t count = 0;
    int32_t ch = std__io__file__read(source);
    {
$$anon_Block_15895234769193670539: (void)(0);
        goto $$anon_Loop_9569422634429357098_Check;
        $$anon_Loop_9569422634429357098_Start: (void)(0);
        {
$$anon_Block_11977092954699203250: (void)(0);
            uint8_t realCh = (uint8_t){ch};
            {
$$anon_Block_7779630055902864632: (void)(0);
                if (!(((realCh == 91) || (realCh == 93)))) goto $$anon_Else_4907636064931205134;
                {
$$anon_Block_12022879660635692288: (void)(0);
                    count = (count + 2);
                }

                goto $$anon_Finally_1433292512581475656;
                $$anon_Else_4907636064931205134: (void)(0);
                {
$$anon_Block_15809605297042570497: (void)(0);
                    count = (count + 1);
                }

                $$anon_Finally_1433292512581475656: (void)(0);
            }

            ch = std__io__file__read(source);
        }

        $$anon_Loop_9569422634429357098_Check: (void)(0);
        if ((ch >= 0)) goto $$anon_Loop_9569422634429357098_Start;
    }

    return (count - 1);
}

int32_t const root__main(const_Slice_const_Slice_uint8_t const args)
{
$$anon_Block_18091845151842219177: (void)(0);
    {
$$anon_Block_16162674634529531010: (void)(0);
        if (!((args.len != 1))) goto $$anon_Finally_4868289067183140247;
        {
$$anon_Block_11635425079708401102: (void)(0);
            std__io__console__println((const_Slice_uint8_t){(uint8_t*)"Expected a single input file.\0", 29});
            return root__ArgumentError;
        }

        goto $$anon_Finally_4868289067183140247;
        $$anon_Finally_4868289067183140247: (void)(0);
    }

    const_Slice_uint8_t const path = *((args.ptr + 0));
    std__io__console__print((const_Slice_uint8_t){(uint8_t*)"Source File: \0", 13});
    std__io__console__println(path);
    int32_t const count = root__countBytecodeSize(path);
    {
$$anon_Block_8935595935260495472: (void)(0);
        if (!((count < 0))) goto $$anon_Finally_3655466039184676393;
        {
$$anon_Block_16667537678397990474: (void)(0);
            return 1;
        }

        goto $$anon_Finally_3655466039184676393;
        $$anon_Finally_3655466039184676393: (void)(0);
    }

/* Inserted Code */
 printf("%d\n", count); 
    return 0;
}


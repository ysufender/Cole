/* Top-level inserted code */


/*
 * This file has been automatically generated
 * by the JASL compiler.
 */

#include "forward_decl.h"

int main() {
    return root__main();
}

std__io__File const std__io__File__open(Slice_uint8_t const path, std__io__OpenMode const mode)
{
$$anon_Block_17599025288361479413: (void)(0);
    FILE* file;
    {
$$anon_Block_14931302220966946916: (void)(0);
        if (!((mode == (std__io__OpenMode){0}))) goto $$anon_Else_5035874246014170412;
        {
$$anon_Block_13496431321134511927: (void)(0);
/* Inserted Code */
 file = fopen(path.ptr, "r"); 
        }

        goto $$anon_Finally_14525175143759077259;
        $$anon_Else_5035874246014170412: (void)(0);
        {
$$anon_Block_3971240746043662859: (void)(0);
            if (!((mode == (std__io__OpenMode){1}))) goto $$anon_Else_12882719531207038732;
            {
$$anon_Block_16233961323067850050: (void)(0);
/* Inserted Code */
 file = fopen(path.ptr, "w"); 
            }

            goto $$anon_Finally_15901871329232600808;
            $$anon_Else_12882719531207038732: (void)(0);
            {
$$anon_Block_12731370710357201570: (void)(0);
/* Inserted Code */
 file = fopen(path.ptr, "w+"); 
            }

            $$anon_Finally_15901871329232600808: (void)(0);
        }

        $$anon_Finally_14525175143759077259: (void)(0);
    }

    return (std__io__File){file, mode};
}

jasl_bool const std__io__File__ok(std__io__File const file)
{
$$anon_Block_2417939988112334111: (void)(0);
    jasl_bool status = 0;
/* Inserted Code */
 status = file.handle != NULL; 
    return status;
}

void std__io__println(Slice_uint8_t const msg)
{
$$anon_Block_2428034255698430285: (void)(0);
/* Inserted Code */
 printf("%s\n", msg.ptr); 
}

void std__io__File__writeln(std__io__File const file, Slice_uint8_t const line)
{
$$anon_Block_8281603307388481355: (void)(0);
/* Inserted Code */
 fprintf(file.handle, line.ptr); 
}

void std__io__File__close(std__io__File const file)
{
$$anon_Block_18097166642412114837: (void)(0);
/* Inserted Code */
 fclose(file.handle); 
}

int32_t const root__main()
{
$$anon_Block_9569422634429357098: (void)(0);
    std__io__File const file = std__io__File__open((Slice_uint8_t){(uint8_t*)"demo/file/mest.txt\0", 18}, (std__io__OpenMode){1});
    {
$$anon_Block_15572651889598128231: (void)(0);
        if (!(!(std__io__File__ok(file)))) goto $$anon_Finally_2604486134261187998;
        {
$$anon_Block_16745735485697338677: (void)(0);
            std__io__println((Slice_uint8_t){(uint8_t*)"Error opening file.\0", 19});
            return 1;
        }

        goto $$anon_Finally_2604486134261187998;
        $$anon_Finally_2604486134261187998: (void)(0);
    }

    std__io__File__writeln(file, (Slice_uint8_t){(uint8_t*)"Hello World\0", 11});
    std__io__File__close(file);
    return 0;
}


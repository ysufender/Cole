typedef struct StackFrame {{
    Slice_uint8_t function;
    Slice_uint8_t file;
    uint32_t line;
    uint32_t col;
}} StackFrame;

typedef struct StackTrace {{
    StackFrame frame;
    struct StackTrace const* next;
}} StackTrace;

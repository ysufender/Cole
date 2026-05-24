// @Specification
//
// 1- Custom types should be converted to namespaces. E.g. :
//        let Type = struct {
//            privField: u32,
//            pub pubField: u32,
//
//            let privDecl: u32 = 0;
//            pub let pubDecl: u32 = 0;
//        };
//
//    should become:
//        typedef struct TypeType {
//          const uint32_t __priv_privField;
//          const uint32_t __pub_pubField;
//        } TypeType;
//
//        const uint32_t __priv_privDecl = 0;
//        const uint32_t __pub_pubDecl = 0;
//
// 2- Plain unions are unsafe C unions, whereas tagged unions are structs
//    with union fields.
//
//        typedef union Untagged {
//            const int32_t __pub_someField;
//        } Untagged;
//
//        typedef struct Tagged {
//            const uin32_t tag;
//            union {
//              const int32_t __pub_someField;
//            } field;
//        } Tagged;

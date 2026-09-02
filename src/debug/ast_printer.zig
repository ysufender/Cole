const std = @import("std");
const common = @import("../core/common.zig");
const defines = @import("../core/defines.zig");
const parser = @import("../parser/parser.zig");
const ModuleList = @import("../parser/prepass.zig").ModuleList;

const AST = parser.AST;
const Expression = parser.Expression;
const Statement = parser.Statement;

const Error = common.CompilerError;

pub fn printASTs(context: *common.CompilerContext, modules: *const ModuleList) void {
    var it = modules.modules.iterator();
    _ = it.next();
    while (it.next()) |module| {
        printAST(module.dataIndex, context);
    }
}

pub fn printAST(astPtr: defines.ASTPtr, context: *common.CompilerContext) void {
    const ast = context.getAST(astPtr);

    var ctx = PrintContext{
        .ast = ast,
        .tokens = context.getTokens(ast.tokens),
        .context = context,
        .file = ast.tokens,
    };
    ctx.print("------------BEGIN  AST: {s}------------\n", .{context.getFileName(astPtr)});
    for (ast.statementMask) |si| {
        ctx.printStmt(@intCast(si), 0);
    }
    ctx.print("------------END  AST: {s}------------\n\n", .{context.getFileName(astPtr)});
}

pub const PrintContext = struct {
    ast: *const AST,
    tokens: *const @TypeOf(@as(*common.CompilerContext, undefined).getTokens(0).*),
    context: *common.CompilerContext,
    file: defines.FilePtr,

    fn write(self: *PrintContext, bytes: []const u8) void {
        common.log.print(self.context.io, "{s}", .{bytes});
    }

    fn print(self: *PrintContext, comptime fmt: []const u8, args: anytype) void {
        common.log.print(self.context.io, fmt, args);
    }

    fn indent(printer: *PrintContext, depth: u32) void {
        var i: u32 = 0;
        while (i < depth) : (i += 1) {
            printer.write(" ");
        }
    }

    fn tokenLexeme(printer: *PrintContext, ptr: defines.TokenPtr) []const u8 {
        return printer.tokens.get(ptr).lexeme(printer.context, printer.file);
    }

    pub fn printStmt(printer: *PrintContext, si: defines.StatementPtr, depth: u32) void {
        const stmts = printer.ast.statements;
        const stype = stmts.items(.type)[si];
        const val   = stmts.items(.value)[si];
        const ex    = printer.ast.extra;

        printer.indent(depth);
        defer printer.write("\n");

        switch (stype) {
            .Block => {
                printer.write("Block {\n");
                const start = ex[val];
                const end   = ex[val + 1];
                for (ex[start..end]) |child| {
                    printer.printStmt(@intCast(child), depth + 1);
                }
                printer.indent(depth);
                printer.write("}\n");
            },

            .Return => {
                printer.write("Return ");
                printer.printExpr(@intCast(val), depth + 1);
                printer.write(";");
            },

            .Discard => {
                printer.write("Discard ");
                printer.printExpr(@intCast(val), depth + 1);
                printer.write(";");
            },

            .Expression => {
                printer.write("ExprStmt ");
                printer.printExpr(@intCast(val), depth + 1);
                printer.write(";");
            },

            .Defer => {
                printer.write("Defer ");
                printer.printExpr(@intCast(val), depth + 1);
                printer.write(";");
            },

            .VariableDefinition => {
                const sig_start = ex[val];
                const expr_idx  = ex[val + 1];
                const is_pub = printer.ast.signatures.items(.public)[sig_start];
                printer.print("Let {s}", .{if (is_pub) "pub " else ""});
                printer.printSignature(sig_start, depth);
                printer.indent(depth);
                printer.write(" = ");
                printer.printExpr(@intCast(expr_idx), depth + 2);
                printer.write(";");
            },

            .Conditional => {
                const cond     = ex[val];
                const body     = ex[val + 1];
                const has_else = ex[val + 2];
                printer.write("If ");
                printer.indent(depth + 1);
                printer.printExpr(@intCast(cond), depth + 2);
                printer.indent(depth + 1);
                printer.write("then ");
                printer.printStmt(@intCast(body), depth + 2);
                if (has_else != 0) {
                    printer.indent(depth + 1);
                    printer.write(" else ");
                    printer.printStmt(@intCast(ex[val + 3]), depth + 2);
                }
            },

            .While, .For => |loop| {
                printer.write(if (loop == .While) "While " else "For ");
                printer.indent(depth + 1);
                printer.printExpr(@intCast(ex[val]), depth + 2);
                printer.indent(depth + 1);
                printer.write("do ");
                printer.printStmt(@intCast(ex[val + 1]), depth + 2);
            },

            .Switch => {
                printer.write("Switch ");
                printer.indent(depth + 1);
                printer.printExpr(@intCast(ex[val]), depth + 2);
                printer.printCases(ex, ex[val + 1], ex[val + 2], depth, true);
            },

            .Break    => printer.write("Break;"),
            .Continue => printer.write("Continue;"),

            .Import => {
                const module    = ex[val];
                const has_alias = ex[val + 1];
                printer.write("Import ");
                printer.printExpr(@intCast(module), depth + 1);
                if (has_alias != 0) {
                    printer.indent(depth + 1);
                    printer.print("as {s}", .{printer.tokenLexeme(@intCast(ex[val + 2]))});
                }
                printer.write(";");
            },

            .InlineC => {
                printer.print("Asm {s} ", .{printer.tokenLexeme(val)});
                printer.write(";");
            },
        }
    }

    pub fn printExpr(printer: *PrintContext, ei: defines.ExpressionPtr, depth: u32) void {
        const exprs = printer.ast.expressions;
        const etype = exprs.items(.type)[ei];
        const val   = exprs.items(.value)[ei];
        const ex    = printer.ast.extra;

        switch (etype) {
            .TupleDefinition => {
                printer.print("Tuple()", .{});
            },
            .Literal => {
                printer.print("Literal({s})", .{printer.tokenLexeme(val)});
            },

            .Identifier => {
                printer.print("Ident({s})", .{printer.tokenLexeme(val)});
            },

            .Binary => {
                printer.print("Binary({s}) ", .{opSymbol(@intCast(ex[val + 1]))});
                printer.printExpr(@intCast(ex[val]),     depth + 1);
                printer.printExpr(@intCast(ex[val + 2]), depth + 1);
            },

            .Unary => {
                printer.print("Unary({s}) ", .{opSymbol(@intCast(ex[val]))});
                printer.printExpr(@intCast(ex[val + 1]), depth + 1);
            },

            .Assignment => {
                printer.write("Assign ");
                printer.printExpr(@intCast(ex[val]),     depth + 1);
                printer.printExpr(@intCast(ex[val + 1]), depth + 1);
            },

            .Call => {
                printer.write("Call ");
                printer.printExpr(@intCast(ex[val]), depth + 1);
                printer.printExpr(@intCast(ex[val + 1]), depth + 1);
            },

            .ExpressionList => {
                printer.write("(");
                const expl = ex[ex[val]..ex[val + 1]];
                for (expl, 0..) |child, i| {
                    printer.printExpr(@intCast(child), depth + 1);
                    printer.print("{s}", .{
                        if (i == expl.len - 1) "" else ", ",
                    });
                }
                printer.write(")");
            },

            .Dot => {
                printer.print("Dot({s}) ", .{printer.tokenLexeme(@intCast(ex[val + 1]))});
                printer.printExpr(@intCast(ex[val]), depth + 1);
            },

            .Scoping => {
                printer.write("Scope(");
                printer.printExpr(@intCast(ex[val]), depth + 1);
                printer.print(", {s})", .{printer.tokenLexeme(@intCast(ex[val + 1]))});
            },

            .Indexing => {
                printer.write("Index ");
                printer.printExpr(@intCast(ex[val]), depth + 1);
                printer.write(" at: ");
                printer.printExpr(@intCast(ex[val + 1]), depth + 2);
            },

            .Slicing => {
                printer.write("Slice ");
                printer.printExpr(@intCast(ex[val]), depth + 1);
                printer.write("from: ");
                printer.printExpr(@intCast(ex[val + 1]), depth + 2);
                printer.write("to: ");
                printer.printExpr(@intCast(ex[val + 2]), depth + 2);
            },

            .Conditional => {
                printer.write("IfExpr ");
                printer.printExpr(@intCast(ex[val]),     depth + 2);
                printer.write(" then ");
                printer.printExpr(@intCast(ex[val + 1]), depth + 2);
                printer.write(" else ");
                printer.printExpr(@intCast(ex[val + 2]), depth + 2);
            },

            .Switch => {
                printer.write("SwitchExpr ");
                printer.printExpr(@intCast(ex[val]), depth + 2);
                printer.printCases(ex, ex[val + 1], ex[val + 2], depth, false);
            },

            .FunctionDefinition => {
                const param_start = ex[val];
                const param_end   = ex[val + 1];
                const ret         = ex[val + 2];
                const body        = ex[val + 3];
                printer.write("FnDef (\n");
                for (ex[param_start..param_end]) |raw_sig| {
                    printer.indent(depth + 1);
                    printer.printSignature(@intCast(raw_sig), depth + 2);
                }
                printer.indent(depth + 1);
                printer.write(" -> ");
                printer.printExpr(@intCast(ret), depth + 2);
                printer.write("{\n");
                printer.printStmt(@intCast(body), depth + 2);
                printer.write("}");
            },

            .StructDefinition => {
                const field_start = ex[val];
                const field_end   = ex[val + 1];
                const def_start   = ex[val + 2];
                const def_end     = ex[val + 3];
                printer.write("Struct {\n");
                for (ex[field_start..field_end]) |raw_sig| {
                    printer.printSignature(@intCast(raw_sig), depth + 1);
                    printer.write("\n");
                }
                for (ex[def_start..def_end]) |raw_stmt| {
                    printer.printStmt(@intCast(raw_stmt), depth + 1);
                }
                printer.indent(depth);
                printer.write("}");
            },

            .EnumDefinition => {
                const var_start = ex[val];
                const var_end   = ex[val + 1];
                const def_start = ex[val + 2];
                const def_end   = ex[val + 3];
                printer.write("Enum {\n");
                for (ex[var_start..var_end]) |tok| {
                    printer.indent(depth + 1);
                    printer.print("{s},\n", .{printer.tokenLexeme(@intCast(tok))});
                }
                for (ex[def_start..def_end]) |raw_stmt| {
                    printer.printStmt(@intCast(raw_stmt), depth + 1);
                }
                printer.indent(depth);
                printer.write("}");
            },

            .UnionDefinition => {
                const tagged = ex[val];
                var off: usize = val + 1;
                if (tagged != 0) {
                    const has_tag = ex[off];
                    off += 1;
                    if (has_tag != 0) {
                        printer.write("Union(");
                        printer.printExpr(@intCast(ex[off]), 0);
                        off += 1;
                        printer.indent(depth);
                        printer.write(") {\n");
                    } else {
                        printer.write("Union(enum) {\n");
                    }
                } else {
                    printer.write("Union {\n");
                }
                const var_start = ex[off];
                const var_end   = ex[off + 1];
                const def_start = ex[off + 2];
                const def_end   = ex[off + 3];
                for (ex[var_start..var_end]) |raw_sig| {
                    printer.printSignature(@intCast(raw_sig), depth + 1);
                    printer.write("\n");
                }
                for (ex[def_start..def_end]) |raw_stmt| {
                    printer.printStmt(@intCast(raw_stmt), depth + 1);
                }
                printer.indent(depth);
                printer.write("}");
            },

            .PointerType  => { printer.write("*");     printer.printExpr(val, depth); },
            .CPointerType => { printer.write("[@c]");  printer.printExpr(val, depth); },
            .SliceType    => { printer.write("[]");    printer.printExpr(val, depth); },
            .MutableType  => { printer.write("mut ");  printer.printExpr(val, depth); },

            .ArrayType => {
                const size_ei = ex[val];
                printer.write("[");
                printer.printExpr(size_ei, depth + 1);
                printer.write("]");
                printer.printExpr(@intCast(ex[val + 1]), depth);
            },

            .FunctionType => {
                printer.write("*fn ");
                printer.printExpr(@intCast(ex[val]),     depth);
                printer.indent(depth);
                printer.write(" -> ");
                printer.printExpr(@intCast(ex[val + 1]), depth);
            },

            .Mark => {
                printer.write("Mark(");
                for (ex[ex[val]..ex[val + 1]]) |hint| {
                    printer.printExpr(@intCast(hint), depth + 1);
                    printer.write(" ");
                }
                printer.indent(depth);
                printer.write(")");
                printer.printExpr(@intCast(ex[val + 2]), depth);
            },
        }
    }

    pub fn printSignature(printer: *PrintContext, si: defines.SignaturePtr, depth: u32) void {
        const sigs = printer.ast.signatures;
        const sig  = sigs.get(si);
        printer.indent(depth);
        if (sig.public) printer.write("pub ");
        printer.print("{s}", .{printer.tokenLexeme(sig.name)});
        printer.write(": ");
        printer.printExpr(sig.type, 0);
    }

    fn printCases(
        printer: *PrintContext,
        ex: []const defines.OpaquePtr,
        case_start: defines.OpaquePtr,
        case_end: defines.OpaquePtr,
        depth: u32,
        comptime is_stmt: bool,
    ) void {
        var i: usize = case_start;
        while (i < case_end) : (i += 3) {
            const case_expr = ex[i];
            const capture   = ex[i + 1];
            const case_body = ex[i + 2];
            printer.indent(depth + 1);
            if (case_expr == 0) {
                printer.write("else");
            } else {
                printer.write("case: ");
                printer.printExpr(@intCast(case_expr), depth + 2);
                printer.indent(depth + 1);
            }
            if (capture != 0) {
                printer.print(" |{s}|", .{printer.tokenLexeme(@intCast(capture))});
            }
            printer.write(" -> ");
            if (is_stmt) {
                printer.printStmt(@intCast(case_body), depth + 2);
            } else {
                printer.printExpr(@intCast(case_body), depth + 2);
            }
        }
    }
};

fn opSymbol(op: u32) []const u8 {
    return switch (op) {
        0  => "==",
        1  => "!=",
        2  => "<",
        3  => "<=",
        4  => ">",
        5  => ">=",
        6  => "+",
        7  => "-",
        8  => "*",
        9  => "/",
        10 => "&&",
        11 => "||",
        12 => "&",
        13 => "|",
        14 => "^",
        15 => "<<",
        16 => ">>",
        17 => "!",
        18 => "-",
        19 => "~",
        else => "?op",
    };
}

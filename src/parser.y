%{
/*
- parser.y - Grammar, AST, symbol table and semantic analysis for the
-            "Recipe" language (block-structured imperative version).
 *
- Design (deliberately ONE mechanism per job, to avoid duplicated work):
 *
-   1. The lexer turns text into tokens and values (numbers already parsed).
-   2. The grammar actions ONLY build an Abstract Syntax Tree. They perform
-      no semantic checks - this is a pure translation scheme producing a
-      synthesized attribute (the AST node) for every production.
-   3. A single tree-walk (analyze_*) does ALL semantic work exactly once:
-      symbol-table management with scoping, type checking, constant-value
-      computation and "unused symbol" reporting.
 *
- Numbers are stored in the AST as real numeric fields (ival/fval), never
- re-stringified, and each action has its own node kind, so the analyser
- dispatches on the node kind - it never re-parses a string to rediscover
- something the lexer/parser already knew.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define DEBUG 0

extern int   yylex(void);
extern int   yylineno;
extern char *yytext;
extern FILE *yyin;
int yyparse(void);

int syntax_errors = 0;   /* counted by yyerror */
int sem_errors    = 0;   /* counted by semantic analysis */
int lex_errors    = 0;   /* counted by the lexer's catch-all rule */

/* =======================================================================
-  AST
- ======================================================================= */
typedef enum {
    NODE_PROGRAM, NODE_INGREDIENTS_DECL, NODE_TOOLS_DECL,
    NODE_PROC_DECL, NODE_RECIPE_DECL,
    NODE_ASSIGN, NODE_PLUS_ASSIGN, NODE_CALL, NODE_RETURN,
    NODE_IF, NODE_WHILE, NODE_REPEAT,
    NODE_ID, NODE_INT, NODE_FLOAT, NODE_STRING, NODE_UNIT,
    NODE_BINOP, NODE_RELOP
} node_kind;

/* Operator codes - stored numerically so the analyser never strcmp()s "+" */
typedef enum {
    OP_ADD, OP_SUB, OP_MUL, OP_DIV,
    OP_EQ, OP_NE, OP_GT, OP_LT, OP_AND
} op_kind;

typedef struct ast_node {
    node_kind kind;
    op_kind   op;          /* for NODE_BINOP / NODE_RELOP            */
    char     *sval;        /* identifier / string / unit text        */
    long      ival;        /* NODE_INT value                         */
    double    fval;        /* NODE_FLOAT value                       */
    int       line;        /* source line, for diagnostics           */
    struct ast_node *child;
    struct ast_node *sibling;
} ast_node;

static ast_node *ast_root = NULL;

static ast_node *mk(node_kind kind) {
    ast_node *n = calloc(1, sizeof(ast_node));
    n->kind = kind;
    n->line = yylineno;
    return n;
}
static ast_node *mk_id(char *s)     { ast_node *n = mk(NODE_ID);     n->sval = s; return n; }
static ast_node *mk_int(long v)     { ast_node *n = mk(NODE_INT);    n->ival = v; return n; }
static ast_node *mk_float(double v) { ast_node *n = mk(NODE_FLOAT);  n->fval = v; return n; }
static ast_node *mk_str(char *s)    { ast_node *n = mk(NODE_STRING); n->sval = s; return n; }
static ast_node *mk_unit(char *s)   { ast_node *n = mk(NODE_UNIT);   n->sval = s; return n; }

static ast_node *mk_op(node_kind kind, op_kind op, ast_node *l, ast_node *r) {
    ast_node *n = mk(kind);
    n->op = op;
    n->child = l;
    if (l) l->sibling = r;
    return n;
}

/* Append `s` as the last sibling of `list`; returns the (possibly new) head. */
static ast_node *append(ast_node *list, ast_node *s) {
    if (!list) return s;
    ast_node *t = list;
    while (t->sibling) t = t->sibling;
    t->sibling = s;
    return list;
}

/* =======================================================================
-  Types & symbol table (dynamic, with a scope stack)
- ======================================================================= */
typedef enum {
    T_INT, T_FLOAT, T_STRING, T_BOOL,
    T_QUANTITY, T_DISH, T_UNIT, T_VOID, T_UNKNOWN
} data_type;

typedef enum { SYM_TOOL, SYM_INGREDIENT, SYM_VARIABLE, SYM_PROCEDURE } sym_kind;

typedef struct symbol {
    char     *name;
    sym_kind  kind;
    data_type dtype;      /* for variables & procedure returns */
    int       decl_line;
    int       used;
    /* computed constant value (for value semantics) */
    int       has_value;
    long      ival;
    double    fval;
    char     *sval;
    struct symbol *next;
} symbol;

typedef struct scope {
    symbol *symbols;
    struct scope *parent;
} scope;

static scope *scope_top    = NULL;  /* innermost scope                  */
static scope *global_scope = NULL;  /* global scope (ingredients/tools) */

static const char *type_name(data_type t) {
    switch (t) {
        case T_INT:      return "integer";
        case T_FLOAT:    return "float";
        case T_STRING:   return "string";
        case T_BOOL:     return "boolean";
        case T_QUANTITY: return "quantity";
        case T_DISH:     return "dish";
        case T_UNIT:     return "unit";
        case T_VOID:     return "void";
        default:         return "unknown";
    }
}
static const char *kind_name(sym_kind k) {
    switch (k) {
        case SYM_TOOL:       return "Tool";
        case SYM_INGREDIENT: return "Ingredient";
        case SYM_PROCEDURE:  return "Procedure";
        default:             return "Variable";
    }
}

/* Report a semantic error but keep going, so ALL problems are shown. */
static void sem_error(int line, const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "SEMANTIC ERROR (line %d): ", line);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    sem_errors++;
}
static void sem_warn(int line, const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "warning (line %d): ", line);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
}

static void push_scope(void) {
    scope *s = calloc(1, sizeof(scope));
    s->parent = scope_top;
    scope_top = s;
}

/* Report local variables and retrieved tools in this scope that were never used. */
static void report_unused_vars(scope *s) {
    for (symbol *e = s->symbols; e; e = e->next) {
        if (!e->used && (e->kind == SYM_VARIABLE || e->kind == SYM_TOOL))
            sem_warn(e->decl_line, "%s '%s' was declared/retrieved but never used",
                     kind_name(e->kind), e->name);
    }
}

static void free_symbols(symbol *e) {
    while (e) {
        symbol *t = e; e = e->next;
        free(t->name); free(t->sval); free(t);
    }
}

static void pop_scope(void) {
    if (!scope_top) return;
    scope *old = scope_top;
    report_unused_vars(old);
    scope_top = old->parent;
    free_symbols(old->symbols);
    free(old);
}

/* Search the scope stack from innermost outward down to the global scope. */
static symbol *lookup(const char *name) {
    for (scope *s = scope_top; s; s = s->parent)
        for (symbol *e = s->symbols; e; e = e->next)
            if (strcmp(e->name, name) == 0) return e;
    return NULL;
}

/* Look up a symbol only in the given scope (for redeclaration checks). */
static symbol *lookup_in(scope *s, const char *name) {
    if (!s) return NULL;
    for (symbol *e = s->symbols; e; e = e->next)
        if (strcmp(e->name, name) == 0) return e;
    return NULL;
}

/* Insert a symbol into the specified target scope. */
static symbol *insert_in(scope *target, const char *name, sym_kind kind, data_type dtype, int line) {
    symbol *s = calloc(1, sizeof(symbol));
    s->name      = strdup(name);
    s->kind      = kind;
    s->dtype     = dtype;
    s->decl_line = line;
    s->next      = target->symbols;
    target->symbols = s;
    return s;
}

/* =======================================================================
-  Type checking & value computation
- ======================================================================= */
static int is_numeric(data_type t) { return t == T_INT || t == T_FLOAT; }

static int compatible(data_type a, data_type b) {
    if (a == T_UNKNOWN || b == T_UNKNOWN) return 1;  /* error already reported */
    if (is_numeric(a) && is_numeric(b))   return 1;  /* int/float mix allowed  */
    return a == b;
}

/* A computed constant value (used to demonstrate value semantics). */
typedef struct { data_type type; long i; double f; char *s; int known; } value;

static const char *op_symbol(op_kind op) {
    switch (op) {
        case OP_ADD: return "+";  case OP_SUB: return "-";
        case OP_MUL: return "*";  case OP_DIV: return "/";
        case OP_EQ:  return "=="; case OP_NE:  return "!=";
        case OP_GT:  return ">";  case OP_LT:  return "<";
        case OP_AND: return "&&"; default: return "?";
    }
}

static int count_args(ast_node *first_arg) {
    int c = 0;
    for (ast_node *a = first_arg; a; a = a->sibling) c++;
    return c;
}

static data_type type_of(ast_node *n);

/* Type-check a procedure call, built-in action, or ingredient constructor. */
static data_type type_of_call(ast_node *n) {
    ast_node *fn   = n->child;
    ast_node *args = fn->sibling;
    const char *name = fn->sval;
    int argc = count_args(args);

    /* 1. retrieve(tool): brings a globally declared tool into the local scope */
    if (strcmp(name, "retrieve") == 0) {
        if (argc != 1 || args->kind != NODE_ID) {
            sem_error(n->line, "retrieve() expects 1 tool identifier");
            return T_UNKNOWN;
        }
        symbol *g = lookup_in(global_scope, args->sval);
        if (!g || g->kind != SYM_TOOL) {
            sem_error(args->line, "'%s' is not declared in global tools", args->sval);
            return T_UNKNOWN;
        }
        g->used = 1;
        if (lookup_in(scope_top, args->sval))
            sem_warn(args->line, "tool '%s' already retrieved in this scope (ignoring)", args->sval);
        else
            insert_in(scope_top, args->sval, SYM_TOOL, T_UNKNOWN, args->line);
        return T_VOID;
    }

    /* 2. cook(ingr, tool, duration, min) / boil(ingr, tool, duration, min) */
    if (strcmp(name, "cook") == 0 || strcmp(name, "boil") == 0) {
        if (argc != 4) {
            sem_error(n->line, "%s() expects 4 arguments: (ingredient, tool, duration, min)", name);
            return T_UNKNOWN;
        }
        ast_node *a1 = args, *a2 = a1->sibling, *a3 = a2->sibling, *a4 = a3->sibling;
        symbol *ing = (a1->kind == NODE_ID) ? lookup_in(global_scope, a1->sval) : NULL;
        if (!ing || ing->kind != SYM_INGREDIENT)
            sem_error(a1->line, "first argument to %s() must be a declared ingredient", name);
        else
            ing->used = 1;

        symbol *tool = (a2->kind == NODE_ID) ? lookup(a2->sval) : NULL;
        if (!tool || tool->kind != SYM_TOOL)
            sem_error(a2->line, "'%s' is not a retrieved tool in current scope",
                      a2->kind == NODE_ID ? a2->sval : "?");
        else
            tool->used = 1;

        if (!is_numeric(type_of(a3)))
            sem_error(a3->line, "%s() duration must be numeric", name);

        if (a4->kind != NODE_UNIT || strcmp(a4->sval, "min") != 0)
            sem_error(a4->line, "%s() duration unit must be 'min'", name);

        return T_VOID;
    }

    /* 3. drain(from_tool, to_tool) */
    if (strcmp(name, "drain") == 0) {
        if (argc != 2 || args->kind != NODE_ID || args->sibling->kind != NODE_ID) {
            sem_error(n->line, "drain() expects 2 retrieved tools");
            return T_UNKNOWN;
        }
        symbol *t1 = lookup(args->sval);
        symbol *t2 = lookup(args->sibling->sval);
        if (!t1 || t1->kind != SYM_TOOL)
            sem_error(args->line, "'%s' is not a retrieved tool in current scope", args->sval);
        else t1->used = 1;
        if (!t2 || t2->kind != SYM_TOOL)
            sem_error(args->sibling->line, "'%s' is not a retrieved tool in current scope", args->sibling->sval);
        else t2->used = 1;
        return T_VOID;
    }

    /* 4. mix(tool) / serve(tool) */
    if (strcmp(name, "mix") == 0 || strcmp(name, "serve") == 0) {
        if (argc != 1 || args->kind != NODE_ID) {
            sem_error(n->line, "%s() expects 1 retrieved tool", name);
            return T_UNKNOWN;
        }
        symbol *t = lookup(args->sval);
        if (!t || t->kind != SYM_TOOL)
            sem_error(args->line, "'%s' is not a retrieved tool in current scope", args->sval);
        else t->used = 1;
        return T_VOID;
    }

    /* 5. Ingredient quantity constructor: e.g. water(1, L) */
    symbol *g = lookup_in(global_scope, name);
    if (g && g->kind == SYM_INGREDIENT) {
        if (argc != 2) {
            sem_error(n->line, "ingredient '%s' constructor expects (quantity, unit)", name);
            return T_UNKNOWN;
        }
        ast_node *qty  = args;
        ast_node *unit = args->sibling;
        if (!is_numeric(type_of(qty)))
            sem_error(qty->line, "quantity for '%s' must be numeric", name);
        if (qty->kind == NODE_INT && qty->ival < 0)
            sem_error(qty->line, "negative quantity for '%s'", name);
        else if (qty->kind == NODE_INT && qty->ival == 0)
            sem_warn(qty->line, "zero quantity for '%s'", name);
        else if (qty->kind == NODE_FLOAT && qty->fval < 0.0)
            sem_error(qty->line, "negative quantity for '%s'", name);
        else if (qty->kind == NODE_FLOAT && qty->fval == 0.0)
            sem_warn(qty->line, "zero quantity for '%s'", name);

        if (unit->kind != NODE_UNIT || strcmp(unit->sval, "min") == 0)
            sem_error(unit->line, "invalid unit for '%s' (expected g, L, or p)", name);
        g->used = 1;
        return T_QUANTITY;
    }

    /* 6. User-defined procedure call: e.g. prepare_pasta() */
    if (g && g->kind == SYM_PROCEDURE) {
        if (argc != 0)
            sem_error(n->line, "procedure '%s' takes no arguments", name);
        g->used = 1;
        return g->dtype;
    }

    sem_error(n->line, "'%s' is not a declared procedure or ingredient", name);
    return T_UNKNOWN;
}

/* Determine the type of an expression/condition, reporting type errors. */
static data_type type_of(ast_node *n) {
    if (!n) return T_UNKNOWN;
    switch (n->kind) {
        case NODE_INT:    return T_INT;
        case NODE_FLOAT:  return T_FLOAT;
        case NODE_STRING: return T_STRING;
        case NODE_UNIT:   return T_UNIT;
        case NODE_CALL:   return type_of_call(n);
        case NODE_ID: {
            symbol *s = lookup(n->sval);
            if (!s) {
                sem_error(n->line, "'%s' is not declared", n->sval);
                return T_UNKNOWN;
            }
            s->used = 1;
            if (s->kind != SYM_VARIABLE) {
                sem_error(n->line, "'%s' is a %s and cannot be used in an expression",
                          n->sval, kind_name(s->kind));
                return T_UNKNOWN;
            }
            return s->dtype;
        }
        case NODE_BINOP: {
            data_type l = type_of(n->child);
            data_type r = type_of(n->child->sibling);
            if (l == T_UNKNOWN || r == T_UNKNOWN) return T_UNKNOWN;
            if (l == T_STRING || r == T_STRING) {
                sem_error(n->line, "cannot apply '%s' to a string", op_symbol(n->op));
                return T_UNKNOWN;
            }
            return (l == T_FLOAT || r == T_FLOAT) ? T_FLOAT : T_INT;
        }
        case NODE_RELOP: {
            if (n->op == OP_AND) {
                data_type l = type_of(n->child);
                data_type r = type_of(n->child->sibling);
                if (l != T_BOOL || r != T_BOOL)
                    sem_error(n->line, "'&&' requires boolean conditions on both sides");
                return T_BOOL;
            }
            data_type l = type_of(n->child);
            data_type r = type_of(n->child->sibling);
            if (!compatible(l, r))
                sem_error(n->line, "cannot compare %s with %s",
                          type_name(l), type_name(r));
            else if ((n->op == OP_GT || n->op == OP_LT) &&
                     !(is_numeric(l) && is_numeric(r)) &&
                     l != T_UNKNOWN && r != T_UNKNOWN)
                sem_error(n->line, "'%s' requires numeric operands", op_symbol(n->op));
            return T_BOOL;
        }
        default:
            return T_UNKNOWN;
    }
}

static double as_double(value v) { return v.type == T_FLOAT ? v.f : (double)v.i; }

/* Fold an expression to a constant value where every operand is known. */
static value eval(ast_node *n) {
    value v = {0}; v.known = 0;
    if (!n) return v;
    switch (n->kind) {
        case NODE_INT:    v.type = T_INT;    v.i = n->ival; v.known = 1; return v;
        case NODE_FLOAT:  v.type = T_FLOAT;  v.f = n->fval; v.known = 1; return v;
        case NODE_STRING: v.type = T_STRING; v.s = n->sval; v.known = 1; return v;
        case NODE_ID: {
            symbol *s = lookup(n->sval);
            if (s && s->has_value) {
                v.type = s->dtype; v.i = s->ival; v.f = s->fval; v.s = s->sval; v.known = 1;
            }
            return v;
        }
        case NODE_BINOP: {
            value a = eval(n->child);
            value b = eval(n->child->sibling);
            if (!a.known || !b.known || a.type == T_STRING || b.type == T_STRING) return v;
            if (a.type == T_FLOAT || b.type == T_FLOAT) {
                double x = as_double(a), y = as_double(b);
                if (n->op == OP_DIV && y == 0.0) {
                    sem_error(n->line, "division by zero"); return v;
                }
                v.type = T_FLOAT; v.known = 1;
                switch (n->op) {
                    case OP_ADD: v.f = x + y; break;
                    case OP_SUB: v.f = x - y; break;
                    case OP_MUL: v.f = x * y; break;
                    case OP_DIV: v.f = x / y; break;
                    default: v.known = 0;
                }
            } else {
                long x = a.i, y = b.i;
                if (n->op == OP_DIV && y == 0) {
                    sem_error(n->line, "division by zero"); return v;
                }
                v.type = T_INT; v.known = 1;
                switch (n->op) {
                    case OP_ADD: v.i = x + y; break;
                    case OP_SUB: v.i = x - y; break;
                    case OP_MUL: v.i = x * y; break;
                    case OP_DIV: v.i = x / y; break;
                    default: v.known = 0;
                }
            }
            return v;
        }
        default:
            return v;
    }
}

static void print_value(value v) {
    if      (v.type == T_INT)    printf("%ld", v.i);
    else if (v.type == T_FLOAT)  printf("%g", v.f);
    else if (v.type == T_STRING) printf("%s", v.s);
}

/* =======================================================================
-  Semantic analysis (single pass over the AST)
- ======================================================================= */
static void analyze_stmt_list(ast_node *first);

static void analyze_stmt(ast_node *n) {
    if (!n) return;
    switch (n->kind) {

    case NODE_ASSIGN: {                     /* var = expression          */
        ast_node *var  = n->child;
        ast_node *expr = var->sibling;
        data_type et = type_of(expr);       /* type-checks the expression */
        value     ev = eval(expr);          /* computes a value if constant */

        /* Assignment declares a variable in the current scope if not yet present,
- or updates an existing variable in the same scope if types are compatible. */
        symbol *existing = lookup_in(scope_top, var->sval);
        if (existing) {
            if (existing->kind != SYM_VARIABLE) {
                sem_error(n->line, "'%s' is a %s and cannot be assigned to",
                          var->sval, kind_name(existing->kind));
                break;
            }
            if (!compatible(existing->dtype, et)) {
                sem_error(n->line, "cannot assign %s to variable '%s' of type %s",
                          type_name(et), var->sval, type_name(existing->dtype));
                break;
            }
            existing->has_value = ev.known;
            if (ev.known) {
                existing->ival = ev.i; existing->fval = ev.f;
                free(existing->sval); existing->sval = ev.s ? strdup(ev.s) : NULL;
            }
            break;
        }
        symbol *s = insert_in(scope_top, var->sval, SYM_VARIABLE, et, n->line);
        s->has_value = ev.known;
        if (ev.known) {
            s->dtype = ev.type; s->ival = ev.i; s->fval = ev.f;
            free(s->sval); s->sval = ev.s ? strdup(ev.s) : NULL;
        }
        printf("  %s (%s)", var->sval, type_name(s->dtype));
        if (ev.known) { printf(" = "); print_value(ev); }
        printf("\n");
        break;
    }

    case NODE_PLUS_ASSIGN: {                /* tool += quantity_or_dish  */
        ast_node *target = n->child;
        ast_node *rhs    = target->sibling;
        symbol *s = lookup(target->sval);
        if (!s) {
            sem_error(n->line, "'%s' is not declared - did you 'retrieve(%s)' first?",
                      target->sval, target->sval);
            break;
        }
        s->used = 1;
        data_type rt = type_of(rhs);
        if (s->kind == SYM_TOOL) {
            if (rt != T_QUANTITY && rt != T_DISH && rt != T_UNKNOWN)
                sem_error(n->line, "cannot add %s to tool '%s' (expected ingredient quantity or dish)",
                          type_name(rt), target->sval);
        } else if (s->kind == SYM_VARIABLE && is_numeric(s->dtype)) {
            if (!is_numeric(rt) && rt != T_UNKNOWN)
                sem_error(n->line, "'+=' on numeric variable '%s' requires numeric operand", target->sval);
        } else {
            sem_error(n->line, "cannot use '+=' on %s '%s'", kind_name(s->kind), target->sval);
        }
        break;
    }

    case NODE_CALL:                         /* proc(...) / builtin(...)  */
        type_of_call(n);
        break;

    case NODE_RETURN: {                     /* return item               */
        ast_node *expr = n->child;
        if (expr->kind == NODE_ID) {
            symbol *s = lookup(expr->sval);
            if (!s)
                sem_error(expr->line, "returned item '%s' is not declared", expr->sval);
            else
                s->used = 1;
        } else {
            type_of(expr);
        }
        break;
    }

    case NODE_IF:
    case NODE_WHILE: {                      /* if/while (cond) { ... }   */
        ast_node *cond = n->child;
        ast_node *body = cond->sibling;
        if (type_of(cond) != T_BOOL)
            sem_error(cond->line, "condition must be a comparison");
        push_scope();
        analyze_stmt_list(body);
        pop_scope();
        break;
    }

    case NODE_REPEAT: {                     /* repeat N times { ... }    */
        ast_node *count = n->child;
        ast_node *body  = count->sibling;
        data_type ct = type_of(count);
        value cv = eval(count);
        if (ct != T_INT && ct != T_UNKNOWN)
            sem_error(count->line, "repeat count must be an integer, got %s", type_name(ct));
        else if (cv.known && cv.i <= 0)
            sem_error(count->line, "repeat count must be positive, got %ld", cv.i);
        push_scope();
        analyze_stmt_list(body);
        pop_scope();
        break;
    }

    default:
        break;
    }
}

static void analyze_stmt_list(ast_node *first) {
    for (ast_node *s = first; s; s = s->sibling)
        analyze_stmt(s);
}

/* Register global ingredients or tools into global_scope. */
static void analyze_global_decl(ast_node *decl, sym_kind kind) {
    for (ast_node *str = decl->child; str; str = str->sibling) {
        size_t len = strlen(str->sval);
        char *clean = malloc(len - 1);
        memcpy(clean, str->sval + 1, len - 2);
        clean[len - 2] = '\0';

        if (lookup_in(global_scope, clean))
            sem_warn(decl->line, "%s '%s' already declared globally (ignoring)",
                     kind_name(kind), clean);
        else
            insert_in(global_scope, clean, kind, T_UNKNOWN, decl->line);
        free(clean);
    }
}

static void analyze_procedure(ast_node *proc) {
    ast_node *name = proc->child;
    printf("\n=== Analysing procedure: %s ===\n", name->sval);

    if (lookup_in(global_scope, name->sval))
        sem_error(proc->line, "procedure '%s' conflicts with an existing global symbol", name->sval);
    else
        insert_in(global_scope, name->sval, SYM_PROCEDURE, T_DISH, proc->line);

    push_scope();
    analyze_stmt_list(name->sibling);
    pop_scope();
}

static void analyze_recipe(ast_node *recipe) {
    ast_node *name = recipe->child;
    printf("\n=== Analysing main recipe: %s ===\n", name->sval);

    push_scope();
    analyze_stmt_list(name->sibling);
    pop_scope();
}

static void analyze_program(ast_node *prog) {
    if (!prog) return;
    ast_node *ingr_decl  = prog->child;
    ast_node *tools_decl = ingr_decl->sibling;
    ast_node *procs_sec  = tools_decl->sibling;
    ast_node *recipe     = procs_sec->sibling;

    push_scope();
    global_scope = scope_top;          /* global ingredients, tools & procedures */

    analyze_global_decl(ingr_decl, SYM_INGREDIENT);
    analyze_global_decl(tools_decl, SYM_TOOL);

    for (ast_node *p = procs_sec->child; p; p = p->sibling)
        analyze_procedure(p);

    analyze_recipe(recipe);

    /* Report global ingredients/tools/procedures that were never used. */
    printf("\n--- Kitchen efficiency check ---\n");
    int any = 0;
    for (symbol *e = global_scope->symbols; e; e = e->next)
        if (!e->used) {
            sem_warn(e->decl_line, "%s '%s' was declared globally but never used",
                     kind_name(e->kind), e->name);
            any = 1;
        }
    if (!any) printf("All declared tools, ingredients and procedures were used.\n");

    pop_scope();
    global_scope = NULL;
}

/* =======================================================================
-  AST printer (for demonstration)
- ======================================================================= */
static const char *node_name(node_kind k) {
    switch (k) {
        case NODE_PROGRAM:          return "PROGRAM";
        case NODE_INGREDIENTS_DECL: return "INGREDIENTS_DECL";
        case NODE_TOOLS_DECL:       return "TOOLS_DECL";
        case NODE_PROC_DECL:        return "PROC_DECL";
        case NODE_RECIPE_DECL:      return "RECIPE_MAIN";
        case NODE_ASSIGN:           return "ASSIGN";
        case NODE_PLUS_ASSIGN:      return "PLUS_ASSIGN";
        case NODE_CALL:             return "CALL";
        case NODE_RETURN:           return "RETURN";
        case NODE_IF:               return "IF";
        case NODE_WHILE:            return "WHILE";
        case NODE_REPEAT:           return "REPEAT";
        case NODE_ID:               return "ID";
        case NODE_INT:              return "INT";
        case NODE_FLOAT:            return "FLOAT";
        case NODE_STRING:           return "STRING";
        case NODE_UNIT:             return "UNIT";
        case NODE_BINOP:            return "BINOP";
        case NODE_RELOP:            return "RELOP";
        default:                    return "?";
    }
}
static void print_ast(ast_node *n, int depth) {
    if (!n) return;
    for (int i = 0; i < depth; i++) printf("  ");
    printf("%s", node_name(n->kind));
    switch (n->kind) {
        case NODE_INT:   printf(" %ld", n->ival); break;
        case NODE_FLOAT: printf(" %g",  n->fval); break;
        case NODE_BINOP:
        case NODE_RELOP: printf(" '%s'", op_symbol(n->op)); break;
        default: if (n->sval) printf(" '%s'", n->sval);
    }
    printf("\n");
    print_ast(n->child, depth + 1);
    print_ast(n->sibling, depth);
}

void yyerror(const char *s) {
    fprintf(stderr, "SYNTAX ERROR (line %d) near '%s': %s\n",
            yylineno, (yytext && *yytext) ? yytext : "end of input", s);
    syntax_errors++;
}
%}

/* =======================================================================
-  Tokens & precedence
- ======================================================================= */
%union {
    long   int_val;
    double double_val;
    char  *string_val;
    struct ast_node *node;
}

%token <string_val> IDENTIFIER STRING_LITERAL
%token <int_val>    INTEGER_LITERAL
%token <double_val> FLOAT_LITERAL

%token INGREDIENTS TOOLS RECIPE RETRIEVE RETURN
%token L_UNIT G_UNIT P_UNIT MIN_UNIT
%token LBRACE RBRACE LBRACKET RBRACKET SEMICOLON COMMA LPAREN RPAREN
%token IF WHILE REPEAT TIMES
%token ASSIGN PLUS_ASSIGN EQ_OP NE_OP GT_OP LT_OP AND_OP ADD_OP SUB_OP MUL_OP DIV_OP

%left AND_OP
%left EQ_OP NE_OP GT_OP LT_OP
%left ADD_OP SUB_OP
%left MUL_OP DIV_OP

%type <node> program ingredients_decl tools_decl str_list
%type <node> proc_list proc_decl recipe_decl
%type <node> stmt_list stmt simple_stmt block
%type <node> arg_list arg_list_items
%type <node> condition expression term factor unit

%start program

%%

/* ----- Program: mandatory ingredients & tools, 0..N procedures, 1 main recipe ----- */
program:
    ingredients_decl tools_decl proc_list recipe_decl {
        ast_node *procs_sec = mk(NODE_ID);
        procs_sec->sval  = strdup("PROCEDURES");
        procs_sec->child = $3;

        $1->sibling        = $2;
        $2->sibling        = procs_sec;
        procs_sec->sibling = $4;

        ast_root = mk(NODE_PROGRAM);
        ast_root->child = $1;
        $$ = ast_root;
    }
    ;

/* ----- Mandatory Global Declarations ----- */
ingredients_decl:
    INGREDIENTS ASSIGN LBRACKET str_list RBRACKET SEMICOLON {
        ast_node *n = mk(NODE_INGREDIENTS_DECL);
        n->child = $4;
        $$ = n;
    }
    ;

tools_decl:
    TOOLS ASSIGN LBRACKET str_list RBRACKET SEMICOLON {
        ast_node *n = mk(NODE_TOOLS_DECL);
        n->child = $4;
        $$ = n;
    }
    ;

str_list:
      STRING_LITERAL                { $$ = mk_str($1); }
    | str_list COMMA STRING_LITERAL { $$ = append($1, mk_str($3)); }
    ;

/* ----- Procedures ----- */
proc_list:
      proc_list proc_decl { $$ = append($1, $2); }
    | /* empty */         { $$ = NULL; }
    ;

proc_decl:
    IDENTIFIER LBRACE stmt_list RBRACE {
        ast_node *n = mk(NODE_PROC_DECL);
        ast_node *name = mk_id($1);
        name->sibling = $3;
        n->child = name;
        $$ = n;
    }
    ;

/* ----- Main Recipe ----- */
recipe_decl:
    RECIPE IDENTIFIER LBRACE stmt_list RBRACE {
        ast_node *n = mk(NODE_RECIPE_DECL);
        ast_node *name = mk_id($2);
        name->sibling = $4;
        n->child = name;
        $$ = n;
    }
    ;

/* ----- Statements ----- */
stmt_list:
      stmt_list stmt { $$ = append($1, $2); }
    | /* empty */    { $$ = NULL; }
    ;

/* Simple statements end with ';'. Block statements (if/while/repeat) do not.
- `error SEMICOLON` lets the parser recover and keep reporting problems. */
stmt:
      simple_stmt SEMICOLON           { $$ = $1; }
    | IF LPAREN condition RPAREN block {
        ast_node *n = mk(NODE_IF); n->child = $3; n->child->sibling = $5; $$ = n;
      }
    | WHILE LPAREN condition RPAREN block {
        ast_node *n = mk(NODE_WHILE); n->child = $3; n->child->sibling = $5; $$ = n;
      }
    | REPEAT expression TIMES block {
        ast_node *n = mk(NODE_REPEAT); n->child = $2; n->child->sibling = $4; $$ = n;
      }
    | SEMICOLON                       { $$ = NULL; }   /* empty statement */
    | error SEMICOLON                 { yyerrok; $$ = NULL; }
    ;

simple_stmt:
      IDENTIFIER ASSIGN expression {
        ast_node *n = mk(NODE_ASSIGN);
        n->child = mk_id($1);
        n->child->sibling = $3;
        $$ = n;
      }
    | IDENTIFIER PLUS_ASSIGN expression {
        ast_node *n = mk(NODE_PLUS_ASSIGN);
        n->child = mk_id($1);
        n->child->sibling = $3;
        $$ = n;
      }
    | RETRIEVE LPAREN arg_list RPAREN {
        ast_node *n = mk(NODE_CALL);
        n->child = mk_id(strdup("retrieve"));
        n->child->sibling = $3;
        $$ = n;
      }
    | IDENTIFIER LPAREN arg_list RPAREN {
        ast_node *n = mk(NODE_CALL);
        n->child = mk_id($1);
        n->child->sibling = $3;
        $$ = n;
      }
    | RETURN expression {
        ast_node *n = mk(NODE_RETURN);
        n->child = $2;
        $$ = n;
      }
    ;

block:
    LBRACE stmt_list RBRACE { $$ = $2; }
    ;

/* ----- Function / Constructor Arguments ----- */
arg_list:
      arg_list_items { $$ = $1; }
    | /* empty */    { $$ = NULL; }
    ;

arg_list_items:
      expression                      { $$ = $1; }
    | arg_list_items COMMA expression { $$ = append($1, $3); }
    ;

/* ----- Conditions & expressions ----- */
condition:
      expression EQ_OP expression { $$ = mk_op(NODE_RELOP, OP_EQ, $1, $3); }
    | expression NE_OP expression { $$ = mk_op(NODE_RELOP, OP_NE, $1, $3); }
    | expression GT_OP expression { $$ = mk_op(NODE_RELOP, OP_GT, $1, $3); }
    | expression LT_OP expression { $$ = mk_op(NODE_RELOP, OP_LT, $1, $3); }
    | condition AND_OP condition  { $$ = mk_op(NODE_RELOP, OP_AND, $1, $3); }
    | LPAREN condition RPAREN     { $$ = $2; }
    ;

expression:
      expression ADD_OP term { $$ = mk_op(NODE_BINOP, OP_ADD, $1, $3); }
    | expression SUB_OP term { $$ = mk_op(NODE_BINOP, OP_SUB, $1, $3); }
    | term                   { $$ = $1; }
    ;

term:
      term MUL_OP factor { $$ = mk_op(NODE_BINOP, OP_MUL, $1, $3); }
    | term DIV_OP factor { $$ = mk_op(NODE_BINOP, OP_DIV, $1, $3); }
    | factor             { $$ = $1; }
    ;

factor:
      INTEGER_LITERAL                   { $$ = mk_int($1); }
    | FLOAT_LITERAL                     { $$ = mk_float($1); }
    | IDENTIFIER                        { $$ = mk_id($1); }
    | STRING_LITERAL                    { $$ = mk_str($1); }
    | IDENTIFIER LPAREN arg_list RPAREN {
        ast_node *n = mk(NODE_CALL);
        n->child = mk_id($1);
        n->child->sibling = $3;
        $$ = n;
      }
    | LPAREN expression RPAREN          { $$ = $2; }
    | unit                              { $$ = $1; }
    ;

unit:
      G_UNIT   { $$ = mk_unit("g"); }
    | L_UNIT   { $$ = mk_unit("L"); }
    | P_UNIT   { $$ = mk_unit("p"); }
    | MIN_UNIT { $$ = mk_unit("min"); }
    ;

%%

int main(int argc, char **argv) {
    if (argc > 1) {
        yyin = fopen(argv[1], "r");
        if (!yyin) { perror(argv[1]); return 1; }
    }

    yyparse();

    if (syntax_errors > 0) {
        printf("\nCOMPILATION FAILED: %d syntax error(s).\n", syntax_errors);
        return 1;
    }
    if (lex_errors > 0) {
        printf("\nCOMPILATION FAILED: %d lexical error(s).\n", lex_errors);
        return 1;
    }

    printf("\n=== Abstract Syntax Tree ===\n");
    print_ast(ast_root, 0);

    printf("\n=== Semantic Analysis ===\n");
    analyze_program(ast_root);

    printf("\n");
    if (sem_errors == 0) {
        printf("COMPILATION SUCCESSFUL: no semantic or type errors found.\n");
    } else {
        printf("COMPILATION FAILED: %d semantic/type error(s).\n", sem_errors);
    }

    if (yyin && yyin != stdin) fclose(yyin);
    return sem_errors == 0 ? 0 : 1;
}
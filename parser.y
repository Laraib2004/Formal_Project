%{
/*
 * parser.y - Grammar, AST, symbol table and semantic analysis for the
 *            "Recipe" language.
 *
 * Design (deliberately ONE mechanism per job, to avoid duplicated work):
 *
 *   1. The lexer turns text into tokens and values (numbers already parsed).
 *   2. The grammar actions ONLY build an Abstract Syntax Tree. They perform
 *      no semantic checks - this is a pure translation scheme producing a
 *      synthesized attribute (the AST node) for every production.
 *   3. A single tree-walk (analyze_*) does ALL semantic work exactly once:
 *      symbol-table management with scoping, type checking, constant-value
 *      computation and "unused symbol" reporting.
 *
 * Numbers are stored in the AST as real numeric fields (ival/fval), never
 * re-stringified, and each action has its own node kind, so the analyser
 * dispatches on the node kind - it never re-parses a string to rediscover
 * something the lexer/parser already knew.
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

/* =======================================================================
 *  AST
 * ======================================================================= */
typedef enum {
    NODE_PROGRAM, NODE_RECIPE, NODE_STEP,
    NODE_GET, NODE_ADD, NODE_COOK, NODE_BOIL, NODE_DRAIN,
    NODE_MIX, NODE_SERVE, NODE_RETURN,
    NODE_ASSIGN, NODE_IF, NODE_WHILE, NODE_REPEAT,
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
 *  Types & symbol table (dynamic, with a scope stack)
 * ======================================================================= */
typedef enum { T_INT, T_FLOAT, T_STRING, T_BOOL, T_UNKNOWN } data_type;
typedef enum { SYM_TOOL, SYM_INGREDIENT, SYM_VARIABLE } sym_kind;

typedef struct symbol {
    char     *name;
    sym_kind  kind;
    data_type dtype;      /* for variables            */
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

static scope *scope_top    = NULL;  /* innermost scope                 */
static scope *recipe_scope = NULL;  /* recipe-wide scope (tools/ingr.) */
static char  *current_recipe_name = NULL;

static const char *type_name(data_type t) {
    switch (t) {
        case T_INT:    return "integer";
        case T_FLOAT:  return "float";
        case T_STRING: return "string";
        case T_BOOL:   return "boolean";
        default:       return "unknown";
    }
}
static const char *kind_name(sym_kind k) {
    switch (k) {
        case SYM_TOOL:       return "Tool";
        case SYM_INGREDIENT: return "Ingredient";
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

/* Report variables declared in this scope that were never referenced. */
static void report_unused_vars(scope *s) {
    for (symbol *e = s->symbols; e; e = e->next)
        if (e->kind == SYM_VARIABLE && !e->used)
            sem_warn(0, "variable '%s' was set but never used", e->name);
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

/* Search the scope stack from innermost outward, then the recipe scope. */
static symbol *lookup(const char *name) {
    for (scope *s = scope_top; s; s = s->parent)
        for (symbol *e = s->symbols; e; e = e->next)
            if (strcmp(e->name, name) == 0) return e;
    return NULL;
}

/* Look up a symbol only in the given scope (for redeclaration checks). */
static symbol *lookup_in(scope *s, const char *name) {
    for (symbol *e = s->symbols; e; e = e->next)
        if (strcmp(e->name, name) == 0) return e;
    return NULL;
}

/* Insert a symbol. Tools and ingredients live in the recipe-wide scope so
 * they remain visible across steps; variables live in the current scope. */
static symbol *insert(const char *name, sym_kind kind, data_type dtype) {
    scope *target = (kind == SYM_VARIABLE) ? scope_top : recipe_scope;
    symbol *s = calloc(1, sizeof(symbol));
    s->name  = strdup(name);
    s->kind  = kind;
    s->dtype = dtype;
    s->next  = target->symbols;
    target->symbols = s;
    return s;
}

/* =======================================================================
 *  Type checking & value computation
 * ======================================================================= */
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

/* Determine the type of an expression/condition, reporting type errors. */
static data_type type_of(ast_node *n) {
    if (!n) return T_UNKNOWN;
    switch (n->kind) {
        case NODE_INT:    return T_INT;
        case NODE_FLOAT:  return T_FLOAT;
        case NODE_STRING: return T_STRING;
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
 *  Semantic analysis (single pass over the AST)
 * ======================================================================= */
static void analyze_stmt_list(ast_node *first);

/* Require that a name refers to an already-declared symbol; mark it used. */
static symbol *require_symbol(ast_node *id, const char *role) {
    symbol *s = lookup(id->sval);
    if (!s) {
        sem_error(id->line, "%s '%s' is not declared - did you 'get' or 'add' it first?",
                  role, id->sval);
        return NULL;
    }
    s->used = 1;
    return s;
}

static void analyze_stmt(ast_node *n) {
    switch (n->kind) {

    case NODE_GET: {                       /* get tool                  */
        ast_node *tool = n->child;
        if (lookup_in(recipe_scope, tool->sval))
            sem_warn(n->line, "tool '%s' already prepared (ignoring)", tool->sval);
        else
            insert(tool->sval, SYM_TOOL, T_UNKNOWN);
        break;
    }

    case NODE_ADD: {                       /* add ingr [qty unit] to container */
        ast_node *ingr = n->child;
        ast_node *next = ingr->sibling;
        ast_node *container;
        if (next->kind == NODE_INT || next->kind == NODE_FLOAT) {
            ast_node *qty = next;
            container = qty->sibling->sibling;      /* skip qty and unit */
            double q = (qty->kind == NODE_INT) ? (double)qty->ival : qty->fval;
            if (q < 0)  sem_error(qty->line, "negative quantity for '%s'", ingr->sval);
            if (q == 0) sem_warn(qty->line, "zero quantity for '%s'", ingr->sval);
        } else {
            container = next;
        }
        /* The container must be a tool that was already obtained. */
        symbol *c = lookup(container->sval);
        if (!c)                       sem_error(container->line,
                                          "cannot add to '%s': it was never obtained with 'get'",
                                          container->sval);
        else                          c->used = 1;
        /* Declare the ingredient (once) in the recipe scope. */
        if (!lookup_in(recipe_scope, ingr->sval))
            insert(ingr->sval, SYM_INGREDIENT, T_UNKNOWN);
        break;
    }

    case NODE_COOK:
    case NODE_BOIL: {                      /* cook/boil ingr in tool N min */
        ast_node *ingr = n->child;
        ast_node *tool = ingr->sibling;
        require_symbol(ingr, "ingredient");
        require_symbol(tool, "tool");
        break;
    }

    case NODE_DRAIN: {                     /* drain item tool           */
        require_symbol(n->child, "ingredient");
        require_symbol(n->child->sibling, "tool");
        break;
    }

    case NODE_MIX:                          /* mix tool                  */
        require_symbol(n->child, "tool");
        break;

    case NODE_RETURN:                       /* return item               */
        require_symbol(n->child, "item");
        break;

    case NODE_SERVE: {                      /* serve dish                */
        ast_node *dish = n->child;
        if (current_recipe_name && strcmp(dish->sval, current_recipe_name) == 0)
            break;                          /* serving the finished recipe */
        require_symbol(dish, "dish");
        break;
    }

    case NODE_ASSIGN: {                     /* set var = expression      */
        ast_node *var  = n->child;
        ast_node *expr = var->sibling;
        data_type et = type_of(expr);       /* type-checks the expression */
        value     ev = eval(expr);          /* computes a value if constant */

        symbol *s = lookup(var->sval);
        if (s && s->kind == SYM_VARIABLE) {
            if (!compatible(s->dtype, et))
                sem_error(n->line, "cannot assign %s to variable '%s' of type %s",
                          type_name(et), var->sval, type_name(s->dtype));
            s->dtype = et;
        } else if (s) {
            sem_error(n->line, "'%s' is a %s and cannot be assigned to",
                      var->sval, kind_name(s->kind));
            break;
        } else {
            s = insert(var->sval, SYM_VARIABLE, et);
        }
        /* Record the computed constant value on the symbol. */
        s->has_value = ev.known;
        if (ev.known) {
            s->dtype = ev.type; s->ival = ev.i; s->fval = ev.f;
            free(s->sval); s->sval = ev.s ? strdup(ev.s) : NULL;
        }
        printf("  set %s (%s)", var->sval, type_name(s->dtype));
        if (ev.known) { printf(" = "); print_value(ev); }
        printf("\n");
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
        if (count->kind == NODE_ID) {
            symbol *s = require_symbol(count, "loop count");
            if (s && s->kind == SYM_VARIABLE && s->dtype != T_INT)
                sem_error(count->line, "repeat count '%s' must be an integer", count->sval);
        } else if (count->ival <= 0) {
            sem_error(count->line, "repeat count must be positive, got %ld", count->ival);
        }
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

static void analyze_step(ast_node *step) {
    /* Steps do not open a new scope: step-level variables belong to the
     * recipe so later steps can read them. Only if/while/repeat blocks
     * introduce nested scopes (demonstrating the scoping mechanism). */
    printf("Step %ld:\n", step->ival);
    analyze_stmt_list(step->child);
}

static void analyze_recipe(ast_node *recipe) {
    ast_node *name = recipe->child;
    current_recipe_name = name->sval;
    printf("\n=== Analysing recipe: %s ===\n", name->sval);

    push_scope();
    recipe_scope = scope_top;          /* tools & ingredients live here */

    for (ast_node *step = name->sibling; step; step = step->sibling)
        analyze_step(step);

    /* Report tools/ingredients that were prepared but never used. */
    printf("--- Kitchen efficiency check ---\n");
    int any = 0;
    for (symbol *e = recipe_scope->symbols; e; e = e->next)
        if (!e->used) {
            sem_warn(0, "%s '%s' was prepared but never used", kind_name(e->kind), e->name);
            any = 1;
        }
    if (!any) printf("All tools and ingredients were used.\n");

    pop_scope();
    recipe_scope = NULL;
}

static void analyze_program(ast_node *prog) {
    if (!prog) return;
    for (ast_node *r = prog->child; r; r = r->sibling)
        analyze_recipe(r);
}

/* =======================================================================
 *  AST printer (for demonstration)
 * ======================================================================= */
static const char *node_name(node_kind k) {
    switch (k) {
        case NODE_PROGRAM: return "PROGRAM"; case NODE_RECIPE: return "RECIPE";
        case NODE_STEP: return "STEP";       case NODE_GET: return "GET";
        case NODE_ADD: return "ADD";         case NODE_COOK: return "COOK";
        case NODE_BOIL: return "BOIL";       case NODE_DRAIN: return "DRAIN";
        case NODE_MIX: return "MIX";         case NODE_SERVE: return "SERVE";
        case NODE_RETURN: return "RETURN";   case NODE_ASSIGN: return "ASSIGN";
        case NODE_IF: return "IF";           case NODE_WHILE: return "WHILE";
        case NODE_REPEAT: return "REPEAT";   case NODE_ID: return "ID";
        case NODE_INT: return "INT";         case NODE_FLOAT: return "FLOAT";
        case NODE_STRING: return "STRING";   case NODE_UNIT: return "UNIT";
        case NODE_BINOP: return "BINOP";     case NODE_RELOP: return "RELOP";
        default: return "?";
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
 *  Tokens & precedence
 * ======================================================================= */
%union {
    long   int_val;
    double double_val;
    char  *string_val;
    struct ast_node *node;
}

%token <string_val> IDENTIFIER STRING_LITERAL
%token <int_val>    INTEGER_LITERAL
%token <double_val> FLOAT_LITERAL

%token RECIPE STEP GET ADD TO COOK IN RETURN BOIL DRAIN MIX SERVE
%token L_UNIT G_UNIT P_UNIT MIN_UNIT
%token LBRACE RBRACE SEMICOLON LPAREN RPAREN
%token IF WHILE REPEAT TIMES SET
%token ASSIGN EQ_OP NE_OP GT_OP LT_OP AND_OP ADD_OP SUB_OP MUL_OP DIV_OP

%left AND_OP
%left EQ_OP NE_OP GT_OP LT_OP
%left ADD_OP SUB_OP
%left MUL_OP DIV_OP

%type <node> program recipe_list recipe step_list step
%type <node> stmt_list stmt simple_stmt block
%type <node> get_stmt add_stmt cook_stmt boil_stmt drain_stmt mix_stmt
%type <node> serve_stmt return_stmt assignment if_stmt while_stmt repeat_stmt
%type <node> condition expression term factor number unit

%start program

%%

/* ----- Program: one or more recipes ----- */
program:
    recipe_list { ast_root = mk(NODE_PROGRAM); ast_root->child = $1; $$ = ast_root; }
    ;

recipe_list:
      recipe_list recipe { $$ = append($1, $2); }
    | recipe             { $$ = $1; }
    ;

recipe:
    RECIPE IDENTIFIER LBRACE step_list RBRACE {
        ast_node *r = mk(NODE_RECIPE);
        ast_node *name = mk_id($2);
        name->sibling = $4;      /* steps follow the name */
        r->child = name;
        $$ = r;
    }
    ;

step_list:
      step_list step { $$ = append($1, $2); }
    | step           { $$ = $1; }
    ;

step:
    STEP INTEGER_LITERAL LBRACE stmt_list RBRACE {
        ast_node *s = mk(NODE_STEP);
        s->ival = $2;            /* step number kept as a real number */
        s->child = $4;
        $$ = s;
    }
    ;

/* ----- Statements ----- */
stmt_list:
      stmt_list stmt { $$ = append($1, $2); }
    | /* empty */    { $$ = NULL; }
    ;

/* Simple statements end with ';'. Block statements (if/while/repeat) do not.
 * `error SEMICOLON` lets the parser recover and keep reporting problems. */
stmt:
      simple_stmt SEMICOLON { $$ = $1; }
    | if_stmt               { $$ = $1; }
    | while_stmt            { $$ = $1; }
    | repeat_stmt           { $$ = $1; }
    | error SEMICOLON       { yyerrok; $$ = NULL; }
    ;

simple_stmt:
      get_stmt | add_stmt | cook_stmt | boil_stmt | drain_stmt
    | mix_stmt | serve_stmt | return_stmt | assignment
    ;

get_stmt:
    GET IDENTIFIER {
        ast_node *n = mk(NODE_GET); n->child = mk_id($2); $$ = n;
    }
    ;

add_stmt:
      ADD IDENTIFIER number unit TO IDENTIFIER {
        ast_node *n = mk(NODE_ADD);
        n->child = mk_id($2);
        n->child->sibling = $3;                         /* quantity   */
        n->child->sibling->sibling = $4;                /* unit       */
        n->child->sibling->sibling->sibling = mk_id($6);/* container  */
        $$ = n;
      }
    | ADD IDENTIFIER TO IDENTIFIER {
        ast_node *n = mk(NODE_ADD);
        n->child = mk_id($2);
        n->child->sibling = mk_id($4);
        $$ = n;
      }
    ;

cook_stmt:
    COOK IDENTIFIER IN IDENTIFIER number MIN_UNIT {
        ast_node *n = mk(NODE_COOK);
        n->child = mk_id($2);
        n->child->sibling = mk_id($4);
        n->child->sibling->sibling = $5;
        n->child->sibling->sibling->sibling = mk_unit("min");
        $$ = n;
    }
    ;

boil_stmt:
    BOIL IDENTIFIER IN IDENTIFIER number MIN_UNIT {
        ast_node *n = mk(NODE_BOIL);
        n->child = mk_id($2);
        n->child->sibling = mk_id($4);
        n->child->sibling->sibling = $5;
        n->child->sibling->sibling->sibling = mk_unit("min");
        $$ = n;
    }
    ;

drain_stmt:
    DRAIN IDENTIFIER IDENTIFIER {
        ast_node *n = mk(NODE_DRAIN);
        n->child = mk_id($2);
        n->child->sibling = mk_id($3);
        $$ = n;
    }
    ;

mix_stmt:
    MIX IDENTIFIER { ast_node *n = mk(NODE_MIX); n->child = mk_id($2); $$ = n; }
    ;

serve_stmt:
    SERVE IDENTIFIER { ast_node *n = mk(NODE_SERVE); n->child = mk_id($2); $$ = n; }
    ;

return_stmt:
    RETURN IDENTIFIER { ast_node *n = mk(NODE_RETURN); n->child = mk_id($2); $$ = n; }
    ;

assignment:
    SET IDENTIFIER ASSIGN expression {
        ast_node *n = mk(NODE_ASSIGN);
        n->child = mk_id($2);
        n->child->sibling = $4;
        $$ = n;
    }
    ;

if_stmt:
    IF LPAREN condition RPAREN block {
        ast_node *n = mk(NODE_IF); n->child = $3; n->child->sibling = $5; $$ = n;
    }
    ;

while_stmt:
    WHILE LPAREN condition RPAREN block {
        ast_node *n = mk(NODE_WHILE); n->child = $3; n->child->sibling = $5; $$ = n;
    }
    ;

repeat_stmt:
      REPEAT INTEGER_LITERAL TIMES block {
        ast_node *n = mk(NODE_REPEAT); n->child = mk_int($2);
        n->child->sibling = $4; $$ = n;
      }
    | REPEAT IDENTIFIER TIMES block {
        ast_node *n = mk(NODE_REPEAT); n->child = mk_id($2);
        n->child->sibling = $4; $$ = n;
      }
    ;

block:
    LBRACE stmt_list RBRACE { $$ = $2; }
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
      INTEGER_LITERAL          { $$ = mk_int($1); }
    | FLOAT_LITERAL            { $$ = mk_float($1); }
    | IDENTIFIER               { $$ = mk_id($1); }
    | STRING_LITERAL           { $$ = mk_str($1); }
    | LPAREN expression RPAREN { $$ = $2; }
    ;

number:
      INTEGER_LITERAL { $$ = mk_int($1); }
    | FLOAT_LITERAL   { $$ = mk_float($1); }
    ;

unit:
      G_UNIT { $$ = mk_unit("g"); }
    | L_UNIT { $$ = mk_unit("L"); }
    | P_UNIT { $$ = mk_unit("p"); }
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

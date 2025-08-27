%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Global debug flag
#define DEBUG 0

extern int yylex();
extern FILE *yyin;
extern int yylineno;
extern char* yytext;
int yyparse();

// Error handling function
void yyerror(const char *s) {
    fprintf(stderr, "\n COOKING ERROR at line %d near '%s':\n", yylineno, yytext);
    fprintf(stderr, "   Problem: %s\n", s);

    // Add helpful hints
    if(strstr(s, "not declared") || strstr(s, "non dichiarata")){
        fprintf(stderr, "   Fix: Did you forget to 'get' this tool or 'add' this ingredient?\n");
        fprintf(stderr, "   Common tools: pot, pan, spoon, bowl\n");
    }
    else if(strstr(s, "syntax error")){
        fprintf(stderr, "   Fix: Check for missing semicolon ';' or closing brace '}'\n");
        fprintf(stderr, "   Recipe structure: recipe name { step 1 { actions; } }\n");
    }
    else if(strstr(s, "unexpected")){
        fprintf(stderr, "   Fix: Check spelling and recipe syntax\n");
        fprintf(stderr, "   Valid actions: get, add, cook, boil, mix, serve\n");
    }
    fprintf(stderr, "   Context: Recipe preparation step\n");
    fprintf(stderr, "\n");
}

// === AST DATA STRUCTURES ===
typedef enum {
    NODE_PROGRAM,
    NODE_RECIPE,
    NODE_STEP,
    NODE_ACTION,
    NODE_IDENTIFIER,
    NODE_INTEGER,
    NODE_UNIT,
    NODE_IF,
    NODE_ASSIGNMENT,
    NODE_STRING,
    NODE_CONDITION,
    NODE_EXPRESSION,
    NODE_WHILE,
    NODE_REPEAT,
    NODE_OPERATOR
} ast_node_type;

typedef struct ast_node {
    ast_node_type type;
    char* value;
    struct ast_node* child;
    struct ast_node* sibling;
} ast_node;

// AST root
struct ast_node* ast_root = NULL;
char* current_recipe_name = NULL;

// Create new AST node
struct ast_node* new_node(ast_node_type type, char* value) {
    struct ast_node* node = (struct ast_node*)malloc(sizeof(struct ast_node));
    if (node) {
        node->type = type;
        node->value = value ? strdup(value) : NULL;
        node->child = NULL;
        node->sibling = NULL;
    }
    return node;
}

// Function to add a sibling to a node
struct ast_node* add_sibling(struct ast_node* current, struct ast_node* sibling) {
    if (!current) {
        return sibling;
    }
    struct ast_node* temp = current;
    while (temp->sibling) {
        temp = temp->sibling;
    }
    temp->sibling = sibling;
    return current;
}

// === SYMBOL TABLE DEFINITIONS ===
typedef enum {
    SYMBOL_INGREDIENT,
    SYMBOL_TOOL,
    SYMBOL_VARIABLE,
    TYPE_INT,   // Type checking additions
    TYPE_STRING,
    TYPE_FLOAT,
    TYPE_UNIT_WEIGHT,
    TYPE_UNIT_VOLUME,
    TYPE_UNIT_TIME,
    TYPE_UNIT_PIECE
} symbol_type;

typedef struct symbol_entry {
    char* name;
    symbol_type type;
    char* value;
    int used;  //  Track if symbol is used
    symbol_type data_type;  // Track the data type for type checking
    struct symbol_entry* next;
} symbol_entry;

typedef struct scope {
    struct symbol_entry* symbols;
    struct scope* next;
} scope;

scope* scope_stack = NULL;
scope* global_recipe_scope = NULL;

// === FORWARD DECLARATIONS ===
struct symbol_entry* lookup_symbol(char* name);
void validate_symbol_exists(char* name, const char* context);
void insert_symbol(char* name, symbol_type type, symbol_type data_type);
void insert_symbol_legacy(char* name, symbol_type type);

// Forward declarations for type checking functions
symbol_type get_node_type(ast_node* node);
symbol_type check_expression_type(ast_node* node);
const char* get_type_name(symbol_type type);
int are_types_compatible(symbol_type type1, symbol_type type2);
void check_assignment_types(ast_node* variable_node, ast_node* value_node);
void check_condition_types(ast_node* condition_node);
void validate_repeat_count(ast_node* times_node);

// Get type name for error messages
const char* get_type_name(symbol_type type) {
    switch(type) {
        case TYPE_INT: return "integer";
        case TYPE_STRING: return "string";
        case TYPE_FLOAT: return "float";
        case TYPE_UNIT_WEIGHT: return "weight_unit";
        case TYPE_UNIT_VOLUME: return "volume_unit";
        case TYPE_UNIT_TIME: return "time_unit";
        case TYPE_UNIT_PIECE: return "piece_unit";
        default: return "unknown";
    }
}

// Check type compatibility
int are_types_compatible(symbol_type type1, symbol_type type2) {
    // Identical types are always compatible
    if (type1 == type2) return 1;

    // Allowed implicit conversions
    if ((type1 == TYPE_INT && type2 == TYPE_FLOAT) ||
        (type1 == TYPE_FLOAT && type2 == TYPE_INT)) {
        return 1;
    }

    // Unit types can be compatible with integers in certain contexts
    if ((type1 == TYPE_INT && (type2 == TYPE_UNIT_WEIGHT || type2 == TYPE_UNIT_VOLUME ||
                               type2 == TYPE_UNIT_TIME || type2 == TYPE_UNIT_PIECE)) ||
        (type2 == TYPE_INT && (type1 == TYPE_UNIT_WEIGHT || type1 == TYPE_UNIT_VOLUME ||
                               type1 == TYPE_UNIT_TIME || type1 == TYPE_UNIT_PIECE))) {
        return 1;
    }

    return 0; // Incompatible types
}

// Get the type of a node
symbol_type get_node_type(ast_node* node) {
    if (!node) {
        fprintf(stderr, "COMPILER ERROR: Cannot determine type of NULL node\n");
        exit(1);
    }

    switch(node->type) {
        case NODE_INTEGER:
            return TYPE_INT;
        case NODE_STRING:
            return TYPE_STRING;
        case NODE_EXPRESSION:
            return check_expression_type(node);
        case NODE_IDENTIFIER: {
            symbol_entry* entry = lookup_symbol(node->value);
            if (!entry) {
                fprintf(stderr, "TYPE ERROR: Unknown identifier '%s' - cannot determine type\n", node->value);
                exit(1);
            }
            return entry->data_type;
        }
        default:
            fprintf(stderr, "COMPILER ERROR: Cannot determine type for node type %d\n", node->type);
            exit(1);
    }
}

// Check expression type with proper recursion
symbol_type check_expression_type(ast_node* node) {
    if (!node) {
        fprintf(stderr, "COMPILER ERROR: Cannot determine type of NULL expression node\n");
        exit(1);
    }

    if (node->type == NODE_EXPRESSION) {
        ast_node* left = node->child;
        ast_node* right = node->child ? node->child->sibling : NULL;

        if (!left || !right) {
            fprintf(stderr, "COMPILER ERROR: Malformed expression node - missing operands\n");
            exit(1);
        }

        symbol_type left_type = check_expression_type(left);
        symbol_type right_type = check_expression_type(right);

        if (!are_types_compatible(left_type, right_type)) {
            fprintf(stderr, "TYPE ERROR: Cannot perform '%s' operation between %s and %s\n",
                    node->value ? node->value : "unknown",
                    get_type_name(left_type),
                    get_type_name(right_type));
            exit(1);
        }

        // Return promoted type
        if (left_type == TYPE_FLOAT || right_type == TYPE_FLOAT) {
            return TYPE_FLOAT;
        }
        return TYPE_INT;
    }

    return get_node_type(node);
}

// Type check for assignments
void check_assignment_types(ast_node* variable_node, ast_node* value_node) {
    symbol_type var_type = get_node_type(variable_node);
    symbol_type val_type = get_node_type(value_node);

    if (!are_types_compatible(var_type, val_type)) {
        fprintf(stderr, "TYPE ERROR: Cannot assign %s to variable '%s' of type %s\n",
                get_type_name(val_type), variable_node->value, get_type_name(var_type));
        exit(1);
    }
}

// Check condition types
void check_condition_types(ast_node* condition_node) {
    if (!condition_node) return;

    if (condition_node->type == NODE_CONDITION) {
        ast_node* left = condition_node->child;
        ast_node* right = condition_node->child->sibling;

        if (!left || !right) {
            fprintf(stderr, "COMPILER ERROR: Malformed condition node\n");
            exit(1);
        }

        symbol_type left_type = check_expression_type(left);
        symbol_type right_type = check_expression_type(right);

        if (!are_types_compatible(left_type, right_type)) {
            fprintf(stderr, "TYPE ERROR: Cannot compare %s with %s in condition\n",
                    get_type_name(left_type), get_type_name(right_type));
            exit(1);
        }

        if (DEBUG) {
            printf("       → Type check passed: comparing %s with %s\n",
                   get_type_name(left_type), get_type_name(right_type));
        }
    }
}

// Validate repeat count with type checking
void validate_repeat_count(ast_node* times_node) {
    symbol_type times_type = get_node_type(times_node);

    if (times_type != TYPE_INT) {
        fprintf(stderr, "TYPE ERROR: REPEAT count must be integer, got %s\n",
                get_type_name(times_type));
        exit(1);
    }

    // If it's a literal, verify it's positive
    if (times_node->type == NODE_INTEGER) {
        int count = atoi(times_node->value);
        if (count <= 0) {
            fprintf(stderr, "SEMANTIC ERROR: REPEAT count must be positive, got %d\n", count);
            exit(1);
        }
        if (count > 1000) {  // Reasonable limit
            fprintf(stderr, "WARNING: Very high REPEAT count (%d) - are you sure?\n", count);
        }
    }
}

// Enter a new scope
void enter_scope(){
    scope* new_scope = malloc(sizeof(scope));
    new_scope->symbols = NULL;
    new_scope->next = scope_stack;
    scope_stack = new_scope;

    if (DEBUG) {
        printf(">>> Entering new local scope\n");
    }
}

// Exit a scope
void exit_scope() {
    if (!scope_stack) return;
    scope* old = scope_stack;
    scope_stack = scope_stack->next;

    // Free symbols
    symbol_entry* e = old->symbols;
    while (e) {
        symbol_entry* tmp = e;
        e = e->next;
        free(tmp->name);
        if (tmp->value) free(tmp->value);
        free(tmp);
    }
    free(old);

    if (DEBUG) {
        printf("<<< Exiting scope\n");
    }
}

void init_recipe_scope() {
    if (global_recipe_scope) return; // Already initialized

    global_recipe_scope = malloc(sizeof(scope));
    global_recipe_scope->symbols = NULL;
    global_recipe_scope->next = NULL;
    if (DEBUG) {
        printf(">>> Initializing global recipe scope\n");
    }
}

void cleanup_recipe_scope() {
    if (!global_recipe_scope) return;

    // Free symbols
    symbol_entry* e = global_recipe_scope->symbols;
    while (e) {
        symbol_entry* tmp = e;
        e = e->next;
        free(tmp->name);
        if (tmp->value) free(tmp->value);
        free(tmp);
    }
    free(global_recipe_scope);
    global_recipe_scope = NULL;
    if (DEBUG) {
        printf("<<< Cleaning up global recipe scope\n");
    }
}

struct symbol_entry* lookup_symbol(char* name) {
    // First check local scope stack
    for (scope* s = scope_stack; s; s = s->next) {
        for (symbol_entry* e = s->symbols; e; e = e->next) {
            if (strcmp(e->name, name) == 0) {
                if (DEBUG) {
                    printf("Found '%s' in LOCAL scope\n", name);
                }
                return e;
            }
        }
    }

    // Then check global recipe scope
    if (global_recipe_scope) {
        for (symbol_entry* e = global_recipe_scope->symbols; e; e = e->next) {
            if (strcmp(e->name, name) == 0) {
                if (DEBUG) {
                    printf("Found '%s' in GLOBAL scope\n", name);
                }
                return e;
            }
        }
    }

    return NULL;
}

// Function to validate symbol exists and mark as used
void validate_symbol_exists(char* name, const char* context) {
    struct symbol_entry* entry = lookup_symbol(name);
    if (!entry) {
        fprintf(stderr, "\n COOKING MISTAKE: '%s' not available!\n", name);
        fprintf(stderr, "   Used in: %s\n", context);

        // Specific hint based on context
        if (strstr(context, "tool") || strstr(context, "cook") || strstr(context, "boil")) {
            fprintf(stderr, "   Quick fix: Add 'get %s;' before using it\n", name);
        }
        else if (strstr(context, "ingredient") || strstr(context, "add")) {
            fprintf(stderr, "   Quick fix: Add 'add %s to container;' first\n", name);
        }
        else {
            fprintf(stderr, "   Quick fix: Declare '%s' before using it\n", name);
        }

        fprintf(stderr, "\n");
        exit(1);
    }
    entry->used = 1;  // Mark as used
}

// Insert a symbol in the current scope - ENHANCED for type checking
void insert_symbol(char* name, symbol_type type, symbol_type data_type) {
    // Ensure global scope exists
    if (!global_recipe_scope) {
        init_recipe_scope();
    }

    scope* target_scope;

    // Decide where to put the symbol based on type
    if(type == SYMBOL_TOOL || type == SYMBOL_INGREDIENT){
        target_scope = global_recipe_scope;
    }
    else {
        if(!scope_stack){
            enter_scope();
        }
        target_scope = scope_stack;
    }

    // Check for redeclaration in the target scope
    for (symbol_entry* e = target_scope->symbols; e; e = e->next) {
        if (strcmp(e->name, name) == 0) {
            if (type == SYMBOL_TOOL || type == SYMBOL_INGREDIENT) {
                printf("Warning: %s '%s' already available (ignoring redeclaration)\n",
                       (type == SYMBOL_TOOL) ? "Tool" : "Ingredient", name);
                return;
            }
            else {
                fprintf(stderr, "ERROR: Variable '%s' already declared.\n", name);
                return;
            }
        }
    }

    // Create new entry
    symbol_entry* new_entry = malloc(sizeof(symbol_entry));
    new_entry->name = strdup(name);
    new_entry->type = type;
    new_entry->data_type = data_type;  // Store the data type
    new_entry->value = NULL;
    new_entry->used = 0;  // Initialize as unused
    new_entry->next = target_scope->symbols;
    target_scope->symbols = new_entry;
}

// Wrapper for backward compatibility
void insert_symbol_legacy(char* name, symbol_type type) {
    symbol_type default_data_type = TYPE_STRING;  // Default fallback
    if (type == SYMBOL_TOOL || type == SYMBOL_INGREDIENT) {
        default_data_type = TYPE_STRING;
    }
    insert_symbol(name, type, default_data_type);
}

// Report unused symbols
void check_unused_symbols() {
    printf("\n=== KITCHEN EFFICIENCY CHECK ===\n");
    int found_unused = 0;

    if (global_recipe_scope) {
        for (symbol_entry* e = global_recipe_scope->symbols; e; e = e->next) {
            if (!e->used) {
                printf("Warning: %s '%s' prepared but never used\n",
                       (e->type == SYMBOL_TOOL) ? "Tool" : "Ingredient", e->name);
                found_unused = 1;
            }
        }
    }

    if (!found_unused) {
        printf("Perfect! All ingredients and tools were used efficiently!\n");
    }
    printf("=====================================\n");
}

// === SEMANTIC VALIDATION ===

void validate_get_action(char* tool_name) {
    if (strcmp(tool_name, "pot") == 0 ||
        strcmp(tool_name, "pan") == 0 ||
        strcmp(tool_name, "bowl") == 0 ||
        strcmp(tool_name, "spoon") == 0 ||
        strcmp(tool_name, "colander") == 0) {
        // Tool valido
        return;
    }
    fprintf(stderr, "ERROR: Unknown tool '%s'.\n", tool_name);
    exit(1);
}

// Validation for 'add'
void validate_add_target(char* target, const char* context) {
    if (strcmp(target, "pot") == 0 ||
        strcmp(target, "pan") == 0 ||
        strcmp(target, "bowl") == 0) {
        // Target valido
        return;
    }
    fprintf(stderr, "ERROR: Cannot add to '%s' in %s.\n", target, context);
    exit(1);
}

// Validation for ingredient
void validate_unit_for_ingredient(char* ingredient, char* unit) {
    if (strcmp(unit, "g") == 0 || strcmp(unit, "kg") == 0 ||
        strcmp(unit, "ml") == 0 || strcmp(unit, "l") == 0 ||
        strcmp(unit, "piece") == 0) {
        // Unità valida
        return;
    }
    fprintf(stderr, "ERROR: Invalid unit '%s' for ingredient '%s'.\n", unit, ingredient);
    exit(1);
}

// Validation for coocking
void validate_cooking_tool(char* tool, const char* cooking_method) {
    if (strcmp(cooking_method, "boil") == 0 ||
        strcmp(cooking_method, "fry") == 0 ||
        strcmp(cooking_method, "cook") == 0) {
        if (strcmp(tool, "pot") == 0 || strcmp(tool, "pan") == 0) {
            return; // Valido
        }
        fprintf(stderr, "ERROR: '%s' is not valid for %s.\n", tool, cooking_method);
        exit(1);
    }
}

// Validation for 'drain'
void validate_draining_action(char* item, char* tool) {
    if (strcmp(tool, "colander") != 0) {
        fprintf(stderr, "ERROR: Need a colander to drain '%s', not '%s'.\n", item, tool);
        exit(1);
    }
}

// Validation for 'mix'
void validate_mix_action(char* target) {
    if (strcmp(target, "bowl") == 0 || strcmp(target, "pot") == 0) {
        return;
    }
    fprintf(stderr, "ERROR: Cannot mix in '%s'.\n", target);
    exit(1);
}

// Enhanced validation for quantities and units
void validate_quantity_unit_compatibility(int quantity, const char* unit, const char* ingredient) {
    if (quantity < 0) {
        fprintf(stderr, "SEMANTIC ERROR: Negative quantity (%d) for ingredient '%s'\n", quantity, ingredient);
        exit(1);
    }

    if (quantity == 0) {
        fprintf(stderr, "WARNING: Zero quantity for ingredient '%s' - are you sure?\n", ingredient);
    }

    // Add reasonable limits for different units
    if (strcmp(unit, "g") == 0 && quantity > 10000) {
        fprintf(stderr, "WARNING: Very large weight (%d g) for ingredient '%s'\n", quantity, ingredient);
    } else if (strcmp(unit, "L") == 0 && quantity > 100) {
        fprintf(stderr, "WARNING: Very large volume (%d L) for ingredient '%s'\n", quantity, ingredient);
    } else if (strcmp(unit, "piece") == 0 && quantity > 1000) {
        fprintf(stderr, "WARNING: Very large count (%d pieces) for ingredient '%s'\n", quantity, ingredient);
    }

    if (DEBUG) {
        printf("Validated: %d %s of %s\n", quantity, unit, ingredient);
    }
}

// === SEMANTIC ANALYSIS FUNCTIONS ===
void analyze_program_semantics(ast_node* node);
void analyze_recipe_semantics(ast_node* node);
void analyze_step_semantics(ast_node* node);
void analyze_action_semantics(ast_node* node);

void analyze_program_semantics(ast_node* node) {
    if (!node || node->type != NODE_PROGRAM) return;

    printf("\n=== SEMANTIC ANALYSIS RESULTS ===\n");
    analyze_recipe_semantics(node->child);
    printf("=================================\n");
}

void analyze_recipe_semantics(ast_node* node) {
    if (!node || node->type != NODE_RECIPE) return;

    char* recipe_name = node->child->value;
    printf(" Analyzing recipe: %s\n", recipe_name);

    // Store recipe name for serve validation
    current_recipe_name = recipe_name;

    ast_node* current_step = node->child->sibling;
    while(current_step != NULL) {
        analyze_step_semantics(current_step);
        current_step = current_step->sibling;
    }
}

void analyze_step_semantics(ast_node* node) {
    if (!node || node->type != NODE_STEP) return;

    printf("  Analyzing Step %s\n", node->value);
    enter_scope();

    ast_node* current_action = node->child;
    while(current_action != NULL) {
        analyze_action_semantics(current_action);
        current_action = current_action->sibling;
    }

    exit_scope();
}

void analyze_action_semantics(ast_node* node) {
    if (!node) return;

    if (node->type == NODE_ACTION) {
        printf("    Validating action: %s", node->value);

        // Perform all semantic validations
        if (strcmp(node->value, "get") == 0) {
            char* item_name = node->child->value;
            validate_get_action(item_name);

            struct symbol_entry* entry = lookup_symbol(item_name);
            if (!entry) {
                insert_symbol_legacy(item_name, SYMBOL_TOOL);
                printf(" (new tool: %s)\n", item_name);
            } else {
                entry->used = 1;
                printf(" (existing tool: %s)\n", item_name);
            }

        } else if (strcmp(node->value, "add") == 0) {
            ast_node* arg1 = node->child;
            ast_node* arg2 = arg1->sibling;

            struct symbol_entry* entry = lookup_symbol(arg1->value);
            if (entry) entry->used = 1;

            if (arg2->type == NODE_INTEGER) {
                ast_node* arg3 = arg2->sibling;
                ast_node* arg4 = arg3->sibling;
                validate_add_target(arg4->value, "add action with quantity");
                validate_unit_for_ingredient(arg1->value, arg3->value);
                printf(" (%s %s of %s to %s)\n", arg2->value, arg3->value, arg1->value, arg4->value);
            } else {
                validate_add_target(arg2->value, "add action (simple)");
                printf(" (%s to %s)\n", arg1->value, arg2->value);
            }

        } else if (strcmp(node->value, "cook") == 0) {
            ast_node* arg1 = node->child;
            ast_node* arg2 = arg1->sibling;
            ast_node* arg3 = arg2->sibling;
            ast_node* arg4 = arg3->sibling;

            validate_symbol_exists(arg1->value, "cook action (ingredient)");
            validate_cooking_tool(arg2->value, "cook");
            printf(" (%s in %s for %s %s)\n", arg1->value, arg2->value, arg3->value, arg4->value);

        } else if (strcmp(node->value, "boil") == 0) {
            ast_node* arg1 = node->child;
            ast_node* arg2 = arg1->sibling;
            ast_node* arg3 = arg2->sibling;
            ast_node* arg4 = arg3->sibling;

            validate_symbol_exists(arg1->value, "boil action (ingredient)");
            validate_cooking_tool(arg2->value, "boil");
            printf(" (%s in %s for %s %s)\n", arg1->value, arg2->value, arg3->value, arg4->value);

        } else if (strcmp(node->value, "drain") == 0) {
            ast_node* arg1 = node->child;
            ast_node* arg2 = arg1->sibling;
            validate_draining_action(arg1->value, arg2->value);
            printf(" (%s using %s)\n", arg1->value, arg2->value);

        } else if (strcmp(node->value, "mix") == 0) {
            char* target = node->child->value;
            validate_mix_action(target);
            printf(" (%s)\n", target);

        } else if (strcmp(node->value, "return") == 0) {
            validate_symbol_exists(node->child->value, "return statement");
            printf(" (%s)\n", node->child->value);

        } else if (strcmp(node->value, "serve") == 0) {
            char* serve_target = node->child->value;
            if (current_recipe_name && strcmp(serve_target, current_recipe_name) == 0) {
                printf(" (final dish: %s)\n", serve_target);
            } else {
                validate_symbol_exists(serve_target, "serve action");
                printf(" (dish: %s)\n", serve_target);
            }
        } else {
            printf("\n");
        }

    } else if (node->type == NODE_ASSIGNMENT) {
        printf("    Validating assignment\n");
        ast_node* variable_node = node->child;
        ast_node* value_node = variable_node->sibling;

        // TYPE CHECKING: Check assignment compatibility
        if (lookup_symbol(variable_node->value) && value_node) {
            check_assignment_types(variable_node, value_node);
        }

        if (value_node->type == NODE_IDENTIFIER) {
            validate_symbol_exists(value_node->value, "assignment value");
        }

        if (!lookup_symbol(variable_node->value)) {
            // Determine data type from value
            symbol_type data_type = TYPE_STRING;  // default
            if (value_node->type == NODE_INTEGER) {
                data_type = TYPE_INT;
            } else if (value_node->type == NODE_STRING) {
                data_type = TYPE_STRING;
            }
            insert_symbol(variable_node->value, SYMBOL_VARIABLE, data_type);
        }

        struct symbol_entry* entry = lookup_symbol(variable_node->value);
        if (entry) {
            entry->used = 1;
            printf("      → Set '%s' = '%s'\n", variable_node->value, value_node->value);
        }

    } else if (node->type == NODE_IF) {
        printf("     Validating IF statement\n");
        ast_node* condition_node = node->child;
        ast_node* action_list = condition_node->sibling;

        // TYPE CHECKING: Check condition types
        check_condition_types(condition_node);

        enter_scope();
        ast_node* current_action = action_list;
        while(current_action != NULL) {
            analyze_action_semantics(current_action);
            current_action = current_action->sibling;
        }
        exit_scope();

    } else if (node->type == NODE_WHILE) {
        printf("     Validating WHILE loop\n");
        ast_node* condition_node = node->child;
        ast_node* action_list = condition_node->sibling;

        // TYPE CHECKING: Check condition types
        check_condition_types(condition_node);

        enter_scope();
        ast_node* current_action = action_list;
        while(current_action != NULL) {
            analyze_action_semantics(current_action);
            current_action = current_action->sibling;
        }
        exit_scope();

    } else if (node->type == NODE_REPEAT) {
        printf("     Validating REPEAT loop\n");
        ast_node* times_node = node->child;
        ast_node* action_list = times_node->sibling;

        // TYPE CHECKING: Validate repeat count
        validate_repeat_count(times_node);

        if (times_node->type == NODE_IDENTIFIER) {
            validate_symbol_exists(times_node->value, "REPEAT times");
        }

        enter_scope();
        ast_node* current_action = action_list;
        while(current_action != NULL) {
            analyze_action_semantics(current_action);
            current_action = current_action->sibling;
        }
        exit_scope();
    }
}

%}

// === UNION & TOKENS ===
%union {
    int int_val;
    double double_val;
    char* string_val;
    struct ast_node* node_ptr;
}

%token <string_val> IDENTIFIER STRING_LITERAL
%token <int_val> INTEGER_LITERAL
%token <double_val> FLOAT_LITERAL
%token RECIPE STEP GET ADD TO COOK IN RETURN BOIL DRAIN MIX SERVE
%token L_UNIT G_UNIT P_UNIT MIN_UNIT
%token LBRACE RBRACE SEMICOLON
%token IF LPAREN RPAREN EQ_OP NE_OP GT_OP LT_OP AND_OP ADD_OP SUB_OP MUL_OP DIV_OP
%token WHILE REPEAT TIMES
%token SET ASSIGN

%start program

%left AND_OP
%left EQ_OP NE_OP GT_OP LT_OP
%left ADD_OP SUB_OP
%left MUL_OP DIV_OP
%left UMINUS

// === AST NODE TYPES FOR GRAMMAR RULES ===
%type <node_ptr> program recipe_declaration step_list step_declaration action_list action if_statement condition assignment while_statement repeat_statement
%type <node_ptr> expression term factor logical_condition relation_condition

%%

/* Grammar rules with semantic actions */

program:
    recipe_declaration {
        ast_root = new_node(NODE_PROGRAM, NULL);
        ast_root->child = $1;
    }
    ;

recipe_declaration:
    RECIPE IDENTIFIER LBRACE step_list RBRACE {
        ast_node* id_node = new_node(NODE_IDENTIFIER, $2);
        ast_node* recipe_node = new_node(NODE_RECIPE, "recipe");
        recipe_node->child = add_sibling(id_node, $4);
        $$ = recipe_node;
    }
    ;

step_list:
    step_list step_declaration { $$ = add_sibling($1, $2); }
    | step_declaration         { $$ = $1; }
    ;

step_declaration:
    STEP INTEGER_LITERAL LBRACE action_list RBRACE {
        char num_str[16];
        sprintf(num_str, "%d", $2);
        ast_node* step_node = new_node(NODE_STEP, num_str);
        step_node->child = $4;
        $$ = step_node;
    }
    ;

if_statement:
    IF LPAREN condition RPAREN LBRACE action_list RBRACE {
        ast_node* if_node = new_node(NODE_IF, "if");
        if_node->child = $3; // The condition node
        if_node->child->sibling = $6; // The action list
        $$ = if_node;
    }
    ;

expression:
    term                               { $$ = $1; }
    | expression ADD_OP term           { $$ = new_node(NODE_EXPRESSION, "+"); $$->child = $1; $$->child->sibling = $3; }
    | expression SUB_OP term           { $$ = new_node(NODE_EXPRESSION, "-"); $$->child = $1; $$->child->sibling = $3; }
    ;

term:
    factor                             { $$ = $1; }
    | term MUL_OP factor               { $$ = new_node(NODE_EXPRESSION, "*"); $$->child = $1; $$->child->sibling = $3; }
    | term DIV_OP factor               { $$ = new_node(NODE_EXPRESSION, "/"); $$->child = $1; $$->child->sibling = $3; }
    ;

factor:
    INTEGER_LITERAL                    { char num_str[16]; sprintf(num_str, "%d", $1); $$ = new_node(NODE_INTEGER, num_str); }
    | IDENTIFIER                       { $$ = new_node(NODE_IDENTIFIER, $1); }
    | STRING_LITERAL                   { $$ = new_node(NODE_STRING, $1); }
    | LPAREN expression RPAREN         { $$ = $2; }
    ;

// Logical and relational condition rules
condition:
    logical_condition                  { $$ = $1; }
    ;

logical_condition:
    relation_condition                 { $$ = $1; }
    | logical_condition AND_OP relation_condition { $$ = new_node(NODE_CONDITION, "&&"); $$->child = $1; $$->child->sibling = $3; }
    ;

relation_condition:
    expression EQ_OP expression        { $$ = new_node(NODE_CONDITION, "=="); $$->child = $1; $$->child->sibling = $3; }
    | expression NE_OP expression      { $$ = new_node(NODE_CONDITION, "!="); $$->child = $1; $$->child->sibling = $3; }
    | expression GT_OP expression      { $$ = new_node(NODE_CONDITION, ">"); $$->child = $1; $$->child->sibling = $3; }
    | expression LT_OP expression      { $$ = new_node(NODE_CONDITION, "<"); $$->child = $1; $$->child->sibling = $3; }
    ;

while_statement:
    WHILE LPAREN condition RPAREN LBRACE action_list RBRACE {
        ast_node* while_node = new_node(NODE_WHILE, "while");
        while_node->child = $3;
        while_node->child->sibling = $6;
        $$ = while_node;
    }
    ;

repeat_statement:
    REPEAT INTEGER_LITERAL TIMES LBRACE action_list RBRACE {
        ast_node* repeat_node = new_node(NODE_REPEAT, "repeat");
        char num_str[16];
        sprintf(num_str, "%d", $2);
        ast_node* times_node = new_node(NODE_INTEGER, num_str);

        validate_repeat_count(times_node);

        repeat_node->child = times_node;
        repeat_node->child->sibling = $5;
        $$ = repeat_node;
    }
    | REPEAT IDENTIFIER TIMES LBRACE action_list RBRACE {
        ast_node* repeat_node = new_node(NODE_REPEAT, "repeat");
        ast_node* times_node = new_node(NODE_IDENTIFIER, $2);

        validate_repeat_count(times_node);

        repeat_node->child = times_node;
        repeat_node->child->sibling = $5;
        $$ = repeat_node;
    }
    ;

assignment:
    SET IDENTIFIER ASSIGN expression {
        ast_node* assign_node = new_node(NODE_ASSIGNMENT, "assignment");
        assign_node->child = new_node(NODE_IDENTIFIER, $2);
        assign_node->child->sibling = $4;
        $$ = assign_node;
    }
    ;

action_list:
    action_list action SEMICOLON { $$ = add_sibling($1, $2); }
    | action SEMICOLON { $$ = $1; }
    ;

action:
    GET IDENTIFIER {
        insert_symbol($2, SYMBOL_TOOL, TYPE_STRING);  // Enhanced with data type
        ast_node* get_node = new_node(NODE_ACTION, "get");
        get_node->child = new_node(NODE_IDENTIFIER, $2);
        $$ = get_node;
    }
    | ADD IDENTIFIER INTEGER_LITERAL G_UNIT TO IDENTIFIER {
        insert_symbol($2, SYMBOL_INGREDIENT, TYPE_UNIT_WEIGHT);
        validate_quantity_unit_compatibility($3, "g", $2);

        ast_node* add_node = new_node(NODE_ACTION, "add");
        char num_str[16];
        sprintf(num_str, "%d", $3);
        add_node->child = new_node(NODE_IDENTIFIER, $2);
        add_node->child->sibling = new_node(NODE_INTEGER, num_str);
        add_node->child->sibling->sibling = new_node(NODE_UNIT, "g");
        add_node->child->sibling->sibling->sibling = new_node(NODE_IDENTIFIER, $6);
        $$ =add_node;
    }
    | ADD IDENTIFIER INTEGER_LITERAL L_UNIT TO IDENTIFIER {
        insert_symbol($2, SYMBOL_INGREDIENT, TYPE_UNIT_VOLUME);
        validate_quantity_unit_compatibility($3, "L", $2);

        ast_node* add_node = new_node(NODE_ACTION, "add");
        char num_str[16];
        sprintf(num_str, "%d", $3);
        add_node->child = new_node(NODE_IDENTIFIER, $2);
        add_node->child->sibling = new_node(NODE_INTEGER, num_str);
        add_node->child->sibling->sibling = new_node(NODE_UNIT, "L");
        add_node->child->sibling->sibling->sibling = new_node(NODE_IDENTIFIER, $6);
        $$ =add_node;
    }
    | ADD IDENTIFIER INTEGER_LITERAL P_UNIT TO IDENTIFIER {
        insert_symbol($2, SYMBOL_INGREDIENT, TYPE_UNIT_PIECE);
        validate_quantity_unit_compatibility($3, "piece", $2);

        ast_node* add_node = new_node(NODE_ACTION, "add");
        char num_str[16];
        sprintf(num_str, "%d", $3);
        add_node->child = new_node(NODE_IDENTIFIER, $2);
        add_node->child->sibling = new_node(NODE_INTEGER, num_str);
        add_node->child->sibling->sibling = new_node(NODE_UNIT, "p");
        add_node->child->sibling->sibling->sibling = new_node(NODE_IDENTIFIER, $6);
        $$ =add_node;
    }
    | ADD IDENTIFIER TO IDENTIFIER {
        insert_symbol($2, SYMBOL_INGREDIENT, TYPE_STRING);
        ast_node* add_node = new_node(NODE_ACTION, "add");
        add_node->child = new_node(NODE_IDENTIFIER, $2);
        add_node->child->sibling = new_node(NODE_IDENTIFIER, $4);
        $$ =add_node;
    }
    | COOK IDENTIFIER IN IDENTIFIER INTEGER_LITERAL MIN_UNIT {
        ast_node* cook_node = new_node(NODE_ACTION, "cook");
        char num_str[16];
        sprintf(num_str, "%d", $5);
        cook_node->child = new_node(NODE_IDENTIFIER, $2);
        cook_node->child->sibling = new_node(NODE_IDENTIFIER, $4);
        cook_node->child->sibling->sibling = new_node(NODE_INTEGER, num_str);
        cook_node->child->sibling->sibling->sibling = new_node(NODE_UNIT, "min");
        $$ = cook_node;
    }
    | RETURN IDENTIFIER {
        ast_node* return_node = new_node(NODE_ACTION, "return");
        return_node->child = new_node(NODE_IDENTIFIER, $2);
        $$ = return_node;
    }
    | BOIL IDENTIFIER IN IDENTIFIER INTEGER_LITERAL MIN_UNIT {
        ast_node* boil_node = new_node(NODE_ACTION, "boil");
        char num_str[16];
        sprintf(num_str, "%d", $5);
        boil_node->child = new_node(NODE_IDENTIFIER, $2);
        boil_node->child->sibling = new_node(NODE_IDENTIFIER, $4);
        boil_node->child->sibling->sibling = new_node(NODE_INTEGER, num_str);
        boil_node->child->sibling->sibling->sibling = new_node(NODE_UNIT, "min");
        $$ = boil_node;
    }
    | DRAIN IDENTIFIER IDENTIFIER {
        ast_node* drain_node = new_node(NODE_ACTION, "drain");
        drain_node->child = new_node(NODE_IDENTIFIER, $2);
        drain_node->child->sibling = new_node(NODE_IDENTIFIER, $3);
        $$ = drain_node;
    }
    | MIX IDENTIFIER {
        ast_node* mix_node = new_node(NODE_ACTION, "mix");
        mix_node->child = new_node(NODE_IDENTIFIER, $2);
        $$ = mix_node;
    }
    | SERVE IDENTIFIER {
        ast_node* serve_node = new_node(NODE_ACTION, "serve");
        serve_node->child = new_node(NODE_IDENTIFIER, $2);
        $$ = serve_node;
    }
    | assignment
    | if_statement
    | while_statement
    | repeat_statement
    ;

%%

// === AST PRINT FUNCTION FOR DEMONSTRATION ===
void print_ast(struct ast_node* node, int level) {
    if (!node) return;

    for (int i = 0; i < level; i++) {
        printf("  ");
    }

    const char* type_str;
    switch(node->type) {
        case NODE_PROGRAM:      type_str = "PROGRAM"; break;
        case NODE_RECIPE:       type_str = "RECIPE"; break;
        case NODE_STEP:         type_str = "STEP"; break;
        case NODE_ACTION:       type_str = "ACTION"; break;
        case NODE_IDENTIFIER:   type_str = "IDENTIFIER"; break;
        case NODE_INTEGER:      type_str = "INTEGER"; break;
        case NODE_UNIT:         type_str = "UNIT"; break;
        case NODE_IF:           type_str = "IF"; break;
        case NODE_ASSIGNMENT:   type_str = "ASSIGNMENT"; break;
        case NODE_STRING:       type_str = "STRING"; break;
        case NODE_CONDITION:    type_str = "CONDITION"; break;
        case NODE_EXPRESSION:   type_str = "EXPRESSION"; break;
        case NODE_WHILE:        type_str = "WHILE"; break;
        case NODE_REPEAT:       type_str = "REPEAT"; break;
        default:                type_str = "UNKNOWN"; break;
    }

    printf("%s", type_str);
    if (node->value) {
        printf(": %s", node->value);
    }
    printf("\n");

    if (node->child) {
        print_ast(node->child, level + 1);
    }
    if (node->sibling) {
        print_ast(node->sibling, level);
    }
}

// === MAIN FUNCTION ===
int main(int argc, char **argv) {
    if (argc > 1) {
        FILE *file = fopen(argv[1], "r");
        if (!file) {
            perror(argv[1]);
            return 1;
        }
        yyin = file;
    }

    // Initialize the scope stack
    scope_stack = NULL;

    int result = yyparse();

    if (result == 0) {
        printf("COMPILATION SUCCESSFUL!\n");
        printf("--- AST ---\n");
        print_ast(ast_root, 0);
        printf("-----------\n");

        // Check for unused symbols at end of compilation
        check_unused_symbols();

        printf("\n ------ Recipe compiled successfully! ------ \n - No semantic errors found.\n");
        printf("   Type checking passed for all expressions and assignments.\n");

    } else {
        printf("COMPILATION FAILED - Fix syntax errors and try again.\n");
    }

    // Cleanup
    cleanup_recipe_scope();

    if (yyin != stdin) {
        fclose(yyin);
    }
    return result;
}

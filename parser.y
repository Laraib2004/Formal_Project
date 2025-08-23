%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int yylex();
extern FILE *yyin;

extern int yylineno;
extern char* yytext;

void yyerror(const char *s) {
    fprintf(stderr, "\n COOKING ERROR at line %d near '%s':\n", yylineno, yytext);
    fprintf(stderr, "   Problem: %s\n", s);

    // Add helpful hints
    if (strstr(s, "not declared") || strstr(s, "non dichiarata")) {
        fprintf(stderr, "   Fix: Did you forget to 'get' this tool or 'add' this ingredient?\n");
        fprintf(stderr, "   Common tools: pot, pan, spoon, bowl\n");
    }
    else if (strstr(s, "syntax error")) {
        fprintf(stderr, "   Fix: Check for missing semicolon ';' or closing brace '}'\n");
        fprintf(stderr, "   Recipe structure: recipe name { step 1 { actions; } }\n");
    }
    else if (strstr(s, "unexpected")) {
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
    NODE_WHILE,
    NODE_REPEAT
} ast_node_type;

typedef struct ast_node {
    ast_node_type type;
    char* value;
    struct ast_node* child;
    struct ast_node* sibling;
} ast_node;

// === GLOBAL VARIABLE FOR THE AST ROOT ===
struct ast_node* ast_root;

// Function to create a new node
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
    if (!current) return sibling;
    struct ast_node* temp = current;
    while (temp->sibling) {
        temp = temp->sibling;
    }
    temp->sibling = sibling;
    return current;
}

// === SYMBOL TABLE WITH SCOPES ===
typedef enum {
    SYMBOL_INGREDIENT,
    SYMBOL_TOOL,
    SYMBOL_VARIABLE
} symbol_type;

typedef struct symbol_entry {
    char* name;
    symbol_type type;
    char* value;
    int used;  //  Track if symbol is used
    struct symbol_entry* next;
} symbol_entry;

typedef struct scope {
    struct symbol_entry* symbols;
    struct scope* next;
} scope;

scope* scope_stack = NULL;
scope* global_recipe_scope = NULL;

// Scope management
void enter_scope() {
    scope* new_scope = malloc(sizeof(scope));
    new_scope->symbols = NULL;
    new_scope->next = scope_stack;
    scope_stack = new_scope;
    printf(">>> Entering new local scope\n");
}

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
    printf("<<< Exiting scope\n");
}

void init_recipe_scope() {
    if (global_recipe_scope) return; // Already initialized

    global_recipe_scope = malloc(sizeof(scope));
    global_recipe_scope->symbols = NULL;
    global_recipe_scope->next = NULL;
    printf(">>> Initializing global recipe scope\n");
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
    printf("<<< Cleaning up global recipe scope\n");
}

struct symbol_entry* lookup_symbol(char* name) {
    // First check local scope stack
    for (scope* s = scope_stack; s; s = s->next) {
        for (symbol_entry* e = s->symbols; e; e = e->next) {
            if (strcmp(e->name, name) == 0) {
                printf("Found '%s' in LOCAL scope\n", name);
                return e;
            }
        }
    }

    // Then check global recipe scope
    if (global_recipe_scope) {
        for (symbol_entry* e = global_recipe_scope->symbols; e; e = e->next) {
            if (strcmp(e->name, name) == 0) {
                printf("Found '%s' in GLOBAL scope\n", name);
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
        
        // Suggerimenti specifici per contesto
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

void insert_symbol(char* name, symbol_type type) {
    // Ensure global scope exists
    if (!global_recipe_scope) init_recipe_scope();

    scope* target_scope;
    const char* scope_name;

    // Decide where to put the symbol based on type
    if (type == SYMBOL_TOOL || type == SYMBOL_INGREDIENT) {
        target_scope = global_recipe_scope;
        scope_name = "GLOBAL";
    } else { // SYMBOL_VARIABLE
        if (!scope_stack) enter_scope(); // ensure local scope exists
        target_scope = scope_stack;
        scope_name = "LOCAL";
    }

    // Check for redeclaration in the target scope
    for (symbol_entry* e = target_scope->symbols; e; e = e->next) {
        if (strcmp(e->name, name) == 0) {
            // CHANGE: Make tool/ingredient redeclaration a warning instead of error
            if (type == SYMBOL_TOOL || type == SYMBOL_INGREDIENT) {
                printf("Warning: %s '%s' already available (ignoring redeclaration)\n",
                       (type == SYMBOL_TOOL) ? "Tool" : "Ingredient", name);
                return;  // Don't create duplicate, just ignore
            } else {
                // Variables still give errors for redeclaration in same scope
                fprintf(stderr, "ERROR: Variable '%s' già dichiarato in scope %s.\n", name, scope_name);
                return;
            }
        }
    }

    // Create new entry
    symbol_entry* new_entry = malloc(sizeof(symbol_entry));
    new_entry->name = strdup(name);
    new_entry->type = type;
    new_entry->value = NULL;
    new_entry->used = 0;  // Initialize as unused
    new_entry->next = target_scope->symbols;
    target_scope->symbols = new_entry;

    // Enhanced output
    printf("Symbol Table: Added '%s' as ", name);
    if (type == SYMBOL_TOOL) printf("TOOL in %s scope.\n", scope_name);
    else if (type == SYMBOL_INGREDIENT) printf("INGREDIENT in %s scope.\n", scope_name);
    else if (type == SYMBOL_VARIABLE) printf("VARIABLE in %s scope.\n", scope_name);
}

// Check for unused symbols at end of recipe
void check_unused_symbols() {
    printf("\n=== KITCHEN EFFICIENCY CHECK ===\n");
    int found_unused = 0;

    if (global_recipe_scope) {
        for (symbol_entry* e = global_recipe_scope->symbols; e; e = e->next) {
            if (!e->used) {
                const char* type_str = (e->type == SYMBOL_TOOL) ? "Tool" : "Ingredient";
                
                printf("Warning: %s '%s' prepared but never used\n", type_str, e->name);
                printf("   Tip: Remove unused declarations for cleaner recipes\n");
                found_unused = 1;
            }
        }
    }

    if (!found_unused) {
        printf("Perfect! All ingredients and tools were used efficiently!\n");
    }
    printf("=====================================\n");
}

void print_all_scopes() {
    printf("\n=== SCOPE DEBUG ===\n");

    printf("GLOBAL RECIPE SCOPE:\n");
    if (global_recipe_scope && global_recipe_scope->symbols) {
        for (symbol_entry* e = global_recipe_scope->symbols; e; e = e->next) {
            const char* type_str = (e->type == SYMBOL_TOOL) ? "TOOL" :
                                  (e->type == SYMBOL_INGREDIENT) ? "INGREDIENT" : "VARIABLE";
            printf("  %s (%s) = %s [%s]\n", e->name, type_str,
                   e->value ? e->value : "NULL", e->used ? "USED" : "UNUSED");
        }
    } else {
        printf("  (empty)\n");
    }

    printf("LOCAL SCOPE STACK:\n");
    if (scope_stack) {
        int level = 0;
        for (scope* s = scope_stack; s; s = s->next) {
            printf("  Level %d:\n", level++);
            if (s->symbols) {
                for (symbol_entry* e = s->symbols; e; e = e->next) {
                    const char* type_str = (e->type == SYMBOL_TOOL) ? "TOOL" :
                                          (e->type == SYMBOL_INGREDIENT) ? "INGREDIENT" : "VARIABLE";
                    printf("    %s (%s) = %s [%s]\n", e->name, type_str,
                           e->value ? e->value : "NULL", e->used ? "USED" : "UNUSED");
                }
            } else {
                printf("    (empty)\n");
            }
        }
    } else {
        printf("  (empty)\n");
    }
    printf("===================\n\n");
}

// === INTERPRETER FUNCTIONS WITH VALIDATION ===
void execute_if(ast_node* node);
void execute_assignment(ast_node* node);
void execute_action_node(ast_node* node);
void execute_action_list(ast_node* node);
void execute_step(ast_node* node);
void execute_recipe(ast_node* node);
int evaluate_condition(ast_node* condition_node);
void execute_while(ast_node* node);
void execute_repeat(ast_node* node);
void execute_program(ast_node* node);

void execute_if(ast_node* node) {
    printf("        * Executing IF statement...\n");
    ast_node* condition_node = node->child;
    ast_node* action_list = condition_node->sibling;

    // VALIDATION: Check if condition variables exist
    validate_symbol_exists(condition_node->child->value, "IF condition");

    if (evaluate_condition(condition_node)) {
        printf("        * Condition is TRUE - executing actions\n");
        enter_scope();
        execute_action_list(action_list);
        exit_scope();
    } else {
        printf("        * Condition is FALSE - skipping actions\n");
    }
}

void execute_assignment(ast_node* node) {
    ast_node* variable_node = node->child;
    ast_node* value_node = variable_node->sibling;

    printf("        * Executing SET statement...\n");

    // VALIDATION: If value is an identifier, check it exists
    if (value_node->type == NODE_IDENTIFIER) {
        validate_symbol_exists(value_node->value, "assignment value");
    }

    if (!lookup_symbol(variable_node->value)) {
        insert_symbol(variable_node->value, SYMBOL_VARIABLE);
    }
    
    struct symbol_entry* entry = lookup_symbol(variable_node->value);
    if (entry) {
        if (entry->value) free(entry->value);
        entry->value = strdup(value_node->value);
        entry->used = 1;  // Mark variable as used when assigned
        printf("        * Set variable '%s' to '%s'\n", entry->name, entry->value);
    } else {
        fprintf(stderr, "Error: variable '%s' not declared\n", variable_node->value);
    }
}

// Global variable to store recipe name
char* current_recipe_name = NULL;

void execute_action_node(ast_node* node) {
    if (strcmp(node->value, "get") == 0) {
        printf("        * Getting %s\n", node->child->value);
        // Mark tool as used when gotten
        struct symbol_entry* entry = lookup_symbol(node->child->value);
        if (entry) entry->used = 1;

    } else if (strcmp(node->value, "add") == 0) {
        ast_node* arg1 = node->child;
        ast_node* arg2 = arg1->sibling;

        // Mark ingredient as used when added
        struct symbol_entry* entry = lookup_symbol(arg1->value);
        if (entry) entry->used = 1;

        if (arg2->type == NODE_INTEGER) {
            ast_node* arg3 = arg2->sibling;
            ast_node* arg4 = arg3->sibling;
            // VALIDATION: Check if tool exists
            validate_symbol_exists(arg4->value, "add action (tool)");
            printf("        * Adding %s %s of %s to %s\n", arg2->value, arg3->value, arg1->value, arg4->value);
        } else {
            // VALIDATION: Check if target container exists
            validate_symbol_exists(arg2->value, "add action (container)");
            printf("        * Adding %s to %s\n", arg1->value, arg2->value);
        }

    } else if (strcmp(node->value, "cook") == 0) {
        ast_node* arg1 = node->child;
        ast_node* arg2 = arg1->sibling;
        ast_node* arg3 = arg2->sibling;
        ast_node* arg4 = arg3->sibling;
        // VALIDATION: Check if ingredient and tool exist
        validate_symbol_exists(arg1->value, "cook action (ingredient)");
        validate_symbol_exists(arg2->value, "cook action (tool)");
        printf("        * Cooking %s in %s for %s %s\n", arg1->value, arg2->value, arg3->value, arg4->value);

    } else if (strcmp(node->value, "return") == 0) {
        // VALIDATION: Check if return value exists
        validate_symbol_exists(node->child->value, "return statement");
        printf("        * Returning %s\n", node->child->value);

    } else if (strcmp(node->value, "boil") == 0) {
        ast_node* arg1 = node->child;
        ast_node* arg2 = arg1->sibling;
        ast_node* arg3 = arg2->sibling;
        ast_node* arg4 = arg3->sibling;
        // VALIDATION: Check if ingredient and tool exist
        validate_symbol_exists(arg1->value, "boil action (ingredient)");
        validate_symbol_exists(arg2->value, "boil action (tool)");
        printf("        * Boiling %s in %s for %s %s\n", arg1->value, arg2->value, arg3->value, arg4->value);

    } else if (strcmp(node->value, "drain") == 0) {
        ast_node* arg1 = node->child;
        ast_node* arg2 = arg1->sibling;
        // VALIDATION: Check if both arguments exist
        validate_symbol_exists(arg1->value, "drain action (ingredient)");
        validate_symbol_exists(arg2->value, "drain action (tool)");
        printf("        * Draining %s using %s\n", arg1->value, arg2->value);

    } else if (strcmp(node->value, "mix") == 0) {
        // VALIDATION: Check if ingredient/mixture exists
        validate_symbol_exists(node->child->value, "mix action");
        printf("        * Mixing %s\n", node->child->value);

    } else if (strcmp(node->value, "serve") == 0) {
        // SPECIAL CASE: Allow serving the recipe itself (final dish)
        char* serve_target = node->child->value;
        if (current_recipe_name && strcmp(serve_target, current_recipe_name) == 0) {
            printf("        * Serving the dish: %s (recipe complete!)\n", serve_target);
        } else {
            // VALIDATION: Check if dish exists
            validate_symbol_exists(serve_target, "serve action");
            printf("        * Serving the dish: %s\n", serve_target);
        }
    }
}

void execute_action_list(ast_node* node) {
    ast_node* current_action = node;
    while(current_action != NULL) {
        if (current_action->type == NODE_ACTION) {
            execute_action_node(current_action);
        } else if (current_action->type == NODE_ASSIGNMENT) {
            execute_assignment(current_action);
        } else if (current_action->type == NODE_IF) {
            execute_if(current_action);
        } else if (current_action->type == NODE_WHILE) {
            execute_while(current_action);
        } else if (current_action->type == NODE_REPEAT) {
            execute_repeat(current_action);
        }
        current_action = current_action->sibling;
    }
}


void execute_step(ast_node* node) {
    if (!node || node->type != NODE_STEP) return;
    printf("  --- Executing Step %s ---\n", node->value);
    enter_scope();
    execute_action_list(node->child);
    exit_scope();
}

void execute_recipe(ast_node* node) {
    if (!node || node->type != NODE_RECIPE) return;

    // Store recipe name for serve validation
    current_recipe_name = node->child->value;
    printf("--- Executing Recipe: %s ---\n", current_recipe_name);

    ast_node* current_step = node->child->sibling;
    while(current_step != NULL) {
        execute_step(current_step);
        current_step = current_step->sibling;
    }

    // Check for unused symbols at end of recipe
    check_unused_symbols();
}

int evaluate_condition(ast_node* condition_node) {
    if (!condition_node || condition_node->type != NODE_CONDITION) return 0;
    
    ast_node* left = condition_node->child;
    ast_node* right = left->sibling;
    
    char* left_value = NULL;
    if (left->type == NODE_IDENTIFIER) {
        struct symbol_entry* entry = lookup_symbol(left->value);
        left_value = entry ? entry->value : left->value;
    } else {
        left_value = left->value;
    }
    
    char* right_value = right->value;
    
    if (left_value && right_value) {
        return strcmp(left_value, right_value) == 0;
    }
    return 0;
}

void execute_while(ast_node* node) {
    printf("        * Executing WHILE loop...\n");
    ast_node* condition_node = node->child;
    ast_node* action_list = condition_node->sibling;
    
    validate_symbol_exists(condition_node->child->value, "WHILE condition");
    
    int iterations = 0;
    const int MAX_ITERATIONS = 1000;
    
    while (evaluate_condition(condition_node) && iterations < MAX_ITERATIONS) {
        iterations++;
        printf("        * WHILE iteration %d (condition still true)\n", iterations);
        
        enter_scope();
        execute_action_list(action_list);
        exit_scope();
    }

    if (iterations >= MAX_ITERATIONS) {
        printf("        * WHILE loop stopped: reached maximum %d iterations (safety limit)\n", MAX_ITERATIONS);
    } else {
        printf("        * WHILE loop completed after %d iterations (condition became false)\n", iterations);
    }
}

void execute_repeat(ast_node* node) {
    printf("        * Executing REPEAT loop...\n");
    ast_node* times_node = node->child;
    ast_node* action_list = times_node->sibling;
    
    int times = 0;
    if (times_node->type == NODE_INTEGER) {
        times = atoi(times_node->value);
    } else if (times_node->type == NODE_IDENTIFIER) {
        validate_symbol_exists(times_node->value, "REPEAT times");
        struct symbol_entry* entry = lookup_symbol(times_node->value);
        if (entry && entry->value) {
            times = atoi(entry->value);
        } else {
            fprintf(stderr, "Error: Variable '%s' has no numeric value for REPEAT\n", times_node->value);
            return;
        }
    }

    // Limit to prevent infinite loops
    if (times > 100) {
        fprintf(stderr, "WARNING: REPEAT %d times seems excessive - limiting to 100\n", times);
        times = 100;
    } else if (times < 0) {
        fprintf(stderr, "WARNING: REPEAT %d times is negative - skipping loop\n", times);
        return;
    }
    
    for (int i = 1; i <= times; i++) {
        printf("        * REPEAT iteration %d of %d\n", i, times);
        enter_scope();
        execute_action_list(action_list);
        exit_scope();
    }

    printf("        * REPEAT loop completed after %d iterations\n", times);
}

void execute_program(ast_node* node) {
    if (!node || node->type != NODE_PROGRAM) return;
    execute_recipe(node->child);
}
%}

// === UNION & TOKENS (unchanged) ===
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
%token IF LPAREN RPAREN EQ_OP
%token WHILE REPEAT TIMES
%token SET ASSIGN

%start program

// === AST NODE TYPES FOR GRAMMAR RULES ===
%type <node_ptr> program recipe_declaration step_list step_declaration action_list action if_statement condition assignment while_statement repeat_statement

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

condition:
    IDENTIFIER EQ_OP IDENTIFIER {
        ast_node* condition_node = new_node(NODE_CONDITION, "condition");
        condition_node->child = new_node(NODE_IDENTIFIER, $1);
        condition_node->child->sibling = new_node(NODE_IDENTIFIER, $3);
        $$ = condition_node;
    }
    | IDENTIFIER EQ_OP INTEGER_LITERAL {
        ast_node* condition_node = new_node(NODE_CONDITION, "condition");
        condition_node->child = new_node(NODE_IDENTIFIER, $1);
        char num_str[16];
        sprintf(num_str, "%d", $3);
        condition_node->child->sibling = new_node(NODE_INTEGER, num_str);
        $$ = condition_node;
    }
    | IDENTIFIER EQ_OP STRING_LITERAL {
        ast_node* condition_node = new_node(NODE_CONDITION, "condition");
        condition_node->child = new_node(NODE_IDENTIFIER, $1);
        condition_node->child->sibling = new_node(NODE_STRING, $3);
        $$ = condition_node;
    }
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
        repeat_node->child = new_node(NODE_INTEGER, num_str);
        repeat_node->child->sibling = $5;
        $$ = repeat_node;
    }
    | REPEAT IDENTIFIER TIMES LBRACE action_list RBRACE {
        ast_node* repeat_node = new_node(NODE_REPEAT, "repeat");
        repeat_node->child = new_node(NODE_IDENTIFIER, $2);
        repeat_node->child->sibling = $5;
        $$ = repeat_node;
    }
    ;

assignment:
    SET IDENTIFIER ASSIGN IDENTIFIER {
        ast_node* assign_node = new_node(NODE_ASSIGNMENT, "assignment");
        assign_node->child = new_node(NODE_IDENTIFIER, $2);
        assign_node->child->sibling = new_node(NODE_IDENTIFIER, $4);
        $$ = assign_node;
    }
    | SET IDENTIFIER ASSIGN INTEGER_LITERAL {
        ast_node* assign_node = new_node(NODE_ASSIGNMENT, "assignment");
        assign_node->child = new_node(NODE_IDENTIFIER, $2);
        char num_str[16];
        sprintf(num_str, "%d", $4);
        assign_node->child->sibling = new_node(NODE_INTEGER, num_str);
        $$ = assign_node;
    }
    | SET IDENTIFIER ASSIGN STRING_LITERAL {
        ast_node* assign_node = new_node(NODE_ASSIGNMENT, "assignment");
        assign_node->child = new_node(NODE_IDENTIFIER, $2);
        assign_node->child->sibling = new_node(NODE_STRING, $4);
        $$ = assign_node;
    }
    ;

action_list:
    action SEMICOLON { $$ = $1; }
   | action { $$ = $1; }
       | action_list action SEMICOLON { $$ = add_sibling($1, $2); }
       | action_list action { $$ = add_sibling($1, $2); }
    ;

action:
    GET IDENTIFIER {
        insert_symbol($2, SYMBOL_TOOL);
        ast_node* get_node = new_node(NODE_ACTION, "get");
        get_node->child = new_node(NODE_IDENTIFIER, $2);
        $$ = get_node;
    }
    | ADD IDENTIFIER INTEGER_LITERAL G_UNIT TO IDENTIFIER {
        insert_symbol($2, SYMBOL_INGREDIENT);
        ast_node* add_node = new_node(NODE_ACTION, "add");
        char num_str[16];
        sprintf(num_str, "%d", $3);
        add_node->child = new_node(NODE_IDENTIFIER, $2);
        add_node->child->sibling = new_node(NODE_INTEGER, num_str);
        add_node->child->sibling->sibling = new_node(NODE_UNIT, "g");
        add_node->child->sibling->sibling->sibling = new_node(NODE_IDENTIFIER, $6);
        $$ = add_node;
    }
    | ADD IDENTIFIER INTEGER_LITERAL L_UNIT TO IDENTIFIER {
        insert_symbol($2, SYMBOL_INGREDIENT);
        ast_node* add_node = new_node(NODE_ACTION, "add");
        char num_str[16];
        sprintf(num_str, "%d", $3);
        add_node->child = new_node(NODE_IDENTIFIER, $2);
        add_node->child->sibling = new_node(NODE_INTEGER, num_str);
        add_node->child->sibling->sibling = new_node(NODE_UNIT, "L");
        add_node->child->sibling->sibling->sibling = new_node(NODE_IDENTIFIER, $6);
        $$ = add_node;
    }
    | ADD IDENTIFIER INTEGER_LITERAL P_UNIT TO IDENTIFIER {
        insert_symbol($2, SYMBOL_INGREDIENT);
        ast_node* add_node = new_node(NODE_ACTION, "add");
        char num_str[16];
        sprintf(num_str, "%d", $3);
        add_node->child = new_node(NODE_IDENTIFIER, $2);
        add_node->child->sibling = new_node(NODE_INTEGER, num_str);
        add_node->child->sibling->sibling = new_node(NODE_UNIT, "p");
        add_node->child->sibling->sibling->sibling = new_node(NODE_IDENTIFIER, $6);
        $$ = add_node;
    }
    | ADD IDENTIFIER TO IDENTIFIER {
        insert_symbol($2, SYMBOL_INGREDIENT);
        ast_node* add_node = new_node(NODE_ACTION, "add");
        add_node->child = new_node(NODE_IDENTIFIER, $2);
        add_node->child->sibling = new_node(NODE_IDENTIFIER, $4);
        $$ = add_node;
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
        printf("Parsing successful!\n");
        printf("--- AST ---\n");
        print_ast(ast_root, 0);
        printf("-----------\n");

        printf("\n--- INTERPRETER OUTPUT ---\n");
        execute_program(ast_root);
        printf("--------------------------\n");

    } else {
        printf("Parsing failed.\n");
    }

    // Cleanup
    cleanup_recipe_scope();
    
    if (yyin != stdin) {
        fclose(yyin);
    }
    return result;
}


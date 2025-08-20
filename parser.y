%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int yylex();
extern FILE *yyin;

void yyerror(const char *s) {
    fprintf(stderr, "Syntax error: %s\n", s);
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
    NODE_CONDITION // New node type for the condition
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


// === SYMBOL TABLE DATA STRUCTURES ===
typedef enum {
    SYMBOL_INGREDIENT,
    SYMBOL_TOOL,
    SYMBOL_VARIABLE // A new type for variables
} symbol_type;

typedef struct symbol_entry {
    char* name;
    symbol_type type;
    char* value; // Storing the value for interpreter
    struct symbol_entry* next;
} symbol_entry;

// Simple linked list for the symbol table
struct symbol_entry* symbol_table = NULL;

// === FORWARD DECLARATION ===
// This tells the compiler that lookup_symbol exists and what its signature is.
struct symbol_entry* lookup_symbol(char* name);

// Corrected function to insert a symbol into the table
void insert_symbol(char* name, symbol_type type) {
    if (lookup_symbol(name) != NULL) {
        fprintf(stderr, "Warning: '%s' is being added again. Symbol table already contains it.\n", name);
        return;
    }
    
    struct symbol_entry* new_entry = (struct symbol_entry*)malloc(sizeof(struct symbol_entry));
    if (!new_entry) {
        fprintf(stderr, "Error: Could not allocate memory for symbol.\n");
        return;
    }
    new_entry->name = strdup(name);
    new_entry->type = type;
    new_entry->value = NULL; // Initialize value
    new_entry->next = symbol_table;
    symbol_table = new_entry;
    printf("Symbol Table: Added '%s' as a ", name);
    if (type == SYMBOL_TOOL) printf("TOOL.\n");
    else if (type == SYMBOL_INGREDIENT) printf("INGREDIENT.\n");
    else if (type == SYMBOL_VARIABLE) printf("VARIABLE.\n");
}

// Function to look up a symbol in the table
struct symbol_entry* lookup_symbol(char* name) {
    struct symbol_entry* current = symbol_table;
    while (current != NULL) {
        if (strcmp(current->name, name) == 0) {
            return current;
        }
        current = current->next;
    }
    return NULL;
}

// === INTERPRETER FUNCTIONS ===
// Forward declarations for the interpreter functions
void execute_if(ast_node* node);
void execute_assignment(ast_node* node);
void execute_action_node(ast_node* node);
void execute_action_list(ast_node* node);
void execute_step(ast_node* node);
void execute_recipe(ast_node* node);
void execute_program(ast_node* node);

void execute_if(ast_node* node) {
    printf("        * Executing IF statement...\n");
    ast_node* condition_node = node->child;
    ast_node* action_list = condition_node->sibling;

    // TODO: Implement actual conditional logic here
    // This is just a placeholder for now
    printf("        * Condition is: %s == %s\n", condition_node->child->value, condition_node->child->sibling->value);

    // Call the new helper function to execute the actions inside the 'if' block
    execute_action_list(action_list); 
}

void execute_assignment(ast_node* node) {
    ast_node* variable_node = node->child;
    ast_node* value_node = variable_node->sibling;

    printf("        * Executing SET statement...\n");

    // Check if the variable exists in the symbol table, if not, add it
    if (!lookup_symbol(variable_node->value)) {
        insert_symbol(variable_node->value, SYMBOL_VARIABLE);
    }
    
    // Store the value
    struct symbol_entry* entry = lookup_symbol(variable_node->value);
    if (entry) {
        if (entry->value) free(entry->value);
        entry->value = strdup(value_node->value);
        printf("        * Set variable '%s' to '%s'\n", entry->name, entry->value);
    }
}


void execute_action_node(ast_node* node) {
    if (strcmp(node->value, "get") == 0) {
        printf("        * Getting %s\n", node->child->value);
    } else if (strcmp(node->value, "add") == 0) {
        ast_node* arg1 = node->child;
        ast_node* arg2 = arg1->sibling;
        
        if (arg2->type == NODE_INTEGER) { // has quantity: add INGREDIENT INT UNIT TO TOOL
            ast_node* arg3 = arg2->sibling;
            ast_node* arg4 = arg3->sibling;
            printf("        * Adding %s %s of %s to %s\n", arg2->value, arg3->value, arg1->value, arg4->value);
        } else { // no quantity: add INGREDIENT TO TOOL
            printf("        * Adding %s to %s\n", arg1->value, arg2->value);
        }

    } else if (strcmp(node->value, "cook") == 0) {
        ast_node* arg1 = node->child;
        ast_node* arg2 = arg1->sibling;
        ast_node* arg3 = arg2->sibling;
        ast_node* arg4 = arg3->sibling;
        printf("        * Cooking %s in %s for %s %s\n", arg1->value, arg2->value, arg3->value, arg4->value);
    } else if (strcmp(node->value, "return") == 0) {
        printf("        * Returning %s\n", node->child->value);
    } else if (strcmp(node->value, "boil") == 0) {
        ast_node* arg1 = node->child;
        ast_node* arg2 = arg1->sibling;
        ast_node* arg3 = arg2->sibling;
        ast_node* arg4 = arg3->sibling;
        printf("        * Boiling %s in %s for %s %s\n", arg1->value, arg2->value, arg3->value, arg4->value);
    } else if (strcmp(node->value, "drain") == 0) {
        ast_node* arg1 = node->child;
        ast_node* arg2 = arg1->sibling;
        printf("        * Draining %s using %s\n", arg1->value, arg2->value);
    } else if (strcmp(node->value, "mix") == 0) {
        printf("        * Mixing %s\n", node->child->value);
    } else if (strcmp(node->value, "serve") == 0) {
        printf("        * Serving the dish: %s\n", node->child->value);
    }
}

// New function to execute a list of actions (e.g., inside an 'if' block)
void execute_action_list(ast_node* node) {
    ast_node* current_action = node;
    while(current_action != NULL) {
        if (current_action->type == NODE_ACTION) {
            execute_action_node(current_action);
        } else if (current_action->type == NODE_ASSIGNMENT) {
            execute_assignment(current_action);
        } else if (current_action->type == NODE_IF) {
            execute_if(current_action);
        }
        current_action = current_action->sibling;
    }
}

// execute_step now acts as a dispatcher
void execute_step(ast_node* node) {
    if (!node || node->type != NODE_STEP) return;
    
    printf("  --- Executing Step %s ---\n", node->value);
    
    // Call the new helper function to execute the actions within the step
    execute_action_list(node->child);
}

void execute_recipe(ast_node* node) {
    if (!node || node->type != NODE_RECIPE) return;

    // The first child is the IDENTIFIER, the second is the step list
    printf("--- Executing Recipe: %s ---\n", node->child->value);
    
    ast_node* current_step = node->child->sibling;
    while(current_step != NULL) {
        execute_step(current_step);
        current_step = current_step->sibling;
    }
}

void execute_program(ast_node* node) {
    if (!node || node->type != NODE_PROGRAM) return;

    execute_recipe(node->child);
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
%token IF LPAREN RPAREN EQ_OP
%token SET ASSIGN

%start program

// === AST NODE TYPES FOR GRAMMAR RULES ===
%type <node_ptr> program recipe_declaration step_list step_declaration action_list action if_statement condition assignment 

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
    | action_list action SEMICOLON { $$ = add_sibling($1, $2); }
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

    // Initialize the symbol table
    symbol_table = NULL;

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

    if (yyin != stdin) {
        fclose(yyin);
    }
    return result;
}
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
    NODE_UNIT
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
    SYMBOL_TOOL
} symbol_type;

typedef struct symbol_entry {
    char* name;
    symbol_type type;
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
    new_entry->next = symbol_table;
    symbol_table = new_entry;
    printf("Symbol Table: Added '%s' as a ", name);
    if (type == SYMBOL_TOOL) printf("TOOL.\n");
    else if (type == SYMBOL_INGREDIENT) printf("INGREDIENT.\n");
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
%}

// === UNION & TOKENS ===
%union {
    int int_val;
    double double_val;
    char* string_val;
    struct ast_node* node_ptr;
}

%token <string_val> IDENTIFIER
%token <int_val> INTEGER_LITERAL
%token <double_val> FLOAT_LITERAL
%token RECIPE STEP GET ADD TO COOK IN RETURN BOIL DRAIN MIX SERVE
%token L_UNIT G_UNIT P_UNIT MIN_UNIT
%token LBRACE RBRACE SEMICOLON

%start program

// === AST NODE TYPES FOR GRAMMAR RULES ===
%type <node_ptr> program recipe_declaration step_list step_declaration action_list action

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
        // Here you could also insert the recipe name into the symbol table
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

action_list:
    action SEMICOLON { $$ = $1; }
    | action_list action SEMICOLON { $$ = add_sibling($1, $2); }
    ;

action:
    GET IDENTIFIER {
        // Semantic action: Add the identifier to the symbol table as a TOOL
        insert_symbol($2, SYMBOL_TOOL);
        ast_node* get_node = new_node(NODE_ACTION, "get");
        get_node->child = new_node(NODE_IDENTIFIER, $2);
        $$ = get_node;
    }
    | ADD IDENTIFIER INTEGER_LITERAL G_UNIT TO IDENTIFIER {
        // Semantic action: Add the identifier to the symbol table as an INGREDIENT
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
        // Semantic action: Add the identifier to the symbol table as an INGREDIENT
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
        // Semantic action: Add the identifier to the symbol table as an INGREDIENT
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
        // Semantic action: Add the identifier to the symbol table as an INGREDIENT
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
        case NODE_PROGRAM:    type_str = "PROGRAM"; break;
        case NODE_RECIPE:     type_str = "RECIPE"; break;
        case NODE_STEP:       type_str = "STEP"; break;
        case NODE_ACTION:     type_str = "ACTION"; break;
        case NODE_IDENTIFIER: type_str = "IDENTIFIER"; break;
        case NODE_INTEGER:    type_str = "INTEGER"; break;
        case NODE_UNIT:       type_str = "UNIT"; break;
        default:              type_str = "UNKNOWN"; break;
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
        print_ast(ast_root, 0); // Correctly calls print on the global AST root
        printf("-----------\n");
    } else {
        printf("Parsing failed.\n");
    }

    if (yyin != stdin) {
        fclose(yyin);
    }
    return result;
}
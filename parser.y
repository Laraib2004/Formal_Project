%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int yylex();
extern FILE *yyin;

void yyerror(const char *s) {
    fprintf(stderr, "Syntax error: %s\n", s);
}
%}

%union {
    int int_val;
    double double_val;
    char* string_val;
}

%token <string_val> IDENTIFIER
%token <int_val> INTEGER_LITERAL
%token <double_val> FLOAT_LITERAL
%token RECIPE STEP GET ADD TO COOK IN RETURN BOIL DRAIN MIX SERVE
%token L_UNIT G_UNIT P_UNIT MIN_UNIT
%token LBRACE RBRACE SEMICOLON

%start program

%%

/* Grammar rules for the 'recipe' language */

program:
    recipe_declaration
    ;

recipe_declaration:
    RECIPE IDENTIFIER LBRACE step_list RBRACE
    ;

step_list:
    step_list step_declaration
    | step_declaration
    ;

step_declaration:
    STEP INTEGER_LITERAL LBRACE action_list RBRACE
    ;

/* Unambiguous grammar for a list of actions separated by semicolons */
action_list:
    action SEMICOLON
    | action_list action SEMICOLON
    ;

action:
    GET IDENTIFIER
    | ADD IDENTIFIER INTEGER_LITERAL G_UNIT TO IDENTIFIER
    | ADD IDENTIFIER INTEGER_LITERAL L_UNIT TO IDENTIFIER
    | ADD IDENTIFIER INTEGER_LITERAL P_UNIT TO IDENTIFIER
    | ADD IDENTIFIER TO IDENTIFIER
    | COOK IDENTIFIER IN IDENTIFIER INTEGER_LITERAL MIN_UNIT
    | RETURN IDENTIFIER
    | BOIL IDENTIFIER IN IDENTIFIER INTEGER_LITERAL MIN_UNIT
    | DRAIN IDENTIFIER IDENTIFIER
    | MIX IDENTIFIER
    | SERVE IDENTIFIER
    ;

%%

int main(int argc, char **argv) {
    if (argc > 1) {
        FILE *file = fopen(argv[1], "r");
        if (!file) {
            perror(argv[1]);
            return 1;
        }
        yyin = file;
    }

    int result = yyparse();
    
    if (result == 0) {
        printf("Parsing successful!\n");
    } else {
        printf("Parsing failed.\n");
    }

    if (yyin != stdin) {
        fclose(yyin);
    }
    return result;
}
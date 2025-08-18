%{
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "parser.tab.h"

// Function to handle string attributes.
char* my_strdup(const char* s) {
    char* d = malloc(strlen(s) + 1);
    if (d == NULL) return NULL;
    strcpy(d, s);
    return d;
}

%}

%%

"recipe"        { return RECIPE; }
"step"          { return STEP; }
"get"           { return GET; }
"add"           { return ADD; }
"to"            { return TO; }
"cook"          { return COOK; }
"in"            { return IN; }
"return"        { return RETURN; }
"boil"          { return BOIL; }
"drain"         { return DRAIN; }
"mix"           { return MIX; }
"serve"         { return SERVE; }
"L"             { return L_UNIT; }
"g"             { return G_UNIT; }
"p"             { return P_UNIT; }
"min"           { return MIN_UNIT; }

"{"             { return LBRACE; }
"}"             { return RBRACE; }
";"             { return SEMICOLON; }

[a-zA-Z_][a-zA-Z0-9_]* {
    yylval.string_val = my_strdup(yytext);
    return IDENTIFIER;
}

[0-9]+            {
    yylval.int_val = atoi(yytext);
    return INTEGER_LITERAL;
}

[0-9]+"."?[0-9]* {
    yylval.double_val = atof(yytext);
    return FLOAT_LITERAL;
}

[ \t\n]+        { /* ignore whitespace */ }

.               { fprintf(stderr, "Error: Invalid character '%c'\n", *yytext); }

%%
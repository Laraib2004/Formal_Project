%option yylineno
%option noyywrap
%option nounput noinput

%{
/*
 * recipe.l - Lexical analyser for the "Recipe" language.
 *
 * Each token is recognised with a regular expression and, where it carries
 * information (numbers, identifiers, strings), the corresponding attribute is
 * placed in yylval for the parser. The numeric conversion done here (atoi/atof)
 * is the ONLY place text becomes a value - the parser keeps that value as-is.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "parser.tab.h"
%}

%%

    /* ---- Keywords: recipe structure ---- */
"recipe"        { return RECIPE; }
"step"          { return STEP; }

    /* ---- Keywords: cooking actions ---- */
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

    /* ---- Keywords: control flow / variables ---- */
"if"            { return IF; }
"set"           { return SET; }
"while"         { return WHILE; }
"repeat"        { return REPEAT; }
"times"         { return TIMES; }

    /* ---- Measurement units ---- */
"L"             { return L_UNIT; }
"g"             { return G_UNIT; }
"p"             { return P_UNIT; }
"min"           { return MIN_UNIT; }

    /* ---- Punctuation ---- */
"{"             { return LBRACE; }
"}"             { return RBRACE; }
";"             { return SEMICOLON; }
"("             { return LPAREN; }
")"             { return RPAREN; }

    /* ---- Operators (multi-char before single-char) ---- */
"=="            { return EQ_OP; }
"!="            { return NE_OP; }
"&&"            { return AND_OP; }
">"             { return GT_OP; }
"<"             { return LT_OP; }
"="             { return ASSIGN; }
"+"             { return ADD_OP; }
"-"             { return SUB_OP; }
"*"             { return MUL_OP; }
"/"             { return DIV_OP; }

    /* ---- Literals ---- */
    /* Float must carry a dot with digits on both sides so it never steals
       a plain integer. atof performs the text->value conversion once. */
[0-9]+"."[0-9]+ {
    yylval.double_val = atof(yytext);
    return FLOAT_LITERAL;
}

[0-9]+ {
    yylval.int_val = atoi(yytext);
    return INTEGER_LITERAL;
}

\"[^\"]*\" {
    /* Copy the string including quotes; the parser strips them if needed. */
    yylval.string_val = strdup(yytext);
    return STRING_LITERAL;
}

[a-zA-Z_][a-zA-Z0-9_]* {
    yylval.string_val = strdup(yytext);
    return IDENTIFIER;
}

    /* ---- Trivia ---- */
"//"[^\n]*      { /* single-line comment: ignored */ }
[ \t\r\n]+      { /* whitespace: ignored */ }

.               { fprintf(stderr, "Lexical error (line %d): stray character '%c'\n", yylineno, *yytext); }

%%

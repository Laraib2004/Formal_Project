%option yylineno
%option noyywrap
%option nounput noinput

%{
/*
 * recipe.l - Lexical analyser for the block-structured "Recipe" language.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "parser.tab.h"

extern int lex_errors;
%}

%%

    /* ---- Keywords: Globals & Structure ---- */
"ingredients"   { return INGREDIENTS; }
"tools"         { return TOOLS; }
"recipe"        { return RECIPE; }

    /* ---- Keywords: Built-ins & Control Flow ---- */
"retrieve"      { return RETRIEVE; }
"return"        { return RETURN; }
"if"            { return IF; }
"while"         { return WHILE; }
"repeat"        { return REPEAT; }
"times"         { return TIMES; }

    /* ---- Measurement units ---- */
"L"             { return L_UNIT; }
"g"             { return G_UNIT; }
"p"             { return P_UNIT; }
"min"           { return MIN_UNIT; }

    /* ---- Punctuation & Brackets ---- */
"{"             { return LBRACE; }
"}"             { return RBRACE; }
"["             { return LBRACKET; }
"]"             { return RBRACKET; }
";"             { return SEMICOLON; }
","             { return COMMA; }
"("             { return LPAREN; }
")"             { return RPAREN; }

    /* ---- Operators ---- */
"+="            { return PLUS_ASSIGN; }
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
[0-9]+"."[0-9]+ {
    yylval.double_val = atof(yytext);
    return FLOAT_LITERAL;
}

[0-9]+ {
    yylval.int_val = atoi(yytext);
    return INTEGER_LITERAL;
}

\"[^\"]*\" {
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

. {
    fprintf(stderr, "Lexical error (line %d): stray character '%c'\n", yylineno, *yytext);
    lex_errors++;
}

%%
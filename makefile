# Recipe language compiler - build file
#
#   make        build the compiler
#   make run    build and run it on the pasta example
#   make clean  remove all generated files

TARGET      = compiler
FLEX_SRC    = recipe.l
BISON_SRC   = parser.y
LEXER_C     = lex.yy.c
PARSER_C    = parser.tab.c
PARSER_H    = parser.tab.h

CC     = gcc
CFLAGS = -Wall -std=gnu99

all: $(TARGET)

# noyywrap is set in recipe.l, so libfl is not needed.
$(TARGET): $(LEXER_C) $(PARSER_C)
	$(CC) $(CFLAGS) -o $(TARGET) $(LEXER_C) $(PARSER_C)

# -d generates parser.tab.h; -v generates parser.output (state machine dump)
$(PARSER_C) $(PARSER_H): $(BISON_SRC)
	bison -d -v $(BISON_SRC)

$(LEXER_C): $(FLEX_SRC) $(PARSER_H)
	flex $(FLEX_SRC)

run: $(TARGET)
	./$(TARGET) pasta_with_tomatoe_souce.txt

clean:
	rm -f $(TARGET) $(LEXER_C) $(PARSER_C) $(PARSER_H) parser.output

.PHONY: all run clean

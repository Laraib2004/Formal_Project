# Define the name of the final executable
TARGET = compiler

# Define the source files
FLEX_SOURCE = recipe.l
BISON_SOURCE = parser.y

# Define the generated C files
LEXER_C = lex.yy.c
PARSER_C = parser.tab.c
PARSER_H = parser.tab.h

# Define compiler and flags
CC = gcc
CFLAGS = -Wall -std=c99

# The default target that builds the compiler
all: $(TARGET)

# Rule to link the object files and create the executable
$(TARGET): $(LEXER_C) $(PARSER_C)
	$(CC) $(CFLAGS) -o $(TARGET) $(LEXER_C) $(PARSER_C) -lfl

# Rule to generate the parser C and H files from the bison source
$(PARSER_C) $(PARSER_H): $(BISON_SOURCE)
	bison -d $(BISON_SOURCE)

# Rule to generate the lexer C file from the flex source
$(LEXER_C): $(FLEX_SOURCE)
	flex $(FLEX_SOURCE)

# Clean up generated files
clean:
	rm -f $(TARGET) $(LEXER_C) $(PARSER_C) $(PARSER_H)
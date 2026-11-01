# Recipe language compiler - build file
#
#   make        build the compiler
#   make run    build and run it on the pasta example
#   make test   build and check every example
#   make clean  remove all generated files
#
# Everything generated lands in build/, so the source tree stays clean.

SRC_DIR   = src
BUILD_DIR = build

TARGET    = $(BUILD_DIR)/compiler
FLEX_SRC  = $(SRC_DIR)/recipe.l
BISON_SRC = $(SRC_DIR)/parser.y
LEXER_C   = $(BUILD_DIR)/lex.yy.c
PARSER_C  = $(BUILD_DIR)/parser.tab.c
PARSER_H  = $(BUILD_DIR)/parser.tab.h

CC     = gcc
CFLAGS = -Wall -std=gnu99

all: $(TARGET)

# noyywrap is set in recipe.l, so libfl is not needed.
$(TARGET): $(LEXER_C) $(PARSER_C)
	$(CC) $(CFLAGS) -o $@ $(LEXER_C) $(PARSER_C)

# -d generates parser.tab.h; -v generates parser.output (state machine dump)
$(PARSER_C) $(PARSER_H): $(BISON_SRC) | $(BUILD_DIR)
	bison -d -v -o $(PARSER_C) $<

# lex.yy.c includes parser.tab.h, so bison must run first.
$(LEXER_C): $(FLEX_SRC) $(PARSER_H) | $(BUILD_DIR)
	flex -o $@ $<

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

run: $(TARGET)
	$(TARGET) examples/pasta_with_sauce.txt

test: $(TARGET)
	@sh tests/run_tests.sh

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run test clean

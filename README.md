# Recipe Language Compiler

A small compiler for **Recipe**, a domain-specific language that describes
cooking recipes as a sequence of steps and actions. Built with **flex**
(lexical analysis) and **bison** (parsing + semantic analysis).

## Build & run

```sh
make                              # build build/compiler
make run                          # build and run on the pasta example
make test                         # build and check every example
make clean                        # delete build/

./build/compiler <file.txt>       # compile one file
```

Needs `flex`, `bison` and `gcc`. Everything generated goes to `build/`.

## Layout

```
src/        recipe.l (lexer) and parser.y (grammar + semantic analysis)
docs/       language reference, implementation notes, assignment brief
examples/   runnable recipes
tests/      run_tests.sh and the test cases it checks
build/      generated; not committed
```

## Example programs

| File                            | What it shows                                  |
|---------------------------------|------------------------------------------------|
| `examples/pasta_with_sauce.txt` | A complete, valid recipe                       |
| `examples/pasta_extended.txt`   | Variables, `if` statements, comments           |
| `examples/loop_test.txt`        | `repeat` and `while` loops, nested scopes      |
| `examples/type_test.txt`        | Type checker: reports 4 type errors on purpose |
| `tests/arithmetic/`             | Operator precedence and constant folding       |
| `tests/scope/`                  | Scope rules: shadowing, redeclaration, lookup  |

`make test` runs all of them and checks each exit status. In `tests/` a filename
containing `fail` is expected to be rejected; every other file is expected to
compile.

## What the compiler does

1. **Lexical analysis** – tokens via regular expressions (`src/recipe.l`).
2. **Parsing** – an LALR grammar builds an Abstract Syntax Tree (`src/parser.y`).
3. **Semantic analysis** – a single walk over the AST performs:
   - a dynamic **symbol table** with **scopes** (recipe-wide and per-block),
   - **type checking** of expressions, assignments and conditions,
   - **constant value computation** for expressions,
   - detection of undeclared / unused tools, ingredients and variables.

Exit status is `0` on success and `1` on any lexical, syntax or semantic error.

## Documentation

- [`docs/DOCUMENTATION.md`](docs/DOCUMENTATION.md) — the language: syntax, types,
  statements, semantic rules, EBNF grammar.
- [`docs/INTERNALS.md`](docs/INTERNALS.md) — the implementation: AST, symbol
  table, scoping rules, type checking, error recovery.

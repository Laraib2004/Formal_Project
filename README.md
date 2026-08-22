# Recipe Language Compiler

A small compiler for **Recipe**, a domain-specific language that describes
cooking recipes as a sequence of steps and actions. Built with **flex**
(lexical analysis) and **bison** (parsing + semantic analysis).

## Build & run

```sh
make            # build the ./compiler executable
make run        # build and run on the pasta example
./compiler <file.txt>
```

`make clean` removes all generated files.

## Example programs

| File                             | What it shows                                   |
|----------------------------------|-------------------------------------------------|
| `pasta_with_tomatoe_souce.txt`   | A complete, valid recipe                         |
| `pasta_extended.txt`             | Variables, `if` statements, comments             |
| `loop_test.txt`                  | `repeat` and `while` loops, nested scopes        |
| `type_test.txt`                  | Type checker: reports 4 type errors on purpose   |

## What the compiler does

1. **Lexical analysis** – tokens via regular expressions (`recipe.l`).
2. **Parsing** – an LALR grammar builds an Abstract Syntax Tree (`parser.y`).
3. **Semantic analysis** – a single walk over the AST performs:
   - a dynamic **symbol table** with **scopes** (recipe-wide and per-block),
   - **type checking** of expressions, assignments and conditions,
   - **constant value computation** for expressions,
   - detection of undeclared / unused tools, ingredients and variables.

See `DOCUMENTATION.md` for the full language description and grammar.

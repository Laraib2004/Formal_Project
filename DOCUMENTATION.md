# The Recipe Language — Compiler Documentation

*Formal Languages and Compilers — Project*

---

## 1. What the compiler does

The **Recipe** language lets you describe a cooking recipe as an ordered list
of **steps**, each containing **actions** (get a tool, add an ingredient, cook,
boil, drain, mix, serve) as well as **variables**, **arithmetic**, **conditional
statements** and **loops**.

The compiler is a classic front end:

```
source text ──► [ lexer ] ──► tokens ──► [ parser ] ──► AST ──► [ analyser ] ──► report
                recipe.l                  parser.y              parser.y
```

1. **Lexical analysis** (`recipe.l`, flex): regular expressions turn the input
   text into tokens. Numbers and identifiers carry an attribute (their value).
2. **Syntax analysis** (`parser.y`, bison): an LALR(1) grammar recognises the
   structure and, as a *translation scheme*, builds an **Abstract Syntax Tree**
   (AST). The grammar actions do nothing but build the tree.
3. **Semantic analysis** (`parser.y`): a single recursive walk over the AST does
   all the semantic work exactly once — symbol table, scoping, type checking,
   value computation and unused/undeclared checks.

### Design note (no duplicated work)

Numbers are converted from text to a value **once**, by the lexer, and are stored
in the AST as real numeric fields (`ival`/`fval`) — they are never turned back
into strings. Every kind of action has its **own AST node kind**, so the analyser
decides what to do with a `switch` on the node kind; it never inspects a string
to rediscover what the parser already knew. All semantics live in one pass, not
scattered between parse-time actions and a second walk.

---

## 2. How to run it

```sh
make                       # builds ./compiler
./compiler <recipe.txt>    # compiles one file
make clean                 # removes generated files
```

The compiler prints the AST, a semantic-analysis trace, and a final verdict.
It exits with status `0` on success and `1` if there are syntax or semantic
errors.

---

## 3. Input format

A program is one or more recipes:

```
recipe <Name> {
    step <n> {
        <statement>;      // simple statements end with ';'
        ...
    }
    ...
}
```

* **Comments**: `// to end of line`.
* **Whitespace** is ignored.
* **Simple statements** end with `;`. **Block statements** (`if`, `while`,
  `repeat`) are terminated by their `}` and take **no** trailing `;`.

### Data types

The language has three value types, inferred from `set`:

| Type      | Example        |
|-----------|----------------|
| `integer` | `set n = 4;`   |
| `float`   | `set r = 3.5;` |
| `string`  | `set s = "x";` |

### Statements

| Statement | Syntax                                             | Meaning                        |
|-----------|----------------------------------------------------|--------------------------------|
| get       | `get <tool>;`                                      | obtain a tool                  |
| add       | `add <ingr> <qty> <unit> to <tool>;`               | add a measured ingredient      |
| add       | `add <ingr> to <tool>;`                            | add an ingredient (no measure) |
| cook      | `cook <ingr> in <tool> <n> min;`                   | cook for a time                |
| boil      | `boil <ingr> in <tool> <n> min;`                   | boil for a time                |
| drain     | `drain <ingr> <tool>;`                             | drain using a tool             |
| mix       | `mix <tool>;`                                      | mix contents of a tool         |
| return    | `return <item>;`                                   | return an intermediate result  |
| serve     | `serve <dish>;`                                    | serve the finished dish        |
| set       | `set <var> = <expression>;`                        | assign a variable              |
| if        | `if (<condition>) { ... }`                         | conditional                    |
| while     | `while (<condition>) { ... }`                      | conditional loop               |
| repeat    | `repeat <n> times { ... }`                         | counted loop                   |

**Units**: `g` (grams), `L` (litres), `p` (pieces); time is in `min`.

**Expressions**: `+ - * /` over integers/floats and variables, with `( )` and the
usual precedence.

**Conditions**: `==  !=  >  <` between expressions, combined with `&&`.

---

## 4. Semantic rules enforced

* **Symbol table (dynamic, with scopes).** Implemented as a linked list of
  scopes forming a stack.
  * Tools and ingredients live in the **recipe scope**, so they are visible in
    every step.
  * Variables live in the **current scope**; `if`/`while`/`repeat` bodies open a
    **nested scope**, so a variable declared inside a block is not visible
    outside it.
* **Declaration before use.** Using a tool/ingredient that was never obtained
  (`get`) or added (`add`), or a variable that was never `set`, is an error.
* **Type checking.** Arithmetic is rejected on strings; comparisons between
  incompatible types (e.g. a string and an integer) are reported. `integer` and
  `float` mix freely (the result is `float`).
* **Value computation.** Constant expressions are folded to a value
  (`set per_person = 100 / 4` reports `= 25`); division by zero is reported.
* **Loop counts** must be positive integers.
* **Warnings** for tools/ingredients prepared but never used, variables set but
  never used, zero quantities, and re-obtaining a tool.

Errors are **collected, not fatal**: the compiler reports every problem it finds
instead of stopping at the first one.

---

## 5. Grammar (EBNF summary)

```
program      → recipe+
recipe       → 'recipe' IDENT '{' step+ '}'
step         → 'step' INT '{' statement* '}'

statement    → simple_stmt ';'
             | if_stmt | while_stmt | repeat_stmt

simple_stmt  → get | add | cook | boil | drain | mix | serve | return | assignment
get          → 'get' IDENT
add          → 'add' IDENT number unit 'to' IDENT
             | 'add' IDENT 'to' IDENT
cook         → 'cook' IDENT 'in' IDENT number 'min'
boil         → 'boil' IDENT 'in' IDENT number 'min'
drain        → 'drain' IDENT IDENT
mix          → 'mix' IDENT
serve        → 'serve' IDENT
return       → 'return' IDENT
assignment   → 'set' IDENT '=' expression

if_stmt      → 'if' '(' condition ')' block
while_stmt   → 'while' '(' condition ')' block
repeat_stmt  → 'repeat' (INT | IDENT) 'times' block
block        → '{' statement* '}'

condition    → expression relop expression
             | condition '&&' condition
             | '(' condition ')'
relop        → '==' | '!=' | '>' | '<'

expression   → expression ('+'|'-') term | term
term         → term ('*'|'/') factor | factor
factor       → INT | FLOAT | IDENT | STRING | '(' expression ')'

number       → INT | FLOAT
unit         → 'g' | 'L' | 'p'
```

The full token definitions are in `recipe.l`; the full grammar with semantic
actions is in `parser.y`.

---

## 6. Example — input and output

**Input** (`pasta_with_tomatoe_souce.txt`): a valid recipe. The compiler prints
the AST, then the semantic trace, and finishes with:

```
COMPILATION SUCCESSFUL: no semantic or type errors found.
```

**Input** (`type_test.txt`): deliberately compares strings with integers. The
compiler reports each type error with its line number and finishes with:

```
SEMANTIC ERROR (line 9):  cannot compare string with integer
SEMANTIC ERROR (line 17): cannot compare integer with string
SEMANTIC ERROR (line 27): cannot compare string with integer
SEMANTIC ERROR (line 31): cannot compare integer with string
COMPILATION FAILED: 4 semantic/type error(s).
```

---

## 7. Files

| File                           | Purpose                                    |
|--------------------------------|--------------------------------------------|
| `recipe.l`                     | Lexer (flex): tokens and attributes        |
| `parser.y`                     | Grammar, AST, symbol table, semantics      |
| `makefile`                     | Build rules                                |
| `*.txt`                        | Example programs                           |
| `README.md`                    | Quick start                                |
| `DOCUMENTATION.md`             | This document                              |

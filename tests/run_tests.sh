#!/bin/sh
# Compiles every example and compares the exit status with what the file is
# supposed to do. Inside tests/ the convention is the filename: anything
# containing "fail" must be rejected, everything else must compile.
#
# Run it from anywhere - it works relative to the project root.

cd "$(dirname "$0")/.." || exit 1

compiler=./build/compiler
passed=0
failed=0

if [ ! -x "$compiler" ]; then
    echo "$compiler not built - run 'make' first" >&2
    exit 1
fi

run() {
    expected=$1
    file=$2

    "$compiler" "$file" >/dev/null 2>&1
    got=$?

    if [ "$got" -eq "$expected" ]; then
        printf 'ok    %s\n' "$file"
        passed=$((passed + 1))
    else
        printf 'FAIL  %s  (expected exit %d, got %d)\n' "$file" "$expected" "$got"
        failed=$((failed + 1))
    fi
}

run 0 examples/pasta_with_sauce.txt
run 0 examples/pasta_extended.txt
run 0 examples/loop_test.txt
run 1 examples/type_test.txt          # deliberate type errors

for f in tests/arithmetic/*.txt tests/scope/*.txt; do
    case $f in
        *fail*) run 1 "$f" ;;
        *)      run 0 "$f" ;;
    esac
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

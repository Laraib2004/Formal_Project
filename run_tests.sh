#!/bin/sh
# Compiles every example and compares the exit status with what the file is
# supposed to do. Inside the test directories the convention is the filename:
# anything containing "fail" must be rejected, everything else must compile.

compiler=./compiler
passed=0
failed=0

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

run 0 pasta_with_tomatoe_souce.txt
run 0 pasta_extended.txt
run 0 loop_test.txt
run 1 type_test.txt          # deliberate type errors

for f in test_for_arithmetic/*.txt test_for_scope/*.txt; do
    case $f in
        *fail*) run 1 "$f" ;;
        *)      run 0 "$f" ;;
    esac
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

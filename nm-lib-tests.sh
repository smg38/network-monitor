#!/bin/bash
# nm-lib-tests.sh - Unit-тесты для библиотеки nm-lib.sh
# Версия: 1.7.0
# Автор: TG: @smg38 smg38@yandex.ru
# Использование: ./nm-lib-tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nm-lib.sh"

# Счетчики тестов
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Цвета (если не загружены)
if [ -z "${GREEN:-}" ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
fi

# Функция assert
assert_equals() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Ожидалось: '$expected'"
        echo "  Получено:  '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Assert для числовых сравнений
assert_numeric() {
    local expected="$1"
    local actual="$2"
    local tolerance="$3"
    local test_name="$4"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    local diff=$((expected - actual))
    [ $diff -lt 0 ] && diff=$((-diff))
    
    if [ $diff -le $tolerance ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Ожидалось: ~$expected (±$tolerance)"
        echo "  Получено:  $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Assert для проверки соответствия шаблону
assert_match() {
    local pattern="$1"
    local value="$2"
    local test_name="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [[ "$value" =~ $pattern ]]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Шаблон: $pattern"
        echo "  Значение: $value"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

echo "=============================================="
echo "ТЕСТЫ БИБЛИОТЕКИ NM-LIB.SH"
echo "=============================================="
echo

# ========================================
# ТЕСТЫ FORMAT_BYTES
# ========================================
echo "--- Тесты format_bytes ---"

assert_equals "0 B" "$(format_bytes 0)" "format_bytes: 0 байт"
assert_equals "512 B" "$(format_bytes 512)" "format_bytes: 512 байт"
assert_equals "1023 B" "$(format_bytes 1023)" "format_bytes: 1023 байта (граница KB)"
assert_equals "1.00 KB" "$(format_bytes 1024)" "format_bytes: 1 KB"
assert_equals "5.50 KB" "$(format_bytes 5632)" "format_bytes: 5.5 KB"
assert_equals "1023.99 KB" "$(format_bytes 1048575)" "format_bytes: граница MB"
assert_equals "1.00 MB" "$(format_bytes 1048576)" "format_bytes: 1 MB"
assert_equals "2.50 MB" "$(format_bytes 2621440)" "format_bytes: 2.5 MB"
assert_equals "1.00 GB" "$(format_bytes 1073741824)" "format_bytes: 1 GB"
assert_equals "1.50 GB" "$(format_bytes 1610612736)" "format_bytes: 1.5 GB"
assert_equals "1.00 TB" "$(format_bytes 1099511627776)" "format_bytes: 1 TB"

# Проверка отрицательных значений
assert_equals "0 B" "$(format_bytes -100)" "format_bytes: отрицательное значение"

# Проверка пустого значения
assert_equals "0 B" "$(format_bytes "")" "format_bytes: пустое значение"

echo

# ========================================
# ТЕСТЫ FORMAT_SPEED
# ========================================
echo "--- Тесты format_speed ---"

result=$(format_speed 1024)
assert_match ".*KB/s$" "$result" "format_speed: KB/s суффикс"

result=$(format_speed 1048576)
assert_match ".*MB/s$" "$result" "format_speed: MB/s суффикс"

result=$(format_speed 1073741824)
assert_match ".*GB/s$" "$result" "format_speed: GB/s суффикс"

echo

# ========================================
# ТЕСТЫ PARSE_FIELD
# ========================================
echo "--- Тесты parse_field ---"

assert_equals "apple" "$(parse_field "apple|banana|cherry" "|" 1)" "parse_field: первое поле"
assert_equals "banana" "$(parse_field "apple|banana|cherry" "|" 2)" "parse_field: второе поле"
assert_equals "cherry" "$(parse_field "apple|banana|cherry" "|" 3)" "parse_field: третье поле"
assert_equals "" "$(parse_field "apple|banana|cherry" "|" 5)" "parse_field: несуществующее поле"
assert_equals "hello" "$(parse_field "hello" "|" 1)" "parse_field: одно поле"

# Разделитель запятая
assert_equals "one" "$(parse_field "one,two,three" "," 1)" "parse_field: запятая разделитель"
assert_equals "two" "$(parse_field "one,two,three" "," 2)" "parse_field: запятая второе поле"

echo

# ========================================
# ТЕСТЫ DRAW_BAR
# ========================================
echo "--- Тесты draw_bar ---"

result=$(draw_bar 0)
if [[ "$result" == *"0%"* ]]; then
    assert_equals "true" "true" "draw_bar: 0% содержит процент"
else
    assert_equals "true" "false" "draw_bar: 0% содержит процент"
fi

result=$(draw_bar 50)
if [[ "$result" == *"50%"* ]] && [[ "$result" == *"["* ]]; then
    assert_equals "true" "true" "draw_bar: 50% корректный формат"
else
    assert_equals "true" "false" "draw_bar: 50% корректный формат"
fi

result=$(draw_bar 100)
if [[ "$result" == *"100%"* ]]; then
    assert_equals "true" "true" "draw_bar: 100% содержит процент"
else
    assert_equals "true" "false" "draw_bar: 100% содержит процент"
fi

# Граничные значения
result=$(draw_bar -10)
if [[ "$result" == *"0%"* ]]; then
    assert_equals "true" "true" "draw_bar: отрицательный процент (обрезка)"
else
    assert_equals "true" "false" "draw_bar: отрицательный процент (обрезка)"
fi

result=$(draw_bar 150)
if [[ "$result" == *"100%"* ]]; then
    assert_equals "true" "true" "draw_bar: >100% (обрезка)"
else
    assert_equals "true" "false" "draw_bar: >100% (обрезка)"
fi

echo
echo "--- Тесты валидации ---"

# validate_interface_name
if validate_interface_name "eth0"; then
    assert_equals "true" "true" "validate_interface_name: eth0 валидно"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "true" "false" "validate_interface_name: eth0 валидно"
fi

if validate_interface_name "wg0"; then
    assert_equals "true" "true" "validate_interface_name: wg0 валидно"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "true" "false" "validate_interface_name: wg0 валидно"
fi

if ! validate_interface_name "eth 0"; then
    assert_equals "false" "false" "validate_interface_name: пробел невалиден"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "false" "true" "validate_interface_name: пробел невалиден"
fi

# validate_ip_address
if validate_ip_address "192.168.1.1"; then
    assert_equals "true" "true" "validate_ip_address: 192.168.1.1 валидно"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "true" "false" "validate_ip_address: 192.168.1.1 валидно"
fi

if validate_ip_address "10.0.0.1"; then
    assert_equals "true" "true" "validate_ip_address: 10.0.0.1 валидно"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "true" "false" "validate_ip_address: 10.0.0.1 валидно"
fi

if ! validate_ip_address "256.1.1.1"; then
    assert_equals "false" "false" "validate_ip_address: 256.x.x.x невалидно"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "false" "true" "validate_ip_address: 256.x.x.x невалидно"
fi

if ! validate_ip_address "invalid"; then
    assert_equals "false" "false" "validate_ip_address: строка невалидна"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "false" "true" "validate_ip_address: строка невалидна"
fi

# validate_date
if validate_date "2024-01-15"; then
    assert_equals "true" "true" "validate_date: 2024-01-15 валидно"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "true" "false" "validate_date: 2024-01-15 валидно"
fi

if ! validate_date "invalid-date"; then
    assert_equals "false" "false" "validate_date: невалидная дата"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "false" "true" "validate_date: невалидная дата"
fi

echo

# ========================================
# ТЕСТЫ ARRAY FUNCTIONS
# ========================================
echo "--- Тесты массивов ---"

# array_contains
test_array=("apple" "banana" "cherry")
if array_contains "banana" "${test_array[@]}"; then
    assert_equals "true" "true" "array_contains: элемент найден"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "true" "false" "array_contains: элемент найден"
fi

if ! array_contains "grape" "${test_array[@]}"; then
    assert_equals "false" "false" "array_contains: элемент не найден"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    assert_equals "false" "true" "array_contains: элемент не найден"
fi

# join_array
result=$(join_array "," "a" "b" "c")
assert_equals "a,b,c" "$result" "join_array: объединение через запятую"

result=$(join_array "-" "one" "two")
assert_equals "one-two" "$result" "join_array: объединение через дефис"

echo

# ========================================
# ТЕСТЫ TIME FUNCTIONS
# ========================================
echo "--- Тесты времени ---"

timestamp=$(get_timestamp)
assert_numeric "$(date +%s)" "$timestamp" 1 "get_timestamp: текущее время"

datetime=$(get_datetime)
assert_match "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$" "$datetime" "get_datetime: формат YYYY-MM-DD HH:MM:SS"

start=$(get_timestamp)
sleep 1
end=$(get_timestamp)
diff=$(time_diff "$start" "$end")
assert_numeric 1 "$diff" 1 "time_diff: разница во времени"

echo

# ========================================
# ТЕСТЫ COMMAND CACHE
# ========================================
echo "--- Тесты кэша команд ---"

# Очищаем кэш
COMMAND_CACHE=()

if check_command_cached "bash"; then
    assert_equals "0" "${COMMAND_CACHE[bash]:-1}" "check_command_cached: bash найден"
else
    assert_equals "0" "1" "check_command_cached: bash найден"
fi

# Проверяем что кэш работает
cached_result="${COMMAND_CACHE[bash]:-not_cached}"
assert_equals "0" "$cached_result" "check_command_cached: результат закэширован"

echo

# ========================================
# ТЕСТЫ LOGGING (визуальная проверка)
# ========================================
echo "--- Тесты логирования ---"
echo "(Визуальная проверка формата логов)"

LOG_LEVEL="DEBUG"
log "DEBUG" "Тестовое DEBUG сообщение"
log "INFO" "Тестовое INFO сообщение"
log "WARN" "Тестовое WARN сообщение"
log "ERROR" "Тестовое ERROR сообщение"

echo

# ========================================
# ИТОГИ
# ========================================
echo "=============================================="
echo "ИТОГИ ТЕСТИРОВАНИЯ"
echo "=============================================="
echo -e "Всего тестов: ${TESTS_RUN}"
echo -e "${GREEN}Пройдено: ${TESTS_PASSED}${NC}"
echo -e "${RED}Провалено: ${TESTS_FAILED}${NC}"
echo

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}Все тесты пройдены!${NC}"
    exit 0
else
    echo -e "${RED}Некоторые тесты провалены!${NC}"
    exit 1
fi

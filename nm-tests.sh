#!/bin/bash
# nm-tests.sh - Юнит-тесты Network Monitor
# Версия: 1.4
# Автор: TG: @smg38 smg38@yandex.ru

set -euo pipefail

# Загружаем конфигурацию
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/nm-config.sh" 2>/dev/null || { echo "❌ nm-config.sh не найден"; exit 1; }

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Счетчики
PASSED=0
FAILED=0
TOTAL=0

# Тест: выполнение команды
run_test() {
    local name="$1"
    local cmd="$2"
    ((TOTAL++))
    
    echo -n "🧪 $name ... "
    if eval "$cmd" 2>/dev/null; then
        echo "${GREEN}✓${NC}"
        ((PASSED++))
    else
        echo "${RED}✗${NC}"
        ((FAILED++))
    fi
}

# Тест 1: Проверка структуры директорий
test_directories() {
    run_test "Директории созданы" "[ -d \"\$BASE_DIR\" ] && [ -d \"\$LOG_DIR\" ]"
    run_test "Права BASE_DIR" "[ -r \"\$BASE_DIR\" ] && [ -x \"\$BASE_DIR\" ]"
}

# Тест 2: Валидация конфигурации
test_config() {
    run_test "Конфиг загружен" "declare -p COLLECT_RULES AGGREGATE_RULES CLEANUP_RULES >/dev/null 2>&1"
    run_test "Интерфейсы заданы" "[[ -n \"\$MAIN_IFACE\" || -n \"\$WG_IFACE\" ]]"
    run_test "Правила сбора" "[ \${#COLLECT_RULES[@]} -gt 0 ]"
    run_test "Правила агрегации" "[ \${#AGGREGATE_RULES[@]} -gt 0 ]"
}

# Тест 3: Проверка БД
test_database() {
    if [ ! -f "$DB_PATH" ]; then
        echo -e "${YELLOW}⚠ БД не создана (нормально до установки)${NC}"
        return
    fi
    
    run_test "БД существует" "[ -f \"\$DB_PATH\" ] && [ -r \"\$DB_PATH\" ]"
    run_test "Таблицы созданы" "sqlite3 \$DB_PATH \".tables\" | grep -q interfaces_stats"
    run_test "Индексы" "sqlite3 \$DB_PATH \"SELECT count(*) FROM sqlite_master WHERE type='index';\" | grep -q '[1-9]'"
    
    # Проверка views
    run_test "Views созданы" "sqlite3 \$DB_PATH \".tables\" | grep -q v_interface_daily"
}

# Тест 4: Проверка скриптов
test_scripts() {
    run_test "nm-daemon.sh исполняемый" "[ -x \"\$BASE_DIR/nm-daemon.sh\" ]"
    run_test "nm-monitor.sh исполняемый" "[ -x \"\$BASE_DIR/nm-monitor.sh\" ]"
    run_test "nm-config.sh в BASE_DIR" "[ -f \"\$BASE_DIR/nm-config.sh\" ]"
}

# Тест 5: Systemd сервис
test_systemd() {
    run_test "Сервис файл" "[ -f /etc/systemd/system/nm-daemon.service ]"
    run_test "Сервис синтаксис" "systemd-analyze verify /etc/systemd/system/nm-daemon.service"
}

# Тест 6: Функциональность nm-monitor.sh (если БД есть)
test_monitor() {
    if [ ! -f "$DB_PATH" ]; then return; fi
    
    run_test "--help работает" "\$BASE_DIR/nm-monitor.sh --help >/dev/null 2>&1"
    run_test "--status работает" "\$BASE_DIR/nm-monitor.sh --status >/dev/null 2>&1"
}

# Тест 7: Валидация путей
test_paths() {
    run_test "BASE_DIR корректен" "[[ \"\$BASE_DIR\" == /opt/network-monitor* ]]"
    run_test "DB_PATH корректен" "[[ \"\$DB_PATH\" == \$BASE_DIR/nm-data.db ]]"
    run_test "LOG_FILE корректен" "[[ \"\$LOG_FILE\" == /var/log/network-monitor/* ]]"
}

# Главная функция
main() {
    echo "${GREEN}🚀 Network Monitor v1.3 - Юнит-тесты${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    
    test_directories
    test_config
    test_database
    test_scripts
    test_systemd
    test_monitor
    test_paths
    
    echo "═══════════════════════════════════════════════════════════════"
    echo "${GREEN}📊 ИТОГО: ${PASSED}/${TOTAL} тестов пройдено${NC}"
    
    if [ $FAILED -eq 0 ]; then
        echo "${GREEN}🎉 Все тесты GREEN!${NC}"
        exit 0
    else
        echo "${RED}❌ Не пройдено: ${FAILED} тестов${NC}"
        exit 1
    fi
}

main "$@"

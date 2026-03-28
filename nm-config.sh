#!/bin/bash
# nm-config.sh - Основной bash-конфиг для разработки/установки (Версия 1.7.1)
# Используется: source в nm-install.sh, nm-tests.sh
# Правила динамически загружаются из БД config_rules (nm-config-rules.sql)
# nm-config.env = копия только простых переменных для systemd
# ✅ ИСПРАВЛЕНО: Добавлена setup_colors() + защита от отсутствия БД (2026-03-27)
# ✅ v1.7.1: Удалена дублирующая setup_colors(), используется nm-lib.sh

set -euo pipefail

# ========================================
# ОСНОВНЫЕ ПЕРЕМЕННЫЕ (идентичны nm-config.env)
# ========================================
export MAIN_IFACE=ens3                    # Основной интерфейс
export WG_IFACE=wg0                       # WireGuard интерфейс
export BASE_DIR=/opt/network-monitor
export DB_PATH=${BASE_DIR}/nm-data.db
export CONFIG_PATH=${BASE_DIR}/nm-config.env
export LOG_DIR=/var/log/network-monitor
export LOG_FILE=${LOG_DIR}/nm-daemon.log
export CHECK_INTERVAL=10
export LOG_LEVEL=INFO
export LOG_MAX_SIZE=100
export LOG_MAX_FILES=5
export TOP_PEERS_DEFAULT=10
export LIVE_REFRESH_INTERVAL=2

# ========================================
# ФУНКЦИИ ЗАГРУЗКИ ПРАВИЛ ИЗ БД (ЗАЩИЩЕНЫ)
# ========================================
declare -A COLLECT_RULES=()
declare -A AGGREGATE_RULES=()
declare -A CLEANUP_RULES=()

# ✅ ИСПРАВЛЕНО: Проверка доступности БД
# check_db_ready() {
#     [ -f "$DB_PATH" ] && sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='config_rules';" >/dev/null 2>&1
# }

check_db_ready() {
    [ -f "$DB_PATH" ] || return 1
    sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='config_rules';" | grep -q 1
}

# ✅ ИСПРАВЛЕНО: Защита от отсутствия БД при --remove
load_config_rules() {
    local source_type="${1:-db}"  # db|sql
    
    if [ "$source_type" = "sql" ] && [ -f "${SCRIPT_DIR}/nm-config-rules.sql" ]; then
        echo "📥 Загрузка правил из nm-config-rules.sql в БД..."
        [ -f "$DB_PATH" ] && sqlite3 "$DB_PATH" < "${SCRIPT_DIR}/nm-config-rules.sql"
    fi
    
    if ! check_db_ready; then
        echo "⚠️  БД недоступна (--remove?), пропускаем загрузку правил из config_rules"
        return 0
    fi
    
    echo "📥 Загрузка активных правил из БД config_rules..."
    
    # Очищаем массивы (но не объявляем заново, чтобы сохранить глобальную область)
    COLLECT_RULES=()
    AGGREGATE_RULES=()
    CLEANUP_RULES=()
    
    # Загружаем правила сбора - формат: rule_key -> "description|interval"
    while IFS='|' read -r rule_key description interval; do
        [[ -z "$rule_key" ]] && continue
        [ -n "$rule_key" ] && COLLECT_RULES["$rule_key"]="${description}|${interval}"
    done < <(sqlite3 "$DB_PATH" "SELECT rule_key, description, interval_sec FROM config_rules WHERE rule_type='collect' AND enabled=1 ORDER BY interval_sec;")
    
    # Загружаем правила агрегации - формат: rule_key -> "description|window|interval"
    while IFS='|' read -r rule_key description window interval; do
        [ -n "$rule_key" ] && AGGREGATE_RULES["$rule_key"]="${description}|${window}|${interval}"
    done < <(sqlite3 "$DB_PATH" "SELECT rule_key, description, window_sec, interval_sec FROM config_rules WHERE rule_type='aggregate' AND enabled=1 ORDER BY interval_sec;")
    
    # Загружаем правила очистки - формат: data_type -> retention_days
    while IFS='|' read -r data_type retention; do
        [ -n "$data_type" ] && CLEANUP_RULES["$data_type"]="$retention"
    done < <(sqlite3 "$DB_PATH" "SELECT rule_key, retention_days FROM config_rules WHERE rule_type='cleanup' AND enabled=1;")
    
    echo "✅ Загружено правил: collect=${#COLLECT_RULES[@]}, aggregate=${#AGGREGATE_RULES[@]}, cleanup=${#CLEANUP_RULES[@]}"
}

# Автозагрузка правил при source (если БД готова)
# ЗАПРЕЩЕНО: автоматическая загрузка отключена для предотвращения конфликтов
# Вызывайте load_config_rules явно в основном скрипте
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# if check_db_ready; then
#     load_config_rules
# else
#     echo "ℹ БД недоступна, правила будут загружены при установке"
# fi

# ========================================
# УТИЛИТЫ ДЛЯ ОТЛАДКИ (bash only)
# ========================================
config_debug() {
    echo "=== Network Monitor Config Debug (${VERSION:-1.6.1}) ==="
    echo "MAIN_IFACE: $MAIN_IFACE"
    echo "WG_IFACE: $WG_IFACE"
    echo "DB_PATH: $DB_PATH"
    echo "DB_READY: $(check_db_ready && echo 'YES' || echo 'NO')"
    echo ""
    echo "=== Collect Rules ==="
    for key in "${!COLLECT_RULES[@]}"; do echo "  $key → ${COLLECT_RULES[$key]}"; done
    echo ""
    echo "=== Aggregate Rules ==="  
    for key in "${!AGGREGATE_RULES[@]}"; do echo "  $key → ${AGGREGATE_RULES[$key]}"; done
    echo ""
    echo "=== Cleanup Rules ==="
    for key in "${!CLEANUP_RULES[@]}"; do echo "  $key → ${CLEANUP_RULES[$key]} дней"; done
}

# Пример использования:
# source nm-config.sh
# config_debug
# load_config_rules sql    # перезагрузка из SQL-дампа


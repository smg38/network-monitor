#!/bin/bash
# nm-daemon.sh - Демон сбора и агрегации данных сетевого мониторинга
# Версия: 1.7.2
# Автор: TG: @smg38 smg38@yandex.ru
# Запускается как systemd сервис

set -euo pipefail  # Строгий режим

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Подключаем общую библиотеку с функциями
if [ -f "${SCRIPT_DIR}/nm-lib.sh" ]; then
    source "${SCRIPT_DIR}/nm-lib.sh"
else
    echo "❌ CRITICAL: nm-lib.sh не найден в ${SCRIPT_DIR}"
    exit 1
fi

# Загружаем базовый конфиг (переменные, но НЕ правила)
source "${SCRIPT_DIR}/nm-config.sh"

# Объявляем массивы для правил
declare -A COLLECT_RULES=()
declare -A AGGREGATE_RULES=()
declare -A CLEANUP_RULES=()

# Явно загружаем правила из БД
load_config_rules db

# Валидация
if [ ${#COLLECT_RULES[@]} -eq 0 ]; then
    log "ERROR" "CRITICAL: COLLECT_RULES пуст → демон не может работать"
    exit 1
fi

collect_count=${#COLLECT_RULES[@]}
aggregate_count=${#AGGREGATE_RULES[@]}
log "INFO" "Демон v1.7.2: config_rules загружены ($collect_count collect, $aggregate_count aggregate)"

# Функция для получения последнего запуска задачи из БД
get_last_run() {
    local task_key="$1"
    local result
    
    result=$(sqlite_safe "$DB_PATH" "SELECT last_run FROM task_schedule WHERE task_key='${task_key}';") || return 1
    
    if [ -n "$result" ]; then
        echo "$result"
    else
        echo "0"
    fi
}

# Обновление времени последнего запуска
update_last_run() {
    local task_key="$1"
    local timestamp
    timestamp=$(get_timestamp)
    
    sqlite_safe "$DB_PATH" "INSERT OR REPLACE INTO task_schedule (task_key, last_run) VALUES ('${task_key}', ${timestamp});" || return 1
}

# Проверка необходимости запуска задачи
should_run_task() {
    local task_key="$1"
    local interval="$2"
    local last_run current_time elapsed
    
    last_run=$(get_last_run "$task_key") || last_run=0
    current_time=$(get_timestamp)
    elapsed=$((current_time - last_run))
    
    [ "$elapsed" -ge "$interval" ]
}

# Сбор данных по правилам collect
do_collect() {
    local rule_key="$1"
    local desc_interval="$2"
    
    local description interval
    description=$(echo "$desc_interval" | cut -d'|' -f1)
    interval=$(echo "$desc_interval" | cut -d'|' -f2)
    
    log "INFO" "Выполнение сбора данных: $rule_key ($description)"
    
    case "$rule_key" in
        5|60)
            collect_interface_stats "$rule_key"
            ;;
        *)
            log "WARN" "Неизвестный тип правила сбора: $rule_key"
            return 1
            ;;
    esac
    
    update_last_run "$rule_key"
}

# Сбор статистики интерфейса
collect_interface_stats() {
    local rule_key="$1"
    local iface="${MAIN_IFACE}"
    local timestamp rx_bytes tx_bytes rx_packets tx_packets
    
    timestamp=$(get_timestamp)
    
    # Чтение статистики из /proc/net/dev (bash only)
    while IFS=: read -r name stats; do
        [[ "$name" != *"$iface"* ]] && continue
        
        # Разбор полей через read вместо awk
        read -ra fields <<< "$stats"
        rx_bytes="${fields[0]}"
        rx_packets="${fields[1]}"
        tx_bytes="${fields[8]}"
        tx_packets="${fields[9]}"
        
        # Сохранение в БД
        sqlite_safe "$DB_PATH" "INSERT INTO interface_stats (timestamp, iface, rx_bytes, tx_bytes, rx_packets, tx_packets) VALUES (${timestamp}, '${iface}', ${rx_bytes}, ${tx_bytes}, ${rx_packets}, ${tx_packets});" || return 1
        
        log "DEBUG" "Собрана статистика интерфейса ${iface}: rx=${rx_bytes}, tx=${tx_bytes}"
        break
    done < /proc/net/dev
}

# Сбор статистики WireGuard
collect_wg_stats() {
    local rule_key="$1"
    local iface="${WG_IFACE}"
    local timestamp peer_pubkey rx_bytes tx_bytes last_handshake
    
    [ -z "$iface" ] && return 0
    
    timestamp=$(get_timestamp)
    
    # Получение списка пиров через wg show (без awk)
    local current_peer=""
    while IFS= read -r line; do
        # Парсинг вывода wg show
        if [[ "$line" =~ ^peer:[[:space:]]*(.+)$ ]]; then
            current_peer="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ transfer:[[:space:]]*([0-9]+)[[:space:]]+([0-9]+) ]]; then
            rx_bytes="${BASH_REMATCH[1]}"
            tx_bytes="${BASH_REMATCH[2]}"
            
            # Сохранение в БД
            sqlite_safe "$DB_PATH" "INSERT INTO wg_peers_stats (timestamp, iface, peer_pubkey, rx_bytes, tx_bytes) VALUES (${timestamp}, '${iface}', '${current_peer}', ${rx_bytes}, ${tx_bytes});" || return 1
            
            log "DEBUG" "Собрана статистика WG пира ${current_peer}: rx=${rx_bytes}, tx=${tx_bytes}"
        elif [[ "$line" =~ latest[[:space:]]+handshake:[[:space:]]+(.+)$ ]]; then
            last_handshake="${BASH_REMATCH[1]}"
        fi
    done < <(wg show "$iface" 2>/dev/null || true)
}

# Агрегация данных
do_aggregate() {
    local rule_key="$1"
    local desc_window_interval="$2"
    
    local description window interval
    description=$(echo "$desc_window_interval" | cut -d'|' -f1)
    window=$(echo "$desc_window_interval" | cut -d'|' -f2)
    interval=$(echo "$desc_window_interval" | cut -d'|' -f3)
    
    log "INFO" "Выполнение агрегации: $rule_key (окно=${window}s, интервал=${interval}s)"
    
    # Определяем тип агрегации по ключу правила
    case "$rule_key" in
        agg_5min*|agg_hour*)
            aggregate_interface_data "$window"
            ;;
        raw:*)
            aggregate_wg_data "$window"
            ;;
        *)
            log "WARN" "Неизвестный тип агрегации: $rule_key"
            return 1
            ;;
    esac
    
    update_last_run "$rule_key"
}

# Агрегация данных интерфейса
aggregate_interface_data() {
    local window="${1:-300}"
    local current_ts start_ts
    
    current_ts=$(get_timestamp)
    start_ts=$((current_ts - window))
    
    # Агрегация через SQL (AVG, SUM, MIN, MAX)
    sqlite_safe "$DB_PATH" "
        INSERT INTO interface_stats_agg (timestamp, iface, avg_rx_bytes, avg_tx_bytes, sum_rx_bytes, sum_tx_bytes, min_rx_bytes, max_rx_bytes)
        SELECT 
            ${current_ts},
            iface,
            AVG(rx_bytes),
            AVG(tx_bytes),
            SUM(rx_bytes),
            SUM(tx_bytes),
            MIN(rx_bytes),
            MAX(rx_bytes)
        FROM interface_stats 
        WHERE timestamp >= ${start_ts} AND timestamp <= ${current_ts}
        GROUP BY iface;
    " || return 1
    
    log "DEBUG" "Агрегация данных интерфейса завершена (окно=${window}s)"
}

# Агрегация данных WireGuard
aggregate_wg_data() {
    local window="${1:-300}"
    local current_ts start_ts
    
    current_ts=$(get_timestamp)
    start_ts=$((current_ts - window))
    
    sqlite_safe "$DB_PATH" "
        INSERT INTO wg_peers_stats_agg (timestamp, iface, peer_pubkey, avg_rx_bytes, avg_tx_bytes, sum_rx_bytes, sum_tx_bytes)
        SELECT 
            ${current_ts},
            iface,
            peer_pubkey,
            AVG(rx_bytes),
            AVG(tx_bytes),
            SUM(rx_bytes),
            SUM(tx_bytes)
        FROM wg_peers_stats 
        WHERE timestamp >= ${start_ts} AND timestamp <= ${current_ts}
        GROUP BY iface, peer_pubkey;
    " || return 1
    
    log "DEBUG" "Агрегация данных WireGuard завершена (окно=${window}s)"
}

# Очистка старых данных
do_cleanup() {
    local data_type="$1"
    local retention_days="$2"
    local cutoff_ts current_ts
    
    current_ts=$(get_timestamp)
    cutoff_ts=$((current_ts - (retention_days * 86400)))
    
    log "INFO" "Очистка данных типа '$data_type' старше ${retention_days} дней"
    
    case "$data_type" in
        raw)
            sqlite_safe "$DB_PATH" "DELETE FROM interface_stats WHERE timestamp < ${cutoff_ts};" || return 1
            sqlite_safe "$DB_PATH" "DELETE FROM wg_peers_stats WHERE timestamp < ${cutoff_ts};" || return 1
            ;;
        agg)
            sqlite_safe "$DB_PATH" "DELETE FROM interface_stats_agg WHERE timestamp < ${cutoff_ts};" || return 1
            sqlite_safe "$DB_PATH" "DELETE FROM wg_peers_stats_agg WHERE timestamp < ${cutoff_ts};" || return 1
            ;;
        *)
            log "WARN" "Неизвестный тип данных для очистки: $data_type"
            return 1
            ;;
    esac
    
    log "DEBUG" "Очистка завершена, удалены данные старше $(date -d "@${cutoff_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')"
}

# Основной цикл демона
main_loop() {
    log "INFO" "Демон мониторинга сети запущен"
    log "INFO" "Основной интерфейс: ${MAIN_IFACE}"
    log "INFO" "WireGuard интерфейс: ${WG_IFACE:-не настроен}"
    log "INFO" "Интервал проверки: ${CHECK_INTERVAL}с"
    
    local iteration=0
    
    while true; do
        iteration=$((iteration + 1))
        log "DEBUG" "=== Итерация ${iteration} ==="
        
        # Проверка правил сбора (collect)
        for rule_key in "${!COLLECT_RULES[@]}"; do
            local desc_interval="${COLLECT_RULES[$rule_key]}"
            local interval
            interval=$(echo "$desc_interval" | cut -d'|' -f2)
            
            if should_run_task "$rule_key" "$interval"; then
                do_collect "$rule_key" "$desc_interval" || log "ERROR" "Ошибка сбора данных: $rule_key"
            fi
        done
        
        # Проверка правил агрегации (aggregate)
        for rule_key in "${!AGGREGATE_RULES[@]}"; do
            local desc_window_interval="${AGGREGATE_RULES[$rule_key]}"
            local interval
            interval=$(echo "$desc_window_interval" | cut -d'|' -f3)
            
            if should_run_task "$rule_key" "$interval"; then
                do_aggregate "$rule_key" "$desc_window_interval" || log "ERROR" "Ошибка агрегации: $rule_key"
            fi
        done
        
        # Проверка правил очистки (cleanup) - раз в час
        if [ $((iteration % 360)) -eq 0 ]; then
            for data_type in "${!CLEANUP_RULES[@]}"; do
                local retention="${CLEANUP_RULES[$data_type]}"
                do_cleanup "$data_type" "$retention" || log "ERROR" "Ошибка очистки: $data_type"
            done
        fi
        
        # Сон до следующей проверки
        sleep "$CHECK_INTERVAL"
    done
}

# Запуск основного цикла
main_loop

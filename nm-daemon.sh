#!/bin/bash
# nm-daemon.sh - Демон сбора и агрегации данных сетевого мониторинга
# Версия: 1.2
# Запускается как systemd сервис

set -euo pipefail  # Строгий режим

# Загружаем конфигурацию
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nm-config"

# Функция логирования
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Проверяем уровень логирования
    case "$LOG_LEVEL" in
        "DEBUG") ;;
        "INFO")  [ "$level" = "DEBUG" ] && return ;;
        "WARN")  [[ "$level" =~ ^(DEBUG|INFO)$ ]] && return ;;
        "ERROR") [[ "$level" =~ ^(DEBUG|INFO|WARN)$ ]] && return ;;
    esac
    
    # Запись в файл
    echo "${timestamp} [${level}] ${message}" >> "$LOG_FILE"
    
    # В journald через stdout (для systemd)
    if [ "$level" = "ERROR" ]; then
        echo >&2 "${timestamp} [${level}] ${message}"
    else
        echo "${timestamp} [${level}] ${message}"
    fi
}

# Функция для получения последнего запуска задачи из БД
get_last_run() {
    local task_key="$1"
    local result
    
    result=$(sqlite3 "$DB_PATH" "SELECT last_run FROM task_last_run WHERE task_key = '$task_key';")
    echo "$result"
}

# Функция для обновления времени последнего запуска
update_last_run() {
    local task_key="$1"
    
    sqlite3 "$DB_PATH" <<EOF
INSERT INTO task_last_run (task_key, last_run, updated_at) 
VALUES ('$task_key', datetime('now'), datetime('now'))
ON CONFLICT(task_key) DO UPDATE SET 
    last_run = datetime('now'),
    updated_at = datetime('now');
EOF
}

# Функция проверки необходимости запуска задачи
need_to_run() {
    local task_type="$1"      # collect, aggregate, cleanup
    local task_key="$2"       # ключ задачи (например, "5" для collect или "raw:300" для aggregate)
    local interval="$3"       # интервал в секундах
    local last_run
    
    last_run=$(get_last_run "${task_type}:${task_key}")
    
    if [ -z "$last_run" ]; then
        log "DEBUG" "Задача ${task_type}:${task_key} никогда не запускалась"
        return 0  # Никогда не запускалась - нужно запустить
    fi
    
    # Конвертируем время в секунды с эпохи
    local last_run_epoch=$(date -d "$last_run" +%s 2>/dev/null || date -d "$last_run UTC" +%s)
    local now_epoch=$(date +%s)
    local diff=$((now_epoch - last_run_epoch))
    
    if [ $diff -ge $interval ]; then
        log "DEBUG" "Задача ${task_type}:${task_key} требует запуска (прошло ${diff}с, интервал ${interval}с)"
        return 0
    else
        log "DEBUG" "Задача ${task_type}:${task_key} еще не пора (прошло ${diff}с, интервал ${interval}с)"
        return 1
    fi
}

# Функция сбора сырых данных с интерфейса
collect_interface_data() {
    local interface="$1"
    local timestamp="$2"
    local data_type="raw"
    
    log "DEBUG" "Сбор данных с интерфейса $interface"
    
    # Читаем данные из /proc/net/dev
    if ! line=$(grep "$interface:" /proc/net/dev); then
        log "WARN" "Интерфейс $interface не найден в /proc/net/dev"
        return 1
    fi
    
    # Парсим строку
    # Пример: ens3: 19042911454 48592510 0 0 0 0 0 0 15742593469 14974526 0 0 0 0 0 0
    rx_bytes=$(echo $line | awk '{print $2}')
    rx_packets=$(echo $line | awk '{print $3}')
    rx_errors=$(echo $line | awk '{print $4}')
    rx_drop=$(echo $line | awk '{print $5}')
    
    tx_bytes=$(echo $line | awk '{print $10}')
    tx_packets=$(echo $line | awk '{print $11}')
    tx_errors=$(echo $line | awk '{print $12}')
    tx_drop=$(echo $line | awk '{print $13}')
    
    # Вставляем в БД
    sqlite3 "$DB_PATH" <<EOF
INSERT INTO interfaces_stats (
    data_type, timestamp, interface,
    rx_bytes, tx_bytes, rx_packets, tx_packets,
    rx_errors, tx_errors, rx_drop, tx_drop
) VALUES (
    '$data_type', '$timestamp', '$interface',
    $rx_bytes, $tx_bytes, $rx_packets, $tx_packets,
    $rx_errors, $tx_errors, $rx_drop, $tx_drop
);
EOF
    
    log "DEBUG" "Данные $interface сохранены: RX=$rx_bytes TX=$tx_bytes"
}

# Функция сбора данных WireGuard клиентов
collect_wg_data() {
    local interface="$1"
    local timestamp="$2"
    local data_type="raw"
    
    log "DEBUG" "Сбор данных WireGuard с $interface"
    
    # Получаем список пиров
    local peers_output
    if ! peers_output=$(wg show "$interface" dump 2>/dev/null); then
        log "WARN" "Не удалось получить данные WireGuard с $interface"
        return 1
    fi
    
    # Парсим вывод wg show dump
    # Формат: private_key public_key endpoint allowed_ips latest_handshake transfer_rx transfer_tx persistent_keepalive
    echo "$peers_output" | while read line; do
        # Пропускаем первую строку (приватный ключ интерфейса)
        if [[ "$line" == *"private_key"* ]]; then
            continue
        fi
        
        public_key=$(echo $line | awk '{print $2}')
        endpoint=$(echo $line | awk '{print $3}')
        allowed_ips=$(echo $line | awk '{print $4}')
        handshake_seconds=$(echo $line | awk '{print $5}')
        rx_bytes=$(echo $line | awk '{print $6}')
        tx_bytes=$(echo $line | awk '{print $7}')
        
        # Получаем IP из allowed_ips (первый /32)
        peer_ip=$(echo "$allowed_ips" | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | head -1)
        
        # Получаем имя клиента из файла конфигурации
        peer_name=""
        if [ -n "$peer_ip" ]; then
            # Ищем в /etc/wireguard/clients/*.conf
            local client_conf=$(grep -l "$peer_ip" /etc/wireguard/clients/*.conf 2>/dev/null | head -1)
            if [ -n "$client_conf" ]; then
                peer_name=$(basename "$client_conf" .conf)
            fi
        fi
        
        # Если не нашли по IP, пробуем найти по публичному ключу
        if [ -z "$peer_name" ] && [ -n "$public_key" ]; then
            local client_conf=$(grep -l "$public_key" /etc/wireguard/clients/*.conf 2>/dev/null | head -1)
            if [ -n "$client_conf" ]; then
                peer_name=$(basename "$client_conf" .conf)
            fi
        fi
        
        # Если имя не найдено, используем первые 8 символов ключа
        if [ -z "$peer_name" ]; then
            peer_name="${public_key:0:8}"
        fi
        
        # Вставляем в БД
        sqlite3 "$DB_PATH" <<EOF
INSERT INTO wg_peers_stats (
    data_type, timestamp, peer_key, peer_ip, peer_name,
    rx_bytes, tx_bytes, handshake_seconds
) VALUES (
    '$data_type', '$timestamp', '$public_key', '$peer_ip', '$peer_name',
    $rx_bytes, $tx_bytes, $handshake_seconds
);
EOF
        
        log "DEBUG" "Данные клиента $peer_name сохранены: RX=$rx_bytes TX=$tx_bytes"
    done
}

# Функция выполнения правил сбора
execute_collect_rules() {
    local timestamp="$1"
    
    for interval in "${!COLLECT_RULES[@]}"; do
        if need_to_run "collect" "$interval" "$interval"; then
            log "INFO" "Выполнение сбора данных (интервал: ${interval}с)"
            
            local start_time=$(date +%s)
            
            # Сбор основного интерфейса
            if [ -n "$MAIN_IFACE" ]; then
                collect_interface_data "$MAIN_IFACE" "$timestamp"
            fi
            
            # Сбор WireGuard интерфейса
            if [ -n "$WG_IFACE" ]; then
                collect_wg_data "$WG_IFACE" "$timestamp"
            fi
            
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            
            # Логируем выполнение
            sqlite3 "$DB_PATH" <<EOF
INSERT INTO tasks_log (task_type, rule_key, started_at, finished_at, status, records_processed)
VALUES ('collect', '$interval', '$timestamp', datetime('now'), 'success', 1);
EOF
            
            update_last_run "collect:$interval"
            log "INFO" "Сбор данных завершен за ${duration}с"
        fi
    done
}

# Функция расчета скорости (дельты) между замерами
calculate_rates() {
    local interface="$1"
    local start_time="$2"
    local end_time="$3"
    
    sqlite3 "$DB_PATH" <<EOF
WITH interface_data AS (
    SELECT 
        timestamp,
        rx_bytes,
        tx_bytes,
        LAG(rx_bytes) OVER (ORDER BY timestamp) as prev_rx,
        LAG(tx_bytes) OVER (ORDER BY timestamp) as prev_tx,
        LAG(timestamp) OVER (ORDER BY timestamp) as prev_time
    FROM interfaces_stats
    WHERE interface = '$interface'
        AND data_type = 'raw'
        AND timestamp BETWEEN '$start_time' AND '$end_time'
    ORDER BY timestamp
)
SELECT 
    AVG((rx_bytes - prev_rx) / strftime('%s', timestamp) - strftime('%s', prev_time)) as avg_rx_rate,
    AVG((tx_bytes - prev_tx) / strftime('%s', timestamp) - strftime('%s', prev_time)) as avg_tx_rate,
    MAX((rx_bytes - prev_rx) / strftime('%s', timestamp) - strftime('%s', prev_time)) as max_rx_rate,
    MAX((tx_bytes - prev_tx) / strftime('%s', timestamp) - strftime('%s', prev_time)) as max_tx_rate,
    MIN((rx_bytes - prev_rx) / strftime('%s', timestamp) - strftime('%s', prev_time)) as min_rx_rate,
    MIN((tx_bytes - prev_tx) / strftime('%s', timestamp) - strftime('%s', prev_time)) as min_tx_rate,
    COUNT(*) as samples
FROM interface_data
WHERE prev_rx IS NOT NULL;
EOF
}

# Функция агрегации данных интерфейсов
aggregate_interfaces_data() {
    local input_type="$1"
    local output_type="$2"
    local window="$3"
    local end_time="$4"
    local start_time=$(date -d "$end_time - $window seconds" "+%Y-%m-%d %H:%M:%S")
    
    log "DEBUG" "Агрегация $input_type -> $output_type за период $start_time - $end_time"
    
    # Для каждого интерфейса
    local interfaces=("$MAIN_IFACE")
    [ -n "$WG_IFACE" ] && interfaces+=("$WG_IFACE")
    
    for interface in "${interfaces[@]}"; do
        if [ -z "$interface" ]; then
            continue
        fi
        
        # Получаем статистику
        local stats=$(sqlite3 "$DB_PATH" <<EOF
WITH data_window AS (
    SELECT 
        timestamp,
        rx_bytes,
        tx_bytes,
        rx_packets,
        tx_packets,
        rx_errors,
        tx_errors,
        rx_drop,
        tx_drop
    FROM interfaces_stats
    WHERE interface = '$interface'
        AND data_type = '$input_type'
        AND timestamp BETWEEN '$start_time' AND '$end_time'
    ORDER BY timestamp
),
rates AS (
    SELECT 
        (rx_bytes - LAG(rx_bytes) OVER (ORDER BY timestamp)) / 
        (strftime('%s', timestamp) - strftime('%s', LAG(timestamp) OVER (ORDER BY timestamp))) as rx_rate,
        (tx_bytes - LAG(tx_bytes) OVER (ORDER BY timestamp)) / 
        (strftime('%s', timestamp) - strftime('%s', LAG(timestamp) OVER (ORDER BY timestamp))) as tx_rate
    FROM data_window
)
SELECT 
    AVG(rx_bytes) as avg_rx,
    AVG(tx_bytes) as avg_tx,
    AVG(rx_packets) as avg_rx_packets,
    AVG(tx_packets) as avg_tx_packets,
    SUM(rx_errors) as total_rx_errors,
    SUM(tx_errors) as total_tx_errors,
    SUM(rx_drop) as total_rx_drop,
    SUM(tx_drop) as total_tx_drop,
    COUNT(*) as sample_count,
    AVG(rx_rate) as avg_rx_rate,
    AVG(tx_rate) as avg_tx_rate,
    MAX(rx_rate) as max_rx_rate,
    MAX(tx_rate) as max_tx_rate,
    MIN(rx_rate) as min_rx_rate,
    MIN(tx_rate) as min_tx_rate
FROM data_window, rates
WHERE rates.rowid = data_window.rowid;
EOF
)
        
        # Парсим результат
        IFS='|' read -r avg_rx avg_tx avg_rx_packets avg_tx_packets \
            total_rx_errors total_tx_errors total_rx_drop total_tx_drop \
            sample_count avg_rx_rate avg_tx_rate max_rx_rate max_tx_rate \
            min_rx_rate min_tx_rate <<< "$stats"
        
        # Сохраняем агрегированную запись
        if [ -n "$avg_rx" ] && [ "$avg_rx" != "NULL" ]; then
            sqlite3 "$DB_PATH" <<EOF
INSERT INTO interfaces_stats (
    data_type, timestamp, interface,
    rx_bytes, tx_bytes, rx_packets, tx_packets,
    rx_errors, tx_errors, rx_drop, tx_drop,
    samples_count,
    min_rx_rate, max_rx_rate, min_tx_rate, max_tx_rate
) VALUES (
    '$output_type', '$end_time', '$interface',
    $avg_rx, $avg_tx, $avg_rx_packets, $avg_tx_packets,
    $total_rx_errors, $total_tx_errors, $total_rx_drop, $total_tx_drop,
    $sample_count,
    $min_rx_rate, $max_rx_rate, $min_tx_rate, $max_tx_rate
);
EOF
            log "DEBUG" "Агрегация $interface сохранена: samples=$sample_count"
        fi
    done
}

# Функция агрегации данных WireGuard клиентов
aggregate_wg_data() {
    local input_type="$1"
    local output_type="$2"
    local window="$3"
    local end_time="$4"
    local start_time=$(date -d "$end_time - $window seconds" "+%Y-%m-%d %H:%M:%S")
    
    log "DEBUG" "Агрегация WG $input_type -> $output_type за период $start_time - $end_time"
    
    # Получаем уникальных клиентов
    local peers=$(sqlite3 "$DB_PATH" <<EOF
SELECT DISTINCT peer_key, peer_name, peer_ip
FROM wg_peers_stats
WHERE data_type = '$input_type'
    AND timestamp BETWEEN '$start_time' AND '$end_time';
EOF
)
    
    echo "$peers" | while IFS='|' read -r peer_key peer_name peer_ip; do
        if [ -z "$peer_key" ]; then
            continue
        fi
        
        # Получаем статистику по клиенту
        local stats=$(sqlite3 "$DB_PATH" <<EOF
WITH data_window AS (
    SELECT 
        timestamp,
        rx_bytes,
        tx_bytes,
        handshake_seconds
    FROM wg_peers_stats
    WHERE peer_key = '$peer_key'
        AND data_type = '$input_type'
        AND timestamp BETWEEN '$start_time' AND '$end_time'
    ORDER BY timestamp
),
rates AS (
    SELECT 
        (rx_bytes - LAG(rx_bytes) OVER (ORDER BY timestamp)) / 
        (strftime('%s', timestamp) - strftime('%s', LAG(timestamp) OVER (ORDER BY timestamp))) as rx_rate,
        (tx_bytes - LAG(tx_bytes) OVER (ORDER BY timestamp)) / 
        (strftime('%s', timestamp) - strftime('%s', LAG(timestamp) OVER (ORDER BY timestamp))) as tx_rate
    FROM data_window
)
SELECT 
    AVG(rx_bytes) as avg_rx,
    AVG(tx_bytes) as avg_tx,
    AVG(handshake_seconds) as avg_handshake,
    COUNT(*) as sample_count,
    AVG(rx_rate) as avg_rx_rate,
    AVG(tx_rate) as avg_tx_rate,
    MAX(rx_rate) as max_rx_rate,
    MAX(tx_rate) as max_tx_rate,
    MIN(rx_rate) as min_rx_rate,
    MIN(tx_rate) as min_tx_rate
FROM data_window, rates
WHERE rates.rowid = data_window.rowid;
EOF
)
        
        # Парсим результат
        IFS='|' read -r avg_rx avg_tx avg_handshake sample_count \
            avg_rx_rate avg_tx_rate max_rx_rate max_tx_rate \
            min_rx_rate min_tx_rate <<< "$stats"
        
        # Сохраняем агрегированную запись
        if [ -n "$avg_rx" ] && [ "$avg_rx" != "NULL" ]; then
            sqlite3 "$DB_PATH" <<EOF
INSERT INTO wg_peers_stats (
    data_type, timestamp, peer_key, peer_ip, peer_name,
    rx_bytes, tx_bytes, handshake_seconds,
    samples_count,
    min_rx_rate, max_rx_rate, min_tx_rate, max_tx_rate
) VALUES (
    '$output_type', '$end_time', '$peer_key', '$peer_ip', '$peer_name',
    $avg_rx, $avg_tx, $avg_handshake,
    $sample_count,
    $min_rx_rate, $max_rx_rate, $min_tx_rate, $max_tx_rate
);
EOF
            log "DEBUG" "Агрегация клиента $peer_name сохранена: samples=$sample_count"
        fi
    done
}

# Функция выполнения правил агрегации
execute_aggregate_rules() {
    local timestamp="$1"
    
    for rule in "${!AGGREGATE_RULES[@]}"; do
        # rule = "raw:300" (входной_тип:интервал_запуска)
        local input_type=$(echo "$rule" | cut -d: -f1)
        local run_interval=$(echo "$rule" | cut -d: -f2)
        local output_config="${AGGREGATE_RULES[$rule]}"  # "agg_5min:300:описание"
        
        local output_type=$(echo "$output_config" | cut -d: -f1)
        local window=$(echo "$output_config" | cut -d: -f2)
        local description=$(echo "$output_config" | cut -d: -f3)
        
        if need_to_run "aggregate" "$rule" "$run_interval"; then
            log "INFO" "Выполнение агрегации: $description"
            
            local start_agg=$(date +%s)
            
            # Агрегация интерфейсов
            aggregate_interfaces_data "$input_type" "$output_type" "$window" "$timestamp"
            
            # Агрегация WireGuard клиентов (если есть)
            if [ -n "$WG_IFACE" ]; then
                aggregate_wg_data "$input_type" "$output_type" "$window" "$timestamp"
            fi
            
            local end_agg=$(date +%s)
            local duration=$((end_agg - start_agg))
            
            # Логируем выполнение
            sqlite3 "$DB_PATH" <<EOF
INSERT INTO tasks_log (task_type, rule_key, started_at, finished_at, status)
VALUES ('aggregate', '$rule', '$timestamp', datetime('now'), 'success');
EOF
            
            update_last_run "aggregate:$rule"
            log "INFO" "Агрегация завершена за ${duration}с"
        fi
    done
}

# Функция очистки старых данных
execute_cleanup_rules() {
    local timestamp="$1"
    
    for data_type in "${!CLEANUP_RULES[@]}"; do
        local retention_days="${CLEANUP_RULES[$data_type]}"
        local cutoff_date=$(date -d "$retention_days days ago" "+%Y-%m-%d %H:%M:%S")
        
        # Проверяем, нужно ли запускать очистку (раз в час)
        if need_to_run "cleanup" "$data_type" "3600"; then
            log "INFO" "Очистка $data_type старше $retention_days дней (до $cutoff_date)"
            
            # Очистка interfaces_stats
            local deleted_if=$(sqlite3 "$DB_PATH" "DELETE FROM interfaces_stats WHERE data_type = '$data_type' AND timestamp < '$cutoff_date'; SELECT changes();")
            
            # Очистка wg_peers_stats
            local deleted_wg=0
            if [ -n "$WG_IFACE" ]; then
                deleted_wg=$(sqlite3 "$DB_PATH" "DELETE FROM wg_peers_stats WHERE data_type = '$data_type' AND timestamp < '$cutoff_date'; SELECT changes();")
            fi
            
            local total_deleted=$((deleted_if + deleted_wg))
            
            # Логируем выполнение
            sqlite3 "$DB_PATH" <<EOF
INSERT INTO tasks_log (task_type, rule_key, started_at, finished_at, status, records_processed)
VALUES ('cleanup', '$data_type', '$timestamp', datetime('now'), 'success', $total_deleted);
EOF
            
            update_last_run "cleanup:$data_type"
            log "INFO" "Очистка завершена, удалено записей: $total_deleted"
        fi
    done
}

# Функция обработки сигналов
cleanup() {
    log "INFO" "Получен сигнал завершения, останавливаем демон"
    exit 0
}

# Главный цикл демона
main_loop() {
    log "INFO" "Демон мониторинга сети запущен"
    log "INFO" "Основной интерфейс: $MAIN_IFACE"
    log "INFO" "WireGuard интерфейс: ${WG_IFACE:-не используется}"
    log "INFO" "Интервал проверки: ${CHECK_INTERVAL}с"
    
    trap cleanup SIGTERM SIGINT
    
    while true; do
        local current_time=$(date "+%Y-%m-%d %H:%M:%S")
        
        # Выполняем сбор данных
        execute_collect_rules "$current_time"
        
        # Выполняем агрегацию
        execute_aggregate_rules "$current_time"
        
        # Выполняем очистку
        execute_cleanup_rules "$current_time"
        
        # Ждем следующий цикл
        sleep "$CHECK_INTERVAL"
    done
}

# Запуск демона
main() {
    # Проверяем, не запущен ли уже демон
    local pid_file="/var/run/nm-daemon.pid"
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file")
        if kill -0 "$old_pid" 2>/dev/null; then
            log "ERROR" "Демон уже запущен (PID: $old_pid)"
            exit 1
        fi
    fi
    
    # Создаем pid файл
    echo $$ > "$pid_file"
    
    # Запускаем основной цикл
    main_loop
    
    # Удаляем pid файл при выходе
    rm -f "$pid_file"
}

# Запуск
main "$@"
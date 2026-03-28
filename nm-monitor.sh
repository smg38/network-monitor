#!/bin/bash
# nm-monitor.sh - Клиент для формирования отчетов и live-мониторинга
# Версия: 1.7.0
# Автор: TG: @smg38 smg38@yandex.ru
# Использование: ./nm-monitor.sh [--live|--summary|--daily|--weekly|--monthly|--top N|--period YYYY-MM-DD YYYY-MM-DD|--help]

set -euo pipefail

# Загружаем общую библиотеку (заменяет дублирование функций)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nm-lib.sh"

# Устанавливаем контекст логирования для этого скрипта
LOG_CONTEXT="monitor"

# Загружаем конфигурацию
source "${SCRIPT_DIR}/nm-config.sh"

# Функция получения текущей скорости (дельты)
get_current_rates() {
    local interface="$1"
    
    # Получаем две последние записи
    local data
    data=$(sqlite3 "$DB_PATH" <<EOF
SELECT timestamp, rx_bytes, tx_bytes FROM interfaces_stats 
WHERE interface = '$interface' AND data_type = 'raw'
ORDER BY timestamp DESC LIMIT 2;
EOF
)
    
    if [ "$(echo "$data" | wc -l)" -lt 2 ]; then
        echo "0|0"
        return
    fi
    
    local latest prev
    latest=$(echo "$data" | head -1)
    prev=$(echo "$data" | tail -1)
    
    local latest_time latest_rx latest_tx
    latest_time=$(parse_field "$latest" "|" 1)
    latest_rx=$(parse_field "$latest" "|" 2)
    latest_tx=$(parse_field "$latest" "|" 3)
    
    local prev_time prev_rx prev_tx
    prev_time=$(parse_field "$prev" "|" 1)
    prev_rx=$(parse_field "$prev" "|" 2)
    prev_tx=$(parse_field "$prev" "|" 3)
    
    local time_diff
    time_diff=$(($(date -d "$latest_time" +%s) - $(date -d "$prev_time" +%s)))
    
    if [ "$time_diff" -eq 0 ]; then
        echo "0|0"
        return
    fi
    
    local rx_rate=$(( (latest_rx - prev_rx) / time_diff ))
    local tx_rate=$(( (latest_tx - prev_tx) / time_diff ))
    
    echo "${rx_rate}|${tx_rate}"
}

# Функция live-режима
live_mode() {
    log "INFO" "Запуск live-режима (обновление каждые ${LIVE_REFRESH_INTERVAL}с)"
    
    # Очищаем экран
    clear
    
    while true; do
        # Сохраняем позицию курсора
        tput sc
        
        # Получаем текущие скорости
    local main_rates main_rx_rate main_tx_rate
    main_rates=$(get_current_rates "$MAIN_IFACE")
    main_rx_rate=$(parse_field "$main_rates" "|" 1)
    main_tx_rate=$(parse_field "$main_rates" "|" 2)
        
        # Получаем статистику за сегодня
    local today main_today main_today_rx main_today_tx
    today=$(date "+%Y-%m-%d")
    main_today=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx
FROM interfaces_stats 
WHERE interface = '$MAIN_IFACE' 
    AND data_type = 'raw'
    AND date(timestamp) = '$today';
EOF
)
    main_today_rx=$(parse_field "$main_today" "|" 1)
    main_today_tx=$(parse_field "$main_today" "|" 2)
        
        # Заголовок
        echo "${BOLD}${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
        echo "${BOLD}${BLUE}│${NC}  ${WHITE}СЕТЕВОЙ МОНИТОР - $(date '+%Y-%m-%d %H:%M:%S')${NC}                ${BLUE}│${NC}"
        echo "${BOLD}${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
        
        # Основной интерфейс
        printf "${BOLD}${BLUE}│${NC}  ${GREEN}%-15s${NC}: ↓ %10s  ↑ %10s  (сегодня: %s / %s) ${BLUE}│${NC}\n" "$MAIN_IFACE" "$(format_speed "$main_rx_rate")" "$(format_speed "$main_tx_rate")" "$(format_bytes "$main_today_rx")" "$(format_bytes "$main_today_tx")"
        
        # WireGuard интерфейс (если есть)
        if [ -n "$WG_IFACE" ]; then
            local wg_rates
            wg_rates=$(get_current_rates "$WG_IFACE")
            local wg_rx_rate
            wg_rx_rate=$(parse_field "$wg_rates" "|" 1)
            local wg_tx_rate
            wg_tx_rate=$(parse_field "$wg_rates" "|" 2)
            
            local wg_today
            wg_today=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx
FROM interfaces_stats 
WHERE interface = '$WG_IFACE' 
    AND data_type = 'raw'
    AND date(timestamp) = '$today';
EOF
)
            local wg_today_rx
            wg_today_rx=$(parse_field "$wg_today" "|" 1)
            local wg_today_tx
            wg_today_tx=$(parse_field "$wg_today" "|" 2)
            
            printf "${BOLD}${BLUE}│${NC}  ${GREEN}%-15s${NC}: ↓ %10s  ↑ %10s  (сегодня: %s / %s) ${BLUE}│${NC}\n" "$WG_IFACE" "$(format_speed "$wg_rx_rate")" "$(format_speed "$wg_tx_rate")" "$(format_bytes "$wg_today_rx")" "$(format_bytes "$wg_today_tx")"
        fi
        
        echo "${BOLD}${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
        echo "${BOLD}${BLUE}│${NC}  ${YELLOW}АКТИВНЫЕ КЛИЕНТЫ WG0:${NC}                                         ${BLUE}│${NC}"
        
        # Получаем активных клиентов (последние 5 минут)
        local active_peers
        active_peers=$(sqlite3 "$DB_PATH" <<EOF
WITH last_peer_data AS (
    SELECT 
        peer_name,
        peer_ip,
        rx_bytes,
        tx_bytes,
        timestamp,
        ROW_NUMBER() OVER (PARTITION BY peer_key ORDER BY timestamp DESC) as rn
    FROM wg_peers_stats
    WHERE data_type = 'raw'
        AND timestamp > datetime('now', '-5 minutes')
)
SELECT 
    peer_name,
    peer_ip,
    rx_bytes,
    tx_bytes,
    datetime(timestamp) as last_seen
FROM last_peer_data
WHERE rn = 1
ORDER BY peer_name
LIMIT 10;
EOF
)
        
        if [ -n "$active_peers" ]; then
            echo "$active_peers" | while IFS='|' read -r name ip rx tx last_seen; do
                # Вычисляем скорость (грубо)
                local time_ago
                time_ago=$(($(date +%s) - $(date -d "$last_seen" +%s)))
                if [ "$time_ago" -lt 60 ]; then
                    local rx_rate=0
                    local tx_rate=0
                    printf "${BOLD}${BLUE}│${NC}  ${CYAN}%-15s${NC} %-15s ↓ %8s  ↑ %8s  (total: %s/%s) ${BLUE}│${NC}\n" "$name" "$ip" "$(format_speed "$rx_rate")" "$(format_speed "$tx_rate")" "$(format_bytes "$rx")" "$(format_bytes "$tx")"
                fi
            done
        else
            echo "${BOLD}${BLUE}│${NC}  Нет активных клиентов                                          ${BLUE}│${NC}"
        fi
        
        echo "${BOLD}${BLUE}├─────────────────────────────────────────────────────────────┤${NC}"
        
        # Пиковые нагрузки за сегодня
        local peaks
        peaks=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    MAX(max_rx_rate) as peak_rx,
    MAX(max_tx_rate) as peak_tx
FROM interfaces_stats 
WHERE interface = '$MAIN_IFACE' 
    AND data_type = 'agg_5min'
    AND date(timestamp) = '$today';
EOF
)
        local peak_rx
        peak_rx=$(parse_field "$peaks" "|" 1)
        local peak_tx
        peak_tx=$(parse_field "$peaks" "|" 2)
        
        printf "${BOLD}${BLUE}│${NC}  Пик сегодня: ↓ %10s  ↑ %10s                 ${BLUE}│${NC}\n" "$(format_speed "$peak_rx")" "$(format_speed "$peak_tx")"
        
        echo "${BOLD}${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
        echo " Нажмите Ctrl+C для выхода"
        
        # Ждем и возвращаем курсор
        sleep "$LIVE_REFRESH_INTERVAL"
        tput rc
        tput ed  # очищаем до конца экрана
    done
}

# Функция сводки за сегодня
summary_mode() {
    local today
    today=$(date "+%Y-%m-%d")
    
    echo "${BOLD}${BLUE}СВОДКА ЗА $(date '+%d.%m.%Y')${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    
    # Статистика по основному интерфейсу
    local main_stats
    main_stats=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx,
    AVG(rx_bytes/300) as avg_rx_rate,
    AVG(tx_bytes/300) as avg_tx_rate,
    MAX(max_rx_rate) as peak_rx,
    MAX(max_tx_rate) as peak_tx
FROM interfaces_stats 
WHERE interface = '$MAIN_IFACE' 
    AND data_type = 'agg_5min'
    AND date(timestamp) = '$today';
EOF
)
    
    IFS='|' read -r total_rx total_tx avg_rx_rate avg_tx_rate peak_rx peak_tx <<< "$main_stats"
    
    echo "${BOLD}ИНТЕРФЕЙС $MAIN_IFACE${NC}"
    echo "───────────────────────────────────────────────────────────────"
    printf "  Всего за день:  ↓ %s  ↑ %s\n" "$(format_bytes "$total_rx")" "$(format_bytes "$total_tx")"
    printf "  Средняя нагрузка: ↓ %s  ↑ %s\n" "$(format_speed "${avg_rx_rate:-0}")" "$(format_speed "${avg_tx_rate:-0}")"
    printf "  Пиковая нагрузка: ↓ %s  ↑ %s\n" "$(format_speed "${peak_rx:-0}")" "$(format_speed "${peak_tx:-0}")"
    echo
    
    # Статистика по WireGuard (если есть)
    if [ -n "$WG_IFACE" ]; then
        local wg_stats
        wg_stats=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx
FROM interfaces_stats 
WHERE interface = '$WG_IFACE' 
    AND data_type = 'raw'
    AND date(timestamp) = '$today';
EOF
)
        IFS='|' read -r wg_total_rx wg_total_tx <<< "$wg_stats"
        
        echo "${BOLD}ИНТЕРФЕЙС $WG_IFACE (WireGuard)${NC}"
        echo "───────────────────────────────────────────────────────────────"
        printf "  Всего за день:  ↓ %s  ↑ %s\n" "$(format_bytes "$wg_total_rx")" "$(format_bytes "$wg_total_tx")"
        echo
    fi
    
    # Топ клиентов за сегодня
    echo "${BOLD}ТОП-${TOP_PEERS_DEFAULT} КЛИЕНТОВ ЗА СЕГОДНЯ${NC}"
    echo "───────────────────────────────────────────────────────────────"
    
    local peers
    peers=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    peer_name,
    peer_ip,
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx
FROM wg_peers_stats 
WHERE data_type = 'raw'
    AND date(timestamp) = '$today'
GROUP BY peer_key, peer_name, peer_ip
ORDER BY (total_rx + total_tx) DESC
LIMIT ${TOP_PEERS_DEFAULT};
EOF
)
    
    if [ -n "$peers" ]; then
        printf "  %-3s %-15s %-15s %12s %12s\n" "#" "Имя" "IP" "Получено" "Отправлено"
        echo "  ───────────────────────────────────────────────────────────"
        local i=1
        echo "$peers" | while IFS='|' read -r name ip rx tx; do
            printf "  %-3d %-15s %-15s %12s %12s\n" "$i" "${name:0:15}" "${ip:-N/A}" "$(format_bytes "$rx")" "$(format_bytes "$tx")"
            i=$((i+1))
        done
    else
        echo "  Нет данных за сегодня"
    fi
}

# Функция дневного отчета с почасовой разбивкой
daily_mode() {
    local date="${1:-$(date '+%Y-%m-%d')}"
    
    echo "${BOLD}${BLUE}ОТЧЕТ ЗА $date${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    
    # Почасовая статистика
    echo "${BOLD}ПОЧАСОВАЯ СТАТИСТИКА $MAIN_IFACE${NC}"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-5s %12s %12s %12s %12s\n" "Час" "Получено" "Отправлено" "Ср. RX" "Ср. TX"
    echo "  ─────────────────────────────────────────────────────────────"
    
    for hour in {00..23}; do
        local start_time="${date} ${hour}:00:00"
        local end_time="${date} ${hour}:59:59"
        
        local hour_stats
        hour_stats=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    SUM(rx_bytes) as hour_rx,
    SUM(tx_bytes) as hour_tx,
    AVG(rx_bytes/300) as avg_rx,
    AVG(tx_bytes/300) as avg_tx
FROM interfaces_stats 
WHERE interface = '$MAIN_IFACE' 
    AND data_type = 'agg_5min'
    AND timestamp BETWEEN '$start_time' AND '$end_time';
EOF
)
        IFS='|' read -r hour_rx hour_tx avg_rx avg_tx <<< "$hour_stats"
        
        if [ -n "$hour_rx" ] && [ "$hour_rx" -gt 0 ] 2>/dev/null; then
            printf "  %02d:00  %12s %12s %12s %12s\n" "$hour" "$(format_bytes "$hour_rx")" "$(format_bytes "$hour_tx")" "$(format_speed "${avg_rx:-0}")" "$(format_speed "${avg_tx:-0}")"
        fi
    done
    echo
    
    # Топ клиентов за день
    echo "${BOLD}ТОП-${TOP_PEERS_DEFAULT} КЛИЕНТОВ${NC}"
    echo "───────────────────────────────────────────────────────────────"
    
    local peers
    peers=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    peer_name,
    peer_ip,
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx
FROM wg_peers_stats 
WHERE data_type = 'raw'
    AND date(timestamp) = '$date'
GROUP BY peer_key, peer_name, peer_ip
ORDER BY (total_rx + total_tx) DESC
LIMIT ${TOP_PEERS_DEFAULT};
EOF
)
    
    if [ -n "$peers" ]; then
        printf "  %-3s %-15s %-15s %12s %12s\n" "#" "Имя" "IP" "Получено" "Отправлено"
        echo "  ───────────────────────────────────────────────────────────"
        local i=1
        echo "$peers" | while IFS='|' read -r name ip rx tx; do
            printf "  %-3d %-15s %-15s %12s %12s\n" "$i" "${name:0:15}" "${ip:-N/A}" "$(format_bytes "$rx")" "$(format_bytes "$tx")"
            i=$((i+1))
        done
    else
        echo "  Нет данных за указанный день"
    fi
}

# Функция недельного отчета
weekly_mode() {
    local end_date="${1:-$(date '+%Y-%m-%d')}"
    local start_date
    start_date=$(date -d "$end_date - 6 days" '+%Y-%m-%d')
    
    echo "${BOLD}${BLUE}ОТЧЕТ ЗА ПЕРИОД $start_date - $end_date${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    
    # Статистика по дням
    echo "${BOLD}ПОСУТОЧНАЯ СТАТИСТИКА${NC}"
    echo "───────────────────────────────────────────────────────────────"
    printf "  %-10s %12s %12s %12s %12s\n" "Дата" "Получено" "Отправлено" "Пик RX" "Пик TX"
    echo "  ─────────────────────────────────────────────────────────────"
    
    for i in {0..6}; do
        local day
        day=$(date -d "$start_date + $i days" '+%Y-%m-%d')
        
        local day_stats
        day_stats=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    SUM(rx_bytes) as day_rx,
    SUM(tx_bytes) as day_tx,
    MAX(max_rx_rate) as peak_rx,
    MAX(max_tx_rate) as peak_tx
FROM interfaces_stats 
WHERE interface = '$MAIN_IFACE' 
    AND data_type = 'agg_hour'
    AND date(timestamp) = '$day';
EOF
)
        IFS='|' read -r day_rx day_tx peak_rx peak_tx <<< "$day_stats"
        
        if [ -n "$day_rx" ] && [ "$day_rx" -gt 0 ] 2>/dev/null; then
            printf "  %-10s %12s %12s %12s %12s\n" "$day" "$(format_bytes "$day_rx")" "$(format_bytes "$day_tx")" "$(format_speed "${peak_rx:-0}")" "$(format_speed "${peak_tx:-0}")"
        fi
    done
    echo
    
    # Топ клиентов за неделю
    echo "${BOLD}ТОП-${TOP_PEERS_DEFAULT} КЛИЕНТОВ ЗА НЕДЕЛЮ${NC}"
    echo "───────────────────────────────────────────────────────────────"
    
    local peers
    peers=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    peer_name,
    peer_ip,
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx
FROM wg_peers_stats 
WHERE data_type = 'raw'
    AND date(timestamp) BETWEEN '$start_date' AND '$end_date'
GROUP BY peer_key, peer_name, peer_ip
ORDER BY (total_rx + total_tx) DESC
LIMIT ${TOP_PEERS_DEFAULT};
EOF
)
    
    if [ -n "$peers" ]; then
        printf "  %-3s %-15s %-15s %12s %12s\n" "#" "Имя" "IP" "Получено" "Отправлено"
        echo "  ───────────────────────────────────────────────────────────"
        local i=1
        echo "$peers" | while IFS='|' read -r name ip rx tx; do
            printf "  %-3d %-15s %-15s %12s %12s\n" "$i" "${name:0:15}" "${ip:-N/A}" "$(format_bytes "$rx")" "$(format_bytes "$tx")"
            i=$((i+1))
        done
    else
        echo "  Нет данных за указанный период"
    fi
}

# Функция месячного отчета
monthly_mode() {
    local end_date="${1:-$(date '+%Y-%m-%d')}"
    local start_date
    start_date=$(date -d "$end_date - 29 days" '+%Y-%m-%d')
    
    echo "${BOLD}${BLUE}ОТЧЕТ ЗА ПЕРИОД $start_date - $end_date${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    
    # Суммарная статистика
    local total_stats
    total_stats=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx,
    AVG(rx_bytes/86400) as avg_daily_rx,
    AVG(tx_bytes/86400) as avg_daily_tx
FROM interfaces_stats 
WHERE interface = '$MAIN_IFACE' 
    AND data_type = 'agg_day'
    AND date(timestamp) BETWEEN '$start_date' AND '$end_date';
EOF
)
    IFS='|' read -r total_rx total_tx avg_daily_rx avg_daily_tx <<< "$total_stats"
    
    echo "${BOLD}ВСЕГО ЗА МЕСЯЦ${NC}"
    echo "───────────────────────────────────────────────────────────────"
    printf "  Получено:  %s\n" "$(format_bytes "$total_rx")"
    printf "  Отправлено: %s\n" "$(format_bytes "$total_tx")"
    printf "  Среднесуточная нагрузка: ↓ %s  ↑ %s\n" "$(format_speed "${avg_daily_rx:-0}")" "$(format_speed "${avg_daily_tx:-0}")"
    echo
    
    # Топ клиентов за месяц
    echo "${BOLD}ТОП-${TOP_PEERS_DEFAULT} КЛИЕНТОВ ЗА МЕСЯЦ${NC}"
    echo "───────────────────────────────────────────────────────────────"
    
    local peers
    peers=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    peer_name,
    peer_ip,
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx
FROM wg_peers_stats 
WHERE data_type = 'raw'
    AND date(timestamp) BETWEEN '$start_date' AND '$end_date'
GROUP BY peer_key, peer_name, peer_ip
ORDER BY (total_rx + total_tx) DESC
LIMIT ${TOP_PEERS_DEFAULT};
EOF
)
    
    if [ -n "$peers" ]; then
        printf "  %-3s %-15s %-15s %12s %12s\n" "#" "Имя" "IP" "Получено" "Отправлено"
        echo "  ───────────────────────────────────────────────────────────"
        local i=1
        echo "$peers" | while IFS='|' read -r name ip rx tx; do
            printf "  %-3d %-15s %-15s %12s %12s\n" "$i" "${name:0:15}" "${ip:-N/A}" "$(format_bytes "$rx")" "$(format_bytes "$tx")"
            i=$((i+1))
        done
    else
        echo "  Нет данных за указанный период"
    fi
}

# Функция отчета за произвольный период
period_mode() {
    local start_date="$1"
    local end_date="$2"
    
    if [ -z "$start_date" ] || [ -z "$end_date" ]; then
        log "ERROR" "Не указаны даты начала и конца периода"
        exit 1
    fi
    
    echo "${BOLD}${BLUE}ОТЧЕТ ЗА ПЕРИОД $start_date - $end_date${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo
    
    # Суммарная статистика
    local total_stats
    total_stats=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx,
    COUNT(DISTINCT date(timestamp)) as days
FROM interfaces_stats 
WHERE interface = '$MAIN_IFACE' 
    AND data_type = 'agg_day'
    AND date(timestamp) BETWEEN '$start_date' AND '$end_date';
EOF
)
    IFS='|' read -r total_rx total_tx days <<< "$total_stats"
    
    echo "${BOLD}ВСЕГО ЗА ПЕРИОД (${days} дней)${NC}"
    echo "───────────────────────────────────────────────────────────────"
    printf "  Получено:  %s\n" "$(format_bytes "$total_rx")"
    printf "  Отправлено: %s\n" "$(format_bytes "$total_tx")"
    printf "  В среднем в день: ↓ %s  ↑ %s\n" "$(format_bytes "$((total_rx / days))")" "$(format_bytes "$((total_tx / days))")"
    echo
    
    # Топ клиентов за период
    echo "${BOLD}ТОП-${TOP_PEERS_DEFAULT} КЛИЕНТОВ${NC}"
    echo "───────────────────────────────────────────────────────────────"
    
    local peers
    peers=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    peer_name,
    peer_ip,
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx
FROM wg_peers_stats 
WHERE data_type = 'raw'
    AND date(timestamp) BETWEEN '$start_date' AND '$end_date'
GROUP BY peer_key, peer_name, peer_ip
ORDER BY (total_rx + total_tx) DESC
LIMIT ${TOP_PEERS_DEFAULT};
EOF
)
    
    if [ -n "$peers" ]; then
        printf "  %-3s %-15s %-15s %12s %12s\n" "#" "Имя" "IP" "Получено" "Отправлено"
        echo "  ───────────────────────────────────────────────────────────"
        local i=1
        echo "$peers" | while IFS='|' read -r name ip rx tx; do
            printf "  %-3d %-15s %-15s %12s %12s\n" "$i" "${name:0:15}" "${ip:-N/A}" "$(format_bytes "$rx")" "$(format_bytes "$tx")"
            i=$((i+1))
        done
    else
        echo "  Нет данных за указанный период"
    fi
}

# Функция топа клиентов
top_mode() {
    local limit="${1:-$TOP_PEERS_DEFAULT}"
    local period="${2:-all}"  # day, week, month, all
    
    case "$period" in
        day)
            local start_date
            start_date=$(date '+%Y-%m-%d')
            local end_date
            end_date=$(date '+%Y-%m-%d')
            local period_text="сегодня"
            ;;
        week)
            local start_date
            start_date=$(date -d "7 days ago" '+%Y-%m-%d')
            local end_date
            end_date=$(date '+%Y-%m-%d')
            local period_text="последние 7 дней"
            ;;
        month)
            local start_date
            start_date=$(date -d "30 days ago" '+%Y-%m-%d')
            local end_date
            end_date=$(date '+%Y-%m-%d')
            local period_text="последние 30 дней"
            ;;
        *)
            local start_date="1970-01-01"
            local end_date
            end_date=$(date '+%Y-%m-%d')
            local period_text="все время"
            ;;
    esac
    
    echo "${BOLD}${BLUE}ТОП-${limit} КЛИЕНТОВ ЗА ${period_text^^}${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    
    local peers
    peers=$(sqlite3 "$DB_PATH" <<EOF
SELECT 
    peer_name,
    peer_ip,
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx,
    COUNT(DISTINCT date(timestamp)) as days_active
FROM wg_peers_stats 
WHERE data_type = 'raw'
    AND date(timestamp) BETWEEN '$start_date' AND '$end_date'
GROUP BY peer_key, peer_name, peer_ip
ORDER BY (total_rx + total_tx) DESC
LIMIT $limit;
EOF
)
    
    if [ -n "$peers" ]; then
        printf "\n  %-3s %-15s %-15s %12s %12s %8s\n" "#" "Имя" "IP" "Получено" "Отправлено" "Дней"
        echo "  ───────────────────────────────────────────────────────────────────"
        local i=1
        echo "$peers" | while IFS='|' read -r name ip rx tx days; do
            printf "  %-3d %-15s %-15s %12s %12s %8d\n" "$i" "${name:0:15}" "${ip:-N/A}" "$(format_bytes "$rx")" "$(format_bytes "$tx")" "$days"
            i=$((i+1))
        done
    else
        echo "  Нет данных за указанный период"
    fi
}

# Функция проверки статуса демона
status_mode() {
    echo "${BOLD}${BLUE}СТАТУС СИСТЕМЫ МОНИТОРИНГА${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    
    # Проверка демона
    if systemctl is-active --quiet nm-daemon.service; then
        echo -e "  Демон: ${GREEN}АКТИВЕН${NC}"
    else
        echo -e "  Демон: ${RED}НЕ АКТИВЕН${NC}"
    fi
    
    # Информация о БД
    local db_size
    db_size=$(du -h "$DB_PATH" | cut -f1)
    local db_records
    db_records=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM interfaces_stats;")
    local wg_records
    wg_records=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM wg_peers_stats;")
    
    echo "  База данных: $DB_PATH"
    echo "  Размер БД: $db_size"
    echo "  Записей интерфейсов: $db_records"
    echo "  Записей клиентов: $wg_records"
    echo
    
    # Последние задачи
    echo "${BOLD}Последние задачи демона:${NC}"
    echo "───────────────────────────────────────────────────────────────"
    
    sqlite3 "$DB_PATH" <<EOF
SELECT 
    datetime(started_at) as time,
    task_type,
    status,
    records_processed
FROM tasks_log
ORDER BY started_at DESC
LIMIT 5;
EOF
}

# Функция справки
help_mode() {
    cat <<EOF
${BOLD}ИСПОЛЬЗОВАНИЕ: $0 [ОПЦИЯ]${NC}

${BOLD}ОСНОВНЫЕ ОПЦИИ:${NC}
  --live                    Интерактивный режим реального времени
  --summary                 Сводка за сегодня
  --daily [ДАТА]            Детальный отчет за день (по умолчанию сегодня)
  --weekly [ДАТА]           Отчет за неделю (по умолчанию последние 7 дней)
  --monthly [ДАТА]          Отчет за месяц (по умолчанию последние 30 дней)
  --period ДАТА1 ДАТА2      Отчет за произвольный период (формат ГГГГ-ММ-ДД)
  --top [N] [day|week|month|all]  Топ N клиентов (по умолчанию: ${TOP_PEERS_DEFAULT} за все время)
  --status                  Статус системы и демона
  --help                    Эта справка

${BOLD}ПРИМЕРЫ:${NC}
  $0 --live
  $0 --summary
  $0 --daily 2026-03-13
  $0 --weekly
  $0 --period 2026-03-01 2026-03-07
  $0 --top 20 month
  $0 --status
EOF
}

# Основная функция
main() {
    # Проверяем наличие БД
    if [ ! -f "$DB_PATH" ]; then
        log "ERROR" "База данных не найдена: $DB_PATH"
        log "ERROR" "Запустите сначала nm-install.sh"
        exit 1
    fi
    
    case "${1:-}" in
        --live)
            live_mode
            ;;
        --summary)
            summary_mode
            ;;
        --daily)
            daily_mode "${2:-}"
            ;;
        --weekly)
            weekly_mode "${2:-}"
            ;;
        --monthly)
            monthly_mode "${2:-}"
            ;;
        --period)
            period_mode "${2:-}" "${3:-}"
            ;;
        --top)
            top_mode "${2:-$TOP_PEERS_DEFAULT}" "${3:-all}"
            ;;
        --status)
            status_mode
            ;;
        --help|-h)
            help_mode
            ;;
        *)
            help_mode
            exit 1
            ;;
    esac
}

# Запуск
main "$@"
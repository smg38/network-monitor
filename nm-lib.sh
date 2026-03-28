#!/bin/bash
# nm-lib.sh - Общая библиотека функций для Network Monitor
# Версия: 1.7.1
# Автор: TG: @smg38 smg38@yandex.ru
# Назначение: Централизованное хранение общих функций
# Использование: source nm-lib.sh

set -euo pipefail

# ========================================
# ЦВЕТА ТЕРМИНАЛА
# ========================================
setup_colors() {
    if [ -t 1 ]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        MAGENTA='\033[0;35m'
        CYAN='\033[0;36m'
        WHITE='\033[0;37m'
        BOLD='\033[1m'
        NC='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        MAGENTA=''
        CYAN=''
        WHITE=''
        BOLD=''
        NC=''
    fi
    export RED GREEN YELLOW BLUE MAGENTA CYAN WHITE BOLD NC
}

# ========================================
# УЛУЧШЕННОЕ ЛОГИРОВАНИЕ С КОНТЕКСТОМ
# ========================================
# Параметры:
#   $1 - уровень (DEBUG|INFO|WARN|ERROR)
#   $2 - сообщение
#   ${LOG_CONTEXT:-} - опциональный контекст (имя функции/компонента)
#   ${LINENO:-} - автоматически добавляется номер строки вызова
log() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp
    local caller_info=""
    
    # Получаем информацию о вызывающем коде
    local frame=1
    local caller_file=""
    local caller_line=""
    local caller_func=""
    
    # Получаем информацию из стека вызовов
    if [ "${BASH_LINENO[1]+isset}" ]; then
        caller_line="${BASH_LINENO[1]}"
        caller_file="${BASH_SOURCE[2]:-unknown}"
        caller_file=$(basename "$caller_file")
        
        # Получаем имя функции, если вызов из функции
        if [ "${FUNCNAME[1]+isset}" ] && [ "${FUNCNAME[1]}" != "main" ] && [ "${FUNCNAME[1]}" != "source" ]; then
            caller_func="${FUNCNAME[1]}"
            caller_info="[${caller_file}:${caller_line} ${caller_func}()]"
        else
            caller_info="[${caller_file}:${caller_line}]"
        fi
    fi
    
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Добавляем контекст если указан
    local context_info=""
    if [ -n "${LOG_CONTEXT:-}" ]; then
        context_info="{${LOG_CONTEXT}}"
    fi
    
    # Формируем полное сообщение
    local full_message="${context_info} ${caller_info} ${message}"
    
    # Проверяем уровень логирования (если LOG_LEVEL установлен)
    if [ -n "${LOG_LEVEL:-}" ]; then
        case "$LOG_LEVEL" in
            "DEBUG") ;;
            "INFO")  [ "$level" = "DEBUG" ] && return ;;
            "WARN")  [[ "$level" =~ ^(DEBUG|INFO)$ ]] && return ;;
            "ERROR") [[ "$level" =~ ^(DEBUG|INFO|WARN)$ ]] && return ;;
        esac
    fi
    
    # Запись в файл лога (если LOG_FILE установлен)
    if [ -n "${LOG_FILE:-}" ]; then
        echo "${timestamp} [${level}] ${full_message}" >> "$LOG_FILE" 2>/dev/null || true
    fi
    
    # Вывод в stdout/stderr
    if [ "$level" = "ERROR" ]; then
        echo >&2 "${timestamp} [${level}] ${full_message}"
    else
        echo "${timestamp} [${level}] ${full_message}"
    fi
}

# Макрос для установки контекста логирования в функциях
# Использование: в начале функции добавить: set_log_context "function_name"
set_log_context() {
    export LOG_CONTEXT="$1"
}

# ========================================
# ФОРМАТИРОВАНИЕ БАЙТ (BASH ONLY - БЕЗ BC)
# ========================================
# Использует только арифметику bash вместо bc для производительности
format_bytes() {
    local bytes="${1:-0}"
    local precision="${2:-2}"
    
    # Проверка на пустое или отрицательное значение
    if [ -z "$bytes" ] || [ "$bytes" -lt 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi
    
    # Используем целочисленную арифметику bash
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then
        # KB: делим на 1024
        local kb=$((bytes / 1024))
        local remainder=$((bytes % 1024))
        local decimal=$((remainder * 100 / 1024))
        printf "%d.%02d KB" "$kb" "$decimal"
    elif [ "$bytes" -lt 1073741824 ]; then
        # MB: делим на 1048576
        local mb=$((bytes / 1048576))
        local remainder=$((bytes % 1048576))
        local decimal=$((remainder * 100 / 1048576))
        printf "%d.%02d MB" "$mb" "$decimal"
    elif [ "$bytes" -lt 1099511627776 ]; then
        # GB: делим на 1073741824
        local gb=$((bytes / 1073741824))
        local remainder=$((bytes % 1073741824))
        local decimal=$((remainder * 100 / 1073741824))
        printf "%d.%02d GB" "$gb" "$decimal"
    else
        # TB: делим на 1099511627776
        local tb=$((bytes / 1099511627776))
        local remainder=$((bytes % 1099511627776))
        local decimal=$((remainder * 100 / 1099511627776))
        printf "%d.%02d TB" "$tb" "$decimal"
    fi
}

# ========================================
# ФОРМАТИРОВАНИЕ СКОРОСТИ
# ========================================
format_speed() {
    local bytes_per_sec="${1:-0}"
    local formatted
    formatted=$(format_bytes "$bytes_per_sec")
    echo "${formatted}/s"
}

# ========================================
# РИСОВАНИЕ ПРОГРЕСС-БАРА (BASH ONLY)
# ========================================
draw_bar() {
    local percent="${1:-0}"
    local width=50
    local filled empty
    
    # Ограничиваем процент от 0 до 100
    [ "$percent" -lt 0 ] && percent=0
    [ "$percent" -gt 100 ] && percent=100
    
    # Вычисляем количество заполненных символов (без bc)
    filled=$((percent * width / 100))
    empty=$((width - filled))
    
    printf "["
    # Используем printf для заполнения (быстрее чем tr)
    if [ "$filled" -gt 0 ]; then
        printf "%*s" "$filled" "" | tr ' ' '█'
    fi
    if [ "$empty" -gt 0 ]; then
        printf "%*s" "$empty" "" | tr ' ' '░'
    fi
    printf "] %3d%%" "$percent"
}

# ========================================
# ПАРСИНГ СТРОКИ ПО РАЗДЕЛИТЕЛЮ (BASH ONLY)
# ========================================
# Альтернатива cut для парсинга строк
# Использование: parse_field "string" "|" field_number
parse_field() {
    local string="$1"
    local delimiter="${2:-|}"
    local field_num="${3:-1}"
    
    local IFS="$delimiter"
    local -a fields
    read -ra fields <<< "$string"
    
    # Индексация с 1
    local idx=$((field_num - 1))
    echo "${fields[$idx]:-}"
}

# Парсинг нескольких полей сразу
# Возвращает массив через echo
parse_fields() {
    local string="$1"
    local delimiter="${2:-|}"
    shift 2
    local -a field_nums=("$@")
    
    local IFS="$delimiter"
    local -a fields
    read -ra fields <<< "$string"
    
    local result=()
    for num in "${field_nums[@]}"; do
        local idx=$((num - 1))
        result+=("${fields[$idx]:-}")
    done
    
    echo "${result[@]}"
}

# ========================================
# БЕЗОПАСНЫЙ ВЫЗОВ SQLITE3
# ========================================
sqlite_safe() {
    local db_path="$1"
    shift
    local query="$*"
    
    # Проверка существования БД
    if [ ! -f "$db_path" ]; then
        log "ERROR" "База данных не найдена: $db_path"
        return 1
    fi
    
    # Выполнение запроса с обработкой ошибок
    local result
    if ! result=$(sqlite3 "$db_path" "$query" 2>&1); then
        log "ERROR" "Ошибка SQLite: $result (запрос: ${query:0:100}...)"
        return 1
    fi
    
    echo "$result"
}

# ========================================
# ИЗМЕРЕНИЕ ВРЕМЕНИ ВЫПОЛНЕНИЯ
# ========================================
# Возвращает время в секундах с начала эпохи
get_timestamp() {
    date +%s
}

# Форматированная дата
get_datetime() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Вычисление разницы во времени
time_diff() {
    local start="$1"
    local end="${2:-$(get_timestamp)}"
    echo $((end - start))
}

# ========================================
# СБОР МЕТРИК РЕСУРСОВ ПРОЦЕССА
# ========================================
# Возвращает метрики текущего процесса в формате key=value
collect_process_metrics() {
    local pid="${1:-$$}"
    
    # Чтение из /proc (Linux)
    if [ -d "/proc/$pid" ]; then
        # Потребление памяти (RSS в KB)
        local rss_kb
        rss_kb=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
        
        # Потребление CPU (из /proc/[pid]/stat)
        local stat_line
        stat_line=$(cat "/proc/$pid/stat" 2>/dev/null || echo "")
        
        if [ -n "$stat_line" ]; then
            local utime stime
            utime=$(echo "$stat_line" | awk '{print $14}')
            stime=$(echo "$stat_line" | awk '{print $15}')
            local total_time=$((utime + stime))
            
            # Время работы процесса в секундах
            local starttime
            starttime=$(echo "$stat_line" | awk '{print $22}')
            local clk_tck
            clk_tck=$(getconf CLK_TCK 2>/dev/null || echo "100")
            local uptime_sec
            uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
            local process_uptime=$((uptime_sec - starttime / clk_tck))
            
            # Процент CPU (грубая оценка)
            local cpu_percent=0
            if [ "$process_uptime" -gt 0 ]; then
                cpu_percent=$((total_time * 100 / clk_tck / process_uptime))
            fi
            
            echo "pid=$pid"
            echo "memory_rss_kb=$rss_kb"
            echo "cpu_percent=$cpu_percent"
            echo "uptime_sec=$process_uptime"
        else
            echo "pid=$pid"
            echo "memory_rss_kb=$rss_kb"
            echo "cpu_percent=0"
            echo "uptime_sec=0"
        fi
    else
        echo "pid=$pid"
        echo "memory_rss_kb=0"
        echo "cpu_percent=0"
        echo "uptime_sec=0"
    fi
}

# Сбор системных метрик
collect_system_metrics() {
    # Загрузка CPU (1 минута)
    local load_avg
    load_avg=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
    
    # Доступная память
    local mem_available
    mem_available=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    
    # Всего памяти
    local mem_total
    mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    
    # Uptime системы в секундах
    local uptime_sec
    uptime_sec=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
    
    echo "load_avg_1m=$load_avg"
    echo "memory_available_kb=$mem_available"
    echo "memory_total_kb=$mem_total"
    echo "system_uptime_sec=$uptime_sec"
}

# ========================================
# КЭШИРОВАНИЕ ПРОВЕРОК ЗАВИСИМОСТЕЙ
# ========================================
declare -A COMMAND_CACHE=()

check_command_cached() {
    local cmd="$1"
    
    # Проверяем кэш
    if [ "${COMMAND_CACHE[$cmd]+isset}" ]; then
        return "${COMMAND_CACHE[$cmd]}"
    fi
    
    # Проверяем наличие команды
    if command -v "$cmd" &>/dev/null; then
        COMMAND_CACHE[$cmd]=0
        return 0
    else
        COMMAND_CACHE[$cmd]=1
        return 1
    fi
}

# Проверка всех необходимых зависимостей
check_dependencies() {
    local deps=("sqlite3" "wg")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! check_command_cached "$dep"; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log "ERROR" "Отсутствуют зависимости: ${missing[*]}"
        return 1
    fi
    
    log "DEBUG" "Все зависимости доступны"
    return 0
}

# ========================================
# ВАЛИДАЦИЯ ВХОДНЫХ ДАННЫХ
# ========================================
validate_interface_name() {
    local iface="$1"
    
    # Простая валидация имени интерфейса
    if [[ "$iface" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_ip_address() {
    local ip="$1"
    
    # Валидация IPv4
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets
        read -ra octets <<< "$ip"
        
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ] 2>/dev/null; then
                return 1
            fi
        done
        return 0
    fi
    
    return 1
}

validate_date() {
    local date_str="$1"
    
    # Проверка формата YYYY-MM-DD
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        # Попытка сконвертировать дату
        if date -d "$date_str" +%s &>/dev/null; then
            return 0
        fi
    fi
    
    return 1
}

# ========================================
# РАБОТА С МАССИВАМИ
# ========================================
# Объединение элементов массива разделителем
join_array() {
    local delimiter="$1"
    shift
    local first="$1"
    shift
    printf '%s' "$first" "${@/#/$delimiter}"
}

# Проверка наличия элемента в массиве
array_contains() {
    local needle="$1"
    shift
    local element
    
    for element in "$@"; do
        [[ "$element" == "$needle" ]] && return 0
    done
    
    return 1
}

# ========================================
# ИНИЦИАЛИЗАЦИЯ БИБЛИОТЕКИ
# ========================================
# Автоматическая инициализация при source
if [ "${NM_LIB_AUTO_INIT:-true}" = "true" ]; then
    setup_colors
fi

# Экспорт основных функций
export -f setup_colors 2>/dev/null || true
export -f log 2>/dev/null || true
export -f format_bytes 2>/dev/null || true
export -f format_speed 2>/dev/null || true
export -f draw_bar 2>/dev/null || true

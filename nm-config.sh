#!/bin/bash
# nm-config - Конфигурационный файл системы мониторинга сети
# Версия: 1.4
# Автор: TG: @smg38 smg38@yandex.ru
# Расположение: /etc/network-monitor/nm-config.sh

# Цвета для вывода (если терминал поддерживает)
setup_colors() {
    if [ -t 1 ]; then
        local RED='\033[0;31m'
        local GREEN='\033[0;32m'
        local YELLOW='\033[0;33m'
        local BLUE='\033[0;34m'
        local MAGENTA='\033[0;35m'
        local CYAN='\033[0;36m'
        local WHITE='\033[0;37m'
        local BOLD='\033[1m'
        local NC='\033[0m' # No Color
        export RED GREEN YELLOW BLUE MAGENTA CYAN WHITE BOLD NC
    else
        unset RED GREEN YELLOW BLUE MAGENTA CYAN WHITE BOLD NC
        export RED GREEN YELLOW BLUE MAGENTA CYAN WHITE BOLD NC
    fi
}

# --- ОСНОВНЫЕ ИНТЕРФЕЙСЫ ---
# Выбираются при установке, можно изменить вручную
export MAIN_IFACE="ens3"             # Основной интерфейс для мониторинга
export WG_IFACE="wg0"                # WireGuard интерфейс (пусто, если нет)

# --- ДИРЕКТОРИИ ---
export BASE_DIR="/opt/network-monitor"
export DB_PATH="${BASE_DIR}/nm-data.db"
export CONFIG_PATH="${BASE_DIR}/nm-config.sh"
export LOG_DIR="/var/log/network-monitor"
export LOG_FILE="${LOG_DIR}/nm-daemon.log"

# --- ПРАВИЛА СБОРА ДАННЫХ (RAW DATA) ---
# Формат: COLLECT_RULES[интервал_в_секундах]="описание"
# Интервал определяет, как часто собираются сырые данные
declare -A COLLECT_RULES=(
    ["5"]="Сбор сырых данных каждые 5 секунд (максимальная детализация)"
    ["60"]="Сбор сырых данных каждую минуту (для долгосрочного хранения)"
)
export COLLECT_RULES

# --- ПРАВИЛА АГРЕГАЦИИ ---
# Формат: AGGREGATE_RULES[входной_тип:интервал_запуска]="выходной_тип:окно_агрегации:описание"
# входной_тип: raw, agg_5min, agg_hour, agg_day
# интервал_запуска: как часто выполнять эту агрегацию (в секундах)
# выходной_тип: тип создаваемых записей
# окно_агрегации: за какой период собирать данные (в секундах)
declare -A AGGREGATE_RULES=(
    ["raw:300"]="agg_5min:300:Агрегация за 5 минут из сырых данных (каждые 5 мин)"
    ["raw:3600"]="agg_hour:3600:Агрегация за час из сырых данных (каждый час)"
    ["agg_5min:3600"]="agg_hour_from_5min:3600:Агрегация за час из 5-минутных данных (каждый час)"
    ["agg_hour:86400"]="agg_day:86400:Агрегация за сутки из часовых данных (раз в день)"
)
export AGGREGATE_RULES

# --- ПРАВИЛА ОЧИСТКИ ---
# Формат: CLEANUP_RULES[тип_данных]="срок_хранения_в_днях"
declare -A CLEANUP_RULES=(
    ["raw"]="7"              # Сырые данные храним 7 дней
    ["agg_5min"]="30"        # 5-минутные агрегаты - 30 дней
    ["agg_hour"]="90"        # Часовые агрегаты - 90 дней
    ["agg_hour_from_5min"]="90"  # Часовые из 5-минутных - 90 дней
    ["agg_day"]="365"        # Дневные агрегаты - год
)
export CLEANUP_RULES

# --- ИНТЕРВАЛЫ ПРОВЕРКИ (в секундах) ---
export CHECK_INTERVAL=10       # Как часто демон проверяет необходимость выполнения задач

# --- НАСТРОЙКИ ЛОГИРОВАНИЯ ---
export LOG_LEVEL="INFO"        # DEBUG, INFO, WARN, ERROR
export LOG_MAX_SIZE="100"      # Максимальный размер лога в MB перед ротацией
export LOG_MAX_FILES="5"       # Количество хранимых файлов лога при ротации

# --- ПАРАМЕТРЫ ОТЧЕТОВ ---
export TOP_PEERS_DEFAULT=10    # Количество клиентов в топ-отчетах по умолчанию
export LIVE_REFRESH_INTERVAL=2 # Интервал обновления live-режима (секунды)

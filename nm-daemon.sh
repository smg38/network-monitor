#!/bin/bash
# nm-daemon.sh - Демон сбора и агрегации данных сетевого мониторинга
# Версия: 1.7.0
# Автор: TG: @smg38 smg38@yandex.ru
# Запускается как systemd сервис

set -euo pipefail  # Строгий режим

# Загружаем общую библиотеку (заменяет дублирование функций)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nm-lib.sh"

# Устанавливаем контекст логирования для этого скрипта
LOG_CONTEXT="daemon"

# Загружаем базовый конфиг + правила из БД (v1.7.0)
source "${SCRIPT_DIR}/nm-config.sh"

# Функция логирования
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
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

# Загружаем базовый конфиг + правила из БД (v1.6.4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Загружаем ПОЛНЫЙ конфиг (а не env!)
source "${SCRIPT_DIR}/nm-config.sh"

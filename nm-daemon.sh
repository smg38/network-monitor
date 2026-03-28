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

# Загружаем конфигурацию
source "${SCRIPT_DIR}/nm-config.sh"

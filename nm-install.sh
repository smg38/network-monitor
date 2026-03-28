#!/bin/bash
# nm-install.sh - Установщик системы мониторинга сети  
# Версия: 1.7.2
# Автор: TG: @smg38 smg38@yandex.ru
# Запуск: ./nm-install.sh (от root, sudo НЕ нужен)

VERSION="1.7.4"

set -e  # Выход при ошибке

# Определяем директорию скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Загружаем общую библиотеку
source "${SCRIPT_DIR}/nm-lib.sh"

# Устанавливаем контекст логирования
LOG_CONTEXT="install"

# Загружаем конфигурацию
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/nm-config.sh"

# Обработка аргументов командной строки
parse_args() {
    ACTION="install"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --uninstall|--remove)
                ACTION="uninstall"
                shift
                ;;
            --update|--upgrade)
                ACTION="update"
                shift
                ;;
            --help|-h)
                echo "Использование: $0 [опции]"
                echo ""
                echo "Опции:"
                echo "  --uninstall, --remove    Удалить установленную систему"
                echo "  --update, --upgrade      Обновить установленную систему"
                echo "  --help, -h               Показать эту справку"
                exit 0
                ;;
            *)
                echo "Неизвестная опция: $1"
                echo "Используйте --help для справки"
                exit 1
                ;;
        esac
    done
}

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log "ERROR" "Пожалуйста, запустите с sudo или от root"
        exit 1
    fi
    log "INFO" "Проверка прав root: OK"
}

# Проверка и установка зависимостей
check_dependencies() {
    local deps=("sqlite3" "bc" "awk" "grep" "sed" "ip" "wg")
    local missing=()
    
    log "INFO" "Проверка зависимостей..."
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        log "WARN" "Отсутствуют пакеты: ${missing[*]}"
        echo -e "${YELLOW}Хотите установить отсутствующие пакеты? (y/n)${NC}"
        read -r answer
        if [[ "$answer" =~ ^[YyДд]$ ]]; then
            if command -v apt-get &> /dev/null; then
                apt-get update
                apt-get install -y "${missing[@]//wg/wireguard-tools}"
            elif command -v yum &> /dev/null; then
                yum install -y "${missing[@]//wg/wireguard-tools}"
            else
                log "ERROR" "Не удалось определить менеджер пакетов"
                exit 1
            fi
            log "INFO" "Пакеты успешно установлены"
        else
            log "ERROR" "Установка невозможна без необходимых пакетов"
            exit 1
        fi
    else
        log "INFO" "Все зависимости удовлетворены"
    fi
}

# Выбор интерфейсов
select_interfaces() {
    log "INFO" "Поиск доступных сетевых интерфейсов..."
    
    # Получаем список всех интерфейсов (кроме loopback)
    mapfile -t interfaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)
    
    echo -e "\n${BOLD}Доступные сетевые интерфейсы:${NC}"
    for i in "${!interfaces[@]}"; do
        echo "  $((i+1)). ${interfaces[$i]}"
    done
    
    # Выбор основного интерфейса
    echo -e "\n${BOLD}Выберите основной интерфейс для мониторинга (номер):${NC}"
    read -r main_choice
    
    if [[ "$main_choice" -ge 1 && "$main_choice" -le "${#interfaces[@]}" ]]; then
        MAIN_IFACE="${interfaces[$((main_choice-1))]}"
        log "INFO" "Выбран основной интерфейс: $MAIN_IFACE"
    else
        log "ERROR" "Неверный выбор"
        exit 1
    fi
    
    # Поиск WireGuard интерфейсов
    local wg_interfaces=()
    for iface in "${interfaces[@]}"; do
        if [[ "$iface" =~ ^wg[0-9]+ ]]; then
            wg_interfaces+=("$iface")
        fi
    done
    
    if [ ${#wg_interfaces[@]} -gt 0 ]; then
        echo -e "\n${BOLD}Найдены WireGuard интерфейсы:${NC}"
        for i in "${!wg_interfaces[@]}"; do
            echo "  $((i+1)). ${wg_interfaces[$i]}"
        done
        echo "  0. Нет WireGuard интерфейса"
        
        echo -e "\n${BOLD}Выберите WireGuard интерфейс для мониторинга (0 для пропуска):${NC}"
        read -r wg_choice
        
        if [ "$wg_choice" -gt 0 ] && [ "$wg_choice" -le "${#wg_interfaces[@]}" ]; then
            WG_IFACE="${wg_interfaces[$((wg_choice-1))]}"
            log "INFO" "Выбран WireGuard интерфейс: $WG_IFACE"
        else
            WG_IFACE=""
            log "INFO" "WireGuard мониторинг отключен"
        fi
    else
        echo -e "\n${YELLOW}WireGuard интерфейсы не найдены${NC}"
        WG_IFACE=""
    fi
}

# Создание структуры директорий
create_directories() {
    log "INFO" "Создание структуры директорий..."
    
    # Основная директория
    mkdir -p "$BASE_DIR"
    chmod 755 "$BASE_DIR"
    
    # Директория для логов  
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    
    # Директория для клиентских конфигов WireGuard (если нужно)
    #mkdir -p /etc/wireguard/clients
    #chmod 700 /etc/wireguard/clients
    
    log "INFO" "Директории созданы"
}

# Создание базы данных SQLite
create_database() {
    log "INFO" "Создание базы данных SQLite..."
    
    # Удаляем старую БД если есть
    [ -f "$DB_PATH" ] && mv "$DB_PATH" "${DB_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Создаем таблицы
    sqlite3 "$DB_PATH" <<EOF
-- Таблица для статистики интерфейсов
CREATE TABLE interface_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME NOT NULL,
    iface TEXT NOT NULL,
    rx_bytes INTEGER,
    tx_bytes INTEGER,
    rx_packets INTEGER,
    tx_packets INTEGER,
    rx_errors INTEGER,
    tx_errors INTEGER,
    rx_drop INTEGER,
    tx_drop INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
EOF
    
    sqlite_safe "$DB_PATH" "CREATE INDEX IF NOT EXISTS idx_interface_stats_time ON interface_stats(timestamp, iface);" || true
    
    # Создаем таблицу для статистики WireGuard клиентов
    sqlite3 "$DB_PATH" <<EOF
CREATE TABLE wg_peers_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME NOT NULL,
    peer_key TEXT NOT NULL,
    peer_ip TEXT,
    peer_name TEXT,
    rx_bytes INTEGER,
    tx_bytes INTEGER,
    handshake_seconds INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
EOF
    
    sqlite_safe "$DB_PATH" "CREATE INDEX IF NOT EXISTS idx_wg_peers_time ON wg_peers_stats(timestamp, peer_key);" || true
    
    # Таблицы для агрегированной статистики
    sqlite3 "$DB_PATH" <<EOF
CREATE TABLE interface_stats_agg (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    iface TEXT NOT NULL,
    avg_rx_bytes REAL,
    avg_tx_bytes REAL,
    sum_rx_bytes INTEGER,
    sum_tx_bytes INTEGER,
    min_rx_bytes INTEGER,
    max_rx_bytes INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
EOF
    
    sqlite_safe "$DB_PATH" "CREATE INDEX IF NOT EXISTS idx_interface_stats_agg_time ON interface_stats_agg(timestamp, iface);" || true
    
    sqlite3 "$DB_PATH" <<EOF
CREATE TABLE wg_peers_agg (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    peer_key TEXT NOT NULL,
    peer_ip TEXT,
    peer_name TEXT,
    avg_rx_bytes REAL,
    avg_tx_bytes REAL,
    sum_rx_bytes INTEGER,
    sum_tx_bytes INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
EOF
    
    sqlite_safe "$DB_PATH" "CREATE INDEX IF NOT EXISTS idx_wg_peers_agg_time ON wg_peers_agg(timestamp, peer_key);" || true
    
    log "INFO" "База данных создана: $DB_PATH"
}

# Копирование скриптов
copy_scripts() {
    log "INFO" "Копирование скриптов в $BASE_DIR..."

    # Копируем основные скрипты
    cp nm-daemon.sh "$BASE_DIR/"
    cp nm-monitor.sh "$BASE_DIR/"
    cp nm-lib.sh "$BASE_DIR/"
    cp nm-config.env "$BASE_DIR/"
    cp nm-config-rules.sql "$BASE_DIR/"

    # Делаем скрипты исполняемыми
    chmod +x "$BASE_DIR/nm-daemon.sh"
    chmod +x "$BASE_DIR/nm-monitor.sh"
    chmod 644 "$BASE_DIR/nm-lib.sh"
    chmod 644 "$BASE_DIR/nm-config.env"
    chmod 644 "$BASE_DIR/nm-config-rules.sql"

    log "INFO" "Скрипты и конфигурация скопированы (v${VERSION})"
}
# Настройка логов

# Создание systemd сервиса
create_systemd_service() {
    log "INFO" "Создание systemd сервиса..."

    local service_file="/etc/systemd/system/nm-daemon.service"

    tee "$service_file" <<SERVICEEOF
# nm-daemon.service - systemd сервис для Network Monitor
# Версия: $VERSION
# Автор: TG: @smg38 smg38@yandex.ru

[Unit]
Description=Network Monitor Daemon
After=network.target network-online.target
Wants=network-online.target
Documentation=https://github.com/your-repo/network-monitor

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${BASE_DIR}
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=${BASE_DIR}/nm-config.env
ExecStart=${BASE_DIR}/nm-daemon.sh
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nm-daemon

# Лимиты ресурсов
LimitNOFILE=65536
LimitNPROC=65536
LimitCORE=infinity

# Безопасность
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=full
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes

[Install]
WantedBy=multi-user.target
SERVICEEOF

    chmod 644 "$service_file"
    log "INFO" "Сервис создан: $service_file"
}
setup_logging() {
    log "INFO" "Настройка логирования..."
    
    # Создаем конфиг для logrotate
    local logrotate_file="/etc/logrotate.d/network-monitor"
    
    cat > "$logrotate_file" <<EOF
$LOG_DIR/*.log {
    daily
    rotate $LOG_MAX_FILES
    maxsize ${LOG_MAX_SIZE}M
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        systemctl kill -s HUP nm-daemon.service >/dev/null 2>&1 || true
    endscript
}
EOF

    log "INFO" "Logrotate настроен"
}

# Функция удаления системы
uninstall_system() {
    echo -e "${BOLD}${RED}Удаление системы мониторинга сети${NC}\n"
    
    check_root
    setup_colors
    
    log "INFO" "Остановка сервиса..."
    systemctl stop nm-daemon.service 2>/dev/null || true
    systemctl disable nm-daemon.service 2>/dev/null || true
    
    log "INFO" "Удаление systemd сервиса..."
    rm -f /etc/systemd/system/nm-daemon.service
    systemctl daemon-reload
    
    log "INFO" "Удаление файлов..."
    rm -rf "$BASE_DIR"
    
    log "INFO" "Удаление завершено успешно!"
    rm -f /etc/logrotate.d/network-monitor
    rm -rf "$LOG_DIR"
    echo -e "\n${GREEN}${BOLD}Система мониторинга сети успешно удалена!${NC}"
}

# Функция обновления системы
update_system() {
    echo -e "${BOLD}${BLUE}Обновление системы мониторинга сети${NC}\n"
    
    check_root
    setup_colors
    
    # Проверяем, установлена ли система
    if [ ! -d "$BASE_DIR" ] || [ ! -f "$BASE_DIR/nm-config.sh" ]; then
        log "ERROR" "Система не установлена. Сначала выполните установку."
        exit 1
    fi
    
    log "INFO" "Остановка сервиса..."
    systemctl stop nm-daemon.service 2>/dev/null || true
    
    log "INFO" "Создание резервной копии базы данных..."
    if [ -f "$DB_PATH" ]; then
        cp "$DB_PATH" "${DB_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    log "INFO" "Обновление скриптов..."
    copy_scripts
    
    # Обновляем версию в БД
    if [ -f "$DB_PATH" ]; then
        sqlite3 "$DB_PATH" "UPDATE config SET value='$VERSION', updated_at=datetime('now') WHERE key='version';"
    fi
    
    log "INFO" "Перегенерация systemd сервиса..."
    create_systemd_service
    
    log "INFO" "Перезапуск сервиса..."
    systemctl daemon-reload
    systemctl start nm-daemon.service
    
    log "INFO" "Обновление конфигурации..."
    #log "INFO" "Обновление завершено успешно!"
    echo -e "\n${GREEN}${BOLD}Система мониторинга сети успешно обновлена до версии $VERSION !${NC}"
}

# Проверка установки
verify_installation() {
    log "INFO" "Проверка установки..."
    
    local errors=0
    
    # Проверяем наличие всех файлов
    [ -f "$BASE_DIR/nm-monitor.sh" ] || { log "ERROR" "nm-monitor.sh не найден"; errors=1; }
    [ -f "$BASE_DIR/nm-daemon.sh" ] || { log "ERROR" "nm-daemon.sh не найден"; errors=1; }
[ -f "$BASE_DIR/nm-config.env" ] || { log "ERROR" "nm-config.env не найден"; errors=1; }
    [ -f "$DB_PATH" ] || { log "ERROR" "База данных не найдена"; errors=1; }
    
    # Проверяем права
    [ -x "$BASE_DIR/nm-monitor.sh" ] || { log "ERROR" "nm-monitor.sh не исполняемый"; errors=1; }
    [ -x "$BASE_DIR/nm-daemon.sh" ] || { log "ERROR" "nm-daemon.sh не исполняемый"; errors=1; }
    
    if [ $errors -eq 0 ]; then
        log "INFO" "Установка завершена успешно!"
        echo -e "\n${GREEN}${BOLD}Установка успешно завершена!${NC}"
        echo -e "\n${BOLD}Для запуска демона выполните:${NC}"
        echo "  sudo systemctl enable --now nm-daemon.service"
        echo -e "\n${BOLD}Для просмотра статуса:${NC}"
        echo "  sudo systemctl status nm-daemon.service"
        echo -e "\n${BOLD}Для просмотра логов:${NC}"
        echo "  sudo journalctl -u nm-daemon.service -f"
        echo -e "\n${BOLD}Для работы с отчетами:${NC}"
        echo "  sudo $BASE_DIR/nm-monitor.sh --help"
    else
        log "ERROR" "Установка завершена с ошибками"
        exit 1
    fi
}

# Основная функция установки
main() {
    parse_args "$@"
    
    case "$ACTION" in
        "install")
            echo -e "${BOLD}${BLUE}Установка системы мониторинга сети версии $VERSION ${NC}\n"
            
            # Создаем директорию для логов сразу (для log())
            mkdir -p "$LOG_DIR"
            chmod 755 "$LOG_DIR"
            
            # ✅ ИСПРАВЛЕНО: source ДО setup_colors (2026-03-27)
            source "${SCRIPT_DIR}/nm-config.sh"
            check_root
            setup_colors
            check_dependencies
            select_interfaces
            create_directories
            create_database
            copy_scripts
            create_systemd_service
            setup_logging
            verify_installation
            ;;
        "uninstall")
            # Создаем директорию для логов ПЕРЕД check_root (фикс tee в log())
            mkdir -p /var/log/network-monitor 2>/dev/null || true
            chmod 755 /var/log/network-monitor 2>/dev/null || true
            
            check_root
            
            # Source config ПОСЛЕ check_root (SQLite ошибки подавлены)
            source "${SCRIPT_DIR}/nm-config.sh"
            setup_colors
            
            uninstall_system
            ;;
        "update")
            check_root
            
            # Создаем директорию для логов сразу после проверки root (для log())
            mkdir -p "$LOG_DIR" 2>/dev/null || true
            chmod 755 "$LOG_DIR" 2>/dev/null || true
            
            # ✅ ИСПРАВЛЕНО: source ДО setup_colors (2026-03-27)
            source "${SCRIPT_DIR}/nm-config.sh"
            setup_colors
            
            update_system
            ;;
    esac
}

# Запуск
main "$@"
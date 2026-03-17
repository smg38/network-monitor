
#!/bin/bash
# nm-install.sh - Установщик системы мониторинга сети  
# Версия: 1.4
# Автор: TG: @smg38 smg38@yandex.ru
# Запуск: ./nm-install.sh (от root, sudo НЕ нужен)

set -e  # Выход при ошибке

# Определяем директорию скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Загружаем конфигурацию
# shellcheck disable=SC1091
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
    
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_DIR}/install.log"
}

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
CREATE TABLE interfaces_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    data_type TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    interface TEXT NOT NULL,
    rx_bytes INTEGER,
    tx_bytes INTEGER,
    rx_packets INTEGER,
    tx_packets INTEGER,
    rx_errors INTEGER,
    tx_errors INTEGER,
    rx_drop INTEGER,
    tx_drop INTEGER,
    samples_count INTEGER DEFAULT 1,
    min_rx_rate INTEGER,
    max_rx_rate INTEGER,
    min_tx_rate INTEGER,
    max_tx_rate INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Таблица для статистики WireGuard клиентов
CREATE TABLE wg_peers_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    data_type TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    peer_key TEXT NOT NULL,
    peer_ip TEXT,
    peer_name TEXT,
    rx_bytes INTEGER,
    tx_bytes INTEGER,
    handshake_seconds INTEGER,
    samples_count INTEGER DEFAULT 1,
    min_rx_rate INTEGER,
    max_rx_rate INTEGER,
    min_tx_rate INTEGER,
    max_tx_rate INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Таблица для логирования задач демона
CREATE TABLE tasks_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_type TEXT NOT NULL,
    rule_key TEXT,
    started_at DATETIME,
    finished_at DATETIME,
    status TEXT,
    records_processed INTEGER,
    error_message TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Таблица для хранения конфигурации в БД
CREATE TABLE config (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Таблица для отслеживания последних запусков задач
CREATE TABLE task_last_run (
    task_key TEXT PRIMARY KEY,
    last_run DATETIME,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Индексы для оптимизации запросов
CREATE INDEX idx_interfaces_type_time ON interfaces_stats(data_type, timestamp);
CREATE INDEX idx_interfaces_iface_time ON interfaces_stats(interface, timestamp);
CREATE INDEX idx_peers_type_time ON wg_peers_stats(data_type, timestamp);
CREATE INDEX idx_peers_key_time ON wg_peers_stats(peer_key, timestamp);
CREATE INDEX idx_tasks_type_status ON tasks_log(task_type, status);
CREATE INDEX idx_tasks_time ON tasks_log(started_at);

-- Представление для удобных отчетов по интерфейсам
CREATE VIEW v_interface_daily AS
SELECT 
    date(timestamp) as day,
    interface,
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx,
    AVG(rx_bytes/300) as avg_rx_rate,
    AVG(tx_bytes/300) as avg_tx_rate,
    MAX(max_rx_rate) as peak_rx_rate,
    MAX(max_tx_rate) as peak_tx_rate
FROM interfaces_stats 
WHERE data_type = 'agg_5min'
GROUP BY date(timestamp), interface;

-- Представление для отчетов по клиентам
CREATE VIEW v_peers_daily AS
SELECT 
    date(timestamp) as day,
    peer_name,
    peer_ip,
    SUM(rx_bytes) as total_rx,
    SUM(tx_bytes) as total_tx,
    COUNT(DISTINCT date(timestamp)) as days_active
FROM wg_peers_stats 
WHERE data_type = 'agg_hour'
GROUP BY date(timestamp), peer_name, peer_ip;

EOF

    # Сохраняем конфигурацию в БД
    sqlite3 "$DB_PATH" <<EOF
INSERT INTO config (key, value) VALUES ('main_iface', '$MAIN_IFACE');
INSERT INTO config (key, value) VALUES ('wg_iface', '$WG_IFACE');
INSERT INTO config (key, value) VALUES ('install_date', datetime('now'));
INSERT INTO config (key, value) VALUES ('version', '1.4');
EOF

    chmod 644 "$DB_PATH"
    log "INFO" "База данных создана: $DB_PATH"
}

# Создание systemd сервиса
create_systemd_service() {
    log "INFO" "Создание systemd сервиса..."
    
    local service_file="/etc/systemd/system/nm-daemon.service"
    
    tee "$service_file" <<EOF
# nm-daemon.service - systemd сервис для Network Monitor
# Версия: 1.4.1
# Автор: TG: @smg38 smg38@yandex.ru

[Unit]
Description=Network Monitor Daemon
After=network.target network-online.target wg-quick@%i.service
Wants=network-online.target
Documentation=https://github.com/your-repo/network-monitor

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${BASE_DIR}
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=${BASE_DIR}/nm-config.sh
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
EOF

    log "INFO" "Сервис создан: $service_file"
}

# Копирование скриптов
copy_scripts() {
    log "INFO" "Копирование скриптов в $BASE_DIR..."
    
    # Копируем основной скрипт
    cp nm-monitor.sh "$BASE_DIR/"
    chmod 755 "$BASE_DIR/nm-monitor.sh"
    
    # Копируем демон
    cp nm-daemon.sh "$BASE_DIR/"
    chmod 755 "$BASE_DIR/nm-daemon.sh"
    
    # Копируем конфиг
    cp nm-config.sh "$BASE_DIR/"
    chmod 644 "$BASE_DIR/nm-config.sh"
    
    log "INFO" "Скрипты скопированы"
}

# Настройка логов
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
    rm -rf "$LOG_DIR"
    rm -f /etc/logrotate.d/network-monitor
    
    log "INFO" "Удаление завершено успешно!"
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
        sqlite3 "$DB_PATH" "UPDATE config SET value='1.4', updated_at=datetime('now') WHERE key='version';"
    fi
    
    log "INFO" "Перегенерация systemd сервиса..."
    create_systemd_service
    
    log "INFO" "Перезапуск сервиса..."
    systemctl daemon-reload
    systemctl start nm-daemon.service
    
    log "INFO" "Обновление конфигурации..."
    #log "INFO" "Обновление завершено успешно!"
    echo -e "\n${GREEN}${BOLD}Система мониторинга сети успешно обновлена до версии 1.4!${NC}"
}

# Проверка установки
verify_installation() {
    log "INFO" "Проверка установки..."
    
    local errors=0
    
    # Проверяем наличие всех файлов
    [ -f "$BASE_DIR/nm-monitor.sh" ] || { log "ERROR" "nm-monitor.sh не найден"; errors=1; }
    [ -f "$BASE_DIR/nm-daemon.sh" ] || { log "ERROR" "nm-daemon.sh не найден"; errors=1; }
    [ -f "$BASE_DIR/nm-config.sh" ] || { log "ERROR" "nm-config.sh не найден"; errors=1; }
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
            echo -e "${BOLD}${BLUE}Установка системы мониторинга сети v1.4${NC}\n"
            
            # Создаем директорию для логов сразу после проверки root
            mkdir -p "$LOG_DIR"
            chmod 755 "$LOG_DIR"
            
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
            check_root
            setup_colors
            
            # Создаем директорию для логов сразу после проверки root
            mkdir -p "$LOG_DIR" 2>/dev/null || true
            chmod 755 "$LOG_DIR" 2>/dev/null || true
            
            uninstall_system
            ;;
        "update")
            check_root
            setup_colors
            
            # Создаем директорию для логов сразу после проверки root
            mkdir -p "$LOG_DIR" 2>/dev/null || true
            chmod 755 "$LOG_DIR" 2>/dev/null || true
            
            update_system
            ;;
    esac
}

# Запуск
main "$@"
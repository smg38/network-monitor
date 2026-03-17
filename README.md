# Network Monitor v1.4

[![Автор](https://img.shields.io/badge/TG-@smg38-blue)](https://t.me/smg38)
[![Email](https://img.shields.io/badge/email-smg38%40yandex.ru-red)](mailto:smg38@yandex.ru)

## 🎯 Описание

**Промышленная система мониторинга сетевой активности** с многоуровневой агрегацией данных:
```
raw (5s/60s) → agg_5min → agg_hour → agg_day
```

**Архитектура:**
```
┌─────────────────┐    ┌──────────────┐    ┌─────────────┐
│ nm-install.sh   │───▶│ nm-daemon.sh │───▶│ nm-data.db  │
└─────────────────┘    └──────────────┘    └─────────────┘
                              ▲                    ▲
                              │                    │  
┌─────────────────┐    ┌──────────────┐    ┌─────────────┐
│   Пользователь  │───▶│ nm-monitor.sh│───▶│   Отчеты    │
└─────────────────┘    └──────────────┘    └─────────────┘
```

## 🚀 Быстрый старт

```bash
# 1. Установка
sudo ./nm-install.sh

# 2. Запуск демона
sudo systemctl enable --now nm-daemon.service

# 3. Проверка статуса
sudo nm-monitor.sh --status

# 4. Live мониторинг
sudo nm-monitor.sh --live
```

## 📊 Отчеты

| Команда | Описание |
|---------|----------|
| `sudo nm-monitor.sh --live` | Живой мониторинг (обновление 2с) |
| `sudo nm-monitor.sh --summary` | Сводка за сегодня |
| `sudo nm-monitor.sh --daily` | Почасовая разбивка за день |
| `sudo nm-monitor.sh --weekly` | Статистика за 7 дней |
| `sudo nm-monitor.sh --monthly` | Статистика за 30 дней |
| `sudo nm-monitor.sh --top 15` | Топ-15 клиентов |
| `sudo nm-monitor.sh --status` | Статус демона + БД |

## ⚙️ Конфигурация

`/opt/network-monitor/nm-config` - **центральный конфиг**:

```bash
# Интерфейсы
MAIN_IFACE="ens3"    # Основной
WG_IFACE="wg0"       # WireGuard

# Правила сбора (каждые N секунд)
COLLECT_RULES["5"]="сырые данные каждые 5с"
COLLECT_RULES["60"]="сырые данные каждую минуту"

# Правила агрегации
AGGREGATE_RULES["raw:300"]="agg_5min:300:5-минутная агрегация"
AGGREGATE_RULES["raw:3600"]="agg_hour:3600:часовая агрегация"

# Очистка (дней хранения)
CLEANUP_RULES["raw"]="7"
CLEANUP_RULES["agg_5min"]="30"
CLEANUP_RULES["agg_hour"]="90"
```

## 🗄️ База данных

**SQLite3** `/opt/network-monitor/nm-data.db`:

| Таблица | Описание |
|---------|----------|
| `interfaces_stats` | Статистика интерфейсов (raw + agg*) |
| `wg_peers_stats` | WireGuard клиенты с именами |
| `tasks_log` | Логи выполнения задач демона |
| `config` | Сохраненная конфигурация |
| `task_last_run` | Последние запуски задач |

## 🛠️ Структура проекта

```
/opt/network-monitor/     ← BASE_DIR
├── nm-config             ← Правила
├── nm-daemon.sh          ← Демон
├── nm-monitor.sh         ← Отчеты
├── nm-data.db            ← База
└── nm-install.sh         ← Установщик (копируется отдельно)

/var/log/network-monitor/ ← Логи
/etc/systemd/system/      ← nm-daemon.service
```

## 🔍 Управление

```bash
# Статус
sudo systemctl status nm-daemon.service
sudo journalctl -u nm-daemon.service -f

# Перезапуск
sudo systemctl restart nm-daemon.service

# Логи задач демона
sudo nm-monitor.sh --status

# Тест агрегации
sudo nm-monitor.sh --summary
```

## 🧪 Тестирование

```bash
sudo ./nm-tests.sh
```

## 📈 Масштабирование

**Горизонтальное:** Несколько серверов → Prometheus + Grafana
**Вертикальное:** Добавить метрики CPU/RAM/Disk

## 🔒 Безопасность

- systemd hardening (ProtectSystem=full, NoNewPrivileges)
- БД: 644 root:root
- Логи: logrotate + ротация

## 📞 Поддержка

**TG:** [@smg38](https://t.me/smg38)  
**Email:** smg38@yandex.ru

**Лицензия:** MIT

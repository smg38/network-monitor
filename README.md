# Network Monitor v1.6

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

**Правила в БД** `/opt/network-monitor/nm-data.db → config_rules`:

```bash
# Управление правилами (НЕ bash-код, SQLite!)
sqlite3 nm-data.db "UPDATE config_rules SET enabled=0 WHERE rule_key='5'"
sqlite3 nm-data.db "SELECT * FROM config_rules WHERE enabled=1"

# Примеры правил (v1.6):
# collect: 5s, 60s
# aggregate: raw→agg_5min(5min)→agg_hour(1h)→agg_day(1day)
# cleanup: raw=7d, agg_5min=30d, agg_hour=90d, agg_day=365d

# Простые переменные: nm-config.env
MAIN_IFACE="ens3"
WG_IFACE="wg0" 
LOG_LEVEL="INFO"

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
├── nm-config.env         ← Переменные env
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

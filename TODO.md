# TODO - План завершения Network Monitor v1.3

## ✅ Готово (v1.2)
- [x] Демон-сборщик с многоуровневой агрегацией  
- [x] Все правила: COLLECT/AGGREGATE/CLEANUP
- [x] Полная БД SQLite (таблицы + индексы + views)
- [x] Клиент nm-monitor.sh (все отчеты + live-режим)
- [x] Установщик nm-install.sh + systemd сервис

## 🔄 В работе (v1.3)
- [ ] 1. BASE_DIR="/opt/network-monitor" (все файлы)
- [ ] 2. Версия 1.3 + автор во всех файлах
- [ ] 3. README.md - документация
- [ ] 4. nm-tests.sh - юнит-тесты
- [ ] 5. Тестирование полной установки

## 📋 После v1.3
- [ ] `sudo ./nm-install.sh`
- [ ] `sudo systemctl enable --now nm-daemon.service`
- [ ] `sudo nm-monitor.sh --live --summary --status`
- [ ] `sudo journalctl -u nm-daemon.service -f`

**Автор:** TG: @smg38 smg38@yandex.ru
**Версия плана:** 1.3

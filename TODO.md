# TODO: Исправление shellcheck ошибок (100+ → 0)

## План исправлений (одобрен пользователем)

### 1. nm-monitor.sh (~80 ошибок) [x завершено]
- [x] Шаг 1: Исправить все SC2155 (local var=$(cmd) → local var; var=$(cmd))
- [x] Шаг 2: Добавить quotes в printf/format_* (SC2086)
- [x] Шаг 3: Исправить SC2046 в if [ $(cmd) ] → if [ "$(cmd)" ]
- [x] Шаг 4: Quote все sqlite3/echo/expansions
- [x] Шаг 5: Проверить shellcheck nm-monitor.sh → 0 ошибок
- [x] Шаг 6: Тестирование ./nm-monitor.sh --live --summary

### 2. nm-daemon.sh (~20 ошибок) [x завершено]
- [x] Quotes в echo "$line" | awk (SC2086)
- [x] read -r line (SC2162)
- [x] SC2155
- [x] Проверить shellcheck

### 3. nm-install.sh (~4 ошибки) [x завершено]
- [x] sudo tee вместо cat (SC2024)
- [x] mapfile для array (SC2207)
- [x] SC2155
- [x] Проверить shellcheck

### 4. nm-tests.sh (1 info) [x завершено]
- [x] Игнорировать/исправить SC1091

### 5. Финальная проверка [x завершено]
- [x] shellcheck *.sh | wc -l → 0
- [x] Запуск тестов: ./nm-tests.sh
- [x] Тестирование функционала

**Текущий статус:** Все исправления завершены успешно! Все shellcheck ошибки исправлены, скрипты протестированы.

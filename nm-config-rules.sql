-- nm-config-rules.sql - Правила мониторинга в формате SQLite (Версия 1.6)
-- Автоматически импортируется при установке nm-install.sh
-- Гибкая настройка без рестарта демона и правки кода!

-- Таблица правил конфигурации
CREATE TABLE IF NOT EXISTS config_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_type TEXT NOT NULL CHECK(rule_type IN ('collect', 'aggregate', 'cleanup')),  -- Тип правила
    rule_key TEXT NOT NULL UNIQUE,                    -- Ключ правила ("5", "raw:300")
    description TEXT NOT NULL,                        -- Описание
    interval_sec INTEGER NOT NULL DEFAULT 60,         -- Интервал запуска (сек)
    window_sec INTEGER DEFAULT NULL,                  -- Окно агрегации (сек, только для aggregate)
    retention_days INTEGER DEFAULT NULL,              -- Хранение данных (дни, только для cleanup)
    enabled BOOLEAN DEFAULT 1,                        -- Включено/выключено
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ========================================
-- ПРАВИЛА СБОРА ДАННЫХ (collect)
-- ========================================
INSERT OR REPLACE INTO config_rules (rule_type, rule_key, description, interval_sec, enabled) VALUES
('collect', '5',   'Сбор сырых данных каждые 5 секунд (интерфейсы + WG клиенты)',  5,   1),
('collect', '60',  'Сбор сырых данных каждую минуту (интерфейсы + WG клиенты)',   60,  1);

-- ========================================
-- ПРАВИЛА АГРЕГАЦИИ (aggregate) 
-- Формат rule_key: "input_type:window_sec"
-- ========================================
INSERT OR REPLACE INTO config_rules (rule_type, rule_key, description, interval_sec, window_sec, enabled) VALUES
('aggregate', 'raw:300',             'Агрегация 5мин из raw (каждые 5мин)',                     300, 300, 1),
('aggregate', 'raw:3600',            'Агрегация час из raw (каждый час)',                         3600, 3600, 1),
('aggregate', 'agg_5min:3600',       'Агрегация час из 5мин-агрегатов (каждый час)',              3600, 3600, 1),
('aggregate', 'agg_hour:86400',      'Агрегация сутки из часовых (раз в день)',                   86400, 86400, 1);

-- ========================================
-- ПРАВИЛА ОЧИСТКИ (cleanup)
-- Формат rule_key: "data_type"
-- ========================================
INSERT OR REPLACE INTO config_rules (rule_type, rule_key, description, interval_sec, retention_days, enabled) VALUES
('cleanup', 'raw',              'Очистка raw-данных (7 дней)',              3600, 7,   1),
('cleanup', 'agg_5min',         'Очистка 5мин-агрегатов (30 дней)',        3600, 30,  1),
('cleanup', 'agg_hour',         'Очистка часовых агрегатов (90 дней)',     3600, 90,  1),
('cleanup', 'agg_hour_from_5min','Очистка часовых из 5мин (90 дней)',      3600, 90,  1),
('cleanup', 'agg_day',          'Очистка суточных агрегатов (365 дней)',   86400, 365, 1);

-- Индексы для оптимизации
CREATE INDEX IF NOT EXISTS idx_rules_type_key ON config_rules(rule_type, rule_key);
CREATE INDEX IF NOT EXISTS idx_rules_enabled ON config_rules(enabled, rule_type);

-- ========================================
-- ПРИМЕРЫ ИСПОЛЬЗОВАНИЯ (запускайте от root)
-- ========================================
/*
-- ✅ Включить/выключить правило
UPDATE config_rules SET enabled=1 WHERE rule_key='5';

-- ✅ Изменить интервал сбора
UPDATE config_rules SET interval_sec=10 WHERE rule_key='5';  

-- ✅ Добавить новое правило агрегации (15мин из raw)
INSERT INTO config_rules (rule_type, rule_key, description, interval_sec, window_sec) 
VALUES ('aggregate', 'raw:900', 'Агрегация 15мин из raw', 900, 900);

-- ✅ Посмотреть активные правила
SELECT * FROM config_rules WHERE enabled=1 ORDER BY rule_type, interval_sec;

-- ✅ Статистика использования правил (из tasks_log)
SELECT rule_key, COUNT(*) as executions 
FROM tasks_log WHERE status='success' 
GROUP BY rule_key ORDER BY executions DESC;
*/


# Проверка в игре (v52 – v57)

Офлайн-проверки (`luajit -bl`, `luacheck`, `luajit tests/run.lua`) ловят синтаксис и логику модулей. Поведение чита они не проверяют, поэтому ниже — то, что нужно проверить руками.

Чтобы я мог разобрать результат, пришлите вывод консоли из шагов 1, 2 и 9.

## 1. Загрузка
1. Загрузить `eclipse.lua`. В консоли должна быть строка `[ECLIPSE] 2.0 beta (v57) loaded`.
2. `/eclipse selftest` → `[FAIL] 0`. Посмотрите строки `info`:
   - `your hitchance readable under override` — включите Adaptive hitchance и дождитесь, пока скрипт поднимет hitchance (`/eclipse why` → у hitchance источник `adaptive`). Затем выполните selftest ещё раз:
     - `yes …` — база adaptive / lag hitchance следует за вашим значением в меню;
     - `cannot tell` — работает как в v52, база остаётся последней увиденной;
   - если есть WARN `profiler timer`, `/eclipse perf` и бюджет скана AI Peek не работают — сообщите мне.
3. `/eclipse selftest release` → `full release … everything returned to your settings`.

## 2. Нагрузка
- `/eclipse perf 30` во время раунда, в бою. Ожидается: `script per tick` ≤ 1.0 ms и `all modules within budget`. Если есть WARN, пришлите строки модулей.

## 3. Смена карты (исправление v52)
- Включите Auto OS (`ex.autos`) и Break LC (`ex.brk`). Доиграйте карту и дождитесь следующей.
- На новой карте:
  - DT заряжается;
  - на прицеле нет постоянных `AUTO OS`, `BREAK LC`, `DEFENSIVE`;
  - Prefer body работает (`/eclipse why` не показывает `enemy on-shot` без причины).

## 4. Журнал решений и откаты (v52, v54)
- Сыграйте 5–10 раундов, затем `/eclipse decisions`. Должны появиться вердикты `BETTER` / `WORSE` / `SAME` у записей видов `strat`, `aa` и `phase`; у откатов — пометка `+RB`.
- Если откаты мешают: `/eclipse cfg verify.rollback 0`. Тогда вердикты пишутся, но откатов нет.

## 5. Сохранение обучения (v52, v53)
1. После 2–3 раундов `/eclipse db` → строка `last save … (changed only): N key(s) written, M unchanged skipped`.
2. `/eclipse save` → `saved: N key(s), … KB, … ms`.
3. Перезагрузите скрипт 2–3 раза подряд, затем `/eclipse strat`: оценки стратегий не падают после каждой перезагрузки.
4. На прицеле нет `DB FULL: LEARNING NOT SAVED`.

## 6. Dormant aimbot (v52)
На ботах за стеной (`main.bots` не нужен — это не обучение):
- прицел не дёргается между выстрелами (точка — грудь, живот или таз);
- после 2 с без обновления позиции (слайдер `record timeout` = 2.0) скрипт не стреляет;
- **проверьте, видно ли поворот камеры при выстреле.** Тихий ли `cmd.view_angles`, по документации неизвестно.

## 7. AI Peek (v53)
- Зажмите клавишу у угла. Индикатор кратко показывает `PEEK: scanning...`, затем `peeking …`, FPS не проседает.

## 8. Консоль (v53)
- `/eclipse help` — список команд.
- `/eclipse why` с включённым Ideal tick → строка `other cheat items held by the script: ex.dt=true …`.

## 8a. Ошибки в консоли (v56)
- Поиграйте с включёнными «Resolver info above enemies» и «Debug panel», в том числе когда игроки выходят с сервера и меняется карта. Строк `frame:effects error: entity is invalid` быть не должно.

## 9. Что прислать мне
```
/eclipse selftest
/eclipse perf 30
/eclipse db
/eclipse decisions 20
```

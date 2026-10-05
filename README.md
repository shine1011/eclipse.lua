# ECLIPSE

Lua-скрипт для Neverlose (CS:GO legacy). Ранее назывался Rage AA Pro 2.

- `eclipse.lua` — скрипт, единственный файл. Его загружаете в Neverlose. Версия записана в `RAP.VERSION`.
- `CHANGELOG.md` — изменения по версиям.
- `AUDIT_v51.md` — аудит v51 и статус пунктов.

## Проверка перед загрузкой в игру

Поведение в игре проверяется только в игре. Эти проверки ловят синтаксис, ошибки статического анализа и регрессии логики.

```bash
luajit -bl eclipse.lua > /dev/null && echo SYNTAX_OK   # синтаксис LuaJIT
luacheck .                                              # статический анализ, конфиг в .luacheckrc
luajit tests/run.lua                                    # офлайн-тесты логики на заглушках API (нужен lua-cjson)
```

Все три проверки запускаются в GitHub Actions на каждый push.

## В игре

- `/eclipse help` — список команд.
- `/eclipse selftest` — самопроверка, ожидается 0 FAIL.
- `/eclipse perf 30` — нагрузка по модулям.
- `/eclipse why` — кто и почему изменил настройки чита.

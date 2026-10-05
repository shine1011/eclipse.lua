--[[
    ECLIPSE (2.0 beta, v53) — скрипт для Neverlose (CS:GO legacy). Ранее назывался Rage AA Pro 2.
    Внутренние имена (таблица RAP, ключи базы rap2_*) сохранены: так переносится все накопленное обучение.
    Модули: core / api (пункты чита, арбитр) / menu / world / shots / telemetry / rage (classifier, brain, resolver,
    голосование) / AA (refs, профили, меню, движок, AI, эволюция) / visuals / lag / exploits / dormant / AI peek /
    grenades / misc / presets / console. Исходник - этот единственный файл (eclipse.lua); версия - RAP.VERSION и GitHub Releases.

    Устройство: весь код в таблице RAP, каждый модуль - отдельный блок do ... end и публикует только то, что нужно
    другим (RAP.<модуль>). Порядок работы за тик: world -> shots -> модули голосуют в арбитр -> arbiter.commit().
    Ни один модуль не вызывает override напрямую для рагебот-пунктов: только RAP.vote(). Это убирает "войну"
    переопределений, а /eclipse why показывает, кто какое решение принял.
]]
local RAP = { NAME = "ECLIPSE", VERSION = "2.0 beta (v53)", mods = {}, tick = {}, frame = {}, hooks = {}, cmd = {}, resets = {} }

---------------------------------------------------------------- util
do
    local U = {}
    local abs, floor, max, min = math.abs, math.floor, math.max, math.min
    U.abs, U.floor, U.max, U.min, U.sqrt = abs, floor, max, min, math.sqrt
    function U.clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
    function U.lerp(a, b, t) return a + (b - a) * U.clamp(t, 0, 1) end
    function U.norm(y) y = y % 360; if y > 180 then y = y - 360 end; return y end
    function U.round(v) return floor(v + 0.5) end
    function U.rand(a, b) return utils.random_int(a, b) end
    function U.randn()
        local u1 = utils.random_int(1, 100000) / 100001
        local u2 = utils.random_int(0, 100000) / 100000
        return U.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
    end
    -- число из базы: nil для не-числа / NaN / бесконечности, иначе зажато в [lo, hi]
    function U.num(v, lo, hi)
        v = tonumber(v)
        if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
        if lo and v < lo then v = lo end
        if hi and v > hi then v = hi end
        return v
    end
    function U.has(list, v)
        if type(list) ~= "table" then return false end
        for _, x in ipairs(list) do if x == v then return true end end
        return false
    end
    -- ошибки модулей: печать раз в 10 с на ключ, счетчик для selftest
    U.errors = {}
    function U.safe(key, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then
            local e = U.errors[key]
            local now = globals.realtime
            if not e then e = { n = 0, t = -99 }; U.errors[key] = e end
            e.n, e.msg = e.n + 1, tostring(err)
            if now - e.t > 10 then e.t = now; print("[eclipse] " .. key .. " error: " .. tostring(err)) end
        end
        return ok, err
    end
    function U.log(tag, fmt, ...) print(string.format("[%s] " .. fmt, tag, ...)) end
    -- поле объекта чита под pcall без замыкания: pcall(U.getf, obj, k) / pcall(U.setf, obj, k, v)
    function U.getf(o, k) return o[k] end
    function U.setf(o, k, v) o[k] = v end
    -- текущее значение hitchance на вкладке текущего оружия (для базы adaptive / lag hc)
    function U.hc_cur() local P = RAP.ref.rage.hitchance; return P and P.cur():get() end
    RAP.U = U
end

---------------------------------------------------------------- store (db + json)
do
    -- Защита данных: поврежденная запись -> резервная копия (последняя успешно прочитанная версия прошлой сессии),
    -- запись больше LIMIT отклоняется (база не раздувается), первая запись за сессию сохраняет старое значение в <key>_bak.
    -- near: ключи больше 75% лимита (предупреждение в selftest до того, как запись начнут отклонять)
    -- dirty: ключи, данные которых менялись с прошлой записи. Плановое сохранение (начало раунда / смерть) пишет
    -- только их; при выгрузке и /eclipse save пишется все (force). io: статистика последнего сохранения.
    local S = { raw = {}, bak_done = {}, LIMIT = 768 * 1024, corrupted = {}, rejected = {}, near = {}, warned = {}, dirty = {},
        io = { n = 0, bytes = 0, ms = 0, skipped = 0 } }
    function S.mark(key) S.dirty[key] = true end
    -- нужно ли писать ключ в этом сохранении; false - пропуск (учитывается в статистике)
    function S.need(key, force)
        if force or S.dirty[key] then return true end
        S.io.skipped = S.io.skipped + 1
        return false
    end
    local function parse(raw)
        if type(raw) ~= "string" or raw == "" then return nil end
        local ok, v = pcall(json.parse, raw)
        return (ok and type(v) == "table") and v or nil
    end
    function S.get(key)
        local ok, raw = pcall(function() return db[key] end)
        if not ok then return nil end
        local v = parse(raw)
        if v then S.raw[key] = raw; return v end
        if type(raw) == "string" and raw ~= "" then
            local okb, rb = pcall(function() return db[key .. "_bak"] end)
            local vb = okb and parse(rb) or nil
            S.corrupted[key] = vb and "restored from backup" or "lost"
            print(string.format("[eclipse] db '%s' is corrupted%s", key, vb and " - restored from backup" or ", starting fresh"))
            if vb then S.raw[key] = rb end
            return vb
        end
        return nil
    end
    function S.set(key, val)
        return RAP.U.safe("db " .. key, function()
            if val == nil then db[key] = nil; S.raw[key] = nil; return end
            local s = json.stringify(val)
            if type(s) ~= "string" then return end
            if #s > S.LIMIT then
                S.rejected[key] = #s
                print(string.format("[eclipse] db '%s' not saved: %.0f KB is over the %.0f KB limit", key, #s / 1024, S.LIMIT / 1024))
                -- раньше только print: обучение молча переставало сохраняться
                if not S.warned[key] and RAP.toast then S.warned[key] = true; RAP.toast("Learning NOT saved: " .. key .. " is too big (/eclipse selftest)") end
                return
            end
            S.rejected[key] = nil
            S.near[key] = #s > S.LIMIT * 0.75 and #s or nil
            S.dirty[key] = nil
            S.io.n, S.io.bytes = S.io.n + 1, S.io.bytes + #s
            if not S.bak_done[key] and S.raw[key] then db[key .. "_bak"] = S.raw[key] end
            S.bak_done[key] = true
            db[key] = s
        end)
    end
    S.parse = parse
    RAP.store = S
end

---------------------------------------------------------------- CFG: все пороги моделей в одном месте
-- Меняются без правки кода: /eclipse cfg <путь> <значение> (сохраняется в db), /eclipse cfg - список, /eclipse cfg reset.
do
    local DEF = {
        strategy = {
            confidence = 0.75,     -- переключение, только если P(другая стратегия лучше текущей) >= этого
            min_samples = 2,       -- до стольких учтенных выстрелов по текущей стратегии - не переключаемся по статистике
            explore = 0.15,        -- доля решений "попробовать другую стратегию" (exploration)
            panic_misses = 3,      -- столько учтенных промахов подряд по цели -> смена на следующую по оценке
            prior_weight = 10,     -- вес опыта против всех врагов (популяции) для нового врага, в выстрелах
            decay = 0.985,         -- затухание старых результатов по врагу на каждый новый выстрел
            pop_decay = 0.995,     -- затухание популяционной статистики
            aat_bias = 2,          -- стартовый бонус: jitter -> safe point, wide -> body (в псевдо-попаданиях)
            half_life_days = 7,    -- сохраненный опыт по врагу теряет половину веса за столько дней
            session_weight = 3,    -- результаты текущей сессии против этого врага весят во столько раз больше
            explore_probing = 0.08,-- доля экспериментов в состояниях UNKNOWN / PROBING / RELEARNING
            explore_confident = 0.02, -- в состоянии CONFIDENT
            confident_p = 0.75,    -- P(лучшая стратегия лучше второй) для перехода в CONFIDENT
            relearn_shots = 6,     -- выстрелов в RELEARNING после провала уверенной стратегии / смены AA врага
            explore_cooldown = 5,  -- после эксперимента столько учтенных выстрелов без новых экспериментов
            equal_margin = 0.05,   -- стратегии с оценкой ближе этого считаются равными (не "лучшая навсегда")
            arms = "1,4,5,6",      -- активные стратегии: 1 Default 2 Head focus 3 Small mp 4 Prefer safe 5 Force safe 6 Prefer body 7 Force body
        },
        aat = {
            window = 24,           -- замеров для классификатора AA
            jitter_flips = 6,      -- смен стороны в окне -> JITTER
            flip_deg = 25,         -- скачок eye yaw, считающийся сменой
            wide = 42,             -- средний |eye - abs| для WIDE
            hold = 0.5,            -- новый тип AA принимается, только если держится столько секунд
            change_conf = 0.5,     -- смена типа AA запускает RELEARNING только при уверенности классификатора >= этого
        },
        -- веса атрибуции: сколько выстрел говорит о решении (0..1). Меняются: /eclipse cfg attr.<имя> <значение>; журнал - /eclipse journal
        attr = {
            correction = 1.0,      -- твой промах correction: о стратегии
            misprediction = 0.5,
            prediction_error = 0.35,
            burst = 0.3,           -- второй выстрел DT-серии (тот же стрелок, < 0.35 с): не независимая выборка
            body_hit = 0.6,        -- попадание по тебе в тело: мало зависит от yaw / десинка
            body_hit_sniper = 0.4,
            untracked = 0.7,       -- попадание без записи выстрела (направление неизвестно)
            light_dodge = 0.6,     -- уворот от пистолета / smg / дробовика: часто это их разброс
            fs = 0.5,              -- freestanding заменял yaw профиля
        },
        -- проверка решений: после смены сравнивается окно "после" с оценкой оставленного варианта
        verify = {
            strat_n = 6,           -- эффективных выборок после смены стратегии до вердикта
            aa_n = 5,              -- то же для профиля AA / phase shift
            max_n = 15,            -- без явной разницы к этому моменту -> "без изменений"
            p = 0.8,               -- P(после хуже / лучше) для вердикта
            block_s = 300,         -- откаченный вариант не выбирается снова столько секунд
            rollback = 1,          -- 1 = откатывать смены с вердиктом "хуже", 0 = только записывать
        },
        shots = { near = 60, inacc_drop = 0.4 },
        peek = { scan_ms = 1.5 },        -- AI Peek: время скана за тик (мс), остаток направлений - на следующих тиках
        dormant = { hit_radius = 16 },   -- радиус (юниты) вокруг точки, попадание в который считается попаданием (оценка HC)
        log = { keep = 600 },      -- выстрелов в журнале (для сравнения версий)
        db = { schema = 50 },
    }
    local saved = RAP.store.get("rap2_cfg") or {}
    local CFG = {}
    for sec, t in pairs(DEF) do
        CFG[sec] = {}
        for k, v in pairs(t) do
            local sv = type(saved[sec]) == "table" and saved[sec][k]
            CFG[sec][k] = (type(sv) == type(v)) and sv or v
        end
    end
    RAP.CFG, RAP.CFG_DEF = CFG, DEF
    function RAP.cfg_set(path, val)
        local sec, key = tostring(path):match("^(%w+)%.([%w_]+)$")
        if not sec or not DEF[sec] or DEF[sec][key] == nil then return false, "unknown key" end
        local num = tonumber(val)
        if type(DEF[sec][key]) == "number" then
            if not num then return false, "number expected" end
            CFG[sec][key] = num
        else CFG[sec][key] = val end
        local out = {}
        for s2, t in pairs(CFG) do
            out[s2] = {}
            for k, v in pairs(t) do if v ~= DEF[s2][k] then out[s2][k] = v end end
        end
        RAP.store.set("rap2_cfg", out)
        return true
    end
    function RAP.cfg_reset()
        for s2, t in pairs(DEF) do for k, v in pairs(t) do CFG[s2][k] = v end end
        RAP.store.set("rap2_cfg", nil)
    end
end

---------------------------------------------------------------- hooks: модули регистрируют функции по фазам
do
    local seq = 0
    -- phase: "tick" (createmove), "frame" (render), "round", "save", "shutdown", "level"
    -- Сортировка стабильная (prio, затем порядок регистрации): table.sort в Lua нестабилен, и хуки с одинаковым
    -- prio раньше могли выполняться в случайном порядке.
    function RAP.on(phase, name, fn, prio)
        local list = RAP.hooks[phase]
        if not list then list = {}; RAP.hooks[phase] = list end
        seq = seq + 1
        list[#list + 1] = { name = name, fn = fn, prio = prio or 50, seq = seq, key = phase .. ":" .. name }
        table.sort(list, function(a, b) if a.prio ~= b.prio then return a.prio < b.prio end return a.seq < b.seq end)
    end
    -- профилировщик: /eclipse perf [сек] включает замер (по умолчанию выключен - ноль накладных расходов).
    -- На модуль: вызовы, сумма, максимум, ошибки и до 400 последних замеров для p95.
    local clock = (os and os.clock) or nil
    local clock_src = clock and "os.clock" or nil
    -- docs: common.get_timestamp - "high precision timestamp in milliseconds"
    if not clock then pcall(function() local f = common.get_timestamp; if f and f() then clock = function() return f() / 1000 end; clock_src = "common.get_timestamp" end end) end
    RAP.prof = { on = false, until_t = 0, d = {}, clock = clock, clock_src = clock_src or "none (perf and AI Peek budget off)" }
    -- tick / frame: на время прохода значения пунктов меню кэшируются (RAP.v вызывается сотни раз за тик,
    -- каждый раз с pcall). Вне прохода (колбэки меню, кнопки) кэша нет - всегда свежие значения.
    local function run_list(list, ...)
        local P = RAP.prof
        if P.on and clock then
            for i = 1, #list do
                local h = list[i]
                local key = h.key
                local t0 = clock()
                local ok = RAP.U.safe(key, h.fn, ...)
                local dt = (clock() - t0) * 1000
                local e = P.d[key]
                if not e then e = { n = 0, sum = 0, max = 0, err = 0, s = {}, si = 0 }; P.d[key] = e end
                e.n, e.sum, e.max = e.n + 1, e.sum + dt, math.max(e.max, dt)
                if not ok then e.err = e.err + 1 end
                e.si = e.si % 400 + 1
                e.s[e.si] = dt
            end
            return
        end
        for i = 1, #list do RAP.U.safe(list[i].key, list[i].fn, ...) end
    end
    -- кэш значений меню на проход: одна таблица, очищается table.clear (LuaJIT), если он доступен в песочнице -
    -- иначе новая таблица на проход, как раньше
    local okc, tclear = pcall(require, "table.clear")
    if not okc or type(tclear) ~= "function" then tclear = nil end
    local VC = {}
    function RAP.run(phase, ...)
        local list = RAP.hooks[phase]
        if not list then return end
        local top = (phase == "tick" or phase == "frame") and not RAP.vcache
        if top then
            if tclear then tclear(VC) else VC = {} end
            RAP.vcache = VC
        end
        run_list(list, ...)
        if top then RAP.vcache = nil end
    end
    -- сравнение значений пунктов: таблицы (мультивыбор) - по содержимому, а не по ссылке
    function RAP.U.same(a, b)
        if a == b then return true end
        if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
        for i = 1, #a do if a[i] ~= b[i] then return false end end
        return true
    end
end
---------------------------------------------------------------- refs: пункты меню чита
do
    local R = { missing = {} }
    local function find(...)
        local ok, it = pcall(ui.find, ...)
        return ok and it or nil
    end
    R.find = find
    R.WSUB = { "Global", "SSG-08", "AWP", "AutoSnipers", "Desert Eagle", "R8 Revolver", "Pistols", "SMGs", "Rifles",
        "Shotguns", "Machineguns" }
    R.WIDX_SUB = { [40] = "SSG-08", [9] = "AWP", [11] = "AutoSnipers", [38] = "AutoSnipers", [1] = "Desert Eagle",
        [64] = "R8 Revolver", [2] = "Pistols", [3] = "Pistols", [4] = "Pistols", [30] = "Pistols", [32] = "Pistols",
        [36] = "Pistols", [61] = "Pistols", [63] = "Pistols", [17] = "SMGs", [19] = "SMGs", [23] = "SMGs", [24] = "SMGs",
        [26] = "SMGs", [33] = "SMGs", [34] = "SMGs", [7] = "Rifles", [8] = "Rifles", [10] = "Rifles", [13] = "Rifles",
        [16] = "Rifles", [39] = "Rifles", [60] = "Rifles", [25] = "Shotguns", [27] = "Shotguns", [29] = "Shotguns",
        [35] = "Shotguns", [14] = "Machineguns", [28] = "Machineguns" }

    -- рагебот-пункт = Global + все вкладки оружия. override идет во все, get() - вкладка текущего оружия
    local function multi(path_group, path_item, path_sub)
        local items, n = {}, 0
        for _, w in ipairs(R.WSUB) do
            local it
            if path_sub then it = find("Aimbot", "Ragebot", path_group, w, path_item, path_sub)
            else it = find("Aimbot", "Ragebot", path_group, w, path_item) end
            if it then items[w], n = it, n + 1 end
        end
        local base = path_sub and find("Aimbot", "Ragebot", path_group, path_item, path_sub)
            or find("Aimbot", "Ragebot", path_group, path_item)
        if n == 0 and not base then return nil, 0 end
        local all, seen = {}, {}
        if base then all[1], seen[base] = base, true end
        for _, w in ipairs(R.WSUB) do local it = items[w]; if it and not seen[it] then all[#all + 1], seen[it] = it, true end end
        local first = all[1]
        local name
        pcall(function() name = first:name() end)
        local P = { items = items, all = all, label = path_sub or path_item, name = name }
        function P.cur() return (RAP.W and RAP.W.wsub and items[RAP.W.wsub]) or first end
        function P.get() return P.cur():get() end
        function P.list() local ok, l = pcall(first.list, first); return ok and l or nil end
        function P.set_override(v)
            for _, it in ipairs(all) do
                if v == nil then pcall(it.override, it) else pcall(it.override, it, v) end
            end
        end
        return P, n
    end
    R.multi = multi

    R.rage = {}
    R.tabs = {}
    for key, p in pairs({
        min_damage = { "Selection", "Min. Damage" }, hitchance = { "Selection", "Hit Chance" },
        hitboxes = { "Selection", "Hitboxes" }, mp_head = { "Selection", "Multipoint", "Head Scale" },
        mp_body = { "Selection", "Multipoint", "Body Scale" }, safe_points = { "Safety", "Safe Points" },
        body_aim = { "Safety", "Body Aim" }, multipoint = { "Selection", "Multipoint" },
        ensure_safety = { "Safety", "Ensure Hitbox Safety" },
    }) do
        local P, n = multi(p[1], p[2], p[3])
        R.rage[key], R.tabs[key] = P, n
        if not P then R.missing[#R.missing + 1] = "rage." .. key end
    end
    R.dt = find("Aimbot", "Ragebot", "Main", "Double Tap")
    R.hs = find("Aimbot", "Ragebot", "Main", "Hide Shots")
    R.slow_walk = find("Aimbot", "Anti Aim", "Misc", "Slow Walk")
    R.fake_duck = find("Aimbot", "Anti Aim", "Misc", "Fake Duck")
    R.peek_assist = find("Aimbot", "Ragebot", "Main", "Peek Assist")
    R.thirdperson_dist = find("Visuals", "World", "Main", "Force Thirdperson", "Distance")
    R.dt_lag = find("Aimbot", "Ragebot", "Main", "Double Tap", "Lag Options")
    R.hs_opt = find("Aimbot", "Ragebot", "Main", "Hide Shots", "Options")
    R.leg = find("Aimbot", "Anti Aim", "Misc", "Leg Movement")
    R.autoscope = find("Aimbot", "Ragebot", "Accuracy", "Auto Scope")
    R.airstrafe = find("Miscellaneous", "Main", "Movement", "Air Strafe")
    R.js_stop = find("Aimbot", "Ragebot", "Accuracy", "SSG-08", "Auto Stop")
    R.js_opts = find("Aimbot", "Ragebot", "Accuracy", "SSG-08", "Auto Stop", "Options")
    R.dormant = find("Aimbot", "Ragebot", "Main", "Enabled", "Dormant Aimbot")
    R.ext = find("Aimbot", "Anti Aim", "Angles", "Extended Angles")
    R.ext_pitch = find("Aimbot", "Anti Aim", "Angles", "Extended Angles", "Extended Pitch")
    R.ext_roll = find("Aimbot", "Anti Aim", "Angles", "Extended Angles", "Extended Roll")
    -- переопределение произвольного пункта с учетом владения: RAP.own(key, item, value), value = nil - снять
    local OWNED = {}
    function RAP.own(key, item, val)
        if not item then return end
        local o = OWNED[key]
        if val == nil then
            if o then pcall(item.override, item); OWNED[key] = nil end
            return
        end
        if o and RAP.U.same(o.v, val) then return end
        if pcall(item.override, item, val) then OWNED[key] = { v = val, item = item } end
    end
    function RAP.own_release_all() for k, o in pairs(OWNED) do pcall(o.item.override, o.item); OWNED[k] = nil end end
    function RAP.own_list() return OWNED end
    function R.on(item) if not item then return false end local ok, v = pcall(item.get, item); return ok and v and true or false end

    -- варианты пунктов (строки) берутся из :list(), а не угадываются
    function R.option(P, word)
        local l = P and P.list() or nil
        if type(l) ~= "table" or #l == 0 then return word:sub(1, 1):upper() .. word:sub(2) end
        for _, v in ipairs(l) do if tostring(v):lower():find(word, 1, true) then return v end end
        return nil
    end
    R.OPT = {
        sp_prefer = R.option(R.rage.safe_points, "prefer"), sp_force = R.option(R.rage.safe_points, "force"),
        ba_prefer = R.option(R.rage.body_aim, "prefer"), ba_force = R.option(R.rage.body_aim, "force"),
        ba_default = R.option(R.rage.body_aim, "default"), sp_default = R.option(R.rage.safe_points, "default"),
    }
    RAP.ref = R
end

---------------------------------------------------------------- binds пользователя
do
    local B = { t = -1, active = {}, toggle = {} }
    function B.refresh()
        local now = globals.realtime
        if now - B.t < 0.1 then return end
        B.t, B.active, B.toggle = now, {}, {}
        pcall(function()
            for _, bd in ipairs(ui.get_binds() or {}) do
                local n = bd.name and tostring(bd.name)
                if n then
                    if bd.active then B.active[n] = true end
                    if bd.mode == 2 then B.toggle[n] = true end
                end
            end
        end)
    end
    function B.is_active(name) B.refresh(); return name ~= nil and B.active[name] == true end
    function B.is_toggle(name) B.refresh(); return name ~= nil and B.toggle[name] == true end
    RAP.binds = B
end

---------------------------------------------------------------- арбитр рагебота
-- Каждый тик модули голосуют: RAP.vote(key, value, prio, source). Побеждает наибольший prio. value = false -
-- "явно оставить настройку пользователя" (голос против переопределения). Бинд пользователя на пункт главнее всего.
do
    -- v52: голоса - одна переиспользуемая запись на пункт (slot) с номером прохода gen; раньше новая таблица на
    -- каждый голос каждый тик и A.votes = {} на каждом commit. A.votes - вид только на голоса текущего тика.
    local slot, gen = {}, 1
    local A = { owned = {}, last = {}, why = {} }
    A.votes = setmetatable({}, { __index = function(_, k) local v = slot[k]; if v and v.gen == gen then return v end end })
    function RAP.vote(key, value, prio, source)
        local v = slot[key]
        if not v then v = { gen = 0 }; slot[key] = v end
        if v.gen ~= gen or prio > v.prio then v.value, v.prio, v.src, v.gen = value, prio, source, gen end
    end
    setmetatable(A, { __index = function(t, k) if k == "votes_now" then return t.votes end end })
    function A.commit()
        -- "Script rage control" выключен: скрипт не трогает рагебот вообще - раньше magic key / noscope / lag hc /
        -- shot pressure продолжали голосовать мимо rage vote, и арбитр применял их голоса
        local off = not RAP.v("rage.on")
        for key, P in pairs(RAP.ref.rage) do
            local v = A.votes[key]
            local val, src = nil, nil
            if v and v.value ~= false and v.value ~= nil then val, src = v.value, v.src end
            if off then val, src = nil, "rage control off" end
            if val ~= nil and RAP.binds.is_active(P.name) then val, src = nil, "your bind" end
            if val ~= nil then
                if not A.owned[key] or not RAP.U.same(A.last[key], val) then P.set_override(val) end
                A.owned[key], A.last[key] = true, val
            elseif A.owned[key] then
                P.set_override(nil)
                A.owned[key], A.last[key] = false, nil
            end
            local w = A.why[key]
            if not w then w = {}; A.why[key] = w end
            local wsrc = src or (v and v.src) or "-"
            if not src and v then
                if w.base ~= v.src then w.base, w.kept = v.src, v.src .. " (kept yours)" end
                wsrc = w.kept
            end
            w.value, w.src = val, wsrc
        end
        gen = gen + 1
    end
    function A.release()
        for key, P in pairs(RAP.ref.rage) do if A.owned[key] then P.set_override(nil); A.owned[key] = false end end
    end
    RAP.arb = A
end
---------------------------------------------------------------- menu builder
-- Пункты описываются ключом "раздел.имя". RAP.cfg[key] - сам пункт, RAP.v(key) - значение.
-- opts: tip (подсказка), adv (только в режиме Advanced), dep (функция видимости), save = false (не в конфиг).
do
    local M = { items = {}, order = {}, deps = {}, defaults = {} }
    RAP.cfg = M.items
    local NIL = {}
    function RAP.v(key)
        local c = RAP.vcache
        if c then
            local x = c[key]
            if x ~= nil then if x == NIL then return nil end return x end
        end
        local it = M.items[key]
        if not it then return nil end
        local ok, v = pcall(it.get, it)
        local r = nil
        if ok then r = v end                   -- false must stay false (раньше false -> nil: экспорт терял выключенные пункты)
        if c then c[key] = r == nil and NIL or r end
        return r
    end

    local function refresh()
        local adv = RAP.v("main.advanced")
        for _, d in ipairs(M.deps) do
            local show = true
            if d.adv and not adv then show = false end
            if show and d.dep then local ok, r = pcall(d.dep); show = ok and r and true or false end
            pcall(d.item.visibility, d.item, show)
        end
    end
    M.refresh = refresh

    local function add(key, item, opts, kind, def)
        if not item then return nil end
        opts = opts or {}
        M.items[key] = item
        if opts.save ~= false and def ~= nil then M.defaults[key] = def end
        M.order[#M.order + 1] = { key = key, kind = kind, save = opts.save ~= false }
        if opts.tip then pcall(item.tooltip, item, opts.tip) end
        if opts.adv or opts.dep then M.deps[#M.deps + 1] = { item = item, adv = opts.adv, dep = opts.dep } end
        pcall(item.set_callback, item, refresh)
        return item
    end

    function M.group(tab, name, col)
        col = (col == 2) and 2 or 1          -- Neverlose: только колонки 1 и 2
        local ok, g = pcall(ui.create, tab, name, col)
        if not ok or not g then print("[eclipse] cannot create group " .. tab .. " / " .. name); return nil end
        local G = { g = g }
        function G.switch(key, name_, def, o) return add(key, g:switch(name_, def and true or false), o, "switch", def and true or false) end
        function G.slider(key, name_, a, b, def, scale, unit, o)
            return add(key, g:slider(name_, a, b, def, scale, unit), o, "slider", def)
        end
        function G.combo(key, name_, list, o) return add(key, g:combo(name_, list), o, "combo", list and list[1]) end
        function G.multi(key, name_, list, def, o)
            local dcopy = {}
            for i, v in ipairs(def or {}) do dcopy[i] = v end
            local it = add(key, g:selectable(name_, list), o, "multi", dcopy)
            if it and def then pcall(it.set, it, def) end
            return it
        end
        function G.color(key, name_, def, o) local o2 = o or {}; o2.save = false; return add(key, g:color_picker(name_, def), o2, "color") end
        function G.input(key, name_, def, o) return add(key, g:input(name_, def or ""), o, "input", def or "") end
        -- бинд: обычный switch, на него вешается родной бинд Neverlose (ПКМ -> New Bind, Hold / Toggle)
        function G.bind(key, name_, o)
            local o2 = o or {}
            o2.tip = o2.tip or "Right-click -> New Bind: key and Hold / Toggle (native Neverlose bind)."
            o2.save = false
            return add(key, g:switch(name_, false), o2, "bind")
        end
        function G.button(name_, fn) local b = g:button(name_); if b and fn then pcall(b.set_callback, b, fn) end; return b end
        function G.label(name_) return g:label(name_) end
        return G
    end

    -- снимок / применение значений (пресеты и экспорт)
    function M.snapshot()
        local t = {}
        for _, o in ipairs(M.order) do
            if o.save then
                local v = RAP.v(o.key)
                if type(v) ~= "userdata" then t[o.key] = v end
            end
        end
        return t
    end
    function M.apply(t)
        local n = 0
        for k, v in pairs(t or {}) do
            local it = M.items[k]
            if it and pcall(it.set, it, v) then n = n + 1 end
        end
        refresh()
        return n
    end
    RAP.menu = M
end
---------------------------------------------------------------- general menu
do
    local G = RAP.menu.group("Main", "General", 1)
    G.switch("main.advanced", "Advanced settings", false, { tip = "Shows fine-tuning sliders everywhere in the script." })
    G.slider("main.ping", "Real ping (0 = auto)", 0, 200, 0, 1, "ms",
        { tip = "With fake latency the measured ping is fake. Enter your real ping for correct timing of enemy shots." })
    G.switch("main.persist", "Remember learning between sessions", true)
    G.switch("main.bots", "Learn from bots", false, { tip = "Off: bots do not train any AI (they do not resolve like cheaters)." })
    G.switch("main.logs", "Console logs", true)
end

---------------------------------------------------------------- world: общий кэш на тик
-- RAP.W: me, alive, weapon, widx, wsub (вкладка рагебота), wgroup, state, vel, enemies, threat, charge, ping, now
do
    local W = { enemies = {}, now = 0 }
    RAP.W = W
    local WG = { [40] = "Scout", [9] = "AWP", [11] = "Auto", [38] = "Auto", [1] = "Deagle", [64] = "Revolver" }
    local PISTOL = { [2] = true, [3] = true, [4] = true, [30] = true, [32] = true, [36] = true, [61] = true, [63] = true }
    W.STATES = { "stand", "move", "slow", "air", "airduck", "duck" }

    -- v52: без замыканий на каждый вызов, автоматическое значение кэшируется на 0.5 с (W.ping зовется каждый тик)
    local function nc_latency() local nc = utils.net_channel(); return nc.latency[0] + nc.latency[1] end
    local function res_ping()
        local p = entity.get_player_resource().m_iPing[entity.get_local_player():get_index()]
        return (p and p > 0) and p / 1000 or nil
    end
    local PING = { t = -1, v = 0.06, src = "default" }
    function W.ping()
        local manual = RAP.v("main.ping")
        if manual and manual > 0 then return manual / 1000, "manual" end
        local now = globals.realtime
        if now - PING.t < 0.5 and now >= PING.t then return PING.v, PING.src end
        PING.t = now
        local ok, v = pcall(nc_latency)
        if ok and type(v) == "number" and v >= 0.005 then PING.v, PING.src = v, "net channel"; return v, "net channel" end
        ok, v = pcall(res_ping)
        if ok and type(v) == "number" and v >= 0.005 then PING.v, PING.src = v, "player resource"; return v, "player resource" end
        PING.v, PING.src = 0.06, "default"
        return 0.06, "default"
    end

    -- стабильный идентификатор игрока: SteamID / bot:имя
    local PIDC = {}
    local function pid_of(ent)
        if ent:is_bot() then return "bot:" .. tostring(ent:get_name()) end
        local x = tostring(ent:get_xuid() or "")
        if x ~= "" and x ~= "0" then return "x:" .. x end
        return "n:" .. tostring(ent:get_name())
    end
    function W.pid(ent)
        if not ent then return nil end
        local idx = ent:get_index()
        local c = PIDC[idx]
        local now = globals.realtime
        if c and now - c.t < 2 and now >= c.t then return c.pid end
        local ok, pid = pcall(pid_of, ent)
        pid = ok and pid or nil
        if not c then c = {}; PIDC[idx] = c end
        c.pid, c.t = pid, now
        return pid
    end
    -- игрок вышел / зашел: тот же индекс сущности может достаться другому игроку - кэш pid сбрасывается
    -- (раньше до 2 с статистика могла уйти чужому pid)
    local function pid_flush() for k in pairs(PIDC) do PIDC[k] = nil end end
    pcall(function() events.player_disconnect:set(function() RAP.U.safe("pid flush", pid_flush) end) end)
    pcall(function() events.player_connect_full:set(function() RAP.U.safe("pid flush", pid_flush) end) end)
    RAP.on("level", "world", pid_flush)
    function W.is_bot_pid(pid) return pid ~= nil and pid:sub(1, 4) == "bot:" end
    function W.learn(pid) return pid ~= nil and (RAP.v("main.bots") or not W.is_bot_pid(pid)) end

    local function state_of(me)
        local flags = me.m_fFlags or 1
        local on_ground = bit.band(flags, 1) == 1
        local duck = (me.m_flDuckAmount or 0) > 0.6 or RAP.ref.on(RAP.ref.fake_duck)
        local v = me.m_vecVelocity
        local spd = v and v:length2d() or 0
        if not on_ground then return duck and "airduck" or "air" end
        if duck then return "duck" end
        if spd < 5 then return "stand" end
        if RAP.ref.on(RAP.ref.slow_walk) then return "slow" end
        return "move"
    end

    local EN_REC, EN_LIST, EN_N = {}, {}, 0
    local function add_enemy(pl)
        if not pl:is_alive() then return end
        local idx = pl:get_index()
        local r = EN_REC[idx]
        if not r then r = {}; EN_REC[idx] = r end
        r.ent, r.idx, r.dormant, r.pid = pl, idx, pl:is_dormant(), W.pid(pl)
        EN_N = EN_N + 1
        EN_LIST[EN_N] = r
    end
    function W.update(cmd)
        W.now, W.cmd = globals.curtime, cmd
        local me = entity.get_local_player()
        W.me, W.alive = me, me and me:is_alive() or false
        if not W.alive then
            for i = #EN_LIST, 1, -1 do EN_LIST[i] = nil end
            W.enemies, W.threat = EN_LIST, nil
            return
        end
        local wpn = me:get_player_weapon()
        W.weapon = wpn
        W.widx = wpn and wpn:get_weapon_index() or nil
        W.wsub = W.widx and RAP.ref.WIDX_SUB[W.widx] or nil
        W.wgroup = W.widx and (WG[W.widx] or (PISTOL[W.widx] and "Pistol") or "other") or "other"
        W.state = state_of(me)
        W.vel = me.m_vecVelocity
        W.eye = me:get_eye_position()
        W.threat = entity.get_threat()
        W.can_hit_me = entity.get_threat(true)
        local okc, ch = pcall(rage.exploit.get, rage.exploit)
        W.charge = okc and ch or 0
        W.ping_s = W.ping()
        -- v52: записи врагов переиспользуются по idx, список - один и тот же массив (раньше новая таблица на
        -- врага и замыкание каждый тик). Модули читают W.enemies только в пределах тика.
        EN_N = 0
        pcall(entity.get_players, true, true, add_enemy)
        for i = #EN_LIST, EN_N + 1, -1 do EN_LIST[i] = nil end
        W.enemies = EN_LIST
    end
    RAP.on("tick", "world", function(cmd) W.update(cmd) end, 0)
end
---------------------------------------------------------------- shots: выстрелы врагов по тебе и твои выстрелы
-- Выстрел врага собирается из трех событий в любом порядке (на живом сервере bullet_fire приходит до 0.6 с позже
-- импакта и попадания): bullet_fire -> неточность, bullet_impact -> направление и длина луча, player_hurt -> попадание.
-- Через 0.5 с запись оценивается и отправляется всем подписчикам: RAP.run("enemy_shot", kind, rec).
-- kind: dodge | hit | far | blocked | inaccurate | bot | nodir
do
    local U = RAP.U
    local SH = { pending = {}, done = {}, hurt = {}, stat = {}, impacts = 0 }
    RAP.shots = SH
    local function st(k) SH.stat[k] = (SH.stat[k] or 0) + 1 end

    local function ray_dist(start, dir, pts)
        local best, tb = 1e9, 0
        for _, p in ipairs(pts) do
            local tx, ty, tz = p.x - start.x, p.y - start.y, p.z - start.z
            local t = tx * dir.x + ty * dir.y + tz * dir.z
            if t >= 0 then
                local dx, dy, dz = start.x + dir.x * t - p.x, start.y + dir.y * t - p.y, start.z + dir.z * t - p.z
                local d = U.sqrt(dx * dx + dy * dy + dz * dz)
                if d < best then best, tb = d, t end
            end
        end
        return best, tb
    end

    -- серия: выстрел того же стрелка < 0.35 с после предыдущего (DT) - одно решение, а не две независимые выборки.
    -- Первый выстрел серии учит полностью, следующие - с весом CFG.attr.burst и не считаются в panic / phase shift / brute.
    SH.elast, SH.olast = {}, {}
    local function mark_burst(rec, last, key)
        local lt = last[key]
        rec.burst = (lt ~= nil and rec.t >= lt and rec.t - lt < 0.35) or false
        last[key] = rec.t
    end
    SH.mark_burst = mark_burst
    local function new_rec(sh, idx, now)
        local me = entity.get_local_player()
        local eye, org = me:get_eye_position(), me:get_origin()
        local start
        pcall(function() start = sh:get_eye_position() end)
        start = start or (sh:get_origin() + vector(0, 0, 64))
        local rec = { t = now, enemy = idx, pid = RAP.W.pid(sh), start = start, inacc = 0,
            pts = { eye, vector(org.x, org.y, org.z + 46), vector(org.x, org.y, org.z + 28), vector(org.x, org.y, org.z + 8) },
            state = RAP.W.state, ctx = {}, sdist = start:dist(eye) }
        pcall(function() rec.sdorm = sh:is_dormant() end)
        mark_burst(rec, SH.elast, idx)
        RAP.run("enemy_shot_start", rec)     -- AA-движок (этап 2) кладет сюда профиль и сторону на момент выстрела
        local h = SH.hurt[idx]
        -- попадание уже отправлено подписчикам как untracked-hit: запись помечается, но второй раз не оценивается
        if h and now - h.t < 0.8 then rec.hit, rec.hitgroup, rec.reported, SH.hurt[idx] = true, h.hg, true, nil end
        SH.pending[#SH.pending + 1] = rec
        if #SH.pending > 32 then table.remove(SH.pending, 1) end
        return rec
    end
    local function find(idx, now, kind)
        for i = #SH.pending, 1, -1 do
            local p = SH.pending[i]
            if p.enemy == idx then
                if kind == "fire" and not p.fired and now - p.t < 0.7 then return p end
                if kind == "impact" and p.imp and now - (p.imp_t or 0) < 0.03 then return p end
            end
        end
        if kind == "impact" then
            for i = 1, #SH.pending do
                local p = SH.pending[i]
                if p.enemy == idx and not p.imp and now - p.t < 1.2 then
                    if now - p.t > 0.5 then st("late_impact") end
                    return p
                end
            end
        end
        return nil
    end

    events.bullet_fire:set(function(e)
        U.safe("shots fire", function()
            local me = entity.get_local_player()
            if not me or not me:is_alive() or not e.entity or not e.entity:is_enemy() then return end
            st("fire")
            local now, idx = globals.curtime, e.entity:get_index()
            local p = find(idx, now, "fire")
            if not p then
                -- поздний bullet_fire к уже оцененной записи
                local d = SH.done[idx]
                if d and now - d < 0.9 then SH.done[idx] = nil; st("late_fire"); return end
                p = new_rec(e.entity, idx, now)
            end
            p.fired, p.inacc = true, (tonumber(e.inaccuracy) or 0) + (tonumber(e.spread) or 0)
            RAP.run("enemy_fire", e.entity, now)
        end)
    end)
    events.bullet_impact:set(function(e)
        U.safe("shots impact", function()
            local me = entity.get_local_player()
            if not me or not me:is_alive() then return end
            local sh = entity.get(e.userid, true)
            if not sh or sh == me or not sh:is_enemy() then return end
            local now, idx = globals.curtime, sh:get_index()
            local imp = vector(e.x, e.y, e.z)
            local p = find(idx, now, "impact") or new_rec(sh, idx, now)
            local d = p.start:dist(imp)
            if not p.imp_d or d > p.imp_d then p.imp, p.imp_d = imp, d end
            p.imp_t = now
            SH.impacts = SH.impacts + 1
        end)
    end)
    events.player_hurt:set(function(e)
        U.safe("shots hurt", function()
            local me = entity.get_local_player()
            if not me or entity.get(e.userid, true) ~= me then return end
            local att = entity.get(e.attacker, true)
            if not att or att == me or not att:is_enemy() then return end
            local w = tostring(e.weapon or "")
            if w:find("grenade") or w == "inferno" or w == "knife" then return end
            local now, idx = globals.curtime, att:get_index()
            for i = #SH.pending, 1, -1 do
                local p = SH.pending[i]
                if p.enemy == idx and not p.hit and now - p.t < 0.25 then
                    p.hit, p.hitgroup = true, e.hitgroup
                    return
                end
            end
            SH.hurt[idx] = { t = now, hg = e.hitgroup }
            SH.last_hurt = SH.last_hurt or {}
            SH.last_hurt[idx] = now
            -- попадание без записи: оценивается сразу (запись может прийти позже и будет помечена попаданием)
            local rec = { t = now, enemy = idx, pid = RAP.W.pid(att), hit = true, hitgroup = e.hitgroup, state = RAP.W.state, ctx = {} }
            mark_burst(rec, SH.elast, idx)
            RAP.run("enemy_shot_start", rec)
            rec.untracked = true
            st("hit")
            RAP.run("enemy_shot", RAP.W.learn(rec.pid) and "hit" or "bot", rec)
        end)
    end)

    local function judge(p)
        if p.hit then
            -- уже отправлено как untracked-hit: второй раз не оценивается (раньше "x and nil or y" всегда давал "hit")
            if p.untracked or p.reported then return nil end
            return "hit"
        end
        if not (p.imp and p.imp_d and p.imp_d > 1) then
            if p.sdorm then st("nodir_dormant") elseif (p.sdist or 0) > 2500 then st("nodir_far") else st("nodir_other") end
            return "nodir"
        end
        local dir = (p.imp - p.start) * (1 / p.imp_d)
        local d, tb = ray_dist(p.start, dir, p.pts)
        p.dist, p.tbody = d, tb
        if d > RAP.CFG.shots.near then return "far" end
        if p.imp_d < tb - 30 then return "blocked" end
        if not RAP.W.learn(p.pid) then return "bot" end
        -- ожидаемый разброс врага на этой дистанции: промах из-за его неточности - не уворот
        local r = tb * (p.inacc or 0)
        p.w = U.clamp(1 - (r - 8) / 30, 0, 1)
        if p.w < RAP.CFG.shots.inacc_drop then return "inaccurate" end
        -- bullet_fire не пришел: точность врага неизвестна (inacc = 0 давал уворот с полным весом)
        if not p.fired then p.w = p.w * 0.6 end
        -- рядом по времени этот враг попал по тебе (player_hurt не сопоставился с записью): это может быть та же пуля -
        -- "уворот" недостоверен, такая запись не учит
        local lh = SH.last_hurt and SH.last_hurt[p.enemy]
        if lh and U.abs(lh - p.t) < 0.6 then st("dodge_ambiguous"); return nil end
        return "dodge"
    end

    RAP.on("tick", "shots", function()
        local now = globals.curtime
        for i = #SH.pending, 1, -1 do
            local p = SH.pending[i]
            local wait = (p.fired and not p.imp and not p.hit) and 1.2 or 0.5
            if now - p.t > wait then
                table.remove(SH.pending, i)
                if not p.fired then SH.done[p.enemy] = p.t end
                local kind = judge(p)
                if kind then
                    st(kind)
                    if kind == "hit" and not RAP.W.learn(p.pid) then kind = "bot" end
                    RAP.run("enemy_shot", kind, p)
                end
            end
        end
    end, 5)
    -- новая карта: записи со старым curtime никогда не оценились бы и перехватывали бы новые bullet_fire
    RAP.on("level", "shots", function()
        SH.pending, SH.done, SH.hurt, SH.elast, SH.olast, SH.ours = {}, {}, {}, {}, {}, {}
        SH.last_hurt = nil
    end)

    -- твои выстрелы: aim_fire / aim_ack -> подписчики "our_fire" / "our_ack"
    SH.ours = {}
    events.aim_fire:set(function(e)
        U.safe("aim_fire", function()
            local rec = { id = e.id, t = globals.curtime, target = e.target, idx = e.target and e.target:get_index(),
                pid = e.target and RAP.W.pid(e.target), wgroup = RAP.W.wgroup, mst = RAP.W.state, ctx = {} }
            mark_burst(rec, SH.olast, rec.idx or -1)
            SH.ours[e.id] = rec
            SH.last_fire = globals.curtime
            RAP.run("our_fire", rec, e)
        end)
    end)
    events.aim_ack:set(function(e)
        U.safe("aim_ack", function()
            local rec = SH.ours[e.id] or { id = e.id, idx = e.target and e.target:get_index(), pid = e.target and RAP.W.pid(e.target), ctx = {} }
            SH.ours[e.id] = nil
            rec.state = e.state
            RAP.run("our_ack", rec, e)
            local now = globals.curtime
            for id, r in pairs(SH.ours) do if now - (r.t or 0) > 3 then SH.ours[id] = nil end end
        end)
    end)
end
---------------------------------------------------------------- telemetry: журнал выстрелов, сессии, сравнение версий
-- Каждый твой выстрел записывается: версия, оружие, тип AA цели, стратегия (и почему выбрана), hitchance, урон,
-- хитбокс, результат / причина промаха, промахов подряд по цели, сменилась ли стратегия перед выстрелом.
-- /eclipse report - сессия против прошлых + сравнение версий + разрезы; /eclipse journal [n] - последние выстрелы.
do
    local U = RAP.U
    local KEY, JKEY, AKEY = "rap2_reports", "rap2_journal", "rap2_ajournal"
    local T = { hist = RAP.store.get(KEY) or {}, journal = RAP.store.get(JKEY) or {}, ajournal = RAP.store.get(AKEY) or {}, streak = {} }
    if type(T.hist.list) ~= "table" then T.hist = { list = {} } end
    if type(T.journal.rows) ~= "table" then T.journal = { rows = {} } end
    -- журнал выстрелов врагов по тебе (для replay AA-логики): профиль, группа, результат, веса атрибуции, время
    if type(T.ajournal.rows) ~= "table" then T.ajournal = { rows = {} } end
    do local okt, ut = pcall(common.get_unixtime); T.session = okt and tonumber(ut) or 0 end
    function T.apush(row)
        local rows = T.ajournal.rows
        row.v, row.s = RAP.VERSION, T.session
        rows[#rows + 1] = row
        while #rows > RAP.CFG.log.keep do table.remove(rows, 1) end
        RAP.store.mark(AKEY)
    end
    RAP.tele = T
    local function fresh()
        return { rounds = 0, shots = 0, hits = 0, hs = 0, miss = {}, kills = 0, deaths = 0, hs_deaths = 0, ehits = 0, ehits_head = 0, dodges = 0 }
    end
    T.cur = fresh()

    RAP.on("our_ack", "tele", function(rec, e)
        local c = T.cur
        local ok = e.state == nil
        c.shots = c.shots + 1
        if ok then c.hits = c.hits + 1; if e.hitgroup == 1 then c.hs = c.hs + 1 end
        else c.miss[tostring(e.state)] = (c.miss[tostring(e.state)] or 0) + 1 end
        local idx = rec.idx or -1
        local before = T.streak[idx] or 0
        T.streak[idx] = ok and 0 or before + 1
        local okt, ts = pcall(common.get_unixtime)
        local row = { v = RAP.VERSION, t = okt and ts or 0, w = rec.wgroup or RAP.W.wgroup, a = rec.ctx.aat or "?",
            s = rec.ctx.mode or "-", y = rec.ctx.why, c = rec.ctx.conf and U.round(rec.ctx.conf * 100) or nil,
            hc = e.hitchance, d = e.damage, wd = e.wanted_damage, hg = e.hitgroup, wh = e.wanted_hitgroup,
            r = ok and "hit" or tostring(e.state), k = before, ch = rec.ctx.changed and 1 or 0, bt = e.backtrack, rt = rec.ctx.rt,
            aw = rec.ctx.attr and U.round(rec.ctx.attr * 100) / 100 or nil, ms = rec.mst, ef = rec.ctx.eff == false and 0 or nil }
        local rows = T.journal.rows
        rows[#rows + 1] = row
        local keep = RAP.CFG.log.keep
        while #rows > keep do table.remove(rows, 1) end
        RAP.store.mark(JKEY); RAP.store.mark(KEY)
    end)
    RAP.on("enemy_shot", "tele", function(kind, rec)
        local c = T.cur
        if kind == "hit" then c.ehits = c.ehits + 1; if rec.hitgroup == 1 then c.ehits_head = c.ehits_head + 1 end
        elseif kind == "dodge" then c.dodges = c.dodges + 1 end
        RAP.store.mark(KEY)
    end)
    events.player_death:set(function(e)
        U.safe("tele death", function()
            local me = entity.get_local_player()
            if not me then return end
            if entity.get(e.attacker, true) == me and entity.get(e.userid, true) ~= me then T.cur.kills = T.cur.kills + 1 end
            if entity.get(e.userid, true) == me then T.cur.deaths = T.cur.deaths + 1; if e.headshot then T.cur.hs_deaths = T.cur.hs_deaths + 1 end end
            RAP.store.mark(KEY)
        end)
    end)
    RAP.on("round", "tele", function() T.cur.rounds = T.cur.rounds + 1; T.streak = {}; RAP.store.mark(KEY) end)
    RAP.resets.journal = function() T.journal = { rows = {} } end
    RAP.resets.ajournal = function() T.ajournal = { rows = {} } end
    RAP.resets.reports = function() T.hist, T.cur.slot = { list = {} }, nil end

    local function summary(c)
        local r = U.max(1, c.rounds)
        return { shots = c.shots, hit = c.shots > 0 and c.hits / c.shots or nil, corr = c.shots > 0 and (c.miss.correction or 0) / c.shots or nil,
            hs = c.hits > 0 and c.hs / c.hits or nil, kd = c.kills / U.max(1, c.deaths), hsd = c.hs_deaths / r,
            dodge = (c.dodges + c.ehits) > 0 and c.dodges / (c.dodges + c.ehits) or nil, rounds = c.rounds, v = RAP.VERSION }
    end
    T.summary = summary
    RAP.on("save", "tele", function(force)
        local S = RAP.store
        local s = summary(T.cur)
        if s.shots >= 5 and S.need(KEY, force) then
            local list = T.hist.list
            if T.cur.slot then list[T.cur.slot] = s else list[#list + 1] = s; T.cur.slot = #list end
            while #list > 20 do table.remove(list, 1); T.cur.slot = #list end
            S.set(KEY, T.hist)
        end
        if S.need(JKEY, force) then S.set(JKEY, T.journal) end
        if S.need(AKEY, force) then S.set(AKEY, T.ajournal) end
    end)

    local function pct(v) return v and string.format("%.0f%%", v * 100) or "-" end
    -- разрез журнала: попадания / correction / mispred по значению поля
    local function cut(rows, field, label)
        local g = {}
        for _, r in ipairs(rows) do
            local k = tostring(r[field])
            local b = g[k]
            if not b then b = { n = 0, h = 0, c = 0, m = 0 }; g[k] = b end
            b.n = b.n + 1
            if r.r == "hit" then b.h = b.h + 1 elseif r.r == "correction" then b.c = b.c + 1 elseif r.r == "misprediction" then b.m = b.m + 1 end
        end
        local parts = {}
        for k, b in pairs(g) do parts[#parts + 1] = { k, b } end
        table.sort(parts, function(a, b) return a[2].n > b[2].n end)
        for _, p in ipairs(parts) do
            local b = p[2]
            U.log("report", "  %-10s %-18s shots %3d  hit %4s  correction %4s  mispred %4s", label, p[1], b.n, pct(b.h / b.n), pct(b.c / b.n), pct(b.m / b.n))
        end
    end
    function T.report()
        local s = summary(T.cur)
        local avg, n = {}, 0
        for i, h in ipairs(T.hist.list) do
            if i ~= T.cur.slot then
                n = n + 1
                for _, k in ipairs({ "hit", "corr", "hs", "kd", "hsd", "dodge" }) do
                    if h[k] then avg[k] = (avg[k] or 0) + h[k]; avg[k .. "_n"] = (avg[k .. "_n"] or 0) + 1 end
                end
            end
        end
        local function cmp(k, fmt, high)
            local v, a = s[k], avg[k .. "_n"] and avg[k] / avg[k .. "_n"] or nil
            local txt = v and (fmt == "%" and pct(v) or string.format(fmt, v)) or "-"
            if v and a then txt = txt .. string.format("  (avg %s, %s)", fmt == "%" and pct(a) or string.format(fmt, a), ((v - a) >= 0) == high and "better" or "worse") end
            return txt
        end
        U.log("report", "session: %d rounds, %d shots, %d kills / %d deaths  |  past sessions: %d", s.rounds, s.shots, T.cur.kills, T.cur.deaths, n)
        U.log("report", "rage hit rate      %s", cmp("hit", "%", true))
        U.log("report", "correction misses  %s", cmp("corr", "%", false))
        U.log("report", "headshot share     %s", cmp("hs", "%", true))
        U.log("report", "K/D                %s", cmp("kd", "%.2f", true))
        U.log("report", "died to HS / round %s", cmp("hsd", "%.2f", false))
        U.log("report", "AA dodge share     %s", cmp("dodge", "%", true))
        -- сравнение версий по журналу
        local rows = T.journal.rows
        local byv, order = {}, {}
        for _, r in ipairs(rows) do
            local b = byv[r.v]
            if not b then b = { n = 0, h = 0, c = 0, rts = {} }; byv[r.v] = b; order[#order + 1] = r.v end
            b.n = b.n + 1
            if r.r == "hit" then b.h = b.h + 1 elseif r.r == "correction" then b.c = b.c + 1 end
            if r.rt then b.rts[#b.rts + 1] = r.rt end
        end
        if #order > 0 then
            U.log("report", "by version (journal, last %d shots):", #rows)
            for _, v in ipairs(order) do
                local b = byv[v]
                local rt = "-"
                if #b.rts > 0 then table.sort(b.rts); rt = string.format("%d ms", b.rts[math.floor(#b.rts / 2) + 1]) end
                -- 95% интервал для доли попаданий: чтобы было видно, где разница - шум
                local p = b.h / b.n
                local ci = 1.96 * math.sqrt(math.max(p * (1 - p), 0.01) / b.n)
                U.log("report", "  %-22s shots %3d  hit %4s (+/-%2.0f%%)  correction %4s  reaction (median) %s", v, b.n, pct(p), ci * 100, pct(b.c / b.n), rt)
            end
        end
        local cur = {}
        for _, r in ipairs(rows) do if r.v == RAP.VERSION then cur[#cur + 1] = r end end
        if #cur > 0 then
            U.log("report", "this version, by enemy AA type / strategy / weapon:")
            cut(cur, "a", "AA type"); cut(cur, "s", "strategy"); cut(cur, "w", "weapon")
            local after, other = { n = 0, h = 0 }, { n = 0, h = 0 }
            local streak_max = 0
            for _, r in ipairs(cur) do
                local b = r.ch == 1 and after or other
                b.n = b.n + 1
                if r.r == "hit" then b.h = b.h + 1 end
                if (r.k or 0) > streak_max then streak_max = r.k end
            end
            U.log("report", "  first shot after a strategy change: hit %s of %d  |  other shots: hit %s of %d  |  longest miss streak %d",
                after.n > 0 and pct(after.h / after.n) or "-", after.n, other.n > 0 and pct(other.h / other.n) or "-", other.n, streak_max)
        end
        if RAP.duels then RAP.duels.report() end
        if RAP.pressure then
            U.log("report", "shot pressure: %d stalls (visible target, weapon ready, no shot), %d shots fired after relief",
                RAP.pressure.stalls, RAP.pressure.relief_shots)
        end
        local parts = {}
        for k, v in pairs(T.cur.miss) do parts[#parts + 1] = k .. " " .. v end
        if #parts > 0 then U.log("report", "session misses: %s", table.concat(parts, ", ")) end
    end
    RAP.cmd.journal = function(arg)
        local n = tonumber(arg) or 15
        local rows = T.journal.rows
        for i = U.max(1, #rows - n + 1), #rows do
            local r = rows[i]
            print(string.format("[journal] %-7s %-7s %-16s %s hc %s dmg %s/%s hg %s/%s  %-14s streak %d%s%s", r.w or "?", r.a or "?", r.s or "-",
                r.c and (r.c .. "%") or "", tostring(r.hc), tostring(r.d), tostring(r.wd), tostring(r.hg), tostring(r.wh), r.r, r.k or 0,
                r.ch == 1 and "  [changed]" or "", r.y and ("  " .. r.y) or ""))
        end
    end
    RAP.cmd.report = function() T.report() end
    -- /eclipse coach: по журналу показывает, из-за чего промахи, и что с этим можно сделать
    RAP.cmd.coach = function()
        local rows = T.journal.rows
        local n = #rows
        if n < 15 then U.log("coach", "only %d shots in the journal, play a few rounds first (need 15+)", n); return end
        local cnt, hs, hits, lowdmg = {}, 0, 0, 0
        for _, r in ipairs(rows) do
            cnt[r.r] = (cnt[r.r] or 0) + 1
            if r.r == "hit" then
                hits = hits + 1
                if r.hg == 1 then hs = hs + 1 end
                if r.wd and r.wd > 0 and r.d and r.d < r.wd * 0.5 then lowdmg = lowdmg + 1 end
            end
        end
        local function share(k) return (cnt[k] or 0) / n end
        U.log("coach", "last %d shots: hit %s, headshots %s of hits", n, pct(hits / n), hits > 0 and pct(hs / hits) or "-")
        local order = {}
        for k, v in pairs(cnt) do if k ~= "hit" then order[#order + 1] = { k, v } end end
        table.sort(order, function(a, b) return a[2] > b[2] end)
        for _, p in ipairs(order) do U.log("coach", "  miss %-18s %3d  (%s)", p[1], p[2], pct(p[2] / n)) end
        if share("spread") > 0.25 then
            U.log("coach", "! many spread misses: the cheat fires at hitchance too low for the weapon. Raise base hitchance, scope in, stop before the shot (auto stop).")
        end
        if share("correction") > 0.30 then
            U.log("coach", "! many resolver (correction) misses: the script cannot change the cheat's resolver, only aim choice. Check what Strategy AI picks against these enemies (/eclipse strat) and keep 'Head focus' disabled.")
        end
        if share("misprediction") + share("prediction error") > 0.15 then
            U.log("coach", "! prediction misses: target is moving/lagging. Shoot after they stop, lower 'Real ping' mismatch (main.ping), avoid shooting while you are fake ducking.")
        end
        if share("damage rejection") > 0.08 then
            U.log("coach", "! damage rejection: server rejected damage (wall / armor / minimum damage). Lower min damage on this weapon or use per-weapon damage.")
        end
        if share("unregistered shot") + share("backtrack failure") > 0.08 then
            U.log("coach", "! unregistered / backtrack failure: network issue or shooting while choking. Check your fake lag limit and ping.")
        end
        if hits > 5 and lowdmg / hits > 0.3 then
            U.log("coach", "! %s of hits do less than half the wanted damage (armor / wrong hitbox). Prefer body or raise damage on armored targets.", pct(lowdmg / hits))
        end
        -- по типу AA врага: где хуже всего
        local g = {}
        for _, r in ipairs(rows) do
            local k = tostring(r.a)
            local b = g[k]
            if not b then b = { n = 0, h = 0 }; g[k] = b end
            b.n = b.n + 1
            if r.r == "hit" then b.h = b.h + 1 end
        end
        for k, b in pairs(g) do
            if b.n >= 8 and b.h / b.n < 0.45 then U.log("coach", "! weakest vs AA type '%s': hit %s of %d shots", k, pct(b.h / b.n), b.n) end
        end
        local s = T.summary(T.cur)
        if s.hsd and s.hsd > 0.5 then U.log("coach", "! you die to headshots %.2f per round: try Safe head on, Limit randomization, AI explore lower (ai.explore)", s.hsd) end
        if s.dodge and s.dodge < 0.5 then U.log("coach", "! AA dodge share %s: most enemy shots near you are hitting. Turn on Anti-brute / Phase shift and let AI collect more data.", pct(s.dodge)) end
    end
end
---------------------------------------------------------------- журнал решений: проверка, что смена действительно помогла
-- Цепочка обучения: контекст -> решение -> выстрел -> атрибуция -> качество выборки -> уверенность -> обучение ->
-- ПРОВЕРКА СМЕНЫ -> новое решение. Здесь - последнее звено, общее для всех систем:
--   DL.outcome(kind, key, вариант, успех, вес) - каждое обученное событие (стратегия: попадание; AA / phase: уворот);
--   DL.record(kind, key, было, стало, почему, info) - смена. Оценка "было" = биномиальная статистика этой сессии по
--   варианту "было" (Beta, неопределенность по min(сумма весов, n_eff)); если ее мало - оценка модели на момент смены.
--   После смены копится окно "стало". При n >= verify.*_n: P(стало лучше) >= p -> better, <= 1 - p -> worse,
--   n >= max_n -> same. Worse -> откат на "было" (кроме самих откатов) и блок "стало" на block_s секунд.
--   Смена до вердикта закрывает открытое решение как interrupted.
-- kind: strat (key = враг|оружие|тип AA), aa (key = группа состояний), phase (key = враг), evo (только запись A/B).
do
    local U = RAP.U
    local KEY = "rap2_decisions"
    local DL = { log = {}, open = {}, block = {}, rb = {}, stats = {} }
    RAP.dl = DL
    local function C() return RAP.CFG.verify end
    local function phi(z)
        local s, x = z < 0 and -1 or 1, U.abs(z) / 1.41421356
        local t = 1 / (1 + 0.3275911 * x)
        local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
        return 0.5 * (1 + s * y)
    end
    DL.phi = phi
    -- эффективный объем: веса > 1 (голова 1.5) не должны выглядеть как больше данных, а неравные веса - как равные
    function DL.n_info(sum, w2)
        if not sum or sum <= 0 then return 0 end
        if not w2 or w2 <= 0 then return sum end
        return U.min(sum, sum * sum / w2)
    end
    local function beta(h, m, w2)
        local n = DL.n_info(h + m, w2)
        local mean = (1 + h) / (2 + h + m)
        return mean, mean * (1 - mean) / (3 + n), n
    end
    do
        local d = RAP.store.get(KEY)
        if d and type(d.list) == "table" then
            for _, r in ipairs(d.list) do if type(r) == "table" and type(r.kind) == "string" and type(r.verdict) == "string" then DL.log[#DL.log + 1] = r end end
        end
    end
    local function push(d)
        DL.log[#DL.log + 1] = d
        while #DL.log > 200 do table.remove(DL.log, 1) end
        RAP.store.mark(KEY)
    end
    local function unixtime() local ok, t = pcall(common.get_unixtime); return ok and tonumber(t) or 0 end
    local function bkey(kind, key, opt) return kind .. "|" .. tostring(key) .. "|" .. tostring(opt) end

    function DL.blocked(kind, key, opt)
        local b = DL.block[bkey(kind, key, opt)]
        return b ~= nil and globals.realtime < b
    end
    -- биномиальная статистика сессии по варианту (затухание 0.97 на событие варианта)
    local function stat(kind, key, opt)
        local k = kind .. "|" .. tostring(key)
        local s = DL.stats[k]
        if not s then s = {}; DL.stats[k] = s end
        local o = s[opt]
        if not o then o = { h = 0, m = 0, w2 = 0 }; s[opt] = o end
        return o
    end

    local function close(d, verdict)
        d.verdict = verdict
        DL.open[d.kind .. "|" .. tostring(d.key)] = nil
        push(d)
    end
    local function judge(d)
        local need = d.kind == "strat" and C().strat_n or C().aa_n
        local m, v, n = beta(d.h, d.m, d.w2)
        if n < need then return end
        local pb = phi((m - d.pre_m) / U.sqrt(U.max(v + d.pre_v, 1e-6)))
        d.post_m, d.pb, d.post_n = m, pb, n
        local verdict
        if pb >= C().p then verdict = "better" elseif pb <= 1 - C().p then verdict = "worse" elseif n >= C().max_n then verdict = "same" end
        if not verdict then return end
        close(d, verdict)
        if verdict == "worse" and not d.no_rb and C().rollback == 1 and DL.rb[d.kind] then
            local ok, done = pcall(DL.rb[d.kind], d)
            if ok and done then
                d.rolled = true
                DL.block[bkey(d.kind, d.key, d.to)] = globals.realtime + C().block_s
                if RAP.v("main.logs") then
                    U.log("verify", "%s %s: %s -> %s was worse (%.0f%% vs %.0f%% expected, P(worse) %.0f%%) -> rolled back",
                        d.kind, tostring(d.key), tostring(d.lf), tostring(d.lt), m * 100, d.pre_m * 100, (1 - pb) * 100)
                end
                if RAP.toast then RAP.toast("Rolled back: " .. tostring(d.lt) .. " -> " .. tostring(d.lf)) end
            end
        end
    end

    function DL.outcome(kind, key, opt, success, w)
        if not w or w <= 0 or opt == nil then return end
        local o = stat(kind, key, opt)
        for _, x in pairs(DL.stats[kind .. "|" .. tostring(key)]) do x.h, x.m, x.w2 = x.h * 0.97, x.m * 0.97, x.w2 * 0.9409 end
        if success then o.h = o.h + w else o.m = o.m + w end
        o.w2 = o.w2 + w * w
        local d = DL.open[kind .. "|" .. tostring(key)]
        if d and d.to == opt then
            if success then d.h = d.h + w else d.m = d.m + w end
            d.w2, d.n = d.w2 + w * w, d.n + 1
            judge(d)
        end
    end
    -- info: conf (уверенность решения 0..1), pre_m / pre_v (оценка "было" по модели - запасной вариант),
    --       lf / lt (имена вариантов для отчета)
    function DL.record(kind, key, from, to, why, info)
        if from == nil or to == nil or from == to then return end
        info = info or {}
        local k = kind .. "|" .. tostring(key)
        local prev = DL.open[k]
        if prev then close(prev, prev.n > 0 and "interrupted" or "superseded") end
        local o = DL.stats[k] and DL.stats[k][from]
        local pm, pv, pn = 0.5, 0.25 / 3, 0
        if o then pm, pv, pn = beta(o.h, o.m, o.w2) end
        local src = "session"
        if pn < 3 and info.pre_m then pm, pv, src = info.pre_m, info.pre_v or 0.25 / 3, "model" end
        why = tostring(why or "-")
        DL.open[k] = { kind = kind, key = key, from = from, to = to, why = why, conf = info.conf, lf = info.lf or tostring(from), lt = info.lt or tostring(to),
            pre_m = pm, pre_v = pv, pre_src = src, t = unixtime(), v = RAP.VERSION, h = 0, m = 0, w2 = 0, n = 0,
            no_rb = why:find("^rollback") ~= nil }
    end
    -- запись без проверки (evo: у него свой A/B)
    function DL.note(kind, key, lf, lt, why, verdict, extra)
        local d = { kind = kind, key = key, lf = lf, lt = lt, why = why, verdict = verdict, t = unixtime(), v = RAP.VERSION, n = 0 }
        for k, v in pairs(extra or {}) do d[k] = v end
        push(d)
    end
    RAP.on("level", "decisions", function() DL.open, DL.stats = {}, {} end)
    RAP.resets.decisions = function() DL.log, DL.open, DL.stats, DL.block = {}, {}, {}, {} end
    RAP.on("save", "decisions", function(force)
        if not RAP.store.need(KEY, force) then return end
        local out = {}
        for _, d in ipairs(DL.log) do
            out[#out + 1] = { kind = d.kind, key = tostring(d.key), lf = d.lf, lt = d.lt, why = d.why, verdict = d.verdict, conf = d.conf,
                pre_m = d.pre_m and U.round(d.pre_m * 1000) / 1000, post_m = d.post_m and U.round(d.post_m * 1000) / 1000,
                pb = d.pb and U.round(d.pb * 1000) / 1000, n = d.post_n and U.round(d.post_n * 10) / 10 or d.n, rolled = d.rolled, t = d.t, v = d.v, pre_src = d.pre_src }
        end
        RAP.store.set(KEY, { list = out })
    end)
    RAP.cmd.decisions = function(arg)
        local n = tonumber(arg) or 15
        for _, d in pairs(DL.open) do
            local m, _, ni = beta(d.h, d.m, d.w2)
            print(string.format("[decisions] OPEN %-6s %-26s %s -> %s  (%s)  after: %.0f%% over %.1f eff. samples, expected %.0f%% (%s)",
                d.kind, tostring(d.key):sub(1, 26), d.lf, d.lt, d.why, m * 100, ni, d.pre_m * 100, d.pre_src))
        end
        for i = U.max(1, #DL.log - n + 1), #DL.log do
            local d = DL.log[i]
            print(string.format("[decisions] %-11s %-6s %-26s %s -> %s  (%s)%s%s", d.verdict:upper() .. (d.rolled and "+RB" or ""), d.kind,
                tostring(d.key):sub(1, 26), tostring(d.lf), tostring(d.lt), tostring(d.why),
                d.post_m and string.format("  after %.0f%% vs %.0f%%", d.post_m * 100, (d.pre_m or 0) * 100) or "",
                d.conf and string.format("  conf %.0f%%", d.conf * 100) or ""))
        end
        if #DL.log == 0 and not next(DL.open) then print("[decisions] no decisions yet") end
    end
end
---------------------------------------------------------------- target context: вся информация о враге в одном объекте
-- RAP.TC[idx] обновляется централизованно (world -> тут), остальные модули только читают:
--   id { idx, pid, bot }  move { speed, state, duck, air }  geo { dist, dz, visible }
--   aa { type, sub, conf, prev, changed_at, width }  hist { shots, hits, miss = { reason = n }, head_miss, streak }
--   threat { weapon, scoped, can_hit }  learn { arm, state, conf, samples, why, next }
do
    local TC = {}
    RAP.TC = TC
    local function new(en)
        return { id = { idx = en.idx, pid = en.pid, bot = RAP.W.is_bot_pid(en.pid) }, move = {}, geo = {}, aa = { type = "unknown", conf = 0 },
            hist = { shots = 0, hits = 0, miss = {}, head_miss = 0, streak = 0 }, threat = {}, learn = {}, seen = 0 }
    end
    function RAP.tc(idx) return TC[idx] end
    local slow = 0
    RAP.on("tick", "target context", function()
        local W = RAP.W
        if not W.alive then return end
        local now = globals.curtime
        slow = slow + 1
        local heavy = slow % 4 == 0           -- дорогие поля (видимость, оружие) - раз в 4 тика
        for _, en in ipairs(W.enemies) do
            local t = TC[en.idx]
            if not t or t.id.pid ~= en.pid then t = new(en); TC[en.idx] = t end
            t.seen, t.dormant, t.ent = now, en.dormant, en.ent
            if not en.dormant then
                local pl = en.ent
                local v = pl.m_vecVelocity
                local fl = pl.m_fFlags or 1
                t.move.speed = v and v:length2d() or 0
                t.move.air = bit.band(fl, 1) ~= 1
                t.move.duck = (pl.m_flDuckAmount or 0) > 0.6
                t.move.state = t.move.air and "air" or (t.move.duck and "duck" or (t.move.speed < 5 and "stand" or (t.move.speed < 120 and "slow" or "move")))
                if heavy then
                    local o = pl:get_origin()
                    t.geo.dist = o and W.eye and W.eye:dist(o) or nil
                    t.geo.dz = o and W.eye and (o.z + 64 - W.eye.z) or nil
                    local okv, vis = pcall(pl.is_visible, pl)
                    t.geo.visible = okv and vis or false
                    local w = pl:get_player_weapon()
                    t.threat.weapon = w and w:get_weapon_index() or nil
                    t.threat.scoped = pl.m_bIsScoped and true or false
                end
            end
        end
        local ct = W.can_hit_me and W.can_hit_me:get_index()
        for idx, t in pairs(TC) do
            t.threat.can_hit = idx == ct
            -- now < seen: curtime начался заново (смена карты) - запись устарела
            if now - t.seen > 30 or now < t.seen then TC[idx] = nil end
        end
    end, 2)
    -- история по цели за сессию (временная память; постоянная - в Strategy AI)
    RAP.on("our_ack", "target history", function(rec, e)
        local t = rec.idx and TC[rec.idx]
        if not t then return end
        local h = t.hist
        h.shots = h.shots + 1
        if e.state == nil then h.hits, h.streak = h.hits + 1, 0
        else
            h.miss[tostring(e.state)] = (h.miss[tostring(e.state)] or 0) + 1
            if RAP.strat and RAP.strat.LEARN[e.state] then h.streak = h.streak + 1 end
            if e.wanted_hitgroup == 1 then h.head_miss = h.head_miss + 1 end
            h.last_miss = tostring(e.state)
        end
    end)
    RAP.on("level", "target context", function() for k in pairs(TC) do TC[k] = nil end end)
end
---------------------------------------------------------------- duels и разбор смертей
-- Дуэль: враг стал виден -> кто выстрелил первым, кто сколько урона нанес, чем кончилось (убил / убили / разошлись).
-- Смерть: профиль AA, состояние, сторона десинка, defensive / DT, оружие врага, куда попали. /eclipse report, /eclipse deaths.
do
    local U = RAP.U
    local KEY = "rap2_deaths"
    local DU = { live = {}, done = {}, deaths = (RAP.store.get(KEY) or {}).list or {} }
    RAP.duels = DU
    local function close(idx, outcome)
        local d = DU.live[idx]
        if not d then return end
        DU.live[idx] = nil
        d.outcome = outcome
        if d.ours or d.theirs or outcome ~= "apart" then
            DU.done[#DU.done + 1] = d
            if #DU.done > 300 then table.remove(DU.done, 1) end
        end
    end
    RAP.on("tick", "duels", function()
        local W = RAP.W
        if not W.alive then for idx in pairs(DU.live) do close(idx, "apart") end; return end
        local now = globals.curtime
        for idx, t in pairs(RAP.TC) do
            local vis = t.geo.visible and not t.dormant
            local d = DU.live[idx]
            if vis then
                if not d then d = { t0 = now, idx = idx, pid = t.id.pid, dealt = 0, taken = 0, aat = t.aa.type }; DU.live[idx] = d end
                d.last_vis = now
            elseif d and now - (d.last_vis or now) > 3 then close(idx, "apart") end
        end
    end, 8)
    RAP.on("our_fire", "duels", function(rec)
        local d = rec.idx and DU.live[rec.idx]
        if d and not d.ours then d.ours = globals.curtime - d.t0 end
    end)
    RAP.on("enemy_fire", "duels", function(ent, now)
        local d = DU.live[ent:get_index()]
        if d and not d.theirs then d.theirs = now - d.t0 end
    end)
    events.player_hurt:set(function(e)
        U.safe("duel hurt", function()
            local me = entity.get_local_player()
            local vic, att = entity.get(e.userid, true), entity.get(e.attacker, true)
            if not me or not vic or not att then return end
            if att == me and vic ~= me then local d = DU.live[vic:get_index()]; if d then d.dealt = d.dealt + (e.dmg_health or 0) end end
            if vic == me and att ~= me then local d = DU.live[att:get_index()]; if d then d.taken = d.taken + (e.dmg_health or 0) end end
        end)
    end)
    events.player_death:set(function(e)
        U.safe("duel death", function()
            local me = entity.get_local_player()
            local vic, att = entity.get(e.userid, true), entity.get(e.attacker, true)
            if not me or not vic then return end
            if vic == me then
                if att and att ~= me then close(att:get_index(), "lost") end
                for idx in pairs(DU.live) do close(idx, "apart") end
                -- разбор смерти
                local AA, W = RAP.aa, RAP.W
                local okt, ts = pcall(common.get_unixtime)
                local tc = att and RAP.TC[att:get_index()]
                local row = { v = RAP.VERSION, t = okt and ts or 0, hs = e.headshot and 1 or 0, w = tostring(e.weapon or "?"),
                    prof = AA.cur and AA.cur.name or "-", grp = AA.group or "?", st = W.state or "?", side = AA.flip and "R" or "L",
                    def = (AA.def and globals.curtime >= AA.def and globals.curtime - AA.def < 0.3) and 1 or 0, dt = (W.charge or 0) >= 1 and 1 or 0,
                    brute = AA.brute and 1 or 0, man = AA.manual or 0, spd = W.vel and U.round(W.vel:length2d()) or 0,
                    dist = tc and tc.geo.dist and U.round(tc.geo.dist) or nil, eaat = tc and tc.aa.type or "?" }
                DU.deaths[#DU.deaths + 1] = row
                if #DU.deaths > 150 then table.remove(DU.deaths, 1) end
                RAP.store.mark(KEY)
            elseif att == me then close(vic:get_index(), "won")
            else close(vic:get_index(), "apart") end
        end)
    end)
    RAP.on("round", "duels", function() for idx in pairs(DU.live) do close(idx, "apart") end end)
    RAP.on("save", "duels", function(force) if RAP.store.need(KEY, force) then RAP.store.set(KEY, { list = DU.deaths }) end end)
    RAP.resets.deaths = function() DU.deaths = {} end

    local function median(t) if #t == 0 then return nil end; table.sort(t); return t[math.floor(#t / 2) + 1] end
    function DU.report()
        local n, won, lost, first, first_won, nfirst, nfirst_won = 0, 0, 0, 0, 0, 0, 0
        local ours, theirs = {}, {}
        for _, d in ipairs(DU.done) do
            if d.outcome ~= "apart" then
                n = n + 1
                if d.outcome == "won" then won = won + 1 else lost = lost + 1 end
                local we_first = d.ours and (not d.theirs or d.ours <= d.theirs)
                if we_first then first = first + 1; if d.outcome == "won" then first_won = first_won + 1 end
                else nfirst = nfirst + 1; if d.outcome == "won" then nfirst_won = nfirst_won + 1 end end
            end
            if d.ours then ours[#ours + 1] = U.round(d.ours * 1000) end
            if d.theirs then theirs[#theirs + 1] = U.round(d.theirs * 1000) end
        end
        if n == 0 then U.log("report", "duels: no finished duels yet"); return end
        U.log("report", "duels: %d decided, won %d (%.0f%%)  |  you fired first in %.0f%%", n, won, won / n * 100, first / n * 100)
        U.log("report", "  won when you fired first: %s  |  won when the enemy fired first: %s",
            first > 0 and string.format("%.0f%% of %d", first_won / first * 100, first) or "-",
            nfirst > 0 and string.format("%.0f%% of %d", nfirst_won / nfirst * 100, nfirst) or "-")
        local mo, mt = median(ours), median(theirs)
        U.log("report", "  time to first shot after the enemy appears (median): you %s, enemy %s",
            mo and (mo .. " ms") or "-", mt and (mt .. " ms") or "-")
    end
    local function cut(rows, field, label)
        local g, order = {}, {}
        for _, r in ipairs(rows) do
            local k = tostring(r[field])
            if not g[k] then g[k] = { n = 0, hs = 0 }; order[#order + 1] = k end
            g[k].n = g[k].n + 1; g[k].hs = g[k].hs + (r.hs or 0)
        end
        table.sort(order, function(a, b) return g[a].n > g[b].n end)
        local parts = {}
        for _, k in ipairs(order) do parts[#parts + 1] = string.format("%s %d (HS %.0f%%)", k, g[k].n, g[k].hs / g[k].n * 100) end
        U.log("deaths", "  by %-14s %s", label, table.concat(parts, ", "))
    end
    function DU.deaths_report()
        local rows = {}
        for _, r in ipairs(DU.deaths) do if r.v == RAP.VERSION then rows[#rows + 1] = r end end
        if #rows == 0 then rows = DU.deaths end
        if #rows == 0 then U.log("deaths", "no deaths recorded"); return end
        local hs, def, dt = 0, 0, 0
        for _, r in ipairs(rows) do hs, def, dt = hs + r.hs, def + r.def, dt + r.dt end
        U.log("deaths", "%d deaths: headshot %.0f%% | defensive active %.0f%% | DT charged %.0f%%", #rows, hs / #rows * 100, def / #rows * 100, dt / #rows * 100)
        cut(rows, "prof", "AA profile:"); cut(rows, "st", "your state:"); cut(rows, "side", "desync side:")
        cut(rows, "w", "enemy weapon:"); cut(rows, "eaat", "enemy AA:")
    end
    RAP.cmd.deaths = function() DU.deaths_report() end
end
---------------------------------------------------------------- rage: меню
do
    local G1 = RAP.menu.group("Rage", "Rage control", 1)
    G1.switch("rage.on", "Script rage control", true, { tip = "Off: the script does not touch your ragebot at all." })
    G1.switch("rage.adapt", "Adaptive hitchance", true, { tip = "Spread misses raise hitchance a little, hits bring it back to base." })
    G1.slider("rage.hc_max", "Adaptive hitchance: max", 40, 100, 78, 1, "%", { adv = true, dep = function() return RAP.v("rage.adapt") end })
    G1.slider("rage.air_hc", "In-air hitchance (0 = keep)", 0, 100, 0, 1, "%", { adv = true })
    G1.switch("rage.dmg_on", "Min damage override", false)
    G1.slider("rage.dmg_val", "Override damage", 1, 126, 10, 1, nil, { dep = function() return RAP.v("rage.dmg_on") end,
        tip = "Over 100 = HP + (value - 100)." })
    G1.bind("rage.dmg_key", "Min damage override key", { dep = function() return RAP.v("rage.dmg_on") end })
    G1.switch("rage.per_wpn", "Per-weapon hitchance / damage / multipoint", false)
    G1.combo("rage.wsel", "Weapon group", { "Scout", "AWP", "Auto", "Deagle", "Revolver", "Pistol", "other" },
        { dep = function() return RAP.v("rage.per_wpn") end })
    for _, wg in ipairs({ "Scout", "AWP", "Auto", "Deagle", "Revolver", "Pistol", "other" }) do
        local d = function() return RAP.v("rage.per_wpn") and RAP.v("rage.wsel") == wg end
        G1.slider("rage.hc_" .. wg, "[" .. wg .. "] Hitchance (0 = keep)", 0, 100, 0, 1, "%", { dep = d })
        G1.slider("rage.dmg_" .. wg, "[" .. wg .. "] Min damage (0 = keep)", 0, 126, 0, 1, nil, { dep = d })
        G1.slider("rage.mph_" .. wg, "[" .. wg .. "] Head scale (0 = keep)", 0, 100, 0, 1, "%", { dep = d })
        G1.slider("rage.mpb_" .. wg, "[" .. wg .. "] Body scale (0 = keep)", 0, 100, 0, 1, "%", { dep = d })
    end

    local G2 = RAP.menu.group("Rage", "Strategy AI (resolver + brain)", 2)
    G2.switch("st.on", "Strategy AI", true, { tip = "For every enemy x weapon x enemy AA type it learns which strategy hits: default, head focus, small multipoint, prefer / force safe point, prefer / force body. Switches only with statistical confidence." })
    local son = function() return RAP.v("st.on") end
    G2.switch("st.ctx", "Learn per weapon", true, { dep = son, adv = true })
    G2.switch("st.pop", "Start new enemies from population", true, { dep = son, adv = true,
        tip = "A new enemy starts from what worked against other enemies with the same AA type." })
    G2.slider("st.mph", "Small multipoint: head scale", 20, 100, 50, 1, "%", { dep = son, adv = true })
    G2.slider("st.mpb", "Small multipoint: body scale", 20, 100, 60, 1, "%", { dep = son, adv = true })
    G2.switch("st.logs", "Log strategy decisions", false, { dep = son })
    G2.switch("rs.onshot", "Head allowed on enemy on-shot", true, { tip = "Right after the target fires its desync is minimal: body preference is dropped." })
    G2.switch("rs.dt_body", "DT charged: prefer body on low HP", true)
    G2.slider("rs.dt_hp", "DT body HP", 20, 100, 70, 1, nil, { adv = true })
    G2.switch("rs.low_body", "Force body under HP", true)
    G2.slider("rs.low_hp", "Force body HP", 10, 100, 45, 1, nil, { adv = true })
end

---------------------------------------------------------------- rage: классификатор AA врага
-- JITTER - сторона / yaw прыгает часто, WIDE - большой разрыв головы и тела, STATIC - остальное (~24 замера)
do
    local U = RAP.U
    local C = { d = {} }
    RAP.aat = C
    local n = 0
    RAP.on("tick", "aa classifier", function()
        if not RAP.W.alive then return end
        n = n + 1
        if n % 2 ~= 0 then return end
        for _, en in ipairs(RAP.W.enemies) do
            if not en.dormant then
                local ok, st = pcall(en.ent.get_anim_state, en.ent)
                if ok and st and st.eye_yaw and st.abs_yaw then
                    local a = C.d[en.idx]
                    if not a or a.pid ~= en.pid then a = { f = {}, m = {}, pid = en.pid }; C.d[en.idx] = a end
                    local d = U.norm(st.eye_yaw - st.abs_yaw)
                    local flip = 0
                    if a.le and U.abs(U.norm(st.eye_yaw - a.le)) > RAP.CFG.aat.flip_deg then flip = 1 end
                    if a.ld and ((a.ld > 5 and d < -5) or (a.ld < -5 and d > 5)) then flip = 1 end
                    a.f[#a.f + 1], a.m[#a.m + 1] = flip, U.abs(d)
                    if #a.f > RAP.CFG.aat.window then table.remove(a.f, 1); table.remove(a.m, 1) end
                    a.le, a.ld, a.t, a.cur = st.eye_yaw, d, globals.curtime, U.abs(d)
                end
            end
        end
    end, 10)
    -- сырая оценка по окну: тип, подтип (быстрый / медленный jitter), уверенность
    local function raw(a)
        local cnt = #a.f
        if cnt < 8 then return nil end
        local fl, sm = 0, 0
        for i = 1, cnt do fl, sm = fl + a.f[i], sm + a.m[i] end
        local K = RAP.CFG.aat
        local width = sm / cnt
        if fl >= K.jitter_flips then
            local rate = fl / cnt
            return "jitter", rate >= 0.5 and "fast jitter" or "slow jitter", U.clamp((fl - K.jitter_flips + 2) / (K.jitter_flips + 2), 0.3, 1), width
        end
        if width >= K.wide then return "wide", fl >= 2 and "unstable wide" or "wide", U.clamp((width - K.wide) / 15 + 0.5, 0.3, 1), width end
        return "static", fl >= 2 and "mixed" or "static", U.clamp(1 - fl / K.jitter_flips, 0.3, 1), width
    end
    -- тип меняется только если новая оценка держится 2 оценки подряд (гистерезис) -> смена фиксируется как изменение поведения
    function C.type(idx)
        local a = idx and C.d[idx]
        if not a or globals.curtime - (a.t or 0) > 2 then return nil end
        if a.eval_t ~= a.t then
            a.eval_t = a.t
            local ty, sub, conf, width = raw(a)
            if ty then
                local now = globals.curtime
                if ty == a.type then a.pend = nil
                elseif ty == a.pend then
                    if now - a.pend_t >= RAP.CFG.aat.hold then
                        a.prev, a.changed_at = a.type, now
                        a.type, a.pend = ty, nil
                    end
                elseif not a.type then a.type = ty
                else a.pend, a.pend_t = ty, now end
                a.sub, a.conf, a.width = sub, conf, width
                local t = RAP.TC and RAP.TC[idx]
                if t then t.aa.type, t.aa.sub, t.aa.conf, t.aa.width, t.aa.prev, t.aa.changed_at = a.type, sub, conf, width, a.prev, a.changed_at end
            end
        end
        return a.type
    end
    function C.delta(idx) local a = C.d[idx]; return a and a.cur or 0 end
    RAP.on("level", "aa classifier", function() C.d = {} end)
end
---------------------------------------------------------------- Strategy AI: resolver + brain в одной модели
-- Для каждой гипотезы "враг x оружие x тип AA врага" хранится статистика 7 стратегий: попытки, попадания (в голову /
-- в тело), промахи по причинам. Стратегия выбирается по апостериорной оценке (Beta) с приором от всех врагов того же
-- типа AA. Переключение - только при статистической уверенности (CFG.strategy.confidence), после серии промахов
-- (panic_misses) или как осознанный эксперимент (explore). Учатся только промахи, которые говорят о стратегии:
-- correction / misprediction / prediction error. Spread -> adaptive hitchance, backtrack failure -> lag, остальное - шум.
do
    local U = RAP.U
    local KEY, OLD = "rap2_strat", "rage_aa_pro_rbrain_v25"
    local ARMS = { "Default", "Head focus", "Small multipoint", "Prefer safe", "Force safe", "Prefer body", "Force body" }
    local ST = { ctx = {}, pop = {}, corr = {}, T = {}, sess = {}, ARMS = ARMS }
    RAP.strat = ST
    local LEARN = { correction = true, misprediction = true, ["prediction error"] = true }
    ST.LEARN = LEARN
    local function C() return RAP.CFG.strategy end

    local ACT = { s = nil, set = {} }
    local function active(a)
        local cfg = tostring(RAP.CFG.strategy.arms or "")
        if ACT.s ~= cfg then
            ACT.s, ACT.set = cfg, {}
            for n in cfg:gmatch("%d+") do ACT.set[tonumber(n)] = true end
            if not next(ACT.set) then ACT.set = { [1] = true } end
        end
        return ACT.set[a] == true
    end
    local function arm_ok(a)
        if not active(a) then return false end
        local O = RAP.ref.OPT
        if a == 4 then return O.sp_prefer ~= nil elseif a == 5 then return O.sp_force ~= nil
        elseif a == 6 then return O.ba_prefer ~= nil elseif a == 7 then return O.ba_force ~= nil end
        return true
    end
    ST.arm_ok = arm_ok
    local function new_arms()
        local t = {}
        -- w2: сумма квадратов весов (для эффективного объема выборки, см. RAP.dl.n_info)
        for a = 1, #ARMS do t[a] = { h = 0, m = 0, w2 = 0, att = 0, hits = 0, hh = 0, bh = 0, corr = 0, mis = 0, pe = 0 } end
        return t
    end
    local function ctx_entry(key)
        local e = ST.ctx[key]
        if not e then e = { arms = new_arms(), ts = 0 }; ST.ctx[key] = e end
        local ok, t = pcall(common.get_unixtime)
        e.ts = ok and t or e.ts
        return e
    end
    local function pop_entry(key)
        local p = ST.pop[key]
        if not p then p = {}; for a = 1, #ARMS do p[a] = { h = 0, m = 0 } end; ST.pop[key] = p end
        return p
    end

    -- загрузка: формат v43 или импорт rage brain v25-v42 (Default / Head focus / Prefer body / Prefer safe)
    do
        local d = RAP.store.get(KEY)
        if d and type(d.ctx) == "table" then
            for k, e in pairs(d.ctx) do
                if type(k) == "string" and type(e) == "table" and type(e.arms) == "table" then
                    local ne = { arms = new_arms(), ts = tonumber(e.ts) or 0, dts = U.num(e.dts, 0) }
                    for a = 1, #ARMS do
                        local x = e.arms[a] or e.arms[tostring(a)]
                        if type(x) == "table" then for f in pairs(ne.arms[a]) do ne.arms[a][f] = U.num(x[f], 0, 1e5) or 0 end end
                    end
                    ST.ctx[k] = ne
                end
            end
            if type(d.pop) == "table" then
                for k, p in pairs(d.pop) do
                    if type(k) == "string" and type(p) == "table" then
                        local np = pop_entry(k)
                        for a = 1, #ARMS do local x = p[a] or p[tostring(a)]; if type(x) == "table" then np[a].h, np[a].m = U.num(x.h, 0, 1e5) or 0, U.num(x.m, 0, 1e5) or 0 end end
                    end
                end
            end
            if type(d.corr) == "table" then for k, v in pairs(d.corr) do local x = U.num(v, 0, 1e4); if x then ST.corr[k] = x end end end
            -- затухание по времени: опыт старше half_life_days весит вдвое меньше (оценка, не счетчики)
            -- v52: отсчет от dts - момента, до которого затухание уже применено. Раньше каждая загрузка заново
            -- применяла затухание за весь возраст записи (ts не менялся), и частые перезагрузки стирали опыт.
            local okt, now = pcall(common.get_unixtime)
            if okt and now and now > 0 then
                local hl = U.max(0.5, RAP.CFG.strategy.half_life_days) * 86400
                for _, e in pairs(ST.ctx) do
                    local age = now - U.max(e.ts or now, e.dts or 0)
                    if age > 3600 then
                        local w = 0.5 ^ (age / hl)
                        for a = 1, #ARMS do local x = e.arms[a]; x.h, x.m, x.w2 = x.h * w, x.m * w, x.w2 * w * w end
                        e.dts = now
                        RAP.store.mark(KEY)
                    end
                end
            end
        else
            local o = RAP.store.get(OLD)
            local MAP = { 1, 2, 6, 4 }
            local n = 0
            if o and type(o.pids) == "table" then
                for pid, e in pairs(o.pids) do
                    if type(e) == "table" and type(e.ctx) == "table" then
                        for c, arms in pairs(e.ctx) do
                            if type(arms) == "table" then
                                local ne = ctx_entry(pid .. "|" .. c .. "|unknown")
                                for m = 1, 4 do
                                    local x = arms[m]
                                    if type(x) == "table" and tonumber(x[1]) and tonumber(x[2]) then
                                        local a = ne.arms[MAP[m]]
                                        a.h, a.m = U.max(0, x[1] - 1), U.max(0, x[2] - 1)
                                        a.att = U.round(a.h + a.m); a.hits = U.round(a.h)
                                    end
                                end
                                n = n + 1
                            end
                        end
                        if tonumber(e.corr) then ST.corr[pid] = tonumber(e.corr) end
                    end
                end
            end
            if n > 0 then print(string.format("[strategy] imported %d enemy x weapon records from rage brain", n)) end
        end
    end

    local function ctx_of(en)
        local wg = RAP.v("st.ctx") and RAP.W.wgroup or "any"
        local aat = RAP.aat.type(en.idx)
        -- классификатор теряет данные через 2 с без видимости: раньше ключ менялся на "unknown", и при каждом
        -- выглядывании врага состояние цели (серия промахов, счетчик выстрелов, RELEARNING) сбрасывалось - panic
        -- почти не срабатывал. Последний известный тип того же врага с тем же оружием сохраняется.
        if not aat then
            local t = ST.T[en.idx]
            aat = (t and t.pid == en.pid and t.wg == wg and t.aat) or "unknown"
        end
        return en.pid .. "|" .. wg .. "|" .. aat, wg, aat
    end
    -- апостериорная оценка стратегии: Beta(1 + приор + бонус + попадания, 1 + приор + промахи)
    function ST.post(key, a, wg, aat)
        local c = C()
        local e = ST.ctx[key]
        local x = e and e.arms[a] or { h = 0, m = 0, w2 = 0 }
        local ph, pm = 0, 0
        if RAP.v("st.pop") then
            local P = ST.pop[wg .. "|" .. aat] or ST.pop[wg] or ST.pop.any
            if P then
                local pr = (P[a].h + 1) / (P[a].h + P[a].m + 2)
                ph, pm = pr * c.prior_weight, (1 - pr) * c.prior_weight
            end
        end
        if (aat == "jitter" and (a == 4 or a == 5)) or (aat == "wide" and (a == 6 or a == 7)) then ph = ph + c.aat_bias end
        local ss = ST.sess[key] and ST.sess[key][a]
        local sw = U.max(0, (c.session_weight or 2) - 1)
        local sh, sm = ss and ss.h * sw or 0, ss and ss.m * sw or 0
        local al, be = 1 + ph + x.h + sh, 1 + pm + x.m + sm
        local mean = al / (al + be)
        -- Неопределенность - только по уникальной информации: выстрелы сессии уже входят в x (их доп. вес меняет
        -- среднее, но не добавляет данных). Раньше дисперсия считалась по завышенным счетчикам -> ложная уверенность.
        -- v51: объем данных - эффективный: min(сумма весов, n_eff). Попадания в голову весят 1.5 и раньше выглядели
        -- как больше выстрелов, чем было. Старые записи без w2 считаются выборками с единичным весом.
        local n_x = RAP.dl.n_info(x.h + x.m, x.w2)
        local n_u = 2 + ph + pm + n_x
        return mean, mean * (1 - mean) / (n_u + 1), n_x
    end
    local function phi(z)
        local s, x = z < 0 and -1 or 1, U.abs(z) / 1.41421356
        local t = 1 / (1 + 0.3275911 * x)
        local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
        return 0.5 * (1 + s * y)
    end
    -- уверенность: P(стратегия b лучше a)
    function ST.p_better(key, b, a, wg, aat)
        local mb, vb = ST.post(key, b, wg, aat)
        local ma, va = ST.post(key, a, wg, aat)
        return phi((mb - ma) / U.sqrt(U.max(vb + va, 1e-6)))
    end
    -- Гистерезис с учетом неопределенности (общий принцип для стратегий и AA-профилей, см. RAP.switch_ok):
    -- переключиться можно, только если P(новая лучше) >= порога И разница оценок больше max(margin, 1 sd разницы).
    -- Мало данных -> sd большая -> нужен большой отрыв; 71% против 73% не переключает никогда.
    function RAP.switch_ok(m_new, v_new, m_cur, v_cur, p_better, p_need, margin)
        local gap = m_new - m_cur
        local need = U.max(margin, U.sqrt(U.max(v_new + v_cur, 0)))
        return p_better >= p_need and gap >= need, gap, need
    end
    function ST.should_switch(t, alt)
        local ma, va = ST.post(t.key, alt, t.wg, t.aat)
        local mc, vc = ST.post(t.key, t.arm, t.wg, t.aat)
        return (RAP.switch_ok(ma, va, mc, vc, ST.p_better(t.key, alt, t.arm, t.wg, t.aat), C().confidence, C().equal_margin))
    end
    local function best_arm(key, wg, aat, exclude)
        local best, bm = nil, -1
        for a = 1, #ARMS do
            -- откаченная (проверка показала "хуже") стратегия не выбирается block_s секунд
            if a ~= exclude and arm_ok(a) and not RAP.dl.blocked("strat", key, a) then local m = ST.post(key, a, wg, aat); if m > bm then best, bm = a, m end end
        end
        return best or 1
    end
    local function thompson(key, wg, aat)
        local best, bv = 1, -1e9
        for a = 1, #ARMS do
            if arm_ok(a) and not RAP.dl.blocked("strat", key, a) then
                local m, v = ST.post(key, a, wg, aat)
                local s = m + U.randn() * U.sqrt(v)
                if s > bv then best, bv = a, s end
            end
        end
        return best
    end

    -- машина состояний решения по цели: UNKNOWN -> PROBING -> CONFIDENT -> FAILED -> RELEARNING -> PROBING ...
    local function samples(key)
        local n = 0
        local e = ST.ctx[key]
        if e then for a = 1, #ARMS do n = n + e.arms[a].h + e.arms[a].m end end
        local ss = ST.sess[key]
        if ss then for a = 1, #ARMS do n = n + ss[a].h + ss[a].m end end
        return n
    end
    local function evaluate(t)
        local c = C()
        -- уверенность текущей стратегии: она не хуже ни одной другой больше чем на equal_margin, а все заметно
        -- худшие проигрывают ей с вероятностью >= confident_p. Почти равные стратегии (A ~ B) не мешают уверенности.
        local mc = ST.post(t.key, t.arm, t.wg, t.aat)
        local pmin, beaten = 1, false
        for a = 1, #ARMS do
            if a ~= t.arm and arm_ok(a) then
                local ma = ST.post(t.key, a, t.wg, t.aat)
                if ma > mc + c.equal_margin then beaten = true
                elseif ma < mc - c.equal_margin then pmin = U.min(pmin, ST.p_better(t.key, t.arm, a, t.wg, t.aat)) end
            end
        end
        t.pconf = beaten and 0 or pmin
        t.conf = mc
        t.samples = samples(t.key)
        if t.state == "RELEARNING" and t.relearn > 0 then  -- RELEARNING держится, пока не сделаны relearn_shots выстрелов
            t.state = "RELEARNING"
        elseif t.samples < 0.5 then t.state = "UNKNOWN"
        elseif not beaten and t.pconf >= c.confident_p and t.n >= c.min_samples then t.state = "CONFIDENT"
        elseif t.state ~= "FAILED" then t.state = "PROBING" end
        -- что произойдет дальше
        if t.state == "CONFIDENT" then t.next = string.format("keep %s (fails after %d misses in a row)", ARMS[t.arm], c.panic_misses - t.streak)
        else
            local alt = best_arm(t.key, t.wg, t.aat, t.arm)
            t.next = string.format("%d miss(es) -> %s", U.max(1, c.panic_misses - t.streak), ARMS[alt])
        end
        local tc = RAP.TC[t.idx]
        if tc then tc.learn = { arm = ARMS[t.arm], state = t.state, conf = t.conf, pconf = t.pconf, samples = t.samples, why = t.why, next = t.next } end
    end
    ST.evaluate = evaluate
    function ST.for_target(en)
        if not RAP.v("st.on") or not en or not en.pid or not RAP.W.learn(en.pid) then return nil end
        local key, wg, aat = ctx_of(en)
        local t = ST.T[en.idx]
        if t and t.key == key and not arm_ok(t.arm) then t.arm, t.n, t.why, t.switched = best_arm(key, wg, aat), 0, "strategy disabled in CFG", true end
        if not t or t.key ~= key then
            local tc = RAP.TC[en.idx]
            local changed = t and t.pid == en.pid and t.wg == wg and t.aat ~= aat and t.aat ~= "unknown" and aat ~= "unknown"
                and tc and (tc.aa.conf or 0) >= RAP.CFG.aat.change_conf
            t = { idx = en.idx, pid = en.pid, key = key, wg = wg, aat = aat, arm = best_arm(key, wg, aat), n = 0, streak = 0,
                why = changed and "enemy AA changed" or "best estimate", state = changed and "RELEARNING" or "UNKNOWN",
                relearn = changed and C().relearn_shots or 0 }
            ST.T[en.idx] = t
            evaluate(t)
            if changed and RAP.v("st.logs") then U.log("strategy", "%s: enemy AA changed -> relearning", key) end
        end
        return t
    end
    local function switch(t, arm, why)
        if arm == t.arm then return end
        local old = t.arm
        local pm, pv = ST.post(t.key, old, t.wg, t.aat)
        RAP.dl.record("strat", t.key, old, arm, why, { conf = ST.p_better(t.key, arm, old, t.wg, t.aat), pre_m = pm, pre_v = pv, lf = ARMS[old], lt = ARMS[arm] })
        t.arm, t.n, t.why, t.switched = arm, 0, why, true
        if RAP.v("st.logs") then
            local m = ST.post(t.key, arm, t.wg, t.aat)
            U.log("strategy", "%s [%s]: %s -> %s (%s, estimate %.0f%%)", t.key, t.state, ARMS[old], ARMS[arm], why, m * 100)
        end
    end

    -- выстрел учится на стратегии, которая реально стояла в рагеботе в момент выстрела (настройки общие для всех
    -- целей), и записывается в контекст той цели, в которую стреляли. Раньше выстрелы не по текущей угрозе
    -- оставались без стратегии ("-" в отчете) и не учили модель.
    -- Действовала ли стратегия на самом деле: ее голоса должны были победить в арбитре на всех ее пунктах
    -- (иначе их перебили on-shot / DT lethal / low HP / shot pressure / бинд пользователя, и выстрел - не про нее).
    local ARM_KEYS = { [2] = { "mp_head" }, [3] = { "mp_head", "mp_body" }, [4] = { "safe_points" },
        [5] = { "safe_points", "mp_head", "mp_body" }, [6] = { "body_aim" }, [7] = { "body_aim" } }
    function ST.effective(arm)
        local keys = ARM_KEYS[arm]
        if not keys then return true end
        for _, k in ipairs(keys) do
            if not RAP.ref.rage[k] then goto skip end          -- пункта нет в этой сборке чита - не проверяется
            local w = RAP.arb.why[k]
            local src = w and w.value ~= nil and tostring(w.src) or nil
            if not src or src:sub(1, 9) ~= "strategy:" then return false, k .. " <- " .. tostring(w and w.src or "-") end
            ::skip::
        end
        return true
    end
    RAP.on("our_fire", "strategy", function(rec)
        rec.ctx.aat = rec.idx and RAP.aat.type(rec.idx) or nil
        if not rec.idx or not RAP.v("st.on") then return end
        local t = ST.T[rec.idx]
        if not t then
            for _, en in ipairs(RAP.W.enemies) do if en.idx == rec.idx then t = ST.for_target(en) end end
        end
        if not t then return end
        local applied = ST.applied or t.arm
        rec.ctx.mode, rec.ctx.arm, rec.ctx.key, rec.ctx.wg, rec.ctx.aatk = ARMS[applied], applied, t.key, t.wg, t.aat
        rec.ctx.changed, rec.ctx.why = t.switched == true, t.why
        rec.ctx.conf = select(1, ST.post(t.key, applied, t.wg, t.aat))
        rec.ctx.eff, rec.ctx.eff_why = ST.effective(applied)
        if ST.applied == nil then rec.ctx.eff, rec.ctx.eff_why = applied == 1, "no strategy was applied (target was not the threat)" end
        t.switched = false
    end)
    -- Shot attribution: насколько этот выстрел говорит о стратегии (вес 0..1), считается до обучения и журнала (prio 10).
    --   Промахи: correction 1.0, misprediction 0.5, prediction error 0.35; spread / backtrack failure / damage rejection /
    --   unregistered / death - 0 (не учат: причина не в выборе хитбокса). Попадание - 1.0.
    --   Понижающие множители: тип AA цели неуверен (< 50%) x0.7, тип AA цели сменился < 2 с назад x0.5,
    --   глубокий backtrack (> 6 тиков) x0.7, ты стрелял в прыжке x0.8.
    -- базовые веса причин промаха - в CFG.attr (меняются: /eclipse cfg attr.<имя> <значение>)
    local ATTR_KEY = { correction = "correction", misprediction = "misprediction", ["prediction error"] = "prediction_error" }
    ST.ATTR_KEY = ATTR_KEY
    function ST.attr_w(state)
        if state == nil then return 1 end
        local k = ATTR_KEY[state]
        return k and RAP.CFG.attr[k] or 0
    end
    function ST.attribution(rec, e)
        local ok = e.state == nil
        local w = ST.attr_w(e.state)
        rec.ctx.bw = w
        local why = {}
        if w <= 0 then return 0, "miss reason '" .. tostring(e.state) .. "' does not depend on strategy" end
        if rec.burst then w = w * RAP.CFG.attr.burst; why[#why + 1] = "DT burst follow-up" end
        if rec.ctx.eff == false then return 0, "strategy was overridden: " .. tostring(rec.ctx.eff_why) end
        local tc = rec.idx and RAP.TC[rec.idx]
        local now = globals.curtime
        if tc and (tc.aa.conf or 0) < 0.5 then w = w * 0.7; why[#why + 1] = "target AA type unsure" end
        if tc and tc.aa.changed_at and now >= tc.aa.changed_at and now - tc.aa.changed_at < 2 then w = w * 0.5; why[#why + 1] = "target AA just changed" end
        if (e.backtrack or 0) > 6 then w = w * 0.7; why[#why + 1] = "deep backtrack" end
        if rec.mst == "air" or rec.mst == "airduck" then w = w * 0.8; why[#why + 1] = "you shot in the air" end
        return w, #why > 0 and table.concat(why, ", ") or (ok and "hit" or "resolver miss")
    end
    RAP.on("our_ack", "attribution", function(rec, e)
        local w, why = ST.attribution(rec, e)
        rec.ctx.attr, rec.ctx.attr_why = w, why
        RAP.CONF = RAP.CONF or {}
        RAP.CONF.shot = { w = w, why = why, r = e.state or "hit", t = globals.realtime }
    end, 10)
    RAP.on("our_ack", "strategy", function(rec, e)
        local ok = e.state == nil
        RAP.store.mark(KEY)
        if rec.pid then
            local cr = ST.corr[rec.pid] or 0
            if e.state == "correction" then cr = cr + 1 elseif ok then cr = U.max(0, cr - 0.5) end
            ST.corr[rec.pid] = cr
        end
        local arm, key = rec.ctx.arm, rec.ctx.key
        if not arm or not key or not RAP.v("st.on") then return end
        local cw = rec.ctx.attr
        if cw == nil then cw = (ok or LEARN[e.state]) and 1 or 0 end
        if cw <= 0 then return end
        local c = C()
        local en = ctx_entry(key)
        local dk = c.decay ^ cw
        for a = 1, #ARMS do local x = en.arms[a]; x.h, x.m = x.h * dk, x.m * dk end
        local x = en.arms[arm]
        x.att = x.att + 1
        -- ценность попадания: голова весит больше, "царапина" (урон < половины желаемого) меньше - стратегия
        -- оценивается по тому, сколько урона она реально приносит, а не только по факту попадания
        local wt = 1
        if ok then
            if e.hitgroup == 1 then wt = 1.5
            elseif (e.wanted_damage or 0) > 0 and (e.damage or 0) < 0.5 * e.wanted_damage then wt = 0.6 end
        end
        if ok then
            x.h, x.hits = x.h + wt * cw, x.hits + 1
            if e.hitgroup == 1 then x.hh = x.hh + 1 else x.bh = x.bh + 1 end
        else
            x.m = x.m + cw
            if e.state == "correction" then x.corr = x.corr + 1 elseif e.state == "misprediction" then x.mis = x.mis + 1 else x.pe = x.pe + 1 end
        end
        local ss = ST.sess[key]
        if not ss then ss = {}; for a = 1, #ARMS do ss[a] = { h = 0, m = 0 } end; ST.sess[key] = ss end
        if ok then ss[arm].h = ss[arm].h + wt * cw else ss[arm].m = ss[arm].m + cw end
        local pdk = c.pop_decay ^ cw
        for _, pk in ipairs({ rec.ctx.wg .. "|" .. rec.ctx.aatk, rec.ctx.wg, "any" }) do
            local P = pop_entry(pk)
            for a = 1, #ARMS do P[a].h, P[a].m = P[a].h * pdk, P[a].m * pdk end
            if ok then P[arm].h = P[arm].h + wt * cw else P[arm].m = P[arm].m + cw end
        end
        -- проверка последней смены по этой гипотезе (журнал решений): исход выстрела с весом атрибуции.
        -- Вердикт "хуже" откатывает смену (DL.rb.strat) - тогда arm ~= t.arm и ниже решение не принимается.
        RAP.dl.outcome("strat", key, arm, ok, cw)
        -- решение о смене (зависит от состояния)
        local t = rec.idx and ST.T[rec.idx]
        if not t or t.key ~= key then return end
        if arm ~= t.arm then evaluate(t); return end      -- стреляли с чужой стратегией (другая цель): учим статистику, но не решаем
        t.n = t.n + 1
        -- серия промахов для panic: считаются только промахи с весом >= 0.5 (слабо атрибутированные не толкают к смене)
        if ok then t.streak = 0 elseif cw >= 0.5 then t.streak = t.streak + 1 end
        if t.relearn > 0 then t.relearn = t.relearn - 1 end
        local was = t.state
        local alt = best_arm(key, t.wg, t.aat, t.arm)
        if t.streak >= c.panic_misses then
            if was == "CONFIDENT" then
                -- уверенная стратегия провалилась: старый опыт по этому врагу ослабляется, больше экспериментов
                t.state, t.relearn = "FAILED", c.relearn_shots
                for a = 1, #ARMS do en.arms[a].h, en.arms[a].m = en.arms[a].h * 0.5, en.arms[a].m * 0.5 end
                switch(t, alt, string.format("confident strategy failed (%d misses)", t.streak))
                t.state = "RELEARNING"
            else
                switch(t, alt, string.format("%d misses in a row", t.streak))
            end
            t.streak = 0
        elseif t.n >= c.min_samples and ST.should_switch(t, alt) then
            local ma, mc = ST.post(key, alt, t.wg, t.aat), ST.post(key, t.arm, t.wg, t.aat)
            switch(t, alt, string.format("%.0f%% vs %.0f%%, confident %.0f%% better", ma * 100, mc * 100, ST.p_better(key, alt, t.arm, t.wg, t.aat) * 100))
        else
            local ex = (was == "CONFIDENT") and c.explore_confident or c.explore_probing
            t.cool = (t.cool or 0) - 1
            if t.cool <= 0 and U.rand(1, 1000) <= ex * 1000 then
                local th = thompson(key, t.wg, t.aat)
                if th ~= t.arm then switch(t, th, "exploration"); t.cool = c.explore_cooldown end
            end
        end
        evaluate(t)
    end)
    -- откат смены стратегии, которую проверка признала хуже (RAP.dl): цель с той же гипотезой, где все еще стоит d.to
    RAP.dl.rb.strat = function(d)
        for _, t in pairs(ST.T) do
            if t.key == d.key and t.arm == d.to then
                switch(t, d.from, "rollback: " .. tostring(d.lt) .. " was worse")
                return true
            end
        end
        return false
    end
    RAP.on("level", "strategy", function() ST.T, ST.sess = {}, {} end)
    RAP.resets.strategy = function() ST.ctx, ST.pop, ST.corr, ST.sess, ST.T = {}, {}, {}, {}, {} end
    RAP.on("save", "strategy", function(force)
        if not RAP.v("main.persist") or not RAP.store.need(KEY, force) then return end
        local list = {}
        for k, e in pairs(ST.ctx) do
            local pid = k:match("^(.-)|")
            if RAP.W.learn(pid) then list[#list + 1] = { k, e.ts or 0 } else ST.ctx[k] = nil end
        end
        if #list > 300 then
            table.sort(list, function(a, b) return a[2] > b[2] end)
            for i = 301, #list do ST.ctx[list[i][1]] = nil end
        end
        -- v52: corr (correction-промахи по врагу) рос без ограничения по всем встреченным игрокам - держим только
        -- врагов, у которых остался контекст; дробные счетчики - 3 знака (база ~25% меньше, лимит 768 KB дальше)
        local live = {}
        for k, e in pairs(ST.ctx) do
            local pid = k:match("^(.-)|")
            if pid then live[pid] = true end
            for a = 1, #ARMS do
                local x = e.arms[a]
                x.h, x.m, x.w2 = U.round(x.h * 1000) / 1000, U.round(x.m * 1000) / 1000, U.round(x.w2 * 1000) / 1000
            end
        end
        for pid, v in pairs(ST.corr) do
            if not live[pid] then ST.corr[pid] = nil else ST.corr[pid] = U.round(v * 100) / 100 end
        end
        RAP.store.set(KEY, { ctx = ST.ctx, pop = ST.pop, corr = ST.corr })
    end)
    -- консоль: стратегии против текущей цели / недавних врагов
    RAP.cmd.strat = function()
        local shown = 0
        local keys = {}
        for k, e in pairs(ST.ctx) do keys[#keys + 1] = { k, e.ts or 0 } end
        table.sort(keys, function(a, b) return a[2] > b[2] end)
        for i = 1, U.min(6, #keys) do
            local k = keys[i][1]
            local _, wg, aat = k:match("^(.-)|(.-)|(.*)$")
            print(string.format("[strategy] %s", k))
            for a = 1, #ARMS do
                local x = ST.ctx[k].arms[a]
                local m = ST.post(k, a, wg, aat)
                if x.att > 0 or a == 1 then
                    print(string.format("[strategy]   %-16s est %3.0f%%  shots %d  hit %d (head %d, body %d)  corr %d  mispred %d  pred %d",
                        ARMS[a], m * 100, x.att, x.hits, x.hh, x.bh, x.corr, x.mis, x.pe))
                end
            end
            shown = shown + 1
        end
        for idx, t in pairs(ST.T) do
            print(string.format("[strategy] target #%d now: %s (%s), %d shots on it, %d misses in a row", idx, ARMS[t.arm], t.why, t.n, t.streak))
        end
        if shown == 0 then print("[strategy] no data yet") end
    end
end
---------------------------------------------------------------- rage: голосование за тик
-- Приоритеты: 10 оружие (hc / dmg / multipoint) < 30 стратегия "prefer" < 40 on-shot < 45 DT lethal < 50 low HP
--             < 60 стратегия "force" < 70 min damage key. Бинд пользователя главнее всего (арбитр).
do
    local U = RAP.U
    local V = { hc_add = {}, last_shot = {}, why = "", base_seen = {} }
    RAP.ragev = V
    local HG_SNIPER = { Scout = true, AWP = true }

    RAP.on("enemy_fire", "onshot", function(ent, now) V.last_shot[ent:get_index()] = now end)
    RAP.on("our_ack", "adaptive hc", function(rec, e)
        local wg = rec.wgroup or RAP.W.wgroup
        if e.state == "spread" then V.hc_add[wg] = U.min(10, (V.hc_add[wg] or 0) + 2)
        elseif e.state == nil or e.state == "correction" then V.hc_add[wg] = U.max(0, (V.hc_add[wg] or 0) - 2) end
    end)

    local function find_threat()
        local thr = RAP.W.threat
        if not thr then return nil end
        local idx = thr:get_index()
        for _, en in ipairs(RAP.W.enemies) do if en.idx == idx then return en end end
        return nil
    end
    V.target = find_threat

    RAP.on("tick", "rage vote", function()
        if not RAP.W.alive or not RAP.v("rage.on") then return end
        local O = RAP.ref.OPT
        local wg = RAP.W.wgroup
        local now = globals.curtime
        -- оружие
        local base_hc, wpn_hc
        if RAP.v("rage.per_wpn") then
            local hc, dmg = RAP.v("rage.hc_" .. wg) or 0, RAP.v("rage.dmg_" .. wg) or 0
            local mph, mpb = RAP.v("rage.mph_" .. wg) or 0, RAP.v("rage.mpb_" .. wg) or 0
            if hc > 0 then base_hc, wpn_hc = hc, hc end
            if dmg > 0 then RAP.vote("min_damage", dmg, 10, "weapon " .. wg) end
            if mph > 0 then RAP.vote("mp_head", mph, 10, "weapon " .. wg) end
            if mpb > 0 then RAP.vote("mp_body", mpb, 10, "weapon " .. wg) end
        end
        if RAP.v("rage.adapt") then
            if not base_hc then
                -- база - твое значение на вкладке текущего оружия (у каждой вкладки свое, общее значение путало оружия)
                local wkey = RAP.W.wsub or "Global"
                local ok, cur = pcall(U.hc_cur)
                if RAP.arb.owned.hitchance then cur = nil end      -- свое значение не берем за базу
                if ok and type(cur) == "number" then V.base_seen[wkey] = cur end
                base_hc = V.base_seen[wkey]
            end
            local add = V.hc_add[wg] or 0
            -- надбавка только повышает: если твой hitchance уже выше потолка, он не снижается до потолка
            local adj = base_hc and U.max(base_hc, U.min(RAP.v("rage.hc_max") or 78, base_hc + add)) or nil
            if adj and adj > base_hc then RAP.vote("hitchance", adj, 12, "adaptive +" .. U.round(adj - base_hc))
            elseif wpn_hc then RAP.vote("hitchance", wpn_hc, 10, "weapon " .. wg) end
        elseif wpn_hc then
            RAP.vote("hitchance", wpn_hc, 10, "weapon " .. wg)
        end
        local air = RAP.v("rage.air_hc") or 0
        if air > 0 and (RAP.W.state == "air" or RAP.W.state == "airduck") then RAP.vote("hitchance", air, 20, "in air") end

        local en = find_threat()
        if en and not en.dormant then
            local idx, ent = en.idx, en.ent
            -- стратегия (Strategy AI)
            local t = RAP.strat.for_target(en)
            local arm = t and t.arm or 1
            RAP.strat.applied = t and arm or nil
            if arm == 2 then
                local mph = RAP.v("rage.mph_" .. wg) or 0
                RAP.vote("mp_head", U.min(100, mph > 0 and mph + 25 or 85), 30, "strategy: head focus")
            elseif arm == 3 or arm == 5 then
                RAP.vote("mp_head", RAP.v("st.mph") or 50, arm == 5 and 60 or 30, "strategy: small multipoint")
                RAP.vote("mp_body", RAP.v("st.mpb") or 60, arm == 5 and 60 or 30, "strategy: small multipoint")
            end
            if arm == 4 and O.sp_prefer then RAP.vote("safe_points", O.sp_prefer, 30, "strategy: prefer safe") end
            if arm == 5 and O.sp_force then RAP.vote("safe_points", O.sp_force, 60, "strategy: force safe") end
            if arm == 6 and O.ba_prefer then RAP.vote("body_aim", O.ba_prefer, 30, "strategy: prefer body") end
            if arm == 7 and O.ba_force then RAP.vote("body_aim", O.ba_force, 60, "strategy: force body") end
            -- сразу после выстрела цели десинк минимален: предпочтение корпуса снимается (голова разрешена)
            local ls = V.last_shot[idx]
            if RAP.v("rs.onshot") and ls and now >= ls and now - ls < 0.2 then RAP.vote("body_aim", false, 40, "enemy on-shot") end
            local hp = ent.m_iHealth or 100
            if RAP.v("rs.dt_body") and O.ba_prefer and not HG_SNIPER[wg] and RAP.W.charge >= 1 and RAP.ref.on(RAP.ref.dt)
                and hp <= (RAP.v("rs.dt_hp") or 70) then RAP.vote("body_aim", O.ba_prefer, 45, "DT lethal") end
            if RAP.v("rs.low_body") and O.ba_force and hp <= (RAP.v("rs.low_hp") or 45) then RAP.vote("body_aim", O.ba_force, 50, "low HP") end
            V.aat, V.mode, V.why = RAP.aat.type(idx), t and RAP.strat.ARMS[t.arm] or nil, t and t.why or nil
            V.conf = t and select(1, RAP.strat.post(t.key, t.arm, t.wg, t.aat)) or nil
        else
            RAP.strat.applied = nil
            V.aat, V.mode, V.why, V.conf = nil, nil, nil, nil
        end
        if RAP.v("rage.dmg_on") and RAP.v("rage.dmg_key") then RAP.vote("min_damage", RAP.v("rage.dmg_val") or 10, 70, "damage key") end
    end, 40)
    RAP.on("tick", "arbiter", function() RAP.arb.commit() end, 99)
    -- новая карта: время выстрела врага из прошлой карты давало "enemy on-shot" постоянно (curtime начался заново)
    RAP.on("level", "rage vote", function() V.last_shot = {} end)
end
---------------------------------------------------------------- shot pressure: рагебот не должен "висеть" на видимой цели
-- Цель видна, оружие готово (снайпер - в прицеле), а выстрела нет дольше stage1 -> ограничения скрипта смягчаются:
-- Force -> Prefer, малый multipoint и повышенный hitchance снимаются. Дольше stage2 -> все пункты рагебота
-- возвращаются к твоим настройкам, пока не будет выстрела. Сброс - на выстреле или потере цели.
-- В v42-v45 этой защиты не было: Force safe против jitter-врагов и поднятый hitchance давали "delay shot".
do
    local U = RAP.U
    local G = RAP.menu.group("Rage", "Rage control", 1)
    G.switch("rage.stall", "Shot pressure (never hang on a visible target)", true,
        { tip = "If the target is visible and the weapon is ready but nothing fires, the script relaxes its own restrictions step by step." })
    G.slider("rage.stall1", "Relax after", 150, 1500, 350, 1, "ms", { adv = true, dep = function() return RAP.v("rage.stall") end })
    G.slider("rage.stall2", "Release all after", 300, 3000, 800, 1, "ms", { adv = true, dep = function() return RAP.v("rage.stall") end })
    G.combo("rage.delay", "Cheat Delay Shot", { "Always off", "Off only while stalling", "Don't touch" },
        { tip = "Delay Shot waits for a tick where the resolver is more accurate: fewer correction misses, but later shots. Default: always off - shots come on time." })

    local SP = { since = nil, level = 0, stalls = 0, relief_shots = 0 }
    RAP.pressure = SP
    -- Delay Shot: разные сборки держат его в разных группах - ищем по нескольким путям на всех вкладках оружия
    local DS
    for _, p in ipairs({ { "Selection", "Delay Shot" }, { "Accuracy", "Delay Shot" }, { "Selection", "Hit Chance", "Delay Shot" }, { "Main", "Delay Shot" } }) do
        local P, n = RAP.ref.multi(p[1], p[2], p[3])
        if P then DS = P; RAP.ref.tabs.delay_shot = n; break end
    end
    RAP.ref.delay_shot = DS
    local DS_OWN = false
    RAP.on("our_fire", "pressure", function(rec)
        if SP.level > 0 then SP.relief_shots = SP.relief_shots + 1 end
        if SP.since then rec.ctx.rt = U.round((globals.curtime - SP.since) * 1000) end
        SP.since, SP.level = nil, 0
    end)
    RAP.on("tick", "shot pressure", function()
        local W = RAP.W
        -- Delay Shot
        if DS then
            local mode = RAP.v("rage.delay")
            local want = W.alive and RAP.v("rage.on") and not RAP.binds.is_active(DS.name) and (mode == "Always off" or (mode == "Off only while stalling" and SP.level >= 2))
            if want and not DS_OWN then DS.set_override(false); DS_OWN = true
            elseif not want and DS_OWN then DS.set_override(nil); DS_OWN = false end
        end
        if not W.alive then SP.since, SP.level = nil, 0; return end
        local now = globals.curtime
        local thr = W.threat
        local tc = thr and RAP.TC[thr:get_index()]
        local wpn, me = W.weapon, W.me
        local ready = wpn and (wpn.m_iClip1 or 1) > 0 and now >= (wpn.m_flNextPrimaryAttack or 0) and now >= (me.m_flNextAttack or 0)
        local scoped_ok = not (W.wgroup == "Scout" or W.wgroup == "AWP" or W.wgroup == "Auto") or me.m_bIsScoped
        local can = tc and not tc.dormant and tc.geo.visible and ready and scoped_ok
        if not can then SP.since, SP.level = nil, 0; return end
        SP.since = SP.since or now
        if not RAP.v("rage.stall") or not RAP.v("rage.on") then SP.level = 0; return end
        local dt = (now - SP.since) * 1000
        local lvl = dt >= (RAP.v("rage.stall2") or 800) and 2 or (dt >= (RAP.v("rage.stall1") or 350) and 1 or 0)
        if lvl > SP.level then SP.stalls = SP.stalls + (SP.level == 0 and 1 or 0) end
        SP.level = lvl
        if lvl == 0 then return end
        local O = RAP.ref.OPT
        if lvl == 1 then
            -- смягчение: Force -> Prefer, без малого multipoint и без надбавок к hitchance
            local w = RAP.arb.votes
            local sp, ba = w.safe_points, w.body_aim
            if sp and sp.value == O.sp_force then RAP.vote("safe_points", O.sp_prefer or false, 90, "shot pressure: relax") end
            if ba and ba.value == O.ba_force and not (ba.src or ""):find("low HP") then RAP.vote("body_aim", O.ba_prefer or false, 90, "shot pressure: relax") end
            RAP.vote("mp_head", false, 90, "shot pressure: relax"); RAP.vote("mp_body", false, 90, "shot pressure: relax")
            RAP.vote("hitchance", false, 90, "shot pressure: relax")
        else
            for _, k in ipairs({ "safe_points", "body_aim", "mp_head", "mp_body", "hitchance", "hitboxes", "ensure_safety" }) do
                RAP.vote(k, false, 95, "shot pressure: released")
            end
        end
    end, 90)
    -- база отклоняет запись (слишком большой ключ): обучение не сохраняется - видно сразу, а не только в консоли
    RAP.on("ind_rows", "db", function(add)
        if next(RAP.store.rejected) then add("DB FULL: LEARNING NOT SAVED", color(255, 110, 110), 1) end
    end)
    RAP.on("ind_rows", "pressure", function(add)
        if SP.level > 0 then add(SP.level == 2 and "PRESSURE: RELEASED" or "PRESSURE: RELAX", color(255, 200, 120), 2) end
    end)
    function SP.release_ds() if DS and DS_OWN then DS.set_override(nil); DS_OWN = false end end
    function SP.ds_owned() return DS_OWN end
    RAP.on("shutdown", "pressure", function() SP.release_ds() end)
end
---------------------------------------------------------------- AA: пункты чита и владение переопределениями
-- RAP.aaset(key, value): value = nil снимает наше переопределение. Все снимается при выключении / выгрузке.
do
    local f = RAP.ref.find
    local A = {
        enabled = f("Aimbot", "Anti Aim", "Angles", "Enabled"), pitch = f("Aimbot", "Anti Aim", "Angles", "Pitch"),
        yaw = f("Aimbot", "Anti Aim", "Angles", "Yaw"), base = f("Aimbot", "Anti Aim", "Angles", "Yaw", "Base"),
        offset = f("Aimbot", "Anti Aim", "Angles", "Yaw", "Offset"), avoid_bs = f("Aimbot", "Anti Aim", "Angles", "Yaw", "Avoid Backstab"),
        hidden = f("Aimbot", "Anti Aim", "Angles", "Yaw", "Hidden"), modifier = f("Aimbot", "Anti Aim", "Angles", "Yaw Modifier"),
        mod_offset = f("Aimbot", "Anti Aim", "Angles", "Yaw Modifier", "Offset"), body = f("Aimbot", "Anti Aim", "Angles", "Body Yaw"),
        left = f("Aimbot", "Anti Aim", "Angles", "Body Yaw", "Left Limit"), right = f("Aimbot", "Anti Aim", "Angles", "Body Yaw", "Right Limit"),
        body_opts = f("Aimbot", "Anti Aim", "Angles", "Body Yaw", "Options"), body_fs = f("Aimbot", "Anti Aim", "Angles", "Body Yaw", "Freestanding"),
        freestand = f("Aimbot", "Anti Aim", "Angles", "Freestanding"),
        fs_nomod = f("Aimbot", "Anti Aim", "Angles", "Freestanding", "Disable Yaw Modifiers"),
        fs_body = f("Aimbot", "Anti Aim", "Angles", "Freestanding", "Body Freestanding"),
    }
    local missing = {}
    for k, v in pairs(A) do if not v then missing[#missing + 1] = "aa." .. k end end
    for _, k in ipairs(missing) do RAP.ref.missing[#RAP.ref.missing + 1] = k end
    RAP.ref.aa = A
    local OWN, LAST = {}, {}
    function RAP.aaset(key, val)
        local it = A[key]
        if not it then return end
        if val == nil then
            if OWN[key] then pcall(it.override, it); OWN[key], LAST[key] = false, nil end
            return
        end
        if OWN[key] and RAP.U.same(LAST[key], val) then return end
        local ok = pcall(it.override, it, val)
        if ok then OWN[key], LAST[key] = true, val end
    end
    function RAP.aa_release()
        for k in pairs(A) do RAP.aaset(k, nil) end
        pcall(rage.antiaim.inverter, rage.antiaim, false)
    end
    function RAP.aa_owned() return OWN end
end
---------------------------------------------------------------- AA: профили (порядок как в v23-v38 - статистика AI переносится)
do
    local P = {
        { name = "Fast jitter", mode = "Jitter", offset = 0, range = 58, delay = 1, left = 58, right = 58 },
        { name = "Delay 3", mode = "Delay jitter", offset = 0, range = 70, delay = 3, left = 58, right = 58 },
        { name = "Delay 6 wide", mode = "Delay jitter", offset = 0, range = 96, delay = 6, left = 60, right = 60 },
        { name = "Sway", mode = "Sway", offset = 0, range = 84, delay = 1, left = 55, right = 55 },
        { name = "Random", mode = "Random", offset = 0, range = 110, delay = 1, left = 58, right = 58 },
        { name = "Left bias", mode = "Delay jitter", offset = -22, range = 52, delay = 4, left = 60, right = 40 },
        { name = "Right bias", mode = "Delay jitter", offset = 22, range = 52, delay = 4, left = 40, right = 60 },
        { name = "Defensive side", mode = "Delay jitter", offset = 0, range = 64, delay = 2, left = 58, right = 58,
            defensive = true, def_pitch = "Random", def_yaw = "Sideways" },
        { name = "Native A", native = true, mode = "Native", offL = -7, offR = 11, mod_off = -46, left = 45, right = 45 },
        { name = "Native wide", native = true, mode = "Native", offL = -30, offR = 34, mod_off = -58, left = 60, right = 60 },
        { name = "Native tight", native = true, mode = "Native", offL = -6, offR = 11, mod_off = -52, left = 36, right = 36 },
        { name = "Native air", native = true, mode = "Native", offL = -3, offR = 16, mod_off = -47, left = 58, right = 58 },
        { name = "3-Way", mode = "3-Way", offset = 0, range = 84, delay = 1, left = 58, right = 58 },
        { name = "5-Way", mode = "5-Way", offset = 0, range = 120, delay = 1, left = 58, right = 58 },
        { name = "Peek real", native = true, mode = "Native", offL = -9, offR = 13, mod_off = -48, left = 50, right = 50, bfs = "Peek Real" },
        { name = "Peek fake", native = true, mode = "Native", offL = -9, offR = 13, mod_off = -48, left = 50, right = 50, bfs = "Peek Fake" },
        { name = "Def ways", mode = "Delay jitter", offset = 0, range = 64, delay = 2, left = 58, right = 58,
            defensive = true, def_pitch = "PAKETA", def_yaw = "Ways custom" },
        { name = "Def flick", mode = "Delay jitter", offset = 0, range = 64, delay = 2, left = 58, right = 58,
            defensive = true, def_pitch = "Random", def_yaw = "Sideways", def_flick = true },
        { name = "Native def", native = true, mode = "Native", offL = -7, offR = 11, mod_off = -46, left = 50, right = 50,
            defensive = true, def_pitch = "Semi-Up", def_yaw = "Side-based" },
    }
    for k = 1, 6 do
        P[#P + 1] = { name = "Evo " .. k, evo = true, mode = "Delay jitter", offset = 0, range = 50 + k * 8, delay = 1 + k % 4, left = 58, right = 58 }
    end
    local NAMES = {}
    for i, p in ipairs(P) do NAMES[i] = p.name end
    RAP.profiles = { list = P, names = NAMES }
    RAP.AA_MODES = { "Jitter", "Delay jitter", "Sway", "Random", "3-Way", "5-Way", "Staged", "Native", "Static" }
    RAP.DEF_PITCH = { "Off", "Up", "Down", "Random", "Zero", "Semi-Up", "Semi-Down", "Jitter", "Spin", "Sway", "PAKETA" }
    RAP.DEF_YAW = { "Off", "Sideways", "Random", "Spin", "Opposite", "Opposite jitter", "Side-based", "3-Way", "5-Way", "Ways custom" }
end
---------------------------------------------------------------- AA: меню
do
    local G = RAP.menu.group("Anti-Aim", "Main", 1)
    local on = function() return RAP.v("aa.on") end
    G.switch("aa.on", "Script anti-aim", true)
    G.combo("aa.source", "Angles from", { "AI (learns profiles)", "Builder" }, { dep = on })
    G.combo("aa.pitch", "Pitch", { "Down", "Disabled", "Fake Down", "Fake Up" }, { dep = on, adv = true })
    G.switch("aa.at_target", "At target", true, { dep = on })
    G.switch("aa.avoid_bs", "Avoid backstab", true, { dep = on })
    G.switch("aa.legit", "Legit AA on use (E)", true, { dep = on })
    G.switch("aa.warmup", "Disable on warmup", false, { dep = on, adv = true })
    G.bind("aa.fs", "Freestanding", { dep = on })
    G.switch("aa.fs_nomod", "Freestanding: disable modifiers", true, { dep = on, adv = true })
    G.switch("aa.fsfix", "Better freestanding (edge fix)", true, { dep = on, adv = true,
        tip = "Turns freestanding off for a moment when it would point the real head at the enemy (target and freestand angles almost equal)." })
    G.bind("aa.man_l", "Manual left", { dep = on })
    G.bind("aa.man_r", "Manual right", { dep = on })
    G.bind("aa.man_b", "Manual back", { dep = on })
    G.combo("aa.brute", "Anti-brute", { "Smart (flip on hit)", "Classic (flip on near shot)", "Off" }, { dep = on,
        tip = "Smart: the side changes on a head hit or a 2nd hit by the same enemy within 8 s (max 3 changes in 15 s); a dodge keeps the side that worked." })
    G.slider("aa.brute_t", "Anti-brute time", 2, 12, 5, 1, "s", { dep = on, adv = true })
    G.combo("aa.lim", "Desync limit randomization", { "After getting hit", "Always", "Off" }, { dep = on })
    G.slider("aa.lim_min", "Randomization: lowest limit", 15, 58, 30, 1, nil, { dep = on, adv = true })
    G.switch("aa.def_peek", "Defensive on peek", true, { dep = on, tip = "Short defensive window when an enemy becomes able to hit you (DT charged)." })
    G.slider("aa.def_peek_t", "Defensive on peek time", 50, 400, 200, 1, "ms", { dep = on, adv = true })
    G.switch("aa.rand_delay", "Randomize jitter delay (+-1 tick)", true, { dep = on, adv = true,
        tip = "Delay jitter with a fixed period is predictable. Sometimes shifts the period by one tick." })
    G.switch("aa.def_smart","Defensive only with DT + threat", true, { dep = on, adv = true })
    G.switch("aa.safe_head", "Safe head (height advantage)", true, { dep = on })
    G.switch("aa.lowhp", "Low HP mode", false, { dep = on,
        tip = "At low HP any hit kills: freestanding (without jitter) while an enemy threatens you, and a 2x longer defensive-on-peek window." })
    G.slider("aa.lowhp_v", "Low HP threshold", 10, 100, 40, 1, nil, { dep = function() return on() and RAP.v("aa.lowhp") end, adv = true })

    -- билдер: свои настройки на каждое состояние
    local B = RAP.menu.group("Anti-Aim", "Builder", 2)
    -- "sniper" - отдельный набор против угрозы со снайперкой (scout / AWP / auto), поверх состояния движения
    local STATES = { "stand", "move", "slow", "air", "airduck", "duck", "sniper" }
    local bon = function() return RAP.v("aa.on") and RAP.v("aa.source") == "Builder" end
    B.switch("bld.sniper_on", "Use 'sniper' state vs snipers", false, { dep = bon,
        tip = "When the enemy that can hit you holds a scout / AWP / auto, the 'sniper' settings are used instead of your movement state." })
    B.combo("bld.state", "State", STATES, { dep = bon })
    for _, s in ipairs(STATES) do
        local p = "bld." .. s .. "."
        local d = function() return bon() and RAP.v("bld.state") == s end
        local dn = function() return d() and RAP.v(p .. "mode") == "Native" end
        local dj = function() return d() and RAP.v(p .. "mode") ~= "Native" end
        B.combo(p .. "mode", "[" .. s .. "] Mode", RAP.AA_MODES, { dep = d })
        B.slider(p .. "offset", "[" .. s .. "] Yaw offset", -60, 60, 0, 1, nil, { dep = dj })
        B.slider(p .. "range", "[" .. s .. "] Jitter range", 0, 120, 60, 1, nil, { dep = dj })
        B.slider(p .. "delay", "[" .. s .. "] Delay (ticks)", 1, 10, 2, 1, nil, { dep = dj })
        B.slider(p .. "delay_r", "[" .. s .. "] Delay right (0 = same)", 0, 10, 0, 1, nil, { dep = dj, adv = true })
        B.slider(p .. "offL", "[" .. s .. "] Native left offset", -60, 30, -7, 1, nil, { dep = dn })
        B.slider(p .. "offR", "[" .. s .. "] Native right offset", -30, 60, 11, 1, nil, { dep = dn })
        B.slider(p .. "mod_off", "[" .. s .. "] Native modifier", -90, 0, -46, 1, nil, { dep = dn })
        B.slider(p .. "left", "[" .. s .. "] Left limit", 0, 60, 58, 1, nil, { dep = d })
        B.slider(p .. "right", "[" .. s .. "] Right limit", 0, 60, 58, 1, nil, { dep = d })
        B.combo(p .. "bfs", "[" .. s .. "] Body freestanding", { "Off", "Peek Fake", "Peek Real" }, { dep = d, adv = true })
        B.switch(p .. "def", "[" .. s .. "] Defensive", false, { dep = d })
        B.combo(p .. "def_pitch", "[" .. s .. "] Defensive pitch", RAP.DEF_PITCH, { dep = function() return d() and RAP.v(p .. "def") end })
        B.combo(p .. "def_yaw", "[" .. s .. "] Defensive yaw", RAP.DEF_YAW, { dep = function() return d() and RAP.v(p .. "def") end })
        B.switch(p .. "def_flick", "[" .. s .. "] Defensive flick", false, { dep = function() return d() and RAP.v(p .. "def") end, adv = true })
    end

    local A = RAP.menu.group("Anti-Aim", "AI", 2)
    local aon = function() return RAP.v("aa.on") and RAP.v("aa.source") ~= "Builder" end
    A.multi("ai.pool", "Profiles in pool (empty = all)", RAP.profiles.names, { "Native A", "Native wide", "Native def", "Def flick",
        "Peek fake", "Delay 3" }, { dep = aon, tip = "Fewer profiles = faster learning: each profile needs several enemy shots to be judged. 5-7 is a good size." })
    A.switch("ai.merge", "Merge similar states (slow -> move, duck -> stand)", true, { dep = aon,
        tip = "3 groups instead of 5: every group gets more data, so the AI learns faster." })
    A.slider("ai.explore", "Exploration (max)", 0, 100, 30, 1, "%", { dep = aon, adv = true,
        tip = "Upper limit. Real share depends on uncertainty: full with little data, 40% / 25% / 10% of it as the best profile gets confident." })
    A.slider("ai.min_life", "Min. profile lifetime", 2, 20, 6, 1, "s", { dep = aon, adv = true,
        tip = "A profile stays at least this long before a normal switch (panic can still switch earlier)." })
    A.switch("ai.per_weapon", "Learn per enemy weapon", true, { dep = aon,
        tip = "Separate statistics against snipers / deagle / pistols / rifles / SMGs." })
    A.slider("ai.memory", "Memory", 80, 99, 95, 1, "%", { dep = aon, adv = true, tip = "How fast old results fade (higher = longer memory)." })
    A.switch("ai.per_enemy", "Learn per enemy", true, { dep = aon })
    A.switch("ai.side_mem", "Hit-side memory (phase shift)", true, { dep = aon,
        tip = "If an enemy hits you mostly on one desync side, that enemy gets the mirrored side." })
    A.switch("ai.panic", "Panic switch (2 hits in 6 s)", true, { dep = aon })
    A.switch("ai.script_jit", "Script jitter for native profiles", true, { dep = aon, adv = true,
        tip = "The script controls the native jitter side itself, so the AI knows which side the enemy shot at." })
    A.switch("ai.evo", "Evolve profiles (Evo 1-6)", true, { dep = aon })
    A.slider("ai.evo_n", "Evo: events before judging", 6, 40, 12, 1, nil, { dep = aon, adv = true })
    A.slider("ai.evo_sigma", "Evo: mutation", 5, 60, 25, 1, "%", { dep = aon, adv = true })
    A.switch("ai.logs", "Log AI decisions", false, { dep = aon, adv = true })
end
---------------------------------------------------------------- AA-движок: профиль -> углы чита
do
    local U = RAP.U
    local set = RAP.aaset
    local S = { sent = 0, flip = false, left = 1, cycle = false, manual = 0, brute_until = 0, brute_flip = false,
        brute_shift = 0, lim_until = 0, def_until = 0, prev_hit = false, fh = {}, prev = {}, ro = 0, mod_rand = 0, flick_base = 0, names = {} }
    local AA = { S = S }
    RAP.aa = AA
    local GROUP = { stand = "stand", move = "move", slow = "slow", air = "air", airduck = "air", duck = "duck" }
    AA.GROUP = GROUP
    local MERGE = { slow = "move", duck = "stand" }
    function AA.group_of(state)
        local g = GROUP[state or "stand"] or "stand"
        if RAP.v("ai.merge") and MERGE[g] then g = MERGE[g] end
        return g
    end
    AA.GROUPS = { "stand", "move", "slow", "air", "duck" }

    -- история показанной стороны по циклам отправки: на какой стороне ты был, когда враг стрелял
    -- Сторона на момент t: последняя запись ДО t (раньше - ближайшая, в т.ч. из будущего). Время выстрела врага
    -- известно с ошибкой (пинг, интерполяция), поэтому если в окне +-tol сторона менялась - ответ nil (неизвестно):
    -- при fast jitter сторона меняется каждый тик, и угаданная сторона была бы шумом в статистике phase shift.
    local SIDE_TOL = 0.05
    local function flip_at(t)
        local side, known = nil, false
        for _, e in ipairs(S.fh) do
            if e[1] <= t then side, known = e[2], true end
        end
        if not known then return nil end
        for _, e in ipairs(S.fh) do
            if e[1] >= t - SIDE_TOL and e[1] <= t + SIDE_TOL and e[2] ~= side then return nil end
        end
        return side
    end
    AA.flip_at = flip_at
    -- профиль на момент t: если в окне [t - 0.25, t] профиль менялся, враг мог стрелять по прошлому - выстрел неоднозначен
    local function profile_mixed(t)
        local seen
        for _, e in ipairs(S.fh) do
            if e[1] >= t - 0.25 and e[1] <= t + SIDE_TOL and e[3] then
                if seen and seen ~= e[3] then return true end
                seen = seen or e[3]
            end
        end
        return false
    end
    AA.profile_mixed = profile_mixed
    function AA.side_known(c)
        if not c or c.mode == "Random" then return false end
        if c.native and not RAP.v("ai.script_jit") then return false end
        return true
    end

    local function pressed(key)
        local it = RAP.cfg[key]
        local cur = RAP.v(key) and true or false
        local prev = S.prev[key] or false
        S.prev[key] = cur
        local name = S.names[key]
        if name == nil then local okn, nm = pcall(it.name, it); name = okn and nm or false; S.names[key] = name end
        if RAP.binds.is_toggle(name or nil) then return cur ~= prev end
        return cur and not prev
    end
    local function update_manual()
        if pressed("aa.man_l") then S.manual = S.manual == -90 and 0 or -90 end
        if pressed("aa.man_r") then S.manual = S.manual == 90 and 0 or 90 end
        if pressed("aa.man_b") then S.manual = S.manual == 180 and 0 or 180 end
        AA.manual = S.manual
    end

    -- одна таблица на состояние, поля обновляются на месте: раньше каждый тик создавалась новая, AA.cur ~= c было
    -- всегда true, flick_base сбрасывался каждый тик и defensive flick в билдере не срабатывал никогда
    local BLD = {}
    local function builder(state)
        local p = "bld." .. state .. "."
        local b = BLD[state]
        if not b then b = { name = "builder " .. state }; BLD[state] = b end
        local mode = RAP.v(p .. "mode") or "Delay jitter"
        b.mode, b.native, b.offset = mode, mode == "Native", RAP.v(p .. "offset") or 0
        b.range, b.delay, b.delay_r = RAP.v(p .. "range") or 60, RAP.v(p .. "delay") or 2, RAP.v(p .. "delay_r") or 0
        b.offL, b.offR, b.mod_off = RAP.v(p .. "offL"), RAP.v(p .. "offR"), RAP.v(p .. "mod_off")
        b.left, b.right, b.bfs = RAP.v(p .. "left") or 58, RAP.v(p .. "right") or 58, RAP.v(p .. "bfs") or "Off"
        b.defensive, b.def_pitch, b.def_yaw, b.def_flick = RAP.v(p .. "def"), RAP.v(p .. "def_pitch"), RAP.v(p .. "def_yaw"), RAP.v(p .. "def_flick")
        return b
    end

    -- константы горячего пути (раньше таблицы-литералы создавались каждый тик)
    local WAY5, WAY3 = { -0.5, -0.25, 0, 0.25, 0.5 }, { -90, 180, 90 }
    local NO_OPTS, OPT_JITTER, OPT_OVERLAP = {}, { "Jitter" }, { "Avoid Overlap" }

    local function tick_flip(c)
        S.left = S.left - 1
        if S.left <= 0 then
            S.flip = not S.flip
            local d = (c.mode == "Jitter") and 1 or (c.delay or 1)
            if not S.flip and (c.delay_r or 0) > 0 and c.mode ~= "Jitter" then d = c.delay_r end
            -- плавающая задержка: фиксированный период (3,3,3...) читается и подстраивается; иногда +-1 тик
            if c.mode == "Delay jitter" and d > 1 and RAP.v("aa.rand_delay") and U.rand(1, 100) <= 35 then d = d + (U.rand(0, 1) == 0 and -1 or 1) end
            S.left = U.max(1, d)
        end
    end
    local function yaw_raw(c)
        local mode, off, rng, n = c.mode, c.offset or 0, c.range or 0, S.sent
        if mode == "Static" then return off, S.flip end
        if mode == "Native" then return off, S.flip end
        if mode == "Jitter" or mode == "Delay jitter" then return off + (S.flip and rng or -rng) / 2, S.flip end
        if mode == "Random" then
            if S.cycle then S.ro = U.rand(-rng, rng) / 2 end
            return off + S.ro, S.flip
        end
        if mode == "3-Way" then local i = n % 3; return off + (i == 0 and -rng / 2 or (i == 2 and rng / 2 or 0)), n % 2 == 0 end
        if mode == "5-Way" then return off + WAY5[n % 5 + 1] * rng, n % 2 == 0 end
        if mode == "Staged" then local k = U.max(2, c.stages or 4); return off + ((n % k) / (k - 1) - 0.5) * rng, n % 2 == 0 end
        local s = math.sin(globals.curtime * 3)
        return off + s * rng / 2, s > 0
    end

    local WAYS = { -90, -45, 180, 45, 90 }
    local function defensive(c, flip)
        local dp, dy, t, n = c.def_pitch, c.def_yaw, globals.curtime, S.sent
        if dp and dp ~= "Off" then
            local v
            if dp == "Up" then v = -89 elseif dp == "Down" then v = 89 elseif dp == "Zero" then v = 0
            elseif dp == "Random" then v = U.rand(-89, 89) elseif dp == "Semi-Up" then v = U.rand(-60, -45)
            elseif dp == "Semi-Down" then v = U.rand(45, 60) elseif dp == "Jitter" then v = n % 2 == 0 and 89 or -89
            elseif dp == "Spin" then v = (t * 360) % 178 - 89 elseif dp == "Sway" then v = math.sin(t * 4) * 89
            elseif dp == "PAKETA" then v = U.abs(t % 0.3 - 0.15) / 0.15 * 178 - 89 end
            if v then pcall(rage.antiaim.override_hidden_pitch, rage.antiaim, U.clamp(v, -89, 89)) end
        end
        if dy and dy ~= "Off" then
            local v
            if dy == "Sideways" then v = flip and U.rand(60, 120) or -U.rand(60, 120)
            elseif dy == "Random" then v = U.rand(-180, 180) elseif dy == "Spin" then v = globals.tickcount * 30
            elseif dy == "Opposite" then v = U.rand(150, 210)
            elseif dy == "Opposite jitter" then v = flip and U.rand(135, 180) or U.rand(180, 225)
            elseif dy == "Side-based" then v = flip and U.rand(-105, -75) or U.rand(75, 105)
            elseif dy == "3-Way" then v = WAY3[n % 3 + 1]
            elseif dy == "5-Way" or dy == "Ways custom" then v = WAYS[n % 5 + 1] end
            if v then pcall(rage.antiaim.override_hidden_yaw_offset, rage.antiaim, U.norm(v)) end
        end
        if c.def_flick and S.cycle and (S.sent - S.flick_base) % 16 == 15 then
            pcall(rage.antiaim.override_hidden_yaw_offset, rage.antiaim, U.rand(-180, 180))
            pcall(rage.antiaim.override_hidden_pitch, rage.antiaim, U.rand(-89, 89))
        end
    end

    -- safe head: смотрим вниз-назад, когда враг ниже (преимущество по высоте) - голова прячется за телом
    local function safe_head()
        if not RAP.v("aa.safe_head") or not RAP.W.threat then return false end
        local okd, org = pcall(RAP.W.threat.get_origin, RAP.W.threat)
        if not okd or not org or not RAP.W.eye then return false end
        local dz = RAP.W.eye.z - (org.z + 64)
        local st = RAP.W.state
        if not ((dz > 22 and (st == "stand" or st == "duck")) or (dz > 65 and st == "airduck")) then return false end
        set("pitch", "Down"); set("yaw", "Backward"); set("base", "At Target"); set("offset", 0)
        set("modifier", "Disabled"); set("mod_offset", 0); set("body", false); set("body_fs", "Off")
        set("hidden", false); set("freestand", false)
        pcall(rage.antiaim.inverter, rage.antiaim, false)
        return true
    end

    -- E нужна игре -> in_use не трогаем: CT у заложенной C4, заложник рядом, сущность (дверь, оружие) под прицелом
    local function near(cls_name, org, r)
        local ok, list = pcall(entity.get_entities, cls_name)
        if not ok or not list then return false end
        for _, e in ipairs(list) do
            local ok2, o = pcall(e.get_origin, e)
            if ok2 and o and o:dist(org) < r then return true end
        end
        return false
    end
    local function use_needed(me, cmd)
        local org = me:get_origin()
        if me.m_iTeamNum == 3 and near("CPlantedC4", org, 80) then return true end
        if near("CHostage", org, 90) then return true end
        local ok, hit = pcall(function()
            local va = cmd.view_angles
            local p, y = math.rad(va.x), math.rad(va.y)
            local eye = RAP.W.eye or vector(org.x, org.y, org.z + 64)
            local cp = math.cos(p)
            local to = vector(eye.x + cp * math.cos(y) * 96, eye.y + cp * math.sin(y) * 96, eye.z - math.sin(p) * 96)
            local tr = utils.trace_line(eye, to, me)
            return tr and tr.fraction < 1 and tr.entity ~= nil and tr.entity ~= me and tr.entity:get_index() ~= 0
        end)
        return ok and hit or false
    end

    local function skip(me)
        local mt = me.m_MoveType
        if mt == 9 or mt == 8 then return "ladder" end
        if RAP.v("aa.warmup") then
            local ok, gr = pcall(entity.get_game_rules)
            if ok and gr and gr.m_bWarmupPeriod then return "warmup" end
        end
        return nil
    end

    -- Smart anti-brute: сторона меняется не от любого попадания, а от весомого сигнала:
    --   попадание в голову (враг явно попал в сторону головы) или 2-е попадание того же врага за 8 с.
    -- Кулдаун 1 с между сменами; больше 3 смен за 15 с - враг "раскачивает" AA: сторона держится, только продлевается таймер.
    S.bhits, S.bflips = {}, {}
    function AA.brute_hit(rec)
        local mode = RAP.v("aa.brute")
        local now = globals.curtime
        local bt = RAP.v("aa.brute_t") or 5
        if mode == "Smart (flip on hit)" then
            local key = (rec and (rec.pid or rec.enemy)) or "?"
            local prev = S.bhits[key]
            local repeat_hit = prev and now - prev < 8 and now >= prev
            S.bhits[key] = now
            local strong = (rec and rec.hitgroup == 1) or repeat_hit
            for k2 = #S.bflips, 1, -1 do if now - S.bflips[k2] > 15 or now < S.bflips[k2] then table.remove(S.bflips, k2) end end
            local last = S.last_brute or -99
            if now < last then last = -99 end
            if strong and now - last > 1 and #S.bflips < 3 then
                S.last_brute = now
                S.bflips[#S.bflips + 1] = now
                S.brute_until = now + bt
                S.brute_flip = not S.brute_flip
                S.brute_shift = (U.rand(0, 1) == 0 and -1 or 1) * U.rand(15, 35)
                AA.brute_why = rec and rec.hitgroup == 1 and "head hit" or "repeat hit"
            elseif now < S.brute_until then
                S.brute_until = now + bt
            end
        end
        if RAP.v("aa.lim") == "After getting hit" then S.lim_until = now + bt end
    end
    RAP.on("level", "aa brute", function() S.bhits, S.bflips, S.last_brute, S.brute_until, S.lim_until, S.def_until, S.fh, AA.def = {}, {}, nil, 0, 0, 0, {}, nil end)
    RAP.on("enemy_shot", "aa brute", function(kind, rec)
        local now = globals.curtime
        if kind == "hit" then AA.brute_hit(rec)
        elseif kind == "dodge" then
            local mode = RAP.v("aa.brute")
            if mode == "Smart (flip on hit)" and now < S.brute_until then S.brute_until = now + (RAP.v("aa.brute_t") or 5) end
            if mode == "Classic (flip on near shot)" and now - (S.last_brute or -9) > 0.25 then
                S.last_brute, S.brute_until, S.brute_flip = now, now + (RAP.v("aa.brute_t") or 5), not S.brute_flip
                S.brute_shift = (U.rand(0, 1) == 0 and -1 or 1) * U.rand(15, 35)
            end
        end
    end)
    -- состояние на момент выстрела врага (для AI и hit-side memory)
    RAP.on("enemy_shot_start", "aa ctx", function(rec)
        rec.ctx.group = AA.group_of(RAP.W.state)
        rec.ctx.profile = AA.cur_index
        rec.ctx.known = AA.side_known(AA.cur)
        local tq = globals.curtime - (RAP.W.ping_s or 0.06)
        rec.ctx.flip = rec.ctx.known and flip_at(tq)
        if rec.ctx.flip == false and not rec.ctx.known then rec.ctx.flip = nil end
        rec.ctx.mixed = profile_mixed(tq)
        -- реально ли стоял профиль: manual / safe head / legit / лестница заменяют его целиком, freestanding - yaw
        rec.ctx.applied = AA.active and AA.cur ~= nil and AA.mode == AA.cur.name and S.manual == 0 and not AA.safe
        rec.ctx.fs, rec.ctx.brute = AA.fs and true or false, AA.brute and true or false
    end)

    local function run(cmd)
        local W = RAP.W
        if not RAP.v("aa.on") or not W.alive then
            if AA.active then RAP.aa_release(); AA.active = false end
            return
        end
        local me = W.me
        local why = skip(me)
        if why then if AA.active then RAP.aa_release(); AA.active = false end; AA.mode, AA.low = why, false; return end
        AA.active = true
        local now = globals.curtime
        S.cycle = cmd.choked_commands == 0
        if S.cycle then S.sent = S.sent + 1 end
        update_manual()
        local group = AA.group_of(W.state)
        -- легит AA на E: чит сам выключает AA, пока зажат IN_USE, поэтому кнопку снимаем
        -- (кроме случаев, когда E нужна игре: разминирование, заложник, дверь / предмет под прицелом)
        local oku, use = pcall(U.getf, cmd, "in_use")
        if oku and use and RAP.v("aa.legit") and not use_needed(me, cmd) then
            pcall(U.setf, cmd, "in_use", false)
            set("enabled", true); set("pitch", "Disabled")
            set("yaw", "Backward"); set("base", "Local View"); set("offset", 180)
            set("modifier", "Disabled"); set("mod_offset", 0)
            set("body", true); set("left", 58); set("right", 58); set("body_opts", NO_OPTS); set("body_fs", "Off")
            set("freestand", false); set("fs_nomod", nil); set("fs_body", nil); set("hidden", false)
            AA.mode, AA.fs, AA.safe, AA.low = "legit", false, false, false
            return
        end
        -- профиль
        local c, idx
        if RAP.v("aa.source") == "Builder" then
            local vs_sniper = RAP.v("bld.sniper_on") and RAP.ai and RAP.ai.wc_now == "sniper"
            c = builder(vs_sniper and "sniper" or W.state)
        else
            idx = RAP.ai and RAP.ai.current(group) or 9
            c = RAP.profiles.list[idx]
        end
        if AA.cur ~= c then S.flick_base = S.sent end
        AA.cur, AA.cur_index, AA.group = c, idx, group
        if S.cycle then tick_flip(c) end

        local inv = idx and RAP.ai and RAP.ai.invert_for(W.threat) or false
        AA.inv = inv
        local yaw, flip = yaw_raw(c)
        if inv then yaw = 2 * (c.offset or 0) - yaw; flip = not flip end
        local brute = now < S.brute_until
        if brute then yaw = yaw + S.brute_shift; if S.brute_flip then flip = not flip end end
        if S.cycle then S.fh[#S.fh + 1] = { now, flip, idx or 0 }; if #S.fh > 40 then table.remove(S.fh, 1) end end
        AA.brute, AA.flip = brute, flip

        local native = c.native and S.manual == 0
        local sj = native and RAP.v("ai.script_jit")
        set("enabled", true)
        set("pitch", RAP.v("aa.pitch") or "Down")
        set("yaw", "Backward")
        set("modifier", (native and not sj) and "Center" or "Disabled")
        if S.cycle then local mv = c.mod_var or 0; S.mod_rand = mv > 0 and U.rand(-mv, mv) or 0 end
        set("mod_offset", (native and not sj) and U.norm((c.mod_off or 0) + S.mod_rand) or 0)
        if S.manual ~= 0 then
            set("base", "Local View")
            yaw = S.manual == 180 and 0 or S.manual
        else
            set("base", RAP.v("aa.at_target") and "At Target" or "Local View")
        end
        if native and c.offL and S.manual == 0 then
            local side = flip
            if not sj then local ok, v = pcall(rage.antiaim.inverter, rage.antiaim); side = ok and v or false end
            yaw = side and c.offL or c.offR
            if sj then local half = (c.mod_off or 0) * 0.5; yaw = yaw + (side and half or -half) end
            if brute then yaw = yaw + S.brute_shift end
        end
        set("offset", U.norm(yaw))
        if S.manual ~= 0 then
            set("body", true); set("left", 60); set("right", 60); set("body_opts", OPT_OVERLAP); set("body_fs", "Off")
            pcall(rage.antiaim.inverter, rage.antiaim, false)
        else
            local L, R = c.left or 58, c.right or 58
            local lm = RAP.v("aa.lim")
            if lm == "Always" or (lm == "After getting hit" and now < S.lim_until) then
                if S.cycle or not S.lim_l then
                    local lo = RAP.v("aa.lim_min") or 30
                    S.lim_l, S.lim_r = U.rand(U.min(lo, L), U.max(lo, L)), U.rand(U.min(lo, R), U.max(lo, R))
                end
                L, R = S.lim_l, S.lim_r
                AA.lim = true
            else AA.lim = false end
            set("body", true); set("left", L); set("right", R); set("body_fs", c.bfs or "Off")
            if native and not sj then set("body_opts", OPT_JITTER)
            else set("body_opts", NO_OPTS); pcall(rage.antiaim.inverter, rage.antiaim, flip) end
        end
        -- freestanding
        -- ideal tick "freestanding on peek" решается здесь же, а не в exploits: иначе два модуля
        -- перетягивали freestand каждый тик, а модификаторы / defensive / edge fix о нем не знали
        local it_fs = RAP.v("it.on") and RAP.v("it.key") and RAP.v("it.fs") and W.threat ~= nil
        -- low HP mode: любое попадание убивает -> freestanding без джиттера, пока есть угроза
        local low = RAP.v("aa.lowhp") and W.threat ~= nil and (me.m_iHealth or 100) <= (RAP.v("aa.lowhp_v") or 40)
        AA.low = low
        it_fs = it_fs or low
        local fs = (RAP.v("aa.fs") or it_fs) and S.manual == 0
        if fs and RAP.v("aa.fsfix") then
            local ok, ta = pcall(rage.antiaim.get_target, rage.antiaim)
            local ok2, tb = pcall(rage.antiaim.get_target, rage.antiaim, true)
            ok = ok and ok2
            local dd = (ok and ta and tb) and U.abs(U.norm(ta - tb)) or nil
            if S.fs_fix then
                if now > S.fs_fix_until or (dd and dd > 15) then S.fs_fix = false end
            elseif dd and dd < 5 then S.fs_fix, S.fs_fix_until = true, now + 0.4 end
            if S.fs_fix then fs = false end
        else S.fs_fix = false end
        if fs then set("freestand", true); set("fs_nomod", (RAP.v("aa.fs_nomod") or it_fs) and true or false); set("fs_body", true)
        else set("freestand", nil); set("fs_nomod", nil); set("fs_body", nil) end
        set("avoid_bs", RAP.v("aa.avoid_bs") and true or nil)
        AA.fs = fs
        -- safe head
        AA.safe = S.manual == 0 and safe_head()
        if AA.safe then AA.mode = "safe head"; return end
        -- defensive: профиль + "defensive on peek"
        local can = W.can_hit_me ~= nil
        if RAP.v("aa.def_peek") and can and not S.prev_hit and (W.charge or 0) >= 1 then
            S.def_until = now + (RAP.v("aa.def_peek_t") or 200) / 1000 * (low and 2 or 1)
        end
        S.prev_hit = can
        local peek_def = now < S.def_until
        local want = c.defensive and S.manual == 0 and not fs
        if want and RAP.v("aa.def_smart") and not ((W.charge or 0) >= 1 and W.threat) then want = false end
        if want or peek_def then
            pcall(U.setf, cmd, "force_defensive", true)
            set("hidden", c.defensive and true or false)
            if c.defensive then defensive(c, flip) end
            AA.def = now
        else
            set("hidden", false)
        end
        AA.mode = c.name
    end
    RAP.on("tick", "aa engine", run, 30)
    RAP.on("shutdown", "aa", function() RAP.aa_release() end)

    RAP.on("ind_rows", "aa", function(add)
        if not RAP.v("aa.on") or not AA.active then return end
        if S.manual ~= 0 then add(S.manual == -90 and "MANUAL LEFT" or (S.manual == 90 and "MANUAL RIGHT" or "MANUAL BACK"), color(255, 220, 140), 2) end
        if AA.fs then add("FREESTAND", color(200, 220, 255), 3) end
        if AA.safe then add("SAFE HEAD", color(160, 255, 160), 2) end
        if AA.low then add("LOW HP", color(255, 120, 120), 2) end
        if AA.def and globals.curtime >= AA.def and globals.curtime - AA.def < 0.15 then add("DEFENSIVE", color(160, 255, 200), 2) end
        if AA.brute then add("BRUTE", color(255, 140, 140), 3) end
        if AA.lim then add("LIMIT RND", color(220, 200, 255), 5) end
        if AA.inv then add("PHASE SHIFT", color(255, 200, 150), 4) end
        if AA.mode then add("AA: " .. AA.mode, color(160, 220, 255), 4) end
    end)
end
---------------------------------------------------------------- AA AI: какой профиль ставить (бандит по группам состояний)
-- Награда: уворот (пуля рядом не попала) +, попадание по тебе - (в голову сильнее). Выбор UCB по средней награде
-- группы, смешанной со статистикой конкретного врага. Статистика v23-v38 импортируется (тот же порядок профилей).
do
    local U = RAP.U
    local P = RAP.profiles.list
    local KEY, OLD = "rap2_ai", "rage_aa_pro_ai_v11"
    -- since[g]: когда в группе включен текущий профиль; bdw["группа|оружие врага"]: увороты / попадания по классу оружия стрелка
    -- ets[pid]: когда враг последний раз учил per-enemy статистику (unixtime) - при сохранении остаются самые свежие
    local AI = { st = {}, en = {}, sm = {}, cur = {}, last_switch = {}, since = {}, hits = {}, bd = {}, ebd = {}, bdw = {}, gs = {}, ets = {} }
    RAP.ai = AI
    local GROUPS = RAP.aa.GROUPS

    local function prior() return { n = 2, sum = 1 } end
    local function fresh_groups() local t = {}; for _, g in ipairs(GROUPS) do t[g] = {}; for i = 1, #P do t[g][i] = prior() end end; return t end
    local function valid_list(l)
        if type(l) ~= "table" or #l == 0 or #l > #P then return false end
        for _, s in ipairs(l) do
            if type(s) ~= "table" or not U.num(s.n) or not U.num(s.sum) or s.n <= 0 then return false end
            s.n, s.sum = U.num(s.n, 0.5, 1e4), U.num(s.sum, -1e5, 1e5)
        end
        return true
    end
    -- строка счетчиков { [профиль] = { увороты, попадания } } из базы: только существующие профили и конечные числа
    local function load_row(row)
        local out = {}
        if type(row) ~= "table" then return out end
        for k, v in pairs(row) do
            local i = tonumber(k)
            if i and P[i] and type(v) == "table" then out[i] = { U.num(v[1], 0, 1e4) or 0, U.num(v[2], 0, 1e4) or 0 } end
        end
        return out
    end
    do
        AI.st = fresh_groups()
        local d = RAP.store.get(KEY)
        local src = d and d.st or RAP.store.get(OLD)
        local imported = 0
        if type(src) == "table" then
            for _, g in ipairs(GROUPS) do
                if valid_list(src[g]) then for i, s in ipairs(src[g]) do AI.st[g][i] = { n = s.n, sum = s.sum } end; imported = imported + 1 end
            end
        end
        if d and type(d.en) == "table" then
            for pid, groups in pairs(d.en) do
                if type(pid) == "string" and type(groups) == "table" then
                    local e = {}
                    for _, g in ipairs(GROUPS) do
                        e[g] = {}
                        if type(groups[g]) == "table" then
                            for k, v in pairs(groups[g]) do
                                local i = tonumber(k)
                                if i and P[i] and type(v) == "table" and U.num(v[1]) and U.num(v[2]) then e[g][i] = { n = U.num(v[1], 0, 1e4), sum = U.num(v[2], -1e5, 1e5) } end
                            end
                        end
                    end
                    AI.en[pid] = e
                end
            end
        end
        if d and type(d.sm) == "table" then
            for pid, s in pairs(d.sm) do
                if type(pid) == "string" and type(s) == "table" and type(s.h) == "table" and type(s.d) == "table" then
                    local function n2(t) return { U.num(t[1], 0, 1e4) or 0, U.num(t[2], 0, 1e4) or 0 } end
                    AI.sm[pid] = { h = n2(s.h), d = n2(s.d), inv = s.inv == true, ts = U.num(s.ts, 0) or 0 }
                end
            end
        end
        if d and type(d.bd) == "table" then
            for g, row in pairs(d.bd) do if type(g) == "string" and type(row) == "table" then AI.bd[g] = load_row(row) end end
        end
        if d and type(d.bdw) == "table" then
            for k, row in pairs(d.bdw) do if type(k) == "string" and type(row) == "table" then AI.bdw[k] = load_row(row) end end
        end
        if d and type(d.ebd) == "table" then
            for pid, groups in pairs(d.ebd) do
                if type(pid) == "string" and type(groups) == "table" then
                    local e = {}
                    for g, row in pairs(groups) do if type(g) == "string" and type(row) == "table" then e[g] = load_row(row) end end
                    AI.ebd[pid] = e
                end
            end
        end
        if d and type(d.ets) == "table" then
            for pid, t in pairs(d.ets) do if type(pid) == "string" and U.num(t, 0) then AI.ets[pid] = U.num(t, 0) end end
        end
        if not d and imported > 0 then print(string.format("[ai] imported learning from v38 for %d state group(s)", imported)) end
    end

    -- пул профилей для группы: выбранные в меню + Evo-слоты своей группы / общий / уже набравшие данные в этой группе
    local function pool(g)
        local sel = RAP.v("ai.pool")
        local set, any = {}, false
        if type(sel) == "table" then for _, n in ipairs(sel) do set[n], any = true, true end end
        local list = {}
        for i, p in ipairs(P) do
            local ok = not any or set[p.name]
            if p.evo then
                ok = false
                if RAP.v("ai.evo") then
                    local home = RAP.evo and RAP.evo.home[i]
                    local x = g and AI.bd[g] and AI.bd[g][i]
                    ok = not g or home == g or home == "all" or (x and x[1] + x[2] >= 3)
                end
            end
            if ok then list[#list + 1] = i end
        end
        return list
    end
    AI.pool = pool
    local function mean(g, i, pid)
        local s = AI.st[g][i]
        local n, sum = s.n, s.sum
        if pid and RAP.v("ai.per_enemy") then
            local e = AI.en[pid] and AI.en[pid][g] and AI.en[pid][g][i]
            if e and e.n > 0 then n, sum = n + e.n * 2, sum + e.sum * 2 end
        end
        return sum / n, s.n
    end
    AI.mean = mean
    -- v46: модель уворотов. Для профиля в группе состояний: уворот (d) / попадание по тебе (h, в голову = 1.5),
    -- с затуханием. Оценка P(уворот) = Beta с приором от средней по группе; против конкретного врага его счетчики
    -- весят x2. Выбор: лучшая оценка (exploitation) + Thompson-эксперимент с долей ai.explore.
    local function cnt(t, i) local x = t and t[i]; if x then return x[1], x[2] end; return 0, 0 end
    local function base(g)
        local D, Hh = 0, 0
        for _, x in pairs(AI.bd[g] or {}) do D, Hh = D + x[1], Hh + x[2] end
        return (D + 1) / (D + Hh + 2)
    end
    -- класс оружия врага: снайпер / дигл / пистолет / винтовка / smg. Против AWP и против AK работают разные профили.
    local WCLASS = { ["SSG-08"] = "sniper", AWP = "sniper", AutoSnipers = "sniper", ["Desert Eagle"] = "deagle", ["R8 Revolver"] = "deagle",
        Pistols = "pistol", Rifles = "rifle", SMGs = "smg", Shotguns = "smg", Machineguns = "smg" }
    function AI.wclass(ent)
        if not ent then return nil end
        local ok, w = pcall(function() local wp = ent:get_player_weapon(); return wp and wp:get_weapon_index() end)
        local sub = ok and w and RAP.ref.WIDX_SUB[w]
        return sub and WCLASS[sub] or nil
    end
    RAP.on("tick", "ai weapon", function()
        local thr = RAP.W.threat
        if not thr then AI.wc_now = nil; return end
        if (globals.tickcount or 0) % 8 == 0 or AI.wc_idx ~= thr:get_index() then AI.wc_now, AI.wc_idx = AI.wclass(thr), thr:get_index() end
    end, 20)
    RAP.on("enemy_shot_start", "ai weapon", function(rec)
        local ok, ent = pcall(entity.get, rec.enemy)
        rec.ctx.wc = ok and AI.wclass(ent) or nil
    end)
    -- wc: класс оружия врага (по умолчанию - у текущей угрозы). Его счетчики добавляются с весом x1 поверх общих.
    function AI.post(g, i, pid, wc)
        local d, h = cnt(AI.bd[g], i)
        local n_u = d + h        -- уникальные события: per-enemy и per-weapon счетчики - подмножества общих
        if pid and RAP.v("ai.per_enemy") then
            local ed, eh = cnt(AI.ebd[pid] and AI.ebd[pid][g], i)
            d, h = d + ed * 2, h + eh * 2
        end
        wc = wc or AI.wc_now
        if wc and RAP.v("ai.per_weapon") then
            local wd, wh = cnt(AI.bdw[g .. "|" .. wc], i)
            d, h = d + wd, h + wh
        end
        local b = base(g)
        -- старый опыт (средняя награда профиля с v23) - тоже приор: накопленные карты не теряются
        local st = AI.st[g] and AI.st[g][i]
        if st and st.n > 3 then b = (b + U.clamp(0.5 + st.sum / st.n * 0.2, 0.2, 0.8)) / 2 end
        local al, be = 1 + b * 3 + d, 1 + (1 - b) * 3 + h
        -- среднее - со смешанными весами (враг / оружие важнее), неопределенность и n - по уникальным событиям:
        -- раньше 5 выстрелов одного врага считались как 15-20 и уверенность росла в 3-4 раза быстрее, чем есть данных
        local m = al / (al + be)
        return m, m * (1 - m) / (5 + n_u + 1), n_u
    end
    local function phi(z)
        local s2, x = z < 0 and -1 or 1, U.abs(z) / 1.41421356
        local t = 1 / (1 + 0.3275911 * x)
        local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
        return 0.5 * (1 + s2 * y)
    end
    function AI.p_better(g, b, a, pid)
        local mb, vb = AI.post(g, b, pid)
        local ma, va = AI.post(g, a, pid)
        return phi((mb - ma) / U.sqrt(U.max(vb + va, 1e-6)))
    end
    -- optimistic = true: оценка + 1 sd (непроверенные профили получают шанс, когда текущий подвел)
    function AI.best(g, exclude, pid, optimistic)
        local best, bm = nil, -1e9
        for _, i in ipairs(pool(g)) do
            -- откаченный (проверка показала "хуже") профиль не выбирается verify.block_s секунд
            if i ~= exclude and not RAP.dl.blocked("aa", g, i) then
                local m, v = AI.post(g, i, pid)
                if optimistic then m = m + U.sqrt(v) end
                if m > bm then best, bm = i, m end
            end
        end
        return best or exclude or 9
    end
    -- Доля экспериментов зависит от неопределенности, ai.explore - потолок (эксперимент с плохим профилем стоит жизни):
    --   мало данных в группе -> 100% потолка; лучший не выделился -> 40%; лучший вероятно лучше второго -> 25%;
    --   лучший уверенно (>= 85%) лучше второго и проверен 6+ раз -> 10%.
    function AI.explore_rate(g, pid)
        local cap = (RAP.v("ai.explore") or 30) / 100
        if not g then return cap, "no group", 0 end
        local list = pool(g)
        local b1, b2, m1, m2, total = nil, nil, -1, -1, 0
        for _, i in ipairs(list) do
            local m, _, n = AI.post(g, i, pid)
            total = total + n
            if m > m1 then b2, m2, b1, m1 = b1, m1, i, m elseif m > m2 then b2, m2 = i, m end
        end
        if total < U.max(8, 2 * #list) then return cap, "little data", 0 end
        local conf = (b1 and b2) and AI.p_better(g, b1, b2, pid) or 0.5
        local _, _, n1 = AI.post(g, b1, pid)
        if conf >= 0.85 and n1 >= 6 then return cap * 0.1, "confident", conf end
        if conf >= 0.65 then return cap * 0.25, "preferred", conf end
        return cap * 0.4, "uncertain", conf
    end
    -- выбор профиля: второй результат - как выбран ("evo" испытание, "explore" эксперимент, "best" лучшая оценка)
    function AI.pick(g, exclude)
        local f = RAP.evo and RAP.evo.force(g, exclude, true)
        if f then return f, "evo" end
        local pid = RAP.W.threat and RAP.W.pid(RAP.W.threat)
        local xp = AI.explore_rate(g, pid)
        if U.rand(1, 1000) <= xp * 1000 then
            local best, bv = nil, -1e9
            for _, i in ipairs(pool(g)) do
                if i ~= exclude and not RAP.dl.blocked("aa", g, i) then
                    local m, v = AI.post(g, i, pid)
                    local smp = m + U.randn() * U.sqrt(v)
                    if smp > bv then best, bv = i, smp end
                end
            end
            if best then return best, "explore" end
        end
        return AI.best(g, exclude, pid), "best"
    end
    -- установка профиля группы: время включения нужно для минимального срока жизни и кулдауна
    AI.how = {}
    function AI.set(g, i, how, why)
        local old = AI.cur[g]
        AI.cur[g], AI.how[g] = i, how or "best"
        if old ~= i then
            local now = globals.curtime
            AI.since[g] = now
            if old then AI.last_switch[g] = now end
            -- журнал решений: смена профиля проверяется по уворотам после нее (evo - не здесь, у него свой A/B)
            if old and why and how ~= "evo" then
                local pid = RAP.W.threat and RAP.W.pid(RAP.W.threat)
                local pm, pv = AI.post(g, old, pid)
                RAP.dl.record("aa", g, old, i, why, { pre_m = pm, pre_v = pv, lf = P[old].name, lt = P[i].name })
            end
            if old and why and RAP.v("ai.logs") then U.log("ai", "%s: %s -> %s (%s)", g, P[old].name, P[i].name, why) end
        end
    end
    -- профиль, убранный из пула (меню / выключенная эволюция), заменяется сразу, а не только при уверенной смене
    AI.pool_chk = {}
    function AI.current(g)
        local cur = AI.cur[g]
        if cur then
            local now, t = globals.realtime, AI.pool_chk[g]
            if not t or now - t > 0.5 or now < t then
                AI.pool_chk[g] = now
                local ok = false
                for _, i in ipairs(pool(g)) do if i == cur then ok = true; break end end
                if not ok then local i, how = AI.pick(g, cur); AI.set(g, i, how, "removed from pool") end
            end
        else
            local i, how = AI.pick(g); AI.set(g, i, how)
        end
        return AI.cur[g]
    end
    -- сколько секунд профиль группы уже стоит (curtime сбрасывается сменой карты - тогда считаем срок истекшим)
    function AI.age(g)
        local s = AI.since[g]
        local d = s and (globals.curtime - s) or 1e9
        return d < 0 and 1e9 or d
    end
    function AI.invert_for(thr)
        if not thr or not RAP.v("ai.side_mem") then return false end
        local s = AI.sm[RAP.W.pid(thr) or ""]
        return s and s.inv or false
    end

    local function dodge_value(dist) return 0.2 + 1.05 * U.clamp(1 - (dist or 60) / 60, 0, 1) end
    local function reward(g, i, pid, v, wgt)
        RAP.store.mark(KEY)
        local gamma = (RAP.v("ai.memory") or 95) / 100
        local s = AI.st[g][i]
        s.n, s.sum = U.max(0.5, s.n * gamma) + 1, s.sum * gamma + v
        if pid and RAP.W.learn(pid) then
            local e = AI.en[pid]
            if not e then e = {}; for _, gg in ipairs(GROUPS) do e[gg] = {} end; AI.en[pid] = e end
            local x = e[g][i] or { n = 0, sum = 0 }
            x.n, x.sum = x.n * gamma + 1, x.sum * gamma + v
            e[g][i] = x
            local okt, ut = pcall(common.get_unixtime)
            if okt and tonumber(ut) then AI.ets[pid] = tonumber(ut) end
        end
        RAP.run("ai_reward", g, i, v, wgt)
    end
    -- hit-side memory: если враг попадает в основном на одной стороне - этому врагу отдается зеркальная сторона
    -- Каждая сторона считается отдельно (попадания / увороты) с затуханием 0.97 на событие. Переключение - только при
    -- уверенности >= 95% (двусторонний z-тест), минимум 3 события на каждой стороне и 8 всего, не чаще раза в 15 с;
    -- повторное переключение в течение 60 с требует уверенности 99%. Врага не видели 20+ минут - статистика заново.
    local function side_note(pid, flip, hit)
        if flip == nil or not pid or not RAP.W.learn(pid) then return end
        RAP.store.mark(KEY)
        local s = AI.sm[pid]
        if not s then s = { h = { 0, 0 }, d = { 0, 0 }, inv = false }; AI.sm[pid] = s end
        local okt, ut = pcall(common.get_unixtime)
        ut = okt and tonumber(ut) or 0
        if ut > 0 and (s.ts or 0) > 0 and ut - s.ts > 1200 then s.h, s.d, s.inv, s.conf, s.t = { 0, 0 }, { 0, 0 }, false, 0, nil end
        if ut > 0 then s.ts = ut end
        for k = 1, 2 do s.h[k], s.d[k] = s.h[k] * 0.97, s.d[k] * 0.97 end
        local k = flip and 1 or 2
        if hit then s.h[k] = s.h[k] + 1 else s.d[k] = s.d[k] + 1 end
        local n1, n2 = s.h[1] + s.d[1], s.h[2] + s.d[2]
        if n1 < 3 or n2 < 3 or n1 + n2 < 8 then s.conf = 0; return end
        local p1, p2 = s.h[1] / n1, s.h[2] / n2
        local p = (s.h[1] + s.h[2]) / (n1 + n2)
        local se = U.sqrt(U.max(p * (1 - p), 0.01) * (1 / n1 + 1 / n2))
        local z = (p1 - p2) / se
        s.p1, s.p2, s.conf = p1, p2, 2 * phi(U.abs(z)) - 1
        local now = globals.curtime
        local since = s.t and now - s.t or 1e9
        if since < 0 then since = 1e9 end
        local need = since < 60 and 0.99 or 0.95
        if s.conf >= need and since > 15 then
            s.inv = not s.inv
            s.h, s.d, s.t = { 0, 0 }, { 0, 0 }, now
            if RAP.v("ai.logs") then U.log("ai", "%s hits side %s %.0f%% vs %.0f%% (confidence %.0f%%) -> phase shift %s",
                pid, p1 > p2 and "A" or "B", U.max(p1, p2) * 100, U.min(p1, p2) * 100, s.conf * 100, s.inv and "ON" or "OFF") end
            RAP.toast("Phase shift " .. (s.inv and "ON" or "OFF"))
            s.conf = 0
        end
    end

    local function bd_note(t, i, dodge, w)
        for _, x in pairs(t) do x[1], x[2] = x[1] * 0.995, x[2] * 0.995 end
        local x = t[i]
        if not x then x = { 0, 0 }; t[i] = x end
        if dodge then x[1] = x[1] + w else x[2] = x[2] + w end
    end
    -- Shot attribution для AA (вес 0..1): говорит ли этот выстрел врага что-то о профиле.
    --   профиль не стоял (manual / safe head / legit / лестница) -> 0 (раньше такие выстрелы портили статистику профиля);
    --   попадание: в голову 1.0, в тело 0.6 (тело мало зависит от yaw / десинка), в тело из снайперки 0.4;
    --   уворот: снайпер 1.0, пистолет / smg / дробовик 0.6 (их промахи - чаще разброс, чем AA);
    --   freestanding заменял yaw x0.5; попадание без записи выстрела (направление неизвестно) x0.7.
    function AI.attr(kind, rec)
        if not rec.ctx.applied then return 0, "profile was not active (manual / safe head / legit)" end
        if rec.ctx.mixed then return 0, "profile switched right before the shot (enemy may have shot at the previous one)" end
        local w, why = 1, {}
        local wc = rec.ctx.wc
        if kind == "hit" then
            if rec.hitgroup ~= 1 then
                w = wc == "sniper" and 0.4 or 0.6
                why[#why + 1] = wc == "sniper" and "body hit by sniper" or "body hit"
            end
            if rec.untracked then w = w * 0.7; why[#why + 1] = "shot not tracked" end
        else
            if wc == "pistol" or wc == "smg" then w = 0.6; why[#why + 1] = wc .. " miss (often spread)" end
        end
        if rec.ctx.fs then w = w * 0.5; why[#why + 1] = "freestanding active" end
        return w, #why > 0 and table.concat(why, ", ") or (kind == "hit" and "head hit" or "clean dodge")
    end
    RAP.on("enemy_shot", "ai", function(kind, rec)
        local g, i = rec.ctx.group, rec.ctx.profile
        if not g or not i or RAP.v("aa.source") == "Builder" then return end
        if kind ~= "dodge" and kind ~= "hit" then return end
        local dodge = kind == "dodge"
        local aw, awhy = AI.attr(kind, rec)
        local w0 = dodge and (rec.w or 1) or (rec.hitgroup == 1 and 1.5 or 1)
        local w = w0 * aw
        RAP.CONF = RAP.CONF or {}
        RAP.CONF.eshot = { w = aw, why = awhy, r = kind, t = globals.realtime }
        if RAP.tele and RAP.tele.apush then
            RAP.tele.apush({ t = U.round(globals.realtime * 10) / 10, g = g, p = i, how = AI.how[g], cur = AI.cur[g], k = kind, hg = rec.hitgroup,
                w0 = U.round(w0 * 100) / 100, aw = U.round(aw * 100) / 100, wc = rec.ctx.wc, d = rec.dist and U.round(rec.dist) or nil })
        end
        if aw <= 0 then return end
        RAP.store.mark(KEY)
        AI.bd[g] = AI.bd[g] or {}
        bd_note(AI.bd[g], i, dodge, w)
        if rec.pid and RAP.W.learn(rec.pid) then
            local e = AI.ebd[rec.pid]
            if not e then e = {}; AI.ebd[rec.pid] = e end
            e[g] = e[g] or {}
            bd_note(e[g], i, dodge, w)
        end
        if rec.ctx.wc then
            local wk = g .. "|" .. rec.ctx.wc
            AI.bdw[wk] = AI.bdw[wk] or {}
            bd_note(AI.bdw[wk], i, dodge, w)
        end
        -- проверка последней смены профиля в группе (откат через DL.rb.aa меняет AI.cur[g] - ниже cur ~= i)
        RAP.dl.outcome("aa", g, i, dodge, w)
        if dodge then
            reward(g, i, rec.pid, dodge_value(rec.dist) * (rec.w or 1) * aw, w)
            if aw >= 0.5 then side_note(rec.pid, rec.ctx.flip, false) end
            return
        end
        reward(g, i, rec.pid, (rec.hitgroup == 1 and -3 or -1.5) * aw, w)
        if aw >= 0.5 then side_note(rec.pid, rec.ctx.flip, true) end
        -- слабо атрибутированное попадание (тело, freestanding) учит статистику, но не запускает смену профиля
        if aw < 0.5 then return end
        -- Смена профиля после попадания по тебе. Правила стабильности:
        --   panic (аварийно): 2 попадания по текущему профилю за 6 с, профиль стоит >= 1.5 с, не чаще раза в 8 с;
        --   иначе профиль должен простоять ai.min_life секунд и пройти 3 с с прошлой смены (кулдаун), и
        --   "уверенно лучше": другой профиль выше на HYST (гистерезис) и лучше с вероятностью >= 80%, 4+ событий;
        --   "ниже среднего": 6+ событий и оценка ниже средней по группе на HYST.
        local now = globals.curtime
        local gs = AI.gs[g]
        if not gs then gs = { hits = {}, last_panic = -99 }; AI.gs[g] = gs end
        if now < gs.last_panic then gs.last_panic = -99 end
        gs.hits[#gs.hits + 1] = { t = now, i = i }
        if #gs.hits > 4 then table.remove(gs.hits, 1) end
        local cur = AI.cur[g]
        if cur ~= i then return end
        local pid = rec.pid
        local HYST = 0.08
        local age = AI.age(g)
        local since_sw = AI.last_switch[g] and now - AI.last_switch[g] or 1e9
        if since_sw < 0 then since_sw = 1e9 end
        local mc, vc, n = AI.post(g, cur, pid)
        local recent = 0
        for _, hh in ipairs(gs.hits) do if hh.i == cur and now - hh.t < 6 and now >= hh.t then recent = recent + 1 end end
        local why, to
        if RAP.v("ai.panic") and recent >= 2 and age >= 1.5 and now - gs.last_panic > 8 then
            why, to = "panic: 2 hits in 6 s", AI.best(g, cur, pid, true)
            gs.last_panic = now
        elseif age >= (RAP.v("ai.min_life") or 6) and since_sw >= 3 then
            local alt = AI.best(g, cur, pid)
            local ma, va, na = AI.post(g, alt, pid)
            local pb = AI.p_better(g, alt, cur, pid)
            -- гистерезис с учетом неопределенности: отрыв >= max(HYST, 1 sd разницы), см. RAP.switch_ok
            if n >= 4 and na >= 3 and RAP.switch_ok(ma, va, mc, vc, pb, 0.8, HYST) then
                why, to = string.format("%.0f%% vs %.0f%%, confident %.0f%% better", ma * 100, mc * 100, pb * 100), alt
            elseif n >= 6 and mc + U.sqrt(vc) < base(g) - HYST / 2 then
                -- "ниже среднего" даже с поправкой на неопределенность (верхняя граница оценки ниже средней)
                why, to = "below group average, trying an untested profile", AI.best(g, cur, pid, true)
            end
        end
        if why and to and to ~= cur then
            local ev = RAP.evo and RAP.evo.force(g, cur)
            AI.set(g, ev or to, ev and "evo" or "best", why)
        end
    end)
    -- Начало раунда: эксперимент / испытание Evo ставятся сразу; профиль, выбранный как лучший, меняется только если
    -- новый кандидат лучше на HYST и с вероятностью >= 75% (без дерганья между почти равными профилями).
    RAP.on("round", "ai", function()
        local pid = RAP.W.threat and RAP.W.pid(RAP.W.threat)
        for _, g in ipairs(GROUPS) do
            local cur = AI.cur[g]
            local cand, how = AI.pick(g)
            if not cur or how ~= "best" or AI.how[g] ~= "best" then
                AI.set(g, cand, how, how == "explore" and "exploration" or (how == "evo" and "evo trial" or "back to best"))
            elseif cand ~= cur then
                local mc, vc = AI.post(g, cur, pid)
                local mn, vn = AI.post(g, cand, pid)
                if RAP.switch_ok(mn, vn, mc, vc, AI.p_better(g, cand, cur, pid), 0.75, 0.08) then
                    AI.set(g, cand, "best", string.format("round start: %.0f%% vs %.0f%%", mn * 100, mc * 100))
                end
            end
        end
    end)
    -- самые свежие враги (по AI.ets) из таблицы tbl, не больше cap; остальные удаляются и из памяти.
    -- v52: раньше брались первые cap в порядке pairs(), то есть случайные - данные активных врагов терялись.
    local function freshest(tbl, cap)
        local l = {}
        for pid in pairs(tbl) do
            if RAP.W.learn(pid) then l[#l + 1] = pid else tbl[pid] = nil end
        end
        table.sort(l, function(a, b) return (AI.ets[a] or 0) > (AI.ets[b] or 0) end)
        for k2 = cap + 1, #l do tbl[l[k2]] = nil end
        if #l > cap then for k2 = cap + 1, #l do l[k2] = nil end end
        return l
    end
    RAP.on("save", "ai", function(force)
        if not RAP.v("main.persist") or not RAP.store.need(KEY, force) then return end
        local en = {}
        for _, pid in ipairs(freshest(AI.en, 48)) do
            local out = {}
            for g, l in pairs(AI.en[pid]) do
                local t = {}
                for i, s in pairs(l) do if s.n > 0.05 then t[tostring(i)] = { U.round(s.n * 100) / 100, U.round(s.sum * 100) / 100 } end end
                out[g] = t
            end
            en[pid] = out
        end
        -- phase shift: не больше 128 врагов, самые свежие
        local sm, sl = {}, {}
        for pid, s in pairs(AI.sm) do if RAP.W.learn(pid) then sl[#sl + 1] = { pid, s.ts or 0 } end end
        table.sort(sl, function(a, b) return a[2] > b[2] end)
        for k2 = 1, U.min(128, #sl) do
            local s = AI.sm[sl[k2][1]]
            sm[sl[k2][1]] = { h = s.h, d = s.d, inv = s.inv, ts = s.ts }
        end
        local function pack(row) local t = {}; for i, x in pairs(row) do if x[1] + x[2] > 0.05 then t[tostring(i)] = { U.round(x[1] * 100) / 100, U.round(x[2] * 100) / 100 } end end; return t end
        local bd, ebd = {}, {}
        for g, row in pairs(AI.bd) do bd[g] = pack(row) end
        for _, pid in ipairs(freshest(AI.ebd, 64)) do
            ebd[pid] = {}
            for g, row in pairs(AI.ebd[pid]) do ebd[pid][g] = pack(row) end
        end
        local bdw = {}
        for wk, row in pairs(AI.bdw) do bdw[wk] = pack(row) end
        local ets = {}
        for pid, t in pairs(AI.ets) do if AI.en[pid] or AI.ebd[pid] then ets[pid] = t else AI.ets[pid] = nil end end
        RAP.store.set(KEY, { st = AI.st, en = en, sm = sm, bd = bd, ebd = ebd, bdw = bdw, ets = ets })
    end)
    function AI.reset()
        AI.st, AI.en, AI.sm, AI.cur, AI.bd, AI.ebd, AI.bdw, AI.since, AI.how, AI.ets = fresh_groups(), {}, {}, {}, {}, {}, {}, {}, {}, {}
        RAP.store.set(KEY, nil)
        print("[ai] AA learning reset")
    end
    -- откат смены профиля, которую проверка признала хуже: только если в группе все еще стоит d.to
    RAP.dl.rb.aa = function(d)
        if AI.cur[d.key] ~= d.to or not P[d.from] then return false end
        -- профиль, который ты с тех пор убрал из пула (или выключенный Evo-слот), не возвращается
        local in_pool = false
        for _, i in ipairs(pool(d.key)) do if i == d.from then in_pool = true; break end end
        if not in_pool then return false end
        AI.set(d.key, d.from, "best", "rollback: " .. tostring(d.lt) .. " was worse")
        return true
    end
    RAP.on("level", "ai", function() AI.since, AI.last_switch, AI.gs = {}, {}, {} end)
    RAP.resets.ai = function() AI.reset(); AI.last_switch, AI.gs = {}, {} end
    RAP.on("panel_rows", "ai", function(rows)
        local g = RAP.aa.group
        if g and AI.cur[g] then
            local pid = RAP.W.threat and RAP.W.pid(RAP.W.threat)
            local m, _, n = AI.post(g, AI.cur[g], pid)
            rows[#rows + 1] = { "AA " .. g, string.format("%s  dodge %.0f%% (n %.0f)", P[AI.cur[g]].name, m * 100, n) }
            local _, mode, conf = AI.explore_rate(g, pid)
            rows[#rows + 1] = { "AA confidence", string.format("%s %.0f%%%s", mode, (conf or 0) * 100, AI.wc_now and ("  vs " .. AI.wc_now) or "") }
        end
    end)
end
---------------------------------------------------------------- эволюция Evo-профилей
-- Evo 1-5 специализируются на stand / move / slow / air / duck, Evo 6 - общий. Слот заменяется потомком лучших
-- профилей, только если он с вероятностью >= 80% хуже среднего (бета-оценка со сжатием к среднему группы).
-- Новорожденный геном получает испытательную квоту (8 событий в своей группе). Геномы v24-v38 импортируются.
do
    local U = RAP.U
    local P = RAP.profiles.list
    local KEY, OLD = "rap2_evo", "rage_aa_pro_evo_v24"
    -- champ[home]: лучший геном, когда-либо доказавший себя в этой группе (не теряется при замене слота);
    -- child[i]: слот сейчас занят потомком (если он тоже провалится - откат к чемпиону, а не новая лотерея)
    local E = { gen = 0, bc = {}, trial = {}, home = {}, slots = {}, rounds = 0, champ = {}, child = {} }
    RAP.evo = E
    local HOMES = { "stand", "move", "slow", "air", "duck", "all" }
    for i, p in ipairs(P) do if p.evo then E.slots[#E.slots + 1] = i end end
    for k, i in ipairs(E.slots) do E.home[i] = HOMES[k] or "all" end
    local MODES = { "Jitter", "Delay jitter", "Sway", "3-Way", "5-Way", "Staged", "Native" }
    local PITCH = { "Up", "Random", "Semi-Up", "Jitter", "Sway", "PAKETA", "Zero" }
    local YAW = { "Sideways", "Random", "Spin", "Opposite", "Side-based", "3-Way", "5-Way" }
    local GENE = { offset = { -30, 30, 0 }, range = { 20, 120, 60 }, delay = { 1, 8, 2 }, delay_r = { 0, 8, 0 }, stages = { 2, 8, 4 },
        left = { 20, 60, 58 }, right = { 20, 60, 58 }, offL = { -45, 10, -7 }, offR = { -10, 45, 11 }, mod_off = { -70, -20, -46 } }
    local function pick(t) return t[U.rand(1, #t)] end
    local function r01() return U.rand(0, 100000) / 100000 end

    local function genome_of(p)
        local g = { mode = U.has(MODES, p.mode) and p.mode or (p.mode == "Random" and "Jitter" or "Delay jitter") }
        for k, b in pairs(GENE) do g[k] = U.clamp(U.round(type(p[k]) == "number" and p[k] or b[3]), b[1], b[2]) end
        g.bfs = p.bfs or "Off"
        g.defensive = p.defensive and true or false
        g.def_pitch = U.has(PITCH, p.def_pitch) and p.def_pitch or "Random"
        g.def_yaw = U.has(YAW, p.def_yaw) and p.def_yaw or "Sideways"
        g.def_flick = p.def_flick and true or false
        return g
    end
    local function valid(g)
        if type(g) ~= "table" or not U.has(MODES, g.mode) then return false end
        for k, b in pairs(GENE) do if type(g[k]) ~= "number" then return false end; g[k] = U.clamp(U.round(g[k]), b[1], b[2]) end
        if not U.has({ "Off", "Peek Fake", "Peek Real" }, g.bfs) then g.bfs = "Off" end
        if not U.has(PITCH, g.def_pitch) then g.def_pitch = "Random" end
        if not U.has(YAW, g.def_yaw) then g.def_yaw = "Sideways" end
        g.defensive, g.def_flick = g.defensive == true, g.def_flick == true
        return true
    end
    local function apply(p, g)
        p.mode, p.native = g.mode, g.mode == "Native"
        for k in pairs(GENE) do p[k] = g[k] end
        if not p.native then p.offL, p.offR, p.mod_off = nil, nil, nil end
        p.bfs = g.bfs ~= "Off" and g.bfs or nil
        p.defensive, p.def_pitch, p.def_yaw, p.def_flick = g.defensive, g.def_pitch, g.def_yaw, g.def_flick
        p.genome = g
    end
    local function mutate(g, s)
        for k, b in pairs(GENE) do
            if r01() < 0.5 then g[k] = U.clamp(U.round(g[k] + U.randn() * s * (b[2] - b[1]) * 0.5), b[1], b[2]) end
        end
        if r01() < s * 0.35 then g.mode = pick(MODES) end
        if r01() < s * 0.3 then g.bfs = pick({ "Off", "Peek Fake", "Peek Real" }) end
        if r01() < s * 0.25 then g.defensive = not g.defensive end
        if r01() < s * 0.3 then g.def_pitch = pick(PITCH) end
        if r01() < s * 0.3 then g.def_yaw = pick(YAW) end
        if r01() < s * 0.2 then g.def_flick = not g.def_flick end
        return g
    end
    local function cross(a, b) local c = {}; for k, v in pairs(a) do c[k] = r01() < 0.5 and v or b[k] end; return c end
    local function seed()
        local hm = {}
        for i, p in ipairs(P) do if not p.evo then hm[#hm + 1] = i end end
        return mutate(genome_of(P[hm[U.rand(1, #hm)]]), 0.35)
    end

    -- байесовские счетчики: попадания по тебе (h) и увороты (d) по группе и профилю
    local function counts(g, i)
        if g == "all" then
            local h, d = 0, 0
            for _, gg in ipairs(RAP.aa.GROUPS) do local t = E.bc[gg] and E.bc[gg][i]; if t then h, d = h + t[1], d + t[2] end end
            return h, d
        end
        local t = E.bc[g] and E.bc[g][i]
        if t then return t[1], t[2] end
        return 0, 0
    end
    local function phi(z)
        local s, x = z < 0 and -1 or 1, U.abs(z) / 1.41421356
        local t = 1 / (1 + 0.3275911 * x)
        local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
        return 0.5 * (1 + s * y)
    end
    function E.score(g, i)
        local H, N = 0, 0
        for j = 1, #P do local h, d = counts(g, j); H, N = H + h, N + h + d end
        local base = (H + 1) / (N + 2.5)
        local h, d = counts(g, i)
        local n = h + d
        local m = (h + base * 4) / (n + 4)
        local sd = U.sqrt(U.max(m * (1 - m), 0.01) / (n + 4))
        return base - m, phi((m - base) / sd), n
    end
    -- A/B-оценка потомка: он сравнивается с эталоном (лучший профиль своей группы на момент рождения) только на
    -- событиях одного окна времени в одной группе - сопоставимые данные (те же карты, враги, твой стиль игры).
    -- Счетчики { попадания по тебе, увороты } с весами атрибуции. Вердикт при min_n событий у потомка и min_n/2 у эталона:
    -- P(потомок хуже) >= 80% -> слот помечается провалившимся (на ближайшей эволюции - откат к чемпиону / замена);
    -- P(потомок лучше) >= 80% -> потомок становится чемпионом группы; 3 x min_n событий без вердикта -> ничья (остается).
    E.ab, E.fail, E.ab_last = {}, {}, {}
    local function ab_start(i)
        local home = E.home[i]
        local ref, rf = nil, -1e9
        for j = 1, #P do
            if j ~= i then local f, _, n = E.score(home, j); if n >= 3 and f > rf then ref, rf = j, f end end
        end
        E.ab[i] = ref and { ref = ref, c = { 0, 0 }, r = { 0, 0 } } or nil
    end
    local function ab_check(s)
        local ab = E.ab[s]
        local min_n = RAP.v("ai.evo_n") or 12
        local cn, rn = ab.c[1] + ab.c[2], ab.r[1] + ab.r[2]
        if cn < min_n or rn < min_n / 2 then return end
        local pc, pr = (ab.c[1] + 1) / (cn + 2), (ab.r[1] + 1) / (rn + 2)
        local se = U.sqrt(U.max(pc * (1 - pc) / (cn + 2) + pr * (1 - pr) / (rn + 2), 1e-6))
        local pw = phi((pc - pr) / se)
        local verdict
        if pw >= 0.8 then verdict = "worse"; E.fail[s] = true
        elseif pw <= 0.2 then
            verdict = "better"
            local home = E.home[s]
            local f, _, n = E.score(home, s)
            E.champ[home] = { genome = (function() local c = {}; for k, v in pairs(P[s].genome or {}) do c[k] = v end; return c end)(), f = f, n = n, gen = E.gen }
            E.child[s] = nil
        elseif cn >= 3 * min_n then verdict = "tie" end
        if verdict then
            E.ab_last[s] = { verdict = verdict, pc = pc, pr = pr, cn = cn, rn = rn, ref = ab.ref }
            E.ab[s] = nil
            U.log("evo", "A/B %s vs %s: hit rate on you %.0f%% vs %.0f%% (n %.0f / %.0f) -> %s", P[s].name, P[ab.ref].name, pc * 100, pr * 100, cn, rn,
                verdict == "worse" and "child is worse, will be replaced" or (verdict == "better" and "child is the new champion" or "no clear difference, kept"))
        end
    end
    RAP.on("ai_reward", "evo", function(g, i, v, wgt)
        RAP.store.mark(KEY)
        local w = wgt or 1
        local row = E.bc[g]
        if not row then row = {}; E.bc[g] = row end
        for _, t in pairs(row) do t[1], t[2] = t[1] * 0.995, t[2] * 0.995 end
        local t = row[i]
        if not t then t = { 0, 0 }; row[i] = t end
        -- вес события - тот же, что у AI (голова 1.5, тело / уворот с учетом атрибуции)
        if v < 0 then t[1] = t[1] + w else t[2] = t[2] + w end
        if (E.trial[i] or 0) > 0 and (E.home[i] == g or E.home[i] == "all") then E.trial[i] = E.trial[i] - 1 end
        for s, ab in pairs(E.ab) do
            if E.home[s] == g or E.home[s] == "all" then
                local b = (i == s and ab.c) or (i == ab.ref and ab.r) or nil
                if b then
                    if v < 0 then b[1] = b[1] + w else b[2] = b[2] + w end
                    ab_check(s)
                end
            end
        end
    end)
    -- balance = true (выбор в начале раунда): пока идет A/B, потомок ставится, если у него заметно меньше событий,
    -- чем у эталона - иначе сравнение было бы на несопоставимых объемах данных
    function E.force(g, exclude, balance)
        if not RAP.v("ai.evo") then return nil end
        for _, i in ipairs(E.slots) do
            if (E.trial[i] or 0) > 0 and i ~= exclude and (E.home[i] == g or E.home[i] == "all") then return i end
        end
        if balance then
            for s, ab in pairs(E.ab) do
                if s ~= exclude and (E.home[s] == g or E.home[s] == "all") and ab.c[1] + ab.c[2] + 2 < ab.r[1] + ab.r[2] then return s end
            end
        end
        return nil
    end
    local function reset_slot(i)
        local AI = RAP.ai
        for _, g in ipairs(RAP.aa.GROUPS) do
            AI.st[g][i] = { n = 2, sum = 1 }
            for _, e in pairs(AI.en) do if e[g] then e[g][i] = nil end end
            if E.bc[g] then E.bc[g][i] = nil end
        end
        -- модель уворотов (v46): счетчики старого генома иначе доставались новорожденному
        for _, row in pairs(AI.bd) do row[i] = nil end
        for _, row in pairs(AI.bdw) do row[i] = nil end
        for _, e in pairs(AI.ebd) do for _, row in pairs(e) do row[i] = nil end end
    end
    local function copy(g) local c = {}; for k, v in pairs(g or {}) do c[k] = v end; return c end
    -- чемпион группы: слот с 2x min_n событий и уверенно (>= 80%) лучше среднего; хранится лучший по фитнесу
    local function update_champs(min_n)
        for _, i in ipairs(E.slots) do
            if (E.trial[i] or 0) <= 0 and P[i].genome then
                local home = E.home[i]
                local f, pw, n = E.score(home, i)
                local c = E.champ[home]
                if n >= 2 * min_n and pw <= 0.2 and (not c or f > c.f) then
                    E.champ[home] = { genome = copy(P[i].genome), f = f, n = n, gen = E.gen }
                    E.child[i] = nil
                    if RAP.v("ai.logs") then U.log("evo", "[%s] new champion: %s (fit %+.1f%%, n %.0f)", home, P[i].name, f * 100, n) end
                end
            end
        end
    end
    E.update_champs = update_champs
    function E.evolve(verbose)
        if not RAP.v("ai.evo") then return end
        RAP.store.mark(KEY)
        local min_n = RAP.v("ai.evo_n") or 12
        update_champs(min_n)
        local worst, wp = nil, 0
        for _, i in ipairs(E.slots) do
            if E.fail[i] then worst = i; break end        -- проиграл A/B эталону - в первую очередь
            if (E.trial[i] or 0) <= 0 then
                local _, pw, n = E.score(E.home[i], i)
                if n >= min_n and pw >= 0.8 and pw > wp then worst, wp = i, pw end
            end
        end
        if worst then
            E.fail[worst], E.ab[worst] = nil, nil
            for s, ab in pairs(E.ab) do if ab.ref == worst then E.ab[s] = nil end end   -- эталон меняется - сравнение недействительно
        end
        if not worst then if verbose then print("[evo] nothing to replace: no Evo slot is confidently worse than average") end; return end
        local g = E.home[worst]
        -- откат: слот занят потомком, и он провалился -> возвращается чемпион группы (если его нет в другом слоте)
        local ch = E.champ[g]
        if E.child[worst] and ch then
            local dup = false
            for _, j in ipairs(E.slots) do
                if j ~= worst and P[j].genome then
                    local same = true
                    for k, v in pairs(ch.genome) do if P[j].genome[k] ~= v then same = false; break end end
                    if same then dup = true; break end
                end
            end
            if not dup then
                local gnm = copy(ch.genome)
                valid(gnm)
                apply(P[worst], gnm)
                reset_slot(worst)
                E.trial[worst], E.child[worst] = 3, nil
                E.gen = E.gen + 1
                U.log("evo", "gen %d [%s]: %s failed -> rollback to champion (fit %+.1f%%, gen %d)", E.gen, g, P[worst].name, ch.f * 100, ch.gen or 0)
                RAP.toast(string.format("Evolution: %s rolled back to champion", P[worst].name))
                return
            end
        end
        local pool = {}
        for i = 1, #P do if i ~= worst then local f, _, n = E.score(g, i); if n >= 3 then pool[#pool + 1] = { i = i, f = f } end end end
        if #pool < 2 then return end
        local function tour() local b = pool[U.rand(1, #pool)]; for _ = 1, 2 do local c = pool[U.rand(1, #pool)]; if c.f > b.f then b = c end end; return b.i end
        local a, b = tour(), tour()
        local child = mutate(cross(genome_of(P[a]), genome_of(P[b])), (RAP.v("ai.evo_sigma") or 25) / 100)
        valid(child)
        apply(P[worst], child)
        reset_slot(worst)
        E.trial[worst], E.child[worst] = 5, true
        ab_start(worst)
        E.gen = E.gen + 1
        U.log("evo", "gen %d [%s]: %s reborn from %s x %s (%s, range %d)", E.gen, g, P[worst].name, P[a].name, P[b].name, child.mode, child.range)
        RAP.toast(string.format("Evolution: gen %d, %s reborn", E.gen, P[worst].name))
    end
    RAP.on("round", "evo", function() E.rounds = E.rounds + 1; if E.rounds % 4 == 0 then E.evolve(false) end end)
    RAP.resets.evo = function()
        RAP.store.mark(KEY)
        E.gen, E.bc, E.trial, E.champ, E.child, E.ab, E.ab_last, E.fail = 0, {}, {}, {}, {}, {}, {}, {}
        for _, i in ipairs(E.slots) do apply(P[i], seed()); reset_slot(i) end
    end

    do
        local d = RAP.store.get(KEY) or RAP.store.get(OLD)
        for k, i in ipairs(E.slots) do
            local g = d and type(d.genomes) == "table" and d.genomes[k]
            if g and valid(g) then apply(P[i], g) else apply(P[i], seed()) end
        end
        if d and type(d.champ) == "table" then
            for _, h in ipairs(HOMES) do
                local c = d.champ[h]
                if type(c) == "table" and type(c.genome) == "table" and valid(c.genome) and U.num(c.f) then
                    E.champ[h] = { genome = c.genome, f = U.num(c.f, -1, 1), n = U.num(c.n, 0, 1e4) or 0, gen = U.num(c.gen, 0) or 0 }
                end
            end
        end
        if d and type(d.child) == "table" then
            for k, i in ipairs(E.slots) do if d.child[k] == true then E.child[i] = true end end
        end
        if d and type(d.ab) == "table" then
            for k, i in ipairs(E.slots) do
                local a = d.ab[tostring(k)]
                local ref = type(a) == "table" and tonumber(a.ref)
                if ref and P[ref] and ref ~= i and type(a.c) == "table" and type(a.r) == "table" then
                    E.ab[i] = { ref = ref, c = { U.num(a.c[1], 0, 1e4) or 0, U.num(a.c[2], 0, 1e4) or 0 }, r = { U.num(a.r[1], 0, 1e4) or 0, U.num(a.r[2], 0, 1e4) or 0 } }
                end
            end
        end
        if d then
            E.gen = U.num(d.gen, 0) or 0
            if type(d.bc) == "table" then
                for g, row in pairs(d.bc) do
                    if type(row) == "table" then
                        E.bc[g] = {}
                        for k, v in pairs(row) do
                            local i = tonumber(k)
                            if i and P[i] and type(v) == "table" and U.num(v[1]) and U.num(v[2]) then E.bc[g][i] = { U.num(v[1], 0, 1e4), U.num(v[2], 0, 1e4) } end
                        end
                    end
                end
            end
        end
    end
    RAP.on("save", "evo", function(force)
        if not RAP.v("main.persist") or not RAP.store.need(KEY, force) then return end
        local gs, bc = {}, {}
        for k, i in ipairs(E.slots) do gs[k] = P[i].genome end
        for g, row in pairs(E.bc) do local t = {}; for i, v in pairs(row) do t[tostring(i)] = { U.round(v[1] * 100) / 100, U.round(v[2] * 100) / 100 } end; bc[g] = t end
        local child, ab = {}, {}
        for k, i in ipairs(E.slots) do
            child[k] = E.child[i] == true
            local a = E.ab[i]
            if a then ab[tostring(k)] = { ref = a.ref, c = a.c, r = a.r } end
        end
        RAP.store.set(KEY, { gen = E.gen, genomes = gs, bc = bc, champ = E.champ, child = child, ab = ab })
    end)
    RAP.on("panel_rows", "evo", function(rows) rows[#rows + 1] = { "evolution", "gen " .. E.gen } end)
end
---------------------------------------------------------------- консоль: AA / AI / эволюция
do
    local P = RAP.profiles.list
    RAP.cmd.ai = function()
        local pid = RAP.W.threat and RAP.W.pid(RAP.W.threat)
        for _, g in ipairs(RAP.aa.GROUPS) do
            if RAP.v("ai.merge") and (g == "slow" or g == "duck") then goto continue end
            local list = {}
            for _, i in ipairs(RAP.ai.pool(g)) do local m, _, n = RAP.ai.post(g, i, pid); list[#list + 1] = { i, m, n } end
            table.sort(list, function(a, b) return a[2] > b[2] end)
            local parts = {}
            for k = 1, math.min(3, #list) do parts[k] = string.format("%s %.0f%% (n %.0f)", P[list[k][1]].name, list[k][2] * 100, list[k][3]) end
            local cur = RAP.ai.cur[g]
            local xr, mode, conf = RAP.ai.explore_rate(g, pid)
            print(string.format("[ai] %-5s dodge estimate top: %s | now: %s (%s, %.0f s) | %s, best-vs-2nd %.0f%%, explore %.0f%%", g,
                table.concat(parts, ", "), cur and P[cur].name or "-", RAP.ai.how[g] or "-", math.min(999, RAP.ai.age(g)), mode, (conf or 0) * 100, xr * 100))
            ::continue::
        end
        if RAP.ai.wc_now then print("[ai] current threat weapon class: " .. RAP.ai.wc_now .. (RAP.v("ai.per_weapon") and "" or " (per-weapon learning off)")) end
        local n = 0
        for pid2, s in pairs(RAP.ai.sm) do
            if s.inv then n = n + 1 end
            if pid2 == pid and s.p1 then
                print(string.format("[ai] threat hit rate by side: A %.0f%%  B %.0f%%  confidence %.0f%%  phase shift %s",
                    s.p1 * 100, s.p2 * 100, (s.conf or 0) * 100, s.inv and "ON" or "OFF"))
            end
        end
        print(string.format("[ai] phase shift active against %d enemies", n))
    end
    RAP.cmd.evo = function()
        local E = RAP.evo
        for _, i in ipairs(E.slots) do
            local f, pw, n = E.score(E.home[i], i)
            local g = P[i].genome or {}
            print(string.format("[evo] %-6s [%-5s] fit %+5.1f%%  P(worse) %3.0f%%  n %4.1f  trial %d  %s rng %s dly %s L%s R%s%s", P[i].name, E.home[i],
                f * 100, pw * 100, n, E.trial[i] or 0, tostring(g.mode), tostring(g.range), tostring(g.delay), tostring(g.left), tostring(g.right),
                g.defensive and (" def " .. tostring(g.def_yaw)) or ""))
        end
        for i, ab in pairs(E.ab) do
            print(string.format("[evo] A/B %-6s vs %-12s child: %.1f hits / %.1f dodges  ref: %.1f / %.1f  (verdict at %d child events)",
                P[i].name, P[ab.ref].name, ab.c[1], ab.c[2], ab.r[1], ab.r[2], RAP.v("ai.evo_n") or 12))
        end
        for i, l in pairs(E.ab_last) do
            print(string.format("[evo] last A/B %-6s vs %-12s: hit rate on you %.0f%% vs %.0f%% -> %s", P[i].name, P[l.ref].name, l.pc * 100, l.pr * 100, l.verdict))
        end
        for _, h in ipairs({ "stand", "move", "slow", "air", "duck", "all" }) do
            local c = E.champ[h]
            if c then print(string.format("[evo] champion [%-5s] fit %+5.1f%%  n %.0f  gen %d  %s rng %s dly %s", h, c.f * 100, c.n, c.gen or 0,
                tostring(c.genome.mode), tostring(c.genome.range), tostring(c.genome.delay))) end
        end
        print("[evo] generation " .. E.gen)
    end
    RAP.cmd.evolve = function() RAP.evo.evolve(true) end
    RAP.cmd.reset_ai = function() RAP.ai.reset() end
end
---------------------------------------------------------------- confidence engine: единая шкала уверенности
-- Все системы отдают уверенность 0..1 и трактуют ее одинаково:
--   < 30% exploring (данных мало - эксперименты), 30-60% cautious (без резких смен), 60-80% preferred, >= 80% confident.
-- Цепочка: выстрел (attribution) -> классификатор AA врага -> стратегия рагебота -> профиль AA.
-- Вес выстрела уже учитывает уверенность классификатора; стратегии и профили меняются по одному правилу RAP.switch_ok
-- (вероятность "лучше" + отрыв больше неопределенности). /eclipse why показывает всю цепочку по текущей цели.
do
    local U = RAP.U
    function RAP.conf_level(p)
        p = p or 0
        if p < 0.3 then return "exploring" elseif p < 0.6 then return "cautious" elseif p < 0.8 then return "preferred" end
        return "confident"
    end
    function RAP.confidence(idx)
        local out = {}
        local tc = idx and RAP.TC[idx]
        out.classifier, out.aa_type, out.aa_sub = tc and (tc.aa.conf or 0) or 0, tc and tc.aa.type or "unknown", tc and tc.aa.sub
        local t = idx and RAP.strat.T[idx]
        if t then out.strategy, out.arm, out.state, out.samples, out.why, out.next, out.st = t.pconf or 0, RAP.strat.ARMS[t.arm], t.state, t.samples or 0, t.why, t.next, t end
        local AI, g = RAP.ai, RAP.aa and RAP.aa.group
        if g and AI and AI.cur[g] then
            local pid = tc and tc.id.pid
            local m, _, n = AI.post(g, AI.cur[g], pid)
            local xr, mode, conf = AI.explore_rate(g, pid)
            out.profile, out.pidx, out.group, out.dodge, out.events = RAP.profiles.list[AI.cur[g]].name, AI.cur[g], g, m, n
            out.aa_conf, out.aa_mode, out.explore, out.how, out.age, out.pid = conf or 0, mode, xr, AI.how[g], AI.age(g), pid
        end
        out.shot, out.eshot = RAP.CONF and RAP.CONF.shot, RAP.CONF and RAP.CONF.eshot
        -- общая уверенность решения по цели - самое слабое звено цепочки
        out.overall = U.min(out.classifier, out.strategy or 0, out.aa_conf or 1)
        return out
    end
    local function pc(v) return string.format("%.0f%%", (v or 0) * 100) end
    function RAP.explain()
        local thr = RAP.W.threat
        if not thr then print("[why] no current target (threat) - showing only ragebot overrides"); return end
        local idx = thr:get_index()
        local okn, name = pcall(thr.get_name, thr)
        local c = RAP.confidence(idx)
        print(string.format("[why] TARGET #%d %s", idx, okn and tostring(name) or ""))
        print(string.format("[why]  enemy AA: %s%s, classifier %s (%s)", c.aa_type, c.aa_sub and (" / " .. c.aa_sub) or "", pc(c.classifier), RAP.conf_level(c.classifier)))
        if c.st then
            local t, ST = c.st, RAP.strat
            print(string.format("[why]  strategy: %s, %s, confidence %s (%s), %.0f samples", c.arm, c.state or "-", pc(c.strategy), RAP.conf_level(c.strategy), c.samples))
            print(string.format("[why]    why: %s | next: %s", tostring(c.why or "-"), tostring(c.next or "-")))
            local mc = ST.post(t.key, t.arm, t.wg, t.aat)
            local rej = {}
            for a = 1, #ST.ARMS do
                if a ~= t.arm and ST.arm_ok(a) then local m = ST.post(t.key, a, t.wg, t.aat); rej[#rej + 1] = { ST.ARMS[a], m, m - mc } end
            end
            table.sort(rej, function(x, y) return x[2] > y[2] end)
            local parts = {}
            for k = 1, U.min(3, #rej) do parts[k] = string.format("%s %s (%+.0f)", rej[k][1], pc(rej[k][2]), rej[k][3] * 100) end
            if #parts > 0 then print("[why]    rejected: " .. table.concat(parts, ", ") .. string.format("  [current %s]", pc(mc))) end
        else
            print("[why]  strategy: Strategy AI off / target not learned (bot or no data)")
        end
        if c.profile then
            local AI = RAP.ai
            print(string.format("[why]  your AA [%s]: %s (%s, %.0f s), dodge estimate %s over %.1f events, best-vs-2nd %s (%s), explore %s",
                c.group, c.profile, c.how or "-", U.min(999, c.age or 0), pc(c.dodge), c.events, pc(c.aa_conf), c.aa_mode or "-", pc(c.explore)))
            local rej = {}
            for _, i in ipairs(AI.pool(c.group)) do
                if i ~= c.pidx then local m, _, n = AI.post(c.group, i, c.pid); rej[#rej + 1] = { RAP.profiles.list[i].name, m, n } end
            end
            table.sort(rej, function(x, y) return x[2] > y[2] end)
            local parts = {}
            for k = 1, U.min(3, #rej) do parts[k] = string.format("%s %s (%+.0f, n %.0f)", rej[k][1], pc(rej[k][2]), (rej[k][2] - c.dodge) * 100, rej[k][3]) end
            if #parts > 0 then print("[why]    rejected: " .. table.concat(parts, ", ")) end
            local A = RAP.aa
            local ov = {}
            if A.manual and A.manual ~= 0 then ov[#ov + 1] = "manual" end
            if A.safe then ov[#ov + 1] = "safe head" end
            if A.fs then ov[#ov + 1] = "freestanding" end
            if A.brute then ov[#ov + 1] = "anti-brute (" .. tostring(A.brute_why or "-") .. ")" end
            if A.inv then ov[#ov + 1] = "phase shift" end
            if A.def and globals.curtime - A.def < 0.2 and globals.curtime >= A.def then ov[#ov + 1] = "defensive" end
            print("[why]    overrides on top of the profile: " .. (#ov > 0 and table.concat(ov, ", ") or "none"))
        end
        if c.shot then print(string.format("[why]  your last shot: %s, learning weight %.2f (%s)", c.shot.r, c.shot.w, c.shot.why)) end
        if c.eshot then print(string.format("[why]  last enemy shot at you: %s, learning weight %.2f (%s)", c.eshot.r, c.eshot.w, c.eshot.why)) end
        print(string.format("[why]  overall decision confidence: %s (%s) - the weakest link of the chain", pc(c.overall), RAP.conf_level(c.overall)))
    end
    RAP.on("panel_rows", "confidence", function(rows)
        local thr = RAP.W.threat
        if not thr then return end
        local c = RAP.confidence(thr:get_index())
        rows[#rows + 1] = { "decision", string.format("%s  classifier %s / strategy %s", RAP.conf_level(c.overall), pc(c.classifier), pc(c.strategy)) }
        if c.shot then rows[#rows + 1] = { "last shot weight", string.format("%.2f  %s", c.shot.w, c.shot.r) } end
    end)
end
---------------------------------------------------------------- visuals: меню и тема
do
    local G1 = RAP.menu.group("Visuals", "Indicators & theme", 1)
    G1.color("vis.accent", "Accent color", color(160, 200, 255))
    G1.switch("vis.inds", "Crosshair indicators", true)
    G1.combo("vis.style", "Indicator style", { "Modern", "Pixel", "Minimal" }, { dep = function() return RAP.v("vis.inds") end })
    G1.combo("vis.detail", "Indicator detail", { "Normal", "Minimal", "Debug" }, { dep = function() return RAP.v("vis.inds") end })
    G1.switch("vis.arrows", "Manual direction arrows", true)
    local G2 = RAP.menu.group("Visuals", "Widgets", 2)
    G2.switch("vis.water", "Watermark", true)
    G2.switch("vis.binds", "Keybinds", true)
    G2.switch("vis.panel", "AI brain panel", true)
    G2.switch("vis.toasts", "Notifications", true)
    G2.switch("vis.debug", "Debug panel (why the script decided)", false)
    G2.button("Reset widget positions", function() if RAP.wid then RAP.wid.reset() end end)
    local G3 = RAP.menu.group("Visuals", "Effects", 1)
    G3.switch("fx.logs", "Shot logs on screen", true)
    G3.switch("fx.marks", "Damage markers", true)
    G3.switch("fx.hitmark", "Crosshair hitmarker", true)
    G3.switch("fx.kill", "Kill effects", true)
    G3.switch("fx.esp", "Resolver info above enemies", true)
    G3.switch("fx.slowed", "Slowed-down warning", true)
    G3.combo("fx.sound", "Hit sound", { "Off", "Skeet", "Bell", "Click", "Custom" })
    G3.input("fx.snd_path", "Custom sound path", "buttons/arena_switch_press_02", { dep = function() return RAP.v("fx.sound") == "Custom" end })
    local G4 = RAP.menu.group("Visuals", "Camera", 2)
    G4.combo("cam.aspect_pre", "Aspect ratio preset", { "Custom", "Off", "16:9 (1.78)", "16:10 (1.60)", "4:3 (1.33)", "5:4 (1.25)", "Stretched 1.20" })
    G4.slider("cam.aspect", "Aspect ratio (0 = off)", 0, 250, 0, 0.01)
    G4.switch("cam.vm", "Viewmodel changer", false)
    for _, a in ipairs({ { "cam.vm_fov", "Viewmodel FOV", 40, 120, 68, 1 }, { "cam.vm_x", "Viewmodel X", -100, 100, 10, 0.1 },
        { "cam.vm_y", "Viewmodel Y", -100, 100, 10, 0.1 }, { "cam.vm_z", "Viewmodel Z", -100, 100, -10, 0.1 } }) do
        G4.slider(a[1], a[2], a[3], a[4], a[5], a[6], nil, { dep = function() return RAP.v("cam.vm") end })
    end
    G4.switch("cam.tp", "Thirdperson distance", false)
    G4.slider("cam.tp_d", "Thirdperson distance value", 30, 250, 120, 1, nil, { dep = function() return RAP.v("cam.tp") end })
end

do
    local U = RAP.U
    local T = { fonts = {} }
    RAP.theme = T
    function T.font(key, name, size, flags, fb)
        local f = T.fonts[key]
        if f == nil then
            local ok, v = pcall(render.load_font, name, size, flags)
            f = (ok and v) or fb
            T.fonts[key] = f
        end
        return f
    end
    function T.measure(f, s)
        local ok, v = pcall(render.measure_text, f, nil, s)
        if ok and v then return v.x, v.y end
        return #s * 6, 12
    end
    function T.accent()
        local ok, c = pcall(function() return RAP.cfg["vis.accent"]:get() end)
        if ok and c then return c end
        local ok2, s = pcall(ui.get_style, "Link Active")
        return ok2 and s or color(160, 200, 255)
    end
    function T.a(c, a) return color(c.r, c.g, c.b, U.floor(U.clamp(a, 0, 1) * (c.a or 255))) end
    -- цветной текст: коды \aRRGGBBAA перед символами (Neverlose render.text)
    function T.tag(c, a) return string.format("\a%02X%02X%02X%02X", c.r, c.g, c.b, U.floor((c.a or 255) * (a or 1))) end
    function T.grad(text, c1, c2, shift, alpha)
        local n, out = #text, {}
        for i = 1, n do
            local t = ((n > 1 and (i - 1) / (n - 1) or 0) + (shift or 0)) % 1
            local k = 1 - U.abs(2 * t - 1)
            local c = color(U.floor(c1.r + (c2.r - c1.r) * k), U.floor(c1.g + (c2.g - c1.g) * k), U.floor(c1.b + (c2.b - c1.b) * k), 255)
            out[#out + 1] = T.tag(c, alpha) .. text:sub(i, i)
        end
        return table.concat(out)
    end
    -- стеклянная панель: свечение акцента -> размытие фона -> полупрозрачная заливка -> тонкий контур -> бегущий блик сверху
    function T.panel(x, y, w, h, a)
        local c = T.accent()
        local r = 10
        local p1, p2 = vector(x, y), vector(x + w, y + h)
        pcall(render.shadow, p1, p2, T.a(c, 0.28 * a), 26, 0, r)
        pcall(render.blur, p1, p2, 0, a, r)
        render.rect(p1, p2, color(14, 15, 22, U.floor(150 * a)), r)
        pcall(render.rect_outline, p1, p2, color(255, 255, 255, U.floor(22 * a)), 1, r)
        local t = (globals.realtime * 0.22) % 1
        local seg = U.max(24, w * 0.35)
        local cx = x + r + (w - 2 * r - seg) * (0.5 - 0.5 * math.cos(t * 2 * math.pi))
        pcall(render.gradient, vector(cx, y), vector(cx + seg * 0.5, y + 1), T.a(c, 0), T.a(c, a), T.a(c, 0), T.a(c, a))
        pcall(render.gradient, vector(cx + seg * 0.5, y), vector(cx + seg, y + 1), T.a(c, a), T.a(c, 0), T.a(c, a), T.a(c, 0))
        return c
    end
    -- уведомления
    T.toasts = {}
    function RAP.toast(text)
        if not RAP.v("vis.toasts") then return end
        T.toasts[#T.toasts + 1] = { text = tostring(text), t = globals.realtime }
        if #T.toasts > 6 then table.remove(T.toasts, 1) end
    end
end
---------------------------------------------------------------- widgets: watermark, keybinds, AI panel, уведомления
do
    local U, T = RAP.U, RAP.theme
    local KEY = "rap2_widgets"
    local DEF = { water = { -1, 10 }, binds = { 20, 380 }, panel = { 20, 500 }, debug = { 20, 640 } }
    local POS = {}
    local W = {}
    RAP.wid = W
    function W.reset() for k, v in pairs(DEF) do POS[k] = { x = v[1], y = v[2] } end; RAP.store.set(KEY, POS) end
    for k, v in pairs(DEF) do POS[k] = { x = v[1], y = v[2] } end
    do
        local d = RAP.store.get(KEY)
        if d then for k in pairs(DEF) do local p = d[k]; if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then POS[k] = { x = p.x, y = p.y } end end end
    end
    local DRAG = { id = nil, was = false }
    local function inr(p, x, y, w, h) return p.x >= x and p.x <= x + w and p.y >= y and p.y <= y + h end
    local function place(id, w, h)
        local p = POS[id]
        local sz = render.screen_size()
        if p.x < 0 then p.x = sz.x - w - 20 end
        p.x, p.y = U.clamp(p.x, 0, U.max(0, sz.x - w)), U.clamp(p.y, 0, U.max(0, sz.y - h))
        if ui.get_alpha() > 0.3 then
            local mp, down = ui.get_mouse_position(), common.is_button_down(1)
            if not DRAG.id and down and not DRAG.was and inr(mp, p.x, p.y, w, h) then
                local mpos, msz = ui.get_position(), ui.get_size()
                if not inr(mp, mpos.x, mpos.y, msz.x, msz.y) then DRAG.id, DRAG.ox, DRAG.oy = id, mp.x - p.x, mp.y - p.y end
            end
            if DRAG.id == id then
                if down then p.x, p.y = mp.x - DRAG.ox, mp.y - DRAG.oy else DRAG.id = nil; RAP.store.set(KEY, POS) end
            end
            render.rect_outline(vector(p.x - 2, p.y - 2), vector(p.x + w + 2, p.y + h + 2), color(255, 255, 255, DRAG.id == id and 140 or 45), 1, 6)
        end
        return p.x, p.y
    end
    pcall(function() events.mouse_input:set(function() if DRAG.id then return false end end) end)

    local FPS = { v = 0, t = 0 }
    local function water()
        local now = globals.realtime
        if now - FPS.t > 0.5 then
            FPS.t = now
            local ft = globals.absoluteframetime or globals.frametime or 0
            FPS.v = ft > 0 and U.round(1 / ft) or 0
        end
        local fb, fr = T.font("wm_b", "Verdana", 12, "ab", 1), T.font("wm_r", "Verdana", 12, "a", 1)
        local c = T.accent()
        local okn, user = pcall(common.get_username)
        local okt, tm = pcall(common.get_date, "%H:%M")
        local fcol = FPS.v >= 120 and color(150, 230, 150) or (FPS.v >= 60 and color(240, 210, 120) or color(255, 120, 120))
        local segs = { { okn and tostring(user) or "user", color(235, 235, 240) }, { FPS.v .. " fps", fcol },
            { U.round((RAP.W.ping_s or RAP.W.ping()) * 1000) .. " ms", color(200, 200, 210) } }
        if okt and tm then segs[#segs + 1] = { tostring(tm), color(200, 200, 210) } end
        local title = RAP.NAME
        local tw1 = T.measure(fb, title) + 14
        local w = tw1 + 18
        for i, s in ipairs(segs) do w = w + T.measure(fr, s[1]) + (i > 1 and 14 or 0) end
        local h = 22
        local x, y = place("water", w, h)
        T.panel(x, y, w, h, 1)
        local dk = color(U.floor(c.r * 0.7), U.floor(c.g * 0.7), U.floor(c.b * 0.7), 245)
        if not pcall(render.gradient, vector(x, y), vector(x + tw1, y + h), T.a(c, 0.96), dk, T.a(c, 0.96), dk, 6) then
            render.rect(vector(x, y), vector(x + tw1, y + h), c, 6)
        end
        render.text(fb, vector(x + 7, y + 4), color(18, 18, 24, 255), nil, title)
        local tx = x + tw1 + 8
        for i, s in ipairs(segs) do
            if i > 1 then render.rect(vector(tx + 4, y + 10), vector(tx + 6, y + 12), T.a(c, 0.8), 1); tx = tx + 14 end
            render.text(fr, vector(tx, y + 4), s[2], nil, s[1])
            tx = tx + T.measure(fr, s[1])
        end
    end

    local function list_panel(id, title, rows, minw)
        local fr = T.font("wm_r", "Verdana", 12, "a", 1)
        local w = minw
        for _, r in ipairs(rows) do w = U.max(w, T.measure(fr, r[1]) + T.measure(fr, r[2]) + 30) end
        local h = 22 + #rows * 15 + 4
        local x, y = place(id, w, h)
        local c = T.panel(x, y, w, h, 1)
        render.text(fr, vector(x + w / 2, y + 5), c, "c", title)
        for k, r in ipairs(rows) do
            local ry = y + 21 + (k - 1) * 15
            render.text(fr, vector(x + 8, ry), color(230, 230, 235), nil, r[1])
            render.text(fr, vector(x + w - 8, ry), r[3] or color(170, 200, 255), "r", r[2])
        end
    end
    W.list_panel = list_panel
    local function binds()
        local rows = {}
        local ok, bl = pcall(ui.get_binds)
        if ok and type(bl) == "table" then
            for _, b in ipairs(bl) do if b.active then rows[#rows + 1] = { tostring(b.name), b.mode == 1 and "hold" or "toggle" } end end
        end
        if #rows == 0 and ui.get_alpha() < 0.3 then return end
        list_panel("binds", "keybinds", rows, 170)
    end
    local PR = { t = -1, rows = {} }
    local function panel()
        local now = globals.realtime
        if now - PR.t > 0.5 then
            PR.t = now
            local rows = {}
            local V = RAP.ragev
            rows[#rows + 1] = { "target AA", V.aat and V.aat:upper() or "-" }
            rows[#rows + 1] = { "strategy", V.mode and string.format("%s %.0f%%", V.mode, (V.conf or 0) * 100) or "-" }
            rows[#rows + 1] = { "why", V.why or "-" }
            local s = RAP.tele.summary(RAP.tele.cur)
            rows[#rows + 1] = { "hit rate", s.hit and string.format("%.0f%% of %d", s.hit * 100, s.shots) or "-" }
            rows[#rows + 1] = { "AA dodges", s.dodge and string.format("%.0f%%", s.dodge * 100) or "-" }
            RAP.run("panel_rows", rows)
            PR.rows = rows
        end
        list_panel("panel", "AI brain", PR.rows, 220)
    end
    local function toasts()
        local sz, now = render.screen_size(), globals.realtime
        local fr = T.font("wm_r", "Verdana", 12, "a", 1)
        local y = (RAP.v("vis.water") and POS.water.y + 30) or 40
        for i = #T.toasts, 1, -1 do
            local t = T.toasts[i]
            local age = now - t.t
            if age > 4.6 then table.remove(T.toasts, i)
            else
                local a = age < 0.2 and age / 0.2 or (age > 4.2 and (4.6 - age) / 0.4 or 1)
                local w = T.measure(fr, t.text) + 20
                local x = sz.x - 20 - w * U.min(1, a * 1.5)
                T.panel(x, y, w, 20, a)
                render.text(fr, vector(x + 10, y + 4), color(235, 235, 240, U.floor(255 * a)), nil, t.text)
                y = y + 24
            end
        end
    end
    RAP.on("frame", "widgets", function()
        if RAP.v("vis.water") then water() end
        if RAP.v("vis.binds") then binds() end
        local me = entity.get_local_player()
        if RAP.v("vis.panel") and (ui.get_alpha() > 0.3 or (me and me:is_alive())) then panel() end
        toasts()
        local down = common.is_button_down(1)
        -- перетаскивание обрывается, если меню закрыли / виджет скрыли посреди drag: иначе DRAG.id оставался, и
        -- mouse_input блокировал мышь в игре до следующего открытия меню
        if DRAG.id and (not down or ui.get_alpha() <= 0.3) then DRAG.id = nil; RAP.store.set(KEY, POS) end
        DRAG.was = down
    end, 50)
end
---------------------------------------------------------------- crosshair indicators (Modern / Pixel / Minimal)
-- Строки собираются от модулей: RAP.on("ind_rows", name, function(add) add(text, color, prio) end).
-- prio: 1 важнее всего. Detail: Minimal <= 3, Normal <= 5, Debug - все.
do
    local U, T = RAP.U, RAP.theme
    local IA = { rows = {}, scope = 0, bar = 0, ord = 0 }
    local MAXP = { Minimal = 3, Normal = 5, Debug = 99 }

    RAP.on("ind_rows", "rage", function(add)
        local W, V = RAP.W, RAP.ragev
        if RAP.ref.on(RAP.ref.dt) then
            add(string.format("DT %d%%", U.floor((W.charge or 0) * 100)), (W.charge or 0) >= 1 and color(160, 255, 160) or color(255, 160, 120), 1)
        elseif RAP.ref.on(RAP.ref.hs) then add("HIDE SHOTS", color(200, 200, 255), 2) end
        if RAP.v("rage.dmg_on") and RAP.v("rage.dmg_key") then add("DMG " .. tostring(RAP.v("rage.dmg_val")), color(255, 220, 120), 2) end

        if V.aat then add("TARGET " .. V.aat:upper(), V.aat == "jitter" and color(255, 170, 90) or color(200, 200, 220), 4) end
        if V.mode and V.mode ~= "Default" then add(V.mode:upper(), V.mode:find("Force") and color(255, 170, 120) or color(255, 210, 150), V.mode:find("Force") and 3 or 4) end
        if RAP.v("fx.slowed") then
            local me = W.me
            local vm = me and W.alive and me.m_flVelocityModifier
            if vm and vm < 0.99 then add(string.format("SLOWED %d%%", U.round(vm * 100)), color(255, 170, 90), 2) end
        end
    end)

    local function draw()
        if not RAP.v("vis.inds") then return end
        local me = entity.get_local_player()
        if not me or not me:is_alive() then return end
        local style, detail = RAP.v("vis.style") or "Modern", RAP.v("vis.detail") or "Normal"
        local px = style == "Pixel"
        local ft = px and T.font("px_t", "Small Fonts", 9, "o", 2) or T.font("md_t", "Verdana", 12, "abd", 4)
        local fr = px and T.font("px_r", "Small Fonts", 9, "o", 2) or T.font("md_r", "Verdana", 11, "ad", 1)
        local dt = U.clamp(globals.frametime or 0.016, 0, 0.1)
        local k = dt * 12
        local acc = T.accent()
        local sz = render.screen_size()
        local cx, cy = U.floor(sz.x * 0.5), U.floor(sz.y * 0.5)
        IA.scope = U.lerp(IA.scope, me.m_bIsScoped and 1 or 0, k)
        local function xp(w) return U.round(U.lerp(cx - w * 0.5, cx + 14, IA.scope)) end
        local y = cy + 22
        if style ~= "Minimal" then
            local title = px and "ECLIPSE" or "eclipse"
            local tw, th = T.measure(ft, title)
            local x = xp(tw)
            render.text(ft, vector(x, y), color(255, 255, 255), nil, T.grad(title, color(245, 245, 250), acc, globals.realtime * 0.35))
            local ch = RAP.W.charge or 0
            pcall(render.circle_outline, vector(x + tw + 8, y + th * 0.5), color(40, 40, 48, 200), 4.5, 0, 1, 2)
            if ch > 0 then pcall(render.circle_outline, vector(x + tw + 8, y + th * 0.5), ch >= 1 and acc or color(255, 170, 110), 4.5, -90, ch, 2) end
            y = y + th + 2
            -- полоса десинка
            local okd, frac, left = pcall(function()
                local md = rage.antiaim:get_max_desync()
                local d = U.norm(rage.antiaim:get_rotation(true) - rage.antiaim:get_rotation())
                return md and md > 0 and U.clamp(U.abs(d) / md, 0, 1) or 0, d < 0
            end)
            IA.bar = U.lerp(IA.bar, okd and frac or 0, k)
            local bw = 44
            local bx = xp(bw)
            render.rect(vector(bx, y), vector(bx + bw, y + 3), color(10, 10, 14, 170), 2)
            local fw = U.round(bw * IA.bar)
            if fw > 1 then
                if okd and left then pcall(render.gradient, vector(bx, y), vector(bx + fw, y + 3), acc, T.a(acc, 0.35), acc, T.a(acc, 0.35), 2)
                else pcall(render.gradient, vector(bx + bw - fw, y), vector(bx + bw, y + 3), T.a(acc, 0.35), acc, T.a(acc, 0.35), acc, 2) end
            end
            y = y + 7
            local st = RAP.W.state or ""
            st = px and st:upper() or st
            local sw = T.measure(fr, st)
            render.text(fr, vector(xp(sw), y), color(200, 200, 210, 190), nil, st)
            y = y + select(2, T.measure(fr, "A")) + 3
        end
        -- строки
        local list, maxp = {}, MAXP[detail] or 5
        RAP.run("ind_rows", function(text, col, pri) if (pri or 5) <= maxp then list[#list + 1] = { text, col or color(230, 230, 235), pri or 5 } end end)
        local seen = {}
        for _, it in ipairs(list) do
            local key = (it[1]:match("^[^%d:%(]+") or it[1]):gsub("%s+$", "")
            if not seen[key] then
                seen[key] = true
                local r = IA.rows[key]
                if not r then IA.ord = IA.ord + 1; r = { a = 0, ord = IA.ord }; IA.rows[key] = r end
                r.txt, r.col, r.pri, r.live = it[1], it[2], it[3], true
            end
        end
        local rows = {}
        for key, r in pairs(IA.rows) do
            if not seen[key] then r.live = false end
            r.a = U.lerp(r.a, r.live and 1 or 0, k)
            if not r.live and r.a < 0.03 then IA.rows[key] = nil else rows[#rows + 1] = r end
        end
        table.sort(rows, function(p, q) if p.pri ~= q.pri then return p.pri < q.pri end return p.ord < q.ord end)
        local rh = select(2, T.measure(fr, "A"))
        for n, r in ipairs(rows) do
            if n > 8 then break end
            r.y = r.y and U.lerp(r.y, y, k) or y
            local s = px and r.txt:upper() or r.txt
            local w = T.measure(fr, s)
            local rx = xp(w)
            if r.pri <= 2 then render.rect(vector(rx - 6, r.y + rh * 0.5 - 1), vector(rx - 3, r.y + rh * 0.5 + 2), T.a(r.col, r.a), 1) end
            render.text(fr, vector(rx, U.round(r.y)), T.a(r.col, r.a), nil, s)
            y = y + rh + 1
        end
        if RAP.v("vis.arrows") and RAP.aa and RAP.aa.manual and RAP.aa.manual ~= 0 then
            local m = RAP.aa.manual
            if m == 180 then render.poly(acc, vector(cx, cy + 52), vector(cx - 6, cy + 43), vector(cx + 6, cy + 43))
            else
                local d = m < 0 and -1 or 1
                local ax = cx + d * 46
                render.poly(acc, vector(ax + d * 9, cy), vector(ax, cy - 6), vector(ax, cy + 6))
            end
        end
    end
    RAP.on("frame", "indicators", draw, 40)
end
---------------------------------------------------------------- effects: логи выстрелов, маркеры, хитмаркер, kill fx, ESP, звук
do
    local U, T = RAP.U, RAP.theme
    local HG = { [0] = "body", "head", "chest", "stomach", "left arm", "right arm", "left leg", "right leg", [10] = "gear" }
    local LOG, MARK = {}, {}
    local HM = { t = -9 }
    local KF = { t = -9, n = 0, last = -9 }
    local STREAK = { [2] = "DOUBLE KILL", [3] = "TRIPLE KILL", [4] = "QUAD KILL", [5] = "ACE" }
    local SOUNDS = { Skeet = "buttons/arena_switch_press_02", Bell = "training/bell_normal", Click = "buttons/button15" }
    local W, D = color(235, 235, 240), color(160, 160, 170)

    local function push(segs)
        LOG[#LOG + 1] = { segs = segs, t = globals.realtime }
        if #LOG > 5 then table.remove(LOG, 1) end
    end
    RAP.on("our_ack", "effects", function(rec, e)
        local name = e.target and e.target:get_name() or "?"
        if e.state == nil then
            local hp = e.target and e.target.m_iHealth or 0
            if RAP.v("fx.logs") then
                push({ { "Hit ", W }, { name, "A" }, { " in the ", W }, { HG[e.hitgroup] or "?", e.hitgroup == 1 and color(255, 215, 90) or W },
                    { " for ", W }, { tostring(e.damage or 0), color(140, 230, 140) },
                    { (hp and hp <= 0) and " (dead)" or string.format(" (%d hp left)", hp or 0), D },
                    { string.format("  |  hc %d%%  bt %dt%s", e.hitchance or 0, e.backtrack or 0, rec.ctx.mode and ("  " .. rec.ctx.mode:lower()) or ""), D } })
            end
            if RAP.v("fx.marks") and e.target then
                local ok, pos = pcall(e.target.get_hitbox_position, e.target, e.hitgroup == 1 and 0 or 5)
                if ok and pos then MARK[#MARK + 1] = { pos = pos, dmg = e.damage or 0, head = e.hitgroup == 1, t = globals.realtime } end
                if #MARK > 12 then table.remove(MARK, 1) end
            end
        elseif RAP.v("fx.logs") then
            push({ { "Missed ", W }, { name, "A" }, { "'s " .. (HG[e.wanted_hitgroup] or "?") .. " due to ", W },
                { tostring(e.state), color(255, 120, 120) }, { string.format("  |  hc %d%%%s", e.hitchance or 0,
                    rec.ctx.aat and ("  " .. rec.ctx.aat) or ""), D } })
        end
    end)
    events.player_hurt:set(function(e)
        U.safe("fx hurt", function()
            local me = entity.get_local_player()
            if not me or entity.get(e.attacker, true) ~= me or entity.get(e.userid, true) == me then return end
            HM.t, HM.head = globals.realtime, e.hitgroup == 1
            local s = RAP.v("fx.sound")
            if s and s ~= "Off" then
                local p = tostring((s == "Custom" and RAP.v("fx.snd_path")) or SOUNDS[s] or ""):gsub("[;\"%c]", "")
                if p ~= "" then utils.console_exec("play " .. p) end
            end
        end)
    end)
    events.player_death:set(function(e)
        U.safe("fx death", function()
            local me = entity.get_local_player()
            if not me or entity.get(e.attacker, true) ~= me or entity.get(e.userid, true) == me then return end
            local now = globals.realtime
            KF.n = (now - KF.last < 5) and KF.n + 1 or 1
            KF.last, KF.t, KF.hs = now, now, e.headshot and true or false
            KF.txt = STREAK[U.min(KF.n, 5)] or (KF.hs and "HEADSHOT" or "KILL")
        end)
    end)
    RAP.on("round", "effects", function() KF.n = 0 end)

    local function draw()
        local sz, now = render.screen_size(), globals.realtime
        local cx, cy = U.floor(sz.x * 0.5), U.floor(sz.y * 0.5)
        local acc = T.accent()
        local f12 = T.font("fx_t", "Verdana", 12, "ad", 1)
        -- логи
        local y = cy + 150
        for i = #LOG, 1, -1 do
            local s = LOG[i]
            local age = now - s.t
            if age > 4.5 then table.remove(LOG, i)
            else
                local a = age < 0.25 and age / 0.25 or (age > 4 and (4.5 - age) / 0.5 or 1)
                local plain, parts = {}, {}
                for _, sg in ipairs(s.segs) do plain[#plain + 1] = sg[1]; parts[#parts + 1] = T.tag(sg[2] == "A" and acc or sg[2], a) .. sg[1] end
                local w = T.measure(f12, table.concat(plain)) + 22
                local x = U.floor(cx - w * 0.5)
                local yy = U.floor(y + (1 - U.min(1, age / 0.25)) * 10)
                T.panel(x, yy, w, 20, a)
                render.text(f12, vector(x + 12, yy + 4), color(255, 255, 255, U.floor(255 * a)), nil, table.concat(parts))
                y = y + 24
            end
        end
        -- маркеры урона
        local f14 = T.font("fx_m", "Verdana", 14, "abd", 4)
        for i = #MARK, 1, -1 do
            local mk = MARK[i]
            local age = now - mk.t
            if age > 1.4 then table.remove(MARK, i)
            else
                local ok, sp = pcall(render.world_to_screen, mk.pos)
                if ok and sp then
                    local a = age > 0.9 and (1.4 - age) / 0.5 or 1
                    render.text(f14, vector(sp.x, sp.y - 18 - age * 36), T.a(mk.head and color(255, 215, 90) or color(255, 255, 255), a), "c", "-" .. mk.dmg)
                end
            end
        end
        -- хитмаркер
        if RAP.v("fx.hitmark") and now - HM.t < 0.5 then
            local a = 1 - (now - HM.t) / 0.5
            local col = HM.head and T.a(acc, a) or color(255, 255, 255, U.floor(255 * a))
            for _, d in ipairs({ { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
                render.line(vector(cx + d[1] * 5, cy + d[2] * 5), vector(cx + d[1] * 11, cy + d[2] * 11), col)
            end
        end
        -- серия убийств
        if RAP.v("fx.kill") and now - KF.t < 1.6 then
            local age = now - KF.t
            local a = age < 1.2 and 1 or (1.6 - age) / 0.4
            local pop = age < 0.12 and age / 0.12 or 1
            local big = T.font(KF.n >= 2 and "fx_k2" or "fx_k1", "Verdana", KF.n >= 2 and 22 or 16, "abd", 4)
            local ky = U.floor(sz.y * 0.27 - (1 - pop) * 12)
            render.text(big, vector(cx, ky), T.a(KF.n >= 2 and acc or color(255, 255, 255), a * pop), "c", KF.txt or "KILL")
            if KF.n >= 2 and KF.hs then render.text(f12, vector(cx, ky + 26), color(255, 215, 90, U.floor(220 * a)), "c", "headshot") end
            if age < 0.35 then
                local fa, w = (0.35 - age) / 0.35, U.floor(sz.x * 0.12)
                pcall(render.gradient, vector(0, 0), vector(w, sz.y), T.a(acc, 0.35 * fa), T.a(acc, 0), T.a(acc, 0.35 * fa), T.a(acc, 0))
                pcall(render.gradient, vector(sz.x - w, 0), vector(sz.x, sz.y), T.a(acc, 0), T.a(acc, 0.35 * fa), T.a(acc, 0), T.a(acc, 0.35 * fa))
            end
        end
        -- подпись над врагами: тип AA, режим brain, промахи по correction
        if RAP.v("fx.esp") then
            local fs = T.font("fx_e", "Verdana", 10, "ad", 1)
            for _, en in ipairs(RAP.W.enemies or {}) do
                if not en.dormant and en.ent:is_alive() then
                    local aat = RAP.aat.type(en.idx)
                    if aat then
                        local o = en.ent:get_origin()
                        local ok, sp = pcall(render.world_to_screen, vector(o.x, o.y, o.z + 84))
                        if ok and sp then
                            local t = RAP.strat.T[en.idx]
                            local txt = aat:upper() .. (t and ("  " .. RAP.strat.ARMS[t.arm]:lower()) or "")
                            local cr = en.pid and RAP.strat.corr[en.pid] or 0
                            if cr >= 2 then txt = txt .. string.format("  miss x%d", U.round(cr)) end
                            local w = T.measure(fs, txt) + 10
                            local col = aat == "jitter" and color(255, 170, 90) or (aat == "wide" and color(255, 120, 120) or color(150, 220, 150))
                            render.rect(vector(sp.x - w / 2, sp.y - 7), vector(sp.x + w / 2, sp.y + 7), color(14, 14, 20, 170), 4)
                            render.rect(vector(sp.x - w / 2, sp.y - 7), vector(sp.x - w / 2 + 2, sp.y + 7), col, 1)
                            render.text(fs, vector(sp.x + 1, sp.y - 6), color(235, 235, 240, 230), "c", txt)
                        end
                    end
                end
            end
        end
    end
    RAP.on("frame", "effects", draw, 60)

    -- камера: исходные значения возвращаются при выключении / выгрузке
    local CAM, CV = {}, { "viewmodel_fov", "viewmodel_offset_x", "viewmodel_offset_y", "viewmodel_offset_z", "cam_idealdist" }
    local function cget(n) local ok, v = pcall(function() return cvar[n]:float() end); return ok and v or nil end
    local function cset(n, v) pcall(function() cvar[n]:float(v, true) end) end
    for _, n in ipairs(CV) do CAM[n] = cget(n) end
    local AR0 = cget("r_aspectratio") or 0      -- твое значение до скрипта: возвращается при "0 = off" и выгрузке
    local TPO = false
    local function apply_cam()
        if RAP.v("cam.vm") then
            cset("viewmodel_fov", RAP.v("cam.vm_fov")); cset("viewmodel_offset_x", RAP.v("cam.vm_x") / 10)
            cset("viewmodel_offset_y", RAP.v("cam.vm_y") / 10); cset("viewmodel_offset_z", RAP.v("cam.vm_z") / 10)
        else
            for i = 1, 4 do if CAM[CV[i]] then cset(CV[i], CAM[CV[i]]) end end
        end
        local tp = RAP.ref.thirdperson_dist
        if RAP.v("cam.tp") then
            if tp then pcall(tp.override, tp, RAP.v("cam.tp_d")); TPO = true end
            cset("cam_idealdist", RAP.v("cam.tp_d"))
        elseif TPO then pcall(tp.override, tp); TPO = false end
        local a = RAP.v("cam.aspect") or 0
        pcall(function() cvar.r_aspectratio:float(a > 0 and a / 100 or AR0, true) end)
    end
    local PRE = { ["Off"] = 0, ["16:9 (1.78)"] = 178, ["16:10 (1.60)"] = 160, ["4:3 (1.33)"] = 133, ["5:4 (1.25)"] = 125, ["Stretched 1.20"] = 120 }
    for _, k in ipairs({ "cam.vm", "cam.vm_fov", "cam.vm_x", "cam.vm_y", "cam.vm_z", "cam.tp", "cam.tp_d", "cam.aspect" }) do
        local it = RAP.cfg[k]
        if it then pcall(it.set_callback, it, function() RAP.menu.refresh(); apply_cam() end) end
    end
    if RAP.cfg["cam.aspect_pre"] then
        pcall(RAP.cfg["cam.aspect_pre"].set_callback, RAP.cfg["cam.aspect_pre"], function()
            local v = PRE[RAP.v("cam.aspect_pre")]
            if v then RAP.cfg["cam.aspect"]:set(v); apply_cam() end
        end)
    end
    RAP.on("frame", "camera tick", function() if RAP.v("cam.tp") then cset("cam_idealdist", RAP.v("cam.tp_d")) end end, 90)
    RAP.on("load", "camera", apply_cam)
    RAP.on("shutdown", "camera", function()
        for n, v in pairs(CAM) do cset(n, v) end
        if TPO and RAP.ref.thirdperson_dist then pcall(RAP.ref.thirdperson_dist.override, RAP.ref.thirdperson_dist) end
        pcall(function() cvar.r_aspectratio:float(AR0, true) end)
    end)
end
---------------------------------------------------------------- debug panel: почему скрипт принял решение по текущей цели
do
    local D = { t = -1, rows = {} }
    local WARN, GOOD, DIM = color(255, 170, 110), color(150, 230, 150), color(170, 170, 185)
    local SCOL = { UNKNOWN = DIM, PROBING = color(240, 210, 120), CONFIDENT = GOOD, FAILED = color(255, 110, 110), RELEARNING = WARN }
    local function build()
        local rows = {}
        local thr = RAP.W.threat
        local t = thr and RAP.TC[thr:get_index()]
        if not t then rows[1] = { "TARGET", "-" }; return rows end
        local okn, name = pcall(thr.get_name, thr)
        rows[#rows + 1] = { "TARGET", (okn and name or "?") .. (t.id.bot and " (bot)" or "") }
        rows[#rows + 1] = { "AA", string.format("%s  %s  %.0f%%", t.aa.type:upper(), t.aa.sub or "", (t.aa.conf or 0) * 100) }
        if t.aa.changed_at and globals.curtime - t.aa.changed_at < 10 then rows[#rows + 1] = { "AA CHANGE", (t.aa.prev or "?") .. " -> " .. t.aa.type, WARN } end
        local L = t.learn or {}
        rows[#rows + 1] = { "STATE", L.state or "-", SCOL[L.state or ""] or DIM }
        rows[#rows + 1] = { "STRATEGY", L.arm or "-" }
        rows[#rows + 1] = { "CONFIDENCE", L.conf and string.format("est %.0f%%  sure %.0f%%", L.conf * 100, (L.pconf or 0) * 100) or "-" }
        rows[#rows + 1] = { "SAMPLES", L.samples and string.format("%.1f weighted", L.samples) or "0" }
        rows[#rows + 1] = { "WHY", L.why or "-" }
        rows[#rows + 1] = { "NEXT", L.next or "-" }
        local h = t.hist
        rows[#rows + 1] = { "SESSION", string.format("%d shots, %d hits, streak %d", h.shots, h.hits, h.streak) }
        rows[#rows + 1] = { "LAST MISS", h.last_miss or "-", h.last_miss == "correction" and WARN or nil }
        local st = RAP.lag and RAP.lag.thr_status
        if st then rows[#rows + 1] = { "LAG", st } end
        rows[#rows + 1] = { "MOVE", string.format("%s %.0f u/s  dist %s", t.move.state or "?", t.move.speed or 0, t.geo.dist and string.format("%.0f", t.geo.dist) or "?") }
        -- итог арбитра: какие пункты рагебота сейчас изменены и кем
        for _, k in ipairs({ "safe_points", "body_aim", "mp_head", "hitchance", "min_damage", "hitboxes" }) do
            local w = RAP.arb.why[k]
            if w and w.value ~= nil then
                local v = type(w.value) == "table" and table.concat(w.value, ",") or tostring(w.value)
                rows[#rows + 1] = { k, v .. "  <- " .. tostring(w.src), DIM }
            end
        end
        return rows
    end
    RAP.on("frame", "debug panel", function()
        if not RAP.v("vis.debug") or not RAP.wid or not RAP.wid.list_panel then return end
        local now = globals.realtime
        if now - D.t > 0.25 then D.t, D.rows = now, build() end
        RAP.wid.list_panel("debug", "RAP DEBUG", D.rows, 300)
    end, 55)
end
---------------------------------------------------------------- fake lag и animation breakers
do
    local U = RAP.U
    local G = RAP.menu.group("Anti-Aim", "Fake lag & animations", 1)
    G.combo("fl.mode", "Fake lag mode", { "Off (cheat settings)", "Adaptive", "Fluctuate", "Random" },
        { tip = "Adaptive: max in air and while peeking, min standing. Fluctuate: min / max on alternate packets." })
    local fon = function() return RAP.v("fl.mode") ~= "Off (cheat settings)" end
    G.slider("fl.max", "Fake lag max", 2, 16, 14, 1, nil, { dep = fon })
    G.slider("fl.min", "Fake lag min", 1, 8, 2, 1, nil, { dep = fon, adv = true })
    G.multi("ab.list", "Animation breakers (local)", { "Landing pitch", "Static legs in air", "Slide on slow walk", "Move lean" }, nil,
        { tip = "Local animation only: mostly visual." })

    local LIM = RAP.ref.find("Aimbot", "Anti Aim", "Fake Lag", "Limit")
    if not LIM then RAP.ref.missing[#RAP.ref.missing + 1] = "fakelag.limit" end
    local F = { own = false, v = nil, k = 0 }
    RAP.on("tick", "fake lag", function(cmd)
        local mode = RAP.v("fl.mode")
        if not LIM or mode == "Off (cheat settings)" or not RAP.W.alive then
            if F.own then pcall(LIM.override, LIM); F.own, F.v = false, nil end
            return
        end
        if cmd.choked_commands == 0 or not F.v then
            local hi = RAP.v("fl.max") or 14
            local lo = U.min(RAP.v("fl.min") or 2, hi)
            if mode == "Fluctuate" then F.k = F.k + 1; F.v = F.k % 2 == 0 and hi or lo
            elseif mode == "Random" then F.v = U.rand(lo, hi)
            else
                local st, spd = RAP.W.state, RAP.W.vel and RAP.W.vel:length2d() or 0
                if st == "air" or st == "airduck" or (spd > 60 and RAP.W.threat) then F.v = hi
                elseif spd > 5 then F.v = U.round((lo + hi) / 2) else F.v = lo end
            end
        end
        if pcall(LIM.override, LIM, F.v) then F.own = true end
    end, 35)
    RAP.on("shutdown", "fake lag", function() if F.own and LIM then pcall(LIM.override, LIM) end end)
    RAP.on("ind_rows", "fake lag", function(add) if F.own and F.v then add("FL " .. F.v, color(200, 200, 220), 6) end end)

    pcall(function()
        events.post_update_clientside_animation:set(function(pl)
            local sel = RAP.v("ab.list")
            if type(sel) ~= "table" or #sel == 0 then return end
            local me = entity.get_local_player()
            if not me or pl ~= me or not me:is_alive() then return end
            U.safe("anim breakers", function()
                local st = me:get_anim_state()
                if not st then return end
                if U.has(sel, "Landing pitch") and st.landing then me.m_flPoseParameter[12] = 0.5 end
                if U.has(sel, "Static legs in air") and not st.on_ground then me.m_flPoseParameter[6] = 1 end
                if U.has(sel, "Slide on slow walk") and RAP.ref.on(RAP.ref.slow_walk) then me.m_flPoseParameter[9] = 0 end
            end)
        end)
    end)
    RAP.on("tick", "move lean", function(cmd)
        local sel = RAP.v("ab.list")
        if type(sel) == "table" and U.has(sel, "Move lean") then pcall(U.setf, cmd, "animate_move_lean", true) end
    end, 95)
end
---------------------------------------------------------------- lag records: состояние лагкомпа врагов
-- По net_update: simulation time пошло назад -> no_entry (defensive / сдвиг tickbase), прыжок позиции > 64 u между
-- записями -> lc_break (бэктрек невозможен), иначе ok + choke (тики между обновлениями).
do
    local U = RAP.U
    local G = RAP.menu.group("Rage", "Lag records", 1)
    G.switch("lag.on", "Track enemy lag records", true)
    G.switch("lag.hc", "Lag-aware hitchance", false, { tip = "no_entry: +N%, LC break: +N/2%, long choke with backtrack ok: -M%." })
    G.slider("lag.ne", "no_entry: hitchance +", 0, 30, 0, 1, "%", { adv = true })
    G.slider("lag.ok", "Long choke: hitchance -", 0, 15, 4, 1, "%", { adv = true })
    local L = { d = {}, base_seen = {} }
    RAP.lag = L
    local function st_of(pl)
        local ok, st = pcall(function() return pl:get_simulation_time().current end)
        if ok and type(st) == "number" then return st end
        return pl.m_flSimulationTime
    end
    events.net_update_end:set(function()
        if not RAP.v("lag.on") then return end
        U.safe("lag records", function()
            local now, ti = globals.curtime, globals.tickinterval
            entity.get_players(true, false, function(pl)
                if not pl:is_alive() or pl:is_dormant() then return end
                local idx = pl:get_index()
                local e = L.d[idx]
                if not e then e = { ne_until = 0, brk_until = 0, choke = 0 }; L.d[idx] = e end
                local st, org = st_of(pl), pl:get_origin()
                if not st or not org then return end
                -- simulation time ушел назад больше чем на 1 с: это не defensive, а новая карта / другой игрок - запись заново
                if e.st and st < e.st - 1 then e.st, e.org, e.choke, e.ne_until, e.brk_until = nil, nil, 0, 0, 0 end
                if e.st then
                    if st < e.st - ti * 0.5 then e.ne_until = now + 0.25
                    elseif st > e.st + ti * 0.5 then
                        e.choke = U.max(0, U.round((st - e.st) / ti) - 1)
                        if e.org and (org - e.org):lengthsqr() > 4096 then e.brk_until = now + 0.5 end
                        e.org = org
                    end
                else e.org = org end
                if not e.st or st > e.st then e.st = st end
            end)
        end)
    end)
    RAP.on("level", "lag records", function() L.d, L.base_seen, L.thr_status = {}, {}, nil end)
    function L.status(idx)
        local e = L.d[idx]
        if not e then return "unknown", 0 end
        local now = globals.curtime
        if now < e.ne_until then return "no_entry", e.choke end
        if now < e.brk_until then return "lc_break", e.choke end
        return "ok", e.choke
    end
    RAP.on("tick", "lag hc", function()
        if not RAP.v("lag.on") or not RAP.W.threat then L.thr_status = nil; return end
        local st, ch = L.status(RAP.W.threat:get_index())
        L.thr_status, L.thr_choke = st, ch
        if not RAP.v("lag.hc") then return end
        local add = 0
        if st == "no_entry" then add = RAP.v("lag.ne") or 6
        elseif st == "lc_break" then add = U.floor((RAP.v("lag.ne") or 6) / 2)
        elseif st == "ok" and ch >= 12 then add = -(RAP.v("lag.ok") or 4) end
        -- база: твое значение, пока арбитр им не владеет (иначе - последнее увиденное). Раньше при владении голос
        -- пропускался -> арбитр снимал override -> на следующем тике голос снова был: hitchance мигал каждый тик.
        local wkey = RAP.W.wsub or "Global"
        local ok, cur = pcall(U.hc_cur)
        if ok and type(cur) == "number" and not RAP.arb.owned.hitchance then L.base_seen[wkey] = cur end
        if add ~= 0 then
            -- поверх голоса с меньшим приоритетом (adaptive / оружие), а не вместо него
            local v = RAP.arb.votes.hitchance
            local base = (v and type(v.value) == "number") and v.value or L.base_seen[wkey]
            if base then RAP.vote("hitchance", U.clamp(base + add, 0, 100), 15, "lag " .. st) end
        end
    end, 41)
    RAP.on("ind_rows", "lag", function(add)
        if RAP.v("lag.on") and L.thr_status and L.thr_status ~= "unknown" then
            add(string.format("LAG %s (choke %d)", L.thr_status, L.thr_choke or 0),
                L.thr_status == "ok" and color(160, 220, 160) or color(255, 170, 110), L.thr_status == "ok" and 6 or 3)
        end
    end)
end
---------------------------------------------------------------- exploits: break LC, magic key, noscope, jump scout, ideal tick, ...
do
    local U, R = RAP.U, RAP.ref
    local SNIPER = { [9] = true, [40] = true, [11] = true, [38] = true }
    local G1 = RAP.menu.group("Exploits", "Exploits", 1)
    G1.switch("ex.brk", "Force break LC", false, { tip = "Double Tap lag option 'Always On' / Hide Shots 'Break LC' while a trigger is active." })
    G1.multi("ex.brk_trig", "Break LC triggers", { "Flashed", "Weapon switch", "Flinch", "Landing", "Jump", "Defensive", "Reloading" },
        { "Flashed", "Weapon switch", "Flinch", "Landing", "Jump" }, { dep = function() return RAP.v("ex.brk") end })
    G1.switch("ex.brk_rev", "Break LC: not with revolver", true, { dep = function() return RAP.v("ex.brk") end, adv = true })
    G1.switch("ex.brk_nade", "Break LC: not with grenades", true, { dep = function() return RAP.v("ex.brk") end, adv = true })
    G1.switch("ex.autos", "Auto OS on peek (snipers: hide shots instead of DT)", false)
    G1.switch("ex.mk", "Magic key (head only, no safe points)", false)
    G1.bind("ex.mk_key", "Magic key", { dep = function() return RAP.v("ex.mk") end })
    G1.switch("ex.nos", "Noscope mode (snipers, close range)", false)
    G1.slider("ex.nos_hc", "Noscope hitchance", 0, 100, 15, 1, "%", { dep = function() return RAP.v("ex.nos") end })
    G1.slider("ex.nos_d", "Noscope distance", 3, 60, 20, 1, "m", { dep = function() return RAP.v("ex.nos") end })
    G1.switch("ex.js", "Jump scout (standing still in air, SSG-08)", false)
    G1.switch("ex.leg", "Leg breaker", false)
    G1.switch("ex.move", "Movement helpers (no fall damage / fast ladder)", false)
    G1.switch("ex.fd", "Unlock fake duck speed", false)
    G1.switch("ex.pred", "Predict (interpolation)", false)
    G1.combo("ex.pred_s", "Predict strength", { "Soft", "Medium", "Extreme", "Ultimate" }, { dep = function() return RAP.v("ex.pred") end })
    G1.switch("ex.ext", "Extended angles", false)
    G1.slider("ex.ext_pitch", "Extended pitch", -180, 180, 0, 1, nil, { dep = function() return RAP.v("ex.ext") end })
    G1.slider("ex.ext_roll", "Extended roll", 0, 90, 0, 1, nil, { dep = function() return RAP.v("ex.ext") end })

    local G2 = RAP.menu.group("Exploits", "Ideal tick", 2)
    G2.switch("it.on", "Ideal tick", false, { tip = "While the key is active: forced double tap, freestanding on peek, optional jump scout and peek assist." })
    local ion = function() return RAP.v("it.on") end
    G2.bind("it.key", "Ideal tick key", { dep = ion })
    G2.switch("it.dt", "Ideal tick: force double tap", true, { dep = ion })
    G2.switch("it.fs", "Ideal tick: freestanding on peek", true, { dep = ion })
    G2.switch("it.js", "Ideal tick: jump scout", false, { dep = ion })
    G2.switch("it.ap", "Ideal tick: peek assist", false, { dep = ion })
    G2.switch("it.recharge", "Auto recharge exploit when no enemy", true)
    G2.switch("it.at", "Air teleport", false)
    G2.slider("it.at_int", "Air teleport interval (ticks)", 4, 40, 12, 1, nil, { dep = function() return RAP.v("it.at") end })
    G2.switch("it.at_vis", "Air teleport: only if enemy hittable after jump", true, { dep = function() return RAP.v("it.at") end })
    G2.switch("misc.dormant", "Dormant aimbot (cheat built-in)", false)

    local S = { brk_until = 0, flash_until = 0, flinch_until = 0, prev_ground = true, fall = 0, last_wpn = nil, os_until = 0 }
    pcall(function()
        events.player_blind:set(function(e)
            U.safe("flash", function()
                local me = entity.get_local_player()
                if me and entity.get(e.userid, true) == me then S.flash_until = globals.curtime + U.max(0, (e.blind_duration or 1) - 0.5) end
            end)
        end)
    end)
    RAP.on("enemy_shot", "flinch", function(kind) if kind == "hit" then S.flinch_until = globals.curtime + 0.3 end end)
    -- новая карта: curtime начинается заново, старые "до момента X" держали бы Auto OS (DT выключен) и Break LC
    -- включенными, пока новый curtime не догонит старый (до десятков минут)
    RAP.on("level", "exploits", function()
        S.brk_until, S.flash_until, S.flinch_until, S.os_until, S.last_wpn, S.prev_ground, S.fall = 0, 0, 0, 0, nil, true, 0
    end)
    -- "до момента t" активно, только если t впереди не дальше max_d секунд (защита от сброса curtime без level_init)
    local function until_ok(now, t, max_d) return now < t and t - now <= max_d end

    local PRED = { Soft = { 1, 3, 0.031 }, Medium = { 1, 2, 0.026 }, Extreme = { 1, 1, 0.015625 }, Ultimate = { 0, 1, 0.015625 } }
    local PRED_DEF, pred_on, pred_cur = { 1, 2, 0.015625 }, false, nil
    -- твои значения до скрипта: возвращаются при выключении / выгрузке (раньше - жестко заданные 1 / 2 / 0.015625)
    pcall(function()
        local a, b, c = cvar.cl_interpolate:int(), cvar.cl_interp_ratio:int(), cvar.cl_interp:float()
        if type(a) == "number" and type(b) == "number" and type(c) == "number" then PRED_DEF = { a, b, c } end
    end)
    local function pred_apply(t)
        if pred_cur == t then return end          -- cvar пишется только при смене, а не каждый тик
        pred_cur = t
        pcall(function() cvar.cl_interpolate:int(t[1]) end)
        pcall(function() cvar.cl_interp_ratio:int(t[2]) end)
        pcall(function() cvar.cl_interp:float(t[3]) end)
    end

    local function on_peek(me, thr)
        if not thr or thr:is_dormant() then return false end
        local v = me.m_vecVelocity
        if not v or v:length2d() < 50 then return false end
        return RAP.W.can_hit_me ~= nil
    end
    local function hittable_after_jump(me)
        local ok, res = pcall(function()
            local sim = me:simulate_movement()
            sim:think(6)
            local from = vector(sim.origin.x, sim.origin.y, RAP.W.eye.z)
            for _, en in ipairs(RAP.W.enemies) do
                if not en.dormant then
                    local dmg, tr = utils.trace_bullet(me, from, en.ent:get_hitbox_position(3))
                    if dmg and dmg > 10 and tr and tr.entity == en.ent then return true end
                end
            end
            return false
        end)
        return ok and res
    end

    -- no fall damage / быстрая лестница (функция модуля: раньше замыкание создавалось каждый тик)
    -- trace_line: skip = me явно (в документации не указан пропуск по умолчанию для trace_line)
    local function move_helpers(me, cmd, W)
        local org = me:get_origin()
        if W.vel and W.vel.z <= -500 then
            if utils.trace_line(org, org - vector(0, 0, 15), me).fraction ~= 1 then cmd.in_duck = false
            elseif utils.trace_line(org, org - vector(0, 0, 50), me).fraction ~= 1 then cmd.in_duck = true end
        end
        if me.m_MoveType == 9 and cmd.forwardmove ~= 0 then
            local fwd = cmd.forwardmove > 0
            if not fwd or cmd.view_angles.x < 45 then
                local va = cmd.view_angles
                va.x = 89
                cmd.in_moveright, cmd.in_moveleft = fwd, not fwd
                cmd.in_forward, cmd.in_back = not fwd, fwd
                local sm = fwd and cmd.sidemove or -cmd.sidemove
                va.y = va.y + (sm == 0 and 90 or (sm < 0 and 150 or 30))
                cmd.view_angles = va
            end
        end
    end

    RAP.on("tick", "exploits", function(cmd)
        local W = RAP.W
        if not W.alive then return end
        local me, now, widx = W.me, globals.curtime, W.widx
        local on_ground = bit.band(me.m_fFlags or 1, 1) == 1
        local charged = (W.charge or 0) >= 1
        -- ideal tick
        local it_on = RAP.v("it.on") and RAP.v("it.key")
        S.it_on = it_on
        RAP.own("it.ap", R.peek_assist, (it_on and RAP.v("it.ap")) and true or nil)
        -- DT держим включенным все время, пока активен ideal tick: раньше он требовал charged и threat,
        -- после первого выстрела заряд падал -> DT снимался -> перезарядки не было, и ideal tick "умирал"
        -- (freestanding для ideal tick теперь в AA engine)
        local want_dt, want_hs
        if it_on and RAP.v("it.dt") then want_dt = true end
        if want_dt == nil and RAP.v("ex.autos") and widx and SNIPER[widx] and charged and W.threat and on_peek(me, W.threat) then S.os_until = now + 0.2 end
        if want_dt == nil and until_ok(now, S.os_until, 0.2) then want_hs, want_dt = true, false end
        RAP.own("ex.dt", R.dt, want_dt)
        RAP.own("ex.hs", R.hs, want_hs)
        -- auto recharge
        if RAP.v("it.recharge") and R.dt and not charged and not W.threat and R.on(R.dt) then pcall(rage.exploit.force_charge, rage.exploit) end
        -- air teleport
        if RAP.v("it.at") and charged and (not on_ground) and globals.tickcount % U.max(1, RAP.v("it.at_int") or 12) == 0 then
            if not RAP.v("it.at_vis") or hittable_after_jump(me) then
                pcall(U.setf, cmd, "force_defensive", true)
                pcall(rage.exploit.force_teleport, rage.exploit)
            end
        end
        -- break LC
        local trig = RAP.v("ex.brk_trig") or {}
        if on_ground and not S.prev_ground and S.fall < -350 and U.has(trig, "Landing") then S.brk_until = U.max(S.brk_until, now + 0.25) end
        if S.prev_ground and not on_ground and U.has(trig, "Jump") then S.brk_until = U.max(S.brk_until, now + 0.2) end
        S.fall, S.prev_ground = W.vel and W.vel.z or 0, on_ground
        if widx ~= S.last_wpn then
            if S.last_wpn ~= nil and U.has(trig, "Weapon switch") then S.brk_until = U.max(S.brk_until, now + 0.2) end
            S.last_wpn = widx
        end
        local brk = false
        if RAP.v("ex.brk") then
            local excl = (RAP.v("ex.brk_rev") and widx == 64) or (RAP.v("ex.brk_nade") and widx and widx >= 43 and widx <= 48)
            local okr, rl = pcall(U.getf, W.weapon, "m_bInReload")
            local reload = okr and rl and true or false
            local def_t = RAP.aa.def
            brk = not excl and (until_ok(now, S.brk_until, 0.25) or (until_ok(now, S.flinch_until, 0.3) and U.has(trig, "Flinch"))
                or (until_ok(now, S.flash_until, 10) and U.has(trig, "Flashed")) or (def_t and now >= def_t and now - def_t < 0.12 and U.has(trig, "Defensive"))
                or (reload and U.has(trig, "Reloading")))
        end
        RAP.own("ex.dtlag", R.dt_lag, brk and "Always On" or nil)
        RAP.own("ex.hsopt", R.hs_opt, brk and "Break LC" or nil)
        S.brk = brk
        -- magic key: только голова, без safe point (голос сильнее resolver)
        if RAP.v("ex.mk") and RAP.v("ex.mk_key") then
            RAP.vote("hitboxes", { "Head" }, 80, "magic key"); RAP.vote("multipoint", { "Head" }, 80, "magic key")
            if R.OPT.ba_default then RAP.vote("body_aim", R.OPT.ba_default, 80, "magic key") end
            if R.OPT.sp_default then RAP.vote("safe_points", R.OPT.sp_default, 80, "magic key") end; RAP.vote("ensure_safety", {}, 80, "magic key")
            S.mk = true
        else S.mk = false end
        -- noscope
        local nos = nil
        if RAP.v("ex.nos") and widx and SNIPER[widx] and not me.m_bIsScoped and W.threat and not W.threat:is_dormant() then
            local ok, d = pcall(function() return W.threat:get_origin():dist(me:get_origin()) end)
            if ok and d <= (RAP.v("ex.nos_d") or 20) * 39.37 then nos = RAP.v("ex.nos_hc") end
        end
        if nos then RAP.vote("hitchance", nos, 75, "noscope") end
        if nos then RAP.own("ex.autoscope", R.autoscope, false) else RAP.own("ex.autoscope", R.autoscope, nil) end
        S.nos = nos ~= nil
        -- jump scout
        local stillair = W.vel and W.vel:length2d() <= 1.2
        local it_js = it_on and RAP.v("it.js") and widx == 40 and not on_ground
        local pk_js = RAP.v("ex.js") and widx == 40 and not on_ground and stillair
        if it_js or pk_js then
            if not it_js then RAP.own("ex.airstrafe", R.airstrafe, false) end
            RAP.own("ex.jsstop", R.js_stop, true)
            RAP.own("ex.jsopts", R.js_opts, it_js and { "Early", "In Air" } or { "In Air" })
            S.js = true
        else
            RAP.own("ex.airstrafe", R.airstrafe, nil); RAP.own("ex.jsstop", R.js_stop, nil); RAP.own("ex.jsopts", R.js_opts, nil)
            S.js = false
        end
        -- leg breaker
        if RAP.v("ex.leg") then
            if cmd.choked_commands == 0 then RAP.own("ex.leg", R.leg, U.rand(0, 1) == 1 and "Walking" or "Sliding") end
        else RAP.own("ex.leg", R.leg, nil) end
        -- extended angles
        if RAP.v("ex.ext") then
            RAP.own("ex.ext", R.ext, true); RAP.own("ex.extp", R.ext_pitch, RAP.v("ex.ext_pitch")); RAP.own("ex.extr", R.ext_roll, RAP.v("ex.ext_roll"))
        else RAP.own("ex.ext", R.ext, nil); RAP.own("ex.extp", R.ext_pitch, nil); RAP.own("ex.extr", R.ext_roll, nil) end
        -- built-in dormant
        if RAP.v("dor.on") then RAP.own("misc.dormant", R.dormant, false)
        elseif RAP.v("misc.dormant") then RAP.own("misc.dormant", R.dormant, true) else RAP.own("misc.dormant", R.dormant, nil) end
        -- predict
        if RAP.v("ex.pred") then pred_apply(PRED[RAP.v("ex.pred_s")] or PRED.Soft); pred_on = true
        elseif pred_on then pred_apply(PRED_DEF); pred_on = false end
        -- fake duck: скорость движения не режется до шага
        if RAP.v("ex.fd") and R.on(R.fake_duck) then
            local spd = U.sqrt(cmd.forwardmove * cmd.forwardmove + cmd.sidemove * cmd.sidemove)
            if spd > 5 and spd < 100 then cmd.forwardmove, cmd.sidemove = cmd.forwardmove / spd * 110, cmd.sidemove / spd * 110 end
        end
        -- movement helpers
        if RAP.v("ex.move") then
            U.safe("move helpers", move_helpers, me, cmd, W)
        end
    end, 45)
    RAP.on("shutdown", "exploits", function() if pred_on then pred_apply(PRED_DEF) end end)
    RAP.exploits = S
    RAP.on("ind_rows", "exploits", function(add)
        if S.it_on then
            local ch = RAP.W.charge or 0
            add(string.format("IDEAL TICK %d%%", U.floor(U.clamp(ch, 0, 1) * 100)), ch >= 1 and color(255, 230, 140) or color(255, 150, 110), 1)
        end
        if S.brk then add("BREAK LC", color(160, 255, 200), 2) end
        if S.mk then add("MAGIC KEY", color(255, 120, 200), 1) end
        if S.nos then add("NOSCOPE", color(255, 210, 150), 3) end
        if S.js then add("JUMP SCOUT", color(200, 220, 255), 3) end
        if until_ok(globals.curtime, S.os_until, 0.2) then add("AUTO OS", color(200, 200, 255), 3) end
    end)
end
---------------------------------------------------------------- dormant aimbot (скрипт): стрельба по врагу за стеной по ESP-данным
-- Цель - dormant-игрок со свежей позицией (ESP). Урон - trace_bullet в точку тела, шанс попадания - выборка разброса
-- оружия (spread + inaccuracy, N лучей). При шансе >= порога - выстрел (снайперы сначала в прицел).
do
    local U = RAP.U
    local G = RAP.menu.group("Exploits", "Dormant aimbot", 2)
    G.switch("dor.on", "Dormant aimbot (script)", false)
    local d = function() return RAP.v("dor.on") end
    G.slider("dor.dmg", "Dormant: min damage", 1, 130, 20, 1, nil, { dep = d })
    G.slider("dor.hc", "Dormant: hitchance", 0, 100, 60, 1, "%", { dep = d })
    G.slider("dor.time", "Dormant: record timeout", 5, 40, 20, 0.1, "s", { dep = d, adv = true })
    G.switch("dor.stop", "Dormant: stop when target found", true, { dep = d })
    G.switch("dor.scope", "Dormant: auto scope", true, { dep = d })
    G.slider("dor.n", "Dormant: spread samples", 64, 256, 160, 1, nil, { dep = d, adv = true })
    G.combo("dor.sel", "Dormant: target", { "Best damage", "Best hit chance", "Closest to crosshair", "Lowest health" }, { dep = d })
    local D = { active = false, seen = {}, r2 = {} }
    RAP.dormant = D
    -- точки по высоте над origin (грудь / живот / таз): v52 - детерминированный мультипоинт вместо random(32, 50),
    -- который перебрасывался на каждом скане - точка прицела и оценка шанса "прыгали"
    local PTS_STAND, PTS_DUCK = { 50, 40, 32 }, { 40, 32, 24 }
    local rnd = math.random or function(a, b) return utils.random_float(a or 0, b or 1) end
    -- выборка разброса один раз на скан: квадраты отклонений (тангенсы), отсортированы - шанс попадания для любой
    -- дистанции = доля выборки внутри круга (бинарный поиск). Раньше 2n вызовов random_float на каждую цель.
    local function sample_spread(spread, inacc, n)
        local r2 = D.r2
        for i = 1, n do
            local a1, r1 = rnd() * 6.2831853, rnd() * spread
            local a2, r2_ = rnd() * 6.2831853, rnd() * inacc
            local ox, oy = math.cos(a1) * r1 + math.cos(a2) * r2_, math.sin(a1) * r1 + math.sin(a2) * r2_
            r2[i] = ox * ox + oy * oy
        end
        for i = #r2, n + 1, -1 do r2[i] = nil end
        table.sort(r2)
    end
    local function hc_at(dist, n)
        local lim = (RAP.CFG.dormant.hit_radius / U.max(dist, 1)) ^ 2
        local r2, lo, hi = D.r2, 0, n
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            if r2[mid] <= lim then lo = mid else hi = mid - 1 end
        end
        return lo / n * 100
    end
    -- свежесть dormant-записи: собственная метка времени последнего изменения позиции (раньше - формула от
    -- get_bbox().alpha, ограниченная 4 с: слайдер "record timeout" выше 4.0 ничего не менял).
    -- network state 1 = "чит знает позицию точно" -> запись свежая; 5 = данных нет / слишком старые -> пропуск.
    local function age_of(en, ns, org, now)
        local s = D.seen[en.idx]
        if not s or s.pid ~= en.pid then s = { pid = en.pid }; D.seen[en.idx] = s end
        if not en.dormant or ns == 1 or not s.x or U.abs(s.x - org.x) + U.abs(s.y - org.y) + U.abs(s.z - org.z) > 1 then
            s.x, s.y, s.z, s.t = org.x, org.y, org.z, now
        end
        return now - s.t
    end
    RAP.on("level", "dormant aimbot", function() D.seen, D.best, D.found, D.scan_t = {}, nil, false, nil end)
    RAP.on("tick", "dormant aimbot", function(cmd)
        D.active = false
        if not RAP.v("dor.on") or not RAP.W.alive then return end
        local W = RAP.W
        local me, wpn = W.me, W.weapon
        if not wpn or W.wgroup == "other" and not W.wsub or me.m_MoveType ~= 2 then return end
        local okg, gr = pcall(entity.get_game_rules)
        if okg and gr and gr.m_bFreezePeriod then return end
        local now = globals.curtime
        local nxt = wpn.m_flNextPrimaryAttack or 0
        if now + 0.3 < nxt then return end
        local spread, inacc = wpn:get_spread(), wpn:get_inaccuracy()
        if not spread or not inacc or spread == 0 then return end
        local eye = W.eye
        local timeout = (RAP.v("dor.time") or 20) / 10
        local need_hc, n, sel = RAP.v("dor.hc") or 60, RAP.v("dor.n") or 160, RAP.v("dor.sel")
        -- поиск (trace_bullet по точкам + шанс попадания на каждого dormant-врага) - раз в 3 тика, между ними - кэш
        local tc = globals.tickcount
        local best, found = D.best, D.found
        if best then
            local oka, alive = pcall(best.ent.is_alive, best.ent)
            local okd, dorm = pcall(best.ent.is_dormant, best.ent)
            if not (oka and alive and okd and dorm) then best = nil end
        end
        local rescan = not D.scan_t or tc - D.scan_t >= 3 or tc < D.scan_t
        if rescan then
            D.scan_t, best, found = tc, nil, false
            local rt = globals.realtime
            local sampled = false
            for _, en in ipairs(W.enemies) do
                local pl = en.ent
                local org = pl:get_origin()
                local okn, ns = pcall(pl.get_network_state, pl)
                local age = org and age_of(en, okn and ns or nil, org, rt) or 1e9
                if en.dormant and org and okn and ns ~= 0 and ns ~= 5 and age < timeout then
                    local hp = pl.m_iHealth or 100
                    local need_dmg = U.min(RAP.v("dor.dmg") or 20, hp)
                    local duck = (pl.m_flDuckAmount or 0) > 0.5
                    for _, dz in ipairs(duck and PTS_DUCK or PTS_STAND) do
                        local pos = vector(org.x, org.y, org.z + dz)
                        -- skip-колбэк: true = "не пропускать" (docs: ShouldHitEntity) - трасса попадает только в эту цель
                        local dmg = utils.trace_bullet(me, eye, pos, function(ent) return ent == pl end)
                        if dmg and dmg >= need_dmg then
                            if not sampled then sample_spread(spread, inacc, n); sampled = true end
                            local hc = hc_at(eye:dist(pos), n)
                            found = true
                            if hc >= need_hc then
                                local score
                                if sel == "Best hit chance" then score = hc elseif sel == "Lowest health" then score = -hp * 1000 + dmg * hc / 100
                                elseif sel == "Closest to crosshair" then
                                    local an, va = eye:to(pos):angles(), cmd.view_angles
                                    score = -(U.abs(U.norm(an.x - va.x)) + U.abs(U.norm(an.y - va.y)))
                                else score = dmg * hc / 100 end          -- ожидаемый урон: урон x шанс попадания
                                if not best or score > best.score then best = { pos = pos, score = score, ent = pl, dmg = dmg, hc = hc } end
                            end
                        end
                    end
                end
            end
        end
        D.best, D.found = best, found
        D.active = found
        if found and RAP.v("dor.stop") then cmd.block_movement = 1 end      -- docs: 1 = замедление до мин. скорости оружия
        if not best or now < (me.m_flNextAttack or 0) then return end
        local info = wpn:get_weapon_info()
        if info and info.weapon_type == 5 and not me.m_bIsScoped and RAP.v("dor.scope") then
            if now > nxt then cmd.in_attack2 = true end
            return
        end
        if now < nxt then return end
        cmd.in_attack = true
        local ang = eye:to(best.pos):angles()
        local cv, okr, rs = cvar.weapon_recoil_scale, false, nil
        if cv then okr, rs = pcall(cv.float, cv) end
        local punch = me.m_aimPunchAngle
        if okr and type(rs) == "number" and punch then ang = ang - punch * rs end
        cmd.view_angles = ang
    end, 50)
    RAP.on("ind_rows", "dormant", function(add) if D.active then add("DORMANT", color(200, 170, 255), 3) end end)
end
---------------------------------------------------------------- AI Peek: выход из-за угла на точку, где можно нанести урон, выстрел, возврат
-- Перебор направлений через simulate_movement (читает forwardmove / view_angles команды - они подменяются на время).
-- Цели: видимые + спрятавшиеся (только позиция, где ты сам видел врага недавно, только впереди). Нужный урон =
-- max(слайдер, min damage рагебота). Обучение: исходы пиков меняют ожидание выстрела, требование DT, доверие к
-- старым позициям и блокируют направление, где тебя убили.
do
    local U = RAP.U
    local G = RAP.menu.group("Exploits", "AI Peek", 1)
    G.switch("peek.on", "AI Peek", false)
    local d = function() return RAP.v("peek.on") end
    G.bind("peek.key", "AI Peek key", { dep = d })
    G.slider("peek.dmg", "AI Peek: min damage", 1, 130, 20, 1, nil, { dep = d })
    G.slider("peek.time", "AI Peek: simulate up to", 100, 700, 400, 1, "ms", { dep = d })
    G.slider("peek.dirs", "AI Peek: directions", 4, 16, 8, 1, nil, { dep = d, adv = true })
    G.combo("peek.pri", "AI Peek: priority", { "Fastest", "Highest damage" }, { dep = d, adv = true })
    G.slider("peek.hold", "AI Peek: wait for shot", 150, 1000, 450, 1, "ms", { dep = d, adv = true })
    G.switch("peek.scope", "AI Peek: snipers only when scoped", false, { dep = d, adv = true })
    G.switch("peek.ai", "AI Peek: learn from outcomes", true, { dep = d })

    local PK = { st = 0, last_scan = 0, reason = "off" }
    local ST = { n = 0, shot = 0, kill = 0, died = 0, empty_dorm = 0, empty_vis = 0, hist = {}, dhist = {}, adj = 0, need_dt = false,
        danger = {}, dorm_age = 6, dorm_off = 0 }
    local SEEN = {}
    RAP.peek = { PK = PK, ST = ST }
    local function setf(cmd, k, v) pcall(U.setf, cmd, k, v) end
    local function getf(cmd, k) local ok, v = pcall(U.getf, cmd, k); return ok and v or nil end

    local function push(kind)
        ST.n = ST.n + 1
        ST[kind] = (ST[kind] or 0) + 1
        ST.hist[#ST.hist + 1] = kind
        if #ST.hist > 12 then table.remove(ST.hist, 1) end
        local dd, ev, n = 0, 0, #ST.hist
        for _, k in ipairs(ST.hist) do if k == "died" then dd = dd + 1 elseif k == "empty_vis" then ev = ev + 1 end end
        if RAP.v("peek.ai") and n >= 4 then
            ST.need_dt = dd / n >= 0.3
            if dd / n >= 0.3 then ST.adj = U.max(-200, ST.adj - 50)
            elseif ev / n >= 0.4 then ST.adj = U.min(300, ST.adj + 50)
            elseif ST.adj ~= 0 then ST.adj = ST.adj - (ST.adj > 0 and 25 or -25) end
        else ST.need_dt, ST.adj = false, 0 end
        if PK.cand and PK.cand.dormant then
            ST.dhist[#ST.dhist + 1] = kind == "empty_dorm" and 1 or 0
            if #ST.dhist > 6 then table.remove(ST.dhist, 1) end
            local bad = 0
            for _, v in ipairs(ST.dhist) do bad = bad + v end
            if RAP.v("peek.ai") and #ST.dhist >= 4 then
                if bad >= 4 then ST.dorm_age = U.max(1.5, ST.dorm_age - 1) elseif bad <= 1 then ST.dorm_age = U.min(6, ST.dorm_age + 0.5) end
                if #ST.dhist >= 6 and bad >= 6 then ST.dorm_off, ST.dhist = globals.curtime + 45, {} end
            end
        end
    end
    local function finish(kind)
        if PK.cand and not PK.logged then
            PK.logged = true
            push(kind)
            if kind == "died" then ST.danger[#ST.danger + 1] = { idx = PK.cand.tidx, yaw = PK.cand.yaw, t = globals.curtime } end
            if #ST.danger > 16 then table.remove(ST.danger, 1) end
        end
    end
    local function reset(reason) PK.st, PK.cand, PK.arrived, PK.shot_t, PK.logged, PK.seen = 0, nil, nil, nil, nil, nil; if reason then PK.reason = reason end end
    -- новая карта: curtime начинается заново - позиции врагов, опасные направления и пауза hidden-пиков устарели
    RAP.on("level", "ai peek", function()
        for k in pairs(SEEN) do SEEN[k] = nil end
        ST.danger, ST.dorm_off, PK.last_scan = {}, 0, 0
        reset("off")
    end)
    events.player_death:set(function(e)
        U.safe("peek death", function()
            if PK.st == 0 or not PK.cand then return end
            local me, vic = entity.get_local_player(), entity.get(e.userid, true)
            if vic == me then finish("died") elseif vic and vic:get_index() == PK.cand.tidx then finish("kill") end
        end)
    end)
    local function dangerous(idx, yaw)
        for _, x in ipairs(ST.danger) do if x.idx == idx and globals.curtime - x.t < 15 and U.abs(U.norm(x.yaw - yaw)) < 35 then return true end end
        return false
    end
    local function need_dmg(t)
        local need = RAP.v("peek.dmg") or 20
        local ok, md = pcall(function() return RAP.ref.rage.min_damage.get() end)
        if ok and type(md) == "number" and md > 0 then if md > 100 then md = t.hp + (md - 100) end; need = U.max(need, md) end
        return U.min(need, t.hp)
    end
    local function points(t)
        local pts = {}
        if not t.dormant then
            for _, id in ipairs({ 0, 5, 3 }) do local ok, p = pcall(t.ent.get_hitbox_position, t.ent, id); if ok and p then pts[#pts + 1] = p end end
        end
        if #pts == 0 then for _, dz in ipairs(t.duck > 0.5 and { 46, 36, 28 } or { 62, 48, 38 }) do pts[#pts + 1] = vector(t.org.x, t.org.y, t.org.z + dz) end end
        return pts
    end
    local function dmg_at(me, from, p, t)
        local ok, dmg, tr = pcall(utils.trace_bullet, me, from, p)
        if not ok or not dmg then return 0 end
        if t.dormant or (tr and tr.entity == t.ent) then return dmg end
        return 0
    end
    local function targets()
        local now, eye = globals.curtime, RAP.W.eye
        local okv, va = pcall(render.camera_angles)
        local fy = okv and va and va.y or nil
        local list = {}
        for _, en in ipairs(RAP.W.enemies) do
            local org
            if not en.dormant then org = en.ent:get_origin()
            elseif now >= ST.dorm_off and SEEN[en.idx] and now >= SEEN[en.idx].t and now - SEEN[en.idx].t < ST.dorm_age then org = SEEN[en.idx].org end
            if org then
                local fov = fy and U.abs(U.norm(eye:to(org):angles().y - fy)) or 0
                if not en.dormant or (fov <= 70 and eye:dist(org) <= 2500) then
                    list[#list + 1] = { ent = en.ent, idx = en.idx, org = org, dormant = en.dormant, hp = en.ent.m_iHealth or 100,
                        duck = SEEN[en.idx] and SEEN[en.idx].duck or 0, fov = fov }
                end
            end
        end
        local tidx = RAP.W.threat and RAP.W.threat:get_index() or -1
        table.sort(list, function(a, b)
            if (a.idx == tidx) ~= (b.idx == tidx) then return a.idx == tidx end
            if a.dormant ~= b.dormant then return not a.dormant end
            return a.fov < b.fov
        end)
        return list
    end
    -- v52: скан с бюджетом времени на тик (CFG.peek.scan_ms). Направления перебираются по порядку; если бюджет
    -- кончился, состояние сохраняется (SCN[group]) и скан продолжается со следующего направления на следующем тике.
    -- Раньше все направления x тики симуляции x trace_bullet считались за один тик - просадка при зажатой клавише.
    -- Продолжение действительно, пока главная цель та же, ты сместился < 8 юнитов и прошло < 0.3 с.
    local SCN = {}
    local SAVED_KEYS = { "forwardmove", "sidemove", "buttons", "in_duck", "in_jump", "in_speed" }
    local function scan(cmd, me, tl, group)
        local org, eye = me:get_origin(), RAP.W.eye
        local vofs = eye.z - org.z
        local now = globals.curtime
        local n = RAP.v("peek.dirs") or 8
        local sc = SCN[group]
        if sc and (sc.tidx ~= tl[1].idx or sc.n ~= n or now - sc.t0 > 0.3 or now < sc.t0 or org:dist2d(sc.org) >= 8) then sc = nil end
        if not sc then
            for _, t in ipairs(tl) do
                if not t.dormant then for _, p in ipairs(points(t)) do if dmg_at(me, eye, p, t) >= need_dmg(t) then SCN[group] = nil; return nil, "already hittable from here" end end end
            end
            local use = { tl[1], tl[2] }
            local pts, needs = {}, {}
            for k, t in ipairs(use) do pts[k], needs[k] = points(t), need_dmg(t) end
            sc = { k = 0, n = n, best = nil, blocked = 0, base = eye:to(tl[1].org):angles().y, org = org:clone(), t0 = now, tidx = tl[1].idx,
                use = use, pts = pts, needs = needs }
            SCN[group] = sc
        end
        local ticks = U.max(4, U.round((RAP.v("peek.time") or 400) / 1000 / globals.tickinterval))
        local still = (RAP.W.vel and RAP.W.vel:length2d() or 0) < 20
        local va = cmd.view_angles
        local y0 = va.y
        local saved = {}
        for _, k in ipairs(SAVED_KEYS) do saved[k] = getf(cmd, k) end
        local clock = RAP.prof.clock
        local budget = (RAP.CFG.peek.scan_ms or 1.5) / 1000
        local c0 = clock and clock()
        local use, pts, needs, start = sc.use, sc.pts, sc.needs, sc.org
        local pri_dmg = RAP.v("peek.pri") == "Highest damage"
        local ok, err = pcall(function()
            setf(cmd, "forwardmove", 450); setf(cmd, "sidemove", 0)
            if saved.buttons ~= nil then setf(cmd, "buttons", 0) end
            setf(cmd, "in_duck", false); setf(cmd, "in_jump", false); setf(cmd, "in_speed", false)
            while sc.k < n do
                local ang = U.norm(sc.base + 90 + sc.k * 360 / n)
                sc.k = sc.k + 1
                va.y = ang
                pcall(U.setf, cmd, "view_angles", va)
                local sim
                if still then local oks, s1 = pcall(me.simulate_movement, me, nil, vector(), 1); sim = oks and s1 or nil end
                sim = sim or me:simulate_movement()
                local prev = 0
                for tk = 1, ticks do
                    sim:think()
                    local spd = sim.velocity:length2d()
                    if tk > 3 and spd < prev - 25 then break end
                    prev = spd
                    if tk % 2 == 0 then
                        local o = sim.origin:clone()
                        if o:dist2d(start) >= 6 then
                            local e = o:clone()
                            local vo = sim.view_offset
                            e.z = e.z + ((type(vo) == "number" and vo > 10) and vo or vofs)
                            local found
                            for k2, t in ipairs(use) do
                                local need, hd = needs[k2], 0
                                for _, p in ipairs(pts[k2]) do local dm = dmg_at(me, e, p, t); if dm >= need and dm > hd then hd = dm end end
                                if hd > 0 then
                                    if dangerous(t.idx, ang) then sc.blocked = sc.blocked + 1 else found = { t = t, dmg = hd } end
                                    break
                                end
                            end
                            if found then
                                local best = sc.best
                                local better = not best or (pri_dmg and (found.dmg > best.dmg + 1 or (found.dmg >= best.dmg - 1 and tk < best.ticks)))
                                    or (not pri_dmg and tk < best.ticks)
                                if better then sc.best = { yaw = ang, ticks = tk, start = start:clone(), pos = o, dmg = found.dmg, tidx = found.t.idx, thr = found.t.ent, dormant = found.t.dormant } end
                                break
                            end
                        end
                    end
                end
                if c0 and sc.k < n and clock() - c0 > budget then break end
            end
        end)
        va.y = y0
        pcall(U.setf, cmd, "view_angles", va)
        for k, v in pairs(saved) do setf(cmd, k, v) end
        if not ok then SCN[group] = nil; error(err, 0) end
        if sc.k < n then return nil, "pending" end
        SCN[group] = nil
        if sc.best then return sc.best end
        if sc.blocked > 0 then return nil, "only spots where you died recently" end
        return nil, string.format("no spot within %d ms", RAP.v("peek.time") or 400)
    end
    local function stop(cmd, me)
        local v = me.m_vecVelocity
        local spd = v and v:length2d() or 0
        if spd > 15 then setf(cmd, "move_yaw", v:angles().y); setf(cmd, "forwardmove", -U.min(450, spd * 2)) else setf(cmd, "forwardmove", 0) end
        setf(cmd, "sidemove", 0)
        for _, k in ipairs({ "in_forward", "in_back", "in_moveleft", "in_moveright" }) do setf(cmd, k, false) end
    end
    local function go(cmd, yaw)
        setf(cmd, "move_yaw", yaw); setf(cmd, "forwardmove", 450); setf(cmd, "sidemove", 0)
        for _, k in ipairs({ "in_forward", "in_back", "in_moveleft", "in_moveright", "in_speed" }) do setf(cmd, k, false) end
    end
    local SNIPER = { [40] = true, [9] = true, [11] = true, [38] = true }

    local function run(cmd)
        local W = RAP.W
        if not W.alive then reset(); return end
        local me, now = W.me, globals.curtime
        -- v52: позиции копятся только при включенном AI Peek и обновляются на месте (раньше - новая таблица на
        -- каждого видимого врага каждый тик, даже с выключенной функцией)
        if not RAP.v("peek.on") then reset("off"); return end
        for _, en in ipairs(W.enemies) do
            if not en.dormant then
                local o = en.ent:get_origin()
                if o then
                    local sv = SEEN[en.idx]
                    if not sv then sv = {}; SEEN[en.idx] = sv end
                    sv.t, sv.org, sv.duck = now, o:clone(), en.ent.m_flDuckAmount or 0
                end
            end
        end
        if not RAP.v("peek.key") then if PK.st ~= 0 then finish(PK.seen and "empty_vis" or "empty_dorm"); reset() end; PK.reason = "hold the AI Peek key"; return end
        if me.m_MoveType ~= 2 then reset("not walking"); return end
        local org = me:get_origin()
        if PK.st == 0 then
            if bit.band(me.m_fFlags or 1, 1) ~= 1 then PK.reason = "in air"; return end
            local since = now - PK.last_scan
            if since < 0.08 and since > -1 then return end      -- since <= -1: curtime сбросился (смена карты)
            PK.last_scan = now
            local wpn = W.weapon
            if not wpn then PK.reason = "no weapon"; return end
            local clip = wpn.m_iClip1 or 1
            if clip == 0 then PK.reason = "empty clip"; return end
            if clip < 0 then PK.reason = "not a gun"; return end
            if RAP.v("peek.scope") and SNIPER[W.widx] and not me.m_bIsScoped then PK.reason = "scope first"; return end
            if ST.need_dt and (W.charge or 0) < 1 then PK.reason = "AI: wait for DT (died on recent peeks)"; return end
            local tl = targets()
            if #tl == 0 then PK.reason = "no target"; return end
            local vis, hid = {}, {}
            for _, t in ipairs(tl) do if t.dormant then hid[#hid + 1] = t else vis[#vis + 1] = t end end
            local c, why
            if #hid == 0 then SCN.hid = nil end
            -- пока продолжается скан спрятавшихся целей, видимые не пересканируются (иначе полный скан каждый тик)
            if #vis > 0 and not SCN.hid then c, why = scan(cmd, me, vis, "vis") end
            if not c and #hid > 0 and why ~= "already hittable from here" and why ~= "pending" then c, why = scan(cmd, me, hid, "hid") end
            -- скан не уложился в бюджет тика: продолжение на следующем тике (без паузы 0.08 с)
            if why == "pending" then PK.reason = "scanning..."; PK.last_scan = now - 1; return end
            -- скан тяжелый (направления x тики x trace_bullet): после пустого скана следующий через 0.25 с, а не 0.08 с
            if not c then PK.reason = why or "no spot"; PK.last_scan = now + 0.17; return end
            local ready = U.max(wpn.m_flNextPrimaryAttack or 0, me.m_flNextAttack or 0) - now
            if ready > c.ticks * globals.tickinterval + 0.1 then PK.reason = "weapon not ready"; return end
            PK.st, PK.cand, PK.t0, PK.arrived, PK.shot_t, PK.logged, PK.seen = 1, c, now, nil, nil, nil, nil
            PK.thr_org = c.thr:get_origin():clone()
            PK.untl = now + c.ticks * globals.tickinterval + 0.35
            PK.reason = string.format("peeking%s: %d dmg in %d ms", c.dormant and " (hidden target)" or "", U.round(c.dmg), U.round(c.ticks * globals.tickinterval * 1000))
            return
        end
        local c = PK.cand
        if PK.st == 1 then
            if not PK.arrived and (org:dist2d(c.pos) < 8 or org:dist2d(c.start) >= c.pos:dist2d(c.start) - 2) then PK.arrived = now end
            local okt, gone = pcall(function() return (not c.thr:is_alive()) or c.thr:get_origin():dist(PK.thr_org) > 150 end)
            local lost = (not okt) or gone
            if (RAP.shots.last_fire or -9) > PK.t0 and not PK.shot_t then PK.shot_t = now end
            local okd, dorm = pcall(c.thr.is_dormant, c.thr)
            if not (okd and dorm) then PK.seen = true end
            local hold = U.clamp((RAP.v("peek.hold") or 450) + ST.adj, 150, 1300) / 1000
            local ghost = PK.arrived and okd and dorm and not PK.seen and now - PK.arrived > 0.25
            if (PK.shot_t and now - PK.shot_t > 0.12) or lost or ghost or (not PK.arrived and now > PK.untl) or (PK.arrived and now - PK.arrived > hold) then
                finish(PK.shot_t and "shot" or (PK.seen and "empty_vis" or "empty_dorm"))
                PK.reason = PK.shot_t and "shot, returning" or (lost and "target moved / died" or (PK.seen and "visible but ragebot did not shoot" or "target not there"))
                PK.st, PK.untl = 2, now + 0.8
            end
        end
        if PK.st == 1 then if PK.arrived then stop(cmd, me) else go(cmd, org:to(c.pos):angles().y) end; return end
        if org:dist2d(c.start) < 8 or now > PK.untl then stop(cmd, me); reset(PK.reason); return end
        go(cmd, org:to(c.start):angles().y)
    end
    RAP.on("tick", "ai peek", function(cmd)
        local ok, err = pcall(run, cmd)
        if not ok then
            PK.reason = "error: " .. tostring(err):gsub("^.-:%d+: ", ""):sub(1, 60)
            RAP.U.errors["ai peek"] = { n = ((RAP.U.errors["ai peek"] or {}).n or 0) + 1, t = globals.realtime, msg = tostring(err) }
            pcall(reset)
        end
    end, 60)
    RAP.on("ind_rows", "peek", function(add)
        if RAP.v("peek.on") and RAP.v("peek.key") then add("PEEK: " .. PK.reason, color(255, 210, 150), 3) end
    end)
    RAP.cmd.peek = function()
        print(string.format("[peek] enabled %s | key %s | state %s | %s", tostring(RAP.v("peek.on")), RAP.v("peek.key") and "held" or "not held",
            PK.st == 1 and "out" or (PK.st == 2 and "back" or "idle"), PK.reason))
        print(string.format("[peek] peeks %d: shot %d | kill %d | died %d | no shot: target not there %d, visible but no shot %d",
            ST.n, ST.shot, ST.kill, ST.died, ST.empty_dorm, ST.empty_vis))
        local off = ST.dorm_off - globals.curtime
        print(string.format("[peek] AI: wait %+d ms | trust hidden position %.1f s | hidden peeks %s%s", ST.adj, ST.dorm_age,
            off > 0 and string.format("paused %.0f s", off) or "on", ST.need_dt and " | DT required" or ""))
    end
end
---------------------------------------------------------------- гранаты: super toss, drop, auto release HE
do
    local U = RAP.U
    local G = RAP.menu.group("Misc", "Grenades", 1)
    G.switch("gr.toss", "Super toss (compensate movement)", false)
    G.switch("gr.drop", "Drop grenades", false)
    G.bind("gr.drop_key", "Drop grenades key", { dep = function() return RAP.v("gr.drop") end })
    G.multi("gr.drop_sel", "Drop: types", { "HE", "Molotov", "Incendiary", "Smoke", "Flash", "Decoy" }, { "HE", "Molotov", "Incendiary" },
        { dep = function() return RAP.v("gr.drop") end })
    G.slider("gr.drop_step", "Drop: pause", 60, 400, 150, 1, "ms", { dep = function() return RAP.v("gr.drop") end, adv = true })
    G.switch("gr.ar", "Auto release HE", false, { tip = "Hold attack with HE and the key: the grenade is released when the cheat's prediction says it deals enough damage." })
    G.bind("gr.ar_key", "Auto release key", { dep = function() return RAP.v("gr.ar") end })
    G.slider("gr.ar_dmg", "Auto release: min damage", 1, 98, 50, 1, nil, { dep = function() return RAP.v("gr.ar") end })
    G.switch("gr.ar_lethal", "Auto release: also when lethal", true, { dep = function() return RAP.v("gr.ar") end })

    local TYPES = { CHEGrenade = { "HE", "weapon_hegrenade" }, CMolotovGrenade = { "Molotov", "weapon_molotov" },
        CIncendiaryGrenade = { "Incendiary", "weapon_incgrenade" }, CSmokeGrenade = { "Smoke", "weapon_smokegrenade" },
        CFlashbang = { "Flash", "weapon_flashbang" }, CDecoyGrenade = { "Decoy", "weapon_decoy" } }
    local function cls(w) if not w then return nil end local ok, c = pcall(w.get_classname, w); return ok and c or nil end

    -- super toss: угол броска с учетом скорости игрока (траектория идет туда, куда смотришь)
    local function toss_angles(ang, vel, tv, strength)
        local dir = vector():angles(ang.x - 10 + U.abs(ang.x) / 9, ang.y)
        local v = U.clamp(tv * 0.9, 15, 750) * (U.clamp(strength, 0, 1) * 0.7 + 0.3)
        local res = dir
        for _ = 1, 8 do res = (dir * (res * v + vel * 1.25):length() - vel * 1.25) / v; res:normalize() end
        local out = res:angles()
        if out.x > -10 then out.x = 0.9 * out.x + 9 else out.x = 1.125 * out.x + 11.25 end
        return out
    end
    pcall(function()
        events.grenade_override_view:set(function(e)
            if not RAP.v("gr.toss") then return end
            U.safe("super toss view", function()
                local me = entity.get_local_player()
                local w = me and me:is_alive() and me:get_player_weapon()
                local info = w and w:get_weapon_info()
                if info and info.throw_velocity and w.m_flThrowStrength then e.angles = toss_angles(e.angles, e.velocity, info.throw_velocity, w.m_flThrowStrength) end
            end)
        end)
    end)

    local DROP = { busy = false, last = false, token = 0 }
    local function drop_start(me)
        local list = me:get_player_weapon(true)
        if type(list) ~= "table" then return end
        local want = {}
        for _, n in ipairs(RAP.v("gr.drop_sel") or {}) do want[n] = true end
        local queue, seen = {}, {}
        for _, w in ipairs(list) do
            local t = TYPES[cls(w)]
            if t and want[t[1]] and not seen[t[2]] then seen[t[2]] = true; queue[#queue + 1] = t[2] end
        end
        if #queue == 0 then return end
        DROP.busy, DROP.token = true, DROP.token + 1
        local token, pause = DROP.token, (RAP.v("gr.drop_step") or 150) / 1000
        local function alive() local m2 = entity.get_local_player(); return (m2 and m2:is_alive()) and m2 or nil end
        local step
        -- ошибка внутри отложенного вызова не должна навсегда оставить busy = true (кнопка переставала работать)
        local function guarded(fn, ...)
            local ok = U.safe("drop grenades", fn, ...)
            if not ok and token == DROP.token then DROP.busy = false end
        end
        function step(i)
            if token ~= DROP.token then return end
            if i > #queue or not alive() then DROP.busy = false; return end
            utils.console_exec("use " .. queue[i])
            local tries = 0
            local function poll()
                if token ~= DROP.token then return end
                local m2 = alive()
                if not m2 then DROP.busy = false; return end
                tries = tries + 1
                local w = m2:get_player_weapon()
                local t = TYPES[cls(w)]
                if t and t[2] == queue[i] then
                    if not w.m_bPinPulled then utils.console_exec("drop") end
                    utils.execute_after(pause, function() guarded(step, i + 1) end)
                elseif tries < 12 then utils.execute_after(0.04, function() guarded(poll) end)
                else step(i + 1) end
            end
            utils.execute_after(0.04, function() guarded(poll) end)
        end
        guarded(step, 1)
    end

    local AR = { ev = nil }
    pcall(function()
        events.grenade_prediction:set(function(e)
            U.safe("grenade prediction", function() AR.ev = { t = globals.realtime, type = e.type, damage = e.damage, fatal = e.fatal } end)
        end)
    end)
    RAP.on("tick", "grenades", function(cmd)
        if not RAP.W.alive then return end
        local me = RAP.W.me
        local on = RAP.v("gr.drop") and RAP.v("gr.drop_key") and true or false
        if on and not DROP.last and not DROP.busy then U.safe("drop grenades", drop_start, me) end
        DROP.last = on
        if RAP.v("gr.ar") and RAP.v("gr.ar_key") and cmd.in_attack then
            local w = RAP.W.weapon
            if cls(w) == "CHEGrenade" and w.m_bPinPulled and AR.ev and globals.realtime - AR.ev.t < 0.15 then
                local dmg = tonumber(AR.ev.damage) or 0
                if dmg >= (RAP.v("gr.ar_dmg") or 50) or (RAP.v("gr.ar_lethal") and AR.ev.fatal) then
                    cmd.in_attack = false
                    if RAP.v("main.logs") then U.log("auto release", "released HE (predicted %d damage%s)", dmg, AR.ev.fatal and ", lethal" or "") end
                end
            end
        end
    end, 70)
    RAP.on("shutdown", "grenades", function() DROP.token = DROP.token + 1 end)
end
---------------------------------------------------------------- misc: clantag, trashtalk, события попаданий, линии AA
do
    local U, T = RAP.U, RAP.theme
    local G = RAP.menu.group("Misc", "Misc", 2)
    G.switch("misc.clan", "Clantag", false)
    G.combo("misc.clan_mode", "Clantag mode", { "Animated", "Streak K/D" }, { dep = function() return RAP.v("misc.clan") end })
    G.switch("misc.trash", "Trashtalk on kill", false)
    G.input("misc.trash_list", "Trashtalk phrases (separate with |)", "1|nt|owned|sit|get good", { dep = function() return RAP.v("misc.trash") end })
    G.switch("misc.events", "Hit / miss events (top-left)", true)
    G.switch("misc.lines", "AA direction lines (real / desync)", false)

    local CLAN = { "", "E", "EC", "ECL", "ECLI", "ECLIP", "ECLIPS", "ECLIPSE", "ECLIPSE", "ECLIPSE", "ECLIPS", "ECLIP", "ECLI", "ECL", "EC", "E" }
    local CL = { i = 1, t = 0, on = false, last = nil, k = 0, d = 0 }
    events.player_death:set(function(e)
        U.safe("misc death", function()
            local me = entity.get_local_player()
            if not me then return end
            local att, vic = entity.get(e.attacker, true), entity.get(e.userid, true)
            if att == me and vic ~= me then
                CL.k = CL.k + 1
                if RAP.v("misc.trash") then
                    local list = {}
                    for p in tostring(RAP.v("misc.trash_list") or ""):gmatch("[^|]+") do
                        p = p:gsub("^%s+", ""):gsub("%s+$", ""):gsub("[;\"%c]", "")
                        if p ~= "" then list[#list + 1] = p end
                    end
                    if #list > 0 then utils.console_exec("say " .. list[U.rand(1, #list)]) end
                end
            elseif vic == me then CL.d = CL.d + 1 end
        end)
    end)
    -- события попаданий / промахов (вверху слева)
    local EV = {}
    RAP.on("our_ack", "events", function(_, e)
        if not RAP.v("misc.events") then return end
        local name = e.target and e.target:get_name() or "?"
        local txt = e.state == nil and string.format("Hit %s for %d", name, e.damage or 0) or string.format("Missed %s (%s)", name, tostring(e.state))
        EV[#EV + 1] = { t = globals.realtime, txt = txt, ok = e.state == nil }
        if #EV > 6 then table.remove(EV, 1) end
    end)
    RAP.on("frame", "misc", function()
        local now = globals.realtime
        if RAP.v("misc.clan") and globals.is_connected then
            if now > CL.t + 0.45 then
                CL.t = now
                local tag
                if RAP.v("misc.clan_mode") == "Streak K/D" then tag = string.format("K%d | D%d", CL.k, CL.d)
                else CL.i = CL.i % #CLAN + 1; tag = CLAN[CL.i] end
                if tag ~= CL.last then CL.last = tag; pcall(common.set_clan_tag, tag) end
                CL.on = true
            end
        elseif CL.on then pcall(common.set_clan_tag, ""); CL.on, CL.last = false, nil end
        if RAP.v("misc.events") then
            local f = T.font("ev", "Verdana", 12, "ad", 1)
            local acc = T.accent()
            local y = 6
            for i = #EV, 1, -1 do
                local e = EV[i]
                local age = now - e.t
                if age > 5 then table.remove(EV, i)
                else
                    local a = age > 4.5 and (5 - age) / 0.5 or 1
                    render.rect(vector(8, y + 3), vector(10, y + 13), T.a(e.ok and acc or color(255, 120, 120), a), 1)
                    render.text(f, vector(16, y), color(235, 235, 240, U.floor(255 * a)), nil, e.txt)
                    y = y + 16
                end
            end
        end
        if RAP.v("misc.lines") and RAP.W.alive then
            U.safe("aa lines", function()
                local me = RAP.W.me
                local o = me:get_origin()
                local function line(yaw, col)
                    local r = math.rad(yaw)
                    local a = render.world_to_screen(o)
                    local b = render.world_to_screen(o + vector(math.cos(r) * 40, math.sin(r) * 40, 0))
                    if a and b then render.line(a, b, col) end
                end
                line(rage.antiaim:get_rotation(), color(255, 255, 255, 200))
                line(rage.antiaim:get_rotation(true), T.accent())
            end)
        end
    end, 70)
    RAP.on("round", "misc", function() end)
    RAP.on("shutdown", "misc", function() if CL.on then pcall(common.set_clan_tag, "") end end)
end
---------------------------------------------------------------- пресеты и экспорт / импорт
do
    local U = RAP.U
    local PRESETS = {
        ["Default"] = {},
        ["Li: SSG HvH"] = {
            ["aa.on"] = true, ["aa.source"] = "AI (learns profiles)", ["aa.pitch"] = "Down", ["aa.at_target"] = true,
            ["aa.avoid_bs"] = true, ["aa.legit"] = true, ["aa.brute"] = "Smart (flip on hit)", ["aa.brute_t"] = 5,
            ["aa.lim"] = "After getting hit", ["aa.lim_min"] = 30, ["aa.def_peek"] = true, ["aa.def_peek_t"] = 200,
            ["aa.def_smart"] = true, ["aa.safe_head"] = true,
            ["ai.pool"] = { "Native A", "Native wide", "Native def", "Def flick", "Peek fake", "Delay 3" }, ["ai.merge"] = true,
            ["ai.explore"] = 30, ["ai.memory"] = 95, ["ai.per_enemy"] = true, ["ai.side_mem"] = true, ["ai.panic"] = true,
            ["ai.script_jit"] = true, ["ai.evo"] = true, ["ai.evo_n"] = 12, ["ai.evo_sigma"] = 25,
            ["fl.mode"] = "Adaptive", ["fl.max"] = 14, ["fl.min"] = 2,
            ["rage.on"] = true, ["rage.adapt"] = true, ["rage.hc_max"] = 78,
            ["st.on"] = true, ["st.ctx"] = true, ["st.pop"] = true, ["st.mph"] = 50, ["st.mpb"] = 60,
            ["rs.onshot"] = true, ["rs.dt_body"] = true,
            ["rs.dt_hp"] = 70, ["rs.low_body"] = true, ["rs.low_hp"] = 45,
            ["main.ping"] = 0, ["main.persist"] = true, ["main.bots"] = false,
            ["vis.inds"] = true, ["vis.style"] = "Modern", ["vis.detail"] = "Normal",
            ["fx.logs"] = true, ["fx.marks"] = true, ["fx.hitmark"] = true, ["fx.kill"] = true, ["fx.esp"] = true, ["fx.sound"] = "Skeet",
            ["ex.brk"] = true, ["ex.brk_trig"] = { "Flashed", "Weapon switch", "Flinch", "Landing", "Jump" }, ["ex.brk_rev"] = true,
            ["ex.brk_nade"] = true, ["it.recharge"] = true, ["lag.on"] = true, ["lag.hc"] = false, ["lag.ne"] = 0, ["lag.ok"] = 4,
            ["rage.stall"] = true, ["rage.stall1"] = 350, ["rage.stall2"] = 800, ["rage.delay"] = "Always off",
            ["peek.on"] = true, ["peek.dmg"] = 25, ["peek.time"] = 400, ["peek.hold"] = 450, ["peek.scope"] = false, ["peek.ai"] = true,
            ["misc.events"] = true,
        },
        -- замена "AI Full Auto" из v23-v38: готовые стили
        ["Style: Balanced"] = { ["aa.on"] = true, ["aa.source"] = "AI (learns profiles)", ["aa.brute"] = "Smart (flip on hit)",
            ["aa.lim"] = "After getting hit", ["aa.def_peek"] = true, ["ai.explore"] = 30, ["rage.adapt"] = true, ["rage.hc_max"] = 78,
            ["st.on"] = true, ["fl.mode"] = "Adaptive", ["ex.brk"] = true },
        ["Style: Safe"] = { ["aa.on"] = true, ["aa.source"] = "AI (learns profiles)", ["aa.brute"] = "Smart (flip on hit)",
            ["aa.lim"] = "Always", ["aa.def_peek"] = true, ["aa.safe_head"] = true, ["ai.explore"] = 20, ["rage.adapt"] = true,
            ["rage.hc_max"] = 85, ["st.on"] = true, ["rs.low_body"] = true, ["rs.low_hp"] = 60, ["fl.mode"] = "Adaptive", ["ex.brk"] = true },
        ["Style: Aggressive"] = { ["aa.on"] = true, ["aa.source"] = "AI (learns profiles)", ["aa.brute"] = "Smart (flip on hit)",
            ["aa.lim"] = "After getting hit", ["aa.def_peek"] = true, ["ai.explore"] = 45, ["rage.adapt"] = false, ["st.on"] = true,
            ["rs.low_body"] = false, ["fl.mode"] = "Fluctuate",
            ["ex.brk"] = true, ["it.recharge"] = true },
    }
    local NAMES = { "Li: SSG HvH", "Style: Balanced", "Style: Safe", "Style: Aggressive", "Default" }
    local G = RAP.menu.group("Main", "Presets & config", 2)
    G.combo("pre.sel", "Preset", NAMES, { save = false })
    G.button("Apply preset", function()
        local name = RAP.v("pre.sel")
        -- "Default" - все сохраняемые пункты к значениям по умолчанию (раньше пустая таблица: пресет ничего не делал)
        local src = PRESETS[name] or {}
        if name == "Default" then
            src = {}
            for k, v in pairs(RAP.menu.defaults) do
                if type(v) == "table" then local c = {}; for i, x in ipairs(v) do c[i] = x end; src[k] = c else src[k] = v end
            end
        end
        local n = RAP.menu.apply(src)
        U.log("preset", "applied '%s' (%d values)", tostring(name), n)
    end)

    -- буфер обмена и base64: библиотеки Neverlose, иначе встроенные (vgui2 VGUI_System010 + base64 на Lua)
    local okc, clip = pcall(require, "neverlose/clipboard")
    if not okc then
        okc, clip = pcall(function()
            local F = ffi or require("ffi")
            local arr = F.typeof("char[?]")
            local cnt = utils.get_vfunc("vgui2.dll", "VGUI_System010", 7, "int(__thiscall*)(void*)")
            local setc = utils.get_vfunc("vgui2.dll", "VGUI_System010", 9, "void(__thiscall*)(void*, const char*, int)")
            local getc = utils.get_vfunc("vgui2.dll", "VGUI_System010", 11, "int(__thiscall*)(void*, int, const char*, int)")
            assert(cnt and setc and getc, "vgui2 clipboard not found")
            return {
                get = function() local n = cnt(); if n > 0 then local b = arr(n); getc(0, b, n); return F.string(b, n - 1) end end,
                set = function(t) t = tostring(t); setc(t, #t) end,
            }
        end)
    end
    local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local DEC = {}
    for i = 1, 64 do DEC[B64:byte(i)] = i - 1 end
    local function enc(s)
        local out = {}
        for i = 1, #s, 3 do
            local a, b, c = s:byte(i, i + 2)
            local v = a * 65536 + (b or 0) * 256 + (c or 0)
            local c1, c2, c3, c4 = math.floor(v / 262144) % 64, math.floor(v / 4096) % 64, math.floor(v / 64) % 64, v % 64
            out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1) .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
        end
        return table.concat(out)
    end
    local function dec(s)
        s = tostring(s):gsub("[^%w%+/]", "")
        local out, bits, nb = {}, 0, 0
        for i = 1, #s do
            local d = DEC[s:byte(i)]
            if d then
                bits, nb = bits * 64 + d, nb + 6
                if nb >= 8 then nb = nb - 8; out[#out + 1] = string.char(math.floor(bits / 2 ^ nb) % 256); bits = bits % 2 ^ nb end
            end
        end
        return table.concat(out)
    end
    RAP.b64 = { enc = enc, dec = dec }
    RAP.clip_ok = okc
    G.button("Export config to clipboard", function()
        if not okc then print("[config] clipboard unavailable"); return end
        U.safe("export", function() clip.set("eclipse>" .. enc(json.stringify(RAP.menu.snapshot())) .. "<"); print("[config] copied to clipboard") end)
    end)
    G.button("Import config from clipboard", function()
        if not okc then print("[config] clipboard unavailable"); return end
        U.safe("import", function()
            -- новые конфиги "eclipse>...<", старые "rap2>...<" (Rage AA Pro 2) тоже принимаются
            local raw = tostring(clip.get() or "")
            local body = raw:match("eclipse>(.-)<") or raw:match("rap2>(.-)<")
            if not body then print("[config] clipboard has no ECLIPSE config"); return end
            local t = json.parse(dec(body))
            print(string.format("[config] imported %d values", RAP.menu.apply(t)))
        end)
    end)
    G.button("Reset AA learning", function() RAP.ai.reset() end)
end
---------------------------------------------------------------- консоль: /eclipse ...
do
    local U = RAP.U
    local C = RAP.cmd
    -- selftest 2.0: PASS / WARN / FAIL. "/eclipse selftest release" дополнительно проверяет снятие всех переопределений
    -- (как при выгрузке скрипта); со следующего тика скрипт применяет их заново.
    local function selftest(arg)
        local ok, probs, warns = 0, {}, {}
        local function chk(name, cond, note)
            if cond then ok = ok + 1; print("[selftest] PASS  " .. name .. (note and ("  (" .. note .. ")") or ""))
            else probs[#probs + 1] = name .. (note and (": " .. note) or "") end
        end
        local function warn(name, cond, note)
            if cond then ok = ok + 1; print("[selftest] PASS  " .. name .. (note and ("  (" .. note .. ")") or ""))
            else warns[#warns + 1] = name .. (note and (": " .. note) or "") end
        end
        local function count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
        -- профили AA: параметры в допустимых пределах
        do
            local bad = {}
            local function rng(v, lo, hi) return v == nil or (type(v) == "number" and v >= lo and v <= hi) end
            for _, p in ipairs(RAP.profiles.list) do
                if not (U.has(RAP.AA_MODES, p.mode) and rng(p.left, 0, 60) and rng(p.right, 0, 60) and rng(p.range, 0, 180)
                    and rng(p.delay, 1, 16) and rng(p.offset, -180, 180) and rng(p.offL, -180, 180) and rng(p.offR, -180, 180)) then bad[#bad + 1] = p.name end
            end
            chk("AA profiles in range", #bad == 0, #bad > 0 and table.concat(bad, ", ") or (#RAP.profiles.list .. " profiles"))
        end
        -- утечки переопределений: выключенный модуль не должен ничего держать
        do
            local rage_owned = 0
            for k, v in pairs(RAP.arb.owned) do if v then rage_owned = rage_owned + 1; if RAP.arb.last[k] == nil then probs[#probs + 1] = "arbiter owns " .. k .. " without a value" end end end
            chk("rage overrides vs Script rage control", RAP.v("rage.on") or rage_owned == 0, rage_owned .. " item(s) owned")
            local aa_owned = 0
            for _, v in pairs(RAP.aa_owned and RAP.aa_owned() or {}) do if v then aa_owned = aa_owned + 1 end end
            chk("AA overrides vs Script anti-aim", RAP.v("aa.on") or aa_owned == 0, aa_owned .. " AA item(s) owned")
            print(string.format("[selftest] info  owned now: rage %d, AA %d, other %d", rage_owned, aa_owned, count(RAP.own_list and RAP.own_list())))
        end
        -- хуки: одна регистрация на имя в фазе (повторная регистрация = двойная работа / двойное обучение)
        do
            local dup = {}
            for phase, list in pairs(RAP.hooks) do
                local seen = {}
                for _, h in ipairs(list) do local k = h.name; if seen[k] then dup[#dup + 1] = phase .. ":" .. k end; seen[k] = true end
            end
            chk("hooks registered once", #dup == 0, #dup > 0 and table.concat(dup, ", ") or nil)
        end
        -- база: поврежденные / отклоненные записи, размер
        do
            local S = RAP.store
            local bad, total = {}, 0
            for _, key in ipairs({ "rap2_strat", "rap2_ai", "rap2_evo", "rap2_journal", "rap2_ajournal", "rap2_reports", "rap2_widgets", "rap2_cfg", "rap2_meta",
                "rap2_decisions", "rap2_deaths" }) do
                local okr, raw = pcall(function() return db[key] end)
                if okr and type(raw) == "string" then
                    total = total + #raw
                    if raw ~= "" and not S.parse(raw) then bad[#bad + 1] = key end
                end
            end
            for k, v in pairs(S.corrupted or {}) do bad[#bad + 1] = k .. " (at load: " .. v .. ")" end
            chk("db records readable", #bad == 0, #bad > 0 and table.concat(bad, ", ") or string.format("%.0f KB total", total / 1024))
            local rej = {}
            for k, v in pairs(S.rejected or {}) do rej[#rej + 1] = string.format("%s %.0f KB", k, v / 1024) end
            warn("db size limit", #rej == 0, #rej > 0 and ("not saved: " .. table.concat(rej, ", ")) or nil)
            local near = {}
            for k, v in pairs(S.near or {}) do near[#near + 1] = string.format("%s %.0f KB", k, v / 1024) end
            warn("db size headroom (< 75% of limit)", #near == 0, #near > 0 and table.concat(near, ", ") or nil)
        end
        -- память: размеры таблиц, которые растут по ходу игры
        do
            local AI, ST = RAP.ai, RAP.strat
            local m = { ["AI per-enemy"] = { count(AI.en), 200 }, ["AI dodge per-enemy"] = { count(AI.ebd), 200 }, ["phase shift"] = { count(AI.sm), 400 },
                ["strategy contexts"] = { count(ST.ctx), 600 }, ["strategy session"] = { count(ST.sess), 300 }, ["target context"] = { count(RAP.TC), 64 },
                ["journal"] = { #RAP.tele.journal.rows, RAP.CFG.log.keep }, ["AA journal"] = { #RAP.tele.ajournal.rows, RAP.CFG.log.keep },
                ["pending enemy shots"] = { #RAP.shots.pending, 32 }, ["Evo A/B"] = { count(RAP.evo.ab), 6 } }
            local big = {}
            for name, v in pairs(m) do if v[1] > v[2] then big[#big + 1] = string.format("%s %d > %d", name, v[1], v[2]) end end
            warn("memory tables within limits", #big == 0, #big > 0 and table.concat(big, ", ") or nil)
            local stale, now = 0, globals.curtime
            for _, p in ipairs(RAP.shots.pending) do if now - p.t > 3 or now < p.t then stale = stale + 1 end end
            warn("no stuck pending shots", stale == 0, stale > 0 and (stale .. " older than 3 s") or nil)
        end
        if arg == "release" then
            RAP.arb.release(); RAP.aa_release(); RAP.own_release_all()
            if RAP.pressure and RAP.pressure.release_ds then RAP.pressure.release_ds() end
            local left = 0
            if RAP.pressure and RAP.pressure.ds_owned and RAP.pressure.ds_owned() then left = left + 1 end
            for _, v in pairs(RAP.arb.owned) do if v then left = left + 1 end end
            for _, v in pairs(RAP.aa_owned()) do if v then left = left + 1 end end
            left = left + count(RAP.own_list())
            chk("full release (as on unload)", left == 0, left > 0 and (left .. " override(s) left") or "everything returned to your settings")
            if RAP.aa then RAP.aa.active = false end
        end
        local R = RAP.ref
        chk("ragebot items", #R.missing == 0, #R.missing > 0 and table.concat(R.missing, ", ")
            or string.format("Min. Damage in %d weapon tab(s)", R.tabs.min_damage or 0))
        chk("Safe Points options", R.OPT.sp_prefer ~= nil and R.OPT.sp_force ~= nil, tostring(R.OPT.sp_prefer) .. " / " .. tostring(R.OPT.sp_force))
        chk("Body Aim options", R.OPT.ba_prefer ~= nil and R.OPT.ba_force ~= nil, tostring(R.OPT.ba_prefer) .. " / " .. tostring(R.OPT.ba_force))
        print("[selftest] info    cheat Delay Shot item: " .. (R.delay_shot and (tostring(R.tabs.delay_shot) .. " weapon tab(s)") or "not found (option has no effect)"))
        local p, src = RAP.W.ping()
        chk("ping", p ~= nil, string.format("%.0f ms via %s", p * 1000, src))
        warn("profiler timer", RAP.prof.clock ~= nil, RAP.prof.clock_src)
        chk("db / json", pcall(function() db.rap2_test = json.stringify({ 1 }); assert(json.parse(db.rap2_test)[1] == 1); db.rap2_test = nil end))
        local SH = RAP.shots
        chk("enemy shot tracking", not ((SH.stat.fire or 0) >= 20 and SH.impacts == 0),
            string.format("%d bullet_fire, %d impacts", SH.stat.fire or 0, SH.impacts))
        local nerr = 0
        for k, e in pairs(U.errors) do nerr = nerr + 1; print(string.format("[selftest] error   %s x%d: %s", k, e.n, e.msg)) end
        chk("module errors", nerr == 0, nerr > 0 and (nerr .. " module(s)") or nil)
        for _, s in ipairs(warns) do print("[selftest] WARN  " .. s) end
        for _, s in ipairs(probs) do print("[selftest] FAIL  " .. s) end
        print(string.format("[selftest] [PASS] %d  [WARN] %d  [FAIL] %d", ok, #warns, #probs))
    end
    C.selftest = selftest
    C.why = function()
        if RAP.explain then RAP.explain() end
        print("[why] ragebot items (value <- who decided):")
        for key, w in pairs(RAP.arb.why) do
            local v = w.value
            if type(v) == "table" then v = table.concat(v, ",") end
            print(string.format("[why] %-12s %-14s <- %s", key, tostring(v or "yours"), w.src))
        end
        -- переопределения вне арбитра (exploits / ideal tick / noscope / Delay Shot): они не видны в списке выше
        local own = {}
        for k, o in pairs(RAP.own_list()) do
            local v = o.v
            if type(v) == "table" then v = "{" .. table.concat(v, ",") .. "}" end
            own[#own + 1] = k .. "=" .. tostring(v)
        end
        if RAP.pressure and RAP.pressure.ds_owned and RAP.pressure.ds_owned() then own[#own + 1] = "Delay Shot=off (rage.delay)" end
        table.sort(own)
        print("[why] other cheat items held by the script: " .. (#own > 0 and table.concat(own, ", ") or "none"))
    end
    C.help = function()
        print("[eclipse] " .. RAP.VERSION .. " - console commands (/eclipse <command>):")
        print("[eclipse]   selftest [release]  health  perf [sec]  why  strat  ai  evo  evolve  decisions [n]  journal [n]")
        print("[eclipse]   report  coach  deaths  shots  peek  replay [aa | strategy.x=v ...]  cfg [path value | reset]")
        print("[eclipse]   db [reset <part>]  save  reset_ai")
    end
    C.brain = function() RAP.cmd.strat() end
    C.cfg = function(arg)
        if not arg or arg == "" then
            for sec, t in pairs(RAP.CFG) do
                local parts = {}
                for k, v in pairs(t) do parts[#parts + 1] = string.format("%s=%s%s", k, tostring(v), v ~= RAP.CFG_DEF[sec][k] and "*" or "") end
                table.sort(parts)
                print(string.format("[cfg] %s: %s", sec, table.concat(parts, "  ")))
            end
            print("[cfg] change: /eclipse cfg strategy.confidence 0.75   |   /eclipse cfg reset   (* = changed)")
            return
        end
        if arg == "reset" then RAP.cfg_reset(); print("[cfg] defaults restored"); return end
        local path, val = arg:match("^(%S+)%s+(%S+)$")
        local ok, err = RAP.cfg_set(path, val)
        print(ok and string.format("[cfg] %s = %s", path, val) or ("[cfg] " .. tostring(err)))
    end
    C.shots = function()
        local s = RAP.shots.stat
        print(string.format("[shots] bullet_fire %d | impacts %d | hit you %d | dodged %d | far %d | cover %d | inaccurate %d | no direction %d | bots %d | late fire %d",
            s.fire or 0, RAP.shots.impacts, s.hit or 0, s.dodge or 0, s.far or 0, s.blocked or 0, s.inaccurate or 0, s.nodir or 0, s.bot or 0, s.late_fire or 0))
        print(string.format("[shots] no direction breakdown: shooter hidden (dormant) %d | shooter > 2500u away %d | other %d | late impacts recovered %d",
            s.nodir_dormant or 0, s.nodir_far or 0, s.nodir_other or 0, s.late_impact or 0))
    end
    C.save = function()
        RAP.save_all(true)
        local io = RAP.store.io
        print(string.format("[eclipse] saved: %d key(s), %.0f KB, %.1f ms", io.n, io.bytes / 1024, io.ms))
    end
    RAP.console = C
    -- команды: /eclipse <команда> (основное имя) или /raap <команда> (старое имя, оставлено для привычки)
    -- true = команда скрипта (ввод не уходит в консоль игры)
    local function handle(text)
        local t = tostring(text or ""):lower()
        local pre
        for _, p in ipairs({ "/eclipse", "/raap" }) do
            local nx = t:sub(#p + 1, #p + 1)
            if t:sub(1, #p) == p and (nx == "" or nx:match("%s")) then pre = p; break end
        end
        if not pre then return false end
        local c, rest = t:sub(#pre + 1):match("^%s+(%S+)%s*(.-)%s*$")
        c = c or ""
        if C[c] then U.safe("console " .. c, C[c], rest)
        else
            local names = {}
            for k in pairs(C) do names[#names + 1] = k end
            table.sort(names)
            print("[eclipse] commands: /eclipse " .. table.concat(names, " | "))
        end
        return true
    end
    events.console_input:set(function(text)
        local ok, mine = U.safe("console", handle, text)
        if ok and mine then return false end
    end)
end

---------------------------------------------------------------- события чита -> фазы модулей
do
    local U = RAP.U
    -- Сохранение (сотни KB JSON) - не в createmove: там оно раз в минуту давало фриз и пропущенный тик посреди боя.
    -- Теперь - в начале раунда и после твоей смерти (для DM-серверов без раундов), не чаще раза в 30 с, и при выгрузке.
    local last_save = globals.realtime
    -- v52: плановое сохранение пишет только измененные ключи (RAP.store.mark), force - все; время и объем - /eclipse db
    function RAP.save_all(force)
        local io, clock = RAP.store.io, RAP.prof.clock
        io.n, io.bytes, io.skipped = 0, 0, 0
        local t0 = clock and clock()
        RAP.run("save", force and true or false)
        io.ms = t0 and (clock() - t0) * 1000 or 0
        io.force, io.t = force and true or false, globals.realtime
    end
    local function save_soon()
        if globals.realtime - last_save < 30 then return end
        last_save = globals.realtime
        RAP.save_all(false)
    end
    events.createmove:set(function(cmd) RAP.run("tick", cmd) end)
    events.render:set(function() RAP.run("frame") end)
    events.round_start:set(function() RAP.run("round"); save_soon() end)
    events.player_death:set(function(e)
        U.safe("autosave", function()
            if entity.get(e.userid, true) == entity.get_local_player() then utils.execute_after(0.5, save_soon) end
        end)
    end)
    events.level_init:set(function() RAP.run("level") end)
    events.shutdown:set(function()
        RAP.save_all(true)
        RAP.arb.release()
        RAP.run("shutdown")
        RAP.own_release_all()
    end)
    RAP.menu.refresh()
    RAP.run("load")
    print(string.format("[%s] %s loaded - console: /eclipse help", RAP.NAME, RAP.VERSION))
end
---------------------------------------------------------------- инструменты: replay по журналу, health, db
do
    local U = RAP.U
    -- Replay 2.0: офлайн A/B двух вариантов логики на одних и тех же событиях журнала.
    --   /eclipse replay                      -> A = логика v49 (без атрибуции и гистерезиса, CFG v49), B = текущая логика и твой CFG
    --   /eclipse replay strategy.panic_misses=4 strategy.confidence=0.8  -> A = текущая, B = текущая с этими значениями
    --   /eclipse replay aa                   -> то же для выбора AA-профилей (журнал выстрелов врагов по тебе)
    -- Метод: политика проигрывается по журналу; результат известен только там, где она выбрала бы то же, что реально
    -- стояло (совпадения) - по ним считается hit rate / dodge rate. Число смен и "ложные" смены (на вариант, который в
    -- журнале показал себя хуже оставленного) считаются по всем событиям. Эксперименты (случайные) не проигрываются.
    local function phi(z)
        local s, x = z < 0 and -1 or 1, math.abs(z) / 1.41421356
        local t = 1 / (1 + 0.3275911 * x)
        local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
        return 0.5 * (1 + s * y)
    end
    local function ci(p, n) return n > 0 and 1.96 * math.sqrt(math.max(p * (1 - p), 0.0025) / n) or 0 end
    local LEGACY_ST = { confidence = 0.8, min_samples = 3, panic_misses = 4, decay = 0.97, equal_margin = 0.05 }
    local function sim_strategy(rows, c, legacy)
        local ST = RAP.strat
        local ARMS = ST.ARMS
        local idx_of = {}
        for i, n in ipairs(ARMS) do idx_of[n] = i end
        local stats, cur, streak, nkey, emp = {}, {}, {}, {}, {}
        local M = { n = 0, agree = 0, hits = 0, sw = 0, list = {} }
        local function beta(s, a) local al, be = 1 + s[a].h, 1 + s[a].m; local t = al + be; return al / t, al * be / (t * t * (t + 1)) end
        for _, r in ipairs(rows) do
            local arm = idx_of[r.s]
            if arm then
                local key = (r.w or "?") .. "|" .. (r.a or "?")
                local s = stats[key]
                if not s then s = {}; for a = 1, #ARMS do s[a] = { h = 0, m = 0 } end; stats[key] = s end
                local pick = cur[key] or arm
                cur[key] = pick
                local hit = r.r == "hit"
                M.n = M.n + 1
                if pick == arm then M.agree = M.agree + 1; if hit then M.hits = M.hits + 1 end end
                local cw
                if legacy then cw = (hit or ST.LEARN[r.r]) and 1 or 0
                else cw = r.aw or (hit and 1 or ST.attr_w(r.r)) end
                if hit or ST.LEARN[r.r] then
                    local e = emp[key] or {}; emp[key] = e
                    local x = e[arm] or { 0, 0 }; e[arm] = x
                    x[1], x[2] = x[1] + (hit and 1 or 0), x[2] + 1
                end
                if cw > 0 then
                    local dk = c.decay ^ cw
                    for a = 1, #ARMS do s[a].h, s[a].m = s[a].h * dk, s[a].m * dk end
                    local val = 1
                    if hit and not legacy then val = r.hg == 1 and 1.5 or (((r.wd or 0) > 0 and (r.d or 0) < 0.5 * r.wd) and 0.6 or 1) end
                    if hit then s[arm].h = s[arm].h + val * cw else s[arm].m = s[arm].m + cw end
                    if arm == pick then
                        nkey[key] = (nkey[key] or 0) + 1
                        if hit then streak[key] = 0 elseif legacy or cw >= 0.5 then streak[key] = (streak[key] or 0) + 1 end
                    end
                    local alt, am = nil, -1
                    for a = 1, #ARMS do if a ~= pick and ST.arm_ok(a) then local m = beta(s, a); if m > am then alt, am = a, m end end end
                    if alt then
                        local ma, va = beta(s, alt)
                        local mc, vc = beta(s, pick)
                        local pb = phi((ma - mc) / math.sqrt(math.max(va + vc, 1e-6)))
                        local go = (streak[key] or 0) >= c.panic_misses
                        if not go and (nkey[key] or 0) >= c.min_samples then
                            if legacy then go = pb >= c.confidence else go = RAP.switch_ok(ma, va, mc, vc, pb, c.confidence, c.equal_margin) end
                        end
                        if go then
                            M.sw = M.sw + 1
                            M.list[#M.list + 1] = { key, pick, alt }
                            cur[key], streak[key], nkey[key] = alt, 0, 0
                        end
                    end
                end
            end
        end
        -- ложная смена: в журнале новый вариант попадал хуже оставленного (оба с 3+ выстрелами)
        M.judged, M.false_sw = 0, 0
        for _, sw in ipairs(M.list) do
            local e = emp[sw[1]] or {}
            local a, b = e[sw[2]], e[sw[3]]
            if a and b and a[2] >= 3 and b[2] >= 3 then
                M.judged = M.judged + 1
                if b[1] / b[2] < a[1] / a[2] then M.false_sw = M.false_sw + 1 end
            end
        end
        return M
    end
    local function sim_aa(rows, legacy, min_life)
        local cnt, cur, since, last_sw, hits, last_panic, emp = {}, {}, {}, {}, {}, {}, {}
        local M = { n = 0, agree = 0, dodges = 0, sw = 0, panic = 0, judged = 0, false_sw = 0, list = {} }
        local sess
        local function post(g, i)
            local row = cnt[g] or {}
            local D, H = 0, 0
            for _, x in pairs(row) do D, H = D + x[1], H + x[2] end
            local b = (D + 1) / (D + H + 2)
            local x = row[i] or { 0, 0 }
            local al, be = 1 + b * 3 + x[1], 1 + (1 - b) * 3 + x[2]
            local t = al + be
            return al / t, al * be / (t * t * (t + 1)), x[1] + x[2], b
        end
        local function best(g, ex, optimistic)
            local bi, bm = nil, -1e9
            for i in pairs(cnt[g] or {}) do
                if i ~= ex then local m, v = post(g, i); if optimistic then m = m + math.sqrt(v) end; if m > bm then bi, bm = i, m end end
            end
            return bi
        end
        for _, r in ipairs(rows) do
            if r.s ~= sess then since, last_sw, hits, last_panic, sess = {}, {}, {}, {}, r.s end
            local g, p, t = r.g, r.p, r.t or 0
            if g and p then
                cnt[g] = cnt[g] or {}
                if not cur[g] then cur[g], since[g] = p, t end
                M.n = M.n + 1
                if cur[g] == p then M.agree = M.agree + 1; if r.k == "dodge" then M.dodges = M.dodges + 1 end end
                local e = emp[g] or {}; emp[g] = e
                local ex = e[p] or { 0, 0 }; e[p] = ex
                ex[1], ex[2] = ex[1] + (r.k == "dodge" and 1 or 0), ex[2] + 1
                local w = (r.w0 or 1) * (legacy and 1 or (r.aw or 1))
                if w > 0 then
                    for _, x in pairs(cnt[g]) do x[1], x[2] = x[1] * 0.995, x[2] * 0.995 end
                    local x = cnt[g][p] or { 0, 0 }; cnt[g][p] = x
                    if r.k == "dodge" then x[1] = x[1] + w else x[2] = x[2] + w end
                end
                if r.k == "hit" and p == cur[g] and (legacy or (r.aw or 1) >= 0.5) then
                    local hl = hits[g] or {}; hits[g] = hl
                    hl[#hl + 1] = t
                    if #hl > 4 then table.remove(hl, 1) end
                    local recent = 0
                    for _, ht in ipairs(hl) do if t - ht < 6 and t >= ht then recent = recent + 1 end end
                    local mc, vc, n, base = post(g, p)
                    local age = t - (since[g] or t)
                    local ssw = last_sw[g] and t - last_sw[g] or 1e9
                    local to, panic
                    if legacy then
                        if recent >= 2 and t - (last_panic[g] or -99) > 4 then to, panic = best(g, p, true), true
                        else
                            local alt = best(g, p, true)
                            if alt and n >= 3 then
                                local ma, va = post(g, alt)
                                if phi((ma - mc) / math.sqrt(math.max(va + vc, 1e-6))) >= 0.7 or mc < base - 0.05 then to = alt end
                            end
                        end
                    else
                        if recent >= 2 and age >= 1.5 and t - (last_panic[g] or -99) > 8 then to, panic = best(g, p, true), true
                        elseif age >= min_life and ssw >= 3 then
                            local alt = best(g, p)
                            if alt then
                                local ma, va, na = post(g, alt)
                                local pb = phi((ma - mc) / math.sqrt(math.max(va + vc, 1e-6)))
                                if n >= 4 and na >= 3 and RAP.switch_ok(ma, va, mc, vc, pb, 0.8, 0.08) then to = alt
                                elseif n >= 6 and mc + math.sqrt(vc) < base - 0.04 then to = best(g, p, true) end
                            end
                        end
                    end
                    if to and to ~= p then
                        if panic then M.panic = M.panic + 1; last_panic[g] = t end
                        M.sw = M.sw + 1
                        M.list[#M.list + 1] = { g, p, to }
                        cur[g], since[g], last_sw[g] = to, t, t
                    end
                end
            end
        end
        for _, sw in ipairs(M.list) do
            local e = emp[sw[1]] or {}
            local a, b = e[sw[2]], e[sw[3]]
            if a and b and a[2] >= 3 and b[2] >= 3 then
                M.judged = M.judged + 1
                if b[1] / b[2] < a[1] / a[2] then M.false_sw = M.false_sw + 1 end
            end
        end
        return M
    end
    RAP.cmd.replay = function(arg)
        arg = tostring(arg or "")
        if arg:match("^aa") then
            local rows = RAP.tele.ajournal.rows
            if #rows < 10 then print(string.format("[replay] AA journal has %d enemy shots - play more (need 10+)", #rows)); return end
            local ml = RAP.v("ai.min_life") or 6
            local A, B = sim_aa(rows, true, ml), sim_aa(rows, false, ml)
            print(string.format("[replay] AA: %d enemy shots at you (hits / dodges), %d sessions mixed in", #rows, (function() local s, n = {}, 0; for _, r in ipairs(rows) do if r.s and not s[r.s] then s[r.s], n = true, n + 1 end end; return n end)()))
            for _, x in ipairs({ { "A legacy v49", A }, { "B current   ", B } }) do
                local m = x[2]
                local p = m.agree > 0 and m.dodges / m.agree or 0
                print(string.format("[replay]   %s matched %3d/%3d  dodge %3.0f%% +/-%2.0f  switches %3d (%.1f per 100 shots, panic %d)  false switches %d of %d judged",
                    x[1], m.agree, m.n, p * 100, ci(p, m.agree) * 100, m.sw, m.n > 0 and m.sw / m.n * 100 or 0, m.panic, m.false_sw, m.judged))
            end
            print("[replay]   matched = shots where the logic would have used the same profile that was really on; dodge % is measured only on them")
            return
        end
        local rows = RAP.tele.journal.rows
        if #rows < 10 then print(string.format("[replay] journal has %d shots - play more (need 10+)", #rows)); return end
        local cur = {}
        for k, v in pairs(RAP.CFG.strategy) do cur[k] = v end
        local A, B, la, lb, lega
        local over = {}
        for k, v in arg:gmatch("strategy%.([%w_]+)=([%-%d%.]+)") do if cur[k] ~= nil and tonumber(v) then over[k] = tonumber(v) end end
        if next(over) then
            local alt = {}
            for k, v in pairs(cur) do alt[k] = over[k] ~= nil and over[k] or v end
            A, B, la, lb = sim_strategy(rows, cur, false), sim_strategy(rows, alt, false), "A your CFG   ", "B with changes"
            local parts = {}
            for k, v in pairs(over) do parts[#parts + 1] = k .. "=" .. v end
            print("[replay] B changes: " .. table.concat(parts, ", "))
        else
            A, B, la, lb, lega = sim_strategy(rows, LEGACY_ST, true), sim_strategy(rows, cur, false), "A legacy v49  ", "B current     ", true
        end
        print(string.format("[replay] strategy: %d of your shots in the journal", #rows))
        for _, x in ipairs({ { la, A }, { lb, B } }) do
            local m = x[2]
            local p = m.agree > 0 and m.hits / m.agree or 0
            print(string.format("[replay]   %s matched %3d/%3d  hit %3.0f%% +/-%2.0f  switches %3d  false switches %d of %d judged",
                x[1], m.agree, m.n, p * 100, ci(p, m.agree) * 100, m.sw, m.false_sw, m.judged))
        end
        print("[replay]   if the +/- ranges overlap, the hit-rate difference is noise; fewer switches and false switches = more stable logic")
        if lega then print("[replay]   try a change: /eclipse replay strategy.panic_misses=4 strategy.confidence=0.8 | AA: /eclipse replay aa") end
    end
    -- Profiler 2.0: /eclipse perf [секунд, 3-120, по умолчанию 10]. По каждому модулю (фаза:имя):
    -- вызовы, вызовов на тик / кадр, среднее, p95, максимум, ошибки за время замера. Бюджеты (предупреждения):
    -- весь скрипт за тик (createmove) <= 1.0 ms в среднем, за кадр (render) <= 1.0 ms, p95 модуля <= 0.25 ms.
    -- Не замеряются обработчики событий вне фаз (bullet_impact, player_hurt и т.п. - они короткие).
    local BUDGET = { tick = 1.0, frame = 1.0, p95 = 0.25 }
    RAP.cmd.perf = function(arg)
        local P = RAP.prof
        if not P.clock then print("[perf] no timer available in this build"); return end
        local sec = U.clamp(tonumber(arg) or 10, 3, 120)
        P.on, P.d, P.until_t, P.start = true, {}, globals.realtime + sec, globals.realtime
        print(string.format("[perf] measuring for %d seconds - keep playing (fight, move, shoot)...", sec))
    end
    local function p95(e)
        local s = {}
        for i = 1, #e.s do s[i] = e.s[i] end
        if #s == 0 then return 0 end
        table.sort(s)
        return s[math.max(1, math.ceil(#s * 0.95))]
    end
    RAP.on("frame", "perf report", function()
        local P = RAP.prof
        if not P.on or globals.realtime < P.until_t then return end
        P.on = false
        local dur = globals.realtime - P.start
        local list, tick_total, frame_total = {}, 0, 0
        for k, e in pairs(P.d) do
            list[#list + 1] = { k, e }
            if k:find("^tick:") then tick_total = tick_total + e.sum elseif k:find("^frame:") then frame_total = frame_total + e.sum end
        end
        table.sort(list, function(a, b) return a[2].sum > b[2].sum end)
        local ticks = math.max(1, (P.d["tick:world"] or { n = 1 }).n)
        local frames = math.max(1, (P.d["frame:widgets"] or { n = 1 }).n)
        local tick_avg, frame_avg = tick_total / ticks, frame_total / frames
        print(string.format("[perf] %.1f s, %d ticks, %d frames: script per tick %.3f ms (budget %.1f), per frame %.3f ms (budget %.1f)",
            dur, ticks, frames, tick_avg, BUDGET.tick, frame_avg, BUDGET.frame))
        print("[perf]   module                         calls  per tick/frame   avg ms   p95 ms   max ms  errors")
        local warns = {}
        for i = 1, math.min(20, #list) do
            local k, e = list[i][1], list[i][2]
            local per = k:find("^tick:") and e.n / ticks or (k:find("^frame:") and e.n / frames or nil)
            local q = p95(e)
            print(string.format("[perf]   %-30s %6d  %14s  %7.3f  %7.3f  %7.3f  %6d", k, e.n, per and string.format("%.2f", per) or "event", e.sum / e.n, q, e.max, e.err or 0))
            if q > BUDGET.p95 then warns[#warns + 1] = string.format("%s p95 %.3f ms > %.2f", k, q, BUDGET.p95) end
            if (e.err or 0) > 0 then warns[#warns + 1] = string.format("%s: %d error(s) - see /eclipse health", k, e.err) end
        end
        if tick_avg > BUDGET.tick then warns[#warns + 1] = string.format("whole script per tick %.3f ms > %.1f", tick_avg, BUDGET.tick) end
        if frame_avg > BUDGET.frame then warns[#warns + 1] = string.format("whole script per frame %.3f ms > %.1f", frame_avg, BUDGET.frame) end
        for _, w in ipairs(warns) do print("[perf] WARN " .. w) end
        if #warns == 0 then print("[perf] all modules within budget") end
    end, 99)
    -- health: модули, ошибки, хуки
    RAP.cmd.health = function()
        local total = 0
        for _, list in pairs(RAP.hooks) do total = total + #list end
        print(string.format("[health] %s | hooks: %d | ragebot items found: %d tabs", RAP.VERSION, total, RAP.ref.tabs.min_damage or 0))
        local any = false
        for k, e in pairs(U.errors) do any = true; print(string.format("[health] ERROR %-28s x%d  last: %s", k, e.n, tostring(e.msg):sub(1, 90))) end
        if not any then print("[health] all modules OK (no errors)") end
        for _, m in ipairs(RAP.ref.missing) do print("[health] missing cheat item: " .. m) end
    end
    -- db: версия схемы, размеры, сброс частей
    local PARTS = { strategy = "rap2_strat", ai = "rap2_ai", evo = "rap2_evo", journal = "rap2_journal", ajournal = "rap2_ajournal", reports = "rap2_reports",
        widgets = "rap2_widgets", cfg = "rap2_cfg", decisions = "rap2_decisions", deaths = "rap2_deaths" }
    RAP.cmd.db = function(arg)
        local part = arg and arg:match("^reset%s+(%S+)")
        if part then
            if not PARTS[part] then print("[db] unknown part, use: " .. table.concat((function() local t = {}; for k in pairs(PARTS) do t[#t + 1] = k end; return t end)(), ", ")); return end
            -- в памяти тоже: иначе ближайшее автосохранение записывало старые данные обратно
            local rs = ({ widgets = function() if RAP.wid then RAP.wid.reset() end end, cfg = RAP.cfg_reset })[part] or RAP.resets[part]
            if rs then U.safe("db reset " .. part, rs) end
            RAP.store.set(PARTS[part], nil)
            print("[db] " .. part .. " cleared")
            return
        end
        local meta = RAP.store.get("rap2_meta") or {}
        print(string.format("[db] schema %s (script expects %d)", tostring(meta.schema), RAP.CFG.db.schema))
        for name, key in pairs(PARTS) do
            local ok, raw = pcall(function() return db[key] end)
            print(string.format("[db] %-9s %6.1f KB", name, (ok and type(raw) == "string") and #raw / 1024 or 0))
        end
        local io = RAP.store.io
        if io.t then
            print(string.format("[db] last save %.0f s ago (%s): %d key(s) written, %d unchanged skipped, %.0f KB, %.1f ms",
                globals.realtime - io.t, io.force and "full" or "changed only", io.n, io.skipped, io.bytes / 1024, io.ms))
        end
        print("[db] reset a part: /eclipse db reset <part>")
    end
    -- версия схемы: записывается при загрузке; при несовпадении - предупреждение (миграции выполняются в модулях)
    do
        local meta = RAP.store.get("rap2_meta") or {}
        if meta.schema and meta.schema ~= RAP.CFG.db.schema then
            print(string.format("[db] schema %s -> %d: data migrated by modules on load", tostring(meta.schema), RAP.CFG.db.schema))
        end
        RAP.store.set("rap2_meta", { schema = RAP.CFG.db.schema, version = RAP.VERSION })
    end
end

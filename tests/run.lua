-- Офлайн-тесты логики ECLIPSE: luajit tests/run.lua (из корня репозитория). Нужен lua-cjson.
-- Каждый тест загружает скрипт в свежем окружении заглушек (tests/stubs.lua) и проверяет поведение модулей.
package.path = "tests/?.lua;" .. package.path
local S = require("stubs")
local PATH = arg and arg[1] or "eclipse.lua"
local vec = S.vec

local tests, failed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function no_errors(E, allow)
    for k, e in pairs(E.RAP.U.errors) do
        if not (allow and k:find(allow)) then error("module error " .. k .. ": " .. tostring(e.msg), 2) end
    end
end
local function has_line(E, pat)
    for _, l in ipairs(E.out) do if l:find(pat) then return true end end
    return false
end

test("loads, runs every phase without module errors", function()
    local E = S.load(PATH)
    E.fire("createmove", { choked_commands = 0, view_angles = vec() })
    E.fire("render"); E.fire("level_init"); E.fire("round_start")
    assert(E.RAP.VERSION:find("^2%.0 beta"), "version string")
    no_errors(E)
end)

test("selftest: 0 FAIL, release clears every override", function()
    local E = S.load(PATH)
    E.RAP.own("ex.dt", E.RAP.ref.dt, true)
    E.console("/eclipse selftest release")
    assert(has_line(E, "%[FAIL%] 0"), "selftest has FAILs")
    assert(next(E.RAP.own_list()) == nil, "own overrides left after release")
    no_errors(E)
end)

test("console: own commands swallowed, others passed to the game", function()
    local E = S.load(PATH)
    assert(E.console("/eclipse help") == false)
    assert(E.console("say hi") == nil)
    for _, c in ipairs({ "health", "why", "db", "decisions", "strat", "ai", "evo", "report", "coach", "deaths", "shots", "peek", "cfg", "save" }) do
        E.console("/eclipse " .. c)
    end
    no_errors(E)
end)

test("arbiter: highest prio wins, false keeps yours, no vote releases", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    local P = RAP.ref.rage.hitchance
    RAP.vote("hitchance", 60, 10, "a"); RAP.vote("hitchance", 70, 20, "b"); RAP.vote("hitchance", 50, 15, "c")
    assert(RAP.arb.votes.hitchance.value == 70)
    RAP.arb.commit()
    assert(P.cur():get() == 70 and RAP.arb.why.hitchance.src == "b")
    assert(RAP.arb.votes.hitchance == nil, "votes must not leak into the next tick")
    RAP.arb.commit()
    assert(P.cur().ov == nil and not RAP.arb.owned.hitchance, "override not released")
    RAP.vote("body_aim", false, 40, "keep"); RAP.arb.commit()
    assert(RAP.arb.why.body_aim.value == nil)
end)

test("map change: Auto OS / on-shot / defensive timers do not stick", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    E.T.now = 2000
    E.hook("enemy_fire", "onshot")({ get_index = function() return 4 end }, 2000)
    RAP.aa.def = 2000
    E.fire("level_init")
    E.T.now = 5
    assert(RAP.aa.def == nil, "AA.def not reset")
    assert(next(RAP.ragev.last_shot) == nil, "last_shot not reset")
end)

test("decisions: worse strategy switch is rolled back and blocked", function()
    local E = S.load(PATH)
    local DL, ST = E.RAP.dl, E.RAP.strat
    local key = "x:1|Scout|jitter"
    ST.T[5] = { idx = 5, pid = "x:1", key = key, wg = "Scout", aat = "jitter", arm = 4, n = 0, streak = 0, state = "PROBING", relearn = 0 }
    DL.record("strat", key, 1, 4, "test", { pre_m = 0.6, pre_v = 0.005, lf = "Default", lt = "Prefer safe" })
    for _ = 1, 10 do DL.outcome("strat", key, 4, false, 1) end
    assert(ST.T[5].arm == 1, "not rolled back")
    assert(DL.blocked("strat", key, 4), "not blocked")
    assert(DL.log[#DL.log].verdict == "worse" and DL.log[#DL.log].rolled)
end)

test("decisions: AA profile rollback, better verdict, pool guard", function()
    local E = S.load(PATH)
    local AI, DL = E.RAP.ai, E.RAP.dl
    AI.cur.stand = 9
    AI.set("stand", 10, "best", "test")
    for _ = 1, 10 do DL.outcome("aa", "stand", 10, false, 1) end
    assert(AI.cur.stand == 9 and DL.blocked("aa", "stand", 10))
    AI.set("move", 11, "best"); AI.set("move", 12, "best", "x")
    for _ = 1, 10 do DL.outcome("aa", "move", 12, true, 1) end
    assert(AI.cur.move == 12 and DL.log[#DL.log].verdict == "better")
    E.RAP.cfg["ai.pool"]:set({ "Native wide" })
    assert(DL.rb.aa({ key = "move", from = 9, to = 12, lt = "x" }) == false, "rollback to a removed profile")
end)

test("decisions: per-round exploration / back to best are not verified decisions", function()
    local E = S.load(PATH)
    local AI, DL = E.RAP.ai, E.RAP.dl
    AI.cur.stand = 9
    AI.set("stand", 10, "best", "62% vs 50%, confident 85% better")
    assert(DL.open["aa|stand"], "real decision not recorded")
    AI.set("stand", 11, "explore", "exploration")
    AI.set("stand", 10, "best", "back to best")
    AI.set("stand", 12, "best", "removed from pool")
    local d = DL.open["aa|stand"]
    assert(d and d.to == 10 and d.why:find("confident"), "real decision was superseded by a temporary switch")
end)

test("decisions: phase shift that makes the enemy hit more is rolled back", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    RAP.W.learn = function() return true end
    local ai = E.hook("enemy_shot", "ai")
    local function shot(kind, flip)
        ai(kind, { pid = "x:9", w = 1, dist = 10, hitgroup = 1, ctx = { group = "stand", profile = 9, applied = true, flip = flip, wc = "rifle" } })
    end
    E.T.now = 1000
    for _ = 1, 6 do shot("hit", true); shot("dodge", false) end
    assert(RAP.ai.sm["x:9"].inv == true, "phase shift did not switch on")
    E.T.now = 1100
    for _ = 1, 8 do shot("hit", nil) end
    assert(RAP.ai.sm["x:9"].inv == false, "phase shift not rolled back")
    assert(RAP.dl.blocked("phase", "x:9", true))
end)

test("strategy: age decay is not re-applied on every load", function()
    local E = S.load(PATH)
    local day = 86400
    E.DB.rap2_strat = json.stringify({ ctx = { ["x:1|Scout|jitter"] = { ts = 1759000000 - 7 * day,
        arms = { { h = 8, m = 8, w2 = 16, att = 16, hits = 8, hh = 0, bh = 8, corr = 0, mis = 0, pe = 0 } } } } })
    local DBC = E.DB.rap2_strat
    local function load_h(unix)
        local E2 = S.load(PATH)
        E2.DB.rap2_strat = DBC
        E2.T.unix = unix
        -- повторная загрузка скрипта с той же базой (свежее окружение получает копию базы)
        local f = assert(io.open(PATH, "rb")); local src = f:read("*a"); f:close()
        local RAP = assert(loadstring(src .. "\nreturn RAP", "=eclipse"))()
        RAP.save_all(true)
        DBC = E2.DB.rap2_strat
        return RAP.strat.ctx["x:1|Scout|jitter"].arms[1].h
    end
    local h1 = load_h(1759000000)               -- 7 дней: x0.5
    local h2 = load_h(1759000000 + 600)         -- через 10 минут: почти без изменений
    assert(math.abs(h1 - 4) < 0.05, "first decay " .. h1)
    assert(math.abs(h2 - h1) < 0.05, "decay applied twice: " .. h1 .. " -> " .. h2)
end)

test("store: scheduled save writes only changed keys, shutdown writes all", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    RAP.save_all(true)
    local n_all = RAP.store.io.n
    RAP.save_all(false)
    assert(RAP.store.io.n == 0, "unchanged keys written")
    RAP.tele.apush({ g = "stand", p = 1, k = "dodge" })
    RAP.save_all(false)
    assert(RAP.store.io.n == 1, "expected only rap2_ajournal")
    assert(n_all >= 6)
end)

test("store: oversize rejection is cleared by the next good save", function()
    local E = S.load(PATH)
    local St = E.RAP.store
    local lim = St.LIMIT
    St.LIMIT = 10
    St.set("rap2_test_big", { x = string.rep("a", 100) })
    assert(St.rejected.rap2_test_big)
    St.LIMIT = lim
    St.set("rap2_test_big", { x = 1 })
    assert(St.rejected.rap2_test_big == nil)
end)

test("ai: per-enemy stats keep the freshest enemies", function()
    local E = S.load(PATH)
    local AI = E.RAP.ai
    for i = 1, 60 do
        local pid = "x:" .. i
        AI.en[pid] = { stand = { [9] = { n = 1, sum = 1 } }, move = {}, slow = {}, air = {}, duck = {} }
        AI.ets[pid] = 1000 + i
    end
    E.RAP.save_all(true)
    local d = json.parse(E.DB.rap2_ai)
    local n = 0
    for _ in pairs(d.en) do n = n + 1 end
    assert(n == 48, "kept " .. n)
    assert(d.en["x:60"] and d.en["x:13"] and not d.en["x:12"], "not the freshest 48")
end)

test("dormant: deterministic multipoint, stale record ignored", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    local enemy = S.player({ idx = 3, is_dormant = function() return true end, get_origin = function() return vec(1000, 0, 0) end,
        get_network_state = function() return 2 end })
    local wpn = { m_flNextPrimaryAttack = 0, m_iClip1 = 5, get_spread = function() return 0.002 end, get_inaccuracy = function() return 0.004 end,
        get_weapon_index = function() return 40 end, get_weapon_info = function() return { weapon_type = 5 } end }
    local me = S.player({ idx = 1, m_MoveType = 2, m_flNextAttack = 0, m_bIsScoped = true, m_aimPunchAngle = vec(),
        get_player_weapon = function() return wpn end, get_eye_position = function() return vec(0, 0, 64) end, get_origin = function() return vec() end })
    entity.get_local_player = function() return me end
    entity.get_players = function(_, _, cb) cb(enemy) end
    local zs = {}
    utils.trace_bullet = function(_, _, to, filter) zs[#zs + 1] = to.z; assert(filter(enemy) == true); return to.z == 40 and 80 or 30 end
    RAP.cfg["dor.on"]:set(true)
    local cmd = { choked_commands = 0, view_angles = vec() }
    E.fire("createmove", cmd)
    assert(table.concat(zs, ",") == "50,40,32", "points " .. table.concat(zs, ","))
    assert(cmd.in_attack == true and RAP.dormant.best.pos.z == 40)
    E.T.real, E.T.tick = E.T.real + 5, E.T.tick + 3
    cmd = { choked_commands = 0, view_angles = vec() }
    E.fire("createmove", cmd)
    assert(cmd.in_attack == nil and RAP.dormant.best == nil, "stale dormant record was used")
end)

test("AI Peek: scan spread over ticks finds the spot", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    RAP.CFG.peek.scan_ms = 0                     -- одно направление за тик: детерминированно
    local enemy = S.player({ idx = 3, get_origin = function() return vec(1000, 0, 0) end,
        get_hitbox_position = function(_, id) return vec(1000, 0, 40 + id) end, get_player_weapon = function() return nil end })
    local wpn = { m_flNextPrimaryAttack = 0, m_iClip1 = 5, get_weapon_index = function() return 7 end }
    local me = S.player({ idx = 1, m_MoveType = 2, m_flNextAttack = 0, get_player_weapon = function() return wpn end,
        get_eye_position = function() return vec(0, 0, 64) end, get_origin = function() return vec() end })
    function me.simulate_movement()
        local yaw = math.rad(RAP.W.cmd.view_angles.y)
        local s = { origin = vec(), velocity = vec(250, 0, 0), view_offset = 64 }
        function s.think() s.origin = s.origin + vec(math.cos(yaw) * 4, math.sin(yaw) * 4, 0) end
        return s
    end
    entity.get_local_player = function() return me end
    entity.get_players = function(_, _, cb) cb(enemy) end
    utils.trace_bullet = function(_, from) if from.y > 30 then return 60, { entity = enemy } end return 0, {} end
    RAP.cfg["peek.on"]:set(true); RAP.cfg["peek.key"]:set(true); RAP.cfg["peek.dirs"]:set(8)
    local scans = 0
    for _ = 1, 12 do
        E.T.now, E.T.tick = E.T.now + 1 / 64, E.T.tick + 1
        local cmd = { choked_commands = 0, view_angles = vec(), forwardmove = 0, sidemove = 0 }
        E.fire("createmove", cmd)
        assert(cmd.view_angles.y == 0, "view angles not restored after scan")
        if RAP.peek.PK.reason == "scanning..." then scans = scans + 1 end
        if RAP.peek.PK.st == 1 then break end
    end
    assert(scans >= 2, "scan was not spread over ticks")
    assert(RAP.peek.PK.st == 1 and RAP.peek.PK.cand.dmg == 60, "no peek: " .. tostring(RAP.peek.PK.reason))
end)

test("hitchance base: menu value used only when it differs from the override", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    local it = RAP.ref.rage.hitchance.cur()
    it.get = function(s) return s.v end            -- модель: get() = значение меню
    it.v = 60
    assert(RAP.U.hc_cur() == 60)
    it.ov = 70
    assert(RAP.U.hc_cur() == 60)
    it.v = 70
    assert(RAP.U.hc_cur() == nil)
end)

test("selftest reports whether your hitchance is readable under override", function()
    local E = S.load(PATH)
    local it = E.RAP.ref.rage.hitchance.cur()
    it.get = function(s) return s.v end
    it.v, it.ov = 60, 72
    E.console("/eclipse selftest")
    assert(has_line(E, "readable under override: yes: menu 60, override 72"))
end)

test("render after an enemy entity became invalid: no module errors, stale snapshot dropped", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    local gone = false
    local function chk() if gone then error("entity is invalid.", 0) end end
    local enemy = S.player({ idx = 3, get_origin = function() chk(); return vec(500, 0, 0) end,
        get_anim_state = function() chk(); return { eye_yaw = 10, abs_yaw = 0 } end })
    enemy.is_alive = function() chk(); return true end
    enemy.get_index = function() return 3 end
    local me = S.player({ idx = 1, get_player_weapon = function() return nil end, get_eye_position = function() return vec(0, 0, 64) end,
        get_origin = function() return vec() end })
    entity.get_local_player = function() return me end
    entity.get_players = function(_, _, cb) cb(enemy) end
    entity.get_threat = function() return enemy end
    RAP.cfg["vis.debug"]:set(true)
    for _ = 1, 20 do E.T.tick = E.T.tick + 1; E.fire("createmove", { choked_commands = 0, view_angles = vec() }) end
    gone = true
    E.fire("render")                                -- тот же кадр: снимок свежий, сущность уже недействительна
    E.T.real = E.T.real + 1
    E.fire("render")                                -- createmove не шел 1 с: снимок сбрасывается
    assert(#RAP.W.enemies == 0 and RAP.W.threat == nil, "stale snapshot kept")
    for k, e in pairs(RAP.U.errors) do if k:find("^frame") or k:find("esp") then error(k .. ": " .. tostring(e.msg)) end end
end)

-- ideal tick: общая подготовка сцены
local function it_scene()
    local E = S.load(PATH)
    local RAP = E.RAP
    local pos = vec(0, 0, 0)
    local wpn = { m_flNextPrimaryAttack = 0, m_iClip1 = 5, get_weapon_index = function() return 11 end }   -- auto
    local me = S.player({ idx = 1, m_MoveType = 2, get_player_weapon = function() return wpn end,
        get_eye_position = function() return pos + vec(0, 0, 64) end, get_origin = function() return pos:clone() end })
    local enemy = S.player({ idx = 3, get_origin = function() return vec(800, 0, 0) end })
    local X = { charge = 1, tp = 0, fc = 0, allow = {}, exposed = false }
    rage.exploit = { get = function() return X.charge end, force_teleport = function() X.tp = X.tp + 1 end,
        force_charge = function() X.fc = X.fc + 1 end, allow_charge = function(_, v) X.allow[#X.allow + 1] = v end }
    entity.get_local_player = function() return me end
    entity.get_players = function(_, _, cb) cb(enemy) end
    entity.get_threat = function(h) if h then return X.exposed and enemy or nil end return enemy end
    RAP.ref.dt:set(true)
    RAP.cfg["it.on"]:set(true); RAP.cfg["it.key"]:set(true)
    local function tick() E.T.tick = E.T.tick + 1; E.T.now = E.T.now + 1 / 64; E.T.real = E.T.real + 1 / 64
        local cmd = { choked_commands = 0, view_angles = vec(), forwardmove = 0, sidemove = 0 }
        E.fire("createmove", cmd); return cmd end
    local function shoot(dmg, hp) enemy.m_iHealth = hp
        E.fire("aim_fire", { id = E.T.tick, target = enemy, damage = dmg, hitchance = 80, hitgroup = 1 }) end
    return E, RAP, X, function(p2) pos = p2 end, tick, shoot
end

test("ideal tick: lethal shot -> teleport back next tick -> recharge only when safe -> ready", function()
    local E, RAP, X, setpos, tick, shoot = it_scene()
    tick()
    assert(RAP.it.st == "READY", RAP.it.st)
    setpos(vec(40, 0, 0)); X.exposed = true; tick()
    assert(RAP.it.st == "PEEK", RAP.it.st)
    shoot(120, 100)
    assert(RAP.it.st == "SHOT")
    local cmd = tick()                                  -- it.tp_off = 1
    assert(X.tp == 1, "no teleport")
    assert(RAP.it.st == "RETURN" and math.abs(cmd.move_yaw - 180) < 1 and cmd.forwardmove == 450, "not moving back to start")
    X.charge = 0; setpos(vec(2, 0, 0)); tick()
    assert(RAP.it.st == "RECHARGE", RAP.it.st)
    tick()
    assert(X.allow[#X.allow] == false, "charge must be blocked while exposed")
    X.exposed = false; tick()
    assert(X.allow[#X.allow] == true and X.fc >= 1, "no recharge in cover")
    X.charge = 1; tick()
    assert(RAP.it.st == "READY", RAP.it.st)
    local c = RAP.it.log[#RAP.it.log]
    assert(c and c.teleported and c.lethal and c.tp_tick - c.shot_tick == 1, "cycle not logged")
    E.console("/eclipse it")
    no_errors(E)
end)

test("ideal tick: non-lethal DT shot waits for the 2nd bullet before teleporting", function()
    local _, RAP, X, setpos, tick, shoot = it_scene()
    tick(); setpos(vec(40, 0, 0)); tick()
    shoot(40, 100)
    tick()
    assert(X.tp == 0 and RAP.it.st == "SHOT", "teleported before the 2nd DT bullet")
    shoot(40, 60)                                       -- вторая пуля DT
    tick()
    assert(X.tp == 1 and RAP.it.log ~= nil, "no teleport after the 2nd bullet")
    assert(RAP.it.cyc.shots == 2)
end)

test("ideal tick: releasing the key releases charge block and peek assist", function()
    local E, RAP, X, setpos, tick, shoot = it_scene()
    tick(); setpos(vec(40, 0, 0)); X.exposed = true; tick()
    shoot(120, 100); tick(); X.charge = 0; tick(); tick()
    assert(RAP.it.blocked == true)
    RAP.cfg["it.key"]:set(false); tick()
    assert(RAP.it.blocked == false and RAP.it.st == "OFF", "not released")
    assert(RAP.own_list()["it.ap"] == nil, "peek assist still owned")
    no_errors(E)
end)

test("shot pressure: tick-based levels, stall log with causes, Delay Shot off on every found path", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    local wpn = { m_flNextPrimaryAttack = 0, m_iClip1 = 5, get_weapon_index = function() return 7 end }
    local me = S.player({ idx = 1, m_flNextAttack = 0, get_player_weapon = function() return wpn end,
        get_eye_position = function() return vec(0, 0, 64) end, get_origin = function() return vec() end })
    local enemy = S.player({ idx = 3, is_visible = function() return true end, get_origin = function() return vec(500, 0, 0) end })
    entity.get_local_player = function() return me end
    entity.get_players = function(_, _, cb) cb(enemy) end
    entity.get_threat = function() return enemy end
    local function tick() E.T.tick = E.T.tick + 1; E.T.now = E.T.now + 1 / 64; E.fire("createmove", { choked_commands = 0, view_angles = vec() }) end
    for _ = 1, 3 do tick() end
    assert(RAP.pressure.level == 1, "relax not after 3 ticks: " .. RAP.pressure.level)
    for _ = 1, 3 do tick() end
    assert(RAP.pressure.level == 2, "release not after 6 ticks")
    E.fire("aim_fire", { id = 1, target = enemy, damage = 50 })
    assert(#RAP.pressure.log == 1 and RAP.pressure.log[1].outcome == "shot" and RAP.pressure.log[1].level == 2)
    local n_off = 0
    for key, it in pairs(E.found) do if key:find("Delay Shot") and it.ov == false then n_off = n_off + 1 end end
    assert(n_off >= 12, "Delay Shot not overridden on all paths: " .. n_off)
    E.console("/eclipse stalls")
    assert(has_line(E, "%[stalls%] 1 stalls"))
    no_errors(E)
end)

local function rage_scene(widx, enemy_fields)
    local E = S.load(PATH)
    local RAP = E.RAP
    local wpn = { m_flNextPrimaryAttack = 0, m_iClip1 = 5, get_weapon_index = function() return widx end, get_weapon_info = function() return nil end }
    local me = S.player({ idx = 1, get_player_weapon = function() return wpn end, get_eye_position = function() return vec(0, 0, 64) end,
        get_origin = function() return vec() end })
    local enemy = S.player(enemy_fields)
    enemy.get_origin = enemy.get_origin or function() return vec(500, 0, 0) end
    entity.get_local_player = function() return me end
    entity.get_players = function(_, _, cb) cb(enemy) end
    entity.get_threat = function() return enemy end
    local function tick() E.T.tick = E.T.tick + 1; E.T.now = E.T.now + 1 / 64; E.fire("createmove", { choked_commands = 0, view_angles = vec() }) end
    return E, RAP, tick, enemy
end

test("head policy: standing enemy -> body aim Default at prio 65 over strategy prefer body", function()
    local E, RAP, tick = rage_scene(11, { idx = 3, m_vecVelocity = vec(0, 0, 0) })
    RAP.CFG.strategy.arms = "6"                          -- стратегия хочет тело
    for _ = 1, 4 do tick() end
    local w = RAP.arb.why.body_aim
    assert(w and w.value == "Default" and tostring(w.src):find("^head: enemy standing"), "body_aim " .. tostring(w and w.value) .. " <- " .. tostring(w and w.src))
    assert(RAP.ragev.head_why:find("^head allowed"))
    no_errors(E)
end)

test("head policy: lethal body (auto, 40 hp, armor) forces body; pistol at 40 hp does not", function()
    local E, RAP, tick = rage_scene(11, { idx = 3, m_iHealth = 40, m_ArmorValue = 100, m_vecVelocity = vec(0, 0, 0) })
    for _ = 1, 4 do tick() end
    local w = RAP.arb.why.body_aim
    assert(w.value == "Force" and tostring(w.src):find("lethal body"), "auto: " .. tostring(w.value) .. " <- " .. tostring(w.src))
    local E2, RAP2, tick2 = rage_scene(2, { idx = 3, m_iHealth = 40, m_ArmorValue = 100, m_vecVelocity = vec(0, 0, 0) })
    for _ = 1, 4 do tick2() end
    local w2 = RAP2.arb.why.body_aim
    assert(not (w2.value == "Force"), "pistol forced body at 40 hp with armor")
    no_errors(E); no_errors(E2)
end)

test("strategy reward: share of target HP (kill = 1), old hit stats only a weak prior", function()
    local E = S.load(PATH)
    local ST = E.RAP.strat
    local rec = { idx = 5, pid = "x:1", hp0 = 100, ctx = { arm = 2, key = "x:1|Scout|jitter", wg = "Scout", aatk = "jitter", attr = 1 } }
    E.hook("our_ack", "strategy")(rec, { state = nil, damage = 100, hitgroup = 1 })
    local x = ST.ctx["x:1|Scout|jitter"].arms[2]
    assert(math.abs(x.vh - 1) < 1e-6 and math.abs(x.vm) < 1e-6, "kill must be reward 1")
    rec.hp0 = 100
    E.hook("our_ack", "strategy")(rec, { state = nil, damage = 25, hitgroup = 3 })
    assert(math.abs(x.vh - (0.985 + 0.25)) < 0.01, "body 25 dmg must be 0.25: " .. x.vh)
    -- голова (2 убийства) против тела с теми же попаданиями: оценка головы выше
    local key = "x:2|Auto|jitter"
    local function ack(arm, dmg) E.hook("our_ack", "strategy")({ idx = 6, pid = "x:2", hp0 = 100, ctx = { arm = arm, key = key, wg = "Auto", aatk = "jitter", attr = 1 } },
        { state = nil, damage = dmg, hitgroup = arm == 2 and 1 or 3 }) end
    for _ = 1, 3 do ack(2, 100); ack(6, 30) end
    assert(ST.post(key, 2, "Auto", "jitter") > ST.post(key, 6, "Auto", "jitter"), "head kills must beat body chip damage")
end)

test("console_exec text is sanitized (trashtalk)", function()
    local E = S.load(PATH)
    local RAP = E.RAP
    local me = S.player({ idx = 1 })
    local vic = S.player({ idx = 2 })
    entity.get_local_player = function() return me end
    entity.get = function(id) if id == 1 then return me elseif id == 2 then return vic end end
    RAP.cfg["misc.trash"]:set(true)
    RAP.cfg["misc.trash_list"]:set('ez;quit\nkill"x')
    E.fire("player_death", { attacker = 1, userid = 2 })
    assert(E.last_exec and not E.last_exec:find("[;\"%c]"), "unsafe console_exec: " .. tostring(E.last_exec))
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then io.write("PASS  ", t.name, "\n") else failed = failed + 1; io.write("FAIL  ", t.name, "\n      ", tostring(err), "\n") end
end
io.write(string.format("%d tests, %d failed\n", #tests, failed))
os.exit(failed == 0 and 0 or 1)

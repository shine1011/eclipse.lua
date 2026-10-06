-- Заглушки API Neverlose для офлайн-тестов логики ECLIPSE (luajit tests/run.lua).
-- Это НЕ эмуляция чита: только то, что нужно, чтобы скрипт загрузился и модули можно было вызывать напрямую.
-- Поведение в игре проверяется только в игре (см. чек-листы в CHANGELOG.md).
local M = {}

-- vector с арифметикой и методами, которые использует скрипт
local V = {}
V.__index = V
local function vec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
V.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__add = function(a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__mul = function(a, k) return vec(a.x * k, a.y * k, a.z * k) end
function V:dist(o) local d = self - o; return math.sqrt(d.x ^ 2 + d.y ^ 2 + d.z ^ 2) end
function V:dist2d(o) local d = self - o; return math.sqrt(d.x ^ 2 + d.y ^ 2) end
function V:to(o) return o - self end
function V:clone() return vec(self.x, self.y, self.z) end
function V:angles() return vec(0, math.deg(math.atan2(self.y, self.x)), 0) end
function V:length2d() return math.sqrt(self.x ^ 2 + self.y ^ 2) end
function V:lengthsqr() return self.x ^ 2 + self.y ^ 2 + self.z ^ 2 end
M.vec = vec

-- объект, у которого любое поле - снова такой объект, а вызов возвращает nil (render, cvar, antiaim)
local function magic()
    return setmetatable({}, {
        __index = function(t, k) local v = magic(); rawset(t, k, v); return v end,
        __call = function() return nil end,
    })
end

local function item(name, def, list)
    local it = { nm = name, v = def, list_ = list, ov = nil }
    function it:get() if self.ov ~= nil then return self.ov end return self.v end
    function it:get_override() return self.ov end
    function it:set(v) self.v = v end
    function it:override(v) self.ov = v end
    function it:name() return self.nm end
    function it:list() return self.list_ end
    function it:tooltip() end
    function it:set_callback(fn) self.cb = fn end
    function it:visibility() end
    return it
end

-- Новое окружение: свежие глобалы чита, база, обработчики событий. Возвращает env (время, база, события).
function M.env()
    local E = { T = { now = 100, real = 1000, tick = 6400, unix = 1759000000 }, DB = {}, handlers = {}, found = {} }
    local T = E.T
    local group = {}
    group.__index = group
    function group:switch(n, d) return item(n, d) end
    function group:slider(n, _, _, d) return item(n, d) end
    function group:combo(n, l) return item(n, l and l[1], l) end
    function group:selectable(n, l) return item(n, {}, l) end
    function group:color_picker(n, d) return item(n, d) end
    function group:input(n, d) return item(n, d) end
    function group:button(n) return item(n) end
    function group:label(n) return item(n) end
    _G.ui = {
        create = function() return setmetatable({}, group) end,
        find = function(...)
            local key = table.concat({ ... }, "/")
            if not E.found[key] then
                local last = select(select("#", ...), ...)
                local list
                if last == "Safe Points" or last == "Body Aim" then list = { "Default", "Prefer", "Force" } end
                local def = 50
                if last == "Delay Shot" or last == "Enabled" then def = true end
                local h = E.find_hook and E.find_hook(key, last)
                if h == nil then h = item(last, def, list) end
                E.found[key] = h
            end
            return E.found[key] or nil
        end,
        get_binds = function() return {} end, get_alpha = function() return 0 end, get_style = function() return nil end,
        get_mouse_position = function() return vec() end, get_position = function() return vec() end, get_size = function() return vec() end,
    }
    _G.globals = setmetatable({}, { __index = function(_, k)
        if k == "curtime" then return T.now elseif k == "realtime" then return T.real elseif k == "tickcount" then return T.tick
        elseif k == "tickinterval" then return 1 / 64 elseif k == "frametime" or k == "absoluteframetime" then return 0.01 end
    end })
    local seed = 1
    local function lcg() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    _G.utils = {
        random_int = function(a, b) return a + math.floor(lcg() * (b - a + 1)) end,
        random_float = function(a, b) return a + lcg() * (b - a) end,
        console_exec = function(c) E.last_exec = c end, execute_after = function() end,
        net_channel = function() return { latency = { [0] = 0.03, [1] = 0.03 } } end,
        trace_line = function() return { fraction = 1 } end,
        trace_bullet = function() return 0, {} end,
    }
    _G.common = { get_unixtime = function() return T.unix end, get_timestamp = function() return os.clock() * 1000 end,
        get_username = function() return "u" end, get_date = function() return "00:00" end, set_clan_tag = function() end,
        is_button_down = function() return false end }
    _G.db = setmetatable({}, { __index = function(_, k) return E.DB[k] end, __newindex = function(_, k, v) E.DB[k] = v end })
    local okj, cjson = pcall(require, "cjson")
    assert(okj, "tests need lua-cjson (apt install lua-cjson)")
    _G.json = { stringify = cjson.encode, parse = cjson.decode }
    _G.events = setmetatable({}, { __index = function(t, k)
        local e = { set = function(_, fn) E.handlers[k] = E.handlers[k] or {}; table.insert(E.handlers[k], fn) end }
        rawset(t, k, e); return e
    end })
    _G.entity = { get_local_player = function() return nil end, get_threat = function() return nil end, get_players = function() return {} end,
        get = function() return nil end, get_game_rules = function() return nil end, get_entities = function() return {} end,
        get_player_resource = function() return nil end }
    _G.rage = { exploit = { get = function() return 0 end }, antiaim = magic() }
    _G.render = magic()
    _G.render.screen_size = function() return vec(1920, 1080) end
    _G.cvar = magic()
    _G.color = function(r, g, b, a) return { r = r or 0, g = g or 0, b = b or 0, a = a or 255 } end
    _G.vector = vec
    function E.fire(name, ...) local r; for _, fn in ipairs(E.handlers[name] or {}) do r = fn(...) end; return r end
    function E.console(line) return E.fire("console_input", line) end
    function E.hook(phase, name) for _, h in ipairs(E.RAP.hooks[phase] or {}) do if h.name == name then return h.fn end end end
    return E
end

-- Загружает скрипт в свежем окружении. print скрипта собирается в E.out (печать в консоль - только при verbose).
function M.load(path, verbose, setup)
    local E = M.env()
    if setup then setup(E, item) end
    E.out = {}
    local real_print = print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        E.out[#E.out + 1] = table.concat(parts, "\t")
        if verbose then real_print(...) end
    end
    local f = assert(io.open(path, "rb")); local src = f:read("*a"); f:close()
    local chunk = assert(loadstring(src .. "\nreturn RAP", "=eclipse"))
    E.RAP = chunk()
    E.restore_print = function() _G.print = real_print end
    return E
end

-- Простая сущность-игрок для сценариев
function M.player(t)
    t.get_index = t.get_index or function(s) return s.idx end
    t.is_alive = t.is_alive or function() return true end
    t.is_dormant = t.is_dormant or function() return false end
    t.get_name = t.get_name or function() return "p" .. tostring(t.idx) end
    t.is_bot = t.is_bot or function() return false end
    t.get_xuid = t.get_xuid or function() return tostring(7000 + t.idx) end
    t.get_player_weapon = t.get_player_weapon or function() return nil end
    t.m_iHealth = t.m_iHealth or 100
    t.m_flDuckAmount = t.m_flDuckAmount or 0
    t.m_fFlags = t.m_fFlags or 1
    t.m_vecVelocity = t.m_vecVelocity or vec()
    return t
end
return M

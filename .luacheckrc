-- luacheck для ECLIPSE: `luacheck .` из корня репозитория
std = "luajit"
max_line_length = false
files["*.lua"] = {}
globals = { "ui", "utils", "globals", "entity", "render", "events", "common", "db", "json", "files", "network",
    "panorama", "vector", "color", "esp", "rage", "cvar", "materials", "bit", "ffi", "client" }

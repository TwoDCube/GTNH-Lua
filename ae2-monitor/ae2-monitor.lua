-- AE2 Network Monitor for Prometheus

local events = require('events')
local component = require('component')
local computer = require('computer')
local event = require('event')

local CONFIG_PATH = "/etc/ae2-monitor.cfg"
local JOB_NAME    = "ae2_monitor"
local INSTANCE    = "main"
local PUSH_INTERVAL = 30

-----------------------------------------------------------------------
local function copyIfMissing(target, example)
    local f = io.open(target, "r")
    if f then f:close() return end
    local src = io.open(example, "r")
    if not src then return end
    local dst = io.open(target, "w")
    dst:write(src:read("*a"))
    src:close()
    dst:close()
end

local function loadConfig(path)
    copyIfMissing(path, path .. ".example")
    local f = io.open(path, "r")
    if not f then error("Config not found: " .. path) end
    local cfg = {}
    for line in f:lines() do
        local k, v = line:match('^%s*([%w_]+)%s*=%s*"(.-)"')
        if k then cfg[k] = v end
    end
    f:close()
    if not cfg.pushgateway_url then error("Missing: pushgateway_url") end
    if not cfg.username then error("Missing: username") end
    if not cfg.password then error("Missing: password") end
    return cfg
end

local function base64encode(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x)
        local r, byte = '', x:byte()
        for i = 8, 1, -1 do
            r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and '1' or '0')
        end
        return r
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
        return b:sub(c + 1, c + 1)
    end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

-----------------------------------------------------------------------
local config = loadConfig(CONFIG_PATH)
local authHeader = "Basic " .. base64encode(config.username .. ":" .. config.password)
local me = component.me_interface
local inet = component.internet
local fmt = string.format
local pushUrl = fmt("%s/metrics/job/%s/instance/%s",
    config.pushgateway_url, JOB_NAME, INSTANCE)
local headers = {
    ["Content-Type"] = "text/plain; version=0.0.4",
    ["Authorization"] = authHeader,
}

local function sanitize(s)
    if not s then return "" end
    return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end

local function safeCall(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function push(body)
    local handle
    local ok, err = pcall(function()
        handle = inet.request(pushUrl, body, headers)
        while true do
            local r, reason = handle.finishConnect()
            if r then break end
            if r == nil then error(reason or "conn failed") end
            os.sleep(0.05)
        end
        while handle.read(1024) do end
    end)
    if handle then pcall(handle.close) end
    if not ok then
        io.stderr:write("Push: " .. tostring(err) .. "\n")
    end
    return ok
end

-- Yield multiple times to force incremental GC to free objects
local function forceGC()
    for i = 1, 20 do os.sleep(0) end
end

local function loop()
    if events.needExit() then
        print("received exit command")
        return false
    end

    -- Aggressively yield to free previous cycle's garbage
    forceGC()

    local cycleOk, cycleErr = pcall(function()

    -- Phase 1: iterate allItems() → seen table (dedup) + totals
    local seen = {}
    local itemTypes = 0
    local totalItems = 0
    local ok = pcall(function()
        for item in me.allItems() do
            itemTypes = itemTypes + 1
            local size = item.size or 0
            totalItems = totalItems + size
            if size >= 1 then
                local key = (item.name or "") .. "|" .. (item.label or "") .. "|" .. (item.damage or 0)
                seen[key] = (seen[key] or 0) + size
            end
        end
    end)

    if not ok then
        seen = nil
        io.stderr:write("allItems failed\n")
        os.sleep(PUSH_INTERVAL)
        return true
    end

    -- Free iterator proxy objects before building strings
    forceGC()

    -- Phase 2: build body from seen table + other metrics
    local lines = {}
    local n = 0
    local function add(s) n = n + 1 lines[n] = s end

    add("# HELP ae2_power_injection Average power injection (AE/t)")
    add("# TYPE ae2_power_injection gauge")
    add(fmt("ae2_power_injection %.2f", safeCall(me.getAvgPowerInjection) or 0))
    add("# HELP ae2_power_usage Average power usage (AE/t)")
    add("# TYPE ae2_power_usage gauge")
    add(fmt("ae2_power_usage %.2f", safeCall(me.getAvgPowerUsage) or 0))
    add("# HELP ae2_power_stored Stored power (AE)")
    add("# TYPE ae2_power_stored gauge")
    add(fmt("ae2_power_stored %.2f", safeCall(me.getStoredPower) or 0))
    add("# HELP ae2_power_max Maximum power capacity (AE)")
    add("# TYPE ae2_power_max gauge")
    add(fmt("ae2_power_max %.2f", safeCall(me.getMaxStoredPower) or 0))

    add("# HELP ae2_item_types Total unique item types")
    add("# TYPE ae2_item_types gauge")
    add(fmt("ae2_item_types %d", itemTypes))
    add("# HELP ae2_items_total Total items stored")
    add("# TYPE ae2_items_total gauge")
    add(fmt("ae2_items_total %.0f", totalItems))

    add("# HELP ae2_item_count Items stored per type")
    add("# TYPE ae2_item_count gauge")
    for key, size in pairs(seen) do
        local name, label, damage = key:match("^(.-)|(.-)|(.+)$")
        add(fmt('ae2_item_count{name="%s",label="%s",damage="%s"} %.0f',
            sanitize(name), sanitize(label), damage, size))
    end
    seen = nil

    local cpus = safeCall(me.getCpus)
    if cpus then
        local t, b = 0, 0
        for _, cpu in ipairs(cpus) do
            t = t + 1
            if cpu.busy then b = b + 1 end
        end
        add("# HELP ae2_cpus_total Total crafting CPUs")
        add("# TYPE ae2_cpus_total gauge")
        add(fmt("ae2_cpus_total %d", t))
        add("# HELP ae2_cpus_busy Busy crafting CPUs")
        add("# TYPE ae2_cpus_busy gauge")
        add(fmt("ae2_cpus_busy %d", b))
    end

    local fluids = safeCall(me.getFluidsInNetwork)
    if fluids then
        add("# HELP ae2_fluid_amount Fluid stored (mB)")
        add("# TYPE ae2_fluid_amount gauge")
        for _, fluid in ipairs(fluids) do
            add(fmt('ae2_fluid_amount{name="%s",label="%s"} %.0f',
                sanitize(fluid.name), sanitize(fluid.label), fluid.amount or fluid.size or 0))
        end
    end

    -- Free seen before concat
    forceGC()

    local body = table.concat(lines, "\n") .. "\n"
    lines = nil
    local size = #body
    local pushed = push(body)
    body = nil

    if pushed then
        print(fmt("pushed %dB [free: %.0fK]", size, computer.freeMemory() / 1024))
    end

    end) -- end pcall

    if not cycleOk then
        io.stderr:write("Cycle failed: " .. tostring(cycleErr) .. "\n")
    end

    os.sleep(PUSH_INTERVAL)
    return true
end

local function main()
    print("AE2 Monitor starting")
    print(fmt("Free: %.0fK", computer.freeMemory() / 1024))
    print("Press 'q' to exit")

    events.initEvents()
    events.hookEvents()

    while loop() do end

    events.unhookEvents()
    print("AE2 Monitor stopped")
end

main()

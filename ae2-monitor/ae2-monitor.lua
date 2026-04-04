-- AE2 Network Monitor for Prometheus

local events = require('events')
local component = require('component')
local computer = require('computer')
local event = require('event')

local CONFIG_PATH    = "/etc/ae2-monitor.cfg"
local WATCHLIST_PATH = "/etc/ae2-watchlist.cfg"
local JOB_NAME       = "ae2_monitor"
local INSTANCE       = "main"
local PUSH_INTERVAL  = 30
local LGT_PORT       = 1337

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

local function loadWatchlist(path)
    copyIfMissing(path, path .. ".example")
    local f = io.open(path, "r")
    if not f then return {items = {}, fluids = {}} end
    local wl = {items = {}, fluids = {}}
    local section = "items"
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line == "" or line:sub(1, 1) == "#" then
            -- skip
        elseif line:match("^%[(.-)%]$") then
            section = line:match("^%[(.-)%]$")
        elseif section == "items" or section == "fluids" then
            if section == "fluids" then
                table.insert(wl.fluids, {name = line})
            else
                local parts = {}
                for part in line:gmatch("[^:]+") do
                    table.insert(parts, part)
                end
                if #parts >= 3 and tonumber(parts[#parts]) then
                    local damage = tonumber(table.remove(parts))
                    table.insert(wl.items, {name = table.concat(parts, ":"), damage = damage})
                else
                    table.insert(wl.items, {name = line})
                end
            end
        end
    end
    f:close()
    return wl
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
local watchlist = loadWatchlist(WATCHLIST_PATH)
local authHeader = "Basic " .. base64encode(config.username .. ":" .. config.password)
local me = component.me_interface
local inet = component.internet
local modem = component.modem

-- Cached fluid labels to keep series stable when fluids disappear
local fluidLabelCache = {}

-- LGT battery data from broadcast
local lgtEU = {current = nil, total = nil}
local function onBatteryData(_, _, _, _, _, msgType, current, total)
    if msgType == "lgt_battery" then
        lgtEU.current = current
        lgtEU.total = total
    end
end
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
    os.sleep(1)
end

local function loop()
    if events.needExit() then
        print("received exit command")
        return false
    end

    -- Aggressively yield to free previous cycle's garbage
    forceGC()

    local cycleOk, cycleErr = pcall(function()

    local lines = {}
    local n = 0
    local function add(s) n = n + 1 lines[n] = s end

    -- Power metrics
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

    -- Item metrics from watchlist (no allItems!)
    if #watchlist.items > 0 then
        add("# HELP ae2_item_count Items stored per type")
        add("# TYPE ae2_item_count gauge")
        for _, entry in ipairs(watchlist.items) do
            local filter = {name = entry.name}
            if entry.damage then filter.damage = entry.damage end
            local results = safeCall(me.getItemsInNetwork, filter)
            if results then
                local total = 0
                local label = ""
                for _, item in ipairs(results) do
                    total = total + (item.size or 0)
                    if item.label and item.label ~= "" then label = item.label end
                end
                add(fmt('ae2_item_count{name="%s",label="%s",damage="%s"} %.0f',
                    sanitize(entry.name), sanitize(label), entry.damage or 0, total))
            end
        end
    end

    forceGC()

    -- CPU metrics
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

    -- Fluid metrics from watchlist (filter client-side, API ignores filter param)
    if #watchlist.fluids > 0 then
        local allFluids = safeCall(me.getFluidsInNetwork)
        if allFluids then
            local fluidByName = {}
            for _, fluid in ipairs(allFluids) do
                if fluid.name then
                    fluidByName[fluid.name] = fluid
                end
            end
            allFluids = nil

            add("# HELP ae2_fluid_amount Fluid stored (mB)")
            add("# TYPE ae2_fluid_amount gauge")
            for _, entry in ipairs(watchlist.fluids) do
                local fluid = fluidByName[entry.name]
                local amount = fluid and (fluid.amount or fluid.size or 0) or 0
                if fluid and fluid.label and fluid.label ~= "" then
                    fluidLabelCache[entry.name] = fluid.label
                end
                local label = fluidLabelCache[entry.name] or ""
                add(fmt('ae2_fluid_amount{name="%s",label="%s"} %.0f',
                    sanitize(entry.name), sanitize(label), amount))
            end
        end
    end

    -- LGT battery metrics from modem broadcast
    if lgtEU.current then
        add("# HELP lgt_eu_stored Current EU stored in LGT battery")
        add("# TYPE lgt_eu_stored gauge")
        add(fmt("lgt_eu_stored %.0f", lgtEU.current))
        add("# HELP lgt_eu_max Maximum EU capacity of LGT battery")
        add("# TYPE lgt_eu_max gauge")
        add(fmt("lgt_eu_max %.0f", lgtEU.total))
    end

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
    print(fmt("Watchlist: %d items, %d fluids", #watchlist.items, #watchlist.fluids))
    print(fmt("Listening for LGT broadcasts on port %d", LGT_PORT))
    print(fmt("Free: %.0fK", computer.freeMemory() / 1024))
    print("Press 'q' to exit")

    modem.open(LGT_PORT)
    event.listen("modem_message", onBatteryData)

    events.initEvents()
    events.hookEvents()

    while loop() do end

    event.ignore("modem_message", onBatteryData)
    modem.close(LGT_PORT)
    events.unhookEvents()
    print("AE2 Monitor stopped")
end

main()

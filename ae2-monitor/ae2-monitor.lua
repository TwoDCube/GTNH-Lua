-- AE2 Network Monitor for Prometheus
-- Collects metrics from AE2 ME network and pushes to Prometheus Pushgateway
--
-- Requires config file at /etc/ae2-monitor.cfg:
--   pushgateway_url = "http://pushgateway-dev.apps.okd4.home.zoltanszepesi.com"
--   username = "pushuser"
--   password = "yourpassword"

local events = require('events')
local component = require('component')
local computer = require('computer')
local event = require('event')

-----------------------------------------------------------------------
-- Configuration
-----------------------------------------------------------------------
local CONFIG_PATH     = "/etc/ae2-monitor.cfg"
local JOB_NAME        = "ae2_monitor"
local INSTANCE        = "main"
local PUSH_INTERVAL   = 30
local ITEM_MIN_COUNT  = 1

-----------------------------------------------------------------------
-- Load config from file
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
    print("Created " .. target .. " from example - please edit it")
end

local function loadConfig(path)
    copyIfMissing(path, path .. ".example")
    local f = io.open(path, "r")
    if not f then
        error("Config file not found: " .. path ..
            "\nCreate it with: pushgateway_url, username, password")
    end
    local cfg = {}
    for line in f:lines() do
        local key, value = line:match('^%s*([%w_]+)%s*=%s*"(.-)"')
        if key and value then
            cfg[key] = value
        end
    end
    f:close()

    if not cfg.pushgateway_url then error("Config missing: pushgateway_url") end
    if not cfg.username then error("Config missing: username") end
    if not cfg.password then error("Config missing: password") end

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
local fmt = string.format
local pushUrlAggregate = fmt("%s/metrics/job/%s/instance/%s",
    config.pushgateway_url, JOB_NAME, INSTANCE)
local pushUrlItems = fmt("%s/metrics/job/%s_items/instance/%s",
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
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

-- Build aggregate metrics (power, CPUs, fluids, item totals) - small payload
local function buildAggregateMetrics()
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

    -- Item totals (count only, no per-item strings)
    local itemTypes = 0
    local totalItems = 0
    local iter = safeCall(me.allItems)
    if iter then
        for item in iter do
            itemTypes = itemTypes + 1
            totalItems = totalItems + (item.size or 0)
        end
    end
    add("# HELP ae2_item_types Total unique item types")
    add("# TYPE ae2_item_types gauge")
    add(fmt("ae2_item_types %d", itemTypes))
    add("# HELP ae2_items_total Total items stored")
    add("# TYPE ae2_items_total gauge")
    add(fmt("ae2_items_total %.0f", totalItems))

    -- CPUs
    local cpus = safeCall(me.getCpus)
    local cpuTotal = 0
    local cpuBusy = 0
    if cpus then
        for _, cpu in ipairs(cpus) do
            cpuTotal = cpuTotal + 1
            if cpu.busy then cpuBusy = cpuBusy + 1 end
        end
    end
    add("# HELP ae2_cpus_total Total crafting CPUs")
    add("# TYPE ae2_cpus_total gauge")
    add(fmt("ae2_cpus_total %d", cpuTotal))
    add("# HELP ae2_cpus_busy Busy crafting CPUs")
    add("# TYPE ae2_cpus_busy gauge")
    add(fmt("ae2_cpus_busy %d", cpuBusy))

    -- Fluids
    local fluids = safeCall(me.getFluidsInNetwork)
    if fluids then
        local fluidTypes = 0
        add("# HELP ae2_fluid_amount Fluid stored (mB)")
        add("# TYPE ae2_fluid_amount gauge")
        for _, fluid in ipairs(fluids) do
            fluidTypes = fluidTypes + 1
            local amount = fluid.amount or fluid.size or 0
            add(fmt('ae2_fluid_amount{name="%s",label="%s"} %.0f',
                sanitize(fluid.name), sanitize(fluid.label), amount))
        end
        add("# HELP ae2_fluid_types Total fluid types")
        add("# TYPE ae2_fluid_types gauge")
        add(fmt("ae2_fluid_types %d", fluidTypes))
    end

    return table.concat(lines, "\n") .. "\n"
end

-- Build per-item metrics separately (large payload, own memory lifecycle)
local function buildItemMetrics()
    -- Phase 1: iterate and deduplicate into seen table
    local seen = {}
    local iter = safeCall(me.allItems)
    if not iter then return nil end

    for item in iter do
        local size = item.size or 0
        if size >= ITEM_MIN_COUNT then
            local key = (item.name or "") .. "|" .. (item.label or "") .. "|" .. (item.damage or 0)
            seen[key] = (seen[key] or 0) + size
        end
    end

    -- Yield to free iterator proxy objects
    os.sleep(0)

    -- Phase 2: build lines from seen table
    local lines = {}
    local n = 0
    lines[1] = "# HELP ae2_item_count Items stored per type"
    lines[2] = "# TYPE ae2_item_count gauge"
    n = 2

    for key, size in pairs(seen) do
        local name, label, damage = key:match("^(.-)|(.-)|(.+)$")
        n = n + 1
        lines[n] = fmt('ae2_item_count{name="%s",label="%s",damage="%s"} %.0f',
            sanitize(name), sanitize(label), damage, size)
    end
    seen = nil

    -- Yield to free seen table before concat
    os.sleep(0)

    local body = table.concat(lines, "\n") .. "\n"
    lines = nil
    return body
end

-- Use raw component.internet with explicit close() to prevent handle leaks
local inet = component.internet

local function pushMetrics(url, body)
    local handle
    local ok, err = pcall(function()
        handle = inet.request(url, body, headers)
        while true do
            local result, reason = handle.finishConnect()
            if result then break end
            if result == nil then error(reason or "connection failed") end
            os.sleep(0.05)
        end
        while handle.read(1024) do end
    end)
    if handle then pcall(handle.close) end
    if not ok then
        io.stderr:write("Push failed: " .. tostring(err) .. "\n")
    end
    return ok
end

local function loop()
    if events.needExit() then
        print("received exit command")
        return false
    end

    -- Phase 1: aggregate metrics (small, ~2KB)
    os.sleep(0)
    local ok, body = pcall(buildAggregateMetrics)
    if ok then
        pushMetrics(pushUrlAggregate, body)
        body = nil
    else
        io.stderr:write("Aggregate failed: " .. tostring(body) .. "\n")
    end

    -- Phase 2: per-item metrics (large, separate lifecycle)
    os.sleep(0)
    ok, body = pcall(buildItemMetrics)
    if ok and body then
        local size = #body
        local pushed = pushMetrics(pushUrlItems, body)
        body = nil
        os.sleep(0)
        if pushed then
            print(fmt("pushed %dB items [free: %.0fK]", size,
                computer.freeMemory() / 1024))
        end
    elseif not ok then
        io.stderr:write("Items failed: " .. tostring(body) .. "\n")
    end

    os.sleep(PUSH_INTERVAL)
    return true
end

local function main()
    print("AE2 Monitor starting")
    print("Pushgateway: " .. config.pushgateway_url)
    print("Interval: " .. PUSH_INTERVAL .. "s")
    print("Press 'q' to exit")

    events.initEvents()
    events.hookEvents()

    while loop() do end

    events.unhookEvents()
    print("AE2 Monitor stopped")
end

main()

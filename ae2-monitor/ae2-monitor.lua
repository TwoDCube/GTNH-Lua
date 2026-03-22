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
local inet = component.internet
local fmt = string.format

local urlAggregate = fmt("%s/metrics/job/%s/instance/%s",
    config.pushgateway_url, JOB_NAME, INSTANCE)
local urlItems = fmt("%s/metrics/job/%s_items/instance/%s",
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

local function push(url, body)
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

    os.sleep(0) -- yield for GC

    -- === Single allItems() pass: collect totals + deduped items ===
    local itemTypes = 0
    local totalItems = 0
    local seen = {}
    local iter = safeCall(me.allItems)
    if iter then
        for item in iter do
            itemTypes = itemTypes + 1
            local size = item.size or 0
            totalItems = totalItems + size
            if size >= ITEM_MIN_COUNT then
                local key = (item.name or "") .. "|" .. (item.label or "") .. "|" .. (item.damage or 0)
                seen[key] = (seen[key] or 0) + size
            end
        end
    end
    iter = nil
    os.sleep(0) -- free iterator proxies

    -- === Phase 1: push aggregate metrics (tiny, ~2KB) ===
    local agg = {
        "# HELP ae2_power_injection Average power injection (AE/t)",
        "# TYPE ae2_power_injection gauge",
        fmt("ae2_power_injection %.2f", safeCall(me.getAvgPowerInjection) or 0),
        "# HELP ae2_power_usage Average power usage (AE/t)",
        "# TYPE ae2_power_usage gauge",
        fmt("ae2_power_usage %.2f", safeCall(me.getAvgPowerUsage) or 0),
        "# HELP ae2_power_stored Stored power (AE)",
        "# TYPE ae2_power_stored gauge",
        fmt("ae2_power_stored %.2f", safeCall(me.getStoredPower) or 0),
        "# HELP ae2_power_max Maximum power capacity (AE)",
        "# TYPE ae2_power_max gauge",
        fmt("ae2_power_max %.2f", safeCall(me.getMaxStoredPower) or 0),
        "# HELP ae2_item_types Total unique item types",
        "# TYPE ae2_item_types gauge",
        fmt("ae2_item_types %d", itemTypes),
        "# HELP ae2_items_total Total items stored",
        "# TYPE ae2_items_total gauge",
        fmt("ae2_items_total %.0f", totalItems),
    }

    local cpus = safeCall(me.getCpus)
    if cpus then
        local cpuTotal, cpuBusy = 0, 0
        for _, cpu in ipairs(cpus) do
            cpuTotal = cpuTotal + 1
            if cpu.busy then cpuBusy = cpuBusy + 1 end
        end
        agg[#agg + 1] = "# HELP ae2_cpus_total Total crafting CPUs"
        agg[#agg + 1] = "# TYPE ae2_cpus_total gauge"
        agg[#agg + 1] = fmt("ae2_cpus_total %d", cpuTotal)
        agg[#agg + 1] = "# HELP ae2_cpus_busy Busy crafting CPUs"
        agg[#agg + 1] = "# TYPE ae2_cpus_busy gauge"
        agg[#agg + 1] = fmt("ae2_cpus_busy %d", cpuBusy)
    end

    local fluids = safeCall(me.getFluidsInNetwork)
    if fluids then
        agg[#agg + 1] = "# HELP ae2_fluid_amount Fluid stored (mB)"
        agg[#agg + 1] = "# TYPE ae2_fluid_amount gauge"
        for _, fluid in ipairs(fluids) do
            agg[#agg + 1] = fmt('ae2_fluid_amount{name="%s",label="%s"} %.0f',
                sanitize(fluid.name), sanitize(fluid.label), fluid.amount or fluid.size or 0)
        end
    end

    local aggBody = table.concat(agg, "\n") .. "\n"
    agg = nil
    push(urlAggregate, aggBody)
    aggBody = nil
    os.sleep(0) -- free aggregate data before building items

    -- === Phase 2: push per-item metrics ===
    local lines = {
        "# HELP ae2_item_count Items stored per type",
        "# TYPE ae2_item_count gauge",
    }
    local n = 2
    for key, size in pairs(seen) do
        local name, label, damage = key:match("^(.-)|(.-)|(.+)$")
        n = n + 1
        lines[n] = fmt('ae2_item_count{name="%s",label="%s",damage="%s"} %.0f',
            sanitize(name), sanitize(label), damage, size)
    end
    seen = nil
    os.sleep(0) -- free seen before concat

    local itemBody = table.concat(lines, "\n") .. "\n"
    lines = nil
    local itemSize = #itemBody
    local pushed = push(urlItems, itemBody)
    itemBody = nil

    if pushed then
        print(fmt("pushed %dB [free: %.0fK]", itemSize,
            computer.freeMemory() / 1024))
    end

    os.sleep(PUSH_INTERVAL)
    return true
end

local function main()
    print("AE2 Monitor starting")
    print("Pushgateway: " .. config.pushgateway_url)
    print("Interval: " .. PUSH_INTERVAL .. "s")
    print(fmt("Free: %.0fK", computer.freeMemory() / 1024))
    print("Press 'q' to exit")

    events.initEvents()
    events.hookEvents()

    while loop() do end

    events.unhookEvents()
    print("AE2 Monitor stopped")
end

main()

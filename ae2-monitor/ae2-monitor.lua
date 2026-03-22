-- AE2 Network Monitor for Prometheus
-- Collects metrics from AE2 ME network and pushes to Prometheus Pushgateway
--
-- Requires config file at /etc/ae2-monitor.cfg:
--   pushgateway_url = "http://pushgateway-dev.apps.okd4.home.zoltanszepesi.com"
--   username = "pushuser"
--   password = "yourpassword"

local events = require('events')
local component = require('component')
local event = require('event')
local internet = require('internet')

-----------------------------------------------------------------------
-- Configuration
-----------------------------------------------------------------------
local CONFIG_PATH     = "/etc/ae2-monitor.cfg"
local JOB_NAME        = "ae2_monitor"
local INSTANCE        = "main"
local PUSH_INTERVAL   = 30    -- seconds between metric pushes
local ITEM_MIN_COUNT  = 1     -- only report items with at least this many stored
local TRACK_FLUIDS    = true
local TRACK_ESSENTIA  = true

-----------------------------------------------------------------------
-- Load config from file
-----------------------------------------------------------------------
local function loadConfig(path)
    local f = io.open(path, "r")
    if not f then
        error("Config file not found: " .. path ..
            "\nCreate it with: pushgateway_url, username, password")
    end
    local cfg = {}
    for line in f:lines() do
        local key, value = line:match('^%s*(%w+)%s*=%s*"(.-)"')
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

local function sanitize(s)
    if not s then return "" end
    return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end

local function collectMetrics()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    local fmt = string.format

    -- Power metrics
    add("# HELP ae2_power_injection Average power injection (AE/t)")
    add("# TYPE ae2_power_injection gauge")
    add(fmt("ae2_power_injection %.2f", me.getAvgPowerInjection()))

    add("# HELP ae2_power_usage Average power usage (AE/t)")
    add("# TYPE ae2_power_usage gauge")
    add(fmt("ae2_power_usage %.2f", me.getAvgPowerUsage()))

    add("# HELP ae2_power_stored Stored power (AE)")
    add("# TYPE ae2_power_stored gauge")
    add(fmt("ae2_power_stored %.2f", me.getStoredPower()))

    add("# HELP ae2_power_max Maximum power capacity (AE)")
    add("# TYPE ae2_power_max gauge")
    add(fmt("ae2_power_max %.2f", me.getMaxStoredPower()))

    -- Item metrics
    local itemTypes = 0
    local totalItems = 0

    add("# HELP ae2_item_count Items stored per type")
    add("# TYPE ae2_item_count gauge")

    for item in me.allItems() do
        itemTypes = itemTypes + 1
        totalItems = totalItems + item.size
        if item.size >= ITEM_MIN_COUNT then
            add(fmt('ae2_item_count{name="%s",label="%s",damage="%d"} %.0f',
                sanitize(item.name), sanitize(item.label), item.damage, item.size))
        end
    end

    add("# HELP ae2_item_types Total unique item types")
    add("# TYPE ae2_item_types gauge")
    add(fmt("ae2_item_types %d", itemTypes))

    add("# HELP ae2_items_total Total items stored")
    add("# TYPE ae2_items_total gauge")
    add(fmt("ae2_items_total %.0f", totalItems))

    -- Crafting CPU metrics
    local cpus = me.getCpus()
    local cpuTotal = 0
    local cpuBusy = 0
    for _, cpu in ipairs(cpus) do
        cpuTotal = cpuTotal + 1
        if cpu.busy then cpuBusy = cpuBusy + 1 end
    end

    add("# HELP ae2_cpus_total Total crafting CPUs")
    add("# TYPE ae2_cpus_total gauge")
    add(fmt("ae2_cpus_total %d", cpuTotal))

    add("# HELP ae2_cpus_busy Busy crafting CPUs")
    add("# TYPE ae2_cpus_busy gauge")
    add(fmt("ae2_cpus_busy %d", cpuBusy))

    -- Fluid metrics
    if TRACK_FLUIDS then
        local ok, fluids = pcall(me.getFluidsInNetwork)
        if ok and fluids then
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
    end

    -- Essentia metrics
    if TRACK_ESSENTIA then
        local ok, essentia = pcall(me.getEssentiaInNetwork)
        if ok and essentia then
            local essTypes = 0
            add("# HELP ae2_essentia_amount Essentia stored")
            add("# TYPE ae2_essentia_amount gauge")
            for _, ess in ipairs(essentia) do
                essTypes = essTypes + 1
                local amount = ess.amount or ess.size or 0
                add(fmt('ae2_essentia_amount{name="%s",label="%s"} %.0f',
                    sanitize(ess.name or ""), sanitize(ess.label or ""), amount))
            end
            add("# HELP ae2_essentia_types Total essentia types")
            add("# TYPE ae2_essentia_types gauge")
            add(fmt("ae2_essentia_types %d", essTypes))
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

local function pushMetrics(body)
    local url = string.format("%s/metrics/job/%s/instance/%s",
        config.pushgateway_url, JOB_NAME, INSTANCE)
    local ok, err = pcall(function()
        for _ in internet.request(url, body, {
            ["Content-Type"] = "text/plain; version=0.0.4",
            ["Authorization"] = authHeader,
        }) do end
    end)
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

    local ok, body = pcall(collectMetrics)
    if ok then
        local pushed = pushMetrics(body)
        if pushed then
            print(string.format("pushed metrics (%d bytes)", #body))
        end
    else
        io.stderr:write("Collect failed: " .. tostring(body) .. "\n")
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

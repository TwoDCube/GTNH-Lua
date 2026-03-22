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
local METRICS_FILE    = "/tmp/ae2_metrics.txt"

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

local function sanitize(s)
    if not s then return "" end
    return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end

-- Write metrics to a temp file line-by-line to avoid accumulating
-- all strings in memory (768K RAM is tight with 1000+ item types)
local function collectMetricsToFile()
    local f = io.open(METRICS_FILE, "w")

    -- Power metrics
    f:write("# HELP ae2_power_injection Average power injection (AE/t)\n")
    f:write("# TYPE ae2_power_injection gauge\n")
    f:write(fmt("ae2_power_injection %.2f\n", me.getAvgPowerInjection()))

    f:write("# HELP ae2_power_usage Average power usage (AE/t)\n")
    f:write("# TYPE ae2_power_usage gauge\n")
    f:write(fmt("ae2_power_usage %.2f\n", me.getAvgPowerUsage()))

    f:write("# HELP ae2_power_stored Stored power (AE)\n")
    f:write("# TYPE ae2_power_stored gauge\n")
    f:write(fmt("ae2_power_stored %.2f\n", me.getStoredPower()))

    f:write("# HELP ae2_power_max Maximum power capacity (AE)\n")
    f:write("# TYPE ae2_power_max gauge\n")
    f:write(fmt("ae2_power_max %.2f\n", me.getMaxStoredPower()))

    -- Item metrics
    local itemTypes = 0
    local totalItems = 0

    f:write("# HELP ae2_item_count Items stored per type\n")
    f:write("# TYPE ae2_item_count gauge\n")

    for item in me.allItems() do
        itemTypes = itemTypes + 1
        totalItems = totalItems + item.size
        if item.size >= ITEM_MIN_COUNT then
            f:write(fmt('ae2_item_count{name="%s",label="%s",damage="%d"} %.0f\n',
                sanitize(item.name), sanitize(item.label), item.damage, item.size))
        end
    end

    f:write("# HELP ae2_item_types Total unique item types\n")
    f:write("# TYPE ae2_item_types gauge\n")
    f:write(fmt("ae2_item_types %d\n", itemTypes))

    f:write("# HELP ae2_items_total Total items stored\n")
    f:write("# TYPE ae2_items_total gauge\n")
    f:write(fmt("ae2_items_total %.0f\n", totalItems))

    -- Crafting CPU metrics
    local cpus = me.getCpus()
    local cpuTotal = 0
    local cpuBusy = 0
    for _, cpu in ipairs(cpus) do
        cpuTotal = cpuTotal + 1
        if cpu.busy then cpuBusy = cpuBusy + 1 end
    end

    f:write("# HELP ae2_cpus_total Total crafting CPUs\n")
    f:write("# TYPE ae2_cpus_total gauge\n")
    f:write(fmt("ae2_cpus_total %d\n", cpuTotal))

    f:write("# HELP ae2_cpus_busy Busy crafting CPUs\n")
    f:write("# TYPE ae2_cpus_busy gauge\n")
    f:write(fmt("ae2_cpus_busy %d\n", cpuBusy))

    -- Fluid metrics
    if TRACK_FLUIDS then
        local ok, fluids = pcall(me.getFluidsInNetwork)
        if ok and fluids then
            local fluidTypes = 0
            f:write("# HELP ae2_fluid_amount Fluid stored (mB)\n")
            f:write("# TYPE ae2_fluid_amount gauge\n")
            for _, fluid in ipairs(fluids) do
                fluidTypes = fluidTypes + 1
                local amount = fluid.amount or fluid.size or 0
                f:write(fmt('ae2_fluid_amount{name="%s",label="%s"} %.0f\n',
                    sanitize(fluid.name), sanitize(fluid.label), amount))
            end
            f:write("# HELP ae2_fluid_types Total fluid types\n")
            f:write("# TYPE ae2_fluid_types gauge\n")
            f:write(fmt("ae2_fluid_types %d\n", fluidTypes))
        end
    end

    -- Essentia metrics
    if TRACK_ESSENTIA then
        local ok, essentia = pcall(me.getEssentiaInNetwork)
        if ok and essentia then
            local essTypes = 0
            f:write("# HELP ae2_essentia_amount Essentia stored\n")
            f:write("# TYPE ae2_essentia_amount gauge\n")
            for _, ess in ipairs(essentia) do
                essTypes = essTypes + 1
                local amount = ess.amount or ess.size or 0
                f:write(fmt('ae2_essentia_amount{name="%s",label="%s"} %.0f\n',
                    sanitize(ess.name or ""), sanitize(ess.label or ""), amount))
            end
            f:write("# HELP ae2_essentia_types Total essentia types\n")
            f:write("# TYPE ae2_essentia_types gauge\n")
            f:write(fmt("ae2_essentia_types %d\n", essTypes))
        end
    end

    f:close()
end

local function pushMetrics(body)
    local url = fmt("%s/metrics/job/%s/instance/%s",
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

    os.sleep(0) -- yield to allow GC

    local ok, err = pcall(collectMetricsToFile)
    if not ok then
        io.stderr:write("Collect failed: " .. tostring(err) .. "\n")
        os.sleep(PUSH_INTERVAL)
        return true
    end

    -- Yield to free iterator/temp objects before reading file
    os.sleep(0)

    -- Read metrics file and push
    local f = io.open(METRICS_FILE, "r")
    local body = f:read("*a")
    f:close()

    local pushed = pushMetrics(body)
    local size = #body
    body = nil
    os.sleep(0) -- yield to free body string

    if pushed then
        print(fmt("pushed metrics (%d bytes)", size))
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
    os.remove(METRICS_FILE)
    print("AE2 Monitor stopped")
end

main()

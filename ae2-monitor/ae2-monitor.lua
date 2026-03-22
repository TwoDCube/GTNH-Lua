-- AE2 Network Monitor for Prometheus
-- Collects metrics from AE2 ME network and pushes to Prometheus Pushgateway
--
-- Requires config file at /etc/ae2-monitor.cfg:
--   pushgateway_url = "http://pushgateway-dev.apps.okd4.home.zoltanszepesi.com"
--   username = "pushuser"
--   password = "yourpassword"
--
-- Optional: track specific items in /etc/ae2-watchlist.cfg (one per line):
--   minecraft:iron_ingot
--   gregtech:gt.metaitem.01:32072

local events = require('events')
local component = require('component')
local event = require('event')
local internet = require('internet')

-----------------------------------------------------------------------
-- Configuration
-----------------------------------------------------------------------
local CONFIG_PATH     = "/etc/ae2-monitor.cfg"
local WATCHLIST_PATH  = "/etc/ae2-watchlist.cfg"
local JOB_NAME        = "ae2_monitor"
local INSTANCE        = "main"
local PUSH_INTERVAL   = 30

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

local function loadWatchlist(path)
    local list = {}
    local f = io.open(path, "r")
    if not f then return list end
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$") -- trim
        if line ~= "" and line:sub(1, 1) ~= "#" then
            -- Parse "name" or "name:damage"
            local name, damage = line:match("^(.+):(%d+)$")
            if name and damage then
                list[#list + 1] = { name = name, damage = tonumber(damage) }
            else
                list[#list + 1] = { name = line }
            end
        end
    end
    f:close()
    return list
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
local fmt = string.format

local function sanitize(s)
    if not s then return "" end
    return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
end

local function buildMetrics()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end

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

    -- Item totals via allItems() - only count, no per-item strings
    local itemTypes = 0
    local totalItems = 0
    for item in me.allItems() do
        itemTypes = itemTypes + 1
        totalItems = totalItems + item.size
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

    -- Watchlist items (targeted queries, memory-efficient)
    if #watchlist > 0 then
        add("# HELP ae2_watched_item_count Watched item count")
        add("# TYPE ae2_watched_item_count gauge")
        for _, entry in ipairs(watchlist) do
            local filter = { name = entry.name }
            if entry.damage then filter.damage = entry.damage end
            local ok, items = pcall(me.getItemsInNetwork, filter)
            if ok and items then
                for _, item in ipairs(items) do
                    add(fmt('ae2_watched_item_count{name="%s",label="%s",damage="%d"} %.0f',
                        sanitize(item.name), sanitize(item.label), item.damage or 0, item.size))
                end
            end
        end
    end

    -- Fluids
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

    return table.concat(lines, "\n") .. "\n"
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

    local ok, body = pcall(buildMetrics)
    if ok then
        local pushed = pushMetrics(body)
        if pushed then
            print(fmt("pushed metrics (%d bytes)", #body))
        end
        body = nil
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
    if #watchlist > 0 then
        print("Watching " .. #watchlist .. " items")
    end
    print("Press 'q' to exit")

    events.initEvents()
    events.hookEvents()

    while loop() do end

    events.unhookEvents()
    print("AE2 Monitor stopped")
end

main()

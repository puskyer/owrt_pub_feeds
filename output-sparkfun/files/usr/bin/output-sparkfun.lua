#!/usr/bin/lua
--[[
    Karl Palsson, 2015 <karlp@remake.is>
]]

local json = require("dkjson")
local uloop = require("uloop")
uloop.init()
local mosq = require("mosquitto")
--local posix = require("posix")
local ugly = require("remake.ugly_log")

local lapp = require("pl.lapp")
local args = lapp [[
    -H,--host (default "localhost") MQTT host to listen to
    -p,--public (string) public key to use
    -k,--key (string) private key (don't do this)
    -v,--verbose (0..7 default 4) Logging level, higher == more
]]
-- FIXME - private key should be file or env var or something so it's not in
-- "ps" output

local cfg = {
    APP_NAME = "output-sparkfun",
    --MOSQ_CLIENT_ID = string.format("output-sparkfun-%d", posix.getpid()["pid"]),
    MOSQ_CLIENT_ID = string.format("output-sparkfun-%d", 123),
    MOSQ_IDLE_LOOP_MS = 100,
    TOPIC_LISTEN = "status/local/json/device/#",
    TEMPLATE_POST_URL="http://data.sparkfun.com/input/%s",
    POST_INTERVAL = 5 * 1000, -- once a minute is enough...
}

local cache = {}

ugly.initialize(cfg.APP_NAME, args.verbose or 4)

mosq.init()
local mqtt = mosq.new(cfg.MOSQ_CLIENT_ID, true)

for i = 1,3 do
    local rv = mqtt:connect(args.host, 1883, 60)
    if rv then
	ugly.notice("Connected to " .. args.host)
        break
    else
        ugly.notice("Failed to connect, retrying...")
	--posix.sleep(1) -- let's not add more deps to get sub second sleeping
    end
end

if not mqtt:subscribe(cfg.TOPIC_LISTEN, 0) then
    -- We are not connected, just abort here and let monit restart us
    ugly.err("Aborting, unable to make MQTT connection")
    os.exit(1)
end

mqtt.ON_MESSAGE = function(mid, topic, jpayload, qos, retain)
    local payload, err = json.decode(jpayload)
    if not payload then
        ugly.warning("Invalid json in message on topic: %s, %s", topic, err)
        return
    end
    if payload.error then ugly.notice("Ignoring failed reading"); return end
    if payload.hwc.typeOfMeasurementPoints == "cbms" then ugly.debug("Ignoring bar reading"); return end
    -- we simply keep the last remaining values.
    cache.volts = payload.phases[1].voltage
    cache.amps = payload.phases[1].current
    cache.pf = payload.phases[1].pf
    cache.kwh = payload.cumulative_wh / 1000
end

local mqtt_read = uloop.fd_add(mqtt:socket(), function(ufd, events)
	mqtt:loop_read()
end, uloop.ULOOP_READ)

local mqtt_write = uloop.fd_add(mqtt:socket(), function(ufd, events)
	mqtt:loop_write()
end, uloop.ULOOP_WRITE)

local mqtt_idle_timer
mqtt_idle_timer = uloop.timer(function()
        -- just handle the mosquitto idle/misc loop
        local success, errno, err = mqtt:loop_misc()
        if not success then
            local err = string.format("Lost MQTT connection: %s", err)
            ugly.crit(err)
            error(err)
        end
        mqtt_idle_timer:set(cfg.MOSQ_IDLE_LOOP_MS)
    end, cfg.MOSQ_IDLE_LOOP_MS)


local timer_process_deltas
timer_process_deltas = uloop.timer(function()
	-- do this properly with libcurl or a library for this...
	local url = string.format(cfg.TEMPLATE_POST_URL, args.public)
	local cmd = string.format([[curl -X POST '%s' -H 'Phant-Private-Key: %s' ]], url, args.key)
	-- WRONG! do a proper url encode please!
	local fields = string.format("-d 'volts=%f&amps=%f&pf=%f&kwh=%f'", cache.volts, cache.amps, cache.pf, cache.kwh)
	cmd = cmd .. fields
	ugly.notice("Posting to sparkfun...", cmd)
	os.execute(cmd)

        timer_process_deltas:set(cfg.POST_INTERVAL)
    end, cfg.POST_INTERVAL)

uloop.run()
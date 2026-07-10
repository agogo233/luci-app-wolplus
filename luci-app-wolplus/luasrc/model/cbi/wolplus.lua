local i = require "luci.sys"
local t, e
local a, nolimit_mac, nolimit_eth, cron, lastwake, btn

t = Map("wolplus", translate("Wake on LAN +"), translate("Wake on LAN is a mechanism to remotely boot computers in the local network."))
e = t:section(TypedSection, "macclient", translate("Host Clients"))
e.template = "cbi/tblsection"
e.anonymous = true
e.addremove = true
e.template_addremove = "wolplus/tblsection_addremove"

a = e:option(Value, "name", translate("Name"))
a.optional = false

nolimit_mac = e:option(Value, "macaddr", translate("MAC Address"))
nolimit_mac.rmempty = false
nolimit_mac.validate = function(self, value, section)
    if not value or not value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        return nil, translate("Invalid MAC address format")
    end
    return value
end
i.net.mac_hints(function(e, t) nolimit_mac:value(e, "%s (%s)" % {e, t}) end)

nolimit_eth = e:option(Value, "maceth", translate("Network Interface"))
nolimit_eth.rmempty = true
for _, dev in ipairs(i.net.devices()) do if dev ~= "lo" then nolimit_eth:value(dev) end end

cron = e:option(Value, "wake_cron", translate("Scheduled Wake"))
cron.placeholder = "07:30"
cron.description = translate("Daily wake time in HH:MM format, leave empty to clear")
cron.validate = function(self, value, section)
    if value == "" then return value end
    local hh, mm = value:match("^(%d%d):(%d%d)$")
    if not hh or not mm then
        return nil, translate("Invalid time format, expected HH:MM")
    end
    if tonumber(hh) > 23 or tonumber(mm) > 59 then
        return nil, translate("Hour must be 0-23, minute 0-59")
    end
    return value
end

lastwake = e:option(DummyValue, "lastwake", translate("Last Woken"))
lastwake.rawhtml = true
function lastwake.cfgvalue(self, section)
    local x = luci.model.uci.cursor()
    local ts = x:get("wolplus", section, "last_wake")
    if ts and ts ~= "" then
        return os.date("%m-%d %H:%M", tonumber(ts))
    end
    return "—"
end

btn = e:option(Button, "_awake", translate("Wake Up Host"))
btn.inputtitle = translate("Awake")
btn.inputstyle = "apply"
btn.disabled = false
btn.template = "wolplus/awake"

t.children[#t.children+1] = {
    prepare = function(self) end,
    parse = function(self) end,
    save = function(self) end,
    render = function(self) luci.template.render("wolplus/custom_actions") end
}
t.children[#t.children+1] = {
    prepare = function(self) end,
    parse = function(self) end,
    save = function(self) end,
    render = function(self) luci.template.render("wolplus/custom_scripts") end
}

function e.create(e, t)
    local id = tostring(os.time()) .. tostring(math.random(999999999))
    math.randomseed(tonumber(tostring(os.time()):reverse():sub(1, 6)))
    TypedSection.create(e, id)
    return id
end

function t.on_commit(map)
    local crontab_path = "/etc/crontabs/root"
    local lines = {}

    if not nixio.fs.access(crontab_path) then
        local fh = io.open(crontab_path, "w")
        if fh then
            fh:close()
            os.execute("chmod 0600 " .. crontab_path)
        end
    end

    local f = io.open(crontab_path, "r")
    if f then
        for line in f:lines() do
            if not line:match("# wolplus:") then
                table.insert(lines, line)
            end
        end
        f:close()
    end

    local x = luci.model.uci.cursor()
    x:foreach("wolplus", "macclient", function(s)
        local cron_input = s.wake_cron or ""
        if cron_input ~= "" then
            local hh, mm = cron_input:match("^(%d%d):(%d%d)$")
            if hh and mm then
                local mac = s.macaddr or ""
                local safe_mac = mac:gsub("[%c]", "")
                local safe_name = (s.name or ""):gsub("[#%c%%]", "")
                table.insert(lines, string.format("%s %s * * * /usr/bin/wol %s 255.255.255.255 2>/dev/null # wolplus:%s:%s",
                    mm, hh, safe_mac, s[".name"] or "", safe_name))
            end
        end
    end)

    f = io.open(crontab_path, "w")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
        os.execute("chmod 0600 " .. crontab_path)
    end
    os.execute("/etc/init.d/cron restart 2>/dev/null")
    os.execute(string.format("logger -t wolplus 'crontab updated: %d entries'", #lines))
end

return t

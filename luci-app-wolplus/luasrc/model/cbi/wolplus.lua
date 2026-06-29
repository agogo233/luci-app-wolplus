local i = require "luci.sys"
local t, e
local a, nolimit_mac, nolimit_eth, cron, lastwake, btn

t = Map("wolplus", translate("Wake on LAN +"), translate("Wake on LAN is a mechanism to remotely boot computers in the local network.") .. [[<br/><br/><a href="https://github.com/agogo233" target="_blank">Powered by agogo233</a>]])
t.template = "wolplus/index"
e = t:section(TypedSection, "macclient", translate("Host Clients"))
e.template = "cbi/tblsection"
e.anonymous = true
e.addremove = true

a = e:option(Value, "name", translate("Name"))
a.optional = false

nolimit_mac = e:option(Value, "macaddr", translate("MAC Address"))
nolimit_mac.rmempty = false
i.net.mac_hints(function(e, t) nolimit_mac:value(e, "%s (%s)" % {e, t}) end)

nolimit_eth = e:option(Value, "maceth", translate("Network Interface"))
nolimit_eth.rmempty = false
for _, dev in ipairs(i.net.devices()) do if dev ~= "lo" then nolimit_eth:value(dev) end end

-- 定时唤醒（HH:MM 格式，每日执行）
cron = e:option(Value, "wake_cron", translate("Scheduled Wake"))
cron.placeholder = "07:30"
cron.description = translate("Daily wake time in HH:MM format, leave empty to clear")

-- 最近唤醒时间（只读）
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

local function gen_uuid()
    local t = tostring(os.time())
    local r = tostring(math.random(99999))
    return t .. r
end

function e.create(e, t)
    local id = gen_uuid()
    return TypedSection.create(e, id)
end

-- 定时任务管理：提交时重建 crontab
function t.on_commit(map)
    local crontab_path = "/etc/crontabs/root"
    local lines = {}

    if not nixio.fs.access(crontab_path) then
        local fh = io.open(crontab_path, "w")
        if fh then fh:close() end
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
                table.insert(lines, string.format("%s %s * * * /usr/bin/wol %s 255.255.255.255 2>/dev/null # wolplus:%s:%s",
                    mm, hh, mac, s[".name"] or "", (s.name or ""):gsub("[#\n]", "")))
            end
        end
    end)

    f = io.open(crontab_path, "w")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
    end
    os.execute("/etc/init.d/cron restart 2>/dev/null")
end

return t

module("luci.controller.wolplus", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/wolplus") then return end
    entry({"admin", "services", "wolplus"}, cbi("wolplus"), _("Wake on LAN"), 95).dependent = true
    entry({"admin", "services", "wolplus", "awake"}, post("awake")).leaf = true
    entry({"admin", "services", "wolplus", "status"}, post("status")).leaf = true
    entry({"admin", "services", "wolplus", "awakeall"}, post("awakeall")).leaf = true
    entry({"admin", "services", "wolplus", "import_arp"}, post("import_arp")).leaf = true
end

-- 工具函数：获取广播地址
local function get_broadcast(iface)
    local f = io.popen("ip -4 -o addr show " .. iface .. " 2>/dev/null | awk '{print $6}'")
    local bc = f and f:read("*l") or nil
    if f then f:close() end
    if not bc or bc == "" then bc = "255.255.255.255" end
    return bc
end

-- 工具函数：检查 ARP 表
local function check_arp(mac)
    local mac_lower = mac:lower()
    local f = io.popen("cat /proc/net/arp 2>/dev/null")
    if not f then return false, nil end
    for line in f:lines() do
        local ip, hw_type, flags, hw_addr = line:match("^(%S+)%s+0x(%S+)%s+0x(%S+)%s+([%x:]+)")
        if ip and hw_addr and hw_addr:lower() == mac_lower and flags == "2" then
            f:close()
            return true, ip
        end
    end
    f:close()
    return false, nil
end

-- 工具函数：检查 IP neighbor
local function check_ip_neigh(mac, iface)
    local mac_lower = mac:lower()
    local f = io.popen("ip neigh show dev " .. iface .. " 2>/dev/null")
    if not f then return false, nil end
    for line in f:lines() do
        local ip, status, hw_addr = line:match("^(%S+)%s+lladdr%s+([%x:]+)%s+(%S+)")
        if ip and hw_addr and hw_addr:lower() == mac_lower then
            if status == "reachable" or status == "stale" or status == "delay" or status == "probe" then
                f:close()
                return true, ip
            end
        end
    end
    f:close()
    return false, nil
end

-- 工具函数：ping 检测
local function ping_check(ip, iface)
    local cmd = "ping -c 1 -W 1 -I " .. iface .. " " .. ip .. " 2>/dev/null"
    return os.execute(cmd) == 0
end

-- 工具函数：解析主机名
local function resolve_hostname(mac, ip)
    local mac_upper = mac:upper()
    local f = io.popen("cat /tmp/dhcp.leases 2>/dev/null")
    if not f then return nil end
    for line in f:lines() do
        local ts, lease_mac, lease_ip, hostname = line:match("^(%d+)%s+([%x:]+)%s+(%S+)%s+(%S+)")
        if lease_mac and lease_mac:upper() == mac_upper then
            f:close()
            if hostname and hostname ~= "*" then return hostname end
        end
    end
    f:close()
    -- 再从 ARP 缓存反查 IP → hostname
    if ip then
        local f2 = io.popen("cat /tmp/dhcp.leases 2>/dev/null | grep " .. ip .. " | head -1")
        if f2 then
            local line2 = f2:read("*l")
            f2:close()
            if line2 then
                local h = line2:match("^%S+%s+%S+%s+%S+%s+(%S+)")
                if h and h ~= "*" then return h end
            end
        end
    end
    return nil
end

-- 唤醒单台设备
function awake(sections)
    local x = luci.model.uci.cursor()
    local lan = x:get("wolplus", sections, "maceth")
    local mac = x:get("wolplus", sections, "macaddr")

    if not lan or not lan:match("^[%w%-%._]+$") then
        lan = "br-lan"
    end

    if not mac or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        luci.http.status(400, "Invalid MAC address")
        return
    end

    local broadcast = get_broadcast(lan)
    local cmd = "/usr/bin/wol " .. mac .. " " .. broadcast .. " 2>&1"
    local p = io.popen(cmd)
    local msg = ""
    if p then
        while true do
            local l = p:read("*l")
            if l then
                if #l > 100 then l = l:sub(1, 100) .. "..." end
                msg = msg .. l
            else
                break
            end
        end
        p:close()
    end

    local name = x:get("wolplus", sections, "name") or ""
    os.execute(string.format("logger -t wolplus 'awake: %s %s'", name, mac))

    luci.http.prepare_content("application/json")
    luci.http.write_json({success = #msg == 0, data = msg, name = name, mac = mac})
end

-- 在线状态检查
function status()
    local x = luci.model.uci.cursor()
    local devices = {}

    x:foreach("wolplus", "macclient", function(s)
        local section = s[".name"]
        local mac = s.macaddr or ""
        local eth = s.maceth or "br-lan"

        if mac == "" then return end

        local online, ip = check_arp(mac)
        if not online then
            online, ip = check_ip_neigh(mac, eth)
        end
        if not online and ip then
            online = ping_check(ip, eth)
        end

        local hostname = resolve_hostname(mac, ip)

        table.insert(devices, {
            section = section,
            mac = mac,
            ip = ip or "",
            hostname = hostname or "",
            online = online or false
        })
    end)

    luci.http.prepare_content("application/json")
    luci.http.write_json({devices = devices})
end

-- 一键全部唤醒
function awakeall()
    local x = luci.model.uci.cursor()
    local results = {}
    local has_any = false

    x:foreach("wolplus", "macclient", function(s)
        has_any = true
        local mac = s.macaddr or ""
        local eth = s.maceth or "br-lan"
        local name = s.name or ""

        if mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
            local broadcast = get_broadcast(eth)
            os.execute("/usr/bin/wol " .. mac .. " " .. broadcast .. " 2>/dev/null")
            os.execute(string.format("logger -t wolplus 'awake_all: %s %s'", name, mac))
            table.insert(results, {name = name, mac = mac, success = true})
        else
            table.insert(results, {name = name, mac = mac, success = false})
        end
    end)

    if not has_any then
        luci.http.prepare_content("application/json")
        luci.http.write_json({results = {}, empty = true})
        return
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({results = results})
end

-- 导入 ARP 缓存中的在线设备
function import_arp()
    local x = luci.model.uci.cursor()
    local existing = {}
    x:foreach("wolplus", "macclient", function(s)
        local mac = s.macaddr or ""
        if mac ~= "" then
            existing[mac:lower()] = true
        end
    end)

    local devices = {}
    local f = io.popen("cat /proc/net/arp 2>/dev/null")
    if f then
        for line in f:lines() do
            local ip, hw_type, flags, hw_addr, mask, dev = line:match(
                "^(%S+)%s+0x(%S+)%s+0x(%S+)%s+([%x:]+)%s+(%S+)%s+(%S+)"
            )
            if ip and hw_addr and flags == "2" then
                if not existing[hw_addr:lower()] then
                    local hostname = resolve_hostname(hw_addr, ip)
                    table.insert(devices, {
                        mac = hw_addr,
                        ip = ip,
                        hostname = hostname or "",
                        iface = dev or ""
                    })
                end
            end
        end
        f:close()
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({devices = devices})
end

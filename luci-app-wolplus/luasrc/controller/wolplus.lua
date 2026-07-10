module("luci.controller.wolplus", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/wolplus") then return end
    entry({"admin", "services", "wolplus"}, cbi("wolplus"), _("Wake on LAN"), 95).dependent = true
    local awake_entry = entry({"admin", "services", "wolplus", "awake"}, call("awake"))
    awake_entry.leaf = true
    local status_entry = entry({"admin", "services", "wolplus", "status"}, call("status"))
    status_entry.leaf = true
    local awakeall_entry = entry({"admin", "services", "wolplus", "awakeall"}, call("awakeall"))
    awakeall_entry.leaf = true
    local import_entry = entry({"admin", "services", "wolplus", "import_arp"}, call("import_arp"))
    import_entry.leaf = true
    awake_entry.post = true
    status_entry.post = true
    awakeall_entry.post = true
    import_entry.post = true
end

-- 工具函数：校验 section 名称格式
local function check_section(section)
    if not section or not section:match("^[%w_]+$") then
        luci.http.status(400, "Invalid section")
        return false
    end
    return true
end

-- 工具函数：校验网络接口类型
local function check_iface(iface)
    if not iface or not iface:match("^[%w%-%._]+$") then
        return "br-lan"
    end
    return iface
end

-- 工具函数：校验 MAC 地址格式
local function check_mac(mac)
    if not mac or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        return false
    end
    return true
end

-- 工具函数：获取广播地址
local function get_broadcast(iface)
    iface = check_iface(iface)
    local f = io.popen(string.format("ip -4 -o addr show %s 2>/dev/null | awk '{print $6}'", string.format("%q", iface)))
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
    iface = check_iface(iface)
    local f = io.popen(string.format("ip neigh show dev %s 2>/dev/null", string.format("%q", iface)))
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
    iface = check_iface(iface)
    local cmd = string.format("ping -c 1 -W 1 -I %s %s 2>/dev/null", string.format("%q", iface), string.format("%q", ip))
    return os.execute(cmd) == 0
end

-- 工具函数：解析主机名（缓存版本）
local hostname_cache = nil
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
        local f2 = io.popen(string.format("cat /tmp/dhcp.leases 2>/dev/null | grep %s | head -1", string.format("%q", ip)))
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
    if not check_section(sections) then return end

    local x = luci.model.uci.cursor()
    local lan = check_iface(x:get("wolplus", sections, "maceth"))
    local mac = x:get("wolplus", sections, "macaddr")
    local name = x:get("wolplus", sections, "name") or ""

    if not check_mac(mac) then
        luci.http.status(400, "Invalid MAC address")
        return
    end

    local broadcast = get_broadcast(lan)
    local cmd = string.format("/usr/bin/wol %s %s 2>&1", string.format("%q", mac), string.format("%q", broadcast))
    local p = io.popen(cmd)
    local msg = ""
    if p then
        msg = p:read("*a") or ""
        p:close()
    end

    os.execute(string.format("logger -t wolplus 'awake: %s %s'", string.format("%q", name), string.format("%q", mac)))

    luci.http.prepare_content("application/json")
    luci.http.write_json({success = true, data = msg or "", name = name, mac = mac})
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
        local eth = check_iface(s.maceth)
        local name = s.name or ""

        if check_mac(mac) then
            local broadcast = get_broadcast(eth)
            local ok = os.execute(string.format("/usr/bin/wol %s %s 2>/dev/null", string.format("%q", mac), string.format("%q", broadcast))) == 0
            os.execute(string.format("logger -t wolplus 'awake_all: %s %s success=%s'", string.format("%q", name), string.format("%q", mac), tostring(ok)))
            table.insert(results, {name = name, mac = mac, success = ok})
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
                if not existing[hw_addr:lower()] and check_mac(hw_addr) then
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

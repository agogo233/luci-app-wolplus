module("luci.controller.wolplus", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/wolplus") then return end
    entry({"admin", "services", "wolplus"}, cbi("wolplus"), _("Wake on LAN"), 95).dependent = true
	entry( {"admin", "services", "wolplus", "awake"}, post("awake") ).leaf = true
end

function awake(sections)
	local x = luci.model.uci.cursor()
	local lan = x:get("wolplus", sections, "maceth")
	local mac = x:get("wolplus", sections, "macaddr")

	-- 验证接口名：只允许字母、数字、连字符、点号、下划线
	if not lan or not lan:match("^[%w%-%._]+$") then
		lan = "br-lan"
	end

	-- 验证 MAC 地址格式
	if not mac or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		luci.http.status(400, "Invalid MAC address")
		return
	end

	-- 获取接口的广播地址
	local f = io.popen("ip -4 -o addr show " .. lan .. " 2>/dev/null | awk '{print $6}'")
	local broadcast = f and f:read("*l") or nil
	if f then f:close() end
	if not broadcast or broadcast == "" then
		broadcast = "255.255.255.255"
	end

	local e = {}
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
	e["data"] = msg
    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

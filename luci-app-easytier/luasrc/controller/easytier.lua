
module("luci.controller.easytier", package.seeall)
local i18n = require "luci.i18n"

-- 安全执行命令并返回结果
local function safe_exec(cmd)
    local handle = io.popen(cmd)
    if not handle then return "" end
    local result = handle:read("*all") or ""
    handle:close()
    return result:gsub("[\r\n]+$", "")
end

-- 安全读取文件内容
local function safe_read_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    return content
end

-- 计算运行时长
local function calc_uptime(start_time_file)
    local content = safe_read_file(start_time_file)
    if not content or content == "" then return "" end

    local start_time = tonumber(content:match("%d+"))
    if not start_time then return "" end

    local now = os.time()
    local elapsed = now - start_time

    local days = math.floor(elapsed / 86400)
    local hours = math.floor((elapsed % 86400) / 3600)
    local mins = math.floor((elapsed % 3600) / 60)
    local secs = elapsed % 60

    local result = ""
    if days > 0 then result = days .. "天 " end
    result = result .. string.format("%02d小时%02d分%02d秒", hours, mins, secs)
    return result
end

function index()
	if not nixio.fs.access("/etc/config/easytier") then
		return
	end

	entry({"admin", "vpn"}, firstchild(), "VPN").dependent = false
	entry({"admin", "vpn", "easytier"}, firstchild(),_("EasyTier")).dependent = true
	entry({"admin", "vpn", "easytier", "status"}, cbi("easytier_status"),_("Status"), 1).leaf = true
	entry({"admin", "vpn", "easytier", "config"}, cbi("easytier"),_("EasyTier Core"), 2).leaf = true
	entry({"admin", "vpn", "easytier", "log"}, template("easytier/easytier_log"),_("Logs"), 3).leaf = true
	entry({"admin", "vpn", "easytier", "get_tun_info"}, call("get_tun_info")).leaf = true
	entry({"admin", "vpn", "easytier", "get_log"}, call("get_log")).leaf = true
	entry({"admin", "vpn", "easytier", "get_log_size"}, call("get_log_size")).leaf = true
	entry({"admin", "vpn", "easytier", "clear_log"}, call("clear_log")).leaf = true
	entry({"admin", "vpn", "easytier", "clear_version_cache"}, call("clear_version_cache")).leaf = true
	entry({"admin", "vpn", "easytier", "api_status"}, call("act_status")).leaf = true
	entry({"admin", "vpn", "easytier", "api_conninfo"}, call("act_conninfo")).leaf = true
end

function act_status()
	local e = {}
	local sys  = require "luci.sys"
	local uci  = require "luci.model.uci".cursor()
	e.crunning = luci.sys.call("pgrep easytier-core >/dev/null") == 0

	-- 使用 Lua 原生计算运行时长
	e.etsta = calc_uptime("/tmp/easytier_time")

	-- 获取 CPU 和内存使用率（使用原始命令）
	local command2 = io.popen('test ! -z "`pidof easytier-core`" && (top -b -n1 | grep -E "$(pidof easytier-core)" 2>/dev/null | grep -v grep | awk \'{for (i=1;i<=NF;i++) {if ($i ~ /easytier-core/) break; else cpu=i}} END {print $cpu}\')')
	e.etcpu = command2:read("*all")
	command2:close()

	local command3 = io.popen("test ! -z `pidof easytier-core` && (cat /proc/$(pidof easytier-core | awk '{print $NF}')/status | grep -w VmRSS | awk '{printf \"%.2f MB\", $2/1024}')")
	e.etram = command3:read("*all")
	command3:close()

	-- 获取版本信息
	local cached_newtag = safe_read_file("/tmp/easytiernew.tag")
	if cached_newtag and cached_newtag ~= "" then
		e.etnewtag = cached_newtag:gsub("[\r\n]+", "")
	else
		e.etnewtag = safe_exec("curl -L -k -s --connect-timeout 3 --user-agent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36' https://api.github.com/repos/EasyTier/EasyTier/releases/latest | grep tag_name | sed 's/[^0-9.]*//g'")
		if e.etnewtag ~= "" then
			local f = io.open("/tmp/easytiernew.tag", "w")
			if f then f:write(e.etnewtag); f:close() end
		end
	end

	local cached_tag = safe_read_file("/tmp/easytier.tag")
	if cached_tag and cached_tag ~= "" then
		e.ettag = cached_tag:gsub("[\r\n]+", "")
	else
		local easytierbin = uci:get_first("easytier", "easytier", "easytierbin") or "/usr/bin/easytier-core"
		e.ettag = safe_exec(easytierbin .. " -V 2>/dev/null | sed 's/^[^0-9]*//'")
		if e.ettag == "" or e.ettag == nil then e.ettag = "unknown" end
		local f = io.open("/tmp/easytier.tag", "w")
		if f then f:write(e.ettag); f:close() end
	end

	e.no_tun = uci:get_first("easytier", "easytier", "no_tun") == "1"
	e.dev_name = uci:get_first("easytier", "easytier", "tunname") or "tun0"

	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

function get_tun_info()
	luci.http.prepare_content("application/json")

	local ifname = luci.http.formvalue("ifname") or "tun0"

	local exists = luci.sys.exec("ip link show " .. ifname .. " >/dev/null 2>&1 && echo 1 || echo 0")
	if not exists:match("1") then
		luci.http.write('{"success":false,"exists":false}')
		return
	end

	local ifconfig_out = luci.sys.exec("ifconfig " .. ifname .. " 2>/dev/null")

	local ip = ifconfig_out:match("inet addr:([%d%.]+)") or ifconfig_out:match("inet ([%d%.]+)")

	local netmask = ""
	local netmask_full = ifconfig_out:match("Mask:([%d%.]+)") or ifconfig_out:match("netmask ([%d%.]+)")

	if not netmask_full or netmask_full == "" then
		local ip_output = luci.sys.exec("ip -4 addr show " .. ifname .. " 2>/dev/null | grep 'inet ' | head -n1 | awk '{print $2}'")
		local cidr = ip_output:match("/(%d+)")
		if cidr then
			cidr = tonumber(cidr)
			local mask = 0xFFFFFFFF - (2 ^ (32 - cidr) - 1)
			netmask = string.format("%d.%d.%d.%d",
				math.floor(mask / 16777216) % 256,
				math.floor(mask / 65536) % 256,
				math.floor(mask / 256) % 256,
				mask % 256)
		end
	else
		netmask = netmask_full
	end

	local ipv6_cmd = luci.sys.exec("ip -6 addr show " .. ifname .. " 2>/dev/null | grep 'inet6' | head -n1 | awk '{print $2}'")
	local ipv6 = ipv6_cmd:gsub("%s", "")
	if ipv6 == "" then ipv6 = nil end

	local mtu = ifconfig_out:match("MTU:(%d+)") or luci.sys.exec("ip link show " .. ifname .. " 2>/dev/null | head -n1 | sed -n 's/.*mtu \\([0-9]*\\).*/\\1/p'"):gsub("%s", "")

	local state = "UNKNOWN"
	if ifconfig_out:match("UP") then
		state = "UP"
	elseif ifconfig_out:match("DOWN") then
		state = "DOWN"
	end

	local rx = luci.sys.exec("cat /sys/class/net/" .. ifname .. "/statistics/rx_bytes 2>/dev/null || echo 0"):gsub("%s", "")
	local tx = luci.sys.exec("cat /sys/class/net/" .. ifname .. "/statistics/tx_bytes 2>/dev/null || echo 0"):gsub("%s", "")

	local response = string.format('{"success":true,"exists":true,"ip":"%s","netmask":"%s","mtu":"%s","state":"%s","rx_bytes":%s,"tx_bytes":%s',
		ip or "", netmask, mtu, state, rx, tx)

	if ipv6 then
		response = response .. ',"ipv6":"' .. ipv6 .. '"'
	end

	response = response .. '}'

	luci.http.write(response)
end

function get_log()
    local log = ""
    local files = {"/tmp/easytier.log"}
    for i, file in ipairs(files) do
        if luci.sys.call("[ -f '" .. file .. "' ]") == 0 then
            log = log .. luci.sys.exec("sed 's/\\x1b\\[[0-9;]*m//g' " .. file)
        end
    end
    luci.http.write(log)
end

function get_log_size()
    local size = luci.sys.exec("[ -f '/tmp/easytier.log' ] && stat -c%s /tmp/easytier.log 2>/dev/null || echo 0")
    luci.http.prepare_content("application/json")
    luci.http.write_json({size = tonumber(size) or 0})
end

function clear_log()
	luci.sys.call("echo '' >/tmp/easytier.log")
end

function clear_version_cache()
	local type = luci.http.formvalue("type")
	if type == "core" then
		luci.sys.call("rm -f /tmp/easytiernew.tag /tmp/easytier.tag")
	end
	luci.http.write("OK")
end

function act_conninfo()
	local e = {}
	local uci = require "luci.model.uci".cursor()
	local easytierbin = uci:get_first("easytier", "easytier", "easytierbin") or "/usr/bin/easytier-core"
	local clibin = easytierbin:gsub("easytier%-core$", "easytier-cli")

	local process_status = luci.sys.exec("pgrep easytier-core")

	if process_status ~= "" then
		-- 获取各类CLI信息
		local function get_cli_output(cmd)
			local handle = io.popen(clibin .. " " .. cmd .. " 2>&1")
			if handle then
				local result = handle:read("*all")
				handle:close()
				return result or ""
			end
			return ""
		end

		e.node = get_cli_output("node")
		e.peer = get_cli_output("peer")
		e.connector = get_cli_output("connector")
		e.stun = get_cli_output("stun")
		e.route = get_cli_output("route")
		e.peer_center = get_cli_output("peer-center")
		e.vpn_portal = get_cli_output("vpn-portal")
		e.proxy = get_cli_output("proxy")
		e.acl = get_cli_output("acl stats")
		e.mapped_listener = get_cli_output("mapped-listener")
		e.stats = get_cli_output("stats")

		-- 获取启动参数
		local cmdhandle = io.popen("cat /proc/$(pidof easytier-core)/cmdline 2>/dev/null | tr '\\0' ' '")
		if cmdhandle then
			e.cmdline = cmdhandle:read("*all") or ""
			cmdhandle:close()
		else
			e.cmdline = ""
		end

		-- 检查是否使用配置文件启动
		if e.cmdline:match("%-%-config%-file") or e.cmdline:match("%-c%s+/") then
			e.config_file = safe_read_file("/etc/easytier/config.toml") or ""
		else
			e.config_file = ""
		end
	else
		local errMsg = i18n.translate("Error: Program not running! Please start the program and refresh")
		e.node = errMsg
		e.peer = errMsg
		e.connector = errMsg
		e.stun = errMsg
		e.route = errMsg
		e.peer_center = errMsg
		e.vpn_portal = errMsg
		e.proxy = errMsg
		e.acl = errMsg
		e.mapped_listener = errMsg
		e.stats = errMsg
		e.cmdline = errMsg
	end

	luci.http.prepare_content("application/json")
	luci.http.write_json(e)
end

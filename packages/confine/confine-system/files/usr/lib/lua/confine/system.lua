--[[



]]--


--- CONFINE system abstraction library.
module( "confine.system", package.seeall )

local nixio   = require "nixio"
local lsys    = require "luci.sys"
local lutil   = require "luci.util"
local sig     = require "signal"
local uci     = require "confine.uci"
local tools   = require "confine.tools"
local data    = require "confine.data"
local ctree   = require "confine.tree"
local null    = data.null


RUNTIME_DIR = "/var/run/confine/"
PID_FILE = RUNTIME_DIR.."pid"
LOG_FILE = "/var/log/confine.log"
LOG_SIZE = 1000000

SERVER_BASE_PATH = "/confine/api"
NODE_BASE_PATH = "/confine/api"

DFLT_SLIVER_DISK_MAX_MB      = 2000
DFLT_SLIVER_DISK_DFLT_MB     = 400
DFLT_SLIVER_DISK_RESERVED_MB = 500

node_state_file     = RUNTIME_DIR.."node_state"
server_state_file   = RUNTIME_DIR.."server_state"
system_state_file   = RUNTIME_DIR.."system_state"

rest_confine_dir    = "/tmp/confine"
rest_base_dir       = rest_confine_dir.."/"
rest_node_dir       = rest_confine_dir.."/node/"
rest_slivers_dir    = rest_confine_dir.."/slivers/"
rest_templates_dir  = rest_confine_dir.."/templates/"

function check_pid()
	tools.mkdirr( RUNTIME_DIR )
	local pid = nixio.fs.readfile( PID_FILE )
	
	if pid and tonumber(pid) and nixio.fs.stat( "/proc/"..pid.."/cmdline" ) then
		tools.err("There already seem a confine deamon running. If not remove %s and retry!", PID_FILE)
		return false
	else
		local out = io.open(PID_FILE, "w")
		assert(out, "Failed to open %s" %PID_FILE)
		out:write( nixio.getpid() )
		out:close()
		return true
	end	
end

function stop(code)
	tools.dbg("Terminating")
	pcall(nixio.fs.remover, rest_confine_dir)
	pcall(nixio.fs.remover, PID_FILE)
	os.exit(code)
--	nixio.kill(nixio.getpid(),sig.SIGKILL)
end

function reboot()
	tools.dbg("rebooting...")
	tools.sleep(2)
	os.execute("reboot")
	stop(0)
end



function help()
	print("usage: /usr/lib/lua/confine/confine.lua  \\\
	      [--debug] \\\
	      [--interactive] \\\
	      [--count=<max iterations>] \\\
	      [--interval=<seconds per iteration>] \\\
	      [--retry==<max failure retries>] \\\
	      [--server-base-path==</confine/api>] \\\
	      [--node-base-path==</confine/api>] \\\
	      [--logfile=<path to logfile>] \\\
	      [--logsize=<max-logfile-size-in-bytes>] \\\
	      ")
	os.exit(0)
end


function check_direct_ifaces( ifaces, picky )

	local sys_devices = lsys.net.devices()
	local direct_ifaces = {}
	
	local k,v
	local n=0
	for k,v in pairs(ifaces) do
		
		if type(v)=="string" and (v:match("^eth[%d]+$") or v:match("^wlan[%d]+$")) and tools.get_table_by_key_val(sys_devices,v) then
			
			n=n+1
			direct_ifaces[tostring(n)] = v
			
		else
			
			tools.dbg("val=%s Invalid interface prefix or Interface does not exits!", tostring(v))
			if picky then
				return false
			end
		end
	end
	
	return direct_ifaces
end

function get_system_conf(sys_conf, arg)

	if not uci.is_clean("confine") or not uci.is_clean("confine-slivers") then return false end
	
	local conf = sys_conf or {}
	local flags = {}
	
	if arg then
		local trash
		flags,trash = tools.parse_flags(arg)
		assert( not trash, "Illegal flags: ".. tostring(trash) )
	end
	
	if flags["help"] then
		help()
		return
	end

	conf.debug          	   = conf.debug       or flags["debug"]              or false
	conf.interactive	   = conf.interactive or flags["interactive"]        or false
	conf.count		   = conf.count       or tonumber(flags["count"])    or 0
	conf.interval 		   = conf.interval    or tonumber(flags["interval"]) or tonumber(uci.get("confine", "node", "interval"))    or 60
	conf.retry_limit           = conf.retry_limit or tonumber(flags["retry"])    or tonumber(uci.get("confine", "node", "retry_limit")) or 0
	conf.err_cnt		   = conf.err_cnt     or 0
	conf.logfile               = conf.logfile     or flags["logfile"]  or uci.get("confine", "node", "logfile")     or LOG_FILE
	if conf.logfile then tools.logfile = conf.logfile end

	conf.logsize               = conf.logsize     or flags["logsize"]  or uci.get("confine", "node", "logsize")     or LOG_SIZE
	if conf.logsize then tools.logsize = conf.logsize end

	conf.id                    = tonumber((uci.get("confine", "node", "id") or "x"), 16)
	conf.uuid                  = uci.get("confine", "node", "uuid") or null
	conf.arch                  = tools.canon_arch(nixio.uname().machine)
	conf.sys_revision          = ((tools.subfindex( nixio.fs.readfile( "/etc/banner" ) or "???", "show%?branch=", "\n" ) or "???"):gsub("&rev=","."))
	conf.cns_version           = lutil.exec( "opkg info confine-system" )
	conf.cns_version           = type(conf.cns_version) == "string" and conf.cns_version:match("Version: [^\n]+\n") or "???"
	conf.cns_version           = conf.cns_version:gsub("Version: ",""):gsub(" ",""):gsub("\n","")
	conf.soft_version          = conf.sys_revision .. "-" .. conf.cns_version

	conf.node_pubkey_file      = "/etc/dropbear/openssh_rsa_host_key.pub" --must match /etc/dropbear/dropbear_rsa_*
--	conf.server_cert_file      = "/etc/confine/keys/server.ca"
	conf.node_cert_file        = "/etc/uhttpd.crt.pem" --must match /etc/uhttpd.crt and /etc/uhttpd.key -- http://wiki.openwrt.org/doc/howto/certificates.overview  http://man.cx/req

	conf.mgmt_ipv6_prefix48    = uci.get("confine", "testbed", "mgmt_ipv6_prefix48")
	conf.mgmt_ipv6_prefix	   = conf.mgmt_ipv6_prefix48.."::/48"
	conf.mgmt_ipv6_addr	   = conf.mgmt_ipv6_prefix48..(":%x::2"%{conf.id})

	conf.priv_ipv6_prefix      = (uci.get("confine-defaults", "confine", "priv_ipv6_prefix48")).."::/48"
	conf.debug_ipv6_prefix     = (uci.get("confine-defaults", "confine", "debug_ipv6_prefix48")).."::/48"


	conf.node_base_path        = conf.node_base_path or flags["node-base-path"] or uci.get("confine", "node", "base_path") or NODE_BASE_PATH
	assert(conf.node_base_path:match("/api$"), "node-base-path MUST end with /api")
	conf.node_base_uri         = "http://["..conf.mgmt_ipv6_prefix48..":".."%X"%conf.id.."::2]"..conf.node_base_path
--	conf.server_base_uri       = "https://controller.confine-project.eu/api"
	conf.server_base_path      = conf.server_base_path or flags["server-base-path"] or uci.get("confine", "server", "base_path") or SERVER_BASE_PATH
	assert(conf.server_base_path:match("/api$"), "server-base-path MUST end with /api")
	conf.server_base_uri       = lsys.getenv("SERVER_URI") or "https://["..conf.mgmt_ipv6_prefix48.."::2]"..conf.server_base_path
	
	conf.local_iface           = uci.get("confine", "node", "local_ifname")
	
	conf.sys_state             = uci.get("confine", "node", "state")
	conf.boot_sn               = tonumber(uci.get("confine", "node", "boot_sn", 0))


	conf.tinc_node_key_priv    = "/etc/tinc/confine/rsa_key.priv" -- required
	conf.tinc_node_key_pub     = "/etc/tinc/confine/rsa_key.pub"  -- created by confine_node_enable
	conf.tinc_hosts_dir        = "/etc/tinc/confine/hosts/"       -- required
	conf.tinc_conf_file        = "/etc/tinc/confine/tinc.conf"    -- created by confine_tinc_setup
	conf.tinc_pid_file         = "/var/run/tinc.confine.pid"
	
	conf.ssh_node_auth_file    = "/etc/dropbear/authorized_keys"


	
	conf.priv_ipv4_prefix      = uci.get("confine", "node", "priv_ipv4_prefix24") .. ".0/24"
	conf.sliver_mac_prefix     = "0x" .. uci.get("confine", "node", "mac_prefix16"):gsub(":", "")
	
	conf.sl_pub_ipv4_proto     = uci.get("confine", "node", "sl_public_ipv4_proto")
	conf.sl_pub_ipv4_addrs     = uci.get("confine", "node", "sl_public_ipv4_addrs")
	conf.sl_pub_ipv4_total     = tonumber(uci.get("confine", "node", "public_ipv4_avail"))	

	conf.direct_ifaces = check_direct_ifaces(
				ctree.copy_recursive_rebase_keys(
				    tools.str2table((uci.get("confine", "node", "rd_if_iso_parents") or ""),"[%a%d_]+"),
				    "direct_ifaces") )

	
	conf.lxc_if_keys           = uci.get("lxc", "general", "lxc_if_keys" )

--	conf.uci = {}
--	conf.uci.confine           = uci.get_all("confine")
	conf.uci_slivers           = uci.get_all("confine-slivers")
	
	conf.sliver_system_dir     = uci.get("lxc", "general", "lxc_images_path").."/"
	
	conf.sliver_template_dir   = uci.get("lxc", "general", "lxc_templates_path").."/"
	
	conf.disk_max_per_sliver   = tonumber(uci.get("confine", "node", "disk_max_per_sliver")  or DFLT_SLIVER_DISK_MAX_MB)
	conf.disk_dflt_per_sliver  = tonumber(uci.get("confine", "node", "disk_dflt_per_sliver") or DFLT_SLIVER_DISK_DFLT_MB)
	conf.disk_reserved         = tonumber(uci.get("confine", "node", "disk_reserved")        or DFLT_SLIVER_DISK_RESERVED_MB)
	conf.disk_avail            = math.floor(tonumber(lutil.exec( "df -P "..conf.sliver_template_dir .."/ | tail -1 | awk '{print $4}'" )) / 1024) - conf.disk_reserved
	

	data.file_put( conf, system_state_file )

	if conf.sys_state ~= "started" then
		tools.err("Confine system config NOT in state=started (current state=%s)!", conf.sys_state)
		stop()
	end

	return conf
end

function set_system_conf( sys_conf, opt, val, section)
	
	assert(opt and type(opt)=="string", "set_system_conf()")
	
	if not val then
	
	elseif opt == "boot_sn" and
		type(val)=="number" and 		
		uci.set("confine", "node", opt, val) then
		
		return get_system_conf(sys_conf)
		
	elseif opt == "uuid" and
		type(val)=="string" and not uci.get("confine", "node", opt) and
		uci.set("confine", "node", opt, val) then
		
		return get_system_conf(sys_conf)
		
	elseif opt == "sys_state" and
		(val=="prepared" or val=="applied" or val=="failure") and
		uci.set("confine", "node", "state", val) then
		
		if val=="failure" then
			stop()
		end
		
		return get_system_conf(sys_conf)
		

	elseif opt == "priv_ipv4_prefix" and (val==null or val=="") then
		
		return get_system_conf(sys_conf)
		
	elseif opt == "priv_ipv4_prefix" and
		type(val)=="string" and val:gsub(".0/24",""):match("[0-255].[0-255].[0-255]") and
		uci.set("confine", "node", "priv_ipv4_prefix24", val:gsub(".0/24","") ) then
		
		return get_system_conf(sys_conf)


	elseif opt == "direct_ifaces" and type(val) == "table" then
		
		local ifaces = check_direct_ifaces( val, true )
		tools.dbg( "iftable="..tools.table2string(ifaces, " ", 1).." ifstr="..tostring(table.concat(ifaces)) )
		if ifaces and uci.set("confine", "node", "rd_if_iso_parents", tools.table2string(ifaces, " ", 1) ) then
			return get_system_conf(sys_conf)
		end
		
	elseif opt == "sliver_mac_prefix" and (val==null or val=="") then
		
		return get_system_conf(sys_conf)

	elseif opt == "sliver_mac_prefix" and type(val) == "string" then
		
		local dec = tonumber(val,16) or 0
		local msb = math.modf(dec / 256)
		local lsb = dec - (msb*256)
		
		if msb > 0 and msb <= 255 and lsb >= 0 and lsb <= 255 and
			uci.set("confine","node","mac_prefix16", "%.2x:%.2x"%{msb,lsb}) then
			
			return get_system_conf(sys_conf)
		end
		
	elseif opt == "disk_max_per_sliver" or opt == "disk_dflt_per_sliver" and
		type(val)=="number" and val <= 10000 and
		uci.set("confine", "node", opt, val) then
		
		return get_system_conf(sys_conf)

	elseif opt=="uci_sliver" and
		type(val)=="table" and type(section)=="string" and
		uci.set_section_opts( "confine-slivers", section, val) then
		
		return get_system_conf(sys_conf)
	--elseif opt == "uci_slivers" and
	--	type(val) == "table" and
	--	uci.set_all( "confine-slivers", val) then
	--	
	--	return get_system_conf(sys_conf)
		
	end
		
	assert(false, "ERR_SETUP: Invalid opt=%s val=%s section=%s" %{opt, tostring(val), tostring(section)})
	
end



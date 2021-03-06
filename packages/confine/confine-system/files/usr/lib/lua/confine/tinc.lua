--[[



]]--

--- CONFINE data io library.
module( "confine.tinc", package.seeall )

local nixio  = require "nixio"
local sig    = require "signal"

local ctree  = require "confine.tree"
local cdata  = require "confine.data"
local crules = require "confine.rules"
local ssl    = require "confine.ssl"
local tools  = require "confine.tools"
local dbg    = tools.dbg


local TINC_PORT = 655



local function get_mgmt_nets(sys_conf, all)
	
	local nets = {}
	local node_name = "node_" .. sys_conf.id
	
	local hosts = nixio.fs.dir( sys_conf.tinc_hosts_dir )
	--if not (type(hosts)=="table" and hosts["server"] and hosts[node_name]) then
	--	tools.err("Missing hosts in "..sys_conf.tinc_hosts_dir)
	--end
	local name
	for name in hosts do
			
		local is_mine = (name==node_name)
			
		if all or not is_mine then
			
			local content = nixio.fs.readfile( sys_conf.tinc_hosts_dir..name )
			
--			dbg( sys_conf.tinc_hosts_dir..file.." = "..content )
			if type(content)=="string" then
				local subnet = tools.subfind(content,"Subnet","\n")
				subnet = subnet and subnet:gsub(" ",""):gsub("Subnet=",""):gsub("\n","")
				subnet = subnet and subnet:gsub("/[%d]+$","")
--				subnet = subnet and subnet:match("^[%x]+:.*/[%d]+")
--				dbg(tostring(subnet))
				subnet = subnet and tools.canon_ipv6(subnet) and subnet
				
				local addr  = tools.subfind(content,"Address","\n")
				addr = addr and addr:match("[%d]+%.[%d]+%.[%d]+%.[%d]+")
				
				local port  = tools.subfind(content,"Port","\n") or (addr and tools.subfind(content,"Address","\n"):match(" [%d]+[^.]+\n"))
				port = port and tonumber( (port and (port:match("[%d]+"))) or TINC_PORT )
				
				local pubkey = tools.subfind(content,ssl.RSA_HEADER,ssl.RSA_TRAILER)
				
				if subnet and pubkey then
					
					local tinc = {
						addresses	= not is_mine and {[1]={addr=(addr or cdata.null), port=(port or cdata.null)}} or nil,
						is_active	= true,
						name		= name,
						pubkey		= pubkey
					} 
					
					nets[name] = {
						addr		= is_mine and sys_conf.mgmt_ipv6_addr or subnet,
						backend		= is_mine and "tinc_client" or "tinc_server",
						native		= cdata.null,
						tinc_client	= is_mine and tinc or cdata.null,
						tinc_server	= is_mine and cdata.null or tinc
					}
				else
					dbg("Missing host=%s subnet=%s addr=%s port=%s pubkey=%s",
					    sys_conf.tinc_hosts_dir..name, tostring(subnet), tostring(addr), tostring(port), tostring(pubkey))
				end
				
			end
		end
	end
	
	return nets
end

function get_node_mgmt_net( sys_conf, cached_net )
	local net = ((get_mgmt_nets( sys_conf, true) or {})["node_"..sys_conf.id]) or cdata.null
	
	if type(net)=="table" and type(cached_net)=="table" then
		net.native = cached_net.native
		if type(net.tinc_client)=="table" and type(cached_net.tinc_client)=="table" then
			net.tinc_client.island = cached_net.tinc_client.island
		end
	end
	
	return net
end
--
--function get_lserver( sys_conf )
--	return ((get_mgmt_nets( sys_conf, false) or {})["server"]) or cdata.null
--end
--
--function get_lgateways( sys_conf )
--	local gateways = get_mgmt_nets( sys_conf, false) or {}
--	gateways.server = nil
--	return gateways
--end



local function renew_tinc_conf (sys_conf, nets)

	local out = io.open(sys_conf.tinc_conf_file, "w")
	assert(out, "Failed to open %s" %file)
	
	out:write( "Name = node_"..sys_conf.id.."\n")
	
	local k,v
	for k,v in pairs(nets) do
		out:write( "ConnectTo = "..v.tinc_server.name.."\n")
	end
	
	out:close()
	
	local pid = nixio.fs.readfile( sys_conf.tinc_pid_file )
	if pid then
		dbg("sending SIGHUP to %s=%d", sys_conf.tinc_pid_file, tonumber(pid))
		nixio.kill(tonumber(pid),sig.SIGHUP)
	end

end

local function check_tinc_conf( sys_conf )

	local nets = get_mgmt_nets(sys_conf)
		
	local content = nixio.fs.readfile( sys_conf.tinc_conf_file )
	
	local node_name = content and tools.subfind(content, "Name","\n")
	
	if not content or not node_name or node_name:gsub(" ",""):gsub("\n","") ~= "Name=node_"..sys_conf.id then
		renew_tinc_conf(sys_conf, nets)
	else
		local k,v
		for k,v in pairs(nets) do
			if not content:match("ConnectTo *= *%s" %v.tinc_server.name) then
				dbg("check_tinc_conf() NO ConnectTo for %s in %s",
				    sys_conf.tinc_hosts_dir..v.tinc_server.name, sys_conf.tinc_conf_file)
				renew_tinc_conf(sys_conf, nets)
				return
			end
		end
		
		local s=0
		while true do
				
			local t_line,b,e = tools.subfind(content:sub(s+1), "ConnectTo", "\n")
			
			if t_line then

				s = s + e

				local t_name = t_line:gsub(" ",""):gsub("\n",""):gsub("ConnectTo=","")
				
				if not nets[t_name] then
					dbg("check_tinc_conf() NO %s for %s in %s",
					    sys_conf.tinc_hosts_dir..t_name, t_line:gsub("\n",""), sys_conf.tinc_conf_file)
					renew_tinc_conf(sys_conf, nets)
					return
				end
			else
				return
			end
		end
	end
end


local function add_mgmt_net(sys_conf, net)

	assert( sys_conf and net)

	local address = net.addr
	local backend = net[net.backend]
	
	if backend.is_active~=false then

		tools.mkdirr(sys_conf.tinc_hosts_dir)
	
		local file = sys_conf.tinc_hosts_dir .. backend.name
		
		local out = io.open(file, "w")
		assert(out, "Failed to open %s" %file)
		
		if type(backend.addresses)=="table" then
			local k,v
			for k,v in pairs(backend.addresses) do
				out:write( "Address = "..v.addr.." "..v.port.."\n")
--				out:write( "Port = "   ..v.port.."\n")
			end
		end
		out:write( "Subnet = "..address.."/128".."\n" )
		out:write( backend.pubkey.."\n" )
	
		out:close()
		
		check_tinc_conf(sys_conf)
	end
	
	return true	
end

local function del_mgmt_net(sys_conf, name)

	assert( type(name)=="string")
	
	if name == "node_"..sys_conf.id then
		dbg("NOT removing own tinc host="..sys_conf.tinc_hosts_dir..name)
	else
		pcall( nixio.fs.remove, sys_conf.tinc_hosts_dir..name )
		check_tinc_conf(sys_conf)
		return true
	end
end


function cb2_mgmt_backend_name( rules, sys_conf, otree, ntree, path, begin, changed )
	if not rules then return "cb2_mgmt_backend_name" end
	
	local old = ctree.get_path_val(otree,path)
	local new = ctree.get_path_val(ntree,path)

	if type(old)=="string" and type(new)=="string" and old~=new then
		del_mgmt_net(sys_conf, old)
	end
end



function cb2_mgmt_net( rules, sys_conf, otree, ntree, path, begin, changed )
	if not rules then return "cb2_mgmt_net" end

	local old = ctree.get_path_val(otree,path)
	local new = ctree.get_path_val(ntree,path)
	--assert( type(old)=="table" or type(new)=="table" )

	if begin and not new and old then

		del_mgmt_net( sys_conf, old.tinc_server.name)
		ctree.set_path_val(otree, path, nil)
		
	elseif begin and new then
		
		if not old then
			dbg("adding empty mgmt_net")
			ctree.set_path_val(otree, path, {})
			dbg("added empty mgmt_net")
		end
		
		local failure = false
		failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."addr", "string", {"[%x]+:.*:[%x]+"} ) or failure
		failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."backend", "string", {"^tinc_server$", "^tinc_client$"} ) or failure

		if new.backend=="tinc_server" then
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_client", type(cdata.null), {cdata.null} ) or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server", "table") or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server/addresses", "table") or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server/addresses/1", "table") or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server/addresses/1/addr", "string", {"^[%d]+%.[%d]+%.[%d]+%.[%d]+$"}) or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server/addresses/1/port", "number") or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server/is_active", "boolean") or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server/name", "string") or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server/pubkey", "string", {"^%s.*%s$"%{ssl.RSA_HEADER,ssl.RSA_TRAILER}}) or failure
		else
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_server", type(cdata.null), {cdata.null} ) or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_client", "table") or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_client/name", "string") or failure
			failure = not crules.chk_or_err( crules.add_error, otree, ntree, path.."tinc_client/pubkey", "string", {"^%s.*%s$"%{ssl.RSA_HEADER,ssl.RSA_TRAILER}}) or failure
		end
		
		
		if failure then
			tools.err("Invalid mgmt_net path=%s! Keeping old!", path)
			--if old then
			--	del_mgmt_net( sys_conf, old.tinc_server.name)
			--end
			ctree.set_path_val( otree, path, nil )
		end

		
	elseif not begin and new and old and changed then
		
		dbg("apply mgmt_net")

		if old.backend and old[old.backend] then			
			del_mgmt_net( sys_conf, old[old.backend].name )
			add_mgmt_net( sys_conf, old )
		else
			ctree.set_path_val( otree, path, nil )
		end
	end
	
	return true
end



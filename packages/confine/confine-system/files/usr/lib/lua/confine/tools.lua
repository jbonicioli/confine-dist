 --[[



]]--

--- CONFINE tools library.
module( "confine.tools", package.seeall )

local lucifs = require "luci.fs"
local socket  = require "socket"
local nixio   = require "nixio"


logfile = false
logsize = 1000


function dbg_(nl, err, func, fmt, ...)
	local t = nixio.times()
	local l = "[%s.%d] %-7s %s%s" %{os.date("%Y%m%d-%H%M%S"), (t.utime + t.stime + t.cutime + t.cstime), func, string.format(fmt,...), nl and "\n" or "" }
	if err then
		io.stderr:write("ERROR "..l)
	else
		io.stdout:write(l)
	end
	
	if logfile then
		
		local stat = nixio.fs.stat(logfile)
		if stat and stat.size > logsize then
			nixio.fs.move(logfile, logfile..".old")
		end
		
		local out = io.open(logfile, "a")
		assert(out, "Failed to open %s" %logfile)
		out:write(l)
		out:close()
	end

	--io.stdout:write(string.format("[%d.%3d] ", os.time(), t.utime + t.stime + t.cutime + t.cstime))
	--io.stdout:write((debug.getinfo(2).name or "???").."() ")
	--io.stdout:write(string.format(fmt, ...))
	--if nl then io.stdout:write("\n") end
end

function dbg(fmt, ...)
	dbg_(true, false, debug.getinfo(2).name or "???", fmt, ...)
end

function err(fmt, ...)
	dbg_(true, true, debug.getinfo(2).name or "???", fmt, ...)
end



function execute(cmd)
	dbg(cmd)
	local result = os.execute(cmd)
	dbg("return code = %s",result)
	return result
end


--- Extract flags from an arguments list.
-- Given string arguments, extract flag arguments into a flags set.
-- For example, given "foo", "--tux=beep", "--bla", "bar", "--baz",
-- it would return the following:
-- {["bla"] = true, ["tux"] = "beep", ["baz"] = true}, "foo", "bar".
function parse_flags(args)
--   local args = {...}
   local flags = {}
   for i = #args, 1, -1 do
      local flag = args[i]:match("^%-%-(.*)")
      if flag then
         local var,val = flag:match("([a-z_%-]*)=(.*)")
         if val then
            flags[var] = val
         else
            flags[flag] = true
         end
         table.remove(args, i)
      end
   end
   return flags, unpack(args)
end

stop = false

function handler(signo)
	nixio.signal(nixio.const.SIGINT,  "ign")
	nixio.signal(nixio.const.SIGTERM, "ign")
	if not stop then
		dbg("going to stop now...")
	end
	stop = true
end

wakeup = false

function wakeup(signo)
   dbg("going to wakeup now...")
   wakeup = true
end

function sleep(sec)
	local interval=1
	if stop then
		return
	else
		dbg("sleeping for %s seconds...", sec)
	end
		
	while sec>0 do
		if stop or wakeup then
			wakeup = false
			return
		end
		if sec > interval then
			sec = sec - interval
		else
			interval = sec
			sec = 0
		end
		socket.select(nil, nil, interval)
	end
end



function canon_arch(arch)
	--if arch == "amd64" or arch == "x86_64" or
	--   arch == "i386"  or arch == "i486" or
	--   arch == "i586"  or arch == "i686"
	--then
	--	return "x86"
	--end

	return arch
end

function canon_ipv6(ipv6)

	local cidr = luci.ip.IPv6(ipv6)
	
	if cidr then
		return cidr:string()
	end
end

function mkdirr( path, mode )
	local first = 0
	local last = path:len()

	while true do
		local sub = path:sub(first + 1)
		local pos = sub:find( "/" )
		if pos then
			first = first + pos
			local dir = string.sub(path, 1, first)
			if not lucifs.isdirectory(dir) then
				--dbg("mkdir "..dir)
				nixio.fs.mkdir( dir, mode )
			end
			assert( lucifs.isdirectory(dir), "Failed creating dir=%s" %dir )
		else
			return
		end
	end
end

function join_tables( t1, t2 )
	local tn = {}
	local k,v
	for k,v in pairs(t1) do tn[k] = v end
	for k,v in pairs(t2) do tn[k] = v end
	return tn
end

function get_table_items( t )
	local count = 0
	local k,v
	for k,v in pairs(t) do
		count = count + 1
		--dbg("get_table_items() c=%s k=%s v=%s", count, k, tostring(v))
	end
	--dbg("get_table_items() t=%s c=%s", tostring(t), count)
	return count
end

function get_table_by_key_val( t, val, key )
	
	local k,v
	for k,v in pairs(t) do
		if key then
			if t[k][key] == val then
				return t[k]
			end
		else
			if t[k] == val then
				return k
			end
		end
	end
	return nil
end

function is_table_value( t, val, path )
	local k,v
	for k,v in pairs(t) do
		
		local curr = (path and path.."/"..k) or "/"..k
		
		if v == val then
			
			return curr
		
		elseif type(v)=="table" then
			
			local found = is_table_value( v, val, curr )
			
			if found then
				return found
			end
		end
	end
end

function fname()
	return debug.getinfo(2).name.."() "
end

function str2table( str, pattern )

	if not pattern then pattern = "%a+" end
	
	local t = {}
	local word
	for word in string.gmatch( str, pattern ) do
		t[#t+1] = word
	end
	
	return t
end

function table2string( tree, separator, maxdepth )
--	luci.util.dumptable(obj):gsub("%s"%tostring(cdata.null),"null")
	if not maxdepth then maxdepth = 1 end
	if not separator then separator = " " end
	if type(tree)~="table" then return tostring(tree) end
	local result = ""
	local k,v
	for k,v in pairs(tree or {}) do
			
		if type(v) ~= "table"  then
			result = (result=="" and result or result..separator) .. tostring(v)
		else
			assert( maxdepth > 1, "maxdepth reached!")
			local sub_result = table2string(v, separator, (maxdepth - 1))
			if sub_result ~= "" then
				result = (result=="" and result or result..separator) .. sub_result
			end
		end
	end
	return result
end


function subfind(str, start_pattern, end_pattern )

	local i,j = str:find(start_pattern)
	
	if i and j then
		
		if end_pattern then
			local k,l = str:sub(j+1):find(end_pattern)
	
--			dbg("sp=%s=%s %d %d ep=%s=%s %d %d found:\n%s",
--			    start_pattern,str:sub(i,j), i, j, end_pattern, str:sub(j+k,j+l), k, l, str:sub(i,j+l) )
			
			if (k and l) then
				return (str:sub(i,j+l)), i, (j+l)
			else
				return nil
			end
		end
		
		return str:sub(i), i, str:len()
	end	
end

function subfindex( str, start_pattern, end_pattern )
	local res,i,j = subfind(str, start_pattern, end_pattern)
	
	if res then
		if end_pattern then		
			return res:gsub( "^%s"%start_pattern,""):gsub("%s$"%end_pattern,""),
				(i+(start_pattern:len())), (j-(end_pattern:len()))
		else
			return res:gsub( "^%s"%start_pattern,""), (i+(start_pattern:len())), j
		end
	end
end

function min(a,b)
	if tonumber(a) < tonumber(b) then
		return tonumber(a)
	else
		return tonumber(b)
	end
end

function max(a,b)
	if tonumber(a) > tonumber(b) then
		return tonumber(a)
	else
		return tonumber(b)
	end
end

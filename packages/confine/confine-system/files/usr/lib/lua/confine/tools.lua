--[[



]]--

--- CONFINE data io library.
module( "confine.tools", package.seeall )

local lucifs = require "luci.fs"

function dbg(fmt, ...)
	local t = nixio.times()
	io.stdout:write(string.format("[%d.%3d] ", os.time(),
	                              t.utime + t.stime + t.cutime + t.cstime))
	io.stdout:write(string.format(fmt, ...))
	io.stdout:write("\n")
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
				dbg("mkdir "..dir)
				nixio.fs.mkdir( dir, mode )
			end
			assert( lucifs.isdirectory(dir), "Failed creating dir=%s" %dir )
		else
			return
		end
	end
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

function str2table( str, pattern )

	if not pattern then pattern = "%a+" end
	
	local t = {}
	local word
	for word in string.gmatch( str, pattern ) do
		t[#t+1] = word
	end
	
	return t
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
		return res:gsub( "^%s"%start_pattern,""):gsub("%s$"%end_pattern,""), (i+(start_pattern:len())), (j-(end_pattern:len()))
	end
end
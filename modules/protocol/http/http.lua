-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

require("protocol/tcp-connection")

local module = {}

local str = string.char


--
-- HTTP utilities
--

local function contains(table, elem)
	return table[elem] ~= nil
end

local function dict(table)
	local ret = {}
	for _, v in pairs(table) do
		ret[v] = true
	end
	return ret
end

local _unreserved = dict({45, 46, 95, 126})

local function uri_safe_decode(uri)
	local uri = string.gsub(uri, '%%(%x%x)',
		function(p)
			local val = tonumber(p, 16)
			if (val > 47 and val < 58) or
			   (val > 64 and val < 91) or
			   (val > 96 and val < 123) or
			   (contains(_unreserved, val)) then
				return str(val)
			else
				return '%' .. string.upper(p)
			end
		end)
	return uri
end

local function uri_safe_decode_split(tab)
	for k, v in pairs(tab) do
		if type(v) == 'table' then
			uri_safe_decode_split(v)
		else
			tab[k] = uri_safe_decode(v)
		end
	end
end

local _prefixes = {{'^%.%./', ''}, {'^%./', ''}, {'^/%.%./', '/'}, {'^/%.%.$', '/'}, {'^/%./', '/'}, {'^/%.$', '/'}}

local function remove_dot_segments(path)
	local output = {}
	local slash = ''
	local nb = 0
	if path:sub(1,1) == '/' then slash = '/' end
	while path ~= '' do
		local index = 0
		for _, prefix in ipairs(_prefixes) do
			path, nb = path:gsub(prefix[1], prefix[2])
			if nb > 0 then
				if index == 2 or index == 3 then
					table.remove(output, #output)
				end
				break
			end
			index = index + 1
		end
		if nb == 0 then
			if path:sub(1,1) == '/' then path = path:sub(2) end
			local left, right = path:match('([^/]*)([/]?.*)')
			table.insert(output, left)
			path = right
		end
	end
	return slash .. table.concat(output, '/')
end

-- register methods on splitted uri object
local mt_uri = {}
mt_uri.__index = mt_uri

function mt_uri:__tostring()
	local uri = {}

	-- authority components
	local auth = {}

	-- host
	if self.host then
		-- userinfo
		if self.user and self.pass then
			table.insert(auth, self.user)
			table.insert(auth, ':')
			table.insert(auth, self.pass)
			table.insert(auth, '@')
		end

		table.insert(auth, self.host)

		--port
		if self.port then
			table.insert(auth, ':')
			table.insert(auth, self.port)
		end
	end

	-- scheme and authority
	if #auth > 0 then
		if self.scheme then
			table.insert(uri, self.scheme)
			table.insert(uri, '://')
			table.insert(uri, table.concat(auth))
		else
			table.insert(uri, table.concat(auth))
		end
	end

	-- path
	if self.path then
		table.insert(uri, self.path)
	end

	-- query
	if self.query then
		local query = {}
		for k, v in pairs(self.args) do
			local q = {}
			table.insert(q, k)
			table.insert(q, v)
			table.insert(query, table.concat(q, '='))
		end

		if #query > 0 then
			table.insert(uri, '?')
			table.insert(uri, table.concat(query, '&'))
		end
	end

	-- fragment
	if self.fragment then
		table.insert(uri, '#')
		table.insert(uri, self.fragment)
	end

	return table.concat(uri)
end


function mt_uri:normalize()
	assert(self)
	-- decode percent-encoded octets of unresserved chars
	-- capitalize letters in escape sequences
	uri_safe_decode_split(self)

	-- use http as default scheme
	if not self.scheme and self.authority then
		self.scheme = 'http'
	end

	-- scheme and host are not case sensitive
	if self.scheme then self.scheme = string.lower(self.scheme) end
	if self.host then self.host = string.lower(self.host) end

	-- remove default port
	if self.port and self.port == '80' then
		self.port = nil
	end

	-- add '/' to path
	if self.scheme == 'http' and (not self.path or self.path == '') then
		self.path = '/'
	end

	-- normalize path according to rfc 3986
	if self.path then self.path = remove_dot_segments(self.path) end

	return self

end


local function uri_split(uri)
	if not uri then return nil end

	local splitted_uri = {}
	local core_uri
	local query, fragment, path, authority

	setmetatable(splitted_uri, mt_uri)

	-- uri = core_uri [ ?query ] [ #fragment ]
	core_uri, query, fragment =
	    string.match(uri, '([^#?]*)[%?]*([^#]*)[#]*(.*)')

	-- query (+ split params)
	if query and query ~= '' then
		splitted_uri.query = query
		local args = {}
		string.gsub(splitted_uri.query, '([^=&]+)=([^&?]*)&?',
		    function(p, q) args[p] = q return '' end)
		splitted_uri.args = args
	end

	-- fragment
	if fragment and fragment ~= '' then
		splitted_uri.fragment = fragment
	end

	-- scheme
	local temp = string.gsub(core_uri, '^(%a*)://',
	    function(p) if p ~= '' then splitted_uri.scheme = p end return '' end)

	-- authority and path
	authority, path = string.match(temp, '([^/]*)([/]*.*)$')

	if (path and path ~= '') then
		splitted_uri.path = path
	end

	-- authority = [ userinfo @ ] host [ : port ]
	if authority and authority ~= '' then
		splitted_uri.authority = authority
		-- userinfo
		authority = string.gsub(authority, "^([^@]*)@",
		    function(p) if p ~= '' then splitted_uri.userinfo = p end return '' end)
		-- port
		authority = string.gsub(authority, ":([^:][%d]+)$",
		    function(p) if p ~= '' then splitted_uri.port = p end return '' end)
		-- host
		if authority ~= '' then splitted_uri.host = authority end
		-- userinfo = user : password (deprecated usage)
		if not splitted_uri.userinfo then return splitted_uri end

		local user, pass = string.match(splitted_uri.userinfo, '(.*):(.*)')
		if user and user ~= '' then
			splitted_uri.user = user
			splitted_uri.pass = pass
		end
	end
	return splitted_uri
end

local function uri_normalize(uri)
	local splitted_uri = uri_split(uri)
	splitted_uri:normalize()
	return tostring(splitted_uri)
end


-- register methods on splitted cookie list
local mt_cookie = {}
mt_cookie.__index = mt_cookie

function mt_cookie:__tostring()
	assert(self)
	local cookie = {}
	for k, v in pairs(self) do
		local ck = {}
		table.insert(ck, k)
		table.insert(ck, v)
		table.insert(cookie, table.concat(ck, '='))
	end
	return table.concat(cookie, ';')
end

local function cookies_split(cookie_line)
	local cookies = {}
	if cookie_line then
		string.gsub(cookie_line, '([^=;]+)=([^;?]*);?',
		    function(p, q) cookies[p] = q return '' end)
	end
	setmetatable(cookies, mt_cookie)
	return cookies
end

module.uri = {}
module.cookies = {}
module.uri.split = uri_split
module.uri.normalize = uri_normalize
module.cookies.split = cookies_split


--
-- HTTP Grammar
--

local begin_grammar = haka.grammar.verify(function (self, ctx)
	self._length = ctx.iter.meter
end)

local end_grammar = haka.grammar.verify(function (self, ctx)
	self._length = ctx.iter.meter-self._length
end)

-- http separator tokens
local WS = haka.grammar.token('[[:blank:]]+')
local CRLF = haka.grammar.token('[%r]?%n')

-- http request version
local version = haka.grammar.record{
	haka.grammar.token('HTTP/'),
	haka.grammar.field('_num', haka.grammar.token('[0-9]+%.[0-9]+'))
}:extra{
	num = function (self)
		return tonumber(self._num)
	end
}

-- http response status code
local status = haka.grammar.record{
	haka.grammar.field('_num', haka.grammar.token('[0-9]{3}'))
}:extra{
	num = function (self)
		return tonumber(self._num)
	end
}

-- http request line
local request_line = haka.grammar.record{
	haka.grammar.field('method', haka.grammar.token('[^()<>@,;:%\\"/%[%]?={}[:blank:]]+')),
	WS,
	haka.grammar.field('uri', haka.grammar.token('[[:alnum:][:punct:]]+')),
	WS,
	haka.grammar.field('version', version),
	CRLF
}

-- http reply line
local response_line = haka.grammar.record{
	haka.grammar.field('version', version),
	WS,
	haka.grammar.field('status', status),
	WS,
	haka.grammar.field('reason', haka.grammar.token('[^%r%n]+')),
	CRLF
}

-- headers list
local header = haka.grammar.record{
	haka.grammar.field('name', haka.grammar.token('[^:[:blank:]]+')),
	haka.grammar.token(':'),
	WS,
	haka.grammar.field('value', haka.grammar.token('[^%r%n]+')),
	CRLF
}

local header_or_crlf = haka.grammar.branch(
	{
		header = header,
		crlf = CRLF
	},
	function (self, ctx)
		local la = ctx:lookahead()
		if la == 0xa or la == 0xd then return 'crlf'
		else return 'header' end
	end
)

local headers = haka.grammar.record{
	haka.grammar.field('headers', haka.grammar.array(header_or_crlf):
		options{ untilcond = function (elem, ctx) return elem and not elem.name end })
}

-- http request
local request = haka.grammar.record{
	begin_grammar,
	request_line,
	headers,
	end_grammar
}:compile()

-- http response
local response = haka.grammar.record{
	begin_grammar,
	response_line,
	headers,
	end_grammar
}:compile()


--
-- HTTP dissector
--

local http_dissector = haka.dissector.new{
	type = haka.dissector.FlowDissector,
	name = 'http'
}

http_dissector:register_event('request')
http_dissector:register_event('response')

http_dissector.property.connection = {
	get = function (self)
		self.connection = self.flow.connection
		return self.connection
	end
}

function http_dissector.method:__init(flow)
	super(http_dissector).__init(self)
	self.flow = flow
	if flow then
		self.connection = flow.connection
	end
	self._state = 'request'
end

function http_dissector.method:continue()
	return self.flow ~= nil
end

function http_dissector.method:drop()
	self.flow:drop()
	self.flow = nil
end

function http_dissector.method:reset()
	self.flow:reset()
	self.flow = nil
end

local function build_headers(result, headers, headers_order)
	for _, name in pairs(headers_order) do
		local value = headers[name]
		if value then
			table.insert(result, name)
			table.insert(result, ": ")
			table.insert(result, value)
			table.insert(result, "\r\n")
		end
	end
	local headers_copy = dict(headers_order)
	for name, value in sorted_pairs(headers) do
		if value and not contains(headers_copy, name) then
			table.insert(result, name)
			table.insert(result, ": ")
			table.insert(result, value)
			table.insert(result, "\r\n")
		end
	end
end

-- The comparison is broken in Lua 5.1, so we need to reimplement the
-- string comparison
local function string_compare(a, b)
	if type(a) == "string" and type(b) == "string" then
		local i = 1
		local sa = #a
		local sb = #b

		while true do
			if i > sa then
				return false
			elseif i > sb then
				return true
			end

			if a:byte(i) < b:byte(i) then
				return true
			elseif a:byte(i) > b:byte(i) then
				return false
			end

			i = i+1
		end

		return false
	else
		return a < b
	end
end

local function dump(t, indent)
	if not indent then indent = "" end

	for n, v in sorted_pairs(t) do
		if n ~= '__property' and n ~= '_validate' then
			if type(v) == "table" then
				print(indent, n)
				dump(v, indent .. "  ")
			elseif type(v) ~= "thread" and
				type(v) ~= "userdata" and
				type(v) ~= "function" then
				print(indent, n, "=", v)
			end
		end
	end
end

local function convert_headers(hdrs)
	local headers = {}
	local headers_order = {}
	for _, header in ipairs(hdrs) do
		if header.name then
			headers[header.name] = header.value
			table.insert(headers_order, header.name)
		end
	end
	return headers, headers_order
end

local function convert_request(request)
	request.version = string.format("HTTP/%s", request.version._num)
	request.headers, request._headers_order = convert_headers(request.headers)
	request.dump = dump
	return request
end

local function convert_response(response)
	response.version = string.format("HTTP/%s", response.version._num)
	response.status = response.status._num
	response.headers, response._headers_order = convert_headers(response.headers)
	response.dump = dump
	return response
end

local ctx_object = class('http_ctx')

function http_dissector.method:receive(flow, iter, direction)
	assert(flow == self.flow)

	local mark

	if direction == 'up' then
		while iter:check_available(1) do
			if self._state == 'request' then
				self.request = ctx_object:new()
				self.response = nil

				self.request.split_uri = function (self)
					if self._splitted_uri then
						return self._splitted_uri
					else
						self._splitted_uri = uri_split(self.uri)
						return self._splitted_uri
					end
				end

				self.request.split_cookies = function (self)
					if self._cookies then
						return self._cookies
					else
						self._cookies = cookies_split(self.headers['Cookie'])
						return self._cookies
					end
				end

				if haka.packet.mode() ~= haka.packet.PASSTHROUGH then
					mark = iter:copy()
					mark:mark()
				end

				request:parseall(iter, self.request)
				if not self:continue() then return end

				self.request = convert_request(self.request)

				if not haka.pcall(haka.context.signal, haka.context, self, http_dissector.events.request, self.request) then
					self:drop()
				end

				if not self:continue() then return end

				self:send(iter, mark, direction)
				self._state = 'response'
			else
				iter:advance('available')
			end
		end
	else
		while iter:check_available(1) do
			if self._state == 'response' then
				self.response = ctx_object:new()
				if haka.packet.mode() ~= haka.packet.PASSTHROUGH then
					mark = iter:copy()
					mark:mark()
				end

				response:parseall(iter, self.response)
				if not self:continue() then return end

				self.response = convert_response(self.response)

				if not haka.pcall(haka.context.signal, haka.context, self, http_dissector.events.response, self.response) then
					self:drop()
				end

				if not self:continue() then return end

				self:send(iter, mark, direction)
				self._state = 'request'
			else
				iter:advance('available')
			end
		end
	end
end

function http_dissector.method:send(iter, mark, direction)
	if direction == 'up' then
		if haka.packet.mode() == haka.packet.PASSTHROUGH then
			return
		end

		local request = {}
		table.insert(request, self.request.method)
		table.insert(request, " ")
		table.insert(request, self.request.uri)
		table.insert(request, " ")
		table.insert(request, self.request.version)
		table.insert(request, "\r\n")
		build_headers(request, self.request.headers, self.request._headers_order)
		table.insert(request, "\r\n")

		mark:unmark()
		iter:move_to(mark)

		iter:sub(self.request._length, true):replace(haka.vbuffer(table.concat(request)))
	else
		if self.request.method == 'CONNECT' then
			self._state = 'connect' -- We should not expect a request nor response anymore
		end

		if haka.packet.mode() == haka.packet.PASSTHROUGH then
			return
		end

		local response = {}
		table.insert(response, self.response.version)
		table.insert(response, " ")
		table.insert(response, self.response.status)
		table.insert(response, " ")
		table.insert(response, self.response.reason)
		table.insert(response, "\r\n")
		build_headers(response, self.response.headers, self.response._headers_order)
		table.insert(response, "\r\n")

		mark:unmark()
		iter:move_to(mark)

		iter:sub(self.response._length, true):replace(haka.vbuffer(table.concat(response)))
	end
end

function module.install_tcp_rule(port)
	haka.rule{
		hook = haka.event('tcp-connection', 'new_connection'),
		eval = function (flow, pkt)
			if pkt.dstport == port then
				haka.log.debug('http', "selecting http dissector on flow")
				haka.context:install_dissector(http_dissector:new(flow))
			end
		end
	}
end

http_dissector.connections = haka.events.StaticEventConnections:new()
http_dissector.connections:register(haka.event('tcp-connection', 'receive_data'),
	haka.events.method(haka.events.self, http_dissector.method.receive),
	{coroutine=true})

return module

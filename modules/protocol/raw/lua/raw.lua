-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with module
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

#include <haka/config.h>

local module = {}

local raw_dissector = haka.dissector.new{
	type = haka.helper.PacketDissector,
	name = 'raw'
}

local dissectors = {}
local packet_send
local packet_new

function module.register(name, dissector)
	dissectors[name] = dissector
end

raw_dissector.options.drop_unknown_dissector = false

function raw_dissector.method:receive()
	haka.context:signal(self, raw_dissector.events.receive_packet)

	local dissector = module.packet_dissector(self)
	if dissector then
		local next_dissector = dissectors[dissector]
		if next_dissector then
			return next_dissector:receive(self)
		else
			if raw_dissector.options.drop_unknown_dissector then
				haka.log.error("dissector '%s' is unknown", dissector)
				return self:drop()
			else
				return self:send()
			end
		end
	else
		return self:send()
	end
end

function raw_dissector:new(pkt)
	return pkt
end

function raw_dissector:create(size)
	return packet_new(size or 0)
end

function raw_dissector.method:send()
	haka.context:signal(self, raw_dissector.events.send_packet)
	return packet_send(self)
end

function raw_dissector.method:can_continue()
	return self:issent()
end

#ifdef HAKA_FFI

local ffibinding = require("ffibinding")
local lib = ffibinding.load[[
	struct lua_ref *packet_get_luadata(struct packet *pkt);
	int packet_new_ffi(struct packet_object *packet, size_t size);
]]

local ffi = require('ffi')
ffi.cdef[[
	/**
	 * \see haka/packet.h
	 */

	const char *packet_dissector(struct packet *pkt);

	enum packet_status {
		normal,
		forged,
		sent,
	};

	int packet_send(struct packet *pkt);
	void packet_inject(struct packet *pkt);
	void packet_drop(struct packet *pkt);
	const struct time *packet_timestamp(struct packet *pkt);
	uint64_t packet_id(struct packet *pkt);
	enum packet_status packet_state(struct packet *pkt);
	void packet_release(struct packet *pkt);

	struct packet { };
]]

module.packet_dissector = function(self)
	local dissector = ffi.C.packet_dissector(self)
	if dissector == nil then
		return nil
	end
	return ffi.string(dissector)
end

packet_send = ffi.C.packet_send

local prop = {
	timestamp = { get = ffibinding.handle_error(ffi.C.packet_timestamp) },
	payload = { get = haka.C.packet_payload },
	id = { get = function(self) return tonumber(ffibinding.handle_error(ffi.C.packet_id)(self)) end },
	state = { get = ffibinding.handle_error(ffi.C.packet_state) },
	data = {
		get = function(self)
			local ref = lib.packet_get_luadata(self)
			if ref:isvalid() then
				return ref:get()
			else
				local data = {}
				ref:set(data, false)
				return data
			end
		end,
	},
}

local inject = ffibinding.handle_error(ffi.C.packet_inject)

local meth = {
	drop = ffibinding.handle_error(ffi.C.packet_drop),
	inject = function (pkt)
		inject(pkt)
		ffibinding.disown(pkt)
	end,
	send = raw_dissector.method.send,
	receive = raw_dissector.method.receive,
	continue = haka.helper.Dissector.method.continue,
	can_continue = raw_dissector.method.can_continue,
	error = ffibinding.handle_error(ffi.C.packet_drop),
	name = "raw",
	issent = function(pkt) return ffibinding.handle_error(ffi.C.packet_state)(pkt) == "sent" end,
}

ffibinding.create_type("struct packet", prop, meth, {}, ffi.C.packet_release)
local object_wrapper = ffibinding.object_wrapper("struct packet")

local packet_new_check_error = object_wrapper(ffibinding.handle_error(lib.packet_new_ffi))

packet_new = function (size)
	local pkt = packet_new_check_error(size)
	ffibinding.own(pkt)
	return pkt
end

#endif

function haka.filter(pkt)
	raw_dissector:receive(pkt)
end

function module.create(size)
	return raw_dissector:create(size)
end

module.events = raw_dissector.events
module.options = raw_dissector.options

return module
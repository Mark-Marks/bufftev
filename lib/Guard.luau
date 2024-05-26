--!strict
--!native
--!optimize 2

-- Buffer reader / writer

type channel = {
	buff: buffer,
	cursor: number,
	size: number,
}

local NEW_BUFFER_SIZE: number = 1024

local function create_channel(): channel
	return {
		buff = buffer.create(NEW_BUFFER_SIZE),
		cursor = 0,
		size = NEW_BUFFER_SIZE,
	}
end

local ref: channel = create_channel()
local ref_buff: buffer = ref.buff
local ref_cursor: number = ref.cursor
local ref_size: number = ref.size

local function load_channel(channel: channel)
	if ref == channel then
		return
	end

	ref = channel
	ref_buff = channel.buff
	ref_cursor = channel.cursor
	ref_size = channel.size
end

local function save_channel()
	ref.buff = ref_buff
	ref.cursor = ref_cursor
	ref.size = ref_size
end

local function dump_channel(channel: channel): buffer?
	local cursor = channel.cursor
	if cursor == 0 then
		return nil
	end

	local dump = buffer.create(cursor)

	buffer.copy(dump, 0, channel.buff, 0, cursor)

	channel.cursor = 0

	if channel == ref then
		ref_cursor = 0
	end

	return dump
end

local function alloc(bytes: number)
	if ref_cursor + bytes < ref_size then
		return
	end

	ref_size *= 2

	local new = buffer.create(ref_size)
	buffer.copy(new, 0, ref_buff)

	ref_buff = new
end

local function writeu8(value: number)
	buffer.writeu8(ref_buff, ref_cursor, value)
	ref_cursor += 1
end

local function readu8(): number
	ref_cursor += 1
	return buffer.readu8(ref_buff, ref_cursor - 1)
end

local function writeu16(value: number)
	buffer.writeu16(ref_buff, ref_cursor, value)
	ref_cursor += 2
end

local function readu16(): number
	ref_cursor += 2
	return buffer.readu16(ref_buff, ref_cursor - 2)
end

local function writef64(value: number)
	buffer.writef64(ref_buff, ref_cursor, value)
	ref_cursor += 8
end

local function readf64(): number
	ref_cursor += 8
	return buffer.readf64(ref_buff, ref_cursor - 8)
end

local function writebool(value: boolean)
	buffer.writeu8(ref_buff, ref_cursor, if value then 1 else 0)
	ref_cursor += 1
end

local function readbool(): boolean
	ref_cursor += 1
	return buffer.readu8(ref_buff, ref_cursor - 1) == 1
end

local function writestring(value: string, length: number)
	buffer.writestring(ref_buff, ref_cursor, value)
	ref_cursor += length
end

local function readstring(length: number): string
	ref_cursor += length
	return buffer.readstring(ref_buff, ref_cursor - length, length)
end

-- Checks

type check<T> = {
	write: (value: T) -> (),
	read: () -> T,
	check: (value: unknown) -> boolean,
}

local boolean_serdes: check<boolean> = {
	write = function(value)
		alloc(1)
		writebool(value)
	end,
	read = readbool,
	check = function(value)
		return type(value) == "boolean"
	end,
}

local nil_serdes: check<nil> = {
	write = function() end,
	read = function() end,
	check = function(value)
		return value == nil
	end,
}

local number_serdes: check<number> = {
	write = function(value)
		alloc(8)
		writef64(value)
	end,
	read = readf64,
	check = function(value)
		return type(value) == "number"
	end,
}

local string_serdes: check<string> = {
	write = function(value)
		local len = string.len(value)
		alloc(len + 2)
		writeu16(len)
		writestring(value, len)
	end,
	read = function()
		local len = readu16()
		return readstring(len)
	end,
	check = function(value)
		return type(value) == "string"
	end,
}

local function optional_serdes<T>(check: check<T>): check<T?>
	local read = check.read
	local write = check.write
	local typecheck = check.check

	return {
		write = function(value)
			local exists = value ~= nil
			writebool(exists)

			if exists then
				write(value :: T)
			end
		end,
		read = function()
			if not readbool() then
				return nil
			end

			return read()
		end,
		check = function(value)
			return (value and typecheck(value)) or true
		end,
	}
end

local function or_serdes<L, R>(left_check: check<L>, right_check: check<R>): check<L | R>
	local read_left = left_check.read
	local write_left = left_check.write
	local typecheck_left = left_check.check

	local read_right = right_check.read
	local write_right = right_check.write
	local typecheck_right = right_check.check

	return {
		write = function(value)
			local is_left = typecheck_left(value)

			if is_left then
				alloc(1)
				writeu8(1)
				write_left(value :: any)
				return
			end

			alloc(1)
			writeu8(2)
			write_right(value :: any)
		end,
		read = function()
			local which = readu8()
			if which == 1 then
				return read_left()
			end

			return read_right()
		end,
		check = function(value)
			return typecheck_left(value) or typecheck_right(value)
		end,
	}
end

local function map_serdes<K, V>(key_check: check<K>, value_check: check<V>): check<{ [K]: V }>
	local read_key = key_check.read
	local write_key = key_check.write
	local typecheck_key = key_check.check

	local read_value = value_check.read
	local write_value = value_check.write
	local typecheck_value = value_check.check

	return {
		write = function(value)
			local len = 0
			for _ in value do
				len += 1
			end

			writeu16(len)

			for key, value in value do
				write_key(key)
				write_value(value)
			end
		end,
		read = function()
			local len = readu16()
			local map = {}

			for _ = 1, len do
				local key = read_key()
				local value = read_value()

				map[key] = value
			end

			return map
		end,
		check = function(value)
			if type(value) ~= "table" then
				return false
			end

			for key, value in value :: any do
				if typecheck_key(key) and typecheck_value(value) then
					continue
				end

				return false
			end

			return true
		end,
	}
end

local function set_serdes<T>(check: check<T>): check<{ T }>
	return {} :: any --todo
end

local function list_serdes<T>(check: check<T>): check<{ T }>
	local read = check.read
	local write = check.write
	local typecheck = check.check

	return {
		write = function(value)
			local len = #value
			writeu16(len)

			for i = 1, len do
				write(value[i])
			end
		end,
		read = function()
			local len = readu16()
			local list = table.create(len)

			for i = 1, len do
				list[i] = read()
			end

			return list
		end,
		check = function(value)
			if type(value) == "table" then
				return false
			end

			for i = 1, #(value :: any) do
				if typecheck((value :: any)[i]) then
					continue
				end

				return false
			end

			return true
		end,
	}
end

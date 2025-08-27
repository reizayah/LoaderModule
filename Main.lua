local _bit = bit32
local _unpack = table.unpack or unpack

local decode_stream
local create_executor
local process_function

-- Configuration constants
local FLUSH_SIZE = 50

-- Instruction mapping table
local OP_MAP = {
	[22] = 18, [31] = 8, [33] = 28,
	[0] = 3, [1] = 13, [2] = 23, [26] = 33,
	[12] = 1, [13] = 6, [14] = 10, [15] = 16, [16] = 20, [17] = 26, [18] = 30, [19] = 36,
	[3] = 0, [4] = 2, [5] = 4, [6] = 7, [7] = 9, [8] = 12, [9] = 14, [10] = 17, [20] = 19,
	[21] = 22, [23] = 24, [24] = 27, [25] = 29, [27] = 32, [32] = 34, [34] = 37,
	[11] = 5, [28] = 11, [29] = 15, [30] = 21, [35] = 25, [36] = 31, [37] = 35,
}

-- Argument types for instructions
local ARG_TYPES = {
	[0] = 'ABC', 'ABx', 'ABC', 'ABC', 'ABC', 'ABx', 'ABC', 'ABx', 'ABC', 'ABC', 'ABC', 'ABC',
	'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'AsBx', 'ABC',
	'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'ABC', 'AsBx', 'AsBx', 'ABC', 'ABC', 'ABC',
	'ABx', 'ABC',
}

local ARG_MODES = {
	[0] = {b = 'OpArgR', c = 'OpArgN'}, {b = 'OpArgK', c = 'OpArgN'}, {b = 'OpArgU', c = 'OpArgU'},
	{b = 'OpArgR', c = 'OpArgN'}, {b = 'OpArgU', c = 'OpArgN'}, {b = 'OpArgK', c = 'OpArgN'},
	{b = 'OpArgR', c = 'OpArgK'}, {b = 'OpArgK', c = 'OpArgN'}, {b = 'OpArgU', c = 'OpArgN'},
	{b = 'OpArgK', c = 'OpArgK'}, {b = 'OpArgU', c = 'OpArgU'}, {b = 'OpArgR', c = 'OpArgK'},
	{b = 'OpArgK', c = 'OpArgK'}, {b = 'OpArgK', c = 'OpArgK'}, {b = 'OpArgK', c = 'OpArgK'},
	{b = 'OpArgK', c = 'OpArgK'}, {b = 'OpArgK', c = 'OpArgK'}, {b = 'OpArgK', c = 'OpArgK'},
	{b = 'OpArgR', c = 'OpArgN'}, {b = 'OpArgR', c = 'OpArgN'}, {b = 'OpArgR', c = 'OpArgN'},
	{b = 'OpArgR', c = 'OpArgR'}, {b = 'OpArgR', c = 'OpArgN'}, {b = 'OpArgK', c = 'OpArgK'},
	{b = 'OpArgK', c = 'OpArgK'}, {b = 'OpArgK', c = 'OpArgK'}, {b = 'OpArgR', c = 'OpArgU'},
	{b = 'OpArgR', c = 'OpArgU'}, {b = 'OpArgU', c = 'OpArgU'}, {b = 'OpArgU', c = 'OpArgU'},
	{b = 'OpArgU', c = 'OpArgN'}, {b = 'OpArgR', c = 'OpArgN'}, {b = 'OpArgR', c = 'OpArgN'},
	{b = 'OpArgN', c = 'OpArgU'}, {b = 'OpArgU', c = 'OpArgU'}, {b = 'OpArgN', c = 'OpArgN'},
	{b = 'OpArgU', c = 'OpArgN'}, {b = 'OpArgU', c = 'OpArgN'},
}

local function parse_int_generic(data, start_pos, end_pos, direction)
	local result = 0
	for pos = start_pos, end_pos, direction do 
		result = result + string.byte(data, pos, pos) * 256 ^ (pos - start_pos) 
	end
	return result
end

local function parse_float_basic(b1, b2, b3, b4)
	local sign_bit = (-1) ^ _bit.rshift(b4, 7)
	local exp_bits = _bit.rshift(b3, 7) + _bit.lshift(_bit.band(b4, 0x7F), 1)
	local frac_bits = b1 + _bit.lshift(b2, 8) + _bit.lshift(_bit.band(b3, 0x7F), 16)
	local norm_flag = 1

	if exp_bits == 0 then
		if frac_bits == 0 then
			return sign_bit * 0
		else
			norm_flag = 0
			exp_bits = 1
		end
	elseif exp_bits == 0x7F then
		if frac_bits == 0 then
			return sign_bit * (1 / 0)
		else
			return sign_bit * (0 / 0)
		end
	end

	return sign_bit * 2 ^ (exp_bits - 127) * (1 + norm_flag / 2 ^ 23)
end

local function parse_double_basic(b1, b2, b3, b4, b5, b6, b7, b8)
	local sign_bit = (-1) ^ _bit.rshift(b8, 7)
	local exp_bits = _bit.lshift(_bit.band(b8, 0x7F), 4) + _bit.rshift(b7, 4)
	local frac_bits = _bit.band(b7, 0x0F) * 2 ^ 48
	local norm_flag = 1

	frac_bits = frac_bits + (b6 * 2 ^ 40) + (b5 * 2 ^ 32) + (b4 * 2 ^ 24) + (b3 * 2 ^ 16) + (b2 * 2 ^ 8) + b1

	if exp_bits == 0 then
		if frac_bits == 0 then
			return sign_bit * 0
		else
			norm_flag = 0
			exp_bits = 1
		end
	elseif exp_bits == 0x7FF then
		if frac_bits == 0 then
			return sign_bit * (1 / 0)
		else
			return sign_bit * (0 / 0)
		end
	end

	return sign_bit * 2 ^ (exp_bits - 1023) * (norm_flag + frac_bits / 2 ^ 52)
end

local function parse_int_le(data, start_pos, end_pos) 
	return parse_int_generic(data, start_pos, end_pos - 1, 1) 
end

local function parse_int_be(data, start_pos, end_pos) 
	return parse_int_generic(data, end_pos - 1, start_pos, -1) 
end

local function parse_float_le(data, pos) 
	return parse_float_basic(string.byte(data, pos, pos + 3)) 
end

local function parse_float_be(data, pos)
	local b1, b2, b3, b4 = string.byte(data, pos, pos + 3)
	return parse_float_basic(b4, b3, b2, b1)
end

local function parse_double_le(data, pos) 
	return parse_double_basic(string.byte(data, pos, pos + 7)) 
end

local function parse_double_be(data, pos)
	local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(data, pos, pos + 7)
	return parse_double_basic(b8, b7, b6, b5, b4, b3, b2, b1)
end

local numeric_parsers = {
	[4] = {little = parse_float_le, big = parse_float_be},
	[8] = {little = parse_double_le, big = parse_double_be},
}

local function stream_byte(stream_obj)
	local current_idx = stream_obj.index
	local byte_val = string.byte(stream_obj.source, current_idx, current_idx)
	stream_obj.index = current_idx + 1
	return byte_val
end

local function stream_string(stream_obj, length)
	local next_pos = stream_obj.index + length
	local result_str = string.sub(stream_obj.source, stream_obj.index, next_pos - 1)
	stream_obj.index = next_pos
	return result_str
end

local function stream_lstring(stream_obj)
	local str_len = stream_obj:s_szt()
	local result_str
	if str_len ~= 0 then 
		result_str = string.sub(stream_string(stream_obj, str_len), 1, -2) 
	end
	return result_str
end

local function create_int_reader(byte_len, parser_func)
	return function(stream_obj)
		local next_pos = stream_obj.index + byte_len
		local parsed_int = parser_func(stream_obj.source, stream_obj.index, next_pos)
		stream_obj.index = next_pos
		return parsed_int
	end
end

local function create_float_reader(byte_len, parser_func)
	return function(stream_obj)
		local parsed_float = parser_func(stream_obj.source, stream_obj.index)
		stream_obj.index = stream_obj.index + byte_len
		return parsed_float
	end
end

local function parse_instructions(stream_obj)
	local instruction_count = stream_obj:s_int()
	local instruction_table = {}

	for i = 1, instruction_count do
		local raw_instruction = stream_obj:s_ins()
		local opcode = _bit.band(raw_instruction, 0x3F)
		local arg_type = ARG_TYPES[opcode]
		local arg_mode = ARG_MODES[opcode]
		local instruction_data = {
			value = raw_instruction, 
			op = OP_MAP[opcode], 
			A = _bit.band(_bit.rshift(raw_instruction, 6), 0xFF)
		}

		if arg_type == 'ABC' then
			instruction_data.B = _bit.band(_bit.rshift(raw_instruction, 23), 0x1FF)
			instruction_data.C = _bit.band(_bit.rshift(raw_instruction, 14), 0x1FF)
			instruction_data.is_KB = arg_mode.b == 'OpArgK' and instruction_data.B > 0xFF
			instruction_data.is_KC = arg_mode.c == 'OpArgK' and instruction_data.C > 0xFF
		elseif arg_type == 'ABx' then
			instruction_data.Bx = _bit.band(_bit.rshift(raw_instruction, 14), 0x3FFFF)
			instruction_data.is_K = arg_mode.b == 'OpArgK'
		elseif arg_type == 'AsBx' then
			instruction_data.sBx = _bit.band(_bit.rshift(raw_instruction, 14), 0x3FFFF) - 131071
		end

		instruction_table[i] = instruction_data
	end

	return instruction_table
end

local function parse_constants(stream_obj)
	local const_count = stream_obj:s_int()
	local const_table = {}

	for i = 1, const_count do
		local const_type = stream_byte(stream_obj)
		local const_value

		if const_type == 1 then
			const_value = stream_byte(stream_obj) ~= 0
		elseif const_type == 3 then
			const_value = stream_obj:s_num()
		elseif const_type == 4 then
			const_value = stream_lstring(stream_obj)
		end

		const_table[i] = const_value
	end

	return const_table
end

local function parse_subfunctions(stream_obj, source_name)
	local sub_count = stream_obj:s_int()
	local sub_table = {}

	for i = 1, sub_count do
		sub_table[i] = process_function(stream_obj, source_name)
	end

	return sub_table
end

local function parse_line_info(stream_obj)
	local line_count = stream_obj:s_int()
	local line_table = {}

	for i = 1, line_count do 
		line_table[i] = stream_obj:s_int() 
	end

	return line_table
end

local function parse_local_vars(stream_obj)
	local var_count = stream_obj:s_int()
	local var_table = {}

	for i = 1, var_count do 
		var_table[i] = {
			varname = stream_lstring(stream_obj), 
			startpc = stream_obj:s_int(), 
			endpc = stream_obj:s_int()
		} 
	end

	return var_table
end

local function parse_upvalues(stream_obj)
	local upval_count = stream_obj:s_int()
	local upval_table = {}

	for i = 1, upval_count do 
		upval_table[i] = stream_lstring(stream_obj) 
	end

	return upval_table
end

function process_function(stream_obj, parent_source)
	local function_proto = {}
	local source_name = stream_lstring(stream_obj) or parent_source

	function_proto.source = source_name

	stream_obj:s_int() -- skip line defined
	stream_obj:s_int() -- skip last line defined

	function_proto.numupvals = stream_byte(stream_obj)
	function_proto.numparams = stream_byte(stream_obj)

	stream_byte(stream_obj) -- skip vararg flag
	stream_byte(stream_obj) -- skip max stack size

	function_proto.code = parse_instructions(stream_obj)
	function_proto.const = parse_constants(stream_obj)
	function_proto.subs = parse_subfunctions(stream_obj, source_name)
	function_proto.lines = parse_line_info(stream_obj)

	parse_local_vars(stream_obj)
	parse_upvalues(stream_obj)

	-- Post-process optimization
	for _, instruction in ipairs(function_proto.code) do
		if instruction.is_K then
			instruction.const = function_proto.const[instruction.Bx + 1]
		else
			if instruction.is_KB then 
				instruction.const_B = function_proto.const[instruction.B - 0xFF] 
			end
			if instruction.is_KC then 
				instruction.const_C = function_proto.const[instruction.C - 0xFF] 
			end
		end
	end

	return function_proto
end

function decode_stream(binary_data)
	local parser_func
	local is_little_endian
	local int_size, szt_size, ins_size, num_size
	local is_int_format

	local stream_obj = {
		index = 1,
		source = binary_data,
	}

	-- Verify Lua signature
	local signature = stream_string(stream_obj, 4)
	assert(signature == '\27Lua', 'invalid Lua signature')

	-- Verify version
	local version = stream_byte(stream_obj)
	assert(version == 0x51, 'invalid Lua version')

	-- Verify format
	local format = stream_byte(stream_obj)
	assert(format == 0, 'invalid Lua format')

	is_little_endian = stream_byte(stream_obj) ~= 0
	int_size = stream_byte(stream_obj)
	szt_size = stream_byte(stream_obj)
	ins_size = stream_byte(stream_obj)
	num_size = stream_byte(stream_obj)
	is_int_format = stream_byte(stream_obj) ~= 0

	parser_func = is_little_endian and parse_int_le or parse_int_be
	stream_obj.s_int = create_int_reader(int_size, parser_func)
	stream_obj.s_szt = create_int_reader(szt_size, parser_func)
	stream_obj.s_ins = create_int_reader(ins_size, parser_func)

	if is_int_format then
		stream_obj.s_num = create_int_reader(num_size, parser_func)
	elseif numeric_parsers[num_size] then
		stream_obj.s_num = create_float_reader(num_size, numeric_parsers[num_size][is_little_endian and 'little' or 'big'])
	else
		error('unsupported float size')
	end

	return process_function(stream_obj, '@virtual')
end

local function close_upvalues(upvalue_list, target_index)
	for key, upval in pairs(upvalue_list) do
		if upval.index >= target_index then
			upval.value = upval.store[upval.index]
			upval.store = upval
			upval.index = 'value'
			upvalue_list[key] = nil
		end
	end
end

local function open_upvalue(upvalue_list, target_index, stack_ref)
	local existing_upval = upvalue_list[target_index]

	if not existing_upval then
		existing_upval = {index = target_index, store = stack_ref}
		upvalue_list[target_index] = existing_upval
	end

	return existing_upval
end

local function pack_variadic(...) 
	return select('#', ...), {...} 
end

local function handle_error(exec_state, error_msg)
	local source_name = exec_state.source
	local line_num = exec_state.lines[exec_state.pc - 1]
	local parsed_source, parsed_line, parsed_msg = string.match(error_msg or '', '^(.-):(%d+):%s+(.+)')
	local format_str = '%s:%i: [%s:%i] %s'

	line_num = line_num or '0'
	parsed_source = parsed_source or '?'
	parsed_line = parsed_line or '0'
	parsed_msg = parsed_msg or error_msg or ''

	error(string.format(format_str, source_name, line_num, parsed_source, parsed_line, parsed_msg), 0)
end

local function execute_function(exec_state)
	local instruction_list = exec_state.code
	local sub_functions = exec_state.subs
	local environment = exec_state.env
	local upvalue_list = exec_state.upvals
	local variadic_args = exec_state.varargs

	local stack_top = -1
	local open_upvals = {}
	local stack = exec_state.stack
	local program_counter = exec_state.pc

	while true do
		local current_inst = instruction_list[program_counter]
		local operation = current_inst.op
		program_counter = program_counter + 1

		if operation < 18 then
			if operation < 8 then
				if operation < 3 then
					if operation < 1 then
						-- LOADNIL
						for i = current_inst.A, current_inst.B do 
							stack[i] = nil 
						end
					elseif operation > 1 then
						-- GETUPVAL
						local target_upval = upvalue_list[current_inst.B]
						stack[current_inst.A] = target_upval.store[target_upval.index]
					else
						-- ADD
						local left_operand, right_operand
						if current_inst.is_KB then
							left_operand = current_inst.const_B
						else
							left_operand = stack[current_inst.B]
						end
						if current_inst.is_KC then
							right_operand = current_inst.const_C
						else
							right_operand = stack[current_inst.C]
						end
						stack[current_inst.A] = left_operand + right_operand
					end
				elseif operation > 3 then
					if operation < 6 then
						if operation > 4 then
							-- SELF
							local reg_a = current_inst.A
							local reg_b = current_inst.B
							local table_index
							if current_inst.is_KC then
								table_index = current_inst.const_C
							else
								table_index = stack[current_inst.C]
							end
							stack[reg_a + 1] = stack[reg_b]
							stack[reg_a] = stack[reg_b][table_index]
						else
							-- GETGLOBAL
							stack[current_inst.A] = environment[current_inst.const]
						end
					elseif operation > 6 then
						-- GETTABLE
						local table_index
						if current_inst.is_KC then
							table_index = current_inst.const_C
						else
							table_index = stack[current_inst.C]
						end
						stack[current_inst.A] = stack[current_inst.B][table_index]
					else
						-- SUB
						local left_operand, right_operand
						if current_inst.is_KB then
							left_operand = current_inst.const_B
						else
							left_operand = stack[current_inst.B]
						end
						if current_inst.is_KC then
							right_operand = current_inst.const_C
						else
							right_operand = stack[current_inst.C]
						end
						stack[current_inst.A] = left_operand - right_operand
					end
				else
					-- MOVE
					stack[current_inst.A] = stack[current_inst.B]
				end
			elseif operation > 8 then
				if operation < 13 then
					if operation < 10 then
						-- SETGLOBAL
						environment[current_inst.const] = stack[current_inst.A]
					elseif operation > 10 then
						if operation < 12 then
							-- CALL
							local reg_a = current_inst.A
							local reg_b = current_inst.B
							local reg_c = current_inst.C
							local param_count
							local return_count, return_values

							if reg_b == 0 then
								param_count = stack_top - reg_a
							else
								param_count = reg_b - 1
							end

							return_count, return_values = pack_variadic(stack[reg_a](_unpack(stack, reg_a + 1, reg_a + param_count)))

							if reg_c == 0 then
								stack_top = reg_a + return_count - 1
							else
								return_count = reg_c - 1
							end

							for i = 1, return_count do 
								stack[reg_a + i - 1] = return_values[i] 
							end
						else
							-- SETUPVAL
							local target_upval = upvalue_list[current_inst.B]
							target_upval.store[target_upval.index] = stack[current_inst.A]
						end
					else
						-- MUL
						local left_operand, right_operand
						if current_inst.is_KB then
							left_operand = current_inst.const_B
						else
							left_operand = stack[current_inst.B]
						end
						if current_inst.is_KC then
							right_operand = current_inst.const_C
						else
							right_operand = stack[current_inst.C]
						end
						stack[current_inst.A] = left_operand * right_operand
					end
				elseif operation > 13 then
					if operation < 16 then
						if operation > 14 then
							-- TAILCALL
							local reg_a = current_inst.A
							local reg_b = current_inst.B
							local param_count

							if reg_b == 0 then
								param_count = stack_top - reg_a
							else
								param_count = reg_b - 1
							end

							close_upvalues(open_upvals, 0)
							return pack_variadic(stack[reg_a](_unpack(stack, reg_a + 1, reg_a + param_count)))
						else
							-- SETTABLE
							local table_index, table_value
							if current_inst.is_KB then
								table_index = current_inst.const_B
							else
								table_index = stack[current_inst.B]
							end
							if current_inst.is_KC then
								table_value = current_inst.const_C
							else
								table_value = stack[current_inst.C]
							end
							stack[current_inst.A][table_index] = table_value
						end
					elseif operation > 16 then
						-- NEWTABLE
						stack[current_inst.A] = {}
					else
						-- DIV
						local left_operand, right_operand
						if current_inst.is_KB then
							left_operand = current_inst.const_B
						else
							left_operand = stack[current_inst.B]
						end
						if current_inst.is_KC then
							right_operand = current_inst.const_C
						else
							right_operand = stack[current_inst.C]
						end
						stack[current_inst.A] = left_operand / right_operand
					end
				else
					-- LOADK
					stack[current_inst.A] = current_inst.const
				end
			else
				-- FORLOOP
				local reg_a = current_inst.A
				local step_val = stack[reg_a + 2]
				local index_val = stack[reg_a] + step_val
				local limit_val = stack[reg_a + 1]
				local should_loop

				if step_val == math.abs(step_val) then
					should_loop = index_val <= limit_val
				else
					should_loop = index_val >= limit_val
				end

				if should_loop then
					stack[current_inst.A] = index_val
					stack[current_inst.A + 3] = index_val
					program_counter = program_counter + current_inst.sBx
				end
			end
		elseif operation > 18 then
			if operation < 28 then
				if operation < 23 then
					if operation < 20 then
						-- LEN
						stack[current_inst.A] = #stack[current_inst.B]
					elseif operation > 20 then
						if operation < 22 then
							-- RETURN
							local reg_a = current_inst.A
							local reg_b = current_inst.B
							local return_vals = {}
							local return_size

							if reg_b == 0 then
								return_size = stack_top - reg_a + 1
							else
								return_size = reg_b - 1
							end

							for i = 1, return_size do 
								return_vals[i] = stack[reg_a + i - 1] 
							end

							close_upvalues(open_upvals, 0)
							return return_size, return_vals
						else
							-- CONCAT
							local concat_str = stack[current_inst.B]
							for i = current_inst.B + 1, current_inst.C do 
								concat_str = concat_str .. stack[i] 
							end
							stack[current_inst.A] = concat_str
						end
					else
						-- MOD
						local left_operand, right_operand
						if current_inst.is_KB then
							left_operand = current_inst.const_B
						else
							left_operand = stack[current_inst.B]
						end
						if current_inst.is_KC then
							right_operand = current_inst.const_C
						else
							right_operand = stack[current_inst.C]
						end
						stack[current_inst.A] = left_operand % right_operand
					end
				elseif operation > 23 then
					if operation < 26 then
						if operation > 24 then
							-- CLOSE
							close_upvalues(open_upvals, current_inst.A)
						else
							-- EQ
							local left_operand, right_operand
							if current_inst.is_KB then
								left_operand = current_inst.const_B
							else
								left_operand = stack[current_inst.B]
							end
							if current_inst.is_KC then
								right_operand = current_inst.const_C
							else
								right_operand = stack[current_inst.C]
							end
							if (left_operand == right_operand) == (current_inst.A ~= 0) then 
								program_counter = program_counter + instruction_list[program_counter].sBx 
							end
							program_counter = program_counter + 1
						end
					elseif operation > 26 then
						-- LT
						local left_operand, right_operand
						if current_inst.is_KB then
							left_operand = current_inst.const_B
						else
							left_operand = stack[current_inst.B]
						end
						if current_inst.is_KC then
							right_operand = current_inst.const_C
						else
							right_operand = stack[current_inst.C]
						end
						if (left_operand < right_operand) == (current_inst.A ~= 0) then 
							program_counter = program_counter + instruction_list[program_counter].sBx 
						end
						program_counter = program_counter + 1
					else
						-- POW
						local left_operand, right_operand
						if current_inst.is_KB then
							left_operand = current_inst.const_B
						else
							left_operand = stack[current_inst.B]
						end
						if current_inst.is_KC then
							right_operand = current_inst.const_C
						else
							right_operand = stack[current_inst.C]
						end
						stack[current_inst.A] = left_operand ^ right_operand
					end
				else
					-- LOADBOOL
					stack[current_inst.A] = current_inst.B ~= 0
					if current_inst.C ~= 0 then 
						program_counter = program_counter + 1 
					end
				end
			elseif operation > 28 then
				if operation < 33 then
					if operation < 30 then
						-- LE
						local left_operand, right_operand
						if current_inst.is_KB then
							left_operand = current_inst.const_B
						else
							left_operand = stack[current_inst.B]
						end
						if current_inst.is_KC then
							right_operand = current_inst.const_C
						else
							right_operand = stack[current_inst.C]
						end
						if (left_operand <= right_operand) == (current_inst.A ~= 0) then 
							program_counter = program_counter + instruction_list[program_counter].sBx 
						end
						program_counter = program_counter + 1
					elseif operation > 30 then
						if operation < 32 then
							-- CLOSURE
							local sub_proto = sub_functions[current_inst.Bx + 1]
							local upval_count = sub_proto.numupvals
							local upval_list

							if upval_count ~= 0 then
								upval_list = {}
								for i = 1, upval_count do
									local pseudo_inst = instruction_list[program_counter + i - 1]
									if pseudo_inst.op == OP_MAP[0] then
										upval_list[i - 1] = open_upvalue(open_upvals, pseudo_inst.B, stack)
									elseif pseudo_inst.op == OP_MAP[4] then
										upval_list[i - 1] = upvalue_list[pseudo_inst.B]
									end
								end
								program_counter = program_counter + upval_count
							end

							stack[current_inst.A] = create_executor(sub_proto, environment, upval_list)
						else
							-- TESTSET
							local reg_a = current_inst.A
							local reg_b = current_inst.B
							if (not stack[reg_b]) == (current_inst.C ~= 0) then
								program_counter = program_counter + 1
							else
								stack[reg_a] = stack[reg_b]
							end
						end
					else
						-- UNM
						stack[current_inst.A] = -stack[current_inst.B]
					end
				elseif operation > 33 then
					if operation < 36 then
						if operation > 34 then
							-- VARARG
							local reg_a = current_inst.A
							local arg_size = current_inst.B
							if arg_size == 0 then
								arg_size = variadic_args.size
								stack_top = reg_a + arg_size - 1
							end
							for i = 1, arg_size do 
								stack[reg_a + i - 1] = variadic_args.list[i] 
							end
						else
							-- FORPREP
							local reg_a = current_inst.A
							local init_val, limit_val, step_val

							init_val = assert(tonumber(stack[reg_a]), '`for` initial value must be a number')
							limit_val = assert(tonumber(stack[reg_a + 1]), '`for` limit must be a number')
							step_val = assert(tonumber(stack[reg_a + 2]), '`for` step must be a number')

							stack[reg_a] = init_val - step_val
							stack[reg_a + 1] = limit_val
							stack[reg_a + 2] = step_val

							program_counter = program_counter + current_inst.sBx
						end
					elseif operation > 36 then
						-- SETLIST
						local reg_a = current_inst.A
						local reg_c = current_inst.C
						local list_size = current_inst.B
						local target_table = stack[reg_a]
						local base_offset

						if list_size == 0 then 
							list_size = stack_top - reg_a 
						end

						if reg_c == 0 then
							reg_c = current_inst[program_counter].value
							program_counter = program_counter + 1
						end

						base_offset = (reg_c - 1) * FLUSH_SIZE

						for i = 1, list_size do 
							target_table[i + base_offset] = stack[reg_a + i] 
						end
					else
						-- NOT
						stack[current_inst.A] = not stack[current_inst.B]
					end
				else
					-- TEST
					if (not stack[current_inst.A]) == (current_inst.C ~= 0) then 
						program_counter = program_counter + 1 
					end
				end
			else
				-- TFORLOOP
				local reg_a = current_inst.A
				local iter_func = stack[reg_a]
				local iter_state = stack[reg_a + 1]
				local iter_index = stack[reg_a + 2]
				local base_reg = reg_a + 3
				local iter_vals

				stack[base_reg + 2] = iter_index
				stack[base_reg + 1] = iter_state
				stack[base_reg] = iter_func

				iter_vals = {iter_func(iter_state, iter_index)}

				for i = 1, current_inst.C do 
					stack[base_reg + i - 1] = iter_vals[i] 
				end

				if stack[base_reg] ~= nil then
					stack[reg_a + 2] = stack[base_reg]
				else
					program_counter = program_counter + 1
				end
			end
		else
			-- JMP
			program_counter = program_counter + current_inst.sBx
		end

		exec_state.pc = program_counter
	end
end

function create_executor(function_state, environment, upvalue_list)
	local state_code = function_state.code
	local state_subs = function_state.subs
	local state_lines = function_state.lines
	local state_source = function_state.source
	local state_params = function_state.numparams

	local function execution_wrapper(...)
		local execution_stack = {}
		local variadic_table = {}
		local variadic_size = 0
		local arg_count, arg_list = pack_variadic(...)

		local exec_state
		local success, error_or_count, return_values

		for i = 1, state_params do 
			execution_stack[i - 1] = arg_list[i] 
		end

		if state_params < arg_count then
			variadic_size = arg_count - state_params
			for i = 1, variadic_size do 
				variadic_table[i] = arg_list[state_params + i] 
			end
		end

		exec_state = {
			varargs = {list = variadic_table, size = variadic_size},
			code = state_code,
			subs = state_subs,
			lines = state_lines,
			source = state_source,
			env = environment,
			upvals = upvalue_list,
			stack = execution_stack,
			pc = 1,
		}

		success, error_or_count, return_values = pcall(execute_function, exec_state, ...)

		if success then
			return _unpack(return_values, 1, error_or_count)
		else
			handle_error(exec_state, error_or_count)
		end

		return
	end

	return execution_wrapper
end

return function(bytecode_data, environment)
	return create_executor(decode_stream(bytecode_data), environment or {})
end

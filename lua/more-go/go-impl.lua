local ts_utils = require("nvim-treesitter.ts_utils")
local parsers = require("nvim-treesitter.parsers")
local job = require("plenary.job")

local config = {}

---@class Config
config.options = {
	---@type nil|"snacks"|"fzf_lua"
	---@usage nil - Use snacks if available, otherwise use fzf-lua
	---@usage "snacks" - Use folke/snacks picker
	---@usage "fzf_lua" - Use ibhagwan/fzf-lua
	picker = "snacks",
	receiver = {
		---Predict the abbreviation for the current struct
		---@param struct_name? string The Go struct name
		---@return string abbreviation The predicted abbreviation
		predict_abbreviation = function(struct_name)
			if not struct_name then
				return ""
			end

			local abbreviation = ""
			abbreviation = abbreviation .. string.sub(struct_name, 1, 1)
			for i = 2, #struct_name do
				local char = string.sub(struct_name, i, i)
				if char == string.upper(char) and char ~= string.lower(char) then
					abbreviation = abbreviation .. char
				end
			end
			return string.lower(abbreviation) .. " *" .. struct_name
		end,
	},

	insert = {
		---@type "after"|"before"|"end"
		---@usage "after" - insert after the receiver's struct declaration
		---@usage "before" - insert before the receiver's struct declaration
		---@usage "end" - insert at the end of the file
		position = "after",
		before_newline = true, -- additional newline before the implementation
		after_newline = false, -- additional newline after the implementation
	},
	icons = {
		interface = {
			text = "󰰄 ",
			hl = "GoImplInterfaceIcon",
		},
		go = {
			text = " ",
			hl = "GoImplGoBlue",
		},
	},
	prompt = {
		receiver = " 󰆼  > ",
		interface = " 󰰄  > ",
		generic = " 󰘻  {name} > ",
	},
	style = {
		---@type nui_popup_options
		---The NuiPopup options for the popup that used to get the receiver
		receiver_input = {
			relative = "cursor",
			position = { row = 1, col = 0 },
			size = 40,
			border = { style = "rounded", text = { top_align = "center" } },
			win_options = {
				winhighlight = "Normal:Normal,FloatBorder:GoImplGoBlue,FloatTitle:GoImplGoBlue",
			},
		},
		---@type nui_popup_options
		---The NuiPopup options for the previewer that used to get the generic arguments
		generic_argument_input = {
			border = {
				style = "rounded",
				text = {
					top_align = "center",
				},
			},
			win_options = {
				winhighlight = "Normal:Normal,FloatBorder:GoImplGoBlue,FloatTitle:GoImplGoBlue",
			},
		},
		---@type nui_popup_options
		---The NuiPopup options for the previewer that used to show the interface declaration
		generic_argument_previewer = {
			border = {
				padding = {
					top = 0,
					bottom = 0,
					left = 2,
					right = 2,
				},
				style = "rounded",
			},
			win_options = {
				winhighlight = "Normal:Normal,FloatBorder:Normal",
			},
		},
		---@type nui_layout_options
		---The NuiLayout options for the popup that used to get the generic arguments
		generic_argument_layout = {
			position = "50%",
			size = {
				width = 80,
				height = 20,
			},
		},
		interface_selector = {
			interface_icon = true,
			query_highlight = true,
			query_highlight_hl = "GoImplGoBlue",
			package_highlight = true,
			package_highlight_hl = "GoImplHighlight",
		},
	},
}

---Merge the user options with the default options
---@param user_opts Config
function config.init(user_opts)
	config.options = vim.tbl_deep_extend("force", config.options, user_opts)
	vim.api.nvim_set_hl(0, "GoImplGoBlue", { fg = "#6BC6F0", bold = true })
	vim.api.nvim_set_hl(0, "GoImplInterfaceIcon", { fg = "#a9b665", bold = true })
	vim.api.nvim_set_hl(0, "GoImplHighlight", { fg = "#ea6962", bold = true })
end

local S = {}

function S.env()
	if S.env_initiated then
		return
	end
	S.env_initiated = true
	S.lsp = require("snacks.picker.source.lsp")
end

function S.is_loaded()
	local is_loaded = pcall(require, "snacks")
	if is_loaded then
		S.env()
	end
	return is_loaded
end

---Get the interface from the user using fzf-lua
---@param co thread
---@return InterfaceData
function S.get_interface(co)
	Snacks.picker.lsp_workspace_symbols({
		finder = S.symbols,
		prompt = config.options.prompt.interface,
		title = "go-impl",
		---@diagnostic disable-next-line: missing-fields
		icons = {
			kinds = {
				Interface = config.options.icons.interface.text,
			},
		},
		filter = {
			go = {
				"Interface",
			},
		},
		confirm = function(picker, item)
			picker:close()
			coroutine.resume(co, item)
		end,
		transform = function(item)
			item.containerName = item.item.containerName
		end,
	})

	local selected = coroutine.yield()

	return {
		col = selected.pos[2] + 1,
		line = selected.pos[1],
		path = selected.file,
		package = selected.containerName,
	}
end

local H = {}

local ts_query_struct = vim.treesitter.query.parse(
	"go",
	[[
        (type_declaration
            (type_spec
                name: (type_identifier) @struct_name
                type: (struct_type)
            )
        ) @struct_declaration
    ]]
)

local ts_query_interface = vim.treesitter.query.parse(
	"go",
	[[
        (type_spec
            name: (type_identifier) @base_name
            type_parameters: (type_parameter_list
                (type_parameter_declaration
                    name: (identifier) @generic_name
                    type: (type_constraint) @generic_type
                )
            )? @parameter_list
            type: (interface_type)
        )
    ]]
)

---Get the gopls client for the current buffer
---@param bufnr integer The buffer number
---@return vim.lsp.Client? client The gopls client
function H.get_gopls(bufnr)
	local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "gopls" })
	return clients and clients[1]
end

---Try to get the current struct name under the cursor
---@return string? struct_name The struct name
function H.get_struct_at_cursor()
	local node = ts_utils.get_node_at_cursor()

	while node and node:type() ~= "type_spec" do
		node = node:parent()
	end
	if not node then
		return
	end

	-- Tree-sitter node structure:
	-- (type_declaration
	--   (type_spec
	--   name: (type_identifier)
	--   type: (struct_type
	--       (field_declaration_list
	--       (field_declaration
	--       ...
	---@type table<string, TSNode>
	local nodes = {}
	for child, field in node:iter_children() do
		nodes[field] = child
	end

	if not nodes["type"] or not nodes["name"] then
		return
	end
	if nodes["type"]:type() ~= "struct_type" then
		return
	end

	local node_text = vim.treesitter.get_node_text(nodes["name"], 0)
	if not node_text then
		return
	end
	return node_text
end

---Check the validity of the go receiver string, and return the last line number of the struct
---@param receiver string? The receiver string
---@return integer? lnum The line number of the struct
function H.get_lnum(receiver)
	if not receiver or #receiver == 0 then
		return
	end

	local struct_name = string.match(receiver, "^%a+%s%*?(.*)$")
	if not struct_name then
		return
	end

	local root_lang_tree = parsers.get_parser(0)
	if not root_lang_tree then
		return
	end

	root_lang_tree:parse()
	local trees = root_lang_tree:trees()
	local root = trees and trees[1] and trees[1]:root()
	if not root then
		return
	end

	---@type TSNode?
	local current_struct_node = nil
	for id, capture_node in ts_query_struct:iter_captures(root, 0) do
		local capture = ts_query_struct.captures[id]
		local text = vim.treesitter.get_node_text(capture_node, 0)

		if capture == "struct_declaration" then
			current_struct_node = capture_node
		elseif capture == "struct_name" then
			if struct_name == text and current_struct_node then
				local start_row, _, end_row = current_struct_node:range(false)
				local lnum = vim.fn.line("$")
				if config.options.insert.position == "after" and end_row then
					lnum = end_row + 1
				elseif config.options.insert.position == "before" and start_row then
					lnum = start_row - 1
				end
				return lnum
			end
		end
	end
end

---@class GenericParameter
---@field name string
---@field type string

---Fetch the generics options for the interface with given path, line and column
---@param path string The path of the file
---@param line integer The line number of the interface symbol
---@param col integer The column number of the interface symbol
---@return string? interface_declaration The full interface declaration
---@return string? base_interface_name The name of the interface, e.g. "MyInterface"
---@return string? parameter_list The list of generic types, e.g. "[T any]"
---@return GenericParameter[]? generic_parameters The list of generic types
function H.parse_interface(path, line, col)
	-- Convert to 0-based index for treesitter
	line, col = line - 1, col - 1

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("filetype", "go", { buf = buf })

	local lines = vim.fn.readfile(path)
	if not lines or #lines == 0 then
		return
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local root_lang_tree = parsers.get_parser(buf)
	if not root_lang_tree then
		return
	end
	root_lang_tree:parse()

	local root = ts_utils.get_root_for_position(line, col, root_lang_tree)
	if not root then
		return
	end

	local node = root:named_descendant_for_range(line, col, line, col)

	while node and node:type() ~= "type_declaration" do
		node = node:parent()
	end

	if not node then
		return
	end

	local interface_declaration = vim.treesitter.get_node_text(node, buf)
	local base_interface_name = nil
	local parameter_list = nil
	local generic_parameters = {}

	for id, capture_node in ts_query_interface:iter_captures(node, buf) do
		local capture = ts_query_interface.captures[id]
		local text = vim.treesitter.get_node_text(capture_node, buf)

		if capture == "base_name" then
			base_interface_name = text
		elseif capture == "generic_name" then
			table.insert(generic_parameters, { name = text, type = nil })
		elseif capture == "generic_type" then
			-- For some cases like [T, K any], there is no `generic_type` parsed for `T`
			-- So we need to find reverse and assign the type to the first `generic_name` without type
			for i = #generic_parameters, 1, -1 do
				if not generic_parameters[i].type then
					generic_parameters[i].type = text
					break
				end
			end
		elseif capture == "parameter_list" then
			parameter_list = text
		end
	end

	vim.api.nvim_buf_delete(buf, { force = true })

	if not base_interface_name then
		return
	end

	return interface_declaration, base_interface_name, parameter_list, generic_parameters
end

---Run `impl`(https://github.com/josharian/impl) to add implementation for the given interface
---@param receiver string The receiver string
---@param package string The package name
---@param interface_name string The interface name
---@param lnum integer The line number to add the implementation
function H.impl(receiver, package, interface_name, lnum)
	local lines = {}
	local job_config = {
		command = "impl",
		args = {
			"-dir",
			vim.fn.fnameescape(vim.fn.expand("%:p:h")),
			receiver,
			package .. "." .. interface_name,
		},
		on_stdout = function(_, data)
			table.insert(lines, data)
		end,
		on_exit = function(_, code)
			if code ~= 0 then
				vim.notify("Failed to add the implementation", vim.log.levels.ERROR, { title = "go-impl" })
				return
			end

			vim.schedule(function()
				-- before newline
				while #lines > 0 and lines[1] == "" do
					table.remove(lines, 1)
				end

				if config.options.insert.before_newline then
					table.insert(lines, 1, "")
				end

				-- after newline
				while #lines > 0 and lines[#lines] == "" do
					table.remove(lines, #lines)
				end

				if config.options.insert.after_newline then
					table.insert(lines, "")
				end

				vim.fn.append(lnum, lines)
			end)
		end,
	}

	job:new(job_config):start()
end

local nui_input = require("nui.input")
local nui_popup = require("nui.popup")
local nui_text = require("nui.text")
local nui_line = require("nui.line")
local nui_layout = require("nui.layout")
local nui_event = require("nui.utils.autocmd").event

local UI = {}

---@class FuzzyFinder
---@field is_loaded fun(): boolean
---@field get_interface fun(co: thread, bufnr: integer, gopls: vim.lsp.Client): InterfaceData

---@type table<string, FuzzyFinder>
local fuzzy_finders = {
	snacks = S,
}

---Get the receiver input
---@param default_value string? defualt value
---@param callback fun(receiver: string?)
function UI.get_receiver(default_value, callback)
	local nui_opts = vim.tbl_deep_extend("force", config.options.style.receiver_input, {
		border = {
			text = {
				top = nui_line({
					nui_text(" [ "),
					nui_text(config.options.icons.go.text, config.options.icons.go.hl),
					nui_text("Receiver", "Fg"),
					nui_text(" ] "),
				}),
			},
		},
	})

	local input = nui_input(nui_opts, {
		prompt = nui_text(config.options.prompt.receiver, "GoImplHighlight"),
		default_value = default_value,
		on_close = callback,
		on_submit = callback,
		on_change = function() end,
	})

	input:mount()
	for _, event in ipairs({
		nui_event.BufWinLeave,
		nui_event.BufLeave,
		nui_event.InsertLeavePre,
	}) do
		input:on(event, function()
			input:unmount()
		end)
	end
end

---@class GenericOpts
---@field name string
---@field type string
---@field interface_base_name string
---@field generic_parameter_list string
---@field interface_declaration string

---Get the receiver input
---@param opts GenericOpts
---@param callback fun(argument?: string)
function UI.get_generic_argument(opts, callback)
	local bottom_text = nil

	-- Generate type highlighted help text
	local params = vim.split(opts.generic_parameter_list, ",")
	local checked_params = {}
	for i = 1, #params do
		local param = params[i]
		local items = vim.split(vim.trim(param), " ")
		if string.find(items[1], opts.name) then
			local remain = table.concat(params, ",", i)
			local n_start, n_end = string.find(remain, opts.name)
			local t_start, t_end = string.find(remain, opts.type)

			if i > 1 then
				table.insert(checked_params, "") -- add last comma in concatenation
			end
			local normal_left = nui_text(table.concat(checked_params, ",") .. string.sub(remain, 1, n_start - 1))
			local hl_name = nui_text(opts.name, "GoImplHighlight")
			local normal_middle = nui_text(string.sub(remain, n_end + 1, t_start - 1))
			local hl_type = nui_text(opts.type, "GoImplHighlight")
			local normal_right = nui_text(string.sub(remain, t_end + 1))

			bottom_text = nui_line({ normal_left, hl_name, normal_middle, hl_type, normal_right })
			break
		end

		table.insert(checked_params, param)
	end

	local nui_opts = vim.tbl_deep_extend("force", config.options.style.generic_argument_input, {
		border = {
			text = {
				top = nui_line({
					nui_text(" [ "),
					nui_text(config.options.icons.interface.text, config.options.icons.interface.hl),
					nui_text(opts.interface_base_name, "Fg"),
					nui_text(" ] "),
				}),
				bottom = bottom_text,
			},
		},
	})

	local prompt_text = string.gsub(config.options.prompt.generic, "%{name%}", opts.name)

	local input = nui_input(nui_opts, {
		prompt = nui_text(prompt_text, "GoImplHighlight"),
		default_value = "",
		on_close = callback,
		on_submit = callback,
		on_change = function() end,
	})

	local previewer = nui_popup(vim.tbl_deep_extend("force", config.options.style.generic_argument_previewer, {
		enter = false,
		focusable = false,
		buf_options = {
			modifiable = false,
			readonly = true,
			filetype = "go",
		},
	}))

	local preview_lines = vim.split(opts.interface_declaration, "\n")
	vim.api.nvim_buf_set_lines(previewer.bufnr, 0, -1, false, preview_lines)

	local layout = nui_layout(
		config.options.style.generic_argument_layout,
		nui_layout.Box({
			nui_layout.Box(input, { size = 3 }),
			nui_layout.Box(previewer, { grow = 1 }),
		}, { dir = "col" })
	)
	layout:mount()

	local inited = false

	-- Weirdly, the popup is not in insert mode by default, so we need to force it
	vim.defer_fn(function()
		vim.api.nvim_command("startinsert!")
		inited = true
	end, 40)

	input:on({
		nui_event.BufWinLeave,
		nui_event.BufLeave,
		nui_event.InsertLeavePre,
	}, function(ctx)
		if ctx and ctx.event == nui_event.InsertLeavePre and not inited then
			return
		end
		layout:unmount()
	end)
end

---Try to get the interface from the given fuzzy finder
---@param finder "snacks" | "fzf_lua" The fuzzy finder to use
---@param co thread The coroutine to resume
---@param bufnr integer The current buffer number
---@param gopls vim.lsp.Client The gopls client
function UI.try_get_interface(finder, co, bufnr, gopls)
	if not finder or not fuzzy_finders[finder] then
		return nil
	end

	if not fuzzy_finders[finder].is_loaded() then
		return nil
	end

	return fuzzy_finders[finder].get_interface(co, bufnr, gopls)
end

local M = {}

---Open the go-impl user interface
function M.open()
	local bufnr = vim.api.nvim_get_current_buf()
	local gopls = H.get_gopls(bufnr)

	if not gopls then
		vim.notify("No gopls client found in the current buffer", vim.log.levels.WARN, { title = "go-impl" })
		return
	end

	coroutine.wrap(function()
		local co = coroutine.running()

		-- Receiver
		local current_struct_name = H.get_struct_at_cursor()
		local default_value = current_struct_name and config.options.receiver.predict_abbreviation(current_struct_name)
			or ""
		UI.get_receiver(default_value, function(recevier)
			coroutine.resume(co, recevier)
		end)
		local receiver = coroutine.yield()

		-- Get the line number to insert the implentation
		local lnum = H.get_lnum(receiver)
		if not lnum then
			vim.notify("Invalid receiver provided", vim.log.levels.INFO, { title = "go-impl" })
			return
		end

		-- Interface
		---@class InterfaceData
		---@field package string
		---@field path string
		---@field line integer
		---@field col integer

		---@type InterfaceData?
		local interface_data = nil

		if config.options.picker then
			interface_data = UI.try_get_interface(config.options.picker, co, bufnr, gopls)
		else
			for _, finder in ipairs({ "snacks" }) do
				interface_data = UI.try_get_interface(finder, co, bufnr, gopls)
				if interface_data then
					break
				end
			end
		end

		for _, key in pairs({ "package", "path", "line", "col" }) do
			if not interface_data or not interface_data[key] then
				vim.notify("Failed to get the interface data", vim.log.levels.WARN, { title = "go-impl" })
				return
			end
		end

		-- Generic Arguments
		local interface_declaration, interface_base_name, generic_parameter_list, generic_parameters =
			H.parse_interface(interface_data.path, interface_data.line, interface_data.col)
		if not interface_declaration or not interface_base_name or not generic_parameters then
			vim.notify("Failed to parse the selected item", vim.log.levels.WARN, { title = "go-impl" })
			return
		end

		local generic_arguments = {}
		if generic_parameter_list then
			for _, generic_parameter in ipairs(generic_parameters) do
				UI.get_generic_argument({
					name = generic_parameter.name,
					type = generic_parameter.type,
					interface_declaration = interface_declaration,
					interface_base_name = interface_base_name,
					generic_parameter_list = generic_parameter_list,
				}, function(arg)
					coroutine.resume(co, arg)
				end)
				local arg = coroutine.yield()
				if not arg then
					vim.notify(
						"Failed to get the generic type: " .. generic_parameter.name,
						vim.log.levels.ERROR,
						{ title = "go-impl" }
					)
					return
				end
				table.insert(generic_arguments, arg)
			end
		end

		-- Run impl
		local interface_name = interface_base_name
		if #generic_arguments > 0 then
			interface_name = string.format("%s[%s]", interface_base_name, table.concat(generic_arguments, ","))
		end
		H.impl(receiver, interface_data.package, interface_name, lnum)
	end)()
end

---Setup the plugin with the given options
---@param user_opts Config
function M.setup(user_opts)
	config.init(user_opts)

	vim.api.nvim_create_user_command("Impl", M.open, {})
end

return M

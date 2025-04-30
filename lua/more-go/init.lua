local M = {}

M.open = function()
	require("more-go.go-impl").open()
end

M.config = {}

function M.setup()
	vim.api.nvim_set_hl(0, "GoImplGoBlue", { fg = "#6BC6F0", bold = true })
	vim.api.nvim_set_hl(0, "GoImplInterfaceIcon", { fg = "#a9b665", bold = true })
	vim.api.nvim_set_hl(0, "GoImplHighlight", { fg = "#ea6962", bold = true })

	vim.api.nvim_create_user_command("Impl", M.open, {})

	require("more-go.go-return").setup({})
	require("more-go.go-show").setup({})

	require("more-go.go-pkgs-blink").setup({})

	-- local cmp = require("cmp")
	-- if cmp ~= nil then
	-- 	cmp.register_source("go_pkgs", require("more-go.go-pkgs-cmp"))
	-- end
end

return M

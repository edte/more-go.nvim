local cmp = require("cmp")
if cmp ~= nil then
	cmp.register_source("go_pkgs", require("more-go.go-pkgs-cmp"))
end

require("more-go.go-pkgs-blink").setup({})

require("more-go.go-return").setup({})

require("more-go.go-show").setup({})

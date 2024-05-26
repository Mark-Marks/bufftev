--!nocheck
local process = require("@lune/process")

local function spawn(cmd: string)
	local arguments = string.split(cmd, " ")
	local command = arguments[1]
	table.remove(arguments, 1)

	process.spawn(command, arguments, {
		stdio = "forward",
	})
end

spawn("wally install")

spawn("rojo sourcemap dev.project.json -o sourcemap.json")

spawn("wally-package-types --sourcemap sourcemap.json Packages/")

spawn("curl -O https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau")

spawn(
	"luau-lsp analyze --definitions=globalTypes.d.luau --base-luaurc=.luaurc --sourcemap=sourcemap.json --settings=.vscode/settings.json --no-strict-dm-types --ignore Packages/**/*.lua --ignore Packages/**/*.luau lib/"
)

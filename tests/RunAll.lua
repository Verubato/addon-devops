-- Entry point for the AddonDevOps harness's own test suite. Run from the repository root:
--
--   lua tests/RunAll.lua
--
-- Requirements: Lua 5.1. An addon repo reaches the harness through build/, but this is the
-- harness, so the shared files sit at Lua/.

package.path = "Lua/?.lua;tests/?.lua;" .. package.path

io.write("AddonDevOps - unit tests\n")
io.write("======================================\n")

local testFiles = {
	"tests/TestSecretValues.lua",
}

local loadErrors = {}

for _, path in ipairs(testFiles) do
	io.write("\n[" .. path .. "]\n")

	local chunk, err = loadfile(path)

	if chunk then
		local ok, runError = pcall(chunk)

		if not ok then
			io.write("  ERROR while running " .. path .. ":\n  " .. tostring(runError) .. "\n")
			loadErrors[#loadErrors + 1] = path .. ": " .. tostring(runError)
		end
	else
		io.write("  ERROR loading " .. path .. ":\n  " .. tostring(err) .. "\n")
		loadErrors[#loadErrors + 1] = path .. ": " .. tostring(err)
	end
end

local fw = require("TestFramework")
local passed = fw.summary()

if #loadErrors > 0 then
	io.write("\nFile-load errors:\n")

	for _, message in ipairs(loadErrors) do
		io.write("  " .. message .. "\n")
	end

	passed = false
end

os.exit(passed and 0 or 1)

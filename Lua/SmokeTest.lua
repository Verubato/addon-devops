-- The smoke test every addon runs: load the whole addon from its TOC into a mocked client,
-- walk it through login, and check it came up clean.
--
-- The body lives here rather than in each repository so that one fix - a new WoW API, a new
-- lifecycle event - lands in all of them at once. An addon's tests/TestSmoke.lua is a call to
-- Run() plus whatever extra assertions are specific to it.

local fw = require("TestFramework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

local M = {}

---@class SmokeOptions
---@field srcRoot string? defaults to "src"
---@field class string? class token to log in as, for addons that only run for one class
---@field allowOutput boolean? when true, chat output during a clean load isn't a failure
---@field requireSavedVariables boolean? when false, skips the saved-variables check even if
---       the TOC declares some
---@field extra fun(context: table)? runs after the standard checks, inside its own test case

---Runs the standard smoke suite for an addon.
---@param addonName string the folder name, which is also the TOC name
---@param options SmokeOptions?
function M.Run(addonName, options)
	options = options or {}

	fw.describe(addonName .. " - smoke test", function()
		-- Shared across the cases below: each step builds on the previous one, and reporting
		-- them separately says which stage broke rather than just "the addon is broken".
		local context

		fw.it("loads every file its TOC lists", function()
			context = harness.Load(addonName, options)

			fw.truthy(#context.Loaded > 0, "the TOC loaded no files")
			fw.eq(#context.Loaded, #context.Toc.Files, "loaded file count")
		end)

		fw.it("initialises through the login sequence", function()
			fw.not_nil(context, "load must succeed first")

			local result = harness.Login(context)
			context.LoginResult = result

			-- An addon that creates no frame, hooks nothing and registers no slash command
			-- has not installed itself, whichever event it was waiting for.
			local activity = result.Activity

			fw.truthy(
				activity.Total > 0,
				string.format(
					"the addon left no trace: %d frames, %d hooks, %d slash commands",
					activity.Frames,
					activity.Hooks,
					activity.SlashCommands
				)
			)
		end)

		if options.requireSavedVariables ~= false then
			fw.it("creates the saved variables its TOC declares", function()
				fw.not_nil(context, "load must succeed first")

				local declared = harness.SavedVariables(context)

				if #declared == 0 then
					-- Not every addon stores settings; the TOC is the source of truth.
					return
				end

				-- Only one has to exist. Several addons declare both an account-wide and a
				-- per-character table and populate whichever the setting belongs in.
				local names = {}
				local created = false

				for _, entry in ipairs(declared) do
					names[#names + 1] = entry.Name

					if type(entry.Value) == "table" then
						created = true
					end
				end

				fw.truthy(created, "none of the declared saved variables were created: " .. table.concat(names, ", "))
			end)
		end

		if not options.allowOutput then
			fw.it("prints nothing to chat on a clean load", function()
				fw.not_nil(context, "load must succeed first")

				local output = WowMock.State.Prints

				-- Every chat line these addons emit goes through mini:Notify, which is for
				-- telling the user something is wrong. On a healthy load there is nothing.
				fw.eq(#output, 0, "unexpected chat output: " .. table.concat(output, " | "))
			end)
		end

		fw.it("runs the slash commands it registered", function()
			fw.not_nil(context, "load must succeed first")

			-- Opening the settings is the one path a login sequence never takes on its own,
			-- and it is where the option panels get wired to the saved variables.
			for _, name in ipairs(WowMock.SlashCommands()) do
				local handler = _G.SlashCmdList[name]

				fw.eq(type(handler), "function", "handler for /" .. name)

				local ok, err = pcall(handler, "")

				fw.truthy(ok, "/" .. name .. " errored: " .. tostring(err))
			end
		end)

		fw.it("comes back up after a reload", function()
			-- A second pass with the saved variables the first one wrote, which is what a
			-- /reload looks like. Catches a migration that isn't idempotent, a library that
			-- can't register itself twice, and anything that only works on a first-ever run.
			local second = harness.Run(addonName, options)

			fw.eq(#second.Loaded, #context.Loaded, "second load file count")
			fw.truthy(second.LoginResult.Activity.Total > 0, "the addon left no trace on the second load")
		end)

		if options.extra then
			fw.it("passes its addon-specific checks", function()
				fw.not_nil(context, "load must succeed first")
				options.extra(context)
			end)
		end
	end)
end

return M

-- Loads a whole addon into a plain Lua process and walks it through the client's login
-- sequence, so a suite can assert "it loads and initialises" without a game running.
--
-- What that catches, none of which luacheck can see: a syntax or runtime error at file scope,
-- a TOC entry pointing at a file that no longer exists, a file reading a namespace key that a
-- later TOC entry provides, an init callback that errors, and any WoW API called with the
-- wrong shape - the mock's parameter counts are real.

local Toc = require("Toc")
local WowMock = require("WowMock")

local M = {}

-- The events a client delivers on a cold login, in order. ADDON_LOADED is what releases
-- MiniFramework's WaitForAddonLoad callbacks, which is where these addons do their real work.
local LOGIN_EVENTS = {
	{ "ADDON_LOADED", "<addon>" },
	{ "VARIABLES_LOADED" },
	{ "SPELLS_CHANGED" },
	{ "PLAYER_LOGIN" },
	{ "PLAYER_ENTERING_WORLD", true, false },
}

-- Events that follow shortly after login on any real character. Firing them exercises the
-- refresh paths, which is where most of these addons keep their per-unit work.
local SETTLE_EVENTS = {
	{ "GROUP_ROSTER_UPDATE" },
	{ "PLAYER_SPECIALIZATION_CHANGED", "player" },
	{ "PLAYER_REGEN_ENABLED" },
	{ "ZONE_CHANGED_NEW_AREA" },
}

---Every saved-variable global the TOC declares, account-wide and per-character.
---@param toc table
---@return string[]
local function declaredSavedVariableNames(toc)
	local names = {}

	for _, directive in ipairs({ "SavedVariables", "SavedVariablesPerCharacter" }) do
		local value = toc.Directives[directive]

		if value then
			for name in value:gmatch("[^,%s]+") do
				names[#names + 1] = name
			end
		end
	end

	return names
end

---Runs a list of Lua files the way the client loads an addon's files: in order, each one
---called with the addon name and the shared private table as its varargs.
---@param addonName string
---@param files string[]
---@param addonTable table
---@return string[] loaded
function M.LoadFiles(addonName, files, addonTable)
	local loaded = {}

	for _, path in ipairs(files) do
		local chunk, err = loadfile(path)

		if not chunk then
			error(string.format("failed to load %s: %s", path, tostring(err)), 0)
		end

		local ok, runError = pcall(chunk, addonName, addonTable)

		if not ok then
			error(string.format("error executing %s: %s", path, tostring(runError)), 0)
		end

		loaded[#loaded + 1] = path
	end

	return loaded
end

---Loads a library that ships an .xml entry point rather than a .toc, as a synthetic addon.
---@param addonName string the name to load it under, which is what it derives its saved
---       variable and slash command names from
---@param xmlPath string
---@param options { install: boolean?, class: string? }?
---@return { Name: string, Addon: table, Loaded: string[], Mock: table }
function M.LoadXml(addonName, xmlPath, options)
	options = options or {}

	if options.install ~= false then
		WowMock.Install()
	end

	if options.class then
		WowMock.SetPlayerClass(options.class)
	end

	local addonTable = {}
	local files = Toc.ParseXml(xmlPath)

	if #files == 0 then
		error("AddonHarness: " .. xmlPath .. " references no Lua files")
	end

	return {
		Name = addonName,
		Toc = { Directives = {}, Files = files },
		Addon = addonTable,
		Loaded = M.LoadFiles(addonName, files, addonTable),
		Mock = WowMock,
	}
end

---Loads every file the TOC lists, in TOC order, into a fresh mocked client.
---@param addonName string the folder name, which is also the TOC name
---@param options { srcRoot: string?, install: boolean?, class: string? }?
---@return { Name: string, Toc: table, Addon: table, Loaded: string[], Mock: table }
function M.Load(addonName, options)
	options = options or {}

	local toc = Toc.Parse(Toc.Find(addonName, options.srcRoot))

	if options.install ~= false then
		-- The saved variables survive the reset, because the client keeps them across a
		-- reload and the second pass is only interesting if it sees the first pass's data.
		WowMock.Install({ preserve = declaredSavedVariableNames(toc) })
	end

	-- Addons that only do anything for one class check UnitClass before they set anything up,
	-- so the smoke test has to log in as a character the addon cares about.
	if options.class then
		WowMock.SetPlayerClass(options.class)
	end

	if #toc.Files == 0 then
		error("AddonHarness: " .. addonName .. "'s TOC lists no Lua files")
	end

	-- The private table every file receives as its second vararg, exactly as the client does.
	local addonTable = {}
	local loaded = M.LoadFiles(addonName, toc.Files, addonTable)

	return {
		Name = addonName,
		Toc = toc,
		Addon = addonTable,
		Loaded = loaded,
		Mock = WowMock,
	}
end

---Counts the traces an addon leaves on the client: frames, secure hooks and slash commands.
---An addon that leaves none did nothing at all, which for a smoke test is the failure case.
---@return { Frames: number, Hooks: number, SlashCommands: number, Total: number }
function M.Activity()
	local frames = WowMock.AddonFrameCount()
	local hooks = #WowMock.Hooks
	local commands = #WowMock.SlashCommands()

	return {
		Frames = frames,
		Hooks = hooks,
		SlashCommands = commands,
		Total = frames + hooks + commands,
	}
end

---Fires the login sequence at an already-loaded addon and drains the timers it queues.
---@param context table the value M.Load returned
---@return { AddonLoadedHandlers: number, Events: number }
function M.Login(context)
	local addonLoadedHandlers = 0
	local fired = 0

	for _, event in ipairs(LOGIN_EVENTS) do
		local name = event[1]
		local first = event[2] == "<addon>" and context.Name or event[2]
		local delivered = WowMock.FireEvent(name, first, event[3])

		if name == "ADDON_LOADED" then
			addonLoadedHandlers = delivered
		end

		fired = fired + 1

		-- Drain between events: an addon that defers its init by a frame expects the timer to
		-- have run before the next event arrives.
		WowMock.RunTimers()
	end

	for _, event in ipairs(SETTLE_EVENTS) do
		WowMock.FireEvent(event[1], event[2])
		fired = fired + 1
	end

	WowMock.RunTimers()
	WowMock.RunOnUpdate(0.1)
	WowMock.RunTimers()

	return {
		AddonLoadedHandlers = addonLoadedHandlers,
		Events = fired,
		Activity = M.Activity(),
	}
end

---Loads the addon and logs it in. The single call a smoke test needs.
---@param addonName string
---@param options table?
---@return table context with a .Login field holding the login result
function M.Run(addonName, options)
	local context = M.Load(addonName, options)
	context.LoginResult = M.Login(context)
	return context
end

---Every saved variable the TOC declares, account-wide and per-character, with whichever ones
---the addon actually populated during the run.
---@return { Name: string, PerCharacter: boolean, Value: any }[]
function M.SavedVariables(context)
	local declared = {}

	local perCharacter = context.Toc.Directives.SavedVariablesPerCharacter or ""

	for _, name in ipairs(declaredSavedVariableNames(context.Toc)) do
		declared[#declared + 1] = {
			Name = name,
			PerCharacter = perCharacter:find(name, 1, true) ~= nil,
			Value = _G[name],
		}
	end

	return declared
end

---Everything the addon printed to chat during the run, as one list.
function M.Output(_)
	return WowMock.State.Prints
end

return M

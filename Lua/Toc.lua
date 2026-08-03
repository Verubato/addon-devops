-- Reads an addon's .toc the same way the client does: metadata directives, then an ordered
-- list of files, following any .xml entry into the <Script>/<Include> files it pulls in.
--
-- The load order is the point. A test harness that invents its own order silently passes on a
-- file that reads addon.Core.X before the TOC has loaded X, which then fails in game only.

local M = {}

-- Paths

---Normalises a TOC path fragment. TOCs are authored on Windows and use backslashes, which a
---Linux CI runner treats as part of the filename rather than a separator.
local function normalise(path)
	return (path:gsub("\\", "/"):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function directoryOf(path)
	return path:match("^(.*)/[^/]+$") or "."
end

local function exists(path)
	local handle = io.open(path, "r")

	if handle then
		handle:close()
		return true
	end

	return false
end

local function read(path)
	local handle, err = io.open(path, "r")

	if not handle then
		error("Toc: cannot open " .. path .. ": " .. tostring(err))
	end

	local contents = handle:read("*a")
	handle:close()

	-- A TOC saved from the WoW client carries a UTF-8 BOM, which would otherwise become part
	-- of the first directive's name and hide it.
	return (contents:gsub("^\239\187\191", ""))
end

-- Parsing

local parseXml

---Appends every .lua file an .xml references, depth first, in declaration order.
---@param xmlPath string path to the .xml, relative to the working directory
---@param out string[] accumulator
---@param seen table<string, boolean> guards a self-referencing include
parseXml = function(xmlPath, out, seen)
	if seen[xmlPath] then
		return
	end

	seen[xmlPath] = true

	local root = directoryOf(xmlPath)

	-- Both tags carry the same file attribute; Include nests another xml, Script a lua file.
	-- The whitespace around the `=` is optional and some vendored libraries use it.
	for tag, file in read(xmlPath):gmatch("<(%a+)%s+file%s*=%s*[\"']([^\"']+)[\"']") do
		local relative = normalise(file)
		local full = root .. "/" .. relative

		if tag == "Script" then
			out[#out + 1] = full
		elseif tag == "Include" then
			parseXml(full, out, seen)
		end
	end
end

---Returns the ordered .lua files an .xml pulls in, following nested includes.
---For a library that ships an .xml entry point instead of a .toc.
---@param xmlPath string
---@return string[]
function M.ParseXml(xmlPath)
	if not exists(xmlPath) then
		error("Toc: no such file: " .. xmlPath)
	end

	local files = {}
	parseXml(xmlPath, files, {})

	return files
end

---Parses a .toc into its metadata and its ordered file list.
---@param tocPath string path to the .toc, relative to the working directory
---@return { Name: string, Directives: table<string, string>, Files: string[] }
function M.Parse(tocPath)
	if not exists(tocPath) then
		error("Toc: no such file: " .. tocPath)
	end

	local root = directoryOf(tocPath)
	local directives = {}
	local files = {}
	local seen = {}

	for line in read(tocPath):gmatch("[^\r\n]+") do
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")

		if trimmed == "" then
			-- blank spacer
		elseif trimmed:match("^##") then
			local key, value = trimmed:match("^##%s*([^:]+):%s*(.*)$")

			if key then
				directives[key:gsub("%s+$", "")] = value
			end
		elseif trimmed:match("^#") then
			-- comment
		else
			local relative = normalise(trimmed)
			local full = root .. "/" .. relative

			if relative:match("%.xml$") then
				parseXml(full, files, seen)
			elseif relative:match("%.lua$") then
				files[#files + 1] = full
			end
		end
	end

	return {
		Name = tocPath:match("([^/\\]+)%.toc$"),
		Directives = directives,
		Files = files,
	}
end

---Resolves the addon's own .toc, which by convention is src/<AddonName>.toc. Named explicitly
---rather than discovered, because every vendored library under src/Libs ships a .toc too.
---@param addonName string
---@param srcRoot string? defaults to "src"
---@return string path
function M.Find(addonName, srcRoot)
	local path = (srcRoot or "src") .. "/" .. addonName .. ".toc"

	if not exists(path) then
		error("Toc: no such file: " .. path .. " - the suite must be run from the addon root")
	end

	return path
end

return M

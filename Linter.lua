local lfs = require("lfs")

-- Forward slashes throughout: Windows accepts them and Linux requires them, so the same script
-- runs locally and on a CI runner. Paths are resolved from this file rather than the working
-- directory so it can be invoked from anywhere.
-- Normalise before splitting: on Windows arg[0] arrives with backslashes, and a mixed-separator
-- root then fails to strip itself off the reported paths.
local scriptPath = (arg and arg[0] or ""):gsub("\\", "/")
local scriptDir = scriptPath:match("^(.*)/[^/]+$") or "."
local addonRoot = scriptDir .. "/.."

local function collect_lua_files(dir, out)
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode == "directory" then
                    collect_lua_files(path, out)
                elseif attr.mode == "file" and entry:match("%.lua$") then
                    -- skip vendored libs
                    if not path:match("/Libs/") then
                        out[#out + 1] = path
                    end
                end
            end
        end
    end
end

local function load_luacheckrc(path)
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load .luacheckrc: " .. tostring(err))
    end

    local ret = chunk()

    if type(ret) ~= "table" then
        error("Unsupported  .luacheckrc file format.")
    end

    return ret
end

local function LuaCheck()
    local luacheck = require("luacheck")

    local cfg = load_luacheckrc(addonRoot .. "/.luacheckrc")

    -- Tests are code too, and were previously unlinted entirely. An addon whose suite predates
    -- this can set `lint_tests = false` in its .luacheckrc to opt out until it is cleaned up;
    -- the key is removed before the config reaches luacheck, which would not recognise it.
    local lintTests = cfg.lint_tests ~= false
    cfg.lint_tests = nil

    local files = {}
    local dirs = { addonRoot .. "/src" }

    if lintTests then
        dirs[#dirs + 1] = addonRoot .. "/tests"
    end

    for _, dir in ipairs(dirs) do
        if lfs.attributes(dir, "mode") == "directory" then
            collect_lua_files(dir, files)
        end
    end

    local totalWarnings, totalErrors, totalFatals = 0, 0, 0

    local function read_all(path)
        local f, err = io.open(path, "rb")
        if not f then
            return nil, err
        end
        local s = f:read("*a")
        f:close()
        return s
    end

    for _, realPath in ipairs(files) do
        -- Report paths as src/WoW/WoW.lua rather than the absolute path we walked.
        local logical = realPath:gsub("\\", "/"):gsub("^" .. addonRoot:gsub("([^%w])", "%%%1") .. "/", "")

        local content, err = read_all(realPath)
        if not content then
            print(string.format("%s: FATAL: couldn't read: %s", logical, tostring(err)))
            totalFatals = totalFatals + 1
        else
            -- IMPORTANT: now luacheck "sees" the filename as `logical`
            local report = luacheck.check_strings({ content }, cfg, { logical })

            totalWarnings = totalWarnings + (report.warnings or 0)
            totalErrors = totalErrors + (report.errors or 0)
            totalFatals = totalFatals + (report.fatals or 0)

            local fileReport = report[1]
            if fileReport.fatal then
                print(string.format("%s: FATAL: %s", logical, tostring(fileReport.msg)))
            else
                for _, issue in ipairs(fileReport) do
                    local msg = luacheck.get_message(issue)
                    local line = issue.line or 0
                    local col = issue.column or 0
                    print(string.format("%s:%d:%d: %s (%s)", logical, line, col, msg, tostring(issue.code)))
                end
            end
        end
    end

    if (totalWarnings + totalErrors + totalFatals) > 0 then
        print(string.format("[Luacheck] FAILED: %d warnings, %d errors, %d fatals", totalWarnings, totalErrors, totalFatals))
        os.exit(1)
    end

    print("[Luacheck] OK")
end

LuaCheck()

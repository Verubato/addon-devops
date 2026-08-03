-- Minimal xUnit-style test framework shared by every addon's suite.
--
-- Deliberately dependency free: a CI runner only has to install lua5.1 for a suite built on
-- this to run, and the same file works unchanged on a developer machine.
--
-- All test files share this singleton through require()'s module cache, so the pass and fail
-- counters accumulate across a whole run and RunAll.lua reports them once at the end.

local M = {}

local passes = 0
local failures = 0
local errors = {}
local suiteName = nil
local beforeEach = nil

-- Suites

---Opens a named group of tests. Resets before_each so each block is independent.
function M.describe(name, fn)
	suiteName = name
	beforeEach = nil
	io.write("\n  " .. name .. "\n")
	fn()
	suiteName = nil
	beforeEach = nil
end

---Registers a setup function that runs before every it() in the current describe block.
function M.before_each(fn)
	beforeEach = fn
end

---Declares a single test case.
function M.it(name, fn)
	local ok, err = pcall(function()
		if beforeEach then
			beforeEach()
		end
		fn()
	end)

	if ok then
		passes = passes + 1
		io.write("    [pass] " .. name .. "\n")
	else
		failures = failures + 1
		io.write("    [FAIL] " .. name .. "\n")
		io.write("           " .. tostring(err) .. "\n")
		errors[#errors + 1] = string.format("(%s) %s\n           %s", suiteName or "?", name, tostring(err))
	end
end

---Declares a test case that is expected to fail (a known limitation, not a regression).
---A failure counts as a pass; an unexpected pass fails, so the marker can't outlive the bug.
function M.xfail(name, fn)
	local ok = pcall(function()
		if beforeEach then
			beforeEach()
		end
		fn()
	end)

	if ok then
		failures = failures + 1
		io.write("    [XPASS] " .. name .. "\n")
		io.write("           XPASS: marked xfail but passed - remove the marker\n")
		errors[#errors + 1] = string.format("(%s) %s\n           XPASS: marked xfail but passed", suiteName or "?", name)
	else
		passes = passes + 1
		io.write("    [xfail] " .. name .. "\n")
	end
end

---Declares a test case that is intentionally not exercised. Counts as neither pass nor fail.
function M.skip(name, _fn)
	io.write("    [skip] " .. name .. "\n")
end

-- Assertions

function M.eq(actual, expected, label)
	if actual ~= expected then
		error(string.format("[%s] expected %s, got %s", label or "eq", tostring(expected), tostring(actual)), 2)
	end
end

function M.neq(actual, unexpected, label)
	if actual == unexpected then
		error(string.format("[%s] expected something other than %s", label or "neq", tostring(actual)), 2)
	end
end

function M.is_nil(value, label)
	if value ~= nil then
		error(string.format("[%s] expected nil, got %s", label or "is_nil", tostring(value)), 2)
	end
end

function M.not_nil(value, label)
	if value == nil then
		error(string.format("[%s] expected non-nil", label or "not_nil"), 2)
	end
end

function M.truthy(value, label)
	if not value then
		error(string.format("[%s] expected truthy, got %s", label or "truthy", tostring(value)), 2)
	end
end

function M.falsy(value, label)
	if value then
		error(string.format("[%s] expected falsy, got %s", label or "falsy", tostring(value)), 2)
	end
end

function M.has_key(t, key, label)
	if type(t) ~= "table" or t[key] == nil then
		error(string.format("[%s] expected key '%s' in table", label or "has_key", tostring(key)), 2)
	end
end

function M.no_key(t, key, label)
	if type(t) == "table" and t[key] ~= nil then
		error(string.format("[%s] expected no key '%s' in table", label or "no_key", tostring(key)), 2)
	end
end

---Asserts the function runs without raising. The error is reported verbatim when it does,
---which is the whole point of a smoke test - the message names the file and line that broke.
function M.no_error(fn, label)
	local ok, err = pcall(fn)

	if not ok then
		error(string.format("[%s] %s", label or "no_error", tostring(err)), 2)
	end
end

-- Summary

---Prints the pass/fail summary and returns true when everything passed.
function M.summary()
	io.write(string.format("\n  %d passed, %d failed\n", passes, failures))

	if #errors > 0 then
		io.write("\n  Failures:\n")

		for _, e in ipairs(errors) do
			io.write("    " .. e .. "\n\n")
		end
	end

	return failures == 0
end

return M

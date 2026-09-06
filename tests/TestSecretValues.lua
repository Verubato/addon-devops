-- Covers the mock's simulation of 12.0 secret values: what a secret refuses to do, what it is
-- still allowed to do, and the two client calls an addon is supposed to route them through.

local fw = require("TestFramework")
local WowMock = require("WowMock")

---Runs fn and returns the error message, or nil when it did not raise.
local function ErrorFrom(fn)
	local ok, err = pcall(fn)

	if ok then
		return nil
	end

	return tostring(err)
end

fw.describe("WowMock - minting secrets", function()
	fw.before_each(function()
		WowMock.Install()
	end)

	fw.it("reports a minted value as secret and everything else as plain", function()
		local secret = WowMock.MakeSecret(42)

		fw.truthy(issecretvalue(secret), "the minted value")
		fw.falsy(issecretvalue(42), "a plain number")
		fw.falsy(issecretvalue("42"), "a plain string")
		fw.falsy(issecretvalue(true), "a plain boolean")
		fw.falsy(issecretvalue(nil), "nil")
		fw.falsy(issecretvalue({}), "an ordinary table")
	end)

	fw.it("mints distinct secrets rather than handing back one shared proxy", function()
		local first = WowMock.MakeSecret(1)
		local second = WowMock.MakeSecret(1)

		fw.falsy(rawequal(first, second), "two mints of the same underlying value")
	end)

	fw.it("wraps false and nil, which a bare registry entry could not tell from absence", function()
		fw.truthy(issecretvalue(WowMock.MakeSecret(false)), "a secret false")
		fw.truthy(issecretvalue(WowMock.MakeSecret(nil)), "a secret nil")
	end)

	fw.it("reports the type a secret wraps rather than the proxy's own table type", function()
		fw.eq(type(WowMock.MakeSecret(42)), "number", "a secret number")
		fw.eq(type(WowMock.MakeSecret("x")), "string", "a secret string")
		fw.eq(type(WowMock.MakeSecret(nil)), "nil", "a secret nil")
		fw.eq(type(42), "number", "a plain value is unaffected")
	end)

	fw.it("exposes the real type function for a suite that needs the unwrapped answer", function()
		local secret = WowMock.MakeSecret(42)

		fw.eq(WowMock.RealType(secret), "table", "the proxy really is a table")
		fw.eq(WowMock.RealType(42), "number", "a plain value is unaffected")
	end)
end)

fw.describe("WowMock - forbidden operations on a secret", function()
	local secret

	fw.before_each(function()
		WowMock.Install()
		secret = WowMock.MakeSecret(7)
	end)

	local function AssertRaises(label, operation, fn)
		local message = ErrorFrom(fn)

		fw.not_nil(message, label .. " raised")

		if message then
			fw.truthy(message:find("secret value", 1, true) ~= nil, label .. " names a secret value: " .. message)
			fw.truthy(message:find(operation, 1, true) ~= nil, label .. " names " .. operation .. ": " .. message)
		end
	end

	fw.it("refuses arithmetic", function()
		AssertRaises("addition", "addition", function()
			return secret + 1
		end)

		AssertRaises("subtraction", "subtraction", function()
			return secret - 1
		end)

		AssertRaises("multiplication", "multiplication", function()
			return secret * 2
		end)

		AssertRaises("division", "division", function()
			return secret / 2
		end)

		AssertRaises("modulo", "modulo", function()
			return secret % 2
		end)

		AssertRaises("exponentiation", "exponentiation", function()
			return secret ^ 2
		end)

		AssertRaises("negation", "negation", function()
			return -secret
		end)
	end)

	fw.it("refuses concatenation, in either order", function()
		AssertRaises("secret on the right", "concatenation", function()
			return "alpha=" .. secret
		end)

		AssertRaises("secret on the left", "concatenation", function()
			return secret .. "!"
		end)
	end)

	fw.it("refuses tostring, so a secret cannot leak into a chat line", function()
		AssertRaises("tostring", "tostring", function()
			return tostring(secret)
		end)
	end)

	fw.it("refuses an ordered comparison between two secrets", function()
		local other = WowMock.MakeSecret(9)

		AssertRaises("less than", "ordered comparison", function()
			return secret < other
		end)

		AssertRaises("less or equal", "ordered comparison", function()
			return secret <= other
		end)
	end)

	fw.it("refuses equality between two secrets", function()
		local other = WowMock.MakeSecret(7)

		AssertRaises("equality", "equality comparison", function()
			return secret == other
		end)
	end)

	fw.it("refuses indexing and assignment, so a secret cannot be treated as an aura table", function()
		AssertRaises("read", "indexing", function()
			return secret.spellId
		end)

		AssertRaises("write", "assignment", function()
			secret.spellId = 1
		end)
	end)

	fw.it("refuses indexing a protected plain table with a secret key", function()
		local message = ErrorFrom(function()
			return RAID_CLASS_COLORS[secret]
		end)

		fw.not_nil(message, "raised")
		fw.truthy(message:find("secret keys", 1, true) ~= nil, "names secret keys: " .. tostring(message))
	end)
end)

fw.describe("WowMock - operations a secret still allows", function()
	fw.before_each(function()
		WowMock.Install()
	end)

	fw.it("survives an if, and both boolean operators, because the client allows them", function()
		local secret = WowMock.MakeSecret(true)

		fw.no_error(function()
			if secret then
				return
			end
		end, "if secret then")

		fw.no_error(function()
			return secret and 1
		end, "secret and value")

		fw.no_error(function()
			return secret or false
		end, "secret or false")
	end)

	fw.it("is always truthy, even wrapping false, because a table cannot be made falsy", function()
		local secret = WowMock.MakeSecret(false)

		fw.truthy(secret and true or false, "a secret false still takes the truthy branch")
	end)
end)

fw.describe("WowMock - secure setters", function()
	local frame

	fw.before_each(function()
		WowMock.Install()
		frame = WowMock.NewFrame("Frame")
	end)

	fw.it("takes a secret through SetAlphaFromBoolean and records that it was one", function()
		fw.no_error(function()
			frame:SetAlphaFromBoolean(WowMock.MakeSecret(true))
		end, "a secret true")

		fw.eq(frame:GetAlpha(), 1, "the underlying true drove the alpha")
		fw.truthy(frame.__alphaFromBoolean, "the recorded state")
		fw.truthy(frame.__alphaFromBooleanWasSecret, "the value was flagged as secret")

		frame:SetAlphaFromBoolean(WowMock.MakeSecret(false))

		fw.eq(frame:GetAlpha(), 0, "a secret false clears the alpha")
		fw.falsy(frame.__alphaFromBoolean, "the recorded state follows the underlying value")
		fw.truthy(frame.__alphaFromBooleanWasSecret, "still flagged as secret")
	end)

	fw.it("keeps the plain-boolean behaviour every existing suite relies on", function()
		frame:SetAlphaFromBoolean(true)

		fw.eq(frame:GetAlpha(), 1, "plain true")
		fw.falsy(frame.__alphaFromBooleanWasSecret, "nothing secret about it")

		frame:SetAlphaFromBoolean(false)

		fw.eq(frame:GetAlpha(), 0, "plain false")
	end)

	fw.it("takes a secret through SetShownFromBoolean and runs the visibility scripts", function()
		local shows = 0
		local hides = 0

		-- Hidden before the scripts go on, so the counts only cover the two calls under test.
		frame:Hide()

		frame:SetScript("OnShow", function()
			shows = shows + 1
		end)
		frame:SetScript("OnHide", function()
			hides = hides + 1
		end)

		fw.no_error(function()
			frame:SetShownFromBoolean(WowMock.MakeSecret(true))
		end, "a secret true")

		fw.truthy(frame:IsShown(), "the frame is shown")
		fw.truthy(frame.__shownFromBooleanWasSecret, "the value was flagged as secret")
		fw.eq(shows, 1, "OnShow ran once")

		frame:SetShownFromBoolean(false)

		fw.falsy(frame:IsShown(), "a plain false hides it")
		fw.falsy(frame.__shownFromBooleanWasSecret, "and is not flagged secret")
		fw.eq(hides, 1, "OnHide ran once")
	end)
end)

fw.describe("WowMock - SetTexture and SetAtlas clear each other", function()
	local texture

	fw.before_each(function()
		WowMock.Install()
		texture = WowMock.NewFrame("Texture")
	end)

	fw.it("clears an atlas set earlier when a texture is set over it", function()
		texture:SetAtlas("some-atlas")
		texture:SetTexture([[Interface\Some\Path]])

		fw.eq(texture:GetTexture(), [[Interface\Some\Path]], "the new texture")
		fw.is_nil(texture:GetAtlas(), "the atlas SetTexture left behind")
	end)

	fw.it("clears a texture set earlier when an atlas is set over it", function()
		texture:SetTexture([[Interface\Some\Path]])
		texture:SetAtlas("some-atlas")

		fw.eq(texture:GetAtlas(), "some-atlas", "the new atlas")
		fw.is_nil(texture:GetTexture(), "the texture SetAtlas left behind")
	end)
end)

fw.describe("WowMock - C_CurveUtil.EvaluateColorValueFromBoolean", function()
	fw.before_each(function()
		WowMock.Install()
	end)

	fw.it("turns a plain boolean into the matching number", function()
		fw.eq(C_CurveUtil.EvaluateColorValueFromBoolean(true, 1, 0.35), 1, "true picks the second argument")
		fw.eq(C_CurveUtil.EvaluateColorValueFromBoolean(false, 1, 0.35), 0.35, "false picks the third")
	end)

	fw.it("turns a secret boolean into a plain number, which is the whole point of it", function()
		local alpha = C_CurveUtil.EvaluateColorValueFromBoolean(WowMock.MakeSecret(true), 1, 0)

		fw.eq(alpha, 1, "a secret true")
		fw.falsy(issecretvalue(alpha), "the result is plain, so it can be compared and stored")

		fw.eq(C_CurveUtil.EvaluateColorValueFromBoolean(WowMock.MakeSecret(false), 1, 0), 0, "a secret false")
	end)

	fw.it("rejects a non-number for either branch, the way the client does", function()
		local second = ErrorFrom(function()
			return C_CurveUtil.EvaluateColorValueFromBoolean(true, true, 0)
		end)

		fw.not_nil(second, "a boolean second argument raised")
		fw.truthy(second:find("bad argument #2", 1, true) ~= nil, "names argument 2: " .. tostring(second))

		local third = ErrorFrom(function()
			return C_CurveUtil.EvaluateColorValueFromBoolean(true, 1, false)
		end)

		fw.not_nil(third, "a boolean third argument raised")
		fw.truthy(third:find("bad argument #3", 1, true) ~= nil, "names argument 3: " .. tostring(third))
	end)

	fw.it("leaves the rest of C_CurveUtil in place", function()
		fw.not_nil(C_CurveUtil.CreateCurve, "CreateCurve")
		fw.not_nil(C_CurveUtil.CreateColorCurve, "CreateColorCurve")
	end)
end)

fw.describe("WowMock - C_Secrets.ShouldAurasBeSecret", function()
	fw.before_each(function()
		WowMock.Install()
	end)

	fw.it("answers false by default, so no existing suite changes behaviour", function()
		fw.falsy(C_Secrets.ShouldAurasBeSecret(), "the default")
	end)

	fw.it("follows the state flag a test sets", function()
		WowMock.State.AurasAreSecret = true

		fw.truthy(C_Secrets.ShouldAurasBeSecret(), "switched on")

		WowMock.State.AurasAreSecret = false

		fw.falsy(C_Secrets.ShouldAurasBeSecret(), "switched back off")
	end)
end)

fw.describe("WowMock - reset between tests", function()
	fw.it("forgets minted secrets on the next Install, so a proxy cannot outlive its suite", function()
		WowMock.Install()

		local secret = WowMock.MakeSecret(true)

		fw.truthy(issecretvalue(secret), "secret before the reset")

		WowMock.Install()

		fw.falsy(issecretvalue(secret), "the registry was cleared")
	end)

	fw.it("returns the aura secrecy switch to its default on the next Install", function()
		WowMock.Install()
		WowMock.State.AurasAreSecret = true

		WowMock.Install()

		fw.falsy(C_Secrets.ShouldAurasBeSecret(), "back to the documented default")
	end)
end)

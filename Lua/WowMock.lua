-- A standalone stand-in for the WoW client, enough of one to load an addon end to end in
-- plain Lua and drive it through the login sequence.
--
-- Scope: the widget system (frames, textures, font strings, animations), the event and timer
-- loops, and the API surface the Mini addons actually call. The point is never to reproduce
-- the client's behaviour - a stub returns something plausible and nothing more - it is to let
-- real addon code run so that load errors, nil indexes, bad argument counts and broken load
-- order surface in CI instead of in game.
--
-- Two deliberate design choices:
--
--   * An unknown global stays nil rather than resolving to an auto-generated stub. Addons
--     feature-detect constantly ("if ShadowUF then", "if Settings.RegisterCanvasLayoutCategory
--     then"), and a mock where every name is truthy would send them down branches that can
--     never run in a real client. The cost is that a genuinely missing API fails a smoke test;
--     that failure is the signal to add it here.
--   * Nothing is auto-fired. Events, timers and OnUpdate are queued and only run when the
--     harness asks, so a retry timer can't spin the suite forever.

local M = {}

-- Fields

-- Everything a test can steer. Reset by M.Install.
M.State = {}

-- Every frame ever created, in creation order, for event dispatch and inspection.
M.Frames = {}

-- Names passed to hooksecurefunc, in order.
M.Hooks = {}

-- How many frames the mock itself created while installing. Anything past this index in
-- M.Frames was created by the addon under test.
M.BaselineFrameCount = 0

local timers = {}
local tickers = {}
local frameCounter = 0

-- Global names any widget claimed, so a reinstall can clear them. A named frame lives in _G
-- for as long as the client runs, and an addon that only creates a frame when the global is
-- still nil would do nothing at all on a second pass through the harness.
local namedGlobals = {}

-- The globals that existed before this module was required. Anything else in _G came from an
-- addon or a library, and installing a fresh client has to take it back out - a vendored
-- LibStub that survived the previous run is not the same thing as a client with no addons.
--
-- This is captured at require time, so require this module before anything that writes to _G.
local baselineGlobals = {}

for key in pairs(_G) do
	baselineGlobals[key] = true
end

-- Widget internals

local function noop() end

-- Widget types that a frame also answers IsObjectType for. Only the depth the addons check.
local objectTypeParents = {
	Frame = { "Region", "ScriptObject" },
	Button = { "Frame", "Region", "ScriptObject" },
	CheckButton = { "Button", "Frame", "Region", "ScriptObject" },
	StatusBar = { "Frame", "Region", "ScriptObject" },
	Slider = { "Frame", "Region", "ScriptObject" },
	EditBox = { "Frame", "Region", "ScriptObject" },
	ScrollFrame = { "Frame", "Region", "ScriptObject" },
	Cooldown = { "Frame", "Region", "ScriptObject" },
	PlayerModel = { "Frame", "Region", "ScriptObject" },
	Texture = { "Region" },
	MaskTexture = { "Texture", "Region" },
	FontString = { "Region" },
	Line = { "Texture", "Region" },
}

local widget = {}
local widgetMeta = { __index = widget }

---A node in a modern menu tree. Every Create* call returns another node, so an addon's menu
---generator can build to whatever depth it likes and every branch of it runs.
local function newMenuDescription()
	local description = {}

	local function child()
		return newMenuDescription()
	end

	description.CreateButton = child
	description.CreateRadio = child
	description.CreateCheckbox = child
	description.CreateTitle = child
	description.CreateDivider = child
	description.CreateSpacer = child
	description.CreateTemplate = child
	description.CreateColorSwatch = child
	description.SetGridMode = noop
	description.SetScrollMode = noop
	description.SetTitle = noop
	description.SetResponse = noop
	description.SetIsSelected = noop
	description.SetSelectionIgnored = noop
	description.SetEnabled = noop
	description.SetTooltip = noop

	return description
end

local function newWidget(objectType, name, parent)
	frameCounter = frameCounter + 1

	local self = setmetatable({}, widgetMeta)

	self.__objectType = objectType
	self.__name = name
	self.__parent = parent
	self.__id = frameCounter
	self.__shown = true
	self.__alpha = 1
	self.__scale = 1
	self.__width = 0
	self.__height = 0
	self.__points = {}
	self.__scripts = {}
	self.__events = {}
	self.__children = {}
	self.__regions = {}
	self.__attributes = {}

	if name then
		_G[name] = self
		namedGlobals[#namedGlobals + 1] = name
	end

	if parent and parent.__children then
		parent.__children[#parent.__children + 1] = self
	end

	return self
end

---Runs every handler registered for a script, the SetScript one first and then any hooks.
local function runScript(self, name, ...)
	local handlers = self.__scripts[name]

	if not handlers then
		return
	end

	for _, handler in ipairs(handlers) do
		handler(self, ...)
	end
end

-- Widget: identity and hierarchy

function widget:GetObjectType()
	return self.__objectType
end

function widget:IsObjectType(objectType)
	if self.__objectType == objectType then
		return true
	end

	for _, parent in ipairs(objectTypeParents[self.__objectType] or {}) do
		if parent == objectType then
			return true
		end
	end

	return false
end

function widget:GetName()
	return self.__name
end

function widget:GetParent()
	return self.__parent
end

function widget:SetParent(parent)
	self.__parent = parent
end

function widget:GetChildren()
	return unpack(self.__children)
end

function widget:GetNumChildren()
	return #self.__children
end

function widget:GetRegions()
	return unpack(self.__regions)
end

function widget:GetNumRegions()
	return #self.__regions
end

function widget:IsForbidden()
	return false
end

function widget:GetID()
	return self.__frameId or 0
end

function widget:SetID(id)
	self.__frameId = id
end

-- Widget: geometry
--
-- Sizes and anchors are stored rather than resolved. Nothing here lays anything out, so a
-- widget reports back whatever it was last told plus a non-zero default, which is all the
-- layout code in these addons needs to divide by.

function widget:SetWidth(width)
	self.__width = width or 0
end

function widget:SetHeight(height)
	self.__height = height or 0
end

function widget:SetSize(width, height)
	self.__width = width or 0
	self.__height = height or 0
end

function widget:GetWidth()
	return self.__width > 0 and self.__width or 100
end

function widget:GetHeight()
	return self.__height > 0 and self.__height or 20
end

function widget:GetSize()
	return self:GetWidth(), self:GetHeight()
end

function widget:GetLeft()
	return 0
end

function widget:GetRight()
	return self:GetWidth()
end

function widget:GetBottom()
	return 0
end

function widget:GetTop()
	return self:GetHeight()
end

function widget:GetCenter()
	return self:GetWidth() / 2, self:GetHeight() / 2
end

function widget:SetPoint(...)
	self.__points[#self.__points + 1] = { ... }
end

function widget:SetAllPoints(other)
	self.__points[#self.__points + 1] = { "ALLPOINTS", other }
end

function widget:ClearAllPoints()
	self.__points = {}
end

function widget:GetNumPoints()
	return #self.__points
end

function widget:GetPoint(index)
	local point = self.__points[index or 1]

	if not point or point[1] == "ALLPOINTS" then
		return "CENTER", self.__parent, "CENTER", 0, 0
	end

	-- SetPoint accepts several shapes; normalise to the five-value form callers expect.
	local first, second, third, fourth, fifth = point[1], point[2], point[3], point[4], point[5]

	if type(second) == "number" then
		return first, self.__parent, first, second, third
	end

	if type(third) == "number" then
		return first, second, first, third, fourth
	end

	return first, second, third, fourth or 0, fifth or 0
end

function widget:SetScale(scale)
	self.__scale = scale or 1
end

function widget:GetScale()
	return self.__scale
end

function widget:GetEffectiveScale()
	return self.__scale
end

function widget:SetHitRectInsets() end
function widget:SetClampedToScreen() end
function widget:SetClampRectInsets() end
function widget:SetResizeBounds() end
function widget:SetMinResize() end
function widget:SetMaxResize() end
function widget:SetClipsChildren() end
function widget:SetDontSavePosition() end
function widget:SetUserPlaced() end

function widget:IsUserPlaced()
	return false
end

-- Widget: visibility

function widget:Show()
	local wasShown = self.__shown
	self.__shown = true

	if not wasShown then
		runScript(self, "OnShow")
	end
end

function widget:Hide()
	local wasShown = self.__shown
	self.__shown = false

	if wasShown then
		runScript(self, "OnHide")
	end
end

function widget:SetShown(shown)
	if shown then
		self:Show()
	else
		self:Hide()
	end
end

function widget:IsShown()
	return self.__shown
end

function widget:IsVisible()
	if not self.__shown then
		return false
	end

	local parent = self.__parent

	while parent do
		if parent.__shown == false then
			return false
		end

		parent = parent.__parent
	end

	return true
end

function widget:SetAlpha(alpha)
	self.__alpha = alpha or 1
end

function widget:GetAlpha()
	return self.__alpha
end

---12.0's secure setter. A test drives it with a plain boolean; the client may pass a secret.
function widget:SetAlphaFromBoolean(value)
	self.__alpha = value and 1 or 0
end

function widget:SetIgnoreParentAlpha() end
function widget:SetIgnoreParentScale() end
function widget:SetFlattensRenderLayers() end
function widget:SetToplevel() end
function widget:Raise() end
function widget:Lower() end

-- Widget: strata and level

function widget:SetFrameStrata(strata)
	self.__strata = strata
end

function widget:GetFrameStrata()
	return self.__strata or "MEDIUM"
end

function widget:SetFrameLevel(level)
	self.__level = level
end

function widget:GetFrameLevel()
	return self.__level or 1
end

-- Widget: scripts and events

function widget:SetScript(name, handler)
	if handler then
		self.__scripts[name] = { handler }
	else
		self.__scripts[name] = nil
	end
end

function widget:HookScript(name, handler)
	local handlers = self.__scripts[name]

	if not handlers then
		self.__scripts[name] = { handler }
		return
	end

	handlers[#handlers + 1] = handler
end

function widget:GetScript(name)
	local handlers = self.__scripts[name]
	return handlers and handlers[1] or nil
end

function widget:HasScript(name)
	-- Every frame type in the mock accepts every script; the addons only use this to
	-- feature-detect OnUpdate/OnEvent, both of which are always available.
	return name ~= nil
end

function widget:RegisterEvent(event)
	self.__events[event] = true
end

function widget:RegisterUnitEvent(event)
	self.__events[event] = true
end

function widget:UnregisterEvent(event)
	self.__events[event] = nil
end

function widget:UnregisterAllEvents()
	self.__events = {}
end

function widget:IsEventRegistered(event)
	return self.__events[event] == true
end

function widget:RegisterForClicks() end
function widget:RegisterForDrag() end
function widget:EnableMouse(enabled)
	self.__mouseEnabled = enabled ~= false
end

function widget:IsMouseEnabled()
	return self.__mouseEnabled == true
end

function widget:EnableMouseWheel() end
function widget:EnableKeyboard() end
function widget:SetMouseClickEnabled() end
function widget:SetMouseMotionEnabled() end
function widget:SetPropagateKeyboardInput() end

function widget:IsMouseOver()
	return false
end

function widget:SetMovable(movable)
	self.__movable = movable ~= false
end

function widget:IsMovable()
	return self.__movable == true
end

function widget:SetResizable() end
function widget:StartMoving() end
function widget:StartSizing() end
function widget:StopMovingOrSizing() end

function widget:SetAttribute(key, value)
	self.__attributes[key] = value
end

function widget:GetAttribute(key)
	return self.__attributes[key]
end

function widget:Execute() end
function widget:WrapScript() end
function widget:SetFrameRef() end

-- Widget: child region factories

function widget:CreateTexture(name, layer)
	local texture = newWidget("Texture", name, self)
	texture.__layer = layer
	self.__regions[#self.__regions + 1] = texture
	return texture
end

function widget:CreateMaskTexture(name)
	local texture = newWidget("MaskTexture", name, self)
	self.__regions[#self.__regions + 1] = texture
	return texture
end

function widget:CreateLine(name)
	local line = newWidget("Line", name, self)
	self.__regions[#self.__regions + 1] = line
	return line
end

function widget:CreateFontString(name, layer, template)
	local fontString = newWidget("FontString", name, self)
	fontString.__layer = layer
	fontString.__template = template
	fontString.__text = ""
	self.__regions[#self.__regions + 1] = fontString
	return fontString
end

function widget:CreateAnimationGroup(name)
	local group = newWidget("AnimationGroup", name, self)
	group.__animations = {}
	return group
end

function widget:CreateAnimation(animationType, name)
	local animation = newWidget(animationType or "Animation", name, self)

	if self.__animations then
		self.__animations[#self.__animations + 1] = animation
	end

	return animation
end

-- Widget: animations

function widget:Play()
	self.__playing = true
end

function widget:Stop()
	self.__playing = false
end

function widget:Pause() end
function widget:Restart() end
function widget:Finish() end

function widget:IsPlaying()
	return self.__playing == true
end

function widget:SetLooping() end
function widget:SetToFinalAlpha() end
function widget:SetDuration() end
function widget:GetDuration()
	return 0
end
function widget:SetStartDelay() end
function widget:SetOrder() end
function widget:SetSmoothing() end
function widget:SetFromAlpha() end
function widget:SetToAlpha() end
function widget:SetDegrees() end
function widget:SetRadians() end
function widget:SetOffset() end
function widget:SetChildKey() end
function widget:SetTarget() end
function widget:SetTargetKey() end
function widget:SetScaleFrom() end
function widget:SetScaleTo() end
function widget:SetFlipBookFrames() end
function widget:SetFlipBookRows() end
function widget:SetFlipBookColumns() end
function widget:SetFlipBookFrameWidth() end
function widget:SetFlipBookFrameHeight() end

-- Widget: textures

function widget:SetTexture(texture)
	self.__texture = texture
end

function widget:GetTexture()
	return self.__texture
end

function widget:SetAtlas(atlas)
	self.__atlas = atlas
end

function widget:GetAtlas()
	return self.__atlas
end

function widget:SetColorTexture(r, g, b, a)
	self.__color = { r, g, b, a or 1 }
end

function widget:SetVertexColor(r, g, b, a)
	self.__vertexColor = { r or 1, g or 1, b or 1, a or 1 }
end

function widget:GetVertexColor()
	local color = self.__vertexColor or { 1, 1, 1, 1 }
	return color[1], color[2], color[3], color[4]
end

function widget:SetTexCoord(...)
	self.__texCoord = { ... }
end

function widget:GetTexCoord()
	local coord = self.__texCoord

	if coord and #coord == 8 then
		return unpack(coord)
	end

	local left, right, top, bottom = 0, 1, 0, 1

	if coord and #coord == 4 then
		left, right, top, bottom = coord[1], coord[2], coord[3], coord[4]
	end

	return left, top, left, bottom, right, top, right, bottom
end

function widget:SetDesaturated(desaturated)
	self.__desaturated = desaturated == true
	return true
end

function widget:SetDesaturation() end
function widget:SetBlendMode() end
function widget:SetRotation() end
function widget:SetHorizTile() end
function widget:SetVertTile() end
function widget:SetSnapToPixelGrid() end
function widget:SetTexelSnappingBias() end
function widget:SetDrawLayer() end

function widget:GetDrawLayer()
	return self.__layer or "ARTWORK", 0
end

function widget:SetGradient() end
function widget:SetMask() end

function widget:AddMaskTexture(mask)
	self.__masks = self.__masks or {}
	self.__masks[#self.__masks + 1] = mask
end

function widget:RemoveMaskTexture(mask)
	if not self.__masks then
		return
	end

	for i, existing in ipairs(self.__masks) do
		if existing == mask then
			table.remove(self.__masks, i)
			return
		end
	end
end

function widget:GetNumMaskTextures()
	return self.__masks and #self.__masks or 0
end

function widget:GetMaskTexture(index)
	return self.__masks and self.__masks[index] or nil
end

-- Widget: text
--
-- String measurement is a linear approximation of the font metrics. Layout code branches on
-- whether text fits, so a constant would make every string the same width and hide the branch.

function widget:SetText(text)
	self.__text = text ~= nil and tostring(text) or ""
end

function widget:SetFormattedText(format, ...)
	self.__text = string.format(format, ...)
end

function widget:GetText()
	return self.__text or ""
end

function widget:SetFont(font, size, flags)
	self.__font = { font, size, flags }
	return true
end

function widget:GetFont()
	local font = self.__font or { "Fonts\\FRIZQT__.TTF", 12, "" }
	return font[1], font[2], font[3]
end

function widget:SetFontObject(fontObject)
	self.__fontObject = fontObject
end

function widget:GetFontObject()
	return self.__fontObject
end

function widget:SetTextColor(r, g, b, a)
	self.__textColor = { r or 1, g or 1, b or 1, a or 1 }
end

function widget:GetTextColor()
	local color = self.__textColor or { 1, 1, 1, 1 }
	return color[1], color[2], color[3], color[4]
end

function widget:GetStringWidth()
	local _, size = self:GetFont()
	return #self:GetText() * (size or 12) * 0.5
end

function widget:GetStringHeight()
	local _, size = self:GetFont()
	return size or 12
end

function widget:GetUnboundedStringWidth()
	return self:GetStringWidth()
end

function widget:GetLineCount()
	return 1
end

function widget:SetJustifyH() end
function widget:SetJustifyV() end
function widget:SetWordWrap() end
function widget:SetNonSpaceWrap() end
function widget:SetSpacing() end
function widget:SetShadowColor() end
function widget:SetShadowOffset() end
function widget:SetMaxLines() end
function widget:SetIndentedWordWrap() end
function widget:CanWordWrap()
	return true
end

-- Widget: buttons

-- The Set/Get texture pairs on buttons and sliders take either a texture object or a file
-- path, and always hand a texture object back - which is what callers immediately size and
-- colour. Storing the string verbatim is what breaks them.
local function assignTexture(self, field, value)
	if type(value) == "table" then
		self[field] = value
		return
	end

	local texture = self[field] or self:CreateTexture()

	if value ~= nil then
		texture:SetTexture(value)
	end

	self[field] = texture
end

local function fetchTexture(self, field)
	self[field] = self[field] or self:CreateTexture()
	return self[field]
end

function widget:SetNormalTexture(texture)
	assignTexture(self, "__normalTexture", texture)
end

function widget:GetNormalTexture()
	return fetchTexture(self, "__normalTexture")
end

function widget:SetPushedTexture(texture)
	assignTexture(self, "__pushedTexture", texture)
end

function widget:GetPushedTexture()
	return fetchTexture(self, "__pushedTexture")
end

function widget:SetDisabledTexture(texture)
	assignTexture(self, "__disabledTexture", texture)
end

function widget:GetDisabledTexture()
	return fetchTexture(self, "__disabledTexture")
end

function widget:SetHighlightTexture(texture)
	assignTexture(self, "__highlightTexture", texture)
end

function widget:GetHighlightTexture()
	return fetchTexture(self, "__highlightTexture")
end

function widget:SetCheckedTexture(texture)
	assignTexture(self, "__checkedTexture", texture)
end

function widget:GetCheckedTexture()
	return fetchTexture(self, "__checkedTexture")
end

function widget:SetFontString(fontString)
	self.__fontString = fontString
end

function widget:GetFontString()
	self.__fontString = self.__fontString or self:CreateFontString()
	return self.__fontString
end

function widget:SetNormalFontObject() end
function widget:SetHighlightFontObject() end
function widget:SetDisabledFontObject() end
function widget:SetHighlightTexCoord() end
function widget:SetMotionScriptsWhileDisabled(enabled)
	self.__motionScripts = enabled == true
end

function widget:GetMotionScriptsWhileDisabled()
	return self.__motionScripts == true
end

function widget:LockHighlight() end
function widget:UnlockHighlight() end

function widget:SetButtonState(state)
	self.__buttonState = state
end

function widget:GetButtonState()
	return self.__buttonState or "NORMAL"
end

function widget:Click()
	runScript(self, "OnClick", "LeftButton", false)
end

function widget:Enable()
	self.__enabled = true
end

function widget:Disable()
	self.__enabled = false
end

function widget:SetEnabled(enabled)
	self.__enabled = enabled ~= false
end

function widget:IsEnabled()
	return self.__enabled ~= false
end

function widget:SetChecked(checked)
	self.__checked = checked and true or false
end

function widget:GetChecked()
	return self.__checked == true
end

-- Widget: sliders and status bars

function widget:SetMinMaxValues(min, max)
	self.__min = min
	self.__max = max
end

function widget:GetMinMaxValues()
	return self.__min or 0, self.__max or 1
end

function widget:SetValue(value)
	self.__value = value
	runScript(self, "OnValueChanged", value)
end

function widget:GetValue()
	return self.__value or 0
end

function widget:SetValueStep() end
function widget:SetObeyStepOnDrag() end
function widget:SetOrientation() end
function widget:SetReverseFill() end
function widget:SetFillStyle() end
function widget:SetStatusBarDesaturated() end

function widget:SetThumbTexture(texture)
	assignTexture(self, "__thumbTexture", texture)
end

function widget:GetThumbTexture()
	return fetchTexture(self, "__thumbTexture")
end

function widget:SetStatusBarTexture(texture)
	assignTexture(self, "__statusBarTexture", texture)
end

function widget:GetStatusBarTexture()
	return fetchTexture(self, "__statusBarTexture")
end

function widget:SetStatusBarColor(r, g, b, a)
	self.__statusBarColor = { r, g, b, a }
end

function widget:GetStatusBarColor()
	local color = self.__statusBarColor or { 1, 1, 1, 1 }
	return color[1], color[2], color[3], color[4]
end

-- Widget: edit boxes

function widget:SetAutoFocus() end
function widget:SetFocus() end
function widget:ClearFocus() end
function widget:HighlightText() end
function widget:SetCursorPosition() end
function widget:SetTextInsets() end
function widget:SetMultiLine() end
function widget:SetNumeric() end
function widget:SetCountInvisibleLetters() end

function widget:SetMaxLetters(letters)
	self.__maxLetters = letters
end

function widget:GetMaxLetters()
	return self.__maxLetters or 0
end

function widget:HasFocus()
	return false
end

-- Widget: scroll frames

function widget:SetScrollChild(child)
	self.__scrollChild = child
end

function widget:GetScrollChild()
	return self.__scrollChild
end

function widget:SetVerticalScroll(offset)
	self.__verticalScroll = offset
end

function widget:GetVerticalScroll()
	return self.__verticalScroll or 0
end

function widget:GetVerticalScrollRange()
	return 0
end

function widget:SetHorizontalScroll() end
function widget:GetHorizontalScroll()
	return 0
end
function widget:UpdateScrollChildRect() end

-- Widget: cooldowns

function widget:SetCooldown(start, duration)
	self.__cooldownStart = start
	self.__cooldownDuration = duration
end

function widget:GetCooldownDuration()
	return self.__cooldownDuration or 0
end

function widget:GetCooldownTimes()
	return (self.__cooldownStart or 0) * 1000, (self.__cooldownDuration or 0) * 1000
end

function widget:SetCooldownDuration() end
function widget:SetCooldownFromDurationObject() end
function widget:SetDurationCooldown() end
function widget:SetDrawBling() end
function widget:SetDrawEdge() end
function widget:SetDrawSwipe() end
function widget:SetHideCountdownNumbers() end
function widget:SetSwipeColor() end
function widget:SetSwipeTexture() end
function widget:SetReverse() end
function widget:SetCountdownFont() end
function widget:SetCountdownMillisecondsThreshold() end
function widget:Clear() end
function widget:Pause_() end

-- Widget: backdrops

function widget:SetBackdrop(backdrop)
	self.__backdrop = backdrop
end

function widget:GetBackdrop()
	return self.__backdrop
end

function widget:SetBackdropColor(r, g, b, a)
	self.__backdropColor = { r, g, b, a or 1 }
end

function widget:GetBackdropColor()
	local color = self.__backdropColor or { 0, 0, 0, 1 }
	return color[1], color[2], color[3], color[4]
end

function widget:SetBackdropBorderColor(r, g, b, a)
	self.__backdropBorderColor = { r, g, b, a or 1 }
end

function widget:GetBackdropBorderColor()
	local color = self.__backdropBorderColor or { 0, 0, 0, 1 }
	return color[1], color[2], color[3], color[4]
end

-- Widget: modern dropdowns
--
-- WowStyle1DropdownTemplate builds its menu through SetupMenu, so running the generator here
-- is what actually exercises an addon's menu-building code rather than just storing it.

function widget:SetupMenu(generator)
	self.__menuGenerator = generator

	if generator then
		generator(self, newMenuDescription())
	end
end

function widget:Update()
	if self.__menuGenerator then
		self.__menuGenerator(self, newMenuDescription())
	end
end

function widget:GenerateMenu()
	self:Update()
end

function widget:IsMenuOpen()
	return false
end

function widget:CloseMenu() end

-- Widget: aura containers
--
-- The 12.1 container system. The client owns the buttons inside a group, so an addon only
-- ever configures groups and reads back which ones exist - which is all that is recorded here.

function widget:AddAuraGroup(key, filterString, options)
	self.__auraGroups = self.__auraGroups or {}
	self.__auraGroups[key] = { Key = key, Filter = filterString, Options = options }
end

function widget:HasAuraGroup(key)
	return self.__auraGroups ~= nil and self.__auraGroups[key] ~= nil
end

function widget:GetAuraGroup(key)
	return self.__auraGroups and self.__auraGroups[key] or nil
end

function widget:SetAuraGroupLayout() end
function widget:SetAuraGroupMaxFrameCount() end
function widget:SetAuraGroupSortMethod() end
function widget:SetAuraGroupCandidateFilters() end
function widget:SetCandidateFilters() end
function widget:SetUseEditModeSource() end
function widget:SetAuraSource() end
function widget:SetFlowLayoutAxis() end
function widget:SetFlowLayoutAnchorPoint() end
function widget:SetFlowLayoutGrowthDirection() end
function widget:SetGridMode() end
function widget:SetInvertLayout() end

-- Widget: models and unit frames

function widget:SetUnit(unit)
	self.__unit = unit
end

function widget:GetUnit()
	return self.__unit
end

function widget:SetPortraitZoom() end
function widget:SetCamDistanceScale() end
function widget:SetModelScale() end
function widget:SetPosition() end
function widget:SetFacing() end
function widget:ClearModel() end
function widget:SetOwner() end
function widget:AddLine() end
function widget:AddDoubleLine() end
function widget:SetSpellByID() end
function widget:SetItemByID() end
function widget:ClearLines() end
function widget:NumLines()
	return 0
end

-- Templates
--
-- CreateFrame errors on an unknown template in game, so a template name here is a promise the
-- frame carries certain members. Only the ones the addons reach for are attached.

local function applyTemplate(frame, template)
	if not template then
		return
	end

	if template:find("UICheckButtonTemplate") or template:find("ChatConfigCheckButtonTemplate") then
		frame.Text = frame:CreateFontString()
		frame.text = frame.Text
	end

	if template:find("UIPanelButtonTemplate") then
		frame.Text = frame:GetFontString()
	end

	if template:find("BackdropTemplate") then
		frame.backdropInfo = nil
	end

	if template:find("UIDropDownMenuTemplate") then
		frame.Button = newWidget("Button", nil, frame)
		frame.Text = frame:CreateFontString()
		frame.Middle = frame:CreateTexture()
		frame.Left = frame:CreateTexture()
		frame.Right = frame:CreateTexture()
	end

	if template:find("OptionsSliderTemplate") or template:find("UISliderTemplate") then
		frame.Low = frame:CreateFontString()
		frame.High = frame:CreateFontString()
		frame.Text = frame:CreateFontString()

		-- The XML template names its children after the slider, and addons written before
		-- the members existed still reach for the globals.
		if frame.__name then
			_G[frame.__name .. "Low"] = frame.Low
			_G[frame.__name .. "High"] = frame.High
			_G[frame.__name .. "Text"] = frame.Text
		end
	end

	if template:find("InputBoxTemplate") or template:find("SearchBoxTemplate") then
		frame.Instructions = frame:CreateFontString()
		frame.clearButton = newWidget("Button", nil, frame)
	end

	if template:find("UIPanelScrollFrameTemplate") or template:find("ScrollFrameTemplate") then
		frame.ScrollBar = newWidget("Slider", nil, frame)
		frame.ScrollBar.ScrollUpButton = newWidget("Button", nil, frame.ScrollBar)
		frame.ScrollBar.ScrollDownButton = newWidget("Button", nil, frame.ScrollBar)
	end
end

-- Public control surface

---Creates a frame outside CreateFrame, for a harness that needs to fake a Blizzard frame.
function M.NewFrame(objectType, name, parent)
	local frame = newWidget(objectType or "Frame", name, parent)
	M.Frames[#M.Frames + 1] = frame
	return frame
end

---Dispatches an event to every frame that registered for it, in creation order.
---@return number handlers the number of frames that received it
function M.FireEvent(event, ...)
	local delivered = 0

	-- Snapshot first: an OnEvent handler is free to create frames, and iterating the live
	-- list while it grows would deliver the event to frames created by the event itself.
	local snapshot = {}

	for i, frame in ipairs(M.Frames) do
		snapshot[i] = frame
	end

	for _, frame in ipairs(snapshot) do
		if frame.__events[event] then
			delivered = delivered + 1
			runScript(frame, "OnEvent", event, ...)
		end
	end

	return delivered
end

---Runs queued C_Timer.After callbacks. Callbacks that queue more timers are picked up by the
---next round; rounds are bounded so a self-rescheduling retry can't hang the suite.
---@param rounds number? defaults to 5
---@return number executed
function M.RunTimers(rounds)
	local executed = 0

	for _ = 1, rounds or 5 do
		if #timers == 0 then
			break
		end

		local pending = timers
		timers = {}

		for _, timer in ipairs(pending) do
			if not timer.cancelled then
				executed = executed + 1
				timer.callback()
			end
		end
	end

	return executed
end

---Fires one tick of every OnUpdate handler.
function M.RunOnUpdate(elapsed)
	local snapshot = {}

	for i, frame in ipairs(M.Frames) do
		snapshot[i] = frame
	end

	for _, frame in ipairs(snapshot) do
		if frame.__scripts.OnUpdate then
			runScript(frame, "OnUpdate", elapsed or 0.1)
		end
	end
end

---Advances the clock GetTime reports.
function M.AdvanceTime(seconds)
	M.State.Time = M.State.Time + (seconds or 1)
end

---Sets the class UnitClass reports for the player, by token (e.g. "DEATHKNIGHT").
function M.SetPlayerClass(token)
	local name = token:sub(1, 1) .. token:sub(2):lower()
	local classIndex = 1

	if _G.RAID_CLASS_COLORS and _G.LOCALIZED_CLASS_NAMES_MALE then
		name = _G.LOCALIZED_CLASS_NAMES_MALE[token] or name
	end

	M.State.Class = { name, token, classIndex }
end

-- Installation

local function installState()
	M.State = {
		Time = 10000,
		BuildNumber = 120100,
		BuildVersion = "12.1.0",
		Locale = "enUS",
		InInstance = false,
		InstanceType = "none",
		InCombat = false,
		InGroup = false,
		InRaid = false,
		GroupMembers = 0,
		-- Which unit tokens UnitExists answers true for. Only the player by default: a stub
		-- world with a full party would send every addon down its group path on load, which
		-- is a state a real client only reaches after PARTY_MEMBERS_CHANGED.
		Units = { player = true },
		Class = { "Warrior", "WARRIOR", 1 },
		Realm = "TestRealm",
		PlayerName = "Tester",
		-- Printed lines, so a suite can assert an addon stayed quiet on a clean load.
		Prints = {},
	}
end

---Installs the whole mock into _G. Safe to call repeatedly; each call resets all state and
---clears whatever the previous run left behind.
---@param options { preserve: string[]? }? names to keep across the reset. Saved variables go
---       here: reinstalling models a /reload, where the frames are gone but the tables the
---       addon wrote are still there, which is the path most worth exercising twice.
function M.Install(options)
	installState()

	local preserve = {}

	for _, name in ipairs(options and options.preserve or {}) do
		preserve[name] = true
	end

	for key in pairs(_G) do
		if not baselineGlobals[key] and not preserve[key] then
			_G[key] = nil
		end
	end

	namedGlobals = {}

	M.Frames = {}
	M.Hooks = {}
	M.BaselineFrameCount = 0
	timers = {}
	tickers = {}
	frameCounter = 0

	local State = M.State

	-- Lua extensions the client adds

	_G.wipe = function(t)
		for key in pairs(t) do
			t[key] = nil
		end

		return t
	end

	-- The client also hangs the table helpers off the table library itself, which is where
	-- some vendored libraries capture them from at load time.
	table.wipe = _G.wipe
	_G.tinsert = table.insert
	_G.tremove = table.remove
	_G.sort = table.sort
	_G.getn = function(t)
		return #t
	end
	_G.strsplit = function(delimiter, text, limit)
		local out = {}
		local pattern = "([^" .. delimiter .. "]*)"

		for match in text:gmatch(pattern .. "[" .. delimiter .. "]?") do
			out[#out + 1] = match

			if limit and #out >= limit then
				break
			end
		end

		-- gmatch with an optional trailing separator yields one empty tail match.
		if out[#out] == "" and #out > 1 then
			table.remove(out)
		end

		return unpack(out)
	end
	_G.strjoin = function(delimiter, ...)
		return table.concat({ ... }, delimiter)
	end
	_G.strtrim = function(text, chars)
		chars = chars or " \t\r\n"
		return (text:gsub("^[" .. chars .. "]+", ""):gsub("[" .. chars .. "]+$", ""))
	end
	_G.strconcat = function(...)
		return table.concat({ ... })
	end
	_G.strrep = string.rep
	_G.strsub = string.sub
	_G.strupper = string.upper
	_G.strlower = string.lower
	_G.strfind = string.find
	_G.strmatch = string.match
	_G.strbyte = string.byte
	_G.strchar = string.char
	_G.strlen = string.len
	_G.gsub = string.gsub
	_G.format = string.format
	_G.max = math.max
	_G.min = math.min
	_G.abs = math.abs
	_G.floor = math.floor
	_G.ceil = math.ceil
	_G.sqrt = math.sqrt
	_G.mod = math.fmod
	_G.random = math.random
	_G.date = os.date
	_G.time = os.time
	_G.difftime = os.difftime
	_G.nop = noop
	_G.securecall = function(fn, ...)
		if type(fn) == "string" then
			return _G[fn](...)
		end

		return fn(...)
	end
	_G.issecure = function()
		return true
	end
	_G.scrub = function(...)
		return ...
	end
	_G.forceinsecure = noop

	-- 12.0 secret values. Nothing in a Lua-only harness is secret, so the predicate is false
	-- and the guards addons wrap around secret handling take their non-secret branch.
	_G.issecretvalue = function()
		return false
	end

	_G.geterrorhandler = function()
		return error
	end

	_G.securecallfunction = function(fn, ...)
		return fn(...)
	end

	-- LuaBitOp, which the client ships and Lua 5.1 does not. Only the operations the vendored
	-- libraries use, on 32-bit values, which is all WoW exposes anyway.
	local function tobit(value)
		value = math.floor(value or 0) % 4294967296

		if value >= 2147483648 then
			value = value - 4294967296
		end

		return value
	end

	local function toUnsigned(value)
		return math.floor(value or 0) % 4294967296
	end

	local function bitwise(a, b, op)
		local result = 0
		local bitValue = 1

		a, b = toUnsigned(a), toUnsigned(b)

		for _ = 1, 32 do
			local aBit = a % 2
			local bBit = b % 2

			if op(aBit == 1, bBit == 1) then
				result = result + bitValue
			end

			a = (a - aBit) / 2
			b = (b - bBit) / 2
			bitValue = bitValue * 2
		end

		return tobit(result)
	end

	_G.bit = {
		tobit = tobit,
		band = function(a, b, ...)
			local result = bitwise(a, b, function(x, y)
				return x and y
			end)

			for i = 1, select("#", ...) do
				result = bitwise(result, (select(i, ...)), function(x, y)
					return x and y
				end)
			end

			return result
		end,
		bor = function(a, b, ...)
			local result = bitwise(a, b, function(x, y)
				return x or y
			end)

			for i = 1, select("#", ...) do
				result = bitwise(result, (select(i, ...)), function(x, y)
					return x or y
				end)
			end

			return result
		end,
		bxor = function(a, b)
			return bitwise(a, b, function(x, y)
				return x ~= y
			end)
		end,
		bnot = function(a)
			return tobit(4294967295 - toUnsigned(a))
		end,
		lshift = function(a, n)
			return tobit(toUnsigned(a) * 2 ^ (n % 32))
		end,
		rshift = function(a, n)
			return tobit(math.floor(toUnsigned(a) / 2 ^ (n % 32)))
		end,
		arshift = function(a, n)
			return tobit(math.floor(tobit(a) / 2 ^ (n % 32)))
		end,
		tohex = function(a)
			return string.format("%08x", toUnsigned(a))
		end,
	}

	_G.tContains = function(t, value)
		for _, existing in pairs(t) do
			if existing == value then
				return true
			end
		end

		return false
	end

	_G.tIndexOf = function(t, value)
		for index, existing in ipairs(t) do
			if existing == value then
				return index
			end
		end

		return nil
	end

	_G.tInvert = function(t)
		local out = {}

		for key, value in pairs(t) do
			out[value] = key
		end

		return out
	end

	_G.tDeleteItem = function(t, value)
		for index = #t, 1, -1 do
			if t[index] == value then
				table.remove(t, index)
			end
		end
	end

	_G.CopyTable = function(source)
		local out = {}

		for key, value in pairs(source) do
			out[key] = type(value) == "table" and _G.CopyTable(value) or value
		end

		return out
	end

	_G.Mixin = function(target, ...)
		for i = 1, select("#", ...) do
			for key, value in pairs((select(i, ...))) do
				target[key] = value
			end
		end

		return target
	end

	_G.CreateFromMixins = function(...)
		return _G.Mixin({}, ...)
	end

	_G.CreateAndInitFromMixin = function(mixin, ...)
		local object = _G.CreateFromMixins(mixin)

		if object.Init then
			object:Init(...)
		end

		return object
	end

	_G.Clamp = function(value, low, high)
		return math.max(low, math.min(high, value))
	end

	_G.Saturate = function(value)
		return _G.Clamp(value, 0, 1)
	end

	_G.Lerp = function(from, to, amount)
		return from + (to - from) * amount
	end

	_G.Round = function(value)
		return math.floor(value + 0.5)
	end

	_G.AbbreviateNumbers = function(value)
		if value >= 1000000 then
			return string.format("%.1fM", value / 1000000)
		end

		if value >= 1000 then
			return string.format("%.1fK", value / 1000)
		end

		return tostring(value)
	end

	_G.AbbreviateLargeNumbers = _G.AbbreviateNumbers

	_G.BreakUpLargeNumbers = function(value)
		return tostring(value)
	end

	_G.FormatLargeNumber = _G.BreakUpLargeNumbers

	_G.SecondsToTime = function(seconds)
		return string.format("%d seconds", math.floor(seconds or 0))
	end

	_G.SecondsToClock = function(seconds)
		seconds = math.floor(seconds or 0)
		return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
	end

	_G.GetCoinTextureString = function(amount)
		return tostring(amount or 0)
	end

	_G.print = function(...)
		local parts = {}

		for i = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end

		State.Prints[#State.Prints + 1] = table.concat(parts, " ")
	end

	-- hooksecurefunc, in both of its shapes: a global by name, or a method on a table.
	_G.hooksecurefunc = function(a, b, c)
		local target, name, hook

		if type(a) == "table" then
			target, name, hook = a, b, c
		else
			target, name, hook = _G, a, b
		end

		local original = target[name]

		if type(original) ~= "function" then
			error("hooksecurefunc: " .. tostring(name) .. " is not a function", 2)
		end

		M.Hooks[#M.Hooks + 1] = tostring(name)

		target[name] = function(...)
			local results = { original(...) }
			hook(...)
			return unpack(results)
		end
	end

	-- Enums and constants
	--
	-- The client's Enum table is exhaustive and addons index it for values they never
	-- compare against anything but each other, so an auto-vivifying table of stable
	-- integers is both accurate enough and immune to the client adding new members.
	local function newEnumGroup()
		local counter = -1

		return setmetatable({}, {
			__index = function(group, key)
				counter = counter + 1
				rawset(group, key, counter)
				return counter
			end,
		})
	end

	_G.Enum = setmetatable({}, {
		__index = function(t, key)
			local group = newEnumGroup()
			rawset(t, key, group)
			return group
		end,
	})

	-- The aura container constants are plain globals rather than Enum members, and addons
	-- index them the same auto-vivifying way.
	for _, name in ipairs({
		"AuraContainerSortMethod",
		"AuraContainerSortDirection",
		"AuraContainerAuraSourceLists",
		"AuraContainerLayout",
	}) do
		_G[name] = newEnumGroup()
	end

	_G.AuraContainerUtil = {
		GetFilterString = function()
			return ""
		end,
	}

	_G.AnchorUtil = {
		FlowLayoutAxis = newEnumGroup(),
		FlowDirection = newEnumGroup(),
		CreateAnchor = function(point, relativeTo, relativePoint, x, y)
			return { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }
		end,
	}

	_G.Constants = setmetatable({}, {
		__index = function(t, key)
			local group = newEnumGroup()
			rawset(t, key, group)
			return group
		end,
	})

	-- Flavour identity. These have to be real distinct numbers rather than left nil: addons
	-- branch on `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`, and two nils compare equal, which
	-- would put a Classic-only client on the retail path by accident.
	_G.WOW_PROJECT_MAINLINE = 1
	_G.WOW_PROJECT_CLASSIC = 2
	_G.WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5
	_G.WOW_PROJECT_WRATH_CLASSIC = 11
	_G.WOW_PROJECT_CATACLYSM_CLASSIC = 14
	_G.WOW_PROJECT_MISTS_CLASSIC = 19
	_G.WOW_PROJECT_ID = _G.WOW_PROJECT_MAINLINE

	_G.LE_EXPANSION_CLASSIC = 0
	_G.LE_EXPANSION_BURNING_CRUSADE = 1
	_G.LE_EXPANSION_WRATH_OF_THE_LICH_KING = 2
	_G.LE_EXPANSION_CATACLYSM = 3
	_G.LE_EXPANSION_MISTS_OF_PANDARIA = 4
	_G.LE_EXPANSION_WARLORDS_OF_DRAENOR = 5
	_G.LE_EXPANSION_LEGION = 6
	_G.LE_EXPANSION_BATTLE_FOR_AZEROTH = 7
	_G.LE_EXPANSION_SHADOWLANDS = 8
	_G.LE_EXPANSION_DRAGONFLIGHT = 9
	_G.LE_EXPANSION_WAR_WITHIN = 10
	_G.LE_EXPANSION_MIDNIGHT = 11
	_G.LE_EXPANSION_LEVEL_CURRENT = 10
	_G.LE_PARTY_CATEGORY_HOME = 1
	_G.LE_PARTY_CATEGORY_INSTANCE = 2
	_G.NUM_CHAT_WINDOWS = 10
	_G.MAX_PARTY_MEMBERS = 4
	_G.MEMBERS_PER_RAID_GROUP = 5
	_G.MAX_RAID_MEMBERS = 40
	_G.MAX_ARENA_ENEMIES = 5
	_G.CHAT_FRAME_TAB_NORMAL_NOMOUSE_ALPHA = 0.4
	_G.OKAY = "Okay"
	_G.CANCEL = "Cancel"
	_G.ACCEPT = "Accept"
	_G.CLOSE = "Close"
	_G.NONE = "None"
	_G.DEFAULT = "Default"
	_G.SAVE = "Save"
	_G.DELETE = "Delete"
	_G.RESET = "Reset"
	_G.ENABLE = "Enable"
	_G.DISABLE = "Disable"
	_G.UNKNOWN = "Unknown"
	_G.HEALER = "Healer"
	_G.TANK = "Tank"
	_G.DAMAGER = "Damage"
	_G.GENERAL = "General"
	_G.OTHER = "Other"
	_G.SETTINGS = "Settings"
	_G.OPTIONS = "Options"
	_G.YES = "Yes"
	_G.NO = "No"
	_G.TOOLTIP_DEFAULT_COLOR = { r = 1, g = 1, b = 1 }
	_G.TOOLTIP_DEFAULT_BACKGROUND_COLOR = { r = 0, g = 0, b = 0 }
	_G.NORMAL_FONT_COLOR = { r = 1, g = 0.82, b = 0 }
	_G.HIGHLIGHT_FONT_COLOR = { r = 1, g = 1, b = 1 }
	_G.GRAY_FONT_COLOR = { r = 0.5, g = 0.5, b = 0.5 }
	_G.RED_FONT_COLOR = { r = 1, g = 0.1, b = 0.1 }
	_G.GREEN_FONT_COLOR = { r = 0.1, g = 1, b = 0.1 }
	_G.BOOKTYPE_SPELL = "spell"
	_G.BOOKTYPE_PET = "pet"
	_G.STATUS_TEXT_DISPLAY_MODE = "NUMERIC"
	_G.CHAT_FRAME_TAB_SELECTED_NOMOUSE_ALPHA = 0.6

	_G.DEBUFF_TYPE_NONE_COLOR = { r = 0.8, g = 0, b = 0 }
	_G.DEBUFF_TYPE_MAGIC_COLOR = { r = 0.2, g = 0.6, b = 1 }
	_G.DEBUFF_TYPE_CURSE_COLOR = { r = 0.6, g = 0, b = 1 }
	_G.DEBUFF_TYPE_DISEASE_COLOR = { r = 0.6, g = 0.4, b = 0 }
	_G.DEBUFF_TYPE_POISON_COLOR = { r = 0, g = 0.6, b = 0 }
	_G.DEBUFF_TYPE_BLEED_COLOR = { r = 0.8, g = 0, b = 0 }

	_G.RAID_CLASS_COLORS = {}
	_G.CUSTOM_CLASS_COLORS = nil

	local classTokens = {
		"WARRIOR",
		"PALADIN",
		"HUNTER",
		"ROGUE",
		"PRIEST",
		"DEATHKNIGHT",
		"SHAMAN",
		"MAGE",
		"WARLOCK",
		"MONK",
		"DRUID",
		"DEMONHUNTER",
		"EVOKER",
	}

	for index, token in ipairs(classTokens) do
		local shade = 0.4 + (index / #classTokens) * 0.5

		_G.RAID_CLASS_COLORS[token] = {
			r = shade,
			g = 1 - shade,
			b = 0.5,
			colorStr = "ff000000",
			GetRGB = function(self)
				return self.r, self.g, self.b
			end,
			GenerateHexColor = function()
				return "ff000000"
			end,
		}
	end

	_G.LOCALIZED_CLASS_NAMES_MALE = {}
	_G.LOCALIZED_CLASS_NAMES_FEMALE = {}

	for _, token in ipairs(classTokens) do
		local name = token:sub(1, 1) .. token:sub(2):lower()
		_G.LOCALIZED_CLASS_NAMES_MALE[token] = name
		_G.LOCALIZED_CLASS_NAMES_FEMALE[token] = name
	end

	_G.PowerBarColor = setmetatable({}, {
		__index = function()
			return { r = 0.5, g = 0.5, b = 0.5 }
		end,
	})

	_G.CLASS_ICON_TCOORDS = setmetatable({}, {
		__index = function()
			return { 0, 0.25, 0, 0.25 }
		end,
	})

	-- Colors

	local colorMixin = {}
	colorMixin.__index = colorMixin

	function colorMixin:GetRGB()
		return self.r, self.g, self.b
	end

	function colorMixin:GetRGBA()
		return self.r, self.g, self.b, self.a
	end

	function colorMixin:GenerateHexColor()
		return string.format("ff%02x%02x%02x", self.r * 255, self.g * 255, self.b * 255)
	end

	function colorMixin:WrapTextInColorCode(text)
		return "|c" .. self:GenerateHexColor() .. text .. "|r"
	end

	_G.CreateColor = function(r, g, b, a)
		return setmetatable({ r = r or 1, g = g or 1, b = b or 1, a = a or 1 }, colorMixin)
	end

	_G.CreateColorFromHexString = function()
		return _G.CreateColor(1, 1, 1, 1)
	end

	_G.ColorMixin = colorMixin
	_G.BackdropTemplateMixin = {}

	-- Widgets

	_G.CreateFrame = function(frameType, name, parent, template, id)
		local frame = newWidget(frameType or "Frame", name, parent)

		frame.__template = template
		frame.__frameId = id

		applyTemplate(frame, template)

		M.Frames[#M.Frames + 1] = frame

		return frame
	end

	_G.EnumerateFrames = function(current)
		if not current then
			return M.Frames[1]
		end

		for index, frame in ipairs(M.Frames) do
			if frame == current then
				return M.Frames[index + 1]
			end
		end

		return nil
	end

	_G.GetMouseFoci = function()
		return {}
	end

	_G.GetMouseFocus = function()
		return nil
	end

	_G.GetCursorPosition = function()
		return 0, 0
	end

	_G.GetCursorInfo = function()
		return nil
	end

	_G.GetScreenWidth = function()
		return 1920
	end

	_G.GetScreenHeight = function()
		return 1080
	end

	-- Font objects. The client exposes these as globals that behave like a font string with no
	-- text: widgets read a size off them and hand them to SetFontObject.
	local fontObjects = {
		GameFontNormal = 12,
		GameFontNormalSmall = 10,
		GameFontNormalLarge = 16,
		GameFontNormalHuge = 20,
		GameFontNormalSmallLeft = 10,
		GameFontHighlight = 12,
		GameFontHighlightSmall = 10,
		GameFontHighlightSmallLeft = 10,
		GameFontHighlightLarge = 16,
		GameFontDisable = 12,
		GameFontDisableSmall = 10,
		GameFontDisableSmallLeft = 10,
		GameFontRed = 12,
		GameFontGreen = 12,
		GameFontWhite = 12,
		GameFontWhiteLarge = 16,
		GameFontBlack = 12,
		NumberFontNormal = 12,
		NumberFontNormalSmall = 10,
		NumberFontNormalLarge = 16,
		NumberFontNormalHuge = 30,
		ChatFontNormal = 12,
		QuestFontNormalSmall = 10,
		TextStatusBarText = 12,
		SystemFont_Shadow_Med1 = 12,
		SystemFont_Outline_Small = 10,
	}

	for name, size in pairs(fontObjects) do
		local font = newWidget("Font", name, nil)

		font:SetFont("Fonts\\FRIZQT__.TTF", size, "")
	end

	_G.PixelUtil = {
		SetWidth = function(region, width)
			region:SetWidth(width)
		end,
		SetHeight = function(region, height)
			region:SetHeight(height)
		end,
		SetSize = function(region, width, height)
			region:SetSize(width, height)
		end,
		SetPoint = function(region, ...)
			region:SetPoint(...)
		end,
		GetNearestPixelSize = function(size)
			return size
		end,
	}

	-- Frame pools

	local function newPool(create, reset)
		local pool = { active = {}, inactive = {} }

		function pool:Acquire()
			local object = table.remove(self.inactive) or create(self)
			self.active[object] = true
			return object, true
		end

		function pool:Release(object)
			if not self.active[object] then
				return false
			end

			self.active[object] = nil
			self.inactive[#self.inactive + 1] = object

			if reset then
				reset(self, object)
			end

			return true
		end

		function pool:ReleaseAll()
			for object in pairs(self.active) do
				self:Release(object)
			end
		end

		function pool:EnumerateActive()
			return pairs(self.active)
		end

		function pool:IsActive(object)
			return self.active[object] == true
		end

		return pool
	end

	_G.CreateFramePool = function(frameType, parent, template, resetFunc)
		return newPool(function()
			return _G.CreateFrame(frameType or "Frame", nil, parent, template)
		end, resetFunc or function(_, frame)
			frame:Hide()
			frame:ClearAllPoints()
		end)
	end

	_G.CreateTexturePool = function(parent, layer, _, _, resetFunc)
		return newPool(function()
			return parent:CreateTexture(nil, layer)
		end, resetFunc)
	end

	_G.CreateObjectPool = function(createFunc, resetFunc)
		return newPool(createFunc, resetFunc)
	end

	-- Time and timers

	_G.GetTime = function()
		return State.Time
	end

	_G.GetTimePreciseSec = function()
		return State.Time
	end

	_G.GetServerTime = function()
		return 1767225600 -- a fixed point in time; nothing here depends on which
	end

	_G.GetFramerate = function()
		return 60
	end

	_G.GetNetStats = function()
		return 0, 0, 30, 30
	end

	_G.debugprofilestop = function()
		return State.Time * 1000
	end

	local function newTimer(callback)
		local timer = { callback = callback, cancelled = false }

		function timer:Cancel()
			self.cancelled = true
		end

		function timer:IsCancelled()
			return self.cancelled
		end

		return timer
	end

	_G.C_Timer = {
		After = function(_, callback)
			timers[#timers + 1] = newTimer(callback)
		end,
		NewTimer = function(_, callback)
			local timer = newTimer(callback)
			timers[#timers + 1] = timer
			return timer
		end,
		NewTicker = function(_, callback)
			-- A ticker never fires on its own here: by definition it repeats, so running one
			-- during a drain would either loop forever or fire an arbitrary number of times.
			local ticker = newTimer(callback)
			tickers[#tickers + 1] = ticker
			return ticker
		end,
	}

	-- Client info

	_G.GetBuildInfo = function()
		return State.BuildVersion, "60000", "Jan 1 2026", State.BuildNumber
	end

	_G.GetLocale = function()
		return State.Locale
	end

	_G.GetRealmName = function()
		return State.Realm
	end

	_G.GetNormalizedRealmName = function()
		return (State.Realm:gsub("%s", ""))
	end

	_G.IsInInstance = function()
		return State.InInstance, State.InstanceType
	end

	_G.GetInstanceInfo = function()
		return "Test Zone", State.InstanceType, 0, "", 0, 0, false, 0, 0, 0
	end

	_G.InCombatLockdown = function()
		return State.InCombat
	end

	_G.UnitAffectingCombat = function()
		return State.InCombat
	end

	_G.IsLoggedIn = function()
		return true
	end

	_G.IsInGroup = function()
		return State.InGroup
	end

	_G.IsInRaid = function()
		return State.InRaid
	end

	_G.IsInGuild = function()
		return false
	end

	_G.GetNumGroupMembers = function()
		return State.GroupMembers
	end

	_G.GetNumSubgroupMembers = function()
		return math.max(0, State.GroupMembers - 1)
	end

	_G.IsActiveBattlefieldArena = function()
		return false
	end

	_G.IsShiftKeyDown = function()
		return false
	end

	_G.IsControlKeyDown = function()
		return false
	end

	_G.IsAltKeyDown = function()
		return false
	end

	_G.IsModifierKeyDown = function()
		return false
	end

	_G.PlayerIsTimerunning = function()
		return false
	end

	_G.ReloadUI = noop
	_G.PlaySound = noop
	_G.PlaySoundFile = noop
	_G.StopSound = noop
	_G.Ambiguate = function(name)
		return name
	end
	_G.HideUIPanel = noop
	_G.ShowUIPanel = noop
	_G.StaticPopup_Show = noop
	_G.StaticPopup_Hide = noop
	_G.StaticPopupDialogs = {}
	_G.SlashCmdList = {}
	_G.SendChatMessage = noop
	_G.SendSystemMessage = noop
	_G.RegisterAttributeDriver = noop
	_G.UnregisterAttributeDriver = noop
	_G.RegisterStateDriver = noop
	_G.UnregisterStateDriver = noop
	_G.SetBinding = noop
	_G.SetBindingClick = noop
	_G.ClearOverrideBindings = noop
	_G.SetOverrideBindingClick = noop
	_G.GetBindingKey = function()
		return nil
	end
	_G.GetBinding = function()
		return nil
	end
	_G.GetNumBindings = function()
		return 0
	end
	_G.SaveBindings = noop
	_G.GetCurrentBindingSet = function()
		return 1
	end

	-- Units

	local function unitExists(unit)
		return unit ~= nil and State.Units[unit] == true
	end

	_G.UnitExists = unitExists

	_G.UnitIsUnit = function(a, b)
		return a == b
	end

	_G.UnitGUID = function(unit)
		return unitExists(unit) and ("Player-1-" .. unit) or nil
	end

	_G.UnitTokenFromGUID = function()
		return nil
	end

	_G.UnitName = function(unit)
		if not unitExists(unit) then
			return nil, nil
		end

		return unit == "player" and State.PlayerName or unit, nil
	end

	_G.UnitNameUnmodified = _G.UnitName
	_G.GetUnitName = function(unit)
		return (_G.UnitName(unit))
	end

	_G.UnitClass = function(unit)
		if not unitExists(unit) then
			return nil, nil, nil
		end

		return State.Class[1], State.Class[2], State.Class[3]
	end

	_G.UnitClassBase = function(unit)
		local _, token = _G.UnitClass(unit)
		return token
	end

	_G.UnitRace = function()
		return "Human", "Human", 1
	end

	_G.UnitLevel = function()
		return 80
	end

	_G.UnitSex = function()
		return 2
	end

	_G.UnitFactionGroup = function()
		return "Alliance", "Alliance"
	end

	_G.UnitCreatureType = function()
		return "Humanoid"
	end

	_G.UnitIsPlayer = unitExists
	_G.UnitIsConnected = unitExists
	_G.UnitIsVisible = unitExists
	_G.UnitPlayerControlled = unitExists

	_G.UnitIsDeadOrGhost = function()
		return false
	end

	_G.UnitIsDead = function()
		return false
	end

	_G.UnitIsGhost = function()
		return false
	end

	_G.UnitIsFeignDeath = function()
		return false
	end

	_G.UnitIsCharmed = function()
		return false
	end

	_G.UnitIsPVP = function()
		return false
	end

	_G.UnitIsTapDenied = function()
		return false
	end

	_G.UnitIsFriend = function()
		return true
	end

	_G.UnitIsEnemy = function()
		return false
	end

	_G.UnitCanAttack = function()
		return false
	end

	_G.UnitCanAssist = function()
		return true
	end

	_G.UnitReaction = function()
		return 5
	end

	_G.UnitInParty = function()
		return false
	end

	_G.UnitInRaid = function()
		return nil
	end

	_G.UnitInRange = function()
		return true, true
	end

	_G.UnitIsInMyGuild = function()
		return false
	end

	_G.UnitIsOtherPlayersPet = function()
		return false
	end

	_G.UnitIsMinion = function()
		return false
	end

	_G.UnitPlayerOrPetInParty = function()
		return false
	end

	_G.UnitPlayerOrPetInRaid = function()
		return false
	end

	_G.UnitHealth = function(unit)
		return unitExists(unit) and 100 or 0
	end

	_G.UnitHealthMax = function(unit)
		return unitExists(unit) and 100 or 0
	end

	_G.UnitPower = function(unit)
		return unitExists(unit) and 50 or 0
	end

	_G.UnitPowerMax = function(unit)
		return unitExists(unit) and 100 or 0
	end

	_G.UnitPowerType = function()
		return 0, "MANA"
	end

	_G.UnitStagger = function()
		return 0
	end

	_G.UnitGetTotalAbsorbs = function()
		return 0
	end

	_G.UnitGetIncomingHeals = function()
		return 0
	end

	_G.UnitGetDetailedHealPrediction = function()
		return 0, 0, 0
	end

	_G.UnitGroupRolesAssigned = function()
		return "NONE"
	end

	_G.UnitThreatSituation = function()
		return nil
	end

	_G.UnitSpellHaste = function()
		return 0
	end

	_G.UnitAffectingCombat = function()
		return State.InCombat
	end

	_G.UnitCastingInfo = function()
		return nil
	end

	_G.UnitChannelInfo = function()
		return nil
	end

	_G.UnitAura = function()
		return nil
	end

	_G.UnitBuff = function()
		return nil
	end

	_G.UnitDebuff = function()
		return nil
	end

	---12.0's secure power reader: evaluates the unit's power through a curve, so the caller
	---never sees the raw value. What comes back is whatever the curve produces, so a colour
	---curve yields a colour and a plain one yields a number - the mock reads the curve's own
	---kind to decide, since callers use the result immediately and would break on the wrong
	---shape.
	_G.UnitPowerPercent = function(_, _, _, curve)
		if curve and curve.__isColorCurve then
			return _G.CreateColor(1, 1, 1, 1)
		end

		return 0.5
	end

	_G.UnitHealthPercent = function()
		return 1
	end

	_G.GetRuneCooldown = function()
		return State.Time, 10, true
	end

	_G.GetRuneCount = function()
		return 1
	end

	_G.GetRuneType = function()
		return 1
	end

	_G.GetRunicPower = function()
		return 0
	end

	_G.CheckInteractDistance = function()
		return true
	end

	-- PlayerLocation, the opaque handle the newer unit APIs take instead of a unit token.
	_G.PlayerLocation = {
		CreateFromUnit = function(unit)
			return { unit = unit, IsValid = function()
				return true
			end }
		end,
		CreateFromGUID = function(guid)
			return { guid = guid, IsValid = function()
				return true
			end }
		end,
	}

	_G.GetPartyAssignment = function()
		return false
	end

	_G.GetRaidRosterInfo = function()
		return nil
	end

	_G.GetHomePartyInfo = function()
		return nil
	end

	_G.SetPortraitTexture = noop
	_G.SetPortraitToTexture = noop

	-- Spells, items and talents

	_G.GetSpellInfo = function(spellId)
		return "Spell " .. tostring(spellId), nil, 134400, 0, 0, 0, spellId
	end

	_G.GetSpellTexture = function()
		return 134400
	end

	_G.GetSpellCooldown = function()
		return 0, 0, 1
	end

	_G.GetSpellLink = function(spellId)
		return "|cff71d5ff|Hspell:" .. tostring(spellId) .. "|h[Spell]|h|r"
	end

	_G.IsSpellKnown = function()
		return false
	end

	-- The pre-11.0 spell book, still called by the addons that ship to Classic.
	_G.GetNumSpellTabs = function()
		return 0
	end

	_G.GetSpellTabInfo = function()
		return nil
	end

	_G.GetSpellBookItemInfo = function()
		return nil
	end

	_G.GetSpellBookItemName = function()
		return nil
	end

	_G.IsSpellInRange = function()
		return nil
	end

	_G.IsSpellBookItemInRange = function()
		return nil
	end

	_G.IsItemInRange = function()
		return nil
	end

	_G.GetAchievementCriteriaInfoByID = function()
		return nil
	end

	_G.GetAchievementInfo = function()
		return nil
	end

	_G.GetGuildInfo = function()
		return nil
	end

	_G.GetCurrentRegion = function()
		return 3
	end

	_G.GetMaxBattlefieldID = function()
		return 2
	end

	_G.GetBattlefieldStatus = function()
		return "none"
	end

	_G.GetBattlefieldTimeWaited = function()
		return 0
	end

	_G.GetBattlefieldEstimatedWaitTime = function()
		return 0
	end

	_G.GetLFGMode = function()
		return nil
	end

	_G.GetLFGQueueStats = function()
		return nil
	end

	_G.GetItemInfo = function()
		return nil
	end

	_G.GetItemIcon = function()
		return 134400
	end

	_G.GetInventoryItemID = function()
		return nil
	end

	_G.GetInventoryItemLink = function()
		return nil
	end

	_G.GetInventoryItemCooldown = function()
		return 0, 0, 1
	end

	_G.GetInventoryItemDurability = function()
		return nil
	end

	_G.GetInventorySlotInfo = function()
		return 13, "Interface\\Icons\\Temp"
	end

	_G.GetMoney = function()
		return 0
	end

	_G.GetSpecialization = function()
		return 1
	end

	_G.GetSpecializationInfo = function(index)
		return 250 + (index or 1), "Spec", "A spec", 134400, "DAMAGER"
	end

	_G.GetSpecializationInfoByID = function(specId)
		return specId, "Spec", "A spec", 134400, "DAMAGER", "WARRIOR"
	end

	_G.GetNumSpecializations = function()
		return 3
	end

	_G.GetNumSpecializationsForClassID = function()
		return 3
	end

	_G.GetSpecializationInfoForClassID = function(_, index)
		return 250 + (index or 1), "Spec", "A spec", 134400, "DAMAGER"
	end

	_G.GetInspectSpecialization = function()
		return 0
	end

	_G.GetNumClasses = function()
		return #classTokens
	end

	_G.GetClassInfo = function(index)
		local token = classTokens[index] or "WARRIOR"
		return token:sub(1, 1) .. token:sub(2):lower(), token, index
	end

	_G.GetClassColor = function(token)
		local color = _G.RAID_CLASS_COLORS[token]

		if not color then
			return 1, 1, 1, "ffffffff"
		end

		return color.r, color.g, color.b, "ff000000"
	end

	_G.GetClassColorObj = function(token)
		local color = _G.RAID_CLASS_COLORS[token]
		return color and _G.CreateColor(color.r, color.g, color.b, 1) or _G.CreateColor(1, 1, 1, 1)
	end

	_G.FillLocalizedClassList = function(t)
		for _, token in ipairs(classTokens) do
			t[token] = token:sub(1, 1) .. token:sub(2):lower()
		end

		return t
	end

	_G.LocalizedClassList = function()
		return _G.FillLocalizedClassList({})
	end

	_G.CanInspect = function()
		return false
	end

	_G.NotifyInspect = noop
	_G.ClearInspectPlayer = noop

	_G.CombatLogGetCurrentEventInfo = function()
		return State.Time, "SPELL_CAST_SUCCESS", false, "Player-1-player", "Tester", 0, 0, nil, nil, 0, 0
	end

	_G.GetCVar = function()
		return "0"
	end

	_G.SetCVar = noop

	_G.GetCVarBool = function()
		return false
	end

	-- C_ namespaces
	--
	-- Only the members these addons call. A missing one is a smoke-test failure, not a silent
	-- nil, which is the trade explained at the top of the file.

	_G.C_AddOns = {
		IsAddOnLoaded = function()
			return false, false
		end,
		GetAddOnEnableState = function()
			return 0
		end,
		GetAddOnMetadata = function(_, field)
			return field == "Version" and "1.0.0" or nil
		end,
		LoadAddOn = function()
			return false, "DISABLED"
		end,
		GetNumAddOns = function()
			return 0
		end,
		GetAddOnInfo = function()
			return nil
		end,
	}

	_G.C_Timer = _G.C_Timer

	_G.C_UI = {
		Reload = noop,
	}

	_G.C_CVar = {
		GetCVar = function()
			return "0"
		end,
		SetCVar = noop,
		RegisterCVar = noop,
		SetCVarBitfield = noop,
		GetCVarBitfield = function()
			return false
		end,
	}

	_G.C_ChatInfo = {
		RegisterAddonMessagePrefix = function()
			return true
		end,
		SendAddonMessage = function()
			return true
		end,
	}

	_G.C_Spell = {
		GetSpellInfo = function(spellId)
			return {
				name = "Spell " .. tostring(spellId),
				spellID = spellId,
				iconID = 134400,
				castTime = 0,
				minRange = 0,
				maxRange = 40,
			}
		end,
		GetSpellName = function(spellId)
			return "Spell " .. tostring(spellId)
		end,
		GetSpellTexture = function()
			return 134400
		end,
		GetSpellCooldown = function()
			return { startTime = 0, duration = 0, isEnabled = true, modRate = 1 }
		end,
		IsSpellInRange = function()
			return nil
		end,
		IsSpellImportant = function()
			return false
		end,
		IsSpellCrowdControl = function()
			return false
		end,
		DoesSpellExist = function()
			return true
		end,
	}

	_G.C_SpellBook = {
		GetNumSpellBookSkillLines = function()
			return 0
		end,
		GetSpellBookSkillLineInfo = function()
			return nil
		end,
		GetSpellBookItemInfo = function()
			return nil
		end,
		GetSpellBookItemName = function()
			return nil
		end,
		IsSpellKnownOrInSpellBook = function()
			return false
		end,
	}

	_G.C_Item = {
		GetItemInfo = function()
			return nil
		end,
		GetItemIconByID = function()
			return 134400
		end,
		IsItemInRange = function()
			return nil
		end,
		IsItemKeystoneByID = function()
			return false
		end,
		GetItemCount = function()
			return 0
		end,
		IsItemDataCachedByID = function()
			return true
		end,
		RequestLoadItemDataByID = noop,
	}

	_G.C_Container = {
		GetContainerNumSlots = function()
			return 0
		end,
		GetContainerItemID = function()
			return nil
		end,
		GetContainerItemLink = function()
			return nil
		end,
		GetContainerItemInfo = function()
			return nil
		end,
	}

	_G.C_NamePlate = {
		GetNamePlates = function()
			return {}
		end,
		GetNamePlateForUnit = function()
			return nil
		end,
		SetNamePlateEnemySize = noop,
		SetNamePlateFriendlySize = noop,
	}

	_G.C_UnitAuras = {
		GetAuraDataByAuraInstanceID = function()
			return nil
		end,
		GetAuraDataBySlot = function()
			return nil
		end,
		GetAuraSlots = function()
			return nil
		end,
		GetUnitAuras = function()
			return nil
		end,
		GetAuraDuration = function()
			return nil
		end,
		GetAuraDispelTypeColor = function()
			return _G.CreateColor(1, 1, 1, 1)
		end,
		IsAuraFilteredOutByInstanceID = function()
			return true
		end,
		AuraIsBigDefensive = function()
			return false
		end,
		AddAuraSound = function()
			return 1
		end,
		RemoveAuraSound = noop,
	}

	_G.C_PvP = {
		GetActiveMatchState = function()
			return 99
		end,
		GetArenaCrowdControlDuration = function()
			return nil
		end,
		IsRatedArena = function()
			return false
		end,
		GetPersonalRatedInfo = function()
			return 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
		end,
	}

	_G.C_Texture = {
		GetAtlasInfo = function()
			return {
				file = 0,
				width = 32,
				height = 32,
				leftTexCoord = 0,
				rightTexCoord = 1,
				topTexCoord = 0,
				bottomTexCoord = 1,
			}
		end,
	}

	_G.C_ClassColor = {
		GetClassColor = function(token)
			local color = _G.RAID_CLASS_COLORS[token]
			return color and _G.CreateColor(color.r, color.g, color.b, 1) or nil
		end,
	}

	_G.C_PlayerInfo = {
		GetClass = function()
			return State.Class[3], State.Class[2], State.Class[1]
		end,
		GetPlayerMythicPlusRatingSummary = function()
			return { currentSeasonScore = 0, runs = {} }
		end,
		UnitIsSameServer = function()
			return true
		end,
	}

	_G.C_SpecializationInfo = {
		GetSpecialization = function()
			return 1
		end,
		GetSpecializationInfo = function(index)
			return 250 + (index or 1), "Spec", "A spec", 134400, "DAMAGER"
		end,
		GetAllSelectedPvpTalentIDs = function()
			return {}
		end,
		GetTalentInfo = function()
			return nil
		end,
		GetPvpTalentSlotInfo = function()
			return nil
		end,
	}

	_G.C_ClassTalents = {
		GetActiveConfigID = function()
			return nil
		end,
		GetTraitTreeForSpec = function()
			return 0
		end,
		InitializeViewLoadout = noop,
		ViewLoadout = noop,
	}

	_G.C_Traits = {
		GetConfigInfo = function()
			return nil
		end,
		GetTreeNodes = function()
			return {}
		end,
		GetNodeInfo = function()
			return nil
		end,
		GetEntryInfo = function()
			return nil
		end,
		GetDefinitionInfo = function()
			return nil
		end,
		GenerateImportString = function()
			return ""
		end,
		GetLoadoutSerializationVersion = function()
			return 2
		end,
	}

	_G.C_MythicPlus = {
		GetOwnedKeystoneChallengeMapID = function()
			return nil
		end,
		GetOwnedKeystoneLevel = function()
			return nil
		end,
		RequestMapInfo = noop,
	}

	_G.C_ChallengeMode = {
		GetMapUIInfo = function()
			return "Test Dungeon", 0, 0
		end,
	}

	_G.C_WeeklyRewards = {
		GetActivities = function()
			return {}
		end,
	}

	_G.C_CurrencyInfo = {
		GetCurrencyInfo = function()
			return { quantity = 0, maxQuantity = 0, name = "Honor" }
		end,
	}

	_G.C_Bank = {
		CanDepositMoney = function()
			return false
		end,
		CanWithdrawMoney = function()
			return false
		end,
		DepositMoney = noop,
		WithdrawMoney = noop,
		FetchDepositedMoney = function()
			return 0
		end,
	}

	_G.C_BattleNet = {
		GetFriendAccountInfo = function()
			return nil
		end,
		GetFriendNumGameAccounts = function()
			return 0
		end,
	}

	_G.C_VoiceChat = {
		GetTtsVoices = function()
			return {}
		end,
		SpeakText = noop,
	}

	_G.C_TTSSettings = {
		GetVoiceOptionID = function()
			return 0
		end,
		SetVoiceOptionID = noop,
	}

	_G.C_TooltipInfo = {
		GetUnit = function()
			return nil
		end,
		GetInventoryItem = function()
			return nil
		end,
	}

	_G.C_KeyBindings = {
		GetBindingByKey = function()
			return nil
		end,
	}

	_G.C_HouseEditor = {
		IsHouseEditorActive = function()
			return false
		end,
	}

	_G.C_Secrets = {
		ShouldAurasBeSecret = function()
			return false
		end,
		GetSpellAuraSecrecy = function()
			return nil
		end,
	}

	_G.C_EncodingUtil = {
		EncodeBase64 = function(value)
			return value
		end,
		DecodeBase64 = function(value)
			return value
		end,
		SerializeJSON = function()
			return "{}"
		end,
		DeserializeJSON = function()
			return {}
		end,
		SerializeCBOR = function()
			return ""
		end,
		DeserializeCBOR = function()
			return {}
		end,
		CompressString = function(value)
			return value
		end,
		DecompressString = function(value)
			return value
		end,
	}

	-- 12.0 curve and duration objects. Both are opaque handles in game; here they are plain
	-- tables that answer the getters, which is enough for anything that isn't secret.
	local function newCurve(isColor)
		return {
			__isColorCurve = isColor == true,
			SetType = noop,
			AddPoint = noop,
			AddColorPoint = noop,
			ClearPoints = noop,
			EvaluateValue = function()
				return 0
			end,
			EvaluateColorValue = function()
				return 1, 1, 1, 1
			end,
		}
	end

	_G.C_CurveUtil = {
		CreateCurve = function()
			return newCurve(false)
		end,
		CreateColorCurve = function()
			return newCurve(true)
		end,
		EvaluateColorValueFromBoolean = function(boolean, ifTrue, ifFalse)
			return boolean and ifTrue or ifFalse
		end,
	}

	_G.C_DurationUtil = {
		CreateDuration = function()
			return {
				SetTimeFromStart = noop,
				SetDuration = noop,
				GetRemainingDuration = function()
					return 0
				end,
				GetTotalDuration = function()
					return 0
				end,
				EvaluateRemainingDuration = function()
					return 0
				end,
				EvaluateRemainingPercent = function()
					return 0
				end,
				EvaluateTotalDuration = function()
					return 0
				end,
			}
		end,
	}

	-- Settings

	local function newCategory(name)
		local id = "category:" .. tostring(name)

		return {
			ID = id,
			name = name,
			GetID = function()
				return id
			end,
			SetID = noop,
			GetName = function()
				return name
			end,
		}
	end

	_G.Settings = {
		RegisterCanvasLayoutCategory = function(_, name)
			return newCategory(name)
		end,
		RegisterCanvasLayoutSubcategory = function(_, _, name)
			return newCategory(name)
		end,
		RegisterAddOnCategory = noop,
		OpenToCategory = noop,
		RegisterVerticalLayoutCategory = function(name)
			return newCategory(name)
		end,
	}

	_G.SettingsPanel = _G.CreateFrame("Frame", "SettingsPanel", nil)
	_G.SettingsPanel.Container = _G.CreateFrame("Frame", nil, _G.SettingsPanel)
	_G.SettingsPanel.Container:SetSize(700, 600)

	-- Root frames

	_G.UIParent = _G.CreateFrame("Frame", "UIParent", nil)
	_G.UIParent:SetSize(1920, 1080)
	_G.WorldFrame = _G.CreateFrame("Frame", "WorldFrame", nil)
	_G.WorldFrame:SetSize(1920, 1080)

	_G.GameTooltip = _G.CreateFrame("GameTooltip", "GameTooltip", _G.UIParent)
	_G.GetAppropriateTooltip = function()
		return _G.GameTooltip
	end
	_G.GetValueOrCallFunction = function(t, key, ...)
		local value = t[key]

		if type(value) == "function" then
			return value(t, ...)
		end

		return value
	end
	_G.GameTooltip_Hide = noop
	_G.GameTooltip_SetDefaultAnchor = noop
	_G.GameTooltip_SetTitle = noop
	_G.GameTooltip_AddNormalLine = noop
	_G.GameTooltip_AddColoredLine = noop
	_G.GameTooltip_AddErrorLine = noop
	_G.GameTooltip_AddInstructionLine = noop
	_G.SharedTooltip_SetBackdropStyle = noop

	-- Blizzard frames and functions the addons hook or read. Present but inert: an addon that
	-- feature-detects one takes the branch it would take on a real retail client.

	-- Unit frames, down to the nesting the addons that restyle them index into. The names are
	-- Blizzard's; an addon reading one that isn't here is reading a path that no longer
	-- exists on retail either, which is worth a test failure rather than a silent nil.
	local function newUnitFrame(name, unit, contentField)
		local frame = _G.CreateFrame("Button", name, _G.UIParent)
		frame.unit = unit

		local content = _G.CreateFrame("Frame", nil, frame)
		local main = _G.CreateFrame("Frame", nil, content)
		local contextual = _G.CreateFrame("Frame", nil, content)

		main.StatusTexture = main:CreateTexture()
		main.HealthBarsContainer = _G.CreateFrame("Frame", nil, main)
		main.HealthBarsContainer.HealthBar = _G.CreateFrame("StatusBar", nil, main.HealthBarsContainer)
		main.ManaBarArea = _G.CreateFrame("Frame", nil, main)
		main.ManaBarArea.ManaBar = _G.CreateFrame("StatusBar", nil, main.ManaBarArea)
		main.ReputationColor = main:CreateTexture()

		contextual.PrestigeBadge = contextual:CreateTexture()
		contextual.PrestigePortrait = contextual:CreateTexture()
		contextual.PlayerPortraitCornerIcon = contextual:CreateTexture()
		contextual.PlayerRestLoop = _G.CreateFrame("Frame", nil, contextual)
		contextual.LevelText = contextual:CreateFontString()
		contextual.PlayerLevelText = contextual:CreateFontString()

		content[contentField .. "Main"] = main
		content[contentField .. "Contextual"] = contextual

		frame[contentField] = content
		frame.healthbar = main.HealthBarsContainer.HealthBar
		frame.manabar = main.ManaBarArea.ManaBar
		frame.portrait = frame:CreateTexture()
		frame.name = frame:CreateFontString()

		return frame
	end

	_G.PlayerFrame = newUnitFrame("PlayerFrame", "player", "PlayerFrameContent")
	-- Target and focus share the target frame's layout, hence the same field name on both.
	_G.TargetFrame = newUnitFrame("TargetFrame", "target", "TargetFrameContent")
	_G.FocusFrame = newUnitFrame("FocusFrame", "focus", "TargetFrameContent")
	_G.PetFrame = newUnitFrame("PetFrame", "pet", "PetFrameContent")

	_G.PlayerLevelText = _G.PlayerFrame.PlayerFrameContent.PlayerFrameContentContextual.PlayerLevelText

	-- Chat. Each window is a frame plus a tab, an edit box, a button frame and the nine
	-- background textures, all reachable by name - which is how addons that fade chat find
	-- them, since none of them are exposed as members.
	local chatTextures = {
		"TopLeftTexture",
		"TopRightTexture",
		"BottomLeftTexture",
		"BottomRightTexture",
		"TopTexture",
		"BottomTexture",
		"LeftTexture",
		"RightTexture",
		"BackgroundTexture",
	}

	for index = 1, _G.NUM_CHAT_WINDOWS do
		local chatName = "ChatFrame" .. index
		local chatFrame = _G.CreateFrame("ScrollingMessageFrame", chatName, _G.UIParent)

		-- Addons that bypass print() and write to a chat window directly still land in the
		-- same transcript, so a suite only has one place to look.
		chatFrame.AddMessage = function(_, message)
			State.Prints[#State.Prints + 1] = tostring(message)
		end

		local tab = _G.CreateFrame("Button", chatName .. "Tab", chatFrame)
		tab.noMouseAlpha = 0.4
		tab.Text = tab:CreateFontString()

		_G.CreateFrame("EditBox", chatName .. "EditBox", chatFrame)
		_G.CreateFrame("Frame", chatName .. "ButtonFrame", chatFrame)

		for _, suffix in ipairs(chatTextures) do
			_G[chatName .. suffix] = chatFrame:CreateTexture()
		end
	end

	_G.DEFAULT_CHAT_FRAME = _G.ChatFrame1
	_G.SELECTED_CHAT_FRAME = _G.ChatFrame1

	-- Action bars. Every button carries a HotKey and a Name font string, which is what the
	-- addons that strip action bar text reach for, by name, twelve at a time.
	local actionBars = {
		"ActionButton",
		"MultiBarBottomLeftButton",
		"MultiBarBottomRightButton",
		"MultiBarLeftButton",
		"MultiBarRightButton",
		"MultiBar5Button",
		"MultiBar6Button",
		"MultiBar7Button",
		"PetActionButton",
		"StanceButton",
	}

	for _, prefix in ipairs(actionBars) do
		for index = 1, 12 do
			local buttonName = prefix .. index
			local button = _G.CreateFrame("CheckButton", buttonName, _G.UIParent)

			button.HotKey = button:CreateFontString(buttonName .. "HotKey")
			button.Name = button:CreateFontString(buttonName .. "Name")
			button.Count = button:CreateFontString(buttonName .. "Count")
			button.icon = button:CreateTexture(buttonName .. "Icon")
			button.cooldown = _G.CreateFrame("Cooldown", buttonName .. "Cooldown", button)
			button.action = index
		end
	end

	-- Containers and bars other addons show, hide or fade wholesale.
	for _, name in ipairs({
		"MainMenuBar",
		"MicroMenu",
		"MicroMenuContainer",
		"BagsBar",
		"StanceBar",
		"PetActionBar",
		"MultiBarBottomLeft",
		"MultiBarBottomRight",
		"MultiBarLeft",
		"MultiBarRight",
		"BuffFrame",
		"DebuffFrame",
		"ObjectiveTrackerFrame",
		"QuickJoinToastButton",
		"StatusTrackingBarManager",
		"CompactRaidFrameManager",
		"CompactRaidFrameContainer",
		"CompactPartyFrame",
		"TotemFrame",
		"MinimapCluster",
		"Minimap",
		"GameMenuFrame",
		"ArenaEnemyFramesContainer",
	}) do
		_G.CreateFrame("Frame", name, _G.UIParent)
	end

	_G.MainMenuBar.EndCaps = _G.CreateFrame("Frame", nil, _G.MainMenuBar)
	_G.MicroMenu.CharacterMicroButton = _G.CreateFrame("Button", "CharacterMicroButton", _G.MicroMenu)
	_G.GetActionInfo = function()
		return nil
	end
	_G.GetActionText = function()
		return nil
	end
	_G.GetMacroInfo = function()
		return nil
	end
	_G.GetMacroIndexByName = function()
		return 0
	end
	_G.GetMacroBodyFromAction = function()
		return nil
	end

	_G.CompactUnitFrame_UpdateAll = noop
	_G.CompactUnitFrame_SetUnit = noop
	_G.CompactUnitFrame_UpdateVisible = noop
	_G.CompactUnitFrame_UpdateRoleIcon = noop
	_G.CompactUnitFrame_UpdateHealPrediction = noop
	_G.CompactUnitFrame_UpdateCenterStatusIcon = noop
	_G.UnitFrameHealthBar_Update = noop
	_G.UnitFrameHealthBar_OnValueChanged = noop
	_G.FCFTab_UpdateAlpha = noop
	-- The modern menu system. Its presence is what puts an addon on the retail dropdown path
	-- rather than the LibUIDropDownMenu fallback, so leaving it out would quietly test the
	-- Classic branch on a client the mock otherwise reports as retail.
	_G.MenuUtil = {
		CreateRadioMenu = noop,
		CreateCheckboxMenu = noop,
		CreateContextMenu = function(_, generator)
			if generator then
				generator(nil, newMenuDescription())
			end
		end,
		CreateButtonMenu = noop,
		HideTooltip = noop,
		ShowTooltip = noop,
	}

	_G.MenuConstants = {
		VerticalGridDirection = 1,
		HorizontalGridDirection = 2,
	}

	_G.CloseMenus = noop
	_G.CloseDropDownMenus = noop
	_G.ToggleDropDownMenu = noop
	_G.HideDropDownMenu = noop
	_G.EasyMenu = noop
	_G.UIDropDownMenu_Initialize = noop
	_G.UIDropDownMenu_CreateInfo = function()
		return {}
	end
	_G.UIDropDownMenu_AddButton = noop
	_G.UIDropDownMenu_SetWidth = noop
	_G.UIDropDownMenu_SetText = noop
	_G.UIDropDownMenu_SetMaxHeight = noop
	_G.UIDropDownMenu_HandleGlobalMouseEvent = noop
	_G.FauxScrollFrame_Update = noop
	_G.FauxScrollFrame_GetOffset = function()
		return 0
	end
	_G.FauxScrollFrame_OnVerticalScroll = noop
	_G.InterfaceOptions_AddCategory = noop
	_G.InterfaceOptionsFrame_OpenToCategory = noop

	-- Third-party addons are absent by design: leaving ElvUI, Masque, ShadowUF and friends nil
	-- is what a clean client looks like, and it keeps the smoke test on the built-in path.

	-- Everything above belongs to the mocked client, so anything created from here on was
	-- created by the addon under test.
	M.BaselineFrameCount = #M.Frames
	M.Hooks = {}
end

---How many frames the addon created, as opposed to the ones the mock ships with.
function M.AddonFrameCount()
	return math.max(0, #M.Frames - M.BaselineFrameCount)
end

---The slash command handlers the addon registered.
function M.SlashCommands()
	local names = {}

	for name in pairs(_G.SlashCmdList or {}) do
		names[#names + 1] = name
	end

	table.sort(names)

	return names
end

return M

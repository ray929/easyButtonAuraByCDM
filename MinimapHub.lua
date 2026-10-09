-- MinimapHub.lua
-- Easy 系列共享小地图按钮
--
-- 设计：三个带配置界面的插件（easyButtonAuraByUnit / easyButtonAuraByCDM /
-- easyCooldownGlow）共用一个小地图按钮。本文件在每个插件里各放一份实现：
-- 谁先加载谁负责创建（挂在全局命名空间 EasyMinimapHub），后加载的只往里
-- 注册自己的名字、图标与「打开配置窗口」回调。
-- 交互：左键点按钮弹出菜单（每个已注册插件一项，点菜单项打开对应配置窗口）；
-- 右键拖动按钮绕小地图边缘移动；悬停显示提示。
-- 稳定性考量：
--   · 不依赖 LibDBIcon / LibDataBroker / UIDropDownMenu，只用最基础的
--     Frame/Texture/Button 与 GameTooltip，客户端大版本更迭时受影响面最小。
--   · 位置存三插件共享的角色级存档 EasyMinimapHubDB（三个 TOC 都声明，
--     谁先加载谁读到），不依赖任何单一插件的存档存活。

local ADDON_NAME = ...

-- =========================================================
-- 共享命名空间：第一个加载的插件负责创建按钮与菜单
-- =========================================================
local HUB = _G.EasyMinimapHub
local IS_CREATOR = false
if not HUB then
    HUB = { addons = {} }
    _G.EasyMinimapHub = HUB
    IS_CREATOR = true
end

-- 三语文案（仅创建者用到，但三份拷贝都带全，保证逻辑一致）
local L = (function()
    local loc = GetLocale()
    if loc == "zhCN" then
        return {
            TITLE     = "Easy 系列插件",
            HINT_MENU = "左键：打开插件菜单",
            HINT_MOVE = "右键拖动：移动按钮",
        }
    elseif loc == "zhTW" then
        return {
            TITLE     = "Easy 系列插件",
            HINT_MENU = "左鍵：開啟插件選單",
            HINT_MOVE = "右鍵拖動：移動按鈕",
        }
    else
        return {
            TITLE     = "Easy Add-ons",
            HINT_MENU = "Left-click: plugin menu",
            HINT_MOVE = "Right-drag: move button",
        }
    end
end)()

if IS_CREATOR then
    local db = EasyMinimapHubDB
    if type(db) ~= "table" then
        db = {}
        EasyMinimapHubDB = db
    end
    db.angle = db.angle or 220

    local RADIUS = 80
    local ITEM_H = 22
    local PAD    = 6

    -- ---------- 按钮本体（经典小地图按钮三层纹理结构） ----------
    local btn = CreateFrame("Button", "EasyMinimapButton", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetSize(31, 31)
    btn:RegisterForClicks("AnyUp")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", 1, -1)
    icon:SetMask("Interface\\Minimap\\MinimapMask")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetSize(54, 54)
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetPoint("TOPLEFT")
    highlight:SetBlendMode("ADD")

    -- 按钮图标：取第一个注册进来的插件图标（见 HUB.SetIcon，只设一次）
    local iconSet = false
    function HUB.SetIcon(tex)
        if tex and not iconSet then
            icon:SetTexture(tex)
            iconSet = true
        end
    end

    local function UpdatePosition()
        local a = math.rad(db.angle)
        btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * RADIUS, math.sin(a) * RADIUS)
    end

    -- ---------- 右键拖动（绕小地图边缘，实时按光标方位角定位） ----------
    local dragging = false
    btn:SetScript("OnUpdate", function()
        if not dragging then return end
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local s = Minimap:GetEffectiveScale()
        px, py = px / s, py / s
        local dx, dy = px - mx, py - my
        if dx ~= 0 or dy ~= 0 then
            db.angle = math.deg(math.atan2(dy, dx))
            UpdatePosition()
        end
    end)
    btn:SetScript("OnMouseDown", function(_, mouse)
        if mouse == "RightButton" then dragging = true end
    end)
    btn:SetScript("OnMouseUp", function(_, mouse)
        if mouse == "RightButton" then dragging = false end
    end)

    -- ---------- 自绘菜单（不依赖 UIDropDownMenu，条目=已注册插件） ----------
    local menu = CreateFrame("Frame", "EasyMinimapMenu", UIParent, "BackdropTemplate")
    menu:SetFrameStrata("DIALOG")
    menu:SetClampedToScreen(true)
    menu:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    menu:SetBackdropColor(0, 0, 0, 0.9)
    menu:SetBackdropBorderColor(0.4, 0.4, 0.4)
    menu:Hide()

    -- 遮罩层：菜单打开时盖住全屏，点击任意处关闭菜单
    local cloak = CreateFrame("Frame", "EasyMinimapMenuCloak", UIParent)
    cloak:SetFrameStrata("HIGH") -- 低于菜单的 DIALOG、高于按钮的 MEDIUM
    cloak:SetAllPoints(UIParent)
    cloak:EnableMouse(true)
    cloak:Hide()

    local pool = {}
    local function GetItem(idx)
        local item = pool[idx]
        if not item then
            item = CreateFrame("Button", nil, menu)
            item:SetSize(194, ITEM_H)
            item:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            local ic = item:CreateTexture(nil, "ARTWORK")
            ic:SetSize(16, 16)
            ic:SetPoint("LEFT", 8, 0)
            local tx = item:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            tx:SetPoint("LEFT", ic, "RIGHT", 6, 0)
            item.icon, item.text = ic, tx
            pool[idx] = item
        end
        item:ClearAllPoints()
        item:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -(PAD + (idx - 1) * ITEM_H) - 2)
        item:Show()
        return item
    end

    local function CloseMenu()
        cloak:Hide()
        menu:Hide()
    end

    local function OpenMenu()
        local n = #HUB.addons
        if n == 0 then return end
        for i, a in ipairs(HUB.addons) do
            local item = GetItem(i)
            item.icon:SetTexture(a.icon)
            item.text:SetText(a.title)
            item:SetScript("OnClick", function()
                CloseMenu()
                if a.toggle then a.toggle() end
            end)
        end
        for i = n + 1, #pool do
            pool[i]:Hide()
        end
        -- 宽度按最长菜单项实测自适应，避免长标题溢出边框
        local textW = 0
        for i = 1, n do
            local w = pool[i].text:GetStringWidth()
            if w > textW then textW = w end
        end
        local menuW = 8 + 16 + 6 + math.ceil(textW) + 12 -- 左缘距 + 图标 + 图文间距 + 右缘距
        for i = 1, n do
            pool[i]:SetSize(menuW - 16, ITEM_H)
        end
        menu:SetSize(menuW, PAD * 2 + n * ITEM_H)
        -- 固定弹出在按钮左侧：锚点用菜单右缘对齐按钮左缘（用户指定，不做方位翻转）
        menu:ClearAllPoints()
        menu:SetPoint("TOPRIGHT", btn, "TOPLEFT", -6, 4)
        cloak:Show()
        menu:Show()
    end

    cloak:SetScript("OnMouseDown", CloseMenu)

    btn:SetScript("OnClick", function(_, mouse)
        if mouse == "LeftButton" then
            if menu:IsShown() then CloseMenu() else OpenMenu() end
        end
    end)

    -- ---------- 悬停提示 ----------
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText(L.TITLE, 1, 0.82, 0.46)
        GameTooltip:AddLine(L.HINT_MENU, 0.8, 0.8, 0.8)
        GameTooltip:AddLine(L.HINT_MOVE, 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    UpdatePosition()
end -- IS_CREATOR

-- =========================================================
-- 注册接口：后加载的插件调用即可挂进菜单
--   HUB.Register(name, title, icon, toggle)
-- =========================================================
function HUB.Register(name, title, icon, toggle)
    for _, a in ipairs(HUB.addons) do
        if a.name == name then return end -- 防重复注册
    end
    HUB.addons[#HUB.addons + 1] = { name = name, title = title, icon = icon, toggle = toggle }
    if HUB.SetIcon then HUB.SetIcon(icon) end
end

-- =========================================================
-- 本插件注册进共享按钮（此块在每个插件拷贝里各不相同）
-- 菜单项显示 TOC 的英文插件名，不做本地化（该场景无本地化命名需求）
-- =========================================================
HUB.Register(ADDON_NAME, "Easy Button Aura by CDM", "Interface\\AddOns\\easyButtonAuraByCDM\\Icon.tga", function()
    if EasyButtonAuraByCDM and EasyButtonAuraByCDM.ToggleConfigFrame then
        EasyButtonAuraByCDM.ToggleConfigFrame()
    end
end)

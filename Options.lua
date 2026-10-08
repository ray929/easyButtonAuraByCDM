-- Options.lua
-- Easy Button Aura by CDM — 设置界面
--
-- 单一设置页，集成进暴雪自带的插件设置（ESC → 选项 → 插件 → 本插件）。
--   · 无 slash 命令；战斗中禁止修改（控件禁用 + 顶部红色提示）。
--   · 每行 = CDM 里一个「已启用」的增益：可把它绑定到某个动作条技能，
--     并分别设置剩余时间 / 层数的位置，以及发光 / 反发光。
--   · 修改即时落盘（canvas layout 的 OnCommit 为空实现）。
--
-- 依赖 easyButtonAuraByCDM.lua 暴露的接口：knownBuffs / GetBindings / GetBinding /
-- SetBoundSpell / SetBindingOption / ParseSpellInput / GetSpellDisplayName /
-- GetCurrentSpecName / BuildSpellButtonMap / POS_KEYS / PosLabel / L / IsSecret。

local B = EasyButtonAuraByCDM
local L = B.L

local PANEL_W  = 620
local ROW_W    = PANEL_W - 16
local ROW_H    = 46
local HEADER_H = 112

local panel
local rows = {}          -- 行池（复用）
local refreshing = false -- RefreshPanel 递归守卫

-- 插件名（用于设置分类标题）
local function GetAddonTitle()
    local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if fn then
        local ok, title = pcall(fn, B.ADDON_NAME, "Title")
        if ok and title and title ~= "" then return title end
    end
    return "Easy Button Aura by CDM"
end
local ADDON_TITLE = GetAddonTitle()

-- =========================================================
-- 小工具
-- =========================================================
-- 保留模板原有的 OnEnter / OnLeave（高亮等），只在其后追加 tooltip
local function AddTip(widget, text)
    local prevEnter = widget:GetScript("OnEnter")
    local prevLeave = widget:GetScript("OnLeave")
    widget:SetScript("OnEnter", function(self, ...)
        if prevEnter then prevEnter(self, ...) end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function(self, ...)
        if prevLeave then prevLeave(self, ...) end
        GameTooltip:Hide()
    end)
end

-- 战斗中禁用全部可编辑控件 + 显示红色提示
local function UpdateCombatState()
    local locked = B._inCombat and true or false
    if panel and panel.combatWarning then
        panel.combatWarning:SetShown(locked)
    end
    for _, row in ipairs(rows) do
        row.edit:SetEnabled(not locked)
        row.selfBtn:SetEnabled(not locked)
        row.timeBtn:SetEnabled(not locked)
        row.stackBtn:SetEnabled(not locked)
        row.glowCheck:SetEnabled(not locked)
        row.inverseCheck:SetEnabled(not locked)
        if locked and row.edit:HasFocus() then row.edit:ClearFocus() end
    end
end

-- 提交「绑定」输入框：名 / ID 皆可；空 = 解绑；无法解析 = 还原并提示
local function CommitEdit(row)
    if row._committing then return end
    local spellID = row.spellID
    if not spellID then return end
    row._committing = true

    local cfg = B.GetBinding(spellID)
    local prev = cfg and cfg.bindSpell
    local text = strtrim(row.edit:GetText() or "")

    if text == "" then
        if prev then B.SetBoundSpell(spellID, nil) end
        row.edit:SetText("")
    else
        local target = B.ParseSpellInput(text)
        if target then
            if target ~= prev then B.SetBoundSpell(spellID, target) end
            row.edit:SetText(B.GetSpellDisplayName(target))
        else
            row.status:SetText(L("ERR_INVALID"))
            row.status:SetTextColor(1, 0.35, 0.35)
            row.edit:SetText(prev and B.GetSpellDisplayName(prev) or "")
        end
    end

    row.edit:ClearFocus()   -- 焦点丢失回调会因 _committing=true 直接返回
    row._committing = false
end

-- 循环切换 时间 / 层数 的位置
local function CyclePos(row, key)
    local spellID = row.spellID
    if not spellID then return end
    local cfg = B.GetBinding(spellID)
    local cur = (cfg and cfg[key]) or "default"
    local idx = 1
    for i = 1, #B.POS_KEYS do
        if B.POS_KEYS[i] == cur then idx = i break end
    end
    local nxt = B.POS_KEYS[(idx % #B.POS_KEYS) + 1]
    B.SetBindingOption(spellID, key, nxt)
end

-- =========================================================
-- 行控件
-- =========================================================
local function CreateRow(index)
    local row = CreateFrame("Frame", nil, panel.rows)
    row:SetSize(ROW_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("TOPLEFT", 4, -6)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.status:SetPoint("LEFT", row.name, "RIGHT", 10, 0)

    row.bindLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.bindLabel:SetPoint("BOTTOMLEFT", 4, 14)
    row.bindLabel:SetText(L("COL_BIND"))

    row.edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    row.edit:SetSize(100, 20)
    row.edit:SetPoint("LEFT", row.bindLabel, "RIGHT", 6, 0)
    row.edit:SetAutoFocus(false)
    row.edit:SetMaxLetters(60)
    row.edit:SetScript("OnEnterPressed", function() CommitEdit(row) end)
    row.edit:SetScript("OnEditFocusLost", function() CommitEdit(row) end)
    row.edit:SetScript("OnEscapePressed", function()
        row._committing = true
        local cfg = B.GetBinding(row.spellID)
        row.edit:SetText(cfg and cfg.bindSpell and B.GetSpellDisplayName(cfg.bindSpell) or "")
        row.edit:ClearFocus()
        row._committing = false
    end)

    row.selfBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.selfBtn:SetSize(40, 20)
    row.selfBtn:SetPoint("LEFT", row.edit, "RIGHT", 4, 0)
    row.selfBtn:SetText(L("BTN_SELF"))
    AddTip(row.selfBtn, L("BTN_SELF_TIP"))
    row.selfBtn:SetScript("OnClick", function()
        if B._inCombat then return end
        if row.spellID then B.SetBoundSpell(row.spellID, row.spellID) end
    end)

    row.timeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.timeBtn:SetSize(104, 20)
    row.timeBtn:SetPoint("LEFT", row.selfBtn, "RIGHT", 10, 0)
    row.timeBtn:SetScript("OnClick", function()
        if B._inCombat then return end
        CyclePos(row, "timePos")
    end)

    row.stackBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.stackBtn:SetSize(116, 20)
    row.stackBtn:SetPoint("LEFT", row.timeBtn, "RIGHT", 8, 0)
    row.stackBtn:SetScript("OnClick", function()
        if B._inCombat then return end
        CyclePos(row, "stackPos")
    end)

    row.glowCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.glowCheck:SetSize(24, 24)
    row.glowCheck:SetPoint("LEFT", row.stackBtn, "RIGHT", 14, 0)
    row.glowLabel = row.glowCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.glowLabel:SetPoint("LEFT", row.glowCheck, "RIGHT", 2, 0)
    row.glowLabel:SetText(L("GLOW"))
    AddTip(row.glowCheck, L("GLOW_TIP"))
    row.glowCheck:SetScript("OnClick", function(self)
        if B._inCombat then
            self:SetChecked(not self:GetChecked())
            return
        end
        if row.spellID then
            B.SetBindingOption(row.spellID, "glow", self:GetChecked() and true or false)
        end
    end)

    row.inverseCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.inverseCheck:SetSize(24, 24)
    row.inverseCheck:SetPoint("LEFT", row.glowLabel, "RIGHT", 14, 0)
    row.inverseLabel = row.inverseCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.inverseLabel:SetPoint("LEFT", row.inverseCheck, "RIGHT", 2, 0)
    row.inverseLabel:SetText(L("INVERSE"))
    AddTip(row.inverseCheck, L("INVERSE_TIP"))
    row.inverseCheck:SetScript("OnClick", function(self)
        if B._inCombat then
            self:SetChecked(not self:GetChecked())
            return
        end
        if row.spellID then
            B.SetBindingOption(row.spellID, "inverseGlow", self:GetChecked() and true or false)
        end
    end)

    return row
end

local function UpdateRow(row, spellID, buttonMap)
    local buff = B.knownBuffs and B.knownBuffs[spellID]
    row.name:SetText(buff and buff.name or B.GetSpellDisplayName(spellID))
    row.icon:SetTexture((buff and buff.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")

    local cfg = B.GetBinding(spellID)
    local bound = cfg and cfg.bindSpell

    if not row.edit:HasFocus() then
        row.edit:SetText(bound and B.GetSpellDisplayName(bound) or "")
    end

    if bound and not buttonMap[bound] then
        row.status:SetText(L("STATUS_NOT_ON_BAR"))
        row.status:SetTextColor(1, 0.4, 0.4)
    else
        row.status:SetText("")
    end

    row.timeBtn:SetText(L("TIME_FMT"):format(B.PosLabel((cfg and cfg.timePos) or "default")))
    row.stackBtn:SetText(L("STACK_FMT"):format(B.PosLabel((cfg and cfg.stackPos) or "default")))
    row.glowCheck:SetChecked(cfg and cfg.glow == true or false)
    row.inverseCheck:SetChecked(cfg and cfg.inverseGlow == true or false)
end

-- =========================================================
-- 面板刷新
-- =========================================================
-- 行集合 = CDM 已启用增益 ∪ 已有绑定（后者保证解绑前的旧光环仍可管理），按名称排序
local function BuildRowList()
    local seen, list = {}, {}
    local function add(id)
        if id and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    for id in pairs(B.knownBuffs or {}) do add(id) end
    for id in pairs(B.GetBindings()) do add(id) end
    table.sort(list, function(a, b)
        return B.GetSpellDisplayName(a) < B.GetSpellDisplayName(b)
    end)
    return list
end

function B.RefreshPanel()
    if not panel or refreshing then return end
    refreshing = true

    B._inCombat = InCombatLockdown() and true or false

    panel.specText:SetText(L("SPEC_LABEL") .. ": " .. B.GetCurrentSpecName())

    local list = BuildRowList()
    local buttonMap = B.BuildSpellButtonMap()

    for i = 1, #list do
        local spellID = list[i]
        local row = rows[i]
        if not row then
            row = CreateRow(i)
            rows[i] = row
        end
        row.spellID = spellID
        row:Show()
        UpdateRow(row, spellID, buttonMap)
    end
    for i = #list + 1, #rows do
        rows[i].spellID = nil
        rows[i]:Hide()
    end

    panel.noAuras:SetShown(#list == 0)
    panel.rows:SetSize(ROW_W, math.max(#list, 1) * ROW_H)
    panel:SetSize(PANEL_W, HEADER_H + math.max(#list, 1) * ROW_H + 16)

    UpdateCombatState()
    refreshing = false
end

-- =========================================================
-- 面板构建 + 注册进暴雪设置
-- =========================================================
local function BuildPanel()
    panel = CreateFrame("Frame")
    panel:SetSize(PANEL_W, HEADER_H + ROW_H + 16)

    -- canvas layout 要求的三函数：修改即时生效，故均为空 / 仅刷新
    panel.OnCommit  = function() end
    panel.OnDefault = function() end
    panel.OnRefresh = function() if B.RefreshPanel then B.RefreshPanel() end end

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("TOPLEFT", 16, -12)
    panel.title:SetText(ADDON_TITLE)

    panel.specText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.specText:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)

    panel.desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.desc:SetPoint("TOPLEFT", panel.specText, "BOTTOMLEFT", 0, -8)
    panel.desc:SetWidth(PANEL_W - 32)
    panel.desc:SetJustifyH("LEFT")
    panel.desc:SetText(L("PAGE_DESC"))

    panel.combatWarning = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.combatWarning:SetPoint("TOPLEFT", panel.desc, "BOTTOMLEFT", 0, -8)
    panel.combatWarning:SetTextColor(1, 0.3, 0.3)
    panel.combatWarning:SetText(L("COMBAT_LOCKED"))
    panel.combatWarning:Hide()

    panel.rows = CreateFrame("Frame", nil, panel)
    panel.rows:SetPoint("TOPLEFT", 8, -HEADER_H)
    panel.rows:SetSize(ROW_W, ROW_H)

    panel.noAuras = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.noAuras:SetPoint("TOPLEFT", 16, -(HEADER_H + 4))
    panel.noAuras:SetWidth(PANEL_W - 32)
    panel.noAuras:SetJustifyH("LEFT")
    panel.noAuras:SetText(L("NO_AURAS"))
    panel.noAuras:Hide()

    -- 设置页显隐：驱动主文件的低频签名巡检（面板打开时保持 CDM 列表最新）
    panel:SetScript("OnShow", function()
        B.panelShown = true
        if B.Rescan then
            B.Rescan()
        elseif B.RefreshPanel then
            B.RefreshPanel()
        end
    end)
    panel:SetScript("OnHide", function()
        B.panelShown = false
    end)
end

local function RegisterSettings()
    if panel then return end
    if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    BuildPanel()
    local category = Settings.RegisterCanvasLayoutCategory(panel, ADDON_TITLE)
    Settings.RegisterAddOnCategory(category)
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event)
    self:UnregisterEvent(event)
    RegisterSettings()
    if B.RefreshPanel then B.RefreshPanel() end
end)

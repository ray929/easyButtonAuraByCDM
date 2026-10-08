-- Options.lua
-- Easy Button Aura by CDM — 设置界面
--
-- 单一设置页，集成进暴雪自带的插件设置（ESC → 选项 → 插件 → 本插件）。
--   · 无 slash 命令；战斗中禁止修改（控件禁用 + 顶部红色提示）。
--   · 每行 = CDM 里一个「已启用」的光环：可把它绑定到某个动作条技能，
--     并分别设置剩余时间 / 层数的位置，以及发光 / 反发光。
--   · 修改即时落盘（canvas layout 的 OnCommit 为空实现）。
--
-- 布局约定：所有控件的坐标都是【相对 row 的绝对坐标】，不互相链式锚定，
-- 保证行与行、控件与控件严格对齐且不重叠（链式锚定曾被反馈「错位」）。

local B = EasyButtonAuraByCDM
local L = B.L

-- 面板宽度：设置 canvas 可视宽度有限，过宽会把右侧控件裁掉
local PANEL_W = 520
local ROW_W   = PANEL_W - 16
local ROW_H   = 56

-- 行内第二行控件的横坐标（相对 row 左侧）与宽度
local X_EDIT,    W_EDIT    = 44, 108
local X_TIME,    W_TIME    = 160, 86
local X_STACK,   W_STACK   = 254, 94
local X_GLOW,    X_INVERSE = 358, 426

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
        row.timeDd:SetEnabled(not locked)
        row.stackDd:SetEnabled(not locked)
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

-- 时间 / 层数位置：下拉菜单（默认 / 上 / 下 / 左 / 右 / 无）
local function CurPos(spellID, key)
    local cfg = B.GetBinding(spellID)
    return (cfg and cfg[key]) or "default"
end

-- 下拉按钮的显示文字（不同版本方法名可能有差异，优先 SetText）
local function SetDdText(dd, text)
    if dd.SetText then
        dd:SetText(text)
    elseif dd.SetDefaultText then
        dd:SetDefaultText(text)
    end
end

-- 给下拉按钮装配位置菜单；dd._spellID 由 UpdateRow 写入
local function SetupPosMenu(dd, key)
    dd:SetupMenu(function(_, rootDescription)
        for _, posKey in ipairs(B.POS_KEYS) do
            rootDescription:CreateRadio(B.PosLabel(posKey), function()
                return CurPos(dd._spellID, key) == posKey
            end, function()
                if B._inCombat or not dd._spellID then return end
                B.SetBindingOption(dd._spellID, key, posKey)
            end)
        end
    end)
end

-- =========================================================
-- 行控件
-- =========================================================
local function CreateRow(index)
    local row = CreateFrame("Frame", nil, panel.rows)
    row:SetSize(ROW_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_H)

    -- 第一行：图标 + 光环名 + 状态提示
    -- 图标做成可悬停按钮：鼠标移上显示与 CDM 高级设置里一致的技能 / 光环提示
    row.icon = CreateFrame("Button", nil, row)
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("TOPLEFT", 6, -4)
    row.icon.tex = row.icon:CreateTexture(nil, "ARTWORK")
    row.icon.tex:SetAllPoints()
    row.icon:SetScript("OnEnter", function(self)
        local id = self.spellID
        if not id then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(id)
        else
            GameTooltip:SetText(B.GetSpellDisplayName(id))
        end
        GameTooltip:Show()
    end)
    row.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.status:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
    row.status:SetJustifyH("LEFT")

    -- 第二行：绑定输入框 / 时间 / 层数 / 发光 / 反发光
    -- 统一底边（按钮 y=6、勾选框 y=4），中心线一致 → 视觉对齐
    row.edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    row.edit:SetSize(W_EDIT, 20)
    row.edit:SetPoint("BOTTOMLEFT", X_EDIT, 6)
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

    row.bindLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.bindLabel:SetPoint("RIGHT", row.edit, "LEFT", -6, 0)
    row.bindLabel:SetText(L("COL_BIND"))

    -- 时间 / 层数：下拉菜单（底边与勾选框一致，中心线对齐）
    row.timeDd = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
    row.timeDd:SetSize(W_TIME, 24)
    row.timeDd:SetPoint("BOTTOMLEFT", X_TIME, 4)
    SetupPosMenu(row.timeDd, "timePos")
    AddTip(row.timeDd, L("COL_TIME"))

    row.stackDd = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
    row.stackDd:SetSize(W_STACK, 24)
    row.stackDd:SetPoint("BOTTOMLEFT", X_STACK, 4)
    SetupPosMenu(row.stackDd, "stackPos")
    AddTip(row.stackDd, L("COL_STACK"))

    row.glowCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.glowCheck:SetSize(24, 24)
    row.glowCheck:SetPoint("BOTTOMLEFT", X_GLOW, 4)
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
    row.inverseCheck:SetPoint("BOTTOMLEFT", X_INVERSE, 4)
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
    row.icon.spellID = spellID
    row.icon.tex:SetTexture((buff and buff.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")

    local cfg = B.GetBinding(spellID)
    local bound = cfg and cfg.bindSpell

    -- 绑定框显示当前绑定的技能名。
    -- ⚠️ 必须「先清空再写入」：EditBox:SetText 在文本未变时被客户端短路为 no-op，
    --    而初次 SetText 发生在设置面板尚隐藏时（字体度量未就绪），内部水平滚动偏移会算错，
    --    文字被滚到框外看不见（鼠标拖动选择才显现）。先清空强制其按当前尺寸重算偏移。
    if not row.edit:HasFocus() then
        local text = bound and B.GetSpellDisplayName(bound) or ""
        row.edit:SetText("")
        row.edit:SetText(text)
    end

    if bound and not buttonMap[bound] then
        row.status:SetText(L("STATUS_NOT_ON_BAR"))
        row.status:SetTextColor(1, 0.4, 0.4)
    else
        row.status:SetText("")
    end

    row.timeDd._spellID = spellID
    row.stackDd._spellID = spellID
    SetDdText(row.timeDd, B.PosLabel((cfg and cfg.timePos) or "default"))
    SetDdText(row.stackDd, B.PosLabel((cfg and cfg.stackPos) or "default"))
    row.glowCheck:SetChecked(cfg and cfg.glow == true or false)
    row.inverseCheck:SetChecked(cfg and cfg.inverseGlow == true or false)
end

-- =========================================================
-- 面板刷新
-- =========================================================
-- 行集合 = 当前仍在 CDM 中【已启用】的光环，按名称排序。
-- 不并入「已有绑定」：光环一旦从 CDM 移除，本行即消失（绑定仍留在存档里，
-- 日后在 CDM 重新启用该光环时自动恢复并重新显示，不会丢配置）。
local function BuildRowList()
    local list = {}
    for id in pairs(B.knownBuffs or {}) do list[#list + 1] = id end
    table.sort(list, function(a, b)
        return B.GetSpellDisplayName(a) < B.GetSpellDisplayName(b)
    end)
    return list
end

local function DoRefresh()
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
        rows[i].icon.spellID = nil
        rows[i]:Hide()
    end

    local count = math.max(#list, 1)
    panel.noAuras:SetShown(#list == 0)
    panel.rows:SetSize(ROW_W, count * ROW_H)

    -- 面板高度 = 头部（面板顶 → 行区域顶） + 行区域 + 底部留白。
    -- 头部高度取运行时实际几何（描述行数会随语言变化，不能用常量）；几何不可用时用兜底值。
    local pTop, rTop = panel:GetTop(), panel.rows:GetTop()
    local headerH = (pTop and rTop and pTop > rTop) and (pTop - rTop) or 120
    panel:SetSize(PANEL_W, headerH + count * ROW_H + 16)

    UpdateCombatState()
    return list
end

-- ⚠️ refreshing 守卫必须无条件复位：刷新中途一旦抛错，若不复位，之后所有刷新都会被守卫挡掉
--    → 面板从此不再更新（表现为「配置像是丢了」）。
function B.RefreshPanel()
    if not panel or refreshing then return end
    refreshing = true
    pcall(DoRefresh)
    refreshing = false
end

-- =========================================================
-- 面板构建 + 注册进暴雪设置
-- =========================================================
local function BuildPanel()
    panel = CreateFrame("Frame")
    panel:SetSize(PANEL_W, 200)

    -- canvas layout 要求的三函数：修改即时生效，故均为空 / 仅刷新
    panel.OnCommit  = function() end
    panel.OnDefault = function() end
    panel.OnRefresh = function() if B.RefreshPanel then B.RefreshPanel() end end

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("TOPLEFT", 16, -12)
    panel.title:SetText(ADDON_TITLE)

    panel.specText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.specText:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)

    panel.combatWarning = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.combatWarning:SetPoint("TOPLEFT", panel.specText, "BOTTOMLEFT", 0, -6)
    panel.combatWarning:SetTextColor(1, 0.3, 0.3)
    panel.combatWarning:SetText(L("COMBAT_LOCKED"))
    panel.combatWarning:Hide()

    panel.desc = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.desc:SetPoint("TOPLEFT", panel.combatWarning, "BOTTOMLEFT", 0, -8)
    panel.desc:SetWidth(PANEL_W - 32)
    panel.desc:SetJustifyH("LEFT")
    panel.desc:SetText(L("PAGE_DESC"))

    panel.noAuras = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.noAuras:SetPoint("TOPLEFT", panel.desc, "BOTTOMLEFT", 0, -14)
    panel.noAuras:SetWidth(PANEL_W - 32)
    panel.noAuras:SetJustifyH("LEFT")
    panel.noAuras:SetText(L("NO_AURAS"))
    panel.noAuras:Hide()

    panel.rows = CreateFrame("Frame", nil, panel)
    panel.rows:SetPoint("TOPLEFT", panel.desc, "BOTTOMLEFT", 8, -14)
    panel.rows:SetSize(ROW_W, ROW_H)

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

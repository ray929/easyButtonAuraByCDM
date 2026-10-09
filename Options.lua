-- Options.lua
-- Easy Button Aura by CDM — 设置界面
--
-- 界面分两块：
--   1. 暴雪插件设置里的【占位页】：只有一句提示 + 一个按钮，点按钮打开自有配置窗口。
--      （不再把整页控件嵌进暴雪设置，省去「ESC → 选项 → 插件 → 本插件」逐层点开。）
--   2. 【自有配置窗口】：承载全部绑定 / 位置 / 发光控件；用 /babc 或占位页按钮打开。
--
-- 战斗行为（用户指定）：战斗中配置窗口直接隐藏，战斗结束若此前是打开状态则自动恢复。
-- 战斗中不响应 /babc 与占位页按钮（窗口无法被打开）。
--
-- 布局约定：所有控件的坐标都是【相对 row 的绝对坐标】，不互相链式锚定，
-- 保证行与行、控件与控件严格对齐且不重叠（链式锚定曾被反馈「错位」）。
--
-- 列表区为【固定高度 + 滚动条】：可见 VISIBLE_ROWS 行，行数超出即出现暴雪原生滚动条
-- （支持鼠标滚轮），窗口高度不随行数增长。

local B = EasyButtonAuraByCDM
local L = B.L

-- 配置窗口宽度：过宽会超出小屏，行内控件按固定列排布。
-- 列表区用 UIPanelScrollFrameTemplate：其滚动条【默认锚在滚动区右侧外部】，
-- 会越过窗口右边界（曾反馈「滚动条超出了右边界」）。BuildConfigFrame 里已显式
-- ClearAllPoints 后把它重锚到滚动区【内部右缘】，故此处只需扣掉左右留白即可。
local PANEL_W = 680
local ROW_W   = PANEL_W - 44
local ROW_H   = 56

-- 列表区固定高度（可见行数），行数超过即出现滚动条，窗口高度不再随行数增长
local VISIBLE_ROWS = 7
local LIST_H = VISIBLE_ROWS * ROW_H

-- 行内第二行控件的横坐标（相对 row 左侧）与宽度。
-- 最右「反发光 / Missing」标签右端需与滚动区右缘留出余量：滚动条重锚后占滚动区
-- 最右约 16px，余量不足会被压住 / 裁掉（本组余量约 40px）。
local X_EDIT,    W_EDIT    = 54, 140
local X_TIME,    W_TIME    = 202, 106
local X_STACK,   W_STACK   = 316, 110
local X_GLOW,    X_INVERSE = 446, 526

-- 暴雪设置分类名 / 配置窗口标题：不本地化，固定用插件名（用户指定）
local ADDON_TITLE = "Easy Button Aura by CDM"

-- 暴雪设置里的占位页宽度：与配置窗口宽度无关，用较小值避免超出暴雪设置画布
local STUB_W = 520

local configFrame
local rows = {}          -- 行池（复用）
local refreshing = false -- RefreshPanel 递归守卫

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
    local row = CreateFrame("Frame", nil, configFrame.rows)
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
    --    而初次 SetText 发生在窗口尚隐藏时（字体度量未就绪），内部水平滚动偏移会算错，
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
    if not configFrame then return end
    B._inCombat = InCombatLockdown() and true or false

    -- 头部信息行：当前职业（数据条目按职业过滤）+ 配置专精（存档槽位）
    configFrame.specText:SetText(
        L("CLASS_LABEL") .. ": " .. (UnitClass("player"))
        .. "　　" .. L("SPEC_LABEL") .. ": " .. B.GetCurrentSpecName())
    if configFrame.enableCheck then
        configFrame.enableCheck:SetChecked(B.IsEnabled and B.IsEnabled() or false)
    end

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
    -- 空列表：隐藏滚动区（其自带底板会盖住提示文字），只显示提示
    local empty = (#list == 0)
    configFrame.noAuras:SetShown(empty)
    configFrame.scroll:SetShown(not empty)
    configFrame.rows:SetSize(ROW_W, count * ROW_H)
    -- 内容尺寸变化后让 ScrollFrame 重算滚动范围（超出即自动显示滚动条，否则隐藏）
    if configFrame.scroll.UpdateScrollChildRect then
        pcall(configFrame.scroll.UpdateScrollChildRect, configFrame.scroll)
    end

    -- 窗口高度 = 顶部（窗口顶 → 滚动区顶） + 固定列表高度 + 底部留白。
    -- 顶部高度取运行时实际几何（提示文字行数会随语言变化，不能用常量）；几何不可用时用兜底值。
    -- 列表高度固定为 LIST_H：行数再多也只出滚动条，窗口不会无限加长。
    local pTop, rTop = configFrame:GetTop(), configFrame.scroll:GetTop()
    local headerH = (pTop and rTop and pTop > rTop) and (pTop - rTop) or 130
    configFrame:SetSize(PANEL_W, headerH + LIST_H + 20)

    return list
end

-- ⚠️ refreshing 守卫必须无条件复位：刷新中途一旦抛错，若不复位，之后所有刷新都会被守卫挡掉
--    → 面板从此不再更新（表现为「配置像是丢了」）。
function B.RefreshPanel()
    if not configFrame or refreshing then return end
    refreshing = true
    pcall(DoRefresh)
    refreshing = false
end

-- =========================================================
-- 自有配置窗口
-- =========================================================
local function BuildConfigFrame()
    configFrame = CreateFrame("Frame", "EasyButtonAuraByCDMConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    configFrame:SetSize(PANEL_W, 320)
    configFrame:SetPoint("TOP", UIParent, "TOP", 0, -120)
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:SetClampedToScreen(true)
    configFrame:SetFrameStrata("DIALOG")
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:Hide()

    -- 标题（不本地化，固定插件名）
    local titleText = (configFrame.TitleContainer and configFrame.TitleContainer.TitleText) or configFrame.TitleText
    if titleText then titleText:SetText(ADDON_TITLE) end

    -- 头部分割线：在「当前专精」行（含右侧全局启用复选框，底 -58）下方，分隔头部与列表
    -- （用户澄清：分割线在总标题「当前专精…」下面，不是窗口标题栏下面）
    configFrame.divTitle = configFrame:CreateTexture(nil, "ARTWORK")
    configFrame.divTitle:SetColorTexture(0.7, 0.7, 0.7, 0.35)
    configFrame.divTitle:SetSize(PANEL_W - 24, 1)
    configFrame.divTitle:SetPoint("TOPLEFT", 12, -64)

    -- 顶部提示：当前专精（说明文字已按用户要求去掉）
    configFrame.specText = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    configFrame.specText:SetPoint("TOPLEFT", 16, -36)

    -- 启用开关（专精级：只关当前专精的显示；整体关闭请禁用插件）。
    -- 标签锚在复选框【左侧】，避免标签向右伸出窗口右边界（滚动条那次同类越界问题的经验）。
    configFrame.enableCheck = CreateFrame("CheckButton", nil, configFrame, "UICheckButtonTemplate")
    configFrame.enableCheck:SetSize(24, 24)
    configFrame.enableCheck:SetPoint("TOPRIGHT", -16, -34)
    configFrame.enableLabel = configFrame.enableCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    configFrame.enableLabel:SetPoint("RIGHT", configFrame.enableCheck, "LEFT", -4, 0)
    configFrame.enableLabel:SetText(L("ENABLE"))
    configFrame.enableCheck:SetScript("OnClick", function(self)
        if InCombatLockdown() then
            self:SetChecked(not self:GetChecked())
            return
        end
        B.SetEnabled(self:GetChecked() and true or false)
    end)
    configFrame.enableCheck:SetChecked(B.IsEnabled and B.IsEnabled() or false)

    configFrame.noAuras = configFrame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    configFrame.noAuras:SetPoint("TOPLEFT", configFrame.specText, "BOTTOMLEFT", 0, -18)
    configFrame.noAuras:SetWidth(PANEL_W - 40)
    configFrame.noAuras:SetJustifyH("LEFT")
    configFrame.noAuras:SetText(L("NO_AURAS"))
    configFrame.noAuras:Hide()

    -- 列表区：固定高度的滚动区（行数超过可见行数时出现滚动条，支持鼠标滚轮）
    configFrame.scroll = CreateFrame("ScrollFrame", "EasyButtonAuraByCDMConfigScroll", configFrame, "UIPanelScrollFrameTemplate")
    configFrame.scroll:SetPoint("TOPLEFT", configFrame.specText, "BOTTOMLEFT", 8, -26)
    configFrame.scroll:SetSize(ROW_W, LIST_H)
    configFrame.scroll:EnableMouseWheel(true)
    configFrame.scroll:SetScript("OnMouseWheel", function(self, delta)
        local bar = self.ScrollBar or _G["EasyButtonAuraByCDMConfigScrollScrollBar"]
        if not bar or not bar:IsShown() then return end
        local lo, hi = bar:GetMinMaxValues()
        local v = (bar:GetValue() or 0) - delta * ROW_H
        if v < lo then v = lo elseif v > hi then v = hi end
        bar:SetValue(v)
    end)

    configFrame.rows = CreateFrame("Frame", nil, configFrame.scroll)
    configFrame.rows:SetPoint("TOPLEFT", configFrame.scroll, "TOPLEFT", 0, 0)
    configFrame.rows:SetSize(ROW_W, LIST_H)
    configFrame.scroll:SetScrollChild(configFrame.rows)

    -- ⚠️ UIPanelScrollFrameTemplate 的滚动条【默认锚在滚动区右侧外部】（右缘约在滚动区右缘
    -- 之外 13px），会越过窗口右边界（用户反馈「滚动条超出了右边界」）。
    -- 注意模板把滚动条存在 `ScrollBar` 字段（大写 S）、全局名 <帧名>.."ScrollBar"。
    -- 这里显式 ClearAllPoints，再把滚动条【右缘】贴到滚动区【内部右缘】（内缩 2px），
    -- 这样无论滚动条多宽都完整落在滚动区（进而窗口）内。
    local bar = configFrame.scroll.ScrollBar or _G["EasyButtonAuraByCDMConfigScrollScrollBar"]
    if bar then
        bar:ClearAllPoints()
        bar:SetPoint("TOPRIGHT", configFrame.scroll, "TOPRIGHT", -2, -14)
        bar:SetPoint("BOTTOMRIGHT", configFrame.scroll, "BOTTOMRIGHT", -2, 14)
    end

    -- 窗口显隐：驱动主文件的低频签名巡检（窗口打开时保持 CDM 列表最新）
    configFrame:SetScript("OnShow", function()
        B.panelShown = true
        if B.Rescan then
            B.Rescan()
        else
            B.RefreshPanel()
        end
    end)
    configFrame:SetScript("OnHide", function()
        B.panelShown = false
    end)
end

-- 打开配置窗口（战斗中不允许打开）
function B.ShowConfigFrame()
    if InCombatLockdown() then return end
    if not configFrame then BuildConfigFrame() end
    -- Easy 系配置窗口互斥：收起其他插件的配置窗口（经共享 MinimapHub 协调）
    if EasyMinimapHub and EasyMinimapHub.NotifyConfigFrameShown then
        EasyMinimapHub.NotifyConfigFrameShown(configFrame)
    end
    configFrame:Show()
end

-- /babc 与占位页按钮：切换配置窗口显隐（战斗中不响应）
function B.ToggleConfigFrame()
    if InCombatLockdown() then return end
    if not configFrame then BuildConfigFrame() end
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        -- Easy 系配置窗口互斥：收起其他插件的配置窗口（经共享 MinimapHub 协调）
    if EasyMinimapHub and EasyMinimapHub.NotifyConfigFrameShown then
        EasyMinimapHub.NotifyConfigFrameShown(configFrame)
    end
    configFrame:Show()
    end
end

-- 战斗状态切换（主文件 PLAYER_REGEN_DISABLED / ENABLED 调用）：
-- 战斗中直接隐藏配置窗口并记住；战斗结束若此前是打开状态则恢复。
function B.OnCombatChanged(inCombat)
    B._inCombat = inCombat and true or false
    if not configFrame then return end
    if inCombat then
        if configFrame:IsShown() then
            B._restoreConfig = true
            configFrame:Hide()
        end
    elseif B._restoreConfig then
        B._restoreConfig = nil
        B.ShowConfigFrame()
    end
end

-- =========================================================
-- 暴雪插件设置里的占位页（提示 + 按钮）
-- =========================================================
local function BuildBlizzardStub()
    local stub = CreateFrame("Frame")
    stub:SetSize(STUB_W, 200)

    -- canvas layout 要求的三函数：本页无实际设置，故均为空实现
    stub.OnCommit  = function() end
    stub.OnDefault = function() end
    stub.OnRefresh = function() end

    -- 页面顶部标题（英文插件名，Chattynator 风格）：左侧分类树有名字，页内自身也要有
    local title = stub:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", stub, "TOP", 0, -18)
    -- 金色大字（与插件图标同色系，#E8BC75 直方图采样主峰）
    title:SetFont(STANDARD_TEXT_FONT, 22, "")
    title:SetTextColor(0.910, 0.737, 0.459)
    title:SetText(ADDON_TITLE)

    local hint = stub:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hint:SetPoint("TOP", stub, "TOP", 0, -64)
    hint:SetWidth(STUB_W - 40)
    hint:SetJustifyH("CENTER")
    hint:SetText(L("STUB_HINT"))

    local template = "SharedButtonLargeTemplate"
    local hasTemplate = false
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        local ok, info = pcall(C_XMLUtil.GetTemplateInfo, template)
        hasTemplate = ok and info ~= nil
    end
    if not hasTemplate then template = "UIPanelDynamicResizeButtonTemplate" end
    local button = CreateFrame("Button", nil, stub, template)
    button:SetText(L("OPEN_OPTIONS"))
    button.padding = 40
    if DynamicResizeButton_Resize then pcall(DynamicResizeButton_Resize, button) end
    button:SetPoint("TOP", hint, "BOTTOM", 0, -30)
    button:SetScript("OnClick", function() B.ToggleConfigFrame() end)

    return stub
end

local function RegisterSettings()
    if B._stubRegistered then return end
    if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    B._stubRegistered = true
    local stub = BuildBlizzardStub()
    -- 分类名不本地化，固定用插件名（用户指定）
    local category = Settings.RegisterCanvasLayoutCategory(stub, ADDON_TITLE)
    Settings.RegisterAddOnCategory(category)
end

-- =========================================================
-- slash 命令：/babc 打开自有配置窗口
-- =========================================================
SLASH_EASYBUTTONAURABYCDM1 = "/babc"
SlashCmdList["EASYBUTTONAURABYCDM"] = function()
    B.ToggleConfigFrame()
end

-- =========================================================
-- 启动
-- =========================================================
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event)
    self:UnregisterEvent(event)
    RegisterSettings()
    BuildConfigFrame()
    B.RefreshPanel()
end)

-- AuraDisplay.lua
-- Easy Button Aura by CDM — 渲染层
--
-- 对每个「已绑定」的 CDM 增益，在目标动作条按钮上显示该光环的剩余时间与层数。
--
-- 实现要点：
--   · 倒计时 / 层数由暴雪 12.1 的 AuraContainer（自建容器 + includeSpellIDs 精确过滤）
--     特权渲染并驱动：addon 只注册子控件（Cooldown / FontString）与摆放位置，
--     不读任何光环数值 → 战斗中照常显示、零 secret 读取。
--   · CDM 的原有显示完全不动（既不隐藏也不移动），只按 spellID 读取
--     CDM item 的明文 IsActive() 作为「光环是否激活」的信号，驱动发光 / 反发光。
--   · 数字容器只挂 UIParent，用按钮的屏幕坐标（GetRect）定位，绝不把坐标锚到安全动作按钮上
--     （否则 taint 传播 → 进战斗整片消失）；发光改由内嵌 LibCustomGlow-1.0 的 Proc Glow 挂在按钮上。
--   · 战斗中绝不重建 / 销毁容器（新建只在脱战后进行），战斗中只做定位与发光更新。

local B = EasyButtonAuraByCDM
local S = B.Style

local DOCK_X, DOCK_Y = -10000, -10000

-- spellID -> entry
local entries = {}

-- 安全读取普通布尔（secret / nil / 非 boolean → nil = 无法判定）
local function ReadBool(v)
    if v == nil then return nil end
    if B.IsSecret(v) then return nil end
    if type(v) ~= "boolean" then return nil end
    return v
end

-- =========================================================
-- 发光：LibCustomGlow-1.0 的 Proc Glow（内嵌库，见 Libs/）
-- =========================================================
local LCG = B.LCG
local GLOW_KEY = "EBAC"   -- LCG key：Start / Stop 必须一致，否则发光帧残留

-- 停掉当前挂在 e._glowBtn 上的发光。必须先停旧键再换按钮，
-- 否则改绑 / 换页后旧按钮上的发光帧会永久残留。
local function StopGlow(e)
    if not LCG then return end
    local btn = e._glowBtn
    if not btn then return end
    pcall(LCG.ProcGlow_Stop, btn, GLOW_KEY)
    e._glowBtn = nil
end

-- mode: "none" | "on"（光环存在，青色） | "inverse"（光环缺失，亮红）
-- 按钮变化（改绑 / 翻页换技能）时即使 mode 未变也要重挂，故一并比较 _glowBtn。
local function SetGlowMode(e, mode)
    local btn = e.button
    if e._glowMode == mode and (mode == "none" or e._glowBtn == btn) then return end
    e._glowMode = mode
    if not LCG then return end
    if mode == "none" or not btn then
        StopGlow(e)
        return
    end
    if e._glowBtn and e._glowBtn ~= btn then StopGlow(e) end
    local c = (mode == "inverse") and S.INVERSE_GLOW_COLOR or S.GLOW_COLOR
    pcall(LCG.ProcGlow_Start, btn, {
        key = GLOW_KEY,
        startAnim = true,
        color = { c[1], c[2], c[3], c[4] or 1 },
    })
    e._glowBtn = btn
end

-- =========================================================
-- 容器创建（暴雪 AuraContainer；只在脱战时创建，战斗中延后）
-- =========================================================
-- 决定容器的追踪单位 + 过滤串。
--   · 单位取自 CDM item frame 的明文 auraDataUnit（缺省 player）——CDM 的增益/减益条目
--     可能追踪的是目标身上的光环（如自己的 DoT），固定用 player 会永远匹配不到。
--   · 过滤串必须与「includeSpellIDs 何时被暴雪允许」一致，否则 includeSpellIDs 被忽略，
--     槽位会匹配到任意光环 → 显示错误数值。规则见
--     Blizzard_AuraContainerUtil.CanApplyIdentityCandidateFilters（核实 2026-10-08，wow-ui-source live）：
--       harmful 且 UnitCanAssist("player", unit)  → includeSpellIDs 被忽略（自身/友方身上的减益）
--       helpful 且 不可协助的 unit               → includeSpellIDs 被忽略（敌方身上的增益）
--     故：可协助单位用 "HELPFUL"，不可协助（敌方）用 "HARMFUL"，两种情况 includeSpellIDs 均生效。
local function ResolveUnitAndFilter(spellID)
    local unit = (B.GetAuraUnit and B.GetAuraUnit(spellID)) or "player"
    local assistable = true
    local ok, res = pcall(UnitCanAssist, "player", unit)
    if ok and res ~= nil and not B.IsSecret(res) and type(res) == "boolean" then
        assistable = res
    end
    return unit, (assistable and "HELPFUL" or "HARMFUL")
end

local function BuildContainer(e)
    local spellID = e.spellID
    local includeSpellIDs = { [spellID] = true }
    -- 12.1+ 天赋改名场景：把扫描到的全部候选 ID 一并纳入精确过滤
    local buff = B.knownBuffs and B.knownBuffs[spellID]
    if buff and buff.ids then
        for _, id in ipairs(buff.ids) do includeSpellIDs[id] = true end
    end

    local unit, filterString = ResolveUnitAndFilter(spellID)

    local container = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(900)
    container:SetSize(36, 36)
    container:SetUnit(unit)
    container:SetEnabled(true)
    container:EnableMouse(false)   -- 覆盖在动作按钮之上，绝不拦截点击（自有帧，非受保护帧，安全）
    e.container = container
    e.unit = unit
    e.filterString = filterString

    -- ⚠️ initializeFrame 是【同步】回调，回调里 e.container 必须已就绪
    local ok = pcall(function()
        container:AddAuraSlot("ebac", filterString, {
            candidateFilters = { includeSpellIDs = includeSpellIDs },
            initializeFrame = function(btn)
                btn:SetAllPoints(container)
                local cd = CreateFrame("Cooldown", nil, btn)
                cd:SetDrawSwipe(false)
                cd:SetDrawEdge(false)
                cd:SetHideCountdownNumbers(false)
                btn:SetDurationCooldown(cd)
                e.cd = cd
                e._cdStyled = nil

                local fs = btn:CreateFontString(nil, "OVERLAY")
                fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 5, -5)
                fs:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
                fs:SetTextColor(S.STACK_COLOR[1], S.STACK_COLOR[2], S.STACK_COLOR[3])
                btn:SetApplicationCount(fs)
                e.fs = fs

                e.auraButton = btn
            end,
        })
    end)
    if not ok then
        e._initFailed = true
        container:Hide()
        e.container = nil
        e.auraButton, e.cd, e.fs = nil, nil, nil
        return false
    end
    e._initFailed = nil
    -- 重建后子控件是全新的、且容器尚未定位 → 清掉布局 / 位置缓存，强制下一次 UpdateEntry 重新摆放
    e._layoutKey = nil
    e._rectL, e._rectB, e._rectW, e._rectH = nil, nil, nil, nil
    container:Show()
    return true
end

local function EnsureEntry(spellID)
    local e = entries[spellID]
    local wantUnit = (B.GetAuraUnit and B.GetAuraUnit(spellID)) or "player"
    -- 单位变了（CDM 条目被改配置）→ 重建容器
    if e and e.auraButton and e.unit == wantUnit then return e end
    if InCombatLockdown() then
        -- 战斗中不新建容器（等脱战后由 PLAYER_REGEN_ENABLED 补建）
        if not e then entries[spellID] = { spellID = spellID } end
        return nil
    end
    if not e then
        e = { spellID = spellID }
        entries[spellID] = e
    end
    if e.container then
        -- 上次 AddAuraSlot 失败 / 单位变化：重建容器
        e.container:Hide()
        e.container = nil
        e.auraButton, e.cd, e.fs = nil, nil, nil
    end
    if not BuildContainer(e) then return nil end
    return e
end

-- 战斗中建容器失败后清标记，允许脱战重建
function B.ResetInitFailed()
    for spellID, e in pairs(entries) do
        if e._initFailed and not e.container then
            entries[spellID] = nil
        end
    end
end

-- =========================================================
-- 布局
-- =========================================================
-- 倒计时框锚定：一律用【绝对屏幕坐标】锚到 UIParent。
-- AuraContainer 的 flow layout 会在光环变化时异步覆盖容器尺寸，若相对容器 / 按钮锚定会跟着错位。
local function ApplyCdLayout(e, rx, ry, cw, ch, timePos, visible)
    local cd = e.cd
    if not cd then return end
    if timePos == "none" or visible == false then
        cd:SetAlpha(0)
        return
    end
    cd:SetAlpha(1)
    cd:ClearAllPoints()
    if timePos == "up" then
        cd:SetSize(cw * 0.68, ch * 0.68)
        cd:SetPoint("CENTER", UIParent, "BOTTOMLEFT", rx + cw / 2, ry + ch + 10)
    elseif timePos == "down" then
        cd:SetSize(cw * 0.68, ch * 0.68)
        cd:SetPoint("CENTER", UIParent, "BOTTOMLEFT", rx + cw / 2, ry - 10)
    elseif timePos == "left" then
        cd:SetSize(cw * 0.68, ch * 0.68)
        cd:SetPoint("CENTER", UIParent, "BOTTOMLEFT", rx - 10, ry + ch / 2)
    elseif timePos == "right" then
        cd:SetSize(cw * 0.68, ch * 0.68)
        cd:SetPoint("CENTER", UIParent, "BOTTOMLEFT", rx + cw + 10, ry + ch / 2)
    else
        -- 默认：按钮左下角 62% 框（与上游 Manual / Preset 同一几何）
        cd:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", rx + 1, ry - 6)
        cd:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", rx + cw * 0.62, ry + ch * 0.62 - 7)
    end
end

local function ApplyFsLayout(e, rx, ry, cw, ch, stackPos, visible)
    local fs = e.fs
    if not fs then return end
    if stackPos == "none" or visible == false then
        fs:SetAlpha(0)
        return
    end
    fs:SetAlpha(1)
    fs:ClearAllPoints()
    if stackPos == "up" then
        fs:SetPoint("CENTER", UIParent, "BOTTOMLEFT", rx + cw / 2, ry + ch + 10)
    elseif stackPos == "down" then
        fs:SetPoint("CENTER", UIParent, "BOTTOMLEFT", rx + cw / 2, ry - 10)
    elseif stackPos == "left" then
        fs:SetPoint("CENTER", UIParent, "BOTTOMLEFT", rx - 10, ry + ch / 2)
    elseif stackPos == "right" then
        fs:SetPoint("CENTER", UIParent, "BOTTOMLEFT", rx + cw + 10, ry + ch / 2)
    else
        -- 默认：左上角
        fs:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", rx + 5, ry + ch - 5)
    end
end

-- 倒计时数字的 FontString 要等暴雪首次驱动后才有；低频轮询，设置一次即标记完成
local function ApplyCountdownFont(e)
    local cd = e.cd
    if not cd or e._cdStyled then return end
    local cds = cd.GetCountdownFontString and cd:GetCountdownFontString()
    if not cds then return end
    local c = S.TIME_COLOR
    pcall(function()
        cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
        cds:SetTextColor(c[1], c[2], c[3])
    end)
    e._cdStyled = true
end

-- =========================================================
-- 光环是否存在（发光 / 反发光信号）
--   优先 CDM item 的明文 IsActive()（战斗中可读）；
--   无 CDM 帧时回退 AuraButton:IsShown()；都无法判定时沿用上次已知状态（粘滞，避免误报）
-- =========================================================
local function AuraPresent(e, item)
    local f = item or (B.FindFrameForSpell and B.FindFrameForSpell(e.spellID))
    if f then e.frame = f end
    -- 优先 CDM item 的明文 IsActive()；当前帧找不到时，退回上次缓存帧（需校验其仍属于本 spell，
    -- 否则 CDM 复用帧会读到别的光环的状态）。
    local probe = f
    if not probe and e.frame and e.frame.__EBACSpellID == e.spellID then probe = e.frame end
    local v = B.IsItemActive(probe)
    if v == nil and e.auraButton then
        local ok, shown = pcall(function() return e.auraButton:IsShown() end)
        if ok then v = ReadBool(shown) end
    end
    if v == nil then v = e._present end
    e._present = v
    return v
end

local function ApplyGlow(e, present, glowOn, inverseOn)
    if present == true then
        SetGlowMode(e, glowOn and "on" or "none")
    elseif present == false then
        SetGlowMode(e, inverseOn and "inverse" or "none")
    else
        SetGlowMode(e, "none")
    end
end

-- =========================================================
-- 单个条目的显示 / 停靠
-- =========================================================
-- 收起倒计时 / 层数（alpha 0，不用 Hide：不与暴雪驱动争抢显隐）
local function HideNumbers(e)
    if e.cd then e.cd:SetAlpha(0) end
    if e.fs then e.fs:SetAlpha(0) end
end

local function HideEntry(e)
    if not e.container then return end
    if e._rectL ~= DOCK_X then
        e.container:ClearAllPoints()
        e.container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", DOCK_X, DOCK_Y)
        e._rectL = DOCK_X
        e._rectB, e._rectW, e._rectH = nil, nil, nil
    end
    HideNumbers(e)
    SetGlowMode(e, "none")
    e.visible = false
end

local function UpdateEntry(e, btn)
    local left, bottom, width, height = btn:GetRect()
    if not left then
        HideEntry(e)
        return
    end
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    local rx, ry = left * r, bottom * r
    local cw, ch = width * r, height * r

    local timePos, stackPos, glowOn, inverseOn = B.GetDisplayOptions(e.spellID)

    -- 光环是否存在：不存在时必须把数字 / 层数收起。暴雪只会在【自己】单位的 AuraButton 上
    -- 清掉 duration cooldown；目标 debuff 消失（切目标 / 翻页）后不会清我们的倒计时 → 数字滞留。
    local present = AuraPresent(e)
    local showNum = (present ~= false)

    -- 容器：自有帧，SetPoint / SetSize 战斗安全。
    -- 位置可缓存；尺寸每次都设（对抗 AuraContainer flow layout 的异步尺寸覆盖）。
    if e._rectL ~= left or e._rectB ~= bottom or e._rectW ~= width or e._rectH ~= height then
        e.container:ClearAllPoints()
        e.container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", rx, ry + ch)
        e._rectL, e._rectB, e._rectW, e._rectH = left, bottom, width, height
    end
    e.container:SetSize(cw, ch)
    e.container:Show()   -- 保持可见以接收 UNIT_AURA（ShouldRegisterForDynamicEvents = IsVisible and IsEnabled）

    -- 子控件布局：几何 / 选项 / 显隐未变则跳过（子控件用绝对屏幕坐标，容器尺寸变化不影响它们）
    local key = table.concat({ timePos, stackPos, rx, ry, cw, ch, showNum and "1" or "0" }, ":")
    if e._layoutKey ~= key then
        e._layoutKey = key
        ApplyCdLayout(e, rx, ry, cw, ch, timePos, showNum)
        ApplyFsLayout(e, rx, ry, cw, ch, stackPos, showNum)
    end

    ApplyCountdownFont(e)
    e.visible = showNum
    ApplyGlow(e, present, glowOn, inverseOn)
end

-- =========================================================
-- 对外接口
-- =========================================================
-- CDM item 的 RefreshData hook（暴雪驱动，战斗中照常触发）→ 只更新发光，开销极小
function B.OnCdmItemRefreshed(spellID, item)
    local e = entries[spellID]
    if not e or not e.button then return end
    e.frame = item
    local _, _, glowOn, inverseOn = B.GetDisplayOptions(spellID)
    if glowOn or inverseOn then
        ApplyGlow(e, AuraPresent(e, item), glowOn, inverseOn)
    end
end

-- 根据当前绑定重建条目（绑定变动 / 专精切换 / 动作条变动时调用）。
-- 战斗中不重建（等脱战），避免战斗中创建容器与目标技能解析受 secret 影响。
function B.RebuildEntries()
    if not B.db or InCombatLockdown() then return end
    local bindings = B.GetBindings()
    local map = B.BuildSpellButtonMap()

    for spellID, cfg in pairs(bindings) do
        local target = cfg.bindSpell
        local buttonName = target and map[target]
        if buttonName then
            local e = EnsureEntry(spellID)
            if e then
                e.buttonName = buttonName
                e.button = _G[buttonName]
            end
        else
            local e = entries[spellID]
            if e then
                e.button, e.buttonName = nil, nil
                e._layoutKey = nil
                HideEntry(e)
            end
        end
    end

    -- 已解除绑定的条目：停靠
    for spellID, e in pairs(entries) do
        local cfg = bindings[spellID]
        if not (cfg and cfg.bindSpell) then
            e.button, e.buttonName = nil, nil
            e._layoutKey = nil
            HideEntry(e)
        end
    end

    B.RefreshAll()
end

-- 翻页 / 换技能后按钮会被改作他用：撤下覆盖层，避免数字滞留在不再对应本绑定的按钮上。
-- 由主文件低频巡检调用（事件可能漏触发，这里做兜底）。match 为 nil（无法判定）时不动。
function B.HideStaleEntries()
    for spellID, e in pairs(entries) do
        if e.buttonName and e.container then
            local match = B.ButtonMatchesBinding and B.ButtonMatchesBinding(e.buttonName, spellID)
            if match == false then
                e.button, e.buttonName = nil, nil
                e._layoutKey = nil
                HideEntry(e)
            end
        end
    end
end

-- 全量刷新：重定位 + 同步发光（登录 / 切换专精 / 动作条变动 / 光环增删 / 定时兜底）
function B.RefreshAll()
    if not B.db then return end
    for spellID, e in pairs(entries) do
        if e.button and e.container then
            local ok = pcall(UpdateEntry, e, e.button)
            if not ok then
                pcall(HideEntry, e)
            end
        end
    end
end

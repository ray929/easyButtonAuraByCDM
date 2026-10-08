-- AuraDisplay.lua
-- Easy Button Aura by CDM — 渲染层
--
-- 对每个「已绑定」的 CDM 增益，在目标动作条按钮上显示该光环的剩余时间与层数。
--
-- ⚠️ 12.1 AuraButton 安全约束（本文件所有设计都源于此；核实日期 2026-10-08，
--    来源 Blizzard_AuraContainer 源码 Blizzard_CustomAuraButton.lua / AuraContainerUtil.lua）：
--   AuraButton 及其子控件带 ForbiddenAspects：
--     UntrustedScriptExecution / UntrustedLayoutScriptExecution / ChangeParent / RemoveSecretAspects。
--   这些限制在 initializeFrame 回调【返回之后】才生效。之后 addon（tainted）对这些子控件：
--     · SetPoint / SetSize / ClearAllPoints（布局）→ 静默失效；
--     · SetAlpha / SetText / Show / Hide（脚本）→ 静默失效，读回的是 secret 值。
--   ⇒ 子控件的创建、注册、定位、样式【只能】在 initializeFrame 回调内完成。
--   ⇒ 之后 addon 只能操作【自己创建的容器】（普通帧，不受限）：
--        移动 / 改尺寸容器 → 子控件随之移动（AuraButton 由 SetAllPoints(container) 跟随）。
--   ⇒ 「时间 / 层数位置」这类会改变子控件锚点的选项，只能在【重建容器】时应用
--      （选项仅允许脱战修改，重建也只在脱战进行）。
--
-- 其余要点：
--   · 倒计时 / 层数由暴雪特权层驱动（SetDurationCooldown / SetApplicationCount），
--     addon 零读取光环数值 → 战斗中照常显示、无 secret 问题。
--   · CDM 的原有显示完全不动（不隐藏 / 不移动），只读 CDM item 的明文 IsActive() 驱动发光。
--   · 容器只挂 UIParent（绝不锚到安全动作按钮）；发光用内嵌 LibCustomGlow-1.0 挂按钮上。

local B = EasyButtonAuraByCDM
local S = B.Style

local DOCK_X, DOCK_Y = -10000, -10000

-- 时间 / 层数在按钮四周时的固定像素外距与缩放
local SIDE_GAP = 10
local SIDE_SCALE = 0.68
-- 按钮尺寸变化超过该像素数才重建容器（避免抖动引发重建循环）
local SIZE_EPS = 2

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
-- 几何
-- =========================================================
-- 按钮当前 rect → UIParent 坐标系的 (rx, ry, cw, ch)。按钮不可见 / 未定位时返回 nil。
local function ButtonRect(btn)
    if not btn then return nil end
    local left, bottom, width, height = btn:GetRect()
    if not left then return nil end
    local r = 1
    local bs, ps = btn:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if bs and ps and ps > 0 then r = bs / ps end
    return left * r, bottom * r, width * r, height * r
end

-- 倒计时框锚点。⚠️ 只在 initializeFrame 回调内调用（见文件头说明）。
-- 位置选项 up/down/left/right/none 在此生效；默认档 = 按钮左下角 62% 框
-- （与上游 ActionbarEnhanced Manual / Preset 同一几何）。
local function AnchorTime(cd, btn, cw, ch, pos)
    cd:ClearAllPoints()
    if pos == "up" then
        cd:SetSize(cw * SIDE_SCALE, ch * SIDE_SCALE)
        cd:SetPoint("CENTER", btn, "TOP", 0, SIDE_GAP)
    elseif pos == "down" then
        cd:SetSize(cw * SIDE_SCALE, ch * SIDE_SCALE)
        cd:SetPoint("CENTER", btn, "BOTTOM", 0, -SIDE_GAP)
    elseif pos == "left" then
        cd:SetSize(cw * SIDE_SCALE, ch * SIDE_SCALE)
        cd:SetPoint("CENTER", btn, "LEFT", -SIDE_GAP, 0)
    elseif pos == "right" then
        cd:SetSize(cw * SIDE_SCALE, ch * SIDE_SCALE)
        cd:SetPoint("CENTER", btn, "RIGHT", SIDE_GAP, 0)
    else
        cd:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 1, -6)
        cd:SetPoint("TOPRIGHT", btn, "BOTTOMLEFT", cw * 0.62, ch * 0.62 - 7)
    end
end

-- 层数文字锚点。⚠️ 同样只在 initializeFrame 回调内调用。
local function AnchorStacks(fs, btn, pos)
    fs:ClearAllPoints()
    if pos == "up" then
        fs:SetPoint("CENTER", btn, "TOP", 0, SIDE_GAP)
    elseif pos == "down" then
        fs:SetPoint("CENTER", btn, "BOTTOM", 0, -SIDE_GAP)
    elseif pos == "left" then
        fs:SetPoint("CENTER", btn, "LEFT", -SIDE_GAP, 0)
    elseif pos == "right" then
        fs:SetPoint("CENTER", btn, "RIGHT", SIDE_GAP, 0)
    else
        fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 5, -5)
    end
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

    -- 先量好按钮尺寸：容器必须【在 AddAuraSlot 之前】就是最终尺寸，
    -- 因为 initializeFrame 回调是同步执行的，回调里要用 cw/ch 计算比例锚点。
    local rx, ry, cw, ch = ButtonRect(e.button)
    if not cw or cw <= 0 then cw, ch = 36, 36 end

    local timePos, stackPos = B.GetDisplayOptions(spellID)

    local container = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(900)
    container:SetSize(cw, ch)
    container:SetUnit(unit)
    container:SetEnabled(true)
    container:EnableMouse(false)   -- 覆盖在动作按钮之上，绝不拦截点击（自有帧，非受保护帧，安全）
    e.container = containe
    e.unit = unit
    e.filterString = filterString
    e.cd, e.fs, e.auraButton = nil, nil, nil

    -- ⚠️ 子控件的一切操作必须在这个回调内完成（回调返回后即受限，见文件头）
    local ok = pcall(function()
        container:AddAuraSlot("ebac", filterString, {
            candidateFilters = { includeSpellIDs = includeSpellIDs },
            initializeFrame = function(btn)
                btn:SetAllPoints(container)

                -- 倒计时（"none" 档不注册 → 按钮上不显示任何剩余时间）
                if timePos ~= "none" then
                    local cd = CreateFrame("Cooldown", nil, btn)
                    cd:SetDrawSwipe(false)
                    cd:SetDrawEdge(false)
                    cd:SetHideCountdownNumbers(false)
                    AnchorTime(cd, btn, cw, ch, timePos)
                    btn:SetDurationCooldown(cd)
                    e.cd = cd
                    e._cdStyled = nil
                end

                -- 层数（"none" 档不注册；暴雪也只在层数 >1 时显示）
                if stackPos ~= "none" then
                    local fs = btn:CreateFontString(nil, "OVERLAY")
                    fs:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
                    fs:SetTextColor(S.STACK_COLOR[1], S.STACK_COLOR[2], S.STACK_COLOR[3])
                    AnchorStacks(fs, btn, stackPos)
                    btn:SetApplicationCount(fs)
                    e.fs = fs
                end

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
    -- 重建后子控件是全新的 → 清掉位置缓存，强制下一次 UpdateEntry 重新摆放
    e._px, e._py, e._pw, e._ph = nil, nil, nil, nil
    e._builtTimePos, e._builtStackPos = timePos, stackPos
    e._builtW, e._builtH = cw, ch
    container:ClearAllPoints()
    if rx then
        container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", rx, ry + ch)
        e._px, e._py, e._pw, e._ph = rx, ry, cw, ch
        e._docked = false
    else
        -- 按钮尚未定位（GetRect 为 nil）：先停靠到屏幕外，等 UpdateEntry 拿到 rect 再摆正
        container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", DOCK_X, DOCK_Y)
        e._docked = true
    end
    container:Show()
    return true
end

-- 销毁并重建容器（仅脱战）。用于：单位变化 / 位置选项变化 / 按钮尺寸变化。
local function RebuildContainer(e)
    if e.container then
        e._docked = true
        e.container:Hide()
        e.container = nil
    end
    e.auraButton, e.cd, e.fs = nil, nil, nil
    e._px, e._py, e._pw, e._ph = nil, nil, nil, nil
    return BuildContainer(e)
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
-- 倒计时数字字体（best-effort：受限帧上的 SetFont 可能静默失效，失败即放弃）
-- =========================================================
local function ApplyCountdownFont(e)
    local cd = e.cd
    if not cd or e._cdStyled then return end
    local cds
    local ok = pcall(function() cds = cd.GetCountdownFontString and cd:GetCountdownFontString() end)
    if not ok or not cds then return end
    local c = S.TIME_COLOR
    pcall(function()
        cds:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
        cds:SetTextColor(c[1], c[2], c[3])
    end)
    e._cdStyled = true
end

-- =========================================================
-- 光环是否存在（发光 / 反发光信号，兼作「数字是否显示」的开关）
--   优先 CDM item 的明文 IsActive()（战斗中可读）；
--   无 CDM 帧时回退 AuraButton:IsShown()（12.1 下多半是 secret → 无法判定）；
--   都无法判定时沿用上次已知状态（粘滞，避免误报）
-- =========================================================
local function AuraPresent(e, item)
    local f = item or (B.FindFrameForSpell and B.FindFrameForSpell(e.spellID))
    if f then e.frame = f end
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
-- 停靠到屏幕外（不用 Hide：需保持可见才继续接收 UNIT_AURA，
-- ShouldRegisterForDynamicEvents = IsVisible and IsEnabled）。
-- 子控件随容器一起移出屏幕 —— 受限帧上无法用 SetAlpha/Hide 单独收起数字。
local function DockContainer(e)
    local c = e.containe
    if not c then return end
    if e._docked then return end
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", DOCK_X, DOCK_Y)
    e._docked = true
    e._px, e._py, e._pw, e._ph = nil, nil, nil, nil
end

local function HideEntry(e)
    DockContainer(e)
    SetGlowMode(e, "none")
    e.visible = false
end

local function UpdateEntry(e, btn)
    local rx, ry, cw, ch = ButtonRect(btn)
    if not rx then
        HideEntry(e)
        return
    end

    -- 按钮尺寸变了（UI 缩放 / 动作条缩放 / 编辑模式改尺寸）→ 比例锚点需按新尺寸重算。
    -- 受限帧无法在回调外改锚点，只能重建容器。仅脱战重建。
    if e._builtW and (math.abs(e._builtW - cw) > SIZE_EPS or math.abs(e._builtH - ch) > SIZE_EPS)
        and not InCombatLockdown() then
        if not RebuildContainer(e) then return end
        rx, ry, cw, ch = ButtonRect(btn)
        if not rx then
            HideEntry(e)
            return
        end
    end

    local timePos, stackPos, glowOn, inverseOn = B.GetDisplayOptions(e.spellID)

    -- 光环不存在：连容器一起停靠（数字随之移出屏幕），并撤下发光以外的显示。
    local present = AuraPresent(e)
    local showNum = (present ~= false)

    if showNum then
        if e._docked or e._px ~= rx or e._py ~= ry or e._pw ~= cw or e._ph ~= ch then
            e.container:ClearAllPoints()
            e.container:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", rx, ry + ch)
            e._px, e._py, e._pw, e._ph = rx, ry, cw, ch
            e._docked = false
        end
        -- 尺寸每次都设：对抗 AuraContainer flow layout 的异步尺寸覆盖
        e.container:SetSize(cw, ch)
        e.container:Show()
    else
        DockContainer(e)
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
        local e = entries[spellID]
        if buttonName then
            -- ⚠️ 先填好 button 再建容器：BuildContainer 要量按钮尺寸来算比例锚点
            if not e then
                e = { spellID = spellID }
                entries[spellID] = e
            end
            e.buttonName = buttonName
            e.button = _G[buttonName]
            local ready = EnsureEntry(spellID)
            if ready then
                -- 位置选项变了 → 受限帧无法在回调外改锚点，只能重建容器把新位置应用进去
                local tPos, sPos = B.GetDisplayOptions(spellID)
                if ready.container and (ready._builtTimePos ~= tPos or ready._builtStackPos ~= sPos) then
                    RebuildContainer(ready)
                end
            end
        else
            local dead = entries[spellID]
            if dead then
                dead.button, dead.buttonName = nil, nil
                HideEntry(dead)
            end
        end
    end

    -- 已解除绑定的条目：停靠
    for spellID, e in pairs(entries) do
        local cfg = bindings[spellID]
        if not (cfg and cfg.bindSpell) then
            e.button, e.buttonName = nil, nil
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

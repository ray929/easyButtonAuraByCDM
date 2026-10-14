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
--   ⚠️ LCG 的发光帧是【按钮级】：按 传入按钮 + key 存放（r["_ProcGlow"..key]）。
--      而绑定是【光环级】——同一个动作按钮可能被多个光环绑定（例如两条光环都绑到
--      同一个技能）。若每个光环各自 Start / Stop，就会互相 Stop 掉共享的发光帧，
--      或每次刷新都重启一次动画 → 视觉上「浓厚 / 闪烁」，甚至残留。
--      故：先按【按钮】汇总所有光环的发光意图（优先级 on > inverse > none），
--      每个按钮只应用一次（模式变化才重启），从根上消除叠层。
-- =========================================================
local LCG = B.LCG
local GLOW_KEY = "EBAC"       -- LCG key：Start / Stop 必须一致，否则发光帧残留
local glowApplied = {}        -- button -> "on" | "inverse"（该按钮当前已应用的发光状态）

local function StopButtonGlow(btn)
    if not btn then return end
    if not glowApplied[btn] then return end
    if LCG then pcall(LCG.ProcGlow_Stop, btn, GLOW_KEY) end
    glowApplied[btn] = nil
end

local function StartButtonGlow(btn, mode)
    if not btn or not LCG then return end
    if glowApplied[btn] == mode then return end
    -- 模式变化（青 ↔ 红）先停旧帧再起，避免颜色 / 动画残留
    if glowApplied[btn] then pcall(LCG.ProcGlow_Stop, btn, GLOW_KEY) end
    local c = (mode == "inverse") and S.INVERSE_GLOW_COLOR or S.GLOW_COLOR
    pcall(LCG.ProcGlow_Start, btn, {
        key = GLOW_KEY,
        startAnim = true,
        color = { c[1], c[2], c[3], c[4] or 1 },
    })
    glowApplied[btn] = mode
end

-- 按按钮汇总并应用发光。意图实时读自「该按钮上所有光环的 present + 发光配置」，
-- 幂等：同按钮同模式重复调用不会重启动画（LCG 的「浓厚感」主要来自反复 Start）。
-- 由 RefreshAll / OnCdmItemRefreshed / HideStaleEntries 末尾统一调用。
function B.ApplyButtonGlows()
    if not LCG then return end
    -- 全局开关关闭：停掉所有发光（覆盖层的撤下由 RefreshAll / RebuildEntries 负责）
    if B.IsEnabled and not B.IsEnabled() then
        for btn in pairs(glowApplied) do StopButtonGlow(btn) end
        return
    end
    local want = {}
    for spellID, e in pairs(entries) do
        local btn = e.button
        if btn and not e._hidden then
            local _, _, glowOn, inverseOn = B.GetDisplayOptions(spellID)
            local present = e._present
            if present == true and glowOn then
                want[btn] = "on"
            elseif present == false and inverseOn and want[btn] ~= "on" then
                want[btn] = "inverse"
            end
        end
    end
    for btn, mode in pairs(want) do StartButtonGlow(btn, mode) end
    for btn in pairs(glowApplied) do
        if not want[btn] then StopButtonGlow(btn) end
    end
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
--
-- ⚠️ 锚定目标必须是【自有容器 container 的 TOPLEFT】（而非 btn / AuraButton）：
--   cd 是 AuraButton 的子帧（受限帧），战斗中在受限帧上的布局操作会被静默拦下；且 AuraButton
--   的位置 / 尺寸受暴雪 AuraContainer flow layout 异步覆盖。锚到容器 TOPLEFT ＋ 固定像素偏移
--   ＋ 显式 SetSize 后，cd 成为「容器子级锚定关系」—— 容器停靠屏幕外时 cd 自动跟随，战斗中
--   无需重锚（对齐 easyButtonAuraByUnit 的 LayoutAuraChildren，修「切换技能栏后数字滞留」）。
--   几何与锚 btn 等价：容器 rect == 按钮 rect（AuraButton 由 SetAllPoints(container) 跟随）。
local function AnchorTime(cd, container, cw, ch, pos)
    cd:ClearAllPoints()
    if pos == "up" then
        cd:SetSize(cw * SIDE_SCALE, ch * SIDE_SCALE)
        cd:SetPoint("CENTER", container, "TOPLEFT", cw * 0.5, SIDE_GAP)
    elseif pos == "down" then
        cd:SetSize(cw * SIDE_SCALE, ch * SIDE_SCALE)
        cd:SetPoint("CENTER", container, "TOPLEFT", cw * 0.5, -ch - SIDE_GAP)
    elseif pos == "left" then
        cd:SetSize(cw * SIDE_SCALE, ch * SIDE_SCALE)
        cd:SetPoint("CENTER", container, "TOPLEFT", -SIDE_GAP, -ch * 0.5)
    elseif pos == "right" then
        cd:SetSize(cw * SIDE_SCALE, ch * SIDE_SCALE)
        cd:SetPoint("CENTER", container, "TOPLEFT", cw + SIDE_GAP, -ch * 0.5)
    else
        cd:SetSize(cw * 0.62 - 1, ch * 0.62 - 1)
        cd:SetPoint("BOTTOMLEFT", container, "TOPLEFT", 1, -(ch + 6))
    end
end

-- 层数文字锚点。⚠️ 同样只在 initializeFrame 回调内调用；锚定目标同 AnchorTime（容器 TOPLEFT）。
local function AnchorStacks(fs, container, cw, ch, pos)
    fs:ClearAllPoints()
    if pos == "up" then
        fs:SetPoint("CENTER", container, "TOPLEFT", cw * 0.5, SIDE_GAP)
    elseif pos == "down" then
        fs:SetPoint("CENTER", container, "TOPLEFT", cw * 0.5, -ch - SIDE_GAP)
    elseif pos == "left" then
        fs:SetPoint("CENTER", container, "TOPLEFT", -SIDE_GAP, -ch * 0.5)
    elseif pos == "right" then
        fs:SetPoint("CENTER", container, "TOPLEFT", cw + SIDE_GAP, -ch * 0.5)
    else
        fs:SetPoint("TOPLEFT", container, "TOPLEFT", 5, -5)
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

-- 客户端能力探测：AuraContainer / CustomAuraContainerTemplate 为 12.1 引入的体系。
-- 目标客户端若缺失（如未在 Camelot / 无限上验证的情形），把标记置 false 后静默跳过
-- （全静默约定，不刷错误）。
local containerSupported = true

local function BuildContainer(e)
    if not containerSupported then return false end
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
    if not cw or cw <= 0 then cw, ch = 42, 42 end

    local timePos, stackPos = B.GetDisplayOptions(spellID)

    -- pcall 兜底：客户端若不支持 AuraContainer 体系，CreateFrame 会抛错
    local okCreate, container = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    if not okCreate or not container then
        containerSupported = false
        return false
    end
    -- MEDIUM + 1000：与 easyButtonAuraByUnit 同款修法。HIGH 会压在世界地图（MEDIUM）之上；
    -- FrameLevel 1000 押后同级内绘制顺序（见 easyButtonAuraByUnit dcb01c3）
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(1000)
    container:SetSize(cw, ch)
    container:SetUnit(unit)
    container:SetEnabled(true)
    container:EnableMouse(false)   -- 覆盖在动作按钮之上，绝不拦截点击（自有帧，非受保护帧，安全）
    e.container = container
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
                    AnchorTime(cd, container, cw, ch, timePos)
                    btn:SetDurationCooldown(cd)
                    e.cd = cd
                    e._cdStyled = nil
                end

                -- 层数（"none" 档不注册；暴雪也只在层数 >1 时显示）
                if stackPos ~= "none" then
                    local fs = btn:CreateFontString(nil, "OVERLAY")
                    fs:SetFont(S.FONT, S.FONT_SIZE, S.OUTLINE)
                    fs:SetTextColor(S.STACK_COLOR[1], S.STACK_COLOR[2], S.STACK_COLOR[3])
                    AnchorStacks(fs, container, cw, ch, stackPos)
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
    e._stale = nil   -- 容器重建 = 重新挂靠，清掉巡检留下的 stale 标记
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

-- 为单个绑定【确保容器存在】（⚠️ 只创建，不挂靠）。
-- 与「按钮是否解析到」完全无关：即便目标技能当前不在任何动作条上，也先把容器建好并停靠
-- 屏幕外，这样任何时候（含战斗中）首次触发光环都已有容器在接收 UNIT_AURA（见坑 14）。
-- 仅可在脱战调用（BuildContainer 内会 CreateFrame("AuraContainer")）。
local function EnsureContainerFor(spellID)
    local e = entries[spellID]
    local wantUnit = (B.GetAuraUnit and B.GetAuraUnit(spellID)) or "player"
    -- 容器已建且单位一致：仅当「时间 / 层数位置」选项变化时重建
    -- （选项改的是 AuraButton 子控件锚点，回调外改不了，只能重建容器让回调按新参数布局）
    if e and e.container and e.unit == wantUnit then
        local tPos, sPos = B.GetDisplayOptions(spellID)
        if e._builtTimePos ~= tPos or e._builtStackPos ~= sPos then
            RebuildContainer(e)
        end
        return e
    end
    -- 单位变了（CDM 条目被改配置）/ 尚未建 → 重建
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

-- =========================================================
-- 单个条目的显示 / 停靠
-- =========================================================
-- 停靠到屏幕外（不用 Hide：需保持可见才继续接收 UNIT_AURA，
-- ShouldRegisterForDynamicEvents = IsVisible and IsEnabled）。
-- 子控件（cd / 层数文字）锚在容器 TOPLEFT 上（见 AnchorTime / AnchorStacks）→ 随容器一起移出
-- 屏幕，无需（也不能）在受限帧上单独 SetAlpha / Hide 收起数字。
local function DockContainer(e)
    local c = e.container
    if not c then return end
    if e._docked then return end
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", DOCK_X, DOCK_Y)
    e._docked = true
    e._px, e._py, e._pw, e._ph = nil, nil, nil, nil
end

local function HideEntry(e)
    DockContainer(e)
    e._hidden = true   -- 不参与发光汇总（按钮不可用 / 未定位）
    e.visible = false
end

local function UpdateEntry(e, btn)
    -- 该条目已被巡检判定「按钮改作他用」（翻页 / 换技能 / 空槽）→ 保持停靠。
    -- 战斗中 RebuildEntries 不执行，故这里【只停靠、不清引用】，技能回来后巡检清掉 _stale
    -- 即可原位恢复（见 HideStaleEntries），不会像清引用那样「切回也不复原」。
    if e._stale then
        DockContainer(e)
        e._hidden = true
        e.visible = false
        return
    end

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

    -- 光环不存在：连容器一起停靠（数字随之移出屏幕），发光由汇总层统一处理。
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
    e._hidden = nil
    e.visible = showNum
    -- 发光不在此处应用：由 RefreshAll 末尾的 B.ApplyButtonGlows 按按钮统一汇总
end

-- =========================================================
-- 对外接口
-- =========================================================
-- CDM item 的 RefreshData hook（暴雪驱动，战斗中照常触发）→ 只更新发光，开销极小
function B.OnCdmItemRefreshed(spellID, item)
    local e = entries[spellID]
    if not e or not e.button then return end
    -- 刷新该光环「是否存在」的明文状态，再按按钮统一重算发光
    AuraPresent(e, item)
    B.ApplyButtonGlows()
end

-- 切换目标后的槽位候选重置（修「切目标后倒计时冻在旧目标实例上」，见 docs 专有坑 17）。
-- 根因：AuraContainer 的 aura slot 按 auraInstanceID 记账，候选表只在全量刷新时清空；
-- UNIT_AURA 增量载荷只含【当前实体】的变化，旧目标的光环实例永远等不到 removed 事件。
-- 切目标（unit token 不变、实体已变）后旧实例残留候选表，若它仍是 preferred 且
-- assigned == preferred，RefreshAuraSlot 既不重分配也不更新按钮 → 倒计时冻在旧目标的
-- 时间线上；重新施法刷的是新实例、preferred 依旧是旧实例 → 也救不回来，只能重载。
-- 处置（与 easyButtonAuraByUnit 的 PLAYER_TARGET_CHANGED 处理同一方案）：显式调
-- UpdateAllAuras → FullAuraRebuild → ParseAllAuras → ClearAuraSlotCandidates（forceReassign）
-- → 全量重解析当前实体的光环 → 下一帧按新目标实例重新分配按钮、冷却重设。
-- 战斗安全：不建帧（区别于会建帧的 AddAuraSlot，见坑 5）、不碰受保护 API；
-- pcall 兜底，失败置 _slotResetPending 由 1s 巡检重试（错误留痕，防静默失败）。
function B.ResetTargetUnitSlots()
    local failed = false
    for _, e in pairs(entries) do
        if e.container and e.unit == "target" then
            local ok = pcall(e.container.UpdateAllAuras, e.container)
            if not ok then failed = true end
        end
    end
    B._slotResetPending = failed or nil
    return not failed
end

-- 根据当前绑定重建条目（绑定变动 / 专精切换 / 登录 / 动作条变动 / 脱战时调用）。
-- ⚠️ 创建与挂靠【解耦】（2026-10-12）：
--   ① 创建：为「CDM 已启用且有绑定」的每条光环【都】建容器，与「按钮是否解析到」无关；
--      解析不到按钮的容器先停靠屏幕外，等按钮出现（脱战）再挂靠。这样任何绑定在进战斗前
--      就已有容器在接收 UNIT_AURA，彻底消除「战斗中首次触发不显示、脱战才出现」（坑 14）。
--   ② 挂靠：解析目标按钮引用；解析到由 RefreshAll 定位到按钮，解析不到即保持停靠。
-- 战斗中不执行（容器只能脱战创建）：仅置 _pendingBuild，等 PLAYER_REGEN_ENABLED / 巡检补做。
function B.RebuildEntries()
    if not B.db then return end
    if InCombatLockdown() then
        B._pendingBuild = true
        return
    end
    B._pendingBuild = nil
    -- 全局开关关闭：撤下所有覆盖层 + 停发光，且不建新容器；开启后下一次重建会恢复
    if B.IsEnabled and not B.IsEnabled() then
        for _, e in pairs(entries) do
            e.button, e.buttonName, e._actionID = nil, nil, nil
            HideEntry(e)
        end
        B.ApplyButtonGlows()
        return
    end
    local bindings = B.GetBindings()
    local map = B.BuildSpellButtonMap()
    local known = B.knownBuffs or {}

    -- ① 创建 + 解析按钮：仅当该光环当前仍在 CDM 中【已启用】且已绑定目标技能时才建立条目
    --    （从 CDM 移除 / 解绑即撤下覆盖层；绑定仍保留在存档里，日后重新启用会自动恢复）。
    for spellID, cfg in pairs(bindings) do
        if known[spellID] and cfg.bindSpell then
            local e = entries[spellID]
            if not e then
                e = { spellID = spellID }
                entries[spellID] = e
            end
            -- ⚠️ 先填好 button 再建容器：BuildContainer 要量按钮尺寸来算比例锚点
            --    （按钮暂缺时为 nil → 容器按默认尺寸创建并停靠，不影响创建本身）
            local buttonName = map[cfg.bindSpell]
            e.buttonName = buttonName
            e.button = buttonName and _G[buttonName] or nil
            -- 记录挂靠时的 action 槽位 ID：战斗中精确比对读不到 spellID 时用它做回退（见
            -- B.ButtonMatchesBinding / B.GetButtonActionID）
            e._actionID = buttonName and B.GetButtonActionID and B.GetButtonActionID(buttonName) or nil
            e._stale = nil      -- 脱战重建即彻底重解析，清掉巡检留下的 stale 标记
            EnsureContainerFor(spellID)
        end
    end

    -- ② 无效条目（解绑 / 该光环已从 CDM 移除 / 专精切换后不再适用）：清引用 + 停靠
    for spellID, e in pairs(entries) do
        local cfg = bindings[spellID]
        if not (cfg and cfg.bindSpell and known[spellID]) then
            e.button, e.buttonName, e._actionID = nil, nil, nil
            HideEntry(e)
        end
    end

    B.RefreshAll()
end

-- =========================================================
-- 按钮重解析（战斗安全）：对齐 easyButtonAuraByUnit 的 ResolveButton 自愈角色
-- =========================================================
-- 为【丢失按钮引用】（buttonName 为 nil）的有效绑定条目重新解析按钮并补挂靠。
--   · 只补丢失的引用，既有引用绝不覆盖：战斗中 GetActionInfo 的 id 可能是 secret（坑 15），
--     覆盖写入有把正在显示中的条目误停靠的风险；既有引用的有效性由 HideStaleEntries
--     巡检判定（_stale 可逆停靠）。
--   · 不创建 / 不重建容器（CreateFrame AuraContainer 战斗中失败）——容器生命周期仍归
--     RebuildEntries（仅脱战）；找不到按钮就保持 nil，由调用方停靠，无副作用。
--   · 无效条目（解绑 / 光环已从 CDM 移除）的清理归 RebuildEntries，这里不做。
-- 典型场景（2026-10-14「野兽之眼 trick」，docs 坑 18）：脱战期间动作条被宠物条覆盖，
-- RebuildEntries 重解析不到目标技能而清掉引用；取消野兽之眼的瞬间进战斗 + 动作条切回，
-- 旧逻辑里唯一的重解析入口（RebuildEntries）被 InCombatLockdown 挡死 → 数字等脱战才恢复。
-- 本函数可在战斗中调用：动作条事件（+0.1s）与 1s 巡检（HideStaleEntries）都会驱动它。
function B.RebindButtons()
    if not B.db then return false end
    if B.IsEnabled and not B.IsEnabled() then return false end
    local bindings = B.GetBindings()
    local known = B.knownBuffs or {}
    local map, changed = nil, false
    for spellID, cfg in pairs(bindings) do
        if known[spellID] and cfg.bindSpell then
            local e = entries[spellID]
            if not e then
                e = { spellID = spellID }
                entries[spellID] = e
            end
            if not e.buttonName then
                map = map or B.BuildSpellButtonMap()
                local buttonName = map[cfg.bindSpell]
                if buttonName then
                    e.buttonName = buttonName
                    e.button = _G[buttonName]
                    e._actionID = B.GetButtonActionID and B.GetButtonActionID(buttonName) or nil
                    e._stale = nil
                    changed = true
                end
            end
        end
    end
    return changed
end

-- 翻页 / 换技能后按钮会被改作他用：撤下覆盖层，避免数字滞留在不再对应本绑定的按钮上。
-- 由主文件低频巡检调用（事件可能漏触发，这里做兜底）。match 为 nil（无法判定）时不动。
-- 2026-10-14 扩展：也负责【恢复】——引用丢失（buttonName 为 nil）的条目先经 RebindButtons
-- 重解析（战斗安全），恢复则 changed 为真、末尾 RefreshAll 原位挂靠；不再只能等脱战重建
-- （修「野兽之眼 trick」，docs 坑 18）。
function B.HideStaleEntries()
    local changed = false
    if B.RebindButtons and B.RebindButtons() then changed = true end
    for spellID, e in pairs(entries) do
        if e.buttonName and e.container then
            local match = B.ButtonMatchesBinding and B.ButtonMatchesBinding(e.buttonName, spellID, e._actionID)
            if match == false then
                -- 按钮确实已改作他用（翻页 / 换技能 / 空槽）：停靠撤下，但【保留】引用。
                -- 战斗中 RebuildEntries 不执行，若在此清引用就无法在战斗中恢复（切回来也不复原）；
                -- 「保留引用 + 停靠」是可逆的：技能回到该按钮时下一次巡检即可原位恢复。
                DockContainer(e)
                e._hidden = true
                e.visible = false
                if not e._stale then
                    e._stale = true
                    changed = true
                end
            elseif match == true and e._stale then
                -- 技能回到该按钮（切回原页）：清掉 stale 标记，交给 RefreshAll 原位恢复
                e._stale = nil
                changed = true
            end
        end
    end
    B.ApplyButtonGlows()
    if changed and B.RefreshAll then B.RefreshAll() end
end

-- 全量刷新：重定位 + 同步发光（登录 / 切换专精 / 动作条变动 / 光环增删 / 定时兜底）
function B.RefreshAll()
    if not B.db then return end
    -- 全局开关关闭：撤下所有覆盖层 + 停发光（定时巡检 / 事件驱动都会走到这里）
    if B.IsEnabled and not B.IsEnabled() then
        for _, e in pairs(entries) do
            if e.container then HideEntry(e) end
        end
        B.ApplyButtonGlows()
        return
    end
    for spellID, e in pairs(entries) do
        if e.container then
            if e.button then
                local ok = pcall(UpdateEntry, e, e.button)
                if not ok then
                    pcall(HideEntry, e)
                end
            else
                -- 尚未解析到按钮（未放置 / 未就绪）：保持停靠（容器已建好，只等挂靠）
                HideEntry(e)
            end
        end
    end
    B.ApplyButtonGlows()
end

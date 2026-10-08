-- easyButtonAuraByCDM.lua
-- Easy Button Aura by CDM
--
-- 把暴雪冷却管理器（Cooldown Manager，下称 CDM）里【已启用】的增益光环，手动绑定到
-- 暴雪原生动作条按钮上：在按钮上显示该光环的剩余时间与层数，可选「发光 / 反发光」提醒。
--
-- 本文件负责：命名空间 / 本地化 / 样式常量 / CDM 增益扫描 / 动作条按钮解析 / 绑定存档 / 事件驱动。
-- 渲染见 AuraDisplay.lua，设置界面见 Options.lua。
--
-- 与上游 ActionbarEnhanced/Manual.lua 的关键差异（2026-10-08 用户指定）：
--   · 绝不隐藏 / 移动 CDM 的原有显示。CDM 只被【只读】使用（取已启用增益列表 +
--     判断光环当前是否激活）；按钮上的倒计时 / 层数改用暴雪 12.1 的 AuraContainer 自绘，
--     不再 reparent CDM 已渲染对象，也不再把 CDM 图标移出屏幕。
--   · 零第三方依赖：不引入任何库（发光自绘）。
--   · 无 slash 命令；设置界面集成进暴雪自带插件设置（战斗中禁止修改）。
--   · 12.x secret 值红线：一律 issecretvalue 判定，不比较 secret 数值，外部数据 pcall 兜底。

EasyButtonAuraByCDM = EasyButtonAuraByCDM or {}
local B = EasyButtonAuraByCDM
B.ADDON_NAME = ...

-- =========================================================
-- 本地化（自维护纯 Lua 表，不引入本地化库）
-- 仅 enUS（默认 / 回退）+ zhCN + zhTW 三语
-- =========================================================
local LOCALES = {
    enUS = {
        SPEC_LABEL        = "Current Specialization",
        SPEC_UNKNOWN      = "Unknown",
        PAGE_DESC         = "Bind auras from Blizzard's Cooldown Manager to action bar buttons. The Cooldown Manager display itself is left untouched.",
        NO_AURAS          = "No auras found. Enable buffs in Blizzard's Cooldown Manager (Buffs) first, then reopen this page.",
        COL_BIND          = "Bind",
        BTN_SELF          = "Self",
        BTN_SELF_TIP      = "Bind to this aura's own spell.",
        POS_DEFAULT       = "Default",
        POS_UP            = "Up",
        POS_DOWN          = "Down",
        POS_LEFT          = "Left",
        POS_RIGHT         = "Right",
        POS_NONE          = "None",
        TIME_FMT          = "Time: %s",
        STACK_FMT         = "Stacks: %s",
        GLOW              = "Glow",
        GLOW_TIP          = "Glow the button while the aura is active.",
        INVERSE           = "Missing",
        INVERSE_TIP       = "Glow the button red while the aura is missing.",
        ERR_INVALID       = "Spell not found",
        STATUS_NOT_ON_BAR = "not on action bars",
        COMBAT_LOCKED     = "Settings cannot be changed during combat.",
    },
    zhCN = {
        SPEC_LABEL        = "当前专精",
        SPEC_UNKNOWN      = "未知",
        PAGE_DESC         = "把暴雪冷却管理器中的增益光环手动绑定到动作条按钮。冷却管理器本身的显示保持原样。",
        NO_AURAS          = "未找到可绑定的光环。请先在暴雪冷却管理器的「增益」里启用要追踪的光环，然后重新打开本页面。",
        COL_BIND          = "绑定",
        BTN_SELF          = "自身",
        BTN_SELF_TIP      = "绑定到该光环自身的法术。",
        POS_DEFAULT       = "默认",
        POS_UP            = "上",
        POS_DOWN          = "下",
        POS_LEFT          = "左",
        POS_RIGHT         = "右",
        POS_NONE          = "无",
        TIME_FMT          = "时间：%s",
        STACK_FMT         = "层数：%s",
        GLOW              = "发光",
        GLOW_TIP          = "光环存在时按钮发光。",
        INVERSE           = "反发光",
        INVERSE_TIP       = "光环缺失时按钮亮红光。",
        ERR_INVALID       = "未找到该法术",
        STATUS_NOT_ON_BAR = "不在动作条上",
        COMBAT_LOCKED     = "战斗中无法修改设置。",
    },
    zhTW = {
        SPEC_LABEL        = "目前專精",
        SPEC_UNKNOWN      = "未知",
        PAGE_DESC         = "把暴雪冷卻管理器中的增益光環手動綁定到快捷列按鈕。冷卻管理器本身的顯示維持原樣。",
        NO_AURAS          = "找不到可綁定的光環。請先在暴雪冷卻管理器的「增益」中啟用要追蹤的光環，然後重新開啟本頁面。",
        COL_BIND          = "綁定",
        BTN_SELF          = "自身",
        BTN_SELF_TIP      = "綁定到該光環本身的法術。",
        POS_DEFAULT       = "預設",
        POS_UP            = "上",
        POS_DOWN          = "下",
        POS_LEFT          = "左",
        POS_RIGHT         = "右",
        POS_NONE          = "無",
        TIME_FMT          = "時間：%s",
        STACK_FMT         = "堆疊：%s",
        GLOW              = "發光",
        GLOW_TIP          = "光環存在時按鈕發光。",
        INVERSE           = "反發光",
        INVERSE_TIP       = "光環缺失時按鈕亮紅光。",
        ERR_INVALID       = "找不到該法術",
        STATUS_NOT_ON_BAR = "不在快捷列上",
        COMBAT_LOCKED     = "戰鬥中無法修改設定。",
    },
}

local activeLocale = LOCALES[GetLocale()] or LOCALES.enUS

local function L(key)
    local v = activeLocale[key]
    if v == nil then v = LOCALES.enUS[key] end
    return v
end
B.L = L

-- =========================================================
-- 样式常量（时间 / 层数 / 发光的字体与颜色；画面风格集中在此）
-- =========================================================
B.Style = {
    FONT               = STANDARD_TEXT_FONT,
    FONT_SIZE          = 16,
    OUTLINE            = "THICKOUTLINE",
    TIME_COLOR         = { 1.00, 1.00, 0.00 },                       -- 倒计时：#FFFF00
    STACK_COLOR        = { 0x3F / 255, 0xC7 / 255, 0xEB / 255 },     -- 层数：#3FC7EB
    GLOW_COLOR         = { 0x16 / 255, 0xF2 / 255, 0xFA / 255, 1 },  -- 发光（光环存在）：#16F2FA 青色
    INVERSE_GLOW_COLOR = { 1.00, 0.00, 0.00, 1 },                    -- 反发光（光环缺失）：#FF0000 亮红
}

-- 时间 / 层数位置：存盘用规范化键（显示时本地化），顺序即循环顺序
B.POS_KEYS = { "default", "up", "down", "left", "right", "none" }
local POS_LABELS = {
    default = "POS_DEFAULT", up = "POS_UP", down = "POS_DOWN",
    left = "POS_LEFT", right = "POS_RIGHT", none = "POS_NONE",
}
function B.PosLabel(key)
    return L(POS_LABELS[key] or "POS_DEFAULT")
end

-- =========================================================
-- Secret Value 安全工具（12.x 红线）
-- =========================================================
-- 12.1+ 的 secret 值类型可能是 number / boolean / string 等，不能靠 type() 预判，
-- 统一用 issecretvalue 识别；pcall 兜底 nil 等异常输入。
local function IsSecret(v)
    local ok, res = pcall(function() return issecretvalue and issecretvalue(v) end)
    return ok and res
end
B.IsSecret = IsSecret

-- 安全读取普通布尔：secret / nil / 非 boolean 一律返回 nil（= 无法判定）
local function ReadBool(v)
    if v == nil or IsSecret(v) then return nil end
    if type(v) ~= "boolean" then return nil end
    return v
end

-- 判断 CDM item frame 的光环当前是否激活（供发光 / 反发光）。
-- 优先 IsActive()：暴雪特权代码消费 secret 光环数据后落盘的【明文布尔】（战斗中可读）。
-- 回退 IsShown()（普通 Frame 状态，pcall 兜底）。两者都无法判定时返回 nil。
local function IsItemActive(item)
    if not item then return nil end
    if item.IsActive then
        local ok, active = pcall(item.IsActive, item)
        if ok then
            local v = ReadBool(active)
            if v ~= nil then return v end
        end
    end
    local ok2, shown = pcall(function() return item:IsShown() end)
    if ok2 then
        local v = ReadBool(shown)
        if v ~= nil then return v end
    end
    return nil
end
B.IsItemActive = IsItemActive

-- =========================================================
-- CDM 扫描：取「已启用」的增益（= CDM 当前为其创建了 item frame 的条目）
-- 数据源：4 个查看器的当前活动帧。CDM 只为玩家在冷却管理器里实际启用追踪的条目建帧，
-- 因此「帧里出现的」=「已启用的」。spellID 经 GetCooldownViewerCooldownInfo 解析；
-- 名称 / 图标取自 C_Spell.GetSpellInfo（不读单位光环数据）。
-- =========================================================
local VIEWER_NAMES = { "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

-- 「增益光环」类查看器：可绑定列表只收录这两个（排除主冷却 / 功能冷却技能）
local AURA_VIEWERS = { BuffIconCooldownViewer = true, BuffBarCooldownViewer = true }

-- 运行时：CDM 已启用的增益（每次重新扫描重建）
-- spellID -> { spellID, name, icon, ids = { 候选 spellID... } }
B.knownBuffs = {}

-- 从 info 解析主 spellID：linkedSpellIDs[1] > overrideSpellID > spellID
local function ResolveSpellID(info)
    if not info then return nil end
    local linked = info.linkedSpellIDs and info.linkedSpellIDs[1]
    if linked and linked > 0 and not IsSecret(linked) then return linked end
    if info.overrideSpellID and info.overrideSpellID > 0 and not IsSecret(info.overrideSpellID) then return info.overrideSpellID end
    if info.spellID and info.spellID > 0 and not IsSecret(info.spellID) then return info.spellID end
    return nil
end

-- 收集 info 里的全部候选 spellID（去重）。
-- 12.1+ 天赋改名场景下光环名与技能名不一致（光环「烈焰震击」vs 按钮「流电炽焰」），
-- 只记一个 ID 会导致按钮匹配失败，故全部候选都要留。
local function CollectItemSpellIDs(info)
    local seen, result = {}, {}
    local function add(id)
        if id and id > 0 and not IsSecret(id) and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end
    if not info then return result end
    add(info.spellID)
    add(info.overrideSpellID)
    add(info.overrideTooltipSpellID)
    add(info.linkedSpellID)
    if info.linkedSpellIDs then
        for _, id in ipairs(info.linkedSpellIDs) do add(id) end
    end
    return result
end

-- 写入 knownBuffs（重复出现时只刷新名称 / 图标 / 候选表）
local function RegisterBuff(spellID, ids)
    if not spellID or IsSecret(spellID) then return end
    local okInfo, spellInfo = pcall(C_Spell.GetSpellInfo, spellID)
    if not okInfo or not spellInfo or not spellInfo.name then return end

    local b = B.knownBuffs[spellID]
    if not b then
        b = { spellID = spellID, name = spellInfo.name, icon = spellInfo.iconID }
        B.knownBuffs[spellID] = b
    else
        b.name = spellInfo.name
        b.icon = spellInfo.iconID or b.icon
    end
    b.ids = ids or b.ids
end

-- 取查看器的当前活动帧。
-- 优先 itemFramePool:EnumerateActive（= 正在显示的 active 帧，拖动 CDM 时不会瞬间变空）；
-- 仅在无该接口时兜底 GetItemFrames。
local function GetViewerFrames(viewer)
    if not viewer then return nil end
    if viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
        local ok, iter = pcall(viewer.itemFramePool.EnumerateActive, viewer.itemFramePool)
        if ok and iter then
            local t = {}
            for f in iter do t[#t + 1] = f end
            return t
        end
    end
    if viewer.GetItemFrames then
        local ok, frames = pcall(viewer.GetItemFrames, viewer)
        if ok and frames then return frames end
    end
    return nil
end

local function FrameCooldownID(frame)
    if not frame then return nil end
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then
        cdID = frame.cooldownInfo.cooldownID
    end
    if not cdID and frame.GetCooldownID then
        local ok, id = pcall(frame.GetCooldownID, frame)
        if ok then cdID = id end
    end
    return cdID
end

-- 记下某个 CDM item frame 对应的候选 spellID（我们自己写的非 secret 字段）
-- 并钩住它的 RefreshData：暴雪驱动刷新时（战斗中照常触发）即时同步该增益的发光状态。
local function HookViewerItem(item)
    if not item or item.__EBACHooked then return end
    item.__EBACHooked = true
    hooksecurefunc(item, "RefreshData", function()
        if item.__EBACSpellID and B.OnCdmItemRefreshed then
            B.OnCdmItemRefreshed(item.__EBACSpellID, item)
        end
    end)
end

local function ScanViewerFrames()
    local total = 0
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local viewer = _G[viewerName]
        local frames = GetViewerFrames(viewer)
        if frames then
            for _, f in ipairs(frames) do
                total = total + 1
                local cdID = FrameCooldownID(f)
                if cdID then
                    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if ok and info then
                        local spellID = ResolveSpellID(info)
                        if spellID and not IsSecret(spellID) then
                            local ids = CollectItemSpellIDs(info)
                            if AURA_VIEWERS[viewerName] then
                                RegisterBuff(spellID, ids)
                            end
                            f.__EBACSpellID = spellID
                            f.__EBACSpellIDs = ids
                            HookViewerItem(f)
                        end
                    end
                end
            end
        end
    end
    return total
end

-- 当前活动帧里 spellID 集合的签名（排序后拼接）：用于检测 CDM 里启用 / 禁用条目，
-- 只在签名变化时重扫，平稳游戏时开销可控。
function B.GetActiveViewerSignature()
    local ids = {}
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local frames = GetViewerFrames(_G[viewerName])
        if frames then
            for _, f in ipairs(frames) do
                local cdID = FrameCooldownID(f)
                if cdID then
                    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if ok and info then
                        local spellID = ResolveSpellID(info)
                        if spellID and not IsSecret(spellID) then
                            ids[#ids + 1] = spellID
                        end
                    end
                end
            end
        end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- 实时查找当前正在显示该 spellID 的 CDM item frame。
-- 不使用静态缓存：CDM 会把同一帧对象复用于别的光环，静态引用会失效。
-- 匹配我们写在帧上的非 secret 字段，绝不读 secret 的 frame.auraSpellID。
function B.FindFrameForSpell(spellID)
    if not spellID then return nil end
    for _, viewerName in ipairs(VIEWER_NAMES) do
        local frames = GetViewerFrames(_G[viewerName])
        if frames then
            for _, f in ipairs(frames) do
                if f.__EBACSpellID == spellID then return f end
                local ids = f.__EBACSpellIDs
                if ids then
                    for _, id in ipairs(ids) do
                        if id == spellID then return f end
                    end
                end
            end
        end
    end
    return nil
end

-- 增量 hook：CDM 新帧出现时实时登记（覆盖加载后 CDM 布局变化的情况）
local hookedViewers = {}
local function EnsureHooks()
    for _, name in ipairs(VIEWER_NAMES) do
        if not hookedViewers[name] then
            local v = _G[name]
            -- ⚠️ 必须捕获 name 的副本：for 循环变量是所有闭包共享的同一 upvalue，
            --    循环结束后 name = 最后一个 viewer，直接引用会让所有 viewer 都按最后一个判断。
            local viewerName = name
            if v and v.OnAcquireItemFrame then
                hooksecurefunc(v, "OnAcquireItemFrame", function(_, f)
                    local cdID = FrameCooldownID(f)
                    if not cdID then return end
                    local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                    if not ok or not info then return end
                    local spellID = ResolveSpellID(info)
                    if not spellID or IsSecret(spellID) then return end
                    local ids = CollectItemSpellIDs(info)
                    if AURA_VIEWERS[viewerName] then
                        RegisterBuff(spellID, ids)
                    end
                    f.__EBACSpellID = spellID
                    f.__EBACSpellIDs = ids
                    HookViewerItem(f)
                    if B.OnCdmItemRefreshed then B.OnCdmItemRefreshed(spellID, f) end
                    B.NotifyBuffsChanged()
                end)
                hookedViewers[name] = true
            end
        end
    end
end

-- 主入口：重新扫描 CDM 已启用的增益。
-- 换新表扫描，扫到 0 帧时保留旧表，避免 CDM 帧重建的过渡态把列表清空。
function B.Rescan()
    if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then
        B.NotifyBuffsChanged()
        return
    end
    local old = B.knownBuffs
    B.knownBuffs = {}
    local total = ScanViewerFrames()
    if total == 0 and next(old) then
        B.knownBuffs = old
    end
    if B.RefreshAll then B.RefreshAll() end
    B.NotifyBuffsChanged()
end

-- =========================================================
-- 原生动作条按钮解析
-- 绑定不再记具体槽位：运行时扫动作条按「目标技能」定位，跟随变形 / 翻页 / 槽位变化。
-- =========================================================
local BAR_BAR_GROUPS = {
    { prefix = "ActionButton" },
    { prefix = "MultiBarBottomLeftButton" },
    { prefix = "MultiBarBottomRightButton" },
    { prefix = "MultiBarLeftButton" },
    { prefix = "MultiBarRightButton" },
    { prefix = "MultiBar5Button" },
    { prefix = "MultiBar6Button" },
    { prefix = "MultiBar7Button" },
}

-- 枚举所有原生动作条按钮的全局名
function B.GetActionBarButtonNames()
    local names, seen = {}, {}
    local maxBtns = NUM_ACTIONBAR_BUTTONS or 12

    local function addPrefix(prefix)
        for i = 1, maxBtns do
            local g = prefix .. i
            if _G[g] and not seen[g] then
                seen[g] = true
                names[#names + 1] = g
            end
        end
    end

    if ActionButtonUtil and ActionButtonUtil.ActionBarButtonNames then
        for _, prefix in ipairs(ActionButtonUtil.ActionBarButtonNames) do
            if type(prefix) == "string" then addPrefix(prefix) end
        end
    end

    -- 兜底：API 缺失 / 返回空时，枚举已知的原生动作条前缀（仅暴雪原生）
    if #names == 0 then
        for _, g in ipairs(BAR_BAR_GROUPS) do addPrefix(g.prefix) end
    end

    return names
end

-- 从按钮全局名取当前所载技能的 spellID（spell / 单法术宏均可）。
-- 只认暴雪原生动作条按钮；验证 id 是真实法术，避免宏 id 误匹配。
local function GetButtonSpellID(buttonName)
    local btn = _G[buttonName]
    if not btn or not btn.action then return nil end
    local ok, atype, id = pcall(GetActionInfo, btn.action)
    if not ok or not atype or not id then return nil end
    if atype ~= "spell" and atype ~= "macro" then return nil end
    if IsSecret(id) then return nil end
    local okInfo, info = pcall(C_Spell.GetSpellInfo, id)
    if okInfo and info and info.name then return id end
    return nil
end

-- 一次性扫描所有动作条，建立 spellID -> 按钮全局名 映射（首个匹配为准）
function B.BuildSpellButtonMap()
    local map = {}
    for _, name in ipairs(B.GetActionBarButtonNames()) do
        local sid = GetButtonSpellID(name)
        if sid and not map[sid] then map[sid] = name end
    end
    return map
end

-- =========================================================
-- 技能名 / ID 解析与显示
-- =========================================================
function B.ParseSpellInput(text)
    text = strtrim(tostring(text or ""))
    if text == "" then return nil end
    local num = tonumber(text)
    if num then
        local ok, info = pcall(C_Spell.GetSpellInfo, num)
        if ok and info and info.name then return num end
        return nil
    end
    local okID, id = pcall(function() return C_Spell.GetSpellID(text) end)
    if okID and id and id > 0 then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and info and info.name then return id end
    end
    local ok2, info2 = pcall(C_Spell.GetSpellInfo, text)
    if ok2 and info2 and info2.name then
        return info2.spellID or info2.id
    end
    return nil
end

function B.GetSpellDisplayName(spellID)
    if not spellID then return "" end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and info and info.name then return info.name end
    return tostring(spellID)
end

-- =========================================================
-- 存档：按专精存储
-- EasyButtonAuraByCDMDB.specs[specID] = { bindings = { [auraSpellID] = cfg } }
--   cfg = { bindSpell = <目标技能 spellID，nil = 未绑定>,
--           timePos = "default|up|down|left|right|none",
--           stackPos = 同上, glow = bool, inverseGlow = bool }
-- specID 取自 GetSpecializationInfo(GetSpecialization())，拿不到时用 0（通用槽）。
-- =========================================================
local function GetCurrentSpecID()
    local ok, specID = pcall(function()
        local idx = GetSpecialization()
        if not idx or idx == 0 then return nil end
        return (select(1, GetSpecializationInfo(idx)))
    end)
    if ok and specID then return specID end
    return 0
end

function B.InitStorage()
    EasyButtonAuraByCDMDB = EasyButtonAuraByCDMDB or {}
    if not EasyButtonAuraByCDMDB.specs then
        EasyButtonAuraByCDMDB.specs = { [0] = { bindings = {} } }
    end
end

-- 切换到「当前专精」配置槽：B.db 指向 specs[specID] 子表
function B.SelectSpec(specID)
    B.InitStorage()
    specID = specID or GetCurrentSpecID()
    local specs = EasyButtonAuraByCDMDB.specs
    if not specs[specID] then
        specs[specID] = { bindings = {} }
    end
    specs[specID].bindings = specs[specID].bindings or {}
    B.db = specs[specID]
    B.currentSpecID = specID
    B.NotifyBindingsChanged()
end

function B.GetCurrentSpecName()
    local ok, name = pcall(function()
        local idx = GetSpecialization()
        if not idx or idx == 0 then return nil end
        return (select(2, GetSpecializationInfo(idx)))
    end)
    if ok and name then return name end
    return L("SPEC_UNKNOWN")
end

function B.GetBindings()
    if B.db and B.db.bindings then return B.db.bindings end
    return {}
end

function B.GetBinding(spellID)
    if not spellID or not B.db or not B.db.bindings then return nil end
    local cfg = B.db.bindings[spellID]
    if type(cfg) == "table" then return cfg end
    return nil
end

function B.IsBound(spellID)
    local cfg = B.GetBinding(spellID)
    return (cfg and cfg.bindSpell ~= nil) and true or false
end

-- 内部：写一条绑定配置（不存在则新建）
local function WriteBinding(spellID, mutate)
    if not spellID or not B.db then return end
    B.db.bindings = B.db.bindings or {}
    local cfg = B.db.bindings[spellID]
    if type(cfg) ~= "table" then cfg = {} end
    mutate(cfg)
    B.db.bindings[spellID] = cfg
end

-- 绑定某 CDM 增益到「目标技能」（targetSpellID = nil 表示解绑，保留其它显示选项）
function B.SetBoundSpell(spellID, targetSpellID)
    if not spellID or not B.db then return end
    WriteBinding(spellID, function(cfg) cfg.bindSpell = targetSpellID end)
    B.NotifyBindingsChanged()
end

-- 设置某绑定的显示选项（timePos / stackPos / glow / inverseGlow）
function B.SetBindingOption(spellID, key, val)
    if not spellID or not key or not B.db then return end
    WriteBinding(spellID, function(cfg) cfg[key] = val end)
    B.NotifyBindingsChanged()
end

-- 读绑定配置的显示项（缺省值集中在此）
function B.GetDisplayOptions(spellID)
    local cfg = B.GetBinding(spellID) or {}
    local glowOn = cfg.glow == true
    local inverseOn = cfg.inverseGlow == true
    return cfg.timePos or "default", cfg.stackPos or "default", glowOn, inverseOn
end

-- =========================================================
-- 变更通知（AuraDisplay / Options 各自实现对应入口，避免被相互覆盖）
-- =========================================================
function B.NotifyBuffsChanged()
    if B.RefreshPanel then B.RefreshPanel() end
end

function B.NotifyBindingsChanged()
    if B.RebuildEntries then B.RebuildEntries() end
    if B.RefreshPanel then B.RefreshPanel() end
end

-- 防抖全量刷新（渲染层）
local refreshTimer
function B.ScheduleRefresh(delay)
    if refreshTimer then refreshTimer:Cancel() end
    refreshTimer = C_Timer.NewTimer(delay or 0.2, function()
        refreshTimer = nil
        if B.RefreshAll then B.RefreshAll() end
    end)
end

-- =========================================================
-- 事件驱动
-- =========================================================
-- 动作条 / 形态 / 页面 / 载具 / 御龙术切换：这些场景未必触发 ACTIONBAR_SLOT_CHANGED，
-- 统一监听，驱动按钮重解析与覆盖层重定位。
local actionbarEvents = {
    ACTIONBAR_SLOT_CHANGED       = true,
    ACTIONBAR_PAGE_CHANGED       = true,
    UPDATE_BONUS_ACTIONBAR       = true,
    UPDATE_OVERRIDE_ACTIONBAR    = true,
    UPDATE_SHAPESHIFT_FORM       = true,
    UPDATE_POSSESS_BAR           = true,
    UPDATE_MULTI_CAST_ACTIONBAR  = true,
    PLAYER_TALENT_UPDATE         = true,
}

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
for ev in pairs(actionbarEvents) do eventFrame:RegisterEvent(ev) end

eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        B.SelectSpec()
        EnsureHooks()
        C_Timer.After(0.5, function() EnsureHooks(); B.Rescan() end)
        C_Timer.After(2.0, function() EnsureHooks(); B.Rescan() end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        B.SelectSpec()
        C_Timer.After(0.5, function() EnsureHooks(); B.Rescan() end)
    elseif event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
        B.SelectSpec()
    elseif event == "UNIT_AURA" then
        -- 光环增删 → 防抖刷新（发光 / 反发光即时纠正）
        B.ScheduleRefresh(0.2)
    elseif actionbarEvents[event] then
        -- 延迟 0.1s：等动作条布局完成后再读按钮坐标 / 重算匹配
        C_Timer.After(0.1, function()
            B.NotifyBindingsChanged()
            if B.RefreshAll then B.RefreshAll() end
        end)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- 脱战：清掉战斗中建容器失败的限制，重建 + 刷新
        if B.ResetInitFailed then B.ResetInitFailed() end
        B.NotifyBindingsChanged()
        if B.RefreshAll then B.RefreshAll() end
        if B.OnCombatChanged then B.OnCombatChanged(false) end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if B.OnCombatChanged then B.OnCombatChanged(true) end
    end
end)

-- 低频签名巡检：CDM 里启用 / 禁用条目、或活动帧集合变化时重扫。
-- 仅在「有绑定」或「设置界面打开」时运行（无消费者时零开销）。
local lastSignature
C_Timer.NewTicker(1.0, function()
    if not next(B.GetBindings()) and not B.panelShown then return end
    local sig = B.GetActiveViewerSignature()
    if sig ~= lastSignature then
        lastSignature = sig
        B.Rescan()
    end
end)

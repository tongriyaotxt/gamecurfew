<#
  gamecurfew.ps1  —  家长控制：限制《我的世界》《迷你世界》及相关网络内容

  设计目标：隐蔽（无窗口/无托盘/无安装记录）、宏观可调（改 settings.json 即生效）、
            抗常见移除手段（进程被杀自动回来、hosts 被回滚自动重写、文件被删自动恢复）。

  在目标电脑上运行 Windows PowerShell（需要管理员的步骤会自动弹 UAC 提权）：
      .\gamecurfew.ps1                              # 安装（默认监控当前账户，适合家长孩子共用账户）
      .\gamecurfew.ps1 -SetPassword                 # 设置家长密码（共用账户时强烈建议）
      .\gamecurfew.ps1 -Unlock                      # 用密码临时解锁（交互式，密码不落盘）
      .\gamecurfew.ps1 -Lock                        # 立刻恢复拦截
      .\gamecurfew.ps1 -SelfTest                    # 自检：看时间窗、关键词误报（不改系统，无需管理员）
      .\gamecurfew.ps1 -TestTitle "我的世界_百度搜索"   # 单条测试匹配（无需管理员）
      .\gamecurfew.ps1 -Report                      # 看拦截日志汇总（无需管理员）
      .\gamecurfew.ps1 -SetWindow "Friday 12:00","Saturday 02:00"   # 改可玩时段
      .\gamecurfew.ps1 -Uninstall                   # 彻底卸载

  另一种解锁通路（不需要管理员权限，避开 UAC）：
      setx GAMECURFEW_PARENT "你的密码"              # 程序读到后校验，并立即删除该环境变量

  默认允许时段：周五 12:00 → 周六 02:00（其余时间拦截）。
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$SelfTest,
    [switch]$Report,
    [string]$TestTitle,
    [string]$ChildUser = '',
    [string[]]$SetWindow,
    [switch]$Pause,
    [int]$Minutes = 120,
    [switch]$Resume,
    [switch]$SetPassword,
    [switch]$Unlock,
    [switch]$Lock,
    [switch]$Wizard,
    [switch]$Menu,
    [switch]$ToggleMode,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# ============================== 常量 ==============================
$Root      = Join-Path $env:ProgramData 'SystemHealth'
$CfgPath   = Join-Path $Root 'settings.json'
$LogPath   = Join-Path $Root 'trace.log'
$CorePath  = Join-Path $Root 'core.ps1'
$AdminPath = Join-Path $Root 'admin.ps1'
$VbsCore   = Join-Path $Root 'runc.vbs'
$VbsAdmin  = Join-Path $Root 'runa.vbs'
$BakDir    = Join-Path $Root 'cache'
$TaskCore  = 'SystemHealthMonitor'
$TaskAdmin = 'SystemHealthService'
$HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$MarkBegin = '# == SYS-HEALTH BEGIN =='
$MarkEnd   = '# == SYS-HEALTH END =='
$PsExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ============================== 默认配置 ==============================
function New-DefaultConfig {
    [ordered]@{
        enabled        = $true
        mode           = 'enforce'         # enforce = 装完立即拦（默认）；dryrun = 只记录不拦
        allowedWindow  = [ordered]@{
            startDay  = 'Friday'
            startTime = '12:00'
            endDay    = 'Saturday'
            endTime   = '02:00'
        }
        action         = 'CloseWindow'     # CloseWindow | KillProcess | LogOnly
        pauseUntil     = ''                # 临时暂停拦截（家长解锁或 -Pause 时写入）；格式 yyyy-MM-dd HH:mm:ss
        weakThreshold  = 2                 # 弱关键词需要同时命中几个才拦（防止 mc 之类误报）
        # --- 家长密码：用来在共用账户下区分"家长在用"和"孩子在用" ---
        # 只存加盐哈希，不存明文。解锁方式见 README 第〇节：
        #   1) .\gamecurfew.ps1 -Unlock       交互式输入密码（推荐，密码不落盘、不进历史）
        #   2) 环境变量 GAMECURFEW_PARENT     家长设完即被读取并立刻清除（不需要管理员权限）
        parentSalt          = ''
        parentHash          = ''
        parentUnlockMinutes = 60           # 解锁后多久自动恢复拦截（忘了锁回来也没事）
        parentFailLimit     = 5            # 连续错几次就记一次告警日志
        # --- 行为密度门槛（默认关闭，保持"命中即拦"的简单思路）---
        # 设成 >0 才启用：同一关键词在 strikeWindowMinutes 分钟内出现这么多个「不同标题」才动手。
        windowStrikeLimit   = 0
        strikeWindowMinutes = 10
        hotMinutes          = 30
        exemptUsers    = @()               # 这些账户不监控（例如家长自己的账户）
        keywordsStrong = @(
            '我的世界', 'Minecraft', '迷你世界', '麦块',
            'mc.163.com', 'minecraft.net', '网易我的世界', '我的世界中国版',
            'Plain Craft Launcher', 'PCL2'
        )
        keywordsWeak   = @(
            'mc', '苦力怕', 'creeper', '红石', 'redstone', '史蒂夫', 'steve',
            '末影人', 'enderman', '鞘翅', '猪灵', '挖矿', '合成表', '附魔',
            '生存模式', '创造模式', '方块', '下界', '主世界', 'mcmod', 'mcbbs', 'minebbs'
        )
        domains        = @(
            'mc.163.com', 'minecraft.net', 'mojang.com', 'minecraftservices.com',
            'mini1.cn', 'mdownload.mini1.cn', 'mnweb.mini1.cn', 'app.mini1.cn',
            'image.mini1.cn', 'webpicture.mini1.cn',
            'mcmod.cn', 'minebbs.com', 'mcbbs.net', 'mc.res.netease.com', 'nie.res.netease.com'
        )
        processNames   = @(
            'miniworld.exe', 'miniworldbeta_pc.exe',
            'minecraftlauncher.exe', 'minecraft.windows.exe', 'minecraft.exe',
            'hmcl.exe', 'pcl.exe', 'pcl2.exe',
            'plain craft launcher 2.exe', 'plain craft launcher.exe'
        )
        # Java 版真正在跑的永远是 javaw.exe，所以必须靠路径与命令行特征识别，不能只拦启动器
        processPathMarkers    = @('mclDownload', '\.minecraft\', 'miniworld', 'minecraft')
        processCmdlineMarkers = @(
            'net.minecraft.client.main.Main',   # 所有启动器（官方/PCL/HMCL/网易）最终都跑这个主类，最可靠
            '--assetIndex',                     # MC Java 独有的参数
            'net.minecraft', 'mclDownload', '-DlauncherControlPort', 'minecraft'
        )
        logMaxMB       = 5
    }
}

# ============================== 公共函数 ==============================
function Write-LogLine {
    param([string]$Path, [hashtable]$Data)
    try {
        $Data['ts'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = ($Data | ConvertTo-Json -Compress)
        if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt 5MB)) {
            $keep = Get-Content -LiteralPath $Path -Tail 2000
            Set-Content -LiteralPath $Path -Value $keep -Encoding UTF8
        }
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    } catch { }
}

function Get-AllowedNow {
    param([object]$Window, [datetime]$Now)
    $sd = [int][System.DayOfWeek]::$($Window.startDay)
    $ed = [int][System.DayOfWeek]::$($Window.endDay)
    $st = [TimeSpan]::Parse($Window.startTime, $Invariant)
    $et = [TimeSpan]::Parse($Window.endTime, $Invariant)
    $dow = [int]$Now.DayOfWeek
    $back = ($dow - $sd + 7) % 7
    $start = $Now.Date.AddDays(-$back).Add($st)
    if ($start -gt $Now) { $start = $start.AddDays(-7) }
    $hours = ((($ed - $sd + 7) % 7) * 24) + ($et.TotalHours - $st.TotalHours)
    if ($hours -le 0) { $hours += 168 }
    return ($Now -lt $start.AddHours($hours))
}

function Get-Hit {
    param([string]$Text, [object]$Cfg)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ hit = $false; word = ''; lvl = '' } }
    foreach ($k in @($Cfg.keywordsStrong)) {
        if ($Text.IndexOf([string]$k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return @{ hit = $true; word = [string]$k; lvl = 'strong' }
        }
    }
    $hits = New-Object System.Collections.ArrayList
    foreach ($k in @($Cfg.keywordsWeak)) {
        $k = [string]$k
        if ($k -cmatch '^[\x20-\x7E]+$') {
            $pat = '(?i)(?<![a-z0-9])' + [regex]::Escape($k) + '(?![a-z0-9])'
            if ($Text -match $pat) { [void]$hits.Add($k) }
        } else {
            if ($Text.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$hits.Add($k) }
        }
    }
    $need = [int]$Cfg.weakThreshold
    if ($need -lt 1) { $need = 1 }
    if ($hits.Count -ge $need) {
        return @{ hit = $true; word = ($hits -join '+'); lvl = 'weak' }
    }
    return @{ hit = $false; word = ''; lvl = '' }
}

function Get-ChildAccount {
    # 已知系统账户名 + 知名 RID 后缀（-500 管理员 / -501 来宾 / -503 默认账户 / -504 WDAG）
    $sysNames  = @('WsiAccount', 'sshd', 'DefaultAccount', 'WDAGUtilityAccount',
                   'Administrator', 'Guest', 'Public', 'Default', 'Default User', 'All Users')
    $sysSuffix = @('-500', '-501', '-503', '-504')
    $cands = @()
    # 来源 1：已有用户配置文件（登录过的账户）
    foreach ($p in (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue)) {
        if (-not $p.LocalPath) { continue }
        if ($p.LocalPath -notmatch '\\Users\\') { continue }
        if ($p.Special) { continue }
        $name = Split-Path $p.LocalPath -Leaf
        if ($sysNames -contains $name) { continue }
        $sid = [string]$p.SID
        $isSys = $false
        foreach ($s in $sysSuffix) { if ($sid.EndsWith($s)) { $isSys = $true } }
        if ($isSys) { continue }
        $cands += $name
    }
    # 来源 2：本地账户 —— 补上"建好了但还从没登录过"的账户（只看配置文件会漏掉它，
    #         而家长完全可能先建好账户、还没让孩子登录就来装）
    try {
        foreach ($u in (Get-LocalUser -ErrorAction Stop)) {
            if (-not $u.Enabled) { continue }
            $name = [string]$u.Name
            if ($sysNames -contains $name) { continue }
            $sid = ''
            try { $sid = [string]$u.SID.Value } catch { }
            $isSys = $false
            foreach ($s in $sysSuffix) { if ($sid.EndsWith($s)) { $isSys = $true } }
            if ($isSys) { continue }
            $cands += $name
        }
    } catch { }
    return ($cands | Sort-Object -Unique)
}

# ============================== 核心监控（孩子会话内运行） ==============================
$CoreCode = @'
$ErrorActionPreference = 'SilentlyContinue'
$Root    = Join-Path $env:ProgramData 'SystemHealth'
$CfgPath = Join-Path $Root 'settings.json'
$LogPath = Join-Path $Root 'trace.log'

$mtx = New-Object System.Threading.Mutex($false, 'Local\SysHealthMon')
if (-not $mtx.WaitOne(0)) { exit 0 }

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinScan {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static List<string> Titles() {
    List<string> r = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (IsWindowVisible(h)) {
        StringBuilder sb = new StringBuilder(600);
        GetWindowTextW(h, sb, 600);
        if (sb.Length > 0) {
          uint pid; GetWindowThreadProcessId(h, out pid);
          r.Add(pid.ToString() + "\t" + h.ToInt64().ToString() + "\t" + sb.ToString());
        }
      }
      return true;
    }, IntPtr.Zero);
    return r;
  }
}
"@

function Get-LogPath { $LogPath }

function Write-LogLine {
    param([hashtable]$Data)
    try {
        $Data['ts'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = ($Data | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Get-AllowedNow {
    param([object]$Window, [datetime]$Now)
    $sd = [int][System.DayOfWeek]::$($Window.startDay)
    $ed = [int][System.DayOfWeek]::$($Window.endDay)
    $st = [TimeSpan]::Parse($Window.startTime, $Invariant)
    $et = [TimeSpan]::Parse($Window.endTime, $Invariant)
    $dow = [int]$Now.DayOfWeek
    $back = ($dow - $sd + 7) % 7
    $start = $Now.Date.AddDays(-$back).Add($st)
    if ($start -gt $Now) { $start = $start.AddDays(-7) }
    $hours = ((($ed - $sd + 7) % 7) * 24) + ($et.TotalHours - $st.TotalHours)
    if ($hours -le 0) { $hours += 168 }
    return ($Now -lt $start.AddHours($hours))
}

function Get-Hit {
    param([string]$Text, [object]$Cfg)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ hit = $false; word = ''; lvl = '' } }
    foreach ($k in @($Cfg.keywordsStrong)) {
        if ($Text.IndexOf([string]$k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return @{ hit = $true; word = [string]$k; lvl = 'strong' }
        }
    }
    $hits = New-Object System.Collections.ArrayList
    foreach ($k in @($Cfg.keywordsWeak)) {
        $k = [string]$k
        if ($k -cmatch '^[\x20-\x7E]+$') {
            $pat = '(?i)(?<![a-z0-9])' + [regex]::Escape($k) + '(?![a-z0-9])'
            if ($Text -match $pat) { [void]$hits.Add($k) }
        } else {
            if ($Text.IndexOf($k, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$hits.Add($k) }
        }
    }
    $need = [int]$Cfg.weakThreshold
    if ($need -lt 1) { $need = 1 }
    if ($hits.Count -ge $need) { return @{ hit = $true; word = ($hits -join '+'); lvl = 'weak' } }
    return @{ hit = $false; word = ''; lvl = '' }
}

$cfg = $null
$cfgAt = [datetime]::MinValue
$warnAt = [datetime]::MinValue
$hot = @{}        # 行为密度状态：关键词 -> @{ titles = 去重标题集合; last; hotUntil }
$parentUntil = [datetime]::MinValue   # 家长密码解锁到期时间（内存态）

while ($true) {
    if (((Get-Date) - $cfgAt).TotalSeconds -gt 15) {
        try {
            $cfg = Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cfgAt = Get-Date
        } catch {
            # 配置被删或损坏：沿用上一次的好配置继续跑，每 5 分钟记一次警告。
            # 文件本身由特权任务（admin.ps1）从 cache 恢复，约 5 分钟内自愈。
            if (((Get-Date) - $warnAt).TotalMinutes -gt 5) {
                Write-LogLine @{ ev = 'config-unreadable'; act = 'kept-last-good'; note = '配置无法读取，已沿用上次配置，等待特权任务恢复文件' }
                $warnAt = Get-Date
            }
        }
    }
    if ($null -ne $cfg -and $cfg.enabled) {
        $failLimit = [int]$cfg.parentFailLimit; if ($failLimit -lt 1) { $failLimit = 5 }

        # ---------- 环境变量通路：无论本轮是否跳过，都必须读取并清除 ----------
        # 漏洞修复：原来这段写在 if (-not $skip) 里，于是"暂停中/豁免中"时家长执行的
        # setx 永远不会被消费，密码明文就一直留在 HKCU\Environment。现在无条件执行。
        $envPwd = $null
        try {
            $envPwd = (Get-ItemProperty -Path 'HKCU:\Environment' -Name 'GAMECURFEW_PARENT' -ErrorAction Stop).GAMECURFEW_PARENT
        } catch { }
        if ($envPwd) {
            # 先数一下 15 分钟内失败了几次，防止拿环境变量当暴力猜测的通道
            $recentFail = 0
            try {
                $since = (Get-Date).AddMinutes(-15)
                if (Test-Path -LiteralPath $LogPath) {
                    foreach ($ln in (Get-Content -LiteralPath $LogPath -Tail 600 -Encoding UTF8)) {
                        if ($ln -notlike '*unlock-failed*') { continue }
                        try { $o = $ln | ConvertFrom-Json; if ([datetime]::Parse([string]$o.ts) -ge $since) { $recentFail++ } } catch { }
                    }
                }
            } catch { }
            if ($recentFail -ge $failLimit) {
                Remove-ItemProperty -Path 'HKCU:\Environment' -Name 'GAMECURFEW_PARENT' -ErrorAction SilentlyContinue
                Write-LogLine @{ ev = 'parent'; act = 'unlock-blocked'; n = $recentFail; note = '15 分钟内失败过多，已拒绝并清除环境变量' }
            } else {
                $okPwd = $false
                if ($cfg.parentHash -and $cfg.parentSalt) {
                    try {
                        $salt = [Convert]::FromBase64String([string]$cfg.parentSalt)
                        $want = [Convert]::FromBase64String([string]$cfg.parentHash)
                        $kdf  = New-Object System.Security.Cryptography.Rfc2898DeriveBytes([string]$envPwd, $salt, 200000)
                        $got  = $kdf.GetBytes(32); $kdf.Dispose()
                        if ($got.Length -eq $want.Length) {
                            $okPwd = $true
                            for ($bi = 0; $bi -lt $got.Length; $bi++) { if ($got[$bi] -ne $want[$bi]) { $okPwd = $false; break } }
                        }
                    } catch { $okPwd = $false }
                }
                # 无论成功失败都立刻删掉，不让密码明文长期躺在注册表里
                Remove-ItemProperty -Path 'HKCU:\Environment' -Name 'GAMECURFEW_PARENT' -ErrorAction SilentlyContinue
                if ($okPwd) {
                    $hm = [int]$cfg.parentUnlockMinutes; if ($hm -lt 1) { $hm = 60 }
                    $parentUntil = (Get-Date).AddMinutes($hm)
                    Write-LogLine @{ ev = 'parent'; act = 'unlock-env'; until = $parentUntil.ToString('yyyy-MM-dd HH:mm:ss') }
                } else {
                    Write-LogLine @{ ev = 'parent'; act = 'unlock-failed'; src = 'env' }
                }
            }
        }

        # ---------- 判断本轮要不要跳过 ----------
        $exempt = @($cfg.exemptUsers) | Where-Object { $_ }
        $skip = $false
        foreach ($u in $exempt) { if ($env:USERNAME -ieq [string]$u) { $skip = $true } }
        # 家长暂停：-Pause / -Unlock 都会写这个字段
        if (-not $skip -and $cfg.pauseUntil) {
            try { if ([datetime]::Parse([string]$cfg.pauseUntil) -gt (Get-Date)) { $skip = $true } } catch { }
        }
        # 环境变量解锁（内存态，进程重启即失效，到期自动恢复）
        if (-not $skip -and $parentUntil -gt (Get-Date)) { $skip = $true }

        if (-not $skip) {
            $allowed = Get-AllowedNow -Window $cfg.allowedWindow -Now (Get-Date)
            if (-not $allowed) {
                foreach ($row in [WinScan]::Titles()) {
                    $parts = $row.Split("`t")
                    if ($parts.Count -lt 3) { continue }
                    $wpid = [int]$parts[0]
                    if ($wpid -eq $PID) { continue }
                    $hwnd = [IntPtr][int64]$parts[1]
                    $title = $parts[2]
                    $h = Get-Hit -Text $title -Cfg $cfg
                    if (-not $h.hit) { continue }

                    $pname = ''
                    try { $pname = (Get-Process -Id $wpid -ErrorAction Stop).ProcessName } catch { }

                    # ---------- 行为密度门槛（不区分"谁在用"） ----------
                    # 为什么需要：家长和孩子共用一个账户时无法按账户区分人。但区分人本身是伪需求——
                    # 改判"偶尔瞥一眼"还是"连续刷"：家长查一次资料不该被拦，孩子连刷才拦。
                    #
                    # 关键细节：计数必须按「不同窗口标题」去重。扫描是每 0.9 秒一轮，
                    # 同一个页面会被反复扫到，不去重的话一秒就爆阈值，门槛等于不存在。
                    $kw  = [string]$h.word
                    $now = Get-Date
                    # 老配置文件里没有这个字段时，回退到 0 = 不做门槛，保持"命中即拦"的原始行为
                    $limit  = if ($null -eq $cfg.windowStrikeLimit) { 0 } else { [int]$cfg.windowStrikeLimit }
                    $winMin = [int]$cfg.strikeWindowMinutes; if ($winMin -lt 1) { $winMin = 10 }
                    $hotMin = [int]$cfg.hotMinutes;           if ($hotMin -lt 1) { $hotMin = 30 }

                    if (-not $hot.ContainsKey($kw)) {
                        $hot[$kw] = @{ titles = (New-Object 'System.Collections.Generic.HashSet[string]'); last = $now; hotUntil = [datetime]::MinValue }
                    }
                    $st = $hot[$kw]
                    if (($now - $st.last).TotalMinutes -gt $winMin) { $st.titles.Clear() }
                    $st.last = $now

                    $over = $false
                    if ($st.hotUntil -gt $now) {
                        # 已"热"：一律直接拦，并且**滑动续期**。
                        # 必须续期 —— 否则孩子只要打开一个标题不变的长视频，拦满 hotMinutes
                        # 后热状态就过期，而标题一直不变又永远凑不满"不同标题"数，
                        # 结果看长视频反而成了绕过方法（仿真时实测到 120 次只拦到 30 次）。
                        $over = $true
                        $st.hotUntil = $now.AddMinutes($hotMin)
                    } elseif ($limit -le 0) {
                        $over = $true          # 配成 0 = 取消门槛，立即拦
                    } else {
                        [void]$st.titles.Add($title)
                        if ($st.titles.Count -ge $limit) {
                            $over = $true
                            $st.hotUntil = $now.AddMinutes($hotMin)
                            $st.titles.Clear()
                        }
                    }

                    $act = [string]$cfg.action
                    if (-not $over) {
                        # 没到阈值：只记录，不动手。家长能在 -Report 里看到这些"擦边"记录。
                        Write-LogLine @{
                            ev = 'window'; act = 'strike'; mode = [string]$cfg.mode
                            proc = $pname; kw = $kw; lvl = $h.lvl; n = $st.titles.Count; lim = $limit; title = $title
                        }
                        Start-Sleep -Milliseconds 250
                        continue
                    }

                    $done = 'logged'
                    if ([string]$cfg.mode -eq 'enforce') {
                        if ($act -eq 'CloseWindow') {
                            [void][WinScan]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
                            $done = 'closed'
                        } elseif ($act -eq 'KillProcess') {
                            try { Stop-Process -Id $wpid -Force -ErrorAction Stop; $done = 'killed' } catch { $done = 'kill-failed' }
                        }
                    }
                    Write-LogLine @{
                        ev = 'window'; act = $done; mode = [string]$cfg.mode; hot = $true
                        proc = $pname; kw = $kw; lvl = $h.lvl; title = $title
                    }
                    Start-Sleep -Milliseconds 250
                }
            }
        }
    }
    Start-Sleep -Milliseconds 900
}
'@

# ============================== 特权模块（SYSTEM 运行） ==============================
$AdminCode = @'
$ErrorActionPreference = 'SilentlyContinue'
$Root      = Join-Path $env:ProgramData 'SystemHealth'
$CfgPath   = Join-Path $Root 'settings.json'
$LogPath   = Join-Path $Root 'trace.log'
$CorePath  = Join-Path $Root 'core.ps1'
$AdminPath = Join-Path $Root 'admin.ps1'
$BakDir    = Join-Path $Root 'cache'
$HostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$MarkBegin = '# == SYS-HEALTH BEGIN =='
$MarkEnd   = '# == SYS-HEALTH END =='

function Write-LogLine {
    param([hashtable]$Data)
    try {
        $Data['ts'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = ($Data | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch { }
}

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Get-AllowedNow {
    param([object]$Window, [datetime]$Now)
    $sd = [int][System.DayOfWeek]::$($Window.startDay)
    $ed = [int][System.DayOfWeek]::$($Window.endDay)
    $st = [TimeSpan]::Parse($Window.startTime, $Invariant)
    $et = [TimeSpan]::Parse($Window.endTime, $Invariant)
    $dow = [int]$Now.DayOfWeek
    $back = ($dow - $sd + 7) % 7
    $start = $Now.Date.AddDays(-$back).Add($st)
    if ($start -gt $Now) { $start = $start.AddDays(-7) }
    $hours = ((($ed - $sd + 7) % 7) * 24) + ($et.TotalHours - $st.TotalHours)
    if ($hours -le 0) { $hours += 168 }
    return ($Now -lt $start.AddHours($hours))
}

# ---- 1) 自愈：脚本**与配置**被删/被改坏就从 cache 恢复 ----
if (-not (Test-Path -LiteralPath $BakDir)) { New-Item -ItemType Directory -Force -Path $BakDir | Out-Null }
$pairs = @(
    @{ live = $CorePath;  bak = (Join-Path $BakDir 'core.bak');     cfg = $false },
    @{ live = $AdminPath; bak = (Join-Path $BakDir 'admin.bak');    cfg = $false },
    @{ live = $CfgPath;   bak = (Join-Path $BakDir 'settings.bak'); cfg = $true  }
)
foreach ($pair in $pairs) {
    if (-not (Test-Path -LiteralPath $pair.live)) {
        if (Test-Path -LiteralPath $pair.bak) {
            Copy-Item -LiteralPath $pair.bak -Destination $pair.live -Force
            Write-LogLine @{ ev = 'selfheal'; what = (Split-Path $pair.live -Leaf) }
        }
    } else {
        if ($pair.cfg) {
            # 只备份"能解析成功"的配置，免得把坏配置覆盖掉好备份
            try {
                $null = Get-Content -LiteralPath $pair.live -Raw -Encoding UTF8 | ConvertFrom-Json
                Copy-Item -LiteralPath $pair.live -Destination $pair.bak -Force
            } catch { }
        } else {
            Copy-Item -LiteralPath $pair.live -Destination $pair.bak -Force
        }
    }
}

$cfg = $null
try {
    $cfg = Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    # 配置坏了或被删：先尝试从 cache 恢复，再读一次
    $cfgBak = Join-Path $BakDir 'settings.bak'
    if (Test-Path -LiteralPath $cfgBak) {
        Copy-Item -LiteralPath $cfgBak -Destination $CfgPath -Force
        Write-LogLine @{ ev = 'selfheal'; what = 'settings.json' }
        try { $cfg = Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { exit 0 }
    } else { exit 0 }
}
if ($null -eq $cfg -or -not $cfg.enabled) { exit 0 }

$allowed = Get-AllowedNow -Window $cfg.allowedWindow -Now (Get-Date)

# ---- 2) hosts 兜底：只在拦截时段生效；改完刷新 DNS 缓存，否则旧解析还生效 ----
try {
    $old = ''
    $encObj = [System.Text.Encoding]::Default   # hosts 通常是 ANSI/ASCII
    if (Test-Path -LiteralPath $HostsFile) {
        $hb = [System.IO.File]::ReadAllBytes($HostsFile)
        if ($hb.Length -ge 3 -and $hb[0] -eq 239 -and $hb[1] -eq 187 -and $hb[2] -eq 191) {
            $encObj = New-Object System.Text.UTF8Encoding($true)   # 带 BOM 才按 UTF-8，避免中文注释变乱码
        }
        $old = [System.IO.File]::ReadAllText($HostsFile, $encObj)
    }
    $new = [regex]::Replace($old, "(?ms)^\s*" + [regex]::Escape($MarkBegin) + ".*?" + [regex]::Escape($MarkEnd) + "\s*\r?\n?", "")
    if (-not $allowed -and [string]$cfg.mode -eq 'enforce') {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine($MarkBegin)
        foreach ($d in @($cfg.domains)) {
            if ($d) { [void]$sb.AppendLine("0.0.0.0 $d"); [void]$sb.AppendLine("0.0.0.0 www.$d") }
        }
        [void]$sb.AppendLine($MarkEnd)
        $new = $new.TrimEnd() + "`r`n" + $sb.ToString()
    }
    if ($new.TrimEnd() -ne $old.TrimEnd()) {
        [System.IO.File]::WriteAllText($HostsFile, $new, $encObj)
        & ipconfig.exe /flushdns | Out-Null
        Write-LogLine @{ ev = 'hosts'; act = $(if ($allowed) { 'cleared' } else { 'applied' }) }
    }
} catch { Write-LogLine @{ ev = 'hosts'; err = "$($_.Exception.Message)" } }

# ---- 3) 进程拦截 ----
if (-not $allowed -and [string]$cfg.mode -eq 'enforce') {
    $names   = @($cfg.processNames)          | ForEach-Object { ([string]$_).ToLower() }
    $pathMk  = @($cfg.processPathMarkers)    | ForEach-Object { [string]$_ }
    $cmdMk   = @($cfg.processCmdlineMarkers) | ForEach-Object { [string]$_ }
    foreach ($p in (Get-CimInstance Win32_Process)) {
        if ($p.ProcessId -eq $PID) { continue }
        $nm = ''
        if ($p.Name) { $nm = $p.Name.ToLower() }
        $reason = ''
        if ($names -contains $nm) { $reason = "name:$nm" }
        if (-not $reason -and $p.ExecutablePath) {
            foreach ($m in $pathMk) { if ($p.ExecutablePath.IndexOf($m, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $reason = "path:$m"; break } }
        }
        if (-not $reason -and $p.CommandLine) {
            foreach ($m in $cmdMk) { if ($p.CommandLine.IndexOf($m, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $reason = "cmd:$m"; break } }
        }
        if ($reason) {
            try {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
                Write-LogLine @{ ev = 'process'; act = 'killed'; proc = $nm; why = $reason }
            } catch {
                Write-LogLine @{ ev = 'process'; act = 'kill-failed'; proc = $nm; why = $reason }
            }
        }
    }
}

# ---- 4) 确保孩子会话里的监控任务处于启用状态 ----
try {
    $t = Get-ScheduledTask -TaskName 'SystemHealthMonitor' -ErrorAction Stop
    if ($t.State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName 'SystemHealthMonitor' | Out-Null
        Write-LogLine @{ ev = 'selfheal'; what = 'task-enabled' }
    }
} catch { }

# ---- 5) 日志归档 / 轮转 / 心跳 ----
#   日志文件必须对孩子可写（否则监控进程根本写不进去），所以由 SYSTEM 定期归档到 cache
#   （该目录孩子无权限）：既能保住记录，也能发现他真的删了。
#   注意：轮转必须由这里统一做。若让监控进程自己截断日志，行数会突然变少，
#   归档逻辑会把它误判成"日志被删改"——这是个假警报。
try {
    $arch    = Join-Path $BakDir 'trace.archive.log'
    $cntFile = Join-Path $BakDir 'lines.txt'
    $seen = 0
    if (Test-Path -LiteralPath $cntFile) { $seen = [int](Get-Content -LiteralPath $cntFile -Raw) }

    if (-not (Test-Path -LiteralPath $LogPath)) {
        Add-Content -LiteralPath $arch -Value ('{"ts":"' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '","ev":"log-tamper","note":"日志文件被删除，已重建"}') -Encoding UTF8
        New-Item -ItemType File -Path $LogPath -Force | Out-Null
        Set-Content -LiteralPath $cntFile -Value 0 -Encoding ASCII
    } else {
        $all = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 | Where-Object { $_ })
        if ($all.Count -lt $seen) {
            Add-Content -LiteralPath $arch -Value ('{"ts":"' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '","ev":"log-tamper","note":"日志行数 ' + $seen + ' -> ' + $all.Count + '，疑似被删改"}') -Encoding UTF8
            $seen = 0
        }
        if ($all.Count -gt $seen) {
            $all[$seen..($all.Count - 1)] | Add-Content -LiteralPath $arch -Encoding UTF8
            Set-Content -LiteralPath $cntFile -Value $all.Count -Encoding ASCII
        }
        if ((Get-Item -LiteralPath $LogPath).Length -gt 5MB) {
            $keep = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 | Where-Object { $_ } | Select-Object -Last 2000)
            $keep | Set-Content -LiteralPath $LogPath -Encoding UTF8
            Set-Content -LiteralPath $cntFile -Value $keep.Count -Encoding ASCII
            Add-Content -LiteralPath $arch -Value ('{"ts":"' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '","ev":"log-rotate","note":"日志超过5MB，保留最后 ' + $keep.Count + ' 行"}') -Encoding UTF8
        }
    }

    # 心跳：家长用 -Report 就能确认特权任务还活着（被安全软件禁用时会停）
    Set-Content -LiteralPath (Join-Path $BakDir 'lastrun.txt') -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Encoding ASCII
} catch { }
'@

# ============================== 各模式实现 ==============================
function Get-Cfg {
    if (Test-Path -LiteralPath $CfgPath) {
        return (Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return (New-DefaultConfig)
}

function Show-TestTitle {
    param([string]$Title)
    $cfg = Get-Cfg
    $h = Get-Hit -Text $Title -Cfg $cfg
    $verdict = if (-not $h.hit) { '放行（不拦）' }
               elseif ($h.lvl -eq 'strong') { '拦截 · 强特征词' }
               else { '拦截 · 弱特征词累积' }
    Write-Host ''
    Write-Host ("标题  : " + $Title)
    Write-Host ("判定  : " + $verdict)
    if ($h.hit) { Write-Host ("命中  : " + $h.word + "   (" + $h.lvl + ")") }
    Write-Host ''
}

function Show-SelfTest {
    $cfg = Get-Cfg
    Write-Host ''
    Write-Host '================ GameCurfew 自检 ================' -ForegroundColor Cyan
    $w = $cfg.allowedWindow
    $now = Get-Date
    $allowed = Get-AllowedNow -Window $w -Now $now
    Write-Host ''
    Write-Host ("当前时间  : " + $now.ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $now.DayOfWeek)
    Write-Host ("允许时段  : " + $w.startDay + ' ' + $w.startTime + '  →  ' + $w.endDay + ' ' + $w.endTime)
    Write-Host ("当前状态  : " + $(if ($allowed) { '可玩时段 → 不拦截' } else { '禁止时段 → 拦截生效' })) -ForegroundColor $(if ($allowed) { 'Green' } else { 'Yellow' })
    Write-Host ("模式      : " + $cfg.mode + '   (dryrun = 只记录, enforce = 真拦)') -ForegroundColor $(if ([string]$cfg.mode -eq 'enforce') { 'Yellow' } else { 'Gray' })
    $paused = $false
    if ($cfg.pauseUntil) {
        try { $paused = ([datetime]::Parse([string]$cfg.pauseUntil) -gt (Get-Date)) } catch { }
    }
    if ($paused) {
        Write-Host ("暂停中    : 拦截已暂停至 " + $cfg.pauseUntil + '  （.\gamecurfew.ps1 -Resume 可提前恢复）') -ForegroundColor Magenta
    } elseif ($cfg.pauseUntil) {
        Write-Host ("暂停      : 已过期（" + $cfg.pauseUntil + '）') -ForegroundColor Gray
    }
    $lim = if ($null -eq $cfg.windowStrikeLimit) { 0 }  else { [int]$cfg.windowStrikeLimit }
    $win = if ($null -eq $cfg.strikeWindowMinutes) { 10 } else { [int]$cfg.strikeWindowMinutes }
    $hm  = if ($null -eq $cfg.hotMinutes) { 30 } else { [int]$cfg.hotMinutes }
    if ($lim -le 0) {
        Write-Host '网页拦截  : 命中关键词立即拦（未启用行为密度门槛）' -ForegroundColor Gray
    } else {
        Write-Host ("网页拦截  : 同一关键词 " + $win + ' 分钟内出现 ' + $lim + ' 个不同标题才拦；达标后 ' + $hm + ' 分钟内直接拦') -ForegroundColor Gray
    }
    Write-Host '游戏进程  : 禁止时段一旦启动立即结束' -ForegroundColor Gray
    if ($cfg.parentHash) {
        $um = if ($null -eq $cfg.parentUnlockMinutes) { 60 } else { [int]$cfg.parentUnlockMinutes }
        Write-Host ('家长密码  : 已设置（解锁后暂停 ' + $um + ' 分钟；.\gamecurfew.ps1 -Unlock）') -ForegroundColor Green
    } else {
        Write-Host '家长密码  : 未设置 —— 共用账户时建议设置： .\gamecurfew.ps1 -SetPassword' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '--- 接下来 7 天的时段边界 ---' -ForegroundColor Cyan
    for ($i = 0; $i -lt 7; $i++) {
        $d = $now.Date.AddDays($i)
        $probe = $d.AddHours(12)
        $a = Get-AllowedNow -Window $w -Now $probe
        $probe2 = $d.AddHours(23)
        $b = Get-AllowedNow -Window $w -Now $probe2
        Write-Host ("  " + $d.ToString('MM-dd') + ' ' + $d.DayOfWeek.ToString().PadRight(10) + ' 12:00=' + $(if ($a) { '可玩' } else { '禁止' }) + '   23:00=' + $(if ($b) { '可玩' } else { '禁止' }))
    }

    Write-Host ''
    Write-Host '--- 关键词误报回归测试 ---' -ForegroundColor Cyan
    $cases = @(
        @{ t = '我的世界_百度搜索'; want = $true },
        @{ t = '【我的世界】生存实况 #1_哔哩哔哩_bilibili'; want = $true },
        @{ t = 'Minecraft Wiki'; want = $true },
        @{ t = '迷你世界官网 - 创造你的世界'; want = $true },
        @{ t = 'MC 红石教程合集 - 知乎'; want = $true },
        @{ t = 'cmd.exe'; want = $false },
        @{ t = "McDonald's 官方网站"; want = $false },
        @{ t = 'HMMC 考试报名系统'; want = $false },
        @{ t = 'MC 天佑 - 音乐'; want = $false },
        @{ t = '红石公园门票预订'; want = $false },
        @{ t = '内存占用监控面板'; want = $false },
        @{ t = 'HashMap 原理详解 - 掘金'; want = $false }
    )
    $pass = 0; $fail = 0
    foreach ($c in $cases) {
        $h = Get-Hit -Text $c.t -Cfg $cfg
        $ok = ($h.hit -eq $c.want)
        if ($ok) { $pass++ } else { $fail++ }
        $tag = if ($ok) { ' OK ' } else { 'FAIL' }
        $col = if ($ok) { 'Green' } else { 'Red' }
        $exp = if ($c.want) { '拦' } else { '放' }
        $got = if ($h.hit) { '拦' } else { '放' }
        $kw = if ($h.hit) { $h.word } else { '' }
        Write-Host ("  [$tag] 期望=$exp 实际=$got  $($c.t)  $kw") -ForegroundColor $col
    }
    Write-Host ("  通过 $pass / 失败 $fail") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })

    Write-Host ''
    Write-Host '--- 当前屏幕上会被命中的窗口 ---' -ForegroundColor Cyan
    $any = $false
    try {
        Get-Process | Where-Object { $_.MainWindowTitle } | ForEach-Object {
            $h = Get-Hit -Text $_.MainWindowTitle -Cfg $cfg
            if ($h.hit) {
                $any = $true
                Write-Host ("  [命中] " + $_.ProcessName + ' :: ' + $_.MainWindowTitle + '   (' + $h.word + ')') -ForegroundColor Yellow
            }
        }
    } catch { }
    if (-not $any) { Write-Host '  （无）' -ForegroundColor Gray }

    Write-Host ''
    Write-Host '--- 安装状态 ---' -ForegroundColor Cyan
    Write-Host ("  程序目录  : " + $Root + '  ' + $(if (Test-Path $Root) { '[存在]' } else { '[未安装]' }))
    foreach ($tn in @($TaskAdmin, $TaskCore)) {
        $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        if ($null -eq $t) { Write-Host ("  计划任务  : " + $tn + '  [未注册]') }
        else { Write-Host ("  计划任务  : " + $tn + '  [' + $t.State + ']') }
    }
    Write-Host ''
}

function Show-Report {
    if (-not (Test-Path -LiteralPath $LogPath)) { Write-Host '暂无日志。' ; return }
    $rows = @()
    foreach ($l in (Get-Content -LiteralPath $LogPath -Tail 5000 -Encoding UTF8)) {
        try { $rows += ($l | ConvertFrom-Json) } catch { }
    }
    Write-Host ''
    Write-Host '================ 拦截日志汇总 ================' -ForegroundColor Cyan
    Write-Host ("日志文件 : " + $LogPath)
    Write-Host ("记录条数 : " + $rows.Count)
    $arch = Join-Path $BakDir 'trace.archive.log'
    if (Test-Path -LiteralPath $arch) {
        $archLines = @(Get-Content -LiteralPath $arch -Encoding UTF8 | Where-Object { $_ })
        Write-Host ("归档副本 : " + $arch + '   ' + $archLines.Count + ' 条  (SYSTEM 备份，孩子无法删改)')
        $tamper = @($archLines | Where-Object { $_ -like '*log-tamper*' })
        if ($tamper.Count -gt 0) {
            Write-Host ("  !! 检测到 " + $tamper.Count + " 次日志被删改的痕迹") -ForegroundColor Red
        }
    } else {
        Write-Host '归档副本 : 尚未生成（特权任务每 5 分钟归档一次）'
    }
    $hb = Join-Path $BakDir 'lastrun.txt'
    if (Test-Path -LiteralPath $hb) {
        $last = (Get-Content -LiteralPath $hb -Raw).Trim()
        $mins = 9999
        try { $mins = [int]((Get-Date) - [datetime]::Parse($last)).TotalMinutes } catch { }
        Write-Host ("特权任务 : 最后运行 " + $last + "  (" + $mins + " 分钟前)") -ForegroundColor $(if ($mins -le 12) { 'Green' } else { 'Red' })
        if ($mins -gt 12) { Write-Host '  !! 超过 12 分钟没运行 —— 可能被安全软件禁用、或任务被关掉了' -ForegroundColor Red }
    } else {
        Write-Host '特权任务 : 还没有心跳记录（安装后 5 分钟内会出现）' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '--- 按日期 ---' -ForegroundColor Cyan
    $rows | Group-Object { ([string]$_.ts).Substring(0, 10) } | Sort-Object Name | ForEach-Object {
        Write-Host ("  " + $_.Name + '  ' + $_.Count + ' 条')
    }
    Write-Host ''
    $acted  = @($rows | Where-Object { [string]$_.act -in @('closed', 'killed') })
    $strike = @($rows | Where-Object { [string]$_.act -eq 'strike' })
    $unlock = @($rows | Where-Object { [string]$_.act -like 'unlock-*' })
    $failed = @($rows | Where-Object { [string]$_.act -eq 'unlock-failed' })
    Write-Host '--- 概览 ---' -ForegroundColor Cyan
    Write-Host ("  已拦截（关窗/杀进程）  : " + $acted.Count + ' 次')
    if ($strike.Count -gt 0) { Write-Host ("  擦边命中（未达门槛）    : " + $strike.Count + ' 次（启用了行为密度门槛）') }
    Write-Host ("  家长解锁               : " + ($unlock | Where-Object { [string]$_.act -eq 'unlock-env' }).Count + ' 次（环境变量）')
    if ($failed.Count -gt 0) {
        Write-Host ("  密码输错               : " + $failed.Count + ' 次') -ForegroundColor Yellow
        Write-Host '  ↑ 如果这不是你输错的，说明有人在试密码。' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '--- 命中关键词 TOP 15 ---' -ForegroundColor Cyan
    $rows | Where-Object { $_.kw } | Group-Object kw | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
        Write-Host ("  " + ([string]$_.Name).PadRight(20) + $_.Count)
    }
    Write-Host ''
    Write-Host '--- 最近 25 条明细 ---' -ForegroundColor Cyan
    $rows | Select-Object -Last 25 | ForEach-Object {
        Write-Host ("  " + $_.ts + '  ' + ([string]$_.ev).PadRight(8) + ' ' + ([string]$_.act).PadRight(10) + ' ' + ([string]$_.kw).PadRight(14) + ' ' + ([string]$_.title))
    }
    Write-Host ''
}

function Invoke-Uninstall {
    # 卸载是最大的"放松"，装了密码必须验。忘了密码也有出路，见下面打印的手工步骤。
    if (Test-Path -LiteralPath $CfgPath) {
        $ucfg = Get-Cfg
        if (-not (Confirm-ParentAuth -What '彻底卸载' -Cfg $ucfg)) {
            Write-Host ''
            Write-Host '如果密码确实想不起来了，可以手工卸载（需要管理员权限）：' -ForegroundColor Yellow
            Write-Host '  1. 任务计划程序 里删除 SystemHealthMonitor 和 SystemHealthService 两个任务'
            Write-Host '     （它们被设为隐藏，勾选右侧「显示隐藏的任务」才能看到）'
            Write-Host '  2. 删除目录  C:\ProgramData\SystemHealth'
            Write-Host '  3. 用记事本打开 C:\Windows\System32\drivers\etc\hosts'
            Write-Host '     删掉  # == SYS-HEALTH BEGIN ==  到  # == SYS-HEALTH END ==  之间的内容'
            Write-Host ''
            return
        }
    }
    Write-Host '正在卸载 GameCurfew ...' -ForegroundColor Yellow
    foreach ($tn in @($TaskCore, $TaskAdmin)) {
        if (Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $tn -Confirm:$false
            Write-Host ("  已删除计划任务 " + $tn)
        }
    }
    try {
        if (Test-Path -LiteralPath $HostsFile) {
            $encObj = [System.Text.Encoding]::Default
            $hb = [System.IO.File]::ReadAllBytes($HostsFile)
            if ($hb.Length -ge 3 -and $hb[0] -eq 239 -and $hb[1] -eq 187 -and $hb[2] -eq 191) { $encObj = New-Object System.Text.UTF8Encoding($true) }
            $raw = [System.IO.File]::ReadAllText($HostsFile, $encObj)
            $new = [regex]::Replace($raw, "(?ms)^\s*" + [regex]::Escape($MarkBegin) + ".*?" + [regex]::Escape($MarkEnd) + "\s*\r?\n?", "")
            [System.IO.File]::WriteAllText($HostsFile, $new.TrimEnd() + "`r`n", $encObj)
            & ipconfig.exe /flushdns | Out-Null
            Write-Host '  已清理 hosts 条目并刷新 DNS 缓存'
        }
    } catch { }
    foreach ($k in @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Google\Chrome')) {
        # 只删"确实是我们写的那个值"。原来的写法是无条件删属性 ——
        # 如果这台机器上本来就有人设过 DnsOverHttpsMode，卸载会把别人的策略一起抹掉。
        try {
            $cur = (Get-ItemProperty -Path $k -Name 'DnsOverHttpsMode' -ErrorAction Stop).DnsOverHttpsMode
            if ([string]$cur -eq 'off') { Remove-ItemProperty -Path $k -Name 'DnsOverHttpsMode' -ErrorAction SilentlyContinue }
        } catch { }
    }
    # 家长环境变量如果还留着（设了但没被消费掉），一并清掉，别把密码留在注册表里
    try {
        if ((Get-ItemProperty -Path 'HKCU:\Environment' -Name $EnvVarName -ErrorAction SilentlyContinue)) {
            Remove-ItemProperty -Path 'HKCU:\Environment' -Name $EnvVarName -ErrorAction SilentlyContinue
            Write-Host '  已清除遗留的家长密码环境变量'
        }
    } catch { }
    foreach ($ff in @("$env:ProgramFiles\Mozilla Firefox", "${env:ProgramFiles(x86)}\Mozilla Firefox")) {
        $pj = Join-Path $ff 'distribution\policies.json'
        if (-not (Test-Path -LiteralPath $pj)) { continue }
        try {
            $obj = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($obj.policies -and ($obj.policies.PSObject.Properties.Name -contains 'DNSOverHTTPS')) {
                $obj.policies.PSObject.Properties.Remove('DNSOverHTTPS')
                $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $pj -Encoding UTF8
                Write-Host ('  已移除 Firefox DoH 策略: ' + $pj)
            }
        } catch { }
    }
    if (Test-Path -LiteralPath $Root) {
        # 目录装的时候被收紧过 ACL，先接管所有权再删，否则可能删不掉
        & takeown.exe /F $Root /R /D Y 2>$null | Out-Null
        & icacls.exe $Root /grant '*S-1-5-32-544:(OI)(CI)(F)' /T /C 2>$null | Out-Null
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Root) {
            Write-Host ('  [警告] ' + $Root + ' 未能完全删除，请手动删除') -ForegroundColor Yellow
        } else {
            Write-Host ("  已删除 " + $Root)
        }
    }
    Write-Host '卸载完成。' -ForegroundColor Green
}

function Invoke-Install {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '请以【管理员】身份运行 PowerShell 后再执行安装。'
    }

    # --- 确定要监控的账户 ---
    # 注意：家长和孩子**共用一个账户**是常见情况，所以不能把"当前登录账户"排除在外——
    # 否则恰恰会在最需要它的场景下选错人。
    $cands = Get-ChildAccount
    if (-not $ChildUser) {
        if ($cands -contains $env:USERNAME) {
            $ChildUser = $env:USERNAME
            Write-Host ("将监控当前账户: " + $ChildUser + '   （家长与孩子共用账户）') -ForegroundColor Green
        } else {
            $pool = @($cands)
            if ($pool.Count -eq 1) {
                $ChildUser = $pool[0]
                Write-Host ("自动识别目标账户: " + $ChildUser) -ForegroundColor Green
            } else {
                Write-Host '本机检测到以下用户账户：' -ForegroundColor Yellow
                $i = 0
                foreach ($c in $cands) { $i++; Write-Host ("  [" + $i + '] ' + $c) }
                Write-Host ''
                Write-Host '请重新运行并指定账户，例如：  .\gamecurfew.ps1 -ChildUser 账户名' -ForegroundColor Yellow
                return
            }
        }
    } elseif ($cands -notcontains $ChildUser) {
        Write-Host ("警告：账户 " + $ChildUser + ' 不在本机用户列表中，仍将继续。') -ForegroundColor Yellow
    }

    New-Item -ItemType Directory -Force -Path $Root, $BakDir | Out-Null
    Set-Content -LiteralPath $CorePath  -Value $CoreCode  -Encoding UTF8
    Set-Content -LiteralPath $AdminPath -Value $AdminCode -Encoding UTF8
    Copy-Item -LiteralPath $CorePath  -Destination (Join-Path $BakDir 'core.bak')  -Force
    Copy-Item -LiteralPath $AdminPath -Destination (Join-Path $BakDir 'admin.bak') -Force
    if (-not (Test-Path -LiteralPath $CfgPath) -or $Force) {
        (New-DefaultConfig) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $CfgPath -Encoding UTF8
    }
    if (-not (Test-Path -LiteralPath $LogPath)) { New-Item -ItemType File -Path $LogPath -Force | Out-Null }

    # --- VBS 静默启动器：彻底消除 PowerShell 的黑窗口闪现 ---
    $psFull = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $vbsTpl = 'Set s = CreateObject("WScript.Shell")' + "`r`n" +
              's.Run """{0}"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{1}""", 0, False' + "`r`n"
    Set-Content -LiteralPath $VbsCore  -Value ($vbsTpl -f $psFull, $CorePath)  -Encoding ASCII
    Set-Content -LiteralPath $VbsAdmin -Value ($vbsTpl -f $psFull, $AdminPath) -Encoding ASCII
    Write-Host ('  程序目录写入完成: ' + $Root)

    # --- ACL：孩子只读程序/配置，只对自己的日志有写权限 ---
    $childSid = $null
    try {
        $childSid = (New-Object System.Security.Principal.NTAccount($ChildUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { }
    try {
        & icacls.exe $Root /inheritance:r /grant '*S-1-5-18:(OI)(CI)(F)' /grant '*S-1-5-32-544:(OI)(CI)(F)' /grant '*S-1-5-32-545:(OI)(CI)(RX)' /T /C | Out-Null
        & icacls.exe $BakDir /inheritance:r /grant '*S-1-5-18:(OI)(CI)(F)' /grant '*S-1-5-32-544:(OI)(CI)(F)' /C | Out-Null
        if ($childSid) { & icacls.exe $LogPath /grant ('*' + $childSid + ':(M)') /C | Out-Null }
        Write-Host '  已设置目录权限（孩子只读，日志可写）'
    } catch { Write-Host '  权限设置失败，请手动检查 ACL' -ForegroundColor Yellow }

    # --- 任务 A：特权（SYSTEM，每 5 分钟 + 开机） ---
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $actA = New-ScheduledTaskAction -Execute $wscript -Argument ('"' + $VbsAdmin + '"')
    $trgA = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    $setA = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -Hidden -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    $prnA = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskAdmin -Action $actA -Trigger $trgA -Settings $setA -Principal $prnA -Force | Out-Null
    Write-Host ('  已注册特权任务: ' + $TaskAdmin + '  (SYSTEM / 每5分钟自愈)')

    # --- 任务 B：监控（孩子会话，登录时 + 每 1 分钟） ---
    $actB = New-ScheduledTaskAction -Execute $wscript -Argument ('"' + $VbsCore + '"')
    $trgB = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $ChildUser),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    $setB = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -Hidden -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
    $okB = $false
    try {
        $prnB = New-ScheduledTaskPrincipal -UserId $ChildUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskCore -Action $actB -Trigger $trgB -Settings $setB -Principal $prnB -Force -ErrorAction Stop | Out-Null
        $okB = $true
    } catch { }
    if (-not $okB) {
        # 退路：用 schtasks 注册（/IT = 仅在该用户登录时运行，无需密码）
        $cmd = 'wscript.exe "' + $VbsCore + '"'
        & schtasks.exe /Create /TN $TaskCore /TR $cmd /SC MINUTE /MO 1 /RU $ChildUser /IT /F | Out-Null
        if ($LASTEXITCODE -eq 0) { $okB = $true }
    }
    if ($okB) {
        Write-Host ('  已注册监控任务: ' + $TaskCore + '  (' + $ChildUser + ' / 每1分钟自愈)')
    } else {
        Write-Host ('  [失败] 监控任务注册失败，请手动检查账户名是否正确：' + $ChildUser) -ForegroundColor Red
    }

    # --- 关闭浏览器自带 DoH ---
    #     hosts 兜底走的是系统解析链路，但浏览器自带的加密 DNS 有可能绕开系统解析器，
    #     所以顺手关掉，代价为零。
    foreach ($k in @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Google\Chrome')) {
        try {
            if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
            Set-ItemProperty -Path $k -Name 'DnsOverHttpsMode' -Value 'off' -Type String
        } catch { }
    }
    foreach ($ff in @("$env:ProgramFiles\Mozilla Firefox", "${env:ProgramFiles(x86)}\Mozilla Firefox")) {
        if (-not (Test-Path -LiteralPath $ff)) { continue }
        try {
            $dist = Join-Path $ff 'distribution'
            if (-not (Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }
            $pj = Join-Path $dist 'policies.json'
            $obj = $null
            if (Test-Path -LiteralPath $pj) {
                try { $obj = Get-Content -LiteralPath $pj -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $obj = $null }
            }
            if ($null -eq $obj) { $obj = New-Object psobject }
            if ($null -eq $obj.policies) { $obj | Add-Member -NotePropertyName policies -NotePropertyValue (New-Object psobject) -Force }
            $obj.policies | Add-Member -NotePropertyName DNSOverHTTPS -NotePropertyValue ([pscustomobject]@{ Enabled = $false }) -Force
            $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $pj -Encoding UTF8
            Write-Host ('  已关闭 Firefox 的 DoH: ' + $pj)
        } catch { }
    }
    Write-Host '  已关闭 Edge/Chrome/Firefox 的 DoH'

    # --- 安装后自验证 ---
    Write-Host ''
    Write-Host '--- 安装结果验证 ---' -ForegroundColor Cyan
    $missing = 0
    foreach ($tn in @($TaskAdmin, $TaskCore)) {
        $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        if ($null -eq $t) { Write-Host ('  [缺失] ' + $tn) -ForegroundColor Red; $missing++ }
        else { Write-Host ('  [OK]   ' + $tn.PadRight(22) + $t.State) -ForegroundColor Green }
    }
    foreach ($f in @($CorePath, $AdminPath, $VbsCore, $VbsAdmin, $CfgPath)) {
        if (Test-Path -LiteralPath $f) { Write-Host ('  [OK]   ' + (Split-Path $f -Leaf)) -ForegroundColor Green }
        else { Write-Host ('  [缺失] ' + $f) -ForegroundColor Red; $missing++ }
    }
    $coreProc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like '*core.ps1*' }
    if ($coreProc) { Write-Host '  [OK]   监控进程已在运行' -ForegroundColor Green }
    else { Write-Host '  [提示] 监控进程尚未启动（孩子下次登录或 1 分钟内会自动拉起）' -ForegroundColor Yellow }
    Write-Host ''
    if ($missing -gt 0) {
        Write-Host '上面有 [缺失] 项 —— 把这段输出发给我。' -ForegroundColor Yellow
    } else {
        Write-Host '各项检查通过。' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '安装完成。' -ForegroundColor Green
    Write-Host ''
    Write-Host '下一步：' -ForegroundColor Cyan
    Write-Host '  1. 默认是 dryrun（只记录不拦截）。观察 1-2 天，看日志误报：'
    Write-Host ('       .\gamecurfew.ps1 -Report')
    Write-Host '  2. 确认误报可接受后，把 settings.json 里的 "mode" 改成 "enforce"：'
    Write-Host ('       ' + $CfgPath)
    Write-Host '     改完 15 秒内自动生效，不用重启。'
    Write-Host ''
}

# ============================== 入口 ==============================
function Invoke-SetWindow {
    param([string[]]$Values)
    $valid = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

    # 兼容三种写法，尤其是 powershell -File 那种——它会把 "a","b" 当成一个含逗号的
    # 字符串（实测 Count=1），如果只认 Count=2，命令会"看着成功但什么都没改"。
    #   1) 在 PowerShell 里:  -SetWindow "Friday 12:00","Saturday 02:00"   -> 数组 2 个
    #   2) 用 powershell -File: -SetWindow "Friday 12:00","Saturday 02:00" -> 一个字符串
    #   3) 单字符串带逗号:     -SetWindow "Friday 12:00,Saturday 02:00"
    if (-not $Values) { $Values = $SetWindow }
    $vals = @()
    foreach ($s in @($Values)) {
        foreach ($piece in ([string]$s -split ',')) {
            $q = $piece.Trim().Trim('"').Trim("'").Trim()
            if ($q) { $vals += $q }
        }
    }
    if ($vals.Count -ne 2) {
        Write-Host '用法（三选一，效果一样）：' -ForegroundColor Yellow
        Write-Host '  .\gamecurfew.ps1 -SetWindow "Friday 12:00","Saturday 02:00"'
        Write-Host '  powershell -ExecutionPolicy Bypass -File .\gamecurfew.ps1 -SetWindow "Friday 12:00,Saturday 02:00"'
        Write-Host '      第一个 = 可玩起点，第二个 = 可玩终点；星期用英文全称，时间用 HH:mm（24 小时制）。'
        return
    }
    $parsed = @()
    foreach ($s in $vals) {
        $parts = ([string]$s).Trim() -split '\s+'
        if ($parts.Count -ne 2) { Write-Host ('格式错误: ' + $s + '  —— 应为 "Friday 12:00"') -ForegroundColor Red; return }
        $day = (Get-Culture).TextInfo.ToTitleCase(([string]$parts[0]).ToLower())
        if ($valid -notcontains $day) { Write-Host ('星期无效: ' + $parts[0]) -ForegroundColor Red; return }
        $t = [TimeSpan]::Zero
        if (-not [TimeSpan]::TryParse([string]$parts[1], [ref]$t)) { Write-Host ('时间无效: ' + $parts[1] + '  —— 应为 HH:mm') -ForegroundColor Red; return }
        $parsed += @{ day = $day; time = $t.ToString('hh\:mm') }
    }

    $cfg = Get-Cfg
    # 改时段等于改"什么时候不拦"，属于放松限制，装了密码就要验。
    # （安装时还没设密码，Confirm-ParentAuth 会直接放行）
    if (Test-Path -LiteralPath $Root) {
        if (-not (Confirm-ParentAuth -What '修改可玩时段' -Cfg $cfg)) { return }
    }
    $cfg.allowedWindow.startDay  = $parsed[0].day
    $cfg.allowedWindow.startTime = $parsed[0].time
    $cfg.allowedWindow.endDay    = $parsed[1].day
    $cfg.allowedWindow.endTime   = $parsed[1].time

    Write-Host ''
    Write-Host ('新的可玩时段: ' + $parsed[0].day + ' ' + $parsed[0].time + '  →  ' + $parsed[1].day + ' ' + $parsed[1].time) -ForegroundColor Cyan

    if (Test-Path -LiteralPath $Root) {
        $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $CfgPath -Encoding UTF8
        Write-Host ('已写入 ' + $CfgPath) -ForegroundColor Green
        Write-Host '监控进程每 15 秒重读一次配置，已自动生效，无需重启。' -ForegroundColor Green
    } else {
        Write-Host '尚未安装（只在内存中生效，安装后会用默认值）。' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '--- 接下来 7 天的实际效果 ---' -ForegroundColor Cyan
    $now = Get-Date
    for ($i = 0; $i -lt 7; $i++) {
        $d = $now.Date.AddDays($i)
        $r = @()
        foreach ($h in @(2, 12, 23)) {
            $ok = Get-AllowedNow -Window $cfg.allowedWindow -Now $d.AddHours($h)
            $r += (('{0:00}:00=' -f $h) + $(if ($ok) { '可玩' } else { '禁止' }))
        }
        Write-Host ("  " + $d.ToString('MM-dd') + ' ' + $d.DayOfWeek.ToString().PadRight(10) + '  ' + ($r -join '   '))
    }
    Write-Host ''
}

# ============================== 家长密码 ==============================
# 只保存加盐哈希（PBKDF2，20 万次迭代），不保存明文。共用账户下这是唯一
# 能真正区分"家长在用"和"孩子在用"的东西——因为密码只有你知道。
$EnvVarName = 'GAMECURFEW_PARENT'

function New-SaltBytes {
    $b = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($b)
    return $b
}

function Get-PasswordHash {
    param([string]$Password, [byte[]]$Salt, [int]$Iterations = 200000)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, $Iterations)
    try { return $kdf.GetBytes(32) } finally { $kdf.Dispose() }
}

function Read-PasswordPlain {
    param([string]$Prompt = '请输入家长密码')
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Test-Password {
    param([string]$Password, $Cfg)
    if (-not $Cfg.parentHash -or -not $Cfg.parentSalt) { return $false }
    try {
        $salt = [Convert]::FromBase64String([string]$Cfg.parentSalt)
        $want = [Convert]::FromBase64String([string]$Cfg.parentHash)
        $got  = Get-PasswordHash -Password $Password -Salt $salt
        if ($got.Length -ne $want.Length) { return $false }
        for ($i = 0; $i -lt $got.Length; $i++) { if ($got[$i] -ne $want[$i]) { return $false } }
        return $true
    } catch { return $false }
}

function Get-RecentFailCount {
    param([int]$Minutes = 15)
    $n = 0
    try {
        if (Test-Path -LiteralPath $LogPath) {
            $since = (Get-Date).AddMinutes(-$Minutes)
            foreach ($ln in (Get-Content -LiteralPath $LogPath -Tail 600 -Encoding UTF8)) {
                if ($ln -notlike '*unlock-failed*') { continue }
                try { $o = $ln | ConvertFrom-Json; if ([datetime]::Parse([string]$o.ts) -ge $since) { $n++ } } catch { }
            }
        }
    } catch { }
    return $n
}

# 放行 / 卸载 / 改时段这类"放松限制"的操作统一走这里鉴权。
# 原来这些命令完全不校验密码 —— 只要知道脚本存在就能绕过密码放行，是个真实漏洞。
function Confirm-ParentAuth {
    param([string]$What = '这个操作', $Cfg)
    if ($null -eq $Cfg) { $Cfg = Get-Cfg }
    if (-not $Cfg.parentHash) {
        Write-Host ''
        Write-Host ('注意：你还没有设置家长密码，所以「' + $What + '」目前没有密码保护。') -ForegroundColor Yellow
        Write-Host '      目标账户只要知道这个脚本存在，同样可以放行或卸载。' -ForegroundColor Yellow
        Write-Host '      建议尽快设置：  .\gamecurfew.ps1 -SetPassword' -ForegroundColor Yellow
        Write-Host ''
        return $true
    }
    $limit = [int]$Cfg.parentFailLimit; if ($limit -lt 1) { $limit = 5 }
    $recent = Get-RecentFailCount -Minutes 15
    if ($recent -ge $limit) {
        Write-Host ''
        Write-Host ('已连续输错 ' + $recent + ' 次。为防止暴力猜测，请等 15 分钟后再试。') -ForegroundColor Red
        Write-Host ''
        return $false
    }
    $p = Read-PasswordPlain -Prompt ('请输入家长密码（' + $What + '）')
    if (Test-Password -Password $p -Cfg $Cfg) { return $true }
    Write-Host '密码错误。' -ForegroundColor Red
    Write-LogLine -Path $LogPath -Data @{ ev = 'parent'; act = 'unlock-failed'; src = 'auth'; what = $What }
    return $false
}

# ============================== 提权与暂停 ==============================
function Test-AdminUser {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-CfgField {
    param($Cfg, [string]$Name, $Value)
    if ($Cfg -is [System.Collections.IDictionary]) { $Cfg[$Name] = $Value }
    else { $Cfg | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Save-Cfg {
    param($Cfg)
    $Cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $CfgPath -Encoding UTF8
}

function Invoke-Elevate {
    # 配置和日志都在 ProgramData 下且只给了 Users 读权限，所以改配置必须提权。
    # 这里自动弹一次 UAC，省掉"右键以管理员身份运行"这一步。
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $re = @()
    if ($Uninstall)   { $re += '-Uninstall' }
    if ($Resume)      { $re += '-Resume' }
    if ($Lock)        { $re += '-Lock' }
    if ($Unlock)      { $re += '-Unlock' }
    if ($SetPassword) { $re += '-SetPassword' }
    if ($ToggleMode)  { $re += '-ToggleMode' }
    if ($Wizard)      { $re += '-Wizard' }
    if ($Menu)        { $re += '-Menu' }
    if ($Pause)       { $re += @('-Pause', '-Minutes', [string]$Minutes) }
    if ($SetWindow) { $re += '-SetWindow'; foreach ($s in $SetWindow) { $re += ('"' + [string]$s + '"') } }
    if ($SelfTest)  { $re += '-SelfTest' }
    if ($Report)    { $re += '-Report' }
    if ($TestTitle) { $re += @('-TestTitle', ('"' + $TestTitle + '"')) }
    if ($ChildUser) { $re += @('-ChildUser', ('"' + $ChildUser + '"')) }
    if ($Force)     { $re += '-Force' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"')) + $re
    Write-Host '这一步需要管理员权限，正在弹出 UAC 确认框……请在弹窗里点「是」。' -ForegroundColor Yellow
    try {
        Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs | Out-Null
        Write-Host '已在新的管理员窗口中继续执行（本窗口的输出可以忽略）。' -ForegroundColor Green
    } catch {
        Write-Host '提权被取消或失败。请改用：右键 PowerShell → 以管理员身份运行。' -ForegroundColor Red
    }
}

function Invoke-Pause {
    if (-not (Test-Path -LiteralPath $CfgPath)) { Write-Host '尚未安装，无需暂停。' -ForegroundColor Yellow; return }
    if ($Minutes -lt 1) { $Minutes = 120 }
    $cfg = Get-Cfg
    if (-not (Confirm-ParentAuth -What '暂停拦截' -Cfg $cfg)) { return }
    $until = (Get-Date).AddMinutes($Minutes)
    Set-CfgField $cfg 'pauseUntil' $until.ToString('yyyy-MM-dd HH:mm:ss')
    Save-Cfg $cfg
    Write-Host ''
    Write-Host ('已暂停拦截，直到 ' + $until.ToString('yyyy-MM-dd HH:mm:ss') + '（' + $Minutes + ' 分钟）') -ForegroundColor Green
    Write-Host '监控进程每 15 秒重读一次配置，已生效。' -ForegroundColor Green
    Write-Host '想提前恢复： .\gamecurfew.ps1 -Resume' -ForegroundColor Gray
    Write-Host ''
}

function Invoke-Resume {
    if (-not (Test-Path -LiteralPath $CfgPath)) { Write-Host '尚未安装。' -ForegroundColor Yellow; return }
    $cfg = Get-Cfg
    Set-CfgField $cfg 'pauseUntil' ''
    Save-Cfg $cfg
    Write-Host '已恢复拦截。' -ForegroundColor Green
}

function Invoke-SetPassword {
    if (-not (Test-Path -LiteralPath $CfgPath)) { Write-Host '尚未安装，请先安装。' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host '设置家长密码（共用账户时用它临时解锁；孩子不知道密码就解不开）' -ForegroundColor Cyan
    $p1 = Read-PasswordPlain -Prompt '请输入家长密码'
    if ([string]::IsNullOrWhiteSpace($p1)) { Write-Host '密码不能为空。' -ForegroundColor Red; return }
    if ($p1.Length -lt 8) {
        Write-Host ('密码太短了（' + $p1.Length + ' 位）。') -ForegroundColor Red
        Write-Host '  哈希文件对目标账户可读，短密码有被离线爆破的风险，请至少 8 位。' -ForegroundColor Yellow
        return
    }
    if ($p1 -match '^\d+$') {
        Write-Host '不要用纯数字密码（生日、手机号之类很容易被猜到）。' -ForegroundColor Red
        return
    }
    $p2 = Read-PasswordPlain -Prompt '请再输入一次'
    if ($p1 -ne $p2) { Write-Host '两次输入不一致，已取消。' -ForegroundColor Red; return }
    $salt = New-SaltBytes
    $hash = Get-PasswordHash -Password $p1 -Salt $salt
    $cfg = Get-Cfg
    Set-CfgField $cfg 'parentSalt' ([Convert]::ToBase64String($salt))
    Set-CfgField $cfg 'parentHash' ([Convert]::ToBase64String($hash))
    Save-Cfg $cfg
    Write-Host ''
    Write-Host '密码已设置（只保存加盐哈希，不保存明文，忘了找不回来）。' -ForegroundColor Green
    Write-Host ''
    Write-Host '解锁方式（二选一）：' -ForegroundColor Cyan
    Write-Host '  方式一（推荐）：  .\gamecurfew.ps1 -Unlock         交互式输入，密码不落盘、不进历史'
    Write-Host '  方式二（免UAC）：  setx GAMECURFEW_PARENT "你的密码"'
    Write-Host '                    程序读到后校验，并【立即删除】该环境变量'
    Write-Host ''
    Write-Host '  锁回去：          .\gamecurfew.ps1 -Lock' -ForegroundColor Gray
    Write-Host '  （两种方式都会在到点后自动恢复拦截，忘了锁回来也没事）' -ForegroundColor Gray
    Write-Host ''
}

function Invoke-Unlock {
    if (-not (Test-Path -LiteralPath $CfgPath)) { Write-Host '尚未安装。' -ForegroundColor Yellow; return }
    $cfg = Get-Cfg
    if (-not $cfg.parentHash) {
        Write-Host '还没有设置家长密码，请先运行：  .\gamecurfew.ps1 -SetPassword' -ForegroundColor Yellow
        return
    }
    if (-not (Confirm-ParentAuth -What '临时解锁' -Cfg $cfg)) { return }
    $hm = [int]$cfg.parentUnlockMinutes; if ($hm -lt 1) { $hm = 60 }
    $until = (Get-Date).AddMinutes($hm)
    Set-CfgField $cfg 'pauseUntil' $until.ToString('yyyy-MM-dd HH:mm:ss')
    Save-Cfg $cfg
    Write-Host ''
    Write-Host ('解锁成功，拦截暂停至 ' + $until.ToString('yyyy-MM-dd HH:mm:ss') + '（' + $hm + ' 分钟）') -ForegroundColor Green
    Write-Host '到点自动恢复。想立刻恢复：  .\gamecurfew.ps1 -Lock' -ForegroundColor Gray
    Write-Host ''
}

function Invoke-Lock {
    if (-not (Test-Path -LiteralPath $CfgPath)) { Write-Host '尚未安装。' -ForegroundColor Yellow; return }
    $cfg = Get-Cfg
    Set-CfgField $cfg 'pauseUntil' ''
    Save-Cfg $cfg
    Write-Host '已恢复拦截。' -ForegroundColor Green
}

function Invoke-ToggleMode {
    if (-not (Test-Path -LiteralPath $CfgPath)) { Write-Host '尚未安装。' -ForegroundColor Yellow; return }
    $cfg = Get-Cfg
    $cur = [string]$cfg.mode
    $new = if ($cur -eq 'enforce') { 'dryrun' } else { 'enforce' }
    # 只有"放松"（切到只记录）才要密码；切回真拦是收紧，不需要。
    if ($new -eq 'dryrun' -and -not (Confirm-ParentAuth -What '切换为只记录模式' -Cfg $cfg)) { return }
    Set-CfgField $cfg 'mode' $new
    Save-Cfg $cfg
    Write-Host ''
    if ($new -eq 'enforce') {
        Write-Host '已切换为【真拦】：禁止时段命中就关窗口 / 结束进程。' -ForegroundColor Yellow
    } else {
        Write-Host '已切换为【只记录】：只写日志，不动手。适合排查误报时临时用。' -ForegroundColor Green
        Write-Host '  改回来：再选一次这个菜单项。' -ForegroundColor Gray
    }
    Write-Host '15 秒内自动生效。' -ForegroundColor Green
    Write-Host ''
}

# ============================== 无管理员解锁（环境变量通路） ==============================
# 走用户级环境变量，所以不需要 UAC。菜单里的"我自己要用电脑"用它。
function Invoke-UnlockNoAdmin {
    if (-not (Test-Path -LiteralPath $CfgPath)) { Write-Host '尚未安装。' -ForegroundColor Yellow; return }
    $cfg = Get-Cfg
    if (-not $cfg.parentHash) {
        # 没设密码时的退路：直接放行，但要说清楚这意味着谁都能解开
        Write-Host ''
        Write-Host '你还【没有设置家长密码】。' -ForegroundColor Yellow
        Write-Host '  现在可以直接放行 60 分钟 —— 但这也意味着孩子只要会点这个菜单，同样能放行。' -ForegroundColor Yellow
        Write-Host '  建议尽快设一个：双击 安装.cmd（或 .\gamecurfew.ps1 -SetPassword）' -ForegroundColor Yellow
        Write-Host ''
        $yn = Read-Host '   确定现在放行 60 分钟吗？输入 Y 确认'
        if ($yn -and $yn.Trim() -ieq 'Y') { Invoke-Pause }
        return
    }
    # 先查失败次数，别让这条"免 UAC"的通路变成暴力猜测的方便入口
    $limit = [int]$cfg.parentFailLimit; if ($limit -lt 1) { $limit = 5 }
    $recent = Get-RecentFailCount -Minutes 15
    if ($recent -ge $limit) {
        Write-Host ''
        Write-Host ('已连续输错 ' + $recent + ' 次。为防止暴力猜测，请等 15 分钟后再试。') -ForegroundColor Red
        Write-Host ''
        return
    }
    $p = Read-PasswordPlain -Prompt '请输入家长密码'
    if (-not (Test-Password -Password $p -Cfg $cfg)) {
        Write-Host '密码错误。' -ForegroundColor Red
        Write-LogLine -Path $LogPath -Data @{ ev = 'parent'; act = 'unlock-failed'; src = 'env-local' }
        return
    }
    # 直接写用户级环境变量，等同 setx，但不经过外部进程、密码不出现在任何命令行里
    [Environment]::SetEnvironmentVariable($EnvVarName, $p, 'User')
    Write-Host ''
    Write-Host '已提交。1-2 秒内监控进程会读到并解除限制（默认 60 分钟，到点自动恢复）。' -ForegroundColor Green
    Write-Host ''
}

# ============================== 一键安装向导 ==============================
function Invoke-Wizard {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '   GameCurfew 一键安装' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Invoke-Install
    if (-not (Test-Path -LiteralPath $CfgPath)) { return }
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '   下一步：设置家长密码' -ForegroundColor Cyan
    Write-Host '   （只有你自己知道；忘了找不回来，因为只存加密结果）' -ForegroundColor Gray
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Invoke-SetPassword
    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '   最后：体检' -ForegroundColor Cyan
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Show-SelfTest
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '   安装完成' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host '限制已经生效：' -ForegroundColor Green
    Write-Host '  可玩时段   周五 12:00 → 周六 02:00（其余时间拦截）'
    Write-Host '  拦什么     《我的世界》《迷你世界》以及相关的网页、搜索、视频'
    Write-Host '  拦截动作   关掉那个窗口 / 结束那个进程，并写进本地日志'
    Write-Host ''
    Write-Host '你自己要用电脑时：双击 日常.cmd → 选 1 → 输密码（60 分钟后自动恢复）' -ForegroundColor Gray
    Write-Host '想先看看会拦什么：日常.cmd → 选 5 切到「只记录」，观察完再切回来' -ForegroundColor Gray
    Write-Host ''
    $cfgNow = Get-Cfg
    if (-not $cfgNow.parentHash) {
        Write-Host '!! 警告：你还没有设置家长密码 !!' -ForegroundColor Red
        Write-Host '   限制已经在跑了，但"我自己要用电脑"目前没有密码保护，' -ForegroundColor Red
        Write-Host '   谁点开那个菜单都能放行。请尽快设一个：' -ForegroundColor Red
        Write-Host '       powershell -ExecutionPolicy Bypass -File .\gamecurfew.ps1 -SetPassword' -ForegroundColor Red
        Write-Host ''
    }
}

# ============================== 日常菜单 ==============================
function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host '   GameCurfew 日常操作' -ForegroundColor Cyan
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '    1. 我自己要用电脑（临时解除限制，需要密码）'
        Write-Host '    2. 看看孩子最近碰了什么'
        Write-Host '    3. 体检（不改任何设置）'
        Write-Host '    4. 改「能玩的时间」'
        Write-Host '    5. 切换「拦截 / 只记录」模式'
        Write-Host '    6. 彻底卸载'
        Write-Host '    0. 退出'
        Write-Host ''
        $c = Read-Host '   输入序号后按回车'
        if ($null -eq $c) { $c = '' }
        switch ($c.Trim()) {
            '1' { Invoke-UnlockNoAdmin }
            '2' { Show-Report }
            '3' { Show-SelfTest }
            '4' {
                Write-Host ''
                Write-Host '   格式：星期用英文全称，时间用 24 小时制 HH:mm' -ForegroundColor Gray
                Write-Host '   星期：Monday Tuesday Wednesday Thursday Friday Saturday Sunday' -ForegroundColor Gray
                Write-Host '   例：起点 Friday 12:00    终点 Saturday 09:00' -ForegroundColor Gray
                Write-Host ''
                $a = Read-Host '   可玩起点 (例如 Friday 12:00)'
                $b = Read-Host '   可玩终点 (例如 Saturday 09:00)'
                if ($a -and $b) {
                    if (Test-AdminUser) {
                        Invoke-SetWindow -Values @($a, $b)
                    } else {
                        Write-Host ''
                        Write-Host '   这一步需要管理员权限，会弹确认框，请点「是」……' -ForegroundColor Yellow
                        $script:SetWindow = @($a, $b)
                        Invoke-Elevate
                    }
                }
            }
            '5' {
                if (Test-AdminUser) {
                    Invoke-ToggleMode
                } else {
                    Write-Host ''
                    Write-Host '   会弹管理员确认框，请点「是」……' -ForegroundColor Yellow
                    $script:ToggleMode = $true
                    Invoke-Elevate
                }
            }
            '6' {
                Write-Host ''
                $yn = Read-Host '   确定彻底卸载吗？输入 Y 确认'
                if ($yn -and $yn.Trim() -ieq 'Y') {
                    if (Test-AdminUser) {
                        Invoke-Uninstall
                    } else {
                        Write-Host ''
                        Write-Host '   会弹管理员确认框，请点「是」……' -ForegroundColor Yellow
                        $script:Uninstall = $true
                        Invoke-Elevate
                    }
                    return
                }
            }
            '0' { return }
            default { }
        }
    }
}

# ============================== 入口 ==============================
$needAdmin = $Uninstall -or $SetWindow -or $Pause -or $Resume -or
             $SetPassword -or $Unlock -or $Lock -or $Wizard -or $ToggleMode -or
             (-not ($SelfTest -or $Report -or $TestTitle -or $Menu))
if ($needAdmin -and -not (Test-AdminUser)) { Invoke-Elevate; return }

if ($Wizard)      { Invoke-Wizard;      return }
if ($Menu)        { Show-Menu;          return }
if ($ToggleMode)  { Invoke-ToggleMode;  return }
if ($Uninstall)   { Invoke-Uninstall;   return }
if ($Lock)        { Invoke-Lock;        return }
if ($SetPassword) { Invoke-SetPassword; return }
if ($Unlock)      { Invoke-Unlock;      return }
if ($Resume)      { Invoke-Resume;  return }
if ($Pause)       { Invoke-Pause;   return }
if ($SetWindow)   { Invoke-SetWindow; return }
if ($SelfTest)    { Show-SelfTest;  return }
if ($Report)      { Show-Report;    return }
if ($TestTitle)   { Show-TestTitle -Title $TestTitle; return }
Invoke-Install

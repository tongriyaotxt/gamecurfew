<#
  doctor.ps1  —  GameCurfew 部署体检与自动修复

  为什么需要它：
    这个软件要做的事（建隐藏计划任务、改 hosts、让脚本宿主静默拉起 PowerShell、收紧目录权限）
    全都踩在杀毒软件和安全策略的高压线上。装完不工作，原因就那么几个，但每一个都要敲不同的命令去查。
    这个脚本把已知故障点一次性查完，能自动修的当场修，修不了的直接告诉你点哪儿。

    最常见的那个故障 ——「加载脚本 runc.vbs 失败（拒绝访问）」—— 它会在探测到
    Windows Script Host 不可用时，自动把计划任务换成「直调 powershell.exe」，绕开脚本宿主这一层。

  用法：
      powershell -ExecutionPolicy Bypass -File .\doctor.ps1              # 体检 + 自动修复（会弹 UAC）
      powershell -ExecutionPolicy Bypass -File .\doctor.ps1 -CheckOnly   # 只看不修（不需要管理员）
      powershell -ExecutionPolicy Bypass -File .\doctor.ps1 -OutFile 报告.txt

  它不碰：家长密码、能玩的时间、拦截模式、日志内容。
  退出码：0 = 没有遗留问题；1 = 还有需要手动处理的事项。
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$Pause,
    [string]$OutFile = '',
    [string]$Root    = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$Invariant             = [System.Globalization.CultureInfo]::InvariantCulture

# ============================== 常量（与 gamecurfew.ps1 保持一致） ==============================
if (-not $Root) { $Root = Join-Path $env:ProgramData 'SystemHealth' }
$CfgPath    = Join-Path $Root 'settings.json'
$LogPath    = Join-Path $Root 'trace.log'
$CorePath   = Join-Path $Root 'core.ps1'
$AdminPath  = Join-Path $Root 'admin.ps1'
$VbsCore    = Join-Path $Root 'runc.vbs'
$VbsAdmin   = Join-Path $Root 'runa.vbs'
$BakDir     = Join-Path $Root 'cache'
$TaskCore   = 'SystemHealthMonitor'
$TaskAdmin  = 'SystemHealthService'
$HostsFile  = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$MarkBegin  = '# == SYS-HEALTH BEGIN =='
$MarkEnd    = '# == SYS-HEALTH END =='
$PsExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
$SidSystem  = 'S-1-5-18'
$SidAdmins  = 'S-1-5-32-544'
$SidUsers   = 'S-1-5-32-545'

# -Root 是给开发时离线测试用的。一旦它指向别处，就强制只读 ——
# 否则脚本会拿着一份假目录去对真实系统重建计划任务、改 hosts，那是真会改坏东西的。
if ($Root -ne (Join-Path $env:ProgramData 'SystemHealth')) { $CheckOnly = $true }

# ============================== 提权 ==============================
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $CheckOnly) {
    Write-Host ''
    Write-Host '  检查和修复需要管理员权限，正在弹 UAC，请点「是」...' -ForegroundColor Yellow
    Write-Host '  （新窗口里会重新跑一遍，这个旧窗口可以直接关掉）' -ForegroundColor DarkGray
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Pause')
    if ($OutFile) { $argList += @('-OutFile', ('"' + $OutFile + '"')) }
    if ($Root)    { $argList += @('-Root',    ('"' + $Root    + '"')) }
    try   { Start-Process -FilePath $PsExe -Verb RunAs -ArgumentList $argList | Out-Null }
    catch { Write-Host '  提权被取消，什么都没做。' -ForegroundColor Red; Read-Host '  按回车退出' }
    exit 0
}

# ============================== 输出 ==============================
$script:Lines  = New-Object 'System.Collections.Generic.List[string]'
$script:Fixes  = New-Object 'System.Collections.Generic.List[string]'
$script:Todos  = New-Object 'System.Collections.Generic.List[string]'
$script:BadCnt = 0

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    if ($Color -eq 'Gray') { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
    $script:Lines.Add($Text)
}
function Ok   { param([string]$t) Say ('  [OK]   ' + $t) 'Green' }
function Bad  { param([string]$t) Say ('  [问题] ' + $t) 'Red';     $script:BadCnt++ }
function Warn { param([string]$t) Say ('  [注意] ' + $t) 'Yellow' }
function Fixd { param([string]$t) Say ('  [已修] ' + $t) 'Cyan';    $script:Fixes.Add($t) }
function Todo { param([string]$t) Say ('  [手动] ' + $t) 'Magenta'; $script:Todos.Add($t) }
function Section { param([string]$t) Say ''; Say ('---- ' + $t + ' ----') 'White' }

# ============================== 小工具 ==============================
function Test-SidMatch {
    param($IdentityReference, [string]$Sid)
    try { return ($IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $Sid) }
    catch { return $false }
}

# 指定路径上，某个 SID 是否有足够权限。Need: RX=读+执行, W=写
function Test-AclRight {
    param([string]$Path, [string]$Sid, [string]$Need = 'RX')
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { return $false }
    foreach ($ace in $acl.Access) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        if (-not (Test-SidMatch $ace.IdentityReference $Sid)) { continue }
        $r = [string]$ace.FileSystemRights
        if ($r -match 'FullControl') { return $true }
        if ($Need -eq 'RX' -and $r -match 'ReadAndExecute|ReadData|Read|Modify') { return $true }
        if ($Need -eq 'W'  -and $r -match 'Write|Modify|AppendData')             { return $true }
    }
    return $false
}

function Get-TaskState {
    param([string]$Name)
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Name       = $Name
        State      = [string]$t.State
        Execute    = [string]$t.Actions[0].Execute
        Arguments  = [string]$t.Actions[0].Arguments
        UserId     = [string]$t.Principal.UserId
        RunLevel   = [string]$t.Principal.RunLevel
        Hidden     = [bool]$t.Settings.Hidden
        LastRun    = $info.LastRunTime
        LastResult = $info.LastTaskResult
    }
}

function Format-TaskResult {
    param($Code)
    if ($null -eq $Code) { return '未知' }
    switch ([int]$Code) {
        0          { return '0 (成功)' }
        267009     { return '267009 (正在运行)' }
        267011     { return '267011 (尚未运行过)' }
        1          { return '1 (一般性失败)' }
        2          { return '2 (找不到文件)' }
        2147942401 { return '0x80070001 (函数不正确)' }
        2147942402 { return '0x80070002 (找不到文件)' }
        2147942405 { return '0x80070005 (拒绝访问) ← 就是它' }
        2147943712 { return '0x80070420 (服务未启动)' }
        default    { return ([string]$Code) }
    }
}

# 探测 Windows Script Host 还能不能加载 .vbs
# 手法：让 .vbs 自己去写一个标记文件 —— 写出来了，说明它真的被加载并执行过
function Test-WshUsable {
    $tag  = [guid]::NewGuid().ToString('N')
    $vbs  = Join-Path $env:TEMP ('gc_probe_' + $tag + '.vbs')
    $flag = Join-Path $env:TEMP ('gc_probe_' + $tag + '.ok')
    try {
        $code = 'CreateObject("Scripting.FileSystemObject").CreateTextFile("' + $flag + '", True).Close'
        Set-Content -LiteralPath $vbs -Value $code -Encoding ASCII
        # //B = batch mode：不弹任何对话框，失败只反映在退出码上（免得又给孩子看见一个报错窗）
        $p = Start-Process -FilePath $WscriptExe -ArgumentList @('//B', '//Nologo', ('"' + $vbs + '"')) `
                           -WindowStyle Hidden -PassThru -ErrorAction Stop
        if (-not $p.WaitForExit(8000)) { try { $p.Kill() } catch { } }
        Start-Sleep -Milliseconds 250
        return (Test-Path -LiteralPath $flag)
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $vbs  -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
}

function New-VbsContent {
    param([string]$TargetPs1)
    $tpl = 'Set s = CreateObject("WScript.Shell")' + "`r`n" +
           's.Run """{0}"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{1}""", 0, False' + "`r`n"
    return ($tpl -f $PsExe, $TargetPs1)
}

# 现在是不是「可以玩」的时段（逻辑照抄 gamecurfew.ps1）
function Test-AllowedNow {
    param([object]$Window, [datetime]$Now)
    try {
        $sd = [int][System.DayOfWeek]::$($Window.startDay)
        $ed = [int][System.DayOfWeek]::$($Window.endDay)
        $st = [TimeSpan]::Parse($Window.startTime, $Invariant)
        $et = [TimeSpan]::Parse($Window.endTime, $Invariant)
        $dow  = [int]$Now.DayOfWeek
        $back = ($dow - $sd + 7) % 7
        $start = $Now.Date.AddDays(-$back).Add($st)
        if ($start -gt $Now) { $start = $start.AddDays(-7) }
        $hours = ((($ed - $sd + 7) % 7) * 24) + ($et.TotalHours - $st.TotalHours)
        if ($hours -le 0) { $hours += 168 }
        return ($Now -lt $start.AddHours($hours))
    } catch { return $false }
}

# ============================== 开跑 ==============================
$launcher  = 'vbs'
$wshOk     = $false
$installed = Test-Path -LiteralPath $Root

Say ''
Say ('=' * 62) 'White'
Say '  GameCurfew 部署体检' 'White'
if ($CheckOnly) { Say '  模式：只检查，不修改任何东西' 'DarkGray' }
else            { Say '  模式：检查 + 自动修复' 'DarkGray' }
Say ('=' * 62) 'White'

# ---------------------------------------------------------------- 1
Section '1/8  环境'
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Ok ('系统: ' + $os.Caption + '  (' + $os.Version + ')')
} catch { Warn '读不到系统信息' }

if ($isAdmin) { Ok '管理员权限: 有' } else { Warn '管理员权限: 没有（只能看，不能修）' }
Ok ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())

$ep = Get-ExecutionPolicy
if ($ep -eq 'Restricted' -or $ep -eq 'AllSigned') {
    Bad ('执行策略是 ' + $ep + '，PowerShell 脚本会被拒绝执行')
    if (-not $CheckOnly -and $isAdmin) {
        try { Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
              Fixd '执行策略已改为 RemoteSigned' }
        catch { Todo '手动执行: Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force' }
    } else { Todo '手动执行: Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force' }
} else { Ok ('执行策略: ' + $ep) }

if (-not $installed) {
    Warn ('程序目录不存在: ' + $Root)
    Say ''
    Say '  这台电脑看起来还没装过（或者整个目录被杀软删掉了）。' 'Yellow'
    Say '  如果确实装过 → 十有八九是被杀软清的：先看第 6 节，再加白名单，然后重跑 安装.cmd。' 'Yellow'
}

# ---------------------------------------------------------------- 2
Section '2/8  程序文件'
if ($installed) {
    $fileSpec = @(
        @{ N = 'core.ps1';      P = $CorePath;  Must = $true;  Vbs = $false },
        @{ N = 'admin.ps1';     P = $AdminPath; Must = $true;  Vbs = $false },
        @{ N = 'settings.json'; P = $CfgPath;   Must = $true;  Vbs = $false },
        @{ N = 'trace.log';     P = $LogPath;   Must = $false; Vbs = $false },
        @{ N = 'runc.vbs';      P = $VbsCore;   Must = $false; Vbs = $true  },
        @{ N = 'runa.vbs';      P = $VbsAdmin;  Must = $false; Vbs = $true  }
    )

    foreach ($f in $fileSpec) {
        $exists = Test-Path -LiteralPath $f.P
        $size   = 0
        if ($exists) { try { $size = (Get-Item -LiteralPath $f.P).Length } catch { } }

        if (-not $exists -or $size -le 0) {
            if ($exists) { Bad ($f.N + ' 是 0 字节（被杀软清了内容）') }
            else         { Bad ($f.N + ' 缺失') }

            if ($f.Vbs) {
                $target = $CorePath
                if ($f.N -eq 'runa.vbs') { $target = $AdminPath }
                if (-not $CheckOnly) {
                    try {
                        Set-Content -LiteralPath $f.P -Value (New-VbsContent $target) -Encoding ASCII -ErrorAction Stop
                        Fixd ($f.N + ' 已重建')
                    } catch { Todo ('重建 ' + $f.N + ' 失败: ' + $_.Exception.Message) }
                } else { Todo ($f.N + ' 缺失，需要重建') }
            }
            elseif ($f.Must) { Todo ('重新双击 安装.cmd（' + $f.N + ' 只能由它生成）') }
            else             { Todo ($f.N + ' 缺失，程序第一次运行时会自动创建') }
            continue
        }

        # 文件在、体积正常 —— 再核对 .vbs 内容有没有被杀软改写
        if ($f.Vbs) {
            $target = $CorePath
            if ($f.N -eq 'runa.vbs') { $target = $AdminPath }
            $want = New-VbsContent $target
            $have = ''
            try { $have = (Get-Content -LiteralPath $f.P -Raw -ErrorAction Stop) } catch { }
            # 行尾可能是 CRLF 也可能是 LF（取决于谁写的），比对前先归一化，免得误报
            $hn = ($have -replace "`r`n", "`n").Trim()
            $wn = ($want -replace "`r`n", "`n").Trim()
            if ($hn -ne $wn) {
                Bad ($f.N + ' 内容不对（被杀软改写或被截断）')
                if (-not $CheckOnly) {
                    try { Set-Content -LiteralPath $f.P -Value $want -Encoding ASCII -ErrorAction Stop
                          Fixd ($f.N + ' 已重建') }
                    catch { Todo ('删除 ' + $f.P + ' 后重新运行 安装.cmd') }
                } else { Todo ($f.N + ' 内容异常，需要重建') }
            } else { Ok ($f.N + '  (' + $size + ' 字节)') }
        } else { Ok ($f.N + '  (' + $size + ' 字节)') }
    }

    if (Test-Path -LiteralPath $BakDir) { Ok 'cache 归档目录存在' }
    else { Warn ('归档目录不存在: ' + $BakDir + '（特权任务跑一次就会建）') }
} else { Warn '跳过（未安装）' }

# ---------------------------------------------------------------- 3
Section '3/8  脚本宿主 ——「加载脚本 runc.vbs 失败」的根源就在这一节'
$wshEnabled = $null
try {
    $wshEnabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' `
                    -Name Enabled -ErrorAction Stop).Enabled
} catch { $wshEnabled = $null }

if ($wshEnabled -eq 0) {
    Bad 'Windows Script Host 被注册表/组策略禁用了 (Enabled = 0)'
    if (-not $CheckOnly -and $isAdmin) {
        try {
            if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings')) {
                New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' -Force | Out-Null
            }
            Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' `
                -Name Enabled -Value 1 -Type DWord -ErrorAction Stop
            Fixd '已重新启用 Windows Script Host (Enabled = 1)'
        } catch {
            Todo "手动执行: Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' -Name Enabled -Value 1"
        }
    } else {
        Todo "以管理员运行: Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' -Name Enabled -Value 1"
    }
} elseif ($null -eq $wshEnabled) {
    Ok 'Windows Script Host 没有被策略禁用'
} else {
    Ok ('Windows Script Host 没有被策略禁用 (Enabled = ' + $wshEnabled + ')')
}

$wshOk = Test-WshUsable
if (-not $wshOk -and $wshEnabled -eq 0 -and -not $CheckOnly) {
    $wshOk = Test-WshUsable      # 刚刚才改完注册表，再测一次
    if ($wshOk) { Ok '修完注册表之后，.vbs 已经能正常加载了' }
}

if ($wshOk) {
    Ok '实测 .vbs 能被加载并执行 —— 脚本宿主是好的'
    $launcher = 'vbs'
} else {
    $launcher = 'direct'
    Bad '实测 .vbs 无法被加载执行 —— 这就是「加载脚本 runc.vbs 失败（拒绝访问）」的直接原因'
    Say '         拦它的不是 Windows 自己，就是杀软的「脚本防护」或 Windows 的「智能应用控制」。' 'Yellow'
    Say '         与其跟它斗，不如把启动方式换掉：' 'Yellow'
    if (-not $CheckOnly -and $isAdmin) {
        Fixd '启动方式改为「计划任务直调 powershell.exe」，绕开脚本宿主（下一步重建任务时生效）'
    } else {
        Todo '用管理员重跑一次本脚本，会自动把任务改成直调 powershell.exe'
    }
}

# ---------------------------------------------------------------- 4
Section '4/8  目录与文件权限'
if ($installed) {
    $targetUser = ''
    $tCore = Get-ScheduledTask -TaskName $TaskCore -ErrorAction SilentlyContinue
    if ($tCore -and $tCore.Principal.UserId) { $targetUser = [string]$tCore.Principal.UserId }

    # ⚠️ 目录和文件必须分开授权。icacls 的 (OI)(CI) 是「容器继承」标志，**对文件无效** ——
    #    安装程序第一版就是栽在这：一句 `icacls /inheritance:r /grant ...:(OI)(CI)(RX) /T`
    #    对目录没问题，对文件却只摘掉了继承、没授上新权限，于是每个文件都变成谁都读不了。
    #    表症是计划任务报「加载脚本 runc.vbs 失败（拒绝访问）」，而目录权限看起来完全正常。
    $dirGrant  = @('*' + $SidSystem + ':(OI)(CI)(F)', '*' + $SidAdmins + ':(OI)(CI)(F)', '*' + $SidUsers + ':(OI)(CI)(RX)')
    $fileGrant = @('*' + $SidSystem + ':(F)',          '*' + $SidAdmins + ':(F)',          '*' + $SidUsers + ':(RX)')

    $dirsBad = @()
    foreach ($d in @($Root, $BakDir)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $okSys = Test-AclRight -Path $d -Sid $SidSystem -Need 'F'
        $okAdm = Test-AclRight -Path $d -Sid $SidAdmins -Need 'F'
        if ($okSys -and $okAdm) { Ok ('目录权限正常: ' + $d) }
        else {
            Bad ('目录权限被改过: ' + $d + '  (SYSTEM完整=' + $okSys + ' / 管理员完整=' + $okAdm + ')')
            $dirsBad += $d
        }
    }
    if ($dirsBad.Count) {
        if (-not $CheckOnly -and $isAdmin) {
            foreach ($d in $dirsBad) {
                & icacls.exe $d /inheritance:r /grant $dirGrant /C 2>&1 | Out-Null
                Get-ChildItem -LiteralPath $d -Recurse -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    & icacls.exe $_.FullName /inheritance:r /grant $dirGrant /C 2>&1 | Out-Null
                }
                if (Test-AclRight -Path $d -Sid $SidSystem -Need 'F') { Fixd ('已重置目录权限: ' + $d) }
                else { Todo ('手动重置权限: icacls "' + $d + '" /grant *S-1-5-32-544:(OI)(CI)(F) /C') }
            }
        } else { Todo ('以管理员重跑，修复目录权限: ' + ($dirsBad -join ', ')) }
    }

    # 文件级：普通用户必须读得到，否则计划任务一起来就是「拒绝访问」。
    # cache 子树按设计只给 SYSTEM/管理员，不参与检查。
    $bakPrefix = $BakDir.TrimEnd('\') + '\'
    $filesBad  = @()
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike ($bakPrefix + '*') } |
        ForEach-Object {
            if (-not (Test-AclRight -Path $_.FullName -Sid $SidUsers -Need 'RX')) { $filesBad += $_.FullName }
        }

    if ($filesBad.Count -eq 0) {
        Ok '所有程序文件普通用户都可读'
    } else {
        Bad ($filesBad.Count + ' 个文件普通用户读不到 —— 这就是「加载脚本 runc.vbs 失败（拒绝访问）」的直接原因')
        foreach ($p in $filesBad) { Say ('         · ' + (Split-Path $p -Leaf)) 'DarkGray' }
        Say '         成因：旧版安装程序用容器继承标志 (OI)(CI) 去给文件授权，' 'DarkGray'
        Say '         继承被摘掉、新权限却没授上，文件就成了谁都读不了。' 'DarkGray'
        if (-not $CheckOnly -and $isAdmin) {
            $fixedN = 0
            foreach ($p in $filesBad) {
                & icacls.exe $p /inheritance:r /grant $fileGrant /C 2>&1 | Out-Null
                if (Test-AclRight -Path $p -Sid $SidUsers -Need 'RX') { $fixedN++ }
            }
            if ($fixedN -eq $filesBad.Count) { Fixd ('已修好 ' + $fixedN + ' 个文件的权限，计划任务应该能起来了') }
            else { Todo ('只修好了 ' + $fixedN + '/' + $filesBad.Count + ' 个，其余手动执行: icacls "<文件>" /grant *S-1-5-32-545:(RX)') }
        } else { Todo '以管理员重跑本脚本，会自动把这批文件的权限修好' }
    }

    if (Test-Path -LiteralPath $LogPath) {
        if ($targetUser -and $targetUser -notmatch '^(SYSTEM|SYSTEM32|NT AUTHORITY)') {
            $sid = ''
            try {
                $sid = (New-Object System.Security.Principal.NTAccount($targetUser)).Translate(
                        [System.Security.Principal.SecurityIdentifier]).Value
            } catch { }
            if ($sid) {
                if (Test-AclRight -Path $LogPath -Sid $sid -Need 'W') { Ok ('日志对目标账户可写: ' + $targetUser) }
                else {
                    Bad ('日志对目标账户不可写，监控进程会记不了日志: ' + $targetUser)
                    if (-not $CheckOnly -and $isAdmin) {
                        & icacls.exe $LogPath /grant ('*' + $sid + ':(M)') /C 2>&1 | Out-Null
                        if (Test-AclRight -Path $LogPath -Sid $sid -Need 'W') { Fixd ('已授予 ' + $targetUser + ' 对 trace.log 的写权限') }
                        else { Todo ('手动授予 ' + $targetUser + ' 对 ' + $LogPath + ' 的写权限') }
                    } else { Todo ('以管理员重跑，授予 ' + $targetUser + ' 日志写权限') }
                }
            }
        } else { Warn '无法确定目标账户（监控任务不存在），跳过日志权限检查' }
    }
} else { Warn '跳过（未安装）' }

# ---------------------------------------------------------------- 5
Section '5/8  计划任务'
$needRebuild = @()
$stateAdmin  = Get-TaskState -Name $TaskAdmin
$stateCore   = Get-TaskState -Name $TaskCore
$targetUser  = ''
if ($stateCore -and $stateCore.UserId) { $targetUser = $stateCore.UserId }

if (-not $stateAdmin -and -not $stateCore) {
    Warn '跳过（两个任务都不存在，应该是还没装）'
} else {
    # --- 特权任务 ---
    if (-not $stateAdmin) {
        Bad ('特权任务不存在: ' + $TaskAdmin)
        $needRebuild += 'admin'
    } else {
        Ok ($TaskAdmin + '  状态=' + $stateAdmin.State + '  身份=' + $stateAdmin.UserId +
            '  上次结果=' + (Format-TaskResult $stateAdmin.LastResult))
        if ($stateAdmin.State -eq 'Disabled') {
            Bad ($TaskAdmin + ' 被禁用了')
            if (-not $CheckOnly -and $isAdmin) {
                try { Enable-ScheduledTask -TaskName $TaskAdmin -ErrorAction Stop | Out-Null; Fixd ($TaskAdmin + ' 已重新启用') }
                catch { Todo ('手动启用计划任务: ' + $TaskAdmin) }
            } else { Todo ('手动启用计划任务: ' + $TaskAdmin) }
        }
        if ($stateAdmin.UserId -and $stateAdmin.UserId -notmatch 'SYSTEM') {
            Bad ($TaskAdmin + ' 的运行身份不是 SYSTEM（现在是 ' + $stateAdmin.UserId + '），特权操作会失败')
            $needRebuild += 'admin'
        }
        if ($null -ne $stateAdmin.LastResult -and [int]$stateAdmin.LastResult -eq 2147942405) {
            Bad ($TaskAdmin + ' 上次运行报「拒绝访问」—— 和 runc.vbs 是同一个病')
            $needRebuild += 'admin'
        }
    }

    # --- 监控任务 ---
    if (-not $stateCore) {
        Bad ('监控任务不存在: ' + $TaskCore)
        $needRebuild += 'core'
    } else {
        Ok ($TaskCore + '  状态=' + $stateCore.State + '  身份=' + $stateCore.UserId +
            '  上次结果=' + (Format-TaskResult $stateCore.LastResult))
        if ($stateCore.State -eq 'Disabled') {
            Bad ($TaskCore + ' 被禁用了')
            if (-not $CheckOnly -and $isAdmin) {
                try { Enable-ScheduledTask -TaskName $TaskCore -ErrorAction Stop | Out-Null; Fixd ($TaskCore + ' 已重新启用') }
                catch { Todo ('手动启用计划任务: ' + $TaskCore) }
            } else { Todo ('手动启用计划任务: ' + $TaskCore) }
        }
        if ($null -ne $stateCore.LastResult -and [int]$stateCore.LastResult -eq 2147942405) {
            Bad ($TaskCore + ' 上次运行报「拒绝访问」—— 就是 runc.vbs 那个报错')
            $needRebuild += 'core'
        }
        $usingVbs = ($stateCore.Execute -match 'wscript')
        if ($launcher -eq 'direct' -and $usingVbs) {
            Bad ($TaskCore + ' 仍在使用 wscript 启动，而脚本宿主已经被拦 → 需要改成直调 powershell')
            $needRebuild += 'core'
            if ($stateAdmin -and $stateAdmin.Execute -match 'wscript') { $needRebuild += 'admin' }
        }
    }
    $needRebuild = @($needRebuild | Select-Object -Unique)

    # --- 重建 ---
    if ($needRebuild.Count -and $CheckOnly) {
        Todo ('需要重建的计划任务: ' + ($needRebuild -join ', ') + '（去掉 -CheckOnly 再跑一次就会自动重建）')
    }
    elseif ($needRebuild.Count -and $isAdmin) {
        Say ''
        Say '  正在重建计划任务...' 'Cyan'
        $howItRuns = 'wscript 静默启动'
        if ($launcher -ne 'vbs') { $howItRuns = '直调 powershell' }

        if ($needRebuild -contains 'admin') {
            if ($launcher -eq 'vbs') {
                if (-not (Test-Path -LiteralPath $VbsAdmin)) {
                    Set-Content -LiteralPath $VbsAdmin -Value (New-VbsContent $AdminPath) -Encoding ASCII
                }
                $actA = New-ScheduledTaskAction -Execute $WscriptExe -Argument ('"' + $VbsAdmin + '"')
            } else {
                $actA = New-ScheduledTaskAction -Execute $PsExe -Argument (
                    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $AdminPath + '"')
            }
            $trgA = @(
                (New-ScheduledTaskTrigger -AtStartup),
                (New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
                    -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650))
            )
            $setA = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -MultipleInstances IgnoreNew -Hidden -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
            $prnA = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            try {
                Register-ScheduledTask -TaskName $TaskAdmin -Action $actA -Trigger $trgA -Settings $setA `
                    -Principal $prnA -Force -ErrorAction Stop | Out-Null
                Fixd ($TaskAdmin + ' 已重建（' + $howItRuns + '）')
            } catch { Todo ($TaskAdmin + ' 重建失败: ' + $_.Exception.Message) }
        }

        if ($needRebuild -contains 'core') {
            if (-not $targetUser) {
                Todo ($TaskCore + ' 重建失败：读不到目标账户名，请重新双击 安装.cmd 走一遍向导')
            } else {
                if ($launcher -eq 'vbs') {
                    if (-not (Test-Path -LiteralPath $VbsCore)) {
                        Set-Content -LiteralPath $VbsCore -Value (New-VbsContent $CorePath) -Encoding ASCII
                    }
                    $actB = New-ScheduledTaskAction -Execute $WscriptExe -Argument ('"' + $VbsCore + '"')
                } else {
                    $actB = New-ScheduledTaskAction -Execute $PsExe -Argument (
                        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $CorePath + '"')
                }
                $trgB = @(
                    (New-ScheduledTaskTrigger -AtLogOn -User $targetUser),
                    (New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
                        -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650))
                )
                $setB = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                            -MultipleInstances IgnoreNew -Hidden -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
                $okB = $false
                try {
                    $prnB = New-ScheduledTaskPrincipal -UserId $targetUser -LogonType Interactive -RunLevel Limited
                    Register-ScheduledTask -TaskName $TaskCore -Action $actB -Trigger $trgB -Settings $setB `
                        -Principal $prnB -Force -ErrorAction Stop | Out-Null
                    $okB = $true
                } catch { }
                if (-not $okB) {
                    $cmdText = 'wscript.exe "' + $VbsCore + '"'
                    if ($launcher -ne 'vbs') {
                        $cmdText = '"' + $PsExe + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $CorePath + '"'
                    }
                    & schtasks.exe /Create /TN $TaskCore /TR $cmdText /SC MINUTE /MO 1 /RU $targetUser /IT /F 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { $okB = $true }
                }
                if ($okB) { Fixd ($TaskCore + ' 已重建（身份 ' + $targetUser + '，' + $howItRuns + '）') }
                else { Todo ($TaskCore + ' 重建失败：确认账户名 ' + $targetUser + ' 是否正确') }
            }
        }
    }
}

# ---------------------------------------------------------------- 6
Section '6/8  安全软件 ——「拒绝访问」的头号嫌疑人'

$avNames = @()
try {
    foreach ($av in @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
        if ($av.displayName) { $avNames += [string]$av.displayName }
    }
} catch { }
if ($avNames.Count) {
    Ok ('已注册的安全软件: ' + ($avNames -join ' / '))
    $third = @($avNames | Where-Object { $_ -notmatch 'Defender|Microsoft|Windows' })
    if ($third.Count) {
        Bad ('检测到第三方杀软: ' + ($third -join ' / ') + ' —— 它的「脚本防护」最可能拦掉 .vbs')
        Todo ('打开 ' + ($third -join '/') + ' → 找到「信任区 / 白名单 / 排除项」→ 把 ' + $Root + ' 整个目录加进去 → 再跑一次本脚本')
        Todo ('顺便看它的拦截日志里有没有 runc.vbs 或 wscript.exe —— 有就实锤了')
    }
} else { Warn '读不到安全软件列表（可能都没注册到安全中心）' }

$sac = $null
try {
    $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
                -Name VerifiedAndReputablePolicyState -ErrorAction Stop).VerifiedAndReputablePolicyState
} catch { }
if ($sac -eq 1) {
    Bad 'Windows 智能应用控制 处于「开启」状态 —— 它会直接拦住未签名脚本，包括 .vbs'
    Todo '设置 → 隐私和安全性 → Windows 安全中心 → 应用和浏览器控制 → 智能应用控制 → 关闭'
    Todo '注意：这个开关关掉以后，除非重装系统否则打不回来。所以先排除掉杀软，再动它。'
} elseif ($sac -eq 2) {
    Warn 'Windows 智能应用控制 处于「评估」状态，仍有可能拦脚本'
} else {
    Ok 'Windows 智能应用控制: 未开启'
}

# ⚠️ 改这个文件之前，先看 README 里「脚本为什么会被安全软件拦掉」那一节。
#   一句话版本：绝不要在脚本里加入「把自己所在目录加进系统安全软件排除列表」的
#   那类调用，也不要在这里写下那个接口的名字。安全软件在脚本**加载阶段**（语法都
#   还没解析、一行都还没执行时）就会扫描全文，命中特征组合就直接拒绝加载。
#   实测：第一版带了那个调用被拦；把调用删掉、只在注释里留下接口名和检测名，照样被拦。
#   所以这类操作只能由人在安全中心界面里手动做。
$mpAvailable = $false
try { $null = Get-MpPreference -ErrorAction Stop; $mpAvailable = $true } catch { }
if ($mpAvailable) {
    $mp   = Get-MpPreference
    $excl = @($mp.ExclusionPath)
    $hasExcl = $false
    foreach ($e in $excl) {
        if ($e -and $e.TrimEnd('\') -ieq $Root.TrimEnd('\')) { $hasExcl = $true }
    }

    $hits = @()
    try {
        $hits = @(Get-MpThreatDetection -ErrorAction Stop |
                  Where-Object { $_.Resources -match 'SystemHealth|runc\.vbs|runa\.vbs|core\.ps1|admin\.ps1|gamecurfew' } |
                  Sort-Object InitialDetectionTime -Descending | Select-Object -First 5)
    } catch { }

    if ($hits.Count) {
        Bad ('Defender 有 ' + $hits.Count + ' 条针对本程序的拦截/隔离记录')
        foreach ($h in $hits) {
            Say ('         ' + $h.InitialDetectionTime + '  ' + (($h.Resources) -join ' ')) 'DarkGray'
        }
        Todo 'Windows 安全中心 → 病毒和威胁防护 → 保护历史记录 → 找到被隔离的项 → 还原'
        if ($hasExcl) { Ok ('Defender 排除项已包含: ' + $Root) }
        else { Todo ('手动添加排除项: Windows 安全中心 → 病毒和威胁防护 → 管理设置 → 排除项 → 添加文件夹 → ' + $Root) }
    } elseif ($hasExcl) {
        Ok ('Defender 排除项已包含: ' + $Root)
    } else {
        Ok 'Defender 没有针对本程序的拦截记录'
        Say ('         （建议手动把 ' + $Root + ' 加进排除项：Windows 安全中心 → 病毒和威胁防护 → 管理设置 → 排除项）') 'DarkGray'
    }

    $asrOn = @()
    try {
        $ids  = @($mp.AttackSurfaceReductionRules_Ids)
        $acts = @($mp.AttackSurfaceReductionRules_Actions)
        for ($i = 0; $i -lt $ids.Count; $i++) {
            if ($i -lt $acts.Count -and [int]$acts[$i] -eq 1) { $asrOn += [string]$ids[$i] }
        }
    } catch { }
    if ($asrOn.Count) {
        Warn ('Defender 攻击面减少(ASR) 有 ' + $asrOn.Count + ' 条规则处于「阻止」状态')
        Todo '若前面几项都查不出问题，就在 Get-MpPreference 里看这几条规则 ——「阻止混淆脚本」那一类会拦 .vbs'
    }
}

# ---------------------------------------------------------------- 7
Section '7/8  运行状态'
if ($installed) {
    $procs = @()
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue)
    } catch { }
    # 只认「-File ...core.ps1」这种真正的启动命令行，并且排掉自己 ——
    # 否则任何命令行里恰好出现 core.ps1 字样的进程（比如正在跑本脚本的那个）都会被当成监控进程
    $coreRun = @($procs | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match '-File\s+.*core\.ps1' })
    $admRun  = @($procs | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match '-File\s+.*admin\.ps1' })
    if ($coreRun.Count) { Ok ('监控进程在跑 (PID ' + (($coreRun | ForEach-Object { $_.ProcessId }) -join ',') + ')') }
    else { Warn '监控进程当前没在跑（下次任务触发会起来；也可能是刚被杀软结束了）' }
    if ($admRun.Count) { Ok ('特权进程在跑 (PID ' + (($admRun | ForEach-Object { $_.ProcessId }) -join ',') + ')') }
    else { Warn '特权进程当前没在跑（它是每 5 分钟的短命进程，正常也可能刚好不在）' }

    if (Test-Path -LiteralPath $LogPath) {
        $li  = Get-Item -LiteralPath $LogPath
        $ago = [int]((Get-Date) - $li.LastWriteTime).TotalMinutes
        if ($ago -le 15) { Ok ('日志 ' + $ago + ' 分钟前还有写入 —— 存活心跳正常') }
        else             { Warn ('日志最后写入是 ' + $ago + ' 分钟前（没在拦，或者现在正好是可玩时段）') }
        Ok ('日志大小: ' + $li.Length + ' 字节')
    } else { Warn '还没有 trace.log' }

    $hostsOk = $false
    try { $hostsOk = (Get-Content -LiteralPath $HostsFile -Raw -ErrorAction Stop).Contains($MarkBegin) } catch { }
    if ($hostsOk) { Ok 'hosts 拦截段已写入' }
    else {
        Bad 'hosts 里没有拦截段（网页/搜索拦截会失效）'
        if (-not $CheckOnly -and $isAdmin) {
            try {
                Start-ScheduledTask -TaskName $TaskAdmin -ErrorAction Stop
                Fixd ($TaskAdmin + ' 已手动触发，它会在几秒内把 hosts 写回去')
            } catch { Todo '手动触发一次 ' + $TaskAdmin + ' 来重写 hosts' }
        } else { Todo ('触发一次 ' + $TaskAdmin + ' 来重写 hosts') }
    }

    $cfgOk = $false
    try { $null = (Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json); $cfgOk = $true } catch { }
    if ($cfgOk) { Ok 'settings.json 是合法 JSON' }
    else {
        Bad 'settings.json 损坏或不是合法 JSON —— 监控进程读不到配置就不会工作'
        Todo '重新双击 安装.cmd 会重建默认配置（注意：「能玩的时间」会被重置回默认值）'
    }
} else { Warn '跳过（未安装）' }

# ---------------------------------------------------------------- 8
Section '8/8  有效性与隐蔽性（只提示，不修改）'
if ($installed -and $cfgOk) {
    try {
        $cfg = Get-Content -LiteralPath $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $now = Get-Date

        if ($cfg.enabled -eq $false) { Bad '配置里 enabled = false —— 监控整体被关掉了' }
        else { Ok '配置 enabled = true' }

        if ($cfg.mode -eq 'dryrun') {
            Warn '当前是「只记录」模式（dryrun）—— 只写日志不动手，拦不住是正常的'
        } else { Ok ('拦截模式: ' + $cfg.mode) }

        if ($cfg.pauseUntil) {
            $pu = $null
            try { $pu = [datetime]::Parse($cfg.pauseUntil, $Invariant) } catch { }
            if ($pu -and $pu -gt $now) { Warn ('家长解锁生效中，到 ' + $pu.ToString('MM-dd HH:mm') + ' 自动恢复') }
        }

        $w = $cfg.allowedWindow
        $allowedNow = Test-AllowedNow -Window $w -Now $now
        $desc = ($w.startDay + ' ' + $w.startTime + ' → ' + $w.endDay + ' ' + $w.endTime)
        if ($allowedNow) { Warn ('现在处于「可玩时段」(' + $desc + ') —— 此刻本来就不拦，看不到记录是正常的') }
        else             { Ok ('可玩时段: ' + $desc + '；当前不在时段内，应该处于拦截状态') }
    } catch { Warn '读配置失败，跳过本节' }

    if ($stateCore) {
        if ($stateCore.Hidden) { Ok '监控任务已隐藏（任务计划程序里不显眼）' }
        else { Warn '监控任务的「隐藏」标志丢了 —— 在任务计划程序里会被看见' }
    }

    if ($targetUser) {
        $isTargetAdmin = $false
        try {
            $members = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop)
            foreach ($m in $members) {
                if ($m.Name -and $m.Name -match [regex]::Escape(($targetUser -split '\\')[-1])) { $isTargetAdmin = $true }
            }
        } catch { }
        if ($isTargetAdmin) {
            Bad ('目标账户 ' + $targetUser + ' 是管理员 —— 这个方案对它基本无效（他能直接删任务、改 hosts）')
            Todo '把孩子的账户降成「标准用户」才是真正有效的那一步'
        } else {
            Ok ('目标账户 ' + $targetUser + ' 不是管理员（标准用户，限制有效）')
        }
    }

    if (-not $wshOk) {
        Warn '脚本宿主不可用：如果还留着 wscript 启动的任务，运行时会弹出报错窗口，把程序路径暴露给孩子'
    }
} else { Warn '跳过（未安装或配置读不出来）' }

# ============================== 汇总 ==============================
Say ''
Say ('=' * 62) 'White'
Say '  体检结束' 'White'
Say ('=' * 62) 'White'

if (-not $installed) {
    Say ''
    Say '  结论：这台电脑上没有装过 GameCurfew（或者整个目录被杀软清掉了）。' 'Yellow'
    Say '  安装方法：把 安装.cmd 和 gamecurfew.ps1 放在同一个文件夹里，双击 安装.cmd。' 'Yellow'
} else {
    if ($script:BadCnt -eq 0 -and $script:Todos.Count -eq 0) { Say '  没查出问题。' 'Green' }
    else { Say ('  发现 ' + $script:BadCnt + ' 处异常。') 'Yellow' }
}

if ($script:Fixes.Count) {
    Say ''
    Say ('  本次自动修好了 ' + $script:Fixes.Count + ' 项：') 'Cyan'
    foreach ($f in $script:Fixes) { Say ('    · ' + $f) 'Cyan' }
}
if ($script:Todos.Count) {
    Say ''
    Say ('  还需要你手动处理 ' + $script:Todos.Count + ' 项：') 'Magenta'
    $n = 1
    foreach ($t in $script:Todos) { Say ('    ' + $n + '. ' + $t) 'Magenta'; $n++ }
}
Say ''
if ($installed -and $script:Todos.Count -eq 0 -and $script:BadCnt -eq 0) {
    Say '  可以回去双击 日常.cmd 选 3 做一次常规体检。' 'DarkGray'
}

# ============================== 报告文件 ==============================
if ($OutFile) {
    try {
        $full = $OutFile
        if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-Location).Path $full }
        $head = @(
            'GameCurfew 部署体检报告',
            '时间: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
            '机器: ' + $env:COMPUTERNAME + '    账户: ' + $env:USERNAME,
            ''
        )
        $all = $head + $script:Lines
        [System.IO.File]::WriteAllLines($full, [string[]]$all, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ('  报告已写到: ' + $full) -ForegroundColor Cyan
        Write-Host '  把这个文件发给我就能接着排查。' -ForegroundColor Cyan
    } catch {
        Write-Host ('  报告写文件失败: ' + $_.Exception.Message) -ForegroundColor Red
    }
}

if ($Pause) { Write-Host ''; Read-Host '  按回车关闭' }

if ($script:Todos.Count -gt 0) { exit 1 } else { exit 0 }

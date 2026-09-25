# GameCurfew

> Give Minecraft on Windows a time window. Outside that window the game won't open, and related web pages, searches, and videos are blocked along with it.
>
> **Single file, zero dependencies, effective the moment it's installed.** One PowerShell script plus two launchers you run by double-clicking.

[中文](README.md) ｜ **English**

```
Play window     Friday 12:00 → Saturday 02:00 (configurable)
All other times Blocks the Minecraft client + related web content
Parents         Enter a password to lift restrictions temporarily; restores automatically after 60 minutes
```

---

## Table of Contents

- [The Problem It Solves](#the-problem-it-solves)
- [Why Off-the-Shelf Solutions Fall Short](#why-off-the-shelf-solutions-fall-short)
- [Three Key Design Decisions](#three-key-design-decisions)
- [Feature Overview](#feature-overview)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Parent Exemption: Telling You Apart from Your Child on a Shared Account](#parent-exemption-telling-you-apart-from-your-child-on-a-shared-account)
- [Configuration](#configuration)
- [Common Commands](#common-commands)
- [Do These Two Things Before You Start](#do-these-two-things-before-you-start)
- [Security Notes](#security-notes)
- [FAQ](#faq)
- [Known Limitations](#known-limitations)
- [Design Tradeoffs](#design-tradeoffs)
- [File Reference](#file-reference)
- [Uninstall](#uninstall)
- [License](#license)

---

## The Problem It Solves

Your child plays Minecraft on a Windows PC — the NetEase China Edition, the international edition, or through launchers such as PCL and HMCL — and also watches Minecraft videos and looks up guides online. What you want isn't a ban; it's a **time window**. Something like "playable from Friday noon to early Saturday morning, not the rest of the week."

The hard part isn't blocking one game. It's that two things have to hold at the same time:

1. **There are countless ways to launch the game**: the official launcher, PCL, HMCL, the NetEase edition, Bedrock Edition UWP…
   Block by executable name and you will always miss one.
2. **"Searching for related content online" simply isn't blockable at the network layer** (see the next section).

---

## Why Off-the-Shelf Solutions Fall Short

The field was surveyed (speed, maintenance status, coverage), and the conclusion is that **no single existing project covers this**:

| Option | Why it isn't enough |
|---|---|
| NetEase's official anti-addiction / parent platform | Covers only NetEase's own games; and it can be bypassed by registering with an adult ID card |
| Microsoft Family Safety | Web filtering **only takes effect in Edge**; availability in mainland China is doubtful (the official page links only to Google Play / the App Store, and the China App Store page is a 404) |
| AdGuard Home / Pi-hole / NextDNS | **The DNS layer cannot see search keywords** — see below |
| OpenAppFilter | Requires an OpenWrt router; it identifies applications at the network layer rather than blocking processes |
| Portmaster | Can cut a process off the network, but **offline single-player still works** |
| e2guardian | The only one that genuinely filters content by keyword, but it requires TLS interception plus a locally installed root certificate — not realistic to deploy on Windows |

### Why the DNS Layer Can't Block "Search for Minecraft"

When your child searches Baidu for 我的世界 (Minecraft), the request is:

```
https://www.baidu.com/s?wd=我的世界
       ^^^^^^^^^^^^^^ domain never changes
```

DNS only ever sees `www.baidu.com`. Blocking that search along with it **means blocking all of Baidu** — which takes legitimate schoolwork down with it.
And once HTTPS is in play, the path and query string are invisible to any network intermediary.

**This is the fundamental reason this project exists.**

---

## Three Key Design Decisions

### ① Block Web Content Through Window Titles, Not a Man-in-the-Middle

Window titles and the browser address bar are **plaintext on the local machine**. If your child searches for 我的世界, the window title literally reads `我的世界_百度搜索`; when they watch a Minecraft video on Bilibili, the title contains `【我的世界】...`.

So **no HTTPS interception and no root certificate are needed** to block "searching for the keyword" and "watching related videos." It's the only workable approach among purely local methods.

It also means blocking is **browser-agnostic** — Edge, Chrome, 360 Browser, portable browsers: none of their title bars can hide it.

### ② Blocking Java Edition Takes Command-Line Signatures, Not Executable Names

PCL, HMCL, and the official launcher **are just shells**. After you click "Launch game", what actually runs is `javaw.exe` — kill the launcher and the game keeps running. And `javaw.exe` is the generic name shared by every Java program, so blocking by name would hit a lot of innocent software.

So the tool identifies the game by **command-line signatures**:

```
net.minecraft.client.main.Main     ← Minecraft Java Edition's main class; every launcher ends up calling it
--assetIndex                       ← a parameter unique to Minecraft Java Edition
```

No matter what the launcher is called, which drive it's installed on, or where `.minecraft` has been moved to, this one signature matches — and it cannot catch an ordinary Java program by mistake.

The NetEase edition is handled by the `MCLDownload` install path plus the `mc.163.com` domain as a fallback.

### ③ Weak Keywords Must Accumulate, or False Positives Drown the Log

Blocking on the abbreviation `mc` alone would catch `cmd.exe`, `McDonald's`, `HMMC`, `MC 天佑`…

So keywords come in two tiers:

- **Strong keywords** (a single hit blocks): `我的世界`, `Minecraft`, `迷你世界`, `Plain Craft Launcher`…
- **Weak keywords** (blocked only when **2 of them hit at once**): `mc`, `红石`, `苦力怕`, `方块`…

Latin words are matched on word boundaries (equivalent to `\bmc\b`); Chinese words are matched by substring.
12 regression cases watch this specifically, including the traps listed above.

---

## Feature Overview

| Capability | Description |
|---|---|
| Time window | Cross-midnight ranges such as "Friday 12:00 → Saturday 02:00", changeable at any time |
| Process blocking | Process name + install path + command line, **matched in three ways**, covering the official launcher / PCL / HMCL / NetEase edition / Bedrock Edition / Mini World |
| Web blocking | Enumerates the titles of all visible windows, matches them against the tiered keywords, and closes the window |
| Domain fallback | Writes blocked domains into the hosts file during the window, disables browser DoH to prevent bypass, and flushes the DNS cache afterwards |
| Parent password | PBKDF2 salted hash (200,000 iterations), no plaintext stored; **at least 8 characters and not all digits** |
| Command authorization | Pausing, switching to log-only, changing the window, and uninstalling **all require the password**; 5 wrong attempts in a row trigger a 15-minute cooldown |
| Stealth | No window, no tray icon, no install record, no startup entry; scheduled tasks are set to Hidden and run in a SYSTEM session |
| Tamper resistance | A killed process **comes back within 1 minute**; a modified hosts file is rewritten within 5 minutes; deleted scripts or config are restored automatically |
| Logging | Local JSONL log + periodic SYSTEM archiving + tamper detection + liveness heartbeat |
| Zero dependencies | No Python / Node / .NET SDK needed — the PowerShell included with Windows is enough |

---

## Quick Start

### Easiest: Double-Click

Put `安装.cmd` (the installer) and `gamecurfew.ps1` **in the same folder**, then **double-click `安装.cmd`**:

```
Double-click → click "Yes" on the UAC prompt → done automatically: install → set the parent password → health check
```

**Restrictions start the moment installation finishes**; no further configuration needed.

For day-to-day use, **double-click `日常.cmd`** (the daily menu launcher), which prints a Chinese-language menu:

```
    1. 我自己要用电脑（临时解除限制，需要密码）
    2. 看看孩子最近碰了什么
    3. 体检（不改任何设置）
    4. 改「能玩的时间」
    5. 切换「拦截 / 只记录」模式
    6. 彻底卸载
    0. 退出
```

> The menu is printed in Chinese. In order: **1** I need the computer myself (lift restrictions temporarily, password required) · **2** See what my child has been up to · **3** Health check (changes nothing) · **4** Change the play window · **5** Switch block / log-only mode · **6** Full uninstall · **0** Exit.

### Command Line

```powershell
powershell -ExecutionPolicy Bypass -File .\gamecurfew.ps1 -Wizard
```

See **[傻瓜指南.md](傻瓜指南.md)** (the step-by-step guide, in Chinese) for what you should see at every step.

---

## How It Works

### Two Scheduled Tasks

| Task | Identity | Trigger | What it does |
|---|---|---|---|
| `SystemHealthMonitor` | Target account | At logon + every 1 minute | Enumerates window titles every 0.9 seconds, closes matching windows, writes the log |
| `SystemHealthService` | SYSTEM | At boot + every 5 minutes | hosts switching, process blocking, self-healing, log archiving, heartbeat |

**Why two are required**: `SystemHealthService` runs in the SYSTEM session (session 0) and **cannot see the user's windows**, while closing a window has to happen inside the user session. Conversely, editing hosts and terminating arbitrary processes need SYSTEM privileges. So the work is split in half, and `IgnoreNew` plus a per-minute repeat trigger is what makes "kill it and it comes back on its own" work.

### Three Layers of Blocking

| Layer | Mechanism | What it blocks |
|---|---|---|
| Process | Terminates the process after three-way matching | The Minecraft client, Mini World |
| Window | Closes the window after tiered title matching | Baidu keyword searches, Bilibili video browsing |
| Domain | hosts + DoH disabled | Direct connections to `mc.163.com` and similar |
| Self-healing | Periodic verification and repair of processes / files / hosts | Common removal attempts |

### How Stealth Is Achieved

- Scheduled tasks are registered with `-Hidden` and **do not show up in Task Scheduler's default view**
- A VBS silent launcher (`WScript.Shell.Run(..., 0, False)`) eliminates the black PowerShell window flash
- No install record, no shortcut in the Startup folder, no tray icon
- **The traces left behind deliberately avoid the project name**: the directory is `C:\ProgramData\SystemHealth`,
  the tasks are `SystemHealthMonitor` / `SystemHealthService`.
  A child who stumbles onto them won't connect them to "parental control software."

### Log Tamper Resistance

The log file **must be writable by the target account** (otherwise the monitoring process can't write to it at all). That means the target account can, in principle, delete it.

Therefore:

- Every 5 minutes the SYSTEM task archives newly written log entries into `cache\` (a directory only SYSTEM/Administrators can access)
- The archiving logic detects a **drop in line count**, treats it as tampering, and records it separately
- Log rotation is handled **entirely by the privileged side** — if the monitoring process truncated the log itself, the sudden drop in line count would be misread as "the log was deleted or altered," spraying false alarms. **A false alarm is worse than no alarm: it teaches you to stop trusting the log.**

> Tightening the log ACL to "append-only, no delete" was tried as a cure and **failed in practice**: both `(WD,AD)` and `(WD,AD,WEA,WA,RC)`
> make `Add-Content` fail with Access denied (.NET asks for the full `GENERIC_WRITE` mask).
> For a monitoring tool, silently losing the entire log is far worse than "the log can be deleted," so `(M)` was kept
> and compensated for with archiving plus tamper detection.

---

## Parent Exemption: Telling You Apart from Your Child on a Shared Account

Many families **share one Windows account** between parent and child. In that case Windows sees the two of you as the same person, and every account-based mechanism fails.

GameCurfew's answer is **not to tell people apart at all, but to use a password only you know.**

### Set the Password

```powershell
.\gamecurfew.ps1 -SetPassword
```

- Only a salted hash is stored (PBKDF2-SHA256, 200,000 iterations); **no plaintext is kept, so a forgotten password cannot be recovered**
- **At least 8 characters, and not all digits** (the hash file is readable by the target account, so a short password risks an offline brute-force attack)

### Unlocking: Two Paths

**Path 1 — Interactive (recommended; the password never touches disk or your command history)**

```powershell
.\gamecurfew.ps1 -Unlock     # enter the password, pause blocking for 60 minutes
.\gamecurfew.ps1 -Lock       # restore immediately
```

**Path 2 — Environment variable (no administrator rights, no UAC prompt)**

```powershell
setx GAMECURFEW_PARENT "your password"
```

Each cycle, the monitoring process reads this variable from `HKCU\Environment` and compares a hash computed with the same salt and iteration count:

- Match → parent mode begins (60 minutes by default)
- **Whether it matches or not, the environment variable is deleted immediately**, so the plaintext password doesn't sit in the registry

| | `-Unlock` | `setx` |
|---|---|---|
| Plaintext password written to disk | Never written | Briefly written to the registry + possibly in command history |
| Requires UAC | Yes | **No** |
| Takes effect | Immediately | After at most one scan cycle (about 1 second) |
| Expires automatically | Yes | Yes |

> Both paths **expire automatically**. That's the key advantage of a password over a static switch — even if you forget to lock it again, it won't stay open forever.

### Which Operations Require the Password

| Operation | Password required? |
|---|---|
| Pause blocking / temporary unlock | ✅ Yes |
| Switch to log-only mode | ✅ Yes |
| Change the play window | ✅ Yes |
| Full uninstall | ✅ Yes |
| Switch back to enforcing, view logs, health check | ❌ No (tightening restrictions needs no authorization) |

After 5 wrong attempts in a row the tool **cools down for 15 minutes** to prevent guessing (`parentFailLimit` is configurable).

---

## Configuration

Config file: `C:\ProgramData\SystemHealth\settings.json` (changes **take effect automatically within 15 seconds, no restart needed**)

The most commonly used fields:

| Field | Description |
|---|---|
| `allowedWindow` | The play window. Starts at `startDay`/`startTime`, ends at `endDay`/`endTime`; **cross-midnight ranges supported**. Days are full English names |
| `mode` | `enforce` = actually block (**default**); `dryrun` = log only, useful when chasing false positives |
| `keywordsStrong` | Strong keywords; a single hit blocks |
| `keywordsWeak` + `weakThreshold` | Weak keywords; blocked only when `weakThreshold` of them (default 2) hit at once |
| `action` | `CloseWindow` / `KillProcess` / `LogOnly` |
| `parentUnlockMinutes` | How long until restrictions resume after an unlock; default 60 |
| `parentFailLimit` | How many wrong attempts are allowed within 15 minutes; default 5 |
| `domains` | The domain list used for the hosts fallback |
| `processNames` / `processPathMarkers` / `processCmdlineMarkers` | The three rules for process blocking |
| `exemptUsers` | Accounts that are not monitored. **Has no effect on a shared account** — use the password instead |

Example: change it to "Friday noon to Saturday 9 a.m."

```json
"allowedWindow": {
  "startDay": "Friday",  "startTime": "12:00",
  "endDay":   "Saturday", "endTime":  "09:00"
}
```

---

## Common Commands

```powershell
.\gamecurfew.ps1 -Wizard       # all-in-one: install + set password + health check
.\gamecurfew.ps1 -Menu         # daily menu (same as double-clicking 日常.cmd)
.\gamecurfew.ps1 -SelfTest     # health check: time window + keyword false-positive regression (no administrator needed)
.\gamecurfew.ps1 -Report       # log summary + liveness heartbeat (no administrator needed)
.\gamecurfew.ps1 -TestTitle "我的世界_百度搜索"   # test whether a single title would be blocked
.\gamecurfew.ps1 -SetPassword  # set the parent password
.\gamecurfew.ps1 -Unlock / -Lock                  # unlock / restore immediately
.\gamecurfew.ps1 -SetWindow "Friday 12:00,Saturday 09:00"   # change the play window
.\gamecurfew.ps1 -ToggleMode   # switch between block / log-only
.\gamecurfew.ps1 -Uninstall    # full uninstall
```

Steps that need administrator rights **raise a single UAC prompt**; `-SelfTest` / `-Report` / `-TestTitle` do not.

---

## Do These Two Things Before You Start

### ⚠️ 1. Check the NetEase Parent Platform First (Free, Highest Priority)

Open **`jiazhang.gm.163.com`** (NetEase's official "Minor Protection Platform", free of charge).

The NetEase edition's official site states plainly: **underage players can only log in on Fridays, Saturdays, Sundays, and public holidays between 20:00 and 21:00.**

In other words, **if your child's account is registered under their own real name as a minor, they simply cannot get into the game on Friday afternoon — the game blocks itself**, and for most of the week this project isn't needed. Conversely, if their account is registered with an adult's ID card, anti-addiction doesn't apply, and this project is what you need.

**This step comes before installing any software.**

### ⚠️ 2. Quit Your Antivirus Before Installing

What this project does (create hidden scheduled tasks + use wscript to launch a hidden PowerShell window + edit hosts + terminate processes) **is exactly the classic malware behavior chain**, so Huorong (火绒), 360 Total Security (360), and Tencent PC Manager (腾讯电脑管家) are likely to block or quarantine it.

- Before installing: right-click the tray icon → Exit
- After installing: add `C:\ProgramData\SystemHealth` to the allowlist, then let the antivirus start with Windows again

This is not a bug, and it should not be worked around in code (**bypassing antivirus software is itself malicious behavior**).

---

## Security Notes

This is a tool for **home use**, and the threat model is **a child who isn't particularly good with computers**, not a professional adversary.
With that in mind, the issues fixed during development are listed below for review:

| Issue | Impact | Fix |
|---|---|---|
| The environment variable was only consumed when "not skipped" | A password set with `setx` during a pause/exemption would **stay in the registry as plaintext forever** | Now **read and cleared unconditionally** |
| Pause / switch to log-only / change window / uninstall **performed no password check at all** | Anyone who knew the script existed could bypass the password or uninstall | All of them now go through `Confirm-ParentAuth` |
| `parentFailLimit` was a dead setting | The password could be brute-forced without limit | Actually implemented: a 15-minute counting window + cooldown |
| No password strength requirement | The hash of a short password could be brute-forced offline | At least 8 characters, all-digit passwords rejected |
| Uninstall deleted `DnsOverHttpsMode` unconditionally | It would delete a policy **someone else** had set on the machine | Now deleted only when the value really is `off` |
| Uninstall didn't clean up the leftover environment variable | The password could remain in the registry | Cleared as well |
| Log rotation ran inside the monitoring process | A sudden drop in line count was misread as "the log was deleted or altered," spraying false alarms | Rotation moved entirely to the privileged side |

### Known, Unfixed Security Boundaries

- **The log file can be deleted by the target account** (it has to be writable for logging to work). Mitigation: archiving + tamper detection + heartbeat.
- **`settings.json` can be read by the target account**, including the keyword lists and the password hash. Mitigation: the hash uses PBKDF2
  with 200,000 iterations plus enforced password strength; the keyword lists rely on being *inconspicuous* rather than encrypted.
- **If the target account is an administrator, it can stop the tasks, delete files, and edit the registry.** Against an administrator, a pure-software solution only raises the bar.
- **A forgotten password means uninstalling by hand** (`-Uninstall` will refuse). The steps are printed when an uninstall is attempted without it.

---

## FAQ

**Will my child find out?**
The software itself stays hidden (no window, no tray icon, hidden tasks, a neutral directory name). But **the blocking itself cannot be hidden** — a video cutting out or a game that won't launch will be noticed. Make **the rule known and keep the implementation hidden**; see [Design Tradeoffs](#design-tradeoffs) for the reasoning.

**Can my child get around it as an administrator?**
Yes. Against an administrator, any pure-software solution only raises the bar. But a child who isn't comfortable with computers won't go digging through Task Scheduler or `C:\ProgramData`. The real dividing line is account type plus physical/firmware-level control.

**Why are the installed files called `SystemHealth` instead of the project name?**
Deliberately. A neutral name doesn't invite associations.

**The log is always empty?**
① You may be inside the play window right now, where nothing is blocked anyway; ② the antivirus may be blocking it — run `-SelfTest` and check whether "privileged task last run" is more than 12 minutes ago; if it is, the task has been disabled.

**Can it manage phones?**
No. This is a Windows-only solution.

**Can it block Minecraft videos in Douyin / Kuaishou?**
No. Their PC clients use a fixed application name as the window title (such as 抖音), which doesn't include the video title.
Either add `douyin.exe` to `processNames` to ban the whole app, or leave it alone.
**Bilibili in a browser and Baidu search are unaffected by this.**

**What if I forget the password?**
Operations such as changing the window or uninstalling will refuse to run, but **manual uninstall steps** are printed
(delete the two scheduled tasks + delete the directory + clean up the hosts section).

---

## Known Limitations

1. **If the target account is an administrator, everything can be bypassed.** Safe Mode and reinstalling Windows are the same story; there is no fix.
2. **Antivirus software may block it** (see above).
3. **Phones and tablets are completely out of reach.**
4. **Native clients such as Douyin and Kuaishou use a fixed application name as the window title**, so the tool cannot tell what is playing inside them.
5. **Browser-based / online Minecraft games** may use generic titles that can't be caught.
6. **`exemptUsers` has no effect on a shared account** — use the parent password.
7. **The log can be deleted by the target account** (tightening the ACL was tried and doesn't work); archiving + tamper detection compensate.
8. **The keyword list can be read**: `settings.json` is readable by the target account (the monitoring process has to read it).
   What can be done here is being inconspicuous, not encryption.
9. **Scheduled task registration and ACL configuration have not been verified on a real machine** (the development machine has no administrator rights, and the author does not test on production machines).

---

## Design Tradeoffs

**Why default to `enforce` rather than observing first?**
Because parents want something that works the moment it's installed. The cost is that it may block you too — hence the password unlock (which expires automatically) and the one-key switch to log-only mode as escape hatches.

**Why not do HTTPS interception for real content filtering?**
It would require installing a local root certificate, HTTPS interception breaks apps that use certificate pinning, and deploying it on Windows isn't realistic.
Window titles get 95% of the effect at zero cost.

**Why not distinguish users by default?**
On a shared account it's technically impossible; and on separate accounts it **isn't necessary** — the criterion is "you don't need access to Minecraft-related content," not "who you are."

**Why not build a graphical interface?**
A GUI has a window, a tray icon, and an install record — all of which violate the core requirement of stealth. PowerShell plus scheduled tasks leaves none of those traces and needs zero dependencies.

**Why is there not a single Chinese character in the `.cmd` files?**
cmd.exe reads batch files by **byte offset**. Any code-page switch (`chcp`) or non-ASCII byte shifts those offsets and splits a line down the middle (in practice the error looks like `'ent' 不是内部或外部命令` — "'ent' is not recognized as an internal or external command").
So the launchers stay pure ASCII with 0 non-ASCII bytes, and all Chinese UI output is left to PowerShell —
PowerShell uses the Unicode console API and behaves correctly under any code page.

---

## File Reference

| File | Description |
|---|---|
| `gamecurfew.ps1` | The main program. Install / monitor / privileged / uninstall / self-test all live in this one file |
| `安装.cmd` | One-click install launcher (double-click; pure ASCII) |
| `日常.cmd` | Daily menu launcher (double-click; pure ASCII) |
| `傻瓜指南.md` | Step-by-step guide (in Chinese), including "what you should see at each step" |

What gets laid down on the target machine after installation:

```
C:\ProgramData\SystemHealth\
    ├─ settings.json   configuration (readable; changes take effect in 15 seconds)
    ├─ trace.log       blocking log (JSONL)
    ├─ core.ps1        window monitoring
    ├─ admin.ps1       privileged task
    ├─ runc.vbs / runa.vbs   silent launchers
    └─ cache\          SYSTEM-only: archives, heartbeat, script backups
```

---

## Uninstall

Double-click `日常.cmd` → choose `6` → type `Y` → enter the parent password.
This removes the two scheduled tasks, the hosts block section, the DoH registry entries that were written, any leftover environment variables,
and the entire `C:\ProgramData\SystemHealth` directory.

```powershell
.\gamecurfew.ps1 -Uninstall
```

> Forgotten password: the uninstall is refused, but the manual uninstall steps are printed.

---

## License

MIT

# Reinstall Kit · Windows 重装后一键装回软件

重装完 Windows，双击一个 bat，把清单里的软件全部自动下载、静默安装（含微信/QQ/百度网盘/VS Code/Git/VC++ 运行库等），装完给出**成功 / 需手动 / 跳过 / 失败**四类结果汇总。

适合：定期重装系统的人、给别人装机的、想把"我的电脑环境"变成一份可复用清单的人。

```text
复制 reinstall-kit 文件夹到 U 盘  →  重装系统  →  双击 一键安装软件.bat  →  等它跑完
```

## 特性

- **清单驱动**：所有软件写在 `apps.json` 里，增删改用编辑器改 JSON 就行，不用碰脚本。
- **四级安装策略**：`winget` 源优先 → 失败自动回退 `msstore` / 官方直链 / GitHub 最新 release 动态解析。
- **自动修 winget**：新系统上 winget 缺失或损坏时，脚本会自动装 `Microsoft.WinGet.Client` 模块并 `Repair-WinGetPackageManager`，再不行直接下 App Installer 安装包。
- **幂等**：已装的软件靠 winget 自身和注册表 `detect` 判断，重复运行不会重复装；`downloads\` 里的安装包会被复用，不重复下载。
- **可演练**：`-DryRun` 只打印计划不装东西；`-Only` / `-Skip` 支持通配符挑软件。
- **全程留痕**：`install-log.txt` 记录每一步，`install-result.csv` 输出结构化结果，失败项可单独重跑。
- **纯 PowerShell + JSON**：无第三方依赖、无编译、无安装器，Windows 自带 PowerShell 5.1 即可运行。

## 目录结构

```text
reinstall-kit/
├─ 一键安装软件.bat      # 双击入口（自动提权、调用 bootstrap.ps1）
├─ bootstrap.ps1         # 主脚本：环境自检 → 修 winget → 按清单安装 → 汇总
├─ apps.json             # 软件清单（唯一需要你维护的文件）
├─ post-setup.ps1        # 可选：装完后的配置恢复（git 配置、VS Code 插件、镜像源…）
├─ README.md
└─ （运行后生成）install-log.txt / install-result.csv / downloads\
```

## 快速开始

1. 下载或克隆本仓库，整个文件夹拷到 U 盘 / 网盘 / 移动硬盘。
2. 重装系统后先装好网卡驱动、连上网。
3. 双击 `一键安装软件.bat`，UAC 弹窗点"是"，等它跑完。

不想双击、想用命令行（在项目目录里打开 PowerShell）：

```powershell
.\bootstrap.ps1                        # 装清单里所有启用的项
.\bootstrap.ps1 -DryRun                # 只演练：打印将要执行的动作，不实际安装
.\bootstrap.ps1 -Only "Git*","微信"     # 只装匹配的项（支持通配符，可多个）
.\bootstrap.ps1 -Skip "Steam*"         # 排除匹配的项
.\bootstrap.ps1 -IncludeDisabled       # 连 enabled=false 的项也一起装
.\bootstrap.ps1 -Interactive           # 直链软件静默安装失败时改为弹出安装界面
.\bootstrap.ps1 -ExportCurrent         # 不安装，改为导出本机已装软件清单
.\bootstrap.ps1 -SkipWingetSetup       # 不尝试自动修复 winget
```

完整参数：`Get-Help .\bootstrap.ps1 -Full`

## 工作原理

```text
读 apps.json
   │
   ├─ 权限检查（非管理员则自动 UAC 提权后重跑）
   ├─ 环境自检（TLS1.2 / winget 是否可用）
   │     └─ winget 不可用 → 装 Microsoft.WinGet.Client → Repair-WinGetPackageManager
   │                       → 仍失败则下载 App Installer(msixbundle) + VCLibs 安装
   │
   └─ 逐条安装
         winget / msstore ──> winget install -e --id ... --silent
                 │ 失败或跳过
                 └─> fallback：url 直链 或 github 最新 release 资产
         url   ──> 下载到 downloads\ → 按 args 静默安装（容忍 1641/3010 等成功码）
         github──> 调 GitHub API 取最新 release → 按通配符选资产 → 同 url 流程
         manual──> 只打印下载地址，不安装
   │
   └─ 汇总结果 + 写 install-log.txt / install-result.csv
```

设计取舍：

- **能用 winget 就用 winget**：版本自动最新，不用维护链接。
- **直链只当备用**：除少数几个真正稳定的地址外，直链都带版本号，会随版本失效。
- **GitHub 项目走 API 解析**：`/releases/latest/download/<文件名>` 对资产名内嵌版本号的项目（如 Clash Verge Rev）必然 404，所以用 API 按通配符筛资产。

## 软件清单

清单在 [`apps.json`](apps.json)，当前 17 条，其中 15 条默认安装：

| 软件 | 方式 | 包 ID / 来源 |
| --- | --- | --- |
| Git for Windows | winget | `Git.Git` |
| Node.js (LTS) | winget | `OpenJS.NodeJS.LTS` |
| Python 3.13 | winget | `Python.Python.3.13` |
| Visual Studio Code | winget | `Microsoft.VisualStudioCode`（有稳定直链兜底） |
| Microsoft Visual C++ 2015-2022 运行库 (x64 / x86) | winget | `Microsoft.VCRedist.2015+.x64` / `.x86` |
| 微信 | winget | `Tencent.WeChat.Universal`（4.x 新版） |
| QQ | winget | `Tencent.QQ.NT`（NT 新版） |
| 百度网盘 | winget | `Baidu.BaiduNetdisk`（直链兜底，容忍退出码 2） |
| Bandizip | winget | `Bandisoft.Bandizip`（官方稳定直链兜底） |
| PotPlayer | winget | `Daum.PotPlayer`（官方稳定直链兜底） |
| Clash Verge Rev | winget | `ClashVergeRev.ClashVergeRev`（GitHub 最新版兜底） |
| 网易 UU 加速器 | 仅提示 | <https://uu.163.com/download/>（需手动，见下） |
| UU 远程 | winget | `NetEase.UURemote` |
| 腾讯 WorkBuddy | winget | `Tencent.WorkBuddy` |
| Google Chrome | winget | `Google.Chrome`（默认关闭） |
| Steam | winget | `Valve.Steam`（默认关闭） |

**唯一需要手动装的**是网易 UU 加速器：官网下载按钮由 JS 生成，页面上没有稳定直链，推测的 CDN 地址返回 403，只能自行下载安装。

## 清单字段说明

```json
{
  "name": "微信",                       // 显示名，-Only/-Skip 匹配的就是它
  "category": "常用",                   // 仅用于分类阅读
  "source": "winget",                   // winget / msstore / url / github / manual
  "id": "Tencent.WeChat.Universal",     // source=winget|msstore 时填包 ID
  "enabled": true                       // false = 默认不装
}
```

| 字段 | 说明 |
| --- | --- |
| `source` | `winget`（winget 源）、`msstore`（微软商店，`id` 填 Store ProductId）、`url`（直链下载后安装）、`github`（从 GitHub 最新 release 按通配符找资产）、`manual`（只提示不安装） |
| `id` | winget 包 ID 或 msstore ProductId |
| `url` / `fileName` | 直链地址 / 下载后保存的文件名（留空则从 URL 推断，支持百分号编码的中文文件名） |
| `repo` / `asset` | `source=github` 时用：`owner/repo` 与资产通配符，例如 `*-windows-amd64.exe` |
| `args` | 静默安装参数数组，例如 `["/S"]`、`["/VERYSILENT","/NORESTART"]` |
| `detect` | 注册表软件名包含该字符串就认为已装，直接跳过（用于直链/manual 条目） |
| `successCodes` | 额外的"成功"退出码，例如百度网盘安装器成功时返回 `2` |
| `fallback` | 主方式失败或跳过时改用的备用方案，写法同一条普通条目 |
| `note` | 给人看的说明，会打进日志 |

经验与坑：

- **GitHub 项目不要写 `/releases/latest/download/<文件名>`**：资产名里带版本号时必然 404，用 `source: "github"` + `asset`。未认证的 GitHub API 限额 60 次/小时，正常装机够用。
- **真正稳定的直链只有少数几个**：PotPlayer 的 `.../Version/Latest/PotPlayerSetup64.exe`、Bandizip 的 `bandisoft.app/bandizip/BANDIZIP-SETUP-STD-X64.EXE`、VS Code 的 `update.code.visualstudio.com/latest/win32-x64-user/stable`。
- **同名不同版**：微信 4.x 是 `Tencent.WeChat.Universal`（3.9 是 `Tencent.WeChat`），QQ 新版是 `Tencent.QQ.NT`（经典版是 `Tencent.QQ`）。
- 找包 ID：`winget search 关键词`，或查 <https://winget.run> / <https://winstall.app>。
- `fallback` 生效时结果表会多一行（主方式一行、备用方式一行），看最后一行的状态即可。
- 编辑 `apps.json` 请保持 **UTF-8（带 BOM）** 编码，否则 PowerShell 5.1 读中文可能乱码。

## 装完之后的配置恢复（可选）

把 `apps.json` 里 `postSetup.enabled` 改成 `true`，脚本会在安装流程结束后执行 `post-setup.ps1`，里面有现成的例子：

- 把同目录的 `.gitconfig` / `.gitconfig-ghproxy` 拷回用户目录
- 安装 VS Code 插件
- 设置 npm / pip 国内镜像
- 建常用目录

按需删除不需要的段落即可，脚本不依赖任何外部文件。

## 离线安装

先在正常系统上跑一次，让 `downloads\` 下全安装包，再把整个文件夹拷到新系统；有缓存的直链条目不会重复下载。注意走 winget 的条目在离线环境下需要另用 `winget download` 保存安装包，或者给它们补一条指向本地安装包的 `fallback`。

## 更新清单 / 迁移到新机器

在已经装好软件的机器上：

```powershell
.\bootstrap.ps1 -ExportCurrent
```

会生成 `apps.generated.json`（本机全部已装软件）和 `winget-export.json`（winget 可识别的包 ID），据此更新 `apps.json`。

## 常见问题

- **提示 winget 不可用**：脚本会自动修复；仍失败就去 Microsoft Store 装"应用安装程序 / App Installer"，或访问 <https://aka.ms/getwinget>，然后重跑。
- **报"无法加载文件……在此系统上禁止运行脚本"**：用 `一键安装软件.bat` 启动（已带 `-ExecutionPolicy Bypass`），或执行 `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1`。
- **某个软件装失败**：单独重试，`.\bootstrap.ps1 -Only "软件名" -Interactive`。
- **结果里"跳过"很多**：说明 winget 不可用且该条目没有 `fallback`；修好 winget 后重跑即可。
- **安装器弹了界面**：该软件的静默参数未知（例如图吧工具箱类的第三方安装包），按提示手动点完即可，脚本会等它结束。

## 免责声明

- 脚本会**静默安装软件并修改系统状态**（装包、可能写入 PATH）。运行前请确认 `apps.json` 里就是你要装的东西，首次使用建议先 `-DryRun` 看一遍。
- 清单里的直链来自各软件官方站点或 GitHub Release，但第三方安装包的行为不受本仓库控制；请自行判断是否信任。
- 本项目按"现状"提供，不对因使用造成的系统或数据问题负责。

## 许可

未指定许可证。如需开源，建议加一个 MIT 或 Apache-2.0 的 `LICENSE` 文件。

## 致谢

清单里的 winget 包 ID 与官方直链经联网核对（winget-pkgs、各软件官网、GitHub API），核对时点为 2026-10；winget-pkgs 每日更新，实际装机时可用 `winget upgrade` 复核。

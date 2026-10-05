<#
.SYNOPSIS
    重装 Windows 之后的一键软件安装脚本。

.DESCRIPTION
    读取同目录的 apps.json，按顺序执行：
      1. 自检环境（管理员权限、TLS、winget 是否可用，不可用则尝试修复/安装）
      2. 用 winget / msstore 安装清单里的软件
      3. 对没有 winget 包的软件，下载官方直链并静默安装
      4. 打印结果汇总，并写出 install-log.txt / install-result.csv

.PARAMETER Manifest
    清单文件路径，默认脚本同目录的 apps.json。

.PARAMETER Only
    只安装名字匹配的条目（支持通配符），例如 -Only "Git*","微信"。

.PARAMETER Skip
    跳过名字匹配的条目。

.PARAMETER DownloadDir
    直链安装包的下载目录，默认脚本同目录的 downloads。

.PARAMETER IncludeDisabled
    连 apps.json 里 enabled=false 的条目一起装。

.PARAMETER DryRun
    只显示将要执行的动作，不实际安装。

.PARAMETER Interactive
    直链软件静默安装失败时，改为弹出交互式安装界面重试。

.PARAMETER SkipWingetSetup
    winget 不可用时不要尝试自动修复，直接用直链/manual 部分。

.PARAMETER ExportCurrent
    不安装任何东西，改为把当前机器已安装的软件导出为 apps.generated.json（用于以后更新清单）。

.EXAMPLE
    .\bootstrap.ps1
    装清单里所有 enabled 的软件。

.EXAMPLE
    .\bootstrap.ps1 -Only "Git*","Node*","Python*"
    只装开发环境。

.EXAMPLE
    .\bootstrap.ps1 -DryRun
    先看一眼它会做什么。
#>
[CmdletBinding()]
param(
    [string]$Manifest,
    [string[]]$Only,
    [string[]]$Skip,
    [string]$DownloadDir,
    [switch]$IncludeDisabled,
    [switch]$DryRun,
    [switch]$Interactive,
    [switch]$SkipWingetSetup,
    [switch]$NoElevate,
    [switch]$ExportCurrent
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- 基础工具

# 注意：Windows PowerShell 5.1 在 param() 默认值里取 $PSScriptRoot 会得到空串，
# 所以脚本目录一律在这里解析。
$script:ScriptPath = $PSCommandPath
if (-not $script:ScriptPath) { $script:ScriptPath = $MyInvocation.MyCommand.Path }
$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $script:ScriptPath }
if (-not $Manifest) { $Manifest = Join-Path $script:Root 'apps.json' }

$script:LogFile = Join-Path $script:Root 'install-log.txt'
$script:Results = New-Object System.Collections.ArrayList

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    $line = "[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Add-Result {
    param([string]$Name, [string]$Source, [string]$Status, [string]$Detail = '')
    [void]$script:Results.Add([pscustomobject]@{
            Name   = $Name
            Source = $Source
            Status = $Status
            Detail = $Detail
        })
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Argument {
    param([string]$Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }
}

# ---------------------------------------------------------------- 权限提升

if (-not (Test-Administrator)) {
    if ($NoElevate) {
        Write-Log '当前不是管理员，继续执行但部分软件可能装不上（-NoElevate）。' 'WARN'
    }
    else {
        Write-Log '需要管理员权限，正在请求提升（会弹出 UAC 确认框）。' 'WARN'
        $exe = $null
        try { $exe = (Get-Process -Id $PID).Path } catch { }
        if (-not $exe) { $exe = Join-Path $PSHOME 'powershell.exe' }

        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Format-Argument $script:ScriptPath))
        foreach ($key in $PSBoundParameters.Keys) {
            if ($key -in @('NoElevate')) { continue }
            $value = $PSBoundParameters[$key]
            if ($value -is [switch]) {
                if ($value.IsPresent) { $argList += "-$key" }
            }
            elseif ($value -is [array]) {
                foreach ($item in $value) { $argList += @("-$key", (Format-Argument ([string]$item))) }
            }
            else {
                $argList += @("-$key", (Format-Argument ([string]$value)))
            }
        }
        try {
            Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs | Out-Null
        }
        catch {
            Write-Log "权限提升被取消或失败：$($_.Exception.Message)" 'ERROR'
            Write-Log '请右键“以管理员身份运行”后重试。' 'ERROR'
            exit 1
        }
        exit 0
    }
}

Write-Log "===== 软件自动安装开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====" 'STEP'
Write-Log "清单文件：$Manifest" 'INFO'
Write-Log "日志文件：$script:LogFile" 'INFO'
Enable-Tls12

if (-not $DownloadDir) { $DownloadDir = Join-Path $script:Root 'downloads' }

# ---------------------------------------------------------------- 导出当前机器软件

function Export-CurrentSoftware {
    param([string]$OutputPath)

    Write-Log '正在枚举当前机器已安装的软件 …' 'STEP'
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $rows = @()
    foreach ($key in $keys) {
        $rows += Get-ItemProperty $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
            Select-Object DisplayName, DisplayVersion, Publisher
    }
    $apps = @()
    foreach ($row in ($rows | Sort-Object DisplayName -Unique)) {
        $apps += [pscustomobject]@{
            name    = $row.DisplayName
            version = $row.DisplayVersion
            source  = 'manual'
            note    = '由 -ExportCurrent 生成，请把 source 改成 winget 并补上 id，或补上官方直链'
            enabled = $false
        }
    }
    $payload = [pscustomobject]@{ version = 1; generatedAt = (Get-Date).ToString('s'); apps = $apps }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    Write-Log "已导出 $($apps.Count) 项到 $OutputPath" 'OK'

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        $wingetDump = Join-Path (Split-Path $OutputPath -Parent) 'winget-export.json'
        Write-Log "另外执行 winget export -o $wingetDump（包含可直接复用的 winget 包 ID）" 'INFO'
        & winget export -o $wingetDump --include-versions --accept-source-agreements 2>&1 |
            ForEach-Object { Write-Log "  $_" 'INFO' }
    }
}

if ($ExportCurrent) {
    Export-CurrentSoftware (Join-Path $script:Root 'apps.generated.json')
    exit 0
}

# ---------------------------------------------------------------- 读取清单

if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Log "找不到清单文件：$Manifest" 'ERROR'
    exit 1
}
try {
    $config = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Log "清单文件不是合法 JSON：$($_.Exception.Message)" 'ERROR'
    exit 1
}

$selected = @()
foreach ($app in $config.apps) {
    if (-not $app.enabled -and -not $IncludeDisabled) { continue }
    if ($Only) {
        $hit = $false
        foreach ($pattern in $Only) { if ($app.name -like $pattern) { $hit = $true; break } }
        if (-not $hit) { continue }
    }
    if ($Skip) {
        $hit = $false
        foreach ($pattern in $Skip) { if ($app.name -like $pattern) { $hit = $true; break } }
        if ($hit) { continue }
    }
    $selected += $app
}
Write-Log "本次将处理 $($selected.Count) 项。" 'INFO'

# ---------------------------------------------------------------- 已安装检测

function Get-InstalledSoftwareNames {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $names = @()
    foreach ($key in $keys) {
        $names += (Get-ItemProperty $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } | Select-Object -ExpandProperty DisplayName)
    }
    return $names
}

$script:InstalledNames = Get-InstalledSoftwareNames

function Test-AlreadyInstalled {
    param($App)
    $pattern = $App.detect
    if (-not $pattern) { return $false }
    foreach ($name in $script:InstalledNames) {
        if ($name -like "*$pattern*") { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- winget

function Test-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try {
        $null = & $cmd.Source --version 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
}

$script:WingetOk = Test-Winget
$script:WingetNote = ''

function Initialize-Winget {
    if ($script:WingetOk) {
        Write-Log "winget 可用：$((& winget --version 2>&1 | Select-Object -First 1))" 'OK'
        return
    }
    if ($SkipWingetSetup) {
        $script:WingetNote = 'winget 不可用，且指定了 -SkipWingetSetup，未尝试自动修复'
        Write-Log "$($script:WingetNote)，将跳过 winget 相关条目。" 'WARN'
        return
    }

    Write-Log 'winget 不可用（未安装或已损坏），尝试自动修复 …' 'WARN'

    # 方案一：用微软官方 PowerShell 模块修复（Win10 1809+ / Win11 首选）
    try {
        Write-Log '尝试安装 Microsoft.WinGet.Client 模块并修复 App Installer …' 'INFO'
        & winget --version 2>&1 | Out-Null
        if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
            }
            Install-Module Microsoft.WinGet.Client -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -Force -ErrorAction Stop
    }
    catch {
        Write-Log "模块修复失败：$($_.Exception.Message)" 'WARN'
    }

    if (Test-Winget) {
        $script:WingetOk = $true
        Write-Log 'winget 修复成功。' 'OK'
        return
    }

    # 方案二：直接下载 App Installer 安装包
    try {
        Write-Log '改为直接下载 Microsoft.DesktopAppInstaller 安装包 …' 'INFO'
        $cache = Join-Path $DownloadDir 'winget'
        New-Item -ItemType Directory -Force -Path $cache | Out-Null
        $headers = @{ 'User-Agent' = 'Mozilla/5.0' }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers $headers -UseBasicParsing
        $bundle = $release.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1
        $license = $release.assets | Where-Object { $_.name -like '*License*.xml' } | Select-Object -First 1
        if (-not $bundle) { throw '未在 GitHub Release 中找到 msixbundle' }

        $bundlePath = Join-Path $cache $bundle.name
        if (-not (Test-Path $bundlePath)) {
            Invoke-WebRequest -Uri $bundle.browser_download_url -OutFile $bundlePath -Headers $headers -UseBasicParsing
        }
        $licensePath = $null
        if ($license) {
            $licensePath = Join-Path $cache $license.name
            if (-not (Test-Path $licensePath)) {
                Invoke-WebRequest -Uri $license.browser_download_url -OutFile $licensePath -Headers $headers -UseBasicParsing
            }
        }

        # 依赖：VCLibs（多数精简系统缺失）
        $vclibs = Join-Path $cache 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
        if (-not (Test-Path $vclibs)) {
            try { Invoke-WebRequest -Uri 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -OutFile $vclibs -Headers $headers -UseBasicParsing }
            catch { Write-Log "VCLibs 下载失败（可忽略）：$($_.Exception.Message)" 'WARN' }
        }
        if (Test-Path $vclibs) {
            try { Add-AppxPackage -Path $vclibs -ErrorAction Stop } catch { Write-Log "VCLibs 安装跳过：$($_.Exception.Message)" 'WARN' }
        }

        if ($licensePath) {
            Add-AppxPackage -Path $bundlePath -DependencyPath @() -ErrorAction Stop
        }
        else {
            Add-AppxPackage -Path $bundlePath -ErrorAction Stop
        }
    }
    catch {
        Write-Log "App Installer 安装失败：$($_.Exception.Message)" 'WARN'
    }

    if (Test-Winget) {
        $script:WingetOk = $true
        Write-Log 'winget 安装成功。' 'OK'
    }
    else {
        $script:WingetNote = 'winget 不可用：请手动从 Microsoft Store 安装“应用安装程序 / App Installer”，或访问 https://aka.ms/getwinget 安装。win 相关的条目将被跳过。'
        Write-Log $script:WingetNote 'ERROR'
    }
}

function Invoke-WingetInstall {
    param($App)

    $source = 'winget'
    $arguments = @('install', '--exact', '--id', $App.id, '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($App.source -eq 'msstore') {
        $source = 'msstore'
        $arguments += @('--source', 'msstore')
    }
    if ($App.scope) { $arguments += @('--scope', $App.scope) }
    if ($App.extraArgs) { $arguments += $App.extraArgs }

    if ($DryRun) {
        Write-Log "[DryRun] winget $($arguments -join ' ')" 'STEP'
        Add-Result $App.name $source 'DRYRUN' ($arguments -join ' ')
        return
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Log ("[$($App.name)] winget 安装（第 {0}/3 次）…" -f $attempt) 'STEP'
        $output = & winget @arguments 2>&1
        $code = $LASTEXITCODE
        foreach ($line in $output) {
            $text = "$line".Trim()
            if ($text) { Write-Log "    $text" 'INFO' }
        }
        $joined = ($output | Out-String)

        if ($code -eq 0) {
            Write-Log "[$($App.name)] 安装成功。" 'OK'
            Add-Result $App.name $source 'OK' ''
            return
        }
        if ($joined -match 'already installed|已安装|没有可用的升级|No available upgrade') {
            Write-Log "[$($App.name)] 已安装，跳过。" 'OK'
            Add-Result $App.name $source '已安装' ''
            return
        }
        # 0x8A15002B = 已安装
        if ($code -eq -1978335189) {
            Write-Log "[$($App.name)] 已安装，跳过。" 'OK'
            Add-Result $App.name $source '已安装' ''
            return
        }
        Write-Log "[$($App.name)] 失败，winget 退出码 $code" 'WARN'
        Start-Sleep -Seconds (3 * $attempt)
    }

    Add-Result $App.name $source '失败' "winget 退出码 $code"
}

# ---------------------------------------------------------------- 直链安装

function Get-InstallerFile {
    param([string]$Url, [string]$FileName)

    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $fileName = $FileName
    if (-not $fileName) {
        try { $fileName = Split-Path ([uri]$Url).AbsolutePath -Leaf } catch { $fileName = 'setup.exe' }
    }
    if (-not $fileName) { $fileName = 'setup.exe' }
    $fileName = [uri]::UnescapeDataString($fileName)
    $target = Join-Path $DownloadDir $fileName

    $needDownload = $true
    if (Test-Path -LiteralPath $target) {
        if ((Get-Item -LiteralPath $target).Length -gt 0) { $needDownload = $false }
    }
    if ($needDownload) {
        Write-Log "    下载 $Url" 'INFO'
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        $old = $ProgressPreference
        $ProgressPreference = 'Continue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $target -Headers $headers -UseBasicParsing -ErrorAction Stop
        }
        finally { $ProgressPreference = $old }
    }
    else {
        Write-Log "    已存在安装包，跳过下载：$target" 'INFO'
    }
    return $target
}

# 从 GitHub 最新 release 里按通配符挑资产。
# 注意：像 Clash Verge Rev 这类项目的资产名里带版本号，
# 直接写 .../releases/latest/download/<文件名> 一定会 404，必须走这个 API。
function Resolve-GitHubAssetUrl {
    param([string]$Repo, [string]$Pattern)

    $headers = @{ 'User-Agent' = 'reinstall-kit'; 'Accept' = 'application/vnd.github+json' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
    if (-not $asset) { throw "在 $Repo 的最新 release 里找不到匹配 [$Pattern] 的资产" }
    Write-Log "    最新版本 $($release.tag_name) → $($asset.name)" 'INFO'
    return $asset.browser_download_url
}

function Invoke-InstallerRun {
    param($App, [string]$Url)

    if (Test-AlreadyInstalled $App) {
        Write-Log "[$($App.name)] 检测到已安装，跳过。" 'OK'
        Add-Result $App.name $App.source '已安装' ''
        return
    }

    if ($DryRun) {
        if ($App.repo) {
            Write-Log "[DryRun] 从 GitHub $($App.repo) 解析最新版本，资产匹配 [$($App.asset)]，参数：$($App.args -join ' ')" 'STEP'
            Add-Result $App.name $App.source 'DRYRUN' "$($App.repo) / $($App.asset)"
        }
        else {
            Write-Log "[DryRun] 下载并安装 $Url 参数：$($App.args -join ' ')" 'STEP'
            Add-Result $App.name $App.source 'DRYRUN' $Url
        }
        return
    }

    if (-not $Url -and $App.repo) {
        try {
            $Url = Resolve-GitHubAssetUrl -Repo $App.repo -Pattern $App.asset
        }
        catch {
            Write-Log "[$($App.name)] 解析 GitHub 下载地址失败：$($_.Exception.Message)" 'ERROR'
            Add-Result $App.name $App.source '失败' "GitHub 解析失败：$($_.Exception.Message)"
            return
        }
    }

    try {
        $file = Get-InstallerFile -Url $Url -FileName $App.fileName
    }
    catch {
        Write-Log "[$($App.name)] 下载失败：$($_.Exception.Message)" 'ERROR'
        Add-Result $App.name $App.source '失败' "下载失败：$($_.Exception.Message)"
        return
    }

    $args = @()
    if ($App.args) { $args = @($App.args) }

    Write-Log "[$($App.name)] 执行安装：$file $($args -join ' ')" 'STEP'
    $proc = Start-Process -FilePath $file -ArgumentList $args -Wait -PassThru
    $code = $proc.ExitCode

    # 有些安装器用非 0 表示成功（例如百度网盘返回 2）
    $okCodes = @(0, 1641, 3010)
    if ($App.successCodes) { $okCodes += @($App.successCodes) }
    if ($okCodes -contains $code) {
        Write-Log "[$($App.name)] 安装完成（退出码 $code）。" 'OK'
        Add-Result $App.name $App.source 'OK' "退出码 $code"
        return
    }

    Write-Log "[$($App.name)] 安装器返回退出码 $code。" 'WARN'
    if ($Interactive) {
        Write-Log "[$($App.name)] 改为交互式安装，请在弹出的窗口里手动完成。" 'WARN'
        Start-Process -FilePath $file -Wait | Out-Null
        Add-Result $App.name $App.source '交互完成' "静默退出码 $code"
        return
    }
    Add-Result $App.name $App.source '失败' "退出码 $code（可加 -Interactive 手动安装）"
}

function Invoke-UrlInstall { param($App) Invoke-InstallerRun -App $App -Url $App.url }
function Invoke-GitHubInstall { param($App) Invoke-InstallerRun -App $App }

# 统一的条目分发（主流程和备用方案都走这里）
function Invoke-AppEntry {
    param($App)

    switch ($App.source) {
        { $_ -in @('winget', 'msstore') } {
            if (-not $script:WingetOk) {
                Write-Log "[$($App.name)] 跳过：$script:WingetNote" 'WARN'
                Add-Result $App.name $App.source '跳过' 'winget 不可用'
                return
            }
            Invoke-WingetInstall $App
        }
        'url' { Invoke-UrlInstall $App }
        'github' { Invoke-GitHubInstall $App }
        'manual' {
            Write-Log "[$($App.name)] 需要手动安装：$($App.url)" 'WARN'
            if ($App.note) { Write-Log "    说明：$($App.note)" 'INFO' }
            Add-Result $App.name 'manual' '需手动' $App.url
        }
        default {
            Write-Log "[$($App.name)] 未知 source：$($App.source)" 'ERROR'
            Add-Result $App.name "$($App.source)" '失败' '未知来源类型'
        }
    }
}


# ---------------------------------------------------------------- 主流程

Initialize-Winget

$index = 0
foreach ($app in $selected) {
    $index++
    Write-Log ("[{0}/{1}] {2}（{3}）" -f $index, $selected.Count, $app.name, $app.source) 'STEP'

    $before = $script:Results.Count
    Invoke-AppEntry $app

    # 主方式失败或（winget 不可用而）跳过时，如果清单里写了 fallback，就再试一次
    if ($app.fallback -and $script:Results.Count -gt $before) {
        $last = $script:Results[$script:Results.Count - 1]
        if ($last.Status -in @('失败', '跳过')) {
            $fb = $app.fallback
            Write-Log "[$($app.name)] 主方式未成功，改用备用方案（$($fb.source)）重试 …" 'WARN'
            $entry = [pscustomobject]@{
                name         = $app.name
                source       = $fb.source
                id           = $fb.id
                url          = $fb.url
                repo         = $fb.repo
                asset        = $fb.asset
                args         = $fb.args
                fileName     = $fb.fileName
                successCodes = $fb.successCodes
                detect       = $(if ($app.detect) { $app.detect } else { $fb.detect })
            }
            Invoke-AppEntry $entry
        }
    }
}

# ---------------------------------------------------------------- 可选后置配置

if ($config.postSetup -and $config.postSetup.enabled) {
    $post = Join-Path $script:Root $config.postSetup.script
    if (Test-Path -LiteralPath $post) {
        Write-Log "执行后置配置脚本：$post" 'STEP'
        if ($DryRun) {
            Write-Log '[DryRun] 跳过 post-setup.ps1' 'INFO'
        }
        else {
            try { & $post } catch { Write-Log "post-setup 出错：$($_.Exception.Message)" 'ERROR' }
        }
    }
    else {
        Write-Log "postSetup 已启用但找不到脚本：$post" 'WARN'
    }
}

# ---------------------------------------------------------------- 汇总

Write-Log '===== 结果汇总 =====' 'STEP'
$script:Results | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Host $_ }

$csv = Join-Path $script:Root 'install-result.csv'
$script:Results | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Write-Log "结果明细已写入：$csv" 'INFO'

$failed = @($script:Results | Where-Object { $_.Status -eq '失败' })
$manual = @($script:Results | Where-Object { $_.Status -eq '需手动' })
$skipped = @($script:Results | Where-Object { $_.Status -eq '跳过' })
$okCount = @($script:Results | Where-Object { $_.Status -in @('OK', '已安装', '交互完成') }).Count

Write-Log ("成功 {0} 项，需手动 {1} 项，跳过 {2} 项，失败 {3} 项。" -f $okCount, $manual.Count, $skipped.Count, $failed.Count) 'STEP'
if ($manual.Count -gt 0) {
    Write-Log '下面这些需要你手动装（地址见上面的表格/清单）：' 'WARN'
    foreach ($item in $manual) { Write-Log "    - $($item.Name)：$($item.Detail)" 'WARN' }
}
if ($skipped.Count -gt 0) {
    Write-Log '下面这些被跳过了（通常是 winget 不可用）：' 'WARN'
    foreach ($item in $skipped) { Write-Log "    - $($item.Name)：$($item.Detail)" 'WARN' }
}
if ($failed.Count -gt 0) {
    Write-Log '失败的项目可以单独重试，例如：.\bootstrap.ps1 -Only "微信" -Interactive' 'WARN'
    exit 1
}
exit 0

<#
    可选的“装完之后顺便恢复配置”脚本。
    默认不启用：把 apps.json 里 postSetup.enabled 改成 true，并在同一个文件夹放这个 post-setup.ps1。
    下面每段都可以按需删掉/注释掉，脚本本身不依赖任何外部文件。
#>

$ErrorActionPreference = 'Continue'
function Info($m) { Write-Host "[post-setup] $m" -ForegroundColor Cyan }

# 1) 恢复 git 配置：把 .gitconfig / .gitconfig-ghproxy 放在本文件夹即可自动拷回用户目录
foreach ($cfg in @('.gitconfig', '.gitconfig-ghproxy')) {
    $src = Join-Path $PSScriptRoot $cfg
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $env:USERPROFILE $cfg) -Force
        Info "已恢复 $cfg"
    }
}
# 需要的话把代理配置也启用到主配置里（按需修改路径）
# git config --global include.path ~/.gitconfig-ghproxy

# 2) 用 winget 装几件 winget 清单之外的东西（可选，按需打开）
# winget install -e --id Microsoft.VisualStudio.2022.Community --accept-package-agreements --accept-source-agreements

# 3) VS Code 插件（需要 code 已在 PATH 里）
if (Get-Command code -ErrorAction SilentlyContinue) {
    foreach ($ext in @('ms-ceintl.vscode-language-pack-zh-hans')) {
        code --install-extension $ext --force | Out-Null
        Info "VS Code 插件：$ext"
    }
}

# 4) npm 全局包 / 国内镜像（按需打开）
# npm config set registry https://registry.npmmirror.com
# npm install -g pnpm

# 5) pip 镜像（按需打开）
# python -m pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple

# 6) 桌面/文档等常用目录（OneDrive 用户请谨慎，勿随意重定向）
# $null = New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE 'Projects')

Info '完成。'

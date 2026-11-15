# cubby.ps1 : run client/cubby from Windows PowerShell / PowerShell 7.
# cubby itself is a POSIX sh script, so it is run with Git for Windows' sh.exe.
#   .\client\cubby.ps1 add-host gpu1 --hostname gpu1.example.com --user alice --cloudflared
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less files as the ANSI code page.
$ErrorActionPreference = 'Stop'

$candidates = @()
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($git) {
    # ...\Git\cmd\git.exe or ...\Git\mingw64\bin\git.exe -> ...\Git\bin\sh.exe
    $root = Split-Path (Split-Path $git.Source -Parent) -Parent
    $candidates += (Join-Path $root 'bin\sh.exe')
    $candidates += (Join-Path (Split-Path $root -Parent) 'bin\sh.exe')
}
$candidates += "$env:ProgramFiles\Git\bin\sh.exe"
$candidates += "${env:ProgramFiles(x86)}\Git\bin\sh.exe"
$candidates += "$env:LOCALAPPDATA\Programs\Git\bin\sh.exe"

$sh = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $sh) {
    Write-Error 'Git for Windows (sh.exe) was not found. Install it from https://git-scm.com/download/win'
    exit 1
}

$script = Join-Path $PSScriptRoot 'cubby'
& $sh $script @args
exit $LASTEXITCODE

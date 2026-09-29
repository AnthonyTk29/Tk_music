# Arma el instalador de TK Music para Windows:
#   1. compila la app en Release (salvo con -SkipBuild),
#   2. copia al lado del exe el runtime de Visual C++ (sin él la app no abre
#      en PCs que no tienen instalado el redistribuible),
#   3. corre Inno Setup con la versión del pubspec.yaml.
# Resultado: build\installer\TK_Music_Setup_<versión>.exe (instalador) y
# TK_Music_Portable_<versión>.zip (portátil, sin instalar).
#
#   powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1
param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $root

$version = (Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
Write-Host "TK Music $version"

if (-not $SkipBuild) {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Falló la compilación de Windows.' }
}

$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'tk_music.exe'))) {
    throw "No está la app compilada en $release"
}

$crt = Get-ChildItem -Path "$env:ProgramFiles\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT" -Directory -ErrorAction SilentlyContinue |
    Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw 'No se encontró el runtime de Visual C++ (Visual Studio > Redist).' }
Copy-Item -Path (Join-Path $crt.FullName '*.dll') -Destination $release -Force
Write-Host "Runtime de Visual C++: $($crt.FullName)"

$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'No se encontró Inno Setup 6 (ISCC.exe).' }

$output = Join-Path $root 'build\installer'
& $iscc "/DAppVersion=$version" "/DSourceDir=$release" "/DOutputDir=$output" (Join-Path $PSScriptRoot 'tk_music.iss')
if ($LASTEXITCODE -ne 0) { throw 'Falló Inno Setup.' }

# Versión portátil: la misma carpeta en un ZIP (se descomprime y se abre
# tk_music.exe, sin instalar).
$portable = Join-Path $output "TK_Music_Portable_$version.zip"
$stagingRoot = Join-Path $output 'portable_tmp'
$staging = Join-Path $stagingRoot "TK Music $version"
if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
New-Item -ItemType Directory -Force $staging | Out-Null
Copy-Item -Path (Join-Path $release '*') -Destination $staging -Recurse -Exclude '*.lib', '*.exp', '*.pdb', '*.ilk'
if (Test-Path -LiteralPath $portable) { Remove-Item -LiteralPath $portable -Force }
Compress-Archive -LiteralPath $staging -DestinationPath $portable -CompressionLevel Optimal
Remove-Item -LiteralPath $stagingRoot -Recurse -Force

Get-ChildItem $output | Where-Object { $_.Name -in @("TK_Music_Setup_$version.exe", "TK_Music_Portable_$version.zip") } | ForEach-Object {
    Write-Host ("Listo: {0} ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB))
}

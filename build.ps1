param(
    [string]$Src = "g90net.py",
    [string]$Head = "install-head.sh",
    [string]$Out = "g90net-install.sh"
)

$ErrorActionPreference = "Stop"
$Marker = "__G90NET_PAYLOAD__"

function Resolve-ProjectPath([string]$PathValue, [string]$BaseDir) {
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $BaseDir -ChildPath $PathValue))
}

$SrcPath  = Resolve-ProjectPath $Src  $PSScriptRoot
$HeadPath = Resolve-ProjectPath $Head $PSScriptRoot
$OutPath  = Resolve-ProjectPath $Out  $PSScriptRoot

if (-not (Test-Path -LiteralPath $SrcPath -PathType Leaf)) {
    throw "Fehler: $SrcPath nicht gefunden"
}
if (-not (Test-Path -LiteralPath $HeadPath -PathType Leaf)) {
    throw "Fehler: $HeadPath nicht gefunden"
}

$pyCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pyCmd) {
    $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue
}
if (-not $pyCmd) {
    throw "Fehler: Python nicht gefunden"
}

& $pyCmd.Source -c "import py_compile, sys; py_compile.compile(sys.argv[1], doraise=True)" $SrcPath

$headLines = [System.IO.File]::ReadAllLines($HeadPath, [System.Text.UTF8Encoding]::new($false))
$markerIdx = [array]::IndexOf($headLines, $Marker)
if ($markerIdx -lt 0) {
    throw "Fehler: Marker '$Marker' fehlt in $HeadPath"
}

$prefixLines = $headLines[0..$markerIdx]
$prefixText = ($prefixLines -join "`n") + "`n"

$srcBytes = [System.IO.File]::ReadAllBytes($SrcPath)
$b64Text = [System.Convert]::ToBase64String($srcBytes) + "`n"

$outDir = Split-Path -Path $OutPath -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$tempOut = Join-Path -Path $outDir -ChildPath (([System.IO.Path]::GetFileName($OutPath)) + "." + [System.IO.Path]::GetRandomFileName())

try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempOut, $prefixText + $b64Text, $utf8NoBom)
    Move-Item -LiteralPath $tempOut -Destination $OutPath -Force
} finally {
    if (Test-Path -LiteralPath $tempOut) {
        Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
    }
}

$size = (Get-Item -LiteralPath $OutPath).Length
Write-Host "$OutPath neu gebaut ($size Bytes)"
$ErrorActionPreference = "Stop"

$python = "D:\LectureTranscriber\venv\Scripts\python.exe"
$lectureTranscriber = "C:\Users\ellih\Desktop\Personal\University Work Y1\Lecture Transcriber"
$modelRoot = "C:\LectureTranscriberModel\SharedParakeet"
$runtimeRoot = Join-Path $PSScriptRoot ".echonote-runtime"
$legacyRuntimeRoot = Join-Path $PSScriptRoot ".echonote-smoke-runtime"
$tailscaleAddress = Get-NetIPAddress -InterfaceAlias "Tailscale" -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike "169.254*" } |
    Select-Object -First 1 -ExpandProperty IPAddress

foreach ($requiredPath in @($python, (Join-Path $lectureTranscriber "transcribe_engine.py"), (Join-Path $modelRoot "huggingface\hub\models--nvidia--parakeet-tdt-0.6b-v2"))) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "EchoNote startup prerequisite is missing: $requiredPath"
    }
}

if (-not $tailscaleAddress) {
    throw "No Tailscale IPv4 address was found. Start Tailscale, then try again."
}

$listener = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    throw "Port 8765 is already in use. Check whether EchoNote is already running before starting another copy."
}

if (Test-Path -LiteralPath $legacyRuntimeRoot) {
    if (Test-Path -LiteralPath $runtimeRoot) {
        throw "Both runtime folders exist. Stop EchoNote and merge them before launching: $legacyRuntimeRoot and $runtimeRoot"
    }
    Move-Item -LiteralPath $legacyRuntimeRoot -Destination $runtimeRoot
    Write-Host "Moved existing runtime data to $runtimeRoot"
}

New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
$env:ECHONOTE_HOST = $tailscaleAddress
$env:ECHONOTE_LECTURE_TRANSCRIBER = $lectureTranscriber
$env:ECHONOTE_MODEL_STORAGE_ROOT = $modelRoot
$env:ECHONOTE_RUNTIME_ROOT = $runtimeRoot

Write-Host "Starting EchoNote on $($tailscaleAddress):8765. The cached Parakeet model loads into memory at startup."
& $python (Join-Path $PSScriptRoot "server.py")

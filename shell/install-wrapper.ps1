# install-wrapper.ps1 — one-time PowerShell setup for `claude --local`:
# appends the wrapper function (claude-wrapper.ps1) to your PowerShell
# profile. Idempotent — safe to re-run. From the repo root:
#   powershell -ExecutionPolicy Bypass -File shell\install-wrapper.ps1
$wrapperSource = Join-Path $PSScriptRoot 'claude-wrapper.ps1'
if (-not (Test-Path $wrapperSource)) {
    Write-Error "claude-wrapper.ps1 not found next to this script."
    exit 1
}

$profileDir = Split-Path $PROFILE
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}
if ((Test-Path $PROFILE) -and (Select-String -Path $PROFILE -Pattern 'claude-local' -Quiet)) {
    Write-Output "already present in $PROFILE"
} else {
    Add-Content -Path $PROFILE -Value ("`n" + (Get-Content $wrapperSource -Raw))
    Write-Output "appended to $PROFILE"
    Write-Output "Open a new PowerShell window to activate claude --local."
}

# Profile scripts never load under a Restricted policy — surface that now
# rather than letting the wrapper silently not exist in the next session.
# Read the PERSISTED scopes: the effective policy is Bypass right now because
# that's how this installer is documented to be invoked.
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq 'Undefined') { $policy = Get-ExecutionPolicy -Scope LocalMachine }
if ($policy -in 'Restricted', 'AllSigned', 'Undefined') {
    Write-Warning ("Execution policy '$policy' may block profile scripts. " +
        "Fix: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
}

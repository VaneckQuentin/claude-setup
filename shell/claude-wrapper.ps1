# --- Claude Code: `claude --local` launches full-local (Ollama) mode ---
# PowerShell twin of claude-wrapper.zsh. Installed into $PROFILE by
# shell/install-wrapper.ps1. The launcher runs in a CHILD shell so its env
# changes (ANTHROPIC_*, CLAUDE_CONFIG_DIR) never leak into your session.
function claude {
    if ($args.Count -ge 1 -and $args[0] -eq '--local') {
        # Match the current edition, by NAME not process path: the profile may
        # be hosted by something that can't run scripts headless (e.g. ISE).
        $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
        & $shell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $HOME '.claude/local-mode/claude-local.ps1') `
            @($args | Select-Object -Skip 1)
    }
    else {
        $real = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($real) { & $real.Path @args }
        else { Write-Error "claude CLI not found on PATH — install Claude Code first." }
    }
}

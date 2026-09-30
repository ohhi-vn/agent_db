# AgentDb agent setup on Windows runs inside WSL2.
#
# The daemon, Elixir toolchain, and install script are Linux programs.
# Windows editors (OpenCode, Zed) talk to the daemon over localhost.
#
# From PowerShell, run the Linux installer inside WSL:
#
#   wsl bash tools/install.sh --check
#   wsl bash tools/install.sh
#
# This script refuses to run natively on Windows so a half-installed
# native setup (no EXLA support, wrong paths) is never mistaken for done.
if ($env:WSL_DISTRO_NAME) {
  Write-Host "Already inside WSL ($env:WSL_DISTRO_NAME); running tools/install.sh ..."
  & bash tools/install.sh @args
  exit $LASTEXITCODE
}

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
  Write-Host "WSL is not installed. Install WSL2 plus a Linux distro, then re-run." -ForegroundColor Red
  Write-Host "See: https://learn.microsoft.com/windows/wsl/install"
  exit 1
}

Write-Host "Do not run the installer natively on Windows." -ForegroundColor Yellow
Write-Host "Run it inside WSL instead:"
Write-Host ""
Write-Host "  wsl bash tools/install.sh --check"
Write-Host "  wsl bash tools/install.sh"
Write-Host ""
Write-Host "Windows OpenCode/Zed then use http://localhost:6060/mcp (see docs/agents.md)."
exit 1

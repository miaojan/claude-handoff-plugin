# pane-sender: PowerShell SendKeys (Windows). UNTESTED.
#
# Usage:
#   pwsh -File windows-sendkeys.ps1 --available
#   pwsh -File windows-sendkeys.ps1 LINE1 LINE2 SLEEP_BETWEEN
#
# Targets the focused window. Caller must ensure the Claude Code
# terminal window is foregrounded before /handoff fires. Sequence per
# command: Esc Esc Ctrl+U <text> Enter

param(
  [string]$Line1,
  [string]$Line2,
  [int]$SleepBetween = 7
)

if ($Line1 -eq "--available") {
  if ($IsWindows) { exit 0 } else { exit 1 }
}

if (-not $Line1 -or -not $Line2) {
  Write-Error "windows-sendkeys: line1 and line2 required"
  exit 2
}

Add-Type -AssemblyName System.Windows.Forms

function Send-Cmd {
  param([string]$cmd)
  # Escape Escape, then Ctrl-U to kill-line-backward.
  [System.Windows.Forms.SendKeys]::SendWait("{ESC}{ESC}^u")
  Start-Sleep -Milliseconds 200
  # Escape SendKeys reserved chars: + ^ % ~ ( ) { }
  $escaped = ($cmd -replace '([+\^%~(){}])', '{$1}')
  [System.Windows.Forms.SendKeys]::SendWait($escaped)
  [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
}

Start-Sleep -Seconds 2
Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') sendkeys $Line1"
Send-Cmd $Line1
Start-Sleep -Seconds $SleepBetween
Write-Host "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') sendkeys $Line2"
Send-Cmd $Line2

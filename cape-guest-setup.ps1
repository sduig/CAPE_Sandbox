# ============================================================
# CAPEv2 Guest Setup — Windows 10/11
# Run as: elevated PowerShell
# Usage: .\cape-guest-setup.ps1 -IP 172.16.204.100
# ============================================================
param(
    [Parameter(Mandatory=$true)]
    [string]$IP,

    [string]$ComputerName = "DESKTOP-$((Get-Random -Max 99999).ToString('X5'))",
    [string]$AgentSource = "http://172.16.204.1:8080/agent.py",
    [switch]$SkipSoftware,
    [switch]$CleanupOnly
)

# --- Colors ---
function Write-Info  { param($m) Write-Host "[INFO]  $m" -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Error2{ param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }

# --- Check admin ---
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error2 "Run as Administrator."; exit 1 }

# ============================================================
# STEP 1: Hardening
# ============================================================
Write-Info "Disabling Defender..."
Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
Set-MpPreference -EnableControlledFolderAccess Disabled -ErrorAction SilentlyContinue
Set-MpPreference -PUAProtection Disabled -ErrorAction SilentlyContinue
Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue

Write-Info "Disabling Firewall..."
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

Write-Info "Disabling Windows Update..."
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Value 1
Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
Set-Service -Name UsoSvc -StartupType Disabled -ErrorAction SilentlyContinue

Write-Info "Disabling UAC..."
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0

Write-Info "Disabling sleep/lock/hibernation..."
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0
powercfg /h off

Write-Info "Disabling SmartScreen..."
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" /v EnableWebContentTrust /t REG_DWORD /d 0 /f

Write-Info "Disabling WER and telemetry..."
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" /v Disabled /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f

# ============================================================
# STEP 2: Static IP
# ============================================================
Write-Info "Setting static IP: $IP ..."
$if = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
if (-not $if) { Write-Error2 "No active network adapter found."; exit 1 }

# Remove existing IPs on this interface
Get-NetIPAddress -InterfaceIndex $if.ifIndex -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.*" -and $_.IPAddress -ne "127.0.0.1" } |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

$gateway = ($IP -split "\.")[0..2] -join "." + ".1"
New-NetIPAddress -InterfaceIndex $if.ifIndex -IPAddress $IP -PrefixLength 24 -DefaultGateway $gateway

Write-Info "IP set to $IP (gateway $gateway)"

# ============================================================
# STEP 3: Software (skip with -SkipSoftware)
# ============================================================
if (-not $SkipSoftware) {
    Write-Info "Installing software..."
    $dl = "$env:USERPROFILE\Downloads"
    $hostIP = ($gateway -split "\.")[0..2] -join "." + ".1"

    # Python 3.9.13 32-bit
    if (-not (Test-Path "C:\Users\user\AppData\Local\Programs\Python\Python39-32\python.exe")) {
        Write-Info "Downloading Python 3.9.13 (32-bit)..."
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe" -OutFile "$dl\python.exe"
        Start-Process -FilePath "$dl\python.exe" -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait
    }

    # pip packages
    $python = "C:\Users\user\AppData\Local\Programs\Python\Python39-32\python.exe"
    if (Test-Path $python) {
        & $python -m pip install --quiet pillow pywin32
    }

    # VC++ Redistributable
    Write-Info "Downloading VC++ Redistributable..."
    Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile "$dl\vc_redist.exe"
    Start-Process -FilePath "$dl\vc_redist.exe" -ArgumentList "/quiet /norestart" -Wait

    # 7-Zip
    if (-not (Get-Command 7z.exe -ErrorAction SilentlyContinue)) {
        Write-Info "Downloading 7-Zip..."
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7z2605-x64.exe" -OutFile "$dl\7zip.exe"
        Start-Process -FilePath "$dl\7zip.exe" -ArgumentList "/S" -Wait
    }

    # Firefox
    if (-not (Get-Command firefox.exe -ErrorAction SilentlyContinue)) {
        Write-Info "Downloading Firefox..."
        Invoke-WebRequest -Uri "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US" -OutFile "$dl\firefox.exe"
        Start-Process -FilePath "$dl\firefox.exe" -ArgumentList "-ms" -Wait
    }

    # Chrome
    if (-not (Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe")) {
        Write-Info "Downloading Chrome..."
        Invoke-WebRequest -Uri "https://dl.google.com/chrome/install/ChromeStandaloneSetup64.exe" -OutFile "$dl\chrome.exe"
        Start-Process -FilePath "$dl\chrome.exe" -ArgumentList "/silent" -Wait
    }

    Write-Info "Software installation complete."
}

# ============================================================
# STEP 4: Deploy Agent
# ============================================================
if (-not $CleanupOnly) {
    Write-Info "Deploying CAPE agent..."
    $agentPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\pizza.pyw"

    # Download agent
    try {
        Invoke-WebRequest -Uri $AgentSource -OutFile $agentPath
    } catch {
        Write-Warn "Could not download agent from $AgentSource — copy it manually to: $agentPath"
    }

    # Create Task Scheduler task
    $pythonw = "C:\Users\user\AppData\Local\Programs\Python\Python39-32\pythonw.exe"
    if (-not (Test-Path $pythonw)) {
        Write-Warn "pythonw.exe not found at $pythonw — agent task may fail."
    }

    # Remove existing task if present
    schtasks /delete /tn "pizza" /f 2>$null

    schtasks /create /tn "pizza" /tr "`"$pythonw`" `"$agentPath`"" /sc onlogon /ru "user" /rp "user" /rl highest /f

    Write-Info "Agent deployed and scheduled."
}

# ============================================================
# STEP 5: AutoLogon
# ============================================================
Write-Info "Configuring AutoLogon..."
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogon -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path $winlogon -Name "DefaultUserName" -Value "user"
Set-ItemProperty -Path $winlogon -Name "DefaultPassword" -Value "user"
Set-ItemProperty -Path $winlogon -Name "DefaultDomainName" -Value "."

# ============================================================
# STEP 6: Rename Computer
# ============================================================
Write-Info "Renaming computer to $ComputerName ..."
Rename-Computer -NewName $ComputerName -Force
Write-Warn "Computer renamed — reboot required for it to take effect."

# ============================================================
# STEP 7: Cleanup (if -CleanupOnly)
# ============================================================
if ($CleanupOnly) {
    Write-Info "Running pre-snapshot cleanup..."

    # Remove agent
    Remove-Item "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\pizza.pyw" -Force -ErrorAction SilentlyContinue
    schtasks /delete /tn "pizza" /f 2>$null
    Get-Process python* -ErrorAction SilentlyContinue | Stop-Process -Force

    # Clear temp
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "C:\Windows\Prefetch\*" -Force -ErrorAction SilentlyContinue

    # Clear recent/explorer
    Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\*" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:USERPROFILE\Downloads\*" -Force -ErrorAction SilentlyContinue

    # Clear event logs
    wevtutil cl Application
    wevtutil cl Security
    wevtutil cl System

    # Add lived-in artifacts
    $docs = "$env:USERPROFILE\Documents"
    "Meeting notes - Q3" | Out-File "$docs\meeting_notes.txt"
    "Budget draft" | Out-File "$docs\budget_draft.txt"
    "TODO list" | Out-File "$docs\TODO.txt"

    # Desktop folders
    $desktop = [Environment]::GetFolderPath("Desktop")
    foreach ($f in @("Work", "Personal", "Downloads")) {
        $path = Join-Path $desktop $f
        if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory | Out-Null }
    }

    Write-Info "Cleanup complete. Reboot, verify no agent running, then take snapshot."
}

# ============================================================
# DONE
# ============================================================
Write-Info "============================================"
Write-Info " Guest setup complete!"
Write-Info "============================================"
Write-Host ""
Write-Host "  Next steps:"
Write-Host "    1. Reboot the VM"
Write-Host "    2. Verify agent: curl http://${IP}:8000 (from host)"
Write-Host "    3. Run cleanup: .\cape-guest-setup.ps1 -IP ${IP} -CleanupOnly"
Write-Host "    4. Reboot, take 'clean' snapshot in VMware"
Write-Host ""   

# CAPE_Sandbox
Online:

Main docs: https://capev2.readthedocs.io/
GitHub README: https://github.com/kevoreilly/CAPEv2 (the README.md in the repo root)
Wiki: https://github.com/kevoreilly/CAPEv2/wiki
Local (on your host):

/opt/CAPEv2/README.md
/opt/CAPEv2/docs/

The docs/ folder has the full installation guide, configuration reference, and troubleshooting pages in Markdown format.

ls /opt/CAPEv2/docs/

The most relevant files for your setup:

File	What it covers
docs/installation.md	Full install (what we followed)
docs/configuration.md	All config files explained
docs/machinery/vmware.md	VMware-specific setup
docs/troubleshooting.md	Common errors and fixes


Copy


based on the steps we used to build it create one


#Drafted CAPE setup guide
Here's a consolidated guide based on your actual build:

CAPEv2 on Linux Mint + VMware Workstation — Build Guide
Architecture
Linux Mint (host)
├── CAPEv2 (/opt/CAPEv2)
├── MongoDB (127.0.0.1:27017)
├── VMware Workstation
│   ├── Win10 guest → 172.16.204.100
│   └── Win11 guest → 172.16.204.101
└── Network: vmnet1 (Host-Only) → 172.16.204.1/24

1. Host Prerequisites (Linux Mint)
sudo apt update
sudo apt install git build-essential cmake ninja-build \
  python3-dev cython3 pybind11-dev python3-pip \
  libre2-dev acpica-tools net-tools gperf \
  openssh-server vim

Install VMware Workstation 17.5.2+ (free for all use since Nov 2024). Verify:

which vmrun

MongoDB
sudo useradd -r -s /bin/false mongodb
sudo mkdir -p /data/db /var/log/mongodb /var/run/mongodb
sudo chown -R mongodb:mongodb /data/db /var/log/mongodb /var/run/mongodb

** Add repo (use jammy for Mint 21.x, noble for 22.x)
sudo wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] http://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

sudo apt update
sudo apt install -y mongodb-org

sudo systemctl start mongodb
sudo systemctl enable mongodb
ss -tlnp | grep 27017   # confirm listening

2. Install CAPEv2
cd ~
git clone https://github.com/kevoreilly/CAPEv2.git
cd CAPEv2/installer

Edit cape2.sh — set:

NETWORK_IFACE=vmnet1
IFACE_IP="172.16.204.1"
PASSWD="your_secure_password"
USER=cape

Run:

sudo chmod +x cape2.sh
sudo ./cape2.sh base cape | tee cape.log
sudo reboot

After reboot, fix DB ownership:

sudo -u postgres psql -c "ALTER DATABASE cape OWNER TO cape;"

3. Configure VMware Host-Only Network
In VMware Workstation: Edit → Virtual Network Editor → Host-Only (VMnet1)

Host IP: 172.16.204.1/24
Confirm ip addr show vmnet1 on the host shows this address
4. Build Windows Guest VMs (Win10 + Win11)
Create the VMs
Setting	Win10	Win11
vCPUs	1 processor × 2 cores	1 processor × 2 cores
RAM	4 GB	4 GB
Disk	60 GB (thin)	60 GB (thin)
Network	Custom: VMnet1 (Host-Only)	Custom: VMnet1 (Host-Only)
3D Acceleration	Off	Off
Floppy	Do not connect	Do not connect

Win11 only: Select guest OS as "Windows 10 x64" in the wizard (avoids forced encryption/vTPM). Point CD/DVD at the Win11 ISO after creation. During setup, when it blocks on TPM, press Shift + F10 → regedit → create HKLM\SYSTEM\Setup\LabConfig with DWORD values BypassTPMCheck=1, BypassSecureBootCheck=1, BypassRAMCheck=1. Then proceed.

Install → "I don't have a product key" → skip network → local account user / user.

#Harden (elevated PowerShell on each VM)
* Defender
Set-MpPreference -DisableRealtimeMonitoring $true
Set-MpPreference -EnableControlledFolderAccess Disabled
Set-MpPreference -PUAProtection Disabled

* Firewall
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

* Windows Update
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Value 1
Set-Service -Name wuauserv -StartupType Disabled
Set-Service -Name UsoSvc -StartupType Disabled

* UAC
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0

* Sleep / lock
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0
powercfg /h off

* SmartScreen
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" /v EnableWebContentTrust /t REG_DWORD /d 0 /f

Static IP (elevated PowerShell)
$if = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
New-NetIPAddress -InterfaceIndex $if.ifIndex -IPAddress 172.16.204.100 -PrefixLength 24 -DefaultGateway 172.16.204.1

Win11 uses 172.16.204.101 instead.

Verify from host: ping 172.16.204.100

Install Software
Download on host, serve via python3 -m http.server 8080, grab from guest browser at http://172.16.204.1:8080/.

Software	Source
Python 3.9.13 (32-bit)	https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe
Office 2010 SP2 (32-bit)	Mount ISO in VM → CD/DVD
Firefox (full installer)	https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US
Chrome (standalone)	https://dl.google.com/chrome/install/ChromeStandaloneSetup64.exe
7-Zip	https://www.7-zip.org/a/7z2605-x64.exe
VC++ Redistributable	https://aka.ms/vs/17/release/vc_redist.x64.exe

After Python:

python -m pip install pillow pywin32

Deploy Agent
copy C:\Users\user\Downloads\agent.py "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\pizza.pyw"

Task Scheduler:

Name: pizza
Trigger: At log on
Program/script: C:\Users\user\AppData\Local\Programs\Python\Python39-32\pythonw.exe
Add arguments: "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\pizza.pyw"
Start in: C:\ProgramData\Microsoft\Windows\Start Menu\Programs
AutoLogon
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d "user" /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d "user" /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultDomainName /t REG_SZ /d "." /f

Verify Agent
Reboot → from host:

curl http://172.16.204.100:8000
# Expected: {"message": "CAPE Agent!", "version": "0.23", ...}

5. Pre-Snapshot Cleanup (on each VM)
Remove agent:

del "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\pizza.pyw"
schtasks /delete /tn "pizza" /f
Get-Process python* | Stop-Process -Force

Clear artifacts (cmd.exe):

del /q C:\Users\user\AppData\Local\Temp\* 2>nul
del /q C:\Windows\Temp\* 2>nul
del /q C:\Windows\Prefetch\* 2>nul
del /q "C:\Users\user\AppData\Roaming\Microsoft\Windows\Recent\*" 2>nul
del /q "C:\Users\user\AppData\Local\Microsoft\Windows\Explorer\*" 2>nul
del /q C:\Users\user\Downloads\* 2>nul

Clear event logs (elevated PowerShell):

wevtutil cl Application
wevtutil cl Security
wevtutil cl System

Add "lived-in" artifacts:

Create Desktop folders: Work, Personal, Downloads
Put a few dummy text files in Documents
Open Firefox → visit wikipedia.org, bbc.com → close
Delete one dummy file (Recycle Bin)
Rename computer:

Rename-Computer -NewName "DESKTOP-XXXXX" -Force

Disconnect DVD drive: VM → Settings → CD/DVD → uncheck "Connect at power on"

Reboot → confirm no agent process, desktop looks "used" → Snapshot → Take Snapshot → name: clean

6. CAPE Configuration
/opt/CAPEv2/conf/vmware.conf
[vmware]
mode = nogui
interface = vmnet1
path = /usr/bin/vmrun
machines = win10,win11

[win10]
vmx_path = /media/user/VMWare/Cape-Windows-10-x64/Cape-Windows-10-x64.vmx
snapshot = clean
platform = windows
ip = 172.16.204.100
arch = x64
tags = win10,x64

[win11]
vmx_path = /media/user/VMWare/Cape-Windows-11-x64/Cape-Windows-11-x64.vmx
snapshot = clean
platform = windows
ip = 172.16.204.101
arch = x64
tags = win11,x64

/opt/CAPEv2/conf/cuckoo.conf
[cuckoo]
machinery = vmware
max_analysis_count = 1
max_machines_count = 2
reschedule = on

[resultserver]
ip = 172.16.204.1

/opt/CAPEv2/conf/reporting.conf
[mongodb]
enabled = yes
host = 127.0.0.1
port = 27017
db = cuckoo

7. Start & Test
sudo systemctl start mongodb
sudo systemctl start cape
sudo systemctl start cape-processor
sudo systemctl start cape-web

Open http://localhost:8000 → Submit → pick a machine → submit a benign .exe.

8. Troubleshooting
Symptom	Fix
AttributeError: 'Config' object has no attribute 'win10'	Machine names in vmware.conf must be lowercase
MongoDB connection is not established	ss -tlnp | grep 27017 — if empty, sudo systemctl start mongodb
vmrun: command not found	Set full path in vmware.conf
Guest unreachable	Check vmnet1 IP on host, guest static IP, firewall off
vmx_path errors	Must point to the .vmx file, not the folder
Win11 auto-shutdown	Enterprise Evaluation license — use Win11 Pro ISO instead
Chrome won't install	Use standalone installer, not web stub; install VC++ redist first
del /q errors in PowerShell	Use cmd.exe for del commands, not PowerShell
HKLM: path not resolving in PowerShell	Use Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\... or use reg add in cmd.exe



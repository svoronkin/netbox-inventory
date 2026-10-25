<#
.SYNOPSIS
    netbox_inventory.ps1 - inventory of a Windows host into NetBox.

.DESCRIPTION
    Collects hardware, OS and network data via CIM/WMI and creates or updates the device in NetBox
    through the REST API. Counterpart of netbox_inventory.sh for Linux: same logic and the same -CollectOnly format.
    Works in Windows PowerShell 5.1 and PowerShell 7+, no external dependencies.

.EXAMPLE
    .\netbox_inventory.ps1 -CollectOnly
.EXAMPLE
    .\netbox_inventory.ps1 -TokenFile C:\ProgramData\netbox\token -DryRun
.EXAMPLE
    .\netbox_inventory.ps1 -TokenFile C:\ProgramData\netbox\token -Site LED -Tenant LAB -Role Workstation
#>
[CmdletBinding()]
param(
    [string]$Url = $(if ($env:NETBOX_URL) { $env:NETBOX_URL } else { 'https://netbox.p4el.net' }),
    [string]$TokenFile = $env:NETBOX_TOKEN_FILE,
    [switch]$Insecure,
    [string]$Name = $env:DEVICE_NAME,
    [string]$Site = $env:SITE_NAME,
    [string]$Role = $(if ($env:DEVICE_ROLE) { $env:DEVICE_ROLE } else { 'server' }),
    [string]$Tenant = $env:TENANT_NAME,
    [string]$Platform = $env:PLATFORM,
    [string]$Rack = $env:RACK_NAME,
    [string]$Location = $env:LOCATION_NAME,
    [string]$Tag = $(if ($env:NETBOX_TAG) { $env:NETBOX_TAG } else { 'auto-inventory' }),
    [string]$SkipInterfaceRegex = $env:SKIP_IF_REGEX,
    [int]$MinDiskGB = $(if ($env:MIN_DISK_GB) { [int]$env:MIN_DISK_GB } else { 1 }),
    [switch]$DryRun,
    [switch]$CollectOnly,
    [switch]$NoIPv6
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ScriptVersion = '2.2.0'

# ---------- output: all messages go to stderr, stdout is only for JSON (-CollectOnly) ----------
function Say([string]$m, $color = $null) {
    if ($null -ne $color) { $old = [Console]::ForegroundColor; [Console]::ForegroundColor = $color }
    [Console]::Error.WriteLine($m)
    if ($null -ne $color) { [Console]::ForegroundColor = $old }
}
function Log([string]$m)    { Say $m }
function Ok([string]$m)     { Say $m 'Green' }
function Warn([string]$m)   { Say "WARN: $m" 'Yellow' }
function Change([string]$m) { Say ("{0} {1}" -f $(if ($DryRun) { '[dry-run]' } else { '*' }), $m) 'Cyan' }
function Die([string]$m)    { Say "ERROR: $m" 'Red'; exit 1 }

# ---------- helpers ----------
$JunkValues = @('', 'unknown', 'none', 'n/a', 'na', 'not specified', 'not available', 'default string',
    'system manufacturer', 'system product name', 'system serial number', 'to be filled by o.e.m.',
    'to be filled by o.e.m', 'o.e.m.', 'oem', 'base board serial number', 'chassis serial number',
    '0', '0000000000', '123456789', 'not present', 'manufacturer', 'ata')
function Clean($v) {
    if ($null -eq $v) { return '' }
    $s = ([string]$v).Trim().TrimEnd('.')
    if ($JunkValues -contains $s.ToLower()) { return '' }
    if ($s -match '^(0x)?0+$') { return '' }
    return $s
}
function Slugify([string]$s) {
    $x = ($s.ToLower() -replace '[^a-z0-9_]+', '-').Trim('-')
    if ($x.Length -gt 100) { $x = $x.Substring(0, 100) }
    return $x
}
function Enc([string]$s) { [uri]::EscapeDataString($s) }

# Vendor normalization: one name per vendor, so that duplicates are not created
function Normalize-Vendor([string]$v) {
    $v = Clean $v
    if (-not $v) { return '' }
    switch -Regex ($v.ToLower()) {
        '^(intel|genuineintel)'                { return 'Intel' }
        '^nvidia'                              { return 'NVIDIA' }
        '^sapphire'                            { return 'Sapphire' }
        '^zotac'                               { return 'Zotac' }
        '^palit'                               { return 'Palit' }
        '^evga'                                { return 'EVGA' }
        '^pny'                                 { return 'PNY' }
        '^xfx'                                 { return 'XFX' }
        '^(powercolor|tul corp)'               { return 'PowerColor' }
        '^gainward'                            { return 'Gainward' }
        '^(galax|kfa2)'                        { return 'Galax' }
        '^colorful'                            { return 'Colorful' }
        '^inno3d'                              { return 'Inno3D' }
        '^(amd|advanced micro devices|authenticamd)' { return 'AMD' }
        '^samsung'                             { return 'Samsung' }
        '^kingston'                            { return 'Kingston' }
        '^(sk ?hynix|hynix|hyundai)'           { return 'SK Hynix' }
        '^micron'                              { return 'Micron' }
        '^crucial'                             { return 'Crucial' }
        '^(wdc|wd|western digital)'            { return 'Western Digital' }
        '^seagate'                             { return 'Seagate' }
        '^(toshiba|kioxia)'                    { return 'Toshiba' }
        '^(hgst|hitachi)'                      { return 'HGST' }
        '^sandisk'                             { return 'SanDisk' }
        '^(asustek|asus)'                      { return 'ASUS' }
        '^(giga-byte|gigabyte)'                { return 'Gigabyte' }
        '^(micro-star|msi$)'                   { return 'MSI' }
        '^asrock'                              { return 'ASRock' }
        '^(supermicro|super micro)'            { return 'Supermicro' }
        '^dell'                                { return 'Dell' }
        '^(hewlett|hp$|hpe$)'                  { return 'HPE' }
        '^lenovo'                              { return 'Lenovo' }
        '^fujitsu'                             { return 'Fujitsu' }
        '^(microsoft)'                         { return 'Microsoft' }
        '^qemu'                                { return 'QEMU' }
        '^realtek'                             { return 'Realtek' }
        '^corsair'                             { return 'Corsair' }
        '^(g ?skill|g\.skill)'                 { return 'G.Skill' }
        '^(teamgroup|team group)'              { return 'TeamGroup' }
        '^(adata|a-data)'                      { return 'ADATA' }
    }
    return $v
}

# Disk vendor from the model
function Disk-Vendor([string]$m) {
    switch -Regex ($m.ToUpper()) {
        '^(SAMSUNG|MZ)'                   { return 'Samsung' }
        '^(KINGSTON|SA400|SKC|SNV)'       { return 'Kingston' }
        '^(WDC|WD[0-9A-Z])'               { return 'Western Digital' }
        '^(ST[0-9]|SEAGATE)'              { return 'Seagate' }
        '^(CT[0-9]|CRUCIAL)'              { return 'Crucial' }
        '^(MICRON|MTFD)'                  { return 'Micron' }
        '^(INTEL|SSDSC|SSDPE)'            { return 'Intel' }
        '^(TOSHIBA|KIOXIA|KXG|THN)'       { return 'Toshiba' }
        '^(HGST|HUS|HUH|HDS)'             { return 'HGST' }
        '^SANDISK'                        { return 'SanDisk' }
        '^(SK HYNIX|HFS|HFM)'             { return 'SK Hynix' }
        'BRIDGE'                          { return '' }
    }
    if (-not $m) { return '' }
    return Normalize-Vendor ($m -split ' ')[0]
}

# RAM vendor: SMBIOS often reports a JEDEC code instead of a name - then use the part number
function Ram-Vendor([string]$v, [string]$part) {
    switch -Regex ($part.ToUpper()) {
        '^(CT[0-9]|BL[0-9])'                       { return 'Crucial' }
        '^(KHX|KF[0-9]|KVR|9905|ACR|KCP|KSM)'      { return 'Kingston' }
        '^(M471|M378|M393|M391|M474|M425|M323)'    { return 'Samsung' }
        '^(HMA|HMT|HMCG)'                          { return 'SK Hynix' }
        '^(MTA|MT[0-9])'                           { return 'Micron' }
        '^(F3-|F4-|F5-)'                           { return 'G.Skill' }
        '^(CMK|CMW|CMSX|CMT|CMH)'                  { return 'Corsair' }
    }
    $n = Normalize-Vendor $v
    if ($n -match '^(0x)?[0-9A-Fa-f]+$') { return '' }
    return $n
}

# Integrated CPU graphics, BMC, remote and virtual adapters are not graphics cards
$IGpuRegex = 'Iris|(UHD|HD|Xe) Graphics|Arc\(TM\) Graphics|Radeon\(TM\) Graphics$|Radeon Graphics$|Radeon Vega|ASPEED|Matrox|Microsoft Basic|Remote Display|Virtual|Parsec|Citrix|DisplayLink|Hyper-V|Meta Virtual|Splashtop'
# Board vendor code (SUBSYS_xxxxVVVV) -> graphics card manufacturer
$PciSubVendors = @{
    '1043' = 'ASUS'; '1458' = 'Gigabyte'; '1462' = 'MSI'; '19DA' = 'Zotac'; '196E' = 'PNY'; '10B0' = 'Gainward'
    '1569' = 'Palit'; '3842' = 'EVGA'; '1682' = 'XFX'; '174B' = 'Sapphire'; '1DA2' = 'Sapphire'; '148C' = 'PowerColor'
    '1849' = 'ASRock'; '7377' = 'Colorful'; '1B4C' = 'Galax'; '10DE' = 'NVIDIA'; '1002' = 'AMD'; '8086' = 'Intel'
    '1028' = 'Dell'; '103C' = 'HPE'; '17AA' = 'Lenovo'; '1025' = 'Acer'
}

# ======================================================================
#  Host data collection
# ======================================================================
function Get-Gpus {
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $regs = @(Get-ChildItem $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } | Where-Object { $_ -and $_.PSObject.Properties['MatchingDeviceId'] })
    $gens = @{ 1 = '1.0'; 2 = '2.0'; 3 = '3.0'; 4 = '4.0'; 5 = '5.0'; 6 = '6.0' }
    $out = @()
    foreach ($v in Get-CimInstance Win32_VideoController) {
        $name = ([string]$v.Name).Trim()
        if (-not $v.PNPDeviceID -or $v.PNPDeviceID -notlike 'PCI\*' -or $name -match $IGpuRegex) { continue }
        $chipVendor = Normalize-Vendor $v.AdapterCompatibility
        $model = ($name -replace '^(NVIDIA|AMD|Intel\(R\)|Intel)\s+', '').Trim()
        $card = $chipVendor
        if ($v.PNPDeviceID -match 'SUBSYS_[0-9A-F]{4}([0-9A-F]{4})' -and $PciSubVendors.ContainsKey($Matches[1].ToUpper())) { $card = $PciSubVendors[$Matches[1].ToUpper()] }
        # Memory size: WMI AdapterRAM is 32-bit (4 GB max), so qwMemorySize from the driver is used
        $mem = $null
        $reg = $regs | Where-Object { $v.PNPDeviceID.ToLower().StartsWith(([string]$_.MatchingDeviceId).ToLower()) } | Select-Object -First 1
        if ($reg -and $reg.PSObject.Properties['HardwareInformation.qwMemorySize']) { $mem = [int][math]::Round([double]$reg.'HardwareInformation.qwMemorySize' / 1GB) }
        elseif ($v.AdapterRAM -and [double]$v.AdapterRAM -lt 4GB) { $mem = [int][math]::Round([double]$v.AdapterRAM / 1GB) }
        if ($mem -eq 0) { $mem = $null }
        $gen = ''; $width = $null; $loc = ''
        try {
            $spd = (Get-PnpDeviceProperty -InstanceId $v.PNPDeviceID -KeyName DEVPKEY_PciDevice_MaxLinkSpeed -ErrorAction Stop).Data
            if ($gens.ContainsKey([int]$spd)) { $gen = $gens[[int]$spd] }
            $width = [int](Get-PnpDeviceProperty -InstanceId $v.PNPDeviceID -KeyName DEVPKEY_PciDevice_MaxLinkWidth -ErrorAction Stop).Data
            $loc = [string](Get-PnpDeviceProperty -InstanceId $v.PNPDeviceID -KeyName DEVPKEY_Device_LocationInfo -ErrorAction Stop).Data
        } catch { }
        if ($width -eq 0) { $width = $null }
        $out += [ordered]@{ pci = $loc; vendor = $chipVendor; card_vendor = $card; name = $model; chip = $name
                            memory_gb = $mem; pcie_gen = $gen; pcie_width = $width; serial = '' }
    }
    return ,$out
}

function Get-Facts {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $bb   = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
    $encl = Get-CimInstance Win32_SystemEnclosure | Select-Object -First 1
    $os   = Get-CimInstance Win32_OperatingSystem

    $virtual = [bool]("$($cs.Manufacturer) $($cs.Model)" -match 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|Xen|Parallels|Bochs')
    $fqdn = ''
    if ($cs.PartOfDomain -and $cs.Domain) { $fqdn = ("{0}.{1}" -f $cs.DNSHostName, $cs.Domain).ToLower() }
    else { try { $h = [Net.Dns]::GetHostEntry('').HostName; if ($h -like '*.*') { $fqdn = $h.ToLower() } } catch { } }

    # OS -> platform
    $isServer = $os.ProductType -ne 1
    $platformName = if ($isServer) { 'Windows Server' } else { 'Windows' }
    $displayVer = ''
    try { $displayVer = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion } catch { }

    # CPU
    $cpus = @(Get-CimInstance Win32_Processor)
    $cpu0 = $cpus[0]
    $cpuModel = ([string]$cpu0.Name).Trim()
    # Frequency: from the model name, otherwise from the registry (~MHz), otherwise MaxClockSpeed. On some builds
    # WMI reports garbage in MaxClockSpeed, so values outside 0.1-10 GHz are discarded.
    $cpuSpeed = $null
    if ($cpuModel -match '@\s*([0-9]+\.[0-9]+)\s*GHz') { $cpuSpeed = [double]$Matches[1] }
    else {
        $mhz = 0
        try { $mhz = [int](Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).'~MHz' } catch { }
        if ($mhz -lt 100 -or $mhz -gt 10000) { $mhz = [int]$cpu0.MaxClockSpeed }
        if ($mhz -ge 100 -and $mhz -le 10000) { $cpuSpeed = [math]::Round($mhz / 1000, 2) }
    }
    $arch = switch ([int]$cpu0.Architecture) { 0 { 'x86' } 5 { 'arm' } 9 { 'x86_64' } 12 { 'arm64' } default { 'unknown' } }

    # RAM
    $ecc = $null
    $arr = Get-CimInstance Win32_PhysicalMemoryArray | Where-Object { $_.Use -eq 3 } | Select-Object -First 1
    if ($arr) { switch ([int]$arr.MemoryErrorCorrection) { 3 { $ecc = $false } { $_ -in 4, 5, 6 } { $ecc = $true } } }
    $memTypes = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5' }
    $slot = 0
    $modules = @(Get-CimInstance Win32_PhysicalMemory | Sort-Object BankLabel, DeviceLocator | ForEach-Object {
        $slot++
        $part = Clean $_.PartNumber
        $t = ''
        if ($memTypes.ContainsKey([int]$_.SMBIOSMemoryType)) { $t = $memTypes[[int]$_.SMBIOSMemoryType] }
        $spd = 0
        if ($_.Speed) { $spd = [int]$_.Speed } elseif ($_.ConfiguredClockSpeed) { $spd = [int]$_.ConfiguredClockSpeed }
        [ordered]@{
            slot = $slot; size_gb = [int][math]::Floor([double]$_.Capacity / 1GB)
            locator = (Clean $_.DeviceLocator); bank = (Clean $_.BankLabel)
            vendor = (Ram-Vendor $_.Manufacturer $part); part = $part; serial = (Clean $_.SerialNumber)
            type = $t; speed = $spd
        }
    } | Where-Object { $_.size_gb -gt 0 })

    # Disks
    $disks = @()
    $pds = $null
    try { $pds = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    if ($pds) {
        foreach ($d in $pds) {
            if ("$($d.BusType)" -match 'Virtual|File Backed|Spaces|Storage Spaces') { continue }
            $sizeGb = [int][math]::Floor([double]$d.Size / 1e9)
            if ($sizeGb -lt $MinDiskGB) { continue }
            $model = Clean $(if ($d.Model) { $d.Model } else { $d.FriendlyName })
            $type = if ("$($d.BusType)" -eq 'NVMe') { 'NVME' }
                    elseif ("$($d.MediaType)" -eq 'SSD') { 'SSD' }
                    elseif ("$($d.MediaType)" -eq 'HDD') { 'HD' }
                    elseif ($model -match 'SSD|NVME|SOLID') { 'SSD' } else { 'HD' }
            $disks += [ordered]@{
                name = "disk$($d.DeviceId)"; size_gb = $sizeGb; model = $model
                serial = (Clean $d.SerialNumber); vendor = ''; tran = "$($d.BusType)".ToLower(); type = $type
                vendor_norm = (Disk-Vendor $model)
            }
        }
    } else {
        foreach ($d in Get-CimInstance Win32_DiskDrive) {
            $sizeGb = [int][math]::Floor([double]$d.Size / 1e9)
            if ($sizeGb -lt $MinDiskGB -or $d.Model -match 'Virtual') { continue }
            $model = Clean $d.Model
            $disks += [ordered]@{
                name = "disk$($d.Index)"; size_gb = $sizeGb; model = $model; serial = (Clean $d.SerialNumber)
                vendor = ''; tran = "$($d.InterfaceType)".ToLower()
                type = $(if ($model -match 'NVME') { 'NVME' } elseif ($model -match 'SSD') { 'SSD' } else { 'HD' })
                vendor_norm = (Disk-Vendor $model)
            }
        }
    }

    # Network
    $defIdx = $null
    $def = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric } |
        Select-Object -First 1
    if ($def) { $defIdx = $def.ifIndex }
    $defName = ''
    $ifaces = @()
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -ne 'Not Present' })
    # Several adapters on one PnP device (Wi-Fi Direct, HBS/MLO on Wi-Fi 7) are one card:
    # keep the adapter with the factory MAC (locally administered bit cleared)
    $isLocalMac = { param($m) $m -and ([Convert]::ToInt32(($m -replace '[-:]', '').Substring(0, 2), 16) -band 2) }
    $dupSkip = @{}
    foreach ($grp in ($adapters | Where-Object { $_.PnPDeviceID } | Group-Object PnPDeviceID | Where-Object { $_.Count -gt 1 })) {
        $keep = $grp.Group | Where-Object { $_.MacAddress -and -not (& $isLocalMac $_.MacAddress) } | Select-Object -First 1
        if (-not $keep) { $keep = $grp.Group | Select-Object -First 1 }
        foreach ($x in $grp.Group) { if ($x.ifIndex -ne $keep.ifIndex) { $dupSkip[[int]$x.ifIndex] = $true } }
    }
    foreach ($a in $adapters) {
        if ($dupSkip.ContainsKey([int]$a.ifIndex)) { continue }
        $wifi = ($a.NdisPhysicalMedium -eq 9) -or ($a.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11')
        $phys = [bool]$a.HardwareInterface -and -not $wifi
        $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue | Where-Object {
            ($_.AddressFamily -eq 'IPv4' -and $_.IPAddress -notmatch '^(127\.|169\.254\.)') -or
            (-not $NoIPv6 -and $_.AddressFamily -eq 'IPv6' -and $_.IPAddress -notmatch '^(fe80|::1)' -and "$($_.SuffixOrigin)" -ne 'Random')
        } | ForEach-Object { "{0}/{1}" -f ($_.IPAddress -replace '%.*$', ''), $_.PrefixLength })
        $mtu = $null
        $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ipif) { $mtu = [int]$ipif.NlMtu }
        $speed = 0
        if ($a.ReceiveLinkSpeed) { $speed = [int]([double]$a.ReceiveLinkSpeed / 1e6) }
        if ($a.ifIndex -eq $defIdx) { $defName = $a.Name }
        $ifaces += [ordered]@{
            name = $a.Name; description = $a.InterfaceDescription; hardware = [bool]$a.HardwareInterface
            kind = $(if ($phys -or $wifi) { '' } else { 'virtual' })
            mac = ($a.MacAddress -replace '-', ':').ToUpper(); mtu = $mtu; up = ($a.Status -eq 'Up')
            physical = $phys; wireless = $wifi; speed = $speed; addresses = $ips
        }
    }

    [ordered]@{
        hostname = $env:COMPUTERNAME.ToLower(); fqdn = $fqdn; virtual = $virtual
        virt_type = $(if ($virtual) { $cs.Model } else { 'none' })
        system = [ordered]@{
            vendor = (Clean $cs.Manufacturer); product = (Clean $cs.Model)
            serial = (Clean $bios.SerialNumber); board_vendor = (Clean $bb.Manufacturer)
            board_name = (Clean $bb.Product); board_serial = (Clean $bb.SerialNumber)
            chassis_serial = (Clean $(if ($encl) { $encl.SerialNumber } else { '' }))
        }
        os = [ordered]@{
            id = 'windows'; name = $os.Caption; version = $os.Version
            pretty = ("{0} {1} (build {2})" -f $os.Caption, $displayVer, $os.BuildNumber) -replace '\s+', ' '
            platform = $platformName; kernel = $os.Version
        }
        cpu = [ordered]@{
            model = $cpuModel; vendor = (Normalize-Vendor $cpu0.Manufacturer); arch = $arch
            sockets = $cpus.Count; cores_per_socket = [int]$cpu0.NumberOfCores
            threads = [int](($cpus | Measure-Object NumberOfLogicalProcessors -Sum).Sum); speed_ghz = $cpuSpeed
        }
        memory = [ordered]@{ total_gb = [int][math]::Round([double]$cs.TotalPhysicalMemory / 1GB); ecc = $ecc; modules = $modules }
        disks = $disks
        gpus = (Get-Gpus)
        default_iface = $defName
        interfaces = $ifaces
    }
}

# Interfaces that are not needed in NetBox
function Skip-Interface($i) {
    $d = "$($i.description)"
    if ($d -match 'Loopback|WAN Miniport|Teredo|ISATAP|6to4|IP-HTTPS|Kernel Debug|Bluetooth|Microsoft Wi-Fi Direct|VirtualBox Host-Only|VMware Virtual Ethernet|Npcap') { return $true }
    if ($i.name -match '^vEthernet \((WSL|Default Switch)') { return $true }   # internal Hyper-V/WSL networks
    # Virtual Wi-Fi "twins" (Wi-Fi Direct, HBS/MLO modes) and service adapters without addresses
    if ($i.wireless -and -not $i.hardware) { return $true }
    if (-not $i.hardware -and @($i.addresses).Count -eq 0) { return $true }
    if ($SkipInterfaceRegex -and $i.name -match $SkipInterfaceRegex) { return $true }
    return $false
}

# ======================================================================
#  NetBox API
# ======================================================================
$script:Headers = $null
$script:NbVersion = ''
$script:TagRef = @()

function Setup-Api {
    $token = $env:NETBOX_TOKEN
    if (-not $token -and $TokenFile) {
        if (-not (Test-Path $TokenFile)) { Die "cannot read $TokenFile" }
        $token = Get-Content -Raw $TokenFile
    }
    if (-not $token) { Die 'no API token: set NETBOX_TOKEN or -TokenFile' }
    # Accept a whole header copied into the file: "Bearer nbt_..." / "Token ..."
    $token = ($token -replace '^\s*(Bearer|Token)\s+', '') -replace '\s', ''
    $scheme = if ($token -like 'nbt_*') { 'Bearer' } else { 'Token' }
    $script:Headers = @{ Authorization = "$scheme $token"; Accept = 'application/json' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($Insecure) {
        Warn 'TLS verification disabled (-Insecure)'
        if ($PSVersionTable.PSVersion.Major -lt 6) { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
}

# Nb METHOD PATH [BODY] -> response object; on error throws with the NetBox response text
function Nb([string]$Method, [string]$Path, $Body = $null) {
    if ($Method -ne 'GET' -and $DryRun) { return [pscustomobject]@{ id = 0 } }
    $uri = "{0}/api/{1}" -f $Url.TrimEnd('/'), $Path.TrimStart('/')
    $p = @{ Method = $Method; Uri = $uri; Headers = $script:Headers; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($Insecure -and $PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 10 -Compress }
        $p.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $p.ContentType = 'application/json; charset=utf-8'
    }
    try { return Invoke-RestMethod @p }
    catch {
        $msg = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        if ($msg -match 'token|credentials') { Die "token rejected ($msg). Check the token and its permissions." }
        throw "$Method /api/$Path : $msg"
    }
}

function Nb-Find([string]$Path, [string]$Query) {
    $r = Nb GET "$($Path)?$Query&limit=2"
    if ($r.count -gt 1) { Warn "found $($r.count) objects $($Path)?$Query, using the first one" }
    if ($r.count -ge 1) { return $r.results[0] }
    return $null
}

# Find by slug/name, otherwise create. Returns the id.
function Nb-EnsureNamed([string]$Path, [string]$NameValue, [hashtable]$Extra = @{}) {
    $slug = Slugify $NameValue
    $o = $null
    if ($slug) { $o = Nb-Find $Path "slug=$(Enc $slug)" }
    if (-not $o) { $o = Nb-Find $Path "name__ie=$(Enc $NameValue)" }
    if ($o) { return [int]$o.id }
    $body = @{ name = $NameValue; slug = $(if ($slug) { $slug } else { 'x-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }); tags = $script:TagRef } + $Extra
    Change "create $($Path.TrimEnd('/')) '$NameValue'"
    return [int](Nb POST $Path $body).id
}

# Lookup only (site/tenant/rack/location are never created)
function Nb-LookupNamed([string]$Path, [string]$NameValue, [string]$ExtraQ = '') {
    $q = if ($ExtraQ) { "&$ExtraQ" } else { '' }
    $o = Nb-Find $Path "name__ie=$(Enc $NameValue)$q"
    if (-not $o) { $o = Nb-Find $Path "slug=$(Enc (Slugify $NameValue))$q" }
    if ($o) { return [int]$o.id }
    return 0
}

function Check-NetBox {
    try { $st = Nb GET 'status/' } catch { Die "NetBox is unreachable: $Url ($_)" }
    $script:NbVersion = ("$($st.'netbox-version')" -split '-')[0]
    $null = Nb GET 'dcim/sites/?limit=1'
    Ok "NetBox $($script:NbVersion) ($Url)"
    $script:TagRef = @(@{ slug = (Slugify $Tag) })
    if (-not $DryRun) { $null = Nb-EnsureNamed 'extras/tags/' $Tag @{ color = '9e9e9e'; description = 'Created by netbox_inventory.ps1' } }
}
function Version-Ge([string]$a, [string]$b) { try { return [version]$a -ge [version]$b } catch { return $false } }

# ======================================================================
#  Device
# ======================================================================
$script:DeviceId = 0
$script:Device = $null

function Ensure-DeviceType($f) {
    $model = $f.system.product; $vendor = $f.system.vendor
    if (-not $model) { $model = $f.system.board_name; $vendor = $f.system.board_vendor }
    if (-not $model) { $model = 'Generic workstation' }
    $vendor = Normalize-Vendor $vendor; if (-not $vendor) { $vendor = 'Generic' }
    # First look for the model under any manufacturer: no duplicate if the type was created manually
    $o = Nb-Find 'dcim/device-types/' "model__ie=$(Enc $model)"
    if ($o) { return [int]$o.id }
    $mid = Nb-EnsureNamed 'dcim/manufacturers/' $vendor
    Change "create device type '$vendor $model'"
    return [int](Nb POST 'dcim/device-types/' @{ manufacturer = $mid; model = $model; slug = (Slugify "$vendor-$model"); tags = $script:TagRef }).id
}

# A platform can be restricted to a manufacturer - then NetBox will not allow assigning it
function Platform-ForType([int]$PlatformId, [int]$TypeId) {
    if ($PlatformId -le 0 -or $TypeId -le 0) { return $PlatformId }
    $pl = Nb GET "dcim/platforms/$PlatformId/"
    if ($pl.manufacturer) {
        $dt = Nb GET "dcim/device-types/$TypeId/"
        if ($pl.manufacturer.id -ne $dt.manufacturer.id) {
            Warn "platform '$($pl.name)' is restricted to manufacturer '$($pl.manufacturer.name)' - not assigning it. Clear the platform manufacturer in NetBox if it is an OS."
            return 0
        }
    }
    return $PlatformId
}

# The hostname may differ from the NetBox name: look up by serial number, then by host IP addresses
function Find-DeviceFallback($f, [string]$Serial) {
    if ($Serial) {
        $r = Nb GET "dcim/devices/?serial=$(Enc $Serial)&limit=2"
        if ($r.count -eq 1) { Log "  found by serial number $Serial"; return $r.results[0] }
    }
    $ids = @()
    foreach ($i in $f.interfaces) { foreach ($a in $i.addresses) {
        if ($a -like '*:*') { continue }
        $ip = Nb-Find 'ipam/ip-addresses/' "address=$(Enc $a)&vrf_id=null"
        if ($ip -and $ip.assigned_object -and $ip.assigned_object.PSObject.Properties['device']) { $ids += [int]$ip.assigned_object.device.id }
    } }
    $ids = @($ids | Sort-Object -Unique)
    if ($ids.Count -eq 1) { Log '  found by host IP addresses'; return (Nb GET "dcim/devices/$($ids[0])/") }
    return $null
}

function Ensure-Device($f) {
    $explicit = [bool]$Name
    $devName = if ($Name) { $Name } else { $f.hostname }
    $serial = if ($f.system.serial) { $f.system.serial } else { $f.system.board_serial }
    $platName = if ($Platform) { $Platform } else { $f.os.platform }
    $platformId = if ($platName) { Nb-EnsureNamed 'dcim/platforms/' $platName } else { 0 }
    $tenantId = 0
    if ($Tenant) { $tenantId = Nb-LookupNamed 'tenancy/tenants/' $Tenant; if (-not $tenantId) { Die "tenant '$Tenant' not found" } }

    $script:Device = Nb-Find 'dcim/devices/' "name=$(Enc $devName)"
    if (-not $script:Device -and -not $explicit) {
        $script:Device = Find-DeviceFallback $f $serial
        if ($script:Device) {
            Warn "hostname '$devName' differs from the NetBox name '$($script:Device.name)' - using it (the NetBox name is not changed; use -Name to skip the lookup)"
            $devName = $script:Device.name
        }
    }
    $script:DeviceName = $devName

    if ($script:Device) {
        $script:DeviceId = [int]$script:Device.id
        Ok "device '$devName' found (id $($script:DeviceId))"
        $platformId = Platform-ForType $platformId ([int]$script:Device.device_type.id)
        $patch = @{}
        if ($serial -and -not $script:Device.serial) { $patch.serial = $serial }
        $curPl = if ($script:Device.platform) { [int]$script:Device.platform.id } else { 0 }
        if ($platformId -gt 0 -and $curPl -ne $platformId) { $patch.platform = $platformId }
        $curTn = if ($script:Device.tenant) { [int]$script:Device.tenant.id } else { 0 }
        if ($tenantId -gt 0 -and $curTn -ne $tenantId) { $patch.tenant = $tenantId }
        if ($patch.Count) {
            Change "update device ${devName}: $(ConvertTo-Json -InputObject $patch -Compress)"
            $null = Nb PATCH "dcim/devices/$($script:DeviceId)/" $patch
        }
        if ($Rack -or $Location) { Warn '-Rack/-Location apply only on creation; placement of an existing device is not changed' }
        return
    }

    if (-not $Site) { Die "device '$devName' is not in NetBox; specify -Site to create it" }
    $siteId = Nb-LookupNamed 'dcim/sites/' $Site
    if (-not $siteId) { Die "site '$Site' not found" }
    $roleId = Nb-EnsureNamed 'dcim/device-roles/' $Role @{ color = '9e9e9e' }
    $typeId = Ensure-DeviceType $f
    $platformId = Platform-ForType $platformId $typeId
    $body = @{ name = $devName; device_type = $typeId; role = $roleId; site = $siteId; status = 'active'; tags = $script:TagRef }
    if ($serial) { $body.serial = $serial }
    if ($platformId -gt 0) { $body.platform = $platformId }
    if ($tenantId -gt 0) { $body.tenant = $tenantId }
    if ($Location) {
        $l = Nb-LookupNamed 'dcim/locations/' $Location "site_id=$siteId"
        if (-not $l) { Die "location '$Location' not found at site '$Site'" }
        $body.location = $l
    }
    if ($Rack) {
        $r = Nb-LookupNamed 'dcim/racks/' $Rack "site_id=$siteId"
        if (-not $r) { Die "rack '$Rack' not found at site '$Site'" }
        $body.rack = $r
    }
    Change "create device '$devName'"
    $script:DeviceId = [int](Nb POST 'dcim/devices/' $body).id
}

# ======================================================================
#  Modules: CPU, RAM, disks, GPUs
# ======================================================================
$script:Profiles = @{}
$script:ProfileSchemas = @{}
$script:Modules = @()
$script:Bays = @()

function Load-Profiles {
    if (-not (Version-Ge $script:NbVersion '4.3')) { Warn "NetBox $($script:NbVersion) < 4.3: module type profiles are unavailable"; return }
    foreach ($p in (Nb GET 'dcim/module-type-profiles/?limit=100').results) { $script:Profiles[$p.name] = [int]$p.id; $script:ProfileSchemas[$p.name] = $p.schema }
}
function Load-DeviceModules {
    if ($script:DeviceId -le 0) { return }
    $script:Modules = @((Nb GET "dcim/modules/?device_id=$($script:DeviceId)&limit=1000").results)
    $script:Bays = @((Nb GET "dcim/module-bays/?device_id=$($script:DeviceId)&limit=1000").results)
}

function Ensure-ModuleType([string]$Vendor, [string]$Model, [string]$ProfileName, [hashtable]$Attrs) {
    if (-not $Vendor) { $Vendor = 'Generic' }
    $mid = Nb-EnsureNamed 'dcim/manufacturers/' $Vendor
    if ($mid -gt 0) {
        $o = Nb-Find 'dcim/module-types/' "manufacturer_id=$mid&model=$(Enc $Model)"
        if ($o) { return [int]$o.id }
    }
    $body = @{ manufacturer = $mid; model = $Model; tags = $script:TagRef }
    if ($script:Profiles.ContainsKey($ProfileName)) {
        # Check attributes against the profile schema: unknown keys and values outside the enum are dropped;
        # if required attributes are missing, the type is created without a profile
        $schema = $script:ProfileSchemas[$ProfileName]
        $props = $null
        if ($schema -and $schema.PSObject.Properties['properties']) { $props = $schema.properties }
        $a = @{}
        foreach ($k in $Attrs.Keys) {
            $val = $Attrs[$k]
            if ($null -eq $val) { continue }
            if ($props) {
                if (-not $props.PSObject.Properties[$k]) { continue }
                $def = $props.$k
                if ($def.PSObject.Properties['enum'] -and -not (@($def.enum) -contains $val)) { continue }
            }
            $a[$k] = $val
        }
        $missing = @()
        if ($schema -and $schema.PSObject.Properties['required']) { $missing = @($schema.required | Where-Object { -not $a.ContainsKey($_) }) }
        if ($missing.Count -eq 0) { $body.profile = $script:Profiles[$ProfileName]; $body.attributes = $a }
        else { Warn "module type '$Vendor $Model' is created without profile '$ProfileName': required attributes are unknown ($($missing -join ', '))" }
    }
    Change "create module type '$Vendor $Model'"
    return [int](Nb POST 'dcim/module-types/' $body).id
}

# Module by serial number; otherwise a module without serial in a bay with the same prefix; otherwise a free/new bay
function Place-Module([string]$Prefix, [string]$BayName, [string]$Label, [int]$TypeId, [string]$Serial) {
    if ($script:DeviceId -le 0) { Change "module $BayName (device not created yet)"; return }
    $mod = $null
    if ($Serial) { $mod = $script:Modules | Where-Object { $_.serial -eq $Serial } | Select-Object -First 1 }
    if (-not $mod) {
        $mod = $script:Modules | Where-Object { $_.module_bay.name -eq $BayName } | Select-Object -First 1
        if ($mod -and $Serial -and $mod.serial) { $mod = $null }
    }
    if (-not $mod) { $mod = $script:Modules | Where-Object { $_.module_bay.name -like "$Prefix*" -and -not $_.serial } | Select-Object -First 1 }
    if ($mod) {
        $patch = @{}
        if ([int]$mod.module_type.id -ne $TypeId) { $patch.module_type = $TypeId }
        if ($Serial -and $mod.serial -ne $Serial) { $patch.serial = $Serial }
        if ($patch.Count) {
            Change "update module in bay $($mod.module_bay.name): $(ConvertTo-Json -InputObject $patch -Compress)"
            $null = Nb PATCH "dcim/modules/$($mod.id)/" $patch
        }
        $script:Modules = @($script:Modules | Where-Object { $_.id -ne $mod.id })
        return
    }
    $bay = $script:Bays | Where-Object { $_.name -eq $BayName -and -not $_.installed_module } | Select-Object -First 1
    if ($bay) { $bayId = [int]$bay.id; $bay.installed_module = @{ id = -1 } }
    else {
        if ($script:Bays | Where-Object { $_.name -eq $BayName }) {
            $n = 1; while ($script:Bays | Where-Object { $_.name -eq "$Prefix$n" }) { $n++ }; $BayName = "$Prefix$n"
        }
        Change "create bay $BayName"
        $bayId = [int](Nb POST 'dcim/module-bays/' @{ device = $script:DeviceId; name = $BayName; label = $Label; tags = $script:TagRef }).id
        $script:Bays += [pscustomobject]@{ id = $bayId; name = $BayName; installed_module = @{ id = -1 } }
    }
    Change ("install module in $BayName" + $(if ($Serial) { " (s/n $Serial)" } else { '' }))
    $body = @{ device = $script:DeviceId; module_bay = $bayId; module_type = $TypeId; status = 'active'; tags = $script:TagRef }
    if ($Serial) { $body.serial = $Serial }
    $null = Nb POST 'dcim/modules/' $body
}

function Sync-Cpu($f) {
    if (-not $f.cpu.model) { return }
    # "AMD Ryzen 9 9950X3D 16-Core Processor" -> "Ryzen 9 9950X3D"; "Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz" -> "Core i7-8700"
    $m = $f.cpu.model -replace '\((R|TM|tm|r)\)', '' -replace '@.*$', '' -replace '\s[0-9]+-Core', '' -replace '\s(CPU|Processor)(\s|$)', ' ' -replace '^(Intel|AMD)\s+', '' -replace '\s+', ' '
    $m = $m.Trim()
    $tid = Ensure-ModuleType $f.cpu.vendor $m 'CPU' @{ cores = $f.cpu.cores_per_socket; speed = $f.cpu.speed_ghz; architecture = $f.cpu.arch }
    for ($i = 1; $i -le $f.cpu.sockets; $i++) {
        $bay = if ($f.cpu.sockets -eq 1) { 'CPU' } else { "CPU$i" }
        Place-Module 'CPU' $bay "CPU socket $i" $tid ''
    }
}

function Sync-Memory($f) {
    if (-not $f.memory.modules -or $f.memory.modules.Count -eq 0) { Log '  RAM modules: no data, skipping'; return }
    foreach ($m in $f.memory.modules) {
        $model = if ($m.part) { $m.part } else { "$($m.size_gb)GB $(if ($m.type) { $m.type } else { 'RAM' })" }
        $class = if ($m.type -match '^DDR[345]$') { $m.type } else { $null }
        $rate = if ($m.speed -gt 0) { $m.speed } else { $null }
        $tid = Ensure-ModuleType $m.vendor $model 'Memory' @{ size = $m.size_gb; ecc = $f.memory.ecc; class = $class; data_rate = $rate }
        $loc = (@($m.bank, $m.locator) | Where-Object { $_ }) -join ' / '
        Place-Module 'RAM-' "RAM-$($m.slot)" $loc $tid $m.serial
    }
}

function Sync-Disks($f) {
    $i = 0
    foreach ($d in $f.disks) {
        $i++
        $model = if ($d.model) { $d.model } else { "$($d.size_gb)GB $($d.type)" }
        $tid = Ensure-ModuleType $d.vendor_norm $model 'Hard disk' @{ size = $d.size_gb; type = $d.type }
        Place-Module 'Disk-' "Disk-$i" $d.name $tid $d.serial
    }
}

function Sync-Gpus($f) {
    $i = 0
    foreach ($g in @($f.gpus)) {
        if ($null -eq $g) { continue }
        $i++
        $iface = if ($g.pcie_gen -and $g.pcie_width) { "PCIe $($g.pcie_gen) x$($g.pcie_width)" } else { $null }
        $chip = (@($g.vendor, $g.name) | Where-Object { $_ }) -join ' '
        $tid = Ensure-ModuleType $g.card_vendor $g.name 'GPU' @{ gpu = $chip; memory = $g.memory_gb; interface = $iface }
        Place-Module 'GPU-' "GPU-$i" $g.pci $tid $g.serial
    }
}

# ======================================================================
#  Interfaces, MAC, IP
# ======================================================================
$script:IfaceIds = @{}

function Iface-Type($i) {
    if ($i.wireless) {
        if ($i.description -cmatch '\bBE[0-9]{3}' -or $i.description -match 'Wi-?Fi 7') { return 'ieee802.11be' }
        if ($i.description -cmatch '\bAX[0-9]{3}' -or $i.description -match 'Wi-?Fi 6') { return 'ieee802.11ax' }
        return 'ieee802.11ac'
    }
    if ($i.physical) {
        switch ([int]$i.speed) {
            10 { return '10base-t' } 100 { return '100base-tx' } 1000 { return '1000base-t' }
            2500 { return '2.5gbase-t' } 5000 { return '5gbase-t' } 10000 { return '10gbase-t' }
            25000 { return '25gbase-x-sfp28' } 40000 { return '40gbase-x-qsfpp' }
        }
        return 'other'
    }
    return 'virtual'
}

function Sync-Mac([int]$Iid, [string]$Mac, $Cur, [bool]$NewApi) {
    if ($Iid -le 0) { Change "MAC $Mac (interface not created yet)"; return }
    if (-not $NewApi) {
        $curMac = if ($Cur) { "$($Cur.mac_address)".ToUpper() } else { '' }
        if ($curMac -ne $Mac) { Change "MAC $Mac on interface $Iid"; $null = Nb PATCH "dcim/interfaces/$Iid/" @{ mac_address = $Mac } }
        return
    }
    # NetBox 4.2+: a MAC is a separate object, the interface references primary_mac_address
    $o = Nb-Find 'dcim/mac-addresses/' "mac_address=$(Enc $Mac)&interface_id=$Iid"
    if ($o) { $mid = [int]$o.id }
    else {
        Change "MAC $Mac -> interface $Iid"
        $mid = [int](Nb POST 'dcim/mac-addresses/' @{ mac_address = $Mac; assigned_object_type = 'dcim.interface'; assigned_object_id = $Iid; tags = $script:TagRef }).id
    }
    $hasPrimary = $Cur -and $Cur.PSObject.Properties['primary_mac_address'] -and $Cur.primary_mac_address
    if (-not $hasPrimary -and $mid -gt 0) { $null = Nb PATCH "dcim/interfaces/$Iid/" @{ primary_mac_address = $mid } }
}

function Sync-Interfaces($f) {
    $existing = @()
    if ($script:DeviceId -gt 0) { $existing = @((Nb GET "dcim/interfaces/?device_id=$($script:DeviceId)&limit=1000").results) }
    $newMac = Version-Ge $script:NbVersion '4.2'
    foreach ($i in $f.interfaces) {
        if (Skip-Interface $i) { continue }
        $type = Iface-Type $i
        $cur = $existing | Where-Object { $_.name -eq $i.name } | Select-Object -First 1
        if ($cur) {
            $id = [int]$cur.id
            if ($cur.type.value -eq 'other' -and $cur.cable -and $type -in 'bridge', 'lag', 'virtual') {
                Warn "interface $($i.name): a cable is attached in NetBox, not setting type '$type'"; $type = 'other'
            }
            $patch = @{}
            if ($cur.type.value -eq 'other' -and $type -ne 'other') { $patch.type = $type }
            if ($i.mtu -and [int]$cur.mtu -ne [int]$i.mtu) { $patch.mtu = [int]$i.mtu }
            if ($patch.Count) { Change "update interface $($i.name): $(ConvertTo-Json -InputObject $patch -Compress)"; $null = Nb PATCH "dcim/interfaces/$id/" $patch }
        } else {
            Change "create interface $($i.name) ($type)"
            $body = @{ device = $script:DeviceId; name = $i.name; type = $type; enabled = [bool]$i.up; description = $i.description; tags = $script:TagRef }
            if ($i.mtu) { $body.mtu = [int]$i.mtu }
            $id = [int](Nb POST 'dcim/interfaces/' $body).id
        }
        $script:IfaceIds[$i.name] = $id
        if ($i.mac) { Sync-Mac $id $i.mac $cur $newMac }
    }
}

function Sync-Ips($f) {
    $primary4 = 0
    foreach ($i in $f.interfaces) {
        if (-not $script:IfaceIds.ContainsKey($i.name)) { continue }
        $iid = $script:IfaceIds[$i.name]
        foreach ($addr in $i.addresses) {
            $isPrimary = ($i.name -eq $f.default_iface -and $addr -notlike '*:*' -and $primary4 -eq 0)
            $ip = Nb-Find 'ipam/ip-addresses/' "address=$(Enc $addr)&vrf_id=null"
            if ($ip) {
                $ipId = [int]$ip.id
                $ownerDev = 0; $ownerName = ''
                if ($ip.assigned_object) {
                    if ($ip.assigned_object.PSObject.Properties['device']) { $ownerDev = [int]$ip.assigned_object.device.id; $ownerName = $ip.assigned_object.device.name }
                    elseif ($ip.assigned_object.PSObject.Properties['virtual_machine']) { $ownerDev = -1; $ownerName = $ip.assigned_object.virtual_machine.name }
                }
                if ($ownerDev -ne 0 -and $ownerDev -ne $script:DeviceId) { Warn "IP $addr is already assigned to another device ($ownerName) - leaving it"; continue }
                if ([int]$ip.assigned_object_id -ne $iid) {
                    Change "IP $addr -> $($i.name)"
                    $null = Nb PATCH "ipam/ip-addresses/$ipId/" @{ assigned_object_type = 'dcim.interface'; assigned_object_id = $iid }
                }
                if ($isPrimary -and $f.fqdn -and -not $ip.dns_name) { Change "DNS name $($f.fqdn) for $addr"; $null = Nb PATCH "ipam/ip-addresses/$ipId/" @{ dns_name = $f.fqdn } }
            } else {
                $body = @{ address = $addr; status = 'active'; assigned_object_type = 'dcim.interface'; assigned_object_id = $iid; tags = $script:TagRef }
                if ($isPrimary -and $f.fqdn) { $body.dns_name = $f.fqdn }
                Change "create IP $addr on $($i.name)"
                $ipId = [int](Nb POST 'ipam/ip-addresses/' $body).id
            }
            if ($isPrimary) { $primary4 = $ipId }
        }
    }
    # primary_ip4 is set only if it is empty (a manual choice is not overwritten)
    $cur = 0
    if ($script:Device -and $script:Device.primary_ip4) { $cur = [int]$script:Device.primary_ip4.id }
    if ($primary4 -gt 0 -and $script:DeviceId -gt 0 -and $cur -eq 0) {
        Change "device primary IPv4 -> $primary4"
        $null = Nb PATCH "dcim/devices/$($script:DeviceId)/" @{ primary_ip4 = $primary4 }
    }
}

# ======================================================================
function Show-Summary($f) {
    $s = $f.system
    Log ("Host:      {0}{1}{2}" -f $f.hostname, $(if ($f.fqdn) { " ($($f.fqdn))" } else { '' }), $(if ($f.virtual) { "  [VM: $($f.virt_type)]" } else { '' }))
    Log ("System:    {0} {1}  board: {2} {3}  s/n: {4}" -f $s.vendor, $s.product, $s.board_vendor, $s.board_name, $(if ($s.serial) { $s.serial } elseif ($s.board_serial) { $s.board_serial } else { '-' }))
    Log ("OS:        {0}  -> platform {1}" -f $f.os.pretty, $f.os.platform)
    Log ("CPU:       {0}x {1}  ({2} cores/socket, {3} threads)" -f $f.cpu.sockets, $f.cpu.model, $f.cpu.cores_per_socket, $f.cpu.threads)
    Log ("RAM:       {0} GB  [{1}]" -f $f.memory.total_gb, ((@($f.memory.modules) | ForEach-Object { "$($_.size_gb)G $($_.vendor) $($_.part)" }) -join ', '))
    Log ("Disks:     {0}" -f ((@($f.disks) | ForEach-Object { "$($_.name) $($_.size_gb)GB $($_.type) $($_.model)" }) -join '; '))
    Log ("GPU:       {0}" -f $(if (@($f.gpus).Count) { (@($f.gpus) | ForEach-Object { "$($_.card_vendor) $($_.name)$(if ($_.memory_gb) { " $($_.memory_gb)GB" })" }) -join '; ' } else { '-' }))
    Log ("Network:   {0}" -f ((@($f.interfaces) | Where-Object { $_.addresses.Count -gt 0 -and -not (Skip-Interface $_) } | ForEach-Object { "$($_.name) $($_.addresses -join ',')" }) -join '; '))
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Warn 'not running as administrator: some serial numbers may be unavailable' }

Log 'Collecting host data...'
$facts = Get-Facts
if ($CollectOnly) { ConvertTo-Json -InputObject $facts -Depth 10; exit 0 }
Show-Summary $facts
if ($facts.virtual) { Warn "this is a virtual machine ($($facts.virt_type)): it is better tracked in Virtualization, not Devices" }
if ($DryRun) { Warn '-DryRun mode: changes are only printed' }

Setup-Api
Check-NetBox
Load-Profiles
Ensure-Device $facts
Load-DeviceModules
Log 'Modules...'
Sync-Cpu $facts
Sync-Memory $facts
Sync-Disks $facts
Sync-Gpus $facts
Log 'Interfaces and addresses...'
Sync-Interfaces $facts
Sync-Ips $facts
Ok ("Done: {0}{1}" -f $script:DeviceName, $(if ($DryRun) { ' (dry-run, nothing changed)' } else { '' }))

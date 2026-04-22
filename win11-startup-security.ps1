[CmdletBinding()]
param(
    [ValidateRange(1, 168)]
    [int]$CooldownHours = 12,
    [ValidateRange(3, 10)]
    [int]$LockoutThreshold = 3,
    [ValidateRange(1, 99999)]
    [int]$LockoutDurationMinutes = 30,
    [ValidateRange(1, 99999)]
    [int]$LockoutWindowMinutes = 30,
    [ValidateRange(0, 23)]
    [int]$UpdateInstallHour = 3,
    [ValidateRange(1, 24)]
    [int]$SignatureUpdateCooldownHours = 6,
    [ValidateRange(1, 24)]
    [int]$WindowsUpdateTriggerCooldownHours = 6,
    [ValidateRange(24, 720)]
    [int]$FullScanCooldownHours = 168,
    [ValidateSet("Auto", "Low", "Balanced", "High")]
    [string]$PerformanceProfile = "Auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Ce script doit etre lance en administrateur."
    exit 1
}

$baseDir = "C:\logs\Win11SecurityBoot"
$logDir = $baseDir
$stateFile = Join-Path "$env:ProgramData\Win11SecurityBoot" "last-run.txt"
$stateDir = Join-Path "$env:ProgramData\Win11SecurityBoot" "state"

New-Item -Path $logDir -ItemType Directory -Force | Out-Null
New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = Join-Path $logDir "security-$timestamp.log"
$complianceFile = Join-Path $logDir "compliance-$timestamp.log"
$complianceResults = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    $line | Tee-Object -FilePath $logFile -Append
}

function Get-HardwareProfile {
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $processors = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop

        $memoryGb = [Math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 1)
        $logicalCpu = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)

        $tier = "High"
        if (($memoryGb -le 8) -or ($logicalCpu -le 4)) {
            $tier = "Low"
        }
        elseif (($memoryGb -le 16) -or ($logicalCpu -le 8)) {
            $tier = "Balanced"
        }

        return [PSCustomObject]@{
            MemoryGb = $memoryGb
            LogicalCpu = $logicalCpu
            Tier = $tier
            Source = "CIM"
        }
    }
    catch {
        return [PSCustomObject]@{
            MemoryGb = -1
            LogicalCpu = -1
            Tier = "Balanced"
            Source = "Fallback"
        }
    }
}

function Resolve-PerformanceSettings {
    param(
        [string]$RequestedProfile,
        [int]$RequestedCooldownHours,
        [int]$RequestedSignatureUpdateCooldownHours,
        [int]$RequestedWindowsUpdateTriggerCooldownHours,
        [int]$RequestedFullScanCooldownHours
    )

    $hardware = Get-HardwareProfile
    $resolvedProfile = $RequestedProfile
    if ($RequestedProfile -eq "Auto") {
        $resolvedProfile = $hardware.Tier
    }

    $effectiveCooldownHours = $RequestedCooldownHours
    $effectiveSignatureUpdateCooldownHours = $RequestedSignatureUpdateCooldownHours
    $effectiveWindowsUpdateTriggerCooldownHours = $RequestedWindowsUpdateTriggerCooldownHours
    $effectiveFullScanCooldownHours = $RequestedFullScanCooldownHours
    $backgroundPriority = "BelowNormal"

    switch ($resolvedProfile) {
        "Low" {
            $effectiveCooldownHours = [Math]::Max($RequestedCooldownHours, 24)
            $effectiveSignatureUpdateCooldownHours = [Math]::Max($RequestedSignatureUpdateCooldownHours, 12)
            $effectiveWindowsUpdateTriggerCooldownHours = [Math]::Max($RequestedWindowsUpdateTriggerCooldownHours, 24)
            $effectiveFullScanCooldownHours = [Math]::Max($RequestedFullScanCooldownHours, 336)
            $backgroundPriority = "Idle"
        }
        "Balanced" {
            $effectiveCooldownHours = [Math]::Max($RequestedCooldownHours, 12)
            $effectiveSignatureUpdateCooldownHours = [Math]::Max($RequestedSignatureUpdateCooldownHours, 6)
            $effectiveWindowsUpdateTriggerCooldownHours = [Math]::Max($RequestedWindowsUpdateTriggerCooldownHours, 12)
            $effectiveFullScanCooldownHours = [Math]::Max($RequestedFullScanCooldownHours, 168)
            $backgroundPriority = "BelowNormal"
        }
        default {
            $backgroundPriority = "BelowNormal"
        }
    }

    return [PSCustomObject]@{
        Hardware = $hardware
        RequestedProfile = $RequestedProfile
        ResolvedProfile = $resolvedProfile
        CooldownHours = $effectiveCooldownHours
        SignatureUpdateCooldownHours = $effectiveSignatureUpdateCooldownHours
        WindowsUpdateTriggerCooldownHours = $effectiveWindowsUpdateTriggerCooldownHours
        FullScanCooldownHours = $effectiveFullScanCooldownHours
        BackgroundPriority = $backgroundPriority
    }
}

$script:NotificationSupported = $false
$script:NotificationReason = ""

function Initialize-NotificationSupport {
    if (-not [Environment]::UserInteractive) {
        $script:NotificationSupported = $false
        $script:NotificationReason = "Session non interactive (execution en compte service/systeme)."
        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $script:NotificationSupported = $true
        $script:NotificationReason = ""
    }
    catch {
        $script:NotificationSupported = $false
        $script:NotificationReason = "Assemblies notification indisponibles: $($_.Exception.Message)"
    }
}

function Get-NotificationTemplate {
    param([string]$TaskName)

    switch ($TaskName) {
        "defender-signature-update" {
            return [PSCustomObject]@{
                Title = "Defender - Signatures"
                Message = "Mise a jour des signatures antivirus lancee."
                Icon = [System.Drawing.SystemIcons]::Information
            }
        }
        "defender-full-scan" {
            return [PSCustomObject]@{
                Title = "Defender - Scan complet"
                Message = "Scan antivirus complet demarre."
                Icon = [System.Drawing.SystemIcons]::Warning
            }
        }
        "windows-update-trigger" {
            return [PSCustomObject]@{
                Title = "Windows Update"
                Message = "Recherche/telechargement/installation des mises a jour declenches."
                Icon = [System.Drawing.SystemIcons]::Application
            }
        }
        "compliance-summary" {
            return [PSCustomObject]@{
                Title = "Securisation Windows"
                Message = "Rapport de conformite genere."
                Icon = [System.Drawing.SystemIcons]::Asterisk
            }
        }
        default {
            return [PSCustomObject]@{
                Title = "Securisation Windows"
                Message = "Tache de securite executee."
                Icon = [System.Drawing.SystemIcons]::Information
            }
        }
    }
}

function Show-TaskNotification {
    param(
        [string]$TaskName,
        [ValidateSet("Success", "Skipped", "Warning", "Error")]
        [string]$Status = "Success",
        [string]$Details = ""
    )

    if (-not $script:NotificationSupported) {
        if (-not [string]::IsNullOrWhiteSpace($script:NotificationReason)) {
            Write-Log "Notification non affichee pour '$TaskName': $script:NotificationReason"
        }
        return
    }

    $template = Get-NotificationTemplate -TaskName $TaskName
    $message = $template.Message
    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        $message = "$message $Details"
    }

    $balloonIcon = [System.Windows.Forms.ToolTipIcon]::Info
    if ($Status -eq "Error") {
        $balloonIcon = [System.Windows.Forms.ToolTipIcon]::Error
    }
    elseif (($Status -eq "Warning") -or ($Status -eq "Skipped")) {
        $balloonIcon = [System.Windows.Forms.ToolTipIcon]::Warning
    }

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    try {
        $notifyIcon.Icon = $template.Icon
        $notifyIcon.Visible = $true
        $notifyIcon.BalloonTipIcon = $balloonIcon
        $notifyIcon.BalloonTipTitle = $template.Title
        $notifyIcon.BalloonTipText = $message
        $notifyIcon.ShowBalloonTip(10000)
        Write-Log "Notification affichee: task='$TaskName' status='$Status' message='$message'"
    }
    catch {
        Write-Log "Erreur notification '$TaskName': $($_.Exception.Message)"
    }
    finally {
        $notifyIcon.Dispose()
    }
}

function Convert-ToAuditString {
    param([object]$Value)

    if ($null -eq $Value) {
        return "<null>"
    }

    if ($Value -is [array]) {
        return (($Value | ForEach-Object { Convert-ToAuditString -Value $_ }) -join ",")
    }

    if ($Value -is [bool]) {
        if ($Value) {
            return "True"
        }

        return "False"
    }

    return [string]$Value
}

function Add-ComplianceResult {
    param(
        [string]$Rule,
        [string]$Expected,
        [object]$Before,
        [object]$After,
        [string]$Status,
        [string]$Details
    )

    $entry = [PSCustomObject]@{
        Rule = $Rule
        Expected = $Expected
        Before = (Convert-ToAuditString -Value $Before)
        After = (Convert-ToAuditString -Value $After)
        Status = $Status
        Details = $Details
    }

    [void]$complianceResults.Add($entry)
    Write-Log ("Conformite [{0}] {1} | attendu='{2}' | avant='{3}' | apres='{4}' | details='{5}'" -f $entry.Status, $entry.Rule, $entry.Expected, $entry.Before, $entry.After, $entry.Details)
}

function Invoke-ComplianceRule {
    param(
        [string]$Rule,
        [string]$Expected,
        [ScriptBlock]$GetValue,
        [ScriptBlock]$Apply,
        [ScriptBlock]$IsCompliant
    )

    $before = "N/A"
    $after = "N/A"
    $status = "KO"
    $details = ""

    try {
        $before = & $GetValue
    }
    catch {
        $before = "UNREADABLE"
        $details = "Lecture avant echec: $($_.Exception.Message)"
    }

    try {
        & $Apply
    }
    catch {
        $applyError = "Application echec: $($_.Exception.Message)"
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $applyError
        }
        else {
            $details = "$details | $applyError"
        }
    }

    try {
        $after = & $GetValue
    }
    catch {
        $after = "UNREADABLE"
        $readAfterError = "Lecture apres echec: $($_.Exception.Message)"
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $readAfterError
        }
        else {
            $details = "$details | $readAfterError"
        }
    }

    try {
        if (& $IsCompliant $after) {
            $status = "OK"
            if ([string]::IsNullOrWhiteSpace($details)) {
                $details = "Regle conforme"
            }
        }
        else {
            $status = "KO"
            if ([string]::IsNullOrWhiteSpace($details)) {
                $details = "Valeur finale non conforme"
            }
        }
    }
    catch {
        $status = "KO"
        $checkError = "Verification echec: $($_.Exception.Message)"
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = $checkError
        }
        else {
            $details = "$details | $checkError"
        }
    }

    Add-ComplianceResult -Rule $Rule -Expected $Expected -Before $before -After $after -Status $status -Details $details
}

function Test-ShouldRun {
    param([int]$Hours)

    if (-not (Test-Path $stateFile)) {
        return $true
    }

    try {
        $lastRunRaw = Get-Content -Path $stateFile -ErrorAction Stop | Select-Object -First 1
        $lastRun = [DateTime]::Parse($lastRunRaw)
        $delta = (Get-Date) - $lastRun
        return $delta.TotalHours -ge $Hours
    }
    catch {
        return $true
    }
}

function Save-RunState {
    (Get-Date).ToString("o") | Set-Content -Path $stateFile -Encoding ASCII
}

function Set-RegistryDword {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value
    )

    New-Item -Path $Path -Force | Out-Null
    Set-ItemProperty -Path $Path -Name $Name -Type DWord -Value $Value
}

function Get-TaskStateFile {
    param([string]$TaskName)

    return (Join-Path $stateDir "$TaskName.txt")
}

function Test-TaskShouldRun {
    param(
        [string]$TaskName,
        [int]$Hours
    )

    $taskStateFile = Get-TaskStateFile -TaskName $TaskName
    if (-not (Test-Path $taskStateFile)) {
        return $true
    }

    try {
        $lastRunRaw = Get-Content -Path $taskStateFile -ErrorAction Stop | Select-Object -First 1
        $lastRun = [DateTime]::Parse($lastRunRaw)
        $delta = (Get-Date) - $lastRun
        return $delta.TotalHours -ge $Hours
    }
    catch {
        return $true
    }
}

function Save-TaskRunState {
    param([string]$TaskName)

    $taskStateFile = Get-TaskStateFile -TaskName $TaskName
    (Get-Date).ToString("o") | Set-Content -Path $taskStateFile -Encoding ASCII
}

function Start-DetachedPowerShell {
    param(
        [string]$Command,
        [ValidateSet("Idle", "BelowNormal", "Normal")]
        [string]$PriorityClass = "BelowNormal"
    )

    $powerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

    Start-Process -FilePath $powerShellExe -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-Command", $Command
    ) -WindowStyle Hidden -PriorityClass $PriorityClass | Out-Null
}

function Get-BuiltInGuestName {
    $guest = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE '%-501'" | Select-Object -First 1
    if ($null -eq $guest) {
        throw "Compte Invite integre (SID finissant par -501) introuvable."
    }

    return $guest.Name
}

function Get-LockoutPolicy {
    $tempFile = Join-Path $env:TEMP ("secpol-{0}.inf" -f [Guid]::NewGuid().ToString("N"))

    try {
        & secedit.exe /export /cfg $tempFile /quiet | Out-Null
        $content = Get-Content -Path $tempFile -ErrorAction Stop
        $threshold = (($content | Select-String -Pattern "^LockoutBadCount\s*=\s*(\d+)" -CaseSensitive).Matches.Groups[1].Value | Select-Object -First 1)
        $duration = (($content | Select-String -Pattern "^LockoutDuration\s*=\s*(-?\d+)" -CaseSensitive).Matches.Groups[1].Value | Select-Object -First 1)
        $window = (($content | Select-String -Pattern "^ResetLockoutCount\s*=\s*(\d+)" -CaseSensitive).Matches.Groups[1].Value | Select-Object -First 1)

        return "Threshold=$threshold;Duration=$duration;Window=$window"
    }
    finally {
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-WinREStatus {
    $output = & reagentc.exe /info 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "reagentc /info a echoue (code=$LASTEXITCODE)."
    }

    $text = ($output | Out-String)
    if ($text -match "Windows RE status:\s*(Enabled|Disabled)") {
        return $Matches[1]
    }

    if ($text -match "Windows RE.*:\s*(Enabled|Disabled|Active|Desactive|Desactivee)") {
        return $Matches[1]
    }

    return "Unknown"
}

function Write-ComplianceSummary {
    $okCount = ($complianceResults | Where-Object { $_.Status -eq "OK" }).Count
    $koCount = ($complianceResults | Where-Object { $_.Status -eq "KO" }).Count

    Write-Log "Resume conformite: OK=$okCount KO=$koCount"

    $header = "Rule | Status | Expected | Before | After | Details"
    Set-Content -Path $complianceFile -Value $header -Encoding ASCII

    foreach ($row in $complianceResults) {
        $line = "{0} | {1} | {2} | {3} | {4} | {5}" -f $row.Rule, $row.Status, $row.Expected, $row.Before, $row.After, $row.Details
        Add-Content -Path $complianceFile -Value $line -Encoding ASCII
    }

    if ($koCount -gt 0) {
        Show-TaskNotification -TaskName "compliance-summary" -Status "Warning" -Details "Resultat: OK=$okCount KO=$koCount"
    }
    else {
        Show-TaskNotification -TaskName "compliance-summary" -Status "Success" -Details "Resultat: OK=$okCount KO=$koCount"
    }

    Write-Log "Rapport de conformite ecrit: $complianceFile"
}

Initialize-NotificationSupport

$performance = Resolve-PerformanceSettings -RequestedProfile $PerformanceProfile -RequestedCooldownHours $CooldownHours -RequestedSignatureUpdateCooldownHours $SignatureUpdateCooldownHours -RequestedWindowsUpdateTriggerCooldownHours $WindowsUpdateTriggerCooldownHours -RequestedFullScanCooldownHours $FullScanCooldownHours
$effectiveCooldownHours = $performance.CooldownHours
$effectiveSignatureUpdateCooldownHours = $performance.SignatureUpdateCooldownHours
$effectiveWindowsUpdateTriggerCooldownHours = $performance.WindowsUpdateTriggerCooldownHours
$effectiveFullScanCooldownHours = $performance.FullScanCooldownHours
$backgroundTaskPriority = $performance.BackgroundPriority

Write-Log "Demarrage du script de securisation."
Write-Log ("Profil performance: demande={0} resolu={1} RAM={2}GB CPU(logical)={3} source={4} priorite={5}" -f $performance.RequestedProfile, $performance.ResolvedProfile, $performance.Hardware.MemoryGb, $performance.Hardware.LogicalCpu, $performance.Hardware.Source, $backgroundTaskPriority)
Write-Log ("Cooldowns effectifs: script={0}h signatures={1}h windows-update={2}h full-scan={3}h" -f $effectiveCooldownHours, $effectiveSignatureUpdateCooldownHours, $effectiveWindowsUpdateTriggerCooldownHours, $effectiveFullScanCooldownHours)

if (-not (Test-ShouldRun -Hours $effectiveCooldownHours)) {
    Write-Log "Execution ignoree: cooldown actif de $effectiveCooldownHours h."
    exit 0
}

Write-Log "Activation des profils pare-feu (Domaine, Prive, Public)."
Invoke-ComplianceRule -Rule "Pare-feu profils actives" -Expected "Domain=True,Private=True,Public=True" -GetValue {
    $profiles = Get-NetFirewallProfile -Profile Domain, Private, Public
    return (($profiles | Sort-Object -Property Name | ForEach-Object { "{0}={1}" -f $_.Name, $_.Enabled }) -join ",")
} -Apply {
    Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
} -IsCompliant {
    param($value)
    return ($value -match "Domain=True") -and ($value -match "Private=True") -and ($value -match "Public=True")
}

Write-Log "Configuration Microsoft Defender (protections de base)."
Invoke-ComplianceRule -Rule "Defender baseline" -Expected "Protections actives + actions auto" -GetValue {
    $pref = Get-MpPreference
    return "RTM=$(-not $pref.DisableRealtimeMonitoring);IOAV=$(-not $pref.DisableIOAVProtection);Script=$(-not $pref.DisableScriptScanning);Archive=$(-not $pref.DisableArchiveScanning);Email=$(-not $pref.DisableEmailScanning);USB=$(-not $pref.DisableRemovableDriveScanning);PUA=$($pref.PUAProtection);MAPS=$($pref.MAPSReporting);Samples=$($pref.SubmitSamplesConsent);NP=$($pref.EnableNetworkProtection);Low=$($pref.LowThreatDefaultAction);Moderate=$($pref.ModerateThreatDefaultAction);High=$($pref.HighThreatDefaultAction);Severe=$($pref.SevereThreatDefaultAction)"
} -Apply {
    Set-MpPreference -DisableRealtimeMonitoring $false
    Set-MpPreference -DisableIOAVProtection $false
    Set-MpPreference -DisableScriptScanning $false
    Set-MpPreference -DisableArchiveScanning $false
    Set-MpPreference -DisableEmailScanning $false
    Set-MpPreference -DisableRemovableDriveScanning $false
    Set-MpPreference -PUAProtection Enabled
    Set-MpPreference -MAPSReporting Advanced
    Set-MpPreference -SubmitSamplesConsent SendSafeSamples
    Set-MpPreference -EnableNetworkProtection Enabled
    Set-MpPreference -LowThreatDefaultAction Quarantine
    Set-MpPreference -ModerateThreatDefaultAction Quarantine
    Set-MpPreference -HighThreatDefaultAction Remove
    Set-MpPreference -SevereThreatDefaultAction Remove
} -IsCompliant {
    param($value)
    return ($value -match "RTM=True") -and
        ($value -match "IOAV=True") -and
        ($value -match "Script=True") -and
        ($value -match "Archive=True") -and
        ($value -match "Email=True") -and
        ($value -match "USB=True") -and
        ($value -match "PUA=(1|Enabled)") -and
        ($value -match "MAPS=(2|Advanced)") -and
        ($value -match "Samples=(1|SendSafeSamples)") -and
        ($value -match "NP=(1|Enabled)") -and
        ($value -match "Low=(2|Quarantine)") -and
        ($value -match "Moderate=(2|Quarantine)") -and
        ($value -match "High=(3|Remove)") -and
        ($value -match "Severe=(3|Remove)")
}

if (Test-TaskShouldRun -TaskName "defender-signature-update" -Hours $effectiveSignatureUpdateCooldownHours) {
    try {
        Write-Log "Lancement asynchrone de la mise a jour des signatures Defender."
        Start-DetachedPowerShell -Command "Update-MpSignature | Out-Null" -PriorityClass $backgroundTaskPriority
        Save-TaskRunState -TaskName "defender-signature-update"
        Show-TaskNotification -TaskName "defender-signature-update" -Status "Success"
    }
    catch {
        Write-Log "Erreur lancement update signatures: $($_.Exception.Message)"
        Show-TaskNotification -TaskName "defender-signature-update" -Status "Error" -Details $_.Exception.Message
    }
}
else {
    Write-Log "Update signatures ignoree (cooldown actif ${effectiveSignatureUpdateCooldownHours}h)."
    Show-TaskNotification -TaskName "defender-signature-update" -Status "Skipped" -Details "Cooldown actif (${effectiveSignatureUpdateCooldownHours}h)."
}

if (Test-TaskShouldRun -TaskName "defender-full-scan" -Hours $effectiveFullScanCooldownHours) {
    try {
        Write-Log "Lancement asynchrone du scan complet Defender (sans blocage du demarrage)."
        Start-DetachedPowerShell -Command "Start-MpScan -ScanType FullScan" -PriorityClass $backgroundTaskPriority
        Save-TaskRunState -TaskName "defender-full-scan"
        Show-TaskNotification -TaskName "defender-full-scan" -Status "Success"
    }
    catch {
        Write-Log "Erreur lancement scan complet: $($_.Exception.Message)"
        Show-TaskNotification -TaskName "defender-full-scan" -Status "Error" -Details $_.Exception.Message
    }
}
else {
    Write-Log "Scan complet ignore (cooldown actif ${effectiveFullScanCooldownHours}h)."
    Show-TaskNotification -TaskName "defender-full-scan" -Status "Skipped" -Details "Cooldown actif (${effectiveFullScanCooldownHours}h)."
}

Write-Log "Desactivation SMBv1 cote serveur (durcissement reseau)."
Invoke-ComplianceRule -Rule "SMBv1 serveur" -Expected "False" -GetValue {
    (Get-SmbServerConfiguration).EnableSMB1Protocol
} -Apply {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force | Out-Null
} -IsCompliant {
    param($value)
    return [string]$value -eq "False"
}

Write-Log "Desactivation des connexions SMB Invite non securisees (client)."
Invoke-ComplianceRule -Rule "SMB client insecure guest" -Expected "False" -GetValue {
    (Get-SmbClientConfiguration).EnableInsecureGuestLogons
} -Apply {
    Set-SmbClientConfiguration -EnableInsecureGuestLogons $false -Force | Out-Null
} -IsCompliant {
    param($value)
    return [string]$value -eq "False"
}

Write-Log "Application de la politique d'echec de connexion (seuil=$LockoutThreshold, duree=${LockoutDurationMinutes}min, fenetre=${LockoutWindowMinutes}min)."
Invoke-ComplianceRule -Rule "Politique verrouillage compte" -Expected "Threshold=$LockoutThreshold;Duration=$LockoutDurationMinutes;Window=$LockoutWindowMinutes" -GetValue {
    Get-LockoutPolicy
} -Apply {
    & net.exe accounts /lockoutthreshold:$LockoutThreshold | Out-Null
    & net.exe accounts /lockoutduration:$LockoutDurationMinutes | Out-Null
    & net.exe accounts /lockoutwindow:$LockoutWindowMinutes | Out-Null
} -IsCompliant {
    param($value)
    return ($value -match "Threshold=$LockoutThreshold") -and ($value -match "Duration=$LockoutDurationMinutes") -and ($value -match "Window=$LockoutWindowMinutes")
}

Write-Log "Desactivation AutoRun (USB/CD) pour limiter les executions automatiques malveillantes."
Invoke-ComplianceRule -Rule "AutoRun" -Expected "NoDriveTypeAutoRun=255" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -ErrorAction Stop).NoDriveTypeAutoRun
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255
} -IsCompliant {
    param($value)
    return [int]$value -eq 255
}

Write-Log "Desactivation du compte Invite local."
Invoke-ComplianceRule -Rule "Compte Invite" -Expected "Enabled=False" -GetValue {
    $guestName = Get-BuiltInGuestName
    (Get-LocalUser -Name $guestName -ErrorAction Stop).Enabled
} -Apply {
    $guestName = Get-BuiltInGuestName
    & net.exe user $guestName /active:no | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Echec net user pour le compte Invite integre '$guestName' (code=$LASTEXITCODE)."
    }
} -IsCompliant {
    param($value)
    return [string]$value -eq "False"
}

Write-Log "Activation SmartScreen systeme en mode blocage."
Invoke-ComplianceRule -Rule "SmartScreen systeme" -Expected "EnableSmartScreen=1;ShellSmartScreenLevel=Block" -GetValue {
    $k = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -ErrorAction Stop
    "EnableSmartScreen=$($k.EnableSmartScreen);ShellSmartScreenLevel=$($k.ShellSmartScreenLevel)"
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -Value 1
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "ShellSmartScreenLevel" -Type String -Value "Block"
} -IsCompliant {
    param($value)
    return ($value -match "EnableSmartScreen=1") -and ($value -match "ShellSmartScreenLevel=Block")
}

Write-Log "Durcissement credentiel: desactivation WDigest en clair."
Invoke-ComplianceRule -Rule "WDigest" -Expected "UseLogonCredential=0" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" -Name "UseLogonCredential" -ErrorAction Stop).UseLogonCredential
} -Apply {
    Set-RegistryDword -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" -Name "UseLogonCredential" -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Write-Log "Durcissement LSASS: protection PPL activee (redemarrage requis pour effet complet)."
Invoke-ComplianceRule -Rule "LSASS RunAsPPL" -Expected "RunAsPPL=1" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RunAsPPL" -ErrorAction Stop).RunAsPPL
} -Apply {
    Set-RegistryDword -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RunAsPPL" -Value 1
} -IsCompliant {
    param($value)
    return [int]$value -eq 1
}

Write-Log "Desactivation de PowerShell v2 (legacy)."
Invoke-ComplianceRule -Rule "PowerShell v2" -Expected "State=Disabled" -GetValue {
    (Get-WindowsOptionalFeature -Online -FeatureName "MicrosoftWindowsPowerShellV2Root" -ErrorAction Stop).State
} -Apply {
    Disable-WindowsOptionalFeature -Online -FeatureName "MicrosoftWindowsPowerShellV2Root" -NoRestart -ErrorAction Stop | Out-Null
} -IsCompliant {
    param($value)
    return ([string]$value -eq "Disabled") -or ([string]$value -eq "DisabledWithPayloadRemoved")
}

Write-Log "Desactivation Windows Recovery Environment (WinRE)."
Invoke-ComplianceRule -Rule "Windows RE" -Expected "Status=Disabled" -GetValue {
    "Status=$(Get-WinREStatus)"
} -Apply {
    & reagentc.exe /disable | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reagentc /disable a echoue (code=$LASTEXITCODE)."
    }
} -IsCompliant {
    param($value)
    return ($value -match "Status=(Disabled|Desactive|Desactivee)")
}

Write-Log "Configuration Windows Update automatique (telechargement + installation)."
Invoke-ComplianceRule -Rule "Windows Update policy" -Expected "AUOptions=4;ScheduledInstallDay=0;ScheduledInstallTime=$UpdateInstallHour;NoAutoRebootWithLoggedOnUsers=1" -GetValue {
    $k = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -ErrorAction Stop
    "AUOptions=$($k.AUOptions);ScheduledInstallDay=$($k.ScheduledInstallDay);ScheduledInstallTime=$($k.ScheduledInstallTime);NoAutoRebootWithLoggedOnUsers=$($k.NoAutoRebootWithLoggedOnUsers)"
} -Apply {
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Force | Out-Null
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Value 4
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "ScheduledInstallDay" -Value 0
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "ScheduledInstallTime" -Value $UpdateInstallHour
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Value 1
} -IsCompliant {
    param($value)
    return ($value -match "AUOptions=4") -and
        ($value -match "ScheduledInstallDay=0") -and
        ($value -match "ScheduledInstallTime=$UpdateInstallHour") -and
        ($value -match "NoAutoRebootWithLoggedOnUsers=1")
}

if (Test-TaskShouldRun -TaskName "windows-update-trigger" -Hours $effectiveWindowsUpdateTriggerCooldownHours) {
    try {
        Write-Log "Lancement asynchrone Windows Update (scan/download/install)."
        $usoClientPath = Join-Path $env:SystemRoot "System32\UsoClient.exe"
        if (Test-Path $usoClientPath) {
            $wuCommand = "& '$usoClientPath' StartScan | Out-Null; & '$usoClientPath' StartDownload | Out-Null; & '$usoClientPath' StartInstall | Out-Null"
            Start-DetachedPowerShell -Command $wuCommand -PriorityClass $backgroundTaskPriority
            Save-TaskRunState -TaskName "windows-update-trigger"
            Write-Log "Windows Update lance via UsoClient."
            Show-TaskNotification -TaskName "windows-update-trigger" -Status "Success"
        }
        else {
            Write-Log "UsoClient.exe introuvable: declenchement immediat ignore."
            Show-TaskNotification -TaskName "windows-update-trigger" -Status "Warning" -Details "UsoClient.exe introuvable."
        }
    }
    catch {
        Write-Log "Erreur lancement Windows Update: $($_.Exception.Message)"
        Show-TaskNotification -TaskName "windows-update-trigger" -Status "Error" -Details $_.Exception.Message
    }
}
else {
    Write-Log "Windows Update immediate ignoree (cooldown actif ${effectiveWindowsUpdateTriggerCooldownHours}h)."
    Show-TaskNotification -TaskName "windows-update-trigger" -Status "Skipped" -Details "Cooldown actif (${effectiveWindowsUpdateTriggerCooldownHours}h)."
}

Write-ComplianceSummary
Save-RunState
Write-Log "Fin du script de securisation."
exit 0

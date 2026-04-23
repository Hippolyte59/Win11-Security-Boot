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

function Get-ComplianceSnapshot {
    param([object[]]$Results)
    
    $snapshot = @{}
    foreach ($result in $Results) {
        $key = $result.Rule -replace '\s+', '_'
        $snapshot[$key] = @{
            Status = $result.Status
            Before = $result.Before
            After = $result.After
        }
    }
    return $snapshot
}

function Compare-ComplianceSnapshots {
    param(
        [object[]]$PreviousResults,
        [object[]]$CurrentResults
    )
    
    $changes = @()
    $prevMap = @{}
    if ($PreviousResults) {
        foreach ($r in $PreviousResults) {
            $key = $r.Rule -replace '\s+', '_'
            $prevMap[$key] = $r
        }
    }
    
    foreach ($curr in $CurrentResults) {
        $key = $curr.Rule -replace '\s+', '_'
        if ($prevMap.ContainsKey($key)) {
            $prev = $prevMap[$key]
            if ($prev.Status -ne $curr.Status) {
                $changes += @{
                    Rule = $curr.Rule
                    PreviousStatus = $prev.Status
                    CurrentStatus = $curr.Status
                    Changed = $true
                }
            }
        }
        else {
            $changes += @{
                Rule = $curr.Rule
                PreviousStatus = "N/A"
                CurrentStatus = $curr.Status
                Changed = $true
            }
        }
    }
    return $changes
}

function Write-ComplianceSummary {
    param([object[]]$PreviousResults = $null)
    
    $okCount = ($complianceResults | Where-Object { $_.Status -eq "OK" }).Count
    $koCount = ($complianceResults | Where-Object { $_.Status -eq "KO" }).Count

    Write-Log "Resume conformite: OK=$okCount KO=$koCount"

    $header = "Rule | Status | Expected | Before | After | Details"
    Set-Content -Path $complianceFile -Value $header -Encoding ASCII

    foreach ($row in $complianceResults) {
        $line = "{0} | {1} | {2} | {3} | {4} | {5}" -f $row.Rule, $row.Status, $row.Expected, $row.Before, $row.After, $row.Details
        Add-Content -Path $complianceFile -Value $line -Encoding ASCII
    }

    if ($PreviousResults) {
        Add-Content -Path $complianceFile -Value "" -Encoding ASCII
        Add-Content -Path $complianceFile -Value "=== HISTORIQUE DES CHANGEMENTS ===" -Encoding ASCII
        $changes = Compare-ComplianceSnapshots -PreviousResults $PreviousResults -CurrentResults $complianceResults
        if ($changes.Count -gt 0) {
            foreach ($change in $changes) {
                $changeLine = "CHANGEMENT: {0} | Avant={1} Maintenant={2}" -f $change.Rule, $change.PreviousStatus, $change.CurrentStatus
                Add-Content -Path $complianceFile -Value $changeLine -Encoding ASCII
            }
        }
        else {
            Add-Content -Path $complianceFile -Value "Aucun changement detected depuis la derniere execution." -Encoding ASCII
        }
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

$previousResultsFile = Join-Path $stateDir "compliance-snapshot.xml"
$previousResults = $null
if (Test-Path $previousResultsFile) {
    try {
        $previousResults = Import-Clixml -Path $previousResultsFile -ErrorAction SilentlyContinue
    }
    catch {
        $previousResults = $null
    }
}

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
    return @(
        ($value -match "RTM=True"),
        ($value -match "IOAV=True"),
        ($value -match "Script=True"),
        ($value -match "Archive=True"),
        ($value -match "Email=True"),
        ($value -match "USB=True"),
        ($value -match "PUA=(1|Enabled)"),
        ($value -match "MAPS=(2|Advanced)"),
        ($value -match "Samples=(1|SendSafeSamples)"),
        ($value -match "NP=(1|Enabled)"),
        ($value -match "Low=(2|Quarantine)"),
        ($value -match "Moderate=(2|Quarantine)"),
        ($value -match "High=(3|Remove)"),
        ($value -match "Severe=(3|Remove)")
    ) -notcontains $false
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

Write-Log "Desactivation de fonctions Microsoft additionnelles qui peuvent ralentir le PC."
Invoke-ComplianceRule -Rule "Widgets et News Feed" -Expected "AllowNewsAndInterests=0" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -ErrorAction Stop).AllowNewsAndInterests
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Invoke-ComplianceRule -Rule "Metadonnees MSN Widgets desactivees" -Expected "DisableWidgetsBoard=1;TaskbarDa=0;ShellFeedsTaskbarViewMode=2" -GetValue {
    $dsh = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -ErrorAction Stop
    $adv = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction Stop
    $feeds = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds" -ErrorAction Stop
    "DisableWidgetsBoard=$($dsh.DisableWidgetsBoard);TaskbarDa=$($adv.TaskbarDa);ShellFeedsTaskbarViewMode=$($feeds.ShellFeedsTaskbarViewMode)"
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "DisableWidgetsBoard" -Value 1
    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Type DWord -Value 0
    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds" -Name "ShellFeedsTaskbarViewMode" -Type DWord -Value 2
} -IsCompliant {
    param($value)
    return ($value -match "DisableWidgetsBoard=1") -and ($value -match "TaskbarDa=0") -and ($value -match "ShellFeedsTaskbarViewMode=2")
}

Invoke-ComplianceRule -Rule "Applications en arriere-plan" -Expected "LetAppsRunInBackground=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsRunInBackground" -ErrorAction Stop).LetAppsRunInBackground
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsRunInBackground" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "GameDVR et capture Xbox" -Expected "AllowGameDVR=0" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -ErrorAction Stop).AllowGameDVR
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Invoke-ComplianceRule -Rule "Windows Copilot" -Expected "TurnOffWindowsCopilot=1" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction Stop).TurnOffWindowsCopilot
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -Value 1
} -IsCompliant {
    param($value)
    return [int]$value -eq 1
}

Invoke-ComplianceRule -Rule "Delivery Optimization P2P" -Expected "DODownloadMode=0" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -ErrorAction Stop).DODownloadMode
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" -Name "DODownloadMode" -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Write-Log "Desactivation des suggestions et publicites dans le menu Demarrer."
Invoke-ComplianceRule -Rule "Suggestions menu Demarrer" -Expected "Start_AccountNotifications=0;Start_RecommendedSection=0" -GetValue {
    $key1 = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "Start_AccountNotifications" -ErrorAction Stop
    $key2 = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "Start_RecommendedSection" -ErrorAction Stop
    "Start_AccountNotifications=$($key1.Start_AccountNotifications);Start_RecommendedSection=$($key2.Start_RecommendedSection)"
} -Apply {
    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "Start_AccountNotifications" -Type DWord -Value 0
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "Start_RecommendedSection" -Type DWord -Value 0
} -IsCompliant {
    param($value)
    return ($value -match "Start_AccountNotifications=0") -and ($value -match "Start_RecommendedSection=0")
}

Invoke-ComplianceRule -Rule "Suggestions applications tierces" -Expected "Start_AppSuggestions=0;SubscribedContentEnabled=0" -GetValue {
    $key1 = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "Start_AppSuggestions" -ErrorAction Stop
    $key2 = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContentEnabled" -ErrorAction Stop
    "Start_AppSuggestions=$($key1.Start_AppSuggestions);SubscribedContentEnabled=$($key2.SubscribedContentEnabled)"
} -Apply {
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "Start_AppSuggestions" -Type DWord -Value 0
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContentEnabled" -Type DWord -Value 0
} -IsCompliant {
    param($value)
    return ($value -match "Start_AppSuggestions=0") -and ($value -match "SubscribedContentEnabled=0")
}

Write-Log "Configuration de Windows Search pour la vie privee (desactivation Bing et collecte)."
Invoke-ComplianceRule -Rule "Recherche Windows - Bing desactive" -Expected "BingSearchEnabled=0" -GetValue {
    (Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -ErrorAction Stop).BingSearchEnabled
} -Apply {
    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Type DWord -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Invoke-ComplianceRule -Rule "Recherche Windows - Historique desactive" -Expected "IsAADAccount=0;HistoryViewEnabled=0" -GetValue {
    $key1 = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "IsAADAccount" -ErrorAction Stop
    $key2 = Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "HistoryViewEnabled" -ErrorAction Stop
    "IsAADAccount=$($key1.IsAADAccount);HistoryViewEnabled=$($key2.HistoryViewEnabled)"
} -Apply {
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "IsAADAccount" -Type DWord -Value 0
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name "HistoryViewEnabled" -Type DWord -Value 0
} -IsCompliant {
    param($value)
    return ($value -match "IsAADAccount=0") -and ($value -match "HistoryViewEnabled=0")
}

Invoke-ComplianceRule -Rule "Recherche cloud Microsoft desactivee" -Expected "AllowCloudSearch=0" -GetValue {
    (Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsCloudSearchEnabled" -ErrorAction Stop).IsCloudSearchEnabled
} -Apply {
    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" -Name "IsCloudSearchEnabled" -Type DWord -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Write-Log "Blocage des domaines publicitaires (Microsoft, Google, Meta, trackers) via le fichier hosts."
$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$adDomains = @(
    "ads.msn.com",
    "ads1.msn.com",
    "ads2.msn.com",
    "api.msn.com",
    "arc.msn.com",
    "assets.msn.com",
    "browser.events.data.msn.com",
    "adnexus.net",
    "a-msedge.net",
    "ads.microsoft.com",
    "c.msn.com",
    "c1.microsoft.com",
    "g.msn.com",
    "go.microsoft.com.nsatc.net",
    "lb1.www.ms.akadns.net",
    "live.rads.msn.com",
    "msads.net",
    "msftncsi.com",
    "msnbot.msn.com",
    "msntest.serving-sys.com",
    "oca.telemetry.microsoft.com",
    "ntp.msn.com",
    "rad.msn.com",
    "redir.metaservices.microsoft.com",
    "img-s-msn-com.akamaized.net",
    "s0.2mdn.net",
    "settings-win.data.microsoft.com",
    "static.2mdn.net",
    "statsfe2.update.microsoft.com.akadns.net",
    "telecommand.telemetry.microsoft.com",
    "telemetry.microsoft.com",
    "vortex-win.data.microsoft.com",
    "vortex.data.microsoft.com",
    "watson.microsoft.com",
    "watson.ppe.telemetry.microsoft.com",
    "watson.telemetry.microsoft.com",
    "www.msn.com.nsatc.net",
    "fe2.update.microsoft.com.akadns.net",
    "login.live.com.nsatc.net",
    "nexus.officeapps.live.com",
    "nexus.passport.com",
    "sqm.microsoft.com",
    "sqm.telemetry.microsoft.com",
    "survey.watson.microsoft.com",
    "ad.doubleclick.net",
    "dart.l.doubleclick.net",
    "ad.google.com",
    "adservice.google.com",
    "adservice.google.fr",
    "adservice.google.be",
    "adservice.google.ca",
    "adservice.google.co.uk",
    "adservice.google.de",
    "ads.google.com",
    "googleadservices.com",
    "googlesyndication.com",
    "pagead2.googlesyndication.com",
    "tpc.googlesyndication.com",
    "partnerad.l.doubleclick.net",
    "pubads.g.doubleclick.net",
    "securepubads.g.doubleclick.net",
    "www.googleadservices.com",
    "www.googletagmanager.com",
    "www.googletagservices.com",
    "ssl.google-analytics.com",
    "google-analytics.com",
    "www.google-analytics.com",
    "analytics.google.com",
    "stats.g.doubleclick.net",
    "an.facebook.com",
    "connect.facebook.net",
    "web.facebook.com",
    "pixel.facebook.com",
    "graph.facebook.com",
    "staticxx.facebook.com",
    "www.facebook.com.cdn.cloudflare.net",
    "edge-atlas.facebook.com",
    "star.c10r.facebook.com",
    "aax.amazon-adsystem.com",
    "c.amazon-adsystem.com",
    "fls-na.amazon.com",
    "mads.amazon-adsystem.com",
    "s.amazon-adsystem.com",
    "z-na.amazon-adsystem.com",
    "adserver.adtech.de",
    "adtech.de",
    "adtechus.com",
    "advertising.com",
    "aol.com.edgesuite.net",
    "aperture.apnx.us",
    "appnexus.com",
    "ib.adnxs.com",
    "aprxd.com",
    "adblade.com",
    "adform.net",
    "ads.adform.net",
    "adnxs.com",
    "adroll.com",
    "ads.adroll.com",
    "d.adroll.com",
    "s.adroll.com",
    "bidswitch.net",
    "bidswitch.com",
    "blismedia.com",
    "brealtime.com",
    "brightroll.com",
    "casalemedia.com",
    "cmcore.com",
    "contextweb.com",
    "ads.contextweb.com",
    "criteo.com",
    "dis.criteo.com",
    "rtax.criteo.com",
    "sslwidget.criteo.com",
    "widget.criteo.com",
    "datalogix.com",
    "emxdgt.com",
    "everestads.net",
    "everesttech.net",
    "exponential.com",
    "admeld.com",
    "gadsid.com",
    "gravitrdp.com",
    "index.exchange",
    "casalemedia.com",
    "innovid.com",
    "insightexpressai.com",
    "interclick.com",
    "lkqd.net",
    "lijit.com",
    "liveintent.com",
    "liverail.com",
    "loopme.com",
    "mediamath.com",
    "data.mediamind.com",
    "moatads.com",
    "z.moatads.com",
    "openx.net",
    "us-u.openx.net",
    "outbrain.com",
    "odb.outbrain.com",
    "widgetserver.com",
    "pubmatic.com",
    "ads.pubmatic.com",
    "simage2.pubmatic.com",
    "rubiconproject.com",
    "fastlane.rubiconproject.com",
    "pixel.rubiconproject.com",
    "sspinit.rubiconproject.com",
    "scorecardresearch.com",
    "b.scorecardresearch.com",
    "smaato.com",
    "soma.smaato.com",
    "smartadserver.com",
    "www2.smartadserver.com",
    "spotxchange.com",
    "srv.spotxchange.com",
    "springserve.com",
    "streamrail.com",
    "taboola.com",
    "cdn.taboola.com",
    "images.taboola.com",
    "trc.taboola.com",
    "thetradedesk.com",
    "match.thetradedesk.com",
    "tradedoubler.com",
    "tradelab.fr",
    "tremorhub.com",
    "tribalfusion.com",
    "triplelift.com",
    "ib.3lift.com",
    "turn.com",
    "pointroll.com",
    "twiago.com",
    "undertone.com",
    "unrulymedia.com",
    "valueclick.com",
    "vdopia.com",
    "videohub.tv",
    "vindico.com",
    "vmm.admeld.com",
    "xad.com",
    "yieldlab.net",
    "yieldlab.de",
    "yieldmanager.com",
    "edge.yieldmanager.com",
    "yieldmo.com",
    "2o7.net",
    "247realmedia.com",
    "realmedia.com",
    "adbrite.com",
    "addthis.com",
    "s7.addthis.com",
    "v1.addthis.com",
    "v2.addthis.com",
    "adinterax.com",
    "admarketplace.net",
    "apmebf.com",
    "atdmt.com",
    "atlas.c10r.facebook.com",
    "audiencescience.com",
    "bh.contextweb.com",
    "cpmstar.com",
    "demdex.net",
    "dpm.demdex.net",
    "cm.everesttech.net",
    "flashtalking.com",
    "fstrk.net",
    "go.sonobi.com",
    "hotwords.com",
    "iesnare.com",
    "iovation.com",
    "ivwbox.de",
    "kxcdn.com",
    "listhub.net",
    "ml314.com",
    "mookie1.com",
    "networkadvertising.org",
    "nexac.com",
    "nugg.ad",
    "oglematches.com",
    "omtrdc.net",
    "optmd.com",
    "semasio.net",
    "serving-sys.com",
    "media.serving-sys.com",
    "sizmek.com",
    "skimresources.com",
    "static.skimresources.com",
    "spotscenered.info",
    "targetingnow.com",
    "tracking.cmcore.com",
    "uberads.com",
    "v0cdn.net",
    "w55c.net",
    "x.bidswitch.net",
    "xtendmedia.com",
    "yume.com"
)

Invoke-ComplianceRule -Rule "Blocage domaines pub Microsoft/MSN (hosts)" -Expected "Tous les domaines bloques dans hosts" -GetValue {
    if (-not (Test-Path $hostsPath)) {
        return "hosts=introuvable"
    }
    $hostsContent = Get-Content -Path $hostsPath -ErrorAction Stop
    $blocked = ($adDomains | Where-Object {
        $domain = $_
        $hostsContent | Where-Object { $_ -match "^\s*0\.0\.0\.0\s+$([regex]::Escape($domain))" }
    }).Count
    return "bloques=$blocked/total=$($adDomains.Count)"
} -Apply {
    $hostsContent = if (Test-Path $hostsPath) {
        Get-Content -Path $hostsPath -ErrorAction Stop
    } else {
        @()
    }
    $marker = "Win11SecurityBoot Ad domains"
    $newEntries = @($marker)
    foreach ($domain in $adDomains) {
        $alreadyPresent = $hostsContent | Where-Object { $_ -match "^\s*0\.0\.0\.0\s+$([regex]::Escape($domain))" }
        if (-not $alreadyPresent) {
            $newEntries += "0.0.0.0 $domain"
        }
    }
    if ($newEntries.Count -gt 1) {
        Add-Content -Path $hostsPath -Value ($newEntries -join "`n") -Encoding ASCII
    }
} -IsCompliant {
    param($value)
    if ($value -match "bloques=(\d+)/total=(\d+)") {
        return [int]$Matches[1] -eq [int]$Matches[2]
    }
    return $false
}

Write-Log "Blocage DNS des domaines publicitaires via NRPT (Name Resolution Policy Table)."
$nrptBase = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig"
$nrptDomains = $adDomains

Invoke-ComplianceRule -Rule "Blocage DNS NRPT domaines pub" -Expected "Tous les domaines bloques dans NRPT" -GetValue {
    $blockedCount = 0
    foreach ($domain in $nrptDomains) {
        $keyName = "Win11SB_$($domain -replace '\.','_')"
        $keyPath = Join-Path $nrptBase $keyName
        if (Test-Path $keyPath) {
            $cfg = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
            if ($cfg -and $cfg.ConfigOptions -eq 8) {
                $blockedCount++
            }
        }
    }
    return "nrpt_bloques=$blockedCount/total=$($nrptDomains.Count)"
} -Apply {
    New-Item -Path $nrptBase -Force | Out-Null
    foreach ($domain in $nrptDomains) {
        $keyName = "Win11SB_$($domain -replace '\.','_')"
        $keyPath = Join-Path $nrptBase $keyName
        New-Item -Path $keyPath -Force | Out-Null
        Set-ItemProperty -Path $keyPath -Name "Version"             -Type DWord  -Value 2
        Set-ItemProperty -Path $keyPath -Name "ConfigOptions"       -Type DWord  -Value 8
        Set-ItemProperty -Path $keyPath -Name "Name"                -Type MultiString -Value @(".$domain")
        Set-ItemProperty -Path $keyPath -Name "GenericDNSServers"   -Type String -Value ""
        Set-ItemProperty -Path $keyPath -Name "IPSECCARestriction"  -Type String -Value ""
        Set-ItemProperty -Path $keyPath -Name "Comment"             -Type String -Value "Win11SecurityBoot - blocked ad domain"
    }
    ipconfig /flushdns | Out-Null
} -IsCompliant {
    param($value)
    if ($value -match "nrpt_bloques=(\d+)/total=(\d+)") {
        return [int]$Matches[1] -eq [int]$Matches[2]
    }
    return $false
}

Write-Log "Durcissement vie privee avance: diagnostics, feedback et partage de donnees."

Invoke-ComplianceRule -Rule "Feedback Windows desactive" -Expected "NumberOfSIUFInPeriod=0" -GetValue {
    (Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" -Name "NumberOfSIUFInPeriod" -ErrorAction Stop).NumberOfSIUFInPeriod
} -Apply {
    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" -Name "NumberOfSIUFInPeriod" -Type DWord -Value 0
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" -Name "PeriodInNanoSeconds" -Type DWord -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Invoke-ComplianceRule -Rule "Rapport erreurs Windows desactive" -Expected "Disabled=1" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -ErrorAction Stop).Disabled
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name "DontSendAdditionalData" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name "LoggingDisabled" -Value 1
} -IsCompliant {
    param($value)
    return [int]$value -eq 1
}

Invoke-ComplianceRule -Rule "Programme amelioration experience (CEIP) desactive" -Expected "CEIPEnable=0" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows" -Name "CEIPEnable" -ErrorAction Stop).CEIPEnable
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows" -Name "CEIPEnable" -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Invoke-ComplianceRule -Rule "Compatibilite applications telemetrie desactivee" -Expected "AITEnable=0" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "AITEnable" -ErrorAction Stop).AITEnable
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "AITEnable" -Value 0
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "DisableInventory" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "DisablePCA" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "DisableUAR" -Value 1
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Write-Log "Durcissement vie privee: blocage acces camera, micro, localisation, contacts."

Invoke-ComplianceRule -Rule "Acces camera applications UWP bloque" -Expected "LetAppsAccessCamera=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessCamera" -ErrorAction Stop).LetAppsAccessCamera
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessCamera" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "Acces microphone applications UWP bloque" -Expected "LetAppsAccessMicrophone=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessMicrophone" -ErrorAction Stop).LetAppsAccessMicrophone
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessMicrophone" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "Acces localisation applications UWP bloque" -Expected "LetAppsAccessLocation=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessLocation" -ErrorAction Stop).LetAppsAccessLocation
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessLocation" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "Acces contacts applications UWP bloque" -Expected "LetAppsAccessContacts=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessContacts" -ErrorAction Stop).LetAppsAccessContacts
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessContacts" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "Acces calendrier applications UWP bloque" -Expected "LetAppsAccessCalendar=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessCalendar" -ErrorAction Stop).LetAppsAccessCalendar
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessCalendar" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "Acces messages SMS applications UWP bloque" -Expected "LetAppsAccessMessaging=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessMessaging" -ErrorAction Stop).LetAppsAccessMessaging
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessMessaging" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "Acces notifications applications UWP bloque" -Expected "LetAppsAccessNotifications=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessNotifications" -ErrorAction Stop).LetAppsAccessNotifications
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" -Name "LetAppsAccessNotifications" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "Localisation systeme desactivee" -Expected "DisableLocation=1" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocation" -ErrorAction Stop).DisableLocation
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocation" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocationScripting" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableSensors" -Value 1
} -IsCompliant {
    param($value)
    return [int]$value -eq 1
}

Write-Log "Durcissement vie privee: desactivation taches planifiees de telemetrie CEIP."

$telemetryTasks = @(
    "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "\Microsoft\Windows\Application Experience\StartupAppTask",
    "\Microsoft\Windows\Autochk\Proxy",
    "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask",
    "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
    "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "\Microsoft\Windows\Feedback\Siuf\DmClient",
    "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
    "\Microsoft\Windows\Maps\MapsToastTask",
    "\Microsoft\Windows\Maps\MapsUpdateTask",
    "\Microsoft\Windows\NetTrace\GatherNetworkInfo",
    "\Microsoft\Windows\SettingSync\BackgroundUploadTask",
    "\Microsoft\Windows\SettingSync\NetworkStateChangeTask",
    "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
)

Invoke-ComplianceRule -Rule "Taches telemetrie CEIP desactivees" -Expected "taches_actives=0" -GetValue {
    $enabled = 0
    foreach ($task in $telemetryTasks) {
        $t = Get-ScheduledTask -TaskPath (Split-Path $task -Parent) -TaskName (Split-Path $task -Leaf) -ErrorAction SilentlyContinue
        if ($t -and $t.State -ne "Disabled") { $enabled++ }
    }
    return "taches_actives=$enabled"
} -Apply {
    foreach ($task in $telemetryTasks) {
        $tp = Split-Path $task -Parent
        $tn = Split-Path $task -Leaf
        $t = Get-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue
        if ($t) { Disable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction SilentlyContinue | Out-Null }
    }
} -IsCompliant {
    param($value)
    return $value -match "taches_actives=0"
}

Write-Log "Durcissement vie privee: desactivation services de collecte de donnees."

Invoke-ComplianceRule -Rule "Service DiagTrack (telemetrie) desactive" -Expected "Disabled" -GetValue {
    (Get-Service -Name "DiagTrack" -ErrorAction Stop).StartType
} -Apply {
    Stop-Service -Name "DiagTrack" -Force -ErrorAction SilentlyContinue
    Set-Service -Name "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
} -IsCompliant {
    param($value)
    return ([string]$value -eq "Disabled") -or ([string]$value -eq "4")
}

Invoke-ComplianceRule -Rule "Service dmwappushservice desactive" -Expected "Disabled" -GetValue {
    (Get-Service -Name "dmwappushservice" -ErrorAction Stop).StartType
} -Apply {
    Stop-Service -Name "dmwappushservice" -Force -ErrorAction SilentlyContinue
    Set-Service -Name "dmwappushservice" -StartupType Disabled -ErrorAction SilentlyContinue
} -IsCompliant {
    param($value)
    return ([string]$value -eq "Disabled") -or ([string]$value -eq "4")
}

Write-Log "Durcissement vie privee: Spotlight, sync cloud, saisie, OneDrive."

Invoke-ComplianceRule -Rule "Windows Spotlight desactive" -Expected "NoLockScreenCamera=1" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreenCamera" -ErrorAction Stop).NoLockScreenCamera
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreenCamera" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreenSlideshow" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsSpotlightFeatures" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsSpotlightOnActionCenter" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsSpotlightOnSettings" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsSpotlightWindowsWelcomeExperience" -Value 1
} -IsCompliant {
    param($value)
    return [int]$value -eq 1
}

Invoke-ComplianceRule -Rule "Synchronisation parametres cloud desactivee" -Expected "DisableSettingSync=2" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -Name "DisableSettingSync" -ErrorAction Stop).DisableSettingSync
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -Name "DisableSettingSync" -Value 2
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -Name "DisableSettingSyncUserOverride" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -Name "DisableApplicationSettingSync" -Value 2
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -Name "DisableCredentialsSettingSync" -Value 2
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -Name "DisableDesktopThemeSettingSync" -Value 2
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -Name "DisablePersonalizationSettingSync" -Value 2
} -IsCompliant {
    param($value)
    return [int]$value -eq 2
}

Invoke-ComplianceRule -Rule "Saisie manuscrite et reconnaissance vocale" -Expected "RestrictImplicitInkCollection=1" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" -Name "RestrictImplicitInkCollection" -ErrorAction Stop).RestrictImplicitInkCollection
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" -Name "RestrictImplicitInkCollection" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization" -Name "RestrictImplicitTextCollection" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports" -Name "PreventHandwritingErrorReports" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC" -Name "PreventHandwritingDataSharing" -Value 1
} -IsCompliant {
    param($value)
    return [int]$value -eq 1
}

Invoke-ComplianceRule -Rule "Publicite par ID materiel desactivee" -Expected "Enabled=0" -GetValue {
    (Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -ErrorAction Stop).Enabled
} -Apply {
    New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Force | Out-Null
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Type DWord -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Invoke-ComplianceRule -Rule "Suivi lancement applications desactive" -Expected "Start_TrackProgs=0" -GetValue {
    (Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_TrackProgs" -ErrorAction Stop).Start_TrackProgs
} -Apply {
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_TrackProgs" -Type DWord -Value 0
} -IsCompliant {
    param($value)
    return [int]$value -eq 0
}

Invoke-ComplianceRule -Rule "OneDrive desactive (politique)" -Expected "DisableFileSyncNGSC=1" -GetValue {
    (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableFileSyncNGSC" -ErrorAction Stop).DisableFileSyncNGSC
} -Apply {
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableFileSyncNGSC" -Value 1
    Set-RegistryDword -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableLibrariesDefaultSaveToOneDrive" -Value 1
} -IsCompliant {
    param($value)
    return [int]$value -eq 1
}

Write-ComplianceSummary -PreviousResults $previousResults
$complianceResults | Export-Clixml -Path $previousResultsFile -Force
Save-RunState
Write-Log "Fin du script de securisation."
exit 0

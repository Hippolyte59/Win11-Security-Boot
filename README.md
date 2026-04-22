# Win11 Security Boot

Automatic Windows 11 hardening at startup with PowerShell, no external dependencies.

[![Platform](https://img.shields.io/badge/Platform-Windows%2011-0078D4?logo=windows11&logoColor=white)](https://www.microsoft.com/windows/windows-11)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Startup Task](https://img.shields.io/badge/Startup-Task%20Scheduler-blue)](start.bat)
[![Defender](https://img.shields.io/badge/Security-Microsoft%20Defender-success)](win11-startup-security.ps1)
[![Status](https://img.shields.io/badge/Status-Active-brightgreen)](.)

Language:
- [Francais](#francais)
- [English](#english)

---

## Francais

### Sommaire (FR)

- [Presentation](#presentation-fr)
- [Fonctionnalites](#fonctionnalites-fr)
- [Regles de conformite](#regles-de-conformite-fr)
- [Structure des fichiers](#structure-des-fichiers-fr)
- [Installation](#installation-fr)
- [Verification](#verification-fr)
- [Mode performance anti-lag](#mode-performance-anti-lag-fr)
- [Parametres avances](#parametres-avances-fr)
- [Logs et notifications](#logs-et-notifications-fr)
- [Desinstallation](#desinstallation-fr)
- [Notes](#notes-fr)

### Presentation (FR)

Le projet execute un script de securisation au demarrage Windows via une tache planifiee.
Le script applique des regles de hardening, genere un rapport de conformite, puis lance certaines taches lourdes en arriere-plan (Defender et Windows Update).
Depuis cette version, le script adapte automatiquement ses cooldowns selon la RAM et le CPU pour limiter le lag au demarrage.

### Fonctionnalites (FR)

- Activation du pare-feu sur Domain, Private, Public.
- Baseline Microsoft Defender (protection temps reel, IOAV, scripts, archives, email, USB, PUA, MAPS, actions automatiques).
- Mise a jour des signatures Defender (avec cooldown).
- Scan complet Defender (avec cooldown).
- Desactivation SMBv1 serveur et blocage des connexions SMB invite non securisees.
- Politique de verrouillage de compte (threshold, duration, window).
- Desactivation AutoRun.
- Desactivation du compte Invite local.
- Activation SmartScreen systeme (mode Block).
- Durcissement WDigest et LSASS (RunAsPPL).
- Desactivation PowerShell v2.
- Desactivation de Windows Recovery Environment (WinRE).
- Configuration Windows Update + declenchement asynchrone (avec cooldown).
- Reduction de la collecte Microsoft (telemetrie, historique d'activite, recherche web cloud, Advertising ID, contenus personnalises).
- Desactivation de fonctions souvent inutiles et couteuses (Widgets/News Feed, apps en arriere-plan, GameDVR/Xbox capture, Copilot, Delivery Optimization P2P).
- Rapport de conformite par regle (OK/KO, before/after).
- Notifications Windows differenciees selon la tache et le statut.
- Profil performance automatique (Auto/Low/Balanced/High) selon RAM/CPU.
- Priorite basse pour les taches lourdes en arriere-plan afin de limiter l'impact sur les machines modestes.

### Regles de conformite (FR)

Chaque regle est lue avant application, appliquee, puis relue apres application.

Regles principales auditees:
- Pare-feu profils: Domain=True, Private=True, Public=True.
- Defender baseline: protections et actions de remediation attendues.
- SMBv1 serveur: False.
- SMB client insecure guest: False.
- Verrouillage compte: Threshold, Duration, Window selon parametres.
- AutoRun: NoDriveTypeAutoRun=255.
- Compte Invite: Enabled=False.
- SmartScreen systeme: EnableSmartScreen=1, ShellSmartScreenLevel=Block.
- WDigest: UseLogonCredential=0.
- LSASS: RunAsPPL=1.
- PowerShell v2: Disabled ou DisabledWithPayloadRemoved.
- Windows RE: Status=Disabled.
- Windows Update policy: AUOptions=4, ScheduledInstallDay=0, ScheduledInstallTime, NoAutoRebootWithLoggedOnUsers=1.
- Telemetry policy: AllowTelemetry=0, DoNotShowFeedbackNotifications=1.
- Advertising ID policy: DisabledByGroupPolicy=1.
- Cloud content policy: DisableWindowsConsumerFeatures=1, DisableTailoredExperiencesWithDiagnosticData=1, DisableSoftLanding=1.
- Activity history policy: EnableActivityFeed=0, PublishUserActivities=0, UploadUserActivities=0.
- Web search privacy policy: AllowCortana=0, DisableWebSearch=1, ConnectedSearchUseWeb=0, ConnectedSearchUseWebOverMeteredConnections=0.
- Debloat policies: AllowNewsAndInterests=0, LetAppsRunInBackground=2, AllowGameDVR=0, TurnOffWindowsCopilot=1, DODownloadMode=0.

### Structure des fichiers (FR)

```text
.
|-- start.bat
|-- uninstall.bat
|-- win11-startup-security.ps1
`-- README.md

C:\logs\Win11SecurityBoot\
|-- security-YYYY-MM-DD_HH-mm-ss.log
`-- compliance-YYYY-MM-DD_HH-mm-ss.log

C:\ProgramData\Win11SecurityBoot\
`-- state\
    |-- defender-signature-update.txt
    |-- defender-full-scan.txt
    `-- windows-update-trigger.txt
```

### Installation (FR)

Prerequis:
- Windows 11
- PowerShell 5.1+
- Session Administrateur

Commandes:

```bat
cd "D:\Win11 Security Boot"
.\start.bat
```

`start.bat` demande les droits admin si necessaire, cree la tache `Win11SecurityBoot`, puis lance immediatement le script de securisation.

### Verification (FR)

Verifier la tache:

```powershell
Get-ScheduledTask -TaskName "Win11SecurityBoot"
```

Lancer un test manuel:

```powershell
Start-ScheduledTask -TaskName "Win11SecurityBoot"
```

Consulter les derniers logs:

```powershell
Get-ChildItem "C:\logs\Win11SecurityBoot" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 5
```

### Mode performance anti-lag (FR)

Le script detecte automatiquement la machine:
- `Low`: RAM <= 8 GB, ou CPU <= 4 threads.
- `Balanced`: RAM <= 16 GB, ou CPU <= 8 threads.
- `High`: au-dela.

Effets:
- Cooldowns augmentes automatiquement sur profils modestes.
- Taches lourdes (scan complet Defender, Windows Update, signatures) lancees avec priorite reduite.

Exemple de comportement par classe:
- `Low`: signatures >= 12h, Windows Update >= 24h, full scan >= 336h.
- `Balanced`: signatures >= 6h, Windows Update >= 12h, full scan >= 168h.
- `High`: utilise les valeurs demandees (parametres du script).

Si besoin, vous pouvez forcer un profil:

```powershell
.\win11-startup-security.ps1 -PerformanceProfile Low
```

### Parametres avances (FR)

Le script principal accepte notamment:
- `CooldownHours` (defaut: 12)
- `LockoutThreshold` (defaut: 3)
- `LockoutDurationMinutes` (defaut: 30)
- `LockoutWindowMinutes` (defaut: 30)
- `UpdateInstallHour` (defaut: 3)
- `SignatureUpdateCooldownHours` (defaut: 6)
- `WindowsUpdateTriggerCooldownHours` (defaut: 6)
- `FullScanCooldownHours` (defaut: 168)
- `PerformanceProfile` (`Auto`, `Low`, `Balanced`, `High`)

Exemple:

```powershell
.\win11-startup-security.ps1 -LockoutThreshold 5 -FullScanCooldownHours 72
```

### Logs et notifications (FR)

Fichiers generes a chaque execution:
- `security-*.log`: actions horodatees.
- `compliance-*.log`: tableau de conformite par regle.

Notifications:
- Une notification distincte est emise pour chaque tache importante (signatures Defender, scan complet, Windows Update, resume de conformite).
- Le message et l'icone changent selon la tache et le statut (success, skipped, warning, error).
- En session non interactive (ex: execution SYSTEM sans bureau utilisateur), la notification peut ne pas s'afficher visuellement; la raison est journalisee.

Chemins actuels:
- Logs: `C:\logs\Win11SecurityBoot\`
- Etat/cooldowns: `C:\ProgramData\Win11SecurityBoot\state\`

### Desinstallation (FR)

```bat
.\uninstall.bat
```

Cette commande retire la tache planifiee uniquement. Les reglages deja appliques restent actifs.
Le nouveau `uninstall.bat` supprime directement la tache sans verification prealable lente, ce qui reduit les blocages perçus.

### Notes (FR)

- Certaines regles peuvent etre ecrasees par des politiques entreprise (GPO/Intune).
- La protection LSASS (RunAsPPL) peut necessiter un redemarrage pour effet complet.
- WinRE est desactive par ce script: sans media de recuperation externe, certaines options de depannage avance ne seront plus disponibles.

---

## English

### Table of Contents (EN)

- [Overview](#overview-en)
- [Features](#features-en)
- [Compliance Rules](#compliance-rules-en)
- [File Layout](#file-layout-en)
- [Installation](#installation-en)
- [Verification](#verification-en)
- [Performance anti-lag mode](#performance-anti-lag-mode-en)
- [Advanced Parameters](#advanced-parameters-en)
- [Logs and Notifications](#logs-and-notifications-en)
- [Uninstall](#uninstall-en)
- [Notes](#notes-en)

### Overview (EN)

This project runs a Windows hardening script at startup through Task Scheduler.
It applies baseline security controls, writes compliance output, and launches heavy tasks asynchronously (Defender and Windows Update).
This version also auto-tunes cooldowns from RAM/CPU so lower-end PCs get less startup lag.

### Features (EN)

- Enables firewall profiles (Domain, Private, Public).
- Applies Microsoft Defender baseline settings.
- Triggers Defender signature update with cooldown.
- Triggers Defender full scan with cooldown.
- Disables SMBv1 server and insecure SMB guest logons.
- Applies account lockout policy.
- Disables AutoRun.
- Disables built-in Guest account.
- Enables system SmartScreen in Block mode.
- Hardens WDigest and LSASS (RunAsPPL).
- Disables PowerShell v2.
- Disables Windows Recovery Environment (WinRE).
- Configures Windows Update policy and asynchronous trigger with cooldown.
- Reduces Microsoft tracking footprint (telemetry, activity history, cloud/web search integration, Advertising ID, tailored experiences).
- Disables commonly unnecessary and heavy features (Widgets/News Feed, background apps, GameDVR/Xbox capture, Copilot, Delivery Optimization P2P).
- Produces per-rule compliance logs (OK/KO, before/after).
- Sends task-specific Windows notifications with different icons/messages.
- Hardware-aware performance profile (Auto/Low/Balanced/High).
- Low-priority background execution for heavy tasks to reduce UI stutter.

### Compliance Rules (EN)

Each rule is read before apply, applied, then read again.

Main audited rules:
- Firewall profiles: Domain=True, Private=True, Public=True.
- Defender baseline values.
- SMBv1 server: False.
- SMB insecure guest logons: False.
- Account lockout policy values.
- AutoRun: NoDriveTypeAutoRun=255.
- Guest account: Enabled=False.
- SmartScreen system: EnableSmartScreen=1, ShellSmartScreenLevel=Block.
- WDigest: UseLogonCredential=0.
- LSASS: RunAsPPL=1.
- PowerShell v2: Disabled or DisabledWithPayloadRemoved.
- Windows RE: Status=Disabled.
- Windows Update policy keys.
- Telemetry policy keys.
- Advertising ID policy key.
- Cloud content and activity history privacy keys.
- Web search privacy keys.
- Debloat policy keys (Widgets, background apps, GameDVR, Copilot, Delivery Optimization).

### File Layout (EN)

```text
.
|-- start.bat
|-- uninstall.bat
|-- win11-startup-security.ps1
`-- README.md

C:\logs\Win11SecurityBoot\
|-- security-YYYY-MM-DD_HH-mm-ss.log
`-- compliance-YYYY-MM-DD_HH-mm-ss.log

C:\ProgramData\Win11SecurityBoot\
`-- state\
    |-- defender-signature-update.txt
    |-- defender-full-scan.txt
    `-- windows-update-trigger.txt
```

### Installation (EN)

Requirements:
- Windows 11
- PowerShell 5.1+
- Administrator session

Commands:

```bat
cd "D:\Win11 Security Boot"
.\start.bat
```

`start.bat` requests elevation when needed, creates the `Win11SecurityBoot` startup task, then immediately runs the hardening script.

### Verification (EN)

Check task registration:

```powershell
Get-ScheduledTask -TaskName "Win11SecurityBoot"
```

Run a manual test:

```powershell
Start-ScheduledTask -TaskName "Win11SecurityBoot"
```

Read latest logs:

```powershell
Get-ChildItem "C:\logs\Win11SecurityBoot" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 5
```

### Performance anti-lag mode (EN)

The script auto-detects hardware:
- `Low`: RAM <= 8 GB, or CPU <= 4 logical threads.
- `Balanced`: RAM <= 16 GB, or CPU <= 8 logical threads.
- `High`: above that.

Effects:
- Cooldowns are increased automatically on lower-end profiles.
- Heavy background tasks run with reduced priority.

Typical class behavior:
- `Low`: signatures >= 12h, Windows Update >= 24h, full scan >= 336h.
- `Balanced`: signatures >= 6h, Windows Update >= 12h, full scan >= 168h.
- `High`: uses requested values from script parameters.

To force a profile manually:

```powershell
.\win11-startup-security.ps1 -PerformanceProfile Low
```

### Advanced Parameters (EN)

Main script parameters include:
- `CooldownHours`
- `LockoutThreshold`
- `LockoutDurationMinutes`
- `LockoutWindowMinutes`
- `UpdateInstallHour`
- `SignatureUpdateCooldownHours`
- `WindowsUpdateTriggerCooldownHours`
- `FullScanCooldownHours`
- `PerformanceProfile` (`Auto`, `Low`, `Balanced`, `High`)

Example:

```powershell
.\win11-startup-security.ps1 -LockoutThreshold 5 -FullScanCooldownHours 72
```

### Logs and Notifications (EN)

Generated files:
- `security-*.log`: timestamped action log.
- `compliance-*.log`: per-rule compliance output.

Paths:
- Logs: `C:\logs\Win11SecurityBoot\`
- State/cooldowns: `C:\ProgramData\Win11SecurityBoot\state\`

Notifications:
- Distinct notifications are emitted for each major task.
- Message and icon vary by task and status (success, skipped, warning, error).
- In non-interactive sessions (for example SYSTEM without user desktop), visual notification may not appear; the reason is logged.

### Uninstall (EN)

```bat
.\uninstall.bat
```

This only removes the scheduled task. Applied security settings remain on the machine.
The updated `uninstall.bat` removes the task directly (no slow pre-query), which reduces perceived lag.

### Notes (EN)

- Enterprise policies (GPO/Intune) can override some settings.
- LSASS protection (RunAsPPL) may require reboot for full effect.
- WinRE is disabled by this script: without external recovery media, some advanced troubleshooting options may no longer be available.



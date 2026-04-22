# Win11 Security Boot

Automatic Windows 11 hardening at startup with PowerShell, no external dependencies.

[![Platform](https://img.shields.io/badge/Platform-Windows%2011-0078D4?logo=windows11&logoColor=white)](https://www.microsoft.com/windows/windows-11)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Startup Task](https://img.shields.io/badge/Startup-Task%20Scheduler-blue)](install-startup-task.ps1)
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
- [Parametres avances](#parametres-avances-fr)
- [Logs et notifications](#logs-et-notifications-fr)
- [Desinstallation](#desinstallation-fr)
- [Notes](#notes-fr)

### Presentation (FR)

Le projet execute un script de securisation au demarrage Windows via une tache planifiee.
Le script applique des regles de hardening, genere un rapport de conformite, puis lance certaines taches lourdes en arriere-plan (Defender et Windows Update).

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
- Configuration Windows Update + declenchement asynchrone (avec cooldown).
- Rapport de conformite par regle (OK/KO, before/after).
- Notifications Windows differenciees selon la tache et le statut.

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
- Windows Update policy: AUOptions=4, ScheduledInstallDay=0, ScheduledInstallTime, NoAutoRebootWithLoggedOnUsers=1.

### Structure des fichiers (FR)

```text
.
|-- win11-startup-security.ps1
|-- install-startup-task.ps1
|-- uninstall-startup-task.ps1
`-- README.md

C:\ProgramData\Win11SecurityBoot\
|-- logs\
|   |-- security-YYYY-MM-DD_HH-mm-ss.log
|   `-- compliance-YYYY-MM-DD_HH-mm-ss.log
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

```powershell
cd "D:\Win11 Security Boot"
.\install-startup-task.ps1
```

La tache `Win11SecurityBoot` est enregistree pour un lancement au demarrage en compte SYSTEM.

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
Get-ChildItem "C:\ProgramData\Win11SecurityBoot\logs" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 5
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

### Desinstallation (FR)

```powershell
.\uninstall-startup-task.ps1
```

Cette commande retire la tache planifiee uniquement. Les reglages deja appliques restent actifs.

### Notes (FR)

- Certaines regles peuvent etre ecrasees par des politiques entreprise (GPO/Intune).
- La protection LSASS (RunAsPPL) peut necessiter un redemarrage pour effet complet.

---

## English

### Table of Contents (EN)

- [Overview](#overview-en)
- [Features](#features-en)
- [Compliance Rules](#compliance-rules-en)
- [File Layout](#file-layout-en)
- [Installation](#installation-en)
- [Verification](#verification-en)
- [Advanced Parameters](#advanced-parameters-en)
- [Logs and Notifications](#logs-and-notifications-en)
- [Uninstall](#uninstall-en)
- [Notes](#notes-en)

### Overview (EN)

This project runs a Windows hardening script at startup through Task Scheduler.
It applies baseline security controls, writes compliance output, and launches heavy tasks asynchronously (Defender and Windows Update).

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
- Configures Windows Update policy and asynchronous trigger with cooldown.
- Produces per-rule compliance logs (OK/KO, before/after).
- Sends task-specific Windows notifications with different icons/messages.

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
- Windows Update policy keys.

### File Layout (EN)

```text
.
|-- win11-startup-security.ps1
|-- install-startup-task.ps1
|-- uninstall-startup-task.ps1
`-- README.md

C:\ProgramData\Win11SecurityBoot\
|-- logs\
|   |-- security-YYYY-MM-DD_HH-mm-ss.log
|   `-- compliance-YYYY-MM-DD_HH-mm-ss.log
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

```powershell
cd "D:\Win11 Security Boot"
.\install-startup-task.ps1
```

This registers the `Win11SecurityBoot` startup task under SYSTEM.

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
Get-ChildItem "C:\ProgramData\Win11SecurityBoot\logs" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 5
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

Example:

```powershell
.\win11-startup-security.ps1 -LockoutThreshold 5 -FullScanCooldownHours 72
```

### Logs and Notifications (EN)

Generated files:
- `security-*.log`: timestamped action log.
- `compliance-*.log`: per-rule compliance output.

Notifications:
- Distinct notifications are emitted for each major task.
- Message and icon vary by task and status (success, skipped, warning, error).
- In non-interactive sessions (for example SYSTEM without user desktop), visual notification may not appear; the reason is logged.

### Uninstall (EN)

```powershell
.\uninstall-startup-task.ps1
```

This only removes the scheduled task. Applied security settings remain on the machine.

### Notes (EN)

- Enterprise policies (GPO/Intune) can override some settings.
- LSASS protection (RunAsPPL) may require reboot for full effect.



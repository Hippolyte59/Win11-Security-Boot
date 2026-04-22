<div align="center">

#  Win11 Security Boot

**Durcissement automatique de Windows 11 au démarrage  PowerShell, sans dépendances**

[![Platform](https://img.shields.io/badge/platform-Windows%2011-0078D4?logo=windows11&logoColor=white)](https://www.microsoft.com/windows/windows-11)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Admin Required](https://img.shields.io/badge/requires-Administrator-red?logo=windows&logoColor=white)](.)
[![License](https://img.shields.io/badge/license-MIT-green)](.)
[![Compliance](https://img.shields.io/badge/audit-OK%2FKO%20par%20regle-brightgreen)](.)
[![Startup](https://img.shields.io/badge/lancement-au%20d%C3%A9marrage-blue?logo=task&logoColor=white)](.)

</div>

---

##  Sommaire

- [Aperçu](#-aperçu)
- [Fonctionnalités](#-fonctionnalités)
- [Règles de conformité auditées](#-règles-de-conformité-auditées)
- [Architecture des fichiers](#-architecture-des-fichiers)
- [Installation](#-installation)
- [Vérification](#-vérification)
- [Paramètres avancés](#-paramètres-avancés)
- [Logs & rapport de conformité](#-logs--rapport-de-conformité)
- [Désinstallation](#-désinstallation)
- [Notes](#-notes)

---

##  Aperçu

**Win11 Security Boot** est un script PowerShell qui se lance automatiquement à chaque démarrage de ton PC via le Planificateur de tâches Windows. Il applique en quelques secondes un ensemble de règles de durcissement, puis lance les tâches lourdes (scan antivirus, mises à jour) **en arrière-plan** pour ne pas ralentir ton démarrage.

###  Démo  Installation de la tâche au démarrage

> *Enregistre ce terminal avec [ScreenToGif](https://www.screentogif.com/) et remplace ce bloc par ton GIF.*

```
.\install-startup-task.ps1
Tache 'Win11SecurityBoot' creee. Le script se lancera au demarrage du PC.
```

![Demo installation](https://placehold.co/800x200/1e1e2e/cdd6f4?text=GIF++install-startup-task.ps1)

---

###  Démo  Exécution du script de sécurité

> *Remplace cette image par un GIF enregistré avec ScreenToGif du script en action.*

```
[2026-04-22 07:01:02] Demarrage du script de securisation.
[2026-04-22 07:01:02] Conformite [OK] Pare-feu profils actives | avant='...' | apres='Domain=True,Private=True,Public=True'
[2026-04-22 07:01:03] Conformite [OK] Defender baseline | ...
[2026-04-22 07:01:04] Resume conformite: OK=10 KO=0
```

![Demo execution](https://placehold.co/800x300/1e1e2e/a6e3a1?text=GIF++win11-startup-security.ps1+en+action)

---

###  Démo  Rapport de conformité

> *Exemple de rapport compliance généré dans les logs.*

```
Rule                      | Status | Expected              | Before | After  | Details
Pare-feu profils actives  | OK     | Domain=True,...       | ...    | ...    | Regle conforme
SMBv1 serveur             | OK     | False                 | True   | False  | Regle conforme
WDigest                   | OK     | UseLogonCredential=0  | 1      | 0      | Regle conforme
```

![Demo compliance](https://placehold.co/800x250/1e1e2e/fab387?text=GIF++compliance+log+avant%2Fapres)

---

##  Fonctionnalités

| Catégorie | Ce qui est fait |
|---|---|
|  **Pare-feu** | Activation sur les 3 profils : Domaine, Privé, Public |
|  **Defender** | Protection temps réel, scripts, archives, e-mail, USB, réseau |
|  **Antivirus auto** | Menaces faibles/modérées  quarantaine · élevées/sévères  suppression |
|  **Signatures** | Mise à jour en arrière-plan toutes les 6 h |
|  **Scan complet** | Scan complet en arrière-plan, 1 fois par semaine |
|  **Windows Update** | Config auto + déclenchement en arrière-plan toutes les 6 h |
|  **SMB** | Désactivation SMBv1 serveur + blocage invité client |
|  **Compte Invité** | Désactivé automatiquement |
|  **AutoRun** | Désactivé pour USB et CD |
|  **SmartScreen** | Activé en mode Blocage système |
|  **WDigest** | Désactivé (évite le stockage des credentials en clair) |
|  **LSASS** | Protection PPL activée (RunAsPPL) |
|  **PowerShell v2** | Désactivé (composant legacy vulnérable) |
|  **Lockout** | Verrouillage après 3 erreurs de mot de passe pendant 30 min |

---

##  Règles de conformité auditées

Chaque règle est vérifiée **avant** application, **appliquée**, puis **vérifiée après** avec un statut `OK` ou `KO` :

| Règle | Valeur attendue |
|---|---|
| Pare-feu profils actives | `Domain=True,Private=True,Public=True` |
| Defender baseline | Toutes protections actives + actions auto |
| SMBv1 serveur | `False` |
| SMB client insecure guest | `False` |
| Politique verrouillage compte | `Threshold=3;Duration=30;Window=30` |
| AutoRun | `NoDriveTypeAutoRun=255` |
| Compte Invité | `Enabled=False` |
| SmartScreen système | `EnableSmartScreen=1;ShellSmartScreenLevel=Block` |
| WDigest | `UseLogonCredential=0` |
| LSASS RunAsPPL | `RunAsPPL=1` |
| PowerShell v2 | `State=Disabled` |
| Windows Update policy | `AUOptions=4;NoAutoRebootWithLoggedOnUsers=1` |

---

##  Architecture des fichiers

```
 sécuriter windows 11/
  win11-startup-security.ps1    Script principal de durcissement
   install-startup-task.ps1     Enregistre la tâche au démarrage
   uninstall-startup-task.ps1   Supprime la tâche planifiée
  README.md

 C:\ProgramData\Win11SecurityBoot\
  logs/
    security-AAAA-MM-JJ_HH-mm-ss.log     Log d'exécution
    compliance-AAAA-MM-JJ_HH-mm-ss.log   Rapport OK/KO avant/après
  state/
     defender-signature-update.txt
     defender-full-scan.txt
     windows-update-trigger.txt
```

---

##  Installation

> **Prérequis :** Windows 11, PowerShell 5.1+, compte Administrateur local.

**1. Clone ou copie le dossier sur ton PC.**

**2. Ouvre PowerShell en administrateur :**

```powershell
# Clic droit sur le menu Démarrer  "Terminal Windows (Admin)"
```

**3. Va dans le dossier du projet :**

```powershell
cd "d:\sécuriter windows 11"
```

**4. Lance l'installateur :**

```powershell
.\install-startup-task.ps1
```

> La tâche `Win11SecurityBoot` est créée dans le Planificateur de tâches et se lancera à chaque démarrage en tant que `SYSTEM`.

---

##  Vérification

**Via le Planificateur de tâches :**
- Ouvre `taskschd.msc`
- Vérifie la présence de la tâche `Win11SecurityBoot`

**Lancement manuel (test) :**

```powershell
Start-ScheduledTask -TaskName "Win11SecurityBoot"
```

**Consulter les logs :**

```powershell
Get-ChildItem "C:\ProgramData\Win11SecurityBoot\logs\" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

---

##  Paramètres avancés

Le script accepte des paramètres pour personnaliser son comportement :

| Paramètre | Défaut | Plage | Description |
|---|---|---|---|
| `CooldownHours` | `12` | 1168 | Délai minimum entre deux exécutions complètes |
| `LockoutThreshold` | `3` | 310 | Nombre d'erreurs avant verrouillage |
| `LockoutDurationMinutes` | `30` | 199999 | Durée du verrouillage (minutes) |
| `LockoutWindowMinutes` | `30` | 199999 | Fenêtre de comptage des erreurs (minutes) |
| `UpdateInstallHour` | `3` | 023 | Heure d'installation planifiée des mises à jour |
| `SignatureUpdateCooldownHours` | `6` | 124 | Fréquence de mise à jour des signatures |
| `WindowsUpdateTriggerCooldownHours` | `6` | 124 | Fréquence du déclenchement Windows Update |
| `FullScanCooldownHours` | `168` | 24720 | Fréquence du scan complet (168 = 1×/semaine) |

**Exemple :**

```powershell
.\win11-startup-security.ps1 -LockoutThreshold 5 -FullScanCooldownHours 72
```

---

##  Logs & rapport de conformité

Deux fichiers sont générés à chaque exécution :

| Fichier | Contenu |
|---|---|
| `security-*.log` | Toutes les actions et événements horodatés |
| `compliance-*.log` | Rapport `Rule \| Status \| Expected \| Before \| After \| Details` |

**Exemple de ligne de conformité :**

```
WDigest | OK | UseLogonCredential=0 | Before=1 | After=0 | Regle conforme
LSASS RunAsPPL | OK | RunAsPPL=1 | Before=0 | After=1 | Regle conforme
```

---

##  Désinstallation

```powershell
.\uninstall-startup-task.ps1
```

> Cela supprime uniquement la tâche planifiée. Les réglages de sécurité déjà appliqués sur Windows restent en place.

---

##  Notes

>  Certaines actions peuvent être ignorées si des politiques d'entreprise (GPO/Intune) sont déjà appliquées.

>  Le scan complet Defender et la recherche de mises à jour sont lancés en arrière-plan et n'impactent pas la vitesse de démarrage.

>  La protection LSASS (RunAsPPL) nécessite un redémarrage pour être pleinement effective.

>  Pour créer tes propres GIFs de démo, utilise [ScreenToGif](https://www.screentogif.com/) (gratuit et open-source).

---

<div align="center">

Made with  for Windows 11 security hardening

</div>



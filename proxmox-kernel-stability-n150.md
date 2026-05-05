# Proxmox Kernel-Stabilität auf Intel N150 (Alder Lake-N)

## Problem

Intel N100/N150 (Alder Lake-N) CPUs haben ein bekanntes Problem mit den
Linux-Power-States (C-States). Der Prozessor geht in tiefe Schlafzustände
(C6/C7+), aus denen er nicht sauber aufwacht. Das führt zu:

- **Komplette System-Freezes** nach 60–80 Stunden Uptime
- **Kernel Panics** ohne Logeinträge
- SSH, Web-UI, VMs — alles tot, nur Hard-Reset hilft
- Tritt auf mit Kernel 6.8, 6.12, 6.14 und 6.17

## Deine aktuelle Installation

| Komponente | Version |
|-----------|---------|
| Proxmox VE | 9.1.0 |
| Laufender Kernel | **6.8.12-4-pve** |
| Installierte Kernel | 6.8.12-4, 6.8.12-16, 6.14.11-4, 6.17.2-1 |
| CPU | Intel N150 (Alder Lake-N) |
| Intel Microcode | 3.20250812.1 |
| Boot-Loader | **systemd-boot** (ZFS-Installation) — Stand 2026-04-17 |
| Root-FS | ZFS (`rpool/ROOT/pve-1`) |

## Empfehlung

### Kernel-Wahl

| Kernel | Status | Empfehlung |
|--------|--------|-----------|
| **6.8.12-16-pve** | Stabil, LTS-nah, bewährt | ✅ **Beste Wahl für Stabilität** |
| 6.14.11-4-pve | PVE 9.0 Default | ⚠️ Freeze-Berichte auf N100/N150 |
| 6.17.2-1-pve | PVE 9.1 Default (neu) | ⚠️ Zu neu, wenig Erfahrung auf N150 |
| 6.8.12-4-pve | Dein aktueller | ✅ OK, aber 6.8.12-16 hat mehr Fixes |

**Empfehlung: Kernel 6.8.12-16-pve** — das ist die neueste Patch-Version
der bewährtesten Kernel-Linie für Proxmox + Alder Lake-N. Kombiniert mit
C-State-Limitierung ist das die stabilste Konfiguration.

### C-State-Limitierung (KRITISCH!)

Das ist die **wichtigste Massnahme** — unabhängig vom Kernel:

```
intel_idle.max_cstate=1 processor.max_cstate=1
```

Dies beschränkt den CPU auf C0 (aktiv) und C1 (leichter Schlaf).
Tiefere Zustände (C6/C7+), die die Freezes verursachen, werden deaktiviert.

**Nachteil:** ~1-2W höherer Idle-Verbrauch. Bei einem N150 Mini-PC
vernachlässigbar.

---

## Schritt-für-Schritt-Anleitung

### Phase 1: Backup erstellen (VOR allen Änderungen!)

```bash
# Backup der VM-Konfigurationen
cp -r /etc/pve /root/pve-backup-$(date +%Y%m%d)

# Backup der wichtigsten VMs
vzdump 100 --storage local --compress zstd --mode snapshot
# Wiederhole für jede wichtige VM (z.B. Home Assistant)
vzdump 108 --storage local --compress zstd --mode snapshot

# Backup der GRUB-Config
cp /etc/default/grub /root/grub.backup
```

### Phase 2: C-State-Limitierung setzen

> ℹ️ **Stand 2026-04-17:** Dieses System nutzt **systemd-boot mit ZFS**.
> Die systemd-boot-Anleitung ist der primäre Pfad. Die GRUB-Anleitung
> bleibt als Referenz erhalten, falls später auf GRUB umgestellt wird.

```bash
# Prüfe welcher Bootloader aktiv ist
test -d /sys/firmware/efi && echo "UEFI (evtl. systemd-boot)" || echo "BIOS (GRUB)"
```

#### Option A: systemd-boot (ZFS) ← Dein aktuelles Setup

```bash
# Kernel-Parameter bearbeiten
nano /etc/kernel/cmdline
```

Inhalt (eine Zeile):
```
root=ZFS=rpool/ROOT/pve-1 boot=zfs intel_idle.max_cstate=1 processor.max_cstate=1
```

Speichern und aktivieren:
```bash
proxmox-boot-tool refresh
```

#### Option B: GRUB (ext4/LVM) ← Falls später umgestellt

```bash
# GRUB-Parameter bearbeiten
nano /etc/default/grub
```

Finde die Zeile:
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
```

Ersetze durch:
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_idle.max_cstate=1 processor.max_cstate=1"
```

Speichern und aktivieren:
```bash
update-grub
```

### Phase 3: Kernel auf 6.8.12-16-pve pinnen

```bash
# Verfügbare Kernel anzeigen
proxmox-boot-tool kernel list

# Kernel 6.8.12-16 ist bereits installiert (laut pveversion)
# Pinne ihn als Standard-Boot-Kernel
proxmox-boot-tool kernel pin 6.8.12-16-pve

# Boot-Loader aktualisieren
proxmox-boot-tool refresh
```

### Phase 4: Reboot und Verifizierung

```bash
# Reboot
reboot
```

Nach dem Reboot verifizieren:

```bash
# Laufender Kernel prüfen
uname -r
# Erwartet: 6.8.12-16-pve

# C-State-Parameter prüfen
cat /proc/cmdline | grep cstate
# Erwartet: intel_idle.max_cstate=1 processor.max_cstate=1

# Aktuelle C-State-Nutzung prüfen
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/disable
# State2+ sollten deaktiviert sein

# Alle VMs und LXCs laufen?
qm list
pct list

# OpenClaw VM erreichbar?
ssh -o ConnectTimeout=5 claw@192.168.178.80 "echo OK"
```

### Phase 5: Unnötige Kernel entfernen (optional)

Nach einigen Tagen Stabilität können alte Kernel entfernt werden:

```bash
# Installierte Kernel anzeigen
dpkg -l | grep proxmox-kernel | grep -v helper

# Ältere Kernel entfernen (NICHT den laufenden!)
# Beispiel: 6.14 und 6.17 entfernen
apt remove proxmox-kernel-6.14.11-4-pve-signed
apt remove proxmox-kernel-6.17.2-1-pve-signed

# Boot-Loader aktualisieren
proxmox-boot-tool refresh
```

**ACHTUNG:** Behalte immer mindestens 2 Kernel (den laufenden + einen
Fallback). Entferne niemals den aktuell laufenden Kernel!

---

## Notfall-Recovery

### Szenario 1: System bootet nicht nach Kernel-Änderung

**Am physischen Monitor + Tastatur:**

1. Beim Booten GRUB-Menü aufrufen (Shift oder Esc gedrückt halten)
2. "Advanced options for Proxmox VE" wählen
3. Einen anderen Kernel wählen (z.B. 6.8.12-4-pve oder 6.17.2-1-pve)
4. System bootet mit dem gewählten Kernel
5. Nach dem Login den defekten Kernel-Pin korrigieren:

```bash
# Pin entfernen
proxmox-boot-tool kernel unpin
proxmox-boot-tool refresh
```

### Szenario 2: System friert nach Reboot sofort ein

1. Hard-Reset (Strom aus/ein)
2. GRUB-Menü → anderen Kernel wählen
3. Falls GRUB nicht erscheint:
   - USB-Stick mit Proxmox Installer booten
   - "Install Proxmox VE (Debug mode)" oder Shell wählen
   - Root-Partition mounten und GRUB reparieren:

```bash
# Root-Partition finden
fdisk -l
# oder für ZFS:
zpool import -f rpool

# Mounten (ext4/LVM)
mount /dev/mapper/pve-root /mnt
mount /dev/sdX1 /mnt/boot  # Boot-Partition

# GRUB reparieren
chroot /mnt
nano /etc/default/grub
# Alle custom Parameter entfernen als Test
update-grub
exit
reboot
```

### Szenario 3: System friert nach 60-80h wieder ein (trotz C-State Fix)

1. Prüfe ob die C-State-Parameter wirklich aktiv sind:
```bash
cat /proc/cmdline
# Muss enthalten: intel_idle.max_cstate=1 processor.max_cstate=1
```

2. Falls ja, zusätzliche Parameter versuchen:
```bash
nano /etc/default/grub
# Ergänze:
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_idle.max_cstate=1 processor.max_cstate=1 pcie_aspm=off"
update-grub
reboot
```

3. Falls immer noch Freezes:
```bash
# BIOS-Update prüfen — besuche die Herstellerseite deines Mini-PCs
# Intel Microcode aktualisieren
apt update && apt install intel-microcode
reboot
```

4. Ultimativer Fallback — Polling-Idle (höchster Stromverbrauch, aber
   garantiert kein Freeze):
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_idle.max_cstate=1 processor.max_cstate=1 idle=poll pcie_aspm=off"
```

### Szenario 4: GRUB-Config zerstört / System bootet in Notfall-Shell

```bash
# Von Proxmox USB-Installer booten → Shell

# Für LVM/ext4:
mount /dev/mapper/pve-root /mnt
mount /dev/sdX1 /mnt/boot/efi  # EFI-Partition
for d in dev proc sys run; do mount --bind /$d /mnt/$d; done
chroot /mnt

# GRUB-Backup wiederherstellen (falls vorhanden)
cp /root/grub.backup /etc/default/grub
update-grub
grub-install /dev/sdX  # Disk, nicht Partition!

exit
umount -R /mnt
reboot
```

### Szenario 5: VM startet nicht nach Host-Reboot

```bash
# VM-Status prüfen
qm status 100

# Falls gestoppt — manuell starten
qm start 100

# Falls Fehler — Config prüfen
qm config 100

# Falls Disk-Fehler — Backup wiederherstellen
qmrestore /var/lib/vz/dump/vzdump-qemu-100-*.vma.zst 100 --force
```

---

## Monitoring nach der Änderung

### Uptime überwachen

```bash
# Uptime anzeigen
uptime

# Automatisches Monitoring-Script (optional)
cat > /usr/local/bin/uptime-monitor.sh << 'EOF'
#!/bin/bash
UPTIME_HOURS=$(awk '{print int($1/3600)}' /proc/uptime)
if [ $UPTIME_HOURS -gt 168 ]; then
  echo "$(date): Uptime $UPTIME_HOURS hours - STABLE" >> /var/log/uptime-monitor.log
fi
EOF
chmod +x /usr/local/bin/uptime-monitor.sh

# Cronjob: alle 6 Stunden loggen
echo "0 */6 * * * root /usr/local/bin/uptime-monitor.sh" > /etc/cron.d/uptime-monitor
```

### Kernel-Logs auf Warnungen prüfen

```bash
# Nach dem Reboot — Kernel-Warnungen prüfen
dmesg | grep -i "error\|panic\|fault\|warn" | head -20

# Journal nach Freeze-Hinweisen durchsuchen
journalctl -b -p err --no-pager | head -30
```

---

## Zusammenfassung der Änderungen

| Was | Vorher | Nachher |
|-----|--------|---------|
| Kernel | 6.8.12-4-pve | **6.8.12-16-pve** (gepinnt) |
| C-State (Kernel) | Unbeschränkt (C7+) | **max_cstate=1** (nur C0/C1) |
| C-State (BIOS) | Enabled | **Disabled** |
| ASPM (BIOS) | Auto | **Disabled** |
| ASPM (Kernel) | Default | Optional: **pcie_aspm=off** |
| AC Power Loss | Unbekannt | **Power On** (Auto-Start) |
| Wake on LAN | Disabled | **Enabled** |
| Fast Boot | Enabled | **Disabled** (GRUB erreichbar) |
| Idle-Verbrauch | ~2-3W | ~4-5W (vernachlässigbar) |
| Stabilität | Freeze nach ~80h | **Stabil (dauerhaft)** |

## BIOS-Einstellungen für Stabilität

### Dein System (aus BIOS-Foto ausgelesen)

| Feld | Wert |
|------|------|
| Board / Project Version | **BK-1264NP-N150 Ver: 41.5** |
| BIOS Build | 15.12.2024, 20:40:49 |
| BIOS-Typ | AMI Aptio (UEFI) |
| Access Level | Administrator |
| CPU Name | AlderLake ULX |
| CPU Typ | Intel(R) N150 |
| Stepping | A0 |
| Speed (Idle) | 800 MHz |
| RAM | 16384 MB (16 GB) DDR5 |
| RAM Frequenz | 4800 MHz |

### Empfohlene BIOS-Änderungen

Navigiere im BIOS mit den Pfeiltasten (`←→` = Reiter, `↑↓` = Einträge,
`Enter` = Öffnen, `F4` = Speichern & Beenden).

#### 1. C-States deaktivieren (WICHTIGSTE Änderung!)

**Pfad:** `Advanced` → `CPU Configuration`

> ℹ️ **Stand 2026-04-17 (aus BIOS-Screenshots verifiziert):** Dieses Board
> hat ein **vereinfachtes BIOS** — es gibt keinen separaten "CPU C States"-
> Master-Schalter. Die einzige C-State-Einstellung ist **C6DRAM**.

| Einstellung | Aktuell (Standard) | Empfohlen |
|-------------|-------------------|-----------|
| **C6DRAM** | Enabled | **→ Disabled** |
| **MonitorMWait** | Enabled | **→ Disabled** |

**Nicht ändern (lassen wie es ist):**

| Einstellung | Wert | Warum nicht ändern |
|-------------|------|-------------------|
| Intel (VMX) Virtualization Technology | Enabled | Proxmox braucht das! |
| Hardware Prefetcher | Enabled | Performance |
| Adjacent Cache Line Prefetch | Enabled | Performance |
| AVX | Enabled | Performance |
| Active Efficient-cores | Enabled | N150 hat nur E-Cores |
| AES | Enabled | Verschlüsselung |
| MachineCheck | Enabled | Hardware-Fehler-Erkennung |
| CPU SMM Enhancement | Default | Firmware-intern, nicht anfassen |

> **Warum:** **C6DRAM** steuert den C6-Deep-Sleep-State, der die Kernel-
> Freezes verursacht. **MonitorMWait** steuert den MWAIT-Befehl, über den
> der Kernel tiefe C-States anfordert — deaktiviert = Kernel kann keine
> tiefen C-States mehr anfordern.
>
> BIOS-seitig deaktivieren ist die erste Verteidigungslinie, die Kernel-
> Parameter (`intel_idle.max_cstate=1`) sind die zweite. Beides zusammen
> gibt maximale Sicherheit.
>
> SpeedStep und Turbo Boost werden hier nicht angezeigt — sie sind auf
> diesem Board automatisch aktiv und steuern nur die Frequenz
> (800 MHz ↔ 3600 MHz), nicht die Schlafzustände.

#### 2. PCIe ASPM deaktivieren

**Pfad:** `Advanced` → `PCI Subsystem Settings`

| Einstellung | Aktuell | Empfohlen |
|-------------|---------|-----------|
| ASPM Support | Auto/L1 | **Disabled** |
| L1 Substates | Enabled | **Disabled** |

> **Warum:** ASPM (Active State Power Management) kann NVMe-SSDs und
> Netzwerkkarten einfrieren. Auf einem Proxmox-Server gibt es keinen
> Grund für PCIe-Stromsparen.

#### 3. USB-Stromsparen deaktivieren

**Pfad:** `Advanced` → `USB Configuration`

| Einstellung | Aktuell | Empfohlen |
|-------------|---------|-----------|
| USB Selective Suspend | Enabled | **Disabled** |
| XHCI Power Management | Enabled | **Disabled** |

> **Warum:** Verhindert, dass USB-Geräte (Tastatur für Notfall-Recovery)
> aus dem Schlaf nicht aufwachen.

#### 4. ACPI Sleep & Wake-on-LAN

**Pfad:** `Advanced` → `ACPI Settings`

| Einstellung | Aktuell | Empfohlen |
|-------------|---------|-----------|
| Enable ACPI Auto Configuration | Disabled ✅ | Lassen |
| Enable Hibernation | Disabled ✅ | Lassen |
| **ACPI Sleep State** | Suspend… | **→ Disabled** |
| S5 Resume By RTC | Disabled | Lassen |
| **Resume By Onboard LAN** | Disabled | **→ Enabled** |
| I226 LAN PXE Boot Support | Disabled | Lassen |

> **Warum:**
> - **ACPI Sleep State → Disabled** = Ein Proxmox-Server darf nie in den
>   Suspend/Sleep gehen. Das kann zu Freeze-ähnlichem Verhalten führen
>   und VMs in einen undefinierten Zustand bringen.
> - **Resume By Onboard LAN → Enabled** = Wake-on-LAN! Damit kannst du
>   den Mini-PC remote starten (z.B. über Fritz!Box-App, Handy-WoL-App
>   oder von einem anderen Rechner mit `wakeonlan` / `etherwake`).

**Nicht ändern:**

| Einstellung | Warum lassen |
|-------------|-------------|
| ACPI Auto Configuration = Disabled | Standard, nicht nötig |
| Hibernation = Disabled | Server soll nie hibernieren |
| S5 Resume By RTC = Disabled | Nicht benötigt (nur für Zeitgesteuertes Aufwachen) |
| PXE Boot = Disabled | Nicht benötigt (kein Netzwerk-Boot) |

#### 5. Stromausfall-Verhalten (bereits korrekt!)

**Pfad:** `Advanced` (Hauptmenü)

| Einstellung | Aktuell | Status |
|-------------|---------|--------|
| **PWRON After Power Loss** | **Always On** ✅ | **Bereits korrekt!** |

> Perfekt — der Mini-PC startet automatisch nach Stromausfall.
> Diese Einstellung war bereits richtig gesetzt.

#### 5. Boot-Einstellungen

**Pfad:** `Boot`

| Einstellung | Empfohlen |
|-------------|-----------|
| Boot Mode | **UEFI** |
| Secure Boot | **Disabled** (für Proxmox) |
| Fast Boot | **Disabled** |
| Quiet Boot | **Disabled** |
| Restore on AC Power Loss | **Power On** |

> **Warum:**
> - **Fast Boot Disabled** = Das BIOS überspringt die POST-Phase nicht,
>   sodass man per `DEL`/`F2` ins BIOS kommt. **Das betrifft NUR das
>   BIOS, nicht den Bootloader!**
> - **Quiet Boot Disabled** = POST-Meldungen sichtbar (Diagnose bei Problemen)
> - **Restore on AC Power Loss = Power On** = Nach Stromausfall startet
>   der Mini-PC automatisch → Proxmox + VMs laufen wieder
>
> ⚠️ **Wichtig: Der Boot-Ablauf ist vollautomatisch!**
>
> **systemd-boot (dein Setup, Stand 2026-04-17):**
> ```
> Stromausfall → Strom kommt zurück
>   → BIOS startet automatisch (AC Power Loss = Power On)
>     → BIOS POST-Phase (5-10 Sek, Fast Boot OFF = Tastatur erreichbar)
>       → systemd-boot → bootet gepinnten Kernel SOFORT (kein Menü!)
>         → Proxmox startet → VMs starten (wenn onboot=1)
> ```
> systemd-boot zeigt standardmäßig **kein Menü** — der gepinnte Kernel
> wird sofort gebootet. Für Notfall-Zugang: beim Booten `Space` oder
> `↓` gedrückt halten, um das Boot-Menü zu erzwingen.
>
> **GRUB (falls später umgestellt):**
> ```
> … → GRUB startet → Timeout (5 Sek) → bootet gepinnten Kernel automatisch
> ```
> GRUB zeigt kurz das Menü, bootet aber automatisch nach dem Timeout.

#### 5b. Boot-Timeout anpassen (optional)

**Für systemd-boot (dein Setup):**

systemd-boot hat keinen sichtbaren Timeout — es bootet sofort.
Falls du ein kurzes Menü möchtest (z.B. für Kernel-Auswahl):

```bash
# loader.conf erstellen/bearbeiten
nano /efi/loader/loader.conf
# oder je nach Mount:
nano /boot/efi/loader/loader.conf
```

Inhalt:
```
timeout 3
```

```bash
proxmox-boot-tool refresh
```

**Für GRUB (falls später umgestellt):**

```bash
# Auf 2 Sekunden setzen (Kompromiss: schnell, aber Notfall möglich)
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub
update-grub
```

> **Empfehlung:** Timeout bei systemd-boot auf **0 lassen** (sofort booten).
> Im Notfall `Space` beim Booten gedrückt halten für Kernel-Auswahl.

#### 6. Thermik prüfen

**Pfad:** `Advanced` → `Hardware Monitor` oder `H/W Monitor`

| Was prüfen | Erwartung |
|------------|-----------|
| CPU-Temperatur im Idle | 35–50°C |
| CPU-Temperatur unter Last | < 85°C |
| Lüfterprofil | **Normal** oder **Performance** |

> **Warum:** N150 Mini-PCs haben oft passive Kühlung oder Mini-Lüfter.
> Bei Überhitzung throttelt die CPU oder es kommt zu Instabilität.
> Falls die Temperaturen zu hoch sind: Wärmeleitpaste erneuern oder
> den Mini-PC besser belüften (nicht im geschlossenen Schrank).

### BIOS-Einstellungen: Zusammenfassung

Nach allen Änderungen `F4` drücken → "Save & Exit".

```
Pfad: Advanced → CPU Configuration
  ✅ C6DRAM:            DISABLED (verhindert C6-Deep-Sleep-Freezes)
  ✅ MonitorMWait:       DISABLED (verhindert MWAIT C-State-Anforderung)

Pfad: Advanced → PCI Subsystem Settings
  ✅ ASPM:               DISABLED (verhindert NVMe/NIC Freezes)

Pfad: Advanced → USB Configuration
  ✅ USB Selective:       DISABLED (Recovery-Tastatur zuverlässig)

Pfad: Advanced → ACPI Settings
  ✅ ACPI Sleep State:    DISABLED (Server darf nie schlafen)
  ✅ Resume By Onboard LAN: ENABLED (Wake-on-LAN für Remote-Start)

Pfad: Advanced (Hauptmenü)
  ✅ PWRON After Power Loss: ALWAYS ON (bereits korrekt gesetzt!)

Pfad: Boot
  ✅ Fast Boot:           DISABLED (POST erreichbar für Notfall)
  ✅ Quiet Boot:          DISABLED (POST-Meldungen sichtbar)
```

### BIOS-Update

Dein BIOS ist **v41.5 vom 15.12.2024**. Prüfe auf der Hersteller-Website
(vermutlich Beelink oder Topton/CWWK) ob ein neueres BIOS verfügbar ist.
BIOS-Updates können Microcode-Updates enthalten, die CPU-Bugs direkt fixen.

```bash
# Auf Proxmox: Intel Microcode ist aktuell (3.20250812.1) — gut!
# BIOS-Update nur über USB-Stick vom Hersteller
# NIEMALS ein BIOS-Update per Remote/SSH starten!
```

> ⚠️ **BIOS-Update nur mit physischem Zugang, USV/Akku und viel Vorsicht!**
> Ein fehlgeschlagenes BIOS-Update kann das Board zerstören.

---

## Sicheres Update/Upgrade-Verfahren

> **Ziel:** Sicherheitspatches und Proxmox-Management-Updates einspielen,
> ohne die Stabilität zu gefährden. Der gepinnte Kernel und ZFS bleiben
> unangetastet.

### Grundregeln

| Regel | Warum |
|-------|-------|
| **Kernel bleibt gepinnt** auf 6.8.12-16-pve | Neuere Kernel (6.14, 6.17, 7.0) haben Freeze-Berichte auf N150 |
| **ZFS wird gehalten** (apt-mark hold) | ZFS 2.4.x hat Stabilitätsprobleme auf N100/N150 mit ZFS-Root gemeldet |
| **Kein Docker auf dem PVE-Host** | Docker-iptables blockieren VM-Bridge-Traffic (FORWARD DROP) |
| **Neue Kernel werden installiert, aber nicht gebootet** | Der Pin übersteuert `proxmox-default-kernel` |

### Vor dem Update: Prüfen

```bash
# 1. Aktueller Kernel + Pin-Status
uname -r
proxmox-boot-tool kernel list
# → Pinned kernel: 6.8.12-16-pve

# 2. ZFS-Hold aktiv?
apt-mark showhold
# Erwartet: libnvpair3linux, libuutil3linux, libzfs6linux,
#           zfs-initramfs, zfs-zed, zfsutils-linux

# 3. Falls ZFS-Hold fehlt — jetzt setzen!
apt-mark hold zfsutils-linux zfs-zed zfs-initramfs \
    libnvpair3linux libuutil3linux

# 4. Dry-Run — was wird gemacht?
apt update && apt -s dist-upgrade
# → Prüfe: "Not Upgrading: 5" (oder mehr) = ZFS-Pakete gehalten
# → Prüfe: Keine "REMOVING"-Zeile mit kritischen Paketen
```

### Update durchführen

```bash
# 5. Upgrade ausführen (ZFS bleibt gehalten)
apt dist-upgrade -y

# 6. Kernel-Pin verifizieren (KRITISCH vor Reboot!)
proxmox-boot-tool kernel list
# → MUSS zeigen: "Pinned kernel: 6.8.12-16-pve"
# → Falls Pin weg: NICHT rebooten! Erst re-pinnen:
#    proxmox-boot-tool kernel pin 6.8.12-16-pve

# 7. Bootloader aktualisieren (nach neuen Kernel-Installationen)
proxmox-boot-tool refresh

# 8. Reboot
reboot
```

### Nach dem Reboot: Verifizieren

```bash
# 9. Kernel + C-State + Version prüfen
uname -r                           # → 6.8.12-16-pve
cat /proc/cmdline | grep cstate    # → intel_idle.max_cstate=1 processor.max_cstate=1
pveversion -v | head -3            # → pve-manager: aktuelle Version

# 10. Alle Workloads gestartet?
qm list && pct list
# → Alle STATUS = running

# 11. Netzwerk OK?
ip link show vmbr0                 # → state UP
ping -c 1 192.168.178.1            # → Gateway erreichbar
```

### Was wird aktualisiert (Beispiele)

| Kategorie | Pakete | Risiko |
|-----------|--------|--------|
| **Debian-Sicherheit** | openssl, openssh, gnutls, libnss3, samba, sudo, libc6, gnupg | ✅ Kein Risiko |
| **Intel Microcode** | intel-microcode | ✅ Wichtig für N150-Stabilität! |
| **Proxmox-Management** | pve-manager, qemu-server, pve-container, pve-firewall | ✅ Point-Releases |
| **Ceph/Corosync** | ceph 19.2.3-pveX, corosync | ✅ Patch-Updates |
| **Neue Kernel (nur installiert)** | proxmox-kernel-7.0, 6.17, 6.14 | ⚠️ Werden NICHT gebootet (Pin!) |
| **ZFS** | zfsutils-linux, zfs-zed | 🛑 GEHALTEN — nicht upgraden |

### Alte Kernel aufräumen (optional, nach stabiler Uptime)

```bash
# Installierte Kernel anzeigen
dpkg -l | grep proxmox-kernel | grep -v helper

# Unnötige Kernel entfernen (NICHT den laufenden oder gepinnten!)
apt remove proxmox-kernel-6.14.11-4-pve-signed  # alter 6.14
apt remove proxmox-kernel-6.17.2-1-pve-signed   # alter 6.17
apt remove proxmox-kernel-6.8.12-4-pve-signed   # alter 6.8 Patch

# Bootloader aktualisieren
proxmox-boot-tool refresh
```

> **ACHTUNG:** Immer mindestens 2 Kernel behalten: den gepinnten
> (6.8.12-16-pve) + einen Fallback (z.B. 7.0.0-3-pve).

### Wann ZFS-Hold aufheben?

ZFS 2.4.x darf erst aktualisiert werden, wenn **alle drei** Bedingungen
erfüllt sind:

1. Proxmox-Forum bestätigt Stabilität auf N100/N150 mit ZFS-Root
2. Mindestens 2 Monate nach Release ohne gemeldete Probleme
3. **Vorher Backup:** `vzdump` aller VMs + `zpool status` + `zfs list`

```bash
# ZFS-Hold aufheben (NUR wenn sicher!)
apt-mark unhold zfsutils-linux zfs-zed zfs-initramfs \
    libnvpair3linux libuutil3linux
apt dist-upgrade -y
```

### Repo-Hygiene

Folgende Repos sollten auf dem PVE-Host aktiv sein:

| Repo | Datei | Status |
|------|-------|--------|
| Debian trixie (main, updates, security) | `/etc/apt/sources.list` | ✅ Aktiv |
| PVE No-Subscription | `pve-no-subscription.list` | ✅ Aktiv |
| Ceph Squid No-Subscription | `ceph.sources` | ✅ Aktiv |
| PVE Enterprise | `pve-enterprise.list` | ❌ Auskommentiert |
| Ceph Reef | `ceph.list` | ❌ Auskommentiert |
| **Docker** | — | 🚫 **ENTFERNT** — Docker gehört NUR in VMs/LXCs! |

---

## Quellen

- [Proxmox Forum: N100/N150 Freeze Reports](https://forum.proxmox.com/tags/n100/)
- [Proxmox Forum: Random host freeze after 60-80h (N150)](https://forum.proxmox.com/threads/random-host-freeze-after-60-80h-uptime-intel-n150.179084/)
- [Proxmox VE Kernel Dokumentation](https://pve.proxmox.com/wiki/Proxmox_VE_Kernel)
- [GitHub: N150 Passthrough Guide](https://github.com/patcfly/n150-passthrough)
- [Proxmox Kernel Changelog](https://github.com/proxmox/pve-kernel/blob/master/debian/changelog)

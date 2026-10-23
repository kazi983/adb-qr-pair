# adb-qr-pair

Pair an Android phone with your PC for **wireless debugging** by scanning a QR code in the terminal, the same way Android Studio does it, but from the command line. Works on **Ubuntu/Linux** and **Windows**.

It shows a QR code, waits for your phone to scan it, runs `adb pair`, then finds the phone's debug port and runs `adb connect`. When it finishes, the phone appears in `adb devices`.

```
█▀▀▀▀▀█ ▄▀▄ █▀▀▀▀▀█
█ ███ █ ▀█▄ █ ███ █      (QR code)
▀▀▀▀▀▀▀ ▀ ▀ ▀▀▀▀▀▀▀
PC Wi-Fi: MyHomeWiFi  (phone must be on the same network)
Scan with: Developer options > Wireless debugging > Pair device with QR code
Waiting for the phone…  27s  (Ctrl-C to cancel)
```

## Requirements

- **Phone:** Android 11 or newer
- PC and phone on the **same Wi-Fi network**
- **Linux:** Ubuntu (or another Linux with apt, Avahi and NetworkManager), adb 30.0.0 or newer (Ubuntu 24.04's `adb` package is fine)
- **Windows:** Windows 10 or 11, Windows PowerShell 5.1 (built in) or PowerShell 7.x, adb from platform-tools **35.0.2 or newer**

Both scripts check their requirements and tell you what's missing.

## Install

### Ubuntu / Linux

```bash
sudo apt install adb qrencode avahi-utils

mkdir -p ~/src ~/.local/bin
git clone https://github.com/kazi983/adb-qr-pair.git ~/src/adb-qr-pair
ln -s ~/src/adb-qr-pair/adb-qr-pair ~/.local/bin/adb-qr-pair
```

Open a new terminal. If `adb-qr-pair` isn't found, log out and back in once so `~/.local/bin` is added to your `PATH`.

To update later: `git -C ~/src/adb-qr-pair pull`

### Windows

In PowerShell:

```powershell
winget install Google.PlatformTools
winget install Git.Git          # skip if you already have Git

git clone https://github.com/kazi983/adb-qr-pair.git "$HOME\adb-qr-pair"

# Add the folder to your user PATH so "adb-qr-pair" works everywhere
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', "$userPath;$HOME\adb-qr-pair", 'User')
```

Open a new terminal afterwards so the new `PATH` takes effect.

No Git? Download the repo as a ZIP from GitHub (**Code → Download ZIP**), extract it, and add that folder to your `PATH` instead.

To update later: `git -C "$HOME\adb-qr-pair" pull`

## Usage

1. On the phone, go to **Settings → Developer options → Wireless debugging → Pair device with QR code**. Opening the scanner before you run the command saves time.
2. On the PC, run:

   ```
   adb-qr-pair
   ```

3. Scan the QR code. The rest happens automatically.

You get 30 seconds to scan, then another 30 seconds for the connect step. For more time:

```bash
ADB_QR_TIMEOUT=60 adb-qr-pair      # Linux
```

```powershell
adb-qr-pair -Timeout 60            # Windows
```

On Windows, `adb-qr-pair` runs `adb-qr-pair.cmd`, a small launcher that starts `adb-qr-pair.ps1` with the PowerShell script policy bypassed for that run only. Your system settings aren't changed. You can also run the script directly with `pwsh -File adb-qr-pair.ps1`.

## How it works

1. Generates a random service name and password and shows them as a QR code (`WIFI:T:ADB;S:<name>;P:<password>;;`).
2. After scanning, the phone announces a `_adb-tls-pairing._tcp` service on the local network (mDNS). The script waits for it.
3. Runs `adb pair <ip>:<port> <password>`.
4. Waits for the phone's `_adb-tls-connect._tcp` service and runs `adb connect <ip>:<port>`.

| | Linux | Windows |
| --- | --- | --- |
| Script | `adb-qr-pair` (Bash) | `adb-qr-pair.ps1` + `adb-qr-pair.cmd` |
| QR code | `qrencode` | Built-in encoder, nothing to install |
| mDNS discovery | `avahi-browse` | adb's built-in mDNS (`adb mdns services`) |
| Wi-Fi name | `nmcli` | `netsh wlan show interfaces` |

## Troubleshooting

**"Timed out: the phone's pairing service never appeared"**
- Check that the PC and phone are on the same Wi-Fi. The `PC Wi-Fi:` line shows which network the PC is on.
- Guest networks and routers with "AP / client isolation" block devices from seeing each other.
- Linux: a firewall may be dropping mDNS. Allow it with `sudo ufw allow 5353/udp`.
- Windows: set your Wi-Fi to a **Private** network (Settings → Network & internet → Wi-Fi → your network). If Windows Firewall asked about `adb.exe`, allow it on private networks.

**Windows: "PC Wi-Fi: not detected"**
You may be on a wired connection. Also, recent Windows 11 versions may hide the Wi-Fi name from command-line tools unless **Location** is turned on (Settings → Privacy & security → Location). This line is informational; pairing still works without it.

**"avahi-daemon is not running"** (Linux)

```bash
sudo systemctl enable --now avahi-daemon
```

**"Your adb is too old"**
- Linux: install a newer adb, or download Google's [SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) and put its `adb` first on your `PATH`.
- Windows: `winget upgrade Google.PlatformTools`

**Manual fallback (no QR, no mDNS)**
1. On the phone: **Wireless debugging → Pair device with pairing code**
2. On the PC: `adb pair <IP>:<PORT> <6-digit code>`
3. Then: `adb connect <IP>:<PORT>`, using the port shown on the main Wireless debugging screen

## Platform support

| Platform | Status |
| --- | --- |
| Ubuntu / Debian-based Linux | ✅ Supported |
| Windows 10 / 11 (PowerShell 5.1 or 7.x) | ✅ Supported |
| macOS | ❌ Not yet |

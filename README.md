# adb-qr-pair

Pair an Android phone with your Ubuntu PC for **wireless debugging** by scanning a QR code in the terminal, the same way Android Studio does it, but from the command line.

It shows a QR code, waits for your phone to scan it, runs `adb pair`, then finds the phone's debug port and runs `adb connect`. When it finishes, the phone appears in `adb devices`.

```
█▀▀▀▀▀█ ▄▀▄ █▀▀▀▀▀█
█ ███ █ ▀█▄ █ ███ █      (QR code)
▀▀▀▀▀▀▀ ▀ ▀ ▀▀▀▀▀▀▀
PC Wi-Fi: MyHomeWiFi  (phone must be on the same network)
Scan with: Developer options > Wireless debugging > Pair device with QR code
Waiting for the phone…  7s  (Ctrl-C to cancel)
```

## Requirements

- **PC:** Ubuntu (or another Linux with apt, Avahi and NetworkManager)
- **Phone:** Android 11 or newer
- **adb 30.0.0 or newer** (Ubuntu 24.04's `adb` package is fine; the script checks this for you)
- PC and phone on the **same Wi-Fi network**

## Install

```bash
sudo apt install adb qrencode avahi-utils

mkdir -p ~/src ~/.local/bin
git clone https://github.com/kazi983/adb-qr-pair.git ~/src/adb-qr-pair
ln -s ~/src/adb-qr-pair/adb-qr-pair ~/.local/bin/adb-qr-pair
```

Open a new terminal. If `adb-qr-pair` isn't found, log out and back in once so `~/.local/bin` is added to your `PATH`.

To update later:

```bash
git -C ~/src/adb-qr-pair pull
```

## Usage

1. On the phone, go to **Settings → Developer options → Wireless debugging → Pair device with QR code**. Open the scanner first, because the countdown is short.
2. On the PC, run:

   ```bash
   adb-qr-pair
   ```

3. Scan the QR code. The rest happens automatically.

You get 10 seconds to scan, then another 10 seconds for the connect step. For more time:

```bash
ADB_QR_TIMEOUT=30 adb-qr-pair
```

## How it works

1. Generates a random service name and password and shows them as a QR code (`WIFI:T:ADB;S:<name>;P:<password>;;`).
2. After scanning, the phone announces a `_adb-tls-pairing._tcp` service on the local network (mDNS). The script listens for it with `avahi-browse`.
3. Runs `adb pair <ip>:<port> <password>`.
4. Listens for the phone's `_adb-tls-connect._tcp` service and runs `adb connect <ip>:<port>`.

## Troubleshooting

**"Timed out: the phone's pairing service never appeared"**
- Check that the PC and phone are on the same Wi-Fi. The `PC Wi-Fi:` line shows which network the PC is on.
- Guest networks and routers with "AP / client isolation" block devices from seeing each other.
- A firewall may be dropping mDNS. Allow it with `sudo ufw allow 5353/udp`.

**"avahi-daemon is not running"**

```bash
sudo systemctl enable --now avahi-daemon
```

**"Your adb is too old"**
Install a newer adb, or download Google's [SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) and put its `adb` first on your `PATH`.

**Manual fallback (no QR, no mDNS)**
1. On the phone: **Wireless debugging → Pair device with pairing code**
2. On the PC: `adb pair <IP>:<PORT> <6-digit code>`
3. Then: `adb connect <IP>:<PORT>`, using the port shown on the main Wireless debugging screen

## Platform support

| Platform | Status |
| --- | --- |
| Ubuntu / Debian-based Linux | ✅ Supported |
| macOS | ❌ Not yet (needs a `dns-sd` version of discovery) |
| Windows | ❌ Not supported (WSL2 with mirrored networking might work, untested) |

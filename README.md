<div align="center">

# LatenciaTools

**A Fedora-native security toolkit installer — Kali's arsenal, done the Fedora way.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Fedora](https://img.shields.io/badge/Fedora-39%2B-51A2DA?logo=fedora&logoColor=white)](https://fedoraproject.org/)
[![Shell](https://img.shields.io/badge/Bash-shellcheck%20clean-4EAA25?logo=gnubash&logoColor=white)](https://www.shellcheck.net/)
[![Status](https://img.shields.io/badge/status-beta-orange.svg)](#project-status)
[![Version](https://img.shields.io/badge/version-2.1.3--beta-blue.svg)](#changelog)

*by [LatenciaTech](https://latenciatech.com) · tested on Fedora 44, July 2026*

</div>

---

> ⚠️ **FOR LEGAL USE ONLY.** This installer sets up offensive- and defensive-security tooling
> intended for **authorised** penetration testing, CTF practice, and security research on systems
> **you own or have explicit written permission to test**. Unauthorised access to systems you do
> not own is illegal in most jurisdictions. You are solely responsible for how you use these tools.

---

## What is this?

Most "install all the hacking tools" scripts out there are written for Kali/Debian and assume
`apt` and Debian package names. On Fedora those scripts fail silently: a large chunk of packages
simply don't exist under those names, and you end up thinking a tool is installed when it isn't.

**LatenciaTools** is a ground-up rewrite for Fedora. Instead of blindly throwing everything at
`dnf`, it routes each tool to the source where it *actually* lives:

- 🟢 **DNF / RPM Fusion** — native Fedora packages
- 🐍 **pipx** — isolated Python CLI apps (no PEP 668 headaches)
- 🐍 **pipx + legacy Python** — tools that break on Fedora's newest Python (auto-installs `python3.12`)
- 🧪 **shared venv** — Python *libraries* you import (pwntools/angr/capstone…)
- 🐹 **go install** — Go-based tools (gobuster, ffuf, nuclei, amass…)
- 💎 **gem** — Ruby tools (evil-winrm)
- 📦 **GitHub releases** — prebuilt binaries (pspy, gitleaks, ghidra, jadx, gophish)
- 📥 **git clone** — source-only tools (with honest "source downloaded, may need building" labels)

The guiding principle: **fail loudly, never fake success.** If a tool can't be installed, you see
a clear red line with the reason — not a green checkmark hiding a broken install.

## Highlights

- **15 categories** in familiar Kali menu order, plus *Install ALL*, *Top-10 essentials*, and an *Update all* pass.
- **Real Fedora gate** — refuses to run on non-Fedora or Fedora < 39 instead of half-breaking your repos.
- **Unattended mode** — *Install ALL* can auto-accept optional prompts for a hands-off run.
- **Safe by default** — never runs as root; asks before running Rapid7's Metasploit installer; validates every downloaded binary is a real ELF before installing.
- **Honest summary** — checks the *runnable command*, not the package name, so the report reflects reality.
- **`shellcheck`-clean**, `set -uo pipefail`, per-command error handling.

## Requirements

- **Fedora 39 or newer** (developed and tested on **Fedora 44**)
- `sudo` privileges
- Internet connection

Host dependencies (`curl wget git unzip tar file jq`) and build toolchains (Go, Ruby, pipx,
`gcc/cmake/rust`, etc.) are installed automatically **on demand** — only when a category needs them.

## Installation

```bash
git clone https://github.com/picaro10/latenciatools.git
cd latenciatools
chmod +x latenciatools.sh
./latenciatools.sh
```

> Do **not** run with `sudo`. The script runs as your normal user and calls `sudo` itself only
> where root is actually required.

Make sure `~/.local/bin` and `~/go/bin` are on your `PATH` (the script adds them for the current
run; add them to your shell profile to keep tools available in new terminals):

```bash
echo 'export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"' >> ~/.bashrc
```

## Usage

Run `./latenciatools.sh` and pick from the menu:

```
   1) Information Gathering    2) Vulnerability Analysis
   3) Web Application          4) Exploitation
   5) Post Exploitation        6) Password Attacks
   7) Wireless Attacks         8) Sniffing & Spoofing
   9) Digital Forensics       10) Reverse Engineering
  11) Network Attacks         12) Social Engineering
  13) CTF & Binary Exploit    14) Cloud & Container Sec.
  15) Anonymity & Anti-Forensics

  16) Install ALL     17) Top-10 essentials     18) Setup Repos
  19) Update all      20) Show summary          0) Exit
```

- **Tools install to:** `~/LatenciaTools/`
- **Logs write to:** `~/latenciatools_log_<timestamp>.txt`
- **Binaries/wrappers land in:** `~/.local/bin/` (and `~/go/bin/` for Go tools)

### Install everything unattended

Pick `16`, answer `y` to the full-install prompt, then `y` to unattended mode. It will auto-accept
the optional prompts (OWASP ZAP, SecLists ~1 GB, kube/Trivy vendor repos, OnionShare, and running
Rapid7's Metasploit installer as root) and run start-to-finish without stopping.

## What gets installed, and from where

A representative sample (not exhaustive — see the script for the full list):

| Category | Native (dnf) | pipx / venv | go / gem | releases / git |
|---|---|---|---|---|
| Info Gathering | nmap, arp-scan, whatweb… | wafw00f, dnsrecon, theHarvester¹ | gobuster, ffuf, amass, subfinder | EyeWitness, recon-ng, spiderfoot |
| Vuln Analysis | lynis, sslscan, openscap | sslyze, commix, wapiti3¹ | nuclei | nikto*, sqlmap* |
| Web App | whatweb… | dirsearch, arjun | gobuster, ffuf, httpx | ParamSpider, XSStrike |
| Exploitation | radare2, gdb, pwntools | — | — | Metasploit², Veil, exploitdb |
| Post Exploitation | python3-ldap3 | impacket, pypykatz, netexec¹ | evil-winrm (gem) | PEASS-ng, pspy |
| Password | hashcat, john, hydra, medusa | hashid, name-that-hash | — | rockyou, SecLists |
| Wireless | aircrack-ng, kismet, reaver… | — | bettercap³ | wifite2 |
| Sniffing | wireshark, ettercap, dsniff… | mitmproxy | bettercap³ | Responder |
| Forensics | sleuthkit, foremost, yara… | volatility3 | — | bulk_extractor, stegseek⁴ |
| Reverse Eng | radare2, valgrind, upx… | frida-tools, ropper¹ | — | Ghidra, jadx, pwndbg |
| Network | proxychains-ng, socat, iodine… | impacket, netexec¹ | chisel, ligolo-ng | Coercer |
| Social Eng | — | pyinstaller | — | SET, gophish, evilginx2 |
| CTF | qemu, z3, gmpy2… | angr, capstone, keystone, unicorn (venv) | — | pwndbg |
| Cloud/Containers | podman, skopeo, awscli | pacu, prowler¹, checkov, detect-secrets | kube-bench, gitleaks | kubectl, trivy |
| Anonymity | tor, proxychains, mat2… | — | — | — |

<sub>`*` clone + wrapper into `~/.local/bin` · `¹` installed via pipx pinned to `python3.12` · `²` official Rapid7 installer (asks first) · `³` Go build with libpcap/libusb/libnetfilter_queue · `⁴` clone + source build</sub>

## Project status

**Beta.** Every category has been run end-to-end on a real Fedora 44 machine (July 2026) and the
installer completes without aborting. The mechanics (dnf/pipx/venv/go/gem/release/git routing,
downloads, validation, summary) are solid and verified.

This is shared so people running Fedora don't have to fight Kali-oriented scripts. Feedback,
issues, and PRs — especially package-mapping corrections for other Fedora versions — are very welcome.

## Known limitations

Honesty over green checkmarks. As of the last verified run:

- **`dnschef`** uses `ast.Str`, removed in Python 3.12+, so it won't run on Fedora's Python. It's
  cloned to `~/LatenciaTools/dnschef`; run it under Python 3.9/3.10 or patch `dnschef.py`.
- **COPR / manual tools** are intentionally *not* auto-installed (the script prints how to get them):
  `masscan`, `crunch`, `fcrackzip`, `netdiscover`, `nbtscan`, `ike-scan`, `hcxdumptool`,
  `scalpel`, `apktool`, `maltego`, `veracrypt`. Many live in COPR repos whose availability varies
  by Fedora release, so they're left as clearly-labelled manual steps rather than fragile guesses.
- **`dnsenum`** is Perl and not in Fedora; `dnsrecon` + `fierce` cover the same ground.
- **`wfuzz` / `dirb`** are abandoned/superseded → use `ffuf` / `gobuster` (both installed).
- **GitHub release asset patterns** (pspy, gitleaks, ghidra, jadx, gophish) are validated at
  download time; if an upstream renames an asset, you'll get a clear error rather than a bad install.
- Package availability is verified against **Fedora 44**. On other releases some `dnf` names may
  differ — the summary will show exactly what didn't resolve.

## Safety notes

- Runs as a normal user; uses `sudo` only where required.
- **Metasploit** is installed via Rapid7's official script, which runs as root — the installer
  **asks for confirmation first** (even in unattended mode you opt into this explicitly).
- Downloaded binaries are checked to be genuine ELF files before being placed on your `PATH`.
- Full checksum/signature verification is **not** performed for every upstream (many don't publish
  checksums uniformly). Review the source before running if that matters to you.

## Contributing

1. Open an issue with your Fedora version and the relevant lines from your
   `~/latenciatools_log_*.txt` (redact anything sensitive).
2. For package-mapping fixes, tell us the tool, the correct Fedora source (dnf/copr/pipx/go/gem),
   and how you verified it.
3. Keep it `shellcheck`-clean (`shellcheck -S warning latenciatools.sh`).

## Changelog

- **2.1.3-beta** — build deps add `rust`, `libcurl-devel`, `openssl-devel`, `libffi-devel`;
  `wapiti` → `wapiti3`; `dnschef` moved to clone + note (Python 3.12 incompatible).
- **2.1.2-beta** — Rust toolchain added for netexec/aardwolf.
- **2.1.1-beta** — Fedora-44 package reclassification from first real run; `bettercap` C-deps,
  `gitleaks` via release, `sqlmap`/`nikto` via clone+wrapper, legacy-Python pipx path, build-deps bootstrap.
- **2.1.0-beta** — code-review hardening: real Fedora gate, wrapped gophish, unattended Install ALL,
  Metasploit confirmation, safer downloads.
- **2.0** — full Fedora-native rewrite with multi-source installer model.

## License

[MIT](./LICENSE) © 2026 LatenciaTech

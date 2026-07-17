#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  LatenciaTools — Security Toolkit Installer for Fedora  ·  by LatenciaTech ║
# ║  Version: 2.1.3-beta  (Fedora-native rewrite)                              ║
# ║  Requires: Fedora 39+ · DNF · sudo                                         ║
# ║  FOR LEGAL USE ONLY — authorised pentest / CTF / security research         ║
# ╚══════════════════════════════════════════════════════════════════════════╝

# -u : unset vars are errors   -o pipefail : catch failures in pipes
# NOTE: '-e' is intentionally NOT set. This is a long interactive installer;
#       a single non-fatal failure (a missing pkg, a slow makecache) must NOT
#       kill the whole session. Failures are handled per-command instead.
#
# SC2024: every `sudo … &>>"$LOG_FILE"` below redirects to a user-owned log in
#         $HOME (never a root-only path), so the "sudo doesn't affect redirects"
#         warning does not apply here. Silence it file-wide to stay shellcheck-clean.
# shellcheck disable=SC2024
set -uo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────────────────
TOOLS_DIR="$HOME/LatenciaTools"
VENV_DIR="$TOOLS_DIR/.venv"                 # shared venv for python *libraries*
LOG_FILE="$HOME/latenciatools_log_$(date +%Y%m%d_%H%M%S).txt"

FEDORA_VER="$(rpm -E %fedora 2>/dev/null || echo 0)"

# ─── sudo keepalive ───────────────────────────────────────────────────────────
_sudo_keepalive() {
    while true; do sudo -n true; sleep 55; done 2>/dev/null &
    _SUDO_KA_PID=$!
    trap 'kill "$_SUDO_KA_PID" 2>/dev/null; tput cnorm 2>/dev/null || true' EXIT
}

# ─── Spinner (never aborts the caller: returns the child's exit code) ─────────
run_with_spinner() {
    local label="$1"; shift
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0 rc=0
    PYTHONUNBUFFERED=1 "$@" >> "$LOG_FILE" 2>&1 &
    local cmd_pid=$!
    tput civis 2>/dev/null || true
    while kill -0 "$cmd_pid" 2>/dev/null; do
        local char="${spin_chars:$(( i % ${#spin_chars} )):1}"
        printf "  ${CYAN}%s${NC} %s\r" "$char" "$label"
        sleep 0.1
        (( i++ )) || true
    done
    tput cnorm 2>/dev/null || true
    printf "  %-70s\r" ""
    wait "$cmd_pid" || rc=$?
    return "$rc"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
_ok()     { echo -e "${GREEN}  ✓${NC} $*"; }
_warn()   { echo -e "${YELLOW}  !${NC} $*"; }
_err()    { echo -e "${RED}  ✗${NC} $*"; }
_info()   { echo -e "${CYAN}  ›${NC} $*"; }
_header() { echo -e "\n${RED}━━  $*  ━━${NC}\n"; }
_sep()    { echo -e "  ${CYAN}──────────────────────────────────────────────${NC}"; }
_manual() { echo -e "  ${WHITE}$*${NC}"; }

log()           { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }
check_command() { command -v "$1" &>/dev/null; }
ASSUME_YES=0
confirm_action() {
    [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
    local r; read -rp "  $1 [y/N]: " r; [[ "$r" =~ ^[Yy]([Ee][Ss])?$ ]];
}

# =============================================================================
# TOOLCHAIN BOOTSTRAP (installed on demand, only once)
# =============================================================================
_ensure_pipx() {
    check_command pipx && return 0
    _info "Installing pipx (Python app manager)…"
    sudo dnf install -y pipx &>>"$LOG_FILE" && pipx ensurepath &>>"$LOG_FILE"
    check_command pipx || { export PATH="$HOME/.local/bin:$PATH"; check_command pipx; }
}

_ensure_go() {
    check_command go && return 0
    _info "Installing Go toolchain…"
    sudo dnf install -y golang &>>"$LOG_FILE"
    check_command go
}

# Build toolchain for compiling Python wheels (unicorn, filebytes…) and sources.
# Includes Rust (aardwolf via netexec, cryptography…) and common -devel headers:
# libcurl-devel (pycurl → theHarvester), openssl/libffi (crypto wheels).
_BUILD_DEPS_DONE=0
_ensure_build_deps() {
    [[ "$_BUILD_DEPS_DONE" == "1" ]] && return 0
    _info "Installing build deps (gcc/cmake/rust/headers)…"
    sudo dnf install -y gcc gcc-c++ make cmake python3-devel pkgconf-pkg-config \
        rust cargo libcurl-devel openssl-devel libffi-devel &>>"$LOG_FILE"
    _BUILD_DEPS_DONE=1
}

# Legacy Python CLI apps that break on Fedora's newest Python (ast.Str removed in
# 3.12). Install an older interpreter and pin pipx to it.
_LEGACY_PY=""
_ensure_legacy_python() {
    [[ -n "$_LEGACY_PY" ]] && return 0
    local v
    for v in python3.12 python3.11; do
        if check_command "$v" || sudo dnf install -y "$v" &>>"$LOG_FILE"; then
            _LEGACY_PY="$v"; return 0
        fi
    done
    return 1
}

# $1 category ; rest = specs (name | name::pipspec, pipspec may be git+URL)
_pipx_legacy() {
    local category="$1"; shift
    _ensure_pipx || { _err "pipx unavailable"; return; }
    _ensure_legacy_python || { _warn "No legacy Python (3.11/3.12) available — skipping ${category}"; return; }
    _ensure_build_deps
    _info "pipx (${_LEGACY_PY}) · ${category}"; echo ""
    local spec name pipspec
    for spec in "$@"; do
        name="${spec%%::*}"
        [[ "$spec" == *"::"* ]] && pipspec="${spec##*::}" || pipspec="$name"
        if pipx list --short 2>/dev/null | grep -qi "^${name} "; then
            echo -e "  ${YELLOW}already (pipx):${NC} $name"
        elif pipx install --python "$_LEGACY_PY" "$pipspec" &>>"$LOG_FILE"; then
            echo -e "  ${GREEN}✓ (pipx ${_LEGACY_PY})${NC} $name"
        else
            echo -e "  ${RED}✗ (pipx ${_LEGACY_PY})${NC} $name"
        fi
    done
}

_ensure_gem() {
    if ! check_command gem; then
        _info "Installing Ruby (for gem-based tools)…"
        sudo dnf install -y ruby ruby-devel rubygems @development-tools &>>"$LOG_FILE" || return 1
    fi
    # Gems installed with --user-install land in Gem.user_dir/bin, which is NOT
    # on PATH by default → the tool installs but isn't runnable. Add it always.
    local gem_bin
    gem_bin="$(ruby -r rubygems -e 'puts Gem.user_dir' 2>/dev/null)/bin"
    case ":$PATH:" in *":$gem_bin:"*) ;; *) [[ -n "$gem_bin" ]] && export PATH="$gem_bin:$PATH" ;; esac
    check_command gem
}

# gem batch — Ruby tools (user-install, no root).
_gem() {
    local category="$1"; shift
    _ensure_gem || { _err "gem unavailable — skipping ${category} ruby tools"; return; }
    _info "gem · ${category}"; echo ""
    for g in "$@"; do
        if gem list -i "$g" &>/dev/null; then
            echo -e "  ${YELLOW}already (gem):${NC} $g"
        elif run_with_spinner "installing $g" gem install --user-install "$g"; then
            check_command "$g" \
                && echo -e "  ${GREEN}✓ (gem)${NC} $g" \
                || echo -e "  ${YELLOW}✓ (gem, not on PATH):${NC} $g"
        else
            echo -e "  ${RED}✗ (gem)${NC} $g"
        fi
    done
}

_ensure_venv() {
    [[ -d "$VENV_DIR" ]] && return 0
    _info "Creating shared Python venv for CTF/RE libraries → $VENV_DIR"
    python3 -m venv "$VENV_DIR" &>>"$LOG_FILE" \
        && "$VENV_DIR/bin/pip" install --upgrade pip &>>"$LOG_FILE"
}

# =============================================================================
# MULTI-SOURCE INSTALLERS
# =============================================================================

# DNF batch — only real Fedora / RPM Fusion package names go here.
_dnf() {
    local category="$1"; shift
    local pkgs=("$@") installed=0 failed=0 skipped=0 name
    _info "DNF · ${category} (${#pkgs[@]} pkgs)"; echo ""
    for name in "${pkgs[@]}"; do
        if rpm -q "$name" &>/dev/null || check_command "$name" 2>/dev/null; then
            echo -e "  ${YELLOW}already:${NC} $name"; ((skipped++)) || true
        elif sudo dnf install -y "$name" &>>"$LOG_FILE"; then
            echo -e "  ${GREEN}✓${NC} $name"; ((installed++)) || true
        else
            echo -e "  ${RED}✗${NC} $name ${RED}(not in Fedora repos)${NC}"; ((failed++)) || true
        fi
    done
    echo ""; _sep
    echo -e "  ${GREEN}Installed: $installed${NC}  ${YELLOW}Present: $skipped${NC}  ${RED}Failed: $failed${NC}"
    _sep
    log "$category(dnf): installed=$installed skipped=$skipped failed=$failed"
}

# pipx batch — standalone Python CLI apps (isolated envs, no PEP668 problems).
_pipx() {
    local category="$1"; shift
    _ensure_pipx || { _err "pipx unavailable — skipping ${category} python apps"; return; }
    _info "pipx · ${category}"; echo ""
    local spec name
    for spec in "$@"; do
        name="${spec%%::*}"                        # allow name::pip-name
        [[ "$spec" == *"::"* ]] && spec="${spec##*::}" || spec="$name"
        if pipx list --short 2>/dev/null | grep -qi "^${name} "; then
            echo -e "  ${YELLOW}already (pipx):${NC} $name"
        elif pipx install "$spec" &>>"$LOG_FILE"; then
            echo -e "  ${GREEN}✓ (pipx)${NC} $name"
        else
            echo -e "  ${RED}✗ (pipx)${NC} $name"
        fi
    done
}

# venv/pip batch — Python *libraries* you import (pwntools, angr, capstone…).
_pylib() {
    local category="$1"; shift
    _ensure_venv || { _err "venv unavailable — skipping ${category} libs"; return; }
    _ensure_build_deps    # unicorn/keystone/filebytes compile wheels → need gcc/cmake
    _info "venv · ${category}  (import via: source $VENV_DIR/bin/activate)"; echo ""
    for lib in "$@"; do
        if "$VENV_DIR/bin/pip" install "$lib" &>>"$LOG_FILE"; then
            echo -e "  ${GREEN}✓ (venv)${NC} $lib"
        else
            echo -e "  ${RED}✗ (venv)${NC} $lib"
        fi
    done
}

# go install batch — symlinks land in ~/go/bin (added to PATH at bootstrap).
# Derive the real installed binary name from a Go module path.
# Handles trailing '/...' and version dirs '/v2','/v3','/v8':
#   github.com/OJ/gobuster/v3@latest        -> gobuster
#   github.com/owasp-amass/amass/v4/...@... -> amass
#   github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest -> nuclei
_go_binname() {
    local p="${1%@*}"        # strip @version
    p="${p%/...}"            # strip trailing /...
    local b; b="$(basename "$p")"
    [[ "$b" =~ ^v[0-9]+$ ]] && b="$(basename "$(dirname "$p")")"
    printf '%s' "$b"
}

_go() {
    local category="$1"; shift
    _ensure_go || { _err "Go unavailable — skipping ${category} go tools"; return; }
    _info "go install · ${category}"; echo ""
    local mod bin
    for mod in "$@"; do
        bin="$(_go_binname "$mod")"
        if check_command "$bin"; then
            echo -e "  ${YELLOW}already (go):${NC} $bin"
        elif run_with_spinner "building $bin" go install "$mod"; then
            echo -e "  ${GREEN}✓ (go)${NC} $bin"
        else
            echo -e "  ${RED}✗ (go)${NC} $bin"
        fi
    done
}

# git clone/pull helper
_clone_tool() {
    local name="$1" url="$2" dest="$TOOLS_DIR/$1"
    if [[ -d "$dest/.git" ]]; then
        _info "Updating: $name"
        git -C "$dest" pull --ff-only --quiet 2>>"$LOG_FILE" && _ok "$name source updated." || _warn "$name pull skipped."
    else
        _info "Cloning: $name"
        git clone --depth=1 "$url" "$dest" &>>"$LOG_FILE" && _ok "$name source downloaded → $dest" || _err "$name clone failed."
    fi
}

# Hardened download: fails on HTTP errors, retries, rejects HTML error pages.
_download() {
    local url="$1" dest="$2" mt
    curl -fL --retry 3 --connect-timeout 15 -o "$dest" "$url" 2>>"$LOG_FILE" \
        || { _err "download failed (HTTP error): $url"; return 1; }
    mt=$(file -b --mime-type "$dest" 2>/dev/null || echo "")
    case "$mt" in
        text/html|application/xhtml+xml)
            _err "got an HTML page instead of a file (bad URL / rate-limit)."; return 1 ;;
    esac
    return 0
}

# Resolve ONE asset download URL from a GitHub 'latest' release.
# Uses jq when present (and surfaces API errors / rate limits); grep fallback otherwise.
# $1 owner/repo   $2 asset-name ERE (be arch-specific: x86_64 / amd64 / 64bit)
_gh_latest_asset() {
    local repo="$1" pat="$2" json err
    json=$(curl -fsSL --retry 3 --connect-timeout 15 \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$repo/releases/latest" 2>>"$LOG_FILE") \
        || { log "GitHub API request failed for $repo"; return 1; }
    if check_command jq; then
        err=$(printf '%s' "$json" | jq -r '.message // empty' 2>/dev/null)
        [[ -n "$err" ]] && { log "GitHub API ($repo): $err"; return 1; }   # rate limit / not found
        printf '%s' "$json" | jq -r --arg p "$pat" \
            '.assets[] | select(.name|test($p)) | .browser_download_url' 2>/dev/null | head -1
    else
        printf '%s' "$json" | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' \
            | cut -d'"' -f4 | grep -E "$pat" | head -1
    fi
}

# Install a SINGLE self-contained binary from a GitHub release.
# No blind "first executable" fallback: if the exact binary isn't found, it FAILS.
# $1 owner/repo   $2 target binary name   $3 asset-name ERE
# The asset may be a raw binary (no extension), a .zip, or a .tar.*.
_release_bin() {
    local repo="$1" bin="$2" pat="$3"
    check_command "$bin" && { _warn "$bin already installed."; return; }
    local url; url=$(_gh_latest_asset "$repo" "$pat") \
        || { _warn "$bin: GitHub API error — install manually from https://github.com/$repo/releases"; return; }
    [[ -z "$url" ]] && { _warn "$bin: no asset matched /$pat/ (check arch/name)."; return; }
    _info "Downloading $bin from $repo…"
    local tmp found=""; tmp="$(mktemp -d)"
    if _download "$url" "$tmp/pkg"; then
        case "$url" in
            *.zip)
                if ! unzip -qo "$tmp/pkg" -d "$tmp/x" 2>>"$LOG_FILE"; then
                    _err "$bin: invalid or corrupted ZIP archive."; rm -rf "$tmp"; return 1; fi
                found=$(find "$tmp/x" -type f -name "$bin" | head -1) ;;
            *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar)
                mkdir -p "$tmp/x"
                if ! tar -xf "$tmp/pkg" -C "$tmp/x" 2>>"$LOG_FILE"; then
                    _err "$bin: invalid or corrupted tar archive."; rm -rf "$tmp"; return 1; fi
                found=$(find "$tmp/x" -type f -name "$bin" | head -1) ;;
            *)  found="$tmp/pkg" ;;   # raw binary asset (e.g. pspy64)
        esac
        if [[ -z "$found" || ! -f "$found" ]]; then
            _err "$bin: expected binary not found in asset — NOT installing a random file."
            rm -rf "$tmp"; return 1
        fi
        # Accept any real ELF (executable, PIE, or static). Deliberately NOT a
        # mime-type whitelist: Go PIE binaries often report as x-sharedlib and
        # would be wrongly rejected. 'ELF' in `file` output is the robust marker.
        if ! file -b "$found" 2>/dev/null | grep -q 'ELF'; then
            _err "$bin: resolved file is not an ELF binary — aborting."
            rm -rf "$tmp"; return 1
        fi
        install -Dm755 "$found" "$HOME/.local/bin/$bin" && _ok "$bin → ~/.local/bin/$bin"
    fi
    rm -rf "$tmp"
}

# Full-archive app installer (for tools that need their sibling files, e.g. gophish
# needs static/ templates/ config.json next to the binary).
install_gophish() {
    check_command gophish && { _warn "gophish already installed."; return; }
    local url; url=$(_gh_latest_asset "gophish/gophish" 'linux-64bit\.zip$') \
        || { _warn "gophish: GitHub API error — install manually."; return; }
    [[ -z "$url" ]] && { _warn "gophish: no linux-64bit asset found."; return; }
    _info "Downloading gophish (full package)…"
    local tmp dir; tmp="$(mktemp -d)"; dir="$TOOLS_DIR/gophish"
    if _download "$url" "$tmp/g.zip"; then
        mkdir -p "$dir"
        if unzip -qo "$tmp/g.zip" -d "$dir" 2>>"$LOG_FILE" && [[ -f "$dir/gophish" ]]; then
            chmod +x "$dir/gophish"
            # Wrapper (not a symlink): gophish resolves static/ templates/ from CWD,
            # so we cd into its dir first. Makes `gophish` work from anywhere.
            cat > "$HOME/.local/bin/gophish" <<EOF
#!/usr/bin/env bash
cd "$dir" || exit 1
exec ./gophish "\$@"
EOF
            chmod +x "$HOME/.local/bin/gophish"
            _ok "gophish → $dir (wrapper en ~/.local/bin/gophish; funciona desde cualquier dir)"
        else
            _err "gophish: extracción incompleta (falta el binario)."
        fi
    fi
    rm -rf "$tmp"
}

# bettercap: Go build needs C libs (libpcap/libusb/libnetfilter_queue).
install_bettercap() {
    check_command bettercap && { _warn "bettercap already installed."; return; }
    _ensure_go || { _err "Go unavailable — skipping bettercap"; return; }
    _info "Installing bettercap build deps…"
    sudo dnf install -y libpcap-devel libusb1-devel libnetfilter_queue-devel pkgconf-pkg-config &>>"$LOG_FILE"
    if run_with_spinner "building bettercap" go install github.com/bettercap/bettercap@latest; then
        _ok "bettercap → ~/go/bin/bettercap"
    else
        _err "bettercap build failed — check $LOG_FILE"
    fi
}

# sqlmap: not packaged in Fedora → clone + wrapper (it's a python app run in place).
install_sqlmap() {
    check_command sqlmap && { _warn "sqlmap already installed."; return; }
    _clone_tool "sqlmap" "https://github.com/sqlmapproject/sqlmap.git"
    if [[ -f "$TOOLS_DIR/sqlmap/sqlmap.py" ]]; then
        printf '#!/usr/bin/env bash\nexec python3 "%s/sqlmap/sqlmap.py" "$@"\n' "$TOOLS_DIR" > "$HOME/.local/bin/sqlmap"
        chmod +x "$HOME/.local/bin/sqlmap"
        _ok "sqlmap → wrapper en ~/.local/bin/sqlmap"
    fi
}

# nikto: Perl app, not in Fedora → clone + wrapper to program/nikto.pl.
install_nikto() {
    check_command nikto && { _warn "nikto already installed."; return; }
    _clone_tool "nikto" "https://github.com/sullo/nikto.git"
    if [[ -f "$TOOLS_DIR/nikto/program/nikto.pl" ]]; then
        printf '#!/usr/bin/env bash\nexec perl "%s/nikto/program/nikto.pl" "$@"\n' "$TOOLS_DIR" > "$HOME/.local/bin/nikto"
        chmod +x "$HOME/.local/bin/nikto"
        _ok "nikto → wrapper en ~/.local/bin/nikto"
    fi
}

# ─── Repository setup ─────────────────────────────────────────────────────────
setup_repos() {
    _header "Setting Up Repositories"
    if ! rpm -q rpmfusion-free-release &>/dev/null; then
        run_with_spinner "RPM Fusion Free" sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
            && _ok "RPM Fusion Free enabled." || _warn "RPM Fusion Free failed."
    else _warn "RPM Fusion Free already enabled."; fi

    if ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
        run_with_spinner "RPM Fusion Non-Free" sudo dnf install -y \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" \
            && _ok "RPM Fusion Non-Free enabled." || _warn "RPM Fusion Non-Free failed."
    else _warn "RPM Fusion Non-Free already enabled."; fi

    run_with_spinner "DNF refresh" sudo dnf makecache && _ok "Repositories ready." || _warn "makecache had warnings."
}

# =============================================================================
# CATEGORY FUNCTIONS  (Kali menu order)
# =============================================================================

# ── 1. Information Gathering ──────────────────────────────────────────────────
cat_information_gathering() {
    _header "Information Gathering"
    echo -e "  ${CYAN}Network recon · DNS · OSINT · port scanning · fingerprinting${NC}\n"
    _dnf "Info Gathering" \
        nmap arp-scan fping hping3 whois bind-utils \
        smbclient onesixtyone p0f whatweb
    _pipx "Info Gathering" wafw00f dnsrecon fierce shodan "sublist3r::sublist3r"
    _pipx_legacy "Info Gathering (legacy py)" theHarvester
    _go "Info Gathering" \
        github.com/OJ/gobuster/v3@latest \
        github.com/ffuf/ffuf/v2@latest \
        github.com/owasp-amass/amass/v4/...@master \
        github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
    _clone_tool "EyeWitness" "https://github.com/RedSiege/EyeWitness.git"
    _clone_tool "recon-ng"   "https://github.com/lanmaster53/recon-ng.git"
    _clone_tool "spiderfoot" "https://github.com/smicallef/spiderfoot.git"
    _info "recon-ng/spiderfoot: instala sus requirements en un venv (rompen con Python del sistema)."
    _info "netdiscover/nbtscan/dnsenum no están en Fedora (dnsenum es Perl). dnsrecon+fierce cubren DNS."
    _manual "masscan → 'sudo dnf copr enable'; maltego → descarga oficial."
}

# ── 2. Vulnerability Analysis ─────────────────────────────────────────────────
cat_vulnerability_analysis() {
    _header "Vulnerability Analysis"
    echo -e "  ${CYAN}Scanners · fuzzers · CVE detection · config auditing${NC}\n"
    _dnf "Vuln Analysis" \
        lynis checksec binwalk sslscan \
        openscap-scanner scap-security-guide python3-pip
    install_nikto; install_sqlmap
    _pipx "Vuln Analysis" sslyze commix
    _pipx_legacy "Vuln Analysis (legacy py)" "wapiti::wapiti3"
    _go  "Vuln Analysis" github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
    echo ""; _info "OpenVAS/GVM: ${WHITE}sudo dnf install gvm && sudo gvm-setup${NC}"
}

# ── 3. Web Application Hacking ────────────────────────────────────────────────
cat_web_application() {
    _header "Web Application Hacking"
    echo -e "  ${CYAN}SQLi · XSS · fuzzing · proxies · CMS scanners${NC}\n"
    _dnf "Web App" \
        whatweb python3-requests python3-beautifulsoup4 curl wget
    install_sqlmap; install_nikto
    _pipx "Web App" commix dirsearch arjun
    _info "wfuzz está abandonado y rompe con Python nuevo → usa ffuf (ya instalado). dirb → gobuster/ffuf."
    _go  "Web App" \
        github.com/OJ/gobuster/v3@latest \
        github.com/ffuf/ffuf/v2@latest \
        github.com/projectdiscovery/httpx/cmd/httpx@latest
    _clone_tool "ParamSpider" "https://github.com/devanshbatham/ParamSpider.git"
    _clone_tool "XSStrike"    "https://github.com/s0md3v/XSStrike.git"
    echo ""; _info "Burp Suite CE: ${WHITE}https://portswigger.net/burp/communitydownload${NC}"
    if confirm_action "Install OWASP ZAP via Flatpak now?"; then
        flatpak install -y flathub org.zaproxy.ZAP 2>&1 | tee -a "$LOG_FILE" \
            && _ok "ZAP installed." || _err "ZAP install failed."
    fi
}

# ── 4. Exploitation ───────────────────────────────────────────────────────────
cat_exploitation() {
    _header "Exploitation Tools"
    echo -e "  ${CYAN}Frameworks · exploit helpers · shellcode · RE${NC}\n"
    _dnf "Exploitation" \
        gdb ltrace strace radare2 binwalk checksec python3-pwntools nasm mingw64-gcc
    install_metasploit
    _clone_tool "Veil"     "https://github.com/Veil-Framework/Veil.git"
    _clone_tool "exploitdb" "https://gitlab.com/exploit-database/exploitdb.git"
    [[ -f "$TOOLS_DIR/exploitdb/searchsploit" ]] && \
        ln -sf "$TOOLS_DIR/exploitdb/searchsploit" "$HOME/.local/bin/searchsploit"
    echo ""; _info "Ghidra: opción 10 (Reverse Engineering) lo descarga."
}

# ── 5. Post Exploitation ──────────────────────────────────────────────────────
cat_post_exploitation() {
    _header "Post Exploitation"
    echo -e "  ${CYAN}Persistence · lateral movement · AD · privesc${NC}\n"
    _dnf  "Post Exploitation" python3-ldap3
    _pipx "Post Exploitation" impacket pypykatz certipy-ad
    _pipx_legacy "Post Exploitation (legacy py)" "netexec::git+https://github.com/Pennyw0rth/NetExec"
    _gem  "Post Exploitation" evil-winrm
    _clone_tool "PEASS-ng"                "https://github.com/peass-ng/PEASS-ng.git"
    _clone_tool "linux-exploit-suggester" "https://github.com/The-Z-Labs/linux-exploit-suggester.git"
    _clone_tool "PowerSploit"             "https://github.com/PowerShellMafia/PowerSploit.git"
    _release_bin "DominicBreuker/pspy" "pspy" 'pspy64$'   # asset is 'pspy64' (static, x86_64)
    _info "linpeas/winpeas están dentro de PEASS-ng (no se clona dos veces)."
    _info "BloodHound (CE): usa Docker Compose → ${WHITE}https://github.com/SpecterOps/BloodHound${NC}"
    _info "crackmapexec quedó deprecado; se instala su sucesor: ${WHITE}netexec (nxc)${NC}."
}

# ── 6. Password Attacks ───────────────────────────────────────────────────────
cat_password_attacks() {
    _header "Password Attacks"
    echo -e "  ${CYAN}Hash cracking · brute force · wordlists${NC}\n"
    _dnf "Password Attacks" \
        hashcat john hydra medusa ncrack pdfcrack
    _pipx "Password Attacks" hashid name-that-hash
    _info "crunch/fcrackzip no están en Fedora → 'sudo dnf copr enable' o build. Genera wordlists con hashcat --stdout o maskprocessor."
    # rockyou (Fedora, a diferencia de Kali, no lo trae)
    if [[ ! -f /usr/share/wordlists/rockyou.txt ]]; then
        _info "Downloading rockyou.txt…"
        local rk; rk="$(mktemp)"
        if _download "https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt" "$rk"; then
            sudo mkdir -p /usr/share/wordlists
            sudo mv "$rk" /usr/share/wordlists/rockyou.txt && _ok "rockyou.txt → /usr/share/wordlists/"
        else
            rm -f "$rk"; _warn "rockyou download failed."
        fi
    else _warn "rockyou.txt already present."; fi
    if [[ ! -d "$TOOLS_DIR/SecLists" ]] && confirm_action "Clone SecLists (~1 GB)?"; then
        git clone --depth=1 "https://github.com/danielmiessler/SecLists.git" \
            "$TOOLS_DIR/SecLists" 2>&1 | tee -a "$LOG_FILE" && _ok "SecLists cloned."
    fi
}

# ── 7. Wireless Attacks ───────────────────────────────────────────────────────
cat_wireless() {
    _header "Wireless Attacks"
    echo -e "  ${CYAN}WiFi · Bluetooth · SDR · RFID/NFC${NC}\n"
    _dnf "Wireless" \
        aircrack-ng kismet hostapd dnsmasq reaver hcxtools \
        bluez bluez-tools gnuradio gqrx rtl-sdr hackrf libnfc iw pixiewps
    install_bettercap
    _clone_tool "wifite2" "https://github.com/kimocoder/wifite2.git"
    _info "hcxdumptool no está en Fedora (build desde github.com/ZerBea/hcxdumptool). wireless-tools está obsoleto → usa 'iw'."
}

# ── 8. Sniffing & Spoofing ────────────────────────────────────────────────────
cat_sniffing_spoofing() {
    _header "Sniffing & Spoofing"
    echo -e "  ${CYAN}Capture · MITM · ARP/DNS spoof · SSL strip${NC}\n"
    _dnf "Sniffing & Spoofing" \
        wireshark-cli wireshark tcpdump ettercap dsniff tcpreplay \
        python3-scapy netsniff-ng p0f nmap macchanger
    _pipx "Sniffing & Spoofing" mitmproxy
    install_bettercap
    _clone_tool "dnschef" "https://github.com/iphelix/dnschef.git"
    _info "dnschef usa ast.Str (roto en Python ≥3.12). Córrelo con python3.9/3.10 o parchea dnschef.py."
    _info "Responder: ${WHITE}git clone https://github.com/lgandx/Responder${NC} (no está en dnf)."
    _clone_tool "Responder" "https://github.com/lgandx/Responder.git"
}

# ── 9. Digital Forensics ─────────────────────────────────────────────────────
cat_forensics() {
    _header "Digital Forensics"
    echo -e "  ${CYAN}Imaging · memory · carving · artefacts${NC}\n"
    _dnf "Forensics" \
        sleuthkit foremost testdisk dc3dd dcfldd binwalk \
        perl-Image-ExifTool yara ssdeep steghide radare2 file binutils
    _pipx "Forensics" volatility3
    _info "scalpel no está en Fedora → foremost cubre el carving por firmas."
    _clone_tool "bulk_extractor" "https://github.com/simsong/bulk_extractor.git"
    # stegseek no publica RPM ni binario Linux genérico → build desde fuente
    _clone_tool "stegseek" "https://github.com/RickdeJager/stegseek.git"
    _info "Build stegseek: ${WHITE}sudo dnf install -y gcc-c++ cmake libmcrypt-devel zlib-devel libjpeg-turbo-devel${NC}"
    _info "        luego: ${WHITE}cd $TOOLS_DIR/stegseek && mkdir -p build && cd build && cmake .. && make && sudo make install${NC}"
    echo ""; _info "Autopsy GUI: ${WHITE}https://www.autopsy.com/download/${NC}"
}

# ── 10. Reverse Engineering ───────────────────────────────────────────────────
cat_reverse_engineering() {
    _header "Reverse Engineering"
    echo -e "  ${CYAN}Disassemblers · debuggers · decompilers${NC}\n"
    _dnf "Reverse Engineering" \
        radare2 gdb ltrace strace valgrind binwalk upx python3-pwntools \
        nasm binutils checksec java-latest-openjdk
    _pipx "Reverse Engineering" frida-tools
    _pipx_legacy "Reverse Engineering (legacy py)" ropper
    _info "apktool no está en Fedora: ${WHITE}descarga el wrapper+jar de github.com/iBotPeaches/Apktool a ~/.local/bin${NC}."
    _clone_tool "pwndbg" "https://github.com/pwndbg/pwndbg.git"
    [[ -d "$TOOLS_DIR/pwndbg" ]] && _info "Instala pwndbg: ${WHITE}cd $TOOLS_DIR/pwndbg && ./setup.sh${NC}"
    install_ghidra
    install_jadx
}

# ── 11. Network Attacks ───────────────────────────────────────────────────────
cat_network_attacks() {
    _header "Network Attacks"
    echo -e "  ${CYAN}MITM · tunnelling · pivoting · SMB · Kerberos${NC}\n"
    _dnf "Network Attacks" \
        nmap nmap-ncat socat proxychains-ng sshuttle iodine hping3 \
        python3-scapy onesixtyone arp-scan curl
    _pipx "Network Attacks" impacket
    _pipx_legacy "Network Attacks (legacy py)" "netexec::git+https://github.com/Pennyw0rth/NetExec"
    _info "ike-scan no está en Fedora (build desde github.com/royhills/ike-scan)."
    _go  "Network Attacks" \
        github.com/jpillora/chisel@latest \
        github.com/nicocha30/ligolo-ng/cmd/agent@latest \
        github.com/nicocha30/ligolo-ng/cmd/proxy@latest
    _clone_tool "Coercer" "https://github.com/p0dalirius/Coercer.git"
}

# ── 12. Social Engineering ────────────────────────────────────────────────────
cat_social_engineering() {
    _header "Social Engineering"
    echo -e "  ${CYAN}Phishing frameworks · payload delivery${NC}\n"
    _dnf  "Social Engineering" python3-pip python3 curl
    _pipx "Social Engineering" pyinstaller
    install_metasploit
    _clone_tool "setoolkit" "https://github.com/trustedsec/social-engineer-toolkit.git"
    [[ -d "$TOOLS_DIR/setoolkit" ]] && _info "Instala SET: ${WHITE}cd $TOOLS_DIR/setoolkit && pip install -r requirements.txt${NC}"
    install_gophish
    _clone_tool "evilginx2" "https://github.com/kgretzky/evilginx2.git"
    [[ -d "$TOOLS_DIR/evilginx2" ]] && _info "Build evilginx2: ${WHITE}cd $TOOLS_DIR/evilginx2 && make${NC}"
}

# ── 13. CTF & Binary Exploitation ────────────────────────────────────────────
cat_ctf_tools() {
    _header "CTF & Binary Exploitation"
    echo -e "  ${CYAN}CTF frameworks · ROP · steg · crypto${NC}\n"
    _dnf "CTF" \
        gdb qemu-system-x86 qemu-user-static steghide perl-Image-ExifTool \
        foremost binwalk hashcat john python3-z3 python3-gmpy2 \
        python3-cryptography nasm radare2 gdb-gdbserver checksec
    # CTF libs → venv (import, no CLI). pwntools ya viene por dnf (python3-pwntools);
    # ropper va por pipx-legacy. unicorn/keystone compilan wheels → build-deps ya instaladas.
    _pylib "CTF libs" angr capstone keystone-engine unicorn
    _info "pwntools disponible system-wide vía dnf (python3-pwntools); en el venv usa --system-site-packages si lo necesitas."
    _clone_tool "pwndbg" "https://github.com/pwndbg/pwndbg.git"
    _info "CyberChef online: ${WHITE}https://gchq.github.io/CyberChef/${NC}"
}

# ── 14. Cloud & Container Security ───────────────────────────────────────────
cat_cloud_containers() {
    _header "Cloud & Container Security"
    echo -e "  ${CYAN}AWS/GCP/Azure · Docker/K8s · secrets${NC}\n"
    _dnf "Cloud & Containers" \
        awscli podman skopeo buildah
    _pipx "Cloud & Containers" pacu detect-secrets checkov
    _pipx_legacy "Cloud & Containers (legacy py)" prowler
    _release_bin "gitleaks/gitleaks" "gitleaks" 'linux_x64\.tar\.gz$'
    _go  "Cloud & Containers" github.com/aquasecurity/kube-bench@latest
    # kubectl / helm / trivy: repos propios
    if confirm_action "Add kubectl + Trivy vendor repos and install?"; then
        _info "Adding Kubernetes repo…"
        sudo tee /etc/yum.repos.d/kubernetes.repo >/dev/null <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
EOF
        _info "Adding Trivy repo…"
        sudo tee /etc/yum.repos.d/trivy.repo >/dev/null <<'EOF'
[trivy]
name=Trivy repository
baseurl=https://aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://aquasecurity.github.io/trivy-repo/rpm/public.key
EOF
        _dnf "Cloud vendor" kubectl trivy
    fi
    _info "helm: ${WHITE}curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash${NC}"
    _info "trufflehog: ${WHITE}go install github.com/trufflesecurity/trufflehog/v3@latest${NC}"
}

# ── 15. Anonymity & Anti-Forensics ───────────────────────────────────────────
cat_anonymity() {
    _header "Anonymity & Anti-Forensics"
    echo -e "  ${CYAN}Tor · proxychains · MAC spoof · wiping · crypto${NC}\n"
    _dnf "Anonymity" \
        tor torsocks proxychains-ng macchanger bleachbit mat2 \
        perl-Image-ExifTool scrub cryptsetup gnupg2 kleopatra
    _info "VeraCrypt (RPM oficial): ${WHITE}https://www.veracrypt.fr/en/Downloads.html${NC}"
    _info "secure-delete no está en Fedora; alternativa: ${WHITE}shred${NC} (coreutils) o ${WHITE}scrub${NC}."
    if confirm_action "Install OnionShare via Flatpak?"; then
        flatpak install -y flathub org.onionshare.OnionShare 2>&1 | tee -a "$LOG_FILE" \
            && _ok "OnionShare installed." || _warn "OnionShare failed."
    fi
}

# =============================================================================
# SPECIAL INSTALLERS
# =============================================================================
install_metasploit() {
    check_command msfconsole && { _warn "Metasploit already installed."; return; }
    _info "Metasploit no está en repos de Fedora — installer oficial de Rapid7…"
    confirm_action "Download and run Rapid7's official installer as root?" \
        || { _warn "Metasploit skipped by user."; return; }
    local tmp; tmp="$(mktemp)"
    if _download "https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb" "$tmp"; then
        chmod +x "$tmp"
        run_with_spinner "Installing Metasploit Framework" sudo "$tmp" \
            && _ok "Metasploit installed (run: msfconsole)." || _err "Metasploit install failed — check $LOG_FILE"
    else
        _err "Could not fetch Metasploit installer."
    fi
    rm -f "$tmp"
}

install_ghidra() {
    { check_command ghidra || [[ -d "$TOOLS_DIR/ghidra" ]]; } && { _warn "Ghidra already present."; return; }
    _info "Downloading latest Ghidra…"
    local url; url=$(_gh_latest_asset "NationalSecurityAgency/ghidra" '_PUBLIC_.*\.zip$') \
        || { _warn "Ghidra: GitHub API error — https://ghidra-sre.org"; return; }
    [[ -z "$url" ]] && { _warn "Ghidra asset not found — https://ghidra-sre.org"; return; }
    local tmp; tmp="$(mktemp)"
    if _download "$url" "$tmp" && unzip -q "$tmp" -d "$TOOLS_DIR/" 2>>"$LOG_FILE"; then
        local dir; dir=$(find "$TOOLS_DIR" -maxdepth 1 -type d -name 'ghidra_*' | head -1)
        [[ -n "$dir" ]] && mv "$dir" "$TOOLS_DIR/ghidra" && _ok "Ghidra → $TOOLS_DIR/ghidra"
    else _err "Ghidra download/extract failed."; fi
    rm -f "$tmp"
}

install_jadx() {
    check_command jadx && { _warn "jadx already installed."; return; }
    local url; url=$(_gh_latest_asset "skylot/jadx" 'jadx-[0-9].*\.zip$') \
        || { _warn "jadx: GitHub API error."; return; }
    [[ -z "$url" ]] && { _warn "jadx asset not found."; return; }
    local tmp; tmp="$(mktemp)"
    if _download "$url" "$tmp"; then
        mkdir -p "$TOOLS_DIR/jadx" && unzip -qo "$tmp" -d "$TOOLS_DIR/jadx/" 2>>"$LOG_FILE" \
            && ln -sf "$TOOLS_DIR/jadx/bin/jadx" "$HOME/.local/bin/jadx" \
            && _ok "jadx → $TOOLS_DIR/jadx" || _err "jadx extract failed."
    fi
    rm -f "$tmp"
}

# ─── Top-10 Essentials ────────────────────────────────────────────────────────
install_top10() {
    _header "Top-10 Essential Tools"
    _dnf "Top-10 (dnf)" nmap aircrack-ng john hashcat hydra wireshark
    _go  "Top-10 (go)"  github.com/OJ/gobuster/v3@latest
    install_sqlmap; install_nikto
    install_metasploit
}

# ─── Install ALL ──────────────────────────────────────────────────────────────
install_all() {
    _header "Installing ALL Categories"
    trap 'ASSUME_YES=0' RETURN          # always reset, even on early return
    echo -e "  ${RED}⚠  Instalará todas las categorías, herramientas y dependencias opcionales. Tarda un rato.${NC}\n"
    confirm_action "Proceed with full install?" || { _warn "Cancelled."; return; }
    if confirm_action "Unattended: auto-accept optional prompts (ZAP, SecLists ~1GB, kube/Trivy repos, OnionShare, run MSF installer as root)?"; then
        ASSUME_YES=1
        _info "Modo desatendido activado — sin más pausas."
    fi
    setup_repos
    cat_information_gathering; cat_vulnerability_analysis; cat_web_application
    cat_exploitation; cat_post_exploitation; cat_password_attacks
    cat_wireless; cat_sniffing_spoofing; cat_forensics
    cat_reverse_engineering; cat_network_attacks; cat_social_engineering
    cat_ctf_tools; cat_cloud_containers; cat_anonymity
    echo ""; _ok "All categories complete. Log: $LOG_FILE"
}

# ─── Update everything ────────────────────────────────────────────────────────
update_tools() {
    _header "Updating All Tools"
    run_with_spinner "DNF upgrade" sudo dnf upgrade -y && _ok "DNF updated." || _warn "DNF upgrade had issues."
    if check_command pipx; then
        _info "Upgrading pipx apps…"
        pipx upgrade-all &>>"$LOG_FILE" && _ok "pipx apps updated." || _warn "pipx upgrade issues."
    fi
    # venv libs (pwntools/angr/capstone/…): upgrades can break pinned ABIs, so opt-in.
    if [[ -d "$VENV_DIR" ]] && confirm_action "Update Python security libs (pwntools/angr/… — potentially breaking)?"; then
        _info "Upgrading venv libs…"
        local outdated=()
        if check_command jq; then
            mapfile -t outdated < <("$VENV_DIR/bin/pip" list --outdated --format=json 2>>"$LOG_FILE" | jq -r '.[].name')
        fi
        if ((${#outdated[@]} == 0)); then
            _ok "venv libraries already up to date."
        elif "$VENV_DIR/bin/pip" install --upgrade "${outdated[@]}" &>>"$LOG_FILE"; then
            _ok "venv updated (${#outdated[@]} libs)."
        else
            _warn "Some venv libraries could not be updated — check $LOG_FILE"
        fi
    fi
    if [[ -d "$TOOLS_DIR" ]]; then
        _info "Updating git-cloned tools…"
        for d in "$TOOLS_DIR"/*/; do
            [[ -d "$d/.git" ]] || continue
            git -C "$d" pull --ff-only --quiet 2>>"$LOG_FILE" \
                && echo -e "  ${GREEN}✓${NC} $(basename "$d")" \
                || echo -e "  ${RED}✗${NC} $(basename "$d")"
        done
    fi
    _ok "Update pass complete."
}

# ─── Summary ─────────────────────────────────────────────────────────────────
show_summary() {
    _header "Installed Tools Summary"
    # label::command — we check the REAL runnable command, not the package name.
    local tools=(
        "nmap::nmap" "Wireshark::wireshark" "TShark::tshark" "tcpdump::tcpdump"
        "Metasploit::msfconsole" "sqlmap::sqlmap" "hydra::hydra" "hashcat::hashcat"
        "John::john" "aircrack-ng::aircrack-ng" "gobuster::gobuster" "ffuf::ffuf"
        "nikto::nikto" "radare2::radare2" "gdb::gdb" "binwalk::binwalk"
        "checksec::checksec" "Volatility3::vol" "Sleuth Kit::fls" "foremost::foremost"
        "steghide::steghide" "NetExec::nxc" "Impacket::impacket-psexec"
        "ProxyChains::proxychains4" "Tor::tor" "macchanger::macchanger"
        "Nuclei::nuclei" "amass::amass" "subfinder::subfinder" "bettercap::bettercap"
        "evil-winrm::evil-winrm" "jadx::jadx"
    )
    local found=0 miss=0 spec label cmd
    echo ""
    for spec in "${tools[@]}"; do
        label="${spec%%::*}"; cmd="${spec##*::}"
        if check_command "$cmd"; then
            echo -e "  ${GREEN}✓${NC} $label"; ((found++)) || true
        else
            echo -e "  ${RED}✗${NC} $label"; ((miss++)) || true
        fi
    done
    echo ""; _sep
    echo -e "  ${GREEN}Runnable: $found${NC}   ${RED}Missing: $miss${NC}   (of ${#tools[@]})"
    _sep; echo ""
    echo -e "  ${CYAN}Cloned sources in $TOOLS_DIR (may need building):${NC}"
    if [[ -d "$TOOLS_DIR" ]]; then
        find "$TOOLS_DIR" -maxdepth 1 -mindepth 1 -type d -printf '    %f\n' | grep -v '^\s*\.venv$' || true
    else echo "    (none yet)"; fi
}

# =============================================================================
# MAIN MENU
# =============================================================================
show_menu() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
  ██╗      █████╗ ████████╗███████╗███╗   ██╗ ██████╗██╗ █████╗
  ██║     ██╔══██╗╚══██╔══╝██╔════╝████╗  ██║██╔════╝██║██╔══██╗
  ██║     ███████║   ██║   █████╗  ██╔██╗ ██║██║     ██║███████║
  ██║     ██╔══██║   ██║   ██╔══╝  ██║╚██╗██║██║     ██║██╔══██║
  ███████╗██║  ██║   ██║   ███████╗██║ ╚████║╚██████╗██║██║  ██║
  ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚═╝╚═╝  ╚═╝
          ████████╗ ██████╗  ██████╗ ██╗     ███████╗
          ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝
             ██║   ██║   ██║██║   ██║██║     ███████╗
             ██║   ██║   ██║██║   ██║██║     ╚════██║
             ██║   ╚██████╔╝╚██████╔╝███████╗███████║
             ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝
BANNER
    echo -e "${NC}"
    echo -e "  ${WHITE}Security Toolkit for Fedora ${FEDORA_VER}${NC}  ${CYAN}· v2.1.3-beta · by LatenciaTech${NC}"
    echo -e "  ${YELLOW}⚠  FOR LEGAL USE ONLY — authorised pentest / CTF / research  ⚠${NC}"
    echo -e "  ${CYAN}  Tools: $TOOLS_DIR   |   Log: $LOG_FILE${NC}\n"
    echo "  ════════════════════════════════════════════════════════"
    echo "  Categories (Kali menu order)"
    echo "  ════════════════════════════════════════════════════════"
    echo "   1) Information Gathering    2) Vulnerability Analysis"
    echo "   3) Web Application          4) Exploitation"
    echo "   5) Post Exploitation        6) Password Attacks"
    echo "   7) Wireless Attacks         8) Sniffing & Spoofing"
    echo "   9) Digital Forensics       10) Reverse Engineering"
    echo "  11) Network Attacks         12) Social Engineering"
    echo "  13) CTF & Binary Exploit    14) Cloud & Container Sec."
    echo "  15) Anonymity & Anti-Forensics"
    echo ""
    echo "  ════════════════════════════════════════════════════════"
    echo "  16) Install ALL     17) Top-10 essentials     18) Setup Repos"
    echo "  19) Update all      20) Show summary          0) Exit"
    echo ""
    read -rp "  Select [0-20]: " choice
}

# =============================================================================
# BOOTSTRAP
# =============================================================================
if [[ $EUID -eq 0 ]]; then
    echo -e "${RED}  ✗ Do NOT run as root!${NC}"
    echo -e "${YELLOW}  Run as a regular user — the script uses sudo when needed.${NC}"
    exit 1
fi

# ─── OS gate: Fedora 39+ only ─────────────────────────────────────────────────
command -v dnf &>/dev/null || { _err "This script requires DNF (Fedora)."; exit 1; }
[[ -r /etc/os-release ]] || { _err "Cannot identify the OS (/etc/os-release missing)."; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "fedora" ]]; then
    _err "LatenciaTools supports Fedora only. Detected: ${PRETTY_NAME:-unknown}"; exit 1
fi
if ! [[ "$FEDORA_VER" =~ ^[0-9]+$ ]] || (( FEDORA_VER < 39 )); then
    _err "Fedora 39 or newer required. Detected: Fedora ${FEDORA_VER}."; exit 1
fi

# ─── Preflight: required host tools (fail hard if any can't be installed) ──────
for dep in curl wget git unzip tar file jq; do
    if ! check_command "$dep"; then
        sudo dnf install -y "$dep" >>"$LOG_FILE" 2>&1 || {
            _err "Required dependency could not be installed: $dep"; exit 1; }
    fi
done

mkdir -p "$HOME/.local/bin" "$TOOLS_DIR"
# Ensure ~/.local/bin and go/bin are on PATH for this run
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
case ":$PATH:" in *":$HOME/go/bin:"*) ;; *) export PATH="$HOME/go/bin:$PATH";; esac

sudo -v
_sudo_keepalive

{ echo ""; echo "==> LatenciaTools Fedora Installer — $(date)"; echo ""; } | tee -a "$LOG_FILE"

while true; do
    show_menu
    case "$choice" in
         1) cat_information_gathering ;;   2) cat_vulnerability_analysis ;;
         3) cat_web_application ;;         4) cat_exploitation ;;
         5) cat_post_exploitation ;;       6) cat_password_attacks ;;
         7) cat_wireless ;;                8) cat_sniffing_spoofing ;;
         9) cat_forensics ;;              10) cat_reverse_engineering ;;
        11) cat_network_attacks ;;        12) cat_social_engineering ;;
        13) cat_ctf_tools ;;              14) cat_cloud_containers ;;
        15) cat_anonymity ;;              16) install_all ;;
        17) install_top10 ;;              18) setup_repos ;;
        19) update_tools ;;               20) show_summary ;;
         0) echo -e "\n${GREEN}  Stay legal. Happy hacking. 👾${NC}\n"; exit 0 ;;
         *) _err "Invalid option: ${choice}" ;;
    esac
    echo ""; read -rp "  Press Enter to continue..."
done

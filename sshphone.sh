#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  SSHphone - Android telefonunuzu SSH ile bağlanılabilen bir "VDS"e dönüştürür
# -----------------------------------------------------------------------------
#  Termux üzerinde çalışır, root GEREKTİRMEZ.
#
#   - OpenSSH sunucusu kurar ve yapılandırır (varsayılan port: 8022)
#   - Parola ve/veya SSH anahtarı ile giriş
#   - İsteğe bağlı tam Linux dağıtımı (Ubuntu, Debian, Alpine, Arch...)
#     proot-distro ile; SSH girişinde doğrudan dağıtıma düşebilirsiniz
#   - Termux:Boot ile telefon açılınca otomatik başlatma
#   - Uyku engelleme (wake-lock), bağlantı bilgisi, MOTD ekranı
#   - Cloudflare Tunnel ile dış ağdan (port yönlendirmesiz) erişim
#
#  Kullanım:  bash sshphone.sh            (ilk kurulum)
#             sshphone help               (kurulumdan sonra)
# =============================================================================

set -o pipefail

SSHPHONE_VERSION="1.0.0"
SSHPHONE_RAW_URL="${SSHPHONE_RAW_URL:-https://raw.githubusercontent.com/mesutozansoftware/SSHphone/main/sshphone.sh}"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME="${HOME:-/data/data/com.termux/files/home}"

CONF_DIR="$HOME/.config/sshphone"
CONF_FILE="$CONF_DIR/config"
HOOK_FILE="$CONF_DIR/shell-hook.sh"
BIN_PATH="$PREFIX/bin/sshphone"
SSHD_CONFIG="$PREFIX/etc/ssh/sshd_config"
LOG_FILE="$PREFIX/var/log/sshphone-sshd.log"
BOOT_DIR="$HOME/.termux/boot"
BOOT_FILE="$BOOT_DIR/sshphone-start"
AUTH_KEYS="$HOME/.ssh/authorized_keys"
BASHRC="$HOME/.bashrc"
DISTRO_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs"

HOOK_BEGIN="# >>> sshphone >>>"
HOOK_END="# <<< sshphone <<<"

BASE_PACKAGES=(openssh procps iproute2 net-tools curl wget git nano htop tmux openssl termux-tools)

# --------------------------------------------------------------------------- #
#  Görünüm yardımcıları
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'; C_DIM=$'\e[2m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_DIM=""
fi

info()  { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

banner() {
    printf '%s' "$C_CYAN"
    cat <<'EOF'
   ____ ____  _   _       _
  / ___/ ___|| | | |_ __ | |__   ___  _ __   ___
  \___ \___ \| |_| | '_ \| '_ \ / _ \| '_ \ / _ \
   ___) |__) |  _  | |_) | | | | (_) | | | |  __/
  |____/____/|_| |_| .__/|_| |_|\___/|_| |_|\___|
                   |_|   Android -> SSH VDS
EOF
    printf '%s  sürüm %s%s\n\n' "$C_DIM" "$SSHPHONE_VERSION" "$C_RESET"
}

# Script "curl ... | bash" ile çalıştırılsa bile soruları terminalden okur.
_read_tty() {
    if [ -r /dev/tty ]; then
        IFS= read -r "$@" </dev/tty
    else
        IFS= read -r "$@"
    fi
}

# ask "Soru" "varsayılan" -> cevabı stdout'a yazar
ask() {
    local prompt="$1" def="${2:-}" ans
    if [ "${SSHPHONE_YES:-0}" = 1 ]; then printf '%s' "$def"; return; fi
    if [ -n "$def" ]; then
        printf '%s?%s %s [%s]: ' "$C_YELLOW" "$C_RESET" "$prompt" "$def" >&2
    else
        printf '%s?%s %s: ' "$C_YELLOW" "$C_RESET" "$prompt" >&2
    fi
    _read_tty ans || ans=""
    printf '%s' "${ans:-$def}"
}

# confirm "Soru" "e|h" -> 0 (evet) / 1 (hayır)
confirm() {
    local prompt="$1" def="${2:-e}" ans hint
    if [ "$def" = e ]; then hint="E/h"; else hint="e/H"; fi
    if [ "${SSHPHONE_YES:-0}" = 1 ]; then [ "$def" = e ]; return; fi
    while true; do
        printf '%s?%s %s (%s): ' "$C_YELLOW" "$C_RESET" "$prompt" "$hint" >&2
        _read_tty ans || ans=""
        ans="${ans:-$def}"
        case "${ans,,}" in
            e|evet|y|yes) return 0 ;;
            h|hayir|hayır|n|no) return 1 ;;
            *) warn "Lütfen 'e' veya 'h' girin." ;;
        esac
    done
}

# --------------------------------------------------------------------------- #
#  Ortam kontrolleri ve yapılandırma
# --------------------------------------------------------------------------- #
is_termux() {
    [ -d "/data/data/com.termux/files/usr" ] || [[ "$PREFIX" == *com.termux* ]]
}

require_termux() {
    if ! is_termux; then
        err "Bu script Android üzerinde Termux içinde çalışmak üzere tasarlanmıştır."
        echo "  1) Termux'u F-Droid veya GitHub'dan kurun:"
        echo "     https://f-droid.org/packages/com.termux/"
        echo "     https://github.com/termux/termux-app/releases"
        echo "  2) Termux'u açıp:  bash sshphone.sh"
        exit 1
    fi
    if [ "$(id -u)" = 0 ]; then
        warn "Script root olarak çalışıyor. Termux'ta normal kullanıcı ile çalıştırmanız önerilir."
    fi
}

load_config() {
    SSHPHONE_PORT=8022
    SSHPHONE_DISTRO=""
    SSHPHONE_AUTOLOGIN=no
    SSHPHONE_AUTOSTART=yes
    SSHPHONE_WAKELOCK=yes
    # shellcheck disable=SC1090
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"
}

save_config() {
    mkdir -p "$CONF_DIR"
    cat >"$CONF_FILE" <<EOF
# SSHphone yapılandırması - 'sshphone' komutları ile değiştirilmesi önerilir.
SSHPHONE_PORT=$SSHPHONE_PORT
SSHPHONE_DISTRO=$SSHPHONE_DISTRO
SSHPHONE_AUTOLOGIN=$SSHPHONE_AUTOLOGIN
SSHPHONE_AUTOSTART=$SSHPHONE_AUTOSTART
SSHPHONE_WAKELOCK=$SSHPHONE_WAKELOCK
EOF
}

is_installed() { [ -f "$CONF_FILE" ] && command -v sshd >/dev/null 2>&1; }

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

# sshd_config içinde bir ayarı güvenle değiştirir.
# sshd ilk eşleşen değeri kullandığı için ayar dosyanın en başına yazılır.
set_sshd_opt() {
    local key="$1" val="$2"
    [ -f "$SSHD_CONFIG" ] || touch "$SSHD_CONFIG"
    sed -i -E "/^[[:space:]]*${key}[[:space:]]/Id" "$SSHD_CONFIG"
    if [ -s "$SSHD_CONFIG" ]; then
        sed -i "1i ${key} ${val}" "$SSHD_CONFIG"
    else
        printf '%s %s\n' "$key" "$val" >"$SSHD_CONFIG"
    fi
}

get_sshd_opt() {
    grep -iE "^[[:space:]]*$1[[:space:]]" "$SSHD_CONFIG" 2>/dev/null | head -n1 | awk '{print $2}'
}

has_password() { [ -f "$HOME/.termux_authinfo" ]; }

has_keys() { [ -s "$AUTH_KEYS" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS"; }

# Dinleyen ana sshd sürecinin PID'i (oturum süreçleri hariç)
sshd_pid() {
    local f="$PREFIX/var/run/sshd.pid" p
    if [ -f "$f" ]; then
        p=$(cat "$f" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "$p"; return 0; fi
    fi
    pgrep -x -o sshd 2>/dev/null
}

sshd_running() { [ -n "$(sshd_pid)" ]; }

distro_installed() { [ -n "${1:-}" ] && [ -d "$DISTRO_ROOT/$1" ]; }

# --------------------------------------------------------------------------- #
#  Ağ bilgisi
# --------------------------------------------------------------------------- #
# "arayüz ip" satırları döndürür. Android 11+ bazı yöntemleri engellediği
# için birkaç yöntem sırayla denenir.
get_ips() {
    local out=""
    if command -v ip >/dev/null 2>&1; then
        out=$(ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print $2" "a[1]}')
    fi
    if [ -z "$out" ] && command -v ifconfig >/dev/null 2>&1; then
        out=$(ifconfig 2>/dev/null | awk '
            /^[^ \t]/ { iface=$1; sub(":", "", iface) }
            /inet / { for (i=1;i<=NF;i++) if ($i=="inet") { ip=$(i+1); sub("addr:", "", ip); print iface" "ip } }')
    fi
    printf '%s\n' "$out" | awk 'NF==2 && $1!="lo" && $2!~/^127\./'
}

describe_iface() {
    local iface="$1" ip="$2"
    case "$iface" in
        wlan*)  echo "Wi-Fi (yerel ağ)" ;;
        rmnet*|ccmni*|seth*|v4-rmnet*) echo "Mobil veri (genelde CGNAT, dışarıdan erişilemez)" ;;
        tun*|wg*)
            case "$ip" in
                100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) echo "Tailscale (her yerden erişim)" ;;
                *) echo "VPN" ;;
            esac ;;
        swlan*|ap*|rndis*|bt-pan*) echo "Hotspot / paylaşım" ;;
        *) echo "$iface" ;;
    esac
}

# --------------------------------------------------------------------------- #
#  Paketler
# --------------------------------------------------------------------------- #
pkg_install() {
    DEBIAN_FRONTEND=noninteractive pkg install -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

update_system() {
    step "Paket listesi güncelleniyor"
    if ! DEBIAN_FRONTEND=noninteractive pkg update -y \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold; then
        warn "Güncelleme başarısız. Ayna sunucusunu değiştirmek için: termux-change-repo"
        confirm "Yine de devam edilsin mi?" e || exit 1
    fi
    if confirm "Kurulu paketler yükseltilsin mi? (önerilir)" e; then
        DEBIAN_FRONTEND=noninteractive pkg upgrade -y \
            -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            || warn "Yükseltme sırasında hata oluştu, devam ediliyor."
    fi
}

# --------------------------------------------------------------------------- #
#  SSH sunucusu
# --------------------------------------------------------------------------- #
configure_sshd() {
    step "SSH sunucusu yapılandırılıyor"
    mkdir -p "$PREFIX/etc/ssh" "$HOME/.ssh" "$(dirname "$LOG_FILE")"
    chmod 700 "$HOME/.ssh"
    [ -f "$AUTH_KEYS" ] || touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    # Sunucu anahtarlarını oluştur (zaten varsa dokunmaz)
    ssh-keygen -A >/dev/null 2>&1 || true

    [ -f "$SSHD_CONFIG.sshphone.bak" ] || cp "$SSHD_CONFIG" "$SSHD_CONFIG.sshphone.bak" 2>/dev/null || true

    set_sshd_opt Port "$SSHPHONE_PORT"
    set_sshd_opt PubkeyAuthentication yes
    set_sshd_opt PrintMotd no
    set_sshd_opt ClientAliveInterval 30
    set_sshd_opt ClientAliveCountMax 4
    set_sshd_opt TCPKeepAlive yes
    set_sshd_opt AllowTcpForwarding yes
    set_sshd_opt X11Forwarding no
    [ -n "$(get_sshd_opt PasswordAuthentication)" ] || set_sshd_opt PasswordAuthentication yes

    if ! grep -qiE '^[[:space:]]*Subsystem[[:space:]]+sftp' "$SSHD_CONFIG"; then
        echo "Subsystem sftp $PREFIX/libexec/sftp-server" >>"$SSHD_CONFIG"
    fi

    if sshd -t -f "$SSHD_CONFIG" 2>/dev/null; then
        ok "sshd_config geçerli (port $SSHPHONE_PORT)"
    else
        sshd -t -f "$SSHD_CONFIG" || true
        die "sshd_config hatalı. Yedek: $SSHD_CONFIG.sshphone.bak"
    fi
}

setup_password() {
    step "Giriş parolası"
    if has_password; then
        confirm "Bir parola zaten var. Değiştirmek ister misiniz?" h || { ok "Mevcut parola korunuyor."; return; }
    else
        info "SSH ile parola girişi için bir parola belirlemelisiniz."
    fi
    local tries=0
    until passwd; do
        tries=$((tries + 1))
        [ "$tries" -ge 3 ] && { warn "Parola ayarlanamadı. Daha sonra 'sshphone password' ile deneyin."; return 1; }
        warn "Tekrar deneyin."
    done
    ok "Parola ayarlandı."
}

add_key() {
    local input="${1:-}" key
    if [ -z "$input" ]; then
        echo "Bilgisayarınızdaki açık anahtarı (ör. ~/.ssh/id_ed25519.pub içeriği) yapıştırın."
        echo "${C_DIM}Anahtarınız yoksa bilgisayarda: ssh-keygen -t ed25519${C_RESET}"
        input=$(ask "Açık anahtar" "")
    fi
    [ -z "$input" ] && { warn "Anahtar girilmedi."; return 1; }

    if [ -f "$input" ]; then key=$(cat "$input"); else key="$input"; fi
    key=$(printf '%s' "$key" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if ! printf '%s' "$key" | grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+'; then
        err "Geçersiz açık anahtar biçimi."
        return 1
    fi

    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    touch "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
    if grep -qF "$(printf '%s' "$key" | awk '{print $2}')" "$AUTH_KEYS"; then
        ok "Bu anahtar zaten ekli."
    else
        printf '%s\n' "$key" >>"$AUTH_KEYS"
        ok "Anahtar eklendi: $(printf '%s' "$key" | awk '{print $1, ($3 ? $3 : "")}')"
    fi
}

list_keys() {
    if has_keys; then
        local i=0
        while IFS= read -r line; do
            [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]] || continue
            i=$((i + 1))
            printf '  %d) %s ...%s %s\n' "$i" "$(awk '{print $1}' <<<"$line")" \
                "$(awk '{print substr($2, length($2)-11)}' <<<"$line")" "$(awk '{print $3}' <<<"$line")"
        done <"$AUTH_KEYS"
    else
        info "Kayıtlı SSH anahtarı yok."
    fi
}

set_password_auth() {
    local mode="$1"
    if [ "$mode" = no ] && ! has_keys; then
        die "Hiç SSH anahtarı ekli değil! Önce 'sshphone add-key' ile anahtar ekleyin, yoksa kilitlenirsiniz."
    fi
    set_sshd_opt PasswordAuthentication "$mode"
    set_sshd_opt KbdInteractiveAuthentication no
    if [ "$mode" = no ]; then ok "Parola ile giriş KAPATILDI (yalnızca anahtar)."; else ok "Parola ile giriş AÇIK."; fi
    sshd_running && restart_sshd
}

start_sshd() {
    local quiet="${1:-}"
    load_config
    if sshd_running; then
        [ -z "$quiet" ] && ok "SSH sunucusu zaten çalışıyor."
        return 0
    fi
    [ "$SSHPHONE_WAKELOCK" = yes ] && command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
    mkdir -p "$(dirname "$LOG_FILE")"
    sshd -E "$LOG_FILE"
    local i
    for i in 1 2 3 4 5; do
        sshd_running && break
        sleep 1
    done
    if sshd_running; then
        [ -z "$quiet" ] && ok "SSH sunucusu başlatıldı (port $SSHPHONE_PORT)."
        return 0
    fi
    err "SSH sunucusu başlatılamadı. Günlük: $LOG_FILE"
    tail -n 10 "$LOG_FILE" 2>/dev/null >&2
    return 1
}

stop_sshd() {
    # Yalnızca dinleyen ana süreç durdurulur; açık SSH oturumları (bu oturum dahil) kopmaz.
    local pid
    pid=$(sshd_pid)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        rm -f "$PREFIX/var/run/sshd.pid"
        ok "SSH sunucusu durduruldu (yeni bağlantı kabul edilmez)."
    else
        info "SSH sunucusu zaten kapalı."
    fi
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
    return 0
}

restart_sshd() {
    # Mevcut SSH oturumlarını koparmadan yalnızca dinleyen ana süreci yeniden başlatır.
    stop_sshd >/dev/null
    start_sshd
}

# --------------------------------------------------------------------------- #
#  Linux dağıtımı (proot-distro)
# --------------------------------------------------------------------------- #
DISTROS=(ubuntu debian alpine archlinux fedora opensuse void manjaro rockylinux almalinux)

install_distro() {
    local d="${1:-}"
    if [ -z "$d" ]; then
        echo "Kurulabilecek dağıtımlar:"
        local i=1
        for x in "${DISTROS[@]}"; do printf '  %2d) %s\n' "$i" "$x"; i=$((i + 1)); done
        local choice
        choice=$(ask "Seçim (numara veya ad)" "1")
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DISTROS[@]}" ]; then
            d="${DISTROS[$((choice - 1))]}"
        else
            d="$choice"
        fi
    fi

    command -v proot-distro >/dev/null 2>&1 || { step "proot-distro kuruluyor"; pkg_install proot-distro || die "proot-distro kurulamadı."; }

    if distro_installed "$d"; then
        ok "$d zaten kurulu."
    else
        step "$d kuruluyor (internet hızınıza göre birkaç dakika sürebilir)"
        proot-distro install "$d" || die "$d kurulamadı. Geçerli adlar için: proot-distro list"
        step "$d içinde temel araçlar kuruluyor"
        case "$d" in
            ubuntu|debian)
                proot-distro login "$d" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y upgrade && apt-get -y install sudo nano curl wget git htop ca-certificates locales tzdata iproute2 iputils-ping net-tools' \
                    || warn "Bazı paketler kurulamadı." ;;
            alpine)
                proot-distro login "$d" -- sh -c 'apk update && apk add bash sudo nano curl wget git htop ca-certificates' || warn "Bazı paketler kurulamadı." ;;
            archlinux|manjaro)
                proot-distro login "$d" -- bash -c 'pacman -Syu --noconfirm sudo nano curl wget git htop' || warn "Bazı paketler kurulamadı." ;;
            fedora|rockylinux|almalinux)
                proot-distro login "$d" -- bash -c 'dnf -y install sudo nano curl wget git htop' || warn "Bazı paketler kurulamadı." ;;
            *) ;;
        esac
        ok "$d kuruldu. Giriş: sshphone linux"
    fi

    load_config
    SSHPHONE_DISTRO="$d"
    save_config
}

linux_login() {
    load_config
    local d="${1:-$SSHPHONE_DISTRO}"
    [ -z "$d" ] && die "Kurulu dağıtım yok. Önce: sshphone distro"
    distro_installed "$d" || die "$d kurulu değil. Önce: sshphone distro $d"
    export SSHPHONE_INSIDE=1
    exec proot-distro login "$d"
}

set_autologin() {
    load_config
    case "${1:-}" in
        on|yes|ac|aç)
            [ -z "$SSHPHONE_DISTRO" ] && die "Önce bir dağıtım kurun: sshphone distro"
            SSHPHONE_AUTOLOGIN=yes ;;
        off|no|kapat) SSHPHONE_AUTOLOGIN=no ;;
        *) die "Kullanım: sshphone autologin on|off" ;;
    esac
    save_config
    if [ "$SSHPHONE_AUTOLOGIN" = yes ]; then
        ok "SSH ile bağlanınca doğrudan '$SSHPHONE_DISTRO' ortamına girilecek."
        info "Termux kabuğu için: ssh ... -t bash   (veya dağıtımda 'exit')"
    else
        ok "SSH girişinde Termux kabuğu açılacak."
    fi
}

# --------------------------------------------------------------------------- #
#  Kabuk kancası, otomatik başlatma, kendini kurma
# --------------------------------------------------------------------------- #
write_hook() {
    mkdir -p "$CONF_DIR"
    cat >"$HOOK_FILE" <<'EOF'
# SSHphone kabuk kancası - otomatik oluşturulur, elle düzenlemeyin.
if [ -f "$HOME/.config/sshphone/config" ]; then
    . "$HOME/.config/sshphone/config"
fi
# Termux açıldığında SSH sunucusu kapalıysa başlat
if [ "${SSHPHONE_AUTOSTART:-yes}" = yes ] && ! pgrep -x sshd >/dev/null 2>&1; then
    sshphone start --quiet >/dev/null 2>&1
fi
# Yalnızca etkileşimli SSH oturumlarında
case $- in
    *i*)
        if [ -n "$SSH_CONNECTION" ] && [ -z "$SSHPHONE_INSIDE" ]; then
            sshphone motd
            if [ "${SSHPHONE_AUTOLOGIN:-no}" = yes ] && [ -n "$SSHPHONE_DISTRO" ] \
               && [ -d "$PREFIX/var/lib/proot-distro/installed-rootfs/$SSHPHONE_DISTRO" ]; then
                export SSHPHONE_INSIDE=1
                exec proot-distro login "$SSHPHONE_DISTRO"
            fi
        fi
        ;;
esac
EOF

    touch "$BASHRC"
    if ! grep -qF "$HOOK_BEGIN" "$BASHRC"; then
        {
            echo ""
            echo "$HOOK_BEGIN"
            echo "[ -f \"\$HOME/.config/sshphone/shell-hook.sh\" ] && . \"\$HOME/.config/sshphone/shell-hook.sh\""
            echo "$HOOK_END"
        } >>"$BASHRC"
    fi
    ok "Kabuk kancası eklendi (~/.bashrc)."
}

write_boot() {
    mkdir -p "$BOOT_DIR"
    cat >"$BOOT_FILE" <<EOF
#!$PREFIX/bin/sh
# SSHphone: telefon açıldığında SSH sunucusunu başlatır (Termux:Boot gerekir)
termux-wake-lock
"$BIN_PATH" start --quiet
EOF
    chmod 700 "$BOOT_FILE"
    ok "Açılışta başlatma betiği yazıldı: $BOOT_FILE"
    info "Bunun çalışması için Termux:Boot uygulamasını kurup BİR KEZ açın (F-Droid)."
}

install_self() {
    local src="${BASH_SOURCE[0]:-$0}"
    if [ -f "$src" ] && grep -q "SSHPHONE_VERSION" "$src" 2>/dev/null; then
        [ "$(realpath "$src" 2>/dev/null)" = "$(realpath "$BIN_PATH" 2>/dev/null)" ] || cp "$src" "$BIN_PATH"
    else
        info "Script indiriliyor: $SSHPHONE_RAW_URL"
        curl -fsSL "$SSHPHONE_RAW_URL" -o "$BIN_PATH" || die "Script indirilemedi."
    fi
    chmod 755 "$BIN_PATH"
    ok "'sshphone' komutu kuruldu: $BIN_PATH"
}

# --------------------------------------------------------------------------- #
#  Bilgi ekranları
# --------------------------------------------------------------------------- #
device_model() {
    local m
    m="$(getprop ro.product.manufacturer 2>/dev/null) $(getprop ro.product.model 2>/dev/null)"
    m="${m## }"; printf '%s' "${m:-Android}"
}

battery_level() {
    local f
    for f in /sys/class/power_supply/battery/capacity /sys/class/power_supply/*/capacity; do
        [ -r "$f" ] && { printf '%%%s' "$(cat "$f" 2>/dev/null)"; return; }
    done
    printf 'bilinmiyor'
}

show_info() {
    load_config
    local user ips
    user=$(whoami)
    ips=$(get_ips)

    printf '\n%s╔══════════════ SSHphone bağlantı bilgisi ══════════════╗%s\n' "$C_GREEN" "$C_RESET"
    printf '  Cihaz      : %s (Android %s, %s)\n' "$(device_model)" "$(getprop ro.build.version.release 2>/dev/null)" "$(uname -m)"
    if sshd_running; then
        printf '  Durum      : %sÇALIŞIYOR%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '  Durum      : %sKAPALI%s  (başlat: sshphone start)\n' "$C_RED" "$C_RESET"
    fi
    printf '  Kullanıcı  : %s\n' "$user"
    printf '  Port       : %s\n' "$SSHPHONE_PORT"
    printf '  Parola     : %s\n' "$(if [ "$(get_sshd_opt PasswordAuthentication)" = no ]; then echo kapalı; elif has_password; then echo açık; else echo 'açık (parola ayarlı DEĞİL!)'; fi)"
    printf '  Anahtarlar : %s\n' "$(if has_keys; then grep -cE '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS"; else echo 0; fi)"
    [ -n "$SSHPHONE_DISTRO" ] && printf '  Linux      : %s (otomatik giriş: %s)\n' "$SSHPHONE_DISTRO" "$SSHPHONE_AUTOLOGIN"
    echo
    if [ -n "$ips" ]; then
        echo "  Bağlanmak için (bilgisayardan):"
        while read -r iface ip; do
            printf '    %sssh -p %s %s@%s%s   %s# %s%s\n' "$C_BOLD" "$SSHPHONE_PORT" "$user" "$ip" "$C_RESET" \
                "$C_DIM" "$(describe_iface "$iface" "$ip")" "$C_RESET"
        done <<<"$ips"
    else
        warn "IP adresi otomatik bulunamadı (Android kısıtlaması olabilir)."
        echo "  Ayarlar > Wi-Fi > bağlı ağ ayrıntılarından IP'yi öğrenip:"
        printf '    %sssh -p %s %s@<TELEFON_IP>%s\n' "$C_BOLD" "$SSHPHONE_PORT" "$user" "$C_RESET"
    fi
    echo
    printf '  Dosya aktarımı: %sscp -P %s dosya %s@<IP>:~/%s  veya SFTP (FileZilla, WinSCP)\n' "$C_BOLD" "$SSHPHONE_PORT" "$user" "$C_RESET"
    printf '  Dış ağdan erişim: %ssshphone tunnel%s  veya Tailscale uygulaması\n' "$C_BOLD" "$C_RESET"
    printf '%s╚═══════════════════════════════════════════════════════╝%s\n\n' "$C_GREEN" "$C_RESET"
}

show_status() {
    load_config
    if sshd_running; then
        ok "sshd çalışıyor (PID: $(sshd_pid))"
    else
        err "sshd çalışmıyor."
    fi
    info "Port: $SSHPHONE_PORT | Parola girişi: $(get_sshd_opt PasswordAuthentication) | Otomatik başlatma: $SSHPHONE_AUTOSTART | Wake-lock: $SSHPHONE_WAKELOCK"
    if [ -n "$SSHPHONE_DISTRO" ]; then
        if distro_installed "$SSHPHONE_DISTRO"; then
            info "Dağıtım: $SSHPHONE_DISTRO (kurulu) | SSH otomatik giriş: $SSHPHONE_AUTOLOGIN"
        else
            warn "Dağıtım: $SSHPHONE_DISTRO (kurulu DEĞİL)"
        fi
    fi
    if [ -f "$BOOT_FILE" ]; then info "Açılış betiği: var ($BOOT_FILE)"; else warn "Açılış betiği yok."; fi
    if [ -f "$LOG_FILE" ]; then
        echo; info "Son günlük satırları ($LOG_FILE):"
        tail -n 5 "$LOG_FILE"
    fi
}

show_motd() {
    load_config
    local mem disk up
    mem=$(free -h 2>/dev/null | awk '/^Mem/ {print $3" / "$2}')
    disk=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $3" / "$2" ("$5")"}')
    up=$(uptime -p 2>/dev/null | sed 's/^up //')
    printf '%s' "$C_CYAN"
    printf '┌─ SSHphone ─────────────────────────────────────────\n'
    printf '│ Cihaz   : %s, Android %s (%s)\n' "$(device_model)" "$(getprop ro.build.version.release 2>/dev/null)" "$(uname -m)"
    printf '│ Açık    : %s\n' "${up:-?}"
    printf '│ Bellek  : %s\n' "${mem:-?}"
    printf '│ Disk    : %s\n' "${disk:-?}"
    printf '│ Batarya : %s\n' "$(battery_level)"
    [ -n "$SSHPHONE_DISTRO" ] && printf '│ Linux   : %s  ->  sshphone linux\n' "$SSHPHONE_DISTRO"
    printf '│ Yardım  : sshphone help\n'
    printf '└────────────────────────────────────────────────────%s\n' "$C_RESET"
}

# --------------------------------------------------------------------------- #
#  Dış ağdan erişim (Cloudflare Quick Tunnel)
# --------------------------------------------------------------------------- #
run_tunnel() {
    load_config
    sshd_running || start_sshd || exit 1
    if ! command -v cloudflared >/dev/null 2>&1; then
        step "cloudflared kuruluyor"
        pkg_install cloudflared || die "cloudflared kurulamadı."
    fi
    cat <<EOF

${C_BOLD}Cloudflare Quick Tunnel başlatılıyor...${C_RESET}
Aşağıda ${C_BOLD}https://XXXX.trycloudflare.com${C_RESET} biçiminde bir adres göreceksiniz.

Bilgisayarınızda cloudflared kurulu olmalı (https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
Sonra şu komutla bağlanın (XXXX yerine verilen adres):

  ${C_BOLD}ssh -o ProxyCommand="cloudflared access ssh --hostname %h" $(whoami)@XXXX.trycloudflare.com${C_RESET}

Tüneli kapatmak için Ctrl+C. Arka planda tutmak için tmux içinde çalıştırın:
  tmux new -s tunnel 'sshphone tunnel'

EOF
    exec cloudflared tunnel --no-autoupdate --url "ssh://localhost:$SSHPHONE_PORT"
}

# --------------------------------------------------------------------------- #
#  Kurulum / kaldırma
# --------------------------------------------------------------------------- #
do_install() {
    require_termux
    banner
    load_config

    echo "Bu kurulum telefonunuzu SSH ile bağlanılabilen bir Linux sunucusuna (VDS) dönüştürür."
    echo "Root gerekmez. Kurulum boyunca birkaç soru sorulacak; varsayılan için Enter'a basın."
    echo

    local port
    while true; do
        port=$(ask "SSH portu (1024-65535)" "$SSHPHONE_PORT")
        valid_port "$port" && break
        warn "Geçersiz port. Root olmadan 1024 altındaki portlar kullanılamaz."
    done
    SSHPHONE_PORT="$port"

    update_system

    step "Gerekli paketler kuruluyor"
    pkg_install "${BASE_PACKAGES[@]}" || die "Paketler kurulamadı. 'termux-change-repo' ile ayna değiştirip tekrar deneyin."
    ok "Paketler kuruldu."

    save_config
    configure_sshd
    setup_password || true

    step "SSH anahtarı (isteğe bağlı, önerilir)"
    if confirm "Bilgisayarınızın açık SSH anahtarını şimdi eklemek ister misiniz?" h; then
        add_key || true
    fi

    step "Tam Linux ortamı (isteğe bağlı)"
    echo "Termux zaten bir Linux ortamıdır; ancak apt/systemd tarzı tam bir dağıtım"
    echo "(Ubuntu, Debian vb.) isterseniz proot ile kurulabilir (~300-800 MB)."
    if confirm "Bir Linux dağıtımı kurulsun mu?" h; then
        install_distro
        load_config
        if confirm "SSH ile bağlanınca doğrudan $SSHPHONE_DISTRO ortamına girilsin mi?" e; then
            SSHPHONE_AUTOLOGIN=yes
        else
            SSHPHONE_AUTOLOGIN=no
        fi
    fi

    step "Telefon depolamasına erişim (isteğe bağlı)"
    if [ ! -d "$HOME/storage" ] && confirm "Dahili depolamaya (~/storage) erişim izni verilsin mi?" h; then
        termux-setup-storage || warn "Depolama izni alınamadı."
    fi

    step "Arka planda çalışma ayarları"
    if confirm "Telefon uyusa bile SSH çalışmaya devam etsin mi? (wake-lock, biraz pil harcar)" e; then
        SSHPHONE_WAKELOCK=yes
    else
        SSHPHONE_WAKELOCK=no
    fi
    SSHPHONE_AUTOSTART=yes
    save_config

    step "SSHphone kuruluyor"
    install_self
    write_hook
    write_boot

    step "SSH sunucusu başlatılıyor"
    stop_sshd >/dev/null 2>&1
    start_sshd || true

    show_info

    cat <<EOF
${C_BOLD}Önemli ipuçları:${C_RESET}
  • Ayarlar > Uygulamalar > Termux > Pil: ${C_BOLD}Kısıtlama yok / Optimize etme${C_RESET} seçin.
  • Android 12+ arka plan süreçlerini öldürebilir ("phantom process killer").
    Bilgisayardan ADB ile kapatmak için README'deki komutlara bakın.
  • Telefon açılınca otomatik başlatma için ${C_BOLD}Termux:Boot${C_RESET} uygulamasını kurup bir kez açın.
  • Tüm komutlar için: ${C_BOLD}sshphone help${C_RESET}

EOF
}

do_uninstall() {
    require_termux
    confirm "SSHphone kaldırılsın mı? (Termux paketleri ve dağıtımlar silinmez)" h || exit 0
    load_config
    stop_sshd
    if [ -f "$BASHRC" ]; then
        sed -i "/^${HOOK_BEGIN}\$/,/^${HOOK_END}\$/d" "$BASHRC"
    fi
    rm -f "$BOOT_FILE" "$HOOK_FILE" "$CONF_FILE"
    rmdir "$CONF_DIR" 2>/dev/null || true
    if [ -f "$SSHD_CONFIG.sshphone.bak" ] && confirm "sshd_config orijinal haline döndürülsün mü?" e; then
        mv "$SSHD_CONFIG.sshphone.bak" "$SSHD_CONFIG"
    fi
    if [ -n "$SSHPHONE_DISTRO" ] && distro_installed "$SSHPHONE_DISTRO"; then
        info "Dağıtımı silmek isterseniz: proot-distro remove $SSHPHONE_DISTRO"
    fi
    if command -v proot-distro >/dev/null 2>&1; then
        info "Kurulu dağıtımları görmek için: proot-distro list"
    fi
    rm -f "$BIN_PATH"
    ok "SSHphone kaldırıldı. (openssh paketi için: pkg uninstall openssh)"
}

do_update() {
    info "Güncel sürüm indiriliyor: $SSHPHONE_RAW_URL"
    local tmp
    tmp=$(mktemp)
    curl -fsSL "$SSHPHONE_RAW_URL" -o "$tmp" || { rm -f "$tmp"; die "İndirilemedi."; }
    grep -q "SSHPHONE_VERSION" "$tmp" || { rm -f "$tmp"; die "İndirilen dosya geçerli değil."; }
    chmod 755 "$tmp"
    mv -f "$tmp" "$BIN_PATH" || { rm -f "$tmp"; die "Kurulamadı: $BIN_PATH"; }
    ok "Güncellendi: $(grep -m1 '^SSHPHONE_VERSION=' "$BIN_PATH" | cut -d'"' -f2)"
    "$BIN_PATH" hook-refresh >/dev/null 2>&1 || true
}

set_port() {
    local p="${1:-}"
    [ -z "$p" ] && p=$(ask "Yeni port" "8022")
    valid_port "$p" || die "Geçersiz port (1024-65535)."
    load_config
    SSHPHONE_PORT="$p"
    save_config
    set_sshd_opt Port "$p"
    ok "Port $p olarak ayarlandı."
    sshd_running && restart_sshd
}

# --------------------------------------------------------------------------- #
#  Menü ve yardım
# --------------------------------------------------------------------------- #
show_help() {
    cat <<EOF
${C_BOLD}SSHphone $SSHPHONE_VERSION${C_RESET} - Android telefonu SSH sunucusuna (VDS) dönüştürür

${C_BOLD}Kullanım:${C_RESET} sshphone <komut> [argüman]

${C_BOLD}Sunucu${C_RESET}
  install              Kurulum sihirbazını çalıştırır
  start | stop | restart
  status               Durum ve son günlükler
  info                 Bağlantı bilgilerini (IP, port, kullanıcı) gösterir
  port <numara>        SSH portunu değiştirir

${C_BOLD}Güvenlik${C_RESET}
  password             Giriş parolasını değiştirir
  add-key [anahtar|dosya]  Açık SSH anahtarı ekler
  keys                 Ekli anahtarları listeler
  password-auth on|off Parola ile girişi açar/kapatır (off = yalnızca anahtar)

${C_BOLD}Linux ortamı${C_RESET}
  distro [ad]          Linux dağıtımı kurar (ubuntu, debian, alpine, archlinux...)
  linux [ad]           Kurulu dağıtıma giriş yapar
  autologin on|off     SSH ile girince doğrudan dağıtıma girer

${C_BOLD}Diğer${C_RESET}
  tunnel               Cloudflare tüneli ile dış ağdan erişim
  wakelock on|off      Uyku engellemeyi açar/kapatır
  autostart on|off     Termux açılınca sshd'yi otomatik başlatır
  menu                 Etkileşimli menü
  update               Scripti GitHub'dan günceller
  uninstall            SSHphone'u kaldırır
  version | help
EOF
}

show_menu() {
    while true; do
        load_config
        printf '\n%sSSHphone%s  [sshd: %s]\n' "$C_BOLD" "$C_RESET" \
            "$(if sshd_running; then echo "${C_GREEN}açık${C_RESET}"; else echo "${C_RED}kapalı${C_RESET}"; fi)"
        cat <<'EOF'
  1) Bağlantı bilgisi        6) SSH anahtarı ekle
  2) Başlat                  7) Linux dağıtımı kur
  3) Durdur                  8) Linux'a giriş
  4) Yeniden başlat          9) Dış ağ tüneli (Cloudflare)
  5) Parola değiştir        10) Durum / günlük
  0) Çıkış
EOF
        local c
        c=$(ask "Seçim" "0")
        case "$c" in
            1) show_info ;;
            2) start_sshd ;;
            3) stop_sshd ;;
            4) restart_sshd ;;
            5) setup_password ;;
            6) add_key ;;
            7) install_distro ;;
            8) linux_login ;;
            9) run_tunnel ;;
            10) show_status ;;
            0|q) exit 0 ;;
            *) warn "Geçersiz seçim." ;;
        esac
    done
}

toggle_config() {
    local var="$1" val="$2" label="$3"
    load_config
    case "$val" in
        on|yes) printf -v "$var" yes ;;
        off|no) printf -v "$var" no ;;
        *) die "Kullanım: sshphone ${label} on|off" ;;
    esac
    save_config
    ok "$label: ${!var}"
}

# --------------------------------------------------------------------------- #
#  Ana giriş noktası
# --------------------------------------------------------------------------- #
main() {
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift

    if [ -z "$cmd" ]; then
        if is_installed; then cmd=menu; else cmd=install; fi
    fi

    case "$cmd" in
        install|kur)          do_install ;;
        start|baslat)         require_termux; start_sshd "${1:+quiet}" ;;
        stop|durdur)          require_termux; stop_sshd ;;
        restart)              require_termux; restart_sshd ;;
        status|durum)         show_status ;;
        info|bilgi)           show_info ;;
        port)                 set_port "${1:-}" ;;
        password|parola|passwd) setup_password ;;
        add-key|addkey|anahtar) add_key "$*" ;;
        keys)                 list_keys ;;
        password-auth)
            case "${1:-}" in
                on|yes) set_password_auth yes ;;
                off|no) set_password_auth no ;;
                *) die "Kullanım: sshphone password-auth on|off" ;;
            esac ;;
        distro)               require_termux; install_distro "${1:-}" ;;
        linux|login)          linux_login "${1:-}" ;;
        autologin)            set_autologin "${1:-}" ;;
        tunnel|tunel)         run_tunnel ;;
        wakelock)
            toggle_config SSHPHONE_WAKELOCK "${1:-}" wakelock
            if [ "$SSHPHONE_WAKELOCK" = yes ]; then termux-wake-lock 2>/dev/null; else termux-wake-unlock 2>/dev/null; fi ;;
        autostart)            toggle_config SSHPHONE_AUTOSTART "${1:-}" autostart ;;
        hook-refresh)         write_hook; write_boot ;;
        motd)                 show_motd ;;
        menu)                 show_menu ;;
        update|guncelle)      do_update ;;
        uninstall|kaldir)     do_uninstall ;;
        version|-v|--version) echo "SSHphone $SSHPHONE_VERSION" ;;
        help|-h|--help|yardim) show_help ;;
        *) err "Bilinmeyen komut: $cmd"; echo; show_help; exit 1 ;;
    esac
}

main "$@"

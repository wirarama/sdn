#!/usr/bin/env bash
# =============================================================================
#  setup_env.sh — Setup network simulator SDN: Ryu (controller) + Mininet
#  Target : Ubuntu 20.04 / 22.04 / 24.04 (native) atau Ubuntu di WSL2
#
#  Yang dilakukan:
#    1. Pasang paket sistem: mininet, openvswitch, iperf/iperf3, hping3, dll.
#    2. Jalankan Open vSwitch dan cek datapath (kernel / userspace).
#    3. Cari/pasang Python 3.9 (Ryu 4.34 TIDAK jalan di Python >= 3.10 karena
#       eventlet 0.30.2 bentrok dengan TimeoutError bawaan Python 3.10+).
#    4. Buat virtual environment, pasang Ryu + eventlet + library analisis.
#    5. Hubungkan library Python Mininet (paket apt) ke dalam venv.
#    6. Daftarkan kernel Jupyter dan jalankan self-test (Ryu + Mininet pingall).
#
#  Pemakaian:
#    bash setup_env.sh
#  Variabel opsional:
#    VENV_DIR=/path/venv      lokasi venv            (default: ./.venv)
#    PYTHON_BIN=python3.9     paksa interpreter      (harus 3.8 / 3.9)
#    SKIP_APT=1               lewati instalasi paket apt
#    RUN_SELFTEST=0           lewati self-test Ryu + Mininet
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/.venv}"
PYTHON_BIN="${PYTHON_BIN:-}"
SKIP_APT="${SKIP_APT:-0}"
RUN_SELFTEST="${RUN_SELFTEST:-1}"
KERNEL_NAME="${KERNEL_NAME:-sdn-ryu-mininet}"
RYU_VERSION="4.34"
EVENTLET_VERSION="0.30.2"
SETUPTOOLS_VERSION="67.6.1"

c_blue='\033[1;34m'; c_yel='\033[1;33m'; c_red='\033[1;31m'; c_grn='\033[1;32m'; c_off='\033[0m'
log()  { printf "${c_blue}[setup]${c_off} %s\n" "$*"; }
ok()   { printf "${c_grn}[ ok  ]${c_off} %s\n" "$*"; }
warn() { printf "${c_yel}[warn ]${c_off} %s\n" "$*"; }
die()  { printf "${c_red}[error]${c_off} %s\n" "$*" >&2; exit 1; }

# ----------------------------------------------------------------- 0. cek OS --
[[ "$(uname -s)" == "Linux" ]] || die "Mininet hanya berjalan di Linux. Di Windows gunakan setup_env.bat (memakai WSL2)."

IS_WSL=0
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=1
    if ! grep -qi "wsl2\|microsoft-standard" /proc/version; then
        die "Terdeteksi WSL1. Mininet butuh WSL2: jalankan 'wsl --set-version <distro> 2' di PowerShell."
    fi
    log "Terdeteksi WSL2."
fi

SUDO=""
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Butuh sudo (atau jalankan sebagai root)."
    SUDO="sudo"
    log "Beberapa langkah butuh sudo — masukkan password bila diminta."
    $SUDO -v
fi

# -------------------------------------------------------- 1. paket sistem ----
if [[ "$SKIP_APT" != "1" ]]; then
    command -v apt-get >/dev/null 2>&1 || die "Script ini untuk distro berbasis apt (Ubuntu/Debian). Pasang paket manual lalu jalankan dengan SKIP_APT=1."
    log "Memasang paket sistem (mininet, openvswitch, iperf, hping3, ...)"
    $SUDO apt-get update -y
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        mininet openvswitch-switch \
        iperf iperf3 hping3 curl \
        net-tools iproute2 iputils-ping ethtool tcpdump psmisc \
        git build-essential python3-venv python3-dev
    ok "Paket sistem terpasang."
else
    warn "SKIP_APT=1 → instalasi paket apt dilewati."
fi

for bin in mn ovs-vsctl mnexec; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' tidak ditemukan. Pastikan paket mininet & openvswitch-switch terpasang."
done

# ------------------------------------------------------ 2. Open vSwitch -----
log "Menjalankan Open vSwitch ..."
if ! $SUDO ovs-vsctl show >/dev/null 2>&1; then
    $SUDO service openvswitch-switch start >/dev/null 2>&1 \
      || $SUDO /usr/share/openvswitch/scripts/ovs-ctl start >/dev/null 2>&1 \
      || true
fi
$SUDO ovs-vsctl show >/dev/null 2>&1 && ok "Open vSwitch berjalan ($(ovs-vsctl --version | head -1))." \
    || die "Open vSwitch gagal dijalankan. Coba: sudo service openvswitch-switch restart"

OVS_DATAPATH="kernel"
if ! { [[ -d /sys/module/openvswitch ]] || $SUDO modprobe openvswitch 2>/dev/null; }; then
    OVS_DATAPATH="user"
    warn "Modul kernel 'openvswitch' tidak tersedia → notebook akan memakai datapath userspace (datapath='user')."
    [[ $IS_WSL == 1 ]] && warn "Ini wajar di sebagian kernel WSL2; simulasi tetap jalan, hanya sedikit lebih lambat."
else
    ok "Datapath OVS: kernel."
fi

# -------------------------------------------- 3. Python 3.8/3.9 untuk Ryu ---
py_ok() { "$1" -c 'import sys; sys.exit(0 if sys.version_info[:2] in ((3,8),(3,9)) else 1)' >/dev/null 2>&1; }

find_python() {
    local c
    for c in "$PYTHON_BIN" python3.9 python3.8; do
        [[ -z "$c" ]] && continue
        if command -v "$c" >/dev/null 2>&1 && py_ok "$c"; then command -v "$c"; return 0; fi
    done
    return 1
}

PY="$(find_python || true)"

if [[ -z "$PY" && "$SKIP_APT" != "1" ]] && grep -qi ubuntu /etc/os-release 2>/dev/null; then
    log "Python 3.9 belum ada → mencoba PPA deadsnakes ..."
    if $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common >/dev/null \
       && $SUDO add-apt-repository -y ppa:deadsnakes/ppa \
       && $SUDO apt-get update -y \
       && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y python3.9 python3.9-venv python3.9-dev; then
        PY="$(find_python || true)"
    else
        warn "PPA deadsnakes gagal."
    fi
fi

if [[ -z "$PY" ]]; then
    log "Mencoba memasang Python 3.9 lewat 'uv' ..."
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh | sh || die "Gagal memasang uv. Pasang Python 3.9 manual lalu jalankan: PYTHON_BIN=/path/python3.9 bash setup_env.sh"
        export PATH="$HOME/.local/bin:$PATH"
    fi
    uv python install 3.9
    PY="$(uv python find 3.9)"
    py_ok "$PY" || die "Python 3.9 dari uv tidak valid."
fi
ok "Interpreter untuk venv: $PY ($("$PY" --version 2>&1))"

# ------------------------------------------------------------- 4. venv -----
if [[ -d "$VENV_DIR" ]] && ! py_ok "$VENV_DIR/bin/python"; then
    warn "venv lama di $VENV_DIR bukan Python 3.8/3.9 → dibuat ulang."
    rm -rf "$VENV_DIR"
fi
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    log "Membuat virtual environment: $VENV_DIR"
    mkdir -p "$(dirname "$VENV_DIR")"
    "$PY" -m venv "$VENV_DIR"
fi
VPY="$VENV_DIR/bin/python"

log "Memasang Ryu $RYU_VERSION + eventlet $EVENTLET_VERSION ..."
"$VPY" -m pip install --upgrade pip
# Ryu 4.34 memakai pbr + easy_install lama → setuptools harus dipin & build isolation dimatikan
"$VPY" -m pip install "setuptools==$SETUPTOOLS_VERSION" wheel pbr
"$VPY" -m pip install --no-build-isolation "ryu==$RYU_VERSION" "eventlet==$EVENTLET_VERSION"

log "Memasang library analisis + Jupyter (requirements.txt) ..."
"$VPY" -m pip install -r "$SCRIPT_DIR/requirements.txt"
# jaga agar dependensi baru tidak menaikkan versi yang dipin Ryu
"$VPY" -m pip install "eventlet==$EVENTLET_VERSION" "setuptools==$SETUPTOOLS_VERSION" >/dev/null

# --------------------------------------- 5. library Python Mininet → venv ---
SITE="$("$VPY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
MN_PKG=""
for sp in /usr/bin/python3 /usr/local/bin/python3; do
    [[ -x "$sp" ]] || continue
    MN_PKG="$("$sp" -c 'import os, mininet; print(os.path.dirname(mininet.__file__))' 2>/dev/null || true)"
    [[ -n "$MN_PKG" ]] && break
done
if [[ -n "$MN_PKG" ]]; then
    ln -sfn "$MN_PKG" "$SITE/mininet"
    ok "Library Mininet ($MN_PKG) ditautkan ke venv."
else
    warn "Library Python Mininet sistem tidak ditemukan → pasang dari GitHub."
    "$VPY" -m pip install "git+https://github.com/mininet/mininet.git@2.3.0"
fi

# ------------------------------------------------------ 6. Jupyter kernel ---
"$VPY" -m ipykernel install --user --name "$KERNEL_NAME" --display-name "Python 3.9 (Ryu + Mininet)" >/dev/null
ok "Kernel Jupyter '$KERNEL_NAME' terdaftar."

mkdir -p "$SCRIPT_DIR/results" "$SCRIPT_DIR/runtime" "$SCRIPT_DIR/ryu_apps"
cat > "$SCRIPT_DIR/.sdn_env" <<EOF
VENV_DIR=$VENV_DIR
OVS_DATAPATH=$OVS_DATAPATH
IS_WSL=$IS_WSL
EOF

# ----------------------------------------------------------- 7. verifikasi --
log "Verifikasi import ..."
"$VPY" - <<'PYEOF'
import importlib, sys
mods = ["ryu", "eventlet", "mininet.net", "networkx", "numpy", "pandas", "sklearn", "matplotlib"]
for m in mods:
    mod = importlib.import_module(m)
    print(f"   {m:<12} {getattr(mod, '__version__', 'ok')}")
print("   python      ", sys.version.split()[0])
PYEOF
"$VENV_DIR/bin/ryu-manager" --version 2>&1 | sed 's/^/   /'

if [[ "$RUN_SELFTEST" == "1" ]]; then
    log "Self-test: Ryu simple_switch_13 + Mininet (topologi single,3) pingall ..."
    $SUDO mn -c >/dev/null 2>&1 || true
    "$VENV_DIR/bin/ryu-manager" --ofp-tcp-listen-port 6653 ryu.app.simple_switch_13 \
        > "$SCRIPT_DIR/runtime/selftest_ryu.log" 2>&1 &
    RYU_PID=$!
    sleep 3
    SW_OPTS="ovsk,protocols=OpenFlow13"
    [[ "$OVS_DATAPATH" == "user" ]] && SW_OPTS="ovsk,protocols=OpenFlow13,datapath=user"
    if $SUDO mn --topo single,3 --controller remote,ip=127.0.0.1,port=6653 \
            --switch "$SW_OPTS" --test pingall 2>&1 | tee "$SCRIPT_DIR/runtime/selftest_mn.log" | grep "Results: 0% dropped" >/dev/null; then
        ok "Self-test lulus: 0% packet dropped."
    else
        warn "Self-test belum lulus — lihat runtime/selftest_mn.log dan runtime/selftest_ryu.log"
    fi
    kill "$RYU_PID" >/dev/null 2>&1 || true
    $SUDO mn -c >/dev/null 2>&1 || true
fi

echo
ok "Environment siap."
echo "   Aktifkan venv  : source \"$VENV_DIR/bin/activate\""
echo "   Jalankan Jupyter (root, wajib untuk Mininet): bash run_jupyter.sh"
echo "   Notebook       : notebooks/00_cek_environment.ipynb → 01_optimasi_jaringan.ipynb → 02_deteksi_ddos.ipynb"

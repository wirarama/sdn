#!/usr/bin/env bash
# =============================================================================
#  run_jupyter.sh — Jalankan JupyterLab dari venv sebagai root.
#  Mininet wajib root (membuat network namespace, veth, OVS bridge), sehingga
#  kernel notebook harus berjalan sebagai root agar MODE='mininet' aktif.
#  Pemakaian: bash run_jupyter.sh          (opsional: PORT=8899 bash run_jupyter.sh)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${VENV_DIR:-}" && -f "$SCRIPT_DIR/.sdn_env" ]]; then
    VENV_DIR="$(grep '^VENV_DIR=' "$SCRIPT_DIR/.sdn_env" | cut -d= -f2-)"
fi
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/.venv}"
PORT="${PORT:-8888}"

[[ -x "$VENV_DIR/bin/jupyter" ]] || { echo "[error] venv belum ada di $VENV_DIR — jalankan: bash setup_env.sh"; exit 1; }

SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
$SUDO ovs-vsctl show >/dev/null 2>&1 || $SUDO service openvswitch-switch start >/dev/null 2>&1 || true
$SUDO mn -c >/dev/null 2>&1 || true            # bersihkan sisa simulasi sebelumnya

mkdir -p "$SCRIPT_DIR/results" "$SCRIPT_DIR/runtime" "$SCRIPT_DIR/ryu_apps"
OWNER="$(id -u):$(id -g)"
restore_owner() {
    # file yang dibuat kernel root dikembalikan ke user biasa
    $SUDO chown -R "$OWNER" "$SCRIPT_DIR/results" "$SCRIPT_DIR/runtime" \
        "$SCRIPT_DIR/ryu_apps" "$SCRIPT_DIR/notebooks" 2>/dev/null || true
    $SUDO mn -c >/dev/null 2>&1 || true
}
trap restore_owner EXIT

echo "[info] JupyterLab (root) → buka URL http://127.0.0.1:$PORT/lab?token=... yang tampil di bawah"
echo "[info] Tekan Ctrl+C dua kali untuk berhenti."
$SUDO env HOME=/root PATH="$VENV_DIR/bin:$PATH" VIRTUAL_ENV="$VENV_DIR" \
    "$VENV_DIR/bin/jupyter" lab --allow-root --no-browser \
    --ip=127.0.0.1 --port="$PORT" --notebook-dir="$SCRIPT_DIR/notebooks" || true

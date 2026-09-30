#!/usr/bin/env bash
#
# capture-dvb.sh — deja corriendo una captura para atrapar el momento EXACTO
# en que se caen los adapters de la(s) TBS. El log de arranque no sirve porque
# ahi todo esta sano; hay que registrar la ventana de la falla.
#
# Uso:
#   sudo ./scripts/capture-dvb.sh            # captura en ./dvb-capture-<fecha>/
#   sudo ./scripts/capture-dvb.sh /ruta/out  # elige carpeta de salida
#
# Genera:
#   - estado-inicial.txt : lspci de las TBS, /dev/dvb, modulos, cmdline
#   - kernel.log         : dmesg -wT en vivo (todo el kernel)
#   - tbs.log            : solo lineas relevantes (tbs/pcie/i2c/dma/reset/...)
#   - watch.log          : marca de tiempo cada vez que CAMBIA el nro de adapters
#
# Deja esto corriendo (o como servicio) hasta que ocurra la caida. Cuando pase,
# Ctrl-C y comparte la carpeta completa.
#
set -u

OUT="${1:-./dvb-capture-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
echo ">> Guardando en: $OUT"

# ---- estado inicial ----
{
  echo "===== fecha ====="; date
  echo; echo "===== kernel cmdline ====="; cat /proc/cmdline
  echo; echo "===== TBS en el bus PCI (vendor 544d) ====="
  lspci -nn | grep -i '544d' || echo "  (ninguna TBS visible en lspci!)"
  echo; echo "===== lspci -vvv de las TBS ====="
  for slot in $(lspci -n | awk '/544d:/{print $1}'); do
    echo "--- $slot ---"; lspci -vvv -s "$slot" 2>/dev/null
  done
  echo; echo "===== /dev/dvb ====="; ls -l /dev/dvb 2>/dev/null || echo "  (no existe /dev/dvb)"
  echo; echo "===== modulos TBS/dvb ====="; lsmod | grep -Ei 'tbs|dvb|stid|stv|mxl' || true
  echo; echo "===== SWIOTLB ====="; dmesg | grep -i swiotlb || true
} > "$OUT/estado-inicial.txt" 2>&1
echo ">> estado-inicial.txt listo"

# ---- watcher: nro de adapters DVB ----
(
  prev=""
  while :; do
    n=$(ls -d /dev/dvb/adapter* 2>/dev/null | wc -l)
    fe=$(ls /dev/dvb/adapter*/frontend* 2>/dev/null | wc -l)
    now="adapters=$n frontends=$fe"
    if [[ "$now" != "$prev" ]]; then
      echo "$(date '+%F %T')  $now" | tee -a "$OUT/watch.log"
      prev="$now"
    fi
    sleep 2
  done
) &
WATCH_PID=$!

# ---- logs de kernel ----
dmesg -wT | tee "$OUT/kernel.log" \
  | grep --line-buffered -iE 'tbs|ecp3|dvb|i2c|aer|pcie|pci|mxl|stid|stv|si218|reset|error|timeout|irq|dma|swiotlb' \
  >> "$OUT/tbs.log" &
DMESG_PID=$!

cleanup() {
  echo; echo ">> deteniendo captura..."
  kill "$WATCH_PID" "$DMESG_PID" 2>/dev/null
  echo ">> Listo. Comparte la carpeta: $OUT"
  exit 0
}
trap cleanup INT TERM

echo ">> Capturando. Reproduce la carga hasta que se caigan los adapters."
echo ">> Cuando ocurra (o ya lo tengas), presiona Ctrl-C."
wait "$DMESG_PID"

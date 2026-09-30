# Diagnóstico: "no feed to stop" + adapters que desaparecen (TBS6909x / TBS6916)

Basado en el `dmesg` de arranque de la máquina `ometepeas` (kernel
6.5.11-060511-generic, Ubuntu) + la captura original del flood.

## TL;DR

- **El `no feed to stop` es un síntoma cosmético, NO la causa** de que se caigan
  los adapters. Lo genera una aplicación (`streamer`) que hace
  `NET_ADD_IF` + `NET_REMOVE_IF` sobre cada adapter (enumeración).
- **El sistema es una VM de VMware** y las TBS entran por **PCI passthrough**.
  Ese es el punto frágil.
- En el arranque analizado **solo aparece UNA tarjeta** (TBS **6909x**,
  STiD135, adapters 0–7 en `0000:03:00.0`). **La 6916 no está en el bus PCI**
  de la VM. Cuando "se van todos los adapters", lo más probable es que una
  tarjeta entera deje de enumerarse a nivel PCIe/passthrough.
- Factores de riesgo detectados: **SWIOTLB de solo 64 MB** (bounce buffering
  por software para el DMA de la tarjeta), **AER/LTR/DPC no soportados** por la
  plataforma (los errores de PCIe ni siquiera se loguean), y el **límite de LLR
  del STiD135** (`Current 84 / Max 90 MLLR/s`) cerca del techo.

## Evidencia (líneas clave del dmesg)

Entorno virtual:
```
DMI: VMware, Inc. VMware20,1/440BX Desktop Reference Platform
Hypervisor detected: VMware
```

DMA por bounce buffer, pequeño:
```
PCI-DMA: Using software bounce buffering for IO (SWIOTLB)
software IO TLB: mapped [mem 0x...bc000000-0x...c0000000] (64MB)
```

Sin AER (no se registran errores de PCIe → la caída puede ser "silenciosa"):
```
acpi PNP0A08:01: _OSC: platform does not support [PCIeHotplug SHPCHotplug PME AER LTR DPC]
```

Una sola TBS en el bus (6909x). No hay un segundo `544d:` (la 6916):
```
pci 0000:03:00.0: [544d:6178] type 00 class 0x048000
TBSECP3 driver 0000:03:00.0: TurboSight TBS 6909x (Octa DVB-S/S2/S2X)
... registering adapter 0..7 frontend 0 (TBS 6909x) ...
TBSECP3 driver 0000:03:00.0: ... PCI 0000:03:00.0, IRQ 47, MMIO 0xfd300000
```

El flood aquí = la app `streamer` enumerando (benigno):
```
streamer[1393]: memfd_create() called without MFD_EXEC or MFD_NOEXEC_SEAL set
dvb_net: created network interface dvb7_0
dvb_net: dvb7_0: no feed to stop
dvb_net: removed network interface dvb7_0
... (repite dvb6_0 ... dvb0_0)
```

Demod trabajando cerca del límite de procesamiento (STiD135):
```
Symbol rate = 27901 Ks
Current LLR  = 84 MLLR/s
Max LLR allowed = 90 MLLR/s
```

## Por qué "se van todos los adapters"

En este log NO se cae nada (arranque sano). La desaparición ocurre en otro
momento y **no quedó capturada**. Con la evidencia del entorno, los sospechosos,
por probabilidad:

1. **Passthrough PCIe inestable (VMware).** Si una tarjeta deja de enumerarse
   (como la 6916 aquí, ausente del bus), TODOS sus adapters desaparecen de
   golpe. Es el patrón clásico de "se fue la tarjeta entera". Como la plataforma
   **no soporta AER**, un error de enlace PCIe no genera log → parece que
   "desaparecieron sin más".
2. **Agotamiento de SWIOTLB (64 MB).** 8+ tuners haciendo DMA de TS completo en
   una VM que usa bounce buffering por software pueden agotar los 64 MB → fallos
   de mapeo DMA → el driver TBSECP3 se atasca/resetea → caen adapters.
3. **Sobre-suscripción del LLR del STiD135.** El 6909x comparte un presupuesto
   global de LLR (FEC) entre sus 8 demods. Con varios muxes de símbolo alto
   (p.ej. 27901 Ks) a la vez se supera `Max LLR allowed` y algunos demods dejan
   de enganchar.

## Qué falta para cerrar el diagnóstico

El log entregado es de un arranque **sano**. Para atrapar la causa real hay que
capturar el `dmesg` **en el momento en que se caen**. Ver `scripts/capture-dvb.sh`.

Además, confirmar:
- `lspci -nn | grep -i 544d` → ¿la VM ve 1 o 2 tarjetas TBS? (clave)
- Qué es exactamente `streamer` y si se reinicia en bucle
  (`systemctl status streamer` / su log). Si re-enumera cada ~20 s, eso explica
  el flood periódico de la primera captura.
- En el host ESXi: `vmkernel.log` en el instante de la caída (errores de
  passthrough / MSI / reset del dispositivo).

## Mitigaciones (aplicar y medir)

Ver `mitigations/` y el README. Resumen:

1. **Agrandar SWIOTLB** en la línea de comandos del kernel (GRUB):
   `swiotlb=131072` (~512 MB) — reduce el agotamiento del bounce buffer.
   Idealmente, además, habilitar IOMMU/DirectPath correctamente en el host para
   no depender del bounce buffering.
2. **Estabilizar el passthrough** en VMware (reservar toda la RAM de la VM —
   *Reserve all guest memory* es obligatorio para DirectPath I/O; fijar la VM a
   un nodo NUMA; no usar snapshots con el dispositivo asignado).
3. **No sobre-suscribir el LLR** del 6909x: repartir/limitar cuántos muxes de
   símbolo alto se sintonizan simultáneamente.
4. **Silenciar el ruido** `no feed to stop` (cosmético): parche o workaround ya
   incluidos (`patches/`, `workaround/`).

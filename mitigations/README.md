# Mitigaciones para "se caen todos los adapters" (TBS en VM VMware)

> Orden sugerido. Aplica de a UNA, reinicia y mide, para saber cuál ayuda.

## 1. Confirmar cuántas tarjetas ve la VM (30 segundos, sin reiniciar)

```bash
lspci -nn | grep -i 544d
```

- Si ves **una sola** línea `544d:...` pero deberían ser dos (6909x + 6916),
  el problema es de **passthrough en el host** (la 6916 no está llegando a la
  VM). Ese es el caso "se fue la tarjeta entera". Solución en el punto 3.
- Si ves **las dos** y aun así desaparecen bajo uso, apunta a DMA/estabilidad
  (puntos 2 y 4).

## 2. Agrandar el buffer de DMA (SWIOTLB)

El kernel arrancó con bounce buffering de **solo 64 MB**
(`software IO TLB: ... (64MB)`). Con 8+ tuners haciendo DMA de TS completo en una
VM eso se puede agotar y tumbar la tarjeta.

Editar `/etc/default/grub`, añadir a `GRUB_CMDLINE_LINUX_DEFAULT`:

```
swiotlb=131072
```

(≈512 MB; `swiotlb=` es número de slots). Luego:

```bash
sudo update-grub && sudo reboot
```

Verificar tras el reboot:

```bash
dmesg | grep -i swiotlb     # debe mostrar un tamaño mayor
```

## 3. Estabilizar el PCI passthrough (lado host, VMware ESXi/Workstation)

Requisitos para DirectPath I/O estable con tarjetas que hacen DMA intensivo:

- **Reserve all guest memory (All locked)**: OBLIGATORIO con passthrough.
  VM Settings → Memory → *Reserve all guest memory*.
- Asignar **ambas** tarjetas TBS al passthrough y verificarlas en la VM con
  `lspci`. Si una no aparece, revisar en el host que el dispositivo esté
  marcado como passthrough y sin errores.
- Fijar la VM a un **único nodo NUMA** (este host tiene 2 nodos; el bus 04 está
  en node 1). Mezclar NUMA + passthrough agrava la latencia de DMA.
- **No usar snapshots** ni suspender/reanudar la VM con el dispositivo asignado.
- Revisar el `vmkernel.log` del host en el instante de la caída.

## 4. No sobre-suscribir el LLR del STiD135 (6909x)

El 6909x comparte un presupuesto global de LLR (FEC) entre sus 8 demods. En el
log: `Current LLR = 84 / Max LLR allowed = 90 MLLR/s` con un mux de 27901 Ks.
Sintonizar varios muxes de símbolo alto a la vez supera el techo y algunos
demods dejan de enganchar (se ven como "caídos").

- Repartir los muxes de alto SR entre menos tuners simultáneos.
- Comprobar si `streamer` intenta abrir los 8 a la vez con SR alto.

## 5. Revisar la app `streamer`

En el log, `streamer` (pid 1393) hace `NET_ADD_IF`+`NET_REMOVE_IF` por cada
adapter. Si eso se repite en bucle (cada ~20 s como en la primera captura),
probablemente la app **se reinicia** o **re-escanea** en loop:

```bash
systemctl status streamer 2>/dev/null || ps aux | grep -i streamer
journalctl -u streamer -n 200 --no-pager 2>/dev/null
```

Si está en un bucle de reinicio, la causa de la caída está en la app o en lo que
la hace fallar (probablemente los puntos 2–4).

## 6. Silenciar el ruido cosmético (opcional)

`no feed to stop` no rompe nada; si molesta en el log, aplica el
`patches/0001-...` o el workaround de NetworkManager (ver README principal).

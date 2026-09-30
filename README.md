# fix_nofeed_no_stop

Fix / silenciado del flood en `dmesg`:

```
dvb_net: dvb0_0: no feed to stop
dvb_net: dvb1_0: no feed to stop
...
dvb_net: dvb27_0: no feed to stop
```

Observado con dos placas TBS multi-tuner (p. ej. **TBS6909x** + **TBS6916**),
que juntas registran ~28 adaptadores DVB → ~28 interfaces de red `dvbX_0`.

---

## 1. Qué está pasando (causa raíz)

El mensaje **no viene del driver de TBS**, viene de `dvb-core`, en
`drivers/media/dvb-core/dvb_net.c`, función `dvb_net_feed_stop()`:

```c
if (priv->feedtype == DVB_NET_FEEDTYPE_MPE) {
    if (priv->secfeed) {
        ...
    } else
        pr_err("%s: no feed to stop\n", dev->name);      // <-- MPE
} else if (priv->feedtype == DVB_NET_FEEDTYPE_ULE) {
    if (priv->tsfeed) {
        ...
    } else
        pr_err("%s: no ts feed to stop\n", dev->name);   // <-- ULE
}
```

Al inicio del archivo hay `#define pr_fmt(fmt) "dvb_net: " fmt`, por eso el
texto final es exactamente `dvb_net: dvbX_0: no feed to stop`.

`dvb_net_feed_stop()` se ejecuta:

- en cada **ndo_stop** (cuando la interfaz se pone *down*), y
- en cada cambio de **rx-mode / lista multicast**, vía
  `dvb_net_set_multicast_list()` → `wq_set_multicast_list()`, que **siempre**
  llama a `dvb_net_feed_stop()` (y luego a `dvb_net_feed_start()`).

Como esas interfaces `dvbX_0` **no tienen un feed IP corriendo**
(`secfeed`/`tsfeed == NULL`) — que es lo normal si no usas MPE/ULE sobre IP —
cada una de esas llamadas cae en el `else` y escribe la línea a **nivel ERROR**.

El detonante del flood es un **gestor de red** (NetworkManager o
systemd-networkd) que ve esas 28 interfaces tipo Ethernet e intenta
gestionarlas: periódicamente les fija rx/multicast/MAC. Eso dispara
`wq_set_multicast_list` en ráfaga sobre las 28 interfaces (por eso en tu
captura salen `dvb0_0..dvb27_0` agrupadas y se repiten ~20 s después).

**Es cosmético.** No indica pérdida de señal ni fallo de las tarjetas: solo
dice "me pediste parar un feed que no estaba corriendo". Pero satura el ring
buffer del kernel y tapa mensajes útiles.

---

## 2. Dos formas de arreglarlo

Puedes usar **la A (sin recompilar)**, **la B (parche al driver)**, o ambas.
Recomendado: aplicar A ya mismo (quita el disparador) y B cuando recompiles
los drivers TBS (deja el log limpio de forma permanente).

### A) Workaround sin recompilar — dejar de gestionar las `dvbX_0`

Le dices al gestor de red que **ignore** las interfaces DVB. Eso elimina las
llamadas periódicas a `feed_stop` y, por tanto, el flood.

**NetworkManager:**
```bash
sudo cp workaround/networkmanager/90-dvb-unmanaged.conf /etc/NetworkManager/conf.d/
sudo systemctl reload NetworkManager     # o: nmcli general reload
```

**systemd-networkd:**
```bash
sudo cp workaround/systemd-networkd/00-dvb-ignore.network /etc/systemd/network/
sudo systemctl restart systemd-networkd
```

Verifica que ya no las gestiona:
```bash
nmcli device status | grep dvb        # deben salir como 'unmanaged'
```

> Si NO usas encapsulado IP sobre DVB (MPE/ULE) — el caso habitual con
> TVHeadend/DVBLast — esto es 100% seguro: esas interfaces no te sirven para
> nada de todas formas.

### B) Parche al driver — bajar el mensaje a nivel debug

Cambia los dos `pr_err(...)` por `netdev_dbg(...)`, de modo que la línea deja
de imprimirse salvo que actives *dynamic debug* a propósito. Es la corrección
correcta: "no había feed que parar" es una condición benigna, no un error.

Ver `patches/0001-dvb_net-demote-no-feed-to-stop-messages-to-debug.patch`.

Aplicar sobre tu árbol de fuentes de los drivers TBS
(`linux_media` o `media_build/media`):

```bash
./scripts/apply-patch.sh /ruta/a/linux_media
```

El script hace backup, aplica el parche (con `git apply --recount`, y
fallback a `patch -p1` para tolerar diferencias de versión), verifica el
resultado y te recuerda cómo recompilar e instalar los módulos.

Recompilar / recargar (resumen):
```bash
# media_build:
make -j"$(nproc)" && sudo make install

# recarga (o reinicia, más seguro si hay tuners en uso):
sudo depmod -a && sudo reboot
```

---

## 3. Comprobar que quedó resuelto

```bash
# ya no debería crecer:
dmesg -w | grep 'no feed to stop'
```

Con la opción A el mensaje deja de aparecer porque nadie vuelve a llamar
`feed_stop`. Con la B, aunque algo llame `feed_stop`, la línea ya no se
imprime a nivel error.

---

## Estructura del repo

```
patches/
  0001-dvb_net-demote-no-feed-to-stop-messages-to-debug.patch
workaround/
  networkmanager/90-dvb-unmanaged.conf
  systemd-networkd/00-dvb-ignore.network
scripts/
  apply-patch.sh
```

## Notas

- Válido para cualquier tarjeta con muchos adaptadores DVB; TBS6909x/6916 solo
  lo hacen más visible por la cantidad de interfaces.
- El parche B es un cambio mínimo y "upstream-friendly": no altera la lógica,
  solo el nivel de log (igual que ya hacen el resto de trazas de esa función,
  que usan `netdev_dbg`).

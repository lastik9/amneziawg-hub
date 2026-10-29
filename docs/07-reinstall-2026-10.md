# §07 — Переустановка роутеров (OpenWrt 25.12.6, GL-MT6000) и ротация ключей, 2026-10

Все три site-узла переустановлены на OpenWrt **25.12.6** (GL-MT6000, target `mediatek/filogic`, arch `aarch64_cortex-a53`). Ключи ротированы на хабе и в реестре. Транспорт каждого узла сохранён прежним.

## Итоговое состояние

| узел | iface | WG | подсеть | транспорт | watchdog | прокси на узле |
|---|---|---|---|---|---|---|
| gorod   | `awg_hub1`  | `10.0.0.2` | `192.168.1.0/24`  | прямой UDP      | directudp | **tachyon** (не clash) |
| village | `awg_hub52` | `10.0.0.3` | `192.168.52.0/24` | дорога A (WSS)  | village   | clash |
| hub53   | `awg_hub53` | `10.0.0.4` | `192.168.53.0/24` | дорога A (WSS)  | hub53     | clash |

Новые публичные ключи — в `registry/hub-peers/*.peer.pub` (коммит ротации).

## Грабли (durable)

1. **Пустой `arch` на 25.12.6.** `ubus call system board` возвращает пустой `@.release.arch`, из-за чего штатный установщик AWG и самодельный парсер URL собирают битое имя пакета (`__`) → 404. Обход: качать пакеты напрямую, подставив арх вручную — `kmod-amneziawg_v25.12.6_aarch64_cortex-a53_mediatek_filogic.apk` (и tools, luci-proto). Либо брать `DISTRIB_ARCH` из `/etc/openwrt_release`, а не из ubus.
2. **wget через прокси падает на релизах GitHub.** На роутере с активным clash/tachyon в окружении стоят `http_proxy`/`https_proxy` → `wget` идёт в прокси и ломается на редиректе `release-assets.githubusercontent.com` (HTTP 400). Всегда `unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY` перед загрузкой.
3. **Чистый роутер: сначала интерфейс.** На свежей прошивке секции `amneziawg_awg_hubNN` ещё нет — нельзя сразу `uci set ...endpoint`. Порядок: `setup-awg.sh --mesh --no-install` создаёт интерфейс из `awg.env`; при `WSTUNNEL_FRONT=1` он сразу ставит loopback-endpoint (дорога A поднимается без ручного uci). При существующей секции скрипт её НЕ трогает (режим «создать только если нет») — тогда endpoint переключать вручную через uci.
4. **gorod на tachyon, не clash.** Для прямого UDP разницы нет — tachyon исходящий UDP роутера на хаб не перехватывает, прямой UDP встаёт сходу (RTT до хаба ~3 мс). НО если gorod когда-нибудь заблокируют и понадобится дорога A — её нельзя построить правилом `IP-CIDR,hub,PROXY` в `/opt/clash/config.yaml` (его нет). У tachyon другой механизм (sing-box / FakeIP 198.18.0.0/15 / свой nftables-tproxy) — дорогу A придётся настраивать через его движок, отдельно.

## Хаб: исправлен холодный PostUp

В `render_config` (`scripts/awg-hub.sh`) `ip route add ... 2>/dev/null` заменён на `ip route replace ... 2>/dev/null || true`. Причина: при холодном старте `awg-quick up` сам поднимает маршруты из AllowedIPs, затем PostUp повторно делал `add` → rc=2 (File exists) на последней команде → wg-quick откатывал интерфейс (`ip link delete`). `replace` идемпотентен, `|| true` гарантирует exit 0. Проявлялось только на холодном старте (операции с пирами идут через `syncconf`, PostUp не выполняется). Боевой хаб пропатчен руками + зафиксировано в репо.

## Журнал

- 2026-10 — gorod/village/hub53 переустановлены (OpenWrt 25.12.6), ключи ротированы. wstunnel на village/hub53 — v10.5.5. Исправлен холодный PostUp на хабе.

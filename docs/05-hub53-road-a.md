# §05 — hub53: дорога A и ручной откат на прямой UDP

hub53 (`awg_hub53`, `10.0.0.4`, подсеть `192.168.53.0/24`) с 2026-08-20 работает через **дорогу A** (AWG-in-WSS: awg → loopback wstunnel → clash → hub:443/WSS), как деревня. Прямой UDP (`138.16.178.138:443`) исправен и держится **ручным резервом** — watchdog его НЕ трогает.

Состояние «на дороге A»: `uci endpoint_host=127.0.0.1:51820`, wstunnel enabled+running, `awg.env WSTUNNEL_FRONT=1`, watchdog = village-лесенка.
Состояние «на прямом UDP»: `uci endpoint_host=138.16.178.138:443`, wstunnel disabled+stopped, `WSTUNNEL_FRONT=0`, watchdog = directudp-лесенка.

## Признак режима
`uci get network.@amneziawg_awg_hub53[0].endpoint_host`: `127.0.0.1` = дорога A, публичный IP = прямой UDP.

## ⚠️ Золотое правило
hub53 БЕЗ входящих (мобильный NAT). Любое переключение endpoint обкладывается **sleep-сторожем** — фоновым откатом на рабочий путь через 180с, если новый не поднял хендшейк. Иначе при сбое узел отваливается без возврата.

## Проверка ПЕРЕД переключением на дорогу A
WSS-нога может лечь (clash-нода деградирует). Всегда проверять «сейчас»:
`curl -x http://127.0.0.1:7890 -k -sS -m 12 -o /dev/null -w 'tls=%{time_appconnect}s http=%{http_code}\n' https://138.16.178.138:443/`
Ждём `tls>0 http=400`. Если таймаут (`curl (28)`) — сменить ноду в clash, повторить. НЕ переключать на мёртвую ногу.

## Процедура: прямой UDP → дорога A
(guard awg_hub53; сторож; endpoint→loopback; wstunnel up; ifup; ждать хендшейк). Полный обкатанный блок — в истории v24; ключевые шаги:
1. sleep-сторож: через 180с если хендшейк мёртв → вернуть endpoint на `138.16.178.138:443`, wstunnel stop+disable, ifup.
2. `wstunnel enable && start`; `uci set endpoint_host=127.0.0.1 endpoint_port=51820`; `uci commit`; `ifup awg_hub53`.
3. Ждать хендшейк <60с. Свежий → сторож вынесет `keep`. Мёртв → сторож откатит на UDP.
4. После успеха: watchdog заменить на village-лесенку, `WSTUNNEL_FRONT=1`.

## Процедура: дорога A → прямой UDP (ручной откат)
Прямой UDP пока whitelist не бьёт, поэтому откат безопаснее (прямой путь заведомо жив):
1. sleep-сторож наоборот: через 180с если хендшейк мёртв → вернуть на loopback+wstunnel (маловероятно, UDP надёжен).
2. `uci set endpoint_host=138.16.178.138 endpoint_port=443`; `uci commit`; `ifup awg_hub53`.
3. `wstunnel stop`; `wstunnel disable`.
4. Ждать хендшейк <60с (прямой UDP поднимается быстро, ~42мс латентность).
5. watchdog заменить на directudp-лесенку; `WSTUNNEL_FRONT=0`.

## Латентность
Дорога A: ~147мс (крюк через clash-ноду, напр. Германия). Прямой UDP: ~42мс. Плата за обфускацию транспорта.

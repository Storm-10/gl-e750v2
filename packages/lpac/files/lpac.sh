#!/bin/sh
#
# Standalone lpac wrapper: reads /etc/config/lpac and exports the matching
# LPAC_* env, then runs the real binary. The LuCI 5gmodem app does NOT use this
# path - it sets LPAC_APDU* itself and calls /usr/lib/lpac/lpac directly - so
# this is only for running `lpac` by hand from the shell.

. /lib/config/uci.sh

APDU_BACKEND="$(uci_get lpac global apdu_backend at)"
APDU_DEBUG="$(uci_get lpac global apdu_debug 0)"

# stdio, а не curl: этот пакет собран с -DLPAC_WITH_HTTP_CURL=OFF, драйвера
# driver_http_curl.so в нём НЕТ, и запрос curl валит lpac с "No HTTP driver
# found" ещё до APDU - снаружи это выглядит как "модем не отдаёт eUICC".
HTTP_BACKEND="$(uci_get lpac global http_backend stdio)"
HTTP_DEBUG="$(uci_get lpac global http_debug 0)"

# Заданный снаружи LPAC_HTTP уважаем: раньше обёртка экспортировала своё
# значение поверх, и переопределить бэкенд для одного запуска было нельзя.
[ -n "$LPAC_HTTP" ] || export LPAC_HTTP="$HTTP_BACKEND"
if [ "$HTTP_DEBUG" -eq 1 ]; then
    export LIBEUICC_DEBUG_HTTP="1"
fi

export LPAC_APDU="$APDU_BACKEND"
if [ "$APDU_DEBUG" -eq 1 ]; then
    export LIBEUICC_DEBUG_APDU="1"
fi

case "$APDU_BACKEND" in
    at)
        export LPAC_APDU_AT_DEVICE="$(uci_get lpac at device /dev/ttyUSB2)"
        [ "$(uci_get lpac at debug 0)" -eq 1 ] && export LPAC_APDU_AT_DEBUG=1
        ;;
    qmi)
        # libqmi backend - shares cdc-wdm with the data session via qmi-proxy.
        export LPAC_APDU_QMI_DEVICE="$(uci_get lpac qmi device /dev/cdc-wdm0)"
        export LPAC_APDU_QMI_UIM_SLOT="$(uci_get lpac qmi uim_slot 1)"
        ;;
    uqmi)
        export LPAC_APDU_QMI_DEVICE="$(uci_get lpac uqmi device /dev/cdc-wdm0)"
        export LPAC_APDU_QMI_UIM_SLOT="$(uci_get lpac uqmi uim_slot 1)"
        ;;
    mbim)
        # libmbim backend - shares cdc-wdm with the data session via mbim-proxy.
        export LPAC_APDU_MBIM_DEVICE="$(uci_get lpac mbim device /dev/cdc-wdm0)"
        export LPAC_APDU_MBIM_UIM_SLOT="$(uci_get lpac mbim uim_slot 1)"
        export LPAC_APDU_MBIM_USE_PROXY="$(uci_get lpac mbim use_proxy 1)"
        ;;
esac

export LPAC_DRIVER_HOME=/usr/lib/lpac
exec /usr/lib/lpac/lpac "$@"

# GL-E750 hooks of luci-app-5gmodem "Buttons": gestures and display modes of mcu-switch.
# Sourced by /usr/share/5gmodem/buttons.sh; hooks: luci-app-5gmodem docs/subsystems/extensions.md

_STATES="$_STATES double"		# double flip of the slide switch

_ext_buttons() {			# long press of the power button comes from the MCU; BTN_0 is the slide switch
	printf 'power\tLong press\tbutton\n'
	awk -F'\t' -v OFS='\t' '$1 == "BTN_0" { $3 = "switch" } { print }'
}

_ext_cond() {
	case "$1" in
		*mcu-switch\ standby*) [ "$(uci -q get mcu.global.power_saveing)" = 1 ] ;;
		*mcu-switch\ metrics*)
			if [ -n "${MCU_K+x}" ]; then [ "$MCU_K" = m ]		# set by mcu-switch: previous screen
			else read -r _p _k 2>/dev/null < /tmp/mcu-switch.pid && [ "$_k" = m ] && kill -0 "$_p" 2>/dev/null; fi ;;
		*) return 3 ;;
	esac
}

_ext_detect() {
	printf '"gl_e750":{"flip":"%s","double":"%s","long":"%s","en":{"pressed":"%s","released":"%s","double":"%s"}},' \
		"$(uci -q get "$CFG.sms.mcu_flip")" "$(uci -q get "$CFG.sms.mcu_double")" "$(uci -q get "$CFG.sms.mcu_long")" \
		"$(uci -q get "$CFG.btn_BTN_0.en_pressed")" "$(uci -q get "$CFG.btn_BTN_0.en_released")" \
		"$(uci -q get "$CFG.btn_BTN_0.en_double")"
}

# slide switch: mcu-switch (/etc/rc.button/BTN_0) tells flips from gestures and runs the action; the plain hotplug event is skipped
_ext_run() { [ "$1" != BTN_0 ] || [ -n "$MCU_GEN" ]; }

_ext_cmd() {
	case "$1" in
		smsmode)	# Show SMS mode: smsmode <flip|double|long> <page|next|prev|replay|read|exit>
			case "$2" in flip|double|long) ;; *) echo '{"error":"bad input"}'; return 0 ;; esac
			case "$3" in page|next|prev|replay|read|exit) ;; *) echo '{"error":"bad action"}'; return 0 ;; esac
			uci -q set "$CFG.sms.mcu_$2=$3" ;;
		e750en)		# slide switch action on/off: e750en <pressed|released|double> <0|1>
			case "$2" in pressed|released|double) ;; *) echo '{"error":"bad state"}'; return 0 ;; esac
			case "$3" in 0|1) ;; *) echo '{"error":"bad value"}'; return 0 ;; esac
			uci -q get "$CFG.btn_BTN_0" >/dev/null || { uci -q set "$CFG.btn_BTN_0=button"; uci -q set "$CFG.btn_BTN_0.name=BTN_0"; }
			uci -q set "$CFG.btn_BTN_0.en_$2=$3" ;;
		*) return 1 ;;
	esac
	uci -q commit "$CFG"
	echo '{"ok":1}'
}

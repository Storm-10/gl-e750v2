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
	printf '"gl_e750":{"gest":"%s","en":{"pressed":"%s","released":"%s","double":"%s"},"menu":[%s]},' \
		"$(uci -q get mcu.switch.gesture)" "$(uci -q get "$CFG.btn_BTN_0.en_pressed")" "$(uci -q get "$CFG.btn_BTN_0.en_released")" \
		"$(uci -q get "$CFG.btn_BTN_0.en_double")" "$(_e750menu)"
}

_e750menu() {				# display menu (mcu-switch menu): mcu.menu.item '<type> <command>' -> ["type","command"],...
	( . /lib/functions.sh; _c=
	  _i() { printf '%s["%s","%s"]' "$_c" "${1%% *}" "$(printf '%s' "${1#* }" | _json_esc)"; _c=,; }
	  config_load mcu; config_list_foreach menu item _i )
}

# slide switch: mcu-switch (/etc/rc.button/BTN_0) tells flips from gestures and runs the action; the plain hotplug event is skipped
_ext_run() { [ "$1" != BTN_0 ] || [ -n "$MCU_GEN" ]; }

_ext_cmd() {
	case "$1" in
		e750gest)	# double flip interval, s: e750gest <1-5>; /etc/config/mcu
			case "$2" in [1-5]) ;; *) echo '{"error":"bad interval"}'; return 0 ;; esac
			uci -q get mcu.switch >/dev/null || uci -q set mcu.switch=switch
			uci -q set "mcu.switch.gesture=$2"; uci -q commit mcu
			echo '{"ok":1}'
			return 0 ;;
		e750en)		# slide switch action on/off: e750en <pressed|released|double> <0|1>
			case "$2" in pressed|released|double) ;; *) echo '{"error":"bad state"}'; return 0 ;; esac
			case "$3" in 0|1) ;; *) echo '{"error":"bad value"}'; return 0 ;; esac
			uci -q get "$CFG.btn_BTN_0" >/dev/null || { uci -q set "$CFG.btn_BTN_0=button"; uci -q set "$CFG.btn_BTN_0.name=BTN_0"; }
			uci -q set "$CFG.btn_BTN_0.en_$2=$3" ;;
		e750menu)	# display menu items in order: e750menu ['<simple|conditional> <command>' ...]; /etc/config/mcu
			shift
			for _m in "$@"; do
				case "$_m" in simple\ ?*|conditional\ ?*) ;; *) echo '{"error":"bad item"}'; return 0 ;; esac
				cmd_allowed "${_m#* }" || { echo '{"error":"command not allowed"}'; return 0; }
			done
			uci -q get mcu.menu >/dev/null || uci -q set mcu.menu=menu
			uci -q delete mcu.menu.item
			for _m in "$@"; do uci -q add_list "mcu.menu.item=$_m"; done
			uci -q commit mcu
			echo '{"ok":1}'
			return 0 ;;
		e750lpg)	# after a save: mcu-switch mirrors the actions to /etc/config/mcu and rewrites its long press frame
			[ ! -x /usr/bin/mcu-switch ] || /usr/bin/mcu-switch lpg </dev/null >/dev/null 2>&1
			echo '{"ok":1}'
			return 0 ;;
		*) return 1 ;;
	esac
	uci -q commit "$CFG"
	echo '{"ok":1}'
}

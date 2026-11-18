# /usr/share/mcu-switch/menu.sh — mcu-switch menu: action list on the MCU screen (sourced by mcu-switch).
# Items: /etc/config/mcu menu.item '<simple|conditional> <command>' (LuCI "Buttons" > "GL-E750 Menu"); "EXIT menu" last.
# Input via $IN + USR1 (flip: mcu-switch, long press: mcu daemon): flip next item, long run it; no input 20 s: exit.
# Intro screen while mcu.menu.intro > 0 (unset: 3), one less per show. DRY=1: list frame to $MF only (lpg: long press frame).
MS=/tmp/mcu-switch.menu NEW=/tmp/5gmodem/sms_new.json TO=1950 D0=0          # cs without input; MCU pop-up lasts 20 s
if [ -z "$DRY" ]; then
   GOT=; trap 'GOT=1' USR1; own n
   trap 'log "menu: superseded"; exit 0' TERM INT HUP
   IC=$(uci -q get mcu.menu.intro) || IC=3; case $IC in ''|0|*[!0-9]*) IC=0 ;; esac
   [ "$IC" = 0 ] || { intro; send "$R1" "$R2" "$R3" "$R4"; now; D0=$((UPC + 200))
      uci -q get mcu.menu >/dev/null || uci -q set mcu.menu=menu; uci -q set mcu.menu.intro=$((IC - 1)); uci -q commit mcu; }
fi

running() { ubus -S call service list "{\"name\":\"$1\"}" 2>/dev/null | grep -q '"running": *true'; }   # procd service

label() {                                                                     # $1 type, $2 command -> R item text (any case)
   local a
   case $2 in
      *mcu-switch\ standby*) a=${2##*standby}; a=${a# }
         case $a in on|off) R="standby $a" ;; *) R=standby; [ "$1" = conditional ] && { sbw; [ $W = 1 ] && R="$R on" || R="$R off"; } ;; esac ;;
      *mcu-switch\ sms*) R=sms ;;
      *mcu-switch\ metrics*|*mcu-switch\ meters*) R=metrics ;;
      *mcu-switch\ *) set -- ${2#*mcu-switch }; config_get R "$1" name "$1"; a=${2#on_}; R="$R ${a:-on}" ;;   # module: AWG FULL
      */reboot_modem.sh*) R="reboot modem" ;;
      */simslot.sh\ set\ *) R="sim slot ${2##* }" ;;
      *buttons.sh\ svc\ *) set -- "$1" ${2#*svc }
         if [ "$1" = conditional ] && [ "$2" = toggle ]; then running "$3" && R="$3 off" || R="$3 on"; else R="$3 $2"; fi ;;
      */etc/init.d/*) set -- ${2#*/etc/init.d/}; R="$1 $2" ;;
      *) set -- $2; R=${1##*/}; R=${R%.sh}; shift; R="$R $*" ;;
   esac
}

N=0 LS=
item() {                                                                      # list item -> T<n> type, C<n> command
   case $1 in simple\ ?*|conditional\ ?*) ;; *) err "menu: bad item '$1'"; return ;; esac
   case $1 in *mcu-switch\ menu*) return ;; esac
   N=$((N + 1)); eval "T$N=\${1%% *} C$N=\${1#* }"
   label "${1%% *}" "${1#* }"; LS="$LS$R
"
}
set -f; config_list_foreach menu item item; set +f
SN=; [ -s $NEW ] && read -r SN < $NEW; SN=${SN#'{"count":'}; SN=${SN%%[!0-9]*}  # new SMS, as the daemon's icon
i=0
while IFS= read -r R; do
   i=$((i + 1)); eval "c=\$C$i"
   case $c in *mcu-switch\ sms*) [ "${SN:-0}" -gt 0 ] && R="$R ($SN new)" ;; esac
   eval "L$i=\$R"
done <<EOF
$(printf %s "$LS" | tr a-z A-Z)
EOF
N=$((N + 1)); eval "L$N='EXIT menu' C$N=exit"

S=1 c=; [ -s $MS ] && read -r c < $MS                                         # last selection
i=1; while [ $i -le $N ]; do eval "[ \"\$C$i\" = \"\$c\" ]" && S=$i; i=$((i + 1)); done

draw() {                                                                      # 4 rows from T, '*' on S; '^'/'v': more above/below
   local i r=1 p m M=$((N - 3))
   T=$((S - 2)); [ $M -gt 1 ] || M=1; [ $T -le $M ] || T=$M; [ $T -ge 1 ] || T=1   # S on row 3 until the end of the list
   i=$T; set --
   while [ $r -le 4 ]; do
      if [ $i -le $N ]; then
         eval "R=\$L$i"; [ ${#R} -le 13 ] || R=${R%"${R#?????????????}"}
         p="  "; [ $i = $S ] && p="* "
         m=" "; [ $r = 1 ] && [ $T -gt 1 ] && m="^"; [ $r = 4 ] && [ $i -lt $N ] && m="v"
         lj 13 "$R"; set -- "$@" "$p$R$m"
      else set -- "$@" ""; fi
      i=$((i + 1)) r=$((r + 1))
   done
   printf '%s\n' "$@" > "$MF"; [ -z "$DRY" ] || return 0                     # MF: first frame of the next menu, for lpg
   send "$@"; now; D=$((UPC + TO))
   eval "CMD=\$C$S G=\$L$S"                                                  # LP: frame of a long press now
   if [ "$CMD" = exit ]; then cen "MENU DONE"; lpw "" "$R"; else OFF= K=n; title; lpw "$R1" "$R2" "$R3" "$R4"; fi
}

input() { GOT=; A=; read -r A < "$IN" 2>/dev/null; : > "$IN"; log "menu: $A"; }
keep() { eval "printf '%s\n' \"\$C$S\"" > $MS; }
bye() { keep; log "menu: exit"; final "MENU DONE"; exit 0; }

run() {                                                                       # item S: start screen as mcu-switch long, then run it
   keep; eval "CMD=\$C$S G=\$L$S"; OFF= K=n; title; send "$R1" "$R2" "$R3" "$R4"; log "menu: $CMD"
   echo $$ > "$GEN"; echo "$$ a" > "$PID"; trap : TERM INT HUP              # the action's own() accepts MCU_GEN=$$
   now; T0=$UPC RUN='sh -c "$CMD"'; go menu; exit 0
}

[ -n "$DRY" ] && { draw; exit 0; }
log "menu: $((N - 1)) items"
now; r=$((D0 - UPC)); [ -n "$GOT" ] || [ $r -le 0 ] || nap $((r / 100)).$((r % 100 / 10))$((r % 10))   # intro 2 s; input ends it
[ -n "$GOT" ] && input                                                         # input during the intro only shows the list
draw
while :; do
   if [ -z "$GOT" ]; then
      now; r=$((D - UPC)); [ $r -gt 0 ] || { keep; log "menu: timeout"; final "MENU DONE"; exit 0; }
      nap $((r / 100)).$((r % 100 / 10))$((r % 10)); continue
   fi
   input
   case $A in
      flip) [ $S -lt $N ] && S=$((S + 1)) || S=1; draw ;;
      long) eval "c=\$C$S"; [ "$c" = exit ] && bye; run ;;
   esac
done

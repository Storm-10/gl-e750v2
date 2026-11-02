# /usr/share/mcu-switch/sms.sh — mcu-switch sms [new]: SMS on the MCU screen (luci-app-5gmodem "Inbox").
# new: called by 5gmodem sessionwatch after sms_new.json update; flashes and/or shows new messages.
# Input while active: mcu-switch delivers flip|double|long via $IN + USR1; actions set in 5gmodem.sms.mcu_*.
SB=/usr/share/5gmodem/smsbridge.sh NEW=/tmp/5gmodem/sms_new.json NOTI=/tmp/mcu-switch.sms.notified
LST=/tmp/mcu-switch.sms NB=$(printf '\302\240')                             # no-break space
[ -x $SB ] || { err "sms: luci-app-5gmodem not installed"; exit 1; }
g() { R=$(uci -q get "5gmodem.sms.$1") || R=$2; }
g mcu_sms 0; ON=$R; g mcu_last 1; LAST=$R; g mcu_time 10; TO=$R; g bnumber ""; BN=$R
g lednotify 0; FL=$R; g smsled ""; [ "$R" = mcu ] || FL=0; g mcu_flash 10; FT=$R
TL="s/а/a/g;s/А/A/g;s/б/b/g;s/Б/B/g;s/в/v/g;s/В/V/g;s/г/g/g;s/Г/G/g;s/д/d/g;s/Д/D/g;s/е/e/g;s/Е/E/g
s/ё/e/g;s/Ё/E/g;s/ж/zh/g;s/Ж/Zh/g;s/з/z/g;s/З/Z/g;s/и/i/g;s/И/I/g;s/й/y/g;s/Й/Y/g;s/к/k/g;s/К/K/g
s/л/l/g;s/Л/L/g;s/м/m/g;s/М/M/g;s/н/n/g;s/Н/N/g;s/о/o/g;s/О/O/g;s/п/p/g;s/П/P/g;s/р/r/g;s/Р/R/g
s/с/s/g;s/С/S/g;s/т/t/g;s/Т/T/g;s/у/u/g;s/У/U/g;s/ф/f/g;s/Ф/F/g;s/х/kh/g;s/Х/Kh/g;s/ц/ts/g;s/Ц/Ts/g
s/ч/ch/g;s/Ч/Ch/g;s/ш/sh/g;s/Ш/Sh/g;s/щ/sch/g;s/Щ/Sch/g;s/ъ/'/g;s/Ъ/'/g;s/ы/y/g;s/Ы/Y/g;s/ь/'/g;s/Ь/'/g
s/э/e/g;s/Э/E/g;s/ю/yu/g;s/Ю/Yu/g;s/я/ya/g;s/Я/Ya/g;s/і/i/g;s/І/I/g;s/ї/yi/g;s/Ї/Yi/g;s/є/ye/g;s/Є/Ye/g
s/ґ/g/g;s/Ґ/G/g;s/«/'/g;s/»/'/g;s/“/'/g;s/”/'/g;s/„/'/g;s/’/'/g;s/‘/'/g;s/—/-/g;s/–/-/g;s/…/.../g
s/№/N/g;s/$NB/ /g"

if [ "$2" = new ]; then                                                       # notify once per new key
   [ -s $NEW ] || exit 0
   K=$(jq -r '.sms[].key' $NEW 2>/dev/null) || { err "sms: bad $NEW"; exit 1; }
   F=; for k in $K; do grep -qxF "$k" $NOTI 2>/dev/null || F=1; done
   [ -n "$F" ] || { echo "$K" > $NOTI; exit 0; }
   [ "$FL$ON" != 00 ] || { echo "$K" > $NOTI; exit 0; }
   owner; case $OK in f|r|t|s) log "sms: new message, screen busy ($OK): retry next round"; exit 0 ;; esac
   echo "$K" > $NOTI; log "sms: new message"
fi
own s; GOT=; trap 'GOT=1' USR1
input() { GOT=; A=; read -r A < "$IN" 2>/dev/null; : > "$IN"; g "mcu_$A" ""; ACT=$R
   [ -n "$ACT" ] || case $A in flip) ACT=page ;; double) ACT=read ;; long) ACT=exit ;; esac
   log "sms: $A -> $ACT"; }

if [ "$2" = new ] && [ "$FL" = 1 ]; then                                      # flash 2 Hz until FT s or input
   B=$(printf '\260\260\260\260\260\260\260\260\260\260\260\260\260\260\260\260')         # 0xB0: 2 thick bars, ~50% lit
   now; E=$((UPC + FT * 100)); log "sms: flash ${FT}s"
   while [ "$UPC" -lt "$E" ] && [ -z "$GOT" ]; do
      send "$B" "$B" "$B" "$B"; nap 0.25; [ -n "$GOT" ] && break
      send "" "      SMS"; nap 0.25; now
   done
   [ -n "$GOT" ] && { input; [ "$ACT" = exit ] || [ "$ACT" = read ] && ON=0; }
   [ "$ON" = 1 ] || { clr; exit 0; }
fi

send "SMS" "loading..."
J=$($SB unseen all,seen "$(uci -q get 5gmodem.sms.storage)" "$(uci -q get 5gmodem.sms.readport)" 2>/dev/null)
printf '%s' "$J" | jq -r '.sms[] | [.time, (if ((" " + (.miss // "") + " ") | contains(" seen ")) then 1 else 0 end),
   .key, .sender, (.text | split("\r") | join("") | split("\n") | join(" ") | split("\t") | join(" "))] | @tsv' \
   2>/dev/null | sort -r > $LST
N=0 U=0 Q= A=                                                                    # newest first: T_i U_i K_i S_i X_i
while IFS='	' read -r t u k s x; do
   N=$((N + 1)); eval "T_$N=\$t U_$N=\$u K_$N=\$k S_$N=\$s X_$N=\$x"; A="$A $N"; [ "$u" = 1 ] && U=$((U + 1)) Q="$Q $N"
done < $LST
[ "$N" -gt 0 ] || { log "sms: no messages"; send "SMS" "No messages"; nap 3; clr; exit 0; }
[ "$LAST" = 1 ] || [ "$U" = 0 ] && Q=$A                                       # sequence: unread or all, newest first
set -- $Q; NQ=$#; log "sms: $N messages, $U unread, showing $NQ"
LG=$(uci -q get luci.main.lang)

fmt() {                                                                       # message $1 -> lines L1..LN
   local i=$1 t s h a=AM IFS=' -:'
   eval "t=\$T_$i s=\$S_$i u=\$U_$i x=\$X_$i"
   while [ "${LN:-0}" -gt 2 ]; do unset L$LN; LN=$((LN - 1)); done
   [ "$u" = 1 ] && h="SMS *" || h=SMS; rj $((16 - ${#h})) "$i/$N"; L1="$h$R"
   set -- $t                                                                  # Y m d H M [S]
   case $LG in
      ru*) L2="$3.$2.$1 $4:$5" ;;
      en*) h=${4#0}; [ "$h" -ge 12 ] && a=PM; h=$((h % 12)); [ $h = 0 ] && h=12
           L2="$2/$3/${1#??} $h:$5$a" ;;
      *)   L2="$1-$2-$3 $4:$5" ;;
   esac
   [ -n "$BN" ] && case "$s" in *"$BN"*) [ ${#s} -gt 5 ] && s="${s%?????}xxxxx" ;; esac
   IFS=' 	
'; LN=2
   while IFS= read -r l; do LN=$((LN + 1)); eval "L$LN=\$l"; done <<EOT
$(printf '%s\n%s\n' "$x" "$s" | sed "$TL" | LC_ALL=C awk '{
   gsub(/[\300-\377][\200-\277]*/, "?"); gsub(/["\\]/, "'"'"'"); gsub(/[\001-\037\177-\377]/, "?")
   n = split($0, w, " "); l = ""
   for (i = 1; i <= n; i++) {
      while (length(w[i]) > 16) { if (l != "") print l; l = ""; print substr(w[i], 1, 16); w[i] = substr(w[i], 17) }
      if (w[i] == "") continue
      if (l == "") l = w[i]; else if (length(l) + 1 + length(w[i]) <= 16) l = l " " w[i]; else { print l; l = w[i] }
   }
   if (l != "") print l }')
EOT
}

page() { eval "send \"\$L$P\" \"\${L$((P + 1)):-}\" \"\${L$((P + 2)):-}\" \"\${L$((P + 3)):-}\""; }
show() { set -- $Q; eval "I=\${$J}"; fmt "$I"; P=1 W=2; page; }      # message J of sequence Q
read1() { eval "k=\$K_$I u=\$U_$I"; [ "$u" = 1 ] || return 0                  # mark read on the device
   $SB seen-add "$k" >/dev/null 2>&1 && eval "U_$I=0" && log "sms: $I/$N read"; }
J=1 AUTO=1; now; E=$((UP + TO)); DL=$UPC; show
while :; do
   tick "$W"; [ -n "$GOT" ] && { input; now; E=$((UP + TO)) DL=$UPC
      case $ACT in
         page)   AUTO=0; if [ $((P + 3)) -ge "$LN" ]; then read1; J=$((J % NQ + 1)); show; else P=$((P + 4)); [ $((P + 3)) -gt "$LN" ] && P=$((LN - 3)); page; fi ;;
         next)   J=$((J % NQ + 1)); show ;;
         prev)   J=$(((J + NQ - 2) % NQ + 1)); show ;;
         replay) AUTO=1; show ;;
         read)   for i in $Q; do I=$i; read1; done; send "SMS" "All marked read"; nap 2; clr; exit 0 ;;
         exit)   clr; log "sms: exit"; exit 0 ;;
      esac; continue; }
   [ "$UP" -ge "$E" ] && { clr; log "sms: ${TO}s timeout"; exit 0; }
   [ "$AUTO" = 1 ] || continue
   if [ $((P + 3)) -lt "$LN" ]; then P=$((P + 1)) W=1; page                  # scroll 1 line/s
   else read1; [ "$LAST" = 1 ] || J=$((J % NQ + 1)); show; fi                # replay last or next
done

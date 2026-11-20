# /usr/share/mcu-switch/sms.sh — mcu-switch sms [new]: SMS on the MCU screen (luci-app-5gmodem "Inbox").
# new: called by 5gmodem sessionwatch after sms_new.json update; flashes and/or shows new messages.
# Input via $IN + USR1 (flip: mcu-switch, long press: mcu daemon): flip next page or message; long press asks
# "Mark all read?" (unread only, else long press exits): flip yes, long press or 20 s no; each ends with "SMS DONE".
SB=/usr/share/5gmodem/smsbridge.sh NEW=/tmp/5gmodem/sms_new.json NOTI=/tmp/mcu-switch.sms.notified
LST=/tmp/mcu-switch.sms NB=$(printf '\302\240')                             # no-break space
[ -x $SB ] || { err "sms: luci-app-5gmodem not installed"; exit 1; }
g() { R=$(uci -q get "5gmodem.sms.$1") || R=$2; }
g mcu_sms 0; ON=$R; g mcu_last 1; LAST=$R; g mcu_time 10; TO=$R; g bnumber ""; BN=$R
g lednotify 0; FL=$R; g smsled ""; [ "$R" = mcu ] || FL=0; g mcu_flash ""; FT=$R      # no UI: unset = default
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
   F=; [ -z "$K" ] || { [ -s $NOTI ] && ! printf '%s\n' "$K" | grep -qvxF -f $NOTI; } || F=1   # a key not notified yet
   [ -n "$F" ] || { echo "$K" > $NOTI; exit 0; }
   [ "$FL$ON" != 00 ] || { echo "$K" > $NOTI; exit 0; }
   owner; case $OK in f|a|r|t|s|n) log "sms: new message, screen busy ($OK): retry next round"; exit 0 ;; esac
   echo "$K" > $NOTI; log "sms: new message"
fi
GOT=; trap 'GOT=1' USR1; own s
JP=; [ "$2" = new ] && [ "$ON" != 1 ] || {                                 # load while flashing
   $SB unseen all,seen "$(uci -q get 5gmodem.sms.storage)" "$(uci -q get 5gmodem.sms.readport)" > $LST.j 2>/dev/null </dev/null & JP=$!; }
input() { GOT=; A=; read -r A < "$IN" 2>/dev/null; : > "$IN"; log "sms: $A"; }

if [ "$2" = new ] && [ "$FL" = 1 ]; then         # flash display; mcu_flash s if set; or until input
   B=$(printf '\260\260\260\260\260\260\260\260\260\260\260\260\260\260\260\260')   # 0xB0: 2 thick bars, ~50% lit
   case $FT in ''|*[!0-9]*) n=2 u=53 TT=954 ;;                                      # 23 units/word + 7 between words
      *) n=$(((FT * 1000 / 167 + 7) / 30)); [ "$n" -gt 0 ] || n=1; u=$((30 * n - 7)) TT=$((FT * 100)) ;; esac
   log "sms: flash $((TT / 100))s"               # >= 167 ms: max 3 flashes/s (WCAG 2.3.1)
   cen "NEW SMS"; lpw "" "$R"                    # long press: ends
   now; T=$UPC c=0
   while [ "$n" -gt 0 ] && [ -z "$GOT" ]; do
      o=1
      for d in 1 1 1 1 1 3 3 1 3 3 1 1 1 1 1 7; do                             # on/off units
         [ "$d" = 7 ] && [ "$n" = 1 ] && break
         if [ "$o" = 1 ]; then send "$B" "$B" "$B" "$B"; o=0; else send "" "      SMS"; o=1; fi
         c=$((c + d)); now; r=$((T + c * TT / u - UPC))                    # deadline in cs: no drift
         [ "$r" -gt 0 ] && nap $((r / 100)).$((r % 100 / 10))$((r % 10)); [ -n "$GOT" ] && break
      done
      n=$((n - 1))
   done
   [ -n "$GOT" ] && { input; [ "$A" = long ] && ON=0; }
   [ "$ON" = 1 ] || { final "NEW SMS"; exit 0; }
   : > "$LP"
fi

kill -0 $JP 2>/dev/null && say "  SMS Load..."
while kill -0 $JP 2>/dev/null; do wait $JP; done                            # wait returns early on USR1
jq -r '.sms[] | [.time, (if ((" " + (.miss // "") + " ") | contains(" seen ")) then 1 else 0 end),
   .key, .sender, (.text | split("\r") | join("") | split("\n") | join(" ") | split("\t") | join(" "))] | @tsv' \
   < $LST.j 2>/dev/null | sort -r > $LST; rm -f $LST.j
N=0 U=0 Q= A=                                                                    # newest first: T_i U_i K_i S_i X_i
while IFS='	' read -r t u k s x; do
   N=$((N + 1)); eval "T_$N=\$t U_$N=\$u K_$N=\$k S_$N=\$s X_$N=\$x"; A="$A $N"; [ "$u" = 1 ] && U=$((U + 1)) Q="$Q $N"
done < $LST
[ "$N" -gt 0 ] || { log "sms: no messages"; final "SMS DONE" "no messages"; exit 0; }
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
   [ -n "$BN" ] && case "$s" in *"$BN"*) [ ${#s} -gt 5 ] && s="${s%?????}#####" ;; esac
   IFS=' 	
'; LN=2
   while IFS= read -r l; do LN=$((LN + 1)); eval "L$LN=\$l"; done <<EOT
$(printf '%s\n%s\n' "$x" "$s" | sed "$TL" | LC_ALL=C awk '{
   gsub(/[\300-\377][\200-\277]*/, "?"); gsub(/["\\]/, "'"'"'"); gsub(/[^ -~]/, "?")
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
q() { $1 "Mark all read?" "YES switch flip" " NO wait ${2}s" "    or hold 3s"; }
ask() {                                                                       # long press: flip marks all read; long press or 20 s: no
   local n=20
   cen "SMS DONE"; lpw "" "$R"; now; DL=$UPC                                 # long press: the daemon covers the pop-up with the final
   while [ $n -gt 0 ]; do
      q send $n; tick 1
      [ -n "$GOT" ] && { input; case $A in
         flip) for i in $Q; do I=$i; read1; done; final "SMS DONE" "all marked read"; exit 0 ;;
         long) break ;; esac; }
      n=$((n - 1))
   done
   log "sms: exit"; final "SMS DONE"; exit 0                                 # replaces the pop-up: a msg "" frame does not clear it
}
J=1 AUTO=1; now; E=$((UP + TO)); DL=$UPC; show
[ "$U" = 0 ] && { cen "SMS DONE"; lpw "" "$R"; } || q lpw 20                # no unread: long press exits
while :; do
   tick "$W"; [ -n "$GOT" ] && { input; now; E=$((UP + TO)) DL=$UPC
      case $A in
         flip) AUTO=0; if [ $((P + 3)) -ge "$LN" ]; then J=$((J % NQ + 1)); show; else P=$((P + 4)); [ $((P + 3)) -gt "$LN" ] && P=$((LN - 3)); page; fi ;;
         long) [ "$U" = 0 ] && { log "sms: exit: long press"; final "SMS DONE"; exit 0; }; ask ;;
      esac; continue; }
   [ "$UP" -ge "$E" ] && { log "sms: ${TO}s timeout"; final "SMS DONE"; exit 0; }
   [ "$AUTO" = 1 ] || continue
   if [ $((P + 3)) -lt "$LN" ]; then P=$((P + 1)) W=1; page                  # scroll 1 line/s
   else [ "$LAST" = 1 ] || J=$((J % NQ + 1)); show; fi                       # replay last or next
done

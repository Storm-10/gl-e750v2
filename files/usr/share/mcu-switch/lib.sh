# /usr/share/mcu-switch/lib.sh — shared by /usr/bin/mcu-switch and its modules (sourced, busybox ash)
# Screen: 'msg' frames (4x16) written straight to the MCU tty, 20 s pop-up or until the next frame.
PID=/tmp/mcu-switch.pid PEND=/tmp/mcu-switch.pend IN=/tmp/mcu-switch.in GEN=/tmp/mcu-switch.gen ARGS="$*"
LP=/tmp/mcu-switch.long BOOT=/tmp/mcu-switch.boot
. /lib/functions.sh
config_load mcu
config_get REFRESH switch refresh 2
config_get GEST    switch gesture 2
config_get MTO     switch meters_timeout 600
config_get MTO     switch metrics_timeout "$MTO"
config_get IFACE   switch iface wwan0
TTY=${MCU_TTY:-$(uci -q get glconfig.mcu.dev)} || TTY=/dev/ttyS0
NET=/sys/class/net/$IFACE/statistics CT=/proc/net/nf_conntrack; [ -r $CT ] || CT=/dev/null
LAN=$(uci -q get network.lan.ipaddr)
case $LAN in */*) ;; ?*) LAN=$LAN/$(uci -q get network.lan.netmask) ;; esac   # a.b.c.d/len or a.b.c.d/mask

log() { logger -t mcu-switch "$*"; }
err() { logger -t mcu-switch -p user.err "$*"; }
now() { read -r UPC _ < /proc/uptime; UP=${UPC%.*}; UPC=$UP${UPC#*.}; }       # s and cs, no fork
rj()  { R=$2; while [ ${#R} -lt "$1" ]; do R=" $R"; done; }                   # right-justify $2 to $1 -> R
lj()  { R=$2; while [ ${#R} -lt "$1" ]; do R="$R "; done; }                   # left-justify
nap() {                                                                       # sleep $1 s; returns at once on a trapped signal
   case $1 in                                                                 # OpenWrt busybox sleep: no fractions -> ucode
      *.*) set -- "${1#*.}000" "${1%.*}"; set -- "${1%"${1#???}"}" "$2"
           ucode -e "sleep($((${2:-0} * 1000 + 1$1 - 1000)))" 2>/dev/null & ;;
      *)   sleep "$1" 2>/dev/null & ;;
   esac
   SP=$!; wait $SP; kill $SP 2>/dev/null; return 0
}

tick() {                                                                      # sleep to deadline: $1 s (REFRESH) after last
   local r
   now; DL=$((DL + ${1:-$REFRESH} * 100)); r=$((DL - UPC))
   [ "$r" -gt 0 ] || { DL=$UPC; return 0; }                                   # late: resync
   nap $((r / 100)).$((r % 100 / 10))$((r % 10))
}

num() {                                                                       # $1 bps / unit $2 -> R: 123, 12.3, 0.123
   local m=$((($1 * 1000 + $2 / 2) / $2))                                     # thousandths
   if [ "$2" = 1 ] || [ "$m" -ge 99950 ]; then R=$(((m + 500) / 1000))
   elif [ "$m" -ge 950 ]; then m=$(((m + 50) / 100)); R=$((m / 10)).$((m % 10))
   else R=0.$((m / 100))$((m / 10 % 10))$((m % 10)); fi
}

bw() {                                                                        # $1 rx, $2 tx bps -> R1 "v32.5 ^.001 Mbps"
   local a=$1 b=$2 u=Mbps d=1000000 g o
   if [ "$a" != - ]; then
      g=$((a > b ? a : b))
      [ "$g" -lt 999500 ] && u=Kbps d=1000; [ "$g" -lt 1000 ] && u=bps d=1
      num "$1" $d; a=$R; num "$2" $d; b=$R
      [ $((${#a} + ${#b} + ${#u})) -gt 12 ] && a=${a#0} b=${b#0}             # no room: drop leading 0
   fi
   g=$((15 - ${#a} - ${#u})); o=$(((g - 1 - ${#b}) / 2))                      # ^ value centered between
   lj $((1 + ${#a} + o)) "v$a"; a=$R; lj $((g - o)) "^$b"; R1="$a$R$u"
}

sample() {                                                                    # CPU% since last call, load, mem, rates
   local a b c d e f g t k v
   now; DT=$((UPC - PU)); PU=$UPC
   read -r _ a b c d e f g _ < /proc/stat
   t=$((a + b + c + d + e + f + g))
   CPU=$(( t > PT ? 100 * (t - PT - d + PI) / (t - PT) : 0 )); PT=$t PI=$d
   read -r LD _ < /proc/loadavg
   while read -r k v _; do [ "$k" = MemAvailable: ] && break; done < /proc/meminfo
   MEM=$((v / 1024)).$((v % 1024 * 10 / 1024))M
   RXM=- TXM=-
   read -r a 2>/dev/null < "$NET/rx_bytes" && read -r b < "$NET/tx_bytes" || { PRX=; return 0; }
   [ -n "$PRX" ] && [ "$DT" -gt 0 ] && RXM=$((a > PRX ? (a - PRX) * 800 / DT : 0)) TXM=$((b > PTX ? (b - PTX) * 800 / DT : 0))
   PRX=$a PTX=$b
}

scan() {               # conntrack as LuCI luci-bwc -c (no TIME_WAIT/loopback); LAN = original src in $LAN
   { read -r LC TC ST OFF; read -r ELINE; } <<EOT
$(awk -v cidr="$LAN" -v logs="$WATCH" -v offs="$OFF" -v done="$DONE" '
   function ip(s,  p) { split(s, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
   BEGIN {
      split(cidr, c, "/"); if (c[2] ~ /\./) d = 4294967296 - ip(c[2]); else for (d = 1; c[2] < 32; c[2]++) d *= 2
      m = int(ip(c[1]) / d); st = "-"
      n = split(logs, f, " "); split(offs, o, " ")
      for (i = 1; i <= n; i++) {                       # new lines only; all lines if file shrank
         k = 0; while ((getline x < f[i]) > 0) L[++k] = x; close(f[i])
         for (j = (k < o[i] ? 1 : o[i] + 1); j <= k; j++)
            if (tolower(L[j]) ~ /error|fail|killed/) { st = "E"; if (e == "") e = L[j] }
            else if (done != "" && st == "-" && index(L[j], done)) st = "D"
         cnt = cnt " " k
      }
   }
   /TIME_WAIT/ { next }
   index($0, "src=127.0.0.1 ") && index($0, "dst=127.0.0.1 ") || index($0, "src=::1 ") && index($0, "dst=::1 ") { next }
   { t++; if (cidr != "" && $1 == "ipv4") for (i = 6; i <= NF; i++) if (substr($i, 1, 4) == "src=") { if (int(ip(substr($i, 5)) / d) == m) l++; break } }
   END { print l + 0, t + 0, st cnt; print e }' $CT)
EOT
}

rows() {                                                       # R2..R4: conns, load/CPU, mem
   local c="$CPU%" k=$((${LD%.*} * 100 + 1${LD#*.} - 100)) l
   rj 11 "$LC/$TC"; R2="Conns$R"
   rj 3 "$c"; c=$R
   if [ ${#c} -eq 3 ] && [ "$k" -lt 995 ]; then k=$(((k + 5) / 10)); l=$((k / 10)).$((k % 10))
   else l=$(((k + 50) / 100)); fi                              # no decimal if CPU 100+% or load 10+
   rj $((6 - ${#c})) "$l"; R3="Load $R CPU $c"
   rj 7 "$MEM"; R4="Mem avail$R"
}
mine() { [ -z "$ME" ] && return 0; read -r p _ 2>/dev/null < "$PID"; [ "$p" = "$ME" ] || { log "screen lost: exit"; exit 0; }; }

send() {                                                                      # rows -> MCU pop-up (20 s or until next)
    mine; printf "{\"msg\": \"%-16.16s%-16.16s%-16.16s%-16.16s\"}" "$@" > "$TTY" || [ -n "$WE" ] || { WE=1; err "cannot write $TTY"; }
}
mcuref() { ubus -t 3 call mcu reload >/dev/null 2>&1; }      # daemon sends a status frame now (1-3 s): ends MCU's own "Standby mode" screen
clr() {                                                       # dismiss pop-up: standard screens return
   mine; printf '{"msg": " "}' > "$TTY"
   [ -e "$LP" ] && { rm -f "$LP"; mcuref; }                   # only after a long press: MCU switched its first screen itself
}
owner() { OP= OK=; [ -f "$PID" ] && read -r OP OK < "$PID"; [ -n "$OP" ] && kill -0 "$OP" 2>/dev/null || OP= OK=; }
own() {                                                        # take the screen as kind $1: f flip, r module, m metrics, s SMS, t standby
   [ -n "$MCU_GEN" ] && { read -r p 2>/dev/null < "$GEN"; [ "$p" = "$MCU_GEN" ] || { log "$ARGS: superseded sequence: skipped"; exit 0; }; }
   echo "${MCU_GEN:-$$}" > "$GEN"                              # gesture sequence id: a later one skips our next calls
   owner; echo "$$ $1" > "$PID"; ME=$$; [ -n "$OP" ] && [ "$OP" != $$ ] && kill "$OP" 2>/dev/null
   trap '[ -s "$PID" ] && read -r p _ < "$PID" && [ "$p" = $$ ] && : > "$PID"' EXIT
}
SIG=/tmp/mcu-switch.sig
sig() {                                                        # $1 name, $2 value, $3..$4 scale (5gtop) -> R "RSRP-103 ###-"
   local v=${2#+} h b=
   v=${v%%.*}
   case $v in ''|-|*[!0-9-]*|?*-*) R="$1 --"; return ;; esac
   h=$(((v - $3) * 100 / ($4 - $3))); [ "$h" -lt 0 ] && h=0; [ "$h" -gt 100 ] && h=100; h=$((h * 14 / 100))
   while [ "$h" -gt 1 ]; do b="$b#"; h=$((h - 2)); done; [ "$h" = 1 ] && b="$b-"   # '#' 1/7, '-' 1/14 of scale
   [ ${#v} -ge 4 ] || { lj 4 " $v"; v=$R; }
   R="$1$v $b"
}
signal() {                                                     # R1..R4: RSRP RSRQ SINR RSSI from 5gmodem, as 5gtop
   local P= Q= S= I= n
   [ -x /usr/share/5gmodem/5gmodem.sh ] && { [ -n "$FP" ] && kill -0 "$FP" 2>/dev/null || {
      read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ n _ < /proc/$$/stat          # poll at normal priority
      SW_BG=1 nice -n $((-n)) /usr/share/5gmodem/5gmodem.sh cached 10 </dev/null > $SIG.t 2>/dev/null \
         && grep -q '"rsrp"' $SIG.t && mv $SIG.t $SIG & FP=$!; }; }
   [ -s $SIG ] && eval "$(jsonfilter -i $SIG -e 'P=@.rsrp' -e 'Q=@.rsrq' -e 'S=@.sinr' -e 'I=@.rssi' 2>/dev/null)"
   sig RSRP "$P" -130 -80; R1=$R; sig RSRQ "$Q" -20 -3; R2=$R; sig SINR "$S" -10 20; R3=$R; sig RSSI "$I" -110 -50; R4=$R
}
elapsed() { now; T0=${MCU_T0:-$UPC} DL=$UPC; EL=$(((UPC - T0) / 100)); }      # counter continues from the flip

# /usr/share/mcu-switch/lib.sh — shared by /usr/bin/mcu-switch and its modules (sourced, busybox ash)
# Screen: 'msg' frames (4x16) written straight to the MCU tty, 20 s pop-up or until the next frame.
PID=/tmp/mcu-switch.pid PEND=/tmp/mcu-switch.pend IN=/tmp/mcu-switch.in
. /lib/functions.sh
config_load mcu
config_get REFRESH switch refresh 2
config_get GEST    switch gesture 2
config_get MTO     switch meters_timeout 600
config_get IFACE   switch iface wwan0
TTY=${MCU_TTY:-$(uci -q get glconfig.mcu.dev)} || TTY=/dev/ttyS0
NET=/sys/class/net/$IFACE/statistics CT=/proc/net/nf_conntrack; [ -r $CT ] || CT=/dev/null
LAN=$(uci -q get network.lan.ipaddr)
case $LAN in */*) ;; ?*) LAN=$LAN/$(uci -q get network.lan.netmask) ;; esac   # a.b.c.d/len or a.b.c.d/mask

log() { logger -t mcu-switch "$*"; }
err() { logger -t mcu-switch -p user.err "$*"; }
now() { read -r UPC _ < /proc/uptime; UP=${UPC%.*}; UPC=$UP${UPC#*.}; }      # s and cs, no fork
rj()  { R=$2; while [ ${#R} -lt "$1" ]; do R=" $R"; done; }                 # right-justify $2 to $1 -> R
lj()  { R=$2; while [ ${#R} -lt "$1" ]; do R="$R "; done; }                 # left-justify
nap() {                                                                       # sleep; returns at once on a trapped signal
   sleep "$1" 2>/dev/null & SP=$!; wait $SP; set -- $? "$1"; kill $SP 2>/dev/null
   [ "$1" = 1 ] && case $2 in *.*) sleep $((${2%.*} + 1)) ;; esac                # busybox sleep: no fractions
   return 0
}

tick() {                                                                      # sleep to deadline: $1 s (REFRESH) after last
   local r
   now; DL=$((DL + ${1:-$REFRESH} * 100)); r=$((DL - UPC))
   [ "$r" -gt 0 ] || { DL=$UPC; return 0; }                                   # late: resync
   nap $((r / 100)).$((r % 100 / 10))
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

metrics() {                                                                   # CPU% since last call, load, mem, rates
   local a b c d e f g t k v
   now; DT=$((UPC - PU)); PU=$UPC
   read -r _ a b c d e f g _ < /proc/stat
   t=$((a + b + c + d + e + f + g))
   CPU=$(( t > PT ? 100 * (t - PT - d + PI) / (t - PT) : 0 )); PT=$t PI=$d
   read -r LD _ < /proc/loadavg
   while read -r k v _; do [ "$k" = MemAvailable: ] && break; done < /proc/meminfo
   MEM=$((v / 1024)).$((v % 1024 * 10 / 1024))M
   RXM=- TXM=-
   read -r a < "$NET/rx_bytes" && read -r b < "$NET/tx_bytes" || { PRX=; return 0; }
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

rows() {                                                                      # R2..R4: conns, load/CPU, mem
   local c="$CPU%" k=$((${LD%.*} * 100 + 1${LD#*.} - 100)) l
   rj 11 "$LC/$TC"; R2="Conns$R"
   rj 3 "$c"; c=$R
   if [ ${#c} -eq 3 ] && [ "$k" -lt 995 ]; then k=$(((k + 5) / 10)); l=$((k / 10)).$((k % 10))
   else l=$(((k + 50) / 100)); fi                                             # no decimal if CPU 100+% or load 10+
   rj $((6 - ${#c})) "$l"; R3="Load $R CPU $c"
   rj 7 "$MEM"; R4="Mem avail$R"
}

send() {                                                                      # rows -> MCU pop-up (20 s or until next)
   printf "{\"msg\": \"%-16.16s%-16.16s%-16.16s%-16.16s\"}" "$@" > "$TTY" || [ -n "$WE" ] || { WE=1; err "cannot write $TTY"; }
}
clr() { printf '{"msg": " "}' > "$TTY"; }                                     # dismiss pop-up: standard screens return
owner() { OP= OK=; [ -f "$PID" ] && read -r OP OK < "$PID"; [ -n "$OP" ] && kill -0 "$OP" 2>/dev/null || OP= OK=; }
own() {                                                                       # take the screen as kind $1: f flip, r module, m meters, s SMS, t standby
   owner; echo "$$ $1" > "$PID"; [ -n "$OP" ] && [ "$OP" != $$ ] && kill "$OP" 2>/dev/null
   trap '[ -s "$PID" ] && read -r p _ < "$PID" && [ "$p" = $$ ] && : > "$PID"' EXIT
}
elapsed() { now; T0=${MCU_T0:-$UPC} DL=$UPC; EL=$(((UPC - T0) / 100)); }      # counter continues from the flip

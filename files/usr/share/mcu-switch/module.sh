# /usr/share/mcu-switch/module.sh — mcu-switch <module> on|on_*|off: run module command, show progress + metrics.
# Module = 'module' section in /etc/config/mcu. Sourced by /usr/bin/mcu-switch with lib.sh loaded.
M=$1 SEQ=$CMD                                                                # SEQ: gesture command line (from act)
case "$2" in on|on_*|off) ;; *) echo "usage: $0 $M on|on_*|off" >&2; exit 2 ;; esac
config_get NAME     "$M" name      "$M"
config_get CMD      "$M" "cmd_$2"
config_get ISON     "$M" is_on
config_get ISX      "$M" "is_$2"                                              # per-action "already" test, else is_on
config_get OKT      "$M" "ok_$2"                                              # row 2 text on success
config_get LOGS     "$M" log
config_get DONE     "$M" done_re
config_get DONE_OFF "$M" done_re_off
config_get EST      "$M" estimate  300
config_get GRACE    "$M" grace     60
config_get STAB     "$M" stabilize 180
config_get CPU_OK   "$M" cpu_ok    50

TAIL=10                                                                       # 3 s tail if more mcu-switch calls follow
case "$SEQ" in *mcu-switch*mcu-switch*) case "${SEQ%"${SEQ##*[!;& ]}"}" in *"mcu-switch $M $2") ;; *) TAIL=3 ;; esac ;; esac
fin() {                                                                       # final state: freeze counter, tail
   STATE=$1 FZ=$EL END=$((DL + TAIL * 100)) WATCH=
   if [ "$1" = "$OKS" ]; then log "$NAME $1 at ${EL}s, CPU $CPU%"; else err "$NAME $1 at ${EL}s: $2"; fi
}

case "$2" in
   on*) STATE=starting DID=started OKS=READY ;;
   off) STATE=stopping DID=stopped OKS=DOWN STAB=0; DONE=${DONE_OFF:-$DONE} ;;
esac
own r; elapsed
trap 'log "$NAME $STATE: superseded at ${EL}s"; exit 0' TERM INT HUP
[ -n "$CMD" ] || { err "$NAME: no cmd_$2 configured"; send "$NAME" "no cmd_$2 set"; nap 5; clr; exit 1; }
[ -z "$ISX" ] && [ -n "$ISON" ] && case $2 in on) ISX=$ISON ;; off) ISX="! { $ISON; }" ;; esac
if [ -n "$ISX" ] && sh -c "$ISX" >/dev/null 2>&1; then                         # already there
   log "$NAME already $2: nothing to do"
   S=${OKT:-ON}; [ "$2" = off ] && S=OFF; rj $(((16 + ${#S}) / 2)) "$S"
   case $MCU_G in on|off) send "$NAME already" "$R" "Flip ignored to" "match state" ;; *) send "$NAME already" "$R" "" "Nothing to do" ;; esac
   nap "$TAIL"; clr; exit 0
fi
log "$NAME $STATE: running cmd_$2"
WATCH=$LOGS; scan                                                             # log line counts before command
read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ NI _ < /proc/$$/stat              # command at normal priority
nice -n $((-NI)) sh -c "$CMD" </dev/null >/dev/null 2>&1 & CP=$!
sample
while :; do
   [ -n "$END" ] && [ "$DL" -ge "$END" ] && { clr; log "$NAME $STATE: screen released"; [ "$STATE" = "$OKS" ]; exit; }
   rj $((15 - ${#NAME} - ${#STATE})) "${FZ:-$EL}s"; R1="$NAME $STATE$R"; [ -n "$LD" ] && rows
   [ "$STATE" = "$OKS" ] && [ -n "$OKT" ] && { rj $(((16 + ${#OKT}) / 2)) "$OKT"; R2=$R; }
   send "$R1" "$R2" "$R3" "$R4"
   tick; sample; scan; EL=$(((UPC - T0) / 100))
   if [ -n "$CP" ] && ! kill -0 "$CP" 2>/dev/null; then                      # command finished
      wait "$CP"; RC=$?; CP=
      if [ "$RC" = 0 ]; then log "cmd_$2 exited 0 at ${EL}s"; else err "cmd_$2 exited $RC at ${EL}s"; fi
      [ -z "$DONE" ] && [ "$ST" = - ] && { [ "$RC" = 0 ] && ST=D || ST=E ELINE="cmd_$2 exit $RC"; }
   fi
   case $STATE in
      starting|stopping)
         if [ "$ST" = E ]; then fin ERROR "$ELINE"
         elif [ "$ST" = D ]; then log "$NAME $DID at ${EL}s"
            if [ "$STAB" -gt 0 ]; then STATE="wait CPU" T1=$UP; log "$NAME $STATE: waiting for CPU < $CPU_OK%"; else fin $OKS; fi
         elif [ "$EL" -ge $((EST + GRACE)) ]; then fin TIMEOUT "no completion within $((EST + GRACE))s"; fi ;;
      "wait CPU")
         if [ "$ST" = E ]; then fin ERROR "$ELINE"
         elif [ "$CPU" -lt "$CPU_OK" ]; then fin $OKS
         elif [ $((UP - T1)) -ge "$STAB" ]; then fin "CPU HIGH" "CPU $CPU% after ${STAB}s"; fi ;;
      "CPU HIGH") [ "$CPU" -lt "$CPU_OK" ] && fin $OKS ;;
   esac
done

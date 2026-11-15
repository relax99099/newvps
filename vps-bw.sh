#!/usr/bin/env bash
# ============================================================================
#  vps-bw.sh — VPS တစ်ခုလုံးရဲ့ Bandwidth စစ်တဲ့ Script (User အလိုက် မဟုတ်)
#
#  Network interface ကနေ တိုင်းတာမို့ Outline / Marzban / 3x-ui / SSH /
#  ဝက်ဘ်ဆိုက် — VPS ပေါ်က service အားလုံးရဲ့ usage အကုန် ပေါင်းပြီး ပြတယ်။
#
#  GitHub မှာ တင်ပြီး သုံးပုံ (relax99099/newvps):
#    curl -sL https://raw.githubusercontent.com/relax99099/newvps/main/vps-bw.sh | sudo bash
#
#  Quota ပြောင်းချင်ရင် (default = 4000 GB, Linode $24 plan):
#    curl -sL <raw-link> | sudo QUOTA_GB=2000 bash
#
#  Linode မှတ်ချက်: Linode က quota ကို Outbound (Upload/TX) နဲ့ပဲ တွက်တယ်။
#  Inbound (Download/RX) က free။ ဒါကြောင့် quota % ကို TX နဲ့ တွက်ပြထားတယ်။
#  (Linode account မှာ VPS အများကြီးရှိရင် quota က pool ပေါင်းတွက်တာမို့
#   အတိအကျ ဆုံး ဂဏန်းက Linode Cloud Manager > Account > Transfer မှာပါ)
#
#  vnstat မရှိသေးရင် ပထမဆုံး run မှာ auto install လုပ်ပေးတယ် —
#  အဲ့ဒီနေ့ကစပြီး လ အလိုက် usage ကို reboot လုပ်လည်း မပျောက်အောင် မှတ်ထားမယ်။
#  vnstat မရှိခင်/စတင်ခါစမှာ ပြတဲ့ ဂဏန်းက "since boot" (နောက်ဆုံး reboot ကစ) ပဲ။
# ============================================================================

QUOTA_GB="${QUOTA_GB:-4000}"
BRAND="${BRAND:-PKK STORE}"

P='\033[95m'; C='\033[96m'; G='\033[92m'; Y='\033[93m'; O='\033[38;5;208m'
R='\033[91m'; W='\033[97m'; D='\033[90m'; B='\033[1m'; N='\033[0m'
[ -t 1 ] || { P=''; C=''; G=''; Y=''; O=''; R=''; W=''; D=''; B=''; N=''; }

gb()   { awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1000000000}'; }          # bytes -> GB number
h()    { awk -v b="${1:-0}" 'BEGIN{ if(b>=1e12)printf "%.2f TB",b/1e12; else if(b>=1e9)printf "%.1f GB",b/1e9; else if(b>=1e6)printf "%.1f MB",b/1e6; else if(b>=1e3)printf "%.1f KB",b/1e3; else printf "%d B",b }'; }
bar()  { awk -v u="${1:-0}" -v q="${2:-1}" 'BEGIN{ p=(q>0)?u/q:0; if(p>1)p=1; f=int(p*34); s=""; for(i=0;i<f;i++)s=s"█"; for(i=f;i<34;i++)s=s"░"; printf "%s", s }'; }
pct()  { awk -v u="${1:-0}" -v q="${2:-1}" 'BEGIN{ printf "%.1f%%", (q>0)?(u/q)*100:0 }'; }

IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
IFACE="${IFACE:-eth0}"

# ---------------- vnstat auto-install (ပထမအကြိမ်) ---------------------------
if ! command -v vnstat >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && [ -z "${NO_INSTALL:-}" ]; then
  echo -e "${Y}vnstat မရှိသေးလို့ install လုပ်နေတယ်... (လအလိုက် မှတ်ထားနိုင်ဖို့)${N}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq vnstat >/dev/null 2>&1
  systemctl enable --now vnstat >/dev/null 2>&1 || service vnstat start >/dev/null 2>&1
  sleep 2
fi

# ---------------- Data ယူ ---------------------------------------------------
# since boot (interface counter)
read -r BOOT_RX BOOT_TX <<<"$(awk -v i="$IFACE:" '$1==i{print $2, $10}' /proc/net/dev)"
BOOT_RX=${BOOT_RX:-0}; BOOT_TX=${BOOT_TX:-0}

SRC="since boot (နောက်ဆုံး reboot က စတဲ့ ဂဏန်း)"
M_RX=$BOOT_RX; M_TX=$BOOT_TX; D_RX=$BOOT_RX; D_TX=$BOOT_TX; T_RX=$BOOT_RX; T_TX=$BOOT_TX
HAVE_VNSTAT=0
if command -v vnstat >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  OUT=$(vnstat -i "$IFACE" --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    t = d["interfaces"][0]["traffic"]
    tot = t.get("total", {})
    day = (t.get("day") or [{}])[0]
    mon = (t.get("month") or [{}])[0]
    print(tot.get("rx",0), tot.get("tx",0), day.get("rx",0), day.get("tx",0), mon.get("rx",0), mon.get("tx",0))
except Exception:
    sys.exit(1)' 2>/dev/null)
  if [ -n "$OUT" ]; then
    read -r T_RX T_TX D_RX D_TX M_RX M_TX <<<"$OUT"
    # vnstat စတင်ခါစ (data နည်းနည်း) ဆိုရင် since-boot က ပိုများနေနိုင်တယ်
    if [ $((M_RX + M_TX)) -ge $((BOOT_RX + BOOT_TX)) ]; then
      SRC="vnstat (ဒီလ အတိအကျ)"; HAVE_VNSTAT=1
    else
      SRC="since boot (vnstat စစုခါစမို့ — နောက်ရက်တွေမှာ လအလိုက် အတိအကျ ဖြစ်လာမယ်)"
      M_RX=$BOOT_RX; M_TX=$BOOT_TX; T_RX=$BOOT_RX; T_TX=$BOOT_TX
    fi
  fi
fi

QUOTA_BYTES=$(awk -v g="$QUOTA_GB" 'BEGIN{printf "%.0f", g*1000000000}')
MONTH_TOTAL=$((M_RX + M_TX))
REMAIN_BYTES=$((QUOTA_BYTES - M_TX)); [ "$REMAIN_BYTES" -lt 0 ] && REMAIN_BYTES=0
OS=$(awk -F'"' '/^PRETTY_NAME/{print $2}' /etc/os-release 2>/dev/null)
UP=$(awk '{d=int($1/86400); hh=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%d days, %d hours, %d minutes", d, hh, m}' /proc/uptime)
LOAD=$(cut -d' ' -f1 /proc/loadavg)
MEM=$(free | awk '/^Mem:/{printf "%.1f%%", ($3/$2)*100}')

# ---------------- Dashboard --------------------------------------------------
echo -e "${D}----------------------------------------------------------------------------${N}"
if command -v figlet >/dev/null 2>&1; then echo -e "${P}"; figlet -f slant "$BRAND"; echo -e "${N}"
else echo -e "${P}${B}   $BRAND — VPS BANDWIDTH${N}"; fi
echo -e "${D}----------------------------------------------------------------------------${N}"
printf "${D}%-10s${N} ${G}%s${N}   ${D}|${N}  ${C}Interface:${N} ${G}%s${N}   ${D}|${N}  ${C}Load:${N} ${G}%s${N}  ${C}Mem:${N} ${G}%s${N}\n" "OS" "$OS" "$IFACE" "$LOAD" "$MEM"
printf "${D}%-10s${N} ${G}%s${N}\n" "Uptime" "$UP"
echo -e "${C}____________________________________________________________________________${N}"
echo -e "${P}--- 📊 Bandwidth Usage (Outline + Marzban + အခြား service အားလုံး ပေါင်း) ---${N}"
printf "${W}%-14s | %-16s | %-16s | %s${N}\n" "PERIOD" "DOWNLOAD (RX)" "UPLOAD (TX)" "TOTAL"
echo -e "${C}----------------------------------------------------------------------------${N}"
printf "${G}%-14s${N} | %-16s | %-16s | %s\n" "Today"        "$(h $D_RX)" "$(h $D_TX)" "$(h $((D_RX + D_TX)))"
printf "${G}%-14s${N} | %-16s | %-16s | %s\n" "This Month"   "$(h $M_RX)" "$(h $M_TX)" "$(h $MONTH_TOTAL)"
printf "${G}%-14s${N} | %-16s | %-16s | %s\n" "Since Boot"   "$(h $BOOT_RX)" "$(h $BOOT_TX)" "$(h $((BOOT_RX + BOOT_TX)))"
[ "$HAVE_VNSTAT" -eq 1 ] && printf "${G}%-14s${N} | %-16s | %-16s | %s\n" "All Time" "$(h $T_RX)" "$(h $T_TX)" "$(h $((T_RX + T_TX)))"
echo -e "${C}____________________________________________________________________________${N}"
echo -e "${O}${B}Linode Quota (Outbound/TX နဲ့ တွက်သည်)${N}"
echo -e "${Y}$(bar $M_TX $QUOTA_BYTES)  $(pct $M_TX $QUOTA_BYTES)${N}"
echo -e "${W}သုံးပြီး (Upload): ${B}$(gb $M_TX) GB${N}  /  ${QUOTA_GB} GB"
echo -e "${W}ကျန်သေး:          ${G}${B}$(gb $REMAIN_BYTES) GB${N}"
echo -e "${D}Download (RX) က Linode မှာ free မို့ quota ထဲ မပါပါ။ Data source: $SRC${N}"
if [ "$M_TX" -ge "$QUOTA_BYTES" ]; then
  echo -e "${R}${B}⚠ Quota ပြည့်သွားပြီ / ကျော်သွားပြီ — Linode overage $0.005/GB ကောက်လိမ့်မယ်${N}"
elif [ "$M_TX" -ge $((QUOTA_BYTES * 80 / 100)) ]; then
  echo -e "${R}${B}⚠ Quota ရဲ့ 80% ကျော်နေပြီ — သတိထားပါ${N}"
fi
echo -e "${C}____________________________________________________________________________${N}"

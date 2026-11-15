#!/usr/bin/env bash
# ============================================================================
#  vps-bw.sh — VPS တစ်ခုလုံးရဲ့ Bandwidth စစ်တဲ့ Script (User အလိုက် မဟုတ်)
#
#  Network interface ကနေ တိုင်းတာမို့ Outline / Marzban / 3x-ui / SSH /
#  ဝက်ဘ်ဆိုက် — VPS ပေါ်က service အားလုံးရဲ့ usage အကုန် ပေါင်းပြီး ပြတယ်။
#
#  သုံးပုံ (relax99099/newvps):
#    curl -sL https://raw.githubusercontent.com/relax99099/newvps/main/vps-bw.sh | sudo bash
#
#  Quota က VPS တစ်ခုနဲ့ တစ်ခု မတူဘူး (Linode $5 = 1TB, $24 = 4TB, တခြား provider = 8TB ...)
#  ဒါကြောင့် quota ကို VPS တစ်လုံးချင်းစီမှာ တစ်ခါပဲ သတ်မှတ်ထားရင် မှတ်ထားပေးတယ်:
#
#    ပထမဆုံးအကြိမ် (quota သတ်မှတ် + မှတ်ထား):
#      curl -sL <raw-link> | sudo bash -s -- --set-quota 1TB
#      curl -sL <raw-link> | sudo bash -s -- --set-quota 4TB
#      curl -sL <raw-link> | sudo bash -s -- --set-quota 8TB --set-count total
#    နောက်ပိုင်း ပုံမှန် run ရင် မှတ်ထားတဲ့ quota နဲ့ ပြပေးတယ်။
#    တစ်ကြိမ်တည်း ပြောင်းကြည့်ချင်ရင်:  ... | sudo bash -s -- --quota 2TB
#
#  --set-count ဆိုတာ quota ကို ဘယ်လို ရေတွက်လဲ:
#      tx    = Upload (TX) နဲ့ပဲ တွက် (Linode ပုံစံ — Download free)
#      total = Download + Upload ပေါင်းပြီး တွက် (တချို့ provider တွေ)
#  သတ်မှတ်ချက်ကို /etc/vps-bw.conf မှာ သိမ်းထားတယ်။
#  ဘာမှ မသတ်မှတ်ရသေးဘဲ run ရင် terminal မှာ quota မေးပြီး မှတ်ထားပေးလိမ့်မယ်။
#
#  vnstat မရှိသေးရင် ပထမဆုံး run မှာ auto install လုပ်ပေးတယ် —
#  အဲ့ဒီနေ့ကစပြီး လ အလိုက် usage ကို reboot လုပ်လည်း မပျောက်အောင် မှတ်ထားမယ်။
#  vnstat မရှိခင်/စတင်ခါစမှာ ပြတဲ့ ဂဏန်းက "since boot" (နောက်ဆုံး reboot ကစ) ပဲ။
# ============================================================================

BRAND="${BRAND:-PKK STORE}"

P='\033[95m'; C='\033[96m'; G='\033[92m'; Y='\033[93m'; O='\033[38;5;208m'
R='\033[91m'; W='\033[97m'; D='\033[90m'; B='\033[1m'; N='\033[0m'
[ -t 1 ] || { P=''; C=''; G=''; Y=''; O=''; R=''; W=''; D=''; B=''; N=''; }

gb()   { awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1000000000}'; }
h()    { awk -v b="${1:-0}" 'BEGIN{ if(b>=1e12)printf "%.2f TB",b/1e12; else if(b>=1e9)printf "%.1f GB",b/1e9; else if(b>=1e6)printf "%.1f MB",b/1e6; else if(b>=1e3)printf "%.1f KB",b/1e3; else printf "%d B",b }'; }
bar()  { awk -v u="${1:-0}" -v q="${2:-1}" 'BEGIN{ p=(q>0)?u/q:0; if(p>1)p=1; f=int(p*34); s=""; for(i=0;i<f;i++)s=s"█"; for(i=f;i<34;i++)s=s"░"; printf "%s", s }'; }
pct()  { awk -v u="${1:-0}" -v q="${2:-1}" 'BEGIN{ printf "%.1f%%", (q>0)?(u/q)*100:0 }'; }

# ---------------- Quota config (VPS အလိုက် မှတ်ထား) -------------------------
CONF="${VPS_BW_CONF:-}"
if [ -z "$CONF" ]; then
  if [ "$(id -u)" -eq 0 ] || [ -f /etc/vps-bw.conf ]; then CONF="/etc/vps-bw.conf"; else CONF="$HOME/.vps-bw.conf"; fi
fi

parse_quota() { # "8TB" / "1.5TB" / "500GB" / "500" -> GB (number) or empty
  echo "$1" | awk '{
    v=$0; gsub(/ /,"",v); v=tolower(v);
    if (v ~ /tb$/) { sub(/tb$/,"",v); printf "%.0f", v*1000 }
    else { sub(/gb$/,"",v); if (v ~ /^[0-9]+(\.[0-9]+)?$/) printf "%.0f", v; } }'
}

save_conf() { # $1=quota_gb $2=count_mode
  local dir; dir=$(dirname "$CONF")
  mkdir -p "$dir" 2>/dev/null
  if [ -w "$dir" ] || [ -w "$CONF" ]; then
    { echo "QUOTA_GB=$1"; echo "COUNT_MODE=$2"; } > "$CONF" 2>/dev/null \
      && echo -e "${G}Quota မှတ်ထားပြီ: $1 GB (count: $2) → $CONF${N}"
  else
    echo -e "${Y}မှတ်ချက်: $CONF မှာ သိမ်းလို့ မရဘူး (sudo နဲ့ run ပါ) — ဒီတစ်ကြိမ်ပဲ ပြမယ်${N}"
  fi
}

# saved config ဖတ်
SAVED_QUOTA=""; SAVED_MODE=""
if [ -f "$CONF" ]; then
  SAVED_QUOTA=$(grep -E '^QUOTA_GB=' "$CONF" 2>/dev/null | cut -d= -f2)
  SAVED_MODE=$(grep -E '^COUNT_MODE=' "$CONF" 2>/dev/null | cut -d= -f2)
fi

QUOTA_GB="${QUOTA_GB:-$SAVED_QUOTA}"          # env > saved
COUNT_MODE="${COUNT_MODE:-${SAVED_MODE:-tx}}" # env > saved > tx (Linode ပုံစံ)

# arguments: --set-quota <val> | --quota <val> | --set-count <tx|total>
SET_Q=""; SET_C=""
while [ $# -gt 0 ]; do
  case "$1" in
    --set-quota) SET_Q=$(parse_quota "${2:-}"); shift 2 ;;
    --quota)     QUOTA_GB=$(parse_quota "${2:-}"); shift 2 ;;
    --set-count) SET_C="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$SET_C" ] && COUNT_MODE="$SET_C"
if [ -n "$SET_Q" ]; then
  QUOTA_GB="$SET_Q"
  save_conf "$QUOTA_GB" "$COUNT_MODE"
fi
[ "$COUNT_MODE" = "total" ] || COUNT_MODE="tx"

# quota မရှိသေးရင် terminal မှာ မေး (curl|bash ဆိုလည်း /dev/tty ကနေ မေးတယ်)
if [ -z "$QUOTA_GB" ] && [ -z "${NO_PROMPT:-}" ] && [ -c /dev/tty ] && [ -r /dev/tty ]; then
  {
    echo -e "${Y}ဒီ VPS ရဲ့ bandwidth quota ကို မသတ်မှတ်ရသေးဘူး။${N}"
    echo "ဥပမာ: Linode \$5 = 1TB, Linode \$24 = 4TB, တခြား provider = 8TB စသည်"
    printf "Quota ထည့်ပါ (ဥပမာ 1TB / 4TB / 8TB / 500GB) — မထည့်ချင်ရင် Enter ပဲ နှိပ်: "
  } > /dev/tty
  read -t 120 -r ANS < /dev/tty || ANS=""
  Q=$(parse_quota "$ANS")
  if [ -n "$Q" ]; then
    {
      printf "ရေတွက်ပုံ: Linode လို Upload ပဲလား [Enter = tx] / Download+Upload ပေါင်းလား [total ရိုက်]: "
    } > /dev/tty
    read -t 60 -r M < /dev/tty || M=""
    [ "$M" = "total" ] && COUNT_MODE="total" || COUNT_MODE="tx"
    QUOTA_GB="$Q"
    save_conf "$QUOTA_GB" "$COUNT_MODE"
  fi
fi
QUOTA_GB="${QUOTA_GB:-0}"

# ---------------- vnstat auto-install (ပထမအကြိမ်) ---------------------------
IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
IFACE="${IFACE:-eth0}"
if ! command -v vnstat >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && [ -z "${NO_INSTALL:-}" ]; then
  echo -e "${Y}vnstat မရှိသေးလို့ install လုပ်နေတယ်... (လအလိုက် မှတ်ထားနိုင်ဖို့)${N}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq vnstat >/dev/null 2>&1
  systemctl enable --now vnstat >/dev/null 2>&1 || service vnstat start >/dev/null 2>&1
  sleep 2
fi

# ---------------- Data ယူ ---------------------------------------------------
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
    if [ $((M_RX + M_TX)) -ge $((BOOT_RX + BOOT_TX)) ]; then
      SRC="vnstat (ဒီလ အတိအကျ)"; HAVE_VNSTAT=1
    else
      SRC="since boot (vnstat စစုခါစမို့ — နောက်ရက်တွေမှာ လအလိုက် အတိအကျ ဖြစ်လာမယ်)"
      M_RX=$BOOT_RX; M_TX=$BOOT_TX; T_RX=$BOOT_RX; T_TX=$BOOT_TX
    fi
  fi
fi

MONTH_TOTAL=$((M_RX + M_TX))
# quota နဲ့ တွက်မယ့် usage: tx mode = Upload ပဲ, total mode = RX+TX
if [ "$COUNT_MODE" = "total" ]; then USED_BYTES=$MONTH_TOTAL; USED_LABEL="Download+Upload"; else USED_BYTES=$M_TX; USED_LABEL="Upload"; fi
QUOTA_BYTES=$(awk -v g="$QUOTA_GB" 'BEGIN{printf "%.0f", g*1000000000}')
REMAIN_BYTES=$((QUOTA_BYTES - USED_BYTES)); [ "$REMAIN_BYTES" -lt 0 ] && REMAIN_BYTES=0
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
if [ "$QUOTA_GB" -gt 0 ]; then
  echo -e "${O}${B}Bandwidth Quota (${USED_LABEL} နဲ့ တွက်သည်)${N}"
  echo -e "${Y}$(bar $USED_BYTES $QUOTA_BYTES)  $(pct $USED_BYTES $QUOTA_BYTES)${N}"
  echo -e "${W}သုံးပြီး (${USED_LABEL}): ${B}$(gb $USED_BYTES) GB${N}  /  ${QUOTA_GB} GB"
  echo -e "${W}ကျန်သေး:          ${G}${B}$(gb $REMAIN_BYTES) GB${N}"
  if [ "$USED_BYTES" -ge "$QUOTA_BYTES" ]; then
    echo -e "${R}${B}⚠ Quota ပြည့်သွားပြီ / ကျော်သွားပြီ${N}"
  elif [ "$USED_BYTES" -ge $((QUOTA_BYTES * 80 / 100)) ]; then
    echo -e "${R}${B}⚠ Quota ရဲ့ 80% ကျော်နေပြီ — သတိထားပါ${N}"
  fi
else
  echo -e "${Y}${B}Quota မသတ်မှတ်ရသေးပါ${N} — ဒီ VPS ရဲ့ quota သတ်မှတ်ဖို့:"
  echo -e "${W}  curl -sL https://raw.githubusercontent.com/relax99099/newvps/main/vps-bw.sh | sudo bash -s -- --set-quota 1TB${N}"
  echo -e "${D}  (ဥပမာ: 1TB / 4TB / 8TB — Download+Upload ပေါင်းတွက်တဲ့ provider ဆိုရင် --set-count total ထည့်ပါ)${N}"
fi
echo -e "${D}Data source: $SRC${N}"
echo -e "${C}____________________________________________________________________________${N}"

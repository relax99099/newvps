#!/bin/bash
#
# add-proxies.sh - Marzban: give EVERY user all 4 proxies
# (VMess, VLESS, Trojan, Shadowsocks)
#
# One-liner (run on the Marzban host, as root):
#   bash <(curl -sL https://raw.githubusercontent.com/relax99099/newvps/main/add-proxies.sh)
#
# Options:
#   --dry-run       show what would change, change nothing
#   --active-only   only active users (default: all users)
#   --no-restart    do not restart Marzban at the end
#   --db PATH       use another db.sqlite3 (default /var/lib/marzban/db.sqlite3)
#
# Only MISSING proxy types are inserted - existing proxies are never
# touched. A timestamped DB backup is saved before any change.

DB="/var/lib/marzban/db.sqlite3"
DRY_RUN=0
ACTIVE_ONLY=0
NO_RESTART=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --active-only) ACTIVE_ONLY=1 ;;
        --no-restart) NO_RESTART=1 ;;
        --db) DB="$2"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

echo -e "\e[1;36m--------------------------------------------------\e[0m"
echo -e "\e[1;36m  Add Proxies - VMess / VLESS / Trojan / Shadowsocks\e[0m"
echo -e "\e[1;36m--------------------------------------------------\e[0m"

# --- Checks ---
if [ ! -f "$DB" ]; then
    echo -e "\e[1;31m❌ Error: Marzban DB ရှာမတွေ့ပါ: $DB\e[0m"
    exit 1
fi
echo -e "\e[1;32m✅ DB found: $DB\e[0m"

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "\e[1;31m❌ Error: python3 မရှိပါ။\e[0m"
    exit 1
fi

# --- Plan + apply (embedded python; same logic as add-proxies.py) ---
PY_ARGS="--db $DB"
[ "$DRY_RUN" -eq 0 ] && PY_ARGS="$PY_ARGS --yes"
[ "$ACTIVE_ONLY" -eq 0 ] && PY_ARGS="$PY_ARGS --all"

PY_OUT=$(python3 - $PY_ARGS <<'PYEOF'
import argparse
import json
import secrets
import shutil
import sqlite3
import sys
import uuid
from datetime import datetime

def new_settings(proxy_type):
    if proxy_type == "VMess":
        return {"id": str(uuid.uuid4())}
    if proxy_type == "VLESS":
        return {"id": str(uuid.uuid4()), "flow": ""}
    if proxy_type == "Trojan":
        return {"password": secrets.token_urlsafe(16), "flow": ""}
    if proxy_type == "Shadowsocks":
        return {"password": secrets.token_urlsafe(16),
                "method": "chacha20-ietf-poly1305"}
    raise ValueError(proxy_type)

REQUIRED = ["VMess", "VLESS", "Trojan", "Shadowsocks"]

ap = argparse.ArgumentParser()
ap.add_argument("--yes", action="store_true")
ap.add_argument("--all", action="store_true")
ap.add_argument("--db", required=True)
args = ap.parse_args()

db = sqlite3.connect(args.db)
if args.all:
    users = db.execute("SELECT id, username, status FROM users ORDER BY id").fetchall()
    scope = "ALL users"
else:
    users = db.execute(
        "SELECT id, username, status FROM users WHERE status = 'active' ORDER BY id"
    ).fetchall()
    scope = "active users only"
print(f"Scope: {scope} ({len(users)} users)")

plan = []
for user_id, username, status in users:
    have = {row[0] for row in db.execute(
        "SELECT type FROM proxies WHERE user_id = ?", (user_id,))}
    missing = [t for t in REQUIRED if t not in have]
    if missing:
        plan.append((user_id, username, missing))

if not plan:
    print("NOTHING_TO_DO")
    sys.exit(0)

total = sum(len(m) for _, _, m in plan)
for user_id, username, missing in plan:
    print(f"  {username}: add {', '.join(missing)}")
print(f"{len(plan)} users, {total} proxies to add.")

if not args.yes:
    print("Dry-run only. Nothing was changed.")
    sys.exit(0)

backup = f"{args.db}.bak-addproxies-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(args.db, backup)
print(f"Backup saved: {backup}")

with db:
    for user_id, username, missing in plan:
        for proxy_type in missing:
            db.execute(
                "INSERT INTO proxies (user_id, type, settings) VALUES (?, ?, ?)",
                (user_id, proxy_type, json.dumps(new_settings(proxy_type))),
            )
print(f"ADDED {total} proxies to {len(plan)} users.")
PYEOF
)
PY_STATUS=$?
echo "$PY_OUT"
if [ $PY_STATUS -ne 0 ]; then
    echo -e "\e[1;31m❌ Error: Python step failed (exit $PY_STATUS)\e[0m"
    exit 1
fi

if echo "$PY_OUT" | grep -q "NOTHING_TO_DO"; then
    echo "--------------------------------------------------"
    echo -e "\e[1;32m✅ User တိုင်း proxy 4 ခု စုံနေပြီးသားပါ — ဘာမှ လုပ်စရာ မလိုပါ။\e[0m"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "--------------------------------------------------"
    echo -e "\e[1;33mDry-run ပြီးပါပြီ — ဘာမှ မပြောင်းထားပါ။\e[0m"
    exit 0
fi

# --- Restart Marzban so the core picks up the new proxies ---
if [ "$NO_RESTART" -eq 0 ]; then
    echo "🔄 Marzban restart လုပ်နေပါတယ်..."
    if command -v marzban >/dev/null 2>&1; then
        marzban restart
    elif [ -f /opt/marzban/docker-compose.yml ]; then
        (cd /opt/marzban && docker compose restart marzban)
    else
        echo -e "\e[1;33m⚠️ Auto-restart မရပါ။ ကိုယ်တိုင် restart လုပ်ပေးပါ:\e[0m"
        echo "  cd /opt/marzban && docker compose restart marzban"
    fi
fi

echo "--------------------------------------------------"
echo -e "\e[1;32m🔥 Add Proxies Complete - user တိုင်း proxy 4 ခု စုံပါပြီ 🔥\e[0m"
echo "--------------------------------------------------"

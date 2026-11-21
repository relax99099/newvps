#!/usr/bin/env python3
"""
add-proxies.py - Marzban: give every user all 4 proxies
(VMess, VLESS, Trojan, Shadowsocks).

Users created by the sale bots only get VMess + Trojan + Shadowsocks,
so their subscriptions have no VLESS (Reality) link. This script inserts
ONLY the missing proxy types into the Marzban database - existing
proxies are never touched.

Usage (run on the Marzban host, as root):
  python3 add-proxies.py                 dry-run: show what would change
  python3 add-proxies.py --yes           apply (a DB backup is made first)
  python3 add-proxies.py --yes --all     also include expired / disabled /
                                         limited / on_hold users
  python3 add-proxies.py --db PATH       use another db.sqlite3 path
                                         (default /var/lib/marzban/db.sqlite3)

After applying, restart Marzban so the xray core picks up the new
proxies:
  cd /opt/marzban && docker compose restart marzban
"""

import argparse
import json
import secrets
import shutil
import sqlite3
import sys
import uuid
from datetime import datetime

# type name as stored in the DB -> settings for a brand-new proxy
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


def main():
    ap = argparse.ArgumentParser(description="Add missing proxies to Marzban users")
    ap.add_argument("--yes", action="store_true", help="apply changes (default is dry-run)")
    ap.add_argument("--all", action="store_true", help="include non-active users too")
    ap.add_argument("--db", default="/var/lib/marzban/db.sqlite3", help="path to Marzban db.sqlite3")
    args = ap.parse_args()

    try:
        db = sqlite3.connect(args.db)
    except sqlite3.Error as e:
        sys.exit(f"Cannot open DB {args.db}: {e}")

    if args.all:
        users = db.execute("SELECT id, username, status FROM users ORDER BY id").fetchall()
        scope = "ALL users"
    else:
        users = db.execute(
            "SELECT id, username, status FROM users WHERE status = 'active' ORDER BY id"
        ).fetchall()
        scope = "active users only"

    print(f"Scope: {scope} ({len(users)} users)")

    plan = []  # (user_id, username, [missing types])
    for user_id, username, status in users:
        have = {row[0] for row in db.execute(
            "SELECT type FROM proxies WHERE user_id = ?", (user_id,))}
        missing = [t for t in REQUIRED if t not in have]
        if missing:
            plan.append((user_id, username, missing))

    if not plan:
        print("Nothing to do - every user in scope already has all 4 proxies.")
        return

    total = sum(len(m) for _, _, m in plan)
    for user_id, username, missing in plan:
        print(f"  {username}: add {', '.join(missing)}")
    print(f"{len(plan)} users, {total} proxies to add.")

    if not args.yes:
        print("Dry-run only. Run again with --yes to apply.")
        return

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
    print(f"Done - added {total} proxies to {len(plan)} users.")
    print("Now restart Marzban so the core picks them up:")
    print("  cd /opt/marzban && docker compose restart marzban")


if __name__ == "__main__":
    main()

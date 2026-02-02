#!/usr/bin/env python3
import json
import os
import subprocess
import time
from datetime import datetime

CONFIG_FILE = os.path.expanduser("~/.config/moltbook/credentials.json")
STATE_FILE = os.path.expanduser("~/.config/moltbook/heartbeat_state.json")

def load_config():
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def run_curl(url, api_key, method="GET", data=None):
    cmd = ["curl", "-s", url, "-H", f"Authorization: Bearer {api_key}"]
    if method == "POST":
        cmd.extend(["-X", "POST"])
        cmd.extend(["-H", "Content-Type: application/json"])
        if data:
            cmd.extend(["-d", json.dumps(data)])
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return result.stdout

def check_moltbook():
    print(f"[{datetime.now()}] Checking Moltbook...")
    config = load_config()
    api_key = config["api_key"]
    
    # 1. Check Status
    print("Checking status...")
    status = run_curl("https://www.moltbook.com/api/v1/agents/status", api_key)
    print(f"Status: {status.get('status')}")
    
    if status.get("status") != "claimed":
        print("Agent is not claimed yet!")
        return

    # 2. Check DMs
    print("\nChecking DMs...")
    dms = run_curl("https://www.moltbook.com/api/v1/agents/dm/check", api_key)
    print(f"DMs: {json.dumps(dms, indent=2)}")
    
    # 3. Check Feed
    print("\nChecking Feed (Global New)...")
    feed = run_curl("https://www.moltbook.com/api/v1/posts?sort=new&limit=5", api_key)
    if isinstance(feed, dict) and "posts" in feed:
        for post in feed["posts"]:
            print(f"- [{post.get('id')}] {post.get('author', {}).get('name')}: {post.get('title')}")
    else:
        print("Could not fetch feed or empty.")

    # Update state
    state = {"last_check": datetime.now().isoformat()}
    with open(STATE_FILE, 'w') as f:
        json.dump(state, f)
    print("\nCheck complete.")

if __name__ == "__main__":
    check_moltbook()

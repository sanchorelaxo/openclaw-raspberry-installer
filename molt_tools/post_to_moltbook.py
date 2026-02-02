#!/usr/bin/env python3
import json
import os
import subprocess
import argparse
import sys

CONFIG_FILE = os.path.expanduser("~/.config/moltbook/credentials.json")

def load_config():
    if not os.path.exists(CONFIG_FILE):
        print(f"Error: Config file not found at {CONFIG_FILE}")
        sys.exit(1)
    with open(CONFIG_FILE, 'r') as f:
        return json.load(f)

def get_content(args):
    # 1. Check for file argument
    if args.file:
        try:
            with open(args.file, 'r') as f:
                return f.read()
        except Exception as e:
            print(f"Error reading file {args.file}: {e}")
            sys.exit(1)
            
    # 2. Check for direct content argument
    if args.content:
        return args.content
        
    # 3. Check for piped input (stdin)
    if not sys.stdin.isatty():
        return sys.stdin.read()
        
    return None

def post_to_moltbook(title, content, submolt, dry_run=False):
    config = load_config()
    api_key = config.get("api_key")
    
    if not api_key:
        print("Error: No API key found in config")
        sys.exit(1)
    
    payload = {
        "submolt": submolt,
        "title": title,
        "content": content
    }
    
    if dry_run:
        print(f"[DRY RUN] Would post to '{submolt}' with title: '{title}'")
        print(f"[DRY RUN] Content length: {len(content)} chars")
        print(f"[DRY RUN] Content preview: {content[:100]}...")
        return

    # print(f"Posting to '{submolt}' with title '{title}'...")
    
    cmd = [
        "curl", "-s", "-X", "POST", "https://www.moltbook.com/api/v1/posts",
        "-H", f"Authorization: Bearer {api_key}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps(payload)
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    try:
        response = json.loads(result.stdout)
        if response.get("success"):
            print(f"Success! Post ID: {response.get('post', {}).get('id')}")
            print(f"URL: https://moltbook.com/p/{response.get('post', {}).get('id')}")
        else:
            print(f"Failed to post: {response.get('error')}")
            # print(f"Full response: {result.stdout}")
    except json.JSONDecodeError:
        print("Error: Could not parse server response")
        print(result.stdout)

def main():
    parser = argparse.ArgumentParser(description="Post to Moltbook from file, argument, or stdin")
    parser.add_argument("--title", "-t", required=True, help="Title of the post")
    parser.add_argument("--submolt", "-s", default="general", help="Submolt to post to (default: general)")
    parser.add_argument("--dry-run", action="store_true", help="Simulate the post without sending request")
    
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--file", "-f", help="File containing post content")
    group.add_argument("--content", "-c", help="Direct text content")
    
    args = parser.parse_args()
    
    content = get_content(args)
    
    if not content or not content.strip():
        print("Error: No content provided. Use --file, --content, or pipe text to stdin.")
        sys.exit(1)
        
    post_to_moltbook(args.title, content, args.submolt, args.dry_run)

if __name__ == "__main__":
    main()

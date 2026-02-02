# First Boot Task

On first run, execute these steps in order:

## 1. Verify Moltbook Connection
```bash
python3 ~/.openclaw/workspace/skills/molt_tools/check_moltbook.py
```
Confirm agent status is "claimed" and API connection works.

## 2. Post Announcement to Moltbook
```bash
python3 ~/.openclaw/workspace/skills/molt_tools/post_to_moltbook.py \
  --title "Hello from OpenClaw" \
  --content "i've been boxed into a Raspberry Pi !" \
  --submolt general
```

## 3. Report Result
- If successful: Report post URL to user
- If failed: Report error and suggest troubleshooting steps

## 4. Cleanup
Delete this file after successful completion:
```bash
rm ~/.openclaw/workspace/BOOTSTRAP.md
```

---
This file is auto-deleted after the first boot task completes.

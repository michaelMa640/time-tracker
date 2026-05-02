#!/usr/bin/env python3
"""batch_create.py - call lark-cli batch create via Python for correct JSON"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

def resolve_cli_path(cli_path=None):
    candidates = [
        cli_path,
        os.environ.get("TIME_TRACKER_LARK_CLI_PATH"),
        shutil.which("lark-cli"),
        shutil.which("lark-cli.cmd"),
    ]

    appdata = os.environ.get("APPDATA")
    if appdata:
        candidates.append(os.path.join(appdata, "npm", "lark-cli.cmd"))

    for candidate in candidates:
        if not candidate:
            continue
        if os.path.exists(candidate):
            return candidate
        resolved = shutil.which(candidate)
        if resolved:
            return resolved

    raise FileNotFoundError(
        "Unable to locate lark-cli. Install it or set TIME_TRACKER_LARK_CLI_PATH."
    )


def batch_create(base_token, table_id, field_ids, rows, dry_run=False, cli_path=None, workdir=None):
    body = {"fields": field_ids, "rows": rows}
    json_str = json.dumps(body, ensure_ascii=False, separators=(',', ':'))
    workdir = workdir or os.getcwd()

    # Keep the payload file under the working directory and reference it relatively.
    fd, json_path = tempfile.mkstemp(
        prefix="_tmp_batch_create_",
        suffix=".json",
        dir=workdir,
        text=True,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json_str)

        cmd = [
            resolve_cli_path(cli_path),
            "base", "+record-batch-create",
            "--base-token", base_token,
            "--table-id", table_id,
            "--json", f"@./{os.path.basename(json_path)}",
            "--as", "user"
        ]
        if dry_run:
            cmd.append("--dry-run")

        result = subprocess.run(cmd, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", cwd=workdir)
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        if result.returncode != 0:
            if result.stdout:
                print(result.stdout, file=sys.stderr, end="")
            print(f"Exit {result.returncode}", file=sys.stderr)
            sys.exit(result.returncode)

        resp = json.loads(result.stdout)
        ok = resp.get("ok", False)
        if not ok:
            err = resp.get("error", {})
            print(f"API error: {err.get('message', result.stdout)}", file=sys.stderr)
            sys.exit(1)

        record_ids = resp.get("data", {}).get("record_id_list", [])
        for rid in record_ids:
            print(rid)
    finally:
        if os.path.exists(json_path):
            os.remove(json_path)

if __name__ == "__main__":
    import json as _json
    with open(sys.argv[1], encoding="utf-8") as f:
        data = _json.load(f)
    batch_create(data["base_token"], data["table_id"],
                 data["field_ids"], data["rows"],
                 dry_run=data.get("dry_run", False),
                 cli_path=data.get("cli_path"),
                 workdir=data.get("workdir"))

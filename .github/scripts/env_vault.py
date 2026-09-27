#!/usr/bin/env python3
"""
env_vault.py — نگهبان متغیرهای محیطی Hermes و OmniRoute.

چرا پایتون و نه bash: نسخهٔ bash دو بار روی سرور شکست خورد (ارجاع به
متغیر در همان دستور `local` با `set -u`، و sed روی مقادیری که کاراکتر
خاص دارند). دستکاری متنیِ فایل اسرار جایی نیست که زرنگ‌بازی کنیم.

سیاست
-----
* هر کلیدِ دارای مقدارِ معنادار در گاوصندوق نگه داشته می‌شود
* کلید غایب یا خالی از گاوصندوق برمی‌گردد
* کلیدی که مقدار غیرخالیِ متفاوت دارد **دست‌نخورده** می‌ماند — کاربر حق
  دارد مقدار را عوض کند؛ فقط گاوصندوق به‌روز می‌شود
* پنجرهٔ blanking خود save.sh محترم است (sentinel)، مگر کهنه شده باشد
"""
from __future__ import annotations
import os, re, sys, time, subprocess

VAULT = "/var/lib/hermes-guard/vault"
LOG = "/var/log/env-vault.log"
SENTINEL = "/run/hermes-env-blanked"
STALE = 600
KV = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
PLACEHOLDER = re.compile(r"^(your-|changeme|xxx|<|\$\{|\s*$)", re.I)

TARGETS = {
    "hermes": "/root/.hermes/.env",
    "omniroute": "/root/.omniroute/.env",
}
EXTRA_SOURCES = {"hermes": ["/var/lib/hermes-guard/env.preblank",
                            "/root/backups/envs/hermes.env"],
                 "omniroute": ["/root/.omniroute-secrets",
                               "/root/backups/envs/omniroute.env"]}


def say(msg: str) -> None:
    line = f"[{time.strftime('%F %T', time.gmtime())}] {msg}"
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line)


def meaningful(v: str) -> bool:
    return len(v.strip()) >= 4 and not PLACEHOLDER.match(v.strip())


def read_env(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for ln in f:
                m = KV.match(ln.rstrip("\n"))
                if m:
                    out[m.group(1)] = m.group(2)
    except OSError:
        pass
    return out


def main() -> int:
    if os.path.exists(SENTINEL):
        age = time.time() - os.path.getmtime(SENTINEL)
        if age < STALE:
            return 0
        say(f"sentinel stale ({int(age)}s) — proceeding")

    os.makedirs(VAULT, mode=0o700, exist_ok=True)
    changed: list[str] = []

    for name, envp in TARGETS.items():
        store = os.path.join(VAULT, name)
        vault = read_env(store)

        # ۱) از منابع کمکی هم غنی‌اش کن (preblank و پشتیبان‌ها)
        for src in EXTRA_SOURCES.get(name, []):
            for k, v in read_env(src).items():
                if meaningful(v) and not meaningful(vault.get(k, "")):
                    vault[k] = v

        # ۲) از فایل زنده به‌روزش کن
        live = read_env(envp)
        for k, v in live.items():
            if meaningful(v):
                vault[k] = v

        if vault:
            tmp = store + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                for k, v in vault.items():
                    f.write(f"{k}={v}\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, store)

        # ۳) بازگردانی کلیدهای گم/خالی
        if not os.path.exists(envp):
            say(f"{name}: .env missing — recreating from vault")
            os.makedirs(os.path.dirname(envp), exist_ok=True)
            with open(envp, "w", encoding="utf-8") as f:
                for k, v in vault.items():
                    f.write(f"{k}={v}\n")
            os.chmod(envp, 0o600)
            changed.append(name)
            continue

        missing = [k for k, v in vault.items() if not meaningful(live.get(k, ""))]
        if not missing:
            continue

        lines = open(envp, encoding="utf-8", errors="replace").read().splitlines(True)
        seen = set()
        out = []
        for ln in lines:
            m = KV.match(ln.rstrip("\n"))
            if m and m.group(1) in missing:
                k = m.group(1)
                out.append(f"{k}={vault[k]}\n")
                seen.add(k)
            else:
                out.append(ln)
        for k in missing:
            if k not in seen:
                if out and not out[-1].endswith("\n"):
                    out.append("\n")
                out.append(f"{k}={vault[k]}\n")
        tmp = envp + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(out)
        os.chmod(tmp, 0o600)
        os.replace(tmp, envp)
        say(f"{name}: restored {len(missing)} key(s): {', '.join(missing[:6])}")
        changed.append(name)

    if "hermes" in changed:
        subprocess.run(["systemctl", "restart", "hermes-serve"], check=False)
        subprocess.run(["systemctl", "--user", "restart", "hermes-gateway.service"],
                       check=False, env={**os.environ, "XDG_RUNTIME_DIR": "/run/user/0"})
    if "omniroute" in changed:
        subprocess.run(["systemctl", "restart", "omniroute"], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())

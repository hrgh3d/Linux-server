#!/usr/bin/env python3
"""
gh_cleanup.py (v6.37) — پاک‌سازی امن محیط GitHub بدون آسیب به سیستم زنده.

چه چیزی را پاک می‌کند
  * workflow runهای *تمام‌شده* که از RETENTION_DAYS قدیمی‌ترند (پیش‌فرض ۲ روز)
  * artifactهای منقضی/قدیمی
  * cacheهای Actions
  * ریلیزهای یتیم (تگ‌هایی که هیچ اسکریپتی به آن‌ها ارجاع نمی‌دهد)

چه چیزی را *هرگز* لمس نمی‌کند (خط قرمزها)
  * هر ران با وضعیت in_progress / queued / waiting / requested / pending
  * N ران آخرِ هر workflow (پیش‌فرض ۵) حتی اگر قدیمی باشند — برای اینکه
    watchdog.sh که با per_page=50 لیست را می‌خواند همیشه تاریخچهٔ کافی ببیند
  * ریلیز/تگ `state` و همهٔ assetهایش — قلب پایداری سیستم است و
    save.sh/restore.sh/watchdog/heartbeat به آن وابسته‌اند. چرخش keep-2 آن
    توسط state_sync.py مدیریت می‌شود و این اسکریپت در آن دخالت نمی‌کند.
  * هیچ محتوای گیت (کامیت/برنچ/تگ کد) — فقط متادیتای Actions و ریلیزهای یتیم
  * ران‌هایی که در پنجرهٔ ایمنی اخیر هستند (RETENTION_DAYS)

اصول طراحی
  * پیش‌فرض DRY-RUN. حذف واقعی فقط با --apply.
  * پیش از هر حذف، یک بکاپ JSON کامل از چیزی که قرار است حذف شود ذخیره می‌شود
    (شامل شناسه، نام، وضعیت، زمان و URL لاگ) تا سابقه از بین نرود.
  * محدودکنندهٔ نرخ: مکث کوتاه بین درخواست‌ها + احترام به هدرهای rate-limit،
    چون OpenClaw و رانر زنده هم‌زمان از همین API استفاده می‌کنند.
  * سقف حذف در هر اجرا (--max-delete) تا یک اشتباه نتواند همه‌چیز را ببرد.

Usage:
  gh_cleanup.py --repo owner/name [--days 2] [--keep-per-workflow 5]
                [--apply] [--max-delete 400] [--backup-dir DIR]
                [--include-releases] [--json]
"""
import argparse
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://api.github.com"

# --------------------------------------------------------------- خط قرمزها
# وضعیت‌هایی که یعنی «این ران زنده است» — حذفشان سرور را می‌کشد.
LIVE_STATUSES = {"in_progress", "queued", "waiting", "requested", "pending",
                 "action_required"}

# تگ ریلیزهایی که سیستم به آن‌ها وابسته است. هرگز حذف نمی‌شوند.
# (از common.sh: STATE_TAG=state — save/restore/watchdog/heartbeat همگی این را
#  می‌خوانند. اگر روزی تگ دیگری اضافه شد، همین‌جا ثبتش کنید.)
PROTECTED_RELEASE_TAGS = {"state"}

_last_call = [0.0]


def _throttle(min_gap=0.12):
    """فاصلهٔ حداقلی بین درخواست‌ها: API را برای رانر زنده خفه نکنیم."""
    dt = time.time() - _last_call[0]
    if dt < min_gap:
        time.sleep(min_gap - dt)
    _last_call[0] = time.time()


def req(method, path, token, data=None, retries=3):
    """درخواست به API با احترام به rate-limit و تلاش مجدد."""
    url = path if path.startswith("http") else API + path
    body = json.dumps(data).encode() if data is not None else None
    for attempt in range(retries):
        _throttle()
        r = urllib.request.Request(url, data=body, method=method)
        r.add_header("Authorization", "Bearer " + token)
        r.add_header("Accept", "application/vnd.github+json")
        r.add_header("X-GitHub-Api-Version", "2022-11-28")
        if body:
            r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r, timeout=45) as resp:
                remaining = resp.headers.get("X-RateLimit-Remaining")
                if remaining is not None and remaining.isdigit() \
                        and int(remaining) < 60:
                    # نزدیک سقف: سرعت را کم کن تا سیستم زنده بی‌سهم نماند
                    time.sleep(1.5)
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            if e.code in (403, 429) and attempt < retries - 1:
                reset = e.headers.get("X-RateLimit-Reset")
                wait = 5.0
                if reset and reset.isdigit():
                    wait = max(2.0, min(60.0, int(reset) - time.time() + 2))
                print(f"    [rate-limit] waiting {wait:.0f}s...", flush=True)
                time.sleep(wait)
                continue
            if e.code in (404, 410):
                return e.code, {}
            if attempt < retries - 1 and e.code >= 500:
                time.sleep(2 * (attempt + 1))
                continue
            return e.code, {"error": e.read().decode(errors="replace")[:300]}
        except Exception as e:  # noqa: BLE001
            if attempt < retries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return 0, {"error": str(e)[:300]}
    return 0, {"error": "exhausted retries"}


def paginate(path, token, key, cap_pages=60):
    """همهٔ صفحات یک لیست را جمع می‌کند."""
    out = []
    for page in range(1, cap_pages + 1):
        sep = "&" if "?" in path else "?"
        st, d = req("GET", f"{path}{sep}per_page=100&page={page}", token)
        if st != 200:
            break
        chunk = d.get(key, []) if isinstance(d, dict) else []
        if not chunk:
            break
        out.extend(chunk)
        if len(chunk) < 100:
            break
    return out


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


# ------------------------------------------------------------------ تحلیل
def plan_runs(repo, token, days, keep_per_wf, now):
    """تصمیم‌گیری دربارهٔ هر run. خروجی: (لیست حذف, لیست نگه‌داشتن+دلیل, آمار)."""
    runs = paginate(f"/repos/{repo}/actions/runs", token, "workflow_runs")
    cutoff = now - datetime.timedelta(days=days)

    # ران‌ها را per-workflow مرتب می‌کنیم تا «N تای آخر» را نگه داریم
    by_wf = {}
    for r in runs:
        by_wf.setdefault(r.get("workflow_id"), []).append(r)
    for v in by_wf.values():
        v.sort(key=lambda x: x.get("created_at") or "", reverse=True)

    recent_ids = set()
    for v in by_wf.values():
        for r in v[:keep_per_wf]:
            recent_ids.add(r["id"])

    delete, keep = [], []
    for r in runs:
        rid = r["id"]
        status = r.get("status") or ""
        created = parse_ts(r.get("created_at"))
        item = {
            "id": rid,
            "run_number": r.get("run_number"),
            "name": r.get("name"),
            "path": r.get("path"),
            "status": status,
            "conclusion": r.get("conclusion"),
            "created_at": r.get("created_at"),
            "html_url": r.get("html_url"),
        }
        # --- خط قرمز ۱: ران زنده
        if status in LIVE_STATUSES:
            item["keep_reason"] = f"LIVE ({status}) — deleting would kill the server"
            keep.append(item)
            continue
        # --- خط قرمز ۲: جزو N تای آخرِ این workflow
        if rid in recent_ids:
            item["keep_reason"] = f"within newest {keep_per_wf} of its workflow (watchdog needs history)"
            keep.append(item)
            continue
        # --- خط قرمز ۳: داخل پنجرهٔ نگهداری
        if created and created > cutoff:
            age_h = (now - created).total_seconds() / 3600
            item["keep_reason"] = f"only {age_h:.1f}h old (< {days}d retention)"
            keep.append(item)
            continue
        item["age_days"] = round((now - created).total_seconds() / 86400, 2) if created else None
        delete.append(item)

    stats = {"total": len(runs), "delete": len(delete), "keep": len(keep)}
    return delete, keep, stats


def plan_artifacts(repo, token, days, now):
    arts = paginate(f"/repos/{repo}/actions/artifacts", token, "artifacts")
    cutoff = now - datetime.timedelta(days=days)
    delete, keep = [], []
    for a in arts:
        created = parse_ts(a.get("created_at"))
        item = {"id": a["id"], "name": a.get("name"),
                "size_in_bytes": a.get("size_in_bytes"),
                "expired": a.get("expired"), "created_at": a.get("created_at")}
        if a.get("expired") or (created and created < cutoff):
            delete.append(item)
        else:
            item["keep_reason"] = "within retention"
            keep.append(item)
    return delete, keep


def plan_caches(repo, token):
    st, d = req("GET", f"/repos/{repo}/actions/caches?per_page=100", token)
    if st != 200:
        return []
    return [{"id": c["id"], "key": c.get("key"),
             "size_in_bytes": c.get("size_in_bytes"),
             "last_accessed_at": c.get("last_accessed_at")}
            for c in d.get("actions_caches", [])]


def plan_releases(repo, token, days, now):
    """فقط ریلیزهای یتیم و قدیمی. تگ‌های محافظت‌شده هرگز."""
    st, d = req("GET", f"/repos/{repo}/releases?per_page=100", token)
    rels = d if st == 200 and isinstance(d, list) else []
    cutoff = now - datetime.timedelta(days=days)
    delete, keep = [], []
    for r in rels:
        tag = r.get("tag_name") or ""
        published = parse_ts(r.get("published_at") or r.get("created_at"))
        size = sum(a.get("size", 0) for a in r.get("assets", []))
        item = {"id": r["id"], "tag_name": tag, "assets": len(r.get("assets", [])),
                "bytes": size, "published_at": r.get("published_at")}
        if tag in PROTECTED_RELEASE_TAGS:
            item["keep_reason"] = "PROTECTED — live persistence depends on this tag"
            keep.append(item)
            continue
        if published and published > cutoff:
            item["keep_reason"] = "within retention"
            keep.append(item)
            continue
        delete.append(item)
    return delete, keep


# ------------------------------------------------------------------ اجرا
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--days", type=int, default=2,
                    help="سن لازم برای حذف (پیش‌فرض ۲ روز)")
    ap.add_argument("--keep-per-workflow", type=int, default=5,
                    help="حداقل تعداد ران اخیر که در هر workflow نگه داشته می‌شود")
    ap.add_argument("--apply", action="store_true",
                    help="حذف واقعی (بدون این پرچم فقط گزارش می‌دهد)")
    ap.add_argument("--max-delete", type=int, default=400,
                    help="سقف حذف در هر اجرا (محافظ اشتباه)")
    ap.add_argument("--backup-dir", default="/tmp/gh-cleanup-backups")
    ap.add_argument("--include-releases", action="store_true",
                    help="ریلیزهای یتیم قدیمی را هم حذف کن (تگ‌های محافظت‌شده هرگز)")
    ap.add_argument("--skip-artifacts", action="store_true")
    ap.add_argument("--skip-caches", action="store_true")
    ap.add_argument("--json", action="store_true", help="خروجی ماشین‌خوان")
    args = ap.parse_args()

    token = (os.environ.get("CLEANUP_TOKEN") or os.environ.get("GH_TOKEN")
             or os.environ.get("GITHUB_TOKEN") or os.environ.get("PERSIST_TOKEN"))
    if not token:
        print("ERROR: no token (set CLEANUP_TOKEN / GH_TOKEN / GITHUB_TOKEN)",
              file=sys.stderr)
        return 2

    now = datetime.datetime.now(datetime.timezone.utc)
    mode = "APPLY (deleting)" if args.apply else "DRY-RUN (nothing deleted)"
    print(f"=== gh_cleanup v6.37 — {args.repo} — {mode} ===")
    print(f"    retention={args.days}d  keep_per_workflow={args.keep_per_workflow}  "
          f"max_delete={args.max_delete}")
    print(f"    protected release tags: {sorted(PROTECTED_RELEASE_TAGS)}")

    print("\n[1/4] analysing workflow runs...")
    del_runs, keep_runs, stats = plan_runs(args.repo, token, args.days,
                                           args.keep_per_workflow, now)
    live = [k for k in keep_runs if "LIVE" in k.get("keep_reason", "")]
    print(f"    total={stats['total']}  to_delete={stats['delete']}  keep={stats['keep']}")
    if live:
        print(f"    🛡  {len(live)} LIVE run(s) protected:")
        for k in live:
            print(f"        #{k['run_number']} {str(k['name'])[:34]:36} {k['status']}")

    del_arts, keep_arts = ([], [])
    if not args.skip_artifacts:
        print("\n[2/4] analysing artifacts...")
        del_arts, keep_arts = plan_artifacts(args.repo, token, args.days, now)
        mb = sum(a.get("size_in_bytes") or 0 for a in del_arts) / 1e6
        print(f"    to_delete={len(del_arts)} ({mb:.1f}MB)  keep={len(keep_arts)}")

    del_caches = []
    if not args.skip_caches:
        print("\n[3/4] analysing caches...")
        del_caches = plan_caches(args.repo, token)
        mb = sum(c.get("size_in_bytes") or 0 for c in del_caches) / 1e6
        print(f"    to_delete={len(del_caches)} ({mb:.1f}MB)")

    del_rels, keep_rels = ([], [])
    print("\n[4/4] analysing releases...")
    del_rels, keep_rels = plan_releases(args.repo, token, args.days, now)
    for k in keep_rels:
        if "PROTECTED" in k.get("keep_reason", ""):
            print(f"    🛡  tag '{k['tag_name']}' PROTECTED "
                  f"({k['assets']} assets, {k['bytes']/1e6:.0f}MB) — untouched")
    if not args.include_releases:
        if del_rels:
            print(f"    {len(del_rels)} orphan release(s) found but --include-releases "
                  f"not set → skipping:")
            for r in del_rels:
                print(f"        {r['tag_name']} ({r['bytes']/1e6:.0f}MB, {r['published_at']})")
        del_rels = []
    else:
        mb = sum(r["bytes"] for r in del_rels) / 1e6
        print(f"    to_delete={len(del_rels)} ({mb:.1f}MB)")

    # ---------------------------------------------------------- بکاپ
    os.makedirs(args.backup_dir, exist_ok=True)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    bpath = os.path.join(args.backup_dir,
                         f"cleanup-{args.repo.replace('/', '_')}-{stamp}.json")
    backup = {
        "generated_at": now.isoformat(),
        "repo": args.repo,
        "mode": "apply" if args.apply else "dry-run",
        "settings": {"days": args.days,
                     "keep_per_workflow": args.keep_per_workflow,
                     "max_delete": args.max_delete,
                     "include_releases": args.include_releases},
        "protected_release_tags": sorted(PROTECTED_RELEASE_TAGS),
        "to_delete": {"runs": del_runs, "artifacts": del_arts,
                      "caches": del_caches, "releases": del_rels},
        "kept": {"runs": keep_runs, "artifacts": keep_arts,
                 "releases": keep_rels},
    }
    with open(bpath, "w", encoding="utf-8") as fh:
        json.dump(backup, fh, indent=2, ensure_ascii=False)
    print(f"\n💾 backup written: {bpath} ({os.path.getsize(bpath)/1024:.0f} KB)")
    print("    (شامل شناسه، شماره، وضعیت، زمان و لینک لاگِ هر موردی که حذف می‌شود)")

    total = len(del_runs) + len(del_arts) + len(del_caches) + len(del_rels)
    if total == 0:
        print("\n✅ nothing to clean.")
        if args.json:
            print(json.dumps({"deleted": 0, "backup": bpath}))
        return 0

    if total > args.max_delete:
        print(f"\n⚠️  {total} items exceed --max-delete={args.max_delete}. "
              f"Trimming to the OLDEST {args.max_delete} runs first.")
        del_runs.sort(key=lambda x: x.get("created_at") or "")
        room = args.max_delete
        del_runs = del_runs[:room]
        room -= len(del_runs)
        del_arts = del_arts[:max(0, room)]
        room -= len(del_arts)
        del_caches = del_caches[:max(0, room)]
        del_rels = del_rels[:max(0, room - len(del_caches))]
        total = len(del_runs) + len(del_arts) + len(del_caches) + len(del_rels)

    if not args.apply:
        print(f"\n🔎 DRY-RUN: would delete {total} item(s) "
              f"({len(del_runs)} runs, {len(del_arts)} artifacts, "
              f"{len(del_caches)} caches, {len(del_rels)} releases).")
        print("    برای اجرای واقعی --apply را اضافه کنید.")
        if args.json:
            print(json.dumps({"would_delete": total, "backup": bpath}))
        return 0

    # ---------------------------------------------------------- حذف
    print(f"\n🗑  deleting {total} item(s)...")
    ok = fail = 0
    for r in del_runs:
        st, _ = req("DELETE", f"/repos/{args.repo}/actions/runs/{r['id']}", token)
        if st in (204, 404, 410):
            ok += 1
        else:
            fail += 1
            print(f"    warn: run {r['id']} -> HTTP {st}")
        if (ok + fail) % 50 == 0:
            print(f"    ...{ok + fail}/{total}", flush=True)
    for a in del_arts:
        st, _ = req("DELETE", f"/repos/{args.repo}/actions/artifacts/{a['id']}", token)
        ok += 1 if st in (204, 404, 410) else 0
        fail += 0 if st in (204, 404, 410) else 1
    for c in del_caches:
        st, _ = req("DELETE", f"/repos/{args.repo}/actions/caches/{c['id']}", token)
        ok += 1 if st in (204, 404, 410) else 0
        fail += 0 if st in (204, 404, 410) else 1
    for r in del_rels:
        st, _ = req("DELETE", f"/repos/{args.repo}/releases/{r['id']}", token)
        ok += 1 if st in (204, 404, 410) else 0
        fail += 0 if st in (204, 404, 410) else 1

    print(f"\n✅ done: deleted={ok} failed={fail}")
    print(f"    backup of everything removed: {bpath}")
    if args.json:
        print(json.dumps({"deleted": ok, "failed": fail, "backup": bpath}))
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

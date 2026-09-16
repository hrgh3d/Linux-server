# RECOVERY — بازگردانی کامل سیستم hrgh3d از روی همین باندل

> این فایل داخل بکاپ تلگرامی است. با آن می‌توانی حتی اگر **کل حساب گیت‌هاب از دست برود**،
> سیستم را دقیقاً به شکل فعلی برگردانی.
> ⚠️ فایل `secrets.env` کنار همین فایل، کلیدهای دسترسی را دارد (Base64). جای امن نگهش دار.
>
> **باندل با هر گزارش ربات به تلگرام می‌آید:** قطع/وصل سیستم (❌/✅)، تغییر آدرس هر داشبورد،
> و کرون روزانه ۰۳:۴۷ UTC. dedup: داخل ۱۵ دقیقه باندل تکراری ارسال نمی‌شود.
> **آخرین باندل در چت = تازه‌ترین نسخهٔ کامل.** اگر سرور موقع بکاپ‌گیری خاموش بوده،
> فایل `SERVER-DATA-UNAVAILABLE.txt` داخلش است و باندل = `bootstrap` + `state.part-*`.
>
> چسباندن بخش‌ها: `cat bk-part-* > final-backup.tar.gz` و `cat state.part-* > state.tar.gz`.

---

## محتویات بکاپ

| فایل | چیست | بحرانی؟ |
|---|---|---|
| `bootstrap/repo.tar.gz` | کل محتوای ریپوی کد (workflowها + اسکریپت‌ها) | ✅ |
| `bootstrap/recovery/secrets.env` | کلید/رمز/توکن‌ها Base64 | ✅ |
| `bootstrap/recovery/RECOVERY.md` | همین فایل | ✅ |
| `state.part-*` | اسنپ‌شات کامل وضعیت سرور (فقط در باندل DR) | ✅ |
| `tailscale-state.tar.gz` | **هویت گره Tailscale + مسیر ماندگار Serve** | ✅ |
| `openclaw.tar.gz` | کانفیگ/سشن/workspace کامل OpenClaw | ✅ |
| `sqlite/openclaw-state.sqlite` | **جدول دستگاه‌های جفت‌شدهٔ OpenClaw** (VACUUM سالم) | ✅ |
| `sqlite/9router-data.sqlite` | دیتابیس 9router (کلیدهای API، کاربران) | ✅ |
| `app-code.tar.gz` | `/opt/9router`, `/root/.hermes`, `/var/www` | ✅ |
| `services.tar.gz` | `/etc/nginx`, `/etc/cron.d`, یونیت‌های systemd (system + user) | ✅ |
| `bin-scripts.tar.gz` | `/usr/local/bin`, `/usr/local/sbin` (همهٔ نگهبان‌ها) | ✅ |
| `home-root.tar.gz` | کل `/root` منهای cacheها | ✅ |
| `info.txt` | نسخه‌ها، سرویس‌های در حال اجرا، MagicDNS، جدول Serve | مرجع |

> 💡 `openclaw/cache`, `openclaw/tmp`, `openclaw/media`, `.npm`, `.cache` عمداً **نیستند** —
> بازساختنی‌اند و ~۵۰ مگابایت حجم بی‌فایده اضافه می‌کردند (و قبلاً باعث می‌شدند کل `/root`
> از بودجه رد شود و اصلاً بکاپ نگیرد).

---

## مراحل بازگردانی

### ۱) حساب و ریپوها
1. حساب گیت‌هاب جدید + دو ریپو: کد (`Linux-server`، **public** تا دقایق Actions نامحدود بماند) و state (`Linux-server-state`، **private**).
2. محتوای ریپو را از بکاپ برگردان:
   ```bash
   tar -xzf repo.tar.gz
   git init && git add -A && git commit -m "restore from backup"
   git branch -M main && git remote add origin https://github.com/<USER>/<REPO>.git
   git push -u origin main
   ```
   - اگر نام کاربر/ریپو عوض شد، در `.github/workflows/*.yml` مقادیر `REPO`/`STATE_REPO` و `TARGET_IP` را جایگزین کن.

### ۲) اسنپ‌شات state
3. بخش‌ها را بچسبان: `cat state.part-* > state.tar.gz`
4. در ریپوی state یک Release با tag **`state`** بساز و `state.tar.gz` را آپلود کن.

### ۳) سکرت‌ها
5. PAT جدید با `contents:write` + `actions:write` روی هر دو ریپو بساز.
6. سکرت‌های ریپو از `secrets.env` (مقادیر Base64 → `base64 -d`):
   `HAMID_PASSWORD, PERSIST_TOKEN, STATE_TOKEN, SUCCESSOR_TOKEN, TAILSCALE_AUTH_KEY,
   TAILSCALE_API_TOKEN, TAILSCALE_FIXED_IP, TELEGRAM_BOT_TOKEN, REPORT_BOT_TOKEN,
   NOTIFY_CHAT_ID, DASHBOARD_PASSWORD`
   - `TAILSCALE_AUTH_KEY` اگر باطل شد، از پنل Tailscale جدید بساز.

### ۴) بالا آوردن
7. `main.yml` → Run workflow. `provision.sh` خودش همه‌چیز را برمی‌گرداند: Node 24 ایزوله، OpenClaw، Hermes، 9router، nginx و همهٔ نگهبان‌ها.
8. چک: `watchdog.yml` با `test_alert=true`، بعد `send-backup.yml`، بعد `ops-server-check.yml`.

---

## ۵) بازگردانی دستی روی یک سرور خالی (اگر state را نداشتی)

اگر فقط همین باندل تلگرامی را داری و اسنپ‌شات state نیست، ترتیب زیر سیستم را برمی‌گرداند:

```bash
# 0) پیش‌نیاز
apt-get update && apt-get install -y curl jq sqlite3 nginx tar

# 1) هویت Tailscale — اول از همه، وگرنه آدرس MagicDNS عوض می‌شود
systemctl stop tailscaled 2>/dev/null
tar -xzf tailscale-state.tar.gz -C /        # /var/lib/tailscale را برمی‌گرداند
curl -fsSL https://tailscale.com/install.sh | sh
systemctl start tailscaled
tailscale status        # باید همان نام گره قبلی بیاید: linux-server-vps

# 2) داده‌ها
tar -xzf home-root.tar.gz     -C /
tar -xzf openclaw.tar.gz      -C /
tar -xzf app-code.tar.gz      -C /
tar -xzf services.tar.gz      -C /
tar -xzf bin-scripts.tar.gz   -C /

# 3) دیتابیس‌های سالم را روی نسخه‌های احتمالاً torn بنشان
mkdir -p /root/.openclaw/state /root/.9router/db
cp sqlite/openclaw-state.sqlite /root/.openclaw/state/openclaw.sqlite
cp sqlite/9router-data.sqlite   /root/.9router/db/data.sqlite

# 4) Node 24 ایزوله برای OpenClaw (Node سیستمی باید روی 22 بماند!)
mkdir -p /opt/openclaw-node && cd /tmp
curl -fsSLo n.tar.xz https://nodejs.org/dist/v24.8.0/node-v24.8.0-linux-x64.tar.xz
tar -xJf n.tar.xz --strip-components=1 -C /opt/openclaw-node
/opt/openclaw-node/bin/npm install -g --prefix /opt/openclaw-app openclaw@latest
cat >/usr/local/bin/openclaw <<'W'
#!/bin/sh
export OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/root/.openclaw}"
exec /opt/openclaw-node/bin/node /opt/openclaw-app/lib/node_modules/openclaw/openclaw.mjs "$@"
W
chmod +x /usr/local/bin/openclaw

# 5) سرویس‌ها
systemctl daemon-reload
systemctl enable --now openclaw-gateway 9router nginx
systemctl enable --now openclaw-serve-guard.timer hermes-gateway-guard.timer
loginctl enable-linger root
export XDG_RUNTIME_DIR=/run/user/0
systemctl --user enable --now hermes-gateway.service

# 6) مسیر HTTPS داشبورد (در /var/lib/tailscale ذخیره می‌شود)
DN=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
tailscale cert "$DN"
tailscale serve --bg --https=443 http://127.0.0.1:18789

# 7) تأیید
curl -s -o /dev/null -w 'dashboard=%{http_code}\n' "https://$DN/"
openclaw devices list         # گوشی‌های جفت‌شده باید همان‌ها باشند
systemctl is-active openclaw-gateway 9router nginx tailscaled
```

### نکات حیاتی این مرحله
- **ترتیب مهم است:** `/var/lib/tailscale` باید *قبل از* استارت tailscaled برگردد، وگرنه گره با هویت جدید ثبت می‌شود، آدرس MagicDNS عوض می‌شود و همهٔ setup codeها و لینک‌های داشبورد باطل می‌شوند.
- **Node سیستمی را به ۲۴ ارتقا نده.** 9router به `better-sqlite3` کامپایل‌شده برای ABI نود ۲۲ وابسته است. OpenClaw رانتایم جدای خودش را در `/opt/openclaw-node` دارد.
- `gateway.tailscale.mode` باید **`off`** بماند و Serve دستی ساخته شود (بند ۶). حالت داخلی OpenClaw claim را فقط in-process نگه می‌دارد و بعد از هر ری‌استارت tailscaled داشبورد می‌میرد.
- اگر داشبورد `proxy_attribution_required` داد، یعنی `gateway.trustedProxies` تنظیم نیست:
  ```bash
  openclaw config set --json gateway.trustedProxies '["127.0.0.1/32","::1/128"]'
  openclaw config set gateway.auth.allowTailscale true
  systemctl restart openclaw-gateway
  ```
- اگر اپ موبایل `http101 403 forbidden` داد، دستگاه در صف Pending است:
  `openclaw devices list` سپس `openclaw devices approve <requestId>`.

---

## نکات عمومی
- ریپوی کد باید **public** باشد ⇒ دقیقه‌های Actions رایگان و نامحدود.
- ربات گزارش از ربات Hermes جداست؛ اگر توکنی عوض شد، سکرت را در **هر دو ریپو** به‌روز کن.
- SSH: `ssh root@100.70.83.2` با رمز (`HAMID_PASSWORD`). مرز امنیتی = عضویت در tailnet.
- تست نهایی: یک بار `send-backup.yml` دستی + یک بار `watchdog.yml` با `test_alert`.

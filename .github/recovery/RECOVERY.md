# RECOVERY — بازگردانی کامل سیستم hrgh3d روی حساب گیت‌هاب جدید

> این فایل داخل بکاپ تلگرامی است. با آن می‌توانی حتی اگر **کل حساب گیت‌هاب قبلی از دست برود**،
> سرور را دوباره بالا بیاوری.
> ⚠️ فایل `secrets.env` کنار همین فایل، کلیدهای دسترسی را دارد (Base64). جای امن نگهش دار.

---

## محتویات بکاپ
| فایل | چیست |
|---|---|
| `bootstrap/repo.tar.gz` | کل محتوای ریپوی کد (workflowها + اسکریپت‌ها) در لحظهٔ بکاپ |
| `bootstrap/recovery/secrets.env` | کلید/رمز/توکن‌ها Base64 + راهنمای decode |
| `bootstrap/recovery/RECOVERY.md` | همین فایل |
| `state.part-*` | اسنپ‌شات کامل وضعیت سرور (چند بخش؛ همان ورودی `main.yml`) |
| `system-backup` (بکاپ روزانه) | کانفیگ‌ها، دامپ MySQL (اگر بود)، `info.txt` |

---

## مراحل بازگردانی

### ۱) حساب و ریپوها
1. حساب گیت‌هاب جدید + دو ریپو: کد (`Linux-server`) و state (`Linux-server-state`).
2. محتوای ریپو را از بکاپ برگردان:
   ```bash
   tar -xzf repo.tar.gz
   git init && git add -A && git commit -m "restore from backup"
   git branch -M main && git remote add origin https://github.com/<USER>/<REPO>.git
   git push -u origin main
   ```
   - اگر نام کاربر/ریپو عوض شد، در `.github/workflows/*.yml` مقادیر `REPO`/`STATE_REPO` و
     `TARGET_IP` را با مقادیر جدید جایگزین کن.

### ۲) اسنپ‌شات state
3. بخش‌ها را بچسبان:
   ```bash
   cat state.part-* > state.tar.gz         # ویندوز: copy /b state.part-aa+state.part-ab+... state.tar.gz
   ```
4. در ریپوی state یک Release با tag **`state`** بساز و `state.tar.gz` را آپلود کن (نام asset آزاد).

### ۳) سکرت‌ها
5. PAT جدید با `contents:write` + `actions:write` روی هر دو ریپو بساز.
6. سکرت‌های ریپو از `secrets.env` (مقادیر Base64 → `base64 -d`):
   `HAMID_PASSWORD, PERSIST_TOKEN, SUCCESSOR_TOKEN, TAILSCALE_AUTH_KEY, TAILSCALE_API_TOKEN,
   TAILSCALE_FIXED_IP, TELEGRAM_BOT_TOKEN, NOTIFY_CHAT_ID, DASHBOARD_PASSWORD`
   - توکن‌های منقضی‌شده را با توکن تازهٔ حساب جدید عوض کن.
   - `TAILSCALE_AUTH_KEY` اگر باطل شد، از پنل Tailscale جدید بساز.

### ۴) بالا آوردن
7. `main.yml` → Run workflow. سرور با همان نام/هویت tailnet برمی‌گردد.
8. چک‌ها: `watchdog.yml` با `test_alert=true` → پیام «🧪 تستی» بیاید؛
   `send-backup.yml` → بکاپ به تلگرام برسد؛ `ops-server-check.yml` → دیسک/سرویس‌ها را نشان دهد.

### ۵) اگر اسنپ‌شات را نداشتی
بکاپ روزانه (`system-backup`) کانفیگ‌ها و دامپ دیتابیس‌ها را دارد؛ روی سرور تازه باز کن و
سرویس‌های مورد نیاز را برگردان. (این سرور سرویس دائمی خاصی ندارد؛ عمدتاً چرخهٔ زنده‌ماندن مهم است.)

---

## نکات
- این سیستم روی همان tailnet سیستم اول است؛ **دو سرور را قاطی نکن** (هر کدام جفت ریپو/state خودش را دارد).
- هشدارها به همان ربات گزارش می‌روند؛ اگر توکن ربات عوض شد، سکرت را در **هر دو ریپو** به‌روز کن.
- تست نهایی: یک بار `send-backup.yml` دستی + یک بار `watchdog.yml` با `test_alert`.

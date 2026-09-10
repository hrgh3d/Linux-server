# Linux-server

سرور Ubuntu پایدار روی GitHub Actions: **داده ماندگار، هویت Tailscale ثابت (IP ثابت)، SSH با کلید، داشبورد رمزدار**. معماری فعلی: **v6.10**.

## چطور کار می‌کند
- هر Run یک runner موقت است (~۵.۸ ساعت عمر). ۲۰ دقیقه قبل از پایان، خودِ Run، Run جانشین را dispatch می‌کند (زنجیره؛ قطعی هر دست‌به‌دست‌سازی = فقط چند دقیقه بوت).
- تیک ساعته کرون فقط **backstop** است (اگر زنجیره پاره شود).
- در ابتدای هر بوت: دانلود state از ریپوی خصوصی `Linux-server-state` → بازنصب پکیج‌های کاربر (کاتالوگ نسخه‌دقیق) → اعمال داده/تنظیمات → تزریق secretها → استارت سرویس‌ها.
- هر ۵ دقیقه state در صورت تغییر ذخیره می‌شود (rolling؛ ۲ نسخه‌ی آخر نگه داشته می‌شود برای rollback).

## چه چیزهایی ماندگار است
- `/root` ،`/home/Hamid` ،`/opt` ،`/srv` ،`/etc` ،`/usr/local/bin|sbin` ،`/var/www` ،`/var/lib` ،`/var/opt` ،cron
- پکیج‌های apt/npm/pip کاربر با **نسخه دقیق** (کاتالوگ در `installed.json`)
- هویت Tailscale (`/var/lib/tailscale`) → **IP ثابت `100.70.83.2`** (node غیر-ephemeral + pin API به‌عنوان پشت‌بند)
- کلیدهای Host SSH (فingerprint ثابت)
- دیتابیس‌های SQLite به‌صورت snapshot سازگار (online backup)

## اتصال SSH
```bash
# کلید (پیشنهادی؛ فایل private key در اختیار شماست — hamid@windows-powershell)
ssh -i ~/.ssh/linux-server root@100.70.83.2
# یا از ویندوز با PowerShell:
#   ssh -i $env:USERPROFILE\.ssh\linux-server root@100.70.83.2
# فیلتر کلیدهای مجاز: فقط root و Hamid (AllowUsers)
```
فingerprint کلید host سرور (برای تأیید هویت در اتصال اول):
`SHA256:kdsQ9FkMfUVWwaLckY3/yb2vEq0faMwUFtgID8eEl4w`

## داشبورد Hermes (با رمز)
آدرس تونل هر بوت به تلگرام ارسال می‌شود (trycloudflare.com). داشبورد پشت **Basic Auth** است:
- کاربر: `hamid` — رمز: secret `DASHBOARD_PASSWORD` (در اختیار شما)
- زنجیره: tunnel → nginx :9119 (auth) → dashboard :9120 (loopback فقط)

## امنیتی (v6.10)
- **Secretها وارد آرشیو state نمی‌شوند**: `TELEGRAM_BOT_TOKEN` قبل از archive خالی می‌شود و در هر بوت از GitHub Secrets تزریق می‌شود (`secrets_inject.sh`).
- آرشیو state فقط **hash یک‌طرفه** رمز داشبورد را می‌بیند (htpasswd SHA-512؛ خود رمز فقط در GitHub Secrets است).
- Tailscale بدون `--accept-routes` (ساب‌نت داخلی runner به tailnet route نمی‌شود).
- dispatch زنجیره با `GITHUB_TOKEN` خودِ ران (توکن لو‌رفته لازم نیست).
- ریپوی state **private** است؛ کلیدهای Tailscale/SSH و داده‌ها فقط در آن‌جا.
- هشدار انقضای کلیدها در هر بوت (`tailscale_expiry_check.py` + `key-dates.json`).

## ⚠️ مصرف دقیقه Actions (مهم)
- این ریپو **public** و اکانت **Free** است → سقف رایگان **۲۰۰۰ دقیقه/ماه** (private روی Free = ۰ دقیقه).
- مصرف فعلی ≈ **۱۴۵۰ دقیقه/روز** (~۴۴٬۰۰۰/ماه) — یعنی سقف ماهانه در ~۱.۴ روز پر می‌شود؛ بعد از پر شدن، Runهای **جدید** (شامل dispatch جانشین!) تا ریست ماهانه رد می‌شوند و سرور می‌ایستد.
- پایش: Settings → Billing and plans → Usage → Actions. گزینه‌های پایدار: پلن Team (۵۰هزار دقیقه/ماه) یا مهاجرت به VPS.

## ساختار ریپو
```
.github/
  workflows/main.yml          # کل چرخه بوت + keepalive + زنجیره جانشین
  scripts/
    save.sh / restore.sh      # اسنپ‌شات و بازیابی (rolling 2 نسخه)
    state_sync.py             # آپلود/دانلود اتمیک + verify + keep-2
    payload.py                # فیلتر مسیرها (چه چیزی بکاپ می‌شود)
    sqlite_stage.py           # snapshot سازگار دیتابیس‌های زنده
    tailscale-setup.sh        # اتصال/بازاتصال Tailscale (bounded)
    tailscale_cleanup.py      # حذف نودهای یتیم هم‌نام آفلاین + rename
    tailscale_expiry_check.py # هشدار انقضای کلیدها
    ssh_configure.sh          # sshd + merge کلید ثابت (بدون حذف کلیدهای مجاز)
    secrets_inject.sh         # تزریق secretهای خارج‌شده از آرشیو (v6.10)
    dashboard_guard.sh        # nginx basic-auth جلوی داشبورد (v6.10)
    provision.sh              # نصب خودکار 9router/Hermes/cloudflared در صورت نبود
    start-services.sh         # استارت سرویس‌های ماندگار
    server_report.sh          # گزارش بوت (Step Summary)
    notify.sh                 # اعلان failure (webhook اختیاری + marker)
  config/sshd_config          # کانفیگ ثابت sshd
  ssh/id_ed25519.pub          # کلید(های) ثابت SSH
  key-dates.json              # تاریخ انقضای توکن‌ها (چک هر بوت)
README.md / OPS.md            # این فایل + راهنمای عملیاتی
```

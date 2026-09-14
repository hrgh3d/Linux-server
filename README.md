# Linux-server

سرور Ubuntu پایدار روی GitHub Actions: **داده ماندگار، هویت Tailscale ثابت (IP ثابت)، SSH ساده با رمز (کلید اختیاری)، داشبورد رمزدار**. معماری فعلی: **v6.13**.

## چطور کار می‌کند
- هر Run یک runner موقت است (~۵.۸ ساعت عمر). ۲۰ دقیقه قبل از پایان، خودِ Run، Run جانشین را dispatch می‌کند (زنجیره؛ قطعی هر دست‌به‌دست‌سازی = فقط چند دقیقه بوت).
- تیک ساعته کرون فقط **backstop** است (اگر زنجیره پاره شود).
- در ابتدای هر بوت: دانلود state از ریپوی خصوصی `Linux-server-state` → بازنصب پکیج‌های کاربر (کاتالوگ نسخه‌دقیق) → اعمال داده/تنظیمات → تزریق secretها → استارت سرویس‌ها.
- هر ۵ دقیقه state در صورت تغییر ذخیره می‌شود (rolling؛ ۲ نسخه‌ی آخر نگه داشته می‌شود برای rollback) + یک `heartbeat` سبک روی همان Release تا watchdog در سرورِ idle هشدار کاذب «state کهنه» ندهد (v6.13).

## چه چیزهایی ماندگار است
- `/root` ،`/home/Hamid` ،`/opt` ،`/srv` ،`/etc` ،`/usr/local/bin|sbin` ،`/var/www` ،`/var/lib` ،`/var/opt` ،cron
- پکیج‌های apt/npm/pip کاربر با **نسخه دقیق** (کاتالوگ در `installed.json`)
- هویت Tailscale (`/var/lib/tailscale`) → **IP ثابت `100.70.83.2`** (node غیر-ephemeral + pin API به‌عنوان پشت‌بند)
- کلیدهای Host SSH (فingerprint ثابت)
- دیتابیس‌های SQLite به‌صورت snapshot سازگار (online backup)

## اتصال SSH
```bash
# اتصال ساده (رمز) — روش اصلی:
ssh root@100.70.83.2
# رمز = secret HAMID_PASSWORD (برای کاربر Hamid هم همان رمز است)

# کلید (اختیاری؛ فایل private key در اختیار شماست — hamid@windows-powershell):
ssh -i ~/.ssh/linux-server root@100.70.83.2
# فیلتر کاربران مجاز: فقط root و Hamid (AllowUsers)
```
- IP فقط از داخل شبکه Tailscale در دسترس است؛ رمز بدون عضویت در tailnet به کار نمی‌آید.
- fingerprint کلید host (تأیید در اتصال اول): `SHA256:6P2g9TXEf9e4kPQC7KslkPg+kbQVyP12mVA9pSdfaoc` (ED25519) — کلیدهای host پایدارند (در state ذخیره می‌شوند).
- اگر خطای `REMOTE HOST IDENTIFICATION HAS CHANGED` دیدید (ورودی قدیمی از سرور قبل از بازسازی)، یک‌بار: `ssh-keygen -R 100.70.83.2`

## داشبورد Hermes (با رمز)
آدرس تونل هر بوت به تلگرام ارسال می‌شود (trycloudflare.com). داشبورد پشت **Basic Auth** است:
- کاربر: `hamid` — رمز: secret `DASHBOARD_PASSWORD` (در اختیار شما)
- زنجیره: tunnel → nginx :9119 (auth) → dashboard :9120 (loopback فقط)

## امنیتی (v6.13)
- **Secretها وارد آرشیو state نمی‌شوند**: `TELEGRAM_BOT_TOKEN` و `REPORT_BOT_TOKEN` قبل از archive خالی می‌شوند و در هر بوت از GitHub Secrets تزریق می‌شود (`secrets_inject.sh`).
- **دو ربات تلگرام جدا**: ربات Hermes Gateway (`TELEGRAM_BOT_TOKEN`) فقط برای خودِ Hermes؛ ربات گزارش سیستم (`REPORT_BOT_TOKEN`) برای watchdog/اعلان‌ها/آدرس تونل داشبورد.
- آرشیو state فقط **hash یک‌طرفه** رمز داشبورد را می‌بیند (htpasswd SHA-512؛ خود رمز فقط در GitHub Secrets است).
- Tailscale بدون `--accept-routes` (ساب‌نت داخلی runner به tailnet route نمی‌شود).
- dispatch زنجیره با `GITHUB_TOKEN` خودِ ران (توکن لو‌رفته لازم نیست).
- ریپوی state **private** است؛ کلیدهای Tailscale/SSH و داده‌ها فقط در آن‌جا.
- هشدار انقضای کلیدها در هر بوت (`tailscale_expiry_check.py` + `key-dates.json`).

## ⏱️ دقیقه‌های Actions
- ریپو **public** است → دقیقه‌های GitHub Actions روی runnerهای استاندارد **رایگان و نامحدود** هستند؛ سقف ماهانه دقیقه فقط برای ریپوهای **private** اعمال می‌شود. تجربه عملی این پروژه: اجرای بی‌وقفه ۲۴/۷ بدون رد شدن حتی یک Run.
- تنها سقف فنی، عمر هر Run (~۶ ساعت) است که معماری زنجیره جانشین آن را پوشش می‌دهد (Run بعدی قبل از پایان قبلی dispatch می‌شود).
- اگر روزی سیاست GitHub تغییر دهد، زنجیره با اولین تیک کرون (هر ۱۰ دقیقه) پس از رفع محدودیت خودکار از سر می‌گیرد و state از ریپوی خصوصی بازیابی می‌شود — بدون از دست رفتن داده.

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

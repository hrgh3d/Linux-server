# Linux-server

سرور Ubuntu پایدار روی GitHub Actions: **داده ماندگار، هویت Tailscale ثابت (IP ثابت)، SSH ساده با رمز (کلید اختیاری)، داشبورد رمزدار**. معماری فعلی: **v6.22** (آخرین به‌روزرسانی: ۲۰۲۶-۰۹-۱۶).

> این مخزن **عمومی** است تا دقایق GitHub Actions نامحدود باشد. هیچ رازی داخل آن نیست — همه از GitHub Secrets تزریق می‌شوند.

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

## داشبوردها (Hermes + 9Router) — همیشه در حال اجرا
هر دو به‌عنوان سرویس systemd با `Restart=always` اجرا می‌شوند؛ تونل‌ها و نگهبان آدرس‌ها هم خودکار زنده نگه داشته می‌شوند.

| داشبورد | آدرس روی سرور | آدرس عمومی |
|---|---|---|
| **Hermes Dashboard** | `http://localhost:9119` | تونل trycloudflare — با هر تغییر، ربات گزارش: `Hermes Dashboard : <آدرس جدید>` |
| **9Router Terminal** | `http://localhost:20128/dashboard` | تونل trycloudflare — با هر تغییر، ربات گزارش: `9Router Terminal : <آدرس جدید>` |

- **ورود Hermes**: گیت nginx با کاربر `hamid` + رمز secret `DASHBOARD_PASSWORD`.
- **ورود 9Router** (از v6.18): گیت nginx **حذف شده** — فقط رمز خودِ پنل، برابر با secret `HAMID_PASSWORD`. از v6.20 این رمز در هر بوت تثبیت می‌شود و بین رانرها به پیش‌فرض برنمی‌گردد.
- زنجیره: tunnel → nginx (برای Hermes با auth، برای 9Router بدون auth) → بک‌اند (`9120` برای Hermes، `20128` برای 9Router — فقط loopback).
- دستور `hermes dashboard` روی سرور دیگر ارور `BACKEND_PORT_IN_USE` نمی‌دهد — چون سرویس در حال اجراست، همان آدرس‌ها را چاپ می‌کند (alias به `hermes-ui`).

## ربات گزارش (Report Bot) — فقط ۳ نوع پیام، فقط هنگام تغییر واقعی
- `سیستم hrgh3d قطع شد ❌` / `سیستم hrgh3d وصل شد ✅` — پایشگر سریع (`watchdog-fast`، مقیم، هر **۶۰ ثانیه**) در نبودِ رانر فوراً رانر جدید روشن می‌کند: تشخیص قطعی ≤۱ دقیقه و وصل کامل ≈ **۳-۵ دقیقه**. کرون‌های ۱۰ دقیقه‌ای فقط پشت‌بندِ خودِ پایشگرند.
- جانشینی‌های عادی ۶ ساعته پیام ندارند (فقط قطعی/بازگشت واقعی).
- `Hermes Dashboard : <آدرس>` / `9Router Terminal : <آدرس>` — وقتی آدرس تونل به هر دلیلی عوض شود.


## تغییرات مهم اخیر (v6.17 → v6.22)
- **v6.22** — تشخیص قابل‌اتکای نصب خراب Hermes: تابع اعتبارسنجی حالا واقعاً مفسر venv را اجرا و وجود درخت کد را بررسی می‌کند (قبلاً نصبِ کاملاً پاک‌شده «سالم» تشخیص داده می‌شد).
- **v6.21** — رفع گم‌شدن اعلان آدرس تونل: `tg_report` در شکست `return 1` می‌دهد (قبلاً `0` برمی‌گرداند و آدرس اشتباهاً «اعلام‌شده» ثبت می‌شد) + کش اعتبارنامه‌ی ربات برای پنجره‌ی خالی‌سازی `save.sh`.
- **v6.20** — تثبیت دائمی رمز پنل 9router (`router_password_guard.sh`) + `wal_checkpoint` روی همه‌ی دیتابیس‌های SQLite پیش از آرشیو (رفع نشتی WAL که تغییرات را از بکاپ حذف می‌کرد).
- **v6.19** — پشتیبانی `ops-exec` از placeholder `__HAMID_PASSWORD__` (راز فقط روی رانر جایگزین می‌شود، نه در ورودی/لاگ عمومی).
- **v6.18** — حذف گیت Basic-Auth از داشبورد 9router (گیت Hermes دست‌نخورده).
- **v6.17** — ارسال باندل کامل بازیابی با هر گزارش.

## امنیتی (v6.13 → v6.21)
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
  workflows/watchdog-fast.yml # پایشگر زنده بودن — هر ۶۰ ثانیه، زنجیره‌ی خودجانشین
  workflows/watchdog.yml (+b) # کرون ۱۰ دقیقه — پشت‌بندِ پایشگر سریع
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
    provision.sh              # نصب خودکار 9router/Hermes/cloudflared در صورت نبود (v6.22: تشخیص نصب خراب)
    start-services.sh         # استارت سرویس‌های ماندگار
    router_password_guard.sh  # تثبیت رمز پنل 9router در هر بوت (v6.20)
    tunnel-watch.sh           # پایش آدرس تونل‌ها + اعلام از راه ربات گزارش (v6.21)
    send_backup.sh            # ارسال باندل کامل بازیابی به تلگرام (v6.17)
    server_report.sh          # گزارش بوت (Step Summary)
    notify.sh                 # اعلان failure (webhook اختیاری + marker)
  config/sshd_config          # کانفیگ ثابت sshd
  ssh/id_ed25519.pub          # کلید(های) ثابت SSH
  key-dates.json              # تاریخ انقضای توکن‌ها (چک هر بوت)
README.md / OPS.md            # این فایل + راهنمای عملیاتی
```

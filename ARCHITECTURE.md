# معماری سرور پایدار — v4 (Persistent Server Architecture)

## نمای کلی

Runner های GitHub Actions ذاتاً Ephemeral هستند و بعد از سقف زمانی (~۶ ساعت) یا Cancel دستی نابود می‌شوند. هدف معماری v4: **Runner همیشه موقت بماند، ولی تمام اطلاعات و State کاربر مستقل از آن، دائمی و خودبازیابی باشد.**

```
[ Run جدید (schedule / workflow_dispatch) ]
      │
      ▼
[ Base system + کاربر Hamid (sudo بدون رمز، root بدون پسورد) ]
      │
      ▼
[ Restore: دانلود تک-اسنپ‌شات state از Linux-server-state ]
      │   ├── بازنصب پکیج‌های کاربر (user_packages.list)
      │   ├── بازگردانی /root , /home/Hamid , /etc , /opt , /srv , /usr/local , /var/www , cron
      │   ├── بازگردانی هویت Tailscale (/var/lib/tailscale)
      │   └── بازگردانی کلیدهای Host SSH
      ▼
[ SSH: کلید عمومی ثابت مخزن + کلیدهای Host پایدار ]
      │
      ▼
[ Tailscale: reconnect با همان Node Key → IP قبلی ثابت (+ pin اختیاری) ]
      │
      ▼
[ سرور فعال (پیش‌فرض ~۵.۵ ساعت) ]
      │  └─ هر ۵ دقیقه: همگام‌سازی state (فقط در صورت تغییر محتوا)
      ▼   (Cancel / Timeout / پایان عمر)
[ ذخیره‌ی نهایی state ] ──► [ Run بعدی همان وضعیت را بازمی‌گرداند ]
```

## اجزاء

### ۱) لایه‌ی ذخیره‌سازی (State Store) — مخزن `Linux-server-state`
- داده‌ها روی **Release با تگ `state`** نگهداری می‌شوند.
- `state_sync.py`:
  - آپلود همیشه با **نام یکتا** (`state-<UTC>-<sha8>.tar.gz`) انجام می‌شود؛ این کار خطای `422 already_exists` (برخورد نام Asset پس از حذف) را که در نسخه‌های قبل باعث ازکارافتادن ذخیره می‌شد، ریشه‌کن می‌کند.
  - اگر **sha256** محتوا با آخرین Asset ذخیره‌شده یکی باشد، آپلود **رد می‌شود** → Cancel/Re-run بکاپ اضافی تولید نمی‌کند.
  - پاک‌سازی Assetهای قدیمی فقط **بعد از موفقیت آپلود جدید** انجام می‌شود → در هر لحظه دقیقاً یک نسخه موجود است و هیچ‌وقت پنجره‌ی بدون-state پیش نمی‌آید.
- `restore.sh` جدیدترین Asset را می‌خواند (نام ثابت ندارد؛ بر اساس زمان).

### ۲) ماندگاری فایل‌ها و `/root`
- مسیرها در `.github/scripts/persist.list` تعریف شده‌اند.
- `save.sh` با `rsync` مسیرها را به استیجینگ می‌برد (با فیلتر فایل‌های گذرا: `.cache`, history, `hostedtoolcache`, …) و با `sudo tar` آرشیو می‌سازد تا **مالکیت واقعی** فایل‌ها حفظ شود.
- `restore.sh` با `sudo tar` استخراج و با `rsync` بازمی‌گرداند؛ سپس مالکیت/مجوز مسیرهای حیاتی (root, home/Hamid, tailscale, ssh) نرمال می‌شود.
- نشانگرهای ماندگاری `/home/Hamid/persist-marker.txt` و `/root/persist-marker.txt` در هر Run جدید به‌روزرسانی می‌شوند و در گزارش Boot نمایش داده می‌شوند.

### ۳) پکیج‌ها / بازسازی محیط
- `packages.list` (کل وضعیت dpkg)، `manual_packages.list` و `user_packages.list` (تفاضل با image پایه) ذخیره می‌شوند.
- در Restore فقط `user_packages.list` دوباره نصب می‌شود (سریع و متمرکز بر نرم‌افزارهای کاربر).

### ۴) SSH ثابت
- کلید عمومی دائمی: `.github/ssh/id_ed25519.pub` → در `authorized_keys` کاربر `Hamid` و `root` **اضافه** می‌شود (بدون حذف کلیدهای مجاز قبلی).
- کلیدهای Host (`/etc/ssh/ssh_host_*`) جدا از `/etc` تضمین و در State ذخیره می‌شوند → fingerprint سرور بعد از اولین Boot تغییر نمی‌کند.
- `sshd_config` استاندارد از `.github/config/sshd_config` اعمال می‌شود.

### ۵) Tailscale پایدار
- `tailscale-setup.sh`:
  1. اگر state بازیابی شده باشد، بدون Auth Key با **همان Node Key** reconnect می‌کند (IP و Hostname قبلی حفظ می‌شود).
  2. در نبود هویت، با `TAILSCALE_AUTH_KEY` احراز می‌شود.
  3. اگر `TAILSCALE_FIXED_IP` تعریف شده و IP فعلی متفاوت باشد، با Tailscale API روی همان IP تثبیت می‌شود.
  4. `tailscale_cleanup.py` فقط Nodeهای **آفلاینِ هم‌خانواده‌ی غیرخودی** را حذف و نام دقیق hostname را حفظ می‌کند (Node فعال/آنلاین هرگز حذف نمی‌شود).

### ۶) Cancel / Re-run بدون بکاپ اضافی
- `concurrency.group` با `cancel-in-progress: false`: Run جدید در صف می‌ماند تا ذخیره‌ی Run قبلی تمام شود.
- ذخیره‌ی نهایی با `if: always()` (حتی بعد از Cancel) اجرا می‌شود.
- به دلیل مقایسه‌ی sha256، اجرای مجدد یا Cancel بدون تغییر داده → هیچ Asset جدیدی ساخته نمی‌شود.

### ۷) مدیریت بدون رمز
- `root`: `passwd -d root` (ورود فقط با کلید از طریق `PermitRootLogin prohibit-password`).
- `Hamid`: عضو sudo با `NOPASSWD:ALL` → `sudo su` بدون درخواست Password.

## جریان داده در هر چرخه
```
boot ──> restore ──> probe(اختیاری) ──> ssh ──> tailscale ──> record ──> keepalive+autosync ──> final save
                                                                                                  │
                                                    (در حالت طبیعی: بعد از LIFETIME_MIN دقیقه)
```

## نکات عملیاتی
- Run دستی با `probe=true` برای راستی‌آزمایی ماندگاری (فایل در `/root`,`/home/Hamid`,`/opt` + پکیج `htop`).
- Run دستی با `lifetime_min` کوچک (مثلاً ۵) برای تست چرخه‌ی Destroy/Rebuild طبیعی بدون انتظار ۶ ساعته.
- گزارش هر Boot شامل markerها، IP تیل‌اسکیل، و fingerprint کلیدهای Host است و در Step Summary قابل مشاهده است.

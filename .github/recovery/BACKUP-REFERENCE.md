# مرجع backup و پایداری Hermes

## دو مسیر مستقل

### ۱. state عمومی

`save.sh` و `restore.sh` داده‌های عملیاتی گسترده‌تر، واحدهای سرویس، تنظیمات و
vault پایدار را مدیریت می‌کنند. stream عمومی فقط artifactهای `state-*` را
مدیریت می‌کند و مسیر بازیابی بحران است.

### ۲. checkpoint سریع Hermes

`hermes_continuity.py` و `hermes_continuity.sh` مسیر canonical برای handoff
Hermes هستند. این checkpoint هر ۶۰ ثانیه، در ابتدای runner و در handoff نهایی
اجرا می‌شود. در نتیجه فاصلهٔ بین یک تغییر واقعی Hermes و backup تأییدشده، حداکثر
تقریباً یک دقیقه است؛ handoff نهایی نیز پس از متوقف شدن writerها انجام می‌شود.

checkpoint سریع تمام فایل‌های پایدار و غیرموقت زیر `/root/.hermes` را خودکار
دارد؛ از جمله:

- conversation/session، databaseهای SQLite، memory و routing Telegram؛
- `SOUL.md`، config، skillهای ساخته‌شده یا تغییرکرده و هر profile جدید؛
- فایل‌های Bot Mode، bindingهای topic/bot، cron و stateهای agent که Hermes در
  آینده زیر home خود بسازد؛
- state/config/credentialهای Composio در ریشه‌های محدود
  `/root/.composio`،`/root/.config/composio` و
  `/root/.local/share/composio`.

Composio executable، adapter، installer، cache و log checkpoint نمی‌شوند؛ این‌ها
قابل نصب مجددند و گنجاندنشان checkpoint یک‌دقیقه‌ای را صدها مگابایت بزرگ می‌کند.
اما هر فایل state تازه‌ای که در ریشه‌های مجاز Composio ساخته شود، بدون نیاز به
تغییر allow-list، وارد checkpoint می‌شود.

## امنیت و موارد عمداً خارج از checkpoint

- `.env` اصلی Hermes و نسخه‌های قدیمی top-level آن وارد archive نمی‌شوند؛ مسیر
  نگهداری آن‌ها vault پایدار و GitHub Secrets است.
- cache، log، socket، pid/lock، venv، `node_modules`، binary و backupهای محلی
  وارد checkpoint نمی‌شوند.
- credentialهای profile یا Composio که ابزار برای ادامهٔ همان اتصال نیاز دارد
  ممکن است در archive سریع باشند، اما archive فقط به **مخزن state خصوصی**
  GitHub upload می‌شود، permission فایل محلی `0600` است و محتوا/secret هرگز در
  log چاپ نمی‌شود. هیچ secret به repository عمومی source وارد نمی‌شود.

## اعتبارسنجی، restore و حذف‌ها

هر archive manifest، SHA-256، نتیجهٔ `SQLite integrity_check` و شمارش
session/message دارد. قبل از هر تغییر state زنده، digest و databaseها کامل
اعتبارسنجی می‌شوند.

restore schema فعلی یک snapshot دقیق از stateهای تحت policy است: ایجاد، تغییر و
حذف skill/profile/bot/config به runner بعدی منتقل می‌شود. فایل‌ها ابتدا stage
می‌شوند؛ سپس install به‌صورت transaction انجام می‌شود و در صورت خطا همهٔ
فایل‌های قبلی rollback می‌شوند. WAL/SHM database نیز همراه همان transaction
پاک‌سازی می‌شوند. archiveهای schema قدیمی هنوز قابل restore هستند، اما برای
امنیت دادهٔ اضافی را prune نمی‌کنند.

## retention و rollback

- stream عمومی و Hermes کاملاً جدا هستند.
- checkpoint تازهٔ Hermes به‌علاوهٔ سه checkpoint rollback قبلی نگه‌داری می‌شود.
- restore ابتدا جدیدترین archive را بررسی می‌کند و در صورت خرابی تا سه offset
  قبل rollback می‌کند.
- archive پذیرفته‌شده توسط GitHub به‌تنهایی trusted نیست؛ manifest، digest و
  SQLite باید معتبر باشند.
- اگر نه archive معتبر و نه state عمومیِ معتبر وجود داشته باشد، Hermes اجازه
  ندارد با history خالی شروع شود.

OpenClaw، Pi/Pi Web و AI Hub بازنشسته‌اند و در هیچ مسیر backup یا restore قرار
نمی‌گیرند.

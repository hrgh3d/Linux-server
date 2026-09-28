# مرجع backup و state

## دو مسیر مستقل

### ۱. state عمومی

`save.sh` و `restore.sh` داده‌های عملیاتی گسترده‌تر، واحدهای سرویس، تنظیمات و
vault پایدار را مدیریت می‌کنند. stream عمومی فقط artifactهای `state-*` را
مدیریت می‌کند.

### ۲. پیوستگی Hermes

`hermes_continuity.py` و `hermes_continuity.sh` مسیر canonical تاریخچهٔ Hermes
هستند. archive آن فقط state SQLite، profileها، session/routing data و فایل‌های
حافظهٔ Markdown را دارد. cache، log، venv و secret داخل آن نیست.

هر archive دارای manifest، SHA256، شمارش session/message و نتیجهٔ SQLite
integrity check است. restore قبل از هر تغییر state زنده، تمام این موارد را
اعتبارسنجی می‌کند و سپس با جایگزینی اتمی نصب می‌شود.

## retention و rollback

- stream عمومی و Hermes کاملاً جدا هستند.
- checkpoint تازهٔ Hermes به‌علاوهٔ سه checkpoint rollback قبلی نگه‌داری می‌شود.
- restore ابتدا جدیدترین archive را بررسی می‌کند و در صورت خرابی تا سه offset
  قبل rollback می‌کند.
- archive پذیرفته‌شده توسط GitHub به‌تنهایی trusted نیست؛ digest و SQLite نیز
  باید معتبر باشند.

## موارد خارج از backup Hermes

secretهای runtime در vault پایدار عمومی هستند، نه در archive Hermes. همچنین
فایل‌های بازنشستهٔ OpenClaw، Pi/Pi Web و AI Hub نباید در هیچ مسیر backup یا
restore قرار گیرند.

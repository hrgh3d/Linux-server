# بازیابی امن runner

این راهنما برای Hermes، 9router، OmniRoute، Headroom، CloudCLI و تنظیمات
Tailscale فعلی است.

## پیش‌نیازها

- source قابل اعتماد در branch `main`
- دسترسی GitHub Release خصوصی و مخزن state
- secretهای workflow فقط در GitHub Secrets
- زمان runner در کوتاه‌ترین مقدار عملی تنظیم شده باشد

## ترتیب بازیابی

1. runner جدید را از `main.yml` راه‌اندازی کنید.
2. restore state عمومی را اجرا کنید. اگر archive عمومی نبود، فقط بخش‌های قابل
   بازسازی شروع می‌شوند؛ secretهای لازم از vault پایدار برمی‌گردند.
3. `hermes_continuity.sh restore` باید پیش از بالا آمدن Hermes اجرا شود. این
   مرحله skill، profile، Bot Mode، topic binding، session، config و state مجاز
   Composio را همراه با state SQLite بازیابی می‌کند.
4. archive ابتدا از نظر manifest، SHA-256 و SQLite integrity check اعتبارسنجی
   می‌شود. restore فایل‌ها را stage می‌کند و با rollback transaction نصب می‌کند؛
   پس از اعتبارسنجی هیچ secret یا متن conversation در log نمی‌آید.
5. اگر جدیدترین checkpoint Hermes نامعتبر بود، restore حداکثر سه نسخهٔ قبلی را
   بررسی می‌کند. اگر هیچ نسخهٔ معتبری نبود، Hermes نباید با history خالی جایگزین
   وضعیت قبلی شود.
6. سرویس‌ها را بالا بیاورید و سلامت Gateway، Serve و routeها را بررسی کنید.
7. یک checkpoint تأییدشدهٔ Hermes ایجاد کنید تا runner جدید نقطهٔ بازیابی تازه
   داشته باشد.

## آزمون‌های صحت بعد از recovery

```bash
systemctl --user is-active hermes-gateway.service
systemctl is-active hermes-serve.service
sqlite3 /root/.hermes/state.db 'PRAGMA integrity_check;'
```

همچنین log workflow باید تعداد session/message restoreشده، تعداد memberها و
digest تأییدشده را بدون نمایش secret نشان دهد. تست archive/restore باید فقط با
home موقت اجرا شود؛ هیچ test نباید Telegram message، topic، Instagram post یا
تغییر state کاربر ایجاد کند.

## handoff

- checkpoint نهایی با `handoff=true` اجباری است.
- writerهای Hermes باید پیش از checkpoint پایانی متوقف باشند.
- اگر lock درگیر بود، handoff حداکثر ۳۰ ثانیه منتظر می‌ماند و با موفقیت کاذب
  رد نمی‌شود.
- پس از تأیید upload، سرویس‌های Hermes روی runner قبلی متوقف و runner بعدی در
  صف concurrency شروع می‌شود.

OpenClaw، Pi/Pi Web و AI Hub بازنشسته‌اند و در هیچ سناریوی recovery بازگردانی
نمی‌شوند.

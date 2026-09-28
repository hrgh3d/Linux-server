# Linux Server Runner

این مخزن runnerهای GitHub Actions برای سرویس‌های پایدار زیر را نگه‌داری می‌کند:

- **Hermes Agent** و پیوستگی تاریخچهٔ آن بین handoffهای runner
- **9router**، **OmniRoute**، **Headroom** و **CloudCLI**
- تنظیم‌شده‌های Tailscale Serve/Funnel و guardهای سلامت
- state عمومی و checkpointهای محدود و اعتبارسنجی‌شده

## اصل عملیاتی

runnerها موقتی‌اند؛ state ضروری از Releaseهای خصوصی و مخزن state بازیابی می‌شود.
Hermes از مسیر اختصاصی continuity استفاده می‌کند و هرگز نباید با state خالی جای
checkpoint تأییدشده شروع شود.

OpenClaw، Pi/Pi Web و AI Hub بازنشسته‌اند. این مخزن آن‌ها را نصب، اجرا، backup
یا restore نمی‌کند.

## شروع سریع برای اپراتور

1. تغییر را در branch `main` ثبت کنید.
2. workflow `main.yml` را با کمترین lifetime عملی dispatch کنید.
3. پس از آماده‌شدن runner، workflow `ops-exec.yml` را فقط برای audit یا عملیات
   محدود و بازبینی‌شده استفاده کنید.
4. قبل از handoff، checkpoint نهایی Hermes باید موفق و قابل بازیابی باشد.

جزئیات اجرایی در [OPS.md](OPS.md) و راهنمای بازیابی در
[.github/recovery/RECOVERY.md](.github/recovery/RECOVERY.md) قرار دارد.

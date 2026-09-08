# Linux-server

سرور Ubuntu همیشه‌روشن روی GitHub Actions با **داده‌های ماندگار، SSH ثابت و
Tailscale IP ثابت**. هر بار که runner ریست می‌شود (حدود هر ۵ ساعت)، همه‌چیز
به‌صورت خودکار بازگردانی می‌شود.

## اتصال به سرور

```bash
# با کلید خصوصی (پیشنهادی) — IP ثابت:
ssh -i ~/.ssh/id_ed25519 Hamid@100.100.100.100

# یا با MagicDNS (اگر فعال باشد):
ssh -i ~/.ssh/id_ed25519 Hamid@linux-server-vps
```

- **کاربر:** `Hamid`
- **پورت:** 22
- **sudo:** بدون رمز (`sudo su` مستقیم کار می‌کند)

## چطور کار می‌کند؟

1. workflow هر ۵ ساعت (یا با `workflow_dispatch` دستی) اجرا می‌شود.
2. `restore.sh` آخرین وضعیت را از **Release مخزن `Linux-server-state`** بازیابی می‌کند.
3. سرور ساخته می‌شود و تا پایان run زنده می‌ماند.
4. `save.sh` فقط در پایان run (حتی در صورت cancel دستی) وضعیت را روی همان
   Release آپلود می‌کند — یک نسخهٔ rolling، بدون بکاپ‌های تکراری.

> داده‌ها در مخزن جداگانهٔ `Linux-server-state` زندگی می‌کنند؛ با حذف این
> workflow یا مخزن کد، داده‌ها از بین نمی‌روند.

## نگه‌داشتن یک فایل/پوشه جدید بین ریست‌ها

فقط مسیرش را به `.github/scripts/persist.list` اضافه کن و commit کن:

```
/var/lib/mysql
```

## جابجایی دستی به سرور جدید (اختیاری)

- run فعلی را **Cancel** کن (ذخیرهٔ نهایی خودکار انجام می‌شود) → سپس در تب
  **Actions → Run workflow** یک run جدید بزن. همه‌چیز از آخرین state بازمی‌گردد.

## Secrets

در **Settings → Secrets and variables → Actions**:

| Secret | مقدار |
|---|---|
| `PERSIST_TOKEN` | توکن دسترسی به مخزن `Linux-server-state` |
| `TAILSCALE_AUTH_KEY` | کلید auth تیل‌اسکیل |
| `TAILSCALE_API_TOKEN` | توکن API (برای IP ثابت) |
| `TAILSCALE_FIXED_IP` | مثل `100.100.100.100` |
| `HAMID_PASSWORD` | پسورد کاربر |

## امنیت

- هر دو مخزن را **Private** نگه دار.
- کلید خصوصی SSH را فقط روی سیستم خودت نگه دار و جایی commit نکن.
- در صورت لو رفتن کلید: کلید عمومی را در `.github/ssh/id_ed25519.pub` عوض کن و
  `HAMID_PASSWORD` را در Secrets به‌روز کن.

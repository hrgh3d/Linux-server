# Linux-server

سرور Ubuntu پایدار مبتنی بر GitHub Actions با **داده‌های ماندگار، کلید SSH ثابت و IP پایدار Tailscale** — معماری v4.

Runner هر ~۶ ساعت از بین می‌رود و دوباره ساخته می‌شود؛ اما هیچ‌کدام از اطلاعات زیر روی Filesystem موقت Runner نمی‌مانند و در مخزن جداگانه‌ی state نگهداری می‌شوند:

- فایل‌های شخصی (`/home/Hamid`) و اطلاعات `/root`
- پکیج‌ها/نرم‌افزارهای نصب‌شده (لیست + بازنصب خودکار)
- تنظیمات و کانفیگ‌های سیستم (`/etc`)، برنامه‌ها (`/opt`, `/srv`, `/usr/local`, `/var/www`)، Cron
- هویت Node تیل‌اسکیل (`/var/lib/tailscale`) برای ثبات IP
- کلیدهای Host سرور (`/etc/ssh/ssh_host_*`) تا fingerprint سرور تغییر نکند

## ویژگی‌های کلیدی (v4)

- **یک اسنپ‌شاتِ واحدِ Rolling** روی Release مخزن `Linux-server-state`؛ آپلود فقط وقتی محتوا واقعاً تغییر کرده باشد → Cancel و Run مجدد **بکاپ اضافی نمی‌سازد**.
- **Restore خودکار** در ابتدای هر Run: فایل‌ها، پکیج‌ها، هویت Tailscale و کلیدهای Host.
- **کلید SSH ثابت**: کلید عمومی `ed25519` در `.github/ssh/id_ed25519.pub`؛ در هر Boot به `authorized_keys` کاربر `Hamid` و `root` اضافه می‌شود (بدون حذف کلیدهای اضافه‌ی مجاز قبلی).
- **مدیریت بدون رمز**: `root` بدون پسورد؛ کاربر `Hamid` دارای `NOPASSWD` و `sudo su` بدون درخواست Password.
- **IP ثابت Tailscale**: بازیابی هویت قبلی (همان Node Key) → همان IP؛ در صورت نیاز `TAILSCALE_FIXED_IP` از طریق Tailscale API تثبیت می‌شود.
- **نتیجه‌ی هر Boot** (markerها، IP، fingerprint کلیدها و …) در `server_report` و Step Summary چاپ می‌شود.

## نحوه اتصال به سرور

پس از اجرای Workflow، اطلاعات اتصال در Step Summary نمایش داده می‌شود:

```bash
ssh -i ~/.ssh/id_ed25519 Hamid@<TAILSCALE_IP>
# یا با MagicDNS (در صورت فعال بودن):
ssh -i ~/.ssh/id_ed25519 Hamid@linux-server-vps
```

- کاربر: `Hamid` — پورت: `22` — دسترسی ریشه: `sudo su` (بدون پسورد)

## ساختار و چرخه‌ی حیات

1. **Run جدید** روی `ubuntu-24.04` شروع می‌شود (هر ۵ ساعت توسط `schedule` یا دستی `workflow_dispatch`).
2. **restore.sh** جدیدترین state را دانلود و بازمی‌گرداند (پکیج‌ها، فایل‌ها، هویت Tailscale، کلیدهای Host).
3. SSH و Tailscale خودکار پیکربندی/اتصال می‌شوند.
4. سرور تا `lifetime_min` (پیش‌فرض ۳۳۰ دقیقه) زنده است؛ هر `SAVE_INTERVAL_MIN` دقیقه (۵) اگر تغییری رخ داده باشد، state همگام می‌شود.
5. با Cancel، Timeout یا پایان عمر، آخرین وضعیت ذخیره و برای چرخه‌ی بعد آماده می‌شود.

### پارامترهای Run دستی
| Input | پیش‌فرض | توضیح |
|---|---|---|
| `lifetime_min` | `330` | طول عمر سرور (برای تست می‌توانید کم کنید) |
| `probe` | `false` | نوشتن فایل تستی در `/root`,`/home/Hamid`,`/opt` + نصب `htop` برای راستی‌آزمایی ماندگاری |
| `selftest` | `true` | تست محلی SSH (sudo بدون رمز، `sudo su`، ورود root با کلید) |

## Secrets مورد نیاز (مخزن اصلی)
| Secret | توضیح |
|---|---|
| `PERSIST_TOKEN` | دسترسی نوشتن به مخزن `Linux-server-state` |
| `TAILSCALE_AUTH_KEY` | کلید Auth تیل‌اسکیل (ترجیحاً reusable) |
| `TAILSCALE_API_TOKEN` | (اختیاری) برای پاک‌سازی Node مرده و تثبیت IP |
| `TAILSCALE_FIXED_IP` | (اختیاری) IP دلخواه ثابت مثل `100.x.y.z` |
| `HAMID_PASSWORD` | (اختیاری) در صورت نیاز به پسورد برای کاربر Hamid |

## امنیت
- هر دو مخزن را **Private** نگه دارید.
- کلید خصوصی SSH را هرگز Commit نکنید؛ فقط روی سیستم شخصی.
- برای تغییر کلید SSH، کلید عمومی جدید را در `.github/ssh/id_ed25519.pub` قرار دهید.
- بعد از اولین Boot معماری v4 ممکن است fingerprint میزبان SSH یک‌بار عوض شود (کلید Host جدید تولید و سپس برای همیشه در State ذخیره می‌شود). مقدار جدید در Step Summary چاپ می‌شود.

# OPS — راهنمای عملیاتی سرور AI ‏(hrgh3d/Linux-server)

> این سرور برای اجرای AI/agent است، نه VPN. چرخه عادی: هر ران ~۶ ساعت (۳۵۰ دقیقه)
> کار می‌کند، ۱۰ دقیقه قبل از پایان، رانِ بعدی را خودش اجرا می‌کند (زنجیره جانشین)
> و قطعی هر دست‌به‌دست شدن فقط چند دقیقه (بوت + بازیابی state) است.

## ۱) کارهای روزمره

- **وضعیت سریع:** تب Actions ← آخرین ران باید `in_progress` و قدم جاری
  `Keep server alive` باشد. قدم قرمز = لاگ همان قدم را بخوان.
- **اجرای دستی:** Actions ← ورکفلو ← `Run workflow` (پیش‌فرض ۳۵۰ دقیقه).
  ران دستی جدید جایگزین قبلی می‌شود (قبلی کنسل می‌گردد).
- **خاموش کردن کامل:** ران را کنسل کن **و** ورکفلو را Disable کن
  (وگرنه کرون هر ۵ ساعت دوباره روشنش می‌کند).

## ۲) قرارداد ایجنت (مهم!)

- پروسس‌ها ریبیلد را زنده نمی‌مانند. اگر فایل اجرایی
  `/root/agent-autostart.sh` وجود داشته باشد، آخر هر بوت خودکار اجرا می‌شود
  (غیرfatal، لاگ: `/var/log/agent-autostart.log`).
- اسکریپت autostart باید **idempotent** باشد (اجرای دوباره ضرر نزند) و سریع
  تمام شود؛ کار طولانی را به background ببرد.
- **فقط این مسیرها بین ریبیلدها می‌مانند** (بقیه می‌پرد!):
  `/root` ،`/home/Hamid` ،`/opt` ،`/srv` ،`/etc` ،`/usr/local/bin` ،`/usr/local/sbin` ،
  `/var/www` ،`/var/spool/cron` ،`/var/lib` ،`/var/opt` (+ هویت Tailscale).
  → workspace ایجنت را زیر `/root` یا `/home/Hamid` نگه دار.
- کلیدهای API سرویس‌ها فقط via **GitHub Secrets → env**؛ هرگز در فایل/ریپو.

## ۳) کلیدها و توکن‌ها (چرخه نگهداری)

| مورد | کجا | چرخه |
|---|---|---|
| Tailscale Auth Key | Secret `TAILSCALE_AUTH_KEY` | reusable باشد؛ قبل از انقضا عوض کن |
| Tailscale Node Key | کنسول ← Machines | **Disable key expiry** را بزن (یک‌بار) |
| `SUCCESSOR_TOKEN` | Secret (برای زنجیره) | با هر تعویض PAT به‌روز شود وگرنه زنجیره می‌ایستد |
| `PERSIST_TOKEN` | Secret (دسترسی state) | فقط همین ریپوی state |
| `.github/key-dates.json` | داخل ریپو (تاریخ‌ها، نه secret) | با هر تعویض توکن به‌روز کن — هر بوت چک می‌شود |
| وبهوک | Secret `NOTIFY_WEBHOOK_URL` | Discord webhook یا Telegram (`bot<TOKEN>/sendMessage?chat_id=<ID>`) |

هشدار انقضا (`[key-expiry]`) هر بوت در لاگ + Summary ران + وبهوک می‌آید (کمتر از ۱۰ روز).

## ۴) خرابی‌های رایج و واکنش

| علامت | واکنش |
|---|---|
| قدم بوت قرمز | لاگ همان قدم؛ معمولاً گذراست → ران دستی جدید |
| node در کنسول Tailscale آفلاین | صبر کن (وسط ریبیلد؟)؛ اگر >۱۵ دقیقه: ران را چک کن |
| ران جدید بعد از پایان قبلی نیامد | دستی dispatch کن + سلامت `SUCCESSOR_TOKEN` را چک کن |
| ایجنت بعد از ریبیلد برنگشت | `/var/log/agent-autostart.log` در بوت بعدی؛ idempotent بودن اسکریپت |
| پیام وبهوک نیامد | رسیدن URL را تست کن (بخش ۵ پرامپت ایجنت) |

## ۵) Billing و امنیت

- این ریپو **public** است → دقیقه Actions نامحدود و رایگان. (اگر private شود: فقط ۲۰۰۰ دقیقه/ماه!)
- ریپوی **state همیشه private** می‌ماند (داخلش داده و کلید است).
- لاگ‌ها بهداشتی‌اند (بدون secret/ایمیل). اگر چیزی حساس لو رفت: لاگ آن ران را با API پاک کن:
  `DELETE /repos/hrgh3d/Linux-server/actions/runs/{id}/logs`
- Spending limit را $0 نگه دار؛ گاهی Billing را نگاه کن.

## ۶) بکاپ (مهم!)

اگر اکانت گیت‌هاب به مشکل بخورد (suspend)، کد + state با هم می‌روند:
- همیشه کلون محلی هر دو ریپو (`Linux-server` و `Linux-server-state`) داشته باش.
- قبل از تغییرات بزرگ، آخرین state را دانلود کن:
```bash
# آخرین ریلیز state + دانلود asset (با PAT خودت)
curl -s -H "Authorization: Bearer $PAT" \
  "https://api.github.com/repos/hrgh3d/Linux-server-state/releases/tags/state" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print([a['name'] for a in d.get('assets',[])])"
```

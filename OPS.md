# OPS — راهنمای عملیاتی سرور (v6.10)

> چرخه عادی: هر Run ~۳۵۰ دقیقه؛ ۲۰ دقیقه قبل از پایان، خودِ Run جانشین را
> dispatch می‌کند (با `GITHUB_TOKEN` خود ران). تیک ساعته کرون فقط backstop است.
> قطعی هر دست‌به‌دست‌سازی = چند دقیقه (بوت + بازیابی state).

## ۱) کارهای روزمره
- **وضعیت سریع:** Actions ← آخرین Run باید `in_progress` و قدم `Keep server alive` باشد. قدم قرمز = لاگ همان قدم.
- **جایگزینی دستی (ریبیلد):** Actions ← Run workflow (پیش‌فرض ۳۵ دقیقه). Run دستی، Run فعلی را کنسل و جایگزینش می‌شود.
- **خاموش کردن کامل:** کنسل Run فعال + Disable ورکفلو (وگرنه کرون ساعته دوباره روشنش می‌کند).
- **وصل SSH:** `ssh -i <کلید> root@100.70.83.2` (فingerprint: `SHA256:kdsQ9FkMfUVWwaLckY3/yb2vEq0faMwUFtgID8eEl4w`).
- **داشبورد Hermes:** آدرس تونل هر بوت به تلگرام می‌آید؛ لاگین `hamid` + رمز (secret `DASHBOARD_PASSWORD`).

## ۲) قرارداد ایجنت
- اگر `/root/agent-autostart.sh` موجود باشد، آخر هر بوت با **root** اجرا می‌شود (غیرfatal؛ لاگ `/var/log/agent-autostart.log`).
- باید **idempotent** و سریع باشد؛ کار طولانی را به background بسپارد.
- فقط مسیرهای `persist.list` بین ریبیلدها می‌مانند → workspace ایجنت را زیر `/root` یا `/home/Hamid` نگه دار.
- کلیدهای API فقط از طریق **GitHub Secrets** (env)؛ هرگز در فایل/آرشیو (مکانیزم: `secrets_inject.sh`).

## ۳) کلیدها و توکن‌ها
| مورد | کجا | وضعیت/چرخه |
|---|---|---|
| Tailscale Auth Key | Secret `TAILSCALE_AUTH_KEY` | ۹۰ روزه (سقف API؛ `expirySeconds:0` پذیرفته نمی‌شود). چون node **غیر-ephemeral** است، بعد از اولین اتصال موفق، reconnect با node key در state است و این key فقط برای bootstrap لازم است. قبل از انقضا (هشدار `[key-expiry]` هر بوت) key تازه بساز — می‌شود با API: `POST /api/v2/tailnet/-/keys` با `capabilities.devices.create {reusable:true, ephemeral:false, preauthorized:true}`. |
| Tailscale API Token | Secret `TAILSCALE_API_TOKEN` | **محدوده‌ی زمانی دارد (مثال فعلی: ۲۴ ساعت!)** — همیشه تاریخ انقضا را در `key-dates.json` ثبت کن. بدون آن: pin IP + cleanup + چک انقضا غیرفعال می‌شوند (boot نمی‌شکند). |
| PAT (push/زنجیره) | Secrets `PERSIST_TOKEN` / `SUCCESSOR_TOKEN` | زنجیره الان با `GITHUB_TOKEN` کار می‌کند؛ PAT فقط برای state و push. با هر تعویض، هر دو secret را به‌روز کن. |
| Telegram Bot Token | Secret `TELEGRAM_BOT_TOKEN` | از آرشیو خارج است (تزریق هر بوت). اگر جایی لو رفت: BotFather → `/token` برای همین bot → revoke → مقدار جدید در secret. |
| رمز داشبورد | Secret `DASHBOARD_PASSWORD` | فقط hash یک‌طرفه در آرشیو است؛ تعویض = تغییر secret (بوت بعد اعمال می‌شود). |
| `.github/key-dates.json` | داخل ریپو | با هر تعویض توکن به‌روز کن — هر بوت چک می‌شود (<۱۰ روز = هشدار). |
| وبهوک اعلان | Secret `NOTIFY_WEBHOOK_URL` | Discord webhook یا Telegram (`bot<TOKEN>/sendMessage?chat_id=<ID>`) — اختیاری. |

## ۴) خرابی‌های رایج
| علامت | واکنش |
|---|---|
| قدم بوت قرمز | لاگ همان قدم؛ معمولاً گذراست → یک Run دستی جدید |
| dispatch جانشین شکست (لاگ `[successor]`) | Run جدید دستی بزن؛ سلامت توکن‌ها را چک کن؛ کرون ساعته backstop است |
| node تیل‌اسکیل آفلاین >۱۵ دقیقه | وسط ریبیلد؟ اگر نه: Run فعلی را چک کن (قدم Setup Tailscale) |
| IP سرور عوض شده | secret `TAILSCALE_FIXED_IP` + token API را چک کن (لاگ `[ts] pin API response`) |
| داشبورد بدون رمز (HTTP 200) | قدم `Dashboard auth guard` را چک کن: nginx install/active + هتپاسورد |
| ایجنت بعد از ریبیلد برنگشت | `/var/log/agent-autostart.log`؛ idempotent بودن اسکریپت |

## ۵) ⚠️ Billing (مهم‌ترین ریسک عملیاتی)
- ریپو **public** + اکانت **Free** = **۲۰۰ دقیقه رایگان/ماه** (نه نامحدود؛ private روی Free = ۰).
- مصرف ≈ **۱۴۵۰ دقیقه/روز** → سقف ماهانه در ~۱.۴ روز پر می‌شود؛ بعدش Runهای جدید (شامل dispatch جانشین) تا **ریست ماهانه (روز ۱)** رد می‌شوند → سرور می‌ایستد و با اولین تیک کرون بعد از ریست زنده می‌شود.
- پایش: Settings → Billing and plans → Usage → Actions (یا email هشدار GitHub).
- گزینه‌های پایدار: (a) پلن Team — ۵۰هزار دقیقه/ماه، (b) مهاجرت به VPS واقعی (ارزان‌ترین و پایدارترین)، (c) پذیرش قطعی ماهانه.

## ۶) بکاپ
- کد: هر لحظه `git clone https://github.com/hrgh3d/Linux-server` (public).
- state: ریپوی private `Linux-server-state`؛ **۲ اسنپ‌شات آخر** روی Release با تگ `state` (latest + rollback):
```bash
curl -s -H "Authorization: Bearer $PAT" \
  "https://api.github.com/repos/hrgh3d/Linux-server-state/releases/tags/state" \
  | python3 -c "import json,sys; [print(a['name'], a['size']) for a in json.load(sys.stdin)['assets']]"
```
- همیشه یک کلون محلی هر دو ریپو نگه دار (اگر اکانت گیت‌هاب suspend شود، کد+state با هم می‌روند).

## ۷) لاگ‌های بهداشتی
لاگ‌ها secret/ایمیل print نمی‌کنند. اگر چیزی حساس لو رفت: لاگ آن Run را با API پاک کن:
`DELETE /repos/hrgh3d/Linux-server/actions/runs/{id}/logs`

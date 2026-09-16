# OPS — راهنمای عملیاتی سرور (v6.22)

> آخرین به‌روزرسانی: ۲۰۲۶-۰۹-۱۶

> چرخه عادی: هر Run ~۳۵۰ دقیقه؛ ۲۰ دقیقه قبل از پایان، خودِ Run جانشین را
> dispatch می‌کند (با `GITHUB_TOKEN` خود ران). تیک ساعته کرون فقط backstop است.
> قطعی هر دست‌به‌دست‌سازی = چند دقیقه (بوت + بازیابی state).

## ۱) کارهای روزمره
- **وضعیت سریع:** Actions ← آخرین Run باید `in_progress` و قدم `Keep server alive` باشد. قدم قرمز = لاگ همان قدم.
- **جایگزینی دستی (ریبیلد):** Actions ← Run workflow (پیش‌فرض ۳۵ دقیقه). Run دستی، Run فعلی را کنسل و جایگزینش می‌شود.
- **خاموش کردن کامل:** کنسل Run فعال + Disable ورکفلو (وگرنه کرون ساعته دوباره روشنش می‌کند).
- **بازیابی قطعی کامل (v6.16):** `watchdog-fast` مقیم هر **۶۰ ثانیه** چک می‌کند؛ نبودِ رانر → dispatch فوری → تشخیص ≤۱ دقیقه + بوت ≈۳ دقیقه = وصل کامل ≈ **۳-۵ دقیقه**. کرون‌های `watchdog`/`watchdog-b` وقتی زنجیرهٔ fast زنده است passive‌اند و فقط اگر خودش بمیرد دوباره روشنش می‌کنند. خاموش‌کردن کاملِ ماندگار: هر سه ورک‌فلو (main + watchdog-fast + watchdog/b) کنسل/Disable شوند.
- **وصل SSH (ساده):** `ssh root@100.70.83.2` + رمز (secret `HAMID_PASSWORD`؛ کاربر `Hamid` هم همان رمز). کلید اختیاری: `ssh -i <کلید> root@100.70.83.2`. fingerprint host: `SHA256:6P2g9TXEf9e4kPQC7KslkPg+kbQVyP12mVA9pSdfaoc` (ED25519، پایدار بین جانشینی‌ها). خطای `HOST IDENTIFICATION HAS CHANGED` = ورودی قدیمی در known_hosts → یک‌بار `ssh-keygen -R 100.70.83.2`.
- **داشبوردها:** Hermes روی سرور `http://localhost:9119` و 9Router `http://localhost:20128/dashboard` — هر دو ۲۴/۷ سرویس systemd با `Restart=always`. آدرس عمومی (تونل) با هر تغییر توسط ربات گزارش اعلام می‌شود: `Hermes Dashboard : <آدرس>` / `9Router Terminal : <آدرس>`. لاگین Hermes: `hamid` + رمز (secret `DASHBOARD_PASSWORD`). لاگین 9Router (از v6.18): گیت nginx حذف شده — فقط رمز خود پنل برابر secret `HAMID_PASSWORD` که از v6.20 در هر بوت تثبیت می‌شود. دستور `hermes dashboard` روی سرور به‌جای ارور، آدرس‌ها را چاپ می‌کند.

## ۲) قرارداد ایجنت
- اگر `/root/agent-autostart.sh` موجود باشد، آخر هر بوت با **root** اجرا می‌شود (غیرfatal؛ لاگ `/var/log/agent-autostart.log`).
- باید **idempotent** و سریع باشد؛ کار طولانی را به background بسپارد.
- فقط مسیرهای `persist.list` بین ریبیلدها می‌مانند → workspace ایجنت را زیر `/root` یا `/home/Hamid` نگه دار.
- کلیدهای API فقط از طریق **GitHub Secrets** (env)؛ هرگز در فایل/آرشیو (مکانیزم: `secrets_inject.sh`).

## ۳) کلیدها و توکن‌ها
| مورد | کجا | وضعیت/چرخه |
|---|---|---|
| Tailscale Auth Key | Secret `TAILSCALE_AUTH_KEY` | ۹۰ روزه (سقف API؛ `expirySeconds:0` پذیرفته نمی‌شود). چون node **غیر-ephemeral** است، بعد از اولین اتصال موفق، reconnect با node key در state است و این key فقط برای bootstrap لازم است. قبل از انقضا (هشدار `[key-expiry]` هر بوت) key تازه بساز — می‌شود با API: `POST /api/v2/tailnet/-/keys` با `capabilities.devices.create {reusable:true, ephemeral:false, preauthorized:true}`. |
| Tailscale API Token | Secret `TAILSCALE_API_TOKEN` | **محدوده‌ی زمانی دارد (حداکثر ۹۰ روز؛ تاریخ‌های فعلی در `key-dates.json`)** — همیشه تاریخ انقضا را در `key-dates.json` ثبت کن. بدون آن: pin IP + cleanup + چک انقضا غیرفعال می‌شوند (boot نمی‌شکند). |
| PAT (push/زنجیره) | Secret `PERSIST_TOKEN` | زنجیره با `GITHUB_TOKEN` خودِ ران کار می‌کند؛ `PERSIST_TOKEN` برای state (آپلود/دانلود) و fallback دیسپچ است. (`SUCCESSOR_TOKEN` حذف شد — همه‌جا به `PERSIST_TOKEN` برمی‌گردند.) با هر تعویض PAT فقط `PERSIST_TOKEN` را به‌روز کن. |
| Telegram Bot Token (Hermes) | Secret `TELEGRAM_BOT_TOKEN` | فقط برای Hermes Gateway (تزریق هر بوت به `/root/.hermes/.env`). اگر جایی لو رفت: BotFather → `/token` برای همین bot → revoke → مقدار جدید در secret. |
| ربات گزارش سیستم | Secret `REPORT_BOT_TOKEN` | **جدا از ربات Hermes** — watchdog، send-backup و notify.sh هشدارها/گزارش‌ها را با این ربات می‌فرستند (`@Vpshamidreportbot`). chat_id: secret `NOTIFY_CHAT_ID`. |
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

## ۵) ⏱️ Billing
- ریپو **public** است → دقیقه‌های Actions روی runnerهای استاندارد **رایگان و نامحدود** (سقف ماهانه فقط برای ریپوهای private است). شاهد عملی: چند روز اجرای پیوسته ۲۴/۷ بدون رد شدن هیچ Run.
- تنها محدودیت فنی، عمر ~۶ ساعته هر job است که زنجیره جانشین (dispatch نسل بعد ~۲۰ دقیقه قبل از پایان) آن را بی‌اثر می‌کند.
- سناریوی احتیاطی: اگر روزی سیاست GitHub تغییر کند و ایجاد Run محدود شود، state در ریپوی خصوصی امن است و زنجیره با اولین تیک کرون پس از رفع محدودیت خودکار برمی‌گردد؛ مهاجرت به VPS واقعی هم همیشه بدون از دست رفتن داده ممکن است.


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

## ۸) OpenClaw — داشبورد و اپ موبایل

آدرس داشبورد (فقط داخل tailnet): `https://linux-server-vps.tail3641f4.ts.net`

### خطای `proxy_attribution_required` در داشبورد
Serve دستی ساخته شده و OpenClaw آن را پراکسیِ ناشناخته می‌بیند. مدیریت Serve
را به خود OpenClaw بدهید (ترتیب مهم است):
```bash
tailscale serve --https=443 off
openclaw config set gateway.bind loopback
openclaw config set gateway.tailscale.mode serve
openclaw config set --json gateway.trustedProxies '["127.0.0.1/32","::1/128"]'
openclaw config set gateway.auth.allowTailscale true
systemctl restart openclaw-gateway
```
موفقیت = لاگ `[tailscale] serve enabled:` و HTTPS root با کد **200**.

### خطای `http101 403 forbidden` در اپ اندروید
یعنی دستگاه در صف Pending است، نه مسدود:
```bash
openclaw devices list
openclaw devices approve <requestId>
```
برای تأیید خودکار همیشگیِ دستگاه‌های داخل tailnet:
```bash
openclaw config set gateway.nodes.pairing.autoApproveLocal true
openclaw config set --json gateway.nodes.pairing.autoApproveCidrs \
  '["100.64.0.0/10","127.0.0.1/32","::1/128"]'
```
`provision.sh` از v6.31 همهٔ این‌ها را در هر بوت خودش اعمال می‌کند.

### داشبورد هر ۱۰ دقیقه می‌میرد (سرویس active است ولی HTTPS قطع)
علت: هر اجرای ops-exec/واچ‌داگ `tailscaled` را Stop/Start می‌کند و حالت داخلی
OpenClaw (`gateway.tailscale.mode=serve`) مسیر ingress را فقط in-process نگه
می‌دارد، پس برنمی‌گردد. درمان (v6.34):
```bash
openclaw config set gateway.tailscale.mode off
systemctl restart openclaw-gateway
tailscale serve --bg --https=443 http://127.0.0.1:18789   # در /var/lib/tailscale می‌ماند
```
نگهبان `openclaw-serve-guard.timer` هر ۶۰ ثانیه آدرس HTTPS را probe می‌کند و
در صورت قطعی مسیر Serve را بازمی‌سازد. لاگ: `/var/log/openclaw-serve-guard.log`.

> ⚠️ `tailscale serve status` را سیگنال سلامت نگیرید — در حالت داخلی OpenClaw
> حتی وقتی داشبورد سالم است «No serve config» می‌گوید و باعث ری‌استارت الکی
> می‌شود. سیگنال درست، `curl` واقعی به آدرس HTTPS است.

### ماندگاری
دستگاه‌های paired در `/root/.openclaw/state/openclaw.sqlite` ذخیره می‌شوند که
در آرشیو state است و `sqlite_stage.py` نسخهٔ سالم از آن می‌گیرد ⇒ بعد از تعویض
رانر نیازی به pairing مجدد نیست. مسیر Serve هم در `/var/lib/tailscale` (روت
persist) ذخیره می‌شود، پس آدرس داشبورد بین رانرها ثابت می‌ماند.

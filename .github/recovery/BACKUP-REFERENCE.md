# سیستم بکاپ — مرجع کامل (v6.35.3)

**به‌روزرسانی:** ۲۰۲۶-۰۹-۱۶

هدف: اگر **کل حساب گیت‌هاب از دست برود**، فقط با آخرین فایل باندل تلگرام
بتوان تمام سیستم را دقیقاً به شکل فعلی بالا آورد.

---

## چه زمانی بکاپ می‌رود

| رویداد | حالت |
|---|---|
| هر گزارش ربات (قطع/وصل ❌✅، تغییر آدرس داشبورد) | عادی |
| کرون روزانه ۰۳:۴۷ UTC | عادی |
| کرون شنبه ۰۴:۱۵ UTC | DR (+ اسنپ‌شات کامل state) |
| دستی | انتخابی |

dedup ۱۵ دقیقه‌ای؛ با `force=true` نادیده گرفته می‌شود.

```bash
PAT=$(grep -oP 'PAT = \K\S+' /home/user/uploads/Hrgh3d.txt)
curl -s -X POST -H "Authorization: token $PAT" \
  https://api.github.com/repos/hrgh3d/Linux-server/actions/workflows/send-backup.yml/dispatches \
  -d '{"ref":"main","inputs":{"full":"true","force":"true"}}'
```

---

## محتویات باندل

| جزء | حجم تقریبی | چرا حیاتی است |
|---|---|---|
| `tailscale-state.tar.gz` | ۸KB | **هویت گره + گواهی TLS.** بدون آن MagicDNS عوض می‌شود و همهٔ setup codeها و لینک داشبورد باطل می‌شوند |
| `openclaw.tar.gz` | ۱.۸MB | کانفیگ، سشن، workspace کامل OpenClaw |
| `sqlite/openclaw-state.sqlite` | — | جدول `device_pairing_paired` (دستگاه‌های جفت‌شده) |
| `sqlite/9router-data.sqlite` | — | کلیدهای API و کاربران 9router |
| `services.tar.gz` | ۱۵KB | nginx، cron، یونیت‌های systemd (system + user) |
| `bin-scripts.tar.gz` | ۱۶۰KB | همهٔ نگهبان‌ها و wrapper اوپن‌کلاو |
| `app-code.tar.gz` | ۵.۱MB | `/opt/9router`، `/root/.hermes`، `/var/www` |
| `home-root.tar.gz` | ۱۴MB | باقی `/root` به‌عنوان تور ایمنی |
| `bootstrap/repo.tar.gz` | ۱۰۰KB | کل ریپوی کد |
| `bootstrap/recovery/secrets.env` | — | همهٔ سکرت‌ها (Base64) |
| `bootstrap/recovery/RECOVERY.md` | — | راهنمای بازگردانی گام‌به‌گام |
| `info.txt` | — | نسخه‌ها، MagicDNS، جدول Serve، دستگاه‌ها |

**مجموع:** حدود ۱۷.۶ مگابایت (زیر سقف ۴۵MB تلگرام ⇒ یک فایل، بدون تکه‌تکه شدن).

در حالت DR، اسنپ‌شات کامل state (~۷۵۰MB) هم در ۱۸ بخش جداگانه می‌آید.

---

## بازرسی خودکار

باندل **قبل از ارسال** باز و بررسی می‌شود؛ نتیجه در کپشن تلگرام می‌آید:

| کپشن | یعنی |
|---|---|
| `✅ کامل — 10 جزء، db:ok paired:5 tsid:ok` | همه‌چیز سالم |
| `⚠️ ناقص — N ایراد بحرانی` | لاگ ران را بخوان |
| `⚠️ بدون دادهٔ سرور (SSH قطع بود)` | فقط bootstrap + state |

بازرسی عمیق شامل:
- `pragma integrity_check` روی اسنپ‌شات دیتابیس
- شمارش دستگاه‌های جفت‌شده
- تأیید وجود `tailscaled.state` داخل آرشیو تیل‌اسکیل

---

## بازگردانی

روال کامل روی سرور خالی: `docs/RECOVERY-BUNDLE.md` بخش ۵
(همان `RECOVERY.md` که داخل خود باندل هم هست).

### سه تلهٔ حیاتی
1. **ترتیب:** `/var/lib/tailscale` باید *قبل از* استارت `tailscaled` برگردد.
2. **Node:** نود سیستمی روی ۲۲ بماند؛ OpenClaw رانتایم خودش را دارد.
3. **Serve:** `gateway.tailscale.mode=off` و Serve دستی — حالت داخلی OpenClaw
   بعد از هر ری‌استарت tailscaled می‌میرد.

---

## سه اشتباه تاریخی (تکرارشان نکن)

1. بودجهٔ حجم را با `du` خام نسنج — `/root/.openclaw/cache` به‌تنهایی ۴۸MB است
   و باعث می‌شد کل `/root` **بی‌صدا** از بکاپ بیفتد.
2. `/usr/local/bin` روی رانر گیت‌هاب ۱.۲GB است (minikube، pulumi، packer…).
   فقط فایل‌های زیر ۲MB را بگیر.
3. دیتابیس زنده را با `cp` نگیر — `VACUUM INTO` بگیر.

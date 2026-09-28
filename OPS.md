# راهنمای عملیات runner

## سرویس‌های فعال

- Hermes Gateway و Hermes Serve
- 9router، OmniRoute، Headroom و CloudCLI
- Tailscale و guardهای مربوط به routeهای مجاز

اجزای بازنشسته (OpenClaw، Pi/Pi Web و AI Hub) بخشی از عملیات نیستند و نباید با
workflow، restore یا backup دوباره ایجاد شوند.

## چرخهٔ امن runner

1. `main.yml` ابتدا state عمومی و سپس checkpoint اختصاصی Hermes را بازیابی می‌کند.
2. سرویس‌ها بعد از اعتبارسنجی restore اجرا می‌شوند.
3. pulse پس‌زمینه هر ۶۰ ثانیه تغییر state Hermes را بررسی می‌کند؛ در صورت تغییر،
   checkpoint جدید می‌فرستد.
4. handoff writerهای Hermes را متوقف می‌کند، checkpoint نهایی را تأیید می‌کند و
   سپس runner را واگذار می‌کند.
5. runهای `main.yml` در concurrency مشترک صف می‌شوند؛ runner جدید runner قبلی را
   به‌زور cancel نمی‌کند.

## کنترل‌های ضروری پس از تغییر

```bash
python3 .github/scripts/hermes_continuity.py selftest
python3 .github/scripts/payload.py selftest
bash -n .github/scripts/hermes_continuity.sh
python3 - <<'PY'
import yaml
for p in ('.github/workflows/main.yml', '.github/workflows/ops-exec.yml'):
    yaml.safe_load(open(p, encoding='utf-8'))
print('workflow YAML: OK')
PY
```

## عملیات از راه دور

- workflow `ops-exec.yml` فقط برای دستورهای صریح، کوتاه و قابل audit است.
- tokenهای persistence نباید در log، artifact یا command چاپ شوند.
- برای کارهای بررسی، ابتدا command فقط‌خواندنی اجرا کنید.
- lifetime runner باید کمترین مقدار عملی باشد و پس از صحت‌سنجی تمدید نشود.

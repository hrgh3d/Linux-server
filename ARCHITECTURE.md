# Linux-server — معماری پایدار (Persistent Immutable Architecture)

## هدف اصلی
ساخت یک سرور Ubuntu 22.04 از طریق GitHub Actions که هر ۶ ساعت جایگزین می‌شود، اما تمام داده‌ها، برنامه‌ها، تنظیمات و دسترسی SSH حفظ می‌شوند.

## معماری پیشنهادی (فقط با ابزارهای GitHub)

### ۱. حافظه ثابت (Persistence Layer)
- **روش:** استفاده از فایل فشرده در Repository (`persistent/state.tar.gz`) و به‌روزرسانی خودکار با `GITHUB_TOKEN` در هر اجرا.
- **مزیت:** کاملاً رایگان، بدون نیاز به Oracle/AWS، بدون انقضا.
- **محتوا:** لیست بسته‌های نصب شده (`dpkg --get-selections`)، فایل‌های تنظیمات `/etc`، داده کاربر `/home/Hamid`، تنظیمات برنامه‌ها.

### ۲. بازیابی خودکار (Auto-Restore)
- در ابتدای هر Workflow، فایل `persistent/state.tar.gz` از Repository دانلود و باز می‌شود.
- تمام بسته‌ها با `apt install --no-install-recommends -y $(cat persistent/packages.list)` نصب می‌شوند.
- تمام تنظیمات سیستم و کاربر بازیابی می‌شوند.

### ۳. کاربر سیستم و رمز عبور
- **نام کاربری:** `Hamid`
- **رمز عبور:** `hamid1369`
- **دسترسی:** عضو گروه `sudo` برای دسترسی کامل به سیستم.

### ۴. SSH ثابت (Stable SSH Access)
- **کلید خصوصی:** `Ed25519` ثابت در `.github/ssh/id_ed25519`
- **کلید عمومی:** ذخیره شده در `.github/ssh/authorized_keys` و در سرور در `/home/Hamid/.ssh/authorized_keys`
- **تونل:** `serveo.net` با نام ثابت (`novinsazehmrv-spec`)
  ```bash
  ssh -R novinsazehmrv-spec:22:localhost:22 serveo.net
  ```
- **اتصال کاربر:**
  ```bash
  ssh -o ProxyCommand="ssh -W novinsazehmrv-spec:22 serveo.net" Hamid@novinsazehmrv-spec
  # یا با کلید خصوصی:
  ssh -i .github/ssh/id_ed25519 -o ProxyCommand="ssh -W novinsazehmrv-spec:22 serveo.net" Hamid@novinsazehmrv-spec
  ```
- **ثبات:** چون از کلید SSH ثابت استفاده می‌شود و `serveo.net` نام مستعار (`alias`) ثابت می‌پذیرد، هر بار سرور جدید بالا بیاید، کاربر با همان کلید و همان نام متصل می‌شود.

### ۵. وقفه کم بین سرور قبلی و جدید (Low Gap)
- **روش:** اجرای همزمان دو Workflow با فاصله زمانی کم (`schedule: cron`) یا استفاده از `workflow_run` با Trigger متوالی.
- **بهینه:** Workflow جدید هر ۵ ساعت یکبار اجرا می‌شود (قبل از انقضای ۶ ساعته قبلی)، بنابراین همیشه حداقل یک سرور فعال وجود دارد و وقفه نزدیک به صفر است.

### ۶. خودکارسازی کامل
- تمام مراحل در `.github/workflows/main.yml` تعریف شده‌اند.
- هیچ مداخله دستی لازم نیست.

## محدودیت و راه‌حل
**محدودیت GitHub-hosted Runners:** هر Runner حداکثر ۶ ساعت زنده می‌ماند و سپس حذف می‌شود. این معماری این محدودیت را با بازیابی خودکار از Repository حل می‌کند.

**دسترسی به Repository:** Token فعلی (`github_pat_...`) دسترسی خواندن دارد اما برای ایجاد Repository جدید نیاز به Scope `repo` کامل دارد. لطفاً یکی از موارد زیر را انجام دهید:
1. ایجاد دستی Repository با نام `Linux-server` (۳۰ ثانیه)
2. ارسال Token با دسترسی کامل `repo` + `workflow`

پس از ایجاد Repository، تمام مراحل به صورت خودکار قابل اجرا هستند.

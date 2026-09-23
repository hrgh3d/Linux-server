#!/usr/bin/env bash
# cloudcli_patch.sh — v6.44
#
# چرا لازم است:
#   رابط CloudCLI روی سرور کاملاً سالم است (لوپ‌بک و 8443 هر دو ۲۰۰ و زیر
#   ۳۰ میلی‌ثانیه) ولی در مرورگر کاربر فقط می‌چرخد و باز نمی‌شود. دلیلش دو
#   چیز است که هیچ‌کدام از سمت سرور دیده نمی‌شوند:
#
#   ۱) فونت گوگل به‌صورت render-blocking در index.html:
#        <link href="https://fonts.googleapis.com/css2?family=Encode+Sans...">
#      مرورگر تا وقتی این استایل‌شیت را نگیرد صفحه را رنگ نمی‌کند. سرور ما
#      به گوگل دسترسی دارد، ولی مرورگر کاربر (ایران) ندارد ⇒ مرورگر تا
#      تایم‌اوت TCP منتظر می‌ماند و کاربر فقط اسپینر می‌بیند.
#      حذف می‌شود و به فونت‌های سیستمی برمی‌گردیم.
#
#   ۲) Service Worker (PWA) که نسخهٔ خراب قبلی را cache کرده:
#      حتی بعد از رفع مشکل، مرورگر همان نسخهٔ cache شده را بالا می‌آورد و
#      اسپینر ادامه پیدا می‌کند. sw.js با یک نسخهٔ خودحذف‌کن جایگزین می‌شود
#      تا مرورگرها ثبت قبلی را دور بیندازند. آفلاین‌بودن برای یک ابزار
#      ریموت روی Tailscale بی‌معنی است، پس چیزی از دست نمی‌رود.
#
# ⚠️ این فایل‌ها زیر node_modules هستند و در آرشیو نمی‌آیند، پس بعد از هر
#    چرخش رانر یا هر `npm install -g` دوباره برمی‌گردند. به همین دلیل این
#    اسکریپت از start-services.sh در هر بوت اجرا می‌شود و idempotent است.
set -u

PKG="${CLOUDCLI_PKG:-/usr/local/lib/node_modules/@cloudcli-ai/cloudcli}"
DIST="$PKG/dist"
IDX="$DIST/index.html"
SW="$DIST/sw.js"
MARK="cloudcli-patch-v6.44"
changed=0

[ -f "$IDX" ] || { echo "[cloudcli-patch] dist/index.html not found — skip"; exit 0; }

# --- ۱) حذف فونت گوگل ---------------------------------------------------
if grep -q "<link[^>]*fonts\.\(googleapis\|gstatic\)\.com" "$IDX" 2>/dev/null \
   || ! grep -q "$MARK" "$IDX" 2>/dev/null; then
  cp -n "$IDX" "$IDX.orig" 2>/dev/null || true
  python3 - "$IDX" "$MARK" <<'PY'
import re, sys
p, mark = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
# هر تگ <link ...> که به فونت گوگل اشاره دارد (حتی چندخطی)
s = re.sub(r'<link\b[^>]*?fonts\.(?:googleapis|gstatic)\.com[^>]*?>\s*', '', s, flags=re.S|re.I)
# کامنت راهنما که فونت‌ها را توضیح می‌داد
s = re.sub(r'<!--\s*Fonts:.*?-->\s*', '', s, flags=re.S|re.I)
if mark not in s:
    s = s.replace('</title>',
        '</title>\n    <!-- ' + mark + ': remote webfont links removed. They were '
        'render-blocking for users who cannot reach the Google font CDN; '
        'system fonts are used instead. -->\n'
        '    <style>:root{--cc-font:system-ui,-apple-system,"Segoe UI",Roboto,'
        '"Helvetica Neue",Arial,"Noto Sans","Vazirmatn",sans-serif}'
        'html,body{font-family:var(--cc-font)}</style>', 1)
open(p, "w", encoding="utf-8").write(s)
PY
  echo "[cloudcli-patch] index.html: Google Fonts links removed"
  changed=1
fi

# --- ۲) خنثی‌کردن Service Worker ----------------------------------------
if [ -f "$SW" ] && ! grep -q "$MARK" "$SW" 2>/dev/null; then
  cp -n "$SW" "$SW.orig" 2>/dev/null || true
  cat >"$SW" <<SWEOF
/* $MARK — self-unregistering stub.
   The original PWA service worker cached a build that never finished
   loading, so the UI kept spinning even after the server was fixed.
   Offline support is pointless for a remote tool reached over Tailscale,
   so this worker unregisters itself and clears every cache it owns. */
self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    try {
      const names = await caches.keys();
      await Promise.all(names.map((n) => caches.delete(n)));
      await self.registration.unregister();
      const cs = await self.clients.matchAll({ type: 'window' });
      cs.forEach((c) => c.navigate(c.url));
    } catch (err) { /* best effort */ }
  })());
});
SWEOF
  echo "[cloudcli-patch] sw.js: replaced with self-unregistering stub"
  changed=1
fi

if [ "$changed" = "1" ]; then
  echo "[cloudcli-patch] applied (originals kept as *.orig)"
else
  echo "[cloudcli-patch] already applied — nothing to do"
fi
exit 0

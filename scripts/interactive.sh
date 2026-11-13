#!/usr/bin/env bash
# جلسة تفاعلية: المحاكي بيظهر في نافذة على شاشة وهمية، ونفتحه من المتصفح عبر noVNC + نفق Cloudflare
set -u
MINUTES="${MINUTES:-30}"
mapfile -t APKS < "$APK_LIST"
AAPT="$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)aapt"

if [ "${#APKS[@]}" -gt 1 ]; then
  adb install-multiple -r -g -t "${APKS[@]}" || adb install -r -g -t "${APKS[0]}"
else
  adb install -r -g -t "${APKS[0]}"
fi
PKG=$("$AAPT" dump badging "${APKS[0]}" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)
[ -n "$PKG" ] && adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

umask 077
x11vnc -display :99 -passwd "$VNC_PASSWORD" -forever -shared -rfbport 5900 -bg -o /tmp/x11vnc.log
websockify --web /usr/share/novnc 6080 localhost:5900 >/tmp/ws.log 2>&1 &

curl -fsSL -o /tmp/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /tmp/cloudflared
/tmp/cloudflared tunnel --no-autoupdate --url http://localhost:6080 > /tmp/cf.log 2>&1 &

URL=""
for _ in $(seq 1 30); do
  URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf.log | head -1)
  [ -n "$URL" ] && break
  sleep 2
done

if [ -z "$URL" ]; then
  echo "فشل إنشاء النفق"; cat /tmp/cf.log; exit 1
fi

echo "=================================================="
echo "افتح: $URL/vnc.html?autoconnect=1&resize=scale"
echo "الباسورد: السر VNC_PASSWORD"
echo "=================================================="
{
  echo "### الجلسة التفاعلية"
  echo "افتح: $URL/vnc.html?autoconnect=1&resize=scale"
  echo "الباسورد هو قيمة السر VNC_PASSWORD. الجلسة تنتهي بعد $MINUTES دقيقة."
} >> "$GITHUB_STEP_SUMMARY"

sleep $((MINUTES * 60))

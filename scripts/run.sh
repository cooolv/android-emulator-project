#!/usr/bin/env bash
# بيشتغل جوه المحاكي. شغال مع أي APK.
set -u
mkdir -p out
APK_LIST="${APK_LIST:?APK_LIST مش متحدد}"
API="${API_LEVEL:-?}"
AAPT="$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)aapt"
esc() { sed 's/&/\&amp;/g;s/</\&lt;/g'; }

STATUS="OK"; FLOWS="-"; NOTES=""
mapfile -t APKS < "$APK_LIST"

# 1) استخراج بيانات التطبيق
PKG=""; BASE=""; LABEL=""; NATIVE=""
for f in "${APKS[@]}"; do
  line=$("$AAPT" dump badging "$f" 2>/dev/null | grep -m1 '^package:' || true)
  if [ -n "$line" ] && ! grep -q 'split=' <<<"$line"; then
    PKG=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$line")
    BASE="$f"
    LABEL=$("$AAPT" dump badging "$f" | sed -n "s/^application-label:'\(.*\)'/\1/p" | head -1)
    NATIVE=$("$AAPT" dump badging "$f" | grep -m1 '^native-code:' || true)
    break
  fi
done
[ -z "$LABEL" ] && LABEL="$PKG"
if [ -n "$NATIVE" ] && ! grep -q 'x86' <<<"$NATIVE"; then
  NOTES="التطبيق فيه مكتبات ARM بس، فهيشتغل بالترجمة وممكن يبقى بطيء أو يفشل."
fi
echo "Package: $PKG"

DEVICE="Android $(adb shell getprop ro.build.version.release | tr -d '\r') (API $API) - $(adb shell getprop ro.product.cpu.abi | tr -d '\r')"

if [ -z "$PKG" ]; then
  STATUS="NO_PACKAGE"
else
  # 2) التثبيت (يدعم split APKs)
  if [ "${#APKS[@]}" -gt 1 ]; then
    adb install-multiple -r -g -t "${APKS[@]}" 2> out/install_error.txt \
      || adb install -r -g -t "$BASE" 2> out/install_error.txt || STATUS="INSTALL_FAILED"
  else
    adb install -r -g -t "$BASE" 2> out/install_error.txt || STATUS="INSTALL_FAILED"
  fi
fi

if [ "$STATUS" = "OK" ]; then
  adb logcat -c
  adb shell screenrecord --time-limit 180 /sdcard/rec.mp4 &
  REC=$!
  sleep 2

  # 3) تشغيل بارد + قياس زمن الفتح
  ACT=$(adb shell cmd package resolve-activity --brief "$PKG" | tail -1 | tr -d '\r')
  : > out/metrics.txt
  if [[ "$ACT" == */* ]]; then
    adb shell am start -W -n "$ACT" | tr -d '\r' | grep -E 'TotalTime|WaitTime' >> out/metrics.txt || true
  else
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  fi
  sleep 8
  adb exec-out screencap -p > out/shot_0.png

  # 4) سيناريوهات Maestro (لو فولدر flows فيه ملفات)
  # أي متغير بيبدأ بـ FLOW_ بيتبعت للسيناريو (مثلاً ${FLOW_PHONE}) ويتخفى من اللوج
  FLOW_ARGS=(); FLOW_VALUES=()
  for k in $(compgen -e | grep '^FLOW_' || true); do
    v="${!k}"
    [ -n "$v" ] && { FLOW_ARGS+=(-e "$k=$v"); FLOW_VALUES+=("$v"); }
  done
  mask() {
    local line v
    while IFS= read -r line; do
      for v in "${FLOW_VALUES[@]+"${FLOW_VALUES[@]}"}"; do line="${line//"$v"/***}"; done
      printf '%s\n' "$line"
    done
  }
  if ls flows/*.y*ml >/dev/null 2>&1 && command -v maestro >/dev/null 2>&1; then
    ( cd out && timeout 900 maestro test -e APP_ID="$PKG" \
        ${FLOW_ARGS[@]+"${FLOW_ARGS[@]}"} --format=junit \
        --output=maestro-report.xml ../flows ) 2>&1 | mask > out/maestro.log
    [ "${PIPESTATUS[0]}" -eq 0 ] && FLOWS="PASSED" || FLOWS="FAILED"
    sleep 2
  fi

  # 5) ضغط عشوائي (Monkey). بيتعطل بـ SKIP_MONKEY=1 (مهم مع التطبيقات اللي فيها حساب حقيقي)
  if [ "${SKIP_MONKEY:-0}" = "1" ]; then
    adb exec-out screencap -p > out/shot_final.png
  else
    for i in 1 2 3 4 5; do
      adb shell monkey -p "$PKG" -s "$i" --throttle 700 \
        --pct-syskeys 0 --pct-appswitch 0 --ignore-timeouts 40 >/dev/null 2>&1
      adb exec-out screencap -p > "out/shot_$i.png"
    done
  fi

  adb shell dumpsys meminfo "$PKG" | tr -d '\r' | grep -m1 'TOTAL' | sed 's/^ *//' | sed 's/^/Memory: /' >> out/metrics.txt || true

  adb shell pkill -2 screenrecord >/dev/null 2>&1
  sleep 4
  adb pull /sdcard/rec.mp4 out/recording.mp4 >/dev/null 2>&1
  kill "$REC" 2>/dev/null

  # 6) تحليل السجلات
  adb logcat -d > out/logcat.txt
  grep -A 15 "FATAL EXCEPTION" out/logcat.txt | head -60 > out/crash.txt
  grep -E "ANR in " out/logcat.txt | head -5 > out/anr.txt
  [ -s out/anr.txt ] && STATUS="ANR"
  [ -s out/crash.txt ] && STATUS="CRASHED"
  [ "$STATUS" = "OK" ] && [ "$FLOWS" = "FAILED" ] && STATUS="FLOWS_FAILED"
fi

echo "$STATUS" > out/status.txt

# 7) صفحة النتائج
{
  echo "<!doctype html><html lang='ar' dir='rtl'><meta charset='utf-8'>"
  echo "<meta name='viewport' content='width=device-width,initial-scale=1'>"
  echo "<title>$LABEL - API $API</title><style>"
  echo "body{font-family:system-ui,sans-serif;max-width:1000px;margin:auto;padding:16px}"
  echo ".g{display:flex;flex-wrap:wrap;gap:10px}.g img{height:420px;border:1px solid #888;border-radius:8px}"
  echo "pre{background:#8882;padding:10px;overflow:auto;direction:ltr}video{max-height:560px}"
  echo "table td{padding:2px 12px}</style>"
  echo "<h1>$LABEL</h1><table>"
  echo "<tr><td>Package</td><td>$PKG</td></tr><tr><td>الجهاز</td><td>$DEVICE</td></tr>"
  echo "<tr><td>الحالة</td><td><b>$STATUS</b></td></tr><tr><td>سيناريوهات Maestro</td><td>$FLOWS</td></tr></table>"
  [ -n "$NOTES" ] && echo "<p>⚠️ $NOTES</p>"
  [ -s out/metrics.txt ] && { echo "<h2>قياسات</h2><pre>"; esc < out/metrics.txt; echo "</pre>"; }
  [ -f out/recording.mp4 ] && echo "<h2>الفيديو</h2><video src='recording.mp4' controls></video>"
  echo "<h2>اللقطات</h2><div class='g'>"
  for f in out/shot_*.png out/flow_*.png; do [ -f "$f" ] && echo "<img src='$(basename "$f")'>"; done
  echo "</div>"
  [ -s out/crash.txt ] && { echo "<h2>Crash</h2><pre>"; esc < out/crash.txt; echo "</pre>"; }
  [ -s out/anr.txt ] && { echo "<h2>ANR</h2><pre>"; esc < out/anr.txt; echo "</pre>"; }
  [ -s out/install_error.txt ] && { echo "<h2>خطأ التثبيت</h2><pre>"; esc < out/install_error.txt; echo "</pre>"; }
  [ -s out/maestro.log ] && { echo "<h2>Maestro</h2><pre>"; esc < out/maestro.log; echo "</pre>"; }
  echo "<p><a href='logcat.txt'>logcat كامل</a></p></html>"
} > out/index.html
exit 0

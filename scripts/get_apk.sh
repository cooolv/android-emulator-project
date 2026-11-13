#!/usr/bin/env bash
# بيجهّز الـ APK من رابط أو من فولدر apks/، ويدعم APK عادي و .xapk و .apks
set -euo pipefail
mkdir -p work

if [ -n "${APK_URL:-}" ]; then
  curl -fL --retry 3 "$APK_URL" -o work/input.bin
  SRC=work/input.bin
else
  SRC=$(git log -1 --format= --name-only -- 'apks/*.apk' 'apks/*.xapk' 'apks/*.apks' | head -1 || true)
  if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    echo "مفيش APK. حط ملف داخل فولدر apks/ أو اديني رابط." >&2
    exit 1
  fi
fi

unzip -Z1 "$SRC" > work/names.txt
if grep -qx 'AndroidManifest.xml' work/names.txt; then
  cp "$SRC" work/app.apk
  echo "$PWD/work/app.apk" > work/list.txt
else
  mkdir -p work/splits
  unzip -q -o "$SRC" -d work/splits
  find "$PWD/work/splits" -name '*.apk' | sort > work/list.txt
  [ -s work/list.txt ] || { echo "مفيش ملفات APK جوه الأرشيف" >&2; exit 1; }
fi

echo "ملفات APK:"; cat work/list.txt
echo "APK_LIST=$PWD/work/list.txt" >> "$GITHUB_ENV"

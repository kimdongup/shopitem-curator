#!/bin/sh
set -eu
# Fixed, installed and verified executables only. ldd returns their transitive
# loader/library dependencies; dereference links so each SONAME is available.
mkdir -p /runtime/usr/bin /runtime/usr/share/tessdata
cp /usr/bin/tesseract /usr/bin/avifdec /runtime/usr/bin/
cp /usr/share/tessdata/eng.traineddata /runtime/usr/share/tessdata/
ldd /usr/bin/tesseract /usr/bin/avifdec \
  | awk '$2 == "=>" { print $3 } $1 ~ /^\// && NF > 1 { print $1 }' \
  | sort -u \
  | while IFS= read -r library; do
      test -f "$library"
      # Minimus /lib and /lib64 point to /usr/lib. Preserve those symlinks
      # in the final image instead of overlaying them with directories.
      destination=$(readlink -f "$(dirname "$library")")
      mkdir -p "/runtime$destination"
      cp -L "$library" "/runtime$destination/"
    done

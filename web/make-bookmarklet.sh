#!/bin/sh
# Turns ytm-eq.js into a bookmarklet (a javascript: URL) and copies it to the clipboard.
set -e

cd "$(dirname "$0")"
python3 -I -c '
import sys, urllib.parse
source = open("ytm-eq.js").read()
sys.stdout.write("javascript:" + urllib.parse.quote(source, safe=""))
' > bookmarklet.txt

pbcopy < bookmarklet.txt
echo "Wrote $(pwd)/bookmarklet.txt ($(wc -c < bookmarklet.txt | tr -d " ") characters) and copied it to the clipboard"

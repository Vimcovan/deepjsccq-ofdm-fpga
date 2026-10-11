"""On a PC with internet: download the .deb files listed by list_uris.sh and verify size + checksum.
    python fetch_debs.py uris.txt debs/
Exit code 1 if any file failed; failed URLs are listed (a 404 means the board's package index is older than the
mirror: see SKILL.md, "Index too old")."""
import hashlib
import os
import sys
import urllib.request

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
bad = []
lines = [l.split() for l in open(src, encoding="utf-8-sig") if l.startswith("'http")]
for url, name, size, hsum in lines:
    url = url.strip("'")
    algo, want = hsum.split(":", 1)
    algo = {"MD5Sum": "md5", "SHA1": "sha1", "SHA256": "sha256", "SHA512": "sha512"}[algo]
    path = os.path.join(out, name)
    try:
        if not os.path.exists(path) or os.path.getsize(path) != int(size):
            urllib.request.urlretrieve(url, path)
        data = open(path, "rb").read()
        ok = len(data) == int(size) and hashlib.new(algo, data).hexdigest() == want
    except Exception as e:                      # network error, 404
        print("FAIL", url, e); bad.append(url); continue
    print("ok  " if ok else "BAD ", name, size)
    if not ok:
        bad.append(url)
print(f"{len(lines) - len(bad)}/{len(lines)} files ok")
sys.exit(1 if bad else 0)

#!/usr/bin/env python3
"""Copy every Storage object from Supabase Cloud to the self-hosted stack.

Runs on the server. The object list comes from the restored storage.objects
table (same rows as cloud). For each object: download from cloud with the
service key, check size and MD5 (eTag) against the row's metadata, upload to
the local Storage API at the same bucket/path with the same content type and
cache-control, then read it back from local and compare SHA-256.

    copy_storage.py <cloud-url> <local-url> <objects.tsv>

The service-role key is read from SERVICE_ROLE_KEY (identical on both sides:
same JWT secret). Exits non-zero if any object fails.
"""
import concurrent.futures as cf
import hashlib
import os
import sys
import time
import urllib.parse
import urllib.request

cloud, local, listing = sys.argv[1].rstrip("/"), sys.argv[2].rstrip("/"), sys.argv[3]
key = os.environ["SERVICE_ROLE_KEY"]
auth = {"Authorization": "Bearer " + key, "apikey": key}


def request(method, url, data=None, headers=None, tries=5):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, data=data, method=method, headers={**auth, **(headers or {})})
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 or i == tries - 1:
                raise RuntimeError(f"{method} {url} -> {e.code} {e.read()[:200]!r}") from None
        except Exception:
            if i == tries - 1:
                raise
        time.sleep(2 ** i)


def copy(row):
    bucket, name, mime, cache, size, etag = row
    path = urllib.parse.quote(f"{bucket}/{name}")
    body = request("GET", f"{cloud}/storage/v1/object/authenticated/{path}")
    if size and int(size) != len(body):
        raise RuntimeError(f"{bucket}/{name}: size {len(body)} != metadata {size}")
    if etag and "-" not in etag and hashlib.md5(body).hexdigest() != etag.strip('"'):
        raise RuntimeError(f"{bucket}/{name}: md5 differs from eTag")
    headers = {"x-upsert": "true", "Content-Type": mime or "application/octet-stream"}
    if cache:
        # Cloud metadata holds either "3600" or a full directive ("max-age=3600").
        headers["Cache-Control"] = cache if "=" in cache else f"max-age={cache}"
    request("POST", f"{local}/storage/v1/object/{path}", data=body, headers=headers)
    back = request("GET", f"{local}/storage/v1/object/authenticated/{path}")
    if hashlib.sha256(back).digest() != hashlib.sha256(body).digest():
        raise RuntimeError(f"{bucket}/{name}: read-back checksum differs")
    return len(body)


rows = [line.rstrip("\n").split("\t") for line in open(listing) if line.strip()]
ok, failed, total = 0, [], 0
with cf.ThreadPoolExecutor(6) as ex:
    futures = {ex.submit(copy, r): r for r in rows}
    for f in cf.as_completed(futures):
        try:
            total += f.result(); ok += 1
        except Exception as e:
            failed.append(str(e))
print(f"objects: {len(rows)}  copied+verified: {ok}  failed: {len(failed)}  bytes: {total}")
for e in failed[:20]:
    print("  FAIL", e)
sys.exit(1 if failed else 0)

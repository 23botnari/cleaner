#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Curățenie Mac — vezi ce ocupă loc și curăță prin click-uri.

Rulează local: pornește un mic server pe 127.0.0.1 și deschide interfața în browser.
Nimic nu pleacă de pe Mac.

Pornire:  python3 curatenie_mac.py
Oprire:   Ctrl+C în Terminal
"""
import fnmatch
import glob
import json
import os
import secrets
import shutil
import subprocess
import sys
import threading
import time
import webbrowser
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HOME = os.path.expanduser("~")
REAL_HOME = os.path.realpath(HOME)
TOKEN = secrets.token_urlsafe(18)
ALLOWED_HOSTS = set()


def hp(*parts):
    return os.path.join(HOME, *parts)


# Foldere care nu se șterg niciodată, indiferent de cerere.
PROTECTED = {os.path.realpath(p) for p in [
    HOME, hp("Library"), hp("Library", "Application Support"), hp("Library", "Group Containers"),
    hp("Library", "Containers"), hp("Library", "Preferences"), hp("Library", "Keychains"),
    hp("Library", "Mail"), hp("Library", "Messages"), hp("Library", "Mobile Documents"),
    hp("Library", "Developer"), hp(".ssh"), hp(".gnupg"), hp(".Trash"),
]}


class UserErr(Exception):
    pass


# ---------------------------------------------------------------- utilitare

def existing(*paths):
    return [p for p in paths if os.path.lexists(p)]


def children(d):
    try:
        return [os.path.join(d, n) for n in os.listdir(d)]
    except Exception:
        return []


def files_matching(d, patterns):
    out = []
    for root, _dirs, files in os.walk(d):
        for f in files:
            if any(fnmatch.fnmatch(f.lower(), p) for p in patterns):
                out.append(os.path.join(root, f))
    return out


def du_many(paths):
    """Mărimea reală pe disc (bytes) a mai multor căi, fără dubluri."""
    paths = existing(*paths)
    total = 0
    for i in range(0, len(paths), 200):
        chunk = paths[i:i + 200]
        try:
            r = subprocess.run(["du", "-skc", "--"] + chunk, capture_output=True, text=True, timeout=1200)
            lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
            if lines:
                total += int(lines[-1].split()[0]) * 1024
        except Exception:
            pass
    return total


def is_running(patterns):
    for p in patterns or []:
        try:
            if subprocess.run(["pgrep", "-f", p], capture_output=True).returncode == 0:
                return True
        except Exception:
            pass
    return False


def under_home(real):
    return real == REAL_HOME or real.startswith(REAL_HOME + os.sep)


def deletable(p):
    ap = os.path.abspath(p)
    full = os.path.join(os.path.realpath(os.path.dirname(ap)), os.path.basename(ap))
    if not under_home(full) or full == REAL_HOME or full in PROTECTED:
        return False
    rel = os.path.relpath(full, REAL_HOME)
    # Foldere vizibile direct în home (Desktop, Documents etc.) rămân neatinse.
    if os.sep not in rel and not rel.startswith("."):
        return False
    return True


# ---------------------------------------------------------------- ținte

TARGETS = {}
LOCK = threading.Lock()
_counter = [0]


def nid(prefix):
    _counter[0] += 1
    return "%s%d" % (prefix, _counter[0])


def add(lst, **t):
    t.setdefault("id", nid("t"))
    t.setdefault("risk", "safe")
    t.setdefault("procs", [])
    t.setdefault("cmds", [])
    t.setdefault("size_paths", [])
    t.setdefault("overlap", False)
    lst.append(t)


def static_targets():
    L = []
    AS = hp("Library", "Application Support")

    g = "Aplicații de chat"
    add(L, id="whatsapp", group=g, name="WhatsApp: date locale (media + chat-uri)", risk="care",
        desc="Toate pozele, video-urile și fișierele primite pe WhatsApp, salvate pe Mac. "
             "Înainte: în WhatsApp → Settings → Account → Log out, apoi închide aplicația. "
             "La reconectare, chat-urile recente revin de pe telefon; media veche rămâne doar pe telefon.",
        resolve=lambda: existing(hp("Library", "Group Containers", "group.net.whatsapp.WhatsApp.shared")),
        procs=["WhatsApp.app/Contents/MacOS"], app_name="WhatsApp")
    add(L, id="telegram", group=g, name="Telegram: media în cache",
        desc="Fișiere descărcate din chat-uri. Rămân în cloud-ul Telegram și se descarcă din nou la nevoie.",
        resolve=lambda: existing(os.path.join(AS, "Telegram Desktop", "tdata", "user_data")),
        procs=["Telegram.app/Contents/MacOS"], app_name="Telegram")
    add(L, id="discord", group=g, name="Discord: cache",
        desc="Imagini și fișiere temporare. Discord le refolosește doar ca să încarce mai repede.",
        resolve=lambda: existing(*[os.path.join(AS, "discord", x) for x in ("Cache", "Code Cache", "GPUCache")]),
        procs=["Discord.app/Contents/MacOS"], app_name="Discord")

    g = "Dezvoltare"
    add(L, id="npm", group=g, name="npm: cache",
        desc="Pachete descărcate anterior. Se redescarcă automat la următorul npm install.",
        resolve=lambda: existing(hp(".npm", "_cacache"), hp(".npm", "_npx"), hp(".npm", "_logs")))
    add(L, id="gradle", group=g, name="Gradle: cache și distribuții",
        desc="Dependențe Android și versiuni Gradle descărcate. Primul build după curățare va dura mai mult.",
        resolve=lambda: existing(hp(".gradle", "caches"), hp(".gradle", "wrapper", "dists"), hp(".gradle", "daemon")),
        procs=["GradleDaemon"], app_name="Android Studio / Gradle (sau rulează ./gradlew --stop)")
    add(L, id="pnpm", group=g, name="pnpm: store",
        desc="Depozitul global de pachete pnpm. Se reface la următorul pnpm install.",
        resolve=lambda: existing(hp("Library", "pnpm", "store")))
    dev = hp("Library", "Developer")
    add(L, id="deriveddata", group=g, name="Xcode: DerivedData",
        desc="Fișiere de build. Xcode le regenerează la următorul build.",
        resolve=lambda: children(os.path.join(dev, "Xcode", "DerivedData")),
        procs=["Xcode.app/Contents/MacOS/Xcode"], app_name="Xcode")
    add(L, id="devicesupport", group=g, name="Xcode: suport pentru dispozitive",
        desc="Simboluri copiate de pe iPhone-urile conectate vreodată. Se recopiază când conectezi din nou un dispozitiv.",
        resolve=lambda: children(os.path.join(dev, "Xcode", "iOS DeviceSupport"))
        + children(os.path.join(dev, "Xcode", "watchOS DeviceSupport")),
        procs=["Xcode.app/Contents/MacOS/Xcode"], app_name="Xcode")
    add(L, id="archives", group=g, name="Xcode: arhive", risk="care",
        desc="Build-uri trimise în App Store / TestFlight. Păstrează-le dacă ai nevoie de rapoarte de crash simbolizate pentru versiuni publicate.",
        resolve=lambda: children(os.path.join(dev, "Xcode", "Archives")),
        procs=["Xcode.app/Contents/MacOS/Xcode"], app_name="Xcode")

    g = "Simulatoare iOS"
    cs = os.path.join(dev, "CoreSimulator")
    add(L, id="simcaches", group=g, name="Simulatoare: cache",
        desc="Fișiere temporare ale simulatoarelor. Se refac automat.",
        resolve=lambda: children(os.path.join(cs, "Caches")))
    if shutil.which("xcrun") and os.path.isdir(os.path.join(cs, "Devices")):
        add(L, id="simerase", group=g, name="Simulatoare: resetează toate", risk="care",
            desc="Șterge aplicațiile și datele din toate simulatoarele și elimină simulatoarele pentru versiuni iOS care nu mai există. "
                 "Simulatoarele rămân în listă, ca noi.",
            cmds=[["sh", "-c", "xcrun simctl shutdown all >/dev/null 2>&1; true"],
                  ["xcrun", "simctl", "delete", "unavailable"],
                  ["xcrun", "simctl", "erase", "all"]],
            size_paths=[os.path.join(cs, "Devices")],
            procs=["Simulator.app/Contents/MacOS"], app_name="Simulator")

    g = "Sistem și altele"
    add(L, id="wallpapers", group=g, name="Wallpapere Aerial descărcate",
        desc="Video-urile pentru wallpapere și screensaver-e animate. Cel folosit acum se descarcă din nou automat.",
        resolve=lambda: files_matching(os.path.join(AS, "com.apple.wallpaper"), ["*.mov", "*.mp4"]))
    add(L, id="dockerinstall", group=g, name="Docker: kit de instalare rămas",
        desc="Fișiere rămase după instalarea Docker Desktop. Docker funcționează și fără ele.",
        resolve=lambda: existing(os.path.join(AS, "com.docker.install")))
    add(L, id="vscode", group=g, name="VS Code: cache",
        desc="Cache-uri și log-uri. Setările, extensiile și proiectele nu sunt atinse.",
        resolve=lambda: existing(*[os.path.join(AS, "Code", x) for x in
                                   ("Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs")]),
        procs=["Visual Studio Code.app/Contents/MacOS"], app_name="VS Code")
    add(L, id="usercaches", group=g, name="Cache-uri aplicații (~/Library/Caches)", risk="care",
        desc="Cache-urile tuturor aplicațiilor (browsere, Homebrew, CocoaPods etc.). Se refac singure; unele aplicații pot porni mai încet o dată. "
             "Închide cât mai multe aplicații înainte și repornește Mac-ul după.",
        resolve=lambda: children(hp("Library", "Caches")))
    add(L, id="logs", group=g, name="Log-uri",
        desc="Jurnale de erori și diagnostic ale aplicațiilor.",
        resolve=lambda: children(hp("Library", "Logs")))
    add(L, id="trash", group=g, name="Coșul (Bin)", risk="care",
        desc="Golește Coșul definitiv. Ce e acolo nu mai poate fi recuperat.",
        resolve=lambda: children(hp(".Trash")))
    return L


def android_targets():
    L = []
    g = "Android"
    for avd in sorted(glob.glob(hp(".android", "avd", "*.avd"))):
        name = os.path.basename(avd)[:-4].replace("_", " ")
        snaps = os.path.join(avd, "snapshots")
        if os.path.isdir(snaps):
            add(L, group=g, name="Emulator %s: snapshot-uri" % name,
                desc="Stări salvate pentru Quick Boot. Emulatorul pornește la rece prima dată; aplicațiile și datele din el rămân.",
                resolve=(lambda s=snaps: children(s)), procs=["qemu-system"], app_name="emulatorul Android")
        add(L, group=g, name="Emulator %s: șterge complet" % name, risk="care", overlap=True,
            desc="Șterge emulatorul cu tot cu datele lui. Îl poți crea din nou din Android Studio → Device Manager.",
            resolve=(lambda a=avd: existing(a, a[:-4] + ".ini")), procs=["qemu-system"], app_name="emulatorul Android")
    sdk = os.environ.get("ANDROID_HOME") or hp("Library", "Android", "sdk")
    base = os.path.join(sdk, "system-images")
    for img in sorted(glob.glob(os.path.join(base, "*", "*", "*"))):
        add(L, group=g, name="Imagine de sistem %s" % os.path.relpath(img, base), risk="care",
            desc="Necesară emulatoarelor pe versiunea asta de Android. Șterge-o doar dacă niciun emulator nu o folosește; se reinstalează din SDK Manager.",
            resolve=(lambda i=img: existing(i)))
    return L


def sim_runtime_targets():
    if not shutil.which("xcrun"):
        return []
    try:
        r = subprocess.run(["xcrun", "simctl", "runtime", "list", "-j"], capture_output=True, text=True, timeout=60)
        data = json.loads(r.stdout)
    except Exception:
        return []
    L = []
    for rt in (data.values() if isinstance(data, dict) else data):
        if not isinstance(rt, dict) or not rt.get("identifier"):
            continue
        plat = rt.get("platformIdentifier", "").lower()
        label = ("watchOS" if "watch" in plat else "tvOS" if "appletv" in plat
                 else "visionOS" if "xr" in plat else "iOS")
        add(L, group="Simulatoare iOS", name="Runtime %s %s" % (label, rt.get("version", "?")), risk="care",
            desc="Sistemul pentru simulatoarele pe această versiune. Păstrează doar ce folosești la testare; "
                 "se descarcă din nou din Xcode → Settings → Components.",
            cmds=[["xcrun", "simctl", "runtime", "delete", rt["identifier"]]],
            fixed_size=int(rt.get("sizeBytes") or 0),
            procs=["Simulator.app/Contents/MacOS"], app_name="Simulator")
    return L


def node_modules_targets():
    L = []
    skip_top = {"Library", "Pictures", "Music", "Movies", "Applications", "Public"}
    for root, dirs, _files in os.walk(HOME):
        depth = 0 if root == HOME else os.path.relpath(root, HOME).count(os.sep) + 1
        keep = []
        for d in dirs:
            full = os.path.join(root, d)
            if d == "node_modules":
                pkg = os.path.join(root, "package.json")
                try:
                    mt = os.path.getmtime(pkg if os.path.exists(pkg) else root)
                except Exception:
                    mt = 0
                add(L, group="node_modules din proiecte", name=os.path.relpath(root, HOME),
                    desc="Proiect modificat ultima dată pe %s. Se reinstalează cu npm / yarn / pnpm install."
                         % time.strftime("%d.%m.%Y", time.localtime(mt)),
                    resolve=(lambda p=full: existing(p)))
            elif d.startswith(".") or os.path.islink(full) or (root == HOME and d in skip_top):
                continue
            elif depth < 7:
                keep.append(d)
        dirs[:] = keep
    return L


def visible(t):
    if "fixed_size" in t:
        return t["fixed_size"] > 0
    if t.get("resolve") and t["resolve"]():
        return True
    return bool(existing(*t["size_paths"]))


def public(t):
    return {k: t.get(k) for k in ("id", "group", "name", "desc", "risk", "app_name", "overlap")}


def target_size(t):
    if "fixed_size" in t:
        return t["fixed_size"]
    paths = t["resolve"]() if t.get("resolve") else []
    return du_many(paths + list(t["size_paths"]))


def clean(t):
    if is_running(t["procs"]):
        raise UserErr("Închide %s înainte de curățare." % (t.get("app_name") or "aplicația"))
    before = target_size(t)
    errors = []
    for p in (t["resolve"]() if t.get("resolve") else []):
        if not deletable(p):
            errors.append("Sărit (protejat): " + p)
            continue
        r = subprocess.run(["rm", "-rf", "--", p], capture_output=True, text=True)
        if r.returncode != 0:
            errors += [l for l in r.stderr.splitlines() if l.strip()][:3]
    for c in t["cmds"]:
        try:
            r = subprocess.run(c, capture_output=True, text=True, timeout=1800)
            if r.returncode != 0:
                errors.append((r.stderr or r.stdout).strip()[:300] or "Comanda a eșuat: " + " ".join(c))
        except Exception as e:
            errors.append(str(e))
    if "fixed_size" in t and not errors:
        t["fixed_size"] = 0
    after = target_size(t)
    return {"freed": max(0, before - after), "size": after, "errors": errors[:12]}


# ---------------------------------------------------------------- explorator

def browse(path):
    rp = os.path.realpath(path or HOME)
    if not under_home(rp):
        raise UserErr("Poți explora doar folderul tău de utilizator.")
    try:
        entries = list(os.scandir(rp))
    except PermissionError:
        raise UserErr("Acces refuzat. Dă Terminalului Full Disk Access: System Settings → Privacy & Security → Full Disk Access.")
    except FileNotFoundError:
        raise UserErr("Folderul nu mai există.")

    def info(e):
        try:
            isdir = e.is_dir(follow_symlinks=False)
            size = du_many([e.path]) if isdir else e.stat(follow_symlinks=False).st_blocks * 512
        except Exception:
            isdir, size = False, 0
        return {"name": e.name, "path": e.path, "dir": isdir, "size": size, "protected": not deletable(e.path)}

    with ThreadPoolExecutor(8) as ex:
        items = list(ex.map(info, entries))
    items.sort(key=lambda x: -x["size"])
    return {"path": rp, "home": REAL_HOME, "rel": os.path.relpath(rp, REAL_HOME),
            "items": items, "total": sum(i["size"] for i in items)}


def move_to_trash(p):
    full = os.path.join(os.path.realpath(os.path.dirname(os.path.abspath(p))), os.path.basename(p))
    if not os.path.lexists(full):
        raise UserErr("Elementul nu mai există.")
    if not deletable(full):
        raise UserErr("Elementul acesta e protejat.")
    trash = hp(".Trash")
    dest = os.path.join(trash, os.path.basename(full))
    if os.path.lexists(dest):
        base, ext = os.path.splitext(os.path.basename(full))
        dest = os.path.join(trash, "%s %s%s" % (base, time.strftime("%H.%M.%S"), ext))
    try:
        os.rename(full, dest)
        return
    except OSError:
        pass
    r = subprocess.run(["osascript", "-e", "on run argv", "-e", "set f to POSIX file (item 1 of argv)",
                        "-e", 'tell application "Finder" to delete f', "-e", "end run", full],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise UserErr("Nu am putut muta la Coș: " + r.stderr.strip()[:200])


# ---------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj, ctype="application/json; charset=utf-8"):
        body = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _ok(self):
        if self.headers.get("Host", "") not in ALLOWED_HOSTS:
            return False
        q = parse_qs(urlparse(self.path).query)
        tok = self.headers.get("X-Token") or q.get("t", [""])[0]
        return secrets.compare_digest(tok, TOKEN)

    def _q(self, k):
        return parse_qs(urlparse(self.path).query).get(k, [""])[0]

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def _run(self, fn):
        try:
            self._send(200, fn())
        except UserErr as e:
            self._send(400, {"error": str(e)})
        except Exception as e:
            self._send(500, {"error": "Eroare neașteptată: %s" % e})

    def do_GET(self):
        if not self._ok():
            return self._send(403, {"error": "Acces interzis"})
        route = urlparse(self.path).path
        if route == "/":
            return self._send(200, PAGE.replace("__TOKEN__", TOKEN).encode(), "text/html; charset=utf-8")
        if route == "/api/disk":
            return self._run(lambda: dict(zip(("total", "used", "free"), shutil.disk_usage(HOME))))
        if route == "/api/targets":
            def build():
                ts = [t for t in static_targets() + sim_runtime_targets() + android_targets() if visible(t)]
                with LOCK:
                    TARGETS.clear()
                    TARGETS.update({t["id"]: t for t in ts})
                return {"targets": [public(t) for t in ts]}
            return self._run(build)
        if route == "/api/node_modules":
            def build_nm():
                ts = node_modules_targets()
                with LOCK:
                    TARGETS.update({t["id"]: t for t in ts})
                return {"targets": [public(t) for t in ts]}
            return self._run(build_nm)
        if route == "/api/size":
            def size():
                t = TARGETS.get(self._q("id"))
                if not t:
                    raise UserErr("Element necunoscut; scanează din nou.")
                return {"size": target_size(t), "running": is_running(t["procs"])}
            return self._run(size)
        if route == "/api/browse":
            return self._run(lambda: browse(self._q("path")))
        self._send(404, {"error": "Nu există"})

    def do_POST(self):
        if not self._ok():
            return self._send(403, {"error": "Acces interzis"})
        route = urlparse(self.path).path
        if route == "/api/clean":
            def do():
                t = TARGETS.get(self._body().get("id"))
                if not t:
                    raise UserErr("Element necunoscut; scanează din nou.")
                return clean(t)
            return self._run(do)
        if route == "/api/trash":
            return self._run(lambda: (move_to_trash(self._body().get("path", "")), {"ok": True})[1])
        if route == "/api/reveal":
            def reveal():
                p = os.path.realpath(self._body().get("path", ""))
                if not under_home(p):
                    raise UserErr("Cale invalidă.")
                subprocess.run(["open", "-R", p])
                return {"ok": True}
            return self._run(reveal)
        self._send(404, {"error": "Nu există"})


PAGE = r'''<!doctype html>
<html lang="ro"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Curățenie Mac</title>
<style>
:root{--bg:#eceef1;--panel:#fff;--line:#dcdfe4;--text:#1a1d21;--muted:#6b717a;--accent:#2563eb;
 --danger:#d92d20;--warn:#b54708;--warnbg:#fef0c7;--ok:#067647;--okbg:#dcfae6;--track:#e3e6ea;
 --used:#8b929c;--free:#e3e6ea;--rec:#12b76a}
@media (prefers-color-scheme:dark){:root{--bg:#17191c;--panel:#212428;--line:#33373d;--text:#eef0f2;
 --muted:#9aa0a8;--accent:#5b8def;--danger:#f97066;--warn:#fdb022;--warnbg:#3a2c0d;--ok:#47cd89;
 --okbg:#0f2e1f;--track:#2e3237;--used:#5d636b;--free:#2e3237;--rec:#32d583}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:940px;margin:0 auto;padding:32px 22px 90px}
h1{font-size:15px;font-weight:600;margin:0 0 22px;color:var(--muted)}
.hero{margin-bottom:26px}
.free{font-size:56px;font-weight:700;letter-spacing:-.035em;line-height:1;font-variant-numeric:tabular-nums}
.free small{font-size:20px;font-weight:500;letter-spacing:0;color:var(--muted);margin-left:8px}
.strip{display:flex;height:34px;border-radius:9px;overflow:hidden;background:var(--free);margin:18px 0 10px}
.strip i{display:block;height:100%;transition:width .6s ease}
#sUsed{background:var(--used)}
#sRec{background:repeating-linear-gradient(-45deg,var(--rec) 0 7px,color-mix(in srgb,var(--rec) 70%,transparent) 7px 14px)}
.legend{display:flex;gap:20px;flex-wrap:wrap;color:var(--muted);font-size:13px;font-variant-numeric:tabular-nums}
.legend b{color:var(--text);font-weight:600}
.dot{display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:6px;vertical-align:0}
.bar{display:flex;justify-content:space-between;align-items:center;gap:12px;margin:0 0 18px;flex-wrap:wrap}
.seg{display:inline-flex;background:var(--track);border-radius:9px;padding:3px}
.seg button{border:0;background:none;color:var(--muted);font:inherit;font-weight:500;padding:6px 14px;border-radius:7px;cursor:pointer}
.seg button.on{background:var(--panel);color:var(--text);box-shadow:0 1px 2px rgba(0,0,0,.12)}
section{margin-bottom:22px}
h2{display:flex;justify-content:space-between;font-size:13px;font-weight:600;color:var(--muted);margin:0 0 8px 4px}
h2 .gsum{font-variant-numeric:tabular-nums;margin-right:4px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.row{display:grid;grid-template-columns:1fr 150px 122px;gap:18px;align-items:center;padding:14px 16px;border-top:1px solid var(--line)}
.row:first-child{border-top:0}
.row.is-done{opacity:.55}
.name{font-weight:600;overflow-wrap:anywhere}
.name a{color:var(--text);text-decoration:none;cursor:pointer}
.name a:hover{color:var(--accent)}
.desc{color:var(--muted);font-size:13px;margin-top:2px;max-width:62ch}
.warn{color:var(--warn);font-size:13px;margin-top:5px;font-weight:500}
.badge{font-size:11px;font-weight:600;padding:1px 7px;border-radius:5px;margin-left:6px;vertical-align:1px;white-space:nowrap}
.badge.safe{background:var(--okbg);color:var(--ok)}
.badge.care{background:var(--warnbg);color:var(--warn)}
.size{font-weight:600;font-size:15px;text-align:right;font-variant-numeric:tabular-nums;margin-bottom:5px}
.track{height:5px;background:var(--track);border-radius:3px;overflow:hidden}
.track i{display:block;height:100%;background:var(--used);border-radius:3px}
.act{display:flex;justify-content:flex-end;gap:6px}
.btn{font:inherit;font-size:13px;font-weight:500;border:1px solid var(--line);background:var(--panel);color:var(--text);padding:6px 12px;border-radius:8px;cursor:pointer;white-space:nowrap}
.btn:hover:not(:disabled){border-color:var(--muted)}
.btn:disabled{opacity:.5;cursor:default}
.btn:focus-visible,.seg button:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.btn.danger{background:var(--danger);border-color:var(--danger);color:#fff}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.done{color:var(--ok);font-weight:600;font-size:13px}
.empty{color:var(--muted);padding:26px 16px;text-align:center;margin:0}
.crumbs{display:flex;flex-wrap:wrap;align-items:center;gap:4px;margin:0 0 10px 4px;font-size:14px}
.crumbs a{color:var(--accent);cursor:pointer;text-decoration:none}
.crumbs .sep{color:var(--muted)}
.crumbs .gsum{margin-left:auto;color:var(--muted);font-variant-numeric:tabular-nums}
.spin{display:inline-block;width:12px;height:12px;border:2px solid var(--track);border-top-color:var(--muted);border-radius:50%;animation:sp .8s linear infinite;vertical-align:-1px;margin-right:6px}
@keyframes sp{to{transform:rotate(360deg)}}
#modal{position:fixed;inset:0;background:rgba(0,0,0,.4);display:flex;align-items:center;justify-content:center;padding:20px;z-index:10}
#modal[hidden]{display:none}
.mbox{background:var(--panel);border-radius:14px;max-width:470px;width:100%;padding:22px;box-shadow:0 20px 60px rgba(0,0,0,.3)}
.mbox h3{margin:0 0 10px;font-size:17px;overflow-wrap:anywhere}
.mbox p{margin:0 0 10px;color:var(--muted)}
.mbox pre{background:var(--bg);padding:10px;border-radius:8px;font-size:12px;white-space:pre-wrap;max-height:200px;overflow:auto}
.mact{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
#toast{position:fixed;left:50%;bottom:24px;transform:translate(-50%,20px);opacity:0;background:var(--text);color:var(--bg);padding:10px 16px;border-radius:10px;font-weight:500;transition:.25s;pointer-events:none;max-width:90vw}
#toast.show{opacity:1;transform:translate(-50%,0)}
#toast.err{background:var(--danger);color:#fff}
footer{color:var(--muted);font-size:12px;margin-top:30px}
@media (max-width:640px){.row{grid-template-columns:1fr auto}.row .meter{grid-column:2;grid-row:1}.row .act{grid-column:1/-1;justify-content:flex-start}.free{font-size:42px}}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
</style></head><body><div class="wrap">
<h1>Curățenie Mac</h1>
<div class="hero">
  <div class="free" id="freeBig">…<small>liberi</small></div>
  <div class="strip"><i id="sUsed" style="width:0"></i><i id="sRec" style="width:0"></i></div>
  <div class="legend">
    <span><span class="dot" style="background:var(--used)"></span>Folosit <b id="lUsed">…</b></span>
    <span><span class="dot" style="background:var(--rec)"></span>Se poate elibera <b id="lRec">…</b> <span id="lPending"></span></span>
    <span><span class="dot" style="background:var(--free);outline:1px solid var(--line)"></span>Liber <b id="lFree">…</b></span>
  </div>
</div>
<div class="bar">
  <div class="seg"><button class="on" data-act="tab" data-tab="rec">Recomandări</button><button data-act="tab" data-tab="exp">Explorator</button></div>
  <button class="btn" id="rescan" data-act="rescan">Scanează din nou</button>
</div>
<div id="rec"></div>
<div id="exp" hidden><div class="crumbs" id="crumbs"></div><div class="card" id="expList"></div></div>
<footer>Rulează local pe Mac-ul tău; nimic nu e trimis pe internet. Ștergerile din Recomandări sunt definitive. În Explorator, elementele merg la Coș.</footer>
</div>
<div id="modal" hidden><div class="mbox" role="dialog" aria-modal="true"><h3 id="mTitle"></h3><div id="mBody"></div>
<div class="mact"><button class="btn" id="mCancel">Anulează</button><button class="btn" id="mOk"></button></div></div></div>
<div id="toast"></div>
<script>
const TOKEN="__TOKEN__";
const $=s=>document.querySelector(s);
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function fmt(b){if(b==null)return '…';const o=n=>({maximumFractionDigits:n});
 if(b<1e6)return (b/1e3).toLocaleString('ro-RO',o(0))+' KB';
 if(b<1e9)return (b/1e6).toLocaleString('ro-RO',o(0))+' MB';
 return (b/1e9).toLocaleString('ro-RO',o(1))+' GB';}
async function api(path,body){
 const url=path+(path.includes('?')?'&':'?')+'t='+TOKEN;
 const opt=body===undefined?{headers:{'X-Token':TOKEN}}:{method:'POST',headers:{'X-Token':TOKEN,'Content-Type':'application/json'},body:JSON.stringify(body)};
 const r=await fetch(url,opt);const j=await r.json().catch(()=>({}));
 if(!r.ok)throw new Error(j.error||('Eroare '+r.status));return j;}

let targets=[],sizes={},running={},busy={},cleaned={},disk=null,pending=0,cur=null,rq=false;
function schedule(){if(rq)return;rq=true;requestAnimationFrame(()=>{rq=false;render();});}
function reclaim(){let s=0;for(const t of targets)if(!t.overlap)s+=sizes[t.id]||0;return s;}

async function loadDisk(){try{disk=await api('/api/disk');}catch(e){}renderHero();}
function renderHero(){
 const rec=reclaim();
 $('#lRec').textContent=fmt(rec);
 $('#lPending').textContent=pending>0?'(se calculează…)':'';
 if(!disk)return;
 const r=Math.min(rec,disk.used);
 $('#freeBig').innerHTML=esc(fmt(disk.free))+'<small>liberi din '+esc(fmt(disk.total))+'</small>';
 $('#lUsed').textContent=fmt(disk.used);$('#lFree').textContent=fmt(disk.free);
 $('#sUsed').style.width=((disk.used-r)/disk.total*100)+'%';
 $('#sRec').style.width=(r/disk.total*100)+'%';}

function queueSizes(list){
 const q=list.map(t=>t.id);pending+=q.length;renderHero();
 const work=async()=>{while(q.length){const id=q.shift();
  try{const s=await api('/api/size?id='+encodeURIComponent(id));sizes[id]=s.size;running[id]=s.running;}catch(e){sizes[id]=0;}
  pending--;schedule();}};
 for(let i=0;i<4;i++)work();}

async function loadTargets(){
 targets=[];sizes={};running={};cleaned={};render();$('#rescan').disabled=true;
 try{const r=await api('/api/targets');targets=r.targets;render();queueSizes(r.targets);
  const n=await api('/api/node_modules');targets=targets.concat(n.targets);render();queueSizes(n.targets);
 }catch(e){toast(e.message,true);}
 $('#rescan').disabled=false;}

function rowHtml(t,max){
 const s=sizes[t.id],done=cleaned[t.id]&&s===0,pct=s?Math.max(1.5,s/max*100):0;
 const warn=running[t.id]&&!done?`<div class="warn">Închide ${esc(t.app_name||'aplicația')} înainte de curățare.</div>`:'';
 const btn=busy[t.id]?'<button class="btn" disabled><span class="spin"></span>Se curăță</button>'
  :done?'<span class="done">Curățat</span>'
  :`<button class="btn" data-act="clean" data-id="${esc(t.id)}" ${s==null?'disabled':''}>Curăță</button>`;
 return `<div class="row${done?' is-done':''}"><div class="info"><div class="name">${esc(t.name)}<span class="badge ${t.risk}">${t.risk==='care'?'Atenție':'Sigur'}</span></div>
 <div class="desc">${esc(t.desc)}</div>${warn}</div>
 <div class="meter"><div class="size">${s==null?'<span class="spin"></span>':fmt(s)}</div><div class="track"><i style="width:${pct}%"></i></div></div>
 <div class="act">${btn}</div></div>`;}

function render(){
 renderHero();const root=$('#rec');
 if(!targets.length){root.innerHTML='<p class="empty"><span class="spin"></span>Se scanează…</p>';return;}
 const groups=[],by={};
 for(const t of targets){if(!by[t.group]){by[t.group]=[];groups.push(t.group);}by[t.group].push(t);}
 const max=Math.max(1,...targets.map(t=>sizes[t.id]||0));
 const html=groups.map(g=>{
  const rows=by[g].filter(t=>sizes[t.id]!==0||cleaned[t.id]).sort((a,b)=>(sizes[b.id]??-1)-(sizes[a.id]??-1));
  if(!rows.length)return '';
  const sum=rows.reduce((s,t)=>s+(t.overlap?0:(sizes[t.id]||0)),0);
  return `<section><h2><span>${esc(g)}</span><span class="gsum">${fmt(sum)}</span></h2><div class="card">${rows.map(t=>rowHtml(t,max)).join('')}</div></section>`;
 }).join('');
 root.innerHTML=html||(pending?'<p class="empty"><span class="spin"></span>Se calculează…</p>':'<p class="empty">Nimic de curățat aici. Folosește Exploratorul ca să cauți manual.</p>');}

function openModal({title,body,ok,danger,onOk}){
 $('#mTitle').textContent=title;$('#mBody').innerHTML=body;
 const b=$('#mOk');b.hidden=!ok;b.textContent=ok||'';b.className='btn '+(danger?'danger':'primary');
 $('#mCancel').textContent=ok?'Anulează':'Închide';
 b.onclick=()=>{closeModal();onOk&&onOk();};$('#modal').hidden=false;(ok?b:$('#mCancel')).focus();}
function closeModal(){$('#modal').hidden=true;}
$('#mCancel').onclick=closeModal;
$('#modal').addEventListener('click',e=>{if(e.target.id==='modal')closeModal();});
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeModal();});

function askClean(id){
 const t=targets.find(x=>x.id===id);
 openModal({title:`Curăți „${t.name}”?`,
  body:`<p>${esc(t.desc)}</p><p>Se șterg definitiv aproximativ <b>${esc(fmt(sizes[id]))}</b>.</p>`,
  ok:'Șterge definitiv',danger:true,onOk:()=>doClean(id)});}
async function doClean(id){
 busy[id]=true;render();
 try{const r=await api('/api/clean',{id});sizes[id]=r.size;running[id]=false;cleaned[id]=true;
  toast('Eliberat '+fmt(r.freed));if(r.errors.length)showErrors(r.errors);
 }catch(e){if(/Închide/.test(e.message))running[id]=true;toast(e.message,true);}
 busy[id]=false;render();loadDisk();}
function showErrors(errs){
 const fda=errs.some(e=>/not permitted|permission denied/i.test(e));
 openModal({title:'Unele elemente nu au putut fi șterse',
  body:`<pre>${esc(errs.join('\n'))}</pre>`+(fda?'<p>Dă Terminalului acces: System Settings → Privacy & Security → Full Disk Access → adaugă Terminal, apoi pornește scriptul din nou.</p>':'')});}

async function browse(p){
 $('#expList').innerHTML='<p class="empty"><span class="spin"></span>Se calculează mărimile. Folderele mari pot dura un minut.</p>';
 try{cur=await api('/api/browse?path='+encodeURIComponent(p||''));renderExp();}
 catch(e){$('#expList').innerHTML=`<p class="empty">${esc(e.message)}</p>`;}}
function renderExp(){
 const parts=cur.rel==='.'?[]:cur.rel.split('/');let acc=cur.home;
 let c=`<a data-act="go" data-path="${esc(cur.home)}">Home</a>`;
 for(const p of parts){acc+='/'+p;c+=`<span class="sep">/</span><a data-act="go" data-path="${esc(acc)}">${esc(p)}</a>`;}
 $('#crumbs').innerHTML=c+`<span class="gsum">${fmt(cur.total)}</span>`;
 const max=Math.max(1,...cur.items.map(i=>i.size));
 $('#expList').innerHTML=cur.items.length?cur.items.map((it,i)=>`<div class="row">
  <div class="info"><div class="name">${it.dir?`<a data-act="open" data-i="${i}">${esc(it.name)}/</a>`:esc(it.name)}</div></div>
  <div class="meter"><div class="size">${fmt(it.size)}</div><div class="track"><i style="width:${Math.max(1,it.size/max*100)}%"></i></div></div>
  <div class="act"><button class="btn" data-act="reveal" data-i="${i}">Finder</button>${it.protected?'':`<button class="btn" data-act="trash" data-i="${i}">La Coș</button>`}</div></div>`).join('')
  :'<p class="empty">Folder gol.</p>';}
function askTrash(i){
 const it=cur.items[i];
 openModal({title:`Muți „${it.name}” la Coș?`,
  body:`<p>${esc(fmt(it.size))}. Îl poți recupera din Coș până îl golești.</p>`,ok:'Mută la Coș',
  onOk:async()=>{try{await api('/api/trash',{path:it.path});cur.items.splice(i,1);cur.total-=it.size;renderExp();toast('Mutat la Coș');
   const tr=targets.find(t=>t.id==='trash');if(tr)queueSizes([tr]);}catch(e){toast(e.message,true);}}});}

function setTab(tab){
 document.querySelectorAll('.seg button').forEach(b=>b.classList.toggle('on',b.dataset.tab===tab));
 $('#rec').hidden=tab!=='rec';$('#exp').hidden=tab!=='exp';$('#rescan').hidden=tab!=='rec';
 if(tab==='exp'&&!cur)browse('');}

document.addEventListener('click',e=>{
 const el=e.target.closest('[data-act]');if(!el)return;const a=el.dataset.act;
 if(a==='clean')askClean(el.dataset.id);
 else if(a==='tab')setTab(el.dataset.tab);
 else if(a==='rescan'){loadTargets();loadDisk();}
 else if(a==='go')browse(el.dataset.path);
 else if(a==='open')browse(cur.items[+el.dataset.i].path);
 else if(a==='reveal')api('/api/reveal',{path:cur.items[+el.dataset.i].path}).catch(err=>toast(err.message,true));
 else if(a==='trash')askTrash(+el.dataset.i);});

let tt;function toast(m,err){const el=$('#toast');el.textContent=m;el.className='show'+(err?' err':'');clearTimeout(tt);tt=setTimeout(()=>el.className='',3800);}
loadDisk();loadTargets();
</script></body></html>'''


def main():
    srv = None
    for port in range(8765, 8790):
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
            break
        except OSError:
            continue
    if not srv:
        sys.exit("Nu am găsit niciun port liber.")
    ALLOWED_HOSTS.update({"127.0.0.1:%d" % port, "localhost:%d" % port})
    url = "http://127.0.0.1:%d/?t=%s" % (port, TOKEN)
    print("\n  Curățenie Mac rulează la:\n  %s\n\n  Lasă fereastra deschisă. Oprește cu Ctrl+C.\n" % url)
    threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  Oprit.")


if __name__ == "__main__":
    main()

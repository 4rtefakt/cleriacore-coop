"""Pack this mod into <id>-<version>.cleriamod (a zip holding one folder named by the mod's id).

    python .dev/pack.py [output folder]      # default: dist/
"""
import os, sys, zipfile

MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ini = {}
for line in open(os.path.join(MOD, "mod.ini"), encoding="utf-8"):
    if "=" in line and not line.strip().startswith(";"):
        k, v = line.split("=", 1)
        ini[k.strip().lower()] = v.strip().strip('"')
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(MOD, "dist")
os.makedirs(out, exist_ok=True)
path = os.path.join(out, "%s-%s.cleriamod" % (ini["id"].lower(), ini["version"]))
files = []
for root, dirs, names in os.walk(MOD):
    dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("dist", "__pycache__", "docs"))
    for n in sorted(names):
        if n.startswith(".") or n.lower().endswith((".cleriamod", ".zip", ".pyc")):
            continue
        files.append(os.path.join(root, n))
with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        info = zipfile.ZipInfo(ini["id"].lower() + "/" + os.path.relpath(f, MOD).replace(os.sep, "/"), (1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, open(f, "rb").read())
print(path, len(files), "files")

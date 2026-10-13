"""Two games on this machine, one hosting and one joining over the loopback, each driven by its own script.

    python .dev/duo.py [case ...]        # CLERIA_EXE=<cleria-view of a CleriaCore with mod API 7>

A case gives each side its room, its drive script, the mod's settings and the lines its output must hold, in order.
The two processes start together; nothing ties their ticks, so the drives leave time (thousands of ticks) between
a cause on one side and its check on the other. SHOW=1 prints both sides' mod lines."""
import os, shutil, socket, struct, subprocess, sys, tempfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)
CC = os.environ.get("CLERIACORE") or os.path.join(os.path.dirname(os.path.dirname(MOD)), "YsOrigin-CleriaCore")
EXE = os.environ.get("CLERIA_EXE") or os.path.join(os.path.dirname(CC), "YsOrigin-CleriaCore-api7", "build_api7", "Release", "cleria-view.exe")
ASSETS = os.environ.get("CLERIA_ASSETS") or os.path.join(CC, "assets")
MID = "4rtefakt.coop"
LP = "[lua:%s] coop: " % MID
STOPPED = ("script stopped", "Mod stopped", "the mod is disabled until the game restarts")


def ppm_to_png(src, dst):
    with open(src, "rb") as f:
        assert f.readline().strip() == b"P6"
        w, h = map(int, f.readline().split())
        f.readline()
        rgb = f.read()
    raw = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(dst, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start(side, port, tmp):
    root = os.path.join(tmp, side["name"])
    settings = os.path.join(root, "settings")
    shutil.copytree(MOD, os.path.join(settings, "mods", MID), ignore=shutil.ignore_patterns(".*", "*.cleriamod", "dist", "docs", "__pycache__"))
    lines = ["Name=" + side["name"], "Auto=" + side["auto"], "Loopback=1", "Address=127.0.0.1", "Port=%d" % port] + side.get("settings", [])
    with open(os.path.join(settings, "cleria.ini"), "w") as f:
        f.write('[cleria.mods]\nUseMods=1\nOrder="%s"\nActive="%s"\n\n[cleria.mod.%s]\n%s\n' % (MID, MID, MID, "\n".join(lines)))
    open(os.path.join(settings, "yso_win.ini"), "w").close()
    env = dict(os.environ, CLERIA_MUTE="1", CLERIA_CHAR=side.get("char", "1"), CLERIA_DRIVE=side["drive"], CLERIA_SAVE_DIR=root,
               CLERIA_SHOT_DIR=root, CLERIA_INI=os.path.join(settings, "yso_win.ini"))
    sob = os.path.join(ASSETS, "MAP", side["room"] + ".SOB")
    return subprocess.Popen([EXE, ASSETS, sob], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")


def run(name, case):
    port = free_port()
    with tempfile.TemporaryDirectory() as tmp:
        procs = [start(s, port, tmp) for s in case["sides"]]
        outs = []
        for p in procs:
            try:
                outs.append(p.communicate(timeout=600)[0])
            except subprocess.TimeoutExpired:
                p.kill()
                outs.append(p.communicate()[0] + "\nTIMEOUT")
        for side in case["sides"]:                              # {name: the tick of a `shot` command} -> .dev/shots/<name>.png
            for shot, tick in side.get("shots", {}).items():
                f = os.path.join(tmp, side["name"], "t%d.ppm" % tick)
                if os.path.exists(f):
                    os.makedirs(os.path.join(HERE, "shots"), exist_ok=True)
                    ppm_to_png(f, os.path.join(HERE, "shots", shot + ".png"))
    ok = True
    for side, out in zip(case["sides"], outs):
        mine = "\n".join(l for l in out.splitlines() if "[lua" in l)
        if os.environ.get("SHOW"):
            print("---- " + side["name"] + "\n" + mine)
        bad = [e for e in list(side.get("absent", [])) + list(STOPPED) if e in out]
        at, missing = 0, None
        for e in side["expect"]:
            k = out.find(e, at)
            if k < 0:
                missing = e
                break
            at = k + len(e)
        if bad or missing:
            ok = False
            print(f"FAIL {name} ({side['name']}): " + (f"unexpected '{bad[0]}'" if bad else f"missing '{missing}'"))
            print(mine[-3000:])
    if ok:
        print(f"ok   {name}")
    return ok


def every(first, last, step, cmd):
    return ";".join(f"{t}:{cmd}" for t in range(first, last, step))


ROOM = "S_10/S_1002/S_1002"
CASES = {
    # The two meet, each sees the other's puppet in the same room; the guest's monsters are the host's (held, the
    # same count); a hit of the guest's reaches the host's monster; the host's kill gives the guest its EXP.
    "together": dict(sides=[
        dict(name="Hosty", auto="host", room=ROOM,
             drive="5:opt=InfiniteHP=1;" + every(1000, 9000, 1000, "lua=coop status") + ";5000:lua=coop kill;9500:quit",
             expect=[LP + "hosting on ", LP + "Guesty joined (2)", "role host id 1 peers 1 here 1 puppets 1 monsters 11 held false owner 1",
                     "monsters 10 held false owner 1"]),
        dict(name="Guesty", auto="join", room=ROOM, char="2",
             drive="5:opt=InfiniteHP=1;" + every(1000, 9000, 1000, "lua=coop status") + ";3000:lua=coop poke;9500:quit",
             expect=[LP + "connected as 2", LP + "Hosty joined (1)", "role guest id 2 peers 1 here 1 puppets 1 monsters 11 held true owner 1",
                     LP + "shared exp ", "monsters 10 held true owner 1"]),
    ]),
    # Friendly fire on both sides: the host swings at the guest standing on the same spot; the guest is hit.
    "friendly_fire": dict(sides=[
        dict(name="Hosty", auto="host", room="S_10/S_1009/S_1009", settings=["FriendlyFire=1"],
             drive=every(1500, 20000, 600, "lua=coop goto") + ";" + every(1510, 20000, 600, "atk") + ";" + every(1000, 20000, 1000, "lua=coop status") + ";20000:quit",
             expect=[LP + "Guesty joined (2)", "puppets 1"]),
        dict(name="Guesty", auto="join", room="S_10/S_1009/S_1009", settings=["FriendlyFire=1"],
             drive="5:opt=InfiniteHP=1;20000:quit",
             expect=[LP + "connected as 2", LP + "hit by Hosty"]),
    ]),
    # The README's pictures: the host (Hugo) walks off and swings; the guest's screen shows him, his name, the monsters.
    "picture": dict(sides=[
        dict(name="Hosty", auto="host", room=ROOM, char="2",
             drive="5:opt=InfiniteHP=1;2000:move=1,0,60;2400:shot;" + every(2500, 9000, 400, "atk") + ";9000:quit",
             expect=[LP + "Guesty joined (2)"], shots={"host": 2400}),
        dict(name="Guesty", auto="join", room=ROOM,
             drive="5:opt=InfiniteHP=1;" + ";".join(f"{t}:shot" for t in (3000, 5000, 7000)) + ";9000:quit",
             expect=[LP + "connected as 2"], shots={"guest1": 3000, "guest2": 5000, "guest3": 7000}),
    ]),
    # In different rooms nobody draws anybody, and each owns its own room's monsters.
    "apart": dict(sides=[
        dict(name="Hosty", auto="host", room=ROOM, drive=every(500, 6000, 500, "lua=coop status") + ";6000:quit",
             expect=[LP + "Guesty joined (2)", "peers 1 here 0 puppets 0 monsters 11 held false owner 1"]),
        dict(name="Guesty", auto="join", room="S_10/S_1009/S_1009", drive=every(500, 40000, 500, "lua=coop status") + ";40000:quit",
             expect=[LP + "connected as 2", "peers 1 here 0 puppets 0 monsters 0 held false owner 2"]),
    ]),
}

if __name__ == "__main__":
    names = sys.argv[1:] or list(CASES)
    bad = sum(not run(n, CASES[n]) for n in names)
    print(f"{len(names) - bad}/{len(names)} passed")
    sys.exit(1 if bad else 0)

-- Co-op for Ys Origin on CleriaCore (mod API 7).
--
-- One player hosts (a TCP listener), the others join. Every message is one line of JSON. A guest talks to the host
-- only; the host stamps each message with its sender (`from`) and passes it on, so a guest never has to be reachable.
--
--   hello / welcome / join / leave / no   who is there
--   p       20 times a second: my room, my pose, my HP, whether I am down, my boss's gauge
--   snap    10 times a second, from the OWNER of a room (the lowest id in it): its monsters. The others hold theirs
--           and show these.
--   dmg     a hit of mine on a monster I do not own: the owner lands it
--   struck  the owner's monster hit your puppet on its screen: your game prices the hit
--   kill    the owner's kill: its EXP and SP for everybody in the room
--   drop    what that monster dropped on the owner's screen: the same pickup falls on everybody's
--   hit     a swing of mine landed on your puppet (friendly fire)
--   item / flag   shared progress: an item obtained, a chest / door / boss flag
--   fx      an effect my character's script made (a skill's blast): shown on my puppet, hitting nobody
--   b       a bullet of mine (Hugo's shots): the same bullet flies on the others' screens, hitting nobody
--   chat    a line of text
if not (cleria.net and cleria.net.tcp and cleria.world and cleria.world.show_bullet and cleria.combat.boss_bonus) then
    cleria.log("Co-op needs a CleriaCore with mod API 7")
    return
end
local N, W, G, P, J, S = cleria.net, cleria.world, cleria.game, cleria.player, cleria.json, cleria.settings
local PROTOCOL = 2

local cfg = {
    name = S.get("Name", "Player"), address = S.get("Address", "127.0.0.1"), port = S.get("Port", 7777),
    monsters = S.get("ShareMonsters", true), rewards = S.get("ShareRewards", true), revive = S.get("Revive", true),
    scale = S.get("TougherMonsters", true), progress = S.get("ShareProgress", false), friendly = S.get("FriendlyFire", false),
    names = S.get("ShowNames", true), party = S.get("ShowParty", true),
    loopback = S.get("Loopback", false),      -- host on this machine only (tests; no firewall question)
    auto = S.get("Auto", ""),                 -- "host" / "join": start at once (tests, or a session you always resume)
}
local function keep(key, field) S.set(key, cfg[field]) end

-- ---- state --------------------------------------------------------------------------------------------------
local role, me, status = nil, nil, "Not connected"   -- role: nil, "host", "guest"
local want = nil                                       -- "guest": keep trying to reach the host
local listener, link, link_seen                        -- the host's listener; a guest's connection, when it last spoke
local dialer                                           -- the guest's one socket, reused by every try: a closed socket
                                                       -- still counts toward the mod's 16 until it is collected
local conns, next_id = {}, 2                           -- the host's guests: {sock =, buf =, id =, seen =}
local peers = {}                                       -- [id] = {name, ch, room, pose, puppet, ...}
local held = false                                     -- this room's monsters are another player's: mine are held
local applying = false                                 -- an item given by a message: not announced again
local told = {}                                        -- flags I was told of: not announced back
local down = nil                                       -- {left = seconds}: I am down, waiting for a revive
local boss_won = nil                                   -- the room whose boss a teammate has just beaten
local drops_seen = 0
local chat = {}                                        -- the last lines
local say_text = ""

local function say(text) cleria.log("coop: " .. text) end
local function in_game() return G.state() ~= "title" end
local function room() return in_game() and G.room() or "" end
local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
local function players() local n = 1 for _ in pairs(peers) do n = n + 1 end return n end

local function drop_puppet(p)
    if p.puppet then W.remove_puppet(p.puppet) end
    for _, id in ipairs(p.props or {}) do W.remove_puppet(id) end
    p.puppet, p.target, p.props = nil, nil, nil
end
local function forget(id)
    local p = peers[id]
    if not p then return end
    drop_puppet(p)
    peers[id] = nil
    say(p.name .. " left")
    cleria.notice(p.name .. " left", "Co-op")
end
local function meet(id, name, ch)
    if id == me or peers[id] then return end
    peers[id] = {name = tostring(name or "?"):sub(1, 24), ch = ch or 1, room = ""}
    say(peers[id].name .. " joined (" .. id .. ")")
    cleria.notice(peers[id].name .. " joined", "Co-op")
end

-- The owner of a room's monsters: the lowest id among the players in it.
local function owner_of(r)
    local o = (r ~= "" and r == room()) and me or nil
    for id, p in pairs(peers) do
        if p.room == r and r ~= "" and (not o or id < o) then o = id end
    end
    return o
end
local function others_here()
    local r, n = room(), 0
    if r == "" then return 0 end
    for _, p in pairs(peers) do if p.room == r then n = n + 1 end end
    return n
end
local function standing_here()                         -- teammates in my room who are on their feet; the nearest one's distance
    local r, n, near = room(), 0, nil
    local st = P.stats()
    for _, p in pairs(peers) do
        local m = p.pose
        if p.room == r and r ~= "" and m and m.x and not m.d and (m.hp or 1) > 0 then
            n = n + 1
            local d = st and math.sqrt((m.x - st.x) ^ 2 + (m.z - st.z) ^ 2) or 99
            if not near or d < near then near = d end
        end
    end
    return n, near
end
local function release()                               -- the monsters are mine again: their handlers run
    if not held then return end
    held = false
    for _, a in ipairs(W.actors()) do W.form(a.id, {ai = true}) end
end

-- ---- the wire -----------------------------------------------------------------------------------------------
local function write(sock, m) return sock:send(J.encode(m) .. "\n") end
local function send(m, to)                             -- to everybody, or to one id
    if role == "guest" then
        m.to = to
        if link and me then write(link, m) end
    elseif role == "host" then
        m.from, m.to = me, to
        for _, c in ipairs(conns) do
            if c.id and (not to or c.id == to) then write(c.sock, m) end
        end
    end
end

local handle
local function close_all()
    release()
    for id in pairs(peers) do drop_puppet(peers[id]) end
    peers = {}
    if link then link:close() link = nil end
    for _, c in ipairs(conns) do c.sock:close() end
    conns = {}
    if listener then listener:close() listener = nil end
    if in_game() then cleria.combat.boss_bonus(0) end
    role, me = nil, nil
end
local function stop(why)                               -- the player's own stop (or a refusal): no retry
    want = nil
    if not role and not why then return end
    close_all()
    status = why or "Not connected"
    say("stopped: " .. status)
end

local function host()
    stop()
    listener = N.tcp()
    local port, err = listener:listen(cfg.port, not cfg.loopback)
    if not port then
        listener = nil
        status = "Could not host: " .. tostring(err)
        say(status)
        return false
    end
    role, me, next_id = "host", 1, 2
    status = "Hosting on port " .. port
    say("hosting on " .. port)
    return true
end
local function dial()
    close_all()
    dialer = dialer or N.tcp()
    link = dialer
    link:connect(cfg.address, cfg.port)
    role, me, link_seen = "guest", nil, cleria.time()
end
local function join()
    stop()
    want = "guest"
    dial()
    status = "Connecting to " .. cfg.address .. ":" .. cfg.port .. "..."
    say("joining " .. cfg.address .. ":" .. cfg.port)
    return true
end
local function lost(why)                               -- the link went away by itself: try again in a moment
    close_all()
    status = why .. " Trying again..."
    say("lost: " .. why)
    cleria.after(3, function() if want == "guest" and not role then dial() end end)
end

-- One complete line from a connection. `c` is the host's record of the guest it came from (nil on a guest).
local function line(text, c)
    local m = J.decode(text)
    if type(m) ~= "table" or type(m.t) ~= "string" then return end
    if role == "host" then
        if m.t == "hello" then
            if c.id then return end
            if m.v ~= PROTOCOL then write(c.sock, {t = "no", why = "another version of the Co-op mod"}) return end
            c.id = next_id
            next_id = next_id + 1
            local list = J.array({J.array({1, cfg.name, G.character()})})
            for id, p in pairs(peers) do list[#list + 1] = J.array({id, p.name, p.ch}) end
            write(c.sock, {t = "welcome", id = c.id, peers = list})
            for _, o in ipairs(conns) do
                if o.id and o ~= c then write(o.sock, {t = "join", from = 1, id = c.id, name = m.name, ch = m.ch}) end
            end
            meet(c.id, m.name, m.ch)
            return
        end
        if not c.id then return end
        m.from = c.id                                  -- never the sender's own word
        for _, o in ipairs(conns) do                   -- pass it on
            if o.id and o ~= c and (not m.to or m.to == o.id) then write(o.sock, m) end
        end
        if m.to and m.to ~= me then return end
    end
    handle(m)
end
local function feed(holder, text, c)                   -- bytes in; whole lines out
    holder.buf = (holder.buf or "") .. text
    if #holder.buf > 4 * 1024 * 1024 then holder.buf = "" return end
    while true do
        local i = holder.buf:find("\n", 1, true)
        if not i then break end
        local l = holder.buf:sub(1, i - 1)
        holder.buf = holder.buf:sub(i + 1)
        if l ~= "" then line(l, c) end
        if not role then return end                    -- a line ended the session
    end
end

local link_buf = {}
local function drop_conn(i)
    local c = table.remove(conns, i)
    c.sock:close()
    if c.id then
        forget(c.id)
        for _, o in ipairs(conns) do if o.id then write(o.sock, {t = "leave", from = 1, id = c.id}) end end
    end
end
local function pump()
    local now = cleria.time()
    if role == "host" then
        for _, e in ipairs(listener:poll()) do
            if e.kind == "accept" then conns[#conns + 1] = {sock = e.socket, seen = now} end
        end
        for i = #conns, 1, -1 do
            local c, gone = conns[i], false
            for _, e in ipairs(c.sock:poll()) do
                if e.kind == "data" then c.seen = now feed(c, e.text, c)
                elseif e.kind == "close" then gone = true break end
            end
            if gone or now - c.seen > 20 then drop_conn(i) end
        end
    elseif role == "guest" and link then
        for _, e in ipairs(link:poll()) do
            if e.kind == "open" then
                link_buf, link_seen = {}, now
                write(link, {t = "hello", v = PROTOCOL, name = cfg.name, ch = G.character()})
                status = "Connected, waiting for the host..."
            elseif e.kind == "data" then
                link_seen = now
                feed(link_buf, e.text)
                if not role then return end
            elseif e.kind == "close" then
                lost(me and "The connection to the host was lost." or "Could not reach the host.")
                return
            end
        end
        if me and now - link_seen > 20 then lost("The host went silent.") end
    end
end

-- ---- what a message does ------------------------------------------------------------------------------------
local function unpack_snapshot(list)
    local out = {}
    for i, a in ipairs(list) do
        out[i] = {id = a[1], cast = a[2], level = a[3], x = a[4], y = a[5], z = a[6], yaw = a[7], hp = a[8], max_hp = a[9],
                  tag = a[10], frame = a[11], sheet = a[12]}
    end
    return out
end
handle = function(m)
    local t = m.t
    if t == "welcome" then
        me = m.id
        status = "Connected"
        say("connected as " .. me)
        for _, p in ipairs(m.peers or {}) do meet(p[1], p[2], p[3]) end
    elseif t == "no" then
        stop("Refused: " .. tostring(m.why))
    elseif t == "join" then meet(m.id, m.name, m.ch)
    elseif t == "leave" then forget(m.id)
    elseif t == "p" then
        local p = peers[m.from]
        if not p then return end
        if p.room ~= m.r then drop_puppet(p) p.sx = nil end
        p.fx, p.fy, p.fz, p.at = p.sx, p.sy, p.sz, cleria.time()      -- glide from where the puppet is shown now
        p.room, p.pose, p.ch = m.r or "", m, m.c or p.ch
    elseif t == "snap" then
        if cfg.monsters and m.r == room() and owner_of(m.r) == m.from and type(m.m) == "table" then
            W.apply(unpack_snapshot(m.m))
            held = true
        end
    elseif t == "dmg" then
        if cfg.monsters and m.r == room() and owner_of(m.r) == me and (m.n or 0) > 0 then cleria.combat.damage(m.a, m.n) end
    elseif t == "struck" then
        if in_game() and not down and (m.atk or 0) > 0 then
            cleria.combat.strike(m.atk, m.power or 0)
            say("struck by a monster of " .. (peers[m.from] and peers[m.from].name or "?"))
        end
    elseif t == "kill" then
        if cfg.rewards and m.r == room() then
            if (m.exp or 0) > 0 then P.add_exp(m.exp) end
            if (m.sp or 0) > 0 then P.add_sp(m.sp) end
            say("shared exp " .. tostring(m.exp) .. " sp " .. tostring(m.sp))
        end
    elseif t == "drop" then
        if cfg.rewards and m.r == room() and type(m.item) == "number" and m.x then
            G.spawn_pickup(m.item, m.x, m.y, m.z)
            drops_seen = drops_seen + 1
            if drops_seen == 1 then say("drop " .. m.item .. " from " .. (peers[m.from] and peers[m.from].name or "?")) end
        end
    elseif t == "hit" then
        if cfg.friendly and in_game() and not down and (m.atk or 0) > 0 then
            cleria.combat.strike(m.atk, m.power or 0)
            say("hit by " .. (peers[m.from] and peers[m.from].name or "?"))
        end
    elseif t == "item" then
        if cfg.progress and in_game() and type(m.item) == "number" then
            applying = true
            cleria.content.give(m.item, m.count or 1, "coop")
            applying = false
            say("shared item " .. m.item)
        end
    elseif t == "flag" then
        -- A chest, a door or a boss the other player dealt with. A boss flag is not taken in the middle of that fight.
        if cfg.progress and in_game() and type(m.flag) == "number" and m.flag >= 128 and m.flag < 512 and not (m.k == "boss" and m.r == room()) then
            told[m.flag] = true
            if G.flag(m.flag) == 0 then G.set_flag(m.flag, 1) say("shared " .. tostring(m.k) .. " flag " .. m.flag) end
        end
    elseif t == "fx" then
        local p = peers[m.from]
        if p and p.puppet and p.room == room() and type(m.e) == "table" then
            W.puppet_effect(p.puppet, m.e)
            if not p.fx_seen then p.fx_seen = true say("effect " .. tostring(m.e.id) .. " on " .. p.name) end
        end
    elseif t == "b" then
        local p = peers[m.from]
        if p and p.room == room() and in_game() and type(m.e) == "table" then
            W.show_bullet(m.e)
            if not p.b_seen then p.b_seen = true say("bullet " .. tostring(m.e.effect) .. " of " .. p.name) end
        end
    elseif t == "bosswon" then
        if cfg.monsters and m.r == room() then boss_won = m.r say("a teammate beat the boss") end
    elseif t == "chat" then
        local who = peers[m.from] and peers[m.from].name or "?"
        local text = tostring(m.text or ""):sub(1, 120)
        chat[#chat + 1] = who .. ": " .. text
        if #chat > 6 then table.remove(chat, 1) end
        cleria.notice(text, who)
        say("chat " .. who .. ": " .. text)
    end
end

-- ---- down and revive ------------------------------------------------------------------------------------------
local function stand_up(hp)
    down = nil
    P.tune({speed = 1, jump = 1})
    if hp then
        P.set_hp(math.max(1, math.floor(P.max_hp() * hp)))
        P.set_invulnerable(120)
        say("revived")
        cleria.notice("Back on your feet!", "Co-op")
    end
end
cleria.combat.add_filter("damage", function(q)
    if not role or not me then return end
    if q.dir == "taken" then
        if down then return 0 end
        if cfg.revive and q.value >= (q.hp or 0) and (q.hp or 0) >= 1 and standing_here() > 0 then
            down = {left = 10}
            P.tune({speed = 0.05, jump = 0.05})
            P.set_invulnerable(60)
            say("down")
            cleria.notice("You are down. A teammate beside you gets you up faster.", "Co-op")
            return math.max(0, q.hp - 1)                 -- left at 1 HP instead of dying
        end
        return
    end
    -- A hit of mine on a monster another player owns: the owner lands it. Here it shows, but never kills.
    if not cfg.monsters or q.dir ~= "dealt" or not q.actor then return end
    local r = room()
    local o = owner_of(r)
    if not o or o == me then return end
    send({t = "dmg", r = r, a = q.actor, n = q.value}, o)
    return math.max(0, math.min(q.value, (q.hp or 1) - 1))
end)
cleria.events.on("tick", function()
    if not down then return end
    if not role then stand_up() return end
    P.set_invulnerable(30)
    local n, near = standing_here()
    if n == 0 then                                       -- nobody left standing in the room: the fall is real
        stand_up()
        say("nobody left standing")
        P.set_hp(0)
        return
    end
    down.left = down.left - (near and near < 2.5 and 3 or 1) / 60
    if down.left <= 0 then stand_up(0.3) end
end)
cleria.events.on("death", function() if down then stand_up() end end)

-- ---- what I send --------------------------------------------------------------------------------------------
local slow = 0
cleria.every(0.05, function()                           -- my room and my pose
    if not role or not me then return end
    local pose = in_game() and P.pose() or nil
    if not pose then
        slow = slow + 1
        if slow % 20 == 1 then send({t = "p", r = ""}) end
        return
    end
    local m = {t = "p", r = room(), x = r2(pose.x), y = r2(pose.y), z = r2(pose.z), yaw = r2(pose.yaw), s = pose.sheet, g = pose.tag,
               f = pose.frame, c = G.character(), hp = P.hp(), mhp = P.max_hp()}
    if down then m.d = math.ceil(down.left) end
    if pose.glow ~= 0 then m.gl = pose.glow end         -- the charged skill's pulse
    if pose.aura ~= 0 then m.au = pose.aura end         -- the Boost's aura
    local fam = P.familiars()                           -- Hugo's eyes: drawn beside his puppet
    if #fam > 0 then
        m.e = J.array({})
        for i, f in ipairs(fam) do m.e[i] = J.array({f.cast, r2(f.x), r2(f.y), r2(f.z), r2(f.yaw), f.tag, f.frame}) end
    end
    local b = W.boss()
    if b and not b.actor and b.max_hp > 0 then m.bf = r2(b.hp / b.max_hp * 100) / 100 end
    send(m)
end)
cleria.every(0.1, function()                            -- the monsters of the room I own
    if not role or not me or not cfg.monsters or not in_game() then return end
    local r = room()
    if owner_of(r) ~= me then return end
    release()
    if others_here() == 0 then return end
    local list = J.array({})
    for i, a in ipairs(W.snapshot()) do
        list[i] = J.array({a.id, a.cast, a.level, r2(a.x), r2(a.y), r2(a.z), r2(a.yaw), r2(a.hp), a.max_hp, a.tag, a.frame, a.sheet})
    end
    send({t = "snap", r = r, m = list})
end)
-- A boss run by the game's own modules is each player's own fight: the fuller gauge catches up with the emptier one
-- through the next hits of its player.
cleria.every(0.5, function()
    if not role or not me or not cfg.monsters or not in_game() then return end
    local b = W.boss()
    if not b or b.actor or b.max_hp <= 0 then return end
    local mine, low, r = b.hp / b.max_hp, nil, room()
    for _, p in pairs(peers) do
        local f = p.room == r and p.pose and p.pose.bf
        if f and (not low or f < low) then low = f end
    end
    cleria.combat.boss_bonus(0)
    if boss_won == r then cleria.combat.boss_bonus(b.hp + 1)             -- a teammate finished theirs: mine falls at my next hit
    elseif low and mine - low > 0.01 then cleria.combat.boss_bonus((mine - low) * b.max_hp) end
end)

-- What my monster drops, the others get too: each player picks up their own copy.
cleria.combat.add_filter("drop", function(q)
    if role and me and cfg.rewards and q.item and q.x and others_here() > 0 and owner_of(room()) == me then
        send({t = "drop", r = room(), item = q.item, x = r2(q.x), y = r2(q.y), z = r2(q.z)})
    end
end)
cleria.events.on("enemy_killed", function(e)
    if role and me and cfg.rewards and others_here() > 0 and owner_of(room()) == me then
        send({t = "kill", r = room(), exp = e.exp, sp = e.sp})
    end
end)
cleria.events.on("player_effect", function(e)          -- my skill's blast, my swing's flash: the others show it on my puppet
    if role and me and others_here() > 0 then
        send({t = "fx", e = {id = e.id, fwd = r2(e.fwd), angle = r2(e.angle), voff = r2(e.voff), scale = r2(e.scale), attach = e.attach}})
    end
end)
cleria.events.on("player_bullet", function(e)          -- a shot of mine: the others see it fly
    if role and me and others_here() > 0 then
        local m = {}
        for k, v in pairs(e) do if type(v) == "number" then m[k] = r2(v) end end
        send({t = "b", e = m})
    end
end)
cleria.events.on("puppet_struck", function(e)          -- my monster hit another player on my screen
    for id, p in pairs(peers) do
        if p.puppet == e.puppet then send({t = "struck", atk = e.atk, power = e.power}, id) return end
    end
end)
cleria.events.on("puppet_hit", function(e)
    if not cfg.friendly then return end
    for id, p in pairs(peers) do
        if p.puppet == e.puppet then send({t = "hit", atk = e.atk, power = e.power}, id) return end
    end
end)
cleria.events.on("item_obtained", function(e)
    if role and me and cfg.progress and not applying and e.source ~= "coop" then send({t = "item", item = e.item, count = e.count}) end
end)
local function share_flag(kind, flag)
    if not (role and me and cfg.progress) or type(flag) ~= "number" then return end
    if told[flag] then return end                       -- it came from a message
    told[flag] = true
    send({t = "flag", k = kind, flag = flag, r = room()})
end
cleria.events.on("chest_opened", function(e) share_flag("chest", e.index) end)
cleria.events.on("door_opened", function(e) share_flag("door", e.flag) end)
cleria.events.on("boss_defeated", function(e)
    if role then say("boss beaten") end
    if role and me and others_here() > 0 then send({t = "bosswon", r = room()}) end
    share_flag("boss", e.flag)
end)
cleria.events.on("room_enter", function()
    held = false                                        -- a new room: its monsters are its own until a snapshot says otherwise
    for _, p in pairs(peers) do p.puppet, p.target, p.sx, p.props = nil, nil, nil, nil end   -- the puppets went with the old room
    if role then cleria.combat.boss_bonus(0) end
    boss_won = nil
end)
cleria.events.on("new_game", function() told = {} end)
cleria.events.on("load", function() told = {} end)

-- More players, sturdier monsters: +60 % HP for each player beyond the first, as each monster is built.
W.add_filter("spawn", function(q)
    if role and me and cfg.scale and q.by == "" then
        local n = players()
        if n > 1 then return {hp = 1 + 0.6 * (n - 1)} end
    end
end)

-- ---- every frame: the sockets, then the puppets -------------------------------------------------------------
cleria.events.on("frame", function()
    if role then pump() end
    if not role or not in_game() then return end
    local r, now = room(), cleria.time()
    local mine = cfg.monsters and owner_of(r) == me
    for _, p in pairs(peers) do
        local m = p.pose
        if p.room == r and m and m.x then
            local k = p.fx and math.min(1, (now - p.at) / 0.05) or 1     -- 20 poses a second, glided over
            local x, y, z = m.x, m.y, m.z
            if k < 1 and math.abs(m.x - p.fx) + math.abs(m.z - p.fz) < 6 then
                x, y, z = p.fx + (m.x - p.fx) * k, p.fy + (m.y - p.fy) * k, p.fz + (m.z - p.fz) * k
            end
            p.sx, p.sy, p.sz = x, y, z
            local set = {x = x, y = y, z = z, yaw = m.yaw, sheet = m.s, tag = m.g, frame = m.f, glow = m.gl or 0, aura = m.au or 0}
            if not p.puppet or not W.set_puppet(p.puppet, set) then
                p.puppet = W.puppet(p.ch, x, y, z, m.yaw)
                p.target = nil
                if p.puppet then
                    set.hittable = cfg.friendly
                    W.set_puppet(p.puppet, set)
                end
            end
            local eyes = m.e or {}                      -- the player's helpers, one prop each
            p.props = p.props or {}
            for i, f in ipairs(eyes) do
                local set = {x = f[2], y = f[3], z = f[4], yaw = f[5], tag = f[6], frame = f[7]}
                if not p.props[i] or not W.set_puppet(p.props[i], set) then
                    p.props[i] = W.prop(f[1], f[2], f[3], f[4], f[5])
                    if p.props[i] then W.set_puppet(p.props[i], set) end
                end
            end
            for i = #p.props, #eyes + 1, -1 do W.remove_puppet(p.props[i]) p.props[i] = nil end
            local tgt = mine and not m.d                -- my monsters chase the players who are on their feet
            if p.puppet and p.target ~= tgt then
                p.target = tgt
                W.set_puppet(p.puppet, {target = tgt})
            end
        elseif p.puppet then
            drop_puppet(p)
        end
    end
end)

cleria.hud.layer("coop", function(d)
    if not role or not in_game() then return end
    local r, s = room(), d.scale
    if cfg.names then
        for _, p in pairs(peers) do
            local m = p.pose
            if p.room == r and m and m.x and p.sx then
                local label = p.name
                if m.d then label = label .. "  DOWN " .. m.d
                elseif m.hp and m.mhp and m.mhp > 0 then label = label .. "  " .. math.floor(m.hp) .. "/" .. math.floor(m.mhp) end
                d:world_text(p.sx, p.sy + 2.1, p.sz, label, {size = 15 * s, color = m.d and 0xFF6050 or 0xFFE08A})
            end
        end
    end
    if down then
        local st = P.stats()
        if st then d:world_text(st.x, st.y + 2.4, st.z, "DOWN  " .. math.ceil(down.left), {size = 18 * s, color = 0xFF6050}) end
    end
    if cfg.party then                                   -- the party, top right: a name, a bar, the room when it is another
        local x, y, w = d.w - 190 * s, 70 * s, 170 * s
        for _, p in pairs(peers) do
            local m = p.pose or {}
            d:text(x, y, p.name, {size = 14 * s, color = m.d and 0xFF6050 or 0xEAE6DA})
            if p.room ~= r then
                d:text(x, y + 16 * s, p.room ~= "" and p.room or "in the menus", {size = 12 * s, color = 0x9A968A})
            elseif m.hp and m.mhp and m.mhp > 0 then
                d:rect(x, y + 19 * s, w, 5 * s, {color = 0x2A2820})
                d:rect(x, y + 19 * s, w * math.max(0, math.min(1, m.hp / m.mhp)), 5 * s, {color = m.d and 0xFF6050 or 0x7EC850})
            end
            y = y + 34 * s
        end
    end
end)

-- ---- the page, and the same in a window (F6) ----------------------------------------------------------------
local function draw(p)
    p:section("Session")
    p:info("Status", status)
    for id, q in pairs(peers) do
        local here = q.room == room()
        p:info(q.name, q.room ~= "" and (q.room .. (here and "  (here)" or "")) or "in the menus")
        if in_game() and q.room ~= "" and not here then
            if p:button("Go to " .. q.name, {desc = "Takes you to the room " .. q.name .. " is in."}) then G.goto_room(q.room) end
        end
    end
    if not role and not want then
        if p:button("Host a game", {desc = "The others join your address on this port. Over the internet the port must be forwarded to this machine."}) then host() end
        if p:button("Join a game", {desc = "Connects to the address and port below, and keeps trying if the connection drops."}) then join() end
    elseif p:button("Leave", {desc = "Ends the session for you (for everybody if you host)."}) then
        stop("Not connected")
    end
    if role and me then
        p:section("Chat")
        for _, l in ipairs(chat) do p:text(l) end
        local text, kept = p:text_field("Say", say_text, {empty = "type and press Enter"})
        if kept and text ~= "" then
            send({t = "chat", text = text:sub(1, 120)})
            chat[#chat + 1] = cfg.name .. ": " .. text:sub(1, 120)
            if #chat > 6 then table.remove(chat, 1) end
            say_text = ""
        else
            say_text = text
        end
    end
    p:section("Connection")
    local text, kept = p:text_field("Your name", cfg.name, {desc = "Shown over your character on the others' screens."})
    if kept and text ~= "" then cfg.name = text:sub(1, 24) keep("Name", "name") end
    text, kept = p:text_field("Address", cfg.address, {desc = "The host's address (to join)."})
    if kept and text ~= "" then cfg.address = text keep("Address", "address") end
    text, kept = p:text_field("Port", tostring(cfg.port), {desc = "1024 to 65535. The same for everybody."})
    if kept and tonumber(text) and tonumber(text) >= 1024 and tonumber(text) <= 65535 then cfg.port = math.floor(tonumber(text)) keep("Port", "port") end
    p:section("Rules (each player's own)")
    local v, ch = p:toggle("Shared monsters and bosses", cfg.monsters, "A room's monsters are the same for everybody in it: one player's game runs them, they chase and hit every player. Bosses stay each player's own fight, but their gauges fall together. Off: everybody fights their own.")
    if ch then cfg.monsters = v keep("ShareMonsters", "monsters") if not v then release() end end
    v, ch = p:toggle("Shared EXP, SP and drops", cfg.rewards, "A kill in your room gives you its EXP and SP too, and what the monster drops falls for every player: each picks up their own.")
    if ch then cfg.rewards = v keep("ShareRewards", "rewards") end
    v, ch = p:toggle("Revive", cfg.revive, "A hit that would kill you while a teammate stands in the room puts you down for 10 seconds instead (3 times faster with a teammate beside you). If nobody is left standing, the fall is real.")
    if ch then cfg.revive = v keep("Revive", "revive") end
    v, ch = p:toggle("Tougher monsters", cfg.scale, "Monsters have 60 % more HP for each player beyond the first.")
    if ch then cfg.scale = v keep("TougherMonsters", "scale") end
    v, ch = p:toggle("Shared progress", cfg.progress, "Items one player obtains are given to the others (skills, keys, gear), and the chests, locked doors and bosses one player dealt with are done for the others too. Meant for games started together.")
    if ch then cfg.progress = v keep("ShareProgress", "progress") end
    v, ch = p:toggle("Friendly fire", cfg.friendly, "Your hits hurt the others and theirs hurt you. Both players must turn it on.")
    if ch then cfg.friendly = v keep("FriendlyFire", "friendly") for _, q in pairs(peers) do drop_puppet(q) end end
    p:section("Display")
    v, ch = p:toggle("Names over players", cfg.names, "Each player's name and HP over their character.")
    if ch then cfg.names = v keep("ShowNames", "names") end
    v, ch = p:toggle("Party list", cfg.party, "The other players' names, HP and rooms at the top right.")
    if ch then cfg.party = v keep("ShowParty", "party") end
end
cleria.ui.page("Co-op", draw)
cleria.ui.window("coop", {title = "Co-op", pause = false, width = 0.5}, function(p)
    draw(p)
    if p:button("Close") then p:close() end
end)
cleria.input.action("coop", {label = "Open the Co-op window", key = "F6"}, function()
    if cleria.ui.is_open("coop") then cleria.ui.close() else cleria.ui.open("coop") end
end)

-- ---- commands (the console, the tests) ----------------------------------------------------------------------
cleria.command("coop", function(a)
    local cmd, rest = a:match("^(%S*)%s*(.*)$")
    if cmd == "host" then host()
    elseif cmd == "join" then join()
    elseif cmd == "stop" then stop("Not connected")
    elseif cmd == "say" then send({t = "chat", text = rest})
    elseif cmd == "follow" then                          -- go to the first player who is elsewhere
        for _, p in pairs(peers) do
            if p.room ~= "" and p.room ~= room() then say("following to " .. p.room) G.goto_room(p.room) return end
        end
    elseif cmd == "kill" then                            -- (tests) my first monster dies of a hit of mine
        local m = W.actors()[1]
        if m then cleria.combat.damage(m.id, 999999) end
    elseif cmd == "poke" then                            -- (tests) a small hit on the first monster, as a swing would be
        local m = W.actors()[1]
        if m then
            local o = owner_of(room())
            if o and o ~= me then send({t = "dmg", r = room(), a = m.id, n = 5}, o) else cleria.combat.damage(m.id, 5) end
        end
    elseif cmd == "goto" then                            -- (tests) stand beside the first player here, facing them
        for _, p in pairs(peers) do
            if p.room == room() and p.pose and p.pose.x then P.set_position(p.pose.x - 0.9, p.pose.y, p.pose.z, 90) return end
        end
    elseif cmd == "tomonster" then                       -- (tests) stand beside the first monster
        local m = W.actors()[1]
        if m then P.set_position(m.x + 1.0, m.y, m.z, 270) end
    elseif cmd == "give" then                            -- (tests) an item obtained, as a chest would give it
        cleria.content.give(tonumber(rest), 1, "test")
    elseif cmd == "door" then                            -- (tests) a door's flag, as its key would set it
        G.set_flag(tonumber(rest), 1)
        share_flag("door", tonumber(rest))
    elseif cmd == "flag" then
        say("flag " .. rest .. " = " .. tostring(G.flag(tonumber(rest))) .. " item " .. tostring(G.flag(0x59)))
    elseif cmd == "go" then
        G.goto_room(rest)
    elseif cmd == "boost" then                           -- (tests) a full Boost gauge
        P.set_boost(30000)
    elseif cmd == "fall" then                            -- (tests) a hit that would kill me
        cleria.combat.strike(99999)
    else
        local n, pup, here, extra = 0, 0, 0, ""
        for _, p in pairs(peers) do
            n = n + 1
            if p.puppet then pup = pup + 1 end
            if p.room == room() then here = here + 1 end
            if p.pose and p.pose.x then extra = string.format(" peer at %.1f%s", p.pose.x, p.pose.d and " down" or "") end
            if p.props and #p.props > 0 then extra = extra .. " eyes " .. #p.props end
            if p.pose and p.pose.au then extra = extra .. " aura " .. p.pose.au end
            if p.pose and p.pose.gl then extra = extra .. " glow" end
        end
        if drops_seen > 0 then extra = extra .. " drops " .. drops_seen end
        local first, b = W.actors()[1], W.boss()
        if b and not b.actor then extra = extra .. string.format(" boss %.0f%% pool %s", b.hp / b.max_hp * 100, tostring((cleria.combat.boss_bonus() or 0) > 0)) end
        say(string.format("status role %s id %s peers %d here %d puppets %d monsters %d held %s owner %s first hp %s/%s room %s hp %d%s%s", tostring(role),
                          tostring(me), n, here, pup, #W.actors(), tostring(held), tostring(owner_of(room())),
                          first and tostring(math.floor(first.hp)) or "-", first and tostring(math.floor(first.max_hp)) or "-", room(),
                          in_game() and P.hp() or 0, down and " down" or "", extra))
    end
end)

if cfg.auto == "host" then host() elseif cfg.auto == "join" then join() end
say("loaded (F6 or F1 > Mods > Co-op)")

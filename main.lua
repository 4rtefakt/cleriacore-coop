-- Co-op for Ys Origin on CleriaCore (mod API 7).
--
-- One player hosts (a TCP listener), the others join. Every message is one line of JSON. A guest talks to the host
-- only; the host stamps each message with its sender (`from`) and passes it on, so a guest never has to be reachable.
--
--   hello / welcome / join / leave    who is there
--   p     20 times a second: my room and my pose (the others draw a puppet of my character from it)
--   hit   a swing of mine landed on your puppet (friendly fire): your game prices it against your DEF
--   snap  10 times a second, from the OWNER of a room (the lowest id in it): its monsters. The others hold theirs
--         and show these.
--   dmg   a hit of mine on a monster I do not own: the owner lands it
--   kill  the owner's kill: its EXP and SP for everybody in the room
--   item  an item I obtained (shared items)
if not (cleria.net and cleria.net.tcp and cleria.world and cleria.world.puppet) then
    cleria.log("Co-op needs a CleriaCore with mod API 7")
    return
end
local N, W, G, P, J, S = cleria.net, cleria.world, cleria.game, cleria.player, cleria.json, cleria.settings
local PROTOCOL = 1

local cfg = {
    name = S.get("Name", "Player"), address = S.get("Address", "127.0.0.1"), port = S.get("Port", 7777),
    friendly = S.get("FriendlyFire", false), monsters = S.get("ShareMonsters", true), rewards = S.get("ShareRewards", true),
    items = S.get("ShareItems", false), names = S.get("ShowNames", true),
    loopback = S.get("Loopback", false),      -- host on this machine only (tests; no firewall question)
    auto = S.get("Auto", ""),                 -- "host" / "join": start at once (tests, or a session you always resume)
}
local function keep(key, field) S.set(key, cfg[field]) end

-- ---- state --------------------------------------------------------------------------------------------------
local role, me, status = nil, nil, "Not connected"   -- role: nil, "host", "guest"
local listener, link                                   -- the host's listener; a guest's connection
local conns, next_id = {}, 2                           -- the host's guests: {sock =, buf =, id =}
local peers = {}                                       -- [id] = {name, ch, room, pose, puppet}
local held = false                                     -- this room's monsters are another player's: mine are held
local applying = false                                 -- an item given by a message: not announced again

local function say(text) cleria.log("coop: " .. text) end
local function in_game() local s = G.state() return s ~= "title" end
local function room() return in_game() and G.room() or "" end
local function r2(v) return math.floor(v * 100 + 0.5) / 100 end

local function drop_puppet(p)
    if p.puppet then W.remove_puppet(p.puppet) p.puppet = nil end
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
        if link then write(link, m) end
    elseif role == "host" then
        m.from, m.to = me, to
        for _, c in ipairs(conns) do
            if c.id and (not to or c.id == to) then write(c.sock, m) end
        end
    end
end

local handle
local function stop(why)
    if not role then return end
    release()
    for id in pairs(peers) do drop_puppet(peers[id]) end
    peers = {}
    if link then link:close() link = nil end
    for _, c in ipairs(conns) do c.sock:close() end
    conns = {}
    if listener then listener:close() listener = nil end
    role, me = nil, nil
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
local function join()
    stop()
    link = N.tcp()
    link:connect(cfg.address, cfg.port)
    role, me = "guest", nil
    status = "Connecting to " .. cfg.address .. ":" .. cfg.port .. "..."
    say("joining " .. cfg.address .. ":" .. cfg.port)
    return true
end

-- One complete line from a connection. `c` is the host's record of the guest it came from (nil on a guest).
local function line(text, c)
    local m = J.decode(text)
    if type(m) ~= "table" or type(m.t) ~= "string" then return end
    if role == "host" then
        if m.t == "hello" then
            if c.id then return end
            if m.v ~= PROTOCOL then write(c.sock, {t = "no", why = "another version of the Co-op mod"}) c.sock:close() return end
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
    end
end

local link_buf = {}
local function pump()
    if role == "host" then
        for _, e in ipairs(listener:poll()) do
            if e.kind == "accept" then conns[#conns + 1] = {sock = e.socket} end
        end
        for i = #conns, 1, -1 do
            local c = conns[i]
            for _, e in ipairs(c.sock:poll()) do
                if e.kind == "data" then feed(c, e.text, c)
                elseif e.kind == "close" then
                    table.remove(conns, i)
                    if c.id then
                        forget(c.id)
                        for _, o in ipairs(conns) do if o.id then write(o.sock, {t = "leave", from = 1, id = c.id}) end end
                    end
                    break
                end
            end
        end
    elseif role == "guest" and link then
        for _, e in ipairs(link:poll()) do
            if e.kind == "open" then
                link_buf = {}
                write(link, {t = "hello", v = PROTOCOL, name = cfg.name, ch = G.character()})
                status = "Connected, waiting for the host..."
            elseif e.kind == "data" then feed(link_buf, e.text)
            elseif e.kind == "close" then
                stop(me and "The host closed the session" or ("Could not connect: " .. e.text))
                return
            end
        end
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
        if p.room ~= m.r then drop_puppet(p) end
        p.room, p.pose, p.ch, p.hp, p.max_hp = m.r or "", m, m.c or p.ch, m.hp, m.mhp
    elseif t == "hit" then
        if cfg.friendly and in_game() and (m.atk or 0) > 0 then
            cleria.combat.strike(m.atk)
            say("hit by " .. (peers[m.from] and peers[m.from].name or "?"))
        end
    elseif t == "snap" then
        if cfg.monsters and m.r == room() and owner_of(m.r) == m.from and type(m.m) == "table" then
            W.apply(unpack_snapshot(m.m))
            held = true
        end
    elseif t == "dmg" then
        if cfg.monsters and m.r == room() and owner_of(m.r) == me and (m.n or 0) > 0 then cleria.combat.damage(m.a, m.n) end
    elseif t == "kill" then
        if cfg.rewards and m.r == room() then
            if (m.exp or 0) > 0 then P.add_exp(m.exp) end
            if (m.sp or 0) > 0 then P.add_sp(m.sp) end
            say("shared exp " .. tostring(m.exp) .. " sp " .. tostring(m.sp))
        end
    elseif t == "item" then
        if cfg.items and in_game() and type(m.item) == "number" then
            applying = true
            cleria.content.give(m.item, m.count or 1, "coop")
            applying = false
            say("shared item " .. m.item)
        end
    end
end

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
    send({t = "p", r = room(), x = r2(pose.x), y = r2(pose.y), z = r2(pose.z), yaw = r2(pose.yaw), s = pose.sheet, g = pose.tag,
          f = pose.frame, c = G.character(), hp = P.hp(), mhp = P.max_hp()})
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

-- A hit of mine on a monster another player owns: the owner lands it. Here it shows, but never kills.
cleria.combat.add_filter("damage", function(q)
    if not role or not me or not cfg.monsters or q.dir ~= "dealt" or not q.actor then return end
    local r = room()
    local o = owner_of(r)
    if not o or o == me then return end
    send({t = "dmg", r = r, a = q.actor, n = q.value}, o)
    return math.max(0, math.min(q.value, (q.hp or 1) - 1))
end)
cleria.events.on("enemy_killed", function(e)
    if role and me and cfg.rewards and others_here() > 0 and owner_of(room()) == me then
        send({t = "kill", r = room(), exp = e.exp, sp = e.sp})
    end
end)
cleria.events.on("puppet_hit", function(e)
    if not cfg.friendly then return end
    for id, p in pairs(peers) do
        if p.puppet == e.puppet then send({t = "hit", atk = (e.atk or 0) + (e.power or 0)}, id) return end
    end
end)
cleria.events.on("item_obtained", function(e)
    if role and me and cfg.items and not applying and e.source ~= "coop" then send({t = "item", item = e.item, count = e.count}) end
end)
cleria.events.on("room_enter", function()
    held = false                                        -- a new room: its monsters are its own until a snapshot says otherwise
    for _, p in pairs(peers) do p.puppet = nil end      -- the puppets went with the old room
end)

-- ---- every frame: the sockets, then the puppets -------------------------------------------------------------
cleria.events.on("frame", function()
    if role then pump() end
    if not role or not in_game() then return end
    local r = room()
    for _, p in pairs(peers) do
        local m = p.pose
        if p.room == r and m and m.x then
            local set = {x = m.x, y = m.y, z = m.z, yaw = m.yaw, sheet = m.s, tag = m.g, frame = m.f}
            if not p.puppet or not W.set_puppet(p.puppet, set) then
                p.puppet = W.puppet(p.ch, m.x, m.y, m.z, m.yaw)
                if p.puppet then
                    set.hittable = cfg.friendly
                    W.set_puppet(p.puppet, set)
                end
            end
        elseif p.puppet then
            drop_puppet(p)
        end
    end
end)

cleria.hud.layer("coop", function(d)
    if not role or not cfg.names or not in_game() then return end
    local r = room()
    for _, p in pairs(peers) do
        local m = p.pose
        if p.room == r and m and m.x then
            local label = p.name
            if p.hp and p.max_hp and p.max_hp > 0 then label = label .. "  " .. math.floor(p.hp) .. "/" .. math.floor(p.max_hp) end
            d:world_text(m.x, m.y + 2.1, m.z, label, {size = 15 * d.scale, color = 0xFFE08A})
        end
    end
end)

-- ---- the page, and the same in a window (F6) ----------------------------------------------------------------
local function draw(p)
    p:section("Session")
    p:info("Status", status)
    local n = 0
    for id, q in pairs(peers) do
        n = n + 1
        p:info(q.name, q.room ~= "" and (q.room .. (q.room == room() and "  (here)" or "")) or "in the menus")
    end
    if not role then
        if p:button("Host a game", {desc = "The others join your address on this port. Over the internet the port must be forwarded to this machine."}) then host() end
        if p:button("Join a game", {desc = "Connects to the address and port below."}) then join() end
    elseif p:button("Leave", {desc = "Ends the session for you (for everybody if you host)."}) then
        stop("Not connected")
    end
    p:section("Connection")
    local text, kept = p:text_field("Your name", cfg.name, {desc = "Shown over your character on the others' screens."})
    if kept and text ~= "" then cfg.name = text:sub(1, 24) keep("Name", "name") end
    text, kept = p:text_field("Address", cfg.address, {desc = "The host's address (to join)."})
    if kept and text ~= "" then cfg.address = text keep("Address", "address") end
    text, kept = p:text_field("Port", tostring(cfg.port), {desc = "1024 to 65535. The same for everybody."})
    if kept and tonumber(text) and tonumber(text) >= 1024 and tonumber(text) <= 65535 then cfg.port = math.floor(tonumber(text)) keep("Port", "port") end
    p:section("Rules (each player's own)")
    local v, ch = p:toggle("Shared monsters", cfg.monsters, "A room's monsters are the same for everybody in it: one player's game runs them, the others show them. Off: everybody fights their own.")
    if ch then cfg.monsters = v keep("ShareMonsters", "monsters") if not v then release() end end
    v, ch = p:toggle("Shared EXP and SP", cfg.rewards, "A kill in your room gives you its EXP and SP too.")
    if ch then cfg.rewards = v keep("ShareRewards", "rewards") end
    v, ch = p:toggle("Friendly fire", cfg.friendly, "Your hits hurt the others and theirs hurt you. Both players must turn it on.")
    if ch then cfg.friendly = v keep("FriendlyFire", "friendly") for _, q in pairs(peers) do drop_puppet(q) end end
    v, ch = p:toggle("Shared items", cfg.items, "An item one player obtains is given to the others: skills, keys, gear. Meant for two games started together.")
    if ch then cfg.items = v keep("ShareItems", "items") end
    v, ch = p:toggle("Names over players", cfg.names, "Each player's name and HP over their character.")
    if ch then cfg.names = v keep("ShowNames", "names") end
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
    if a == "host" then host()
    elseif a == "join" then join()
    elseif a == "stop" then stop("Not connected")
    elseif a == "kill" then                              -- (tests) my first monster dies of a hit of mine
        local m = W.actors()[1]
        if m then cleria.combat.damage(m.id, 999999) end
    elseif a == "goto" then                              -- (tests) stand beside the first player here, facing them
        for _, p in pairs(peers) do
            if p.room == room() and p.pose and p.pose.x then P.set_position(p.pose.x - 0.9, p.pose.y, p.pose.z, 90) return end
        end
    elseif a == "poke" then                              -- (tests) a small hit on the first monster, as a swing would be
        local m = W.actors()[1]
        if m then
            local o = owner_of(room())
            if o and o ~= me then send({t = "dmg", r = room(), a = m.id, n = 5}, o) else cleria.combat.damage(m.id, 5) end
        end
    else
        local n, pup, here, hp = 0, 0, 0, ""
        for _, p in pairs(peers) do
            n = n + 1
            if p.puppet then pup = pup + 1 end
            if p.room == room() then here = here + 1 end
            if p.pose and p.pose.x then hp = string.format(" peer at %.1f", p.pose.x) end
        end
        local first = W.actors()[1]
        say(string.format("status role %s id %s peers %d here %d puppets %d monsters %d held %s owner %s first hp %s%s", tostring(role), tostring(me),
                          n, here, pup, #W.actors(), tostring(held), tostring(owner_of(room())), first and tostring(math.floor(first.hp)) or "-", hp))
    end
end)

if cfg.auto == "host" then host() elseif cfg.auto == "join" then join() end
say("loaded (F6 or F1 > Mods > Co-op)")

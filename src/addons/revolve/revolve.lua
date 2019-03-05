
_addon.author   = 'Eleven Pies';
_addon.name     = 'Revolve';
_addon.version  = '2.0.0';

require 'common'

local REVOLVE_FRONT = 1;
local REVOLVE_BACK = 2;
local REVOLVE_OFFSET = 3;
local REVOLVE_ALT_FRONT = 4;
local REVOLVE_ALT_BACK = 5;

local ROTDIR_ANY = 0;
local ROTDIR_CCW = 1;
local ROTDIR_CW = 2;

local TURN_NONE = 0;
local TURN_TO = 1;
local TURN_AWAY = 2;

local DISTDIR_TO = 1;
local DISTDIR_AWAY = 2;

local __px;
local __pz;
local __tx;
local __tz;
local __tdist;
local __final_dist;
local __yaw_adj_amt;
local __steps_to_take_end;
local __rotdir_to_use;
local __turn;
local __dist_adj_amt;
local __distdir;
local __dist_steps_to_take_end;
local __steps_to_take_with_delay_start;
local __entity;
local __selfIndex;
local __selfWarp;
local __loop = 0;
local __turn_delay = 0;
local __go = false;
local __turn_delay_to_wait = 15;

local function write_float_hack(addr, value)
    local packed = struct.pack('f', value);
    local unpacked = { struct.unpack('B', packed, 1), struct.unpack('B', packed, 2), struct.unpack('B', packed, 3), struct.unpack('B', packed, 4) };

    -- ashita.memory.write_float appears busted in ashita v3, converting to byte array
    ashita.memory.write_array(addr, unpacked);
end

local function findEntity(entityid)
    -- targid < 0x400
    --   TYPE_MOB || TYPE_NPC || TYPE_SHIP
    -- targid < 0x700
    --   TYPE_PC
    -- targid < 0x800
    --   TYPE_PET

    -- Search players
    for x = 0x400, 0x6FF do
        local ent = GetEntity(x);
        if (ent ~= nil and ent.ServerId == entityid) then
            return x;
        end
    end

    return nil;
end

local function findEntityByName(name)
    -- targid < 0x400
    --   TYPE_MOB || TYPE_NPC || TYPE_SHIP
    -- targid < 0x700
    --   TYPE_PC
    -- targid < 0x800
    --   TYPE_PET

    -- Search players
    for x = 0x400, 0x6FF do
        local ent = GetEntity(x);
        if (ent ~= nil and ent.Name == name) then
            return x;
        end
    end

    return nil;
end

local function getEntityIndex(zoneid, entityid)
    local zonemin = bit.lshift(zoneid, 12) + 0x1000000;

    local entityindex;

    -- Check if entity looks like a mobid
    if (bit.band(zonemin, entityid) == zonemin) then
        entityindex = bit.band(entityid, 0xfff);
    else
        -- Otherwise try finding player in NPC map
        entityindex = findEntity(entityid);
    end

    return entityindex;
end

local function getEntityIndexByName(zoneid, name)
    return findEntityByName(name);
end

local function getEntityIndexByServerId(zoneid, serverId)
    local zonemin = bit.lshift(zoneid, 12) + 0x1000000;

    local entityindex;

    -- Check if entity looks like a mobid
    if (bit.band(zonemin, serverId) == zonemin) then
        entityindex = bit.band(serverId, 0xfff);
    else
        -- Otherwise try finding player in NPC map
        entityindex = findEntity(serverId);
    end

    return entityindex;
end

local function getEntityIndexByNameOrServerId(zoneid, nameOrServerId)
    local serverId = tonumber(nameOrServerId);

    if (tostring(serverId) == nameOrServerId) then
        return getEntityIndexByServerId(zoneid, serverId);
    end

    return getEntityIndexByName(zoneid, nameOrServerId);
end

local function read_fps_divisor() -- borrowed from fps addon
    local fpsaddr = ashita.memory.findpattern('FFXiMain.dll', 0, '81EC000100003BC174218B0D', 0, 0);
    if (fpsaddr == 0) then
        print('[FPS] Could not locate required signature!');
        return true;
    end

    -- Read the address..
    local addr = ashita.memory.read_uint32(fpsaddr + 0x0C);
    addr = ashita.memory.read_uint32(addr);
    return ashita.memory.read_uint32(addr + 0x30);
end

local function diffYaw(y0, y1)
    -- Diff can be lt (-pi) and gt (+pi), so need to adjust
    local result = y0 - y1;
    if (result > math.pi) then
        return result - (2 * math.pi);
    elseif (result < -math.pi) then
        return result + (2 * math.pi);
    end
    return result;
end

local function revolveAnyTarget(targetindex, direction, rotdir, offset, is_alt, alt_target, turn)
    local entity = AshitaCore:GetDataManager():GetEntity();
    local party = AshitaCore:GetDataManager():GetParty();
    if (targetindex ~= nil) then
        local targetEntity = GetEntity(targetindex);
        local altEntity;

        if (targetEntity == nil) then
            return false;
        end

        local selfIndex = party:GetMemberTargetIndex(0);
        local selfWarp = entity:GetWarpPointer(selfIndex);
        local px = entity:GetLocalX(selfIndex);
        local py = entity:GetLocalY(selfIndex);
        local pz = entity:GetLocalZ(selfIndex);
        local pyaw = entity:GetLocalYaw(selfIndex);

        local speed = entity:GetSpeed(selfIndex);
        local status = entity:GetStatus(selfIndex);
        -- On chocobo, so double speed
        if (status == 5) then
            speed = speed * 2;
        end

        local tx = targetEntity.Movement.LocalPosition.X;
        local ty = targetEntity.Movement.LocalPosition.Y;
        local tz = targetEntity.Movement.LocalPosition.Z;
        local tyaw = targetEntity.Movement.LocalPosition.Yaw;

        local tdist = math.sqrt(targetEntity.Distance);

        local final_dist;
        local alt_yaw_away;
        if (is_alt) then
            local zoneid = AshitaCore:GetDataManager():GetParty():GetMemberZone(0);
            altindex = getEntityIndexByNameOrServerId(zoneid, alt_target);
            if (altindex == nil) then
                return false
            end
            altEntity = GetEntity(altindex);
            if (altEntity == nil) then
                return false;
            end

            local ax = altEntity.Movement.LocalPosition.X;
            local ay = altEntity.Movement.LocalPosition.Y;
            local az = altEntity.Movement.LocalPosition.Z;
            local ayaw = altEntity.Movement.LocalPosition.Yaw;

            local deltaz_a_t = az - tz;
            local deltax_a_t = ax - tx;
            local adist = math.sqrt((deltax_a_t * deltax_a_t) + (deltaz_a_t * deltaz_a_t));

            if (direction == REVOLVE_ALT_FRONT) then
                -- Half a yalm in front of "alt target"
                final_dist = adist - 0.5;
                if (final_dist < 0) then
                    final_dist = 0;
                end
            elseif (direction == REVOLVE_ALT_BACK) then
                -- Half a yalm behind "alt target"
                final_dist = adist + 0.5;
            end

            -- Need to calculate relative yaw between "alt target" and target
            alt_yaw_away = 0 - math.atan2(az - tz, ax - tx);
        else
            final_dist = tdist;
        end

        local fps = (60.0 / read_fps_divisor());

        -- Distance to move per frame
        local dist_adj_amt = speed / fps;

        -- Calculate appropriate distance to move
        -- Rotation speed appears to be fixed at original retail movement speed of 4.0
        -- Using player speed here
        local yaw_adj_amt;
        if (tdist > 0) then
            yaw_adj_amt = dist_adj_amt / tdist;
        else
            yaw_adj_amt = 0;
        end

        -- Need to calculate relative yaw between player and target
        local yaw_away = 0 - math.atan2(pz - tz, px - tx);

        -- Target yaw appears to always be 0..2*(+pi) instead of (-pi)..(+pi)
        local tyaw_adj;
        if (tyaw > math.pi) then
            tyaw_adj = tyaw - (2 * math.pi);
        elseif (tyaw < -math.pi) then
            tyaw_adj = tyaw + (2 * math.pi);
        else
            tyaw_adj = tyaw;
        end

        -- Calculate offset for front/back
        local offset_to_use;
        if (direction == REVOLVE_FRONT) then
            offset_to_use = diffYaw(tyaw_adj, yaw_away);
        elseif (direction == REVOLVE_BACK) then
            local revtyaw_adj;
            if (tyaw_adj < 0) then
                revtyaw_adj = tyaw_adj + math.pi;
            else
                revtyaw_adj = tyaw_adj - math.pi;
            end
            offset_to_use = diffYaw(revtyaw_adj, yaw_away);
        elseif (direction == REVOLVE_OFFSET) then
            offset_to_use = offset;
        elseif (direction == REVOLVE_ALT_FRONT or direction == REVOLVE_ALT_BACK) then
            offset_to_use = diffYaw(alt_yaw_away, yaw_away);
        end

        local dist_delta = final_dist - tdist;

        local distdir;
        if (dist_delta < 0) then
            -- Move closer
            distdir = DISTDIR_TO;
        else
            -- Move further away
            distdir = DISTDIR_AWAY;
        end

        local dist_steps_to_take;
        if (dist_adj_amt > 0) then
            dist_steps_to_take = math.abs(dist_delta / dist_adj_amt);
        else
            dist_steps_to_take = 0;
        end

        -- How many iterations to move
        local steps_to_take;
        if (yaw_adj_amt > 0) then
            steps_to_take = math.abs(offset_to_use / yaw_adj_amt);
        else
            steps_to_take = 0;
        end

        local rotdir_to_use;
        if (rotdir == ROTDIR_ANY) then
            -- For ROTDIR_ANY, determine if shortest to go CCW or CW
            if (offset_to_use < 0) then
                rotdir_to_use = ROTDIR_CCW;
            elseif (offset_to_use > 0) then
                rotdir_to_use = ROTDIR_CW;
            end
        else
            rotdir_to_use = rotdir;
        end

        if (selfWarp ~= nil) then
            __tx = tx;
            __tz = tz;
            __tdist = tdist;
            __final_dist = final_dist;
            __yaw_adj_amt = yaw_adj_amt;
            __steps_to_take_end = steps_to_take;
            __rotdir_to_use = rotdir_to_use;
            __turn = turn;
            __dist_adj_amt = dist_adj_amt;
            __distdir = distdir;
            __dist_steps_to_take_end = steps_to_take + dist_steps_to_take;
            __steps_to_take_with_delay_start = steps_to_take + dist_steps_to_take + __turn_delay_to_wait;
            __entity = entity;
            __selfIndex = selfIndex;
            __selfWarp = selfWarp;
            __loop = 0;
            __turn_delay = 0;
            __go = true;
        end
    end
end

local function revolveAny(serverid, direction, rotdir, offset, is_alt, alt_target, turn)
    local targetindex;

    if (serverid ~= nil) then
        local zoneid = AshitaCore:GetDataManager():GetParty():GetMemberZone(0);
        targetindex = getEntityIndex(zoneid, serverid);
    else
        local target = AshitaCore:GetDataManager():GetTarget();
        targetindex = target:GetTargetIndex();
    end

    revolveAnyTarget(targetindex, direction, rotdir, offset, is_alt, alt_target, turn);
end

local function revolveFront(serverid, turn)
    revolveAny(serverid, REVOLVE_FRONT, ROTDIR_ANY, 0, false, nil, turn);
end

local function revolveBack(serverid, turn)
    revolveAny(serverid, REVOLVE_BACK, ROTDIR_ANY, 0, false, nil, turn);
end

local function revolveOffset(serverid, rotdir, offset, turn)
    revolveAny(serverid, REVOLVE_OFFSET, rotdir, offset, false, nil, turn);
end

local function revolveAltFront(serverid, alt_target, turn)
    revolveAny(serverid, REVOLVE_ALT_FRONT, ROTDIR_ANY, 0, true, alt_target, turn);
end

local function revolveAltBack(serverid, alt_target, turn)
    revolveAny(serverid, REVOLVE_ALT_BACK, ROTDIR_ANY, 0, true, alt_target, turn);
end

ashita.register_event('command', function(cmd, nType)
    local args = cmd:args();

    if (#args > 0 and args[1] == '/revolve')  then
        if (#args > 1)  then
            local serverid;
            local offset;
            local alt_target;

            if (string.find(args[2], 'front') == 1)  then
                if (#args > 2) then
                    serverid = tonumber(args[3]);
                else
                    serverid = nil;
                end
                if (args[2] == 'front')  then
                    revolveFront(serverid, TURN_NONE);
                    return true;
                elseif (args[2] == 'frontto') then
                    revolveFront(serverid, TURN_TO);
                    return true;
                elseif (args[2] == 'frontaway') then
                    revolveFront(serverid, TURN_AWAY);
                    return true;
                end
            elseif (string.find(args[2], 'back') == 1)  then
                if (#args > 2) then
                    serverid = tonumber(args[3]);
                else
                    serverid = nil;
                end
                if (args[2] == 'back')  then
                    revolveBack(serverid, TURN_NONE);
                    return true;
                elseif (args[2] == 'backto') then
                    revolveBack(serverid, TURN_TO);
                    return true;
                elseif (args[2] == 'backaway') then
                    revolveBack(serverid, TURN_AWAY);
                    return true;
                end
            elseif (string.find(args[2], 'ccw') == 1)  then
                if (#args > 2) then
                    offset = tonumber(args[3]);
                else
                    offset = nil;
                end
                if (#args > 3) then
                    serverid = tonumber(args[4]);
                else
                    serverid = nil;
                end
                if (args[2] == 'ccw')  then
                    revolveOffset(serverid, ROTDIR_CCW, 0 - math.rad(offset), TURN_NONE);
                    return true;
                elseif (args[2] == 'ccwto') then
                    revolveOffset(serverid, ROTDIR_CCW, 0 - math.rad(offset), TURN_TO);
                    return true;
                elseif (args[2] == 'ccwaway') then
                    revolveOffset(serverid, ROTDIR_CCW, 0 - math.rad(offset), TURN_AWAY);
                    return true;
                end
            elseif (string.find(args[2], 'cw') == 1)  then
                if (#args > 2) then
                    offset = tonumber(args[3]);
                else
                    offset = nil;
                end
                if (#args > 3) then
                    serverid = tonumber(args[4]);
                else
                    serverid = nil;
                end
                if (args[2] == 'cw')  then
                    revolveOffset(serverid, ROTDIR_CW, math.rad(offset), TURN_NONE);
                    return true;
                elseif (args[2] == 'cwto') then
                    revolveOffset(serverid, ROTDIR_CW, math.rad(offset), TURN_TO);
                    return true;
                elseif (args[2] == 'cwaway') then
                    revolveOffset(serverid, ROTDIR_CW, math.rad(offset), TURN_AWAY);
                    return true;
                end
            elseif (string.find(args[2], 'altfront') == 1)  then
                if (#args > 2) then
                    -- Can be string (name) or number (serverid)
                    alt_target = args[3];
                else
                    alt_target = nil;
                end
                if (#args > 3) then
                    serverid = tonumber(args[4]);
                else
                    serverid = nil;
                end
                if (args[2] == 'altfront')  then
                    revolveAltFront(serverid, alt_target, TURN_NONE);
                    return true;
                elseif (args[2] == 'altfrontto') then
                    revolveAltFront(serverid, alt_target, TURN_TO);
                    return true;
                elseif (args[2] == 'altfrontaway') then
                    revolveAltFront(serverid, alt_target, TURN_AWAY);
                    return true;
                end
            elseif (string.find(args[2], 'altback') == 1)  then
                if (#args > 2) then
                    -- Can be string (name) or number (serverid)
                    alt_target = args[3];
                else
                    alt_target = nil;
                end
                if (#args > 3) then
                    serverid = tonumber(args[4]);
                else
                    serverid = nil;
                end
                if (args[2] == 'altback')  then
                    revolveAltBack(serverid, alt_target, TURN_NONE);
                    return true;
                elseif (args[2] == 'altbackto') then
                    revolveAltBack(serverid, alt_target, TURN_TO);
                    return true;
                elseif (args[2] == 'altbackaway') then
                    revolveAltBack(serverid, alt_target, TURN_AWAY);
                    return true;
                end
            elseif (args[2] == 'stop')  then
                __go = false;
            end
        end
    end

    return false;
end);

ashita.register_event('render', function()
    if (__go) then
        if (__loop < __steps_to_take_end) then
            -- Update player position
            __px = __entity:GetLocalX(__selfIndex);
            __pz = __entity:GetLocalZ(__selfIndex);

            local yaw_away = 0 - math.atan2(__pz - __tz, __px - __tx);

            local newyaw = yaw_away;
            if (__rotdir_to_use == ROTDIR_CCW) then
                newyaw = newyaw - __yaw_adj_amt;
            elseif (__rotdir_to_use == ROTDIR_CW) then
                newyaw = newyaw + __yaw_adj_amt;
            end

            -- Position to move player
            local x;
            local z;

            x = __tx + (__tdist * math.cos(newyaw));
            z = __tz - (__tdist * math.sin(newyaw));

            write_float_hack(__selfWarp + 0x34, x);
            write_float_hack(__selfWarp + 0x3C, z);
        elseif (__loop < __dist_steps_to_take_end) then
            -- Update player position
            __px = __entity:GetLocalX(__selfIndex);
            __pz = __entity:GetLocalZ(__selfIndex);

            local yaw_away = 0 - math.atan2(__pz - __tz, __px - __tx);

            local newdist = 0;
            if (__distdir == DISTDIR_TO) then
                newdist = newdist - __dist_adj_amt;
            elseif (__distdir == DISTDIR_AWAY) then
                newdist = newdist + __dist_adj_amt;
            end

            -- Position to move player
            local x;
            local z;

            x = __px + (newdist * math.cos(yaw_away));
            z = __pz - (newdist * math.sin(yaw_away));

            write_float_hack(__selfWarp + 0x34, x);
            write_float_hack(__selfWarp + 0x3C, z);
        elseif (__loop >= __steps_to_take_with_delay_start) then
            -- Need to wait several frames before turning

            -- Update player position
            __px = __entity:GetLocalX(__selfIndex);
            __pz = __entity:GetLocalZ(__selfIndex);

            local yaw_away = 0 - math.atan2(__pz - __tz, __px - __tx);

            -- Set yaw as a final step after all moves
            if (__turn == TURN_TO) then
                -- Direction for player to face
                local final_yaw;

                -- Reverse to face towards target
                if (yaw_away < 0) then
                    final_yaw = yaw_away + math.pi;
                else
                    final_yaw = yaw_away - math.pi;
                end

                write_float_hack(__selfWarp + 0x48, final_yaw);
            elseif (__turn == TURN_AWAY) then
                -- Direction for player to face
                local final_yaw;

                -- Facing away from target
                final_yaw = yaw_away;

                write_float_hack(__selfWarp + 0x48, final_yaw);
            end

            __go = false;
        end

        __loop = __loop + 1;
    end
end);

local gunlib = {}
local attachments = {}
local player_huds = {} 
local last_shot_time = {} 
local player_physics = {} -- Для отслеживания скорости игрока
local gun_settings = {}

-- Список всех возможных слотов в игре
local ALL_SLOTS = {"muzzle", "optic", "underbarrel", "grip"}

-----------------------------------------
-- 1. РЕГИСТРАЦИЯ ПАТРОНОВ, МАГАЗИНОВ И ОБВЕСОВ
-----------------------------------------

core.register_craftitem("gunlib:ammo_45", {
    description = "Ammo .45 ACP",
    inventory_image = "ammo_45.png",
})

-- Новый предмет: Магазин для AK-47
core.register_craftitem("gunlib:mag_ak47", {
    description = "AK-47 Magazine (30 rnds)",
    inventory_image = "mag_ak47.png",
})

core.register_craftitem("gunlib:mag_awp", {
    description = "AWP Magazine (5rnd)",
    inventory_image = "mag_awp.png",
})

function gunlib.register_attachment(name, def)
    attachments[name] = def
    core.register_craftitem(name, {
        description = def.description,
        inventory_image = def.inventory_image,
        groups = {gun_attachment = 1}, 
    })
end

-----------------------------------------
-- 2. ЛОГИКА МЕТАДАННЫХ И СТАТОВ
-----------------------------------------

local function get_attachments(itemstack)
    local str = itemstack:get_meta():get_string("atts")
    if str == "" then return {} end
    return core.deserialize(str) or {}
end

local function set_attachments(itemstack, atts)
    itemstack:get_meta():set_string("atts", core.serialize(atts))
end

local function get_modified_stats(itemstack)
    local itemname = itemstack:get_name()
    local base = gun_settings[itemname]
    if not base then return {}, {} end
    
    local stats = table.copy(base)
    local atts = get_attachments(itemstack)
    
    for slot, att_name in pairs(atts) do
        local adef = attachments[att_name]
        if adef then
            if adef.damage_mult then stats.damage = stats.damage * adef.damage_mult end
            if adef.recoil_mult then stats.recoil = stats.recoil * adef.recoil_mult end
            if adef.spread_mult then stats.spread = stats.spread * adef.spread_mult end
            if adef.fire_interval_mult then stats.fire_interval = stats.fire_interval * adef.fire_interval_mult end
            if adef.speed_mult then stats.move_speed = (stats.move_speed or 1.0) * adef.speed_mult end
            if adef.zoom_fov then stats.zoom_fov = adef.zoom_fov end
            if adef.sound then stats.sound = adef.sound end
            if adef.is_laser then stats.has_laser = true end
            if adef.is_silencer then stats.is_silenced = true end
        end
    end
    return stats, atts
end

-----------------------------------------
-- 3. ИНВЕНТАРЬ ДЛЯ ОБВЕСОВ (СЛОТЫ)
-----------------------------------------

core.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    local inv = core.create_detached_inventory("gun_atts_" .. name, {
        allow_put = function(inv, listname, index, stack, player)
            local wstack = player:get_wielded_item()
            local itemname = wstack:get_name()
            
            if core.get_item_group(itemname, "gun") == 0 then return 0 end
            
            local gun_def = gun_settings[itemname]
            if not gun_def or not gun_def.allowed_slots or not gun_def.allowed_slots[listname] then
                return 0 
            end

            local def = attachments[stack:get_name()]
            if def and def.slot == listname then return 1 end
            return 0
        end,
        
        on_put = function(inv, listname, index, stack, player)
            local wstack = player:get_wielded_item()
            if core.get_item_group(wstack:get_name(), "gun") > 0 then
                local atts = get_attachments(wstack)
                atts[listname] = stack:get_name() 
                set_attachments(wstack, atts)
                player:set_wielded_item(wstack)
            end
        end,
        
        on_take = function(inv, listname, index, stack, player)
            local wstack = player:get_wielded_item()
            if core.get_item_group(wstack:get_name(), "gun") > 0 then
                local atts = get_attachments(wstack)
                atts[listname] = nil
                set_attachments(wstack, atts)
                player:set_wielded_item(wstack)
            end
        end,
    })
    
    for _, slot in ipairs(ALL_SLOTS) do inv:set_size(slot, 1) end
end)

-----------------------------------------
-- 4. ВЗРЫВЧАТКА И СНАРЯДЫ 
-----------------------------------------

-- Центральная функция детонации
-- This function handles the actual damage and destruction of the explosion
function gunlib.detonate(pos, strength, thrower_name)
    core.sound_play("explosion", {pos = pos, gain = 2.0, max_hear_distance = 64}) -- Лучше заменить на "explosion"
    local radius = math.max(1, strength * 3)    
    -- Частицы взрыва
    core.add_particle({
        pos = pos,
        velocity = {x=0, y=0, z=0},
        acceleration = {x=0, y=0, z=0},
        expirationtime = 0.5,
        size = strength * 10,
        collisiondetection = false,
        texture = "tnt_boom.png", -- Ensure you have this texture or change it
        glow = 10,
    })
    if strength > 0 then
        -- Урон энтити
        for _, obj in pairs(core.get_objects_inside_radius(pos, radius)) do
            if obj:is_player() or obj:get_luaentity() then
                -- Урон падает в зависимости от расстояния от центра
                local dist = vector.distance(pos, obj:get_pos())
                local dmg = math.max(1, (radius - dist) / radius * (strength * 5))
                obj:punch(obj, 1.0, {full_punch_interval=1.0, damage_groups={fleshy=dmg}})
            end
        end       
        -- Разрушение блоков (Strength 4+)
        if strength >= 4 then
            local r = math.floor(strength)
            for x = -r, r do
                for y = -r, r do
                    for z = -r, r do
                        if x*x + y*y + z*z <= r*r then
                            local p = vector.add(pos, {x=x, y=y, z=z})
                            local node = core.get_node(p)
                            if node.name ~= "air" and node.name ~= "ignore" then
                                -- Защита от разрушения неразрушимых блоков (админиум и тд)
                                if core.registered_nodes[node.name] and not core.registered_nodes[node.name].on_blast then
                                   core.remove_node(p)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
-- Внутренняя функция для обработки типов гранат
local function trigger_detonation(pos, def, thrower)
    local exp_type = def.type or "HE" -- По умолчанию осколочная (High Explosive)

    if exp_type == "HE" then
        gunlib.detonate(pos, def.strength or 1, thrower)
        
    elseif exp_type == "SG" then
        core.sound_play(def.detonate_sound or "smoke_hiss", {pos = pos, gain = 1.0, max_hear_distance = 32})
        core.add_particlespawner({
            amount = def.smoke_amount or 300,
            time = def.smoke_duration or 12,
            minpos = vector.subtract(pos, 3),
            maxpos = vector.add(pos, 3),
            minvel = {x=-1, y=0, z=-1},
            maxvel = {x=1, y=1, z=1},
            minexptime = 3,
            maxexptime = 5,
            minsize = 30,
            maxsize = 50,
            texture = "smoke_puff.png",
            glow = 0
        })
        
    elseif exp_type == "Flash" then
        core.sound_play(def.detonate_sound or "flashbang_boom", {pos = pos, gain = 3.0, max_hear_distance = 64})
        local radius = def.flash_radius or 15
        local duration = def.flash_duration or 3.0
        
        for _, obj in pairs(core.get_objects_inside_radius(pos, radius)) do
            if obj:is_player() then
                local head_pos = vector.add(obj:get_pos(), {x=0, y=1.62, z=0})
                local ray = core.raycast(pos, head_pos, true, false)
                local hit = ray:next()
                
                if hit and hit.type == "object" and hit.ref == obj then
                    local pname = obj:get_player_name()
                    local flash_id = obj:hud_add({
                        hud_elem_type = "image",
                        position = {x = 0.5, y = 0.5},
                        scale = {x = -100, y = -100},
                        text = "flash_white.png", 
                        alignment = {x = 0, y = 0},
                        offset = {x = 0, y = 0}
                    })
                    core.after(duration, function()
                        local p = core.get_player_by_name(pname)
                        if p then p:hud_remove(flash_id) end
                    end)
                end
            end
        end
    end

    -- Оставляем возможность добавлять УНИКАЛЬНЫЙ код даже поверх встроенных типов
    if def.on_detonate then def.on_detonate(pos, thrower) end
end

-- Регистрация типа взрывчатки (Граната/Ракета)
function gunlib.register_explosive(name, def)
    core.register_craftitem(name, {
        description = def.description,
        inventory_image = def.inventory_image,
        on_use = function(itemstack, user, pointed_thing)
            if not def.is_throwable then return itemstack end
            
            local pos = user:get_pos()
            local dir = user:get_look_dir()
            local start_p = {x = pos.x, y = pos.y + (user:get_properties().eye_height or 1.62), z = pos.z}
            
            local obj = core.add_entity(start_p, name .. "_entity")
            if obj then
                local ent = obj:get_luaentity()
                ent.thrower = user:get_player_name()
                obj:set_velocity(vector.multiply(dir, def.velocity or 15))
                itemstack:take_item()
            end
            return itemstack
        end
    })

    core.register_entity(name .. "_entity", {
        initial_properties = {
            physical = false,
            visual = "sprite",
            textures = {def.inventory_image},
            visual_size = {x=0.5, y=0.5},
            pointable = false,
        },
        timer = def.timer or 0,
        age = 0,
        
        on_activate = function(self, staticdata)
            self.object:set_acceleration({x=0, y=-(def.gravity or 9.8), z=0})
        end,
        
        on_step = function(self, dtime)
            self.age = self.age + dtime
            
            if def.timer and self.age >= def.timer then
                trigger_detonation(self.object:get_pos(), def, self.thrower)
                self.object:remove()
                return
            end

            if def.gravity == 0 then
                core.add_particle({
                    pos = self.object:get_pos(),
                    expirationtime = 0.3, size = 2, texture = "smoke_puff.png"
                })
            end

            local pos = self.object:get_pos()
            local vel = self.object:get_velocity()
            local next_pos = vector.add(pos, vector.multiply(vel, dtime))
            
            local ray = core.raycast(pos, next_pos, true, false)
            local hit = ray:next()
            
            while hit and hit.type == "object" and hit.ref:get_player_name() == self.thrower do
                hit = ray:next()
            end

            if hit then
                if def.on_impact then
                    local hit_p = hit.intersection_point or next_pos
                    trigger_detonation(hit_p, def, self.thrower)
                    self.object:remove()
                else
                    local norm = hit.intersection_normal
                    if norm then
                        local dot = vel.x*norm.x + vel.y*norm.y + vel.z*norm.z
                        local reflect = {
                            x = vel.x - 2 * dot * norm.x,
                            y = vel.y - 2 * dot * norm.y,
                            z = vel.z - 2 * dot * norm.z
                        }
                        
                        local new_vel = vector.multiply(reflect, 0.5)
                        
                        if vector.length(new_vel) < 1.0 and norm.y > 0.5 then
                            new_vel = {x=0, y=0, z=0}
                            self.object:set_acceleration({x=0, y=0, z=0})
                        end

                        self.object:set_velocity(new_vel)
                        local safe_pos = vector.add(hit.intersection_point, vector.multiply(norm, 0.05))
                        self.object:set_pos(safe_pos)
                    end
                end
            end
        end
    })
end

-----------------------------------------
-- 5. HUD И ЛОГИКА СТРЕЛЬБЫ ПУЛЯМИ
-----------------------------------------

local function update_hud(player, itemstack)
    local name = player:get_player_name()
    local itemname = itemstack:get_name()
    
    if itemstack and core.get_item_group(itemname, "gun") > 0 then
        local meta = itemstack:get_meta()
        local ammo = meta:get_int("ammo")
        local now = core.get_gametime()
        local reloading = meta:get_float("reload_done") > now
        local stats, atts = get_modified_stats(itemstack)
        
        local att_str = ""
        for _, att_name in pairs(atts) do
            local adef = attachments[att_name]
            if adef then att_str = att_str .. "[" .. (adef.short_name or adef.description) .. "] " end
        end
        if att_str ~= "" then att_str = att_str .. "\n" end
        
        local str = ""
        local color = 0xFFFFFF
        
        if reloading then
            str = att_str .. "RELOADING..."
            color = 0xFF0000
        else
            local mode = stats.fire_mode == "auto" and "[AUTO]" or (stats.fire_mode == "spray" and "[SPRAY]" or (stats.fire_mode == "explosive" and "[LAUNCHER]" or "[SEMI]"))
            str = att_str .. mode .. " Ammo: " .. ammo .. " / " .. (stats.mag_size or 0)
        end
        
        if not player_huds[name] then
            player_huds[name] = player:hud_add({
                hud_elem_type = "text", position = {x = 1, y = 1}, offset = {x = -150, y = -75},
                text = str, number = color,
            })
        else
            player:hud_change(player_huds[name], "text", str)
            player:hud_change(player_huds[name], "number", color)
        end
    elseif player_huds[name] then
        player:hud_remove(player_huds[name])
        player_huds[name] = nil
    end
end

local function shot_logic(itemstack, user, settings)
    local meta = itemstack:get_meta()
    local now_gt = core.get_gametime()
    
    if meta:get_string("inf") == "" then
        meta:set_int("ammo", settings.mag_size)
        meta:set_string("inf", "yes")
        itemstack:set_count(settings.mag_size)
    end

    if meta:get_float("reload_done") > now_gt then return itemstack end

    local name = user:get_player_name()
    local now_us = core.get_us_time() / 1000000
    local last_shot = last_shot_time[name] or 0
    if now_us - last_shot < (settings.fire_interval or 0.2) then return itemstack end

    local ammo = meta:get_int("ammo")
    if ammo <= 0 then
        -- NEW: Uses empty_sound parameter!
        core.sound_play(settings.empty_sound or "gun_click", {object = user, gain = 0.6})
        last_shot_time[name] = now_us
        return itemstack
    end

    local pos = user:get_pos()
    local dir = user:get_look_dir()
    local start_p = {x = pos.x, y = pos.y + (user:get_properties().eye_height or 1.62), z = pos.z}

    -- ЕСЛИ ЭТО ГРАНАТОМЕТ/РПГ
    if settings.fire_mode == "explosive" then
        local obj = core.add_entity(start_p, settings.ammo_type .. "_entity")
        if obj then
            local ent = obj:get_luaentity()
            ent.thrower = user:get_player_name()
            -- Множитель скорости из настроек пусковой установки
            obj:set_velocity(vector.multiply(dir, settings.projectile_velocity or 20))
        end
    else
        -- ОБЫЧНАЯ СТРЕЛЬБА (Raycast)
        local pellets = settings.pellets or 1
        local base_spread = settings.spread or 0.05
        local velocity = user:get_velocity() or {x=0, y=0, z=0}
        local speed = vector.length(velocity)

        if speed > 0.5 then base_spread = base_spread * 2.0 end
        if user:get_player_control().zoom then base_spread = base_spread * 0.5 end

        for i = 1, pellets do
            local rx = (math.random() - 0.5) * base_spread
            local ry = (math.random() - 0.5) * base_spread
            local rz = (math.random() - 0.5) * base_spread
            local final_dir = vector.normalize({x = dir.x + rx, y = dir.y + ry, z = dir.z + rz})
            
            local end_p = vector.add(start_p, vector.multiply(final_dir, 100))
            local ray = core.raycast(start_p, end_p, true, false)
            
            local hit = ray:next()
            while hit and hit.type == "object" and hit.ref == user do hit = ray:next() end

            if hit then
                local hit_pos = hit.intersection_point or end_p
                if hit.type == "object" then
                    hit.ref:punch(user, 1.0, {full_punch_interval = 0.1, damage_groups = {fleshy = settings.damage}})
                end
                core.add_particle({
                    pos = hit_pos, velocity = {x=0, y=1, z=0}, expirationtime = 0.4,
                    size = 1.0, texture = "smoke_puff.png", glow = 5
                })
            end
        end
    end

    local fire_snd = settings.sound or "gun_shot"
    if settings.is_silenced then fire_snd = settings.silenced_sound or "gun_silenced" end
    core.sound_play(fire_snd, {object = user, gain = 1.0})
    
    user:set_look_vertical(user:get_look_vertical() - (settings.recoil or 0.1))
    ammo = ammo - 1
    meta:set_int("ammo", ammo)
    
    -- Swap to empty texture if out of ammo
    if ammo <= 0 and settings.texture_empty then
        meta:set_string("inventory_image", settings.texture_empty)
    end
    itemstack:set_count(math.max(1, ammo))
    meta:set_string("description", settings.description .. "\nAmmo: " .. ammo .. "/" .. settings.mag_size)
    if ammo >= 1 then
		last_shot_time[name] = now_us
	end
    
    return itemstack
end

-----------------------------------------
-- 6. ГЛОБАЛЬНЫЙ ЦИКЛ (Физика, Лазер, Зум)
-----------------------------------------

local laser_timer = 0
core.register_globalstep(function(dtime)
    laser_timer = laser_timer + dtime
    local do_laser = laser_timer > 0.1
    if do_laser then laser_timer = 0 end

    for _, player in ipairs(core.get_connected_players()) do
        local item = player:get_wielded_item()
        local itemname = item:get_name()
        local control = player:get_player_control()
        local p_name = player:get_player_name()
        
        update_hud(player, item)
        
        if core.get_item_group(itemname, "gun") > 0 then
            local stats = get_modified_stats(item)
            local meta = item:get_meta()
            local changed = false

            -- FIX: Proactive Initialization (For Creative Mode/New Items)
            -- If the gun is new (no "inf" key), we set it up immediately when held
            if meta:get_string("inf") == "" then
                meta:set_int("ammo", stats.mag_size)
                meta:set_string("inf", "yes")
                meta:set_string("inventory_image", stats.inventory_image)
                item:set_count(math.max(1, stats.mag_size))
                changed = true
            end

            -- FIX: Automatic Texture Check
            -- Switches texture between Full and Empty based on current ammo
            local ammo = meta:get_int("ammo")
            local current_tex = meta:get_string("inventory_image")

            if ammo <= 0 and stats.texture_empty then
                if current_tex ~= stats.texture_empty then
                    meta:set_string("inventory_image", stats.texture_empty)
                    changed = true
                end
            elseif ammo > 0 then
                if current_tex ~= stats.inventory_image then
                    meta:set_string("inventory_image", stats.inventory_image)
                    changed = true
                end
            end

            -- Apply changes to the item in the player's hand
            if changed then
                player:set_wielded_item(item)
            end

            -- Movement Physics
            local target_speed = stats.move_speed or 1.0
            if player_physics[p_name] ~= target_speed then
                player:set_physics_override({speed = target_speed})
                player_physics[p_name] = target_speed
            end

            -- Laser Logic
            if stats.has_laser and do_laser then
                local pos = player:get_pos()
                local dir = player:get_look_dir()
                local start_p = {x = pos.x, y = pos.y + (player:get_properties().eye_height or 1.62), z = pos.z}
                local end_p = vector.add(start_p, vector.multiply(dir, 200))
                local ray = core.raycast(start_p, end_p, true, false)
                local hit = ray:next()
                while hit and hit.type == "object" and hit.ref == player do hit = ray:next() end
                local hit_pos = hit and hit.intersection_point or end_p
                core.add_particle({
                    pos = hit_pos, expirationtime = 0.15, size = 5, texture = "laser_dot.png", glow = 14
                })
            end
            
            -- Zoom Logic
            if control.zoom then
                player:set_fov(stats.zoom_fov or 40, false)
            else
                player:set_fov(0)
            end

            -- Auto Fire Logic
            if (stats.fire_mode == "auto") and control.LMB then
                player:set_wielded_item(shot_logic(item, player, stats))
            end
        else
            -- Reset physics if not holding a gun
            if player_physics[p_name] and player_physics[p_name] ~= 1.0 then
                player:set_physics_override({speed = 1.0})
                player_physics[p_name] = 1.0
            end
            if player:get_fov() ~= 0 then player:set_fov(0) end
        end
    end
end)

-----------------------------------------
-- 7. РЕГИСТРАЦИЯ ПУШЕК И ПУСКОВЫХ УСТАНОВОК
-----------------------------------------

function gunlib.register(name, def)
    gun_settings[name] = def
    core.register_tool(name, {
        description = def.description,
        inventory_image = def.inventory_image,
        stack_max = def.mag_size,
        groups = {gun = 1},

        on_use = function(itemstack, user)
            local stats = get_modified_stats(itemstack)
            
            -- If it's a click-based fire mode, just run the shot logic
            if stats.fire_mode == "semi" or stats.fire_mode == "spray" or stats.fire_mode == "explosive" then
                return shot_logic(itemstack, user, stats)
            end
            
            return itemstack
        end,

        on_place = function(itemstack, user)
            local control = user:get_player_control()
            local name = user:get_player_name()
            
            if control.sneak then
                local inv = core.get_inventory({type="detached", name="gun_atts_"..name})
                local atts = get_attachments(itemstack)
                local stats = get_modified_stats(itemstack)
                
                for _, slot in ipairs(ALL_SLOTS) do inv:set_stack(slot, 1, "") end
                
                local fs = "size[8,6.5]"
                local x_pos = 0.5
                
                if stats.allowed_slots then
                    for _, slot in ipairs(ALL_SLOTS) do
                        if stats.allowed_slots[slot] then
                            inv:set_stack(slot, 1, atts[slot] or "")
                            local label = slot:gsub("^%l", string.upper)
                            fs = fs .. "label["..x_pos..",0.2;"..label.."]" ..
                                       "list[detached:gun_atts_"..name..";"..slot..";"..x_pos..",0.8;1,1;]"
                            x_pos = x_pos + 1.8 
                        end
                    end
                end
                
                fs = fs .. "label[0,2;Your Inventory:]list[current_player;main;0,2.5;8,4;]listring[]"
                core.show_formspec(name, "gunlib:att_menu", fs)
                return itemstack
            end

            -- ПЕРЕЗАРЯДКА
            local stats = get_modified_stats(itemstack)
            local meta = itemstack:get_meta()
            local now = core.get_gametime()

            if meta:get_float("reload_done") > now then return itemstack end

            local ammo = meta:get_int("ammo")
            local missing = stats.mag_size - ammo

            if missing > 0 then
                local inv = user:get_inventory()
                local can_use_mag = stats.magazine_type and inv:contains_item("main", stats.magazine_type)
                local can_use_ammo = stats.ammo_type and (not stats.magazine_type) and inv:contains_item("main", stats.ammo_type)

                if can_use_mag or can_use_ammo then
                    local r_time = stats.reload_time or 2.0
                    meta:set_float("reload_done", now + r_time)
                    core.sound_play(stats.reload_sound or "gun_reload", {object = user, gain = 1.0})

                    core.after(r_time, function()
                        local stack = user:get_wielded_item()
                        if stack:get_name() == itemstack:get_name() then
                            local inv2 = user:get_inventory()
                            local new_meta = stack:get_meta()
                            local current_ammo = new_meta:get_int("ammo")
                            local added = 0
                            
                            if can_use_mag then
                                local mag_stack = ItemStack(stats.magazine_type)
                                mag_stack:set_count(1)
                                local removed = inv2:remove_item("main", mag_stack)
                                if removed:get_count() > 0 then added = stats.mag_size - current_ammo end
                            else
                                local ammo_stack = ItemStack(stats.ammo_type)
                                ammo_stack:set_count(stats.mag_size - current_ammo)
                                local removed = inv2:remove_item("main", ammo_stack)
                                added = removed:get_count()
                            end
                            
                            if added > 0 then
								new_meta:set_int("ammo", current_ammo + added)
								-- Restore the original texture
								new_meta:set_string("inventory_image", stats.inventory_image)
								
								stack:set_count(math.max(1, current_ammo + added))
								user:set_wielded_item(stack)
							end
                        end
                    end)
                end
            end
            return itemstack
        end,
    })
end

-- Функция-обертка для Гранатометов/РПГ
function gunlib.register_weapon_explosive(name, def)
    def.fire_mode = "explosive"
    gunlib.register(name, def)
end

-----------------------------------------
-- 8. ПРИМЕРЫ (ОБВЕСЫ, ПУШКИ, ВЗРЫВЧАТКА)
-----------------------------------------

-- Обвесы... (оставлены без изменений)
gunlib.register_attachment("gunlib:silencer", {description = "Silencer", short_name = "SIL", inventory_image = "silencer.png", slot = "muzzle", damage_mult = 0.85, recoil_mult = 0.5, is_silencer = true})
gunlib.register_attachment("gunlib:heavy_barrel", {description = "Heavy Barrel", short_name = "H-BAR", inventory_image = "heavy_barrel.png", slot = "muzzle", damage_mult = 1.3, fire_interval_mult = 1.5, speed_mult = 0.85})
gunlib.register_attachment("gunlib:red_dot", {description = "Red Dot Sight", short_name = "SIGHT", inventory_image = "red_dot.png", slot = "optic", zoom_fov = 53, spread_mult = 0.8})
gunlib.register_attachment("gunlib:2x_scope", {description = "2X Scope", short_name = "2X-SCOPE", inventory_image = "2x_scope.png", slot = "optic", zoom_fov = 28, spread_mult = 0.7})
gunlib.register_attachment("gunlib:4x_scope", {description = "4X Scope", short_name = "4X-SCOPE", inventory_image = "4x_scope.png", slot = "optic", zoom_fov = 13, spread_mult = 0.6})
gunlib.register_attachment("gunlib:8x_scope", {description = "8X Scope", short_name = "8X-SCOPE", inventory_image = "8x_scope.png", slot = "optic", zoom_fov = 4, spread_mult = 0.4})
gunlib.register_attachment("gunlib:laser", {description = "Laser Sight", short_name = "LASER", inventory_image = "laser.png", slot = "underbarrel", is_laser = true, spread_mult = 0.6})
gunlib.register_attachment("gunlib:vertical_grip", {description = "Vertical Grip", short_name = "V-GRIP", inventory_image = "vertical_grip.png", slot = "grip", recoil_mult = 0.6, spread_mult = 0.85})

-- Пушки...
gunlib.register("gunlib:deagle", {
    description = "Desert Eagle", inventory_image = "deagle.png", damage = 4, mag_size = 7,
    recoil = 0.2, spread = 0.04, move_speed = 0.95, fire_mode = "semi", fire_interval = 0.5, reload_time = 3, zoom_fov = 68,
    ammo_type = "gunlib:ammo_45", sound = "deagle_shot", reload_sound = "deagle_reload", silenced_sound = "deagle_silenced",
    allowed_slots = {muzzle = true, optic = true, underbarrel = true}
})

gunlib.register("gunlib:ak47", {
    description = "AK-47", inventory_image = "ak47.png", texture_empty = "ak47_empty.png", damage = 1, mag_size = 30,
	empty_sound = "ak47_click",
    recoil = 0.05, spread = 0.08, move_speed = 0.85, fire_mode = "auto", fire_interval = 0.1, reload_time = 2.4, zoom_fov = 66,
    magazine_type = "gunlib:mag_ak47", sound = "ak47_shot", reload_sound = "ak47_reload", silenced_sound = "ak47_silenced",
    allowed_slots = {muzzle = true, optic = true, underbarrel = true, grip = true}
})

-- === НОВЫЕ ПРИМЕРЫ ВЗРЫВЧАТКИ ===

-- 2. Снаряд для РПГ-7 (Блоки ломает, летит прямо, взрыв при касании)
gunlib.register_explosive("gunlib:rocket_pg7v", {
    description = "PG-7V Rocket",
    inventory_image = "rocket.png",
    is_throwable = false, -- Руками бросать нельзя, только заряжать
    on_impact = true,     -- Взрывается от столкновения со стеной/игроком
    gravity = 0,          -- Летит идеально прямо (без падения)
    strength = 5          -- Разрушает блоки (4+)
})

-- 3. Сама пусковая установка РПГ-7
gunlib.register_weapon_explosive("gunlib:rpg7", {
    description = "RPG-7 Launcher",
    inventory_image = "rpg7.png",
	texture_empty = "rpg7_empty.png",
    mag_size = 1,             -- Однозарядный
    recoil = 0.5,             -- Сильно подкидывает камеру
    move_speed = 0.6,         -- Очень тяжелый
	spread = 0.0,
    fire_interval = 1.0, 
    reload_time = 4.0, 
    zoom_fov = 50,
    
    projectile_velocity = 40, -- Выплёвывает снаряд на огромной скорости
    ammo_type = "gunlib:rocket_pg7v", -- Использует зарегистрированный выше снаряд
    sound = "gun_shot",       -- Заменишь потом на "rpg_fire"
    
    allowed_slots = {optic = true} -- На РПГ можно повесить прицел!
})

gunlib.register("gunlib:awp", {
    description = "AWP",
    inventory_image = "awp.png",
	texture_empty = "awp_empty.png",
    damage = 20, mag_size = 5,
    recoil = 0.4, spread = 0.0, move_speed = 0.65,
    fire_mode = "semi", fire_interval = 1.1, reload_time = 2.5, zoom_fov = 58,
    magazine_type = "gunlib:mag_awp",
    sound = "awp_shot",
	reload_sound = "awp_reload",
	silenced_sound = "deagle_silenced",
    allowed_slots = {muzzle = true, optic = true, underbarrel = true}
})

gunlib.register("gunlib:remington", {
    description = "Remington 870",
    inventory_image = "remington.png",
    damage = 2, pellets = 8, mag_size = 6,
    recoil = 0.5, spread = 0.15, move_speed = 0.8,
    fire_mode = "spray", fire_interval = 0.8, reload_time = 4.0, zoom_fov = 70,
    ammo_type = "gunlib:ammo_45",
    sound = "remington_shot",
	reload_sound = "remington_reload",
    allowed_slots = {muzzle = true, optic = true}
})

-- 1. Граната F1 (High Explosive)
gunlib.register_explosive("gunlib:grenade_f1", {
    description = "F1 Frag Grenade",
    inventory_image = "grenade.png",
    type = "HE",          -- NEW!
    is_throwable = true,
    timer = 3.0,
    gravity = 9.8,
    velocity = 15,
    strength = 3
})

-- 2. Дымовая граната (Smoke Grenade)
gunlib.register_explosive("gunlib:grenade_smoke", {
    description = "Smoke Grenade",
    inventory_image = "grenade_smoke.png",
    type = "SG",          -- NEW!
    is_throwable = true,
    timer = 2.5,
    gravity = 9.8,
    velocity = 15,
    smoke_amount = 400,   -- Custom parameters!
    smoke_duration = 15,
    detonate_sound = "smoke_hiss"
})

-- 3. Светошумовая граната (Flashbang)
gunlib.register_explosive("gunlib:grenade_flash", {
    description = "Flashbang",
    inventory_image = "grenade_flash.png",
    type = "Flash",       -- NEW!
    is_throwable = true,
    timer = 2.0,
    gravity = 9.8,
    velocity = 15,
    flash_radius = 20,    -- Custom parameters!
    flash_duration = 4.0,
    detonate_sound = "flashbang_boom"
})
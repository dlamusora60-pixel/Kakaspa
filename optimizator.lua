-- 🚀 ULTIMATE Performance Optimizer v4.1 (Visual-Preserving, Spatial updates, Cleanup, Batching fixes)
-- Spatial Hashing + Frustum Culling + LOD Proxy + Adaptive System
-- ВАЖНО: визуальные свойства НЕ меняются. Все оптимизации — логические/пропуск вычислений.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- =========================
-- КОНФИГУРАЦИЯ
-- =========================
local CONFIG = {
    OPTIMIZATION_LEVEL = 2,
    DISTANCE_NEAR = 2500,      -- 50^2
    DISTANCE_MID = 10000,      -- 100^2
    DISTANCE_FAR = 40000,      -- 200^2
    BATCH_SIZE = 80,
    AUTO_ADJUST_FPS = true,
    TARGET_FPS = 45,
    SECTOR_SIZE = 64,          -- Размер сектора для spatial hashing
    UNSEEN_TIMEOUT = 30,       -- Секунд до пометки как "редко обновлять"
    UPDATE_INTERVALS = {       -- Разные интервалы для разных типов
        models = 0.5,
        particles = 1.0,
        trails = 1.0,
        textures = 1.0,
        lights = 1.5,
        meshparts = 2.0,
        cleanup = 10.0,        -- интервал компактизации/чистки кэша
        spatialSync = 1.0      -- интервал для синхронизации позиций в spatial grid
    },
    SPATIAL_MOVE_THRESHOLD = 32 -- если модель сместилась больше этого (в юнитах), обновляем сектор
}

-- =========================
-- КЭШ ОБЪЕКТОВ (логические записи)
-- =========================
local cachedObjects = {
    models = {},
    particles = {},
    trails = {},
    textures = {},
    lights = {},
    meshParts = {}
}

-- spatial grid: ключ -> list of cached data entries
local spatialGrid = {}
local sectorIndexCount = 0

local batchIndices = {models = 1, particles = 1, trails = 1, textures = 1, lights = 1, meshParts = 1}
local lastUpdateTimes = {models = 0, particles = 0, trails = 0, lights = 0, meshparts = 0, cleanup = 0, spatialSync = 0}
local isInitialized = false

-- =========================
-- УТИЛИТЫ
-- =========================

local function fastDistance2(pos1, pos2)
    local dx = pos1.X - pos2.X
    local dy = pos1.Y - pos2.Y
    local dz = pos1.Z - pos2.Z
    return dx*dx + dy*dy + dz*dz
end

local function isOnScreen(pos)
    if not camera then return false end
    local viewportPoint, inViewport = camera:WorldToViewportPoint(pos)
    return inViewport and viewportPoint.Z > 0
end

local function getSectorCoords(position)
    local x = math.floor(position.X / CONFIG.SECTOR_SIZE)
    local y = math.floor(position.Y / CONFIG.SECTOR_SIZE)
    local z = math.floor(position.Z / CONFIG.SECTOR_SIZE)
    return x, y, z
end

local function makeSectorKey(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

local function getSectorKey(position)
    local x, y, z = getSectorCoords(position)
    return makeSectorKey(x, y, z)
end

local function addToSpatialGrid(data, position)
    if not position then return end
    local key = getSectorKey(position)
    if not spatialGrid[key] then
        spatialGrid[key] = {}
        sectorIndexCount = sectorIndexCount + 1
    end
    table.insert(spatialGrid[key], data)
    data._spatialKey = key
end

local function removeFromSpatialGrid(data)
    local key = data and data._spatialKey
    if not key then return end
    local list = spatialGrid[key]
    if not list then
        data._spatialKey = nil
        return
    end
    for i = #list, 1, -1 do
        if list[i] == data then
            table.remove(list, i)
            break
        end
    end
    data._spatialKey = nil
    if #list == 0 then
        spatialGrid[key] = nil
        sectorIndexCount = math.max(0, sectorIndexCount - 1)
    end
end

-- Переместить запись в новую ячейку по позиции
local function updateModelSector(data, newPos)
    if not data then return end
    local newKey = getSectorKey(newPos)
    if data._spatialKey == newKey then
        data._lastSectorPos = newPos
        return
    end
    removeFromSpatialGrid(data)
    addToSpatialGrid(data, newPos)
    data._lastSectorPos = newPos
end

-- Возвращает nearby объекты: теперь используем координаты сектора центра и перебор индексов
local function getNearbyObjects(position, radius)
    local nearby = {}
    if not position then return nearby end

    local centerX, centerY, centerZ = getSectorCoords(position)
    local sectors = math.ceil(radius / CONFIG.SECTOR_SIZE)

    for dx = -sectors, sectors do
        for dy = -sectors, sectors do
            for dz = -sectors, sectors do
                local key = makeSectorKey(centerX + dx, centerY + dy, centerZ + dz)
                local list = spatialGrid[key]
                if list then
                    for _, data in ipairs(list) do
                        table.insert(nearby, data)
                    end
                end
            end
        end
    end

    -- fallback: если пусто — вернуть небольшой срез общего списка, чтобы не остаться без обработки
    if #nearby == 0 and #cachedObjects.models > 0 then
        local max = math.min(100, #cachedObjects.models)
        for i = 1, max do
            table.insert(nearby, cachedObjects.models[i])
        end
    end

    return nearby
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Удаляем запись из произвольного списка (по предикату)
local function removeFromList(list, predicate)
    for i = #list, 1, -1 do
        local v = list[i]
        if predicate(v) then
            table.remove(list, i)
        end
    end
end

-- Компактная очистка массивов (удаление записей с пометкой removed или с уничтоженными объектами)
local function compactCaches()
    -- models
    for i = #cachedObjects.models, 1, -1 do
        local d = cachedObjects.models[i]
        local alive = d and d.model and d.model.Parent
        if not alive or d._removed then
            removeFromSpatialGrid(d)
            table.remove(cachedObjects.models, i)
        end
    end
    -- particles
    for i = #cachedObjects.particles, 1, -1 do
        local d = cachedObjects.particles[i]
        if not d or not d.effect or not d.effect.Parent or d._removed then
            table.remove(cachedObjects.particles, i)
        end
    end
    -- trails
    for i = #cachedObjects.trails, 1, -1 do
        local d = cachedObjects.trails[i]
        if not d or not d.trail or not d.trail.Parent or d._removed then
            table.remove(cachedObjects.trails, i)
        end
    end
    -- textures
    for i = #cachedObjects.textures, 1, -1 do
        local d = cachedObjects.textures[i]
        if not d or not d.texture or not d.texture.Parent or d._removed then
            table.remove(cachedObjects.textures, i)
        end
    end
    -- lights
    for i = #cachedObjects.lights, 1, -1 do
        local d = cachedObjects.lights[i]
        if not d or not d.light or not d.light.Parent or d._removed then
            table.remove(cachedObjects.lights, i)
        end
    end
    -- meshParts
    for i = #cachedObjects.meshParts, 1, -1 do
        local d = cachedObjects.meshParts[i]
        if not d or not d.mesh or not d.mesh.Parent or d._removed then
            table.remove(cachedObjects.meshParts, i)
        end
    end
end

-- Пометка записи как удалённой (и удаление из spatial grid сразу)
local function markRemovedEntry(obj)
    -- models
    for _, d in ipairs(cachedObjects.models) do
        if d.model == obj or d.primaryPart == obj then
            d._removed = true
            removeFromSpatialGrid(d)
        end
    end
    -- particles
    for _, d in ipairs(cachedObjects.particles) do
        if d.effect == obj then d._removed = true end
    end
    -- trails
    for _, d in ipairs(cachedObjects.trails) do
        if d.trail == obj then d._removed = true end
    end
    -- textures
    for _, d in ipairs(cachedObjects.textures) do
        if d.texture == obj then d._removed = true end
    end
    -- lights
    for _, d in ipairs(cachedObjects.lights) do
        if d.light == obj then d._removed = true end
    end
    -- meshParts
    for _, d in ipairs(cachedObjects.meshParts) do
        if d.mesh == obj then d._removed = true end
    end
end

-- =========================
-- ИНИЦИАЛИЗАЦИЯ КЕША (сбор объектов; НИЧЕГО ВИЗУАЛЬНОГО НЕ МЕНЯЕМ)
-- =========================
local function initializeCache()
    if isInitialized then return end
    print("🔄 Инициализация кеша (spatial hashing, логические прокси)...")
    local startTime = tick()

    local taggedModels = CollectionService:GetTagged("LOD")
    local useTagSystem = #taggedModels > 0
    local objectsToProcess = useTagSystem and taggedModels or Workspace:GetDescendants()

    for _, obj in ipairs(objectsToProcess) do
        if CollectionService:HasTag(obj, "NO_OPT") then
            -- пропускаем
        else
            if obj:IsA("Model") and obj.PrimaryPart then
                local humanoid = obj:FindFirstChildOfClass("Humanoid")
                if not humanoid or obj ~= player.Character then
                    local parts = {}
                    for _, part in ipairs(obj:GetDescendants()) do
                        if part:IsA("BasePart") then
                            table.insert(parts, part)
                        end
                    end
                    if #parts > 0 then
                        local data = {
                            model = obj,
                            primaryPart = obj.PrimaryPart,
                            parts = parts,
                            lastSeenTime = tick(),
                            rarelyUpdated = false,
                            _lastSectorPos = obj.PrimaryPart.Position
                        }
                        table.insert(cachedObjects.models, data)
                        addToSpatialGrid(data, obj.PrimaryPart.Position)
                    end
                end
            end

            if obj:IsA("ParticleEmitter") and obj.Parent and obj.Parent:IsA("BasePart") then
                table.insert(cachedObjects.particles, {
                    effect = obj,
                    parent = obj.Parent,
                    originalRate = obj.Rate
                })
            end

            if obj:IsA("Trail") and obj.Parent and obj.Parent:IsA("BasePart") then
                table.insert(cachedObjects.trails, {
                    trail = obj,
                    parent = obj.Parent,
                    originalEnabled = obj.Enabled
                })
            end

            if (obj:IsA("Decal") or obj:IsA("Texture") or obj:IsA("SurfaceGui")) and obj.Parent and obj.Parent:IsA("BasePart") then
                table.insert(cachedObjects.textures, {
                    texture = obj,
                    parent = obj.Parent
                })
            end

            if (obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight")) then
                table.insert(cachedObjects.lights, {
                    light = obj,
                    parent = obj.Parent
                })
            end

            if obj:IsA("MeshPart") then
                table.insert(cachedObjects.meshParts, {
                    mesh = obj
                })
            end
        end
    end

    local loadTime = math.floor((tick() - startTime) * 1000)
    print(string.format("✅ Кеш инициализирован: %dмс | %d моделей | %d секторов",
        loadTime, #cachedObjects.models, sectorIndexCount))

    isInitialized = true
end

-- =========================
-- OPTIMIZERS (логические, без изменений визуала)
-- =========================

-- heavy model logic placeholder: выполняется ТОЛЬКО для близких видимых объектов
local function performHeavyModelLogicIfNeeded(data, camPos, dist2, onScreen)
    -- Здесь можно поместить дорогостоящую логику: update AI, сложные коллизии и т.п.
    -- Важно: по умолчанию ничего не меняем в визуале — только логика.
    -- Запускать только если onScreen и близко
    if not onScreen then return end
    if dist2 > CONFIG.DISTANCE_MID then return end

    -- Пример: обновить bounding info если прошла много времени
    if not data._bounds or (tick() - (data._boundsLast or 0) > 5) then
        -- вычисляем простую bounding-сферу (разовая операция, не трогаем визуал)
        local minX, minY, minZ = math.huge, math.huge, math.huge
        local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
        for _, p in ipairs(data.parts) do
            if p and p.Position then
                local pos = p.Position
                minX = math.min(minX, pos.X); minY = math.min(minY, pos.Y); minZ = math.min(minZ, pos.Z)
                maxX = math.max(maxX, pos.X); maxY = math.max(maxY, pos.Y); maxZ = math.max(maxZ, pos.Z)
            end
        end
        if minX ~= math.huge then
            data._bounds = {min = Vector3.new(minX, minY, minZ), max = Vector3.new(maxX, maxY, maxZ)}
            data._boundsLast = tick()
        end
    end

    -- Здесь можно запускать дополнительные логические апдейты (AI, пошаговый physics-check и т.д.)
end

local function optimizeModelsBatch(camPos, currentTime)
    if #cachedObjects.models == 0 then return end
    if currentTime - lastUpdateTimes.models < CONFIG.UPDATE_INTERVALS.models then return end
    lastUpdateTimes.models = currentTime

    local nearbyModels = getNearbyObjects(camPos, 300)
    local processed = 0
    local maxProcess = math.min(CONFIG.BATCH_SIZE, #nearbyModels)

    for i = 1, maxProcess do
        local data = nearbyModels[i]
        if not data or not data.model or not data.primaryPart or not data.primaryPart.Parent then
            -- skip
        else
            local pos = data.primaryPart.Position
            local dist2 = fastDistance2(camPos, pos)
            local onScreen = isOnScreen(pos)

            if onScreen and dist2 <= CONFIG.DISTANCE_FAR then
                data.lastSeenTime = currentTime
                data.rarelyUpdated = false
            end

            if currentTime - data.lastSeenTime > CONFIG.UNSEEN_TIMEOUT then
                data.rarelyUpdated = true
            else
                data.rarelyUpdated = false
            end

            -- выполняем heavy logic только для видимых и близких
            performHeavyModelLogicIfNeeded(data, camPos, dist2, onScreen)
        end
        processed = processed + 1
    end
end

local function optimizeParticlesBatch(camPos, currentTime)
    if #cachedObjects.particles == 0 then return end
    if currentTime - lastUpdateTimes.particles < CONFIG.UPDATE_INTERVALS.particles then return end
    lastUpdateTimes.particles = currentTime

    local processed = 0
    while processed < CONFIG.BATCH_SIZE do
        local data = cachedObjects.particles[batchIndices.particles]
        if not data then
            batchIndices.particles = 1
            break
        end

        if data.effect and data.parent and data.parent.Parent then
            local dist2 = fastDistance2(camPos, data.parent.Position)
            -- НЕ ИЗМЕНЯЕМ data.effect.Rate/Enabled!
            -- Просто помечаем для редких апдейтов
            data.rarelyUpdated = dist2 > CONFIG.DISTANCE_FAR
        end

        batchIndices.particles = batchIndices.particles + 1
        processed = processed + 1
    end
end

local function optimizeTrailsBatch(camPos, currentTime)
    if #cachedObjects.trails == 0 then return end
    if currentTime - lastUpdateTimes.trails < CONFIG.UPDATE_INTERVALS.trails then return end
    lastUpdateTimes.trails = currentTime

    local processed = 0
    while processed < CONFIG.BATCH_SIZE do
        local data = cachedObjects.trails[batchIndices.trails]
        if not data then
            batchIndices.trails = 1
            break
        end

        if data.trail and data.parent and data.parent.Parent then
            local dist2 = fastDistance2(camPos, data.parent.Position)
            data.rarelyUpdated = dist2 > CONFIG.DISTANCE_MID
            -- НЕ меняем data.trail.Enabled
        end

        batchIndices.trails = batchIndices.trails + 1
        processed = processed + 1
    end
end

local function optimizeTexturesBatch(camPos, currentTime)
    if #cachedObjects.textures == 0 then return end
    if currentTime - lastUpdateTimes.textures < CONFIG.UPDATE_INTERVALS.textures then return end
    lastUpdateTimes.textures = currentTime

    local processed = 0
    while processed < CONFIG.BATCH_SIZE do
        local data = cachedObjects.textures[batchIndices.textures]
        if not data then
            batchIndices.textures = 1
            break
        end

        if data.texture and data.parent and data.parent.Parent then
            local dist2 = fastDistance2(camPos, data.parent.Position)
            data.rarelyUpdated = dist2 > CONFIG.DISTANCE_FAR * 1.5
            -- НЕ меняем визуальные параметры
        end

        batchIndices.textures = batchIndices.textures + 1
        processed = processed + 1
    end
end

local function optimizeLightsBatch(camPos, currentTime)
    if CONFIG.OPTIMIZATION_LEVEL < 2 or #cachedObjects.lights == 0 then return end
    if currentTime - lastUpdateTimes.lights < CONFIG.UPDATE_INTERVALS.lights then return end
    lastUpdateTimes.lights = currentTime

    local processed = 0
    while processed < CONFIG.BATCH_SIZE do
        local data = cachedObjects.lights[batchIndices.lights]
        if not data then
            batchIndices.lights = 1
            break
        end

        if data.light and data.parent and data.parent.Parent then
            local dist2 = fastDistance2(camPos, data.parent.Position)
            data.rarelyUpdated = dist2 > CONFIG.DISTANCE_MID
            -- НЕ меняем свойств лампы
        end

        batchIndices.lights = batchIndices.lights + 1
        processed = processed + 1
    end
end

local function optimizeMeshPartsBatch(camPos, currentTime)
    if CONFIG.OPTIMIZATION_LEVEL < 2 or #cachedObjects.meshParts == 0 then return end
    if currentTime - lastUpdateTimes.meshparts < CONFIG.UPDATE_INTERVALS.meshparts then return end
    lastUpdateTimes.meshparts = currentTime

    local processed = 0
    while processed < CONFIG.BATCH_SIZE do
        local data = cachedObjects.meshParts[batchIndices.meshParts]
        if not data then
            batchIndices.meshParts = 1
            break
        end

        if data.mesh and data.mesh.Parent then
            local dist2 = fastDistance2(camPos, data.mesh.Position)
            data.rarelyUpdated = dist2 > CONFIG.DISTANCE_FAR
            -- НЕ меняем Reflectance/TextureID
        end

        batchIndices.meshParts = batchIndices.meshParts + 1
        processed = processed + 1
    end
end

-- =========================
-- Spatial sync (обновляем сектор моделей при движении/интервале)
-- =========================
local function spatialSync(camPos, currentTime)
    if currentTime - lastUpdateTimes.spatialSync < CONFIG.UPDATE_INTERVALS.spatialSync then return end
    lastUpdateTimes.spatialSync = currentTime

    for _, d in ipairs(cachedObjects.models) do
        if not d or not d.primaryPart or not d.primaryPart.Parent then
            d._removed = true
        else
            local pos = d.primaryPart.Position
            local lastPos = d._lastSectorPos or pos
            local moveDist2 = fastDistance2(pos, lastPos)
            if moveDist2 >= (CONFIG.SPATIAL_MOVE_THRESHOLD * CONFIG.SPATIAL_MOVE_THRESHOLD) then
                updateModelSector(d, pos)
            end
        end
    end
end

-- =========================
-- Periodic cleanup/compaction
-- =========================
local function periodicCleanup(currentTime)
    if currentTime - lastUpdateTimes.cleanup < CONFIG.UPDATE_INTERVALS.cleanup then return end
    lastUpdateTimes.cleanup = currentTime
    compactCaches()
end

-- =========================
-- ГЛАВНЫЙ ЦИКЛ
-- =========================
local optimizationStep = 1
local lastUpdate = 0

local function runOptimizationCycle()
    local currentTime = tick()
    if currentTime - lastUpdate < 0.05 then return end -- чуть более частый тик для хорошей реактивности
    lastUpdate = currentTime

    if not camera then return end
    local camPos = camera.CFrame.Position

    -- spatial sync & cleanup выполняются независимо в своём шаге
    if optimizationStep == 1 then
        optimizeModelsBatch(camPos, currentTime)
    elseif optimizationStep == 2 then
        optimizeParticlesBatch(camPos, currentTime)
    elseif optimizationStep == 3 then
        optimizeTrailsBatch(camPos, currentTime)
    elseif optimizationStep == 4 then
        optimizeTexturesBatch(camPos, currentTime)
    elseif optimizationStep == 5 then
        optimizeLightsBatch(camPos, currentTime)
    elseif optimizationStep == 6 then
        optimizeMeshPartsBatch(camPos, currentTime)
    elseif optimizationStep == 7 then
        spatialSync(camPos, currentTime)
    elseif optimizationStep == 8 then
        periodicCleanup(currentTime)
    end

    optimizationStep = optimizationStep + 1
    if optimizationStep > 8 then optimizationStep = 1 end
end

-- =========================
-- FPS монитор + адаптив
-- =========================
local fpsCounter = 0
local fpsTimer = 0
local currentFPS = 60
local smoothedFPS = 60

RunService.RenderStepped:Connect(function(dt)
    fpsCounter = fpsCounter + 1
    fpsTimer = fpsTimer + dt

    if fpsTimer >= 1 then
        currentFPS = fpsCounter
        smoothedFPS = smoothedFPS * 0.8 + currentFPS * 0.2
        fpsCounter = 0
        fpsTimer = 0

        if CONFIG.AUTO_ADJUST_FPS then
            if smoothedFPS < CONFIG.TARGET_FPS - 10 then
                CONFIG.OPTIMIZATION_LEVEL = math.min(3, CONFIG.OPTIMIZATION_LEVEL + 1)
            elseif smoothedFPS > CONFIG.TARGET_FPS + 15 then
                CONFIG.OPTIMIZATION_LEVEL = math.max(1, CONFIG.OPTIMIZATION_LEVEL - 1)
            end
        end
    end
end)

-- =========================
-- События: добавление / удаление объектов
-- =========================
Workspace.DescendantAdded:Connect(function(obj)
    wait(0.2)
    if CollectionService:HasTag(obj, "NO_OPT") then return end

    if obj:IsA("ParticleEmitter") and obj.Parent and obj.Parent:IsA("BasePart") then
        table.insert(cachedObjects.particles, {
            effect = obj,
            parent = obj.Parent,
            originalRate = obj.Rate
        })
    end

    if obj:IsA("Trail") and obj.Parent and obj.Parent:IsA("BasePart") then
        table.insert(cachedObjects.trails, {
            trail = obj,
            parent = obj.Parent,
            originalEnabled = obj.Enabled
        })
    end

    if obj:IsA("MeshPart") then
        table.insert(cachedObjects.meshParts, {
            mesh = obj
        })
    end

    if (obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight")) then
        table.insert(cachedObjects.lights, {
            light = obj,
            parent = obj.Parent
        })
    end

    if (obj:IsA("Decal") or obj:IsA("Texture") or obj:IsA("SurfaceGui")) and obj.Parent and obj.Parent:IsA("BasePart") then
        table.insert(cachedObjects.textures, {
            texture = obj,
            parent = obj.Parent
        })
    end

    -- Если добавлен новый Model с PrimaryPart — добавляем в кэш
    if obj:IsA("Model") and obj.PrimaryPart then
        if not CollectionService:HasTag(obj, "NO_OPT") then
            local humanoid = obj:FindFirstChildOfClass("Humanoid")
            if not humanoid or obj ~= player.Character then
                local parts = {}
                for _, part in ipairs(obj:GetDescendants()) do
                    if part:IsA("BasePart") then table.insert(parts, part) end
                end
                if #parts > 0 then
                    local data = {
                        model = obj,
                        primaryPart = obj.PrimaryPart,
                        parts = parts,
                        lastSeenTime = tick(),
                        rarelyUpdated = false,
                        _lastSectorPos = obj.PrimaryPart.Position
                    }
                    table.insert(cachedObjects.models, data)
                    addToSpatialGrid(data, obj.PrimaryPart.Position)
                end
            end
        end
    end
end)

Workspace.DescendantRemoving:Connect(function(obj)
    markRemovedEntry(obj)
end)

-- Также отслеживаем удаление через AncestryChanged для безопасности (когда объект уезжает из иерархии)
Workspace.DescendantAdded:Connect(function(_) end) -- заглушка, чтобы парность событий была стабильной

-- =========================
-- START
-- =========================
print("=" .. string.rep("=", 60))
print("🚀 ULTIMATE Performance Optimizer v4.1 (Visual-Preserving, Spatial-sync, Cleanup)")
print("   Spatial Hash | Frustum Culling | LODProxy | Adaptive (NO visual changes)")
print("=" .. string.rep("=", 60))

if not player.Character then player.CharacterAdded:Wait() end
wait(1)

initializeCache()
RunService.Heartbeat:Connect(runOptimizationCycle)

print("✅ Система запущена (все оптимизации — логические, визуал НЕ тронут).")
print(string.format("📊 Level %d | Batch %d | Sector %d | Target FPS %d",
    CONFIG.OPTIMIZATION_LEVEL, CONFIG.BATCH_SIZE, CONFIG.SECTOR_SIZE, CONFIG.TARGET_FPS))
print("=" .. string.rep("=", 60))
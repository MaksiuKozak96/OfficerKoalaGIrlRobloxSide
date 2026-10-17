local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local URL = "wss://management-dans-realtors-develops.trycloudflare.com/?key=koala-7f3a9c21-b84e-4d6a-91ce-52d0e8a7b3f1"

local PENDING_FILE = "koala_pending_job.json"
local PENDING_MAX_AGE = 600     -- seconds before a pending job is considered stale
local CHARACTER_TIMEOUT = 20    -- max seconds to wait for the character to spawn
local SETTLE_SECONDS = 10       -- extra wait after loading, so the map fully streams in

local ws = WebSocket.connect(URL)

local function reply(id, status, extra)
    local payload = extra or {}
    payload.id = id
    payload.status = status
    ws:Send(HttpService:JSONEncode(payload))
end

-- List every file in the workspace (recursive)
local function listAll(path, out)
    out = out or {}
    local ok, items = pcall(listfiles, path)
    if not ok or type(items) ~= "table" then return out end
    for _, item in ipairs(items) do
        if isfolder(item) then
            listAll(item, out)
        else
            out[item] = true
        end
    end
    return out
end

local function snapshot()
    for _, root in ipairs({"", "."}) do
        local ok, items = pcall(listfiles, root)
        if ok and type(items) == "table" then
            return listAll(root)
        end
    end
    return {}
end

local function findNewFile(before, after)
    for path in pairs(after) do
        if not before[path] and path:lower():match("%.rbx[lm]x?$") then
            return path
        end
    end
end

-- Read the file until its size stops changing
local function readStable(path)
    local prevSize = -1
    local data
    for _ = 1, 60 do
        data = readfile(path)
        if #data == prevSize then
            return data
        end
        prevSize = #data
        task.wait(4)
    end
    return data
end

-- Build a multipart/form-data body
local function buildMultipart(fields, fileField, name, data)
    local boundary = "KoalaBoundary" .. os.time() .. math.random(1000, 9999)
    local parts = {}
    for k, v in pairs(fields) do
        parts[#parts + 1] = "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"" .. k .. "\"\r\n\r\n" .. v .. "\r\n"
    end
    parts[#parts + 1] = "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"" .. fileField .. "\"; filename=\"" .. name .. "\"\r\nContent-Type: application/octet-stream\r\n\r\n"
    parts[#parts + 1] = data
    parts[#parts + 1] = "\r\n--" .. boundary .. "--\r\n"
    return table.concat(parts), boundary
end

-- Upload hosts, tried in order. If one fails, the next is tried.
local HOSTS = {
    {
        name = "litterbox",
        url = "https://litterbox.catbox.moe/resources/internals/api.php",
        field = "fileToUpload",
        extra = { reqtype = "fileupload", time = "72h" },
    },
    {
        name = "uguu",
        url = "https://uguu.se/upload?output=text",
        field = "files[]",
        extra = {},
    },
    {
        name = "0x0",
        url = "https://0x0.st",
        field = "file",
        extra = {},
    },
}

-- Returns url, hostName  OR  nil, errorString
local function uploadFile(path, data)
    local name = (path:match("[^/\\]+$") or "save.rbxl"):gsub("[^%w%._%-]", "_")
    local errors = {}

    for _, host in ipairs(HOSTS) do
        local body, boundary = buildMultipart(host.extra, host.field, name, data)
        local ok, res = pcall(request, {
            Url = host.url,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
                ["User-Agent"] = "KoalaBot/1.0",
            },
            Body = body,
        })

        if not ok then
            errors[#errors + 1] = host.name .. ": " .. tostring(res)
        elseif res.Success and tostring(res.Body):match("^%s*https?://") then
            return (res.Body:gsub("%s+", "")), host.name
        else
            errors[#errors + 1] = host.name .. ": HTTP " .. tostring(res.StatusCode) .. " " .. tostring(res.Body):sub(1, 80)
        end
    end

    return nil, table.concat(errors, " | ")
end

-- Wait until the game, the player and the character are ready
local function waitForGameLoad()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    local lp = Players.LocalPlayer
    while not lp do
        task.wait(0.2)
        lp = Players.LocalPlayer
    end

    local start = os.clock()
    while not lp.Character and os.clock() - start < CHARACTER_TIMEOUT do
        task.wait(0.5)
    end

    task.wait(SETTLE_SECONDS)
end

-- Run the script, then find / upload the saved file
local function runAndUpload(job)
    local id = job.id
    local before = job.upload and snapshot() or nil

    local fn, compileErr = loadstring(job.code)
    if not fn then
        reply(id, "error", {message = "compile error: " .. tostring(compileErr)})
        return
    end

    local ok, runErr = pcall(fn)
    if not ok then
        reply(id, "error", {message = "runtime error: " .. tostring(runErr)})
        return
    end

    if not job.upload then
        reply(id, "finished")
        return
    end

    reply(id, "saved")

    local ok2, err2 = pcall(function()
        -- find the new file (wait up to ~30s for it to appear)
        local path
        for _ = 1, 15 do
            path = findNewFile(before, snapshot())
            if path then break end
            task.wait(2)
        end
        if not path then
            reply(id, "error", {message = "could not find the saved file"})
            return
        end

        local data = readStable(path)
        reply(id, "uploading")

        local url, info = uploadFile(path, data)
        data = nil

        if url then
            -- only delete the file after a SUCCESSFUL upload
            pcall(delfile, path)
            reply(id, "link", {url = url})
        else
            -- keep the file in workspace so nothing is lost
            reply(id, "error", {message = "upload failed (file kept at " .. path .. "): " .. tostring(info)})
        end
    end)

    if not ok2 then
        reply(id, "error", {message = tostring(err2)})
    end
end

-- We are in the target game: (optionally wait for load) then start saving
local function landed(job, needsLoadWait)
    if needsLoadWait then
        waitForGameLoad()
    end
    reply(job.id, "loaded")
    runAndUpload(job)
end

-- Remember the job in a file, then teleport. The autoexec re-runs in the new game and continues it.
local function startTeleport(job)
    job.started = os.time()

    local okW, errW = pcall(writefile, PENDING_FILE, HttpService:JSONEncode(job))
    if not okW then
        reply(job.id, "error", {message = "could not save pending job: " .. tostring(errW)})
        return
    end

    reply(job.id, "teleporting")

    local conn
    conn = TeleportService.TeleportInitFailed:Connect(function(_, result, errorMessage)
        pcall(delfile, PENDING_FILE)
        reply(job.id, "error", {message = "teleport failed: " .. tostring(errorMessage ~= "" and errorMessage or result)})
        if conn then conn:Disconnect() end
    end)

    local ok, err = pcall(function()
        TeleportService:Teleport(job.place_id, Players.LocalPlayer)
    end)
    if not ok then
        pcall(delfile, PENDING_FILE)
        conn:Disconnect()
        reply(job.id, "error", {message = "teleport error: " .. tostring(err)})
    end
end

local function handleJob(job)
    local target = tonumber(job.place_id)

    if target and target ~= game.PlaceId then
        startTeleport(job)
    elseif target then
        landed(job, false)          -- already in the right game
    else
        runAndUpload(job)           -- no game ID given, just run here
    end
end

-- Runs on every startup: continue a job that was waiting for a teleport
local function resumePending()
    if not isfile(PENDING_FILE) then return end

    local ok, job = pcall(function()
        return HttpService:JSONDecode(readfile(PENDING_FILE))
    end)
    pcall(delfile, PENDING_FILE)   -- delete first so it can never fire twice
    if not ok or type(job) ~= "table" or not job.id then return end

    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    if os.time() - (tonumber(job.started) or 0) > PENDING_MAX_AGE then
        reply(job.id, "error", {message = "teleport took too long, job expired"})
        return
    end

    if game.PlaceId ~= tonumber(job.place_id) then
        reply(job.id, "error", {message = "landed in place " .. tostring(game.PlaceId) .. " instead of " .. tostring(job.place_id)})
        return
    end

    landed(job, true)
end

ws.OnMessage:Connect(function(message, isBinary)
    if isBinary then return end

    local ok, job = pcall(function()
        return HttpService:JSONDecode(message)
    end)
    if not ok or type(job) ~= "table" then return end

    task.spawn(handleJob, job)
end)

ws.OnClose:Connect(function()
    print("Disconnected, Volt will try to reconnect")
end)

task.spawn(resumePending)

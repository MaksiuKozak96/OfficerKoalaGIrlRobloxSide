local HttpService = game:GetService("HttpService")

local URL = "wss://perhaps-christine-protected-golf.trycloudflare.com/?key=koala-7f3a9c21-b84e-4d6a-91ce-52d0e8a7b3f1"
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

local function uploadToLitterbox(path, data)
    local boundary = "KoalaBoundary" .. os.time() .. math.random(1000, 9999)
    local name = (path:match("[^/\\]+$") or "save.rbxl"):gsub("[^%w%._%-]", "_")

    local body = table.concat({
        "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n",
        "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"time\"\r\n\r\n72h\r\n",
        "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"" .. name .. "\"\r\nContent-Type: application/octet-stream\r\n\r\n",
        data,
        "\r\n--" .. boundary .. "--\r\n",
    })

    local ok, response = pcall(request, {
        Url = "https://litterbox.catbox.moe/resources/internals/api.php",
        Method = "POST",
        Headers = {
            ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
        },
        Body = body,
    })

    if not ok then return nil, tostring(response) end
    if response.Success and response.Body:match("^https?://") then
        return response.Body:gsub("%s+", "")
    end
    return nil, "HTTP " .. tostring(response.StatusCode) .. " " .. tostring(response.Body):sub(1, 100)
end

local function handleJob(job)
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

        local url, uploadErr = uploadToLitterbox(path, data)
        data = nil
        pcall(delfile, path)

        if url then
            reply(id, "link", {url = url})
        else
            reply(id, "error", {message = "upload failed: " .. tostring(uploadErr)})
        end
    end)

    if not ok2 then
        reply(id, "error", {message = tostring(err2)})
    end
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

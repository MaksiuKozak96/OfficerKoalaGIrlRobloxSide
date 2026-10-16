local URL = "wss://perhaps-christine-protected-golf.trycloudflare.com/?key=koala-7f3a9c21-b84e-4d6a-91ce-52d0e8a7b3f1"

local ws = WebSocket.connect(URL)

ws.OnMessage:Connect(function(message, isBinary)
    if isBinary then return end

    task.spawn(function()
        local fn, compileErr = loadstring(message)
        if not fn then
            ws:Send("compile error: " .. tostring(compileErr))
            return
        end

        local ok, runErr = pcall(fn)
        if ok then
            ws:Send("script finished")
        else
            ws:Send("runtime error: " .. tostring(runErr))
        end
    end)
end)

ws.OnClose:Connect(function()
    print("Disconnected, Volt will try to reconnect")
end)

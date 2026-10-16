import json
import uuid
import discord
from discord import app_commands
from discord.ext import commands
from urllib.parse import urlparse, parse_qs
from websockets.asyncio.server import serve

WS_KEY = "koala-7f3a9c21-b84e-4d6a-91ce-52d0e8a7b3f1"
PORT = 8765

SAVEINST_SCRIPT = r'''
local Params = {
    RepoURL = "https://raw.githubusercontent.com/luau/SynSaveInstance/main/",
    SSI = "saveinstance",
}
local synsaveinstance = loadstring(game:HttpGet(Params.RepoURL .. Params.SSI .. ".luau", true), Params.SSI)()
local Options = {
    RemovePlayerCharacters = false,
    SafeMode = false,
    NoScripts = false,
    IsolatePlayers = true,
    IsolateLocalPlayer = true,
}
synsaveinstance(Options)
'''


def render(job):
    text = f"Sent to {job['clients']} client(s).\nLink to Download: "
    if job["links"]:
        text += "\n".join(job["links"])
    else:
        text += job["state"]
    return text


class Executor(commands.Cog):
    def __init__(self, bot):
        self.bot = bot
        self.clients = set()
        self.jobs = {}
        self.server = None

    async def cog_load(self):
        self.server = await serve(self.handler, "127.0.0.1", PORT)
        print(f"WebSocket server listening on port {PORT}")

    async def cog_unload(self):
        if self.server:
            self.server.close()

    async def handler(self, ws):
        query = parse_qs(urlparse(ws.request.path).query)
        if query.get("key", [""])[0] != WS_KEY:
            await ws.close()
            return

        self.clients.add(ws)
        print("Client connected")
        try:
            async for raw in ws:
                try:
                    data = json.loads(raw)
                except Exception:
                    print("Client says:", raw)
                    continue
                await self.on_client_message(data)
        finally:
            self.clients.discard(ws)
            print("Client disconnected")

    async def on_client_message(self, data):
        job = self.jobs.get(data.get("id"))
        if not job:
            return

        status = data.get("status")
        final = False

        if status == "saved":
            job["state"] = "Save finished, preparing file..."
        elif status == "uploading":
            job["state"] = "Uploading..."
        elif status == "link":
            job["links"].append(data.get("url", "???"))
            final = True
        elif status == "error":
            job["state"] = f"Failed ({data.get('message', 'unknown error')})"
            final = True
        elif status == "finished":
            job["state"] = "Done"
            final = True

        await self.refresh(job, final)
        if final:
            self.jobs.pop(job["id"], None)

    async def refresh(self, job, final):
        try:
            await job["interaction"].edit_original_response(content=render(job))
        except discord.HTTPException:
            # Discord only lets us edit the message for 15 minutes.
            # If it expired, DM the user the result instead.
            if final:
                try:
                    await job["user"].send(render(job))
                except discord.HTTPException:
                    pass

    @app_commands.command(name="testsaveinst", description="Run saveinstance on the client")
    @app_commands.allowed_installs(guilds=True, users=True)
    @app_commands.allowed_contexts(guilds=True, dms=True, private_channels=True)
    async def testsaveinst(self, interaction: discord.Interaction):
        if not self.clients:
            await interaction.response.send_message("No client connected.")
            return

        job_id = uuid.uuid4().hex
        job = {
            "id": job_id,
            "interaction": interaction,
            "user": interaction.user,
            "clients": len(self.clients),
            "links": [],
            "state": "Pending",
        }
        self.jobs[job_id] = job

        payload = json.dumps({"id": job_id, "code": SAVEINST_SCRIPT, "upload": True})
        for ws in list(self.clients):
            await ws.send(payload)

        await interaction.response.send_message(render(job))


async def setup(bot):
    await bot.add_cog(Executor(bot))

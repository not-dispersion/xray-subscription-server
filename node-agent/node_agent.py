import json
import os
import secrets
import shutil
import subprocess
import tempfile
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException, status
from pydantic import BaseModel

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

CONFIG_PATH = "/usr/local/etc/xray/config.json"
KEYS_PATH = "/usr/local/etc/xray/.keys"
AGENT_SECRET = os.getenv("NODE_KEY")

NODE_CACHE = {
    "host": "",
    "port": 443,
    "sni": "",
    "pbk": "",
    "sid": "",
}


def load_static_params():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)

    inbound = config["inbounds"][0]
    NODE_CACHE["port"] = inbound.get("port", 443)
    NODE_CACHE["sni"] = inbound["streamSettings"]["realitySettings"]["serverNames"][0]

    pbk, sid = "", ""
    if os.path.exists(KEYS_PATH):
        with open(KEYS_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line_lower = line.lower()
                if "password" in line_lower or "public" in line_lower:
                        pbk = line.split(":", 1)[1].strip()
                elif "shortsid" in line_lower or "short id" in line_lower:
                        sid = line.split(":", 1)[1].strip()

    NODE_CACHE["pbk"] = pbk
    NODE_CACHE["sid"] = sid

    try:
        ip = subprocess.check_output(
            ["curl", "-4", "-s", "--max-time", "5", "icanhazip.com"],
            text=True,
        ).strip()
        NODE_CACHE["host"] = ip
    except Exception as e:
        print(f"[WARN] Failed to get external IP via curl: {e}")
        NODE_CACHE["host"] = "127.0.0.1"


@asynccontextmanager
async def lifespan(app: FastAPI):
    load_static_params()
    yield


app = FastAPI(title="Xray Node Agent", lifespan=lifespan)


class AddUserRequest(BaseModel):
    email: str
    uuid: str | None = None


def check_auth(secret: str | None):
    if not secret or not AGENT_SECRET or not secrets.compare_digest(secret, AGENT_SECRET):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid node secret",
        )


def atomic_write_config(config: dict):
    dir_name = os.path.dirname(CONFIG_PATH)
    with tempfile.NamedTemporaryFile(
        "w", dir=dir_name, delete=False, encoding="utf-8"
    ) as tf:
        json.dump(config, tf, indent=2, ensure_ascii=False)
        temp_path = tf.name

    os.chmod(temp_path, 0o644)
    shutil.move(temp_path, CONFIG_PATH)
    subprocess.run(["systemctl", "restart", "xray"], check=True)


def build_link(client_uuid: str, email: str) -> str:
    host = NODE_CACHE["host"]
    port = NODE_CACHE["port"]
    sni = NODE_CACHE["sni"]
    pbk = NODE_CACHE["pbk"]
    sid = NODE_CACHE["sid"]
    return (
        f"vless://{client_uuid}@{host}:{port}"
        f"?security=reality&sni={sni}&fp=firefox&pbk={pbk}&sid={sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#{email}"
    )


@app.get("/health")
async def health(x_node_secret: str | None = Header(None, alias="X-Node-Secret")):
    check_auth(x_node_secret)
    return {"status": "ok"}


@app.get("/users")
async def list_users(x_node_secret: str | None = Header(None, alias="X-Node-Secret")):
    check_auth(x_node_secret)
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)
    clients = config["inbounds"][0]["settings"].get("clients", [])
    return {c["email"]: c.get("id") for c in clients if c.get("email") and c.get("id")}


@app.post("/users")
async def add_user(
    payload: AddUserRequest,
    x_node_secret: str | None = Header(None, alias="X-Node-Secret"),
):
    check_auth(x_node_secret)

    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)

    clients = config["inbounds"][0]["settings"].setdefault("clients", [])

    for client in clients:
        if client.get("email") == payload.email:
            existing_uuid = client.get("id")
            link = build_link(existing_uuid, payload.email)
            return {
                "status": "already_exists",
                "email": payload.email,
                "uuid": existing_uuid,
                "key": link,
            }

    client_uuid = payload.uuid or str(uuid.uuid4())
    clients.append(
        {
            "id": client_uuid,
            "email": payload.email,
            "flow": "xtls-rprx-vision",
        }
    )

    atomic_write_config(config)
    link = build_link(client_uuid, payload.email)

    return {
        "status": "created",
        "email": payload.email,
        "uuid": client_uuid,
        "key": link,
    }


@app.delete("/users/{email}")
async def delete_user(
    email: str, x_node_secret: str | None = Header(None, alias="X-Node-Secret")
):
    check_auth(x_node_secret)

    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)

    clients = config["inbounds"][0]["settings"].get("clients", [])
    new_clients = [c for c in clients if c.get("email") != email]

    if len(clients) == len(new_clients):
        return {"status": "not_found", "email": email}

    config["inbounds"][0]["settings"]["clients"] = new_clients
    atomic_write_config(config)

    return {"status": "deleted", "email": email}

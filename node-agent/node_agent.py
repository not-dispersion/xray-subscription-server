import json
import os
import secrets
import subprocess
import uuid
import urllib.parse
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
INBOUND_TAG = "VLESS-IN"
API_SERVER = "127.0.0.1:10085"
STATE_FILE = Path("/etc/node-agent/users_state.json")

NODE_CACHE = {
    "host": "",
    "port": 443,
    "sni": "",
    "pbk": "",
    "sid": "",
}


def load_state() -> dict[str, str]:
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_state(state: dict[str, str]):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_file = STATE_FILE.with_name(f"{STATE_FILE.name}.tmp")
    with open(tmp_file, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    tmp_file.replace(STATE_FILE)


def load_static_params():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        config = json.load(f)

    inbound = next((ib for ib in config["inbounds"] if ib.get("tag") == INBOUND_TAG), config["inbounds"][0])
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
        print(f"[WARN] Failed to get IP: {e}")
        NODE_CACHE["host"] = "127.0.0.1"


@asynccontextmanager
async def lifespan(app: FastAPI):
    load_static_params()
    state = load_state()
    for email, client_uuid in state.items():
        xray_add_user(client_uuid, email)
    yield


app = FastAPI(title="Xray Node Agent", lifespan=lifespan)


class UserItem(BaseModel):
    email: str
    uuid: str | None = None


class BatchUsersRequest(BaseModel):
    users: list[UserItem]


def check_auth(secret: str | None):
    if not secret or not AGENT_SECRET or not secrets.compare_digest(secret, AGENT_SECRET):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid node secret",
        )


def build_link(client_uuid: str, email: str) -> str:
    host = NODE_CACHE["host"]
    port = NODE_CACHE["port"]
    sni = NODE_CACHE["sni"]
    pbk = NODE_CACHE["pbk"]
    sid = NODE_CACHE["sid"]

    if len(pbk) == 42:
        pbk += "="
    encoded_pbk = urllib.parse.quote(pbk, safe="")
    return (
        f"vless://{client_uuid}@{host}:{port}"
        f"?security=reality&sni={sni}&fp=firefox&pbk={encoded_pbk}&sid={sid}&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#{email}"
    )


def xray_add_user(client_uuid: str, email: str) -> bool:
    cmd = [
        "xray", "api", "addu",
        f"--server={API_SERVER}",
        f"--tag={INBOUND_TAG}",
        f"--email={email}",
        f"--uuid={client_uuid}",
        "--flow=xtls-rprx-vision",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.returncode == 0


def xray_remove_user(email: str) -> bool:
    """Вызов xray api rmu на лету без рестарта"""
    cmd = [
        "xray", "api", "rmu",
        f"--server={API_SERVER}",
        f"--tag={INBOUND_TAG}",
        f"--email={email}",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.returncode == 0


@app.get("/health")
async def health(x_node_secret: str | None = Header(None, alias="X-Node-Secret")):
    check_auth(x_node_secret)
    return {"status": "ok"}


@app.get("/users")
async def list_users(x_node_secret: str | None = Header(None, alias="X-Node-Secret")):
    check_auth(x_node_secret)
    return load_state()


@app.post("/users/batch")
async def add_users_batch(
    payload: BatchUsersRequest,
    x_node_secret: str | None = Header(None, alias="X-Node-Secret"),
):
    check_auth(x_node_secret)
    state = load_state()
    response_items = []
    state_changed = False

    for item in payload.users:
        if item.email in state:
            existing_uuid = state[item.email]
            link = build_link(existing_uuid, item.email)
            response_items.append({
                "status": "already_exists",
                "email": item.email,
                "uuid": existing_uuid,
                "key": link,
            })
            continue

        client_uuid = item.uuid or str(uuid.uuid4())
        xray_add_user(client_uuid, item.email)
        state[item.email] = client_uuid
        state_changed = True

        link = build_link(client_uuid, item.email)
        response_items.append({
            "status": "created",
            "email": item.email,
            "uuid": client_uuid,
            "key": link,
        })

    if state_changed:
        save_state(state)

    return {"results": response_items}


@app.delete("/users/{email}")
async def delete_user(
    email: str, x_node_secret: str | None = Header(None, alias="X-Node-Secret")
):
    check_auth(x_node_secret)
    state = load_state()

    if email not in state:
        return {"status": "not_found", "email": email}

    xray_remove_user(email)
    del state[email]
    save_state(state)

    return {"status": "deleted", "email": email}
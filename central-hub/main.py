import asyncio
import base64
import json
import secrets
from contextlib import asynccontextmanager
from datetime import datetime
from urllib.parse import parse_qs, unquote, urlparse

from app.auth import admin_auth
from app.database import Base, engine, get_db
from app.models import Device, Link, LinkNode, Node, User
from app.node_client import create_user_on_node, delete_user_from_node, ping_node
from app.routing import build_routing_profile, encode_routing_header
from app.schemas import (
    DeviceResponse,
    NodeManage,
    NodeResponse,
    UserCreate,
    UserResponse,
    UserUpdate,
)
from app.tasks import sync_nodes_task
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    sync_task = asyncio.create_task(sync_nodes_task())
    yield
    sync_task.cancel()
    await engine.dispose()


app = FastAPI(
    title="VPN subscription server",
    description="Central node",
    version="0.1.0",
    lifespan=lifespan,
)


def build_sub_url(request: Request, token: str) -> str:
    base_url = str(request.base_url).rstrip("/")
    return f"{base_url}/sub/{token}"


def parse_vless_to_outbound(vless_uri: str, tag: str) -> dict:
    parsed = urlparse(vless_uri)
    query = parse_qs(parsed.query)

    uuid_str = parsed.username
    host = parsed.hostname
    port = parsed.port or 443

    flow = query.get("flow", ["xtls-rprx-vision"])[0]
    fp = query.get("fp", ["firefox"])[0]
    sni = query.get("sni", [""])[0]
    pbk = query.get("pbk", [""])[0]
    sid = query.get("sid", [""])[0]
    spx = unquote(query.get("spx", ["/"])[0])

    return {
        "tag": tag,
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": host,
                    "port": port,
                    "users": [{"id": uuid_str, "encryption": "none", "flow": flow}],
                }
            ]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": False,
                "fingerprint": fp,
                "serverName": sni,
                "publicKey": pbk,
                "shortId": sid,
                "spiderX": spx,
            },
        },
    }


def build_auto_config(vless_keys: list[str]) -> dict:
    outbounds = []

    for idx, key in enumerate(vless_keys, start=1):
        outbound = parse_vless_to_outbound(key, tag=f"node-{idx}")
        outbounds.append(outbound)

    return {
        "remarks": "Auto",
        "inbounds": [
            {
                "tag": "socks-in",
                "port": 10808,
                "listen": "127.0.0.1",
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True},
            }
        ],
        "outbounds": outbounds,
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "balancers": [
                {
                    "tag": "balancer-auto",
                    "selector": ["node-"],
                    "strategy": {"type": "leastPing"},
                }
            ],
            "rules": [
                {
                    "type": "field",
                    "network": "tcp,udp",
                    "balancerTag": "balancer-auto",
                }
            ],
        },
        "observatory": {
            "subjectSelector": ["node-"],
            "probeURL": "https://cp.cloudflare.com/generate_204",
            "probeInterval": "1m",
            "enableConcurrency": True,
        },
    }


def build_single_node_config(vless_key: str, node_name: str) -> dict:
    outbound = parse_vless_to_outbound(vless_key, tag="proxy")
    return {
        "remarks": node_name,
        "inbounds": [
            {
                "tag": "socks-in",
                "port": 10808,
                "listen": "127.0.0.1",
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True},
            }
        ],
        "outbounds": [
            outbound,
            {"tag": "direct", "protocol": "freedom", "settings": {}},
        ],
    }


@app.post(
    "/nodes",
    dependencies=[Depends(admin_auth)],
    response_model=NodeResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["Nodes"],
)
async def create_node(payload: NodeManage, db: AsyncSession = Depends(get_db)):
    existing_query = select(Node).where(Node.name == payload.name)
    existing_res = await db.execute(existing_query)
    if existing_res.scalar_one_or_none():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Node '{payload.name}' already exists",
        )

    is_alive = await ping_node(payload.api_url)

    new_node = Node(
        name=payload.name,
        api_url=payload.api_url,
        is_active=is_alive,
    )
    db.add(new_node)
    await db.flush()

    if is_alive:
        links_res = await db.execute(select(Link))
        all_links = links_res.scalars().all()

        for link in all_links:
            key = await create_user_on_node(new_node.api_url, link.token)
            if key:
                db.add(LinkNode(link_id=link.id, node_id=new_node.id, key=key))

    await db.commit()
    await db.refresh(new_node)
    return new_node


@app.get(
    "/nodes",
    dependencies=[Depends(admin_auth)],
    response_model=list[NodeResponse],
    tags=["Nodes"],
)
async def get_nodes(db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Node))
    return result.scalars().all()


@app.delete(
    "/nodes/{node_id}",
    dependencies=[Depends(admin_auth)],
    status_code=status.HTTP_204_NO_CONTENT,
    tags=["Nodes"],
)
async def delete_node(node_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Node).where(Node.id == node_id))
    node = result.scalar_one_or_none()
    if not node:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Node not found"
        )

    await db.delete(node)
    await db.commit()


@app.post(
    "/users",
    dependencies=[Depends(admin_auth)],
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
    tags=["Users"],
)
async def create_user(
    payload: UserCreate, request: Request, db: AsyncSession = Depends(get_db)
):
    new_user = User(surname=payload.surname)
    db.add(new_user)
    await db.flush()

    token = secrets.token_urlsafe(16)
    new_link = Link(
        user_id=new_user.id,
        token=token,
        device_limit=payload.device_limit,
    )
    db.add(new_link)
    await db.flush()

    nodes_res = await db.execute(select(Node).where(Node.is_active == True))
    active_nodes = nodes_res.scalars().all()

    for node in active_nodes:
        key = await create_user_on_node(node.api_url, new_link.token)
        if key:
            db.add(LinkNode(link_id=new_link.id, node_id=node.id, key=key))

    await db.commit()
    await db.refresh(new_user)
    await db.refresh(new_link)

    sub_url = build_sub_url(request, new_link.token)
    return UserResponse(
        id=new_user.id,
        surname=new_user.surname,
        device_limit=new_link.device_limit,
        link=sub_url,
    )


@app.get(
    "/users",
    dependencies=[Depends(admin_auth)],
    response_model=list[UserResponse],
    tags=["Users"],
)
async def get_users(request: Request, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User))
    users = result.scalars().all()

    return [
        UserResponse(
            id=u.id,
            surname=u.surname,
            device_limit=u.link.device_limit if u.link else None,
            used_devices=len(u.link.devices) if u.link else 0,
            link=build_sub_url(request, u.link.token) if u.link else None,
        )
        for u in users
    ]


@app.patch(
    "/users/{user_id}",
    dependencies=[Depends(admin_auth)],
    response_model=UserResponse,
    tags=["Users"],
)
async def update_user(
    user_id: int,
    payload: UserUpdate,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    if payload.surname is not None:
        user.surname = payload.surname.strip()

    if payload.device_limit is not None and user.link:
        user.link.device_limit = payload.device_limit

    await db.commit()
    await db.refresh(user)
    if user.link:
        await db.refresh(user.link)

    sub_url = build_sub_url(request, user.link.token) if user.link else None

    return UserResponse(
        id=user.id,
        surname=user.surname,
        device_limit=user.link.device_limit if user.link else None,
        link=sub_url,
    )


@app.delete(
    "/users/{user_id}",
    dependencies=[Depends(admin_auth)],
    status_code=status.HTTP_204_NO_CONTENT,
    tags=["Users"],
)
async def delete_user(user_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="User not found"
        )

    if user.link:
        nodes_res = await db.execute(select(Node).where(Node.is_active == True))
        for node in nodes_res.scalars().all():
            await delete_user_from_node(node.api_url, user.link.token)

    await db.delete(user)
    await db.commit()


@app.get(
    "/users/{user_id}/devices",
    dependencies=[Depends(admin_auth)],
    response_model=list[DeviceResponse],
    tags=["Devices"],
)
async def get_user_devices(user_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user or not user.link:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User or subscription not found",
        )

    devices_sorted = sorted(
        user.link.devices, key=lambda d: d.created_at or datetime.min
    )

    return [
        DeviceResponse(
            slot=idx,
            id=d.id,
            device_identifier=d.device_identifier,
            device_os=d.device_os,
            created_at=d.created_at,
        )
        for idx, d in enumerate(devices_sorted, start=1)
    ]


@app.delete(
    "/users/{user_id}/devices/{device_slot}",
    dependencies=[Depends(admin_auth)],
    status_code=status.HTTP_204_NO_CONTENT,
    tags=["Devices"],
)
async def delete_user_device_by_slot(
    user_id: int, device_slot: int, db: AsyncSession = Depends(get_db)
):
    if device_slot < 1:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Incorrect input",
        )

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user or not user.link:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User or subscription not found",
        )

    devices_sorted = sorted(
        user.link.devices, key=lambda d: d.created_at or datetime.min
    )

    if device_slot > len(devices_sorted):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"This user has only {len(devices_sorted)} devices. Device #{device_slot} not found",
        )

    device_to_delete = devices_sorted[device_slot - 1]

    await db.delete(device_to_delete)
    await db.commit()


@app.get("/sub/{token}", tags=["Subscription"])
async def get_subscription(
    token: str,
    x_hwid: str | None = Header(None, alias="x-hwid"),
    x_device_os: str | None = Header(None, alias="x-device-os"),
    x_client: str | None = Header(None, alias="x-client"),
    user_agent: str | None = Header(None, alias="user-agent"),
    db: AsyncSession = Depends(get_db),
):
    is_incy = (x_client and "INCY" in x_client.upper()) or (
        user_agent and "INCY" in user_agent.upper()
    )
    if not is_incy:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Access only for INCY client",
        )
    elif not x_hwid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Device x_hwid not found",
        )

    link_res = await db.execute(select(Link).where(Link.token == token))
    link = link_res.scalar_one_or_none()

    if not link:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Subscription not found",
        )

    device_res = await db.execute(
        select(Device).where(
            Device.link_id == link.id,
            Device.device_identifier == x_hwid,
        )
    )
    device = device_res.scalar_one_or_none()

    if not device:
        count_res = await db.execute(
            select(func.count()).select_from(Device).where(Device.link_id == link.id)
        )
        current_devices_count = count_res.scalar_one()

        if current_devices_count >= link.device_limit:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Device limit reached ({link.device_limit}).",
            )

        db.add(
            Device(
                link_id=link.id,
                device_identifier=x_hwid,
                device_os=x_device_os or "Unknown",
            )
        )
        await db.commit()

    active_keys = [
        f"{mapping.key.split('#', 1)[0]}#{mapping.node.name}"
        for mapping in link.node_mappings
        if mapping.key and mapping.node and mapping.node.is_active
    ]

    items_to_pack = []
    if not active_keys:
        dummy_uri = "vless://00000000-0000-0000-0000-000000000000@127.0.0.1:443?security=reality&encryption=none&pbk=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&fp=firefox&spx=%2F&type=tcp&flow=xtls-rprx-vision&sni=example.invalid&sid=00000000#"
        items_to_pack.append(build_single_node_config(dummy_uri, "No Active Nodes"))

    if len(active_keys) >= 2:
        auto_cfg = build_auto_config(active_keys)
        items_to_pack.append(auto_cfg)

    for mapping in link.node_mappings:
        if mapping.key and mapping.node and mapping.node.is_active:
            single_cfg = build_single_node_config(mapping.key, mapping.node.name)
            items_to_pack.append(single_cfg)
    raw_payload = json.dumps(items_to_pack, ensure_ascii=False)
    encoded_payload = base64.b64encode(raw_payload.encode("utf-8")).decode("utf-8")

    routing_profile = build_routing_profile()

    headers = {
        "Content-Type": "text/plain; charset=utf-8",
        "Profile-Update-Interval": "12",
        "Profile-Title": "Interconnection VPN",
        "routing": encode_routing_header(routing_profile),
    }

    return Response(
        content=encoded_payload,
        media_type="text/plain; charset=utf-8",
        headers=headers,
    )

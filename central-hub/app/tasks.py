import asyncio
import re
from urllib.parse import urlparse
from sqlalchemy import select

from app.database import AsyncSessionLocal
from app.models import Link, Node, LinkNode
from app.node_client import (
    create_user_on_node,
    delete_user_from_node,
    list_users_on_node,
    ping_node,
)
SYNC_INTERVAL = 60
TOKEN_RE = re.compile(r"^[A-Za-z0-9_\-]{22}$")

def extract_uuid(key: str) -> str | None:
    try:
        return urlparse(key).username
    except Exception:
        return None

async def sync_nodes_task():
    while True:
        try:
            await reconcile_once()
        except Exception as e:
            print(f"Sync error: {e}")

        await asyncio.sleep(SYNC_INTERVAL)

async def reconcile_once():
    async with AsyncSessionLocal() as db:
        nodes = (await db.execute(select(Node))).scalars().all()
        all_links = (await db.execute(select(Link))).scalars().all()
        all_mappings = (await db.execute(select(LinkNode))).scalars().all()

        mapping_dict = {(m.link_id, m.node_id): m for m in all_mappings}
        valid_tokens = {link.token for link in all_links}

        for node in nodes:
            is_alive = await ping_node(node.api_url)
            node.is_active = is_alive

            if not is_alive:
                continue

            remote_users = await list_users_on_node(node.api_url)
            if remote_users is None:
                continue

            managed_remote_users = {
                email: uid
                for email, uid in remote_users.items()
                if TOKEN_RE.match(email)
            }

            for link in all_links:
                mapping = mapping_dict.get((link.id, node.id))
                remote_uuid = managed_remote_users.get(link.token)

                if mapping is None:
                    key = await create_user_on_node(node.api_url, link.token)
                    if key:
                        new_mapping = LinkNode(link_id=link.id, node_id=node.id, key=key)
                        db.add(new_mapping)
                        mapping_dict[(link.id, node.id)] = new_mapping
                    continue

                db_uuid = extract_uuid(mapping.key)

                if remote_uuid is None or remote_uuid != db_uuid:
                    key = await create_user_on_node(
                        node.api_url, link.token, client_uuid=db_uuid
                    )
                    if key:
                        mapping.key = key

            orphan_emails = set(managed_remote_users.keys()) - valid_tokens
            for email in orphan_emails:
                await delete_user_from_node(node.api_url, email)

        await db.commit()
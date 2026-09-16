import asyncio
import re
from urllib.parse import urlparse
from sqlalchemy import select

from app.database import AsyncSessionLocal
from app.models import Link, Node, LinkNode
from app.node_client import (
    create_users_batch_on_node,
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

            users_to_batch = []
            links_to_update = {}

            for link in all_links:
                mapping = mapping_dict.get((link.id, node.id))
                remote_uuid = managed_remote_users.get(link.token)

                if mapping is None:
                    users_to_batch.append({"email": link.token, "uuid": None})
                    links_to_update[link.token] = (link, None)
                else:
                    db_uuid = extract_uuid(mapping.key)
                    if remote_uuid is None or remote_uuid != db_uuid:
                        users_to_batch.append({"email": link.token, "uuid": db_uuid})
                        links_to_update[link.token] = (link, mapping)

            if users_to_batch:
                batch_results = await create_users_batch_on_node(node.api_url, users_to_batch)
                if batch_results:
                    for item in batch_results:
                        token = item.get("email")
                        key = item.get("key")
                        if not token or not key:
                            continue

                        link_info = links_to_update.get(token)
                        if not link_info:
                            continue

                        link_obj, mapping_obj = link_info
                        if mapping_obj is None:
                            new_mapping = LinkNode(link_id=link_obj.id, node_id=node.id, key=key)
                            db.add(new_mapping)
                            mapping_dict[(link_obj.id, node.id)] = new_mapping
                        else:
                            mapping_obj.key = key

            orphan_emails = set(managed_remote_users.keys()) - valid_tokens
            for email in orphan_emails:
                await delete_user_from_node(node.api_url, email)

        await db.commit()
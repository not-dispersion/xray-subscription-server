import httpx

from app.config import settings

TIMEOUT = 20.0

async def ping_node(api_url: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            res = await client.get(
                f"{api_url.rstrip('/')}/health",
                headers={"X-Node-Secret": settings.NODE_KEY},
            )
            return res.status_code == 200
    except Exception:
        return False


async def list_users_on_node(api_url: str) -> dict[str, str] | None:
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            res = await client.get(
                f"{api_url.rstrip('/')}/users",
                headers={"X-Node-Secret": settings.NODE_KEY},
            )

            if res.status_code == 200:
                data = res.json()

                if isinstance(data, dict):
                    return data

    except Exception:
        return None


async def create_user_on_node(
    api_url: str, token: str, client_uuid: str | None = None
) -> str | None:
    payload = {"email": token}
    if client_uuid:
        payload["uuid"] = client_uuid

    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            res = await client.post(
                f"{api_url.rstrip('/')}/users",
                json=payload,
                headers={"X-Node-Secret": settings.NODE_KEY},
            )
            if res.status_code == 200:
                return res.json().get("key")
    except Exception:
        return None


async def delete_user_from_node(api_url: str, token: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            res = await client.delete(
                f"{api_url.rstrip('/')}/users/{token}",
                headers={"X-Node-Secret": settings.NODE_KEY},
            )
            return res.status_code == 200
    except Exception:
        return False
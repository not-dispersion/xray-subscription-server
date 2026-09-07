import secrets
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from app.config import settings

bearer_scheme = HTTPBearer(auto_error=True)


async def admin_auth(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
):
    if not secrets.compare_digest(credentials.credentials, settings.ADMIN_API_KEY):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return True
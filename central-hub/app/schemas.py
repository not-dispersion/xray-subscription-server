from datetime import datetime
from pydantic import BaseModel, ConfigDict, Field

class NodeManage(BaseModel):
    name: str = Field(..., min_length=1)
    api_url: str = Field(..., min_length=1)

class NodeResponse(BaseModel):
    id: int
    name: str
    api_url: str
    is_active: bool

    model_config = ConfigDict(from_attributes=True)

class UserCreate(BaseModel):
    surname: str = Field(..., min_length=1)
    device_limit: int = Field(1, ge=1, le=50)

class UserUpdate(BaseModel):
    surname: str | None = Field(None, min_length=1)
    device_limit: int | None = Field(None, ge=1, le=50)

class UserResponse(BaseModel):
    id: int
    surname: str
    device_limit: int | None = None
    link: str | None = None

    model_config = ConfigDict(from_attributes=True)

class DeviceResponse(BaseModel):
    slot: int
    id: int
    device_identifier: str
    device_os: str | None = None
    created_at: datetime | None = None

    model_config = ConfigDict(from_attributes=True)
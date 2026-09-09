import base64
import json
import time
from pydantic import BaseModel, Field

DOMAINS_DIRECT = [
    "domain:avito.st",
    "geosite:category-ru",
    "regexp:.*\\.ru$",
    "regexp:.*\\.xn-p1ai$",
]

DIRECT_IP = [
    "geoip:ru",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "224.0.0.0/4",
    "255.255.255.255/32",
]

BLOCK_SITES = ["geosite:category-ads-all"]

class IncyRoutingProfile(BaseModel):
    Name: str = ""
    GlobalProxy: str = "true"
    DirectSites: list[str] = Field(default_factory=list)
    DirectIp: list[str] = Field(default_factory=list)
    ProxySites: list[str] = Field(default_factory=list)
    ProxyIp: list[str] = Field(default_factory=list)
    BlockSites: list[str] = Field(default_factory=list)
    BlockIp: list[str] = Field(default_factory=list)
    DomainStrategy: str = "IPIfNonMatch"
    RemoteDNSType: str | None = None
    RemoteDNSIP: str | None = None
    DomesticDNSType: str | None = None
    DomesticDNSIP: str | None = None
    LastUpdated: str


def build_routing_profile() -> IncyRoutingProfile:
    return IncyRoutingProfile(
        Name="Interconnection Bypass RU",
        DirectSites=DOMAINS_DIRECT,
        DirectIp=DIRECT_IP,
        BlockSites=BLOCK_SITES,
        LastUpdated=str(int(time.time())),
    )


def encode_routing_header(profile: IncyRoutingProfile) -> str:
    payload = json.dumps(profile.model_dump(exclude_none=True), ensure_ascii=False)
    return base64.b64encode(payload.encode("utf-8")).decode("utf-8")
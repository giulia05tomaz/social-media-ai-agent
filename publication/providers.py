"""Publication provider contracts. Real publishing remains unarmed in Phase 8.2."""
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import json

from .buffer_client import BufferClient


class SocialPublishProvider(Protocol):
    def list_channels(self, organization_id: str) -> list[dict[str, Any]]: ...
    def get_channel(self, channel_id: str) -> dict[str, Any]: ...
    def create_post(self, payload: dict[str, Any], existing_provider_post_id: str | None = None) -> dict[str, Any]: ...


@dataclass
class BufferPublishProvider:
    client: BufferClient

    def list_channels(self, organization_id: str) -> list[dict[str, Any]]:
        return self.client.list_channels(organization_id)

    def get_channel(self, channel_id: str) -> dict[str, Any]:
        return self.client.get_channel(channel_id)

    def create_post(self, payload: dict[str, Any], existing_provider_post_id: str | None = None,
                    dry_run: bool | None = None) -> dict[str, Any]:
        return self.client.create_post(payload, existing_provider_post_id, dry_run)


class PublicationProvider(Protocol):
    def create_container(self, account_id: str, image_url: str, caption: str) -> str: ...
    def get_container_status(self, container_id: str) -> str: ...
    def publish_container(self, account_id: str, container_id: str) -> str: ...


@dataclass
class MockInstagramProvider:
    def create_container(self, account_id: str, image_url: str, caption: str) -> str:
        return f"mock-container-{account_id}"

    def get_container_status(self, container_id: str) -> str:
        return "FINISHED"

    def publish_container(self, account_id: str, container_id: str) -> str:
        return f"mock-media-{account_id}"


@dataclass
class InstagramLoginProvider:
    access_token: str
    api_version: str = "v26.0"
    host: str = "https://graph.instagram.com"
    live_mode: bool = False
    publish_enabled: bool = False

    def _guard(self) -> None:
        if not self.live_mode:
            raise RuntimeError("LIVE_MODE_DISABLED")
        if not self.publish_enabled:
            raise RuntimeError("INSTAGRAM_PUBLISH_DISABLED")
        if not self.access_token:
            raise RuntimeError("INSTAGRAM_CREDENTIALS_MISSING")

    def _request(self, method: str, path: str, data: dict | None = None) -> dict:
        self._guard()
        body = urlencode(data or {}).encode() if data is not None else None
        request = Request(f"{self.host}/{self.api_version}/{path.lstrip('/')}", data=body, method=method)
        request.add_header("Authorization", f"Bearer {self.access_token}")
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
        with urlopen(request, timeout=30) as response:  # pragma: no cover - Phase 8.1 must never reach here
            return json.loads(response.read())

    def create_container(self, account_id: str, image_url: str, caption: str) -> str:
        result = self._request("POST", f"{account_id}/media", {"image_url": image_url, "caption": caption})
        return result["id"]

    def get_container_status(self, container_id: str) -> str:
        result = self._request("GET", f"{container_id}?fields=status_code")
        return result["status_code"]

    def publish_container(self, account_id: str, container_id: str) -> str:
        result = self._request("POST", f"{account_id}/media_publish", {"creation_id": container_id})
        return result["id"]

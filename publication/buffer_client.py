"""Minimal Buffer GraphQL client with mutation guards.

Phase 8.2 calls only list_organizations, list_channels and get_channel.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import json


class BufferApiError(RuntimeError):
    pass


class BufferApiUncertainError(BufferApiError):
    """The transport failed after a live mutation may have reached Buffer."""


Transport = Callable[[str, dict[str, Any]], dict[str, Any]]


@dataclass
class BufferClient:
    api_key: str
    api_url: str = "https://api.buffer.com"
    transport: Transport | None = None
    live_mode: bool = False
    publish_enabled: bool = False
    selected_provider: str = "mock"
    dry_run: bool = False
    demo_mode: bool = True
    mutation_count: int = 0

    def _request(self, query: str, variables: dict[str, Any] | None = None) -> dict[str, Any]:
        if not self.api_key:
            raise BufferApiError("BUFFER_CREDENTIALS_MISSING")
        payload = {"query": query, "variables": variables or {}}
        if self.transport:
            result = self.transport(query, payload["variables"])
        else:
            request = Request(
                self.api_url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"},
                method="POST",
            )
            try:
                with urlopen(request, timeout=30) as response:
                    result = json.loads(response.read())
            except HTTPError as exc:
                if exc.code in (401, 403):
                    raise BufferApiError("BUFFER_AUTH_FAILED") from exc
                raise BufferApiError(f"BUFFER_HTTP_{exc.code}") from exc
            except (URLError, TimeoutError, OSError) as exc:
                raise BufferApiUncertainError("BUFFER_TRANSPORT_UNCERTAIN") from exc
        if result.get("errors"):
            raise BufferApiError("BUFFER_GRAPHQL_ERROR")
        return result.get("data", {})

    def _mutation_guard(self) -> None:
        if self.selected_provider != "buffer":
            raise BufferApiError("SOCIAL_PUBLISH_PROVIDER_NOT_BUFFER")
        if self.dry_run:
            raise BufferApiError("BUFFER_DRY_RUN_ACTIVE")
        if not self.live_mode:
            raise BufferApiError("LIVE_MODE_DISABLED")
        if not self.publish_enabled:
            raise BufferApiError("BUFFER_PUBLISH_DISABLED")
        if self.demo_mode:
            raise BufferApiError("DEMO_MODE_ACTIVE")
        if not self.api_key:
            raise BufferApiError("BUFFER_CREDENTIALS_MISSING")

    def list_organizations(self) -> list[dict[str, Any]]:
        data = self._request("query GetOrganizations { account { organizations { id } } }")
        return data["account"]["organizations"]

    def list_channels(self, organization_id: str) -> list[dict[str, Any]]:
        query = """query GetChannels($organizationId: OrganizationId!) {
          channels(input: {organizationId: $organizationId}) {
            id name displayName service type isDisconnected allowedActions timezone
          }
        }"""
        return self._request(query, {"organizationId": organization_id})["channels"]

    def get_channel(self, channel_id: str) -> dict[str, Any]:
        query = """query GetChannel($id: ChannelId!) {
          channel(input: {id: $id}) {
            id name displayName service type isDisconnected allowedActions timezone
          }
        }"""
        return self._request(query, {"id": channel_id})["channel"]

    def get_post(self, post_id: str) -> dict[str, Any]:
        query = """query GetPost($id: PostId!) {
          post(input: {id: $id}) { id channelId status text dueAt externalLink }
        }"""
        return self._request(query, {"id": post_id})["post"]

    @staticmethod
    def _create_post_request(payload: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        scheduling_type = payload.get("scheduling_type")
        if scheduling_type not in ("automatic", "notification"):
            raise BufferApiError("BUFFER_SCHEDULING_TYPE_REQUIRED")
        mode = payload.get("provider_mode", "shareNow")
        if mode not in ("shareNow", "shareNext", "addToQueue", "customScheduled"):
            raise BufferApiError("BUFFER_SHARE_MODE_INVALID")
        query = """mutation CreatePost($input: CreatePostInput!) {
          createPost(input: $input) {
            __typename
            ... on PostActionSuccess { post { id status dueAt text externalLink } }
            ... on MutationError { message }
          }
        }"""
        assets = []
        for item in payload.get("media", []):
            kind = item.get("type") or ("video" if str(item.get("mime_type", "")).startswith("video/") else "image")
            if kind not in ("image", "video"):
                raise BufferApiError("BUFFER_MEDIA_TYPE_UNSUPPORTED")
            assets.append({kind: {"url": item["url"]}})
        input_data = {
            "text": payload.get("caption", ""),
            "channelId": payload["provider_account_id"],
            "assets": assets,
            "schedulingType": scheduling_type,
            "mode": mode,
            "needsApproval": False,
            "source": "social-media-ai-agent",
        }
        if payload.get("platform") == "instagram":
            instagram_type = payload.get("instagram_type", "post")
            if instagram_type not in ("post", "story", "reel"):
                raise BufferApiError("BUFFER_INSTAGRAM_TYPE_INVALID")
            input_data["metadata"] = {
                "instagram": {
                    "type": instagram_type,
                    "shouldShareToFeed": bool(payload.get("should_share_to_feed", True)),
                    "isAiGenerated": bool(payload.get("ai_generated", False)),
                }
            }
        if mode == "customScheduled":
            if not payload.get("scheduled_at"):
                raise BufferApiError("BUFFER_SCHEDULED_AT_REQUIRED")
            input_data["dueAt"] = payload["scheduled_at"]
        return query, {"input": input_data}

    def prepare_create_post(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Build the real GraphQL request and intercept it before HTTP."""
        if self.selected_provider != "buffer":
            raise BufferApiError("SOCIAL_PUBLISH_PROVIDER_NOT_BUFFER")
        if not self.dry_run:
            raise BufferApiError("BUFFER_DRY_RUN_DISABLED")
        if not self.api_key:
            raise BufferApiError("BUFFER_CREDENTIALS_MISSING")
        query, variables = self._create_post_request(payload)
        return {
            "dry_run": True,
            "operation_name": "CreatePost",
            "query": query,
            "variables": variables,
            "http_mutation_executed": False,
        }

    def create_post(self, payload: dict[str, Any], existing_provider_post_id: str | None = None,
                    dry_run: bool | None = None) -> dict[str, Any]:
        """Use one serialization path for dry-run and future live publishing."""
        effective_dry_run = self.dry_run if dry_run is None else dry_run
        if effective_dry_run:
            original = self.dry_run
            self.dry_run = True
            try:
                return self.prepare_create_post(payload)
            finally:
                self.dry_run = original
        self._mutation_guard()
        if existing_provider_post_id:
            return self.get_post(existing_provider_post_id)
        if self.mutation_count >= 1:
            raise BufferApiError("BUFFER_MUTATION_LIMIT_EXCEEDED")
        query, variables = self._create_post_request(payload)
        self.mutation_count += 1
        return self._request(query, variables)["createPost"]

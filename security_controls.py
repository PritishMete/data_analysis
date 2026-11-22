"""Central application security controls."""
from __future__ import annotations

import ipaddress
import os
import re
import socket
from pathlib import PurePath
from urllib.parse import urlparse

SAFE_UPLOAD_EXTENSIONS = {".csv", ".tsv", ".xlsx", ".xls", ".parquet"}
_CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")


def configured_origins() -> set[str]:
    default = (
        "https://pritishmete.github.io"
        if os.getenv("INSIGHTFLOW_ENV", "production").strip().lower() == "production"
        else "https://pritishmete.github.io,http://localhost:3000,http://localhost:5000,http://127.0.0.1:3000"
    )
    raw = os.getenv("INSIGHTFLOW_CORS_ORIGINS", default)
    return {item.strip().rstrip("/") for item in raw.split(",") if item.strip()}


def validate_upload_filename(filename: str | None) -> str:
    name = str(filename or "").strip()
    if not name or len(name) > 255 or _CONTROL_CHARS.search(name) or any(char in name for char in '<>"\''):
        raise ValueError("Invalid upload filename.")
    if "\\" in name or "/" in name or name in {".", ".."}:
        raise ValueError("Upload filename must not contain a path.")
    if PurePath(name).suffix.lower() not in SAFE_UPLOAD_EXTENSIONS:
        raise ValueError("Unsupported upload file type.")
    return name


def validate_outbound_url(raw_url: str, *, allowed_hosts: set[str]) -> str:
    """Validate an outbound URL against strict SSRF policy."""
    parsed = urlparse(str(raw_url or ""))
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.port:
        raise ValueError("Only HTTPS URLs without credentials or custom ports are allowed.")
    host = (parsed.hostname or "").rstrip(".").lower()
    normalized_hosts = {h.rstrip(".").lower() for h in allowed_hosts}
    if not host or host not in normalized_hosts:
        raise ValueError("Outbound host is not allowlisted.")
    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)}
    except OSError as exc:
        raise ValueError("Outbound host could not be resolved.") from exc
    for address in addresses:
        parsed_ip = ipaddress.ip_address(address)
        if parsed_ip.is_private or parsed_ip.is_loopback or parsed_ip.is_link_local or parsed_ip.is_reserved or parsed_ip.is_unspecified:
            raise ValueError("Outbound host resolves to a private or reserved network.")
    return parsed.geturl()

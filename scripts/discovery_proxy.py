#!/usr/bin/env python3
"""
Auto-discovery reverse proxy for vLLM endpoint.

Solves: vLLM HTTP server's node changes with each training restart
(Ray actor placement is non-deterministic).

Architecture:
  trajproxy → localhost:9090 (this proxy, on x86)
  this proxy → auto-discovers actual vLLM node → forwards

Deploy once on x86, never change trajproxy config again.
"""
import asyncio
import logging
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Nodes to scan for vLLM API (rollout first, then all)
NODES = [17, 195, 85, 48, 36, 41, 51, 88, 89, 47, 50, 189]
PORT = 9090

_state = {"backend": None, "last_discovery": 0}
DISCOVERY_INTERVAL = 30  # re-discover every 30s if backend is down


async def discover_backend(force: bool = False) -> str | None:
    """Scan nodes to find active vLLM API."""
    import time
    now = time.time()
    if not force and _state["backend"] and now - _state["last_discovery"] < DISCOVERY_INTERVAL:
        return _state["backend"]

    for node in NODES:
        url = f"http://192.168.0.{node}:{PORT}"
        try:
            async with httpx.AsyncClient(timeout=2) as c:
                r = await c.get(f"{url}/v1/models")
                if r.status_code == 200 and "object" in r.json():
                    _state["backend"] = url
                    _state["last_discovery"] = now
                    logger.info(f"Found vLLM at {url}")
                    return url
        except Exception:
            continue

    logger.warning("No vLLM backend found")
    _state["backend"] = None
    return None


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting auto-discovery proxy on :9090")
    await discover_backend(force=True)
    yield


app = FastAPI(lifespan=lifespan)


# Health check
@app.get("/health")
async def health():
    backend = _state["backend"]
    return {"status": "ok", "backend": backend}


@app.get("/discover")
async def force_discover():
    backend = await discover_backend(force=True)
    return {"backend": backend}


# Proxy all requests
@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
async def proxy(request: Request, path: str):
    backend = _state["backend"] or await discover_backend()
    if not backend:
        return JSONResponse({"error": "no vLLM backend available"}, status_code=503)

    url = f"{backend}/{path}"
    method = request.method
    headers = {k: v for k, v in request.headers.items() if k not in ["host", "connection"]}

    try:
        async with httpx.AsyncClient(timeout=300) as c:
            if method == "GET":
                r = await c.get(url, headers=headers, params=dict(request.query_params))
            elif method in ("POST", "PUT", "PATCH"):
                body = await request.body()
                r = await c.request(method, url, content=body, headers=headers)
            else:
                r = await c.request(method, url, headers=headers)

            # Check if backend died
            if r.status_code >= 500:
                _state["backend"] = None
                # Try to rediscover
                backend = await discover_backend(force=True)
                if backend:
                    url = f"{backend}/{path}"
                    if method in ("POST", "PUT", "PATCH"):
                        r = await c.request(method, url, content=body, headers=headers)

            return JSONResponse(r.json() if r.headers.get("content-type", "").startswith("application/json") else {"raw": r.text}, status_code=r.status_code)
    except httpx.ConnectError:
        _state["backend"] = None
        return JSONResponse({"error": "backend connection failed, rediscovering"}, status_code=502)
    except Exception as e:
        logger.error(f"Proxy error: {e}")
        return JSONResponse({"error": str(e)}, status_code=500)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=9090)

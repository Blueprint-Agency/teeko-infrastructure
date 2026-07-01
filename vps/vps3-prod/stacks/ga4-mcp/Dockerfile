# Wraps the upstream stdio-only Google Analytics MCP server (PyPI: analytics-mcp)
# with mcp-proxy so it can be reached over HTTP/SSE behind Traefik.
# Upstream has no HTTP transport and no official image: https://github.com/googleanalytics/google-analytics-mcp
FROM ghcr.io/sparfenyuk/mcp-proxy:latest

RUN pip install --no-cache-dir analytics-mcp

# Wraps the upstream stdio-only Google Search Console MCP server
# (PyPI: mcp-search-console, github.com/AminForou/mcp-gsc) with mcp-proxy so it can be
# reached over HTTP behind Traefik. Upstream has no HTTP transport and no official image.
# The console script installed by the package is `mcp-gsc`.
FROM ghcr.io/sparfenyuk/mcp-proxy:latest

RUN pip install --no-cache-dir mcp-search-console

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**bashttpd** is a single-file HTTP server written entirely in bash. It relies on an external TCP listener (`ncat`, `socat`, or `netcat`) to accept connections. Each incoming connection spawns a fresh `bashttpd` process — one request in on stdin, one response out on stdout, then exit. There is no build step, no test suite, and no dependencies beyond bash and standard coreutils.

## Running the server

```bash
./start.sh              # foreground on port 38080
./start.sh 9090         # foreground on custom port
./start.sh -d           # daemon mode (backgrounds itself)
./start.sh -d 9090      # daemon + custom port
```

`start.sh` invokes `ncat -4lkp <port> -e ./bashttpd`. Stop the server by killing the `ncat` process. The `tree` command is recommended for HTML directory listings (falls back to `ls -la`).

## Architecture

The entire server is two files working together:

- **`bashttpd`** (the executable) — Reads one HTTP request from stdin, parses the request line and headers, then `source`s `bashttpd.conf` to evaluate routing rules. Contains all HTTP response logic, MIME detection, file/directory serving, and path sanitization. Only `GET` is supported; everything else returns 405.

- **`bashttpd.conf`** (sourced as bash code) — Defines routes using `on_uri_match REGEX command` and `unconditionally command`. Rules are evaluated top-to-bottom; the first match calls `send_response_ok_exit` / `exit 0`, so later rules are skipped. If nothing matches, `bashttpd` falls through to `fail_with 500`. Custom handler functions can be defined directly in this file.

## Request lifecycle

1. `ncat` accepts a TCP connection and spawns `./bashttpd`
2. `bashttpd` reads the request line → parses `REQUEST_METHOD`, `REQUEST_URI`, `REQUEST_HTTP_VERSION`
3. Reads remaining headers into `REQUEST_HEADERS` array
4. `source bashttpd.conf` — routing rules execute inline
5. First matching `on_uri_match` calls its handler, which sends the response and `exit 0`
6. If no match, `fail_with 500`

## How routing works

```bash
# bashttpd.conf routing primitives:
on_uri_match '^/path(.*)' serve_dir_or_file_from "/local/root"
unconditionally serve_static_string 'fallback response'
```

- `on_uri_match REGEX handler [args]` — tests `$REQUEST_URI` against a bash extended regex. If it matches, calls `handler` with `[args] ${BASH_REMATCH[@]}` appended. The capture groups in `BASH_REMATCH` are how the URI sub-path reaches the handler.
- `unconditionally handler [args]` — always fires; use as a catch-all at the end.
- `serve_dir_or_file_from DIR` is the workhorse — it constructs a local path from `DIR + BASH_REMATCH[capture]`, strips query parameters, sanitizes the path (whitelist `[a-zA-Z0-9_~\-\.\/]`, blocks `..`), serves `index.html` if present, then dispatches to `serve_file` or `serve_dir`.

## Writing custom handlers

Define a bash function in `bashttpd.conf`. Arguments are your explicit args followed by `${BASH_REMATCH[@]}` (full match at `$1`, first capture group at `$2`, etc.):

```bash
my_handler() {
   add_response_header "Content-Type" "text/plain"
   send_response_ok_exit <<< "You requested: $2"
}
on_uri_match '^/api/(.*)$' my_handler
```

## Available serve commands

| Command | Purpose |
|---|---|
| `serve_file FILE` | Serve a single file with auto-detected MIME type |
| `serve_dir DIR` | Directory listing via `tree -H` (HTML) or `ls -la` (plain text fallback) |
| `serve_dir_or_file_from DIR` | Map URI to local path under DIR; serve file or directory listing |
| `serve_static_string STRING` | Return a plain-text string |

## Binary vs text response

`serve_file` checks `Content-Type`: if it starts with `text`, it uses `send_response` (line-by-line read/write). Otherwise it uses `send_response_bin` (raw `cat` + `sleep 10` as a crude keep-alive to prevent premature connection closure).

## MIME type handling

Hardcoded overrides for `.css` → `text/css`, `.js` → `text/javascript`, `.md` → `text/markdown; charset=utf-8`. Everything else uses `file -b --mime-type`. Content-Length comes from `stat -c'%s'` (GNU coreutils).

## Markdown preview

Three HTML viewer pages serve markdown files rendered client-side via `marked.js` (loaded from CDN):
- `md_viewer.html` — basic GitHub-styled preview
- `md_viewer_raw.html` — minimal raw viewer
- `md_viewer_rich.html` — full-featured: live editor, theme toggle, Prism.js syntax highlighting

Usage: navigate to `md_viewer.html?file=/path/to/doc.md` — the viewer fetches the `.md` via AJAX and renders it.

## Key conventions

- `set -vx` is active in `on_uri_match` and at the top level — all request processing is traced to stderr (the `ncat` parent's stderr). Use this for debugging.
- `recv` / `send` log to stderr with `<` / `>` prefixes — the server's debug log is the stderr stream.
- Path sanitization strips everything not in `[a-zA-Z0-9_~\-\.\/]` and rejects any `..` with 400. This means URIs with spaces, unicode, or special characters are silently stripped.
- First run without a `bashttpd.conf` auto-generates a default config and exits — this is intentional bootstrap behavior, not an error.
- The `/timeout` URI triggers a 3-day sleep (test artifact in `on_uri_match`).

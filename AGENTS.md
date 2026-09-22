# Repository Guidelines

## Project Structure & Module Organization

- `bashttpd` — the entire HTTP server, a single bash script (~320 lines). Request parsing, response helpers, and built-in serve commands all live here.
- `bashttpd.conf` — rule-based config sourced at request time (`on_uri_match REGEX cmd`, `unconditionally cmd`). If absent, the script generates a default and exits.
- `start.sh` — launcher: `ncat -4lkp <port> -e ./bashttpd`, or `./start.sh -d <port>` for daemon mode (nohup).
- `md_viewer.html`, `md_viewer_rich.html`, `md_viewer_raw.html` — static HTML/JS pages for markdown preview; edited as plain assets, no build step.
- No source tree, no vendored dependencies.

## Build, Test, and Development Commands

There is no build step. Run and verify manually:

```sh
./start.sh 38080                      # foreground, port 38080
./start.sh -d 38080                   # daemon mode
socat TCP4-LISTEN:8080,fork EXEC:$(pwd)/bashttpd   # one process per connection
curl -v http://127.0.0.1:38080/       # exercise directory listing
curl -v http://127.0.0.1:38080/some/file.md   # file serving
```

Requirements: bash, `ncat`/`socat`/netcat, `file` (MIME types), `tree` (optional, prettier listings).

## Coding Style & Naming Conventions

- Bash 4+, POSIX-ish: use `local`, avoid the `function` keyword, prefer bash built-ins over external tools (per upstream history).
- Indentation is 3 spaces in `bashttpd`; match the surrounding block when editing.
- Functions are `lower_snake_case` verbs (`serve_file`, `fail_with`, `add_response_header`); globals are `UPPER_SNAKE_CASE` (`DOCROOT`, `REQUEST_URI`).
- No linter or formatter is configured; run `bash -n bashttpd` before committing.

## Testing Guidelines

There is no test framework. Verify changes end-to-end with `curl` against a running instance, covering at minimum: directory listing, file serving (text and binary), 404/403 paths, URL-encoded (percent-encoded, e.g. Chinese) filenames, and path-traversal rejection (`..` must return 400). Note the script runs `set -vx`; tracing on stderr is expected, not a bug.

## Commit & Pull Request Guidelines

- Commit messages are short, lowercase, imperative first lines, e.g. `support binary file download`, `fix bug of listing directory`. Prefix with `bashttpd:` or `start.sh:` when scoping is useful.
- Keep changes small and single-purpose; PRs should describe behavior changes, include `curl` output or commands used to verify, and note any `bashttpd.conf` impact.

## Security & Configuration Tips

- `bashttpd` runs untrusted URI input through bash regex matching and `urldecode`; treat it as a local/private tool only — the README warns against public deployment.
- New URL routes go in `bashttpd.conf`, not the script, unless a new serve command is genuinely required (see the `serve_hello` example in the generated default config).

# macOS

The macOS half of the Claude Code → InferHub shim. One script installs
everything; nothing here needs `sudo`.

```bash
./setup.sh              # install (idempotent, safe to re-run)
./setup.sh --check      # report what is present, change nothing
./setup.sh --uninstall  # remove the launcher, keep your key

claude-acs              # pick a model + folder, then launch Claude Code
claude-acs ~/some/proj  # skip the pickers
```

`setup.sh` installs, without `sudo`:

| Piece | Where |
|---|---|
| Claude Code | into **every** Node prefix it finds (see the trap below) |
| LiteLLM | `~/litellm/.litellm-venv` (uv-managed Python 3.12) |
| Proxy scripts | `~/litellm/{start,stop}-litellm.sh`, `~/litellm/scripts/apply_seat.py` |
| Launcher | `~/.local/bin/claude-acs` + `launch-claude-inferhub.sh` |
| InferHub key | `~/.config/inferhub/.env`, mode 600 |

It never uses `sudo`, so it works on a stock Mac without an admin prompt.

## The model table is live, not hardcoded

`ire_live_models.py` fetches the current IRE Top 20 at runtime:

```
Pukujan/inference-recommendation-engine
  operational/telemetry/gravebuster/pipeline/ihub/lists/
    research_model_top20_recommendations.csv
```

```bash
python3 ire_live_models.py               # print the table (cache if fresh)
python3 ire_live_models.py --refresh     # force a re-fetch
python3 ire_live_models.py --check-proxy # run one real completion per route
```

Results cache to `~/.local/state/claude-acs/ire-models.json` for 6 hours, so a
launch works offline and falls back to the cache if GitHub is unreachable.

`--check-proxy` is the honest availability check — it asks LiteLLM to actually run
a completion per route instead of trusting the CSV. Last run on this Mac:

```
answered: 16/20   unavailable: 4/20
  #8  cmc/meta/muse-spark-1.3-contributor   503 no provider available
  #11 ali/deepseek-v4-flash-0731            402 no provider bidding
  #17 cmc/meta/muse-spark-1.2-contributor   503 no provider available
  #20 ali/kimi-k2.7-code                    402 no provider bidding
```

Those four are upstream capacity, not misconfiguration. The routes stay in the
table because that reflects the ranking; run `--check-proxy` to see what answers
right now.

## Folder navigation (terminal only)

In the launcher menu, `b` opens browse mode:

| Key | Action |
|---|---|
| `Up` / `Down` | move the highlight |
| `Right` / `Enter` | forward — go **into** the highlighted folder |
| `Left` / `Backspace` | back — go to the **owning (parent)** folder |
| `n` | new folder here, then go into it |
| `b` | back to the main menu |
| `Esc` | back to the main menu |

Left/right are strictly parent/child — there is no history stack, so the path in
the title always tells you where you are. Leaving a folder re-highlights it, so
`Right` goes straight back in.

Main menu: `b` browse · `q` quick picks · `t` type a path · `n` new folder.
Recent folders appear automatically (newest first, capped at 20).

There is deliberately **no Finder/GUI dialog** (`osascript choose folder`). It
blocks the terminal, steals focus, and cannot be driven from a script. A test
asserts no `osascript` call exists in the launcher.

## Gotchas this handles for you

Each was a real failure during development, with a code guard or a test:

- **Multiple Node prefixes.** `/opt/homebrew/bin/node` and
  `~/.nvm/versions/node/*/bin/node` frequently coexist. A global `npm i -g`
  installs into exactly one, so `claude` resolves in one shell and not another.
  `setup.sh` installs into every prefix and verifies each with
  `claude --version`.
- **Inherited `NPM_CONFIG_PREFIX`.** An exported prefix silently redirects the
  install to the wrong tree — it reported success while doing exactly that.
  Cleared per install.
- **`python -m litellm` fails.** The package has no `__main__`; the proxy uses the
  `litellm` console script.
- **Claude Code ignores `ANTHROPIC_MODEL` on the wire.** It sends its own model
  ids (observed `claude-sonnet-5-5`), so the seat config aliases every Claude Code
  id, not just `sonnet`/`main`/`opus`.
- **`ANTHROPIC_AUTH_TOKEN` beats `ANTHROPIC_API_KEY`.** A leftover token routes
  around the proxy with no visible error, so the environment is scrubbed of every
  `ANTHROPIC_*` / `CLAUDE_CODE_*` / `CKFF_*` variable first.
- **UI output inside `$(...)`.** The picker returns an index on stdout; a
  screen-clearing escape printed to stdout lands in that capture and corrupts it.
  All UI writes go to `/dev/tty`, and `assert_index` fails loudly rather than
  letting a bad value reach arithmetic.
- **bash 3.2 `read -t` takes integers only.** The escape-sequence read uses `-t 1`.

## No master key

The proxy runs **without** a LiteLLM master key, bound to loopback only. Claude
Code still requires an `ANTHROPIC_API_KEY` value, so it receives a dummy that
LiteLLM ignores. The real `INFERHUB_API_KEY` stays inside the proxy process and is
never written into the Claude child environment, a settings file, or this repo.

## Tests

```bash
bash tests/run-tests.sh    # 40 assertions, offline
bash tests/nav-tests.sh    # 25 assertions, folder navigation
shellcheck -S warning *.sh proxy/*.sh
```

CI additionally builds bash 3.2 explicitly, because macOS ships 3.2 and the
launcher must run there — Linux runners only ever test bash 5.
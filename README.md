# hey-edge-probe

The external probe for [heyresearch.xyz](https://heyresearch.xyz): every hour, a GitHub Actions run reads HEY
Research Lab's public pages and API through Cloudflare, the way a visitor does, and fails when a route answers a
server error or is slower than [HEY's performance budget](packages/domain/src/reliability/performance-budget.json)
allows. Each run's table is in its job summary.

- Public reads only: no secret, no credential, no write. Requests are labelled `hey-internal/edge-probe`.
- `scripts/edge-probe.sh` and the budget are copied from HEY's own repository; `scripts/lib/common.sh` holds only the
  three helpers the probe uses.
- Run it yourself: `scripts/edge-probe.sh --base-url https://heyresearch.xyz` (needs curl, jq and awk).

Community-run by Hey Research Lab · not affiliated with or endorsed by Robinhood.

MIT licence.

# SMPC-RL

Use this Compose project to run two-party SMPC record linkage through BeamSEL. It starts two isolated bridgehead-like sites, a Beam broker with local PKI, and `samply/secure-linkage-service`.

Each site runs Mainzelliste, PostgreSQL, a Beam proxy, BeamSEL, SecureEpiLinker, and a curl sidecar. The test uses the curl sidecars to trigger the REST endpoints in the Mainzelliste. A data loader imports 20 records from each CSV file in `test-data/`.

## Manually run the test

Run these commands from the repository root:

```bash
docker compose -f compose.local.yaml pull
docker compose -f compose.local.yaml up -d --no-build
docker compose -f compose.local.yaml wait two-party-match-test
```

`docker compose wait` returns the test container's exit code.

Follow the test output with:

```bash
docker compose -f compose.local.yaml logs -f two-party-match-test
```

The `two-party-match-test` container runs `two-party-match.sh`. Run the script through Compose because it expects the Compose containers, Docker socket access, `jq`, and the per-site curl containers.

## Test coverage

The Linkage Service reads its parties from `config/linkage-parties.toml`. The automated test:

- confirms that the Linkage Service knows `SiteA` and `SiteB`;
- waits for both Beam proxies and both SecureEpiLinker peers;
- initializes persisted linkage IDs;
- runs M:N matching from `SiteA` to `SiteB`;
- uses a page size of five records;
- requires `matchingStatus` to reach `finished`;
- runs M:N linkage and waits for the new SecureEpiLinker job to finish;
- verifies 20 unique linkage IDs;
- checks that every returned ID exists in PostgreSQL;
- rejects numeric temporary IDs.

## Test report

The test writes `/test-results/smpc-rl-report.json` inside the test container. Copy it after the run:

```bash
mkdir -p test-results
docker compose -f compose.local.yaml cp \
  two-party-match-test:/test-results/. test-results/
```

The report contains matching totals, matching and linkage job results, and ID verification counts.

GitHub Actions uploads `smpc-rl-report.json` and the Compose logs as the `smpc-rl-report` artifact. The workflow also includes the JSON report in the job summary.

## Cleanup

Remove the containers, networks, and test databases after the run:

```bash
docker compose -f compose.local.yaml down -v --remove-orphans
```

## License

Apache License 2.0. See `LICENSE`.

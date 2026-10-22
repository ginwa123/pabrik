# benchmark

A GET benchmark whose **verdict is determined** and whose timing is honest about being timing.

```sh
zig build install:linux -Doptimize=ReleaseFast -Dno-webapp-rebuild   # produces zig-out/bin/pabrikcore-linux-x86_64
benchmark/run.sh selftest                                            # the harness unit tests, no container, no network
benchmark/run.sh run                                                 # build, isolate, measure, gate
CONTAINER_ENGINE=podman benchmark/run.sh run                         # same thing on podman
```

`run` leaves `api-bench.json`, `api-bench.md` and `server.log` in `$API_BENCH_OUT`
(default `$TMPDIR/pabrik-api-bench`). Nothing it writes lands in the repository.

## The fixed spec

Both phases run inside containers, and every knob that could move the numbers is pinned:

| | server | load generator |
| --- | --- | --- |
| image | `benchmark/Containerfile` (ubuntu 24.04 + the four libs the binary NEEDs) | same image |
| cpu | `--cpus 2 --cpuset-cpus 0,1` | `--cpus 2 --cpuset-cpus 2,3` |
| memory | 2048m, swap disabled | 1024m, swap disabled |
| network | `--network none` | `--network container:<server>` |

The server binds `127.0.0.1` only (`src/main.zig:281`), so the load generator joins its **netns**.
The only reachable network in either container is loopback, and no other process on the machine can
take those four cores. Numbers from a machine without four logical cpus are refused, not fudged:
`benchmark/run.sh` exits before building anything.

A host whose cgroup delegates `cpu memory pids` but not `cpuset` (rootless podman on a desktop) can
still run the harness by dropping the pinning — `API_BENCH_SERVER_CPUSET=` and
`API_BENCH_CLIENT_CPUSET=` — which reports the profile as `quota-2cpu` instead of `dedicated-2cpu`
and loosens nothing else.

## The contract, and what is allowed to move

Two phases, each exactly `$API_BENCH_REQUESTS` requests on a closed loop (never "run for 30
seconds"): concurrency 1 (`c1`) and concurrency N (`cN`).

**Determined.** Every response must be `200`, `application/json`, and byte-identical once the
`timestamp` field is masked — the only byte that legitimately differs between two runs of
`GET /health`. `machine.result_sha256` covers that contract and nothing else, so two runs of one
profile print the same digest:

```
deterministic result digest `…` — identical on every run of this profile, timing excluded
```

Measured over five local runs: one digest, one body fingerprint, `rps` between 17.5k and 57k
depending on what else the host was doing. A run with 12 CPU hogs on the box produced the same
digest and a red *performance* gate — which is the intended split.

**Advisory.** `scaling.throughput` is `throughput(cN) / throughput(c1)`, a ratio, so machine speed
cancels out of it. `latency.p99_c1` and `throughput.cN` are deliberately loose ceilings that only
catch a catastrophic regression. All three are warnings unless the run is strict
(`API_BENCH_STRICT=1`, or the `strict` input on the workflow dispatch); the functional checks are
always enforced.

On a GitHub-hosted runner (4 vCPU, the `dedicated-2cpu` profile):

```
| gate | kind | value | limit | ok |
| scaling.throughput | performance | 6.132 | 2.000 | yes |
| latency.p99_c1 | performance | 0.093 | 5.000 | yes |
| throughput.cN | performance | 84958.400 | 2000.000 | yes |
```

The limits are set an order of magnitude away from that baseline on purpose: this gate exists to
catch a collapse, not to police a percentage.

## kabelweb closes a connection every 1000 requests

`Keep-Alive: timeout=5, max=1000`, enforced at `keepalive_count < 1000` in kabelweb's threaded and
event-loop paths. The load generator reconnects on `Connection: close` and reports how many
connections it needed: 2 for 2000 requests at concurrency 1, one per worker at concurrency 8. A run
that needed more than that is a server behaviour change worth looking at, not a client bug.

## Files

| file | what it is |
| --- | --- |
| `api_bench.zig` | the load generator, the statistics, the gate, and 41 `zig test` behaviour checks |
| `run.sh` | the orchestration: load generator build, image build, both containers, artifacts, exit code |
| `Containerfile` | the image both containers run |

`.github/workflows/ci-api-benchmark.yml` is the same three steps, on a GitHub-hosted runner. It is a
visible check and deliberately not part of `ci-ok`.

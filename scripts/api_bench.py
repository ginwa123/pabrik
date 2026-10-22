#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import socket
import sys
import threading
import time

SCHEMA_VERSION = 1
EXPECTED_BODY = b'{"status":"ok","timestamp":<ts>}'
TIMESTAMP_FIELD = re.compile(rb'"timestamp":\s*-?\d+')
STATUS_LINE = re.compile(rb"^HTTP/1\.1\s+(\d{3})\b")
CHUNK_SIZE_LINE = re.compile(rb"^([0-9a-fA-F]+)$")
TOO_MANY_BYTES = 1 << 20

PHASES = ("c1", "cN")
DETERMINISTIC_PHASE_FIELDS = (
    "requests",
    "expected_requests",
    "statuses",
    "distinct_bodies",
    "body_fingerprint",
    "content_types",
    "ok",
    "problems",
)


def deterministic_view(spec, phases, gate):
    return {
        "spec": spec,
        "phases": {
            name: {field: phases[name][field] for field in DETERMINISTIC_PHASE_FIELDS}
            for name in PHASES
        },
        "functional_checks": [
            {"name": check["name"], "ok": check["ok"]}
            for check in gate["checks"]
            if check["kind"] == "functional"
        ],
    }


def result_digest(spec, phases, gate):
    payload = json.dumps(
        deterministic_view(spec, phases, gate), sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(payload.encode()).hexdigest()


def normalize_body(body):
    return TIMESTAMP_FIELD.sub(b'"timestamp":<ts>', body)


def fingerprint(bodies):
    digest = hashlib.sha256()
    for body in sorted(set(bodies)):
        digest.update(len(body).to_bytes(8, "big"))
        digest.update(body)
    return digest.hexdigest()


def percentile(ordered_values, q):
    if not ordered_values:
        return None
    if q <= 0:
        return ordered_values[0]
    if q >= 1:
        return ordered_values[-1]
    position = (len(ordered_values) - 1) * q
    lower = int(position)
    upper = lower + 1
    if upper >= len(ordered_values):
        return ordered_values[lower]
    fraction = position - lower
    return int(round(ordered_values[lower] + (ordered_values[upper] - ordered_values[lower]) * fraction))


def plan_requests(total, workers):
    if workers < 1:
        raise ValueError("concurrency must be at least 1")
    base, remainder = divmod(total, workers)
    return [base + (1 if worker < remainder else 0) for worker in range(workers)]


def latency_stats(durations_ns, elapsed_ns):
    ordered = sorted(durations_ns)
    if not ordered:
        return {
            "samples": 0,
            "p50_ms": None,
            "p90_ms": None,
            "p99_ms": None,
            "max_ms": None,
            "mean_ms": None,
            "throughput_rps": 0.0,
        }
    seconds = elapsed_ns / 1e9
    return {
        "samples": len(ordered),
        "p50_ms": round(percentile(ordered, 0.50) / 1e6, 3),
        "p90_ms": round(percentile(ordered, 0.90) / 1e6, 3),
        "p99_ms": round(percentile(ordered, 0.99) / 1e6, 3),
        "max_ms": round(ordered[-1] / 1e6, 3),
        "mean_ms": round(sum(ordered) / len(ordered) / 1e6, 3),
        "throughput_rps": round(len(ordered) / seconds, 1) if seconds > 0 else 0.0,
    }


def parse_head(head):
    lines = head.split(b"\r\n")
    match = STATUS_LINE.match(lines[0])
    if match is None:
        raise ValueError("not an HTTP/1.1 status line: %r" % lines[0][:64])
    headers = {}
    for line in lines[1:]:
        if not line:
            continue
        name, _, value = line.partition(b":")
        headers[name.strip().lower()] = value.strip()
    return int(match.group(1)), headers


def take_chunked(buf):
    body = b""
    offset = 0
    while True:
        line_end = buf.find(b"\r\n", offset)
        if line_end < 0:
            return None, buf
        match = CHUNK_SIZE_LINE.match(buf[offset:line_end].split(b";")[0].strip())
        if match is None:
            raise ValueError("bad chunk size line: %r" % buf[offset:line_end][:32])
        size = int(match.group(1), 16)
        offset = line_end + 2
        if size == 0:
            trailer_end = buf.find(b"\r\n\r\n", offset - 2)
            if trailer_end < 0:
                if buf.endswith(b"\r\n") and len(buf) == offset + 2:
                    return body, buf[offset + 2:]
                return None, buf
            return body, buf[trailer_end + 4:]
        if len(buf) < offset + size + 2:
            return None, buf
        body += buf[offset:offset + size]
        offset += size + 2


def take_response(buf):
    head_end = buf.find(b"\r\n\r\n")
    if head_end < 0:
        if len(buf) > TOO_MANY_BYTES:
            raise ValueError("response head exceeds %d bytes" % TOO_MANY_BYTES)
        return None, buf
    status, headers = parse_head(buf[:head_end])
    offset = head_end + 4
    if b"content-length" in headers:
        length = int(headers[b"content-length"])
        if len(buf) < offset + length:
            return None, buf
        return {
            "status": status,
            "headers": headers,
            "body": buf[offset:offset + length],
        }, buf[offset + length:]
    if headers.get(b"transfer-encoding", b"").lower() == b"chunked":
        body, rest = take_chunked(buf[offset:])
        if body is None:
            return None, buf
        return {"status": status, "headers": headers, "body": body}, rest
    return None, buf


def read_response(sock, buf):
    while True:
        response, rest = take_response(buf)
        if response is not None:
            return response, rest
        chunk = sock.recv(1 << 16)
        if not chunk:
            raise ConnectionError("peer closed the connection mid-response")
        buf += chunk


def aggregate(samples, elapsed_ns, expected_requests, expected_body=EXPECTED_BODY, connections=0):
    statuses = {}
    content_types = set()
    bodies = []
    durations = []
    for duration_ns, status, body, content_type in samples:
        durations.append(duration_ns)
        statuses[str(status)] = statuses.get(str(status), 0) + 1
        content_types.add(content_type if isinstance(content_type, str) else content_type.decode("utf-8", "replace"))
        bodies.append(normalize_body(body))

    unique_bodies = sorted(set(bodies))
    report = {
        "requests": len(samples),
        "expected_requests": expected_requests,
        "statuses": dict(sorted(statuses.items())),
        "distinct_bodies": len(unique_bodies),
        "body_fingerprint": fingerprint(bodies) if bodies else None,
        "content_types": sorted(content_types),
        "connections": connections,
        "latency": latency_stats(durations, elapsed_ns),
    }
    report["problems"] = phase_problems(report, unique_bodies, expected_body)
    report["ok"] = not report["problems"]
    return report


def phase_problems(report, unique_bodies, expected_body):
    problems = []
    if report["requests"] != report["expected_requests"]:
        problems.append(
            "completed %d of %d requests" % (report["requests"], report["expected_requests"])
        )
    if report["requests"] == 0:
        problems.append("no responses were measured")
        return problems
    unexpected = {code: count for code, count in report["statuses"].items() if code != "200"}
    if unexpected:
        problems.append("non-200 statuses %s" % unexpected)
    if report["distinct_bodies"] != 1:
        problems.append("%d distinct response bodies" % report["distinct_bodies"])
    elif unique_bodies[0] != expected_body:
        problems.append("body does not match the contract: %r" % unique_bodies[0][:160])
    if not report["content_types"]:
        problems.append("no content-type was sent")
    for content_type in report["content_types"]:
        if not content_type.startswith("application/json"):
            problems.append("content-type %r is not application/json" % content_type)
    return problems


def evaluate_gate(phases, rules, strict):
    checks = []
    for name in PHASES:
        phase = phases[name]
        checks.append({
            "name": "functional.%s" % name,
            "kind": "functional",
            "ok": phase["ok"],
            "detail": "; ".join(phase["problems"]) or "every response matches the contract",
        })

    floor = phases["c1"]["latency"]["throughput_rps"]
    ceiling = phases["cN"]["latency"]["throughput_rps"]
    scaling = round(ceiling / floor, 3) if floor > 0 else 0.0
    checks.append({
        "name": "scaling.throughput",
        "kind": "performance",
        "ok": scaling >= rules["min_scaling"],
        "value": scaling,
        "limit": rules["min_scaling"],
        "detail": "throughput at concurrency %d over concurrency 1" % rules["concurrency"],
    })
    p99 = phases["c1"]["latency"]["p99_ms"]
    checks.append({
        "name": "latency.p99_c1",
        "kind": "performance",
        "ok": p99 is not None and p99 <= rules["max_p99_ms"],
        "value": p99,
        "limit": rules["max_p99_ms"],
        "detail": "percentile-99 round trip at concurrency 1, in milliseconds",
    })
    checks.append({
        "name": "throughput.cN",
        "kind": "performance",
        "ok": ceiling >= rules["min_rps"],
        "value": ceiling,
        "limit": rules["min_rps"],
        "detail": "requests per second at concurrency %d" % rules["concurrency"],
    })

    failed = [check for check in checks if not check["ok"]]
    enforced = [
        check["name"] for check in failed
        if check["kind"] == "functional" or strict
    ]
    return {
        "verdict": "pass" if not failed else "fail",
        "strict": bool(strict),
        "enforced": bool(enforced),
        "enforced_by": enforced,
        "checks": checks,
    }


def build_request(host, port, route, agent):
    lines = [
        "GET %s HTTP/1.1" % route,
        "Host: %s:%d" % (host, port),
        "User-Agent: %s" % agent,
        "Accept: application/json",
        "Connection: keep-alive",
    ]
    return ("\r\n".join(lines) + "\r\n\r\n").encode()


class Connection:
    def __init__(self, host, port, timeout):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.sock = None
        self.buf = b""
        self.opens = 0

    def open(self):
        self.sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""
        self.opens += 1

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.buf = b""

    def request(self, payload):
        if self.sock is None:
            self.open()
        try:
            self.sock.sendall(payload)
            response, self.buf = read_response(self.sock, self.buf)
        except OSError:
            self.close()
            self.open()
            self.sock.sendall(payload)
            response, self.buf = read_response(self.sock, self.buf)
        if response["headers"].get(b"connection", b"").strip().lower() == b"close":
            self.close()
        return response


def run_phase(host, port, request_bytes, requests, concurrency, timeout):
    counts = plan_requests(requests, concurrency)
    samples = [[] for _ in range(concurrency)]
    opened = [0] * concurrency
    failures = []
    lock = threading.Lock()
    barrier = threading.Barrier(concurrency + 1)

    def worker(index, count):
        connection = Connection(host, port, timeout)
        try:
            try:
                barrier.wait(timeout=120)
            except threading.BrokenBarrierError:
                return
            for _ in range(count):
                started = time.perf_counter_ns()
                response = connection.request(request_bytes)
                finished = time.perf_counter_ns()
                samples[index].append((
                    finished - started,
                    response["status"],
                    response["body"],
                    response["headers"].get(b"content-type", b"").decode("utf-8", "replace"),
                ))
            connection.close()
        except Exception as exc:
            with lock:
                failures.append("%s: %s" % (type(exc).__name__, exc))
            try:
                barrier.abort()
            except Exception:
                pass
            connection.close()
        finally:
            opened[index] = connection.opens

    threads = [
        threading.Thread(target=worker, args=(index, counts[index]), daemon=True)
        for index in range(concurrency)
    ]
    for thread in threads:
        thread.start()
    try:
        barrier.wait(timeout=120)
    except threading.BrokenBarrierError:
        pass
    started = time.perf_counter_ns()
    for thread in threads:
        thread.join(timeout=max(timeout, 1) * max(counts) + 60)
    elapsed = time.perf_counter_ns() - started

    flat = [sample for worker_samples in samples for sample in worker_samples]
    return flat, failures, elapsed, sum(opened)


def wait_ready(host, port, request_bytes, timeout):
    deadline = time.monotonic() + timeout
    last = "no attempt was made"
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2.0) as sock:
                sock.sendall(request_bytes)
                response, _ = read_response(sock, b"")
                if response["status"] == 200:
                    return True, None
                last = "status %d" % response["status"]
        except Exception as exc:
            last = "%s: %s" % (type(exc).__name__, exc)
        time.sleep(0.1)
    return False, last


def calibrate(rounds=32, size=1 << 20):
    payload = bytes(range(256)) * (size // 256)
    started = time.perf_counter_ns()
    for _ in range(rounds):
        hashlib.sha256(payload).digest()
    elapsed_ns = time.perf_counter_ns() - started
    mib = rounds * size / (1 << 20)
    return round(mib / (elapsed_ns / 1e9), 1) if elapsed_ns > 0 else 0.0


def render_markdown(result):
    spec = result["spec"]
    lines = [
        "## api benchmark: `GET %s`" % spec["route"],
        "",
        "profile `%s` — %d requests per phase, concurrency 1 and %d, warmup %d"
        % (spec["profile"], spec["requests"], spec["concurrency"], spec["warmup"]),
        "",
        "| phase | requests | p50 ms | p90 ms | p99 ms | max ms | rps | bodies | verdict |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for name in PHASES:
        phase = result["phases"][name]
        latency = phase["latency"]
        lines.append(
            "| %s | %d/%d | %s | %s | %s | %s | %s | %d | %s |"
            % (
                name,
                phase["requests"],
                phase["expected_requests"],
                latency["p50_ms"],
                latency["p90_ms"],
                latency["p99_ms"],
                latency["max_ms"],
                latency["throughput_rps"],
                phase["distinct_bodies"],
                "pass" if phase["ok"] else "fail",
            )
        )
    for name in PHASES:
        phase = result["phases"][name]
        if phase["problems"]:
            lines.append("")
            lines.append("- %s: %s" % (name, "; ".join(phase["problems"])))
    lines += ["", "| gate | kind | value | limit | ok |", "| --- | --- | --- | --- | --- |"]
    for check in result["gate"]["checks"]:
        lines.append(
            "| %s | %s | %s | %s | %s |"
            % (
                check["name"],
                check["kind"],
                check.get("value", "-"),
                check.get("limit", "-"),
                "yes" if check["ok"] else "no",
            )
        )
    lines += [
        "",
        "response body fingerprint `%s` on %s — identical bytes on every run of this profile"
        % (result["phases"]["cN"]["body_fingerprint"], result["phases"]["cN"]["distinct_bodies"] == 1 and "one body" or "several bodies"),
        "",
        "deterministic result digest `%s` — identical on every run of this profile, timing excluded"
        % result["machine"]["result_sha256"],
        "",
        "container spec: `%s`, server cpuset `%s`, client cpuset `%s`, memory `%s` MB"
        % (
            result["spec"]["profile"],
            result["spec"]["server_cpuset"],
            result["spec"]["client_cpuset"],
            result["spec"]["memory_mb"],
        ),
    ]
    return "\n".join(lines) + "\n"


def run(args):
    rules = {
        "concurrency": args.concurrency,
        "min_scaling": args.min_scaling,
        "max_p99_ms": args.max_p99_ms,
        "min_rps": args.min_rps,
    }
    request_bytes = build_request(args.host, args.port, args.route, args.agent)
    spec = {
        "profile": args.profile,
        "route": args.route,
        "method": "GET",
        "host": args.host,
        "port": args.port,
        "requests": args.requests,
        "concurrency": args.concurrency,
        "warmup": args.warmup,
        "request_sha256": hashlib.sha256(request_bytes).hexdigest(),
        "server_cpuset": args.server_cpuset,
        "client_cpuset": args.client_cpuset,
        "memory_mb": args.memory_mb,
        "server_binary_sha256": args.server_binary_sha256,
        "rules": rules,
    }

    ready, reason = wait_ready(args.host, args.port, request_bytes, args.ready_timeout)
    if not ready:
        print("api_bench: the server never answered on %s:%d (%s)" % (args.host, args.port, reason), file=sys.stderr)
        return 2

    if args.warmup > 0:
        warmup_samples, warmup_failures, _, _ = run_phase(
            args.host, args.port, request_bytes, args.warmup, min(args.warmup, args.concurrency), args.timeout
        )
        print(
            "api_bench: warmup %d requests, %d samples, %d client errors"
            % (args.warmup, len(warmup_samples), len(warmup_failures)),
            file=sys.stderr,
        )
        if warmup_failures:
            print("api_bench: warmup failed: %s" % warmup_failures[0], file=sys.stderr)
            return 2

    cpu_mibs = calibrate()
    phases = {}
    for name, concurrency in (("c1", 1), ("cN", args.concurrency)):
        samples, failures, elapsed_ns, connections = run_phase(
            args.host, args.port, request_bytes, args.requests, concurrency, args.timeout
        )
        report = aggregate(samples, elapsed_ns, args.requests, connections=connections)
        if failures:
            report["problems"].append("client errors: %s" % "; ".join(sorted(set(failures))))
            report["ok"] = False
        phases[name] = report

    gate = evaluate_gate(phases, rules, args.strict)
    result = {
        "schema": SCHEMA_VERSION,
        "spec": spec,
        "phases": phases,
        "gate": gate,
        "machine": {
            "python": sys.version.split()[0],
            "cpus": os.cpu_count(),
            "cpu_hash_mib_per_s": cpu_mibs,
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
    }
    result["machine"]["result_sha256"] = result_digest(spec, phases, gate)
    return result


def main(argv):
    parser = argparse.ArgumentParser(description="deterministic GET benchmark for the pabrik api")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--route", default="/health")
    parser.add_argument("--agent", default="pabrik-api-bench/1")
    parser.add_argument("--requests", type=int, default=2000)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--warmup", type=int, default=200)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--ready-timeout", type=float, default=120.0)
    parser.add_argument("--min-scaling", type=float, default=1.2)
    parser.add_argument("--max-p99-ms", type=float, default=50.0)
    parser.add_argument("--min-rps", type=float, default=200.0)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--profile", default="dedicated-2cpu")
    parser.add_argument("--server-cpuset", default="")
    parser.add_argument("--client-cpuset", default="")
    parser.add_argument("--memory-mb", type=int, default=0)
    parser.add_argument("--server-binary-sha256", default="")
    parser.add_argument("--json", default="")
    parser.add_argument("--markdown", default="")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()

    result = run(args)
    if isinstance(result, int):
        return result

    print(render_markdown(result))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
            handle.write("\n")
    if args.markdown:
        with open(args.markdown, "w", encoding="utf-8") as handle:
            handle.write(render_markdown(result))

    gate = result["gate"]
    for check in gate["checks"]:
        if not check["ok"]:
            print(
                "api_bench: gate check %s failed: value %s, limit %s (%s)"
                % (check["name"], check.get("value", "-"), check.get("limit", "-"), check["detail"]),
                file=sys.stderr,
            )
    print("api_bench: verdict %s (enforced: %s)" % (gate["verdict"], gate["enforced"]), file=sys.stderr)
    return 1 if gate["enforced"] else 0


def selftest():
    checks = []

    def check(name, fn):
        try:
            fn()
        except AssertionError as exc:
            checks.append((name, False, str(exc)))
        else:
            checks.append((name, True, ""))

    def timestamps_normalize_to_one_body():
        early = normalize_body(b'{"status":"ok","timestamp":1700000000}')
        late = normalize_body(b'{"status":"ok","timestamp":1700000123}')
        assert early == late == EXPECTED_BODY, (early, late)

    def bodies_without_a_timestamp_are_left_alone():
        assert normalize_body(b'{"status":"ok"}') == b'{"status":"ok"}'

    def a_wrong_status_word_still_differs_after_normalization():
        assert normalize_body(b'{"status":"down","timestamp":1}') != EXPECTED_BODY

    def fingerprint_ignores_arrival_order():
        one = fingerprint([b"a", b"b", b"a"])
        two = fingerprint([b"b", b"a"])
        assert one == two, (one, two)

    def fingerprint_changes_when_a_body_changes():
        assert fingerprint([b"a"]) != fingerprint([b"b"])

    def percentile_of_one_sample_is_that_sample():
        assert percentile([7], 0.5) == 7
        assert percentile([7], 0.99) == 7

    def percentile_interpolates_between_neighbours():
        assert percentile([0, 100], 0.5) == 50
        assert percentile([0, 10, 20, 30, 40], 0.25) == 10

    def percentile_clamps_at_both_ends():
        assert percentile([1, 2, 3], 0.0) == 1
        assert percentile([1, 2, 3], 1.0) == 3

    def percentile_of_nothing_is_none():
        assert percentile([], 0.5) is None

    def percentiles_never_decrease_with_q():
        ordered = list(range(1, 1001))
        values = [percentile(ordered, q) for q in (0.5, 0.9, 0.99, 1.0)]
        assert values == sorted(values), values

    def a_plan_splits_exactly_the_requested_total():
        for total, workers in ((2000, 8), (7, 3), (1, 8), (0, 4), (100, 1)):
            counts = plan_requests(total, workers)
            assert sum(counts) == total, (total, workers, counts)
            assert len(counts) == workers, (total, workers, counts)
            assert max(counts) - min(counts) <= 1, (total, workers, counts)

    def a_plan_of_zero_workers_is_rejected():
        try:
            plan_requests(10, 0)
        except ValueError:
            return
        raise AssertionError("plan_requests accepted zero workers")

    def throughput_is_requests_over_wall_clock():
        stats = latency_stats([1_000_000] * 100, 1_000_000_000)
        assert stats["throughput_rps"] == 100.0, stats
        assert stats["samples"] == 100

    def a_complete_response_is_taken_whole():
        raw = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\nhi"
        response, rest = take_response(raw)
        assert response["status"] == 200, response
        assert response["body"] == b"hi", response
        assert rest == b"", rest

    def an_incomplete_response_asks_for_more():
        raw = b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort"
        response, rest = take_response(raw)
        assert response is None, response
        assert rest == raw, rest

    def a_split_head_asks_for_more():
        response, rest = take_response(b"HTTP/1.1 200 OK\r\nContent-Le")
        assert response is None and rest == b"HTTP/1.1 200 OK\r\nContent-Le"

    def pipelined_responses_leave_the_remainder():
        raw = (
            b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\na"
            b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nb"
        )
        first, rest = take_response(raw)
        second, rest2 = take_response(rest)
        assert (first["body"], second["body"], rest2) == (b"a", b"b", b""), (first, second, rest2)

    def a_chunked_body_is_decoded():
        raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n3\r\nefg\r\n0\r\n\r\n"
        response, rest = take_response(raw)
        assert response["body"] == b"abcdefg", response
        assert rest == b"", rest

    def a_bad_status_line_is_rejected():
        try:
            take_response(b"NOT-HTTP\r\n\r\n")
        except ValueError:
            return
        raise AssertionError("take_response accepted a non-HTTP status line")

    def header_names_are_case_insensitive():
        raw = b"HTTP/1.1 204 No Content\r\ncontent-length: 0\r\n\r\n"
        response, _ = take_response(raw)
        assert response["status"] == 204

    def a_clean_phase_reports_no_problems():
        samples = [(1_000_000, 200, EXPECTED_BODY, "application/json")] * 5
        report = aggregate(samples, 5_000_000, 5)
        assert report["problems"] == [], report
        assert report["distinct_bodies"] == 1

    def a_wrong_status_code_is_a_problem():
        samples = [(1_000_000, 200, EXPECTED_BODY, "application/json")] * 4
        samples.append((1_000_000, 503, EXPECTED_BODY, "application/json"))
        report = aggregate(samples, 5_000_000, 5)
        assert not report["ok"], report
        assert any("non-200" in problem for problem in report["problems"]), report

    def two_distinct_bodies_are_a_problem():
        samples = [
            (1_000_000, 200, b'{"status":"ok","timestamp":1}', "application/json"),
            (1_000_000, 200, b'{"status":"ok","timestamp":2,"extra":1}', "application/json"),
        ]
        report = aggregate(samples, 2_000_000, 2)
        assert report["distinct_bodies"] == 2, report
        assert any("distinct response bodies" in problem for problem in report["problems"]), report

    def a_missing_response_is_a_problem():
        samples = [(1_000_000, 200, EXPECTED_BODY, "application/json")] * 3
        report = aggregate(samples, 3_000_000, 4)
        assert not report["ok"], report
        assert any("completed 3 of 4" in problem for problem in report["problems"]), report

    def a_non_json_content_type_is_a_problem():
        samples = [(1_000_000, 200, EXPECTED_BODY, "text/html")] * 2
        report = aggregate(samples, 2_000_000, 2)
        assert any("content-type" in problem for problem in report["problems"]), report

    def an_empty_phase_is_a_problem():
        report = aggregate([], 1_000_000, 1)
        assert not report["ok"], report
        assert any("no responses" in problem for problem in report["problems"]), report

    def a_gate_passes_on_a_healthy_run():
        phases = healthy_phases()
        gate = evaluate_gate(phases, healthy_rules(), strict=True)
        assert gate["verdict"] == "pass", gate
        assert gate["enforced"] is False, gate

    def a_flat_throughput_curve_fails_the_scaling_check():
        phases = healthy_phases()
        phases["cN"]["latency"]["throughput_rps"] = phases["c1"]["latency"]["throughput_rps"]
        gate = evaluate_gate(phases, healthy_rules(), strict=False)
        assert gate["verdict"] == "fail", gate
        assert gate["enforced"] is False, gate
        assert "scaling.throughput" in gate["enforced_by"] or gate["enforced_by"] == [], gate

    def a_strict_run_enforces_a_performance_failure():
        phases = healthy_phases()
        phases["cN"]["latency"]["throughput_rps"] = 1.0
        gate = evaluate_gate(phases, healthy_rules(), strict=True)
        assert gate["enforced"] is True, gate
        assert "scaling.throughput" in gate["enforced_by"], gate

    def a_functional_failure_is_enforced_without_strict():
        phases = healthy_phases()
        phases["c1"]["ok"] = False
        phases["c1"]["problems"] = ["non-200 statuses {'500': 1}"]
        gate = evaluate_gate(phases, healthy_rules(), strict=False)
        assert gate["enforced"] is True, gate
        assert "functional.c1" in gate["enforced_by"], gate

    def a_digest_ignores_timing():
        first = digest_fixture(throughput=100.0, p99=1.0)
        second = digest_fixture(throughput=999.0, p99=99.0)
        assert first == second, (first, second)

    def a_digest_changes_when_a_body_changes():
        baseline = digest_fixture()
        mutated = digest_fixture(body=b'{"status":"down","timestamp":<ts>}')
        assert baseline != mutated, baseline

    def a_digest_changes_when_a_response_is_missing():
        baseline = digest_fixture()
        short = digest_fixture(requests=9, expected=10)
        assert baseline != short, baseline

    def a_slow_p99_fails_the_latency_check():
        phases = healthy_phases()
        phases["c1"]["latency"]["p99_ms"] = 9000.0
        gate = evaluate_gate(phases, healthy_rules(), strict=True)
        assert gate["verdict"] == "fail", gate
        assert "latency.p99_c1" in gate["enforced_by"], gate

    for name, fn in (
        ("timestamps normalize to one body", timestamps_normalize_to_one_body),
        ("bodies without a timestamp are left alone", bodies_without_a_timestamp_are_left_alone),
        ("a wrong status word differs after normalization", a_wrong_status_word_still_differs_after_normalization),
        ("the fingerprint ignores arrival order", fingerprint_ignores_arrival_order),
        ("the fingerprint changes with the body", fingerprint_changes_when_a_body_changes),
        ("one sample is its own percentile", percentile_of_one_sample_is_that_sample),
        ("percentiles interpolate", percentile_interpolates_between_neighbours),
        ("percentiles clamp at both ends", percentile_clamps_at_both_ends),
        ("an empty percentile is none", percentile_of_nothing_is_none),
        ("percentiles never decrease", percentiles_never_decrease_with_q),
        ("a plan splits the exact total", a_plan_splits_exactly_the_requested_total),
        ("a plan rejects zero workers", a_plan_of_zero_workers_is_rejected),
        ("throughput is requests over wall clock", throughput_is_requests_over_wall_clock),
        ("a complete response is taken whole", a_complete_response_is_taken_whole),
        ("an incomplete response asks for more", an_incomplete_response_asks_for_more),
        ("a split head asks for more", a_split_head_asks_for_more),
        ("pipelined responses leave the remainder", pipelined_responses_leave_the_remainder),
        ("a chunked body is decoded", a_chunked_body_is_decoded),
        ("a bad status line is rejected", a_bad_status_line_is_rejected),
        ("header names are case insensitive", header_names_are_case_insensitive),
        ("a clean phase has no problems", a_clean_phase_reports_no_problems),
        ("a wrong status code is a problem", a_wrong_status_code_is_a_problem),
        ("two distinct bodies are a problem", two_distinct_bodies_are_a_problem),
        ("a missing response is a problem", a_missing_response_is_a_problem),
        ("a non-json content type is a problem", a_non_json_content_type_is_a_problem),
        ("an empty phase is a problem", an_empty_phase_is_a_problem),
        ("a healthy run passes the gate", a_gate_passes_on_a_healthy_run),
        ("flat throughput fails scaling", a_flat_throughput_curve_fails_the_scaling_check),
        ("strict enforces a performance failure", a_strict_run_enforces_a_performance_failure),
        ("functional failure is always enforced", a_functional_failure_is_enforced_without_strict),
        ("a digest ignores timing", a_digest_ignores_timing),
        ("a digest changes with the body", a_digest_changes_when_a_body_changes),
        ("a digest notices a missing response", a_digest_changes_when_a_response_is_missing),
        ("a slow p99 fails the latency check", a_slow_p99_fails_the_latency_check),
    ):
        check(name, fn)

    failed = [entry for entry in checks if not entry[1]]
    for name, ok, detail in checks:
        print("%s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else " — " + detail))
    print("api_bench --selftest: %d checks, %d failed" % (len(checks), len(failed)))
    return 1 if failed else 0


def healthy_phases():
    return {
        "c1": {
            "requests": 10,
            "expected_requests": 10,
            "ok": True,
            "problems": [],
            "latency": {"throughput_rps": 100.0, "p99_ms": 12.0},
        },
        "cN": {
            "requests": 10,
            "expected_requests": 10,
            "ok": True,
            "problems": [],
            "latency": {"throughput_rps": 500.0, "p99_ms": 40.0},
        },
    }


def digest_fixture(throughput=500.0, p99=40.0, body=EXPECTED_BODY, requests=10, expected=10):
    spec = {"route": "/health", "requests": expected, "concurrency": 8}
    samples = [(1_000_000, 200, body, "application/json")] * requests
    phases = {
        "c1": aggregate(samples, 1_000_000, expected),
        "cN": aggregate(samples, 1_000_000, expected),
    }
    phases["c1"]["latency"] = {"throughput_rps": 1.0, "p99_ms": p99}
    phases["cN"]["latency"] = {"throughput_rps": throughput, "p99_ms": p99}
    return result_digest(spec, phases, evaluate_gate(phases, healthy_rules(), strict=False))


def healthy_rules():
    return {"concurrency": 8, "min_scaling": 2.0, "max_p99_ms": 50.0, "min_rps": 200.0}


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

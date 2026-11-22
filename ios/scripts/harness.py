#!/usr/bin/env python3
"""The UI tests' hands on the Mac (SPEC.md 16.3, 16.4).

XCUITests run inside the simulator and can't start processes on the Mac. This small HTTP
server, bound to 127.0.0.1, runs exactly two programs for them, each in a temporary home:

  * tools/fake-machine (FAKE_MACHINE_BIN), with FAKE_MACHINE_HOME=<tmp>/<home>
  * the real sealctl CLI (SEALCTL_BIN, optional), with HOME=<tmp>/<home>/home and the
    environment of sealctl's scripts/pair-test.sh: no services, no agent, no SSH agent

and drives the booted simulator with `xcrun simctl openurl` and `xcrun simctl push`.

  POST /job      {"cmd": "machine"|"cli", "home": "m1", "args": [...], "stdin": "...", "env": {...}, "tty": false}
  GET  /job/<id> {"done": bool, "code": int|null, "out": "..."}
  POST /stop/<id>
  POST /openurl  {"url": "..."}
  POST /push     {"payload": {...}}
  POST /reset    stops every job and the CLI's daemons, and deletes the homes
  GET  /health

Requests from a browser (an Origin or Sec-Fetch-* header, a Host other than the loopback
address) and request bodies that are not application/json are refused.

Run: FAKE_MACHINE_BIN=... [SEALCTL_BIN=...] SEALCTL_RELAY=... SIM_UDID=... harness.py [port]
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Short paths: the CLI's daemon keeps unix sockets under HOME (104-byte limit).
ROOT = tempfile.mkdtemp(prefix="sch-", dir="/tmp")
JOBS = {}
LOCK = threading.Lock()
NEXT = [0]


class Job:
    def __init__(self, argv, env, stdin, cwd=None, tty=False):
        self.tty = tty
        self.out = []
        self.code = None
        self.proc = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        if stdin is not None:
            # Answers to prompts ("unseal", "y"), then end of input.
            threading.Thread(target=self._feed, args=(stdin,), daemon=True).start()
        else:
            self.proc.stdin.close()
        threading.Thread(target=self._read, daemon=True).start()

    def _feed(self, text):
        try:
            self.proc.stdin.write(text)
            self.proc.stdin.flush()
            # Under `script`, an early end of input reaches the command as ^D: keep it open.
            if not self.tty:
                self.proc.stdin.close()
        except OSError:
            pass

    def _read(self):
        for line in self.proc.stdout:
            with LOCK:
                self.out.append(line)
        self.code = self.proc.wait()

    def state(self):
        with LOCK:
            return {"done": self.code is not None, "code": self.code, "out": "".join(self.out)}


def home(name):
    safe = "".join(c for c in name if c.isalnum() or c in "-_") or "default"
    path = os.path.join(ROOT, safe)
    os.makedirs(path, exist_ok=True)
    return path


def cli_env(h):
    """The CLI's environment for the home `h`, as in sealctl's scripts/pair-test.sh."""
    env = {k: v for k, v in os.environ.items()
           if k not in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "SEALCTL_SSH_DIR", "SSH_AUTH_SOCK", "CI")}
    env.update(HOME=h, SEALCTL_NO_SERVICE="1", SEALCTL_AGENT="0")
    return env


def stop_jobs():
    """Stops every job, then the daemons the CLI started (they run in their own process group)."""
    for job in list(JOBS.values()):
        if job.code is None:
            job.proc.terminate()
    JOBS.clear()
    cli = os.environ.get("SEALCTL_BIN")
    if not cli or not os.path.isdir(ROOT):
        return
    for entry in os.listdir(ROOT):
        h = os.path.join(ROOT, entry, "home")
        if entry.startswith("cli-") and os.path.isdir(h):
            try:
                subprocess.run([cli, "daemon", "--stop"], env=cli_env(h), cwd=h, stdin=subprocess.DEVNULL,
                               capture_output=True, timeout=30)
            except (OSError, subprocess.SubprocessError):
                pass


def start(spec):
    relay = spec.get("relay") or os.environ["SEALCTL_RELAY"]
    args = [str(a) for a in spec.get("args", [])]
    if spec.get("cmd") == "machine":
        env = dict(os.environ, FAKE_MACHINE_HOME=home(spec.get("home", "m1")), SEALCTL_RELAY=relay)
        argv = [os.environ["FAKE_MACHINE_BIN"]] + args
    elif spec.get("cmd") == "cli" and os.environ.get("SEALCTL_BIN"):
        h = os.path.join(home("cli-" + spec.get("home", "c1")), "home")
        os.makedirs(h, exist_ok=True)
        os.chmod(h, 0o700)
        env = cli_env(h)
        env["SEALCTL_RELAY"] = relay
        env.update({k: str(v) for k, v in spec.get("env", {}).items() if k.startswith("SEALCTL_")})
        argv = [os.environ["SEALCTL_BIN"]] + args
        if spec.get("tty"):
            # Commands that need a person at a terminal (unseal) run under a pseudo-terminal.
            argv = ["/usr/bin/script", "-q", "/dev/null"] + argv
        spec.setdefault("cwd", h)
    else:
        raise ValueError("unknown command")
    with LOCK:
        NEXT[0] += 1
        jid = str(NEXT[0])
    JOBS[jid] = Job(argv, env, spec.get("stdin"), spec.get("cwd"), bool(spec.get("tty")))
    return jid


def simctl(*args):
    udid = os.environ.get("SIM_UDID", "booted")
    r = subprocess.run(["xcrun", "simctl", args[0], udid] + list(args[1:]), capture_output=True, text=True)
    return {"code": r.returncode, "out": r.stdout + r.stderr}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n and self.headers.get_content_type() != "application/json":
            raise ValueError("the body must be application/json")
        return json.loads(self.rfile.read(n) or b"{}")

    def _from_test(self):
        """Only the tests' own calls: no browser (which always sends Origin on a POST, and
        Sec-Fetch-* in current versions), and the loopback Host (not a name rebound to it)."""
        if self.headers.get("Origin") is not None or any(k.lower().startswith("sec-fetch-") for k in self.headers):
            return False
        return (self.headers.get("Host") or "").rsplit(":", 1)[0] in ("127.0.0.1", "localhost")

    def log_message(self, fmt, *args):
        sys.stderr.write("harness: " + (fmt % args) + "\n")

    def do_GET(self):
        if not self._from_test():
            return self._send(403, {"error": "forbidden"})
        if self.path == "/health":
            return self._send(200, {"ok": True, "cli": bool(os.environ.get("SEALCTL_BIN")),
                                    "relay": os.environ.get("SEALCTL_RELAY", "")})
        if self.path.startswith("/job/"):
            job = JOBS.get(self.path[5:])
            return self._send(200, job.state()) if job else self._send(404, {"error": "no job"})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._from_test():
            return self._send(403, {"error": "forbidden"})
        try:
            if self.path == "/job":
                return self._send(200, {"id": start(self._body())})
            if self.path.startswith("/stop/"):
                job = JOBS.get(self.path[6:])
                if job and job.code is None:
                    job.proc.terminate()
                return self._send(200, {"ok": True})
            if self.path == "/openurl":
                return self._send(200, simctl("openurl", self._body()["url"]))
            if self.path == "/push":
                payload = self._body()["payload"]
                with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
                    json.dump(payload, f)
                r = simctl("push", "com.sealctl.app", f.name)
                os.unlink(f.name)
                return self._send(200, r)
            if self.path == "/reset":
                stop_jobs()
                for entry in os.listdir(ROOT):
                    shutil.rmtree(os.path.join(ROOT, entry), ignore_errors=True)
                return self._send(200, {"ok": True})
        except Exception as e:  # noqa: BLE001 - report to the test
            return self._send(500, {"error": str(e)})
        self._send(404, {"error": "not found"})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"harness on 127.0.0.1:{port}, homes in {ROOT}", flush=True)
    # `pkill` (CI) sends SIGTERM: leave through the cleanup below.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        server.serve_forever()
    finally:
        stop_jobs()
        shutil.rmtree(ROOT, ignore_errors=True)

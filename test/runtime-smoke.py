#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Opt-in real-package smoke check; never publishes images or host ports."""

import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import time
import uuid

POSTGRES = "postgres@sha256:33f923b05f64ca54ac4401c01126a6b92afe839a0aa0a52bc5aeb5cc958e5f20"
OWNER_LABEL = "io.netbird.cloudron.smoke"
DOMAIN = "netbird.example.invalid"


class SmokeError(Exception):
    """A deliberately credential-free diagnostic."""


class SmokeCheck:
    def __init__(self, image, timeout):
        self.image = image
        self.deadline = time.monotonic() + timeout
        self.stage = "prerequisites"
        self.owner = uuid.uuid4().hex
        self.prefix = "netbird-smoke-" + self.owner
        self.network = self.prefix + "-net"
        self.database = self.prefix + "-db"
        self.app = self.prefix + "-app"
        self.certificate_helper = self.prefix + "-cert"
        self.volume = self.prefix + "-data"
        self.certificate_volume = self.prefix + "-certs"
        self.resources = []
        self.last_http_status = "unavailable"
        self.owner_email = "owner-" + secrets.token_hex(6) + "@example.invalid"
        self.owner_password = "Smoke-" + self.owner[-24:]
        self.password = secrets.token_hex(24)

    def command(self, *args, check=True, environment=None, deadline=None):
        remaining = (self.deadline if deadline is None else deadline) - time.monotonic()
        if remaining <= 0:
            raise SmokeError("time budget exhausted")
        process = subprocess.Popen(
            ["docker", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=environment,
        )
        try:
            output, error = process.communicate(timeout=min(20, remaining))
        except BaseException:
            process.kill()
            process.communicate()
            raise
        if check and process.returncode:
            # Never print Docker arguments, environment, or raw upstream logs:
            # NetBird logs its generated auth secret and database DSN at startup.
            raise SmokeError("Docker operation failed (raw output withheld)")
        return process.returncode, output, error

    def wait(self, probe, description):
        while self.deadline - time.monotonic() > 3:
            result = probe()
            if result[0] == 0:
                return result[1]
            if ("container", self.app) in self.resources:
                state = self.command("container", "inspect", "--format", "{{.State.Status}}",
                                     self.app, check=False)
                if state[0] == 0 and state[1].strip() not in ("created", "running"):
                    raise SmokeError("application container exited while waiting for " + description)
            time.sleep(min(1, max(0, self.deadline - time.monotonic())))
        suffix = " (last HTTP status: " + self.last_http_status + ")" if "endpoint" in description else ""
        raise SmokeError("deadline waiting for " + description + suffix)

    def create(self, kind, name, *options, environment=None):
        # Register the unique name before creation, including interrupted CLI calls.
        # Cleanup independently verifies the per-run label before touching anything.
        self.resources.append((kind, name))
        if kind == "container":
            args = ["container", "create", "--name", name]
        else:
            args = [kind, "create"]
        args += ["--label", OWNER_LABEL + "=" + self.owner, *options]
        if kind != "container":
            args.append(name)
        self.command(*args, environment=environment)

    def prerequisites(self):
        if shutil.which("docker") is None:
            raise SmokeError("Docker CLI is required; install it before running this check")
        self.command("info", "--format", "{{.ServerVersion}}")
        for image in (self.image, POSTGRES):
            result = self.command("image", "inspect", image, check=False)
            if result[0]:
                raise SmokeError("candidate and pinned PostgreSQL images must already be local; see README")
            if image == self.image:
                self.image = json.loads(result[1])[0]["Id"]
        manifest = json.loads((Path(__file__).resolve().parents[1] / "CloudronManifest.json").read_text())
        self.port = manifest["httpPort"]
        self.native_container_port = manifest["tcpPorts"]["NETBIRD_PORT"]["containerPort"]
        self.native_external_port = 34443
        self.health_path = manifest["healthCheckPath"]
        if not isinstance(self.port, int) or not 1 <= self.port <= 65535:
            raise SmokeError("invalid manifest HTTP port")
        if not isinstance(self.health_path, str) or not self.health_path.startswith("/"):
            raise SmokeError("invalid manifest health path")
        if self.native_container_port != 33074:
            raise SmokeError("invalid manifest native client container port")

    def start(self):
        self.stage = "database startup"
        # Outbound access is needed for NetBird's geolocation bootstrap download.
        self.create("network", self.network)
        self.create("volume", self.volume)
        self.create("volume", self.certificate_volume)
        certificate_command = (
            "openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=" + DOMAIN
            + " -addext subjectAltName=DNS:" + DOMAIN
            + " -keyout /certs/tls_key.pem -out /certs/tls_cert.pem"
            + " && chmod 0644 /certs/tls_cert.pem /certs/tls_key.pem"
        )
        self.create(
            "container", self.certificate_helper,
            "--mount", "type=volume,source=" + self.certificate_volume + ",target=/certs",
            self.image, "bash", "-c", certificate_command,
        )
        self.command("start", "--attach", self.certificate_helper)
        self.create(
            "container", self.database, "--network", self.network,
            "--memory", "512m", "--cpus", "2", "--tmpfs", "/var/lib/postgresql/data",
            "--env", "POSTGRES_USER=netbird", "--env", "POSTGRES_DB=netbird",
            "--env", "POSTGRES_PASSWORD", POSTGRES,
            environment=dict(os.environ, POSTGRES_PASSWORD=self.password),
        )
        self.command("start", self.database)
        self.wait(lambda: self.command("exec", self.database, "pg_isready", "-U", "netbird", check=False),
                  "PostgreSQL")
        self.stage = "fresh application startup"
        self.create(
            "container", self.app, "--platform", "linux/amd64", "--network", self.network,
            "--network-alias", DOMAIN,
            "--read-only", "--tmpfs", "/run", "--tmpfs", "/tmp", "--memory", "512m", "--cpus", "2",
            "--mount", "type=volume,source=" + self.volume + ",target=/app/data",
            "--mount", "type=volume,source=" + self.certificate_volume + ",target=/etc/certs,readonly",
            "--env", "CLOUDRON_APP_DOMAIN=" + DOMAIN,
            "--env", "CLOUDRON_POSTGRESQL_HOST=" + self.database,
            "--env", "CLOUDRON_POSTGRESQL_USERNAME=netbird",
            "--env", "CLOUDRON_POSTGRESQL_PASSWORD",
            "--env", "CLOUDRON_POSTGRESQL_DATABASE=netbird",
            "--env", "CLOUDRON_POSTGRESQL_PORT=5432",
            "--env", "NETBIRD_PORT=" + str(self.native_external_port),
            "--env", "STUN_PORT=5349", self.image,
            environment=dict(os.environ, CLOUDRON_POSTGRESQL_PASSWORD=self.password),
        )
        self.command("start", self.app)
        self.wait(lambda: self.command("exec", self.app, "test", "-s",
                                      "/app/data/config/nginx.conf", check=False),
                  "nginx configuration generation")
        nginx_test = self.command("exec", self.app, "runuser", "-u", "cloudron", "--",
                                  "nginx", "-t", "-c", "/app/data/config/nginx.conf", check=False)
        if nginx_test[0] != 0:
            raise SmokeError("generated nginx configuration is invalid")

    def http(self, path, method="GET", data=None):
        args = [
            "exec", self.app, "curl", "-fsSL", "--max-redirs", "3", "--max-time", "2",
            "--request", method, "--header", "Content-Type: application/json",
            "--write-out", "\n%{http_code}",
        ]
        if data is not None:
            args += ["--data", json.dumps(data)]
        args.append("http://127.0.0.1:" + str(self.port) + path)
        code, output, error = self.command(*args, check=False)
        body, _, status = output.rpartition("\n")
        self.last_http_status = status if status.isdecimal() else "unavailable"
        return (0 if code == 0 and status == "200" else 1), body, error

    def instance_setup_required(self):
        response = self.http("/api/instance")
        if response[0]:
            raise SmokeError("unauthenticated instance status endpoint unavailable")
        return json.loads(response[1]).get("setup_required")

    def complete_setup(self):
        response = self.http("/api/setup", method="POST", data={
            "email": self.owner_email,
            "password": self.owner_password,
            "name": "Smoke Owner",
        })
        if response[0]:
            raise SmokeError("unauthenticated initial owner setup failed")
        result = json.loads(response[1])
        if result.get("email") != self.owner_email or not result.get("user_id"):
            raise SmokeError("initial owner setup response mismatch")

    def dashboard_runtime_config(self):
        placeholders = self.command("exec", self.app, "grep", "-RIl",
                                    "AUTH_SUPPORTED_SCOPES", "/run/dashboard", check=False)
        if placeholders[0] == 0:
            raise SmokeError("dashboard runtime placeholders were not substituted")
        configured = self.command("exec", self.app, "grep", "-RIl",
                                  "https://" + DOMAIN, "/run/dashboard", check=False)
        if configured[0] != 0:
            raise SmokeError("dashboard runtime origin was not injected")

    def stun_listener(self):
        config = self.command("exec", self.app, "grep", "-F", "--", "- 5349",
                              "/app/data/config/config.yaml", check=False)
        if config[0] != 0:
            raise SmokeError("selected STUN port missing from generated config")
        sockets = self.command("exec", self.app, "ss", "-H", "-lun", check=False)
        if sockets[0] != 0 or ":5349" not in sockets[1]:
            raise SmokeError("NetBird is not listening on the selected STUN UDP port")

    def native_tls_listener(self):
        expected = (
            'exposedAddress: "https://' + DOMAIN + ":"
            + str(self.native_external_port) + '"'
        )
        config = self.command("exec", self.app, "grep", "-F", expected,
                              "/app/data/config/config.yaml", check=False)
        if config[0] != 0:
            raise SmokeError("selected native client port missing from generated config")
        sockets = self.command("exec", self.app, "ss", "-H", "-ltn", check=False)
        if sockets[0] != 0 or ":" + str(self.native_container_port) not in sockets[1]:
            raise SmokeError("nginx is not listening on the native client TLS port")
        endpoint = "https://" + DOMAIN + ":" + str(self.native_container_port) + "/api/instance"
        response = self.command(
            "exec", self.app, "curl", "-fsSL", "--http2", "--max-time", "2",
            "--resolve", DOMAIN + ":" + str(self.native_container_port) + ":127.0.0.1",
            "--cacert", "/etc/certs/tls_cert.pem",
            "--write-out", "\n%{http_version}\n%{http_code}", endpoint, check=False,
        )
        if response[0] != 0:
            raise SmokeError("native client TLS endpoint request failed")
        _, protocol, status = response[1].rsplit("\n", 2)
        if protocol != "2" or status != "200":
            raise SmokeError("native client endpoint did not negotiate verified HTTP/2 TLS")

    def native_dashboard_redirects(self):
        base = "https://" + DOMAIN + ":" + str(self.native_container_port)
        resolve = DOMAIN + ":" + str(self.native_container_port) + ":127.0.0.1"
        for path, method, spoofed_host in (
            ("/", "GET", None),
            ("/setup?returnTo=%2Fpeers", "GET", "spoofed.example.invalid"),
            ("/peers", "HEAD", None),
        ):
            response = self.command(
                "exec", self.app, "curl", "-sS", "--http2", "--max-redirs", "0",
                "--max-time", "2", "--resolve", resolve, "--cacert", "/etc/certs/tls_cert.pem",
                "--request", method, "--output", "/dev/null",
                "--write-out", "%{http_version}\\n%{http_code}\\n%{redirect_url}",
                *( ["--header", "Host: " + spoofed_host] if spoofed_host else [] ), base + path,
                check=False,
            )
            if response[0] != 0:
                raise SmokeError("native dashboard navigation request failed")
            protocol, status, redirect = response[1].rsplit("\\n", 2)
            expected = "https://" + DOMAIN + path
            if protocol != "2" or status != "308" or redirect != expected:
                raise SmokeError("native dashboard navigation did not redirect to canonical HTTPS")

        response = self.command(
            "exec", self.app, "curl", "-sS", "--http2", "--max-redirs", "0", "--max-time", "2",
            "--resolve", resolve, "--cacert", "/etc/certs/tls_cert.pem", "--output", "/dev/null",
            "--write-out", "%{http_code}", base + "/oauth2/.well-known/openid-configuration", check=False,
        )
        if response[0] != 0 or response[1] != "200":
            raise SmokeError("native OAuth endpoint was redirected or unavailable")

    def processes(self):
        expected_uid = self.command("exec", self.app, "id", "-u", "cloudron")[1].strip()
        if not expected_uid.isdecimal() or expected_uid == "0":
            raise SmokeError("cloudron must resolve to an unprivileged UID")
        rows = self.command("exec", self.app, "ps", "-eo", "uid,pid,ppid,comm")[1].splitlines()[1:]
        processes = [row.split() for row in rows]
        if not any(row[0] == "0" and row[1] == "1" and row[3] == "supervisord" for row in processes):
            raise SmokeError("Supervisor must be PID 1 and UID 0")
        selected = []
        for command in ("nginx", "netbird-server"):
            matches = [row for row in processes if row[3] == command]
            if not matches or any(row[0] != expected_uid for row in matches):
                raise SmokeError("nginx and NetBird must both run as cloudron")
            selected.extend(tuple(row) for row in matches)
        return sorted(selected)

    def verify(self, phase, setup_required):
        self.stage = phase + " health endpoint"
        self.wait(lambda: self.http(self.health_path), "manifest health endpoint")
        self.stage = phase + " OIDC discovery"
        discovery = self.http("/oauth2/.well-known/openid-configuration")
        if discovery[0] or json.loads(discovery[1]).get("issuer") != "https://" + DOMAIN + "/oauth2":
            raise SmokeError("OIDC discovery issuer mismatch")
        self.stage = phase + " setup state"
        if self.http("/setup")[0]:
            raise SmokeError("setup page unavailable")
        if self.instance_setup_required() is not setup_required:
            raise SmokeError("instance setup state mismatch")
        self.stage = phase + " dashboard configuration"
        self.dashboard_runtime_config()
        self.stage = phase + " STUN listener"
        self.stun_listener()
        self.stage = phase + " native TLS listener"
        self.native_tls_listener()
        self.stage = phase + " native dashboard redirect"
        self.native_dashboard_redirects()
        self.stage = phase + " process stability"
        before = self.processes()
        time.sleep(min(3, max(0, self.deadline - time.monotonic())))
        if self.processes() != before or self.http(self.health_path)[0]:
            raise SmokeError("services restarted or became unhealthy during stability check")
        self.command("exec", self.app, "test", "-s", "/run/supervisord.pid")
        self.command("exec", self.app, "test", "-f", "/app/data/.initialized")
        fingerprint = self.command("exec", self.app, "sha256sum",
                                   "/app/data/config/.encryption_key", "/app/data/config/.auth_secret")[1]
        count = self.command("exec", self.database, "psql", "-U", "netbird", "-d", "netbird", "-Atc",
                             "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")[1]
        if int(count.strip()) < 1:
            raise SmokeError("database has not initialized")
        print("PASS: " + phase + " health/setup/config, stable unprivileged services, PID file and database", flush=True)
        return fingerprint

    def run(self):
        self.prerequisites()
        self.start()
        original = self.verify("fresh", True)
        self.stage = "initial owner setup"
        self.complete_setup()
        if self.instance_setup_required() is not False:
            raise SmokeError("instance still requires setup after owner creation")
        print("PASS: unauthenticated initial owner setup completed", flush=True)
        self.command("exec", self.app, "touch", "/app/data/smoke-persistence-marker")
        self.stage = "restart"
        self.command("restart", "--time", "10", self.app)
        if self.verify("restart", False) != original:
            raise SmokeError("persistent encryption/auth secrets changed across restart")
        self.command("exec", self.app, "test", "-f", "/app/data/smoke-persistence-marker")
        print("PASS: setup state, persistent data and secrets survived restart (values withheld)", flush=True)

    def cleanup(self):
        deadline = time.monotonic() + 60
        failed = False
        for kind, name in reversed(self.resources):
            try:
                code, output, error = self.command(kind, "inspect", name, check=False, deadline=deadline)
                if code and ("No such" in error or "not found" in error):
                    continue
                if code:
                    raise SmokeError("cannot inspect owned resource")
                resource = json.loads(output)[0]
                labels = resource.get("Config", resource).get("Labels", {})
                if labels.get(OWNER_LABEL) != self.owner:
                    raise SmokeError("ownership label mismatch; refusing removal")
                identity = resource["Name"] if kind == "volume" else resource["Id"]
                if kind == "container":
                    self.command("stop", "--time", "5", identity, deadline=deadline)
                self.command(kind, "rm", identity, deadline=deadline)
            except (SmokeError, subprocess.TimeoutExpired, OSError, ValueError, KeyError):
                failed = True
                print("CLEANUP REQUIRED: inspect " + kind + " " + name
                      + " and verify label " + OWNER_LABEL + "=" + self.owner + " before removal", file=sys.stderr)
        return not failed


def interrupted(signum, _frame):
    raise SmokeError("interrupted by signal " + str(signum))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="locally present candidate image (never pulled automatically)")
    parser.add_argument("--timeout", type=int, default=180, help="overall test budget in seconds (default 180, plus up to 60 for cleanup)")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 900:
        parser.error("--timeout must be between 1 and 900 seconds")
    smoke = SmokeCheck(args.image, args.timeout)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    status = 0
    try:
        print("RUN: " + smoke.prefix, flush=True)
        smoke.run()
    except (SmokeError, subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
        message = str(error) if isinstance(error, SmokeError) else "operation failed (details withheld to protect credentials)"
        print("FAIL during " + smoke.stage + ": " + message, file=sys.stderr)
        status = 1
    finally:
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        if not smoke.cleanup():
            status = 1
        else:
            print("PASS: all recorded test resources absent or removed", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())

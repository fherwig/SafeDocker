#!/usr/bin/env python3
"""Tests of app/scripts/agent-check.sh, app/scripts/time-capsule.sh, install-safe.sh,
and the checks of app/scripts/build-app.sh before it compiles (it builds nothing here).

    python3 tools/test_scripts.py        all tests
    python3 tools/test_scripts.py -v     one line per test

time-capsule.sh runs here against a stand-in for docker, so these tests need
neither Docker nor the image and write no large file. install-safe.sh installs
a stand-in Safe.app from a release folder made here into a folder made here
(SAFE_RELEASE_DIR, SAFE_APPS_DIR), never into ~/Applications, and never opens
an app; if app/dist holds the files of make-release.sh, one test installs the
real release the same way. Everything goes into new folders under $TMPDIR,
which are removed at the end.
"""

import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
AGENT_CHECK = os.path.join(REPO, "app", "scripts", "agent-check.sh")
BUILD_APP = os.path.join(REPO, "app", "scripts", "build-app.sh")
# a sandbox that only denies the network, as an agent's command sandbox may
OUTER_SANDBOX = "(version 1)(allow default)(deny network-outbound (remote ip))"
TIME_CAPSULE = os.path.join(REPO, "app", "scripts", "time-capsule.sh")
INSTALL_SAFE = os.path.join(REPO, "install-safe.sh")
DIST = os.path.join(REPO, "app", "dist")
BUNDLE_ID = "io.github.fherwig.safedocker"
with open(os.path.join(HERE, "docker-image.txt")) as _f:
    PINNED = [line.strip() for line in _f if line.strip() and not line.startswith("#")][0]

CHECKS = {
    "macos": "required", "macos_for_build": "build", "architecture": "required", "free_space": "required",
    "hdiutil": "required", "codesign": "required", "ditto": "required", "shasum": "required",
    "curl": "required", "free_space_for_build": "build", "plutil": "build", "xattr": "build",
    "developer_tools": "build", "swift": "build", "macos_sdk": "build", "lipo": "build",
    "git": "build", "filevault": "warn", "encrypted_swap": "warn", "source": "info",
    "installed_app": "info", "other_copy": "info", "app_running": "info", "app_data": "info", "docker": "info",
    "pending_deletes": "info",
}

FAKE_DOCKER = r'''
import io, os, sys, tarfile
args = sys.argv[1:]
with open(os.environ["FAKE_DOCKER_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
mode = os.environ.get("FAKE_DOCKER_MODE", "ok")
if args[:1] == ["info"]:
    sys.exit(1 if mode == "stopped" else 0)
if args[:2] == ["image", "inspect"]:
    if mode == "noimage":
        sys.exit(1)
    if "--format" in args:
        fmt = args[args.index("--format") + 1]
        if "RepoDigests" in fmt:
            print(os.environ.get("FAKE_DOCKER_DIGEST", ""))
        else:
            print({"{{.Id}}": "sha256:" + "ab" * 32, "{{.Os}}/{{.Architecture}}": "linux/arm64",
                   "{{.Created}}": "2026-10-25T04:25:29Z", "{{.Size}}": "4096"}[fmt])
    sys.exit(0)
if args[:1] == ["run"]:
    print("OpenSSL 3.0.22 25 Aug 2026 (fake)")
    print("12.15")
    sys.exit(0)
if args[:1] == ["save"]:
    if mode == "savefail":
        sys.stdout.buffer.write(b"half an archive")
        sys.exit(1)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as tar:
        for name, data in [("manifest.json", b"[]"), ("repositories", b"{}")]:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    sys.stdout.buffer.write(buffer.getvalue())
    sys.exit(0)
sys.stderr.write("fake docker: unexpected command %s\n" % args)
sys.exit(99)
'''


def write_executable(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o755)


def repo_files():
    """The files of the repository outside .git, with their sizes."""
    found = {}
    for top, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            path = os.path.join(top, name)
            found[path] = os.lstat(path).st_size
    return found


class Folder(unittest.TestCase):
    """Gives each test a new folder under $TMPDIR and removes it afterwards."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="safetest-scripts-")
        self.addCleanup(self.remove_tmp)

    def remove_tmp(self):
        if os.path.basename(self.tmp).startswith("safetest-scripts-"):
            shutil.rmtree(self.tmp)

    def bin_folder(self):
        folder = os.path.join(self.tmp, "bin")
        os.makedirs(folder, exist_ok=True)
        return folder


class AgentCheck(Folder):
    def run_check(self, env=None, args=()):
        return subprocess.run(["/bin/bash", AGENT_CHECK] + list(args), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env, timeout=120)

    def report(self, env=None):
        result = self.run_check(env)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stderr, b"")
        return json.loads(result.stdout.decode("utf-8"))

    def check_consistent(self, report):
        self.assertEqual(report["tool"], "agent-check.sh")
        self.assertEqual(report["format"], 1)
        checks = report["checks"]
        self.assertEqual(set(checks), set(CHECKS))
        for name, check in checks.items():
            with self.subTest(name):
                self.assertEqual(check["level"], CHECKS[name])
                self.assertIsInstance(check["ok"], bool)
                self.assertIsInstance(check["value"], str)
                self.assertTrue(check["hint"].strip())
        required = all(c["ok"] for c in checks.values() if c["level"] == "required")
        build = required and all(c["ok"] for c in checks.values() if c["level"] == "build")
        self.assertEqual(report["ready_to_install"], required)
        self.assertEqual(report["ready_to_build"], build)
        self.assertEqual(sorted(report["warnings"]),
                         sorted(n for n, c in checks.items() if c["level"] == "warn" and not c["ok"]))

    def test_report_on_this_mac(self):
        report = self.report()
        self.check_consistent(report)
        # the builders' Mac: macOS 13 or later and the Command Line Tools
        self.assertTrue(report["ready_to_install"], report)
        self.assertTrue(report["checks"]["developer_tools"]["ok"])
        self.assertRegex(report["checks"]["swift"]["value"], r"^\d+\.\d+")
        self.assertIn(os.uname().machine, report["checks"]["architecture"]["value"])
        with open(os.path.join(REPO, "app", "VERSION")) as f:
            self.assertIn(f.read().strip(), report["checks"]["source"]["value"])

    def test_read_only(self):
        # a stand-in for docker, because the real one writes Docker Desktop's own log
        folder = self.bin_folder()
        write_executable(os.path.join(folder, "docker"), "#!/bin/sh\nexit 0\n")
        home = os.path.join(self.tmp, "home")
        os.makedirs(home)
        before = repo_files()
        report = self.report(dict(os.environ, HOME=home, PATH=folder + ":" + os.environ["PATH"]))
        self.check_consistent(report)
        self.assertEqual(os.listdir(home), [])
        self.assertEqual(repo_files(), before)
        self.assertFalse(report["checks"]["installed_app"]["ok"])

    def test_without_developer_tools(self):
        # xcode-select finds nothing; stand-ins for swift, lipo and git note any call,
        # because the real stubs would open the install dialog
        folder = self.bin_folder()
        marker = os.path.join(self.tmp, "called")
        write_executable(os.path.join(folder, "xcode-select"),
                         "#!/bin/sh\necho 'xcode-select: error' >&2\nexit 2\n")
        for tool in ("swift", "lipo", "git", "xcrun"):
            write_executable(os.path.join(folder, tool), "#!/bin/sh\necho %s >> '%s'\n" % (tool, marker))
        report = self.report(dict(os.environ, PATH=folder + ":/usr/bin:/bin:/usr/sbin:/sbin"))
        self.check_consistent(report)
        self.assertFalse(report["checks"]["developer_tools"]["ok"])
        self.assertFalse(report["ready_to_build"])
        for tool in ("swift", "macos_sdk", "lipo", "git"):
            self.assertFalse(report["checks"][tool]["ok"])
        self.assertFalse(os.path.exists(marker), "a developer tool was run")

    def test_minimal_path(self):
        # some agent tools and launchd jobs run with PATH=/usr/bin:/bin, without
        # /usr/sbin, where sysctl is: the swap check must not change
        normal = self.report()
        minimal = self.report({"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin"})
        self.check_consistent(minimal)
        self.assertEqual(minimal["checks"]["encrypted_swap"], normal["checks"]["encrypted_swap"])
        self.assertEqual(minimal["warnings"], normal["warnings"])

    def test_macos_too_old_to_build(self):
        # macOS 14.4 runs Safe.app, but cannot get the Command Line Tools that build it
        folder = self.bin_folder()
        write_executable(os.path.join(folder, "sw_vers"),
                         "#!/bin/sh\ncase $1 in -productVersion) echo 14.4 ;; *) echo 23E214 ;; esac\n")
        report = self.report(dict(os.environ, PATH=folder + ":" + os.environ["PATH"]))
        self.check_consistent(report)
        self.assertTrue(report["checks"]["macos"]["ok"])
        self.assertFalse(report["checks"]["macos_for_build"]["ok"])
        self.assertIn("cannot build", report["checks"]["macos_for_build"]["hint"])
        self.assertFalse(report["ready_to_build"])

    def test_docker_not_running(self):
        folder = self.bin_folder()
        write_executable(os.path.join(folder, "docker"), "#!/bin/sh\nexit 1\n")
        report = self.report(dict(os.environ, PATH=folder + ":" + os.environ["PATH"]))
        self.check_consistent(report)
        docker = report["checks"]["docker"]
        self.assertFalse(docker["ok"])
        self.assertIn("not running", docker["value"])
        self.assertIn("Not needed by Safe.app", docker["hint"])

    def test_without_home(self):
        # env -i and some sandboxes give no HOME: the script finds it, and still
        # prints its one JSON object (finding of review round 3)
        report = self.report({})
        self.check_consistent(report)
        self.assertNotEqual(report["checks"]["free_space"]["value"], "unknown")
        self.assertEqual(report["checks"]["installed_app"]["value"],
                         self.report()["checks"]["installed_app"]["value"])

    def test_home_unknown(self):
        # not even the directory service says: the checks that need it say "unknown"
        folder = self.bin_folder()
        write_executable(os.path.join(folder, "dscl"), "#!/bin/sh\nexit 1\n")
        report = self.report({"PATH": folder + ":/usr/bin:/bin:/usr/sbin:/sbin"})
        self.check_consistent(report)
        self.assertEqual(report["checks"]["free_space"]["value"], "unknown")
        self.assertFalse(report["ready_to_install"])
        self.assertEqual(report["checks"]["installed_app"]["value"], "unknown")

    def test_pending_deletes(self):
        # unencrypted rests of New from Folder are counted, never named; the uninstall
        # must not remove their only record first (finding of review round 4)
        home = os.path.join(self.tmp, "home")
        support = os.path.join(home, "Library", "Application Support", "SafeDocker")
        os.makedirs(support)
        rest = os.path.join(home, ".safetest.safe-pending-12345678")
        os.makedirs(rest)
        with open(os.path.join(support, "pending-deletes.json"), "w") as f:
            json.dump({"version": 1, "pending": [rest, os.path.join(home, "gone")]}, f)
        report = self.report(dict(os.environ, HOME=home))
        self.check_consistent(report)
        pending = report["checks"]["pending_deletes"]
        self.assertTrue(pending["ok"])
        self.assertEqual(pending["value"], "1")
        self.assertNotIn("safe-pending", json.dumps(report))
        self.assertIn("Safe did not finish deleting a folder", pending["hint"])
        empty = self.report(dict(os.environ, HOME=os.path.join(self.tmp, "nobody")))
        self.assertFalse(empty["checks"]["pending_deletes"]["ok"])

    def test_outside_a_checkout(self):
        # INSTALL-AGENT.md section 3 runs the script alone, downloaded; that is fine for the release
        alone = os.path.join(self.tmp, "dl", "agent-check.sh")
        os.makedirs(os.path.dirname(alone))
        shutil.copy(AGENT_CHECK, alone)
        result = subprocess.run(["/bin/bash", alone], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        source = json.loads(result.stdout.decode("utf-8"))["checks"]["source"]
        self.assertFalse(source["ok"])
        self.assertIn("fine for an install from the release", source["hint"])

    def test_usage(self):
        self.assertEqual(self.run_check(args=["--help"]).returncode, 0)
        self.assertEqual(self.run_check(args=["--bogus"]).returncode, 2)


class BuildAppSandboxCheck(unittest.TestCase):
    """build-app.sh --check-sandbox: the note for a shell inside another sandbox.
    It builds nothing: the option is handled before anything else."""

    def run_build_app(self, sandboxed):
        command = ["/bin/bash", BUILD_APP, "--check-sandbox"]
        if sandboxed:
            command = ["/usr/bin/sandbox-exec", "-p", OUTER_SANDBOX] + command
        return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)

    @unittest.skipUnless(os.path.exists("/usr/bin/sandbox-exec"), "no sandbox-exec")
    def test_outside_a_sandbox(self):
        before = repo_files()
        result = self.run_build_app(False)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout.decode().strip(), "not inside a sandbox")
        self.assertEqual(result.stderr, b"")
        self.assertEqual(repo_files(), before)

    @unittest.skipUnless(os.path.exists("/usr/bin/sandbox-exec"), "no sandbox-exec")
    def test_inside_a_sandbox(self):
        # finding of review round 3: under set -o pipefail the old probe never printed its note
        result = self.run_build_app(True)
        if b"sandbox_apply" in result.stderr and result.returncode == 71:
            self.skipTest("this test itself runs inside a sandbox")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout.decode().strip(), "inside a sandbox")
        self.assertIn("this is not a fault of Safe.app", result.stderr.decode())


class BuildAppBeforeCompiling(Folder):
    """What build-app.sh checks before it compiles (findings of review round 4)."""

    def test_without_home(self):
        # env -i and some sandboxes give no HOME, which agent-check.sh handles; so must
        # build-app.sh, instead of stopping with "HOME: unbound variable"
        result = subprocess.run(["/bin/bash", BUILD_APP, "--check-sandbox"], env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertNotIn(b"unbound variable", result.stderr)
        self.assertIn(b"sandbox", result.stdout)

    def test_without_developer_tools(self):
        # /usr/bin/swift and lipo are stubs that open an install dialog: without the
        # developer folder the script says what is missing and runs neither
        folder = self.bin_folder()
        marker = os.path.join(self.tmp, "called")
        write_executable(os.path.join(folder, "xcode-select"),
                         "#!/bin/sh\necho 'xcode-select: error' >&2\nexit 2\n")
        for tool in ("swift", "lipo", "xcrun"):
            write_executable(os.path.join(folder, tool), "#!/bin/sh\necho %s >> '%s'\nexit 1\n" % (tool, marker))
        before = repo_files()
        result = subprocess.run(["/bin/bash", BUILD_APP, "--release"],
                                env=dict(os.environ, PATH=folder + ":/usr/bin:/bin:/usr/sbin:/sbin"),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(result.returncode, 1, result.stderr.decode())
        self.assertIn(b"xcode-select --install", result.stderr)
        self.assertFalse(os.path.exists(marker), "a developer tool was run")
        self.assertEqual(repo_files(), before)


# A stand-in for Safe.app's program: what install-safe.sh runs, logged. Its --check
# names a volume, as the real one names the user's, which must never be printed.
FAKE_SAFE = r"""#!/bin/bash
echo "$*" >> "${FAKE_SAFE_LOG:-/dev/null}"
case ${1:-} in
    --version) echo "@VERSION@" ;;
    --self-test)
        if [ "${FAKE_SAFE_SELF_TEST:-ok}" = fail ]
        then
            printf '{\n  "configuration" : "release",\n  "ok" : false\n}\n'
            exit 1
        fi
        printf '{\n  "configuration" : "release",\n  "ok" : true\n}\n' ;;
    --check)
        printf '{\n  "configuration" : "release",\n  "manifestFound" : true,\n  "networkBlocked" : true,\n'
        printf '  "pendingDeletes" : %s,\n' "${FAKE_SAFE_PENDING:-0}"
        printf '  "volumes" : [{"path" : "/Users/safetest-private/vault.sparsebundle"}]\n}\n' ;;
    *) exit 2 ;;
esac
"""
PRIVATE_PATH = b"safetest-private"


class InstallSafe(Folder):
    """install-safe.sh against a stand-in release, into a folder of the test."""

    def setUp(self):
        super().setUp()
        self.apps = os.path.join(self.tmp, "apps")
        self.home = os.path.join(self.tmp, "home")
        self.release = os.path.join(self.tmp, "release")
        self.log = os.path.join(self.tmp, "safe.log")
        self.calls = os.path.join(self.tmp, "calls.log")
        os.makedirs(os.path.join(self.home, "Library", "Application Support", "SafeDocker"))
        os.makedirs(self.release)
        # stand-ins: Safe is not running, and open and defaults only log
        folder = self.bin_folder()
        write_executable(os.path.join(folder, "pgrep"), "#!/bin/sh\necho \"pgrep $*\" >> '%s'\nexit ${FAKE_RUNNING:-1}\n" % self.calls)
        for tool in ("open", "defaults"):
            write_executable(os.path.join(folder, tool), "#!/bin/sh\necho \"%s $*\" >> '%s'\n" % (tool, self.calls))
        self.make_bundle(os.path.join(self.tmp, "build"), "9.9.9")
        subprocess.run(["ditto", "-c", "-k", "--keepParent", os.path.join(self.tmp, "build", "Safe.app"),
                        os.path.join(self.release, "Safe.zip")], check=True)
        self.write_sums()

    def make_bundle(self, where, version, identifier=BUNDLE_ID):
        import plistlib
        app = os.path.join(where, "Safe.app")
        os.makedirs(os.path.join(app, "Contents", "MacOS"))
        with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "Safe",
                           "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"}, f)
        write_executable(os.path.join(app, "Contents", "MacOS", "Safe"), FAKE_SAFE.replace("@VERSION@", version))
        subprocess.run(["codesign", "--force", "--sign", "-", app], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return app

    def write_sums(self):
        result = subprocess.run(["shasum", "-a", "256", "Safe.zip"], cwd=self.release, check=True,
                                stdout=subprocess.PIPE)
        with open(os.path.join(self.release, "SHA256SUMS"), "wb") as f:
            f.write(result.stdout)

    def run_install(self, *args, **extra):
        env = {"PATH": self.bin_folder() + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": self.home,
               "TMPDIR": self.tmp + "/", "SAFE_RELEASE_DIR": self.release, "SAFE_APPS_DIR": self.apps,
               "FAKE_SAFE_LOG": self.log}
        env.update(extra)
        # a new session without a terminal: a question to the user cannot be answered
        return subprocess.run(["/bin/bash", INSTALL_SAFE] + list(args), env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120, start_new_session=True)

    def read(self, path):
        if not os.path.exists(path):
            return ""
        with open(path) as f:
            return f.read()

    def installed_version(self):
        import plistlib
        with open(os.path.join(self.apps, "Safe.app", "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f)["CFBundleShortVersionString"]

    def assert_no_work_left(self):
        self.assertEqual([n for n in os.listdir(self.tmp) if n.startswith("safe-install.")], [])

    def test_installs_and_checks(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(self.installed_version(), "9.9.9")
        subprocess.run(["codesign", "--verify", "--strict", os.path.join(self.apps, "Safe.app")], check=True)
        out = result.stdout.decode()
        self.assertIn("checksum of Safe.zip is right", out)
        self.assertIn("Installed Safe 9.9.9", out)
        self.assertIn("Safe was not opened", out)
        # the self-test of the unpacked app and of the installed one, then the checks
        calls = self.read(self.log).split()
        self.assertEqual(calls.count("--self-test"), 2, calls)
        self.assertIn("--check", calls)
        self.assertIn("--version", calls)
        self.assertNotIn(PRIVATE_PATH, result.stdout + result.stderr)
        self.assertNotIn("open ", self.read(self.calls))
        self.assert_no_work_left()

    def test_replaces_an_older_version(self):
        self.make_bundle(self.apps, "0.1.0")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(b"Replaced Safe 0.1.0", result.stdout)
        self.assertEqual(self.installed_version(), "9.9.9")
        self.assertEqual(os.listdir(self.apps), ["Safe.app"])
        self.assert_no_work_left()

    def test_refuses_a_checksum_mismatch(self):
        self.make_bundle(self.apps, "0.1.0")
        with open(os.path.join(self.release, "SHA256SUMS"), "w") as f:
            f.write("0" * 64 + "  Safe.zip\n")
        result = self.run_install()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"does not match SHA256SUMS", result.stderr)
        self.assertIn(b"Nothing was installed", result.stderr)
        self.assertEqual(self.installed_version(), "0.1.0")
        self.assertEqual(self.read(self.log), "", "the downloaded app was run")
        self.assert_no_work_left()

    def test_refuses_without_a_checksum(self):
        with open(os.path.join(self.release, "SHA256SUMS"), "w") as f:
            f.write("0" * 64 + "  Safe-9.9.9.zip\n")
        result = self.run_install()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"no checksum for Safe.zip", result.stderr)
        self.assertFalse(os.path.exists(self.apps))

    def test_failed_self_test_keeps_the_old_app(self):
        self.make_bundle(self.apps, "0.1.0")
        result = self.run_install(FAKE_SAFE_SELF_TEST="fail")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"self-test of the new Safe failed", result.stderr)
        self.assertEqual(self.installed_version(), "0.1.0")
        self.assert_no_work_left()

    def test_refuses_to_replace_another_app(self):
        self.make_bundle(self.apps, "5.0", identifier="org.example.other")
        result = self.run_install()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"is another app", result.stderr)
        self.assertEqual(self.installed_version(), "5.0")

    def test_waits_for_safe_to_quit_and_never_kills_it(self):
        self.make_bundle(self.apps, "0.1.0")
        result = self.run_install(FAKE_RUNNING="0")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"quit Safe", result.stdout)
        self.assertIn(b"Safe is running", result.stderr)
        self.assertEqual(self.installed_version(), "0.1.0")
        # only the Safe in the test's folder was looked for, and nothing was killed
        calls = self.read(self.calls)
        self.assertIn("pgrep -f %s/Safe.app/Contents/MacOS/Safe" % self.apps, calls)
        with open(INSTALL_SAFE) as f:
            script = f.read()
        self.assertIsNone(re.search(r"^[^#]*\b(kill|pkill|killall)\b", script, re.M))

    def test_refuses_an_old_macos(self):
        write_executable(os.path.join(self.bin_folder(), "sw_vers"), "#!/bin/sh\necho 12.7.6\n")
        result = self.run_install()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"needs macOS 13.0 or later", result.stderr)
        self.assertFalse(os.path.exists(self.apps))

    def test_never_sudo(self):
        with open(INSTALL_SAFE) as f:
            script = f.read()
        # sudo as a command: at the start of a line, or after ; & | or (
        self.assertIsNone(re.search(r"^\s*sudo\s|[;&|(]\s*sudo\s", script, re.M))

    def test_uninstall_keeps_data(self):
        self.make_bundle(self.apps, "0.1.0")
        secret = os.path.join(self.home, "notes.txt.crypt")
        with open(secret, "w") as f:
            f.write("Salted__")
        result = self.run_install("--uninstall")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(os.path.exists(os.path.join(self.apps, "Safe.app")))
        self.assertTrue(os.path.isdir(os.path.join(self.home, "Library", "Application Support", "SafeDocker")))
        self.assertTrue(os.path.exists(secret))
        self.assertNotIn("defaults", self.read(self.calls))
        self.assertNotIn(PRIVATE_PATH, result.stdout + result.stderr)

    def test_uninstall_remove_data(self):
        self.make_bundle(self.apps, "0.1.0")
        secret = os.path.join(self.home, "notes.txt.crypt")
        with open(secret, "w") as f:
            f.write("Salted__")
        result = self.run_install("--uninstall", "--remove-data")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(os.path.exists(os.path.join(self.apps, "Safe.app")))
        self.assertFalse(os.path.exists(os.path.join(self.home, "Library", "Application Support", "SafeDocker")))
        self.assertTrue(os.path.exists(secret))
        self.assertIn("defaults delete %s" % BUNDLE_ID, self.read(self.calls))

    def test_uninstall_stops_for_pending_deletes(self):
        self.make_bundle(self.apps, "0.1.0")
        result = self.run_install("--uninstall", "--remove-data", FAKE_SAFE_PENDING="2")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"2 folder(s)", result.stdout)
        self.assertTrue(os.path.isdir(os.path.join(self.apps, "Safe.app")))
        self.assertTrue(os.path.isdir(os.path.join(self.home, "Library", "Application Support", "SafeDocker")))

    def test_usage(self):
        result = self.run_install("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"https://raw.githubusercontent.com/fherwig/Safe/main/install-safe.sh", result.stdout)
        result = self.run_install("--bogus")
        self.assertEqual(result.returncode, 2)

    @unittest.skipUnless(os.path.exists(os.path.join(DIST, "SHA256SUMS")) and
                         os.path.exists(os.path.join(DIST, "Safe.zip")), "no release files in app/dist")
    def test_the_real_release(self):
        # the files of make-release.sh, installed into the test's folder; the real
        # Safe runs its self-test and --check, with a volume list of the test's own
        result = self.run_install(SAFE_RELEASE_DIR=DIST, SAFE_VOLUME_LIST=os.path.join(self.tmp, "volumes.json"))
        if b"inside a sandbox" in result.stderr:
            self.skipTest("this test runs inside a sandbox")
        self.assertEqual(result.returncode, 0, result.stderr.decode() + result.stdout.decode())
        with open(os.path.join(REPO, "app", "VERSION")) as f:
            version = f.read().strip()
        self.assertEqual(self.installed_version(), version)
        self.assertIn(("Installed Safe %s" % version).encode(), result.stdout)
        self.assertNotIn("open ", self.read(self.calls))
        self.assert_no_work_left()


class TimeCapsule(Folder):
    def setUp(self):
        super().setUp()
        folder = self.bin_folder()
        write_executable(os.path.join(folder, "docker"), "#!%s\n%s" % (sys.executable, FAKE_DOCKER))
        self.log = os.path.join(self.tmp, "docker.log")
        self.out = os.path.join(self.tmp, "capsule")
        os.makedirs(self.out)

    def run_capsule(self, args, mode="ok", digest=PINNED):
        env = dict(os.environ, PATH=self.bin_folder() + ":" + os.environ["PATH"],
                   FAKE_DOCKER_LOG=self.log, FAKE_DOCKER_MODE=mode, FAKE_DOCKER_DIGEST=digest)
        return subprocess.run(["/bin/bash", TIME_CAPSULE] + list(args), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env, timeout=120)

    def docker_calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def test_usage(self):
        self.assertEqual(self.run_capsule([]).returncode, 2)
        self.assertEqual(self.run_capsule([self.out, self.out]).returncode, 2)
        self.assertEqual(self.run_capsule(["--bogus"]).returncode, 2)
        self.assertEqual(self.run_capsule(["--help"]).returncode, 0)

    def test_refuses_the_repository(self):
        for folder in (REPO, os.path.join(REPO, "tools"), os.path.join(REPO, "app", "scripts")):
            with self.subTest(folder):
                result = self.run_capsule([folder])
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"inside the repository", result.stderr)
        self.assertEqual(self.docker_calls(), [])

    def test_refuses_another_repository(self):
        other = os.path.join(self.tmp, "other")
        os.makedirs(os.path.join(other, ".git"))
        os.makedirs(os.path.join(other, "sub"))
        result = self.run_capsule([os.path.join(other, "sub")])
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"git repository", result.stderr)
        self.assertEqual(os.listdir(os.path.join(other, "sub")), [])

    def test_refuses_a_missing_folder(self):
        result = self.run_capsule([os.path.join(self.tmp, "missing")])
        self.assertEqual(result.returncode, 1)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "missing")))

    def test_refuses_without_docker_running(self):
        result = self.run_capsule([self.out], mode="stopped")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Docker is not running", result.stderr)
        self.assertEqual(os.listdir(self.out), [])

    def test_refuses_without_the_image(self):
        result = self.run_capsule([self.out], mode="noimage")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"never pulls", result.stderr)
        self.assertIn(PINNED.encode(), result.stderr)
        self.assertEqual(os.listdir(self.out), [])
        self.assertFalse(any(c.startswith("pull") for c in self.docker_calls()))

    def test_saves_and_records(self):
        result = self.run_capsule([self.out])
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        names = sorted(os.listdir(self.out))
        self.assertEqual(len(names), 2, names)
        archive, record = names
        self.assertRegex(archive, r"^fherwig-safe-22\.0-\d{8}\.tar\.gz$")
        self.assertEqual(record, archive.replace(".tar.gz", ".txt"))
        listing = subprocess.run(["tar", "-tzf", os.path.join(self.out, archive)],
                                 stdout=subprocess.PIPE, check=True).stdout.decode().split()
        self.assertIn("manifest.json", listing)
        with open(os.path.join(self.out, record)) as f:
            text = f.read()
        self.assertIn(PINNED, text)
        self.assertIn("matches tools/docker-image.txt", text)
        self.assertIn("OpenSSL 3.0.22", text)
        sha = subprocess.run(["shasum", "-a", "256", os.path.join(self.out, archive)],
                             stdout=subprocess.PIPE, check=True).stdout.decode().split()[0]
        self.assertIn("archive SHA-256:  " + sha, text)
        self.assertIn(text.strip(), result.stdout.decode())
        # Docker only as allowed: a throwaway container without network, nothing pulled or removed
        calls = self.docker_calls()
        runs = [c for c in calls if c.startswith("run ")]
        self.assertEqual(len(runs), 1)
        self.assertRegex(runs[0], r"^run --rm --network none --pull never --name safetest-capsule-\d+ fherwig/safe:22\.0 ")
        for call in calls:
            self.assertRegex(call, r"^(info|image inspect|run|save)( |$)")
        # never overwrites
        again = self.run_capsule([self.out])
        self.assertEqual(again.returncode, 1)
        self.assertIn(b"exists already", again.stderr)
        self.assertEqual(sorted(os.listdir(self.out)), names)

    def test_other_digest_is_reported(self):
        result = self.run_capsule([self.out], digest="fherwig/safe@sha256:" + "0" * 64)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(b"DIFFERS from tools/docker-image.txt", result.stdout)

    def test_local_build_has_no_digest(self):
        result = self.run_capsule([self.out], digest="")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(b"never pushed", result.stdout)

    def test_failed_save_leaves_nothing(self):
        result = self.run_capsule([self.out], mode="savefail")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(os.listdir(self.out), [])


class Pinned(unittest.TestCase):
    def test_pinned_digest_line(self):
        self.assertRegex(PINNED, r"^fherwig/safe@sha256:[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Tests of tools/safe-decrypt.py, Python 3 standard library only.

Makes encrypted test files with macOS's /usr/bin/openssl (LibreSSL) and with
the Docker image fherwig/safe:22.0 (OpenSSL 3), in a new folder under $TMPDIR
that is removed at the end, and checks that safe-decrypt.py opens every
variant and refuses wrong passwords. If app/Fixtures holds a manifest.json,
it checks those reference files too.

    python3 tools/test_safe_decrypt.py            all tests
    python3 tools/test_safe_decrypt.py -v         one line per test
    python3 tools/test_safe_decrypt.py --quick    no Docker, short wrong-password runs
    SAFETEST_NO_DOCKER=1 python3 tools/test_safe_decrypt.py    no Docker

Docker runs only the local image, with --rm --network none --pull never and a
container name that starts with safetest. Without Docker or without the image
those tests are skipped with a note.
"""

import hashlib
import importlib.util
import io
import json
import os
import random
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "safe-decrypt.py")
FIXTURES = os.path.join(os.path.dirname(HERE), "app", "Fixtures")
OPENSSL = "/usr/bin/openssl"
IMAGE = "fherwig/safe:22.0"

QUICK = "--quick" in sys.argv
if QUICK:
    sys.argv.remove("--quick")

# import safe-decrypt.py as a module, without leaving a __pycache__ in the repository
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("safe_decrypt", SCRIPT)
sd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sd)

PASSWORDS = [
    "correct horse battery staple",
    "Grüße aus Zürich, 東京 €🔑",
    "x",
    "a \"b\" 'c' \\ $d `e` %f",
    "L" * 200,
]

# what the generators write: (variant, salted, openssl options)
LIBRESSL_SPECS = [
    ("current", True, "-aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt"),
    ("legacyAESSHA256", True, "-aes-256-cbc -md sha256 -salt"),
    ("legacyAESSHA256", True, "-aes-256-cbc"),  # no -md: SHA-256 today
    ("legacyAESSHA256", False, "-aes-256-cbc -md sha256 -nosalt"),
    ("legacyAESMD5", True, "-aes-256-cbc -md md5"),
    ("legacyAESMD5", False, "-aes-256-cbc -md md5 -nosalt"),
    ("legacyRC4MD5", True, "-rc4 -md md5"),
    ("legacyRC4MD5", False, "-rc4 -md md5 -nosalt"),
    ("legacyRC4SHA256", True, "-rc4 -md sha256"),
    ("legacyRC4SHA256", True, "-rc4"),
    ("legacyRC4SHA256", False, "-rc4 -md sha256 -nosalt"),
]
# OpenSSL 3 has no RC4
DOCKER_SPECS = [spec for spec in LIBRESSL_SPECS if "RC4" not in spec[0]]

TMP = None
LIBRESSL_VECTORS = []


def _random_bytes(rnd, n):
    return rnd.getrandbits(8 * n).to_bytes(n, "big") if n else b""


def make_plaintexts():
    rnd = random.Random(20261025)
    lines = ["Line %d of a test file for safe-decrypt.py, marker SAFETEST-%04d." % (i, i)
             for i in range(8)]
    return {
        "text": ("\n".join(lines) + "\n").encode("ascii"),
        "utf8": "Grüße aus Zürich!\n東京の天気は晴れ。\nPrice: 12 €, ✓ done.\n".encode("utf-8"),
        "empty": b"",
        "block32": b"exactly thirty-two bytes of text",
        "png": b"\x89PNG\r\n\x1a\n" + _random_bytes(rnd, 2000),
        "pdf": b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n" + _random_bytes(rnd, 1500),
        # starts with a NUL byte, so neither text nor a known type
        "binary": b"\x00\x01" + _random_bytes(rnd, 3000),
    }


PLAINTEXTS = make_plaintexts()
BIG = "".join("Line %06d of the big test file, Grüße.\n" % i for i in range(27000)).encode("utf-8")


class Vector:
    def __init__(self, generator, variant, salted, options, plain_name, plaintext, password, path):
        self.generator = generator
        self.variant = variant
        self.salted = salted
        self.options = options
        self.plain_name = plain_name
        self.plaintext = plaintext
        self.password = password
        self.path = path

    @property
    def name(self):
        return "%s %s (%s) %s" % (self.generator, self.variant, self.options, self.plain_name)

    def data(self):
        with open(self.path, "rb") as f:
            return f.read()


def vector_plan(specs):
    """Every spec with every plain text, the passwords taken in turn; the current
    format also with every password, and with the 1 MB file unless --quick."""
    plan = []
    n = 0
    for variant, salted, options in specs:
        for plain_name in PLAINTEXTS:
            plan.append((variant, salted, options, plain_name, PASSWORDS[n % len(PASSWORDS)]))
            n += 1
    for i, password in enumerate(PASSWORDS):
        plan.append(("current", True, specs[0][2], "text", password))
    if not QUICK:
        plan.append(("current", True, specs[0][2], "big", PASSWORDS[1]))
        plan.append(("legacyAESMD5", False, "-aes-256-cbc -md md5 -nosalt", "big", PASSWORDS[0]))
    return plan


def plaintext_of(name):
    return BIG if name == "big" else PLAINTEXTS[name]


def write_plaintexts(folder):
    os.makedirs(folder)
    for name in list(PLAINTEXTS) + ["big"]:
        with open(os.path.join(folder, name), "wb") as f:
            f.write(plaintext_of(name))


def make_libressl_vectors():
    plain = os.path.join(TMP, "plain")
    write_plaintexts(plain)
    out = os.path.join(TMP, "libressl")
    os.makedirs(out)
    vectors = []
    for i, (variant, salted, options, plain_name, password) in enumerate(vector_plan(LIBRESSL_SPECS)):
        path = os.path.join(out, "%03d.enc" % i)
        env = dict(os.environ, SAFETEST_PW=password)
        result = subprocess.run(
            [OPENSSL, "enc", "-e"] + options.split()
            + ["-pass", "env:SAFETEST_PW", "-in", os.path.join(plain, plain_name), "-out", path],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode != 0:
            raise RuntimeError("openssl failed for %s: %s" % (options, result.stderr.decode()))
        vectors.append(Vector("LibreSSL", variant, salted, options, plain_name,
                              plaintext_of(plain_name), password, path))
    return vectors


def docker_status():
    """None if Docker can run the image, else why not."""
    if os.environ.get("SAFETEST_NO_DOCKER"):
        return "SAFETEST_NO_DOCKER is set"
    if QUICK:
        return "--quick"
    if not shutil.which("docker"):
        return "Docker is not installed"
    try:
        result = subprocess.run(["docker", "image", "inspect", IMAGE], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=30)
    except subprocess.TimeoutExpired:
        return "Docker does not answer"
    if result.returncode != 0:
        return "Docker is not running, or the image %s is not on this Mac" % IMAGE
    return None


DOCKER_SCRIPT = """set -e
mkdir /tmp/w
cd /tmp/w
tar xf -
mkdir out
while read -r out pw in opts
do
    openssl enc -e $opts -pass file:pw/$pw -in plain/$in -out out/$out
done < jobs
openssl version > out/VERSION
tar cf - out
"""


def make_docker_vectors():
    """One container makes all files: the plain texts and the passwords go in as a
    tar archive on stdin, the encrypted files come back as one on stdout."""
    plan = vector_plan(DOCKER_SPECS)
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        def add(name, data):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o600
            tar.addfile(info, io.BytesIO(data))
        for name in list(PLAINTEXTS) + ["big"]:
            add("plain/" + name, plaintext_of(name))
        for i, password in enumerate(PASSWORDS):
            add("pw/%d" % i, password.encode("utf-8") + b"\n")
        jobs = "".join("%03d.enc %d %s %s\n" % (i, PASSWORDS.index(p), plain_name, options)
                       for i, (_, _, options, plain_name, p) in enumerate(plan))
        add("jobs", jobs.encode("ascii"))
    result = subprocess.run(
        ["docker", "run", "--rm", "--network", "none", "--pull", "never", "-i",
         "--name", "safetest-decrypt-%d" % os.getpid(), IMAGE, "sh", "-c", DOCKER_SCRIPT],
        input=archive.getvalue(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
    if result.returncode != 0:
        raise RuntimeError("the Docker run failed: %s" % result.stderr.decode(errors="replace"))
    out = os.path.join(TMP, "docker")
    os.makedirs(out)
    vectors = []
    with tarfile.open(fileobj=io.BytesIO(result.stdout)) as tar:
        files = {m.name: tar.extractfile(m).read() for m in tar.getmembers() if m.isfile()}
    version = files["out/VERSION"].decode().strip()
    for i, (variant, salted, options, plain_name, password) in enumerate(plan):
        path = os.path.join(out, "%03d.enc" % i)
        with open(path, "wb") as f:
            f.write(files["out/%03d.enc" % i])
        vectors.append(Vector(version.split(" (")[0], variant, salted, options, plain_name,
                              plaintext_of(plain_name), password, path))
    return vectors


def setUpModule():
    global TMP, LIBRESSL_VECTORS
    TMP = tempfile.mkdtemp(prefix="safetest-decrypt-")
    LIBRESSL_VECTORS = make_libressl_vectors()


def tearDownModule():
    if TMP and os.path.basename(TMP).startswith("safetest-decrypt-"):
        shutil.rmtree(TMP)


def run_cli(args, stdin=b""):
    """Runs safe-decrypt.py in a new session, so that it cannot ask on the terminal."""
    return subprocess.run([sys.executable, "-I", SCRIPT] + args, input=stdin,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300,
                          start_new_session=True)


def pw(text):
    return text.encode("utf-8")


class VectorChecks:
    """The checks over a list of vectors, for LibreSSL and Docker."""

    def vectors(self):
        raise NotImplementedError

    def test_every_vector_decrypts_with_its_variant(self):
        for v in self.vectors():
            with self.subTest(v.name):
                self.assertEqual(sd.decrypt(v.data(), pw(v.password), v.variant), v.plaintext)

    def test_every_vector_is_found_without_variant(self):
        for v in self.vectors():
            if v.plain_name == "binary" or (v.plain_name == "empty" and "RC4" in v.variant):
                continue
            with self.subTest(v.name):
                variant, plaintext, description = sd.decrypt_auto(v.data(), pw(v.password))
                self.assertEqual(variant, v.variant)
                self.assertEqual(plaintext, v.plaintext)
                self.assertIsNotNone(description)

    def test_salt_header_as_expected(self):
        for v in self.vectors():
            with self.subTest(v.name):
                self.assertEqual(sd.is_salted(v.data()), v.salted)

    def test_binary_needs_force(self):
        for v in self.vectors():
            if v.plain_name != "binary" or v.variant != "current":
                continue
            with self.subTest(v.name):
                with self.assertRaises(sd.DecryptError) as caught:
                    sd.decrypt_auto(v.data(), pw(v.password))
                if "several variants" in str(caught.exception):
                    # a legacy key gave a correct padding as well, 3 in 256 times
                    self.assertIn("current", str(caught.exception))
                    continue
                self.assertIn("--force", str(caught.exception))
                variant, plaintext, description = sd.decrypt_auto(v.data(), pw(v.password), force=True)
                self.assertEqual((variant, plaintext, description), ("current", v.plaintext, None))

    def test_several_paddings_need_the_variant(self):
        data = [v for v in self.vectors() if v.plain_name == "binary" and v.variant == "current"][0]
        original = sd.decrypt
        def fits_always(data, password, variant, prefix=None):
            if variant.startswith("legacyAES"):
                return b"\x00 garbage"
            return original(data, password, variant, prefix)
        sd.decrypt = fits_always
        try:
            with self.assertRaises(sd.DecryptError) as caught:
                sd.decrypt_auto(data.data(), pw(data.password), force=True)
        finally:
            sd.decrypt = original
        self.assertIn("several variants (current, legacyAESSHA256, legacyAESMD5)", str(caught.exception))


class LibreSSLVectors(VectorChecks, unittest.TestCase):
    def vectors(self):
        return LIBRESSL_VECTORS

    def test_empty_rc4_files_need_the_variant(self):
        # RC4 of nothing is nothing: any password "opens" it, so only --variant does
        for v in LIBRESSL_VECTORS:
            if v.plain_name == "empty" and "RC4" in v.variant:
                with self.subTest(v.name):
                    self.assertEqual(len(v.data()), 16 if v.salted else 0)
                    with self.assertRaises(sd.DecryptError):
                        sd.decrypt_auto(v.data(), pw(v.password))
                    self.assertEqual(sd.decrypt(v.data(), b"any", v.variant), b"")

    def test_all_variants_present(self):
        self.assertEqual({v.variant for v in LIBRESSL_VECTORS}, set(sd.VARIANTS))


class DockerVectors(VectorChecks, unittest.TestCase):
    vectors_made = None

    @classmethod
    def setUpClass(cls):
        why_not = docker_status()
        if why_not:
            raise unittest.SkipTest("Docker vectors skipped: " + why_not)
        cls.vectors_made = make_docker_vectors()

    def vectors(self):
        return self.vectors_made

    def test_made_by_openssl_3(self):
        self.assertTrue(self.vectors_made[0].generator.startswith("OpenSSL 3"),
                        self.vectors_made[0].generator)
        self.assertEqual({v.variant for v in self.vectors_made},
                         {"current", "legacyAESSHA256", "legacyAESMD5"})


class KnownAnswers(unittest.TestCase):
    def test_self_test_option(self):
        result = run_cli(["--self-test"])
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(b"self-test passed", result.stdout)

    def test_self_test_function(self):
        self.assertEqual(sd.self_test(), [])

    def test_aes_fips_197(self):
        plain = sd.aes256_cbc_decrypt(bytes(range(32)), bytes(16),
                                      bytes.fromhex("8ea2b7ca516745bfeafc49904b496089"))
        self.assertEqual(plain.hex(), "00112233445566778899aabbccddeeff")

    def test_aes_against_openssl_with_given_key(self):
        rnd = random.Random(7)
        key, iv = _random_bytes(rnd, 32), _random_bytes(rnd, 16)
        plain = _random_bytes(rnd, 16 * 50)
        result = subprocess.run([OPENSSL, "enc", "-e", "-aes-256-cbc", "-nopad", "-K", key.hex(),
                                 "-iv", iv.hex()], input=plain, stdout=subprocess.PIPE, check=True)
        self.assertEqual(sd.aes256_cbc_decrypt(key, iv, result.stdout), plain)

    def test_rc4_against_openssl_with_given_key(self):
        key, plain = bytes(range(1, 17)), b"RC4 known answer, " * 20
        result = subprocess.run([OPENSSL, "enc", "-e", "-rc4", "-K", key.hex()], input=plain,
                                stdout=subprocess.PIPE, check=True)
        self.assertEqual(sd.rc4(key, result.stdout), plain)

    def test_plain_pbkdf2_matches_hashlib(self):
        for password, salt, n in [(b"pw", b"saltsalt", 1), (pw(PASSWORDS[1]), b"\x00" * 8, 2000)]:
            self.assertEqual(sd.pbkdf2_sha512(password, salt, n, 48, use_hashlib=False),
                             hashlib.pbkdf2_hmac("sha512", password, salt, n, 48))

    def openssl_key_iv(self, options):
        result = subprocess.run([OPENSSL, "enc"] + options.split() + ["-pass", "env:SAFETEST_PW", "-P"],
                                env=dict(os.environ, SAFETEST_PW=PASSWORDS[1]),
                                stdout=subprocess.PIPE, check=True)
        values = {}
        for line in result.stdout.decode().splitlines():
            name, _, value = line.partition("=")
            values[name.strip()] = bytes.fromhex(value.strip())
        return values.get("key"), values.get("iv")

    def test_key_derivation_matches_openssl(self):
        salt = bytes.fromhex("0102030405060708")
        password = pw(PASSWORDS[1])
        cases = [
            ("-aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -S 0102030405060708",
             sd.pbkdf2_sha512(password, salt, 100000, 48), 32),
            ("-aes-256-cbc -md md5 -S 0102030405060708",
             sd.evp_bytes_to_key("md5", password, salt, 48), 32),
            ("-aes-256-cbc -md sha256 -nosalt", sd.evp_bytes_to_key("sha256", password, None, 48), 32),
            ("-aes-256-cbc -S 0102030405060708", sd.evp_bytes_to_key("sha256", password, salt, 48), 32),
            ("-rc4 -md md5 -nosalt", sd.evp_bytes_to_key("md5", password, None, 16), 16),
            ("-rc4 -md sha256 -S 0102030405060708", sd.evp_bytes_to_key("sha256", password, salt, 16), 16),
        ]
        for options, derived, key_length in cases:
            with self.subTest(options):
                key, iv = self.openssl_key_iv(options)
                self.assertEqual(key, derived[:key_length])
                if key_length == 32:
                    self.assertEqual(iv, derived[32:48])


class WrongPasswords(unittest.TestCase):
    def wrong_passwords(self, n, seed):
        rnd = random.Random(seed)
        alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 äöü€"
        return ["".join(rnd.choice(alphabet) for _ in range(rnd.randint(1, 20))) for _ in range(n)]

    def find(self, variant, salted, plain_name):
        for v in LIBRESSL_VECTORS:
            if (v.variant, v.salted, v.plain_name) == (variant, salted, plain_name):
                return v
        self.fail("no vector %s %s %s" % (variant, salted, plain_name))

    def check_none_accepted(self, v, n, seed):
        data = v.data()
        accepted = []
        for password in self.wrong_passwords(n, seed):
            if password == v.password:
                continue
            try:
                accepted.append((password, sd.decrypt_auto(data, pw(password))[0]))
            except sd.DecryptError:
                pass
        self.assertEqual(accepted, [], v.name)

    def test_current_format(self):
        self.check_none_accepted(self.find("current", True, "text"), 20 if QUICK else 200, 1)

    def test_current_format_short_text(self):
        self.check_none_accepted(self.find("current", True, "block32"), 10 if QUICK else 100, 2)

    def test_legacy_aes_without_salt(self):
        self.check_none_accepted(self.find("legacyAESMD5", False, "text"), 50 if QUICK else 1000, 3)

    def test_legacy_rc4(self):
        self.check_none_accepted(self.find("legacyRC4MD5", False, "utf8"), 50 if QUICK else 1000, 4)

    def test_explicit_variant_never_gives_the_text(self):
        v = self.find("legacyAESSHA256", False, "text")
        data = v.data()
        refused = 0
        passwords = self.wrong_passwords(500, 5)
        for password in passwords:
            try:
                self.assertNotEqual(sd.decrypt(data, pw(password), v.variant), v.plaintext)
            except sd.DecryptError:
                refused += 1
        # about 1 in 256 gets past the padding
        self.assertGreater(refused, len(passwords) * 0.95)


def openssl_encrypt(plain, password, options):
    """`plain` encrypted by /usr/bin/openssl with these options."""
    result = subprocess.run([OPENSSL, "enc", "-e"] + options.split() + ["-pass", "env:SAFETEST_PW"],
                            input=plain, env=dict(os.environ, SAFETEST_PW=password),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return result.stdout


class ShortRC4(unittest.TestCase):
    """Findings of review round 3: a wrong password "decrypted" a short RC4 file."""

    def test_short_rc4_needs_the_variant(self):
        rnd = random.Random(7)
        alphabet = "abcdefghijklmnopqrstuvwxyz0123456789 äöü"
        for options in ("-rc4 -md md5 -nosalt", "-rc4 -md md5", "-rc4 -md sha256"):
            with self.subTest(options):
                data = openssl_encrypt(b"4711", "safetest-pin", options)
                with self.assertRaises(sd.DecryptError) as caught:
                    sd.decrypt_auto(data, pw("safetest-pin"))
                self.assertIn("--variant", str(caught.exception))
                variant = "legacyRC4MD5" if "md5" in options else "legacyRC4SHA256"
                self.assertEqual(sd.decrypt(data, pw("safetest-pin"), variant), b"4711")
                accepted = []
                for _ in range(2000):
                    wrong = "".join(rnd.choice(alphabet) for _ in range(rnd.randint(1, 16)))
                    for force in (False, True):
                        try:
                            accepted.append((wrong, sd.decrypt_auto(data, pw(wrong), force=force)))
                        except sd.DecryptError:
                            pass
                self.assertEqual(accepted, [])


class OtherEncodings(unittest.TestCase):
    """Text in ISO Latin-1, MacRoman or UTF-16 opens with --force, as Safe.app opens
    it after the user's yes (finding of review round 3)."""

    LATIN1 = "Grüße aus Köln, und bis bald im Frühjahr! Liebe Grüße\n".encode("latin-1")
    UTF16 = b"\xff\xfe" + "Name;Wert\r\nÄpfel;3\r\nBirnen;5\r\n".encode("utf-16-le")

    def test_other_encodings_need_force(self):
        for plain in (self.LATIN1, self.UTF16):
            for options, variant in (("-rc4 -md md5", "legacyRC4MD5"), ("-rc4 -md md5 -nosalt", "legacyRC4MD5"),
                                     ("-aes-256-cbc -md md5", "legacyAESMD5"),
                                     ("-aes-256-cbc -md sha512 -pbkdf2 -iter 100000", "current")):
                with self.subTest(plain=plain[:6], options=options):
                    data = openssl_encrypt(plain, "safetest-enc", options)
                    with self.assertRaises(sd.DecryptError) as caught:
                        sd.decrypt_auto(data, pw("safetest-enc"))
                    self.assertIn("--force", str(caught.exception))
                    self.assertEqual(sd.decrypt_auto(data, pw("safetest-enc"), force=True),
                                     (variant, plain, sd.OTHER_TEXT))

    def test_random_bytes_are_not_text(self):
        rnd = random.Random(11)
        passed = sum(sd.is_other_text(_random_bytes(rnd, 48)) for _ in range(20000))
        self.assertEqual(passed, 0)


class CutShort(unittest.TestCase):
    """A file cut at a block boundary: the end is missing (finding of review round 3)."""

    def setUp(self):
        self.plain = "".join("Zeile %04d, Grüße aus Köln.\n" % i for i in range(400)).encode("utf-8")
        self.data = openssl_encrypt(self.plain, "safetest-cut", "-aes-256-cbc -md sha512 -pbkdf2 -iter 100000")

    def test_cut_at_a_block_boundary(self):
        for cut in (4096, 8192):
            with self.subTest(cut=cut):
                damaged = self.data[:cut]
                with self.assertRaises(sd.DecryptError) as caught:
                    sd.decrypt_auto(damaged, pw("safetest-cut"))
                self.assertIn("end of the file is missing", str(caught.exception))
                self.assertIn("--salvage", str(caught.exception))
                self.assertEqual(sd.salvage(damaged, pw("safetest-cut")), self.plain[:cut - 32])
                with self.assertRaises(sd.DecryptError):
                    sd.salvage(damaged, pw("safetest-wrong"))
        # a wrong password is not told that the file is damaged
        for wrong in ("safetest-wrong", "x", "Safetest-cut"):
            with self.assertRaises(sd.DecryptError) as caught:
                sd.decrypt_auto(self.data[:4096], pw(wrong))
            self.assertNotIn("missing", str(caught.exception))

    def test_cut_inside_a_block(self):
        # finding of review round 4: a cut inside a block was only "cut short, or RC4",
        # and --salvage refused it
        for length in (300, 4096 - 7, 5000):
            with self.subTest(length=length):
                damaged = self.data[:length]
                with self.assertRaises(sd.DecryptError) as caught:
                    sd.decrypt_auto(damaged, pw("safetest-cut"))
                self.assertIn("end of the file is missing", str(caught.exception))
                whole = (length - 16) // 16 * 16
                self.assertEqual(sd.salvage(damaged, pw("safetest-cut")), self.plain[:whole - 16])
                with self.assertRaises(sd.DecryptError):
                    sd.salvage(damaged, pw("safetest-wrong"))
        # a start that is no known type: the old message, and --salvage --force
        binary = bytes((i * 13 + 5) & 0xFF for i in range(6000))
        data = openssl_encrypt(binary, "safetest-cut", "-aes-256-cbc -md sha512 -pbkdf2 -iter 100000")
        with self.assertRaises(sd.DecryptError) as caught:
            sd.decrypt_auto(data[:4096 - 7], pw("safetest-cut"))
        self.assertIn("cut short (damaged), or it is an old RC4 file", str(caught.exception))
        self.assertIn("--salvage --force", str(caught.exception))
        with self.assertRaises(sd.DecryptError) as caught:
            sd.salvage(data[:4096], pw("safetest-cut"))
        self.assertIn("--force", str(caught.exception))
        self.assertEqual(sd.salvage(data[:4096], pw("safetest-cut"), force=True), binary[:4096 - 32])
        self.assertEqual(sd.salvage(data[:4096 - 7], pw("safetest-cut"), force=True), binary[:4096 - 48])

    def test_salvage_on_the_command_line(self):
        path = os.path.join(TMP, "cut-notes.txt.crypt")
        with open(path, "wb") as f:
            f.write(self.data[:4096])
        out = os.path.join(TMP, "cut-notes.txt")
        result = run_cli(["--stdin", "-o", out, path], b"safetest-cut\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"--salvage", result.stderr)
        self.assertFalse(os.path.exists(out))
        result = run_cli(["--stdin", "--salvage", "-o", out, path], b"safetest-cut\n")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        with open(out, "rb") as f:
            self.assertEqual(f.read(), self.plain[:4096 - 32])
        self.assertIn(b"incomplete", result.stderr)
        result = run_cli(["--stdin", "--salvage", "-o", out + "-2", path], b"safetest-wrong\n")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(os.path.exists(out + "-2"))


class LikeSafeApp(unittest.TestCase):
    """describe() follows Safe.app's Plausibility (finding of review round 4)."""

    def test_text_with_control_characters(self):
        log = "\x1b[31mred\x1b[0m line one\n\x1b[32mgreen\x1b[0m line two\n".encode("utf-8")
        self.assertEqual(sd.describe(log), "text")
        data = openssl_encrypt(log, "safetest-log", "-aes-256-cbc -md sha512 -pbkdf2 -iter 100000")
        self.assertEqual(sd.decrypt_auto(data, pw("safetest-log")), ("current", log, "text"))
        # short ones: no control characters but tab, line feed, form feed, carriage return
        self.assertIsNone(sd.describe(bytes([0x37, 0x7D, 0x1F, 0x46, 0x53, 0x52, 0x02])))
        self.assertEqual(sd.describe(b"tab\tand CR\r\n\x0c"), "text")
        self.assertIsNone(sd.describe(b"NUL\x00 inside a text that is long enough\n"))

    def test_more_file_types(self):
        samples = {
            b"\x1f\x8b\x08\x00" + bytes(20): "a gzip archive",
            b"BZh9" + bytes(20): "a bzip2 archive",
            b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + bytes(20): "an older Office document",
            b"\xfd7zXZ\x00" + bytes(20): "an xz archive",
            b"7z\xbc\xaf\x27\x1c" + bytes(20): "a 7-Zip archive",
            b"Rar!\x1a\x07\x00" + bytes(20): "a RAR archive",
            b"{\\rtf1\\ansi" + bytes(20): "an RTF document",
            b"SQLite format 3\x00" + bytes(20): "an SQLite database",
            b"RIFF\x10\x00\x00\x00WEBPVP8 " + bytes(20): "a WebP image",
            b"BM\x10\x00\x00\x00\x00\x00\x00\x00" + bytes(20): "a BMP image",
            b" " * 1000 + b"%PDF-1.7": "a PDF document",
            bytes(257) + b"ustar\x0000": "a tar archive",
        }
        for data, name in samples.items():
            with self.subTest(name):
                self.assertEqual(sd.describe(data), name)

    def test_padding_fits_names_rc4(self):
        binary = bytes((i * 37 + 11) & 0xFF for i in range(998))
        data = openssl_encrypt(binary, "safetest-bin", "-aes-256-cbc -md sha512 -pbkdf2 -iter 100000")
        with self.assertRaises(sd.DecryptError) as caught:
            sd.decrypt_auto(data, pw("safetest-bin"))
        if "several variants" not in str(caught.exception):
            self.assertIn("--variant legacyRC4MD5", str(caught.exception))
            self.assertIn("control characters", str(caught.exception))


class Padding(unittest.TestCase):
    def test_strip_padding(self):
        block = b"0123456789abcdef"
        self.assertEqual(sd.strip_padding(block[:15] + b"\x01"), block[:15])
        self.assertEqual(sd.strip_padding(block[:12] + b"\x04" * 4), block[:12])
        self.assertEqual(sd.strip_padding(b"\x10" * 16), b"")
        self.assertEqual(sd.strip_padding(block + b"\x10" * 16), block)
        for bad in [block[:15] + b"\x00", block[:15] + b"\x11", block[:13] + b"\x02\x03\x03",
                    block[:12] + b"\x04\x04\x05\x04", block[:15] + b"\xff", b"", block[:15],
                    block + b"\x01"]:
            with self.subTest(bad=bad):
                with self.assertRaises(sd.DecryptError):
                    sd.strip_padding(bad)

    def encrypt_without_padding(self, plain, options):
        result = subprocess.run([OPENSSL, "enc", "-e", "-nopad"] + options.split()
                                + ["-pass", "env:SAFETEST_PW"], input=plain,
                                env=dict(os.environ, SAFETEST_PW="padding"),
                                stdout=subprocess.PIPE, check=True)
        return result.stdout

    def test_bad_padding_in_a_file_is_refused(self):
        body = b"sixteen bytes..." + b"twelve bytes"
        for options, variant in [("-aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt", "current"),
                                 ("-aes-256-cbc -md md5 -nosalt", "legacyAESMD5")]:
            for ending in [b"\x00\x00\x00\x00", b"\x03\x03\x02\x03", b"\x11\x11\x11\x11",
                           b"\x05\x05\x05\x05"]:
                with self.subTest(options=options, ending=ending):
                    data = self.encrypt_without_padding(body + ending, options)
                    with self.assertRaises(sd.DecryptError):
                        sd.decrypt(data, b"padding", variant)
            good = self.encrypt_without_padding(body + b"\x04" * 4, options)
            self.assertEqual(sd.decrypt(good, b"padding", variant), body)


class Damaged(unittest.TestCase):
    def test_damaged_files(self):
        v = [v for v in LIBRESSL_VECTORS if v.variant == "current" and v.plain_name == "text"][0]
        data = v.data()
        for name, damaged in [("empty", b""), ("header only", data[:8]), ("salt cut", data[:12]),
                              ("salt only", data[:16]), ("last byte missing", data[:-1])]:
            with self.subTest(name):
                with self.assertRaises(sd.DecryptError):
                    sd.decrypt(damaged, pw(v.password), "current")
                with self.assertRaises(sd.DecryptError):
                    sd.decrypt_auto(damaged, pw(v.password))

    def test_missing_block(self):
        # CBC: without the first block the padding still fits, but the start is garbage
        v = [v for v in LIBRESSL_VECTORS if v.variant == "current" and v.plain_name == "text"][0]
        data = v.data()
        damaged = data[:16] + data[32:]
        self.assertNotEqual(sd.decrypt(damaged, pw(v.password), "current"), v.plaintext)
        with self.assertRaises(sd.DecryptError):
            sd.decrypt_auto(damaged, pw(v.password))

    def test_flipped_byte_in_last_block(self):
        v = [v for v in LIBRESSL_VECTORS if v.variant == "current" and v.plain_name == "text"][0]
        data = bytearray(v.data())
        data[-20] ^= 0x01
        try:
            plain = sd.decrypt(bytes(data), pw(v.password), "current")
        except sd.DecryptError:
            return
        self.assertNotEqual(plain, v.plaintext)


class CommandLine(unittest.TestCase):
    def vector(self, variant="current", plain_name="text", salted=True):
        for v in LIBRESSL_VECTORS:
            if (v.variant, v.plain_name, v.salted) == (variant, plain_name, salted):
                return v
        self.fail("no vector")

    def out_path(self, name):
        return os.path.join(TMP, "cli-" + name)

    def test_output_file(self):
        v = self.vector(plain_name="utf8")
        out = self.out_path("utf8.txt")
        result = run_cli(["--stdin", "-o", out, v.path], pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        with open(out, "rb") as f:
            self.assertEqual(f.read(), v.plaintext)
        self.assertEqual(stat.S_IMODE(os.stat(out).st_mode), 0o600)
        self.assertIn(b"NOT encrypted", result.stderr)
        self.assertEqual(result.stdout, b"")

    def test_never_overwrites(self):
        v = self.vector()
        out = self.out_path("exists.txt")
        with open(out, "wb") as f:
            f.write(b"keep me")
        result = run_cli(["--stdin", "-o", out, v.path], pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 2)
        with open(out, "rb") as f:
            self.assertEqual(f.read(), b"keep me")

    def test_standard_output(self):
        v = self.vector()
        result = run_cli(["--stdin", v.path], pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, v.plaintext)
        self.assertIn(b"warning", result.stderr)
        self.assertIn(b"NOT encrypted", result.stderr)

    def test_password_is_the_first_line(self):
        v = self.vector()
        result = run_cli(["--stdin", v.path], pw(v.password) + b"\nsecond line\n")
        self.assertEqual(result.stdout, v.plaintext)
        result = run_cli(["--stdin", v.path], pw(v.password))
        self.assertEqual(result.stdout, v.plaintext, "a password without a line feed")
        result = run_cli(["--stdin", v.path], pw(v.password) + b" \n")
        self.assertEqual(result.returncode, 1, "a trailing space belongs to the password")

    def test_password_prompt_on_a_terminal(self):
        # a pseudo terminal, as if the password were typed: it must not be echoed
        import pty
        import select
        v = [v for v in LIBRESSL_VECTORS if v.password == PASSWORDS[1] and v.variant == "current"][0]
        out = self.out_path("prompt.txt")
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.execv(sys.executable, [sys.executable, "-I", SCRIPT, "-o", out, v.path])
            finally:
                os._exit(127)
        output, sent = b"", False
        while True:
            ready, _, _ = select.select([fd], [], [], 60)
            if not ready:
                os.kill(pid, 9)
                break
            try:
                chunk = os.read(fd, 1024)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if not sent and b"Password:" in output:
                os.write(fd, pw(v.password) + b"\n")
                sent = True
        _, status = os.waitpid(pid, 0)
        os.close(fd)
        self.assertTrue(sent, output)
        self.assertEqual(os.WEXITSTATUS(status), 0, output)
        self.assertNotIn(pw(v.password), output)
        with open(out, "rb") as f:
            self.assertEqual(f.read(), v.plaintext)

    def test_non_ascii_password(self):
        v = [v for v in LIBRESSL_VECTORS if v.password == PASSWORDS[1] and v.variant == "current"][0]
        result = run_cli(["--stdin", v.path], pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, v.plaintext)

    def test_wrong_password(self):
        v = self.vector()
        out = self.out_path("wrong.txt")
        result = run_cli(["--stdin", "-o", out, v.path], b"not the password\n")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(os.path.exists(out))
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"not decrypted", result.stderr)

    def test_no_password(self):
        result = run_cli(["--stdin", self.vector().path], b"")
        self.assertEqual(result.returncode, 2)

    def test_binary_needs_force(self):
        v = self.vector(plain_name="binary")
        out = self.out_path("binary")
        result = run_cli(["--stdin", "-o", out, v.path], pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 1)
        if b"several variants" in result.stderr:
            # a legacy key gave a correct padding as well, 3 in 256 times
            option = ["--variant", "current"]
        else:
            self.assertIn(b"--force", result.stderr)
            option = ["--force"]
        result = run_cli(["--stdin", "-o", out, v.path] + option, pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        with open(out, "rb") as f:
            self.assertEqual(f.read(), v.plaintext)

    def test_legacy_file_is_named(self):
        v = self.vector("legacyAESMD5", "text", False)
        result = run_cli(["--stdin", v.path], pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, v.plaintext)
        self.assertIn(b"old format (legacyAESMD5 without salt)", result.stderr)

    def test_explicit_variant(self):
        v = self.vector("legacyRC4SHA256", "pdf", True)
        result = run_cli(["--stdin", "--variant", "legacyRC4SHA256", v.path], pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, v.plaintext)
        # RC4 cannot tell a wrong password; the tool says the result looks wrong
        result = run_cli(["--stdin", "--variant", "legacyRC4SHA256", v.path], b"wrong\n")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"neither text nor a file type", result.stderr)
        # the current format needs the salt header
        v = self.vector("legacyAESMD5", "text", False)
        result = run_cli(["--stdin", "--variant", "current", v.path], pw(v.password) + b"\n")
        self.assertEqual(result.returncode, 1)

    def test_usage(self):
        self.assertEqual(run_cli([]).returncode, 2)
        self.assertEqual(run_cli(["--stdin", os.path.join(TMP, "no-such-file")], b"x\n").returncode, 2)
        self.assertEqual(run_cli(["--variant", "rot13", "x"]).returncode, 2)
        result = run_cli(["--version"])
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"safe-decrypt.py", result.stdout)

    def test_no_encryption_in_the_tool(self):
        with open(SCRIPT) as f:
            source = f.read()
        self.assertNotIn("def encrypt", source)


def manifest_entries(manifest):
    """The entries of app/Fixtures/manifest.json, which WP1 writes: a list, or
    an object with a list under "files" or "fixtures", or an object by file name."""
    if isinstance(manifest, dict):
        for key in ("files", "fixtures", "entries"):
            if isinstance(manifest.get(key), list):
                return manifest[key]
        return [dict(value, file=name) for name, value in manifest.items() if isinstance(value, dict)]
    return manifest


def first_key(entry, names):
    for name in names:
        if name in entry:
            return entry[name]
    return None


class AppFixtures(unittest.TestCase):
    """The reference files of app/Fixtures open with the reference decryptor (G5)."""

    def test_fixtures(self):
        manifest_path = os.path.join(FIXTURES, "manifest.json")
        if not os.path.exists(manifest_path):
            self.skipTest("no app/Fixtures/manifest.json yet")
        with open(manifest_path, encoding="utf-8") as f:
            entries = manifest_entries(json.load(f))
        self.assertTrue(entries, "the manifest lists no files")
        for entry in entries:
            name = first_key(entry, ("file", "name", "fileName", "filename", "path"))
            with self.subTest(name):
                self.assertIsNotNone(name, "no file name in %s" % sorted(entry))
                password = first_key(entry, ("password",))
                if password is None and "passwordHex" in entry:
                    password = bytes.fromhex(entry["passwordHex"]).decode("utf-8")
                digest = first_key(entry, ("sha256", "plaintextSHA256", "plaintextSha256",
                                           "plaintext_sha256", "plainSHA256"))
                length = first_key(entry, ("length", "plaintextLength", "plaintext_length",
                                           "size", "plainLength"))
                variant = first_key(entry, ("variant",))
                self.assertIsNotNone(password, "no password in %s" % sorted(entry))
                self.assertIsNotNone(digest, "no SHA-256 in %s" % sorted(entry))
                self.assertIn(variant, sd.VARIANTS)
                with open(os.path.join(FIXTURES, name), "rb") as f:
                    data = f.read()
                plaintext = sd.decrypt(data, pw(password), variant)
                self.assertEqual(hashlib.sha256(plaintext).hexdigest(), digest.lower())
                if length is not None:
                    self.assertEqual(len(plaintext), int(length))
                if sd.describe(plaintext) is not None:
                    self.assertEqual(sd.decrypt_auto(data, pw(password))[:2], (variant, plaintext))


if __name__ == "__main__":
    unittest.main()

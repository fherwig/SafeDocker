#!/usr/bin/env python3
"""Reference decryptor for files encrypted by crypt.sh, openssl enc and Safe.app.

It needs nothing but Python 3 and its standard library, so it still opens the
files when macOS, its openssl and Safe.app have moved on (requirement G5 in
docs/requirements.md). It only decrypts; it never writes an encrypted file.

    safe-decrypt.py FILE.crypt                  ask for the password, plain text to stdout
    safe-decrypt.py -o FILE FILE.crypt          write the plain text to FILE (never overwrites)
    safe-decrypt.py --stdin -o FILE FILE.crypt  read the password from the first line of stdin
    safe-decrypt.py --variant NAME ...          try only this variant
    safe-decrypt.py --force ...                 write a result that is neither UTF-8 text nor
                                                a file type this tool knows: text in another
                                                encoding, or an AES result whose padding fits
    safe-decrypt.py --salvage -o FILE FILE.crypt
                                                a file in the current format whose end is
                                                missing: write the part that can be read;
                                                with --force also when its start is not
                                                a type this tool knows
    safe-decrypt.py --self-test                 check this Python against known answers

The variants, byte by byte in docs/format.md and in section 5 of
docs/safe-app/building-plan.md:

  current          "Salted__", 8 bytes of salt, then AES-256-CBC with PKCS#7
                   padding. Key and IV are the 48 bytes of PBKDF2-HMAC-SHA512 over
                   the password's UTF-8 bytes and the salt, 100000 iterations:
                   key = bytes 0 to 31, IV = bytes 32 to 47. This is
                   openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt,
                   what crypt.sh writes since 2023 and what Safe.app writes.
  legacyAESSHA256  AES-256-CBC, key and IV from EVP_BytesToKey with SHA-256 and one
                   iteration: openssl enc without -pbkdf2 and without -md, from
                   OpenSSL 1.1.0 on, and today's LibreSSL.
  legacyAESMD5     the same with MD5: openssl enc without -md before OpenSSL 1.1.0.
  legacyRC4MD5     RC4 with a 16-byte key from EVP_BytesToKey with MD5, no IV:
                   crypt.sh before version 1.4.
  legacyRC4SHA256  the same with SHA-256.

The legacy variants may start with "Salted__" and a salt, or not (-nosalt).
Without --variant the variants are tried in the order above. AES needs a correct
padding, and since about 1 in 256 wrong passwords still gives one, the result
must also look right: text in UTF-8, or a file type this tool knows by its
first bytes (PDF, PNG, JPEG, GIF, TIFF, HEIC, zip). RC4 gives a result with any
password, so an RC4 result shorter than 32 bytes is never taken without
--variant. Text means strict UTF-8 without NUL bytes, as in Safe.app, and below
32 bytes also without control characters other than tab, line feed, form feed
and carriage return. Text in another encoding (ISO Latin-1, MacRoman, UTF-16),
which Safe.app opens without confirming the password, needs --force; anything
else needs --force (AES) or --variant.

A file in the current format cut short (an interrupted copy or download) fails
the padding check even with the right password, at a 16-byte boundary or not.
If the start of what the password gives looks like a real file, the tool says
that the end is missing, and --salvage writes the readable part: every whole
block but the last.

Exit status: 0 decrypted, 1 not decrypted (wrong password, not an encrypted
file, damaged file), 2 wrong usage or a file that cannot be read or written.
"""

import argparse
import codecs
import getpass
import hashlib
import hmac
import os
import struct
import sys

VERSION = "1.2"
MAGIC = b"Salted__"
ITERATIONS = 100000
# results shorter than this are UTF-8 too often by chance to be trusted from RC4,
# as in Safe.app (Plausibility.shortestUncheckedText)
SHORTEST_UNCHECKED_TEXT = 32
# how much of the start the RC4 quick look and the damage check decrypt
START_LENGTH = 4096
# the order of attempts, building plan 5.2
VARIANTS = ("current", "legacyAESSHA256", "legacyAESMD5", "legacyRC4MD5", "legacyRC4SHA256")


class DecryptError(Exception):
    """The file does not decrypt with this password and variant."""


# ---------------------------------------------------------------------------
# AES-256 decryption, FIPS-197. The tables are computed from the definitions
# rather than copied, and --self-test checks them against the standard's
# example. Td0 to Td3 join InvSubBytes and InvMixColumns, the usual way to
# make the "equivalent inverse cipher" of FIPS-197 section 5.3.5 fast.

def _xtime(a):
    """Multiplies by x (that is 2) in GF(2^8) modulo x^8 + x^4 + x^3 + x + 1."""
    a <<= 1
    return a ^ 0x11B if a & 0x100 else a


def _mul(a, b):
    """Multiplies two bytes in GF(2^8)."""
    result = 0
    while b:
        if b & 1:
            result ^= a
        a = _xtime(a)
        b >>= 1
    return result


def _make_tables():
    # powers of 3, which generate all non-zero bytes, give the inverses
    exp, log = [0] * 255, [0] * 256
    x = 1
    for i in range(255):
        exp[i], log[x] = x, i
        x ^= _xtime(x)
    sbox = [0] * 256
    for a in range(256):
        b = exp[(255 - log[a]) % 255] if a else 0
        s = b
        for _ in range(4):
            b = ((b << 1) | (b >> 7)) & 0xFF
            s ^= b
        sbox[a] = s ^ 0x63
    inv_sbox = [0] * 256
    for a in range(256):
        inv_sbox[sbox[a]] = a
    td0 = []
    for a in range(256):
        s = inv_sbox[a]
        td0.append((_mul(s, 14) << 24) | (_mul(s, 9) << 16) | (_mul(s, 13) << 8) | _mul(s, 11))
    td1 = [((w >> 8) | (w << 24)) & 0xFFFFFFFF for w in td0]
    td2 = [((w >> 16) | (w << 16)) & 0xFFFFFFFF for w in td0]
    td3 = [((w >> 24) | (w << 8)) & 0xFFFFFFFF for w in td0]
    return sbox, inv_sbox, td0, td1, td2, td3


SBOX, INV_SBOX, TD0, TD1, TD2, TD3 = _make_tables()


def _sub_word(w):
    return ((SBOX[w >> 24] << 24) | (SBOX[(w >> 16) & 0xFF] << 16)
            | (SBOX[(w >> 8) & 0xFF] << 8) | SBOX[w & 0xFF])


def _decryption_keys(key):
    """The 60 round-key words of AES-256 for the equivalent inverse cipher."""
    if len(key) != 32:
        raise ValueError("AES-256 needs a 32-byte key")
    w = list(struct.unpack(">8I", key))
    rcon = 1
    for i in range(8, 60):
        t = w[i - 1]
        if i % 8 == 0:
            t = _sub_word(((t << 8) & 0xFFFFFFFF) | (t >> 24)) ^ (rcon << 24)
            rcon = _xtime(rcon)
        elif i % 8 == 4:
            t = _sub_word(t)
        w.append(w[i - 8] ^ t)
    rounds = [w[4 * r:4 * r + 4] for r in range(15)]
    rounds.reverse()
    keys = []
    for r, words in enumerate(rounds):
        if 0 < r < 14:
            # InvMixColumns of a round key: S-box first, because Td includes InvSubBytes
            words = [TD0[SBOX[x >> 24]] ^ TD1[SBOX[(x >> 16) & 0xFF]]
                     ^ TD2[SBOX[(x >> 8) & 0xFF]] ^ TD3[SBOX[x & 0xFF]] for x in words]
        keys.extend(words)
    return keys


def aes256_cbc_decrypt(key, iv, data):
    """Decrypts whole 16-byte blocks with AES-256 in CBC mode; removes no padding."""
    if len(data) % 16:
        raise ValueError("CBC data must be whole 16-byte blocks")
    if not data:
        return b""
    dk = _decryption_keys(key)
    td0, td1, td2, td3, si = TD0, TD1, TD2, TD3, INV_SBOX
    n = len(data) // 4
    words = struct.unpack(">%dI" % n, data)
    out = [0] * n
    p0, p1, p2, p3 = struct.unpack(">4I", iv)
    for i in range(0, n, 4):
        c0, c1, c2, c3 = words[i], words[i + 1], words[i + 2], words[i + 3]
        s0, s1, s2, s3 = c0 ^ dk[0], c1 ^ dk[1], c2 ^ dk[2], c3 ^ dk[3]
        for k in range(4, 56, 4):
            s0, s1, s2, s3 = (
                td0[s0 >> 24] ^ td1[(s3 >> 16) & 255] ^ td2[(s2 >> 8) & 255] ^ td3[s1 & 255] ^ dk[k],
                td0[s1 >> 24] ^ td1[(s0 >> 16) & 255] ^ td2[(s3 >> 8) & 255] ^ td3[s2 & 255] ^ dk[k + 1],
                td0[s2 >> 24] ^ td1[(s1 >> 16) & 255] ^ td2[(s0 >> 8) & 255] ^ td3[s3 & 255] ^ dk[k + 2],
                td0[s3 >> 24] ^ td1[(s2 >> 16) & 255] ^ td2[(s1 >> 8) & 255] ^ td3[s0 & 255] ^ dk[k + 3])
        # the last round has no InvMixColumns
        out[i] = ((si[s0 >> 24] << 24) | (si[(s3 >> 16) & 255] << 16)
                  | (si[(s2 >> 8) & 255] << 8) | si[s1 & 255]) ^ dk[56] ^ p0
        out[i + 1] = ((si[s1 >> 24] << 24) | (si[(s0 >> 16) & 255] << 16)
                      | (si[(s3 >> 8) & 255] << 8) | si[s2 & 255]) ^ dk[57] ^ p1
        out[i + 2] = ((si[s2 >> 24] << 24) | (si[(s1 >> 16) & 255] << 16)
                      | (si[(s0 >> 8) & 255] << 8) | si[s3 & 255]) ^ dk[58] ^ p2
        out[i + 3] = ((si[s3 >> 24] << 24) | (si[(s2 >> 16) & 255] << 16)
                      | (si[(s1 >> 8) & 255] << 8) | si[s0 & 255]) ^ dk[59] ^ p3
        p0, p1, p2, p3 = c0, c1, c2, c3
    return struct.pack(">%dI" % n, *out)


def strip_padding(data):
    """Removes PKCS#7 padding, strictly: 1 to 16 bytes, all of the same value."""
    if not data or len(data) % 16:
        raise DecryptError("the encrypted data is not a whole number of 16-byte blocks")
    n = data[-1]
    if not 1 <= n <= 16 or data[-n:] != bytes([n]) * n:
        raise DecryptError("bad padding")
    return data[:-n]


# ---------------------------------------------------------------------------
# RC4, read only (crypt.sh before 1.4)

def rc4(key, data):
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 255
        s[i], s[j] = s[j], s[i]
    stream = bytearray(len(data))
    i = j = 0
    for n in range(len(data)):
        i = (i + 1) & 255
        si = s[i]
        j = (j + si) & 255
        sj = s[j]
        s[i], s[j] = sj, si
        stream[n] = s[(si + sj) & 255]
    if not data:
        return b""
    x = int.from_bytes(bytes(data), "big") ^ int.from_bytes(bytes(stream), "big")
    return x.to_bytes(len(data), "big")


# ---------------------------------------------------------------------------
# Key derivation

def _hash(name):
    try:
        return hashlib.new(name, usedforsecurity=False)
    except TypeError:
        return hashlib.new(name)
    except ValueError:
        raise DecryptError("this Python has no %s, which the variant needs" % name.upper())


def evp_bytes_to_key(digest, password, salt, length):
    """OpenSSL's EVP_BytesToKey with one iteration: D1 = H(password + salt),
    D2 = H(D1 + password + salt), ... until `length` bytes. No salt for -nosalt."""
    out = b""
    block = b""
    while len(out) < length:
        h = _hash(digest)
        h.update(block)
        h.update(password)
        if salt:
            h.update(salt)
        block = h.digest()
        out += block
    return out[:length]


def pbkdf2_sha512(password, salt, iterations, length, use_hashlib=True):
    """PBKDF2-HMAC-SHA512 (RFC 8018). Takes hashlib's version when it has one
    (from Python 3.12 only builds with OpenSSL do); the plain one is the same."""
    if use_hashlib and hasattr(hashlib, "pbkdf2_hmac"):
        return hashlib.pbkdf2_hmac("sha512", bytes(password), salt, iterations, length)
    inner = hmac.new(bytes(password), digestmod=hashlib.sha512)
    out = b""
    block_number = 1
    while len(out) < length:
        h = inner.copy()
        h.update(salt + struct.pack(">I", block_number))
        u = h.digest()
        result = int.from_bytes(u, "big")
        for _ in range(iterations - 1):
            h = inner.copy()
            h.update(u)
            u = h.digest()
            result ^= int.from_bytes(u, "big")
        out += result.to_bytes(64, "big")
        block_number += 1
    return out[:length]


# ---------------------------------------------------------------------------
# The variants

def split_salt(data):
    """Returns (salt, ciphertext); the salt is None without the "Salted__" header."""
    if data[:8] == MAGIC:
        if len(data) < 16:
            raise DecryptError("the file is cut short inside its salt header")
        return data[8:16], data[16:]
    return None, data


def is_salted(data):
    return data[:8] == MAGIC and len(data) >= 16


def _keys(variant, password, salt):
    """Key and IV of a variant; the IV is None for RC4."""
    if variant == "current":
        if salt is None:
            raise DecryptError("no 'Salted__' header, so not the current format")
        d = pbkdf2_sha512(password, salt, ITERATIONS, 48)
        return d[:32], d[32:48]
    if variant not in VARIANTS:
        raise ValueError("unknown variant %r" % variant)
    digest = "md5" if variant.endswith("MD5") else "sha256"
    if variant.startswith("legacyAES"):
        d = evp_bytes_to_key(digest, password, salt, 48)
        return d[:32], d[32:48]
    return evp_bytes_to_key(digest, password, salt, 16), None


def decrypt(data, password, variant, prefix=None):
    """Decrypts the whole file `data` (bytes) with `password` (bytes) and one variant.

    For AES the padding of the last block is checked first, which is quick, and
    a wrong padding raises DecryptError. RC4 has nothing to check. With `prefix`,
    RC4 decrypts only that many bytes, for a quick look."""
    salt, body = split_salt(data)
    if not variant.startswith("legacyRC4") and (not body or len(body) % 16):
        # before the key, which takes 100000 rounds for the current format
        if variant == "current" and salt is None:
            raise DecryptError("no 'Salted__' header, so not the current format")
        raise DecryptError("the encrypted data is not a whole number of 16-byte blocks")
    key, iv = _keys(variant, password, salt)
    if iv is None:
        return rc4(key, body if prefix is None else body[:prefix])
    previous = body[-32:-16] if len(body) >= 32 else iv
    strip_padding(aes256_cbc_decrypt(key, previous, body[-16:]))
    return strip_padding(aes256_cbc_decrypt(key, iv, body))


# ---------------------------------------------------------------------------
# Does a result look right?

# the first bytes of the types Safe.app knows for any name (Magic.isStrongType in
# Plausibility.swift), and JPEG, gzip and bzip2; PDF, RIFF and BMP below
FILE_TYPES = (
    (0, b"\x89PNG\r\n\x1a\n", "a PNG image"),
    (0, b"\xff\xd8\xff", "a JPEG image"),
    (0, b"GIF87a", "a GIF image"),
    (0, b"GIF89a", "a GIF image"),
    (0, b"II*\x00", "a TIFF image"),
    (0, b"MM\x00*", "a TIFF image"),
    (0, b"II+\x00", "a TIFF image"),
    (0, b"MM\x00+", "a TIFF image"),
    (4, b"ftyp", "an HEIC image or a video"),
    (0, b"PK\x03\x04", "a zip archive or an Office document"),
    (0, b"PK\x05\x06", "an empty zip archive"),
    (0, b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1", "an older Office document"),
    (0, b"\x1f\x8b\x08", "a gzip archive"),
    (0, b"\xfd7zXZ\x00", "an xz archive"),
    (0, b"\x28\xb5\x2f\xfd", "a zstd archive"),
    (0, b"7z\xbc\xaf\x27\x1c", "a 7-Zip archive"),
    (0, b"Rar!\x1a\x07", "a RAR archive"),
    (0, b"fLaC", "a FLAC sound"),
    (0, b"OggS", "an Ogg file"),
    (0, b"{\\rtf", "an RTF document"),
    (0, b"SQLite format 3\x00", "an SQLite database"),
    (0, b"bplist0", "a binary property list"),
    (257, b"ustar", "a tar archive"),
    (0, MAGIC, "a file encrypted with openssl (encrypted twice)"),
)
_RIFF_FORMS = {b"WEBP": "a WebP image", b"WAVE": "a WAV sound", b"AVI ": "an AVI video"}


def known_type(data):
    """The name of the type whose first bytes `data` starts with, or None."""
    if b"%PDF-" in data[:1024]:
        return "a PDF document"
    if data[:4] == b"RIFF" and data[8:12] in _RIFF_FORMS:
        return _RIFF_FORMS[data[8:12]]
    if data[:2] == b"BM" and data[6:10] == b"\x00\x00\x00\x00":
        return "a BMP image"
    if data[:3] == b"BZh" and data[3:4] in b"123456789" and len(data) > 3:
        return "a bzip2 archive"
    for offset, magic, name in FILE_TYPES:
        if data[offset:offset + len(magic)] == magic:
            return name
    return None


def describe(data, complete=True):
    """What the decrypted bytes look like, or None if neither text nor a known
    type. With complete=False `data` is only the start of the result. Text is
    strict UTF-8 without NUL, as in Safe.app (Plausibility.check), and below 32
    bytes also without control characters other than tab, line feed, form feed
    and carriage return: 15 random bytes are strict UTF-8 about once in 6,600
    tries, but also without those only once in 107,000."""
    if not data:
        return "empty" if complete else None
    name = known_type(data)
    if name is not None:
        return name
    try:
        text = codecs.getincrementaldecoder("utf-8")().decode(data, final=complete)
    except UnicodeDecodeError:
        return None
    if "\x00" in text:
        return None
    if len(data) < SHORTEST_UNCHECKED_TEXT and any(_is_control(ord(c)) for c in text if ord(c) < 0x80):
        return None
    return "text"


def is_text(description):
    return description in ("text", "empty")


OTHER_TEXT = "text in another encoding"


def _is_control(c):
    """A byte that text does not hold: C0 but tab, line feed, form feed, carriage return; DEL."""
    return (c < 0x20 and c not in (0x09, 0x0A, 0x0C, 0x0D)) or c == 0x7F


# code points of the common scripts, for UTF-16 text
_COMMON = ((0x09, 0x0D), (0x20, 0x7E), (0xA0, 0x52F), (0x590, 0x6FF), (0x2000, 0x206F),
           (0x20A0, 0x20CF), (0x2100, 0x214F), (0x3000, 0x30FF), (0x4E00, 0x9FFF),
           (0xAC00, 0xD7A3), (0xFF00, 0xFFEF))


def is_other_text(data):
    """True for text in another encoding than UTF-8, told apart from random bytes
    as Safe.app does (Plausibility.looksLikeText): at least 32 bytes of an 8-bit
    encoding without control bytes and at least 80 % ASCII, or UTF-16 after a
    byte order mark, valid, without control characters, 90 % in common scripts."""
    if len(data) < SHORTEST_UNCHECKED_TEXT:
        return False
    if not any(_is_control(c) for c in data) and sum(c < 0x80 for c in data) * 5 >= len(data) * 4:
        return True
    if len(data) % 2 or data[:2] not in (b"\xff\xfe", b"\xfe\xff"):
        return False
    order = "little" if data[:2] == b"\xff\xfe" else "big"
    units = [int.from_bytes(data[i:i + 2], order) for i in range(2, len(data), 2)]
    characters = common = 0
    k = 0
    while k < len(units):
        u = units[k]
        characters += 1
        if 0xD800 <= u <= 0xDBFF:
            if k + 1 >= len(units) or not 0xDC00 <= units[k + 1] <= 0xDFFF:
                return False
            common += 1
            k += 2
            continue
        if 0xDC00 <= u <= 0xDFFF or (u < 0x80 and _is_control(u)) or u in (0xFFFE, 0xFFFF):
            return False
        if any(a <= u <= b for a, b in _COMMON):
            common += 1
        k += 1
    return characters > 0 and common * 10 >= characters * 9


def could_be_text_start(start):
    """False only if a result that begins with `start` can be neither UTF-8 text,
    nor text in another encoding, nor a known type: the RC4 quick look."""
    return (describe(start, complete=False) is not None or not any(_is_control(c) for c in start)
            or start[:2] in (b"\xff\xfe", b"\xfe\xff"))


def looks_like_start(start):
    """True if `start`, the beginning of what a key gives for a file whose
    padding failed, looks like the start of a real file: a known type (JPEG with
    a fourth byte that real files have), UTF-8 text of 32 bytes or more whose last
    character may be cut, or text in another encoding of 64 bytes or more. There
    is no padding check before this, so random bytes must nearly never pass."""
    description = describe(start, complete=False)
    if description == "a JPEG image":
        return len(start) > 3 and (0xE0 <= start[3] <= 0xEF or start[3] in (0xDB, 0xC0, 0xC2, 0xC4, 0xFE))
    if description == "a gzip archive":
        # the flag byte's reserved bits are clear in every real file, as Safe.app checks
        return len(start) > 3 and start[3] & 0xE0 == 0
    if description not in (None, "text", "empty"):
        return True
    if description == "text" and len(start) >= SHORTEST_UNCHECKED_TEXT:
        return True
    return len(start) >= 2 * SHORTEST_UNCHECKED_TEXT and is_other_text(start)


def cut_short_start(data, password):
    """For a salted file whose current-format padding failed, or whose body is not
    whole blocks (cut inside a block): the start of what the password gives,
    without the last whole block, or None."""
    salt, body = split_salt(data)
    whole = len(body) // 16 * 16
    if salt is None or whole < 32:
        return None
    key, iv = _keys("current", password, salt)
    length = min(START_LENGTH, whole - 16)
    return aes256_cbc_decrypt(key, iv, body[:length])


def salvage(data, password, force=False):
    """The readable part of a file in the current format whose end is missing:
    every whole block but the last, if its start looks like a real file, or
    whatever it looks like with force (Safe.app's Export Readable Part, unchecked)."""
    salt, body = split_salt(data)
    if salt is None:
        raise DecryptError("no 'Salted__' header, so not the current format")
    whole = len(body) // 16 * 16
    if whole < 32:
        raise DecryptError("--salvage needs a file in the current format with at least two whole "
                           "16-byte blocks after the header")
    key, iv = _keys("current", password, salt)
    part = aes256_cbc_decrypt(key, iv, body[:whole - 16])
    if not force and not looks_like_start(part[:START_LENGTH]):
        raise DecryptError("the start does not look like a file this tool knows: a wrong password, "
                           "not a damaged file in the current format, or a type it cannot check. To "
                           "write it anyway, run again with --force")
    return part


def decrypt_auto(data, password, force=False):
    """Tries the variants in order; returns (variant, plaintext, description).

    The first result that looks right wins, except an RC4 result shorter than 32
    bytes, which random bytes match too often. With force, if none does, a
    result that is text in another encoding is taken (description "text in
    another encoding"), else the one AES result whose padding fits (description
    None). RC4 that is neither never comes back: it gives a result with any
    password. If nothing fits, the message says why: a file cut short, a short
    RC4 file, or a wrong password."""
    padded = []
    other = []
    short_rc4 = []
    if not data:
        raise DecryptError("the file is empty")
    salt, body = split_salt(data)
    if not body:
        raise DecryptError("nothing follows the salt header: a damaged file, or an empty file "
                           "encrypted with RC4, which --variant legacyRC4MD5 gives")
    for variant in VARIANTS:
        if variant == "current" and salt is None:
            continue
        rc4_variant = variant.startswith("legacyRC4")
        try:
            if rc4_variant and len(body) > START_LENGTH:
                # a quick look at the start first, RC4 in Python is slow
                if not could_be_text_start(decrypt(data, password, variant, prefix=START_LENGTH)):
                    continue
            plaintext = decrypt(data, password, variant)
        except DecryptError:
            continue
        description = describe(plaintext)
        if rc4_variant and len(plaintext) < SHORTEST_UNCHECKED_TEXT:
            if description is not None:
                short_rc4.append(variant)
            continue
        if description is not None:
            return variant, plaintext, description
        if is_other_text(plaintext):
            other.append((variant, plaintext))
        elif not rc4_variant:
            padded.append((variant, plaintext))
    if force:
        if len(other) == 1:
            return other[0][0], other[0][1], OTHER_TEXT
        if not other and len(padded) == 1:
            return padded[0][0], padded[0][1], None
    if other:
        raise DecryptError(
            "the result could be text in another encoding than UTF-8, such as ISO Latin-1, MacRoman "
            "or UTF-16 (%s), which this tool does not take without a check: with a wrong password it "
            "would be meaningless. To write it anyway, run again with --force%s."
            % (", ".join(v for v, _ in other),
               "" if len(other) == 1 else ", choosing the variant with --variant"))
    if len(padded) == 1:
        raise DecryptError(
            "the padding fits (%s), but the result is neither text nor a file type this tool "
            "knows: text with control characters, or a type this tool does not know. Or the "
            "password is wrong (about 1 in 256 wrong passwords gets this far), or it is an old RC4 "
            "file, which --variant legacyRC4MD5 opens. To write this result anyway, run again with "
            "--force." % padded[0][0])
    if padded:
        raise DecryptError(
            "the padding fits for several variants (%s), and none gives text or a file type "
            "this tool knows. Choose one with --variant." % ", ".join(v for v, _ in padded))
    if short_rc4:
        raise DecryptError(
            "RC4 cannot confirm a password for a file this short (%d bytes): it gives a result with "
            "any password. Check with --variant %s and look at the result." % (len(body), short_rc4[0]))
    start = cut_short_start(data, password)
    if start is not None and looks_like_start(start):
        raise DecryptError(
            "the password seems right, but the end of the file is missing, as when a copy, a "
            "download or a sync was interrupted. --salvage writes the part that can be read. If "
            "there is a .bak file next to it, it holds the previous version.")
    if salt is not None and len(body) % 16:
        raise DecryptError(
            "the data after the header is not a whole number of 16-byte blocks: the file is cut "
            "short (damaged), or it is an old RC4 file whose content this tool cannot check, which "
            "only --variant legacyRC4MD5 or --variant legacyRC4SHA256 opens. Or the password is wrong. "
            "--salvage --force writes what the password gives for the start in the current format.")
    raise DecryptError("wrong password, or not a file this tool can decrypt. An old RC4 file "
                       "that holds neither text nor a known file type opens only with "
                       "--variant legacyRC4MD5 or --variant legacyRC4SHA256.")


def variant_label(variant, data):
    if variant == "current":
        return "current"
    return variant + (" with salt" if is_salted(data) else " without salt")


# ---------------------------------------------------------------------------
# Self-test: known answers, made with macOS's LibreSSL 3.3.6 in October 2026
# with the password below, each for the plain text "Known answer for VARIANT.\n"

SELF_TEST_PASSWORD = "Grüße, self-test"
SELF_TEST_FILES = {
    "current": "53616c7465645f5f1e84ab9aedf3dc4fa77805bf416ecfae1c02c7a4278ec0eb"
               "6b1b085b9cd7d400c8c218fe5de04b56",
    "legacyAESSHA256": "53616c7465645f5fef028f4a1f5e9c5fee655680d0a3643c6c7f9a1bbd8b207f"
                       "be9196bf2c38f4bad5e6d8cb4d9dd25502b52b3254f0a9daa7a8503e8737dafb",
    "legacyAESMD5": "e93b338a8c4cf5ea459e6408850f5afda4d260d4e877efe9a92bb08fec6e9012",
    "legacyRC4MD5": "53616c7465645f5fa5dd1594383975e8f3179708cc22f4e03aa0f666f46b622c"
                    "8fc1b8112b10c42eb43b2fa4dc012e",
    "legacyRC4SHA256": "e20098b9d9b423fc049181bf12a5c3fdf07be1833d6d84e3ca8dd6047cd4b5d8abc4",
}


def self_test():
    """Returns a list of failures; empty if this Python decrypts correctly."""
    failures = []
    # FIPS-197 appendix C.3
    key = bytes(range(32))
    block = aes256_cbc_decrypt(key, bytes(16), bytes.fromhex("8ea2b7ca516745bfeafc49904b496089"))
    if block != bytes.fromhex("00112233445566778899aabbccddeeff"):
        failures.append("AES-256 does not decrypt the example of FIPS-197")
    # RFC 6229, 128-bit key, the first 16 bytes of the key stream
    stream = rc4(bytes(range(1, 17)), bytes(16))
    if stream != bytes.fromhex("9ac7cc9a609d1ef7b2932899cde41b97"):
        failures.append("RC4 does not give the key stream of RFC 6229")
    # PBKDF2: hashlib's and the plain one agree
    if hasattr(hashlib, "pbkdf2_hmac"):
        a = pbkdf2_sha512(b"password", b"saltsalt", 1000, 48)
        b = pbkdf2_sha512(b"password", b"saltsalt", 1000, 48, use_hashlib=False)
        if a != b:
            failures.append("the two PBKDF2-HMAC-SHA512 implementations disagree")
    password = SELF_TEST_PASSWORD.encode("utf-8")
    for variant, hexdata in SELF_TEST_FILES.items():
        data = bytes.fromhex(hexdata)
        expected = ("Known answer for %s.\n" % variant).encode("ascii")
        try:
            if decrypt(data, password, variant) != expected:
                failures.append("%s: wrong plain text" % variant)
            if variant.startswith("legacyRC4") and len(expected) < SHORTEST_UNCHECKED_TEXT:
                # too short for RC4 to be trusted without --variant
                try:
                    found = decrypt_auto(data, password)[0]
                    failures.append("%s: a short RC4 file was taken as %s without --variant"
                                    % (variant, found))
                except DecryptError as e:
                    if "--variant" not in str(e):
                        failures.append("%s: %s" % (variant, e))
                continue
            found, plaintext, _ = decrypt_auto(data, password)
            if found != variant or plaintext != expected:
                failures.append("%s: found as %s without --variant" % (variant, found))
        except DecryptError as e:
            failures.append("%s: %s" % (variant, e))
        try:
            decrypt_auto(data, b"not the password")
            failures.append("%s: a wrong password was accepted" % variant)
        except DecryptError:
            pass
    return failures


# ---------------------------------------------------------------------------
# Command line

def read_password(from_stdin):
    """The password as a bytearray: the first line of stdin, without its line
    feed (as openssl -pass stdin and crypt.sh do it), or typed at a prompt."""
    if from_stdin:
        line = sys.stdin.buffer.readline()
        if not line:
            raise ValueError("no password on standard input")
        return bytearray(line[:-1] if line.endswith(b"\n") else line)
    return bytearray(getpass.getpass("Password: ").encode("utf-8"))


def wipe(buffer):
    """Overwrites a bytearray; Python may still hold copies elsewhere."""
    for i in range(len(buffer)):
        buffer[i] = 0


def say(message):
    sys.stderr.write("safe-decrypt: " + message + "\n")


def write_new_file(path, data):
    """Writes a new file readable by the owner only; never overwrites one."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:
        os.unlink(path)
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="safe-decrypt.py",
        description="Decrypt a file made by crypt.sh, openssl enc or Safe.app. Needs only "
                    "Python 3; never encrypts.",
        epilog="Exit status: 0 decrypted, 1 not decrypted, 2 wrong usage or file error.")
    parser.add_argument("file", nargs="?", help="the encrypted file")
    parser.add_argument("-o", "--output", metavar="OUT",
                        help="write the plain text to OUT, a new file readable only by you; "
                             "without -o it goes to standard output")
    parser.add_argument("--stdin", action="store_true",
                        help="read the password from the first line of standard input "
                             "instead of asking for it")
    parser.add_argument("--variant", choices=("auto",) + VARIANTS, default="auto",
                        help="try only this variant (default: all, in this order)")
    parser.add_argument("--force", action="store_true",
                        help="write the result even if it is neither UTF-8 text nor a known file "
                             "type: text in another encoding, or an AES result whose padding fits")
    parser.add_argument("--salvage", action="store_true",
                        help="for a file in the current format whose end is missing: write the "
                             "part that can be read (with --force also when its start is not a "
                             "type this tool knows)")
    parser.add_argument("--self-test", action="store_true",
                        help="check the decryption against known answers and exit")
    parser.add_argument("--version", action="version", version="safe-decrypt.py " + VERSION)
    args = parser.parse_args(argv)

    if args.self_test:
        failures = self_test()
        for failure in failures:
            say("self-test failed: " + failure)
        if failures:
            return 1
        print("safe-decrypt.py %s: self-test passed (Python %s)" % (VERSION, sys.version.split()[0]))
        return 0
    if not args.file:
        parser.print_usage(sys.stderr)
        say("give the encrypted file")
        return 2
    if args.output and os.path.lexists(args.output):
        say("%s exists already. Not overwriting it." % args.output)
        return 2
    try:
        with open(args.file, "rb") as f:
            data = f.read()
    except OSError as e:
        say("cannot read %s: %s" % (args.file, e.strerror or e))
        return 2

    try:
        password = read_password(args.stdin)
    except (ValueError, EOFError) as e:
        say(str(e) or "no password read")
        return 2
    try:
        if args.salvage:
            variant = "current"
            plaintext = salvage(data, password, force=args.force)
            description = "the readable part of a damaged file"
        elif args.variant == "auto":
            variant, plaintext, description = decrypt_auto(data, password, force=args.force)
        else:
            variant = args.variant
            plaintext = decrypt(data, password, variant)
            description = describe(plaintext)
    except DecryptError as e:
        say("%s not decrypted: %s" % (args.file, e))
        return 1
    finally:
        wipe(password)

    if description is None:
        say("note: the result is neither text nor a file type this tool knows; "
            "if you expected text, the password or the variant is wrong.")
    elif description == OTHER_TEXT:
        say("note: the result is not UTF-8; it looks like text in another encoding. "
            "If it is not what you expected, the password or the variant is wrong.")
    elif args.salvage:
        say("note: the end of %s is missing; what was written is incomplete." % args.file)
        if args.force:
            say("note: with --force its start was not checked; with a wrong password it is meaningless.")
    if variant != "current":
        say("note: %s is in an old format (%s). Safe.app can save it again in the current "
            "format." % (args.file, variant_label(variant, data)))

    if args.output:
        try:
            write_new_file(args.output, plaintext)
        except OSError as e:
            say("cannot write %s: %s" % (args.output, e.strerror or e))
            return 2
        say("decrypted %s (%s, %s) into %s, %d bytes. %s is NOT encrypted: delete it when "
            "you no longer need it." % (args.file, variant_label(variant, data),
                                        description or "unknown type", args.output,
                                        len(plaintext), args.output))
        return 0
    if sys.stdout.isatty() and not is_text(description) and description != OTHER_TEXT:
        say("the result is %s, not text. Give -o FILE to write it to a file."
            % (description or "of an unknown type"))
        return 2
    say("warning: the decrypted content of %s (%s) goes to standard output, NOT encrypted."
        % (args.file, variant_label(variant, data)))
    sys.stdout.flush()
    sys.stdout.buffer.write(plaintext)
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.stderr.write("\n")
        sys.exit(130)

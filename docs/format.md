# The file format of encrypted files

An encrypted file, `NAME.crypt`, is what `openssl enc` writes with these options:

    openssl enc -e -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt -in NAME -out NAME.crypt

`crypt.sh` (version 1.5) writes it, and Safe.app writes it with its own code, which does not
call the system's `openssl` (requirements G3 and G5). This document describes the format byte
by byte, the older variants that Safe.app can still read, and how to decrypt any of them with
plain `openssl`, without Safe.app.

## The current format

| Bytes | Content |
|---|---|
| 0 to 7 | the 8 ASCII characters `Salted__`, in hex `53 61 6c 74 65 64 5f 5f` |
| 8 to 15 | the salt: 8 random bytes, new for every encryption |
| 16 to the end | the ciphertext: AES-256-CBC with PKCS#7 padding, a multiple of 16 bytes, at least 16 |

**Key and IV.** PBKDF2 with HMAC-SHA512 (RFC 8018) over

- the password: its exact UTF-8 bytes as typed, without a newline at the end and without any
  Unicode normalisation (see Passwords below),
- the salt: bytes 8 to 15 of the file,
- 100,000 iterations,

gives 48 bytes. Bytes 0 to 31 are the AES-256 key, bytes 32 to 47 the IV.

**Cipher.** AES with a 256-bit key in CBC mode. Before encryption the plaintext is padded to a
whole number of 16-byte blocks with PKCS#7: 1 to 16 bytes are added, each holding the number
of bytes added. A plaintext whose length is already a multiple of 16 gets a whole block of
sixteen bytes 0x10. So a plaintext of n bytes gives a file of 16 + 16 × (⌊n / 16⌋ + 1) bytes;
an empty file gives 32 bytes.

**Passwords.** A password is the UTF-8 bytes of what was typed, nothing added. It must not
contain a line break: `openssl` reads its prompt, `-pass stdin` and `-pass file:` only up to
the first line break, and `crypt.sh` reads one line, so a file encrypted with such a password
would open with neither. Safe.app refuses a new password with a line break or another control
character (tab included), and drops line breaks at the end of a password typed to open a file,
which pasting a whole line adds. `openssl`'s prompt takes at most 511 bytes (`-pass stdin` and
`-pass file:` up to 1023), so Safe.app refuses new passwords longer than 511 bytes. Password
fields on the Mac, Safe.app's included, take only Latin keyboard layouts and no emoji: a
password with letters of another script (Greek, Cyrillic, Hebrew, Arabic, Chinese, Japanese,
Korean) or with emoji must be pasted there, and the clipboard cleared afterwards (`crypt.sh` in
Terminal takes any keyboard layout). Latin letters with accents are fine. Safe.app says so when
such a password is chosen.

**Decryption.** Read the salt, derive key and IV, decrypt all blocks, then check the padding:
the last byte p must be 1 to 16, and the last p bytes must all be p. Remove them. Safe.app
checks the padding itself, because CommonCrypto's `kCCOptionPKCS7Padding` reported success for
wrong keys in a test (2000 of 2000). It names CBC mode (`kCCModeCBC`) instead of relying on a
default, and it decrypts the last block first (its IV is the ciphertext block before it) to
check the padding, so that a wrong password costs one block and not a pass over the file.

**A wrong password can pass the padding check.** About 1 in 256 wrong passwords decrypts to
garbage whose last byte happens to be `01`. So Safe.app also checks that the result is
plausible for the original name (the name without `.crypt`):

- content that starts with the magic bytes of a known type counts for any name, because files
  are often misnamed: `%PDF-` within the first 1024 bytes; PNG `89 50 4E 47 0D 0A 1A 0A`;
  `GIF87a` or `GIF89a`; TIFF `II*\0`, `MM\0*` or BigTIFF; `ftyp` at byte 4 (MP4, MOV, M4A, and
  with a HEIF or AVIF brand such as `heic`, `mif1` or `avif` a picture); `RIFF` with `WEBP`,
  `WAVE` or `AVI `; BMP (`BM`, then four zero bytes at byte 6); ZIP `PK\3\4` or `PK\5\6`
  (Office, OpenDocument, EPUB and iWork files); the Office compound file
  `D0 CF 11 E0 A1 B1 1A E1`; xz, zstd, 7-Zip, RAR, FLAC, Ogg, RTF (`{\rtf`), SQLite, binary
  property lists and POSIX tar. Random bytes match one of these less than about once in
  10^8 tries;
- text endings (`.txt`, `.md`, `.markdown`, `.csv`, `.json`, `.yaml`, `.yml`, `.xml`, `.tex`,
  `.log`, and no ending, like `safe`): valid UTF-8 without NUL bytes; a text shorter than 32
  bytes also without control bytes other than tab, line feed, form feed and carriage return
  (15 random bytes are strict UTF-8 without NUL about once in 6,600 tries, but also without
  those control bytes only once in 107,000). A text of exactly 15 bytes, which leaves one byte
  of padding, is not confirmed even then: a wrong password that passes the padding check
  gives one about once in 27 million tries, more often than the other checks allow, so
  Safe.app asks the user (below);
- endings of known binary types need the magic bytes of their type: `.pdf`; pictures (`.png`,
  `.jpg`, `.jpeg`, `.gif`, `.tif`, `.tiff`, `.heic`, `.heif`, `.webp`, `.bmp`, `.avif`, where
  any picture counts, JPEG's `FF D8 FF` included); ZIP-based documents (`.zip`, `.docx`,
  `.xlsx`, `.pptx`, `.odt`, `.epub`, `.pages`, `.numbers` and a few more, but not `.key`,
  which is also the ending of private keys); `.doc`,
  `.xls`, `.ppt`; `.gz` and `.tgz` (`1F 8B 08`); `.bz2` (`BZh` and a digit); `.xz`, `.zst`,
  `.7z`, `.rar`, `.wav`, `.avi`, `.mp4`, `.m4a`, `.m4v`, `.3gp`, `.flac`, `.ogg`, `.rtf`,
  `.sqlite`;
- any other ending: UTF-8 text of at least 32 bytes counts (random bytes are that about once
  in 10^8 tries); anything else is a type Safe.app cannot check.

**A check that fails does not prove a wrong password.** A text file in ISO Latin-1 or UTF-16 is
not UTF-8, and a picture may be in a format Safe.app does not know. So a result of the current
format whose padding is right is never refused:

- a plausible result opens;
- a result of a type that cannot be checked opens if more than one byte of padding was
  removed: nearly every wrong password that passes the padding check leaves one byte, while a
  real file has one only once in 16 times. A wrong password removes two bytes or more about
  once in 65,000 tries; for such a file its meaningless result is then exported (the only way
  out for this type) without the note that it may be meaningless, and an old file of such a
  type is taken as such a current result;
- a picture (JPEG's `FF D8 FF` included) or gzip opens whatever the name, a JPEG saved
  without an ending for example: after the padding check, a wrong password gets that far about
  once in 4 billion tries;
- any other result (content that does not fit its name, or a type that cannot be checked with
  one byte of padding) is not shown straight away. Safe.app says that it could not confirm the
  password, because the content does not look like such a file, and the user chooses: open a
  text read only (as UTF-8, as UTF-16 after a byte order mark, or as ISO Latin-1, which keeps
  every byte) and allow editing after checking it, view a picture or PDF, export the result,
  or type another password.

For a text name, Safe.app first tells text in another encoding apart from random bytes. Text
counts as such if it is at least 32 bytes of an 8-bit encoding (no NUL or other control byte
but tab, line feed, form feed and carriage return, and at least 80 % ASCII: ISO Latin-1,
Windows-1252, MacRoman and the like), or UTF-16 after a byte order mark (valid, without control
characters, at least 90 % of it in the common scripts). Random bytes of 32 bytes pass about once
in 3 million tries. Only such text is offered read only. A result that is neither UTF-8 nor text
is nearly always a wrong password: Safe.app says that the password is probably not right and
asks for it again, and offers Export Anyway, so that the right password is still never refused
(for a binary file without an ending, for example). The same holds for a name whose type
always starts with the same bytes (`.pdf`, ZIP-based documents, `.doc`, `.xls`, `.ppt`,
archives, media, `.rtf`, `.sqlite`) when the result matches no known type: a real PDF always
has `%PDF-` near its start. Pictures keep the softer question, because a picture may be in a
format Safe.app does not know.

About 1 in 256 wrong passwords passes the current format's padding check. Safe.app also tries
the two older AES derivations on every salted file, each with its own 1 in 256, so about 3 in
256 wrong passwords (14 to 31 of 2000 in the test runs) reach the user as results Safe.app
could not confirm. None is confirmed, and for a text name none is offered read only: all were
reported as probably wrong, never shown.

### Worked example

Password `safetest` (bytes `73 61 66 65 74 65 73 74`), salt `01 02 03 04 05 06 07 08`:

    key = 190d11c6016143d648000169550c96ed86ce07e03d5694b28c39651a60d7ef1f
    iv  = 120b32f1ec3ca941f349f48006ae08b3

The plaintext `hello` and a newline (6 bytes) encrypts to this 32-byte file:

    53 61 6c 74 65 64 5f 5f 01 02 03 04 05 06 07 08
    28 ae 1a 6a f8 60 20 57 b7 f1 ef 7d 86 38 9a 50

`openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -S 0102030405060708 -P -pass pass:safetest`
prints the same key and IV. The test suite checks this example (`crypto/the worked example of
docs/format.md`).

## Decrypting and encrypting with plain openssl

Decrypt (asks for the password):

    openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in NAME.crypt -out NAME

`NAME` must not exist: `-out` replaces a file without asking, and after a wrong password
(`bad decrypt`) it holds garbage, which should be deleted. `[ -e NAME ] || openssl enc -d ...`
guards against that; `crypt.sh -d` and `tools/safe-decrypt.py -o NAME` never overwrite.

Encrypt:

    openssl enc -e -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt -in NAME -out NAME.crypt

Name every option, as here: the defaults of `openssl` have changed over the years (see below),
the options have not. Tested with macOS's `/usr/bin/openssl` (LibreSSL 3.3.6) and with OpenSSL
3.0.22 in the Docker image `fherwig/safe:22.0`, both ways, also with non-ASCII passwords.
`-pbkdf2` and `-iter` need OpenSSL 1.1.1 or later, or LibreSSL 3.x: `/usr/bin/openssl` on macOS
13 and later has them (LibreSSL 3.3.6). Older Macs ship LibreSSL 2.x, which very probably lacks
them: there, use `tools/safe-decrypt.py` or the Docker image.

A wrong password usually makes `openssl` say `bad decrypt` and exit with status 1, but, as
above, about 1 in 256 wrong passwords gives garbage and status 0. `crypt.sh` and Safe.app
encrypt only after typing the password twice and check every new file by decrypting it again.

The password typed on a Mac keyboard is in composed Unicode (NFC): `ü` is one code point,
bytes `c3 bc`. The decomposed form (`u` and a combining diaeresis, `75 cc 88`) is another
password. Programs that hand a password to `openssl` must pass its bytes unchanged; Foundation's
`Process` converts command-line arguments and environment variables to the decomposed form, so
pass passwords through stdin or a file, as `crypt.sh` and Safe.app do.

Without `openssl` at all, `tools/safe-decrypt.py` decrypts the current format and every older
variant below with nothing but Python 3 and its standard library; it is the executable reference
of this document. Its `--variant` names are the variant names used here (`current`,
`legacyAESMD5`, and so on). See `tools/README.md`.

## Files next to an encrypted file

- `NAME.crypt`: the encrypted file.
- `NAME.crypt.bak`: the previous version, kept by every save.
- `NAME.crypt_new`: exists only while a file is saved or encrypted.

Saving, in Safe.app as in `crypt.sh`: check that `NAME.crypt` is still the file that was
opened; encrypt into a new `NAME.crypt_new` (mode 0600, flushed to the disk); decrypt it
again and compare with the plaintext, and delete it if they differ; copy `NAME.crypt` to
`NAME.crypt.bak`; rename `NAME.crypt_new` to `NAME.crypt`. Encrypting a file `NAME` is the
same from the second step, ends with deleting `NAME`, and refuses if `NAME.crypt` exists. No
step writes plaintext to the disk.

## Older variants (read only)

Safe.app reads files that older tools wrote, and never writes them. If a file opens only as an
older variant, Safe.app says so and offers to save it in the current format (a text is saved
so at its next Cmd-S, other files with Save in Current Format); the old file then stays as
`NAME.crypt.bak`.

Without `-pbkdf2`, `openssl enc` derives key and IV with `EVP_BytesToKey(digest, salt,
password, 1)`:

    D1 = H(password + salt)
    Di = H(D(i-1) + password + salt)
    key and IV = the first bytes of D1 + D2 + D3 + ...

where H is the digest and `+` joins bytes. The salt is left out for files written with
`-nosalt`, which have no `Salted__` header; their ciphertext starts at byte 0. AES-256-CBC
takes 32 bytes of key and 16 of IV; RC4 takes a 16-byte key and no IV.

| Variant | Written by | Decrypt with |
|---|---|---|
| `legacyAESSHA256` | `openssl enc -aes-256-cbc` without `-md` and `-pbkdf2`, OpenSSL 1.1.0 and later, LibreSSL 3.3.6 | `openssl enc -d -aes-256-cbc -md sha256 -in F` |
| `legacyAESMD5` | the same with older versions, which used MD5; `crypt.sh` 1.4 (2010 to 2023) with such an `openssl` | `openssl enc -d -aes-256-cbc -md md5 -in F` |
| `legacyRC4MD5` | `crypt.sh` before 1.4, which used RC4, with an `openssl` of that time | `openssl enc -d -rc4 -md md5 -in F` |
| `legacyRC4SHA256` | RC4 with a newer `openssl` | `openssl enc -d -rc4 -md sha256 -in F` |

Add `-nosalt` for a file that does not start with `Salted__`. RC4 is in macOS's LibreSSL; in
OpenSSL 3 it needs `-provider legacy -provider default` (the Docker image has the legacy
provider). Check the result: RC4 has no padding, so it "decrypts" with any password.

Safe.app tries the current format first, then `legacyAESSHA256`, `legacyAESMD5`,
`legacyRC4MD5`, `legacyRC4SHA256`. The first result that is plausible for the original name is
confirmed; a plausible older result wins over a current one that could not be confirmed. Only a
plausible result is confirmed, because several attempts raise the chance that a wrong password
passes. Other results that could be right are kept, so that the right password is never
refused, and are offered to the user as above, without a confirmation:

- an AES variant's result whose padding is right: for a name whose type cannot be checked
  Safe.app asks "Is this the right password?"; for content that does not fit its name (a text
  in Windows-1252 written with the old MD5 default, for example) it asks as for the current
  format;
- RC4 decrypts with any password, so its result is kept only if it is text in another encoding
  (above) for a text name, if it is plausible but shorter than 32 bytes (plausible too often by
  chance: about once in 12,000 tries for 16 bytes, so such a result never counts as text when
  results are compared: it must not beat the right result of the current format for a short
  Latin-1 text), or, for a name whose type cannot be checked, if the file is salted and not a
  whole number of 16-byte blocks, which AES cannot have. For a file larger than 4 KB, Safe.app
  decrypts the first 4 KB with RC4 first and goes on only if the whole result could still be
  kept.

Between several kept results Safe.app prefers, for a text name, one that is text; then the
current format, unless an older AES result removed more than one byte of padding and the current
one only one; then more padding before less; otherwise the earlier attempt. A result the user
accepted without a check (an unchecked one) is never saved in the current format without the
user's yes: a text is shown read only until Allow Editing, other files can only be exported.

What does not open in a window of Safe.app, and how to get at it:

- an RC4 file of a type Safe.app cannot check (such as `.bin`) whose length is a whole number of
  16-byte blocks or that has no salt, and an RC4 file of a text name that holds neither text nor
  a known type: RC4 gives a result with any password, which cannot be told from garbage. When
  the same password is refused twice in a row for such a name, Safe.app offers Export as an Old
  RC4 File (with an MD5 key, as crypt.sh before 1.4 wrote, or a SHA-256 key) and warns that it
  cannot check the result; it never shows or saves it. With about 1 in 128 passwords (1 in 85
  for a salted file), the right one included, one of the AES attempts passes its padding check
  on such a file instead, and Safe.app asks about that result ("Is this the right password?",
  or that it could not confirm it): its button Other Readings then offers the same export.
  Without Safe.app: `openssl enc -d -rc4 -md md5 ...` (above) or
  `tools/safe-decrypt.py --variant legacyRC4MD5`;
- an old AES file of a type Safe.app cannot check whose padding is one byte, while the current
  format also passed its padding check with one byte (about once in 4,000 such files): Safe.app
  takes the current result. Use `tools/safe-decrypt.py --variant` with the old variant;
- a file made by hand with `openssl enc -pbkdf2` and other options than those of the current
  format: its defaults (SHA-256 and 10,000 iterations) or another `-iter`. Neither Safe.app nor
  `tools/safe-decrypt.py` tries these; use `openssl` with the options it was made with.

A file without the `Salted__` header whose content already looks like its type (UTF-8 text of
at least 32 bytes for a text name, for example, or the first bytes of a known type) is reported
as not encrypted. Shorter content is tried with the older variants first, because a few random
bytes, such as an old encrypted PIN, are valid UTF-8 often.

**Damaged files.** A salted file whose length after the header is not a whole number of 16-byte
blocks cannot be AES as it was written: it is an old RC4 file, or a file cut short, by an
interrupted copy or sync for example. A file that holds only the 16-byte header is reported as
damaged (it could also be an empty file encrypted with RC4).

A file in the current format cut short fails the padding check even with the right password,
because its last block is missing (cut at a block boundary, as interrupted copies, downloads and
syncs usually are, at 4 KiB, 64 KiB or 1 MiB) or incomplete (cut inside a block). But CBC
decrypts each block with the one before it, so the start of the file comes out right. When the
padding check fails, or the length is not whole blocks, Safe.app therefore looks at what the key
gives for the first whole blocks (up to 4 KB, never the last whole block): if it looks like the
start of a file of that name (the first bytes of a known type, JPEG and gzip with one byte more
than usual; or for a text name or a type that cannot be checked UTF-8 text of at least 32 bytes,
whose last character may be cut; or for a text name text in another encoding of at least 64
bytes), the password is very likely right: random bytes pass about once in 10^8 tries. Safe.app
then says that the end of the file is missing, names `NAME.crypt.bak` if there is one, and
offers Export Readable Part, which writes every whole block but the last (a partial block after
them is dropped too). Older variants are not checked this way.

If the start does not look like such a file, because Safe.app cannot check the type (a `.bin`,
a `.kdbx`, a private key) or a text name holds something else, nothing tells a damaged file
from a wrong password. If no variant gives a result, Safe.app says that the password was not
right and, for a salted file that is not whole blocks, that the file may be damaged, and asks
again; the same password typed again offers Export Readable Part (and Export as an Old RC4
File), both with the warning that Safe.app could not check the result. For a type that cannot
be checked, a file cut inside a block can look like an RC4 file and give meaningless bytes;
Safe.app asks the user before trusting that, and its button Other Readings offers the readable
part instead.

`tools/safe-decrypt.py` says "nothing follows the salt header" for a file that holds only the
header; for one cut short whose start looks right, at a block boundary or not, that the end of
the file is missing; and for one that is not whole blocks with a start it does not know, that it
is cut short or an old RC4 file. `--salvage -o FILE` then writes the readable part, and
`--salvage --force -o FILE` writes it also when the start is not a type it knows.

Key and IV for the password `safetest` and the salt `01 02 03 04 05 06 07 08`:

    MD5:              key = c1717b718da9a8543b72a65af25d7e2fb0776a05085dd0803730283d7c50afbd
                      iv  = b24726c1367eb8569a6cf7b1f0ed1b6f
    MD5, RC4:         key = c1717b718da9a8543b72a65af25d7e2f
    SHA-256, no salt: key = dd05bf6a716e347e25ebb081de95b745673e7962ed5db476d498adea5803e2b5
                      iv  = 4237d54e727e8e0fcf03024d696910cf

## Reference files

`app/Fixtures` holds files with known passwords and contents, made by several
implementations, named `<generator>-<variant>-<n>.enc` (not `.crypt`, which `.gitignore`
excludes). Safe.app checks them when it is built, installed and started (`Safe --self-test`),
and refuses to encrypt if one fails.

| Generator | Made with |
|---|---|
| `openssl3` | OpenSSL 3.0.22 in the Docker image `fherwig/safe:22.0`, RC4 through its legacy provider |
| `cryptsh` | `crypt.sh` 1.5 in the same image, given the password with `printf "pw\npw\n"` |
| `libressl` | macOS's `/usr/bin/openssl`, LibreSSL 3.3.6 |
| `app` | Safe.app's own code (SafeCore) |

They cover every variant, salted and unsalted, non-ASCII passwords, empty files, a 1 MiB file,
a PDF, a PNG, a JPEG, a HEIC picture, files without an ending, files of a type that cannot be
checked, and texts in ISO Latin-1, MacRoman and UTF-16 in the current format and the older
variants, which Safe.app opens without confirming the password.

`app/Fixtures/manifest.json` lists them:

    {
      "format": "...",
      "files": [
        {"file": "openssl3-current-1.enc", "generator": "Debian OpenSSL 3.0.22",
         "variant": "current", "salted": true,
         "options": "-aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt",
         "originalName": "notes.txt", "password": "...", "length": 279, "sha256": "..."},
        ...
      ]
    }

- `file`: the file in `app/Fixtures`;
- `generator`: what made it, with its version;
- `variant`: one of `current`, `legacyAESSHA256`, `legacyAESMD5`, `legacyRC4MD5`,
  `legacyRC4SHA256`;
- `salted`: whether the file has the `Salted__` header;
- `options`: the `openssl enc` options that decrypt it (with `-d`);
- `originalName`: the name of the plaintext file;
- `password`: the password, in UTF-8;
- `length`, `sha256`: the length and SHA-256 (lower-case hex) of the plaintext.

To decrypt one by hand:

    printf '%s\n' 'PASSWORD' | openssl enc -d OPTIONS -pass stdin -in app/Fixtures/FILE

`app/scripts/make-fixtures.sh` makes a new set. Each text and picture plaintext holds a
random marker (`safetest-marker-` and 32 hex digits), which the leak test searches the disk
for; the plaintexts themselves are not kept anywhere.

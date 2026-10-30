This directory holds the ways to open encrypted files that depend
neither on macOS, nor on Safe.app, nor on Docker Hub (requirement G5
in docs/requirements.md).

* safe-decrypt.py: a reference decryptor that needs nothing but
  Python 3 and its standard library. It reads every format that
  crypt.sh, openssl enc and Safe.app have written: the current one
  (AES-256-CBC, PBKDF2-HMAC-SHA512 with 100000 iterations) and the old
  variants (key from MD5 or SHA-256 without PBKDF2, RC4, with or
  without salt). It only decrypts. AES, RC4 and the strict padding
  check are written out in Python, so an update of openssl cannot
  change what it reads.

      python3 safe-decrypt.py -o report.pdf report.pdf.crypt
      python3 safe-decrypt.py notes.txt.crypt | less
      python3 safe-decrypt.py --self-test

  It asks for the password without showing it (--stdin reads it from
  the first line of standard input instead) and never overwrites a
  file. The decrypted copy is NOT encrypted: delete it when done.
  Without --variant or --force it takes only a result that looks
  right, so a wrong password is reported as wrong: about 1 in 256
  wrong passwords gets past an AES padding check, so the result must
  also look like UTF-8 text (as Safe.app judges it: strict UTF-8 without
  NUL, and below 32 bytes without control characters) or a known file
  type (PDF, pictures, zip and Office documents, archives, media, RTF,
  SQLite, the same first bytes Safe.app knows). RC4 gives a result
  with any password, so an RC4 result shorter than 32 bytes is never
  taken without --variant.
  Text in another encoding (ISO Latin-1, MacRoman, UTF-16), and other
  contents of an AES file whose padding fits, need --force. An old RC4
  file whose content is neither text nor a known type (a binary file)
  needs --variant legacyRC4MD5 or --variant legacyRC4SHA256; --variant
  tries only that variant and also settles the rare file whose padding
  fits for several variants. With --variant or --force the tool cannot
  tell a wrong password: check the result. A file in the current
  format cut short (an interrupted copy) is reported as damaged when
  the start still looks right; --salvage writes the part that can be
  read, and --salvage --force writes it also when the start is not a
  type the tool knows. python3 safe-decrypt.py --help lists the
  options.

* docker-image.txt: the digest of the Docker image fherwig/safe:22.0,
  which has OpenSSL 3. docker pull with that line gets exactly this
  image. ../app/scripts/time-capsule.sh DIR saves the image as an
  archive file in DIR, outside the repository, with a record of its
  digest and how to use it.

* test_safe_decrypt.py: tests of the decryptor. It makes encrypted
  files with macOS's /usr/bin/openssl (LibreSSL) and with the Docker
  image (OpenSSL 3, run with --rm --network none), checks that every
  variant opens and that wrong passwords do not, and checks the
  reference files in ../app/Fixtures against their manifest.

      python3 test_safe_decrypt.py            up to three minutes
      python3 test_safe_decrypt.py --quick    without Docker, quicker

* test_scripts.py: tests of ../app/scripts/agent-check.sh and
  ../app/scripts/time-capsule.sh, the latter against a stand-in for
  docker.

The tests write only to new folders under $TMPDIR and remove them.

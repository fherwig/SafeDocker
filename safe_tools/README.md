This directory contains the tools

* bd: this is a wrapper for crypt.sh specifically managing decrypting
  and encrypting safe.txt. It opens safe.txt in emacs without backup
  or auto-save files, encrypts it again only if it was changed, and
  removes the plain text at the end.

* crypt.sh: this is a wrapper for openssl making sure we are saving
  the previous copy of safe.txt.crypt (as safe.txt.crypt.bak) and we
  are checking on the password to be correct as entered when
  encrypting. It deletes a file only after openssl has succeeded, and
  it never overwrites an existing file when decrypting.

They are built into the Docker image (make build) and installed in
/usr/local/bin, owned by root: inside the container they are on the
PATH and cannot be changed. After editing them, run make build again,
on every machine that uses the safe.

To read the previous version, decrypt a copy of the backup, and
delete old.txt when done:

    cp safe.txt.crypt.bak old.txt.crypt
    crypt.sh -d -r old.txt.crypt

The format is plain openssl, so the safe can also be opened without
these tools:

    openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in safe.txt.crypt -out safe.txt

These scripts are only executed inside the docker container "safe" as
an instance of safe:22.0

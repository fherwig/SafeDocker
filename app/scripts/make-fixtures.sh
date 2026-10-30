#!/bin/bash
# Regenerate the reference files in app/Fixtures (building plan 5.4, G5):
# files encrypted with known passwords by several implementations, and
# manifest.json, which lists for each file its password, the length and
# SHA-256 of its plaintext, the variant, the original name, the generator and
# the openssl enc options. docs/format.md describes the format.
#
#   make-fixtures.sh
#
# The generators:
#   openssl3  OpenSSL 3 in the Docker image fherwig/safe:22.0, run with --rm
#             --network none; RC4 through its legacy provider
#   cryptsh   crypt.sh in the same image, fed with printf "pw\npw\n"
#   libressl  macOS's /usr/bin/openssl (LibreSSL), which still has RC4
#   app       the app's own code (SafeCore), through the SafeTests program
#
# The plaintexts are made in a folder under /tmp and removed at the end. Each
# text and picture holds a random marker, safetest-marker- and 32 hex digits,
# that the leak test looks for; so no plaintext of a reference file is in the
# repository. Besides UTF-8 texts there are texts in ISO Latin-1, MacRoman and
# UTF-16, random bytes, a PDF, a PNG, a JPEG and a HEIC picture.
# Before the new files replace the old ones, every file is decrypted again
# with /usr/bin/openssl and the app's self-test runs over the new set.
#
# Needs Docker with the image (never pulled), /usr/bin/openssl, perl, iconv,
# swift, and a Mac whose ImageIO writes HEIC. The build goes to
# ~/Library/Caches/SafeDocker-build; set SAFE_SCRATCH_PATH to use another place.

set -euo pipefail

if [ $# -ne 0 ]
then
    sed -n '2,27s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
    exit 2
fi

appdir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixtures=$appdir/Fixtures
image=fherwig/safe:22.0
openssl=/usr/bin/openssl
current_opts="-aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt"

for tool in docker swift perl shasum od iconv "$openssl"
do
    if ! command -v "$tool" >/dev/null
    then
        echo "$tool is missing." >&2
        exit 1
    fi
done
if ! docker image inspect "$image" >/dev/null 2>&1
then
    echo "Docker is not running, or the image $image is missing (it is never pulled here)." >&2
    exit 1
fi

key=$(printf '%s' "$appdir" | shasum -a 256 | cut -c1-8)
scratch=${SAFE_SCRATCH_PATH:-$HOME/Library/Caches/SafeDocker-build/make-fixtures-$key}
case $scratch in
    "$appdir"|"$appdir"/*) echo "SAFE_SCRATCH_PATH must be outside $appdir." >&2; exit 1 ;;
esac

# the scratch folder: plain/ the plaintexts, out/ the new reference files
work=$(mktemp -d /tmp/safetest-fixtures.XXXXXX)
mkdir "$work/plain" "$work/out"
cleanup() {
    # the two subfolders first, so that only files are left in $work
    for dir in "$work/plain" "$work/out" "$work"
    do
        if [ -d "$dir" ]
        then
            (cd "$dir" && /bin/rm -f -- ./* ./.[!.]*)
            rmdir "$dir" || echo "Could not remove $dir; remove it by hand." >&2
        fi
    done
}
trap cleanup EXIT

echo "Building SafeTests in $scratch ...."
swift build --package-path "$appdir" --scratch-path "$scratch" --product SafeTests >/dev/null
safetests=$(swift build --package-path "$appdir" --scratch-path "$scratch" --show-bin-path)/SafeTests

# 1. the plaintexts
marker() {
    printf 'safetest-marker-%s' "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
}

plain=$work/plain
printf '%s\n' \
    "Safe reference file, made by make-fixtures.sh." \
    "Latin and German: café, naïve, Grüße, Straße." \
    "Greek and Cyrillic: αβγ δ, Привет. Japanese: 日本語. Emoji: 🔐 🗝." \
    "marker: $(marker)" > "$plain/notes.txt"
printf 'The last line has no newline at the end.' >> "$plain/notes.txt"

printf '%s\n' \
    "# Reference file" \
    "" \
    "Markdown is edited as plain text: *emphasis*, \`code\`, [a link](https://example.org)." \
    "" \
    "- one item, € 12,50" \
    "- marker: $(marker)" > "$plain/brief.md"

printf '%s\n' \
    "A text file without an ending, like safe." \
    "Tabs"$'\t'"and  spaces, quotes \" ' and a backslash \\." \
    "marker: $(marker)" > "$plain/README"

: > "$plain/empty.txt"

# 1 MiB of text, exactly 1048576 bytes
perl -e '
    my $m = shift;
    my $s = "marker: $m\n";
    my $i = 0;
    $s .= sprintf("line %06d of the 1 MiB reference file, plain ASCII text\n", ++$i) while length($s) < 1048576;
    print substr($s, 0, 1048576);
' "$(marker)" > "$plain/big.txt"

# random bytes of a type that cannot be checked; 4099 is not a whole number of
# AES blocks, so RC4 is the only variant that fits it
head -c 4096 /dev/urandom > "$plain/data.bin"
head -c 4099 /dev/urandom > "$plain/data-odd.bin"

# a one-page PDF with the marker in its text and title
perl -e '
    my ($out, $m) = @ARGV;
    my $text = "BT /F1 16 Tf 24 100 Td (Safe reference PDF) Tj 0 -28 Td ($m) Tj ET\n";
    my @obj = (
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 160] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length " . length($text) . " >>\nstream\n${text}endstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Title ($m) /Producer (make-fixtures.sh) >>",
    );
    my $pdf = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n";
    my @offsets;
    for my $i (0 .. $#obj) {
        push @offsets, length($pdf);
        $pdf .= ($i + 1) . " 0 obj\n$obj[$i]\nendobj\n";
    }
    my $xref = length($pdf);
    $pdf .= "xref\n0 " . (@obj + 1) . "\n0000000000 65535 f \n";
    $pdf .= sprintf("%010d 00000 n \n", $_) for @offsets;
    $pdf .= "trailer\n<< /Size " . (@obj + 1) . " /Root 1 0 R /Info 6 0 R >>\nstartxref\n$xref\n%%EOF\n";
    open(my $fh, ">:raw", $out) or die "$out: $!";
    print $fh $pdf;
    close($fh);
' "$plain/sample.pdf" "$(marker)"

# a 32 x 32 PNG with the marker in a tEXt chunk
perl -MCompress::Zlib -e '
    my ($out, $m) = @ARGV;
    my ($w, $h) = (32, 32);
    my $raw = "";
    for my $y (0 .. $h - 1) {
        $raw .= "\0";
        $raw .= pack("C3", $_ * 8, $y * 8, 128) for 0 .. $w - 1;
    }
    sub chunk { my ($t, $d) = @_; pack("N", length $d) . $t . $d . pack("N", crc32($t . $d)) }
    my $png = "\x89PNG\r\n\x1a\n" . chunk("IHDR", pack("NNC5", $w, $h, 8, 2, 0, 0, 0))
        . chunk("tEXt", "Comment\0$m") . chunk("IDAT", compress($raw)) . chunk("IEND", "");
    open(my $fh, ">:raw", $out) or die "$out: $!";
    print $fh $png;
    close($fh);
' "$plain/sample.png" "$(marker)"

# text in other encodings than UTF-8, which Safe opens without confirming the
# password (docs/format.md): ISO Latin-1, MacRoman in a file without an ending
# and without a line break at the end, UTF-16 with a byte order mark
printf '%s\n' \
    "Text in ISO Latin-1, not UTF-8: Grüße aus Köln, café, naïve." \
    "marker: $(marker)" | iconv -f UTF-8 -t ISO-8859-1 > "$plain/latin1.txt"
printf '%s\n%s' \
    "Text in MacRoman, without an ending: Café crème für Jürgen, 5 € Trinkgeld." \
    "marker: $(marker)" | iconv -f UTF-8 -t MACINTOSH > "$plain/macroman"
{
    printf '\377\376'
    printf '%s\r\n' "Name;Wert" "Äpfel;3" "marker;$(marker)" | iconv -f UTF-8 -t UTF-16LE
} > "$plain/table.csv"

# random bytes in a file without an ending: not text, so only the padding
# speaks for the password; 4000 bytes get 16 bytes of padding
head -c 4000 /dev/urandom > "$plain/blob"

# a JPEG and a HEIC picture of the PNG, with a marker in their EXIF description
for picture in jpeg:photo.jpg heic:photo.heic
do
    SAFETEST_FIXTURE_IN="$plain/sample.png" SAFETEST_FIXTURE_OUT="$plain/${picture#*:}" \
        SAFETEST_FIXTURE_TYPE="public.${picture%%:*}" SAFETEST_FIXTURE_MARKER="$(marker)" \
        "$safetests" --child fixtures/picture
done

# 2. the jobs: generator, variant, number, input, password, openssl enc options.
# Passwords must not hold tabs, double quotes or backslashes (they go into
# manifest.json as they are).
p1='safetest-pw-1'
p2='Grüße-Paßwort-日本-🔐'
p3='a b $HOME !x %s `q` ;&<>'
p4='çàé-ÉÈ-ñ-ü'

jobs=$work/jobs.tsv
: > "$jobs"
job() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$jobs"
}

job openssl3 current 1 notes.txt   "$p1" "$current_opts"
job openssl3 current 2 brief.md    "$p2" "$current_opts"
job openssl3 current 3 empty.txt   "$p1" "$current_opts"
job openssl3 current 4 big.txt     "$p1" "$current_opts"
job openssl3 current 5 sample.pdf  "$p3" "$current_opts"
job openssl3 current 6 sample.png  "$p4" "$current_opts"
job openssl3 current 7 README      "$p3" "$current_opts"
job openssl3 current 8 data.bin    "$p1" "$current_opts"
job openssl3 current 9 photo.jpg   "$p2" "$current_opts"
job openssl3 legacyAESSHA256 1 notes.txt  "$p1" "-aes-256-cbc -salt"
job openssl3 legacyAESSHA256 2 notes.txt  "$p2" "-aes-256-cbc -nosalt"
job openssl3 legacyAESSHA256 3 sample.png "$p1" "-aes-256-cbc -md sha256 -salt"
job openssl3 legacyAESMD5 1 notes.txt     "$p1" "-aes-256-cbc -md md5 -salt"
job openssl3 legacyAESMD5 2 brief.md      "$p2" "-aes-256-cbc -md md5 -nosalt"
job openssl3 legacyAESMD5 3 latin1.txt    "$p1" "-aes-256-cbc -md md5 -salt"
job openssl3 legacyRC4MD5 1 notes.txt     "$p1" "-rc4 -md md5 -salt"
job openssl3 legacyRC4MD5 2 table.csv     "$p2" "-rc4 -md md5 -salt"
job openssl3 legacyRC4SHA256 1 notes.txt  "$p1" "-rc4 -md sha256 -salt"

job cryptsh current 1 notes.txt  "$p1" "$current_opts"
job cryptsh current 2 brief.md   "$p2" "$current_opts"
job cryptsh current 3 sample.pdf "$p3" "$current_opts"
job cryptsh current 4 empty.txt  "$p4" "$current_opts"

job libressl current 1 notes.txt  "$p1" "$current_opts"
job libressl current 2 brief.md   "$p2" "$current_opts"
job libressl current 3 empty.txt  "$p1" "$current_opts"
job libressl current 4 sample.pdf "$p1" "$current_opts"
job libressl current 5 sample.png "$p2" "$current_opts"
job libressl current 6 README     "$p4" "$current_opts"
job libressl current 7 latin1.txt "$p1" "$current_opts"
job libressl current 8 photo.heic "$p4" "$current_opts"
job libressl current 9 table.csv  "$p2" "$current_opts"
job libressl legacyAESSHA256 1 notes.txt  "$p1" "-aes-256-cbc -salt"
job libressl legacyAESSHA256 2 notes.txt  "$p1" "-aes-256-cbc -nosalt"
job libressl legacyAESSHA256 3 latin1.txt "$p1" "-aes-256-cbc -salt"
job libressl legacyAESSHA256 4 macroman   "$p2" "-aes-256-cbc -salt"
job libressl legacyAESSHA256 5 table.csv  "$p1" "-aes-256-cbc -nosalt"
job libressl legacyAESSHA256 6 blob       "$p4" "-aes-256-cbc -salt"
job libressl legacyAESMD5 1 notes.txt     "$p2" "-aes-256-cbc -md md5 -salt"
job libressl legacyAESMD5 2 notes.txt     "$p1" "-aes-256-cbc -md md5 -nosalt"
job libressl legacyAESMD5 3 sample.pdf    "$p1" "-aes-256-cbc -md md5 -salt"
job libressl legacyAESMD5 4 data.bin      "$p1" "-aes-256-cbc -md md5 -salt"
job libressl legacyAESMD5 5 latin1.txt    "$p2" "-aes-256-cbc -md md5 -nosalt"
job libressl legacyAESMD5 6 macroman      "$p1" "-aes-256-cbc -md md5 -nosalt"
job libressl legacyAESMD5 7 table.csv     "$p4" "-aes-256-cbc -md md5 -salt"
job libressl legacyAESMD5 8 blob          "$p1" "-aes-256-cbc -md md5 -nosalt"
job libressl legacyRC4MD5 1 notes.txt     "$p1" "-rc4 -md md5 -salt"
job libressl legacyRC4MD5 2 brief.md      "$p2" "-rc4 -md md5 -nosalt"
job libressl legacyRC4MD5 3 sample.pdf    "$p1" "-rc4 -md md5 -salt"
job libressl legacyRC4MD5 4 data-odd.bin  "$p3" "-rc4 -md md5 -salt"
job libressl legacyRC4MD5 5 latin1.txt    "$p1" "-rc4 -md md5 -salt"
job libressl legacyRC4MD5 6 macroman      "$p4" "-rc4 -md md5 -nosalt"
job libressl legacyRC4MD5 7 table.csv     "$p1" "-rc4 -md md5 -nosalt"
job libressl legacyRC4SHA256 1 notes.txt  "$p1" "-rc4 -md sha256 -salt"
job libressl legacyRC4SHA256 2 brief.md   "$p2" "-rc4 -md sha256 -nosalt"

job app current 1 notes.txt  "$p1" "$current_opts"
job app current 2 brief.md   "$p2" "$current_opts"
job app current 3 empty.txt  "$p1" "$current_opts"
job app current 4 sample.png "$p3" "$current_opts"
job app current 5 photo.jpg  "$p1" "$current_opts"

# 3. run them. In the container, OpenSSL 3 needs its legacy provider for RC4.
cat > "$work/docker-jobs.sh" <<'EOF'
set -eu
cd /work/plain
while IFS=$'\t' read -r gen variant n input pw opts
do
    out=/work/out/$gen-$variant-$n.enc
    case $gen in
        openssl3)
            case $opts in
                -rc4*) opts="$opts -provider legacy -provider default" ;;
            esac
            printf '%s\n' "$pw" | openssl enc -e $opts -pass stdin -in "$input" -out "$out" 2>/dev/null \
                || { echo "openssl failed to make $out" >&2; exit 1; }
            ;;
        cryptsh)
            printf '%s\n%s\n' "$pw" "$pw" | crypt.sh -e "$input" >/dev/null 2>&1 \
                || { echo "crypt.sh failed to make $out" >&2; exit 1; }
            mv "$input.crypt" "$out"
            ;;
    esac
done < /work/jobs.tsv
openssl version | awk '{print $2}' > /work/out/.openssl-version
crypt.sh -v | awk '{print $2}' | tr -d , > /work/out/.cryptsh-version
EOF

echo "Encrypting with OpenSSL 3 and crypt.sh in $image ...."
docker run --rm --pull never --network none --name "safetest-fixtures-$$" \
    -v "$work:/work" "$image" bash /work/docker-jobs.sh

echo "Encrypting with $openssl and the app ...."
while IFS=$'\t' read -r gen variant n input pw opts
do
    out=$work/out/$gen-$variant-$n.enc
    case $gen in
        libressl)
            printf '%s\n' "$pw" | "$openssl" enc -e $opts -pass stdin -in "$plain/$input" -out "$out" 2>/dev/null \
                || { echo "$openssl failed to make $out" >&2; exit 1; }
            ;;
        app)
            printf '%s\n' "$pw" | SAFETEST_FIXTURE_IN="$plain/$input" SAFETEST_FIXTURE_OUT="$out" \
                "$safetests" --child fixtures/encrypt
            ;;
    esac
done < "$jobs"

openssl3_version=$(cat "$work/out/.openssl-version")
cryptsh_version=$(cat "$work/out/.cryptsh-version")
libressl_version=$("$openssl" version | awk '{print $2}')
app_version=$(tr -d '[:space:]' < "$appdir/VERSION")

# 4. check every file with LibreSSL, which reads all the variants, and write
# manifest.json
manifest=$work/out/manifest.json
{
    echo '{'
    echo '  "format": "see docs/format.md; made by app/scripts/make-fixtures.sh",'
    echo '  "files": ['
} > "$manifest"
first=1
while IFS=$'\t' read -r gen variant n input pw opts
do
    file=$gen-$variant-$n.enc
    case $pw in
        *'"'*|*'\'*) echo "The password of $file holds a double quote or a backslash." >&2; exit 1 ;;
    esac
    case $gen in
        openssl3) generator="Debian OpenSSL $openssl3_version" ;;
        cryptsh)  generator="crypt.sh $cryptsh_version (Debian OpenSSL $openssl3_version)" ;;
        libressl) generator="macOS LibreSSL $libressl_version" ;;
        app)      generator="Safe.app SafeCore $app_version" ;;
    esac
    case $opts in
        *-nosalt*) salted=false ;;
        *) salted=true ;;
    esac
    sha=$(shasum -a 256 < "$plain/$input" | cut -c1-64)
    length=$(wc -c < "$plain/$input" | tr -d ' ')
    check=$(printf '%s\n' "$pw" | "$openssl" enc -d $opts -pass stdin -in "$work/out/$file" 2>/dev/null \
        | shasum -a 256 | cut -c1-64)
    if [ "$check" != "$sha" ]
    then
        echo "$file does not decrypt to $input with $openssl." >&2
        exit 1
    fi
    if [ $first = 0 ]
    then
        echo ',' >> "$manifest"
    fi
    first=0
    printf '    {"file": "%s", "generator": "%s", "variant": "%s", "salted": %s, "options": "%s",\n     "originalName": "%s", "password": "%s", "length": %s, "sha256": "%s"}' \
        "$file" "$generator" "$variant" "$salted" "$opts" "$input" "$pw" "$length" "$sha" >> "$manifest"
done < "$jobs"
{
    echo
    echo '  ]'
    echo '}'
} >> "$manifest"
/bin/rm -f "$work/out/.openssl-version" "$work/out/.cryptsh-version"

# 5. the app's self-test over the new set, with the network denied as in the app
echo "Running the self-test over the new files ...."
if ! SAFETEST_FIXTURES="$work/out" "$safetests" --child selftest/run-enforced
then
    echo "The self-test failed over the new files; app/Fixtures was not changed." >&2
    echo "A file of a type that cannot be checked may have passed with a wrong variant; run again." >&2
    exit 1
fi

# 6. replace the old reference files
mkdir -p "$fixtures"
(cd "$fixtures" && /bin/rm -f ./*.enc ./manifest.json)
cp "$work/out/"*.enc "$work/out/manifest.json" "$fixtures/"
# crypt.sh writes mode 0600; the reference files are not secret
chmod 644 "$fixtures/"*.enc "$fixtures/manifest.json"
echo "Wrote $(ls "$fixtures" | grep -c '\.enc$') reference files and manifest.json to $fixtures"

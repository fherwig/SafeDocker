# Safe-Hilfe

Safe hält Dateien verschlüsselt und lässt dich mit ihnen arbeiten, ohne eine lesbare Kopie auf dem Datenträger zu hinterlassen. Diese Hilfe ist auch eine Datei im Quellcode von Safe, `app/Resources/SafeHelp.de.md`, die jeder Texteditor öffnen kann. Die englische Fassung ist `app/Resources/SafeHelp.md`.

## Die Idee hinter Safe {#idea}

### Zwei Arten von Schutz

Safe schützt deine Dateien auf zwei Arten.

- **Verschlüsselte Dateien.** Eine Datei wird für sich allein verschlüsselt. Aus `report.pdf` wird `report.pdf.crypt`, und nur ihr Passwort öffnet sie. Das passt für einzelne Dokumente: eine Liste mit Passwörtern, einen gescannten Reisepass, einen Vertrag.
- **Verschlüsselte Volumes.** Ein Volume ist ein verschlüsseltes Disk-Image: ein einziges Objekt im Finder, das viele Dateien und Ordner enthält. Wenn du es mit seinem Passwort öffnest, erscheint es im Finder wie ein USB-Stick, und du verwendest seine Dateien wie gewohnt. Das passt für einen ganzen Ordner, ein Projekt oder eine Fotosammlung.

Du kannst beides kombinieren. Eine einzeln verschlüsselte Datei, die in einem Volume liegt, braucht beide Passwörter.

### Entschlüsselte Inhalte bleiben im Arbeitsspeicher

Wenn Safe eine verschlüsselte Datei öffnet, gibt es den Text, das PDF oder das Bild nur im Arbeitsspeicher von Safe, in seinem Fenster. Beim Öffnen, Bearbeiten, Sichern und Ansehen wird nie eine lesbare Kopie auf den Datenträger geschrieben, nicht einmal für einen Moment. Beim Sichern werden nur verschlüsselte Daten geschrieben. Wenn du das Fenster schließt, vergisst Safe den Inhalt und das Passwort.

Der Grund: Eine gelöschte Datei ist nicht wirklich weg. Auf der SSD eines modernen Mac können die Blöcke einer gelöschten Datei lesbar bleiben, bis sie zufällig überschrieben werden. In einem verschlüsselten Disk-Image ließe sich eine gelöschte Datei im Image noch finden (das wurde getestet, als Safe gebaut wurde). Eine unverschlüsselte Kopie, die „nur für einen Moment“ geschrieben wird, bliebe also zurück. Safe legt deshalb keine an.

Die einzige Ausnahme ist **Exportieren**. Es schreibt eine normale, unverschlüsselte Kopie an einen Ort, den du wählst, mit Absicht und nach einer Warnung.

### Standardformate, die Safe überdauern

Safe verwendet Formate, die dokumentiert sind und die andere Programme lesen. So bleiben deine Dateien jahrzehntelang lesbar, mit oder ohne Safe.

- Eine verschlüsselte Datei hat das Format von `openssl`, einem Programm, das auf jedem Mac vorhanden ist: AES-256, wobei das Passwort mit PBKDF2-HMAC-SHA512 über 100.000 Runden gestreckt wird. Das Terminal jedes Mac kann sie entschlüsseln. Das können auch `tools/safe-decrypt.py` aus dem Quellcode von Safe, das nur Python 3 braucht, das Docker-Image `fherwig/safe:22.0` und das ältere Terminal-Werkzeug `crypt.sh`. Die Befehle stehen im Abschnitt „Alte Dateien und die Zukunft“.
- Ein Volume ist ein verschlüsseltes Disk-Image in Apples eigenem Format (AES-256). Jeder Mac öffnet es mit einem Doppelklick und dem Passwort, ohne Safe.

### Überhaupt kein Netzwerk

Als Erstes schaltet Safe beim Start seinen eigenen Netzwerkzugang ab. Es kann nichts irgendwohin senden: keine Suche nach Updates, keine Statistik, keine Online-Hilfe. Diese Hilfe ist Teil der App.

### Automatisches Sperren

Nach 10 Minuten ohne jede Eingabe am Mac, und wenn der Mac in den Ruhezustand wechselt oder der Bildschirm gesperrt wird, blendet Safe aus oder schließt, was es zeigt, und schließt die Volumes, die es geöffnet hat. Der Abschnitt „Sperren“ beschreibt, was mit jeder Art von Fenster geschieht.

### Keine Wiederherstellung von Passwörtern

Niemand kann ein verlorenes Passwort wiederherstellen: nicht Safe, nicht die Person, die Safe installiert hat, nicht Apple. Die Verschlüsselung hat keine Hintertür. **Wenn du das Passwort verlierst, ist die Datei oder das Volume verloren.** Bewahre deine Passwörter sicher auf, zum Beispiel auf Papier an einem sicheren Ort oder in einem Passwort-Manager, dem du vertraust.

Zum Installieren, Aktualisieren oder Entfernen von Safe braucht niemand deine Passwörter: weder das Installationsprogramm noch die Person oder der KI-Agent, die Safe installiert haben. Wenn Safe entfernt wird, werden deine verschlüsselten Dateien und Volumes nie gelöscht.

### Wogegen Safe nicht schützt

Safe schützt Dateien, solange sie verschlüsselt sind. Gegen alles kann es nicht schützen. Beachte diese Grenzen:

- **Schadsoftware oder jemand, der dein angemeldetes Benutzerkonto verwendet.** Während eine Datei in Safe geöffnet ist oder ein Volume geöffnet ist, kann ein Programm, das unter deinem Benutzerkonto läuft, sie lesen, ebenso eine Person an deinem entsperrten Mac. Wer zusieht, kann auch das Passwort sehen, das du eingibst. Sperre den Bildschirm, wenn du den Mac verlässt (Control-Befehl-Q).
- **Kopien, die vor dem Verschlüsseln entstanden sind.** Beim Verschlüsseln wird das Original gelöscht, aber ältere unverschlüsselte Kopien können anderswo noch vorhanden sein: im Papierkorb und in der Versionsgeschichte eines Sync-Dienstes wie Nextcloud, Dropbox oder iCloud Drive, in Time Machine-Backups und lokalen Schnappschüssen, im Spotlight-Index und in den Vorschaubildern von Übersicht (den Miniaturen, die der Finder erstellt). Auf einer SSD kann das gelöschte Original eine Weile lesbar bleiben. FileVault, die eigene Festplattenverschlüsselung des Mac, schützt diese Kopien auf dem Mac selbst. Schalte es ein unter Systemeinstellungen > Datenschutz & Sicherheit > FileVault.
- **Bildschirmfotos und Kameras.** Safe hält die Fenster mit entschlüsselten Inhalten aus den meisten Bildschirmfotos und Bildschirmfreigaben heraus. Das gelingt aber nicht in jedem Fall, und gegen eine Kamera, die auf den Bildschirm gerichtet ist, hilft es nicht.
- **Kopien, die du absichtlich exportierst.** Eine exportierte Kopie ist eine normale Datei. Lösche sie, wenn du sie nicht mehr brauchst.
- **Ein Volume, solange es geöffnet ist.** Ein geöffnetes Volume ist für jede App, die du verwendest, ein normaler Ordner. Jede von ihnen kann seine Dateien lesen, anderswohin kopieren oder hochladen. Schließe ein Volume, wenn du damit fertig bist.
- **Der Verlauf der Zwischenablage.** Manche Versionen von macOS speichern einen Verlauf dessen, was du kopierst (Spotlight unter macOS 26). Safe kann ihn nicht leeren. Was Safe tut, erklärt der Abschnitt „Eine Textdatei öffnen und bearbeiten“.

## Passwörter {#passwords}

### Ein neues Passwort wählen

Wenn du eine Datei verschlüsselst oder ein Volume erstellst, fragt Safe zweimal nach dem neuen Passwort. Beide Eingaben müssen gleich sein, damit dich ein Tippfehler nicht aussperren kann. Ein langes Passwort aus mehreren Wörtern ist leichter zu merken und schwerer zu erraten als ein kurzes mit Sonderzeichen, zum Beispiel `garten-geige-sieben-hafen`.

Safe lehnt ein neues Passwort ab, das:

- leer ist;
- einen Zeilenumbruch oder ein anderes Steuerzeichen wie einen Tabulator enthält. Solche Zeichen kommen meist beim Einsetzen hinein. `openssl` liest ein Passwort nur bis zu einem Zeilenumbruch, deshalb ließe sich eine Datei mit einem solchen Passwort dort nicht öffnen;
- länger als 511 Byte ist, das Maximum, das `openssl` annimmt.

Wenn das Passwort Buchstaben einer anderen als der lateinischen Schrift enthält (Griechisch, Kyrillisch, Chinesisch und andere) oder Emoji, warnt Safe dich vorher. Passwortfelder auf dem Mac nehmen nur lateinische Tastaturlayouts an und keine Emoji. Du müsstest ein solches Passwort also jedes Mal einsetzen. Wenn du es trotzdem verwenden willst, gib es noch einmal zweimal ein oder setze es noch einmal zweimal ein. Buchstaben mit Akzenten, etwa die deutschen ä, ö, ü und ß, sind lateinische Buchstaben: Du tippst sie wie gewohnt auf einem deutschen oder jedem anderen lateinischen Tastaturlayout.

Groß- und Kleinbuchstaben zählen: `Garten` und `garten` sind verschiedene Passwörter.

### Ein Passwort zum Öffnen eingeben

Safe fragt einmal. Wenn das Passwort falsch ist, sagt Safe das und fragt erneut. Ein Zeilenumbruch am Ende eines eingesetzten Passworts wird ignoriert, weil kein Passwort mit einem Zeilenumbruch enden kann.

### Wo Passwörter aufbewahrt werden

Solange eine Datei geöffnet ist, behält Safe ihr Passwort im Arbeitsspeicher, damit Befehl-S sichern kann, ohne erneut zu fragen. Es liegt in einem Teil des Arbeitsspeichers, der nie in die Auslagerungsdatei geschrieben wird, und wird gelöscht, wenn du das Fenster schließt. Safe schreibt nie ein Passwort auf den Datenträger. Bei Volumes gibt Safe das Passwort direkt an das Disk-Image-Werkzeug von macOS weiter und vergisst es.

Es gibt keine Wiederherstellung von Passwörtern. Warum, erklärt der Abschnitt „Die Idee hinter Safe“.

## Eine Datei verschlüsseln {#encrypting}

### Im Finder

1. Wähle im Finder eine oder mehrere Dateien aus.
2. Klicke mit der rechten Maustaste (oder bei gedrückter Control-Taste) darauf und wähle **Mit Safe verschlüsseln**. Je nach macOS-Version und den Einstellungen des Finder findest du den Befehl unter **Schnellaktionen** oder unter **Dienste**.
3. Gib zweimal ein neues Passwort ein und klicke auf „OK“.

Du kannst auch in Safe **Ablage > Datei verschlüsseln …** (Umschalt-Befehl-E) wählen und die Dateien dort auswählen.

### Was mit dem Original geschieht

Safe schreibt die verschlüsselte Kopie neben das Original und hängt `.crypt` an den Namen an: Aus `report.pdf` wird `report.pdf.crypt`. Dann liest Safe die verschlüsselte Kopie zurück, entschlüsselt sie und vergleicht das Ergebnis mit dem Original. Nur wenn beide gleich sind, löscht es das Original. Wenn etwas schiefgeht, bleibt das Original, wo es war, und Safe sagt es dir.

Nur der Inhalt der Datei wird verschlüsselt. Finder-Tags und Kommentare bleiben nicht erhalten.

Beim ersten Verschlüsseln erinnert dich Safe einmal daran, welche älteren unverschlüsselten Kopien übrig bleiben können (Abschnitt „Die Idee hinter Safe“). Bei einer Datei in einem synchronisierten Ordner sagt es, dass der Sync-Dienst eine unverschlüsselte Kopie in seinem Papierkorb und seiner Versionsgeschichte behält (Nextcloud standardmäßig 30 Tage lang). Bei einer Datei in einem geöffneten Volume sagt es, dass das gelöschte Original im Image des Volumes für alle lesbar bleibt, die das Passwort des Volumes haben: Verschlüssele Dateien, bevor du sie in ein Volume bewegst.

### Mehrere Dateien auf einmal

Wähle mehrere Dateien aus und wähle einmal „Mit Safe verschlüsseln“. Safe fragt nach einem Passwort, verwendet es für alle Dateien und verschlüsselt jede in eine eigene `.crypt`-Datei. Am Ende listet es jede Datei auf, die es nicht verschlüsselt hat, mit dem Grund. Diese Originale bleiben erhalten.

### Was Safe ablehnt

- **Ordner.** Erstelle stattdessen aus dem Ordner ein verschlüsseltes Volume (Abschnitt „Volumes“).
- **Verschlüsselte Disk-Images und Sparse-Bundles.** Füge sie mit „Vorhandenes hinzufügen“ zum Fenster „Volumes“ hinzu. Ein unverschlüsseltes Disk-Image aus einer einzigen Datei (`.dmg`) wird wie jede andere Datei verschlüsselt.
- **Dateien, die schon verschlüsselt sind** (`.crypt`), und Dateien, zu denen es `NAME.crypt` schon gibt.
- **Dateien, die größer als 1 GB sind.** Zum Verschlüsseln braucht Safe mehrere Kopien im Arbeitsspeicher. Lege große Dateien in ein Volume.
- **Dateien mit einem zweiten Namen** (einem harten Link). Wenn das Original gelöscht wird, wäre der Inhalt nicht entfernt. Er bliebe unter dem anderen Namen lesbar.
- **Dateien mit einem Resource Fork**, einer alten Mac-Methode, zusätzliche Daten zu speichern, die die `.crypt`-Datei nicht behalten könnte.

Beim Start prüft Safe zuerst seine eigene Verschlüsselung (der Selbsttest, Abschnitt „Alte Dateien und die Zukunft“). Das Verschlüsseln wartet, bis diese Prüfung bestanden ist. Das dauert ein paar Sekunden.

## Eine Textdatei öffnen und bearbeiten {#editing}

### Öffnen

Doppelklicke im Finder auf eine `.crypt`-Datei, oder klicke mit der rechten Maustaste darauf und wähle **Mit Safe öffnen**, oder wähle in Safe **Ablage > Öffnen …** (Befehl-O). Gib das Passwort ein. Was dann geschieht, hängt von der Datei ab:

- **Text** wird im Editor von Safe geöffnet;
- **PDFs und Bilder** werden im Viewer von Safe geöffnet (Abschnitt „PDFs und Bilder ansehen und exportieren“);
- **andere Dateien**, etwa ein Word-Dokument oder ein Zip-Archiv, kann Safe nicht anzeigen. Safe bietet an, sie zu exportieren.

Eine Datei gilt als Text, wenn ihr Name auf `.txt`, `.md`, `.markdown`, `.csv`, `.json`, `.yaml`, `.yml`, `.xml`, `.tex` oder `.log` endet oder gar keine Endung hat, und wenn ihr Inhalt Text ist. Wenn die Datei schon geöffnet ist, holt Safe ihr Fenster nach vorne.

Der Titel des Fensters ist der ursprüngliche Name der Datei, darunter steht der Ordner, in dem sie liegt. Die Zeile unten im Fenster beginnt mit „Nur im Arbeitsspeicher entschlüsselt.“

### Sichern

Befehl-S sichert, ohne erneut nach dem Passwort zu fragen. Safe verschlüsselt den Text, schreibt ihn in eine neue Datei, liest diese zurück und prüft sie, behält die vorherige Version als `NAME.crypt.bak` und setzt erst dann die neue Version an ihre Stelle. Die Zeile unten sagt dann zum Beispiel: „Gesichert um 14:05, die vorherige Version bleibt als notes.txt.crypt.bak erhalten.“

Die `.bak`-Datei ist mit demselben Passwort verschlüsselt und lässt sich wie jede andere `.crypt`-Datei öffnen. Bei jedem Sichern wird sie durch die jeweils vorherige Version ersetzt.

### Schließen

Schließe das Fenster mit Befehl-W. Wenn es ungesicherte Änderungen gibt, fragt Safe, ob du sie sichern willst: „Sichern“, „Nicht sichern“ (Befehl-D) oder „Abbrechen“. Beim Schließen werden der Text, der Verlauf zum Widerrufen und das Passwort aus dem Arbeitsspeicher entfernt.

### Suchen

Befehl-F blendet über dem Text ein Suchfeld ein. Tippe etwas ein, um den ersten Treffer zu finden. Der Zeilenschalter findet den nächsten, Umschalt-Zeilenschalter den vorherigen. Befehl-G und Umschalt-Befehl-G tun dasselbe von überall im Fenster. Die esc-Taste oder „Fertig“ blendet das Feld aus. Die Suche unterscheidet nicht zwischen Groß- und Kleinbuchstaben und macht nach dem Ende oben weiter. Was du suchst, bleibt in diesem Fenster: Safe teilt es nicht mit der Suche anderer Apps.

### Wenn die Datei anderswo geändert wurde

Wenn ein anderes Programm oder ein anderer Mac die Datei geändert hat, nachdem du sie geöffnet hast, überschreibt Befehl-S diese Version nicht. Safe fragt, was geschehen soll:

- **Meine Version als Kopie behalten** sichert deinen Text als eigene verschlüsselte Datei daneben, zum Beispiel `notes (conflict 2026-10-25 14-05).txt.crypt`, mit demselben Passwort.
- **Meine Änderungen verwerfen** lädt die Datei so, wie sie jetzt ist.
- **Abbrechen** lässt deinen Text im Fenster und ändert nichts.

Wenn der Ordner der Datei verschwunden ist, meist weil das Volume, in dem sie lag, geschlossen wurde, sagt Safe das. Öffne das Volume wieder und sichere dann. Wenn Safe selbst das Volume beim Sperren geschlossen hat, bietet es **„NAME“ wieder öffnen** an.

### „Safe konnte das Passwort nicht bestätigen“

Ein falsches Passwort ergibt manchmal etwas, das wie eine Datei aussieht. Safe prüft, ob das Entschlüsselte so aussieht wie die Art von Datei, die ihr Name angibt. Meist bestätigt diese Prüfung das Passwort. Manche echten Dateien bestehen sie nicht, zum Beispiel ein Text, der unter Windows in einer älteren Codierung (ISO Latin-1) oder in UTF-16 geschrieben wurde. Dann kann Safe ein richtiges Passwort nicht von einem falschen unterscheiden und fragt dich:

- **Schreibgeschützt öffnen** zeigt den Text, ohne dass du ihn ändern kannst. Ein gelber Hinweis oben sagt, dass Safe das Passwort nicht bestätigen konnte. Wenn der Text so aussieht, wie du ihn erwartest, ist das Passwort richtig: Klicke auf **Bearbeitung zulassen**. Wenn er unleserlich ist, schließe das Fenster und öffne die Datei erneut mit dem richtigen Passwort.
- **Anderes Passwort eingeben** fragt erneut.
- **Abbrechen** bricht ab.

Bei einer solchen Datei behält das erste Sichern die Datei, wie sie war, in `NAME.crypt.bak`. Spätere Sicherungen im selben Fenster behalten diese `.bak`-Datei. So können zwei Sicherungen nicht sowohl die Datei als auch ihre Sicherungskopie ersetzen, falls das Passwort doch falsch war.

Wenn gar kein Text herauskommt, sagt Safe: **Das Passwort ist wahrscheinlich falsch**, und bietet „Erneut eingeben“, „Trotzdem exportieren“ und „Abbrechen“ an.

### Codierungen

Die meisten Texte sind in UTF-8. Safe liest auch UTF-8 mit Byte-Order-Mark (so schreibt es der Windows-Editor Notepad), UTF-16 und ISO Latin-1. Es zeigt die Codierung in der Zeile unten an und schreibt den Text in derselben Codierung zurück. Wenn du ein Zeichen hinzufügst, das ISO Latin-1 nicht enthält, etwa das Euro-Zeichen, bietet Safe an, den Text stattdessen in UTF-8 zu sichern.

### Die Zwischenablage

Was du in Safe kopierst oder ausschneidest, ist nur für diesen Mac gedacht:

- es wird nicht an dein iPhone oder iPad gesendet (Universelle Zwischenablage);
- es ist als verborgen markiert, und Programme zur Verwaltung der Zwischenablage, die diese Markierung beachten, lassen es weg;
- Safe leert die Zwischenablage nach einer Minute, beim Sperren und beim Beenden, wenn sie noch enthält, was Safe hineingelegt hat.

Wenn macOS einen Verlauf der Zwischenablage speichert (Spotlight unter macOS 26), kann Safe diesen Verlauf nicht leeren. Safe fragt deshalb bei jedem Start vor dem ersten Kopieren nach. Du kannst den Verlauf unter Systemeinstellungen > Spotlight ausschalten.

### Was der Editor weglässt, und warum

Der Editor von Safe ist absichtlich schlicht. Er hat keine Rechtschreibprüfung, keine Grammatikprüfung, keine Autokorrektur, keine Textvervollständigung, keine typografischen Anführungszeichen, keine Schreibtools, kein Nachschlagen, keine Dienste, kein Teilen, kein Drucken, kein Ziehen von ausgewähltem Text in andere Apps und kein automatisches Sichern von Versionen. Jede dieser Funktionen gibt deinen Text an einen anderen Teil von macOS oder an eine andere App weiter, die ihn behalten, auf den Datenträger schreiben oder über das Netzwerk senden kann. Deshalb hat die Menüleiste keine Einträge für Rechtschreibung, Ersetzungen, Sprachausgabe oder Schreibtools.

Aus demselben Grund löscht Control-K bis zum Ende der Zeile, behält das Gelöschte aber nicht, und Control-Y setzt nichts ein: Sonst würde macOS den gelöschten Text in einem Zwischenspeicher behalten, aus dem jedes Textfeld einsetzen kann.

Markdown wird als reiner Text bearbeitet.

## PDFs und Bilder ansehen und exportieren {#viewing}

### Der Viewer

PDFs und Bilder (PNG, JPEG, HEIC, GIF, TIFF, WebP, BMP, AVIF) werden im Viewer von Safe geöffnet, nur aus dem Arbeitsspeicher. Der Viewer ist schreibgeschützt.

- **Vergrößern** (Befehl-Plus), **Verkleinern** (Befehl-Minus), **Originalgröße** (Wahl-Befehl-0) und **Größe an Fenster anpassen** (Befehl-9) findest du im Menü „Darstellung“.
- Bei einem PDF stehen dort auch **Nächste Seite** (Wahl-Befehl-Abwärtspfeil) und **Vorherige Seite** (Wahl-Befehl-Aufwärtspfeil). Scrollen funktioniert wie gewohnt.
- Du kannst in einem PDF Text auswählen und kopieren. Es gelten die Regeln des Editors für die Zwischenablage.
- Links in einem PDF bewirken nichts, und Drucken wird nicht angeboten: Beides würde den Inhalt an andere Programme weitergeben.
- Ein PDF mit einem eigenen Passwort zeigt **PDF entsperren …**. Gib das Passwort dieses PDFs ein.
- **Schließen** oder die esc-Taste schließt den Viewer und vergisst den Inhalt.

### Exportieren

**Exportieren …** (Wahl-Befehl-E) schreibt eine normale, **unverschlüsselte** Kopie der Datei, um sie in einer anderen App zu verwenden oder jemandem zu schicken. Du findest den Befehl im Viewer, im Menü „Ablage“ des Editors und im Finder: Klicke mit der rechten Maustaste auf eine `.crypt`-Datei und wähle **Mit Safe exportieren**.

1. Ein Dialog zum Sichern schlägt den ursprünglichen Namen vor, im Ordner der verschlüsselten Datei. Bei einer Datei in einem geöffneten Volume schlägt er stattdessen den Schreibtisch vor, weil eine Kopie, die in einem Volume gelöscht wird, im Image des Volumes lesbar bleibt.
2. Safe warnt, dass die exportierte Kopie nicht verschlüsselt ist, und sagt, wohin sie kommt. Alle, die diesen Ordner lesen können, können sie lesen, und ein Sync-Dienst lädt sie vielleicht hoch.
3. Klicke auf „Exportieren“, um die Kopie zu schreiben, oder auf „Abbrechen“, um nichts zu schreiben.

Lösche eine exportierte Kopie, wenn du sie nicht mehr brauchst, und leere den Papierkorb. Denk daran, dass die App, mit der du sie öffnest, eigene Kopien behalten kann (zuletzt benutzte Dateien, automatische Versionen, Vorschauen).

Safe exportiert nicht über die verschlüsselte Datei selbst und nicht unter einem Namen, der auf `.crypt` oder `.crypt.bak` endet. Während Safe schreibt, heißt die Kopie `NAME (exporting XXXXXXXX).tmp`. Wenn der Mac während eines Exports keinen Strom mehr hatte, ist diese Datei eine unverschlüsselte Kopie, die du löschen solltest.

### Eine alte Datei im aktuellen Format sichern

Bei einer Datei in einem älteren Format (Abschnitt „Alte Dateien und die Zukunft“) bietet der Viewer **Im aktuellen Format sichern** an. Damit wird derselbe Inhalt im heutigen Format neu verschlüsselt, mit demselben Passwort, und die alte Datei bleibt als `NAME.crypt.bak` erhalten.

## Volumes {#volumes}

### Was ein Volume ist

Ein Volume ist ein verschlüsseltes Disk-Image im Standardformat von Apple, mit AES-256 verschlüsselt. Safe erstellt Volumes als **Sparse-Bundles**: Sie wachsen, wenn du Dateien hinzufügst, bis zu einer Maximalgröße, die du wählst. Sie werden als viele kleine Teile gespeichert, sodass ein Sync-Dienst nur die Teile hochlädt, die sich geändert haben. Geöffnet erscheint ein Volume im Finder wie ein Laufwerk, und du verwendest seine Dateien wie gewohnt. Geschlossen ist es ein einziges Objekt im Finder (zum Beispiel `Private.sparsebundle`), das niemand ohne das Passwort lesen kann.

### Das Fenster „Volumes“

Das Fenster „Volumes“ listet deine Volumes mit Name, Ort und Status auf: Geöffnet, Geschlossen oder Nicht gefunden (an diesem Ort ist nichts mehr). Es erscheint beim Start von Safe, und Fenster > Volumes (Befehl-0) holt es zurück. Die Schaltflächen gibt es auch im Menü **Volume**, das die Tastaturkurzbefehle hat.

Wähle ein Volume in der Liste aus, um „Öffnen“, „Schließen“, „Passwort ändern“ und „Aus Liste entfernen“ zu verwenden. Doppelklicke auf ein Volume oder drücke den Zeilenschalter, um es zu öffnen.

### Leeres Volume (Befehl-N)

Safe fragt nach einem Namen und einer Maximalgröße (1 GB, wenn du nichts änderst; schreibe zum Beispiel `500 MB`, `2 GB` oder `1 TB`), dann, wo das Volume gesichert werden soll, und dann zweimal nach einem neuen Passwort. Das neue Volume wird zur Liste hinzugefügt.

### Aus Ordner (Umschalt-Befehl-N)

Damit wird ein vorhandener Ordner zu einem Volume.

1. Wähle den Ordner.
2. Wähle, wo das neue Volume gesichert werden soll (nicht in dem Ordner).
3. Gib zweimal ein neues Passwort ein.

Safe kopiert den Ordner in das neue Volume und vergleicht dann jede Datei im Volume mit dem Ordner. **Nur wenn sie übereinstimmen, löscht es den Ordner.** Wenn die Prüfung fehlschlägt oder etwas den Ordner inzwischen verändert hat, bleibt der Ordner erhalten, und Safe sagt dir, wo das neue Volume ist.

Safe lehnt deinen Benutzerordner ab und die Ordner, die ihn enthalten, ebenso Ordner der obersten Ebene, ganze Laufwerke, Ordner, in die ein Laufwerk eingebunden ist, und Ordner mit einer Datei, die außerhalb des Ordners einen zweiten Namen (einen harten Link) hat.

Reste des gelöschten Ordners können zurückbleiben, und Safe sagt dir das einmal: Auf einer SSD können die gelöschten Dateien eine Weile lesbar bleiben; Vorschaubilder von Übersicht und der Spotlight-Index können Kopien außerhalb des Volumes behalten, die FileVault schützt; ein Sync-Dienst behält von einem synchronisierten Ordner unverschlüsselte Kopien in seinem Papierkorb und seiner Versionsgeschichte; Time Machine behält ältere Kopien.

Das Löschen eines großen Ordners kann eine Weile dauern. Wird Safe während des Löschens gestoppt, fragt es beim nächsten Start, ob es den Rest löschen soll: „Löschen“, „Im Finder anzeigen“ oder „Nicht jetzt“.

### Öffnen (Befehl-Zeilenschalter)

Safe fragt nach dem Passwort des Volumes, öffnet das Volume und zeigt es in einem Finder-Fenster. Es öffnet das Volume in einem privaten Ordner, den nur dein Benutzerkonto betreten kann, und nicht am üblichen Ort für Laufwerke. So können andere Benutzerkonten auf demselben Mac es nicht lesen. Das Volume erscheint wie gewohnt in der Seitenleiste des Finder. Wenn das Volume schon geöffnet ist, zeigt „Öffnen“ es im Finder.

### Schließen (Befehl-E)

„Schließen“ wirft das Volume aus, so wie Befehl-E im Finder ein Laufwerk auswirft. Safe erzwingt das Schließen eines Volumes nie, weil eine andere App darauf noch ungesicherte Arbeit haben kann. Wenn eine Datei auf dem Volume noch verwendet wird, bleibt das Volume geöffnet, und Safe sagt das: Schließe diese Datei oder beende die App, die sie verwendet, und versuche es erneut.

Wenn du Safe beendest, schließt es die Volumes, die es geöffnet hat. Wenn eines davon verwendet wird, wählst du zwischen „Abbrechen“ und „Trotzdem beenden“. Mit „Trotzdem beenden“ bleibt es geöffnet, bis du es im Finder auswirfst.

### Passwort ändern

Wähle ein geschlossenes Volume aus und wähle „Passwort ändern“. Gib das aktuelle Passwort einmal und das neue zweimal ein.

Was es nicht tut: Der Schlüssel des Volumes bleibt derselbe. Deshalb **lässt sich eine Kopie des Volumes, die von früher aufbewahrt ist** (in der Versionsgeschichte eines Sync-Dienstes, in einem Backup oder auf einem anderen Mac), **weiterhin mit dem alten Passwort öffnen**. Wenn jemand das alte Passwort kennen könnte, erstelle stattdessen ein neues leeres Volume und bewege die Dateien dorthin.

### Vorhandenes hinzufügen (Umschalt-Befehl-A)

Fügt ein verschlüsseltes Disk-Image hinzu, das Safe nicht erstellt hat, zum Beispiel eines aus dem Festplattendienstprogramm: eine `.dmg`, `.sparsebundle` oder `.sparseimage`. Safe nimmt nur verschlüsselte Images an.

### Aus Liste entfernen

Entfernt das ausgewählte Volume nach einer Rückfrage aus der Liste von Safe. **Das Volume selbst bleibt auf dem Datenträger** und wird nicht gelöscht. Du kannst es mit „Vorhandenes hinzufügen“ wieder hinzufügen. In der Liste macht die Rückschritttaste dasselbe.

### Prüfen, ob die Sync-App läuft

Wenn ein Volume in einem Ordner liegt, den eine Sync-App aktuell hält, wähle es aus, aktiviere **Vor dem Öffnen prüfen, ob diese App läuft:** und gib den Namen der App ein, zum Beispiel `Nextcloud`. Läuft diese App nicht, wenn du das Volume öffnest, warnt Safe dich, weil diese Kopie des Volumes vielleicht nicht die neueste ist. Safe fragt dann, ob du es trotzdem öffnen willst.

### Auf einem anderen Mac

Ein Volume braucht kein Safe. Kopiere das Sparse-Bundle auf einen anderen Mac, oder lass es von einem Sync-Dienst dorthin bringen. Doppelklicke im Finder darauf und gib das Passwort ein. Ein so geöffnetes Volume bindet macOS am üblichen Ort für Laufwerke ein. Dort können andere Benutzerkonten auf diesem Mac es lesen, solange es geöffnet ist.

### Dateien, die zusätzlichen Schutz brauchen

In einem geöffneten Volume kannst du einzelne Dateien mit „Mit Safe verschlüsseln“ verschlüsseln. Sie brauchen dann beide Passwörter. Verschlüssele sie, bevor du sie in das Volume bewegst: Eine unverschlüsselte Datei, die in einem Volume gelöscht wird, bleibt im Image des Volumes für alle lesbar, die das Passwort des Volumes haben.

### Ein Tipp für den Finder

Das Finder-Fenster eines Volumes öffnet sich ohne Symbolleiste. Das macht der Finder bei jedem Disk-Image. So änderst du das im Fenster:

- Befehl-1, Befehl-2, Befehl-3 und Befehl-4 wechseln zwischen Symbol-, Listen-, Spalten- und Galeriedarstellung;
- Wahl-Befehl-T blendet die Symbolleiste ein (und wieder aus).

Der Finder merkt sich das für jedes Volume.

## Sperren {#locking}

### Wann Safe sperrt

- nach **10 Minuten ohne jede Eingabe am Mac**: keine Taste gedrückt, keine Bewegung von Maus oder Trackpad, in irgendeiner App, nicht nur in Safe;
- wenn der Mac in den **Ruhezustand** wechselt oder sein Display ausgeht;
- wenn der **Bildschirm gesperrt** wird oder du zu einem anderen Benutzer wechselst;
- wenn du **Safe > Jetzt sperren** (Control-Befehl-L) wählst.

### Was beim Sperren geschieht

- **Ein Text ohne ungesicherte Änderungen** wird geschlossen.
- **Ein Text mit ungesicherten Änderungen** bleibt geöffnet, aber eine Sperre verdeckt den Text. Klicke auf **Text anzeigen …** (oder drücke den Zeilenschalter) und gib das Passwort der Datei ein, um ihn wieder zu sehen, mit deinen Änderungen. Nichts wird verworfen, ohne dass Safe fragt.
- **Viewer** werden geschlossen.
- **Die Zwischenablage** wird geleert, wenn sie noch enthält, was Safe hineingelegt hat.
- **Volumes, die Safe geöffnet hat,** werden geschlossen. Safe erzwingt das nie: Wenn eine Datei auf einem Volume verwendet wird, bleibt dieses Volume geöffnet, und Safe sagt es dir, wenn du zurück bist. Volumes, die du selbst mit einem Doppelklick im Finder geöffnet hast, schließt Safe nicht.

Ein Volume wird auch dann geschlossen, wenn es einen Text mit ungesicherten Änderungen enthält. Wenn du diesen Text wieder anzeigst, bietet Safe **„NAME“ wieder öffnen** an. Damit wird das Volume am selben Ort geöffnet, sodass Befehl-S dort sichert, wo die Datei war.

Wenn beim Sperren gerade eine Frage offen war, zum Beispiel „Safe konnte das Passwort nicht bestätigen“, wird deine Antwort nach dem Sperren nicht übernommen: Safe fragt zuerst wieder nach dem Passwort. Nach einer Sperre wird nichts Entschlüsseltes ohne das Passwort angezeigt.

## Alte Dateien und die Zukunft {#longterm}

### Alte Formate

Im Laufe der Jahre haben `openssl` und das Terminal-Werkzeug `crypt.sh` Dateien auf leicht unterschiedliche Weise geschrieben: mit einem Schlüssel aus MD5 oder SHA-256 statt dem heutigen PBKDF2, oder mit dem alten Verschlüsselungsverfahren RC4 (`crypt.sh` vor Version 1.4), mit oder ohne zufälliges Salt. Wenn das heutige Format eine Datei nicht öffnet, probiert Safe auch diese älteren Wege.

Wenn ein älterer Weg die Datei öffnet, nennt Safe ihn. Ein Text wird beim nächsten Befehl-S im heutigen Format gesichert. Für andere Dateien bieten der Viewer und die Frage zum Exportieren **Im aktuellen Format sichern** an. Dabei bleibt die alte Datei als `NAME.crypt.bak` erhalten. Wenn Safe das Ergebnis nicht prüfen konnte (eine alte Datei einer Art, die es nicht erkennt), fragt es vor dem Sichern ein zweites Mal. Safe schreibt nie die alten Formate.

### Alte RC4-Dateien

RC4 liefert mit jedem Passwort irgendein Ergebnis. Deshalb kann Safe bei einer alten RC4-Datei nicht immer erkennen, ob das Passwort richtig ist. Wenn du bei einem Text oder einer Datei einer Art, die Safe nicht prüfen kann, zweimal hintereinander dasselbe Passwort eingibst und Safe trotzdem sagt, dass es falsch ist, bietet es **Als alte RC4-Datei exportieren …** an. Dann fragt es, wie die Datei geschrieben wurde: mit `crypt.sh` vor 1.4 oder mit einem anderen Werkzeug. Die exportierte Kopie wird nicht geprüft: Sieh sie dir an. **Andere Lesarten …** in den Fragen zu einem Passwort, das Safe nicht bestätigen konnte, bietet dasselbe an, und dazu den lesbaren Teil einer beschädigten Datei.

### Der Selbsttest bei jedem Start

Bei jedem Start entschlüsselt Safe eine Reihe von Referenzdateien, die mit mehreren Programmen erstellt wurden (OpenSSL 3, das LibreSSL von macOS, `crypt.sh` und Safe selbst). Es prüft, dass ein falsches Passwort abgelehnt wird, und prüft, dass sein Netzwerkzugang abgeschaltet ist. Das dauert im Hintergrund ein paar Sekunden.

Wenn der Selbsttest fehlschlägt, stimmt etwas mit dieser Kopie von Safe oder mit diesem Mac nicht. Safe verschlüsselt und sichert dann nicht, damit es nie eine Datei schreibt, die es nicht zurücklesen kann, und meldet das in Rot im Fenster „Volumes“. Bereits verschlüsselte Dateien lassen sich weiterhin öffnen und exportieren. Bitte die Person, die Safe installiert hat, es zu prüfen. Sie kann für die Einzelheiten `Safe --self-test` ausführen.

### Auswege, die Safe nicht brauchen

Deine Dateien hängen nicht von Safe ab. Im Terminal jedes Mac mit macOS 13 oder neuer

    openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt

entschlüsselt dieser Befehl `FILE.crypt` und zeigt den Inhalt im Terminal, nachdem er nach dem Passwort gefragt hat. Um den Inhalt stattdessen in eine Datei zu schreiben (die Datei `FILE` darf noch nicht existieren; lösche sie, wenn du fertig bist):

    openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt -out FILE

Ohne `openssl` liest das kleine Programm `tools/safe-decrypt.py` aus dem Quellcode von Safe jedes Format, das Safe kennt, auch die alten. Es braucht nichts außer Python 3:

    python3 safe-decrypt.py -o report.pdf report.pdf.crypt

Das Docker-Image `fherwig/safe:22.0`, das OpenSSL 3 enthält, ist ein dritter Weg. Volumes lassen sich auf jedem Mac mit einem Doppelklick öffnen.

### Lizenz und Quellcode

Safe ist freie Software, unter der GNU General Public License, Version 3 oder neuer (GPL-3.0-or-later). Du darfst es benutzen, weitergeben und ändern; wer eine geänderte Fassung weitergibt, muss auch ihren Quellcode weitergeben. Es gibt keinerlei Gewährleistung. Der vollständige Text ist die Datei `LICENSE`, in der App (in `Safe.app/Contents/Resources`) und im Quellcode von Safe, der unter github.com/fherwig/Safe liegt. Safe > Über Safe zeigt die Version.

## Einstellungen und Sprache {#settings}

### Das Fenster „Einstellungen“

**Safe > Einstellungen …** (Befehl-Komma) öffnet das Fenster „Einstellungen“. Zurzeit hat es eine Einstellung: die Sprache. Safe merkt sie sich für dein Benutzerkonto, und sie gilt für jedes Fenster von Safe.

### Die Sprache wählen

Safe spricht Englisch und Deutsch. Wähle unter **Sprache**:

- **System** folgt der Liste der Sprachen unter Systemeinstellungen > Allgemein > Sprache & Region: Deutsch, wenn Deutsch in dieser Liste vor Englisch steht, sonst Englisch.
- **English** oder **Deutsch** verwendet diese Sprache, egal welche Sprache macOS verwendet.

### Was sich wann ändert

Die Menüleiste, das Fenster „Volumes“, diese Hilfe und das Fenster „Einstellungen“ ändern sich sofort. Ein geöffneter Text oder Viewer behält seine Sprache, bis du die Datei erneut öffnest: Ein Wechsel der Sprache schließt nie ein Fenster und berührt nie einen Text mit ungesicherten Änderungen. Dasselbe gilt für einen geöffneten Dialog.

Einige Dinge, die macOS für Safe zeichnet, folgen der neuen Sprache erst, wenn Safe neu gestartet wird: die Dialoge zum Öffnen und Sichern, das Fenster „Über Safe“ und das Suchfeld oben im Menü „Hilfe“. Das Fenster „Einstellungen“ sagt, wenn das der Fall ist. Wenn in Safe nichts geöffnet ist (kein Text, kein Viewer, kein Volume), bietet es **Safe neu starten** an. Sonst wirkt die Änderung beim nächsten Start von Safe.

### Der Finder folgt macOS

Die Dienste im Finder (Mit Safe verschlüsseln, Mit Safe öffnen, Mit Safe exportieren) und der Name des Dateityps `.crypt`, den der Finder als „Verschlüsselte Datei“ anzeigt, folgen der Sprache von macOS, nicht der Einstellung in Safe, weil der Finder sie anzeigt. Wenn macOS auf Englisch eingestellt ist, heißen sie Encrypt with Safe, Open with Safe, Export with Safe und „Encrypted file“.

## Tastaturkurzbefehle {#shortcuts}

Diese Kurzbefehle stehen auch in den Menüs neben jedem Eintrag.

| Kurzbefehl | Funktion |
|---|---|
| ⌘O | Ablage > Öffnen: verschlüsselte Dateien öffnen |
| ⇧⌘E | Ablage > Datei verschlüsseln: Dateien verschlüsseln |
| ⌘W | Ablage > Schließen: das Fenster schließen |
| ⌘S | Ablage > Sichern: den Text verschlüsselt sichern |
| ⌥⌘E | Ablage > Exportieren: eine unverschlüsselte Kopie schreiben |
| ⌘Z | Bearbeiten > Widerrufen |
| ⇧⌘Z | Bearbeiten > Wiederholen |
| ⌘X | Bearbeiten > Ausschneiden |
| ⌘C | Bearbeiten > Kopieren |
| ⌘V | Bearbeiten > Einsetzen |
| ⌘A | Bearbeiten > Alles auswählen |
| ⌘F | Bearbeiten > Suchen: das Suchfeld einblenden |
| ⌘G | Bearbeiten > Weitersuchen |
| ⇧⌘G | Bearbeiten > Weitersuchen (rückwärts) |
| ⌘+ (oder ⌘=) | Darstellung > Vergrößern (Viewer) |
| ⌘- | Darstellung > Verkleinern (Viewer) |
| ⌥⌘0 | Darstellung > Originalgröße (Viewer) |
| ⌘9 | Darstellung > Größe an Fenster anpassen (Viewer) |
| ⌥⌘↓ | Darstellung > Nächste Seite (PDF) |
| ⌥⌘↑ | Darstellung > Vorherige Seite (PDF) |
| ⌘N | Volume > Neues leeres Volume |
| ⇧⌘N | Volume > Neues Volume aus Ordner |
| ⇧⌘A | Volume > Vorhandenes Volume hinzufügen |
| ⌘↩ | Volume > Volume öffnen |
| ⌘E | Volume > Volume schließen |
| ⌘0 | Fenster > Volumes: das Fenster „Volumes“ einblenden |
| ⌘M | Fenster > Im Dock ablegen |
| ⌃⌘L | Safe > Jetzt sperren |
| ⌘H | Safe > Safe ausblenden |
| ⌥⌘H | Safe > Andere ausblenden |
| ⌘Q | Safe > Safe beenden |
| ⌘? | Hilfe > Safe-Hilfe |
| ⌘, | Safe > Einstellungen: die Sprache wählen |

Die Symbole: ⌘ ist die Befehlstaste, ⇧ die Umschalttaste, ⌥ die Wahltaste, ⌃ die Control-Taste, ↩ der Zeilenschalter, ↓ und ↑ sind die Pfeiltasten. Auf einer deutschen Tastatur ist ⌘? Umschalt-Befehl-ß, ⌘+ ist die Befehlstaste mit der Plustaste (ohne Umschalttaste), und ⌘= ist Umschalt-Befehl-0. Auf einer englischen Tastatur ist ⌘? Umschalt-Befehl-/ und ⌘+ ist Umschalt-Befehl-=. Die Kurzbefehle sind in beiden Sprachen von Safe gleich.

Tasten in den Fenstern:

| Taste | Wo | Funktion |
|---|---|---|
| Zeilenschalter | Liste der Volumes | das ausgewählte Volume öffnen |
| Rückschritttaste | Liste der Volumes | das ausgewählte Volume aus der Liste entfernen (fragt vorher) |
| Zeilenschalter, ⇧Zeilenschalter | Suchfeld | den nächsten oder den vorherigen Treffer finden |
| esc-Taste | Suchfeld | das Suchfeld ausblenden |
| esc-Taste | Viewer | den Viewer schließen |
| Zeilenschalter | gesperrter Text | Text anzeigen: das Passwort eingeben, um den Text wieder zu sehen |
| ⌘D | Frage „Möchtest du die Änderungen … sichern?“ | Nicht sichern |

„Passwort ändern“ und „Aus Liste entfernen“ haben im Menü keinen Kurzbefehl, damit ein Vertipper sie nicht auslösen kann.

### Kurzbefehle für die Dienste im Finder

„Mit Safe verschlüsseln“, „Mit Safe öffnen“ und „Mit Safe exportieren“ haben im Finder keinen Kurzbefehl. Ein Kurzbefehl für einen Dienst gilt nämlich in jeder App und würde mit den Kurzbefehlen anderer Apps kollidieren. Du kannst ihnen selbst einen geben:

1. Öffne Systemeinstellungen > Tastatur und klicke auf **Tastaturkurzbefehle …**.
2. Wähle links **Dienste** und öffne **Dateien und Ordner**.
3. Doppelklicke neben „Mit Safe verschlüsseln“ auf **Ohne** und drücke die gewünschten Tasten, zum Beispiel Control-Wahl-Befehl-E. Wähle Tasten, die keine andere App verwendet.
4. Klicke auf „Fertig“. Der Kurzbefehl funktioniert, wenn im Finder Dateien ausgewählt sind.

## Wenn etwas nicht klappt {#problems}

### Falsches Passwort, beschädigte Datei oder Passwort nicht bestätigt

- **„Das Passwort war falsch.“** Prüfe die Feststelltaste und das Tastaturlayout (die Flagge oder die Buchstaben in der Menüleiste) und gib das Passwort erneut ein. Denk daran, dass Groß- und Kleinbuchstaben zählen.
- **„Das Passwort öffnet die Datei nicht, oder die Datei ist beschädigt.“** Meist ist das Passwort falsch. Wenn du dir des Passworts sicher bist, wurde die Datei vielleicht abgeschnitten.
- **„NAME“ ist beschädigt.** Das Passwort scheint richtig zu sein, aber das Ende der Datei fehlt, meist weil ein Kopiervorgang oder eine Synchronisierung unterbrochen wurde. Wenn es eine `NAME.crypt.bak` gibt, öffne diese: Sie ist die Version vor dem letzten Sichern. Sonst sichert **Lesbaren Teil exportieren …** alles, was sich noch lesen lässt.
- **„Safe konnte das Passwort nicht bestätigen.“** Der Inhalt sieht nicht aus wie die Art von Datei, die ihr Name angibt. Deshalb kann Safe nicht erkennen, ob das Passwort richtig ist. Öffne die Datei schreibgeschützt und sieh sie dir an (Abschnitt „Eine Textdatei öffnen und bearbeiten“).
- **„Das Passwort ist wahrscheinlich falsch.“** Was herauskam, ist nicht das, was die Datei enthalten sollte. Gib das Passwort erneut ein. „Trotzdem exportieren“ gibt es für die seltene Datei, die wirklich so aussieht.

### Ein Volume lässt sich nicht schließen

Eine Datei darauf wird noch verwendet: Sie ist zum Beispiel in einer App geöffnet, oder ein Terminal-Fenster ist in einem seiner Ordner. Schließe die Datei oder beende die App und klicke dann erneut auf „Schließen“. Safe erzwingt das Schließen eines Volumes nie, weil die App, die es verwendet, ungesicherte Arbeit haben kann. Wenn Safe sperrt oder beendet wird, bleibt ein belegtes Volume geöffnet, und Safe sagt es dir.

### Sichern funktioniert nicht

- **„Der Ordner, in dem sie liegt, ist nicht mehr da.“** Das Volume mit der Datei wurde geschlossen. Öffne es wieder und sichere dann. Deine Änderungen sind noch im Fenster.
- **„… wurde auf dem Datenträger geändert.“** Ein anderes Programm oder ein anderer Mac hat die Datei geändert (Abschnitt „Eine Textdatei öffnen und bearbeiten“).
- **„Safe prüft noch …“** Der Selbsttest läuft noch. Versuche es gleich noch einmal.
- **„Safe verschlüsselt und sichert nicht, weil sein Selbsttest fehlgeschlagen ist.“** Siehe Abschnitt „Alte Dateien und die Zukunft“.

### Dateien, die du neben einer verschlüsselten Datei finden kannst

Safe benennt diese Dateien in beiden Sprachen gleich, deshalb enthalten manche Namen englische Wörter.

- **`NAME.crypt.bak`**: die vorherige Version, die jedes Sichern behält. Sie ist verschlüsselt, mit dem Passwort, das die Datei damals hatte, und öffnet sich mit einem Doppelklick wie jede `.crypt`-Datei.
- **`NAME.crypt_new`**: gibt es nur, während Safe sichert oder verschlüsselt. Wenn du eine findest, wurde das Sichern oder Verschlüsseln unterbrochen. Sie ist verschlüsselt, und `NAME.crypt` ist noch die letzte gute Version. Safe entfernt sie beim nächsten Sichern. Du kannst sie auch löschen.
- **`NAME (conflict 2026-10-25 14-05).txt.crypt`**: deine Version, als Kopie gesichert, weil die Datei anderswo geändert wurde, während du sie bearbeitet hast („conflict“ heißt Konflikt). Öffne beide, behalte, was du brauchst, und lösche die andere.
- **`NAME (exporting XXXXXXXX).tmp`**: ein Export, der unterbrochen wurde („exporting“ heißt „wird exportiert“). Diese Datei ist **nicht verschlüsselt**: Lösche sie.
- **Ein unsichtbarer Ordner `.NAME.safe-pending-XXXXXXXX`**: ein Ordner, den „Aus Ordner“ gerade löschte. Safe bietet an, das Löschen beim nächsten Start zu beenden.

### Safe startet nicht

Wenn Safe „Safe kann nicht starten“ meldet, weil es seinen eigenen Netzwerkzugang nicht abschalten konnte, beendet es sich, statt ohne diesen Schutz zu laufen. Bitte die Person, die Safe installiert hat, es sich anzusehen.

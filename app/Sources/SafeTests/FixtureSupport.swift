import CryptoKit
import Foundation
import SafeCore

// WP1: helpers for the crypto, files and self-test suites: the reference
// files in app/Fixtures and their manifest.json (building plan 5.4), and
// /usr/bin/openssl and the Docker image as second opinions. The data goes
// through stdin and stdout, so no plaintext is written to disk. Passwords go
// through a file or stdin, never through arguments or the environment:
// Foundation's Process passes those in decomposed Unicode (NFD), which turns
// "ü" into other bytes and so into another password.

/// One entry of app/Fixtures/manifest.json.
struct ReferenceFile: Decodable {
    let file: String
    let generator: String
    let variant: String
    let salted: Bool
    let options: String
    let originalName: String
    let password: String
    let length: Int
    let sha256: String

    var url: URL { TestPaths.fixtures.appendingPathComponent(file) }
    func data() throws -> Data { try Data(contentsOf: url) }
    var cryptVariant: CryptVariant? { CryptVariant(rawValue: variant) }
}

enum ReferenceFiles {
    struct Manifest: Decodable {
        let files: [ReferenceFile]
    }

    static func load() throws -> [ReferenceFile] {
        let data = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data).files
    }

    /// The first entry that matches, or a test failure.
    static func first(_ description: String, _ match: (ReferenceFile) -> Bool) throws -> ReferenceFile {
        guard let entry = try load().first(where: match) else {
            throw CryptError.io("no reference file: \(description)")
        }
        return entry
    }

    /// A text file in the current format, made by OpenSSL 3.
    static func text() throws -> ReferenceFile {
        try first("a text file in the current format") {
            $0.variant == "current" && $0.originalName == "notes.txt"
        }
    }

    /// Copies a reference file into `directory` as ORIGINAL.crypt.
    static func copyAsCrypt(_ entry: ReferenceFile, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(entry.originalName + ".crypt")
        try entry.data().write(to: url)
        return url
    }
}

enum CryptoTestKit {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func randomData(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &g) })
    }

    /// The marker the leak test looks for: safetest-marker- and 32 hex digits, in
    /// UTF-8 text, or in text in another encoding (UTF-16, ISO Latin-1).
    static func marker(in data: Data) -> String? {
        if let marker = utf8Marker(in: data) {
            return marker
        }
        return utf8Marker(in: Data(TextCoding.decodeAnyway(data).text.utf8))
    }

    private static func utf8Marker(in data: Data) -> String? {
        let prefix = Data("safetest-marker-".utf8)
        guard let range = data.range(of: prefix), data.count >= range.upperBound + 32 else {
            return nil
        }
        let hex = data[range.upperBound ..< range.upperBound + 32]
        guard hex.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }) else {
            return nil
        }
        return String(decoding: data[range.lowerBound ..< range.upperBound + 32], as: UTF8.self)
    }

    static let currentOptions = ["-aes-256-cbc", "-md", "sha512", "-pbkdf2", "-iter", "100000"]

    /// Runs /usr/bin/openssl enc with the password in a file (-pass file:)
    /// and the data on stdin.
    static func openssl(_ mode: String, _ data: Data, password: String, options: [String]) throws -> ProcessResult {
        try withTemporaryDirectory { dir in
            let file = dir.appendingPathComponent("password")
            try Data((password + "\n").utf8).write(to: file)
            return try runProcess("/usr/bin/openssl", ["enc", mode] + options + ["-pass", "file:" + file.path],
                                  input: data)
        }
    }

    /// Decrypts with macOS's /usr/bin/openssl; returns the plaintext or nil.
    static func opensslDecrypt(_ ciphertext: Data, password: String,
                               options: [String] = currentOptions) throws -> Data? {
        let result = try openssl("-d", ciphertext, password: password, options: options)
        return result.status == 0 ? result.stdout : nil
    }

    /// Encrypts with macOS's /usr/bin/openssl, for variants made at test time.
    static func opensslEncrypt(_ plaintext: Data, password: String, options: [String]) throws -> Data {
        let result = try openssl("-e", plaintext, password: password, options: options)
        guard result.status == 0 else {
            throw CryptError.io("openssl enc -e failed: \(result.errorOutput)")
        }
        return result.stdout
    }

    static let dockerImage = "fherwig/safe:22.0"

    /// The docker program, if Docker is running and has the image; else nil.
    static let docker: String? = {
        for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                     "/Applications/Docker.app/Contents/Resources/bin/docker"]
            where FileManager.default.isExecutableFile(atPath: path) {
            guard let info = try? runProcess(path, ["image", "inspect", dockerImage]), info.status == 0 else {
                return nil
            }
            return path
        }
        return nil
    }()

    /// Runs a shell script in a throwaway container of the image, without
    /// network. The first line of stdin is the password, which the script
    /// finds in $SAFETEST_PW; the rest of stdin is `input`.
    static func inDocker(_ script: String, input: Data, password: String) throws -> ProcessResult {
        guard let docker = docker else {
            try skip("Docker is not running or the image \(dockerImage) is missing")
        }
        return try runProcess(docker, ["run", "--rm", "-i", "--pull", "never", "--network", "none",
                                       "--name", "safetest-wp1-\(UUID().uuidString.prefix(8).lowercased())",
                                       dockerImage, "sh", "-c",
                                       "IFS= read -r SAFETEST_PW; export SAFETEST_PW; " + script],
                              input: Data((password + "\n").utf8) + input)
    }
}


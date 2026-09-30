import Foundation

/// Queue persistante FIFO (C05 §2.5).
///
/// - `queue.jsonl` : append-only, une ligne JSON par événement ;
/// - `queue.head` : nombre de lignes déjà consommées (envoyées ou droppées) en tête du fichier.
///
/// Compactée (réécrite sans les lignes mortes) quand plus de la moitié des lignes sont mortes.
/// N'est pas thread-safe : elle appartient à l'actor `AnalyticsCore`. Aucune erreur n'est propagée.
final class EventQueue {
    /// Résultat d'un `peek` : les événements lisibles et le nombre de lignes qu'ils occupent
    /// (une ligne illisible est comptée, pour être acquittée avec le reste, mais pas renvoyée).
    struct Peek {
        var events: [QueuedEvent]
        var lineCount: Int
    }

    static let folderName = "com.platform.analytics"
    static let syncEvery = 10

    let directory: URL
    private let fileURL: URL
    private let headURL: URL
    private var maxEvents: Int
    private var handle: FileHandle?
    private var lineCount = 0
    private var deadCount = 0
    private var unsyncedLines = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Nombre d'événements en attente.
    var count: Int { lineCount - deadCount }

    /// `Library/Application Support/com.platform.analytics/`.
    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: folderName, directoryHint: .isDirectory)
    }

    init(directory: URL, maxEvents: Int) {
        self.directory = directory
        self.fileURL = directory.appending(path: "queue.jsonl", directoryHint: .notDirectory)
        self.headURL = directory.appending(path: "queue.head", directoryHint: .notDirectory)
        self.maxEvents = max(1, maxEvents)
        prepareDirectory()
        load()
        enforceMaximum()
    }

    deinit {
        try? handle?.synchronize()
        try? handle?.close()
    }

    // MARK: - Opérations

    func append(_ event: QueuedEvent) {
        guard var line = try? encoder.encode(event) else {
            Log.error("event '\(event.name)' could not be encoded, dropped")
            return
        }
        line.append(0x0A)
        do {
            let handle = try openHandle()
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            Log.error("queue write failed (\(error.localizedDescription)), event '\(event.name)' dropped")
            closeHandle()
            return
        }
        lineCount += 1
        unsyncedLines += 1
        if unsyncedLines >= Self.syncEvery {
            sync()
        }
        enforceMaximum()
    }

    /// Les `limit` plus anciens événements en attente, sans les retirer.
    func peek(_ limit: Int) -> Peek {
        guard limit > 0, count > 0 else { return Peek(events: [], lineCount: 0) }
        var events: [QueuedEvent] = []
        var consumed = 0
        let decoder = JSONDecoder()
        for line in readLines().dropFirst(deadCount) {
            if events.count == limit { break }
            consumed += 1
            if let event = try? decoder.decode(QueuedEvent.self, from: line) {
                events.append(event)
            } else {
                Log.warning("unreadable queue line skipped")
            }
        }
        return Peek(events: events, lineCount: consumed)
    }

    /// Retire les `lines` premières lignes en attente (après un envoi réussi ou un batch droppé).
    func ack(_ lines: Int) {
        guard lines > 0 else { return }
        deadCount = min(lineCount, deadCount + lines)
        writeHead()
        compactIfNeeded()
    }

    /// Vide la queue (opt-out, clé révoquée, reset d'identité).
    func purge() {
        closeHandle()
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: headURL)
        lineCount = 0
        deadCount = 0
        unsyncedLines = 0
    }

    /// Force l'écriture sur disque (`fsync`), appelé toutes les 10 lignes et à chaque flush.
    func sync() {
        guard unsyncedLines > 0 else { return }
        try? handle?.synchronize()
        unsyncedLines = 0
    }

    func setMaxEvents(_ value: Int) {
        maxEvents = max(1, value)
        enforceMaximum()
    }

    // MARK: - Interne

    private func prepareDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            Log.error("queue directory unavailable (\(error.localizedDescription))")
        }
    }

    private func load() {
        var data = (try? Data(contentsOf: fileURL)) ?? Data()
        // Une dernière ligne sans « \n » vient d'une écriture interrompue : on la retire.
        if let last = data.last, last != 0x0A {
            let keep = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
            data = data.prefix(upTo: keep)
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.error("queue repair failed (\(error.localizedDescription))")
            }
            Log.warning("truncated queue line removed")
        }
        lineCount = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        let head = (try? String(contentsOf: headURL, encoding: .utf8)).flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        deadCount = min(max(0, head ?? 0), lineCount)
    }

    private func readLines() -> [Data] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast().map { Data($0) }
    }

    private func enforceMaximum() {
        let excess = count - maxEvents
        guard excess > 0 else { return }
        deadCount += excess
        Log.warning("queue full: \(excess) oldest event(s) dropped")
        writeHead()
        compactIfNeeded()
    }

    private func compactIfNeeded() {
        guard deadCount > 0, deadCount * 2 > lineCount else { return }
        sync()
        closeHandle()
        let live = readLines().dropFirst(deadCount)
        var data = Data()
        for line in live {
            data.append(line)
            data.append(0x0A)
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            lineCount = live.count
            deadCount = 0
            writeHead()
        } catch {
            Log.error("queue compaction failed (\(error.localizedDescription))")
        }
    }

    private func writeHead() {
        do {
            try Data(String(deadCount).utf8).write(to: headURL, options: .atomic)
        } catch {
            Log.error("queue head write failed (\(error.localizedDescription))")
        }
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        }
        let opened = try FileHandle(forWritingTo: fileURL)
        handle = opened
        return opened
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }
}

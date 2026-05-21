import Foundation

struct InAppBrowserPage: Decodable {
    let url: String
    let statusCode: Int
    let headers: [String: String]
    let contentType: String
    let body: String?
    let bodyBase64: String?
    let truncated: Bool
}

struct InAppBrowserProxy: Decodable {
    let type: String
    let host: String
    let port: Int
    let address: String
}

struct InAppTerminalRequest: Encodable {
    let host: String
    let port: Int
    let payload: String
    let appendNewline: Bool
    let timeoutMillis: Int
}

struct InAppTerminalResponse: Decodable {
    let body: String?
    let bodyBase64: String?
    let truncated: Bool
}

struct InAppSSHOpenRequest: Encodable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let privateKey: String
    let passphrase: String
    let terminal: String
    let columns: Int
    let rows: Int
    let timeoutMillis: Int
}

struct InAppSSHSessionRequest: Encodable {
    let sessionID: String
    let waitMillis: Int?

    init(sessionID: String, waitMillis: Int? = nil) {
        self.sessionID = sessionID
        self.waitMillis = waitMillis
    }
}

struct InAppSSHSendRequest: Encodable {
    let sessionID: String
    let input: String
    let waitMillis: Int?

    init(sessionID: String, input: String, waitMillis: Int? = nil) {
        self.sessionID = sessionID
        self.input = input
        self.waitMillis = waitMillis
    }
}

struct InAppSSHResponse: Decodable {
    let sessionID: String
    let body: String?
    let bodyBase64: String?
    let active: Bool
    let truncated: Bool

    var terminalOutputData: Data? {
        if let body {
            return Data(body.utf8)
        }
        if let bodyBase64 {
            return Data(base64Encoded: bodyBase64)
        }
        return nil
    }
}

struct TerminalScreenBuffer {
    private enum ParserState {
        case ground
        case escape
        case escapeIgnoringOne
        case csi(String)
        case osc
        case oscEscape
    }

    private var rows: [[Character]] = [[]]
    private var cursorRow = 0
    private var cursorColumn = 0
    private var cursorVisible = true
    private var savedCursor: (row: Int, column: Int)?
    private var parserState: ParserState = .ground
    private var pendingUTF8: [UInt8] = []
    private let maxRows: Int
    private static let cursorCharacter: Character = "█"

    init(maxRows: Int = 1_000) {
        self.maxRows = max(1, maxRows)
    }

    var renderedText: String {
        renderedLines(showCursor: false).joined(separator: "\n")
    }

    var renderedTextWithCursor: String {
        renderedLines(showCursor: cursorVisible).joined(separator: "\n")
    }

    mutating func reset() {
        rows = [[]]
        cursorRow = 0
        cursorColumn = 0
        cursorVisible = true
        savedCursor = nil
        parserState = .ground
        pendingUTF8 = []
    }

    mutating func append(_ data: Data) {
        pendingUTF8.append(contentsOf: data)
        let incompleteCount = trailingIncompleteUTF8ByteCount(in: pendingUTF8)
        let completeCount = pendingUTF8.count - incompleteCount
        guard completeCount > 0 else { return }

        let completeBytes = pendingUTF8.prefix(completeCount)
        pendingUTF8 = Array(pendingUTF8.suffix(incompleteCount))
        let text = String(decoding: completeBytes, as: UTF8.self)
        for scalar in text.unicodeScalars {
            process(scalar)
        }
    }

    private func renderedLines(showCursor: Bool) -> [String] {
        var snapshot = rows
        if showCursor {
            let rowIndex = max(0, cursorRow)
            let columnIndex = max(0, cursorColumn)
            while rowIndex >= snapshot.count {
                snapshot.append([])
            }
            if columnIndex > snapshot[rowIndex].count {
                snapshot[rowIndex].append(contentsOf: Array(repeating: Character(" "), count: columnIndex - snapshot[rowIndex].count))
            }
            if columnIndex == snapshot[rowIndex].count {
                snapshot[rowIndex].append(Self.cursorCharacter)
            } else {
                snapshot[rowIndex][columnIndex] = Self.cursorCharacter
            }
        }
        return snapshot.map(renderedLine)
    }

    private func renderedLine(_ row: [Character]) -> String {
        var trimmed = row
        while trimmed.last == " " {
            trimmed.removeLast()
        }
        return String(trimmed)
    }

    private func trailingIncompleteUTF8ByteCount(in bytes: [UInt8]) -> Int {
        guard let last = bytes.last else { return 0 }
        if last < 0x80 { return 0 }

        var continuationCount = 0
        var index = bytes.count - 1
        while index >= 0, (bytes[index] & 0xC0) == 0x80 {
            continuationCount += 1
            if index == 0 { break }
            index -= 1
        }
        guard index >= 0 else { return min(bytes.count, 4) }

        let lead = bytes[index]
        let expectedCount: Int
        if (lead & 0xE0) == 0xC0 {
            expectedCount = 2
        } else if (lead & 0xF0) == 0xE0 {
            expectedCount = 3
        } else if (lead & 0xF8) == 0xF0 {
            expectedCount = 4
        } else {
            return 0
        }

        let actualCount = bytes.count - index
        return actualCount < expectedCount ? actualCount : 0
    }

    private mutating func process(_ scalar: Unicode.Scalar) {
        switch parserState {
        case .ground:
            processGround(scalar)
        case .escape:
            processEscape(scalar)
        case .escapeIgnoringOne:
            parserState = .ground
        case .csi(let sequence):
            processCSI(sequence: sequence, scalar: scalar)
        case .osc:
            processOSC(scalar)
        case .oscEscape:
            if scalar == "\\" {
                parserState = .ground
            } else {
                parserState = .osc
            }
        }
    }

    private mutating func processGround(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x1B:
            parserState = .escape
        case 0x9B:
            parserState = .csi("")
        case 0x9D:
            parserState = .osc
        case 0x0D:
            cursorColumn = 0
        case 0x0A:
            lineFeed()
        case 0x08, 0x7F:
            cursorColumn = max(0, cursorColumn - 1)
        case 0x09:
            let spaces = 8 - (cursorColumn % 8)
            for _ in 0..<spaces { write(" ") }
        case 0x20...0x10FFFF:
            write(Character(String(scalar)))
        default:
            break
        }
    }

    private mutating func processEscape(_ scalar: Unicode.Scalar) {
        switch scalar {
        case "[":
            parserState = .csi("")
        case "]":
            parserState = .osc
        case "7":
            savedCursor = (cursorRow, cursorColumn)
            parserState = .ground
        case "8":
            restoreCursor()
            parserState = .ground
        case "c":
            reset()
        case "(", ")", "*", "+", "-", ".", "/", "#", "%":
            parserState = .escapeIgnoringOne
        default:
            parserState = .ground
        }
    }

    private mutating func processCSI(sequence: String, scalar: Unicode.Scalar) {
        if scalar.value >= 0x40, scalar.value <= 0x7E {
            applyCSI(sequence: sequence, final: scalar)
            parserState = .ground
        } else if sequence.count < 64 {
            parserState = .csi(sequence + String(scalar))
        } else {
            parserState = .ground
        }
    }

    private mutating func processOSC(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x07:
            parserState = .ground
        case 0x1B:
            parserState = .oscEscape
        default:
            break
        }
    }

    private mutating func applyCSI(sequence: String, final: Unicode.Scalar) {
        let params = csiParameters(sequence)
        let first = params.first ?? nil
        switch final {
        case "A":
            cursorRow = max(0, cursorRow - parameter(first, default: 1))
        case "B":
            cursorRow += parameter(first, default: 1)
            ensureCursorRow()
        case "C":
            cursorColumn += parameter(first, default: 1)
        case "D":
            cursorColumn = max(0, cursorColumn - parameter(first, default: 1))
        case "G":
            cursorColumn = max(0, parameter(first, default: 1) - 1)
        case "H", "f":
            cursorRow = max(0, parameter(params.first ?? nil, default: 1) - 1)
            cursorColumn = max(0, parameter(params.dropFirst().first ?? nil, default: 1) - 1)
            ensureCursorRow()
        case "J":
            eraseDisplay(parameter(first, default: 0))
        case "K":
            eraseLine(parameter(first, default: 0))
        case "P":
            deleteCharacters(parameter(first, default: 1))
        case "X":
            eraseCharacters(parameter(first, default: 1))
        case "L":
            insertLines(parameter(first, default: 1))
        case "M":
            deleteLines(parameter(first, default: 1))
        case "S":
            scrollUp(parameter(first, default: 1))
        case "T":
            scrollDown(parameter(first, default: 1))
        case "s":
            savedCursor = (cursorRow, cursorColumn)
        case "u":
            restoreCursor()
        case "h", "l":
            applyPrivateMode(sequence: sequence, enabled: final == "h")
        default:
            break
        }
    }

    private mutating func applyPrivateMode(sequence: String, enabled: Bool) {
        guard sequence.contains("?") else { return }
        for parameter in csiParameters(sequence) {
            if parameter == 25 {
                cursorVisible = enabled
            }
        }
    }

    private func csiParameters(_ sequence: String) -> [Int?] {
        let parameterText = sequence.drop { character in
            !(character.isNumber || character == ";" || character == "-")
        }
        return parameterText.split(separator: ";", omittingEmptySubsequences: false).map { part in
            let digits = part.filter { $0.isNumber || $0 == "-" }
            return Int(digits)
        }
    }

    private func parameter(_ value: Int?, default defaultValue: Int) -> Int {
        guard let value, value > 0 else { return defaultValue }
        return value
    }

    private mutating func write(_ character: Character) {
        ensureCursorRow()
        if cursorColumn > rows[cursorRow].count {
            rows[cursorRow].append(contentsOf: Array(repeating: Character(" "), count: cursorColumn - rows[cursorRow].count))
        }
        if cursorColumn == rows[cursorRow].count {
            rows[cursorRow].append(character)
        } else {
            rows[cursorRow][cursorColumn] = character
        }
        cursorColumn += 1
    }

    private mutating func lineFeed() {
        cursorRow += 1
        cursorColumn = 0
        ensureCursorRow()
        trimScrollbackIfNeeded()
    }

    private mutating func ensureCursorRow() {
        while cursorRow >= rows.count {
            rows.append([])
        }
    }

    private mutating func trimScrollbackIfNeeded() {
        guard rows.count > maxRows else { return }
        let overflow = rows.count - maxRows
        rows.removeFirst(overflow)
        cursorRow = max(0, cursorRow - overflow)
        if let savedCursor {
            self.savedCursor = (max(0, savedCursor.row - overflow), savedCursor.column)
        }
    }

    private mutating func restoreCursor() {
        guard let savedCursor else { return }
        cursorRow = savedCursor.row
        cursorColumn = savedCursor.column
        ensureCursorRow()
    }

    private mutating func eraseDisplay(_ mode: Int) {
        ensureCursorRow()
        switch mode {
        case 1:
            for index in 0..<cursorRow {
                rows[index].removeAll()
            }
            eraseLine(1)
        case 2, 3:
            rows = [[]]
            cursorRow = 0
            cursorColumn = 0
        default:
            eraseLine(0)
            if cursorRow + 1 < rows.count {
                rows.removeSubrange((cursorRow + 1)..<rows.count)
            }
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        ensureCursorRow()
        switch mode {
        case 1:
            guard !rows[cursorRow].isEmpty else { return }
            let end = min(cursorColumn, rows[cursorRow].count - 1)
            guard end >= 0 else { return }
            for index in 0...end {
                rows[cursorRow][index] = " "
            }
        case 2:
            rows[cursorRow].removeAll()
            cursorColumn = 0
        default:
            guard cursorColumn < rows[cursorRow].count else { return }
            rows[cursorRow].removeSubrange(cursorColumn..<rows[cursorRow].count)
        }
    }

    private mutating func deleteCharacters(_ count: Int) {
        ensureCursorRow()
        guard cursorColumn < rows[cursorRow].count else { return }
        let end = min(rows[cursorRow].count, cursorColumn + max(0, count))
        rows[cursorRow].removeSubrange(cursorColumn..<end)
    }

    private mutating func eraseCharacters(_ count: Int) {
        ensureCursorRow()
        let end = cursorColumn + max(0, count)
        if end > rows[cursorRow].count {
            rows[cursorRow].append(contentsOf: Array(repeating: Character(" "), count: end - rows[cursorRow].count))
        }
        for index in cursorColumn..<end {
            rows[cursorRow][index] = " "
        }
    }

    private mutating func insertLines(_ count: Int) {
        ensureCursorRow()
        rows.insert(contentsOf: Array(repeating: [], count: max(0, count)), at: cursorRow)
        trimScrollbackIfNeeded()
    }

    private mutating func deleteLines(_ count: Int) {
        ensureCursorRow()
        let end = min(rows.count, cursorRow + max(0, count))
        guard cursorRow < end else { return }
        rows.removeSubrange(cursorRow..<end)
        if rows.isEmpty { rows = [[]] }
        ensureCursorRow()
    }

    private mutating func scrollUp(_ count: Int) {
        let removeCount = min(rows.count, max(0, count))
        guard removeCount > 0 else { return }
        rows.removeFirst(removeCount)
        rows.append(contentsOf: Array(repeating: [], count: removeCount))
        cursorRow = max(0, cursorRow - removeCount)
    }

    private mutating func scrollDown(_ count: Int) {
        let insertCount = max(0, count)
        guard insertCount > 0 else { return }
        rows.insert(contentsOf: Array(repeating: [], count: insertCount), at: 0)
        if rows.count > maxRows {
            rows.removeLast(rows.count - maxRows)
        }
        cursorRow += insertCount
    }
}

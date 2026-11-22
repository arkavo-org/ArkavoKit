import Foundation

/// Splits a byte stream into newline-delimited messages. A message longer than
/// `maxMessageSize`, complete or not, is refused, so a peer that never sends a newline
/// can't make the buffer grow without limit.
struct NDJSONFramer {
    struct MessageTooLarge: Error {}

    let maxMessageSize: Int
    private var buffer = Data()
    /// Byte offset from `buffer.startIndex` to the start of the next unread message
    private var readOffset = 0
    /// Bytes from `readOffset` already searched for a newline
    private var searched = 0

    init(maxMessageSize: Int) {
        self.maxMessageSize = maxMessageSize
    }

    /// Adds received bytes and returns the messages they complete, without their newlines
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        let base = buffer.startIndex
        while let newline = buffer[(base + readOffset + searched)...].firstIndex(of: 0x0A) {
            let messageStart = base + readOffset
            let messageLength = newline - messageStart
            guard messageLength <= maxMessageSize else {
                compact()
                throw MessageTooLarge()
            }
            messages.append(Data(buffer[messageStart..<newline]))
            readOffset = (newline - base) + 1
            searched = 0
        }
        let remaining = buffer.count - readOffset
        guard remaining <= maxMessageSize else {
            compact()
            throw MessageTooLarge()
        }
        searched = remaining
        compact()
        return messages
    }

    /// Compacts consumed prefix bytes once per `append` call so framing stays O(N).
    private mutating func compact() {
        guard readOffset > 0 else { return }
        if readOffset >= buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count <= maxMessageSize)
        } else {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readOffset))
        }
        readOffset = 0
    }
}

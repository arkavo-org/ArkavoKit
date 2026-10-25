import Foundation

/// Splits a byte stream into newline-delimited messages. A message longer than
/// `maxMessageSize`, complete or not, is refused, so a peer that never sends a newline
/// can't make the buffer grow without limit.
struct NDJSONFramer {
    struct MessageTooLarge: Error {}

    let maxMessageSize: Int
    private var buffer = Data()
    /// Bytes at the start of `buffer` already searched for a newline
    private var searched = 0

    init(maxMessageSize: Int) {
        self.maxMessageSize = maxMessageSize
    }

    /// Adds received bytes and returns the messages they complete, without their newlines
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let newline = buffer[(buffer.startIndex + searched)...].firstIndex(of: 0x0A) {
            let message = buffer[buffer.startIndex..<newline]
            guard message.count <= maxMessageSize else { throw MessageTooLarge() }
            messages.append(Data(message))
            buffer.removeSubrange(buffer.startIndex...newline)
            searched = 0
        }
        guard buffer.count <= maxMessageSize else { throw MessageTooLarge() }
        searched = buffer.count
        return messages
    }
}

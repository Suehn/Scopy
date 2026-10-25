import Foundation

/// Shared traversal over the well-formed UTF-8 of a String.
enum UTF8Text {
    /// Scalars that are composed (NFC-stable, combining class 0), lowercase to such a scalar of the
    /// same UTF-16 length, and never share a character with a neighbour that is one too, except CR
    /// LF. Verified against every assigned scalar in these ranges; a scalar the runtime does not
    /// know behaves the same in String. The commonest ranges, ASCII and CJK, come first.
    static func isPlainStarter(_ value: UInt32) -> Bool {
        switch value {
        case 0...0x7F, 0x3100...0x9FFF, 0xA0...0xAC, 0xAE...0x12F, 0x131...0x17F, 0x370...0x373, 0x375...0x37D,
             0x37F...0x386, 0x388...0x482, 0x48A...0x52F, 0x2010...0x2027, 0x2030...0x205E, 0x2190...0x2328,
             0x232B...0x23FF, 0x2500...0x27BF, 0x2B00...0x2BFF, 0x3000...0x3029, 0x3030...0x303F, 0x3041...0x3096,
             0x309B...0x30FF, 0xAC00...0xD7A3, 0xFF01...0xFF60, 0x1F000...0x1F1E5, 0x1F200...0x1F3FA,
             0x1F400...0x1FAFF, 0x20000...0x2F7FF, 0x30000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    /// UTF-16 units of the scalars whose lead bytes lie in `bytes[start..<end]`.
    static func utf16Count(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int {
        var count = 0
        for index in start..<end {
            let byte = bytes[index]
            count &+= (byte & 0xC0 != 0x80 ? 1 : 0) &+ (byte >= 0xF0 ? 1 : 0)
        }
        return count
    }

    /// Reads a text's characters forward from a character boundary. A character that is a single
    /// plain starter, the common case, is exposed as that scalar: two such
    /// scalars break between them (except CR LF) and are NFC-stable, so the scalar is the whole
    /// character and equal characters are equal scalars. Any other character is read through the
    /// String, preserving its grapheme boundaries and canonical equality.
    struct CharacterCursor {
        private static let noScalar = UInt32.max
        private let bytes: UnsafeBufferPointer<UInt8>
        private let text: String
        /// Where the current character starts.
        private(set) var offset: Int
        private var end = 0
        /// The current character's scalar when it is a single plain starter, else `noScalar`.
        private var scalar = Self.noScalar
        private var fallbackCharacter: Character = "\0"
        /// The scalar after the current one, decoded ahead.
        private var nextScalar: UInt32 = 0
        private var nextWidth = 0
        private var nextIsPlain = false

        init(bytes: UnsafeBufferPointer<UInt8>, text: String, offset: Int) {
            self.bytes = bytes
            self.text = text
            self.offset = offset
            if offset < bytes.count {
                decodeNext(at: offset)
                load()
            }
        }

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func advance() {
            offset = end
            if offset < bytes.count { load() }
        }

        /// The current whole character as a scalar when the plain-starter proof applies.
        var plainScalar: UInt32? { scalar == Self.noScalar ? nil : scalar }

        /// Only materializes a plain character when its caller needs the Character representation.
        var character: Character {
            if let scalar = Unicode.Scalar(scalar) { return Character(scalar) }
            return fallbackCharacter
        }

        /// The character boundary before the boundary `boundary > 0`.
        func characterStart(before boundary: Int) -> Int {
            let start = Self.scalarStart(endingAt: boundary, in: bytes)
            if start == 0 { return 0 }
            let value = Self.decode(bytes, at: start).value
            if UTF8Text.isPlainStarter(value) {
                let previous = Self.decode(bytes, at: Self.scalarStart(endingAt: start, in: bytes)).value
                if UTF8Text.isPlainStarter(previous), !(previous == 0x0D && value == 0x0A) {
                    return start
                }
            }
            let utf8 = text.utf8
            let index = text.index(before: utf8.index(utf8.startIndex, offsetBy: boundary))
            return utf8.distance(from: utf8.startIndex, to: index)
        }

        /// Reads the character at `offset`, whose first scalar is in `next*`.
        private mutating func load() {
            let value = nextScalar
            let scalarEnd = offset + nextWidth
            if nextIsPlain {
                if scalarEnd == bytes.count {
                    scalar = value
                    end = scalarEnd
                    return
                }
                decodeNext(at: scalarEnd)
                if nextIsPlain, !(value == 0x0D && nextScalar == 0x0A) {
                    scalar = value
                    end = scalarEnd
                    return
                }
            }
            scalar = Self.noScalar
            let utf8 = text.utf8
            fallbackCharacter = text[utf8.index(utf8.startIndex, offsetBy: offset)]
            end = offset + fallbackCharacter.utf8.count
            if end < bytes.count { decodeNext(at: end) }
        }

        private mutating func decodeNext(at index: Int) {
            (nextScalar, nextWidth) = Self.decode(bytes, at: index)
            nextIsPlain = UTF8Text.isPlainStarter(nextScalar)
        }

        /// The scalar at a scalar boundary of well-formed UTF-8, and its width.
        private static func decode(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> (value: UInt32, width: Int) {
            let lead = UInt32(bytes[index])
            if lead < 0x80 { return (lead, 1) }
            if lead < 0xE0 { return ((lead & 0x1F) << 6 | UInt32(bytes[index + 1] & 0x3F), 2) }
            if lead < 0xF0 {
                return ((lead & 0x0F) << 12 | UInt32(bytes[index + 1] & 0x3F) << 6 | UInt32(bytes[index + 2] & 0x3F), 3)
            }
            return (
                (lead & 0x07) << 18 | UInt32(bytes[index + 1] & 0x3F) << 12 | UInt32(bytes[index + 2] & 0x3F) << 6
                    | UInt32(bytes[index + 3] & 0x3F),
                4
            )
        }

        private static func scalarStart(endingAt boundary: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
            var start = boundary - 1
            while bytes[start] & 0xC0 == 0x80 { start -= 1 }
            return start
        }
    }
}

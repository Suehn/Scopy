import Foundation

public enum TextMetrics {
    /// “字数”展示：中文/日文/韩文按字计数；英文/数字按“词”计数（避免把一个单词按字母算多个字）。
    public static func displayWordUnitCount(for text: String) -> Int {
        var count = 0
        var inWord = false

        for scalar in text.unicodeScalars {
            if isCJKWordUnit(scalar) {
                if inWord {
                    count += 1
                    inWord = false
                }
                count += 1
                continue
            }

            let props = scalar.properties
            if props.isAlphabetic || props.numericType != nil {
                inWord = true
                continue
            }

            if inWord, (isInWordJoiner(scalar) || props.generalCategory == .nonspacingMark) {
                continue
            }

            if inWord {
                count += 1
                inWord = false
            }
        }

        if inWord {
            count += 1
        }

        return count
    }

    /// Returns a compact summary for UI display while scanning the string only once.
    ///
    /// - wordUnitCount: same semantics as `displayWordUnitCount(for:)`.
    /// - lineCount: same semantics as `text.components(separatedBy: .newlines).count`.
    public static func displayWordUnitCountAndLineCount(for text: String) -> (wordUnitCount: Int, lineCount: Int) {
        var wordUnitCount = 0
        var inWord = false
        var newlineSeparators = 0

        for scalar in text.unicodeScalars {
            if isNewlineSeparator(scalar) {
                newlineSeparators += 1
            }

            if isCJKWordUnit(scalar) {
                if inWord {
                    wordUnitCount += 1
                    inWord = false
                }
                wordUnitCount += 1
                continue
            }

            let props = scalar.properties
            if props.isAlphabetic || props.numericType != nil {
                inWord = true
                continue
            }

            if inWord, (isInWordJoiner(scalar) || props.generalCategory == .nonspacingMark) {
                continue
            }

            if inWord {
                wordUnitCount += 1
                inWord = false
            }
        }

        if inWord {
            wordUnitCount += 1
        }

        return (wordUnitCount, newlineSeparators + 1)
    }

    private static func isInWordJoiner(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0027, 0x2019: // ' and ’
            return true
        default:
            return false
        }
    }

    private static func isNewlineSeparator(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x000A, // LF
             0x000B, // VT
             0x000C, // FF
             0x000D, // CR
             0x0085, // NEL
             0x2028, // LS
             0x2029: // PS
            return true
        default:
            return false
        }
    }

    private static func isCJKWordUnit(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        // Han
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2F800...0x2FA1F:
            return true
        // Hiragana, Katakana
        case 0x3040...0x309F,
             0x30A0...0x30FF,
             0x31F0...0x31FF:
            return true
        // Hangul (Jamo + Syllables)
        case 0x1100...0x11FF,
             0x3130...0x318F,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}

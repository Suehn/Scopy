import XCTest
import WebKit
import ScopyKit

@testable import Scopy

/// The contract's typography, quote, code and table rules, read as computed styles from a real WebKit load of
/// the production document at 100% layout scale (one CSS px per contract px).
@MainActor
final class MarkdownComputedStyleTests: XCTestCase {
    private static let source = """
    # H1

    ## H2

    ### H3

    #### H4

    ##### H5

    ###### H6

    First paragraph with `inline code`.

    Second paragraph.

    - item

    > quoted

    ```swift
    let x = 1
    ```

    | Name | Value |
    | --- | --- |
    | a | 1 |
    | b | 2 |
    """

    func testDocumentMatchesContractTypographyQuoteCodeAndTableRules() throws {
        let document = try LiveMarkdownDocument()
        defer { document.close() }
        let context = MarkdownRenderContextResolver.defaultContext(for: Self.source, layoutScale: .percent100)
        XCTAssertTrue(try document.load(MarkdownHTMLRenderer.render(markdown: Self.source, context: context)))
        XCTAssertTrue(document.isRenderReady, "\(document.evaluate("JSON.stringify(window.ScopyDocument.state)") ?? "no state")")

        let script = """
        (() => {
          const root = document.getElementById('content');
          const pick = (selector, pseudo, names) => {
            const node = root.querySelector(selector);
            if (!node) { return null; }
            const style = getComputedStyle(node, pseudo || null);
            return names.map((name) => style.getPropertyValue(name)).join(' | ');
          };
          const text = ['font-size', 'line-height', 'font-weight'];
          const block = ['margin-top', 'margin-bottom'];
          return JSON.stringify({
            body: getComputedStyle(document.body).fontSize + ' | ' + getComputedStyle(document.body).lineHeight,
            h1: pick('h1', null, text.concat(block)),
            h2: pick('h2', null, text.concat(block)),
            h3: pick('h3', null, text.concat(block)),
            h4: pick('h4', null, text.concat(block)),
            h5: pick('h5', null, text.concat(block)),
            h6: pick('h6', null, text.concat(block)),
            paragraph: pick('p', null, text.concat(block)),
            adjacentParagraph: pick('p + p', null, ['margin-top']),
            list: pick('ul', null, ['margin-top', 'margin-bottom', 'padding-inline-start']),
            listItem: pick('li', null, text.concat(['padding-inline-start'])),
            blockquote: pick('blockquote', null, text.concat(['margin-bottom', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left'])),
            quoteBar: pick('blockquote', '::after', ['width', 'top', 'bottom', 'border-top-left-radius']),
            inlineCode: pick('p code', null, ['font-size', 'font-weight', 'padding-top', 'padding-left', 'border-top-left-radius', 'overflow-wrap']),
            codeCard: pick('pre', null, ['font-size', 'line-height', 'border-top-left-radius', 'white-space', 'overflow-x']),
            table: pick('table', null, ['font-size', 'line-height']),
            header: pick('thead th', null, ['font-weight', 'line-height', 'padding-top', 'padding-bottom']),
            cell: pick('tbody td', null, ['padding-top', 'padding-bottom', 'word-break', 'overflow-wrap']),
            nonFinalCell: pick('tbody td:not(:last-child)', null, ['padding-inline-end']),
            lastRowCell: pick('tbody tr:last-child td', null, ['border-bottom-width', 'padding-bottom'])
          });
        })()
        """
        let json = try XCTUnwrap(document.evaluate(script) as? String)
        let styles = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])

        let expected: [String: String] = [
            "body": "16px | 26px",
            "h1": "24px | 32px | 600 | 0px | 8px",
            "h2": "20px | 28px | 600 | 16px | 4px",
            "h3": "18px | 28px | 600 | 16px | 4px",
            "h4": "16px | 24px | 600 | 16px | 0px",
            "h5": "16px | 26px | 600 | 0px | 0px",
            "h6": "16px | 26px | 400 | 0px | 0px",
            "paragraph": "16px | 26px | 400 | 4px | 4px",
            "adjacentParagraph": "16px",
            "list": "0px | 0px | 26px",
            "listItem": "16px | 26px | 400 | 6px",
            "blockquote": "16px | 24px | 400 | 8px | 8px | 0px | 8px | 24px",
            "quoteBar": "4px | 8px | 8px | 2px",
            "inlineCode": "14px | 500 | 2.4px | 4.8px | 4px | anywhere",
            "codeCard": "14px | 20px | 24px | pre | auto",
            "table": "14px | 24px",
            "header": "600 | 16px | 8px | 8px",
            "cell": "10px | 10px | normal | anywhere",
            "nonFinalCell": "24px",
            "lastRowCell": "0px | 24px"
        ]
        for (name, value) in expected {
            XCTAssertEqual(styles[name], value, name)
        }
    }
}

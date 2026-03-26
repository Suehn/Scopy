import Foundation

enum MarkdownTaskListRuntime {
    static let style = """
      .task-list-container {
        padding-left: 0;
      }
      .task-list-item {
        list-style: none;
      }
      .task-list-item > p:first-child {
        margin-top: 0;
      }
      .task-list-item-checkbox {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 1.05em;
        height: 1.05em;
        margin-right: 0.5em;
        border: 1px solid rgba(127,127,127,0.55);
        border-radius: 0.22em;
        box-sizing: border-box;
        vertical-align: text-top;
        transform: translateY(0.08em);
        flex: 0 0 auto;
      }
      .task-list-item-checkbox[data-checked="true"]::after {
        content: "✓";
        font-size: 0.78em;
        line-height: 1;
      }
      .task-list-item-checkbox + input[type="checkbox"] {
        display: none !important;
      }
    """

    static let bootstrapScript = """
        <script>
          (function () {
            function firstMeaningfulTextNode(node) {
              if (!node) { return null; }
              var child = node.firstChild;
              while (child) {
                if (child.nodeType === Node.TEXT_NODE && /\\S/.test(child.nodeValue || '')) {
                  return child;
                }
                if (child.nodeType === Node.ELEMENT_NODE) {
                  var tag = child.tagName;
                  if (tag !== 'UL' && tag !== 'OL') {
                    var nested = firstMeaningfulTextNode(child);
                    if (nested) { return nested; }
                  }
                }
                child = child.nextSibling;
              }
              return null;
            }

            function markerTargetForListItem(item) {
              if (!item) { return null; }
              var child = item.firstChild;
              while (child) {
                if (child.nodeType === Node.TEXT_NODE && /\\S/.test(child.nodeValue || '')) {
                  return { container: item, node: child };
                }
                if (child.nodeType === Node.ELEMENT_NODE) {
                  var tag = child.tagName;
                  if (tag === 'UL' || tag === 'OL') { break; }
                  var nested = firstMeaningfulTextNode(child);
                  if (nested) {
                    return { container: child, node: nested };
                  }
                }
                child = child.nextSibling;
              }
              return null;
            }

            function applyTaskListItem(item) {
              if (!item || item.classList.contains('task-list-item')) { return; }
              var target = markerTargetForListItem(item);
              if (!target || !target.node) { return; }
              var value = target.node.nodeValue || '';
              var match = value.match(/^(\\s*)\\[([ xX])\\](\\s+|$)/);
              if (!match) { return; }

              target.node.nodeValue = (match[1] || '') + value.slice(match[0].length);

              var checkbox = document.createElement('span');
              checkbox.className = 'task-list-item-checkbox';
              checkbox.setAttribute('role', 'checkbox');
              checkbox.setAttribute('aria-checked', /[xX]/.test(match[2]) ? 'true' : 'false');
              checkbox.setAttribute('data-checked', /[xX]/.test(match[2]) ? 'true' : 'false');

              target.container.insertBefore(checkbox, target.node);
              item.classList.add('task-list-item');

              var list = item.parentElement;
              if (list && (list.tagName === 'UL' || list.tagName === 'OL')) {
                list.classList.add('task-list-container');
              }

              var nativeInputs = item.querySelectorAll('input[type="checkbox"]');
              for (var i = 0; i < nativeInputs.length; i++) {
                nativeInputs[i].setAttribute('hidden', 'hidden');
                nativeInputs[i].setAttribute('aria-hidden', 'true');
              }
            }

            window.__scopyApplyTaskLists = function (root) {
              if (!root) { return; }
              var items = root.querySelectorAll('li');
              for (var i = 0; i < items.length; i++) {
                applyTaskListItem(items[i]);
              }
            };
          })();
        </script>
    """
}

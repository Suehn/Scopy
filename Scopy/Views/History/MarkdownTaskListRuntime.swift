import Foundation

enum MarkdownTaskListRuntime {
    static let style = """
      .task-list-container {
        list-style-type: disc;
        padding-left: 26px;
        margin-top: 0;
        margin-bottom: 0;
      }
      .task-list-item {
        list-style-type: disc;
        padding-left: 6px;
      }
      .task-list-item::marker {
        font-size: 16px;
        line-height: 26px;
        font-weight: 700;
        color: rgb(13, 13, 13);
      }
      .task-list-item > p:first-child {
        display: inline;
        margin-top: 0;
        margin-bottom: 0;
      }
      .task-list-item-checkbox {
        display: inline-block;
        position: static;
        width: 16px;
        height: 16px;
        margin: 0 0.35em 0 0;
        border: 1px solid rgb(142, 142, 142);
        border-radius: 4px;
        background: transparent;
        box-sizing: border-box;
        vertical-align: -3px;
      }
      .task-list-item-checkbox[data-checked="true"]::after {
        content: "✓";
        display: block;
        width: 14px;
        height: 14px;
        color: #fff;
        background: rgb(0, 79, 153);
        border-radius: 3px;
        font-size: 12px;
        line-height: 14px;
        text-align: center;
        transform: translate(-1px, -1px);
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

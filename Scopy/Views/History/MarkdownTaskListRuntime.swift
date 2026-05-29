import Foundation

enum MarkdownTaskListRuntime {
    static let style = """
      .task-list-container {
        list-style-type: none;
        padding-left: 4px;
        margin: 8px 0 16px 0;
      }
      .task-list-item {
        display: flex;
        align-items: baseline;
        gap: 8px;
        list-style: none;
        padding-left: 0;
        margin: 8px 0;
        min-height: 24px;
      }
      .task-list-item::marker {
        content: "";
      }
      .task-list-item > p {
        display: block;
        margin-top: 0;
        margin-bottom: 0;
      }
      .task-list-item-marker {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        flex: none;
        width: 16px;
        height: 16px;
        margin: 0;
        border: 1px solid rgb(142, 142, 142);
        border-radius: 4px;
        background-color: transparent;
        box-sizing: border-box;
        transform: translateY(2px);
        pointer-events: none;
      }
      .task-list-item-marker[data-checked="true"] {
        border-color: rgb(0, 122, 255);
        background-color: rgb(0, 122, 255);
      }
      .task-list-item-marker[data-checked="true"]::after {
        content: "";
        width: 8px;
        height: 5px;
        border-left: 2px solid #fff;
        border-bottom: 2px solid #fff;
        transform: rotate(-45deg) translate(1px, -1px);
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

            function firstTaskInput(node) {
              if (!node) { return null; }
              var child = node.firstChild;
              while (child) {
                if (child.nodeType === Node.ELEMENT_NODE) {
                  var tag = child.tagName;
                  if (tag === 'UL' || tag === 'OL') { break; }
                  if (tag === 'INPUT' && (child.getAttribute('type') || '').toLowerCase() === 'checkbox') {
                    return child;
                  }
                  var nested = firstTaskInput(child);
                  if (nested) { return nested; }
                }
                child = child.nextSibling;
              }
              return null;
            }

            function createTaskMarker(checked) {
              var marker = document.createElement('span');
              marker.className = 'task-list-item-marker';
              marker.setAttribute('role', 'checkbox');
              marker.setAttribute('aria-checked', checked ? 'true' : 'false');
              marker.setAttribute('data-checked', checked ? 'true' : 'false');
              return marker;
            }

            function hideNativeTaskInput(input) {
              input.setAttribute('hidden', 'hidden');
              input.setAttribute('aria-hidden', 'true');
              input.setAttribute('tabindex', '-1');
            }

            function markTaskListContainer(item) {
              item.classList.add('task-list-item');
              var list = item.parentElement;
              if (list && (list.tagName === 'UL' || list.tagName === 'OL')) {
                list.classList.add('task-list-container');
              }
            }

            function normalizeExistingTaskInput(item) {
              var existingMarker = item.querySelector('.task-list-item-marker');
              if (existingMarker) {
                markTaskListContainer(item);
                return true;
              }

              var nativeInput = firstTaskInput(item);
              if (!nativeInput) { return false; }

              var checked = nativeInput.checked || nativeInput.hasAttribute('checked');
              hideNativeTaskInput(nativeInput);
              var marker = createTaskMarker(checked);

              var anchor = nativeInput;
              if (nativeInput.parentElement && nativeInput.parentElement !== item && nativeInput.parentElement.parentElement === item) {
                anchor = nativeInput.parentElement;
              }
              item.insertBefore(marker, anchor);
              markTaskListContainer(item);
              return true;
            }

            function applyTaskListItem(item) {
              if (!item) { return; }
              if (normalizeExistingTaskInput(item)) { return; }

              var target = markerTargetForListItem(item);
              if (!target || !target.node) { return; }
              var value = target.node.nodeValue || '';
              var match = value.match(/^(\\s*)\\[([ xX])\\](\\s+|$)/);
              if (!match) { return; }

              target.node.nodeValue = (match[1] || '') + value.slice(match[0].length);

              var marker = createTaskMarker(/[xX]/.test(match[2]));

              if (target.container === item) {
                item.insertBefore(marker, target.node);
              } else {
                item.insertBefore(marker, target.container);
              }
              markTaskListContainer(item);

              var nativeInputs = item.querySelectorAll('input[type="checkbox"]');
              for (var i = 0; i < nativeInputs.length; i++) {
                hideNativeTaskInput(nativeInputs[i]);
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

import WebKit

extension Notification.Name {
    /// A text field in a desktop window gained or lost DOM focus; object is true (focus) or false (blur).
    static let iDeskTypingFocus = Notification.Name("iDeskTypingFocus")
}

/// Auto keyboard, like native iOS: tapping a text field in any window opens the iPhone keyboard,
/// tapping outside it or finishing closes it. A page script reports DOM focus changes; the phone's
/// desktop listens and raises or lowers the keyboard it already mirrors onto the desktop.
final class TypingFocus: NSObject, WKScriptMessageHandler {
    static let shared = TypingFocus()
    static let messageName = "ideskTypingFocus"

    /// The web view whose field currently has DOM focus. Tapping the desktop's background blurs it,
    /// so the keyboard closes and the next tap on the field reports focus anew (0.9.15).
    private(set) weak var focusedWebView: WKWebView?

    static let script = WKUserScript(source: """
        (function() {
            function isField(el) {
                if (!el || el.disabled || el.readOnly) return false;
                var t = el.tagName;
                if (t === 'TEXTAREA' || t === 'SELECT') return true;
                if (t === 'INPUT') {
                    var ty = (el.type || 'text').toLowerCase();
                    return ['text','search','email','url','tel','password','number'].indexOf(ty) >= 0;
                }
                return el.isContentEditable === true;
            }
            var NAME = '\(messageName)';
            document.addEventListener('focusin', function(e) {
                if (isField(e.target)) window.webkit.messageHandlers[NAME].postMessage('focus');
            }, true);
            document.addEventListener('focusout', function(e) {
                if (isField(e.target)) window.webkit.messageHandlers[NAME].postMessage('blur');
            }, true);
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        if body == "focus" { focusedWebView = message.webView }
        else if focusedWebView === message.webView { focusedWebView = nil }
        NotificationCenter.default.post(name: .iDeskTypingFocus, object: body == "focus")
    }
}

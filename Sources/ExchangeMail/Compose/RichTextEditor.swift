import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// WKWebView(contentEditable) 기반 리치 텍스트 편집기. 작성 창과 서명 편집기가 같이 쓴다.
/// 결과는 HTML이고, 넣은 그림은 data: URI로 들어간다 (alt에 파일 이름을 담아 첨부 이름으로 쓴다).
@Observable
final class RichTextController: NSObject, WKNavigationDelegate {
    /// 편집기의 지금 HTML. 프로그램이 넣은 값과 사람이 고친 값 모두.
    private(set) var html = ""
    /// 사람이 고쳤을 때만 불린다 (서명 편집기가 저장에 쓴다).
    @ObservationIgnored var onUserEdit: ((String) -> Void)?
    /// 편집기에 파일을 끌어다 놓았을 때 (S-017). 없으면 그림은 본문에 넣고 나머지는 무시한다 (서명 편집기).
    @ObservationIgnored var onFileDrop: (([URL]) -> Void)?

    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var pendingHTML: String?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var pendingFocus = false

    static let editorPage = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    :root{color-scheme:light dark}
    html,body{margin:0;height:100%}
    body{font:14px -apple-system,'Apple SD Gothic Neo',sans-serif}
    #editor{min-height:100%;padding:16px 20px;outline:none;box-sizing:border-box;word-wrap:break-word}
    img{max-width:100%;height:auto}
    blockquote[type=cite]{margin-left:0;padding-left:10px;border-left:2px solid #b4b4b4}
    </style></head><body><div id="editor" contenteditable="true"></div><script>
    const ed=document.getElementById('editor');
    function post(user){window.webkit.messageHandlers.change.postMessage({html:ed.innerHTML,user:user})}
    ed.addEventListener('input',()=>post(true));
    function setHTML(h){ed.innerHTML=h;post(false)}
    function cmd(c,v){document.execCommand('styleWithCSS',false,true);document.execCommand(c,false,v);post(true)}
    function fontSize(px){
      document.execCommand('styleWithCSS',false,false);
      document.execCommand('fontSize',false,'7');
      ed.querySelectorAll('font[size="7"]').forEach(f=>{f.removeAttribute('size');f.style.fontSize=px+'px'});
      post(true)}
    function insertHTML(h){ed.focus();document.execCommand('insertHTML',false,h);post(true)}
    function replaceSignature(h){
      const old=ed.querySelectorAll('[data-signature]');
      const anchor=old.length?old[0]:null;
      if(h){
        const t=document.createElement('div');t.innerHTML=h;const n=t.firstElementChild;
        if(anchor){anchor.replaceWith(n)}
        else{const q=ed.querySelector('[data-quote]');if(q){q.before(n)}else{ed.appendChild(n)}}
      }else if(anchor){anchor.remove()}
      old.forEach((e,i)=>{if(i>0)e.remove()});
      post(true)}
    function quoteMore(){document.execCommand('styleWithCSS',false,false);document.execCommand('indent');
      const s=window.getSelection();if(s.rangeCount){let n=s.getRangeAt(0).startContainer;
        while(n&&n!==ed){if(n.nodeName==='BLOCKQUOTE'){n.setAttribute('type','cite');n.removeAttribute('style');break}n=n.parentNode}}
      post(true)}
    function setSpellcheck(on){ed.spellcheck=on}
    // 고른 글이 없으면 서명과 인용문을 뺀 본문을 고른다 (Siri로 글쓰기가 다룰 글).
    function selectForWriting(){
      const s=window.getSelection();
      if(s.rangeCount&&!s.isCollapsed&&ed.contains(s.anchorNode)) return;
      const r=document.createRange();r.selectNodeContents(ed);
      const stop=ed.querySelector('[data-signature],[data-quote]');
      if(stop){r.setEndBefore(stop)}
      s.removeAllRanges();s.addRange(r);ed.focus()}
    function focusStart(){const r=document.createRange();r.setStart(ed,0);r.collapse(true);
      const s=window.getSelection();s.removeAllRanges();s.addRange(r);ed.focus()}
    </script></body></html>
    """

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.userContentController.add(ScriptProxy(self), name: "change")
        // Siri로 글쓰기 (Apple Intelligence 글쓰기 도구): 고쳐 쓰기, 교정, 요약, 말투 바꾸기를 편집기 안에서 한다.
        config.writingToolsBehavior = .complete
        let wv = WKWebView(frame: .zero, configuration: config)
        // 웹 편집기는 끌어다 놓은 파일을 file:// 링크나 그림으로 넣어 버린다. 드래그 등록을 풀어
        // 드롭이 SwiftUI의 .dropDestination으로 가게 하고, 앱이 첨부로 받는다 (S-017).
        wv.unregisterDraggedTypes()
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.loadHTMLString(Self.editorPage, baseURL: nil)
        webView = wv
        return wv
    }

    /// 편집기 영역에 놓은 파일. 작성 창은 첨부로, 서명 편집기는 그림만 본문에 넣는다.
    func dropped(_ urls: [URL]) {
        if let onFileDrop {
            onFileDrop(urls)
        } else {
            for url in urls where UTTypeLookup.isImage(url) { insertImage(url: url) }
        }
    }

    fileprivate func receive(html newHTML: String, user: Bool) {
        html = newHTML
        if user { onUserEdit?(newHTML) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        webView.unregisterDraggedTypes()
        js("setSpellcheck(\(spellcheck))")
        if let p = pendingHTML {
            pendingHTML = nil
            setHTML(p)
        }
        if pendingFocus {
            pendingFocus = false
            focusStart()
        }
    }

    // MARK: 명령

    private func js(_ s: String) {
        webView?.evaluateJavaScript(s, completionHandler: nil)
    }

    /// Swift 문자열을 JavaScript 문자열 리터럴로.
    private func literal(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    func setHTML(_ h: String) {
        html = h
        guard ready else { pendingHTML = h; return }
        js("setHTML(\(literal(h)))")
    }

    func command(_ name: String, _ value: String? = nil) {
        js("cmd(\(literal(name)), \(value.map(literal) ?? "null"))")
    }

    func setFontFamily(_ family: String) { command("fontName", family) }

    /// 설정 > 작성 > 맞춤법 검사. 편집기가 아직 안 떴으면 뜰 때 건다.
    @ObservationIgnored var spellcheck = true {
        didSet { if ready { js("setSpellcheck(\(spellcheck))") } }
    }

    /// Siri로 글쓰기: 고른 글(없으면 서명·인용문 앞까지의 본문)에 macOS 글쓰기 도구를 연다.
    /// Apple Intelligence가 꺼져 있으면 아무 일도 일어나지 않는다.
    func showWritingTools() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("selectForWriting()") { _, _ in
            MainActor.assumeIsolated {
                _ = NSApp.sendAction(#selector(NSResponder.showWritingTools(_:)), to: nil, from: webView)
            }
        }
    }

    // 포맷 메뉴 (M17)
    func indent() { command("indent") }
    func outdent() { command("outdent") }
    /// 인용 단계 늘리기: 고른 문단을 인용(blockquote type=cite)으로 한 단계 더 감싼다.
    func quoteMore() { js("quoteMore()") }
    /// 인용 단계 줄이기
    func quoteLess() { command("outdent") }
    func setFontSize(_ px: Int) { js("fontSize(\(px))") }

    func setColor(_ color: NSColor) {
        // 시스템 색(labelColor 등)은 RGB 값이 없으므로 sRGB로 바꾼 뒤 읽는다. 실패하면 검정.
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        command("foreColor", hex)
    }

    func replaceSignature(blockHTML: String) { js("replaceSignature(\(literal(blockHTML)))") }
    /// 커서를 본문 맨 앞에 둔다 (답장할 때). 편집기가 아직 준비 중이면 준비된 뒤에.
    func focusStart() {
        guard ready else { pendingFocus = true; return }
        webView?.window?.makeFirstResponder(webView)
        js("focusStart()")
    }

    func insertLink(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "https://" else { return }
        command("createLink", trimmed)
    }

    /// 그림 넣기: data: URI로 넣고 파일 이름은 alt에 둔다 → 보낼 때 첨부 이름이 된다.
    func insertImage(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = UTTypeLookup.mimeType(for: url, fallback: "image/png")
        let name = HTMLAttr.escape(url.lastPathComponent.precomposedStringWithCanonicalMapping)
        insertHTML("<img src=\"data:\(mime);base64,\(data.base64EncodedString())\" alt=\"\(name)\" style=\"max-width:100%\">")
    }

    func insertHTML(_ h: String) { js("insertHTML(\(literal(h)))") }
}

/// WKUserContentController는 핸들러를 강하게 잡는다. 컨트롤러가 풀리도록 약한 참조로 넘긴다.
private final class ScriptProxy: NSObject, WKScriptMessageHandler {
    weak var target: RichTextController?

    init(_ target: RichTextController) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let html = body["html"] as? String else { return }
        target?.receive(html: html, user: (body["user"] as? Bool) ?? true)
    }
}

enum UTTypeLookup {
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func mimeType(for url: URL, fallback: String) -> String {
        ComposeSender.mimeType(for: url) == "application/octet-stream" ? fallback : ComposeSender.mimeType(for: url)
    }
}

enum HTMLAttr {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct RichTextEditor: NSViewRepresentable {
    let controller: RichTextController

    func makeNSView(context: Context) -> WKWebView { controller.makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 글꼴·크기·색·굵게·정렬·목록·링크·그림 도구 막대 (작성 창과 서명 편집기 공용).
struct FormatToolbar: View {
    let controller: RichTextController
    /// 서식 막대에 Siri로 글쓰기 단추를 둘지 (작성 창은 창 도구 막대에 둔다)
    var showsWritingTools = true
    @State private var family = "Apple SD Gothic Neo"
    @State private var size = 14
    @State private var color = Color.primary

    private let families = NSFontManager.shared.availableFontFamilies
    private let sizes = [10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 40]

    var body: some View {
        HStack(spacing: Space.sm) {
            Menu {
                ForEach(families, id: \.self) { f in
                    Button(f) {
                        family = f
                        controller.setFontFamily(f)
                    }
                }
            } label: {
                Text(family).lineLimit(1)
            }
            .menuStyle(.button)
            .fixedSize()
            .help("글꼴")

            Picker("크기", selection: $size) {
                ForEach(sizes, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("글자 크기")
            .onChange(of: size) { _, v in controller.setFontSize(v) }

            ColorPicker("글자 색", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .help("글자 색")
                .onChange(of: color) { _, v in controller.setColor(NSColor(v)) }

            Divider().frame(height: Space.lg)
            ControlGroup {
                button("bold", "굵게", "bold")
                button("italic", "기울임", "italic")
                button("underline", "밑줄", "underline")
            }
            .fixedSize()
            ControlGroup {
                button("text.alignleft", "왼쪽 정렬", "justifyLeft")
                button("text.aligncenter", "가운데 정렬", "justifyCenter")
                button("text.alignright", "오른쪽 정렬", "justifyRight")
            }
            .fixedSize()
            button("list.bullet", "글머리 기호 목록", "insertUnorderedList")
            Button("링크", systemImage: "link") { addLink() }
                .labelStyle(.iconOnly)
                .help("링크 넣기")
            Button("그림", systemImage: "photo") { pickImage() }
                .labelStyle(.iconOnly)
                .help("그림 넣기")
            if showsWritingTools {
                Button("Siri로 글쓰기", systemImage: "apple.writing.tools") { controller.showWritingTools() }
                    .labelStyle(.iconOnly)
                    .help("Siri로 글쓰기")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    private func button(_ symbol: String, _ title: String, _ command: String) -> some View {
        Button(title, systemImage: symbol) { controller.command(command) }
            .labelStyle(.iconOnly)
            .help(title)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach { controller.insertImage(url: $0) } }
    }

    private func addLink() {
        let alert = NSAlert()
        alert.messageText = "링크 넣기"
        alert.informativeText = "고른 글자에 연결할 주소를 넣으세요."
        alert.addButton(withTitle: "넣기")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = "https://"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn { controller.insertLink(field.stringValue) }
    }
}

/// 앞에 있는 작성 창의 편집기. 포맷 메뉴가 이 편집기에 동작한다 (M17).
nonisolated struct RichTextEditorKey: FocusedValueKey {
    typealias Value = RichTextController
}

extension FocusedValues {
    nonisolated var richTextEditor: RichTextController? {
        get { self[RichTextEditorKey.self] }
        set { self[RichTextEditorKey.self] = newValue }
    }
}

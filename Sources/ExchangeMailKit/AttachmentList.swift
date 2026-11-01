import Foundation

/// 작성 창 첨부 목록 규칙 (S-017). 파일 선택 창과 끌어다 놓기가 같이 쓴다.
public enum AttachmentList {
    public struct Result: Equatable, Sendable {
        public var files: [URL]
        /// 폴더처럼 첨부할 수 없어 건너뛴 항목의 이름
        public var skipped: [String]
    }

    /// 새 파일을 끝에 붙인다. 이미 있는 파일(같은 경로)은 다시 넣지 않고, 폴더는 건너뛴다.
    public static func merge(_ current: [URL], adding new: [URL],
                             isDirectory: (URL) -> Bool = AttachmentList.isDirectory) -> Result {
        var files = current
        var seen = Set(current.map(key))
        var skipped: [String] = []
        for url in new {
            if isDirectory(url) {
                skipped.append(url.lastPathComponent)
                continue
            }
            guard seen.insert(key(url)).inserted else { continue }
            files.append(url)
        }
        return Result(files: files, skipped: skipped)
    }

    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

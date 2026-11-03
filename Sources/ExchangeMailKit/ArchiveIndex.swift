import Foundation

// 나의 Mac에 상자의 목록 색인 (S-055).
// 상자를 열 때마다 mbox 전체(첨부 포함)를 해석하면 느리다. 가져올 때 한 번 메일마다 요약(제목, 사람, 날짜,
// 미리보기, 검색용 글)과 파일 안 위치를 만들어 저장해 두고, 열 때는 색인만 읽는다.
// 본문·첨부는 고른 메일 한 통만 그 위치에서 읽어 해석한다.

/// 목록 한 줄과 검색에 필요한 것만. 본문·첨부 바이트는 없다.
public struct ArchivedSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    /// mbox 파일 안에서 이 메일(구분 줄 포함)의 위치
    public var offset: Int
    public var length: Int
    public var subject: String
    public var from: String
    public var to: String
    public var date: Date?
    public var preview: String
    public var hasAttachments: Bool
    /// MailArchive.searchText (소문자, 길면 앞부분)
    public var search: String

    public var title: String { subject.isEmpty ? L("(제목 없음)") : subject }
}

public enum ArchiveIndex {
    /// 색인 형식이 바뀌면 올린다 (파일 이름에 들어가 예전 색인은 다시 만든다).
    public static let version = 1
    static let searchLimit = 20_000

    /// FAKUKU Mail이 쓴 mbox(MailArchive.mboxEntry)의 메일별 위치.
    /// 메일 사이는 빈 줄 + "From "이고, 본문 안의 "From " 줄은 ">From "으로 바꿔 두었다.
    public static func entryRanges(_ data: Data) -> [Range<Int>] {
        guard !data.isEmpty else { return [] }
        let marker = Data("\n\nFrom ".utf8)
        var starts: [Int] = []
        if data.starts(with: Data("From ".utf8)) { starts.append(data.startIndex) }
        var searchFrom = data.startIndex
        while let r = data.range(of: marker, in: searchFrom..<data.endIndex) {
            starts.append(r.lowerBound + 2)
            searchFrom = r.lowerBound + 2
        }
        guard !starts.isEmpty else { return [data.startIndex..<data.endIndex] }
        return starts.enumerated().map { i, start in
            start..<(i + 1 < starts.count ? starts[i + 1] : data.endIndex)
        }
    }

    /// mbox 파일 전체의 요약 (최근 메일부터)
    public static func summaries(ofMbox data: Data) -> [ArchivedSummary] {
        entryRanges(data).enumerated().compactMap { i, range in
            guard let raw = MailArchive.split(Data(data[range])).first else { return nil }
            return summary(MailArchive.parse(raw, id: i), offset: range.lowerBound - data.startIndex, length: range.count)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public static func summary(_ mail: ArchivedMail, offset: Int, length: Int) -> ArchivedSummary {
        ArchivedSummary(id: mail.id, offset: offset, length: length, subject: mail.subject, from: mail.from, to: mail.to,
                        date: mail.date, preview: MailArchive.preview(mail),
                        hasAttachments: mail.attachments.contains { !$0.isInline },
                        search: String(MailArchive.searchText(mail).prefix(searchLimit)))
    }

    /// 요약의 위치에서 메일 한 통을 읽어 해석한다.
    public static func message(_ summary: ArchivedSummary, inFile url: URL) throws -> ArchivedMail {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(summary.offset))
        let bytes = try handle.read(upToCount: summary.length) ?? Data()
        let raw = MailArchive.split(bytes).first ?? bytes
        return MailArchive.parse(raw, id: summary.id)
    }

    public static func encode(_ list: [ArchivedSummary]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(list)
    }

    public static func decode(_ data: Data) throws -> [ArchivedSummary] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ArchivedSummary].self, from: data)
    }
}

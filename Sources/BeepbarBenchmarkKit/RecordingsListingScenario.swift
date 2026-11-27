import BeepbarCore
import Foundation

/// The Recordings refresh after a sync (#275), as far as Core can measure it: the decisions of
/// `RecmanArchiveListing` over a synthetic Recman archive, plus a count of what a real session
/// would ask WebKit for.
///
/// What this is not: WebKit. A fake archive has no page loads, no JavaScript and no network, so
/// the wall time and memory here are the cost of decoding and judging pages (microseconds per
/// page) and say nothing about the real cost of a course, which is dominated by main-frame loads.
/// The pages, scripts and loads (parameters of the result, constant across runs and checked to be) are therefore a model of `RecmanWebSession.recordings(for:)`
/// and `search` (keep in step with them): per course one archive probe, `clearColumnFilters`
/// (assumed already clean), `search` (one load), `hundredPerPage` (one load, only when the
/// archive shows a "prossima" link, i.e. more than ten rows) and, per page, one archive probe and
/// one `resultsPage`, with `nextPage` (one load) between pages.
///
/// Archive model: 100 rows a page after `hundredPerPage`, a declared total on every page, one
/// academic year, every row the course's own. Rows are unique.
package enum RecordingsListingScenario {
    package static let rowsPerPage = 100

    /// Pages a course with `rows` recordings is read in.
    package static func pages(rows: Int) -> Int { max(1, (rows + rowsPerPage - 1) / rowsPerPage) }

    /// The results pages, as the `resultsPage` script would return them (JSON), for one course.
    static func archive(code: String, rows: Int) -> [String] {
        let pageCount = pages(rows: rows)
        return (0..<pageCount).map { page in
            let range = (page * rowsPerPage)..<min(rows, (page + 1) * rowsPerPage)
            let rowJSON = range.map { index -> String in
                let day = String(format: "%02d/%02d/2026 10:00", index % 28 + 1, (index / 28) % 12 + 1)
                let url = "https://onlineservices.polimi.it\(RecmanURLPolicy.archivePath)?evn_preview_link=evento&transfer_id=\(code)-\(index)"
                return #"{"cells":["","2026 / 27","\#(day)","\#(code) - SYNTHETIC COURSE","Lezione","Lecture \#(index)","","90 min","120 MB"],"previewURL":"\#(url)"}"#
            }.joined(separator: ",")
            return #"{"rows":[\#(rowJSON)],"total":\#(rows),"hasNext":\#(page < pageCount - 1),"saysEmpty":false,"searchedCode":"\#(code)","searchedYear":"2026"}"#
        }
    }

    struct Counts: Equatable {
        var pages = 0, scripts = 0, loads = 0, recordings = 0
    }

    /// Lists every course the way `RecmanWebSession.search` does (decode a page, `add` it, follow
    /// "prossima") and returns the counts. Throws when a listing is incomplete.
    static func listAll(_ archives: [(key: RecmanCourseKey, pages: [String])], rows: Int) throws -> Counts {
        var counts = Counts()
        for (key, pages) in archives {
            counts.scripts += 4   // archive probe, clearColumnFilters, search, hundredPerPage
            counts.loads += 1     // search
            if rows > 10 { counts.loads += 1 }   // the "100" link
            var listing = RecmanArchiveListing(key: key)
            for json in pages {
                counts.scripts += 2   // archive probe, resultsPage
                counts.pages += 1
                guard try listing.add(try RecmanResultsPage.decode(json)) else { break }
                counts.scripts += 1   // nextPage
                counts.loads += 1
            }
            counts.recordings += listing.recordings.count
        }
        return counts
    }

    package static func run(courses: Int, rowsPerCourse rows: Int, runs: Int, warmup: Int) async throws -> ScenarioResult {
        let archives = try (0..<courses).map { index -> (key: RecmanCourseKey, pages: [String]) in
            let code = String(format: "%06d", 100_000 + index)
            guard let key = RecmanCourseKey(courseCode: code, academicYear: 2026) else { throw BenchmarkError.setup("invalid synthetic course \(code)") }
            return (key, archive(code: code, rows: rows))
        }
        var samples: [RunSample] = []
        var counted: [Counts] = []
        let clock = ContinuousClock()
        for index in 0..<(warmup + runs) {
            let footprint = PeakFootprintSampler.footprint()
            guard let resources = ResourceUsage.current() else { throw BenchmarkError.setup("proc_pid_rusage failed") }
            let sampler = PeakFootprintSampler()
            let start = clock.now
            let result = try listAll(archives, rows: rows)
            let wall = clock.now - start
            let peak = sampler.stop()
            guard index >= warmup else { continue }
            counted.append(result)
            samples.append(RunSample(
                wallMilliseconds: Scenarios.milliseconds(wall), resources: (ResourceUsage.current() ?? resources).since(resources),
                peakFootprintGrowth: Int64(peak) - Int64(footprint), peakFootprint: peak, database: .init(), fileStore: .init(), upstream: UpstreamCounters(),
                installed: 0, conflicts: 0, failures: 0))
        }
        let checks = [
            "every course listed completely": counted.allSatisfy { $0.recordings == courses * rows },
            "every page read": counted.allSatisfy { $0.pages == courses * pages(rows: rows) },
            "same work every run": Set(counted.map { "\($0)" }).count == 1,
        ]
        return ScenarioResult(
            name: "recordings-listing", parameters: ["courses": "\(courses)", "rowsPerCourse": "\(rows)", "pages": "\(counted.first?.pages ?? 0)", "scripts": "\(counted.first?.scripts ?? 0)", "loads": "\(counted.first?.loads ?? 0)"],
            warmupRuns: warmup, samples: samples, checks: checks,
            notes: ["Core logic over a fake archive: wall and memory exclude WebKit page loads, JavaScript and network; pages, scripts and loads are a model of RecmanWebSession.search"]
        )
    }
}

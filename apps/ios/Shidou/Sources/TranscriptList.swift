import Observation
import SwiftUI
import UIKit

/// Only the jump control observes this. Scroll notifications must not rebuild
/// the transcript or its row array.
@MainActor @Observable
final class TranscriptScrollState {
    var isAwayFromLatest = false
}

struct TranscriptScrollRequest: Equatable {
    enum Target: Equatable {
        case bottom
        case submittedMessage(String)
        case find(String)
        case review(String)
    }

    let id = UUID()
    let target: Target
}

/// UIKit owns row reuse, measurement, and scroll position; SwiftUI owns cells.
/// Pattern reference: exyte/Chat's UIList.swift, especially its serialized
/// updates and preservation of a visible message's offset across an update.
/// Unlike its inverted table, this table retains normal reading order.
struct TranscriptList<Row: Identifiable, RowContent: View>: View where Row.ID == String {
    let rows: [Row]
    let scrollState: TranscriptScrollState
    let request: TranscriptScrollRequest?
    let submittedMessageID: String?
    @ViewBuilder let rowContent: (Row) -> RowContent

    var body: some View {
        GeometryReader { geometry in
            // A representable does not extend its scrollable content through
            // SwiftUI's bars like ScrollView does. Keep the viewport under the
            // native glass, and reserve the readable area with UIKit insets.
            TranscriptTable(
                rows: rows,
                scrollState: scrollState,
                request: request,
                submittedMessageID: submittedMessageID,
                barInsets: geometry.safeAreaInsets,
                rowContent: rowContent
            )
            .padding(.top, -geometry.safeAreaInsets.top)
            .padding(.bottom, -geometry.safeAreaInsets.bottom)
        }
    }
}

private struct TranscriptTable<Row: Identifiable, RowContent: View>: UIViewRepresentable where Row.ID == String {
    let rows: [Row]
    let scrollState: TranscriptScrollState
    let request: TranscriptScrollRequest?
    let submittedMessageID: String?
    let barInsets: EdgeInsets
    @ViewBuilder let rowContent: (Row) -> RowContent

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITableView {
        let table = TranscriptTableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.allowsSelection = false
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 100
        table.selfSizingInvalidation = .enabledIncludingConstraints
        table.keyboardDismissMode = .interactive
        table.accessibilityIdentifier = "transcript-scroll"
        table.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 4))
        table.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 8))
        context.coordinator.attach(table)
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        let insets = UIEdgeInsets(top: barInsets.top, left: 0, bottom: barInsets.bottom, right: 0)
        if table.contentInset != insets {
            table.contentInset = insets
            table.verticalScrollIndicatorInsets = insets
        }
        context.coordinator.enqueue(self, environment: context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITableView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ table: UITableView, coordinator: Coordinator) {
        (table as? TranscriptTableView)?.didLayout = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDelegate, UIGestureRecognizerDelegate {
        private weak var table: UITableView?
        private var dataSource: UITableViewDiffableDataSource<Int, String>?
        private var latest: TranscriptTable?
        private var environment = EnvironmentValues()
        private var displayedRows: [Row] = []
        private var ids: [String] = []
        private var indexByID: [String: Int] = [:]
        private var measuredHeights: [String: CGFloat] = [:]
        private var appliedRequest: UUID?
        private var updateScheduled = false
        private var updatePending = false
        private var applyingUpdate = false
        private var correctingLayout = false
        private var reportScheduled = false
        private var placedInitially = false
        private var followsTail = true
        private var lastGeometry: Geometry?
        private var footerAnchorID: String?

        private struct Geometry: Equatable {
            let viewport: CGSize
            let top: CGFloat
            let bottom: CGFloat
            let contentHeight: CGFloat

            init(_ table: UITableView) {
                viewport = table.bounds.size
                top = table.adjustedContentInset.top
                bottom = table.adjustedContentInset.bottom
                contentHeight = table.contentSize.height
            }

            func sameViewport(as other: Self) -> Bool {
                viewport == other.viewport && top == other.top && bottom == other.bottom
            }
        }

        private struct ReadingAnchor {
            let id: String
            let distanceFromTop: CGFloat
        }

        func attach(_ table: UITableView) {
            self.table = table
            table.delegate = self
            let tap = UITapGestureRecognizer(target: self, action: #selector(didTapTranscript))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            table.addGestureRecognizer(tap)
            table.register(UITableViewCell.self, forCellReuseIdentifier: "transcript-row")
            dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) {
                [weak self] table, indexPath, id in
                let cell = table.dequeueReusableCell(withIdentifier: "transcript-row", for: indexPath)
                guard let self, let index = self.indexByID[id],
                    index < self.displayedRows.count, let latest = self.latest
                else { return cell }
                let row = self.displayedRows[index]
                let environment = self.environment
                cell.backgroundColor = .clear
                cell.contentConfiguration = UIHostingConfiguration {
                    latest.rowContent(row)
                        .id(id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .environment(\.self, environment)
                }
                .margins(.all, 0)
                return cell
            }
            (table as? TranscriptTableView)?.didLayout = { [weak self] in self?.didLayout() }
        }

        func detach() {
            latest = nil
            dataSource = nil
            table = nil
        }

        func enqueue(_ value: TranscriptTable, environment: EnvironmentValues) {
            latest = value
            self.environment = environment
            updatePending = true
            scheduleUpdate()
        }

        private func scheduleUpdate() {
            guard !updateScheduled, !applyingUpdate else { return }
            updateScheduled = true
            // Coalesce commits and leave SwiftUI's updateUIView transaction
            // before asking UIKit to measure or reconfigure hosted cells.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                self.applyUpdate()
            }
        }

        private func applyUpdate() {
            guard updatePending, !applyingUpdate, let table, let latest, let dataSource else { return }
            updatePending = false
            applyingUpdate = true
            let oldGeometry = Geometry(table)
            let newIDs = latest.rows.map(\.id)
            let structureChanged = ids != newIDs
            let retained = Set(newIDs)
            let anchor = readingAnchor(retaining: retained)
            let oldOffset = table.contentOffset.y
            displayedRows = latest.rows
            if structureChanged {
                ids = newIDs
                indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                measuredHeights = measuredHeights.filter { retained.contains($0.key) }
            }
            footerAnchorID = latest.submittedMessageID
            let request = latest.request
            let completion = { [weak self] in
                guard let self, let table = self.table else { return }
                table.layoutIfNeeded()
                self.updateFooter()
                table.layoutIfNeeded()
                let viewportChanged = !oldGeometry.sameViewport(as: Geometry(table))
                if let request, request.id != self.appliedRequest {
                    self.appliedRequest = request.id
                    self.perform(request.target)
                    self.placedInitially = true
                } else if !self.placedInitially, !self.ids.isEmpty {
                    self.scrollToTail(resolveLastRow: true)
                    self.placedInitially = true
                } else if !self.isInteracting {
                    if self.followsTail, !viewportChanged,
                        structureChanged || abs(table.contentSize.height - oldGeometry.contentHeight) > 0.5
                    {
                        self.scrollToTail(resolveLastRow: structureChanged)
                    } else {
                        self.restore(anchor, fallback: oldOffset)
                    }
                }
                self.lastGeometry = Geometry(table)
                self.applyingUpdate = false
                self.reportPosition()
                if self.updatePending { self.scheduleUpdate() }
            }
            UIView.performWithoutAnimation {
                if structureChanged {
                    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                    snapshot.appendSections([0])
                    snapshot.appendItems(ids)
                    let existing = Set(dataSource.snapshot().itemIdentifiers)
                    let visible = table.indexPathsForVisibleRows ?? []
                    let visibleIDs = visible.compactMap { dataSource.itemIdentifier(for: $0) }
                    snapshot.reconfigureItems(visibleIDs.filter { retained.contains($0) && existing.contains($0) })
                    dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
                } else {
                    // A diffable data source owns all mutations, including
                    // reconfiguration. Only mounted cells need new content.
                    var snapshot = dataSource.snapshot()
                    snapshot.reconfigureItems((table.indexPathsForVisibleRows ?? []).compactMap {
                        dataSource.itemIdentifier(for: $0)
                    })
                    dataSource.apply(snapshot, animatingDifferences: false, completion: completion)
                }
            }
        }

        private var isInteracting: Bool {
            guard let table else { return false }
            return table.isTracking || table.isDragging || table.isDecelerating
        }

        private func readingAnchor(retaining ids: Set<String>) -> ReadingAnchor? {
            guard let table, let dataSource else { return nil }
            for indexPath in (table.indexPathsForVisibleRows ?? []).sorted() {
                guard let id = dataSource.itemIdentifier(for: indexPath), ids.contains(id) else { continue }
                return ReadingAnchor(
                    id: id,
                    distanceFromTop: table.rectForRow(at: indexPath).minY
                        - table.contentOffset.y - table.adjustedContentInset.top
                )
            }
            return nil
        }

        private func restore(_ anchor: ReadingAnchor?, fallback: CGFloat) {
            guard let table else { return }
            if let anchor, let index = indexByID[anchor.id] {
                setOffset(table.rectForRow(at: IndexPath(row: index, section: 0)).minY
                    - anchor.distanceFromTop - table.adjustedContentInset.top)
            } else {
                setOffset(fallback)
            }
        }

        private func perform(_ target: TranscriptScrollRequest.Target) {
            guard let table else { return }
            switch target {
            case .bottom:
                followsTail = true
                scrollToTail(resolveLastRow: true)
            case .submittedMessage(let id):
                followsTail = true
                guard let index = indexByID[id] else { return }
                table.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
            case .review(let id):
                followsTail = false
                guard let index = indexByID[id] else { return }
                table.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
            case .find(let id):
                followsTail = false
                guard let index = indexByID[id] else { return }
                table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: false)
            }
        }

        private func setOffset(_ y: CGFloat) {
            guard let table else { return }
            let minimum = -table.adjustedContentInset.top
            let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            let target = min(maximum, max(minimum, y))
            if abs(table.contentOffset.y - target) > 0.5 {
                table.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }

        private func scrollToTail(resolveLastRow: Bool) {
            guard let table, !ids.isEmpty else { return }
            if resolveLastRow {
                table.scrollToRow(at: IndexPath(row: ids.count - 1, section: 0), at: .bottom, animated: false)
                table.layoutIfNeeded()
            }
            setOffset(table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        }

        private func updateFooter() {
            guard let table, let footer = table.tableFooterView,
                let header = table.tableHeaderView
            else { return }
            let viewport = table.bounds.height - table.adjustedContentInset.top - table.adjustedContentInset.bottom
            let rowsHeight = table.contentSize.height - header.frame.height - footer.frame.height
            var headerHeight = max(4, viewport - rowsHeight - 8)
            var height: CGFloat = 8
            if let footerAnchorID, let index = indexByID[footerAnchorID],
                table.numberOfSections > 0, index < table.numberOfRows(inSection: 0)
            {
                let start = table.rectForRow(at: IndexPath(row: index, section: 0)).minY
                let submittedHeight = table.contentSize.height - footer.frame.height - start
                height = max(height, viewport - submittedHeight)
                headerHeight = 4
            }
            if abs(header.frame.height - headerHeight) > 0.5 {
                header.frame.size.height = headerHeight
                table.tableHeaderView = header
            }
            if abs(footer.frame.height - height) > 0.5 {
                footer.frame.size.height = height
                table.tableFooterView = footer
            }
        }

        private func didLayout() {
            guard let table, !correctingLayout else { return }
            let geometry = Geometry(table)
            let previous = lastGeometry
            lastGeometry = geometry
            guard !applyingUpdate, placedInitially, previous != geometry else { return }
            correctingLayout = true
            defer { correctingLayout = false }
            updateFooter()
            // A keyboard/inset change is not stream growth. Dynamic SwiftUI
            // cell changes (images, expanded tools) still get native following.
            if let previous, geometry.sameViewport(as: previous),
                geometry.contentHeight != previous.contentHeight, followsTail, !isInteracting
            {
                setOffset(table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            }
            reportPosition()
        }

        private func reportPosition() {
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                guard let table = self.table, let state = self.latest?.scrollState else { return }
                let gap = table.contentSize.height - table.bounds.height
                    + table.adjustedContentInset.bottom - table.contentOffset.y
                let away = gap > 100
                if state.isAwayFromLatest != away { state.isAwayFromLatest = away }
            }
        }

        @objc private func didTapTranscript() { table?.window?.endEditing(true) }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { followsTail = false }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { reportPosition() }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishUserScroll() }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishUserScroll() }

        private func finishUserScroll() {
            guard let table else { return }
            let gap = table.contentSize.height - table.bounds.height
                + table.adjustedContentInset.bottom - table.contentOffset.y
            followsTail = gap <= 100
            reportPosition()
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard indexPath.row < ids.count else { return 100 }
            return measuredHeights[ids[indexPath.row]] ?? 100
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            guard indexPath.row < ids.count else { return }
            measuredHeights[ids[indexPath.row]] = cell.bounds.height
        }
    }
}

private final class TranscriptTableView: UITableView {
    var didLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AvailabilitySelectionGridView: View {
    @Binding var selectedRawValues: Set<String>

    let slots: [AvailabilityGridSlot]
    let isDisabled: Bool
    let preferredViewportHeight: CGFloat?

    private let headerHeight: CGFloat = 38
    private let hourRowHeight: CGFloat = 48

    private var fullGridHeight: CGFloat {
        headerHeight + CGFloat(orderedHourIDs(from: slots).count) * hourRowHeight
    }

    private var gridHeight: CGFloat {
        guard let preferredViewportHeight else { return fullGridHeight }
        return min(fullGridHeight, max(preferredViewportHeight, headerHeight + hourRowHeight))
    }

    var body: some View {
        if slots.isEmpty {
            Text("No time slots returned by the API.")
                .foregroundStyle(.secondary)
        } else {
            #if canImport(UIKit)
            AvailabilitySelectionGridRepresentable(
                selectedRawValues: $selectedRawValues,
                slots: slots,
                isDisabled: isDisabled
            )
            .frame(height: gridHeight)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
            }
            .opacity(isDisabled ? 0.55 : 1)
            #else
            Text("Grid selection is unavailable on this platform.")
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private func orderedHourIDs(from slots: [AvailabilityGridSlot]) -> [Int] {
        orderedUniqueValues(slots.map { hourID(for: $0.timeID) })
    }

    private func hourID(for timeID: Int) -> Int {
        (timeID / 60) * 60
    }

    private func orderedUniqueValues<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seenValues: Set<Value> = []

        return values.filter { value in
            seenValues.insert(value).inserted
        }
    }
}

#if canImport(UIKit)
private struct AvailabilitySelectionGridRepresentable: UIViewRepresentable {
    @Binding var selectedRawValues: Set<String>

    let slots: [AvailabilityGridSlot]
    let isDisabled: Bool

    func makeUIView(context: Context) -> AvailabilitySelectionUIKitGridView {
        AvailabilitySelectionUIKitGridView()
    }

    func updateUIView(_ uiView: AvailabilitySelectionUIKitGridView, context: Context) {
        uiView.configure(
            slots: slots,
            selectedRawValues: selectedRawValues,
            isDisabled: isDisabled
        ) { newSelection in
            selectedRawValues = newSelection
        }
    }
}

private struct AvailabilitySelectionDisabledAncestorScrollView {
    weak var scrollView: UIScrollView?
    let wasScrollEnabled: Bool
    let wasPanGestureRecognizerEnabled: Bool
}

private enum AvailabilitySelectionGridDrawing {
    static let lineWidth: CGFloat = 0.5
    static let hourCellLineWidth: CGFloat = 1.5
}

private final class AvailabilitySelectionUIKitGridView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let bodyGridView = AvailabilitySelectionBodyGridView()
    private let topHeaderView = AvailabilitySelectionTopHeaderView()
    private let leftHeaderView = AvailabilitySelectionLeftHeaderView()
    private let cornerView = UIView()
    private let selectionOverlayView = UIView()
    private let selectionBadgeLabel = UILabel()
    private let haptics = UISelectionFeedbackGenerator()

    private var tapRecognizer: UITapGestureRecognizer?
    private var longPressRecognizer: UILongPressGestureRecognizer?
    private var panShieldRecognizer: AvailabilitySelectionPanShieldGestureRecognizer?

    private var configuration = AvailabilitySelectionGridConfiguration.empty
    private var selectedRawValues: Set<String> = []
    private var draftSelectedRawValues: Set<String> = []
    private var dragSelectionMode: AvailabilitySelectionDragMode?
    private var lastDragCoordinate: AvailabilitySelectionGridCoordinate?
    private var dragBaseRawValues: Set<String> = []
    private var dragAnchorCoordinate: AvailabilitySelectionGridCoordinate?
    private var isDragSelecting = false
    private var lastDragViewportLocation: CGPoint?
    private var autoScrollDisplayLink: CADisplayLink?
    private var disabledAncestorScrollViews: [AvailabilitySelectionDisabledAncestorScrollView] = []
    private var onSelectionCommitted: ((Set<String>) -> Void)?

    private let timeColumnWidth: CGFloat = 42
    private let dayColumnWidth: CGFloat = 64
    private let headerHeight: CGFloat = 38
    private let hourRowHeight: CGFloat = 48
    private let segmentOffsets = [0, 15, 30, 45]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        setupGestures()
    }

    deinit {
        stopAutoScroll()
        restoreAncestorScrollViews()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutGridViews()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        refreshColors()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)

        if newWindow == nil {
            stopAutoScroll()
        }
    }

    func configure(
        slots: [AvailabilityGridSlot],
        selectedRawValues: Set<String>,
        isDisabled: Bool,
        onSelectionCommitted: @escaping (Set<String>) -> Void
    ) {
        self.onSelectionCommitted = onSelectionCommitted

        if configuration.slots != slots {
            configuration = AvailabilitySelectionGridConfiguration(
                slots: slots,
                timeColumnWidth: timeColumnWidth,
                dayColumnWidth: dayColumnWidth,
                headerHeight: headerHeight,
                hourRowHeight: hourRowHeight,
                segmentOffsets: segmentOffsets
            )
            applyConfiguration()
        }

        if !isDragSelecting && self.selectedRawValues != selectedRawValues {
            let changedRawValues = self.selectedRawValues.symmetricDifference(selectedRawValues)
            self.selectedRawValues = selectedRawValues
            draftSelectedRawValues = selectedRawValues
            bodyGridView.selectedRawValues = selectedRawValues
            bodyGridView.invalidate(rawValues: changedRawValues)
        }

        scrollView.isUserInteractionEnabled = !isDisabled
        bodyGridView.isDisabled = isDisabled
        tapRecognizer?.isEnabled = !isDisabled
        longPressRecognizer?.isEnabled = !isDisabled
        panShieldRecognizer?.isEnabled = !isDisabled
        accessibilityValue = selectedRawValues.isEmpty ? "No availability selected" : "Availability selected"
    }

    private func setupViews() {
        backgroundColor = .secondarySystemGroupedBackground
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Availability grid"
        accessibilityHint = "Scroll to browse times. Long press and drag to select availability."

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.bounces = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.delaysContentTouches = false
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.addSubview(bodyGridView)

        cornerView.backgroundColor = .systemBackground
        topHeaderView.backgroundColor = .systemBackground
        leftHeaderView.backgroundColor = .systemBackground

        selectionOverlayView.isUserInteractionEnabled = false
        selectionOverlayView.layer.borderWidth = 2
        selectionOverlayView.layer.cornerRadius = 8
        selectionOverlayView.isHidden = true

        selectionBadgeLabel.isUserInteractionEnabled = false
        selectionBadgeLabel.text = "Selecting"
        selectionBadgeLabel.font = .preferredFont(forTextStyle: .caption2)
        selectionBadgeLabel.adjustsFontForContentSizeCategory = true
        selectionBadgeLabel.textColor = .white
        selectionBadgeLabel.textAlignment = .center
        selectionBadgeLabel.layer.cornerRadius = 12
        selectionBadgeLabel.layer.masksToBounds = true
        selectionBadgeLabel.isHidden = true

        addSubview(scrollView)
        addSubview(topHeaderView)
        addSubview(leftHeaderView)
        addSubview(cornerView)
        addSubview(selectionOverlayView)
        addSubview(selectionBadgeLabel)
        refreshColors()
    }

    private func setupGestures() {
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = self
        bodyGridView.addGestureRecognizer(tapRecognizer)
        self.tapRecognizer = tapRecognizer

        let longPressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressRecognizer.minimumPressDuration = 0.22
        longPressRecognizer.allowableMovement = 10
        longPressRecognizer.cancelsTouchesInView = true
        longPressRecognizer.delaysTouchesBegan = false
        longPressRecognizer.delaysTouchesEnded = false
        longPressRecognizer.delegate = self
        bodyGridView.addGestureRecognizer(longPressRecognizer)
        self.longPressRecognizer = longPressRecognizer

        let panShieldRecognizer = AvailabilitySelectionPanShieldGestureRecognizer(target: self, action: #selector(handlePanShield(_:)))
        panShieldRecognizer.cancelsTouchesInView = true
        panShieldRecognizer.delaysTouchesBegan = false
        panShieldRecognizer.delaysTouchesEnded = false
        panShieldRecognizer.delegate = self
        scrollView.addGestureRecognizer(panShieldRecognizer)
        self.panShieldRecognizer = panShieldRecognizer
    }

    private func applyConfiguration() {
        bodyGridView.configuration = configuration
        bodyGridView.selectedRawValues = selectedRawValues
        topHeaderView.configuration = configuration
        leftHeaderView.configuration = configuration
        scrollView.contentSize = configuration.bodyContentSize
        bodyGridView.frame = CGRect(origin: .zero, size: configuration.bodyContentSize)
        layoutGridViews()
        updateHeaderOffsets()
    }

    private func layoutGridViews() {
        let bodyWidth = max(bounds.width - timeColumnWidth, 0)
        let bodyHeight = max(bounds.height - headerHeight, 0)

        cornerView.frame = CGRect(x: 0, y: 0, width: timeColumnWidth, height: headerHeight)
        topHeaderView.frame = CGRect(x: timeColumnWidth, y: 0, width: bodyWidth, height: headerHeight)
        leftHeaderView.frame = CGRect(x: 0, y: headerHeight, width: timeColumnWidth, height: bodyHeight)
        scrollView.frame = CGRect(x: timeColumnWidth, y: headerHeight, width: bodyWidth, height: bodyHeight)
        bodyGridView.frame = CGRect(origin: .zero, size: configuration.bodyContentSize)
        selectionOverlayView.frame = scrollView.frame
        selectionBadgeLabel.frame = CGRect(x: bounds.maxX - 82, y: 7, width: 74, height: 24)
        updateHeaderOffsets()
    }

    private func refreshColors() {
        selectionOverlayView.layer.borderColor = tintColor.cgColor
        selectionBadgeLabel.backgroundColor = tintColor
        bodyGridView.tintColor = tintColor
        topHeaderView.tintColor = tintColor
        leftHeaderView.tintColor = tintColor
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateHeaderOffsets()
    }

    private func updateHeaderOffsets() {
        topHeaderView.contentOffsetX = scrollView.contentOffset.x
        leftHeaderView.contentOffsetY = scrollView.contentOffset.y
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, scrollView.isUserInteractionEnabled else { return }
        guard let slot = configuration.slot(at: recognizer.location(in: bodyGridView)) else { return }

        var updatedRawValues = selectedRawValues
        if updatedRawValues.contains(slot.rawValue) {
            updatedRawValues.remove(slot.rawValue)
        } else {
            updatedRawValues.insert(slot.rawValue)
        }

        applySelection(updatedRawValues, changedRawValues: [slot.rawValue])
        commitSelection()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard scrollView.isUserInteractionEnabled else { return }
        let viewportLocation = viewportLocation(for: recognizer)
        let bodyLocation = contentLocation(forViewportLocation: viewportLocation)

        switch recognizer.state {
        case .began:
            lastDragViewportLocation = viewportLocation
            beginDragSelection(at: bodyLocation)
            startAutoScrollIfNeeded()
        case .changed:
            lastDragViewportLocation = viewportLocation
            updateDragSelection(at: bodyLocation)
            startAutoScrollIfNeeded()
        case .ended, .cancelled, .failed:
            stopAutoScroll()
            endDragSelection()
        default:
            break
        }
    }

    @objc private func handlePanShield(_ recognizer: UIPanGestureRecognizer) {
        // This recognizer exists only to keep grid drags from being shared with the sheet pan.
    }

    private func beginDragSelection(at location: CGPoint) {
        guard let coordinate = configuration.coordinate(at: location),
              let slot = configuration.slot(for: coordinate) else {
            return
        }

        isDragSelecting = true
        disableAncestorScrollViews()
        selectionOverlayView.isHidden = false
        selectionBadgeLabel.isHidden = false
        scrollView.isScrollEnabled = false
        dragBaseRawValues = selectedRawValues
        draftSelectedRawValues = selectedRawValues
        dragAnchorCoordinate = coordinate
        dragSelectionMode = draftSelectedRawValues.contains(slot.rawValue) ? .deselecting : .selecting
        lastDragCoordinate = nil
        haptics.prepare()
        updateDragSelection(at: location)
    }

    private func updateDragSelection(at location: CGPoint) {
        guard isDragSelecting,
              let coordinate = configuration.coordinate(at: location),
              lastDragCoordinate != coordinate else {
            return
        }

        guard let dragAnchorCoordinate else { return }

        let rectangleCoordinates = coordinatesInSelectionRectangle(
            from: dragAnchorCoordinate,
            to: coordinate
        )
        let updatedRawValues = selectionValues(
            fromBase: dragBaseRawValues,
            coordinates: rectangleCoordinates,
            mode: dragSelectionMode
        )
        let changedRawValues = selectedRawValues.symmetricDifference(updatedRawValues)

        guard !changedRawValues.isEmpty else {
            lastDragCoordinate = coordinate
            return
        }

        draftSelectedRawValues = updatedRawValues
        applySelection(updatedRawValues, changedRawValues: changedRawValues)
        triggerSelectionFeedback(changeCount: changedRawValues.count)
        lastDragCoordinate = coordinate
    }

    private func endDragSelection() {
        guard isDragSelecting else { return }

        commitSelection()
        isDragSelecting = false
        dragSelectionMode = nil
        lastDragCoordinate = nil
        lastDragViewportLocation = nil
        dragBaseRawValues = []
        dragAnchorCoordinate = nil
        selectionOverlayView.isHidden = true
        selectionBadgeLabel.isHidden = true
        scrollView.isScrollEnabled = true
        restoreAncestorScrollViews()
    }

    private func disableAncestorScrollViews() {
        restoreAncestorScrollViews()

        var currentView = superview
        while let view = currentView {
            if let ancestorScrollView = view as? UIScrollView,
               ancestorScrollView !== scrollView {
                let wasScrollEnabled = ancestorScrollView.isScrollEnabled
                let wasPanGestureRecognizerEnabled = ancestorScrollView.panGestureRecognizer.isEnabled
                disabledAncestorScrollViews.append(AvailabilitySelectionDisabledAncestorScrollView(
                    scrollView: ancestorScrollView,
                    wasScrollEnabled: wasScrollEnabled,
                    wasPanGestureRecognizerEnabled: wasPanGestureRecognizerEnabled
                ))
                ancestorScrollView.isScrollEnabled = false
                ancestorScrollView.panGestureRecognizer.isEnabled = false
            }

            currentView = view.superview
        }
    }

    private func restoreAncestorScrollViews() {
        for disabledScrollView in disabledAncestorScrollViews {
            disabledScrollView.scrollView?.isScrollEnabled = disabledScrollView.wasScrollEnabled
            disabledScrollView.scrollView?.panGestureRecognizer.isEnabled = disabledScrollView.wasPanGestureRecognizerEnabled
        }

        disabledAncestorScrollViews = []
    }

    private func startAutoScrollIfNeeded() {
        guard isDragSelecting, autoScrollDisplayLink == nil else { return }

        let displayLink = CADisplayLink(target: self, selector: #selector(handleAutoScroll(_:)))
        displayLink.add(to: .main, forMode: .common)
        autoScrollDisplayLink = displayLink
    }

    private func stopAutoScroll() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
    }

    @objc private func handleAutoScroll(_ displayLink: CADisplayLink) {
        guard isDragSelecting, let lastDragViewportLocation else {
            stopAutoScroll()
            return
        }

        let step = autoScrollStep(
            for: lastDragViewportLocation,
            displayLinkDuration: displayLink.duration
        )
        guard step != .zero else { return }

        let maximumOffsetX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
        let maximumOffsetY = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let nextOffset = CGPoint(
            x: min(max(scrollView.contentOffset.x + step.x, 0), maximumOffsetX),
            y: min(max(scrollView.contentOffset.y + step.y, 0), maximumOffsetY)
        )
        guard nextOffset != scrollView.contentOffset else { return }

        scrollView.contentOffset = nextOffset
        updateDragSelection(at: contentLocation(forViewportLocation: lastDragViewportLocation))
    }

    private func contentLocation(forViewportLocation viewportLocation: CGPoint) -> CGPoint {
        clampedContentLocation(CGPoint(
            x: scrollView.contentOffset.x + viewportLocation.x,
            y: scrollView.contentOffset.y + viewportLocation.y
        ))
    }

    private func viewportLocation(for recognizer: UIGestureRecognizer) -> CGPoint {
        let location = recognizer.location(in: self)
        return CGPoint(
            x: location.x - scrollView.frame.minX,
            y: location.y - scrollView.frame.minY
        )
    }

    private func clampedContentLocation(_ contentLocation: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(contentLocation.x, 0), max(configuration.bodyContentSize.width - 0.5, 0)),
            y: min(max(contentLocation.y, 0), max(configuration.bodyContentSize.height - 0.5, 0))
        )
    }

    private func autoScrollStep(for location: CGPoint, displayLinkDuration: TimeInterval) -> CGPoint {
        let maximumPointsPerSecond: CGFloat = 460
        let duration = displayLinkDuration > 0 ? displayLinkDuration : 1 / 60
        let pointsPerFrame = maximumPointsPerSecond * CGFloat(duration)
        let stepX = autoScrollStep(
            location: location.x,
            viewportLength: scrollView.bounds.width,
            contentLength: scrollView.contentSize.width,
            currentOffset: scrollView.contentOffset.x,
            pointsPerFrame: pointsPerFrame
        )
        let stepY = autoScrollStep(
            location: location.y,
            viewportLength: scrollView.bounds.height,
            contentLength: scrollView.contentSize.height,
            currentOffset: scrollView.contentOffset.y,
            pointsPerFrame: pointsPerFrame
        )

        return CGPoint(x: stepX, y: stepY)
    }

    private func autoScrollStep(
        location: CGFloat,
        viewportLength: CGFloat,
        contentLength: CGFloat,
        currentOffset: CGFloat,
        pointsPerFrame: CGFloat
    ) -> CGFloat {
        guard contentLength > viewportLength else { return 0 }

        let edgeLength = min(max(viewportLength * 0.22, 36), 64)
        if location < edgeLength, currentOffset > 0 {
            let proximity = min(max((edgeLength - location) / edgeLength, 0), 1)
            return -pointsPerFrame * proximity
        }

        let trailingEdgeStart = viewportLength - edgeLength
        if location > trailingEdgeStart, currentOffset < contentLength - viewportLength {
            let proximity = min(max((location - trailingEdgeStart) / edgeLength, 0), 1)
            return pointsPerFrame * proximity
        }

        return 0
    }

    private func coordinatesInSelectionRectangle(
        from start: AvailabilitySelectionGridCoordinate,
        to end: AvailabilitySelectionGridCoordinate
    ) -> [AvailabilitySelectionGridCoordinate] {
        let segmentCount = segmentOffsets.count
        let startRowIndex = start.absoluteSegmentIndex(segmentCount: segmentCount)
        let endRowIndex = end.absoluteSegmentIndex(segmentCount: segmentCount)
        let dayRange = min(start.dayIndex, end.dayIndex)...max(start.dayIndex, end.dayIndex)
        let rowRange = min(startRowIndex, endRowIndex)...max(startRowIndex, endRowIndex)

        var coordinates: [AvailabilitySelectionGridCoordinate] = []
        for dayIndex in dayRange {
            for rowIndex in rowRange {
                coordinates.append(AvailabilitySelectionGridCoordinate(
                    dayIndex: dayIndex,
                    hourIndex: rowIndex / segmentCount,
                    segmentIndex: rowIndex % segmentCount
                ))
            }
        }

        return coordinates
    }

    private func selectionValues(
        fromBase baseRawValues: Set<String>,
        coordinates: [AvailabilitySelectionGridCoordinate],
        mode: AvailabilitySelectionDragMode?
    ) -> Set<String> {
        var rawValues = baseRawValues

        for coordinate in coordinates {
            guard let slot = configuration.slot(for: coordinate) else { continue }

            switch mode {
            case .selecting:
                rawValues.insert(slot.rawValue)
            case .deselecting:
                rawValues.remove(slot.rawValue)
            case nil:
                break
            }
        }

        return rawValues
    }

    private func applySelection(_ updatedRawValues: Set<String>, changedRawValues: Set<String>) {
        selectedRawValues = updatedRawValues
        draftSelectedRawValues = updatedRawValues
        bodyGridView.selectedRawValues = updatedRawValues
        bodyGridView.invalidate(rawValues: changedRawValues)
    }

    private func commitSelection() {
        onSelectionCommitted?(selectedRawValues)
    }

    private func triggerSelectionFeedback(changeCount: Int) {
        guard changeCount > 0 else { return }

        for index in 0..<changeCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.018) { [weak self] in
                self?.haptics.selectionChanged()
                self?.haptics.prepare()
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard scrollView.isUserInteractionEnabled else { return false }

        if gestureRecognizer === tapRecognizer || gestureRecognizer === longPressRecognizer {
            return bodyGridView.bounds.contains(touch.location(in: bodyGridView))
        }

        return bounds.contains(touch.location(in: self))
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panShieldRecognizer,
              let panRecognizer = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        if isDragSelecting {
            return true
        }

        let velocity = panRecognizer.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if isDragSelecting {
            return isGridInternalGestureRecognizer(gestureRecognizer) && isGridInternalGestureRecognizer(otherGestureRecognizer)
        }

        if gestureRecognizer === longPressRecognizer || otherGestureRecognizer === longPressRecognizer {
            let pairedRecognizer = gestureRecognizer === longPressRecognizer ? otherGestureRecognizer : gestureRecognizer
            return isGridInternalGestureRecognizer(pairedRecognizer)
        }

        guard gestureRecognizer === panShieldRecognizer || otherGestureRecognizer === panShieldRecognizer else {
            return true
        }

        let pairedRecognizer = gestureRecognizer === panShieldRecognizer ? otherGestureRecognizer : gestureRecognizer
        return isGridInternalGestureRecognizer(pairedRecognizer)
    }

    private func isGridInternalGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === tapRecognizer ||
            gestureRecognizer === longPressRecognizer ||
            gestureRecognizer === panShieldRecognizer ||
            gestureRecognizer === scrollView.panGestureRecognizer {
            return true
        }

        guard let recognizerView = gestureRecognizer.view else { return false }
        return recognizerView === scrollView || recognizerView.isDescendant(of: scrollView)
    }
}

private final class AvailabilitySelectionBodyGridView: UIView {
    var configuration = AvailabilitySelectionGridConfiguration.empty {
        didSet { setNeedsDisplay() }
    }

    var selectedRawValues: Set<String> = []

    var isDisabled = false {
        didSet {
            guard oldValue != isDisabled else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .systemBackground
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = true
        backgroundColor = .systemBackground
    }

    func invalidate(rawValues: Set<String>) {
        guard !rawValues.isEmpty else { return }

        for rawValue in rawValues {
            if let frame = configuration.slotFramesByRawValue[rawValue] {
                setNeedsDisplay(frame.insetBy(dx: -1, dy: -1))
            }
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        UIColor.systemBackground.setFill()
        context.fill(rect)

        let segmentHeight = configuration.segmentHeight
        let startDayIndex = max(Int(floor(rect.minX / configuration.dayColumnWidth)), 0)
        let endDayIndex = min(Int(ceil(rect.maxX / configuration.dayColumnWidth)), configuration.dayIDs.count - 1)
        let startHourIndex = max(Int(floor(rect.minY / configuration.hourRowHeight)), 0)
        let endHourIndex = min(Int(ceil(rect.maxY / configuration.hourRowHeight)), configuration.hourIDs.count - 1)

        guard startDayIndex <= endDayIndex, startHourIndex <= endHourIndex else { return }

        for hourIndex in startHourIndex...endHourIndex {
            let hourID = configuration.hourIDs[hourIndex]
            for dayIndex in startDayIndex...endDayIndex {
                let dayID = configuration.dayIDs[dayIndex]
                for segmentIndex in configuration.segmentOffsets.indices {
                    let timeID = hourID + configuration.segmentOffsets[segmentIndex]
                    let slot = configuration.slotLookup[configuration.lookupKey(dayID: dayID, timeID: timeID)]
                    let frame = CGRect(
                        x: CGFloat(dayIndex) * configuration.dayColumnWidth,
                        y: CGFloat(hourIndex) * configuration.hourRowHeight + CGFloat(segmentIndex) * segmentHeight,
                        width: configuration.dayColumnWidth,
                        height: segmentHeight
                    )

                    drawCell(slot: slot, frame: frame, in: context)
                }

                let hourFrame = CGRect(
                    x: CGFloat(dayIndex) * configuration.dayColumnWidth,
                    y: CGFloat(hourIndex) * configuration.hourRowHeight,
                    width: configuration.dayColumnWidth,
                    height: configuration.hourRowHeight
                )
                drawHourCellBorder(frame: hourFrame, in: context)
            }
        }
    }

    private func drawCell(slot: AvailabilityGridSlot?, frame: CGRect, in context: CGContext) {
        let isSelected = slot.map { selectedRawValues.contains($0.rawValue) } ?? false
        let fillColor: UIColor
        let strokeColor: UIColor
        let lineWidth: CGFloat

        if isSelected {
            fillColor = tintColor.withAlphaComponent(isDisabled ? 0.34 : 0.72)
            strokeColor = tintColor
            lineWidth = 2
        } else {
            fillColor = .secondarySystemGroupedBackground
            strokeColor = .separator
            lineWidth = AvailabilitySelectionGridDrawing.lineWidth
        }

        fillColor.setFill()
        context.fill(frame)
        strokeColor.setStroke()
        context.setLineWidth(lineWidth)
        context.stroke(frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    }

    private func drawHourCellBorder(frame: CGRect, in context: CGContext) {
        let lineWidth = AvailabilitySelectionGridDrawing.hourCellLineWidth
        UIColor.separator.setStroke()
        context.setLineWidth(lineWidth)
        context.stroke(frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    }
}

private final class AvailabilitySelectionTopHeaderView: UIView {
    var configuration = AvailabilitySelectionGridConfiguration.empty {
        didSet { setNeedsDisplay() }
    }

    var contentOffsetX: CGFloat = 0 {
        didSet {
            guard oldValue != contentOffsetX else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = true
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        UIColor.systemBackground.setFill()
        context.fill(rect)

        let startDayIndex = max(Int(floor(contentOffsetX / configuration.dayColumnWidth)), 0)
        let endDayIndex = min(Int(ceil((contentOffsetX + bounds.width) / configuration.dayColumnWidth)), configuration.dayIDs.count - 1)
        guard startDayIndex <= endDayIndex else { return }

        for dayIndex in startDayIndex...endDayIndex {
            let dayID = configuration.dayIDs[dayIndex]
            let header = configuration.dayHeaders[dayID]
            let frame = CGRect(
                x: CGFloat(dayIndex) * configuration.dayColumnWidth - contentOffsetX,
                y: 0,
                width: configuration.dayColumnWidth,
                height: bounds.height
            )

            drawHeader(dayLabel: header?.dayLabel ?? dayID, weekdayLabel: header?.weekdayLabel, frame: frame, in: context)
        }
    }

    private func drawHeader(dayLabel: String, weekdayLabel: String?, frame: CGRect, in context: CGContext) {
        UIColor.systemBackground.setFill()
        context.fill(frame)
        UIColor.separator.setStroke()
        context.setLineWidth(AvailabilitySelectionGridDrawing.lineWidth)
        context.stroke(frame.insetBy(
            dx: AvailabilitySelectionGridDrawing.lineWidth / 2,
            dy: AvailabilitySelectionGridDrawing.lineWidth / 2
        ))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .caption1).bolded(),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .caption2).bolded(),
            .foregroundColor: UIColor.secondaryLabel,
            .paragraphStyle: paragraphStyle
        ]

        if let weekdayLabel {
            dayLabel.draw(in: CGRect(x: frame.minX + 2, y: frame.minY + 6, width: frame.width - 4, height: 14), withAttributes: attributes)
            weekdayLabel.draw(in: CGRect(x: frame.minX + 2, y: frame.minY + 21, width: frame.width - 4, height: 13), withAttributes: secondaryAttributes)
        } else {
            dayLabel.draw(in: CGRect(x: frame.minX + 2, y: frame.minY + 12, width: frame.width - 4, height: 16), withAttributes: attributes)
        }
    }
}

private final class AvailabilitySelectionLeftHeaderView: UIView {
    var configuration = AvailabilitySelectionGridConfiguration.empty {
        didSet { setNeedsDisplay() }
    }

    var contentOffsetY: CGFloat = 0 {
        didSet {
            guard oldValue != contentOffsetY else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = true
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        UIColor.systemBackground.setFill()
        context.fill(rect)

        let startHourIndex = max(Int(floor(contentOffsetY / configuration.hourRowHeight)), 0)
        let endHourIndex = min(Int(ceil((contentOffsetY + bounds.height) / configuration.hourRowHeight)), configuration.hourIDs.count - 1)
        guard startHourIndex <= endHourIndex else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .caption1).bolded(),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ]

        for hourIndex in startHourIndex...endHourIndex {
            let frame = CGRect(
                x: 0,
                y: CGFloat(hourIndex) * configuration.hourRowHeight - contentOffsetY,
                width: bounds.width,
                height: configuration.hourRowHeight
            )

            UIColor.systemBackground.setFill()
            context.fill(frame)
            UIColor.separator.setStroke()
            context.setLineWidth(AvailabilitySelectionGridDrawing.lineWidth)
            context.stroke(frame.insetBy(
                dx: AvailabilitySelectionGridDrawing.lineWidth / 2,
                dy: AvailabilitySelectionGridDrawing.lineWidth / 2
            ))

            configuration.hourLabel(for: configuration.hourIDs[hourIndex]).draw(
                in: CGRect(x: frame.minX + 2, y: frame.minY + 4, width: frame.width - 6, height: 16),
                withAttributes: attributes
            )
        }
    }
}

private final class AvailabilitySelectionPanShieldGestureRecognizer: UIPanGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        !isGridInternalGestureRecognizer(preventedGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    private func isGridInternalGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view, let recognizerView = gestureRecognizer.view else {
            return false
        }

        return recognizerView === view || recognizerView.isDescendant(of: view)
    }
}

private enum AvailabilitySelectionDragMode {
    case selecting
    case deselecting
}

private struct AvailabilitySelectionGridCoordinate: Equatable {
    let dayIndex: Int
    let hourIndex: Int
    let segmentIndex: Int

    func absoluteSegmentIndex(segmentCount: Int) -> Int {
        hourIndex * segmentCount + segmentIndex
    }
}

private struct AvailabilitySelectionDayHeader: Equatable {
    let dayLabel: String
    let weekdayLabel: String?
}

private struct AvailabilitySelectionGridConfiguration: Equatable {
    let slots: [AvailabilityGridSlot]
    let dayIDs: [String]
    let hourIDs: [Int]
    let dayHeaders: [String: AvailabilitySelectionDayHeader]
    let slotLookup: [String: AvailabilityGridSlot]
    let slotFramesByRawValue: [String: CGRect]
    let timeColumnWidth: CGFloat
    let dayColumnWidth: CGFloat
    let headerHeight: CGFloat
    let hourRowHeight: CGFloat
    let segmentOffsets: [Int]

    static let empty = AvailabilitySelectionGridConfiguration(
        slots: [],
        timeColumnWidth: 42,
        dayColumnWidth: 64,
        headerHeight: 38,
        hourRowHeight: 48,
        segmentOffsets: [0, 15, 30, 45]
    )

    var bodyContentSize: CGSize {
        CGSize(
            width: CGFloat(dayIDs.count) * dayColumnWidth,
            height: CGFloat(hourIDs.count) * hourRowHeight
        )
    }

    var segmentHeight: CGFloat {
        hourRowHeight / CGFloat(segmentOffsets.count)
    }

    init(
        slots: [AvailabilityGridSlot],
        timeColumnWidth: CGFloat,
        dayColumnWidth: CGFloat,
        headerHeight: CGFloat,
        hourRowHeight: CGFloat,
        segmentOffsets: [Int]
    ) {
        self.slots = slots
        self.timeColumnWidth = timeColumnWidth
        self.dayColumnWidth = dayColumnWidth
        self.headerHeight = headerHeight
        self.hourRowHeight = hourRowHeight
        self.segmentOffsets = segmentOffsets

        let dayIDs = Self.orderedUniqueValues(slots.map(\.dayID))
        let hourIDs = Self.orderedUniqueValues(slots.map { Self.hourID(for: $0.timeID) })
        self.dayIDs = dayIDs
        self.hourIDs = hourIDs

        var dayHeaders: [String: AvailabilitySelectionDayHeader] = [:]
        for slot in slots where dayHeaders[slot.dayID] == nil {
            dayHeaders[slot.dayID] = AvailabilitySelectionDayHeader(dayLabel: slot.dayLabel, weekdayLabel: slot.weekdayLabel)
        }
        self.dayHeaders = dayHeaders

        let slotLookup = Dictionary(slots.map { slot in
            (Self.lookupKey(dayID: slot.dayID, timeID: slot.timeID), slot)
        }, uniquingKeysWith: { firstSlot, _ in firstSlot })
        self.slotLookup = slotLookup

        let hourIndexByID = Dictionary(uniqueKeysWithValues: hourIDs.enumerated().map { ($0.element, $0.offset) })
        let dayIndexByID = Dictionary(uniqueKeysWithValues: dayIDs.enumerated().map { ($0.element, $0.offset) })
        let segmentIndexByOffset = Dictionary(uniqueKeysWithValues: segmentOffsets.enumerated().map { ($0.element, $0.offset) })
        let segmentHeight = hourRowHeight / CGFloat(segmentOffsets.count)
        var slotFramesByRawValue: [String: CGRect] = [:]

        for slot in slots {
            guard let dayIndex = dayIndexByID[slot.dayID],
                  let hourIndex = hourIndexByID[Self.hourID(for: slot.timeID)],
                  let segmentIndex = segmentIndexByOffset[slot.timeID - Self.hourID(for: slot.timeID)] else {
                continue
            }

            slotFramesByRawValue[slot.rawValue] = CGRect(
                x: CGFloat(dayIndex) * dayColumnWidth,
                y: CGFloat(hourIndex) * hourRowHeight + CGFloat(segmentIndex) * segmentHeight,
                width: dayColumnWidth,
                height: segmentHeight
            )
        }
        self.slotFramesByRawValue = slotFramesByRawValue
    }

    func slot(at location: CGPoint) -> AvailabilityGridSlot? {
        guard let coordinate = coordinate(at: location) else { return nil }
        return slot(for: coordinate)
    }

    func slot(for coordinate: AvailabilitySelectionGridCoordinate) -> AvailabilityGridSlot? {
        guard dayIDs.indices.contains(coordinate.dayIndex),
              hourIDs.indices.contains(coordinate.hourIndex),
              segmentOffsets.indices.contains(coordinate.segmentIndex) else {
            return nil
        }

        return slotLookup[lookupKey(
            dayID: dayIDs[coordinate.dayIndex],
            timeID: hourIDs[coordinate.hourIndex] + segmentOffsets[coordinate.segmentIndex]
        )]
    }

    func coordinate(at location: CGPoint) -> AvailabilitySelectionGridCoordinate? {
        guard location.x >= 0, location.y >= 0 else { return nil }

        let dayIndex = Int(location.x / dayColumnWidth)
        let hourIndex = Int(location.y / hourRowHeight)
        let segmentOffset = location.y.truncatingRemainder(dividingBy: hourRowHeight)
        let segmentIndex = Int(segmentOffset / segmentHeight)

        guard dayIDs.indices.contains(dayIndex),
              hourIDs.indices.contains(hourIndex),
              segmentOffsets.indices.contains(segmentIndex) else {
            return nil
        }

        return AvailabilitySelectionGridCoordinate(
            dayIndex: dayIndex,
            hourIndex: hourIndex,
            segmentIndex: segmentIndex
        )
    }

    func lookupKey(dayID: String, timeID: Int) -> String {
        Self.lookupKey(dayID: dayID, timeID: timeID)
    }

    func hourLabel(for hourID: Int) -> String {
        let hour = hourID / 60
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? "AM" : "PM"
        return "\(displayHour) \(period)"
    }

    private static func lookupKey(dayID: String, timeID: Int) -> String {
        "\(dayID)-\(timeID)"
    }

    private static func hourID(for timeID: Int) -> Int {
        (timeID / 60) * 60
    }

    private static func orderedUniqueValues<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seenValues: Set<Value> = []

        return values.filter { value in
            seenValues.insert(value).inserted
        }
    }
}

private extension UIFont {
    func bolded() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else {
            return self
        }

        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif

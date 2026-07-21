import Flutter
import UIKit
import SVGKit
import os.log

private let splitActivationLog = OSLog(subsystem: "cupertino_native_plus", category: "split-activation")

/// Container view that notifies when it gains a window or lays out with non-zero width.
/// Used to drive deferred split-tab-bar constraint activation without polling.
final class CupertinoTabBarContainerView: UIView {
  var onDidMoveToWindow: (() -> Void)?
  var onLayout: (() -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onDidMoveToWindow?()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

class CupertinoTabBarPlatformView: NSObject, FlutterPlatformView, UITabBarDelegate, UIGestureRecognizerDelegate {
  private let channel: FlutterMethodChannel
  private let container: CupertinoTabBarContainerView
  private var tabBar: UITabBar?
  private var tabBarLeft: UITabBar?
  private var tabBarRight: UITabBar?
  private var centerActionButton: UIButton?
  
  // MARK: - State Properties
  private var isSplit: Bool = false
  private var rightCountVal: Int = 1
  private var splitRightAsButton: Bool = false
  private var currentSelectedIndex: Int = 0
  private var currentLabels: [String] = []
  private var currentSymbols: [String] = []
  private var currentActiveSymbols: [String] = []
  private var currentBadges: [String?] = []
  private var currentBadgeColors: [NSNumber?] = []
  private static let badgeViewTagBase = 0xC0FFEE
  private var containerBoundsObservation: NSKeyValueObservation?
  private var currentCustomIconBytes: [Data?] = []
  private var currentActiveCustomIconBytes: [Data?] = []
  private var currentImageAssetPaths: [String] = []
  private var currentActiveImageAssetPaths: [String] = []
  private var currentImageAssetXcassetNames: [String] = []
  private var currentActiveImageAssetXcassetNames: [String] = []
  private var currentImageAssetData: [Data?] = []
  private var currentActiveImageAssetData: [Data?] = []
  private var currentImageAssetFormats: [String] = []
  private var currentActiveImageAssetFormats: [String] = []
  private var currentSizes: [NSNumber] = []
  private var iconScale: CGFloat = UIScreen.main.scale
  private var leftInsetVal: CGFloat = 0
  private var rightInsetVal: CGFloat = 0
  private var splitSpacingVal: CGFloat = 12 // Apple's recommended spacing for visual separation
  private var suppressSelectionCallbacks: Bool = false
  private var labelStyleDict: [String: Any]? = nil
  private var activeLabelStyleDict: [String: Any]? = nil
  private var labelRefreshGeneration: Int = 0
  private var hasScheduledNonZeroBoundsRefresh: Bool = false
  private var isRefreshingLabels: Bool = false
  private var needsLabelRefresh: Bool = false
  private var centerActionIndex: Int?
  private var centerActionSize: CGFloat = 44

  // Pending split-constraint activation deferred while view has no width
  // (e.g. backgrounded at init). Resumed on foreground.
  private struct PendingSplitActivation {
    weak var left: UITabBar?
    weak var right: UITabBar?
    let count: Int
    let rightCount: Int
    let leftInset: CGFloat
    let rightInset: CGFloat
  }
  private var pendingSplitActivation: PendingSplitActivation?
  private var foregroundObserver: NSObjectProtocol?

  // MARK: - Text style helpers

  private func parseTextStyle(_ dict: [String: Any]) -> UIFont? {
    let fontSize = (dict["fontSize"] as? NSNumber).map { CGFloat(truncating: $0) }
    let fontWeight = dict["fontWeight"] as? Int
    let fontFamily = dict["fontFamily"] as? String
    var font: UIFont? = nil
    if let size = fontSize {
      if let family = fontFamily, let customFont = UIFont(name: family, size: size) {
        font = customFont
      } else {
        let weight: UIFont.Weight
        switch fontWeight ?? 400 {
        case 100: weight = .ultraLight
        case 200: weight = .thin
        case 300: weight = .light
        case 400: weight = .regular
        case 500: weight = .medium
        case 600: weight = .semibold
        case 700: weight = .bold
        case 800: weight = .heavy
        case 900: weight = .black
        default:  weight = .regular
        }
        font = UIFont.systemFont(ofSize: size, weight: weight)
      }
    }
    if (dict["italic"] as? Bool) == true, let f = font {
      if let descriptor = f.fontDescriptor.withSymbolicTraits(.traitItalic) {
        font = UIFont(descriptor: descriptor, size: f.pointSize)
      }
    }
    return font
  }

  private func applyLabelStyles() {
    let bars: [UITabBar] = [tabBar, tabBarLeft, tabBarRight].compactMap { $0 }
    guard !bars.isEmpty else { return }

    if #available(iOS 13.0, *) {
      for bar in bars {
        let appearance: UITabBarAppearance
        if #available(iOS 15.0, *) {
          appearance = bar.standardAppearance.copy() as! UITabBarAppearance
        } else {
          appearance = UITabBarAppearance()
          appearance.configureWithDefaultBackground()
        }
        func buildAttrs(_ dict: [String: Any]?) -> [NSAttributedString.Key: Any]? {
          guard let dict = dict else { return nil }
          let font = parseTextStyle(dict)
          var attrs: [NSAttributedString.Key: Any] = [:]
          if let f = font { attrs[.font] = f }
          return attrs.isEmpty ? nil : attrs
        }
        for layoutAppearance in [
          appearance.stackedLayoutAppearance,
          appearance.inlineLayoutAppearance,
          appearance.compactInlineLayoutAppearance,
        ] {
          layoutAppearance.normal.titleTextAttributes = buildAttrs(labelStyleDict) ?? [:]
          layoutAppearance.selected.titleTextAttributes = buildAttrs(activeLabelStyleDict) ?? [:]
        }
        bar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
          bar.scrollEdgeAppearance = appearance
        }
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
      }
    }
  }

  /// Parses badges from method channel: null = no badge, "" = dot only, non-empty = badge text.
  private static func parseBadges(_ any: Any?) -> [String?] {
    guard let arr = any as? [Any] else { return [] }
    return arr.map { item in
      if item is NSNull { return nil }
      return item as? String
    }
  }

  /// Parses badge colors from method channel: null = default badge color, number = ARGB.
  private static func parseBadgeColors(_ any: Any?) -> [NSNumber?] {
    guard let arr = any as? [Any] else { return [] }
    return arr.map { item in
      if item is NSNull { return nil }
      return item as? NSNumber
    }
  }

  /// Whether the badge string means "show badge" (dot or text). nil = no badge.
  private static func hasBadge(_ badge: String?) -> Bool {
    guard let b = badge else { return false }
    return true // "" = dot, non-empty = text
  }

  private static func isBlankBadgeText(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Best-guess icon frame for a given slot (for positioning badge overlay).
  private func iconAnchor(forSlot slot: Int, in bar: UITabBar, count: Int) -> CGRect {
    guard count > 0 else { return bar.bounds }
    let barWidth = bar.bounds.width
    let slotWidth = barWidth / CGFloat(count)
    let slotX = slotWidth * CGFloat(slot)
    let slotRect = CGRect(x: slotX, y: 0, width: slotWidth, height: bar.bounds.height)
    func findImageView(_ view: UIView) -> UIImageView? {
      for sub in view.subviews {
        let frame = sub.convert(sub.bounds, to: bar)
        if frame.intersects(slotRect) {
          if let iv = sub as? UIImageView, iv.bounds.width > 5 { return iv }
          if let iv = findImageView(sub) { return iv }
        }
      }
      return nil
    }
    if let iv = findImageView(bar) { return iv.convert(iv.bounds, to: bar) }
    let topY = bar.bounds.height * 0.12
    let iconH = bar.bounds.height * 0.4
    return CGRect(x: slotX, y: topY, width: slotWidth, height: iconH)
  }

  private func applyBadges(to bar: UITabBar, itemOffset: Int) {
    let count = bar.items?.count ?? 0
    guard count > 0 else { return }
    guard bar.bounds.width > 0 else { return }
    for localIndex in 0..<count {
      let nativeIndex = itemOffset + localIndex
      guard let globalIndex = logicalIndex(forNativeIndex: nativeIndex) else {
        bar.items?[localIndex].badgeValue = nil
        continue
      }
      let tag = Self.badgeViewTagBase + globalIndex
      let existing = bar.viewWithTag(tag)
      let badge = (globalIndex < currentBadges.count) ? currentBadges[globalIndex] : nil
      let shouldShow = Self.hasBadge(badge)
      let hasText = shouldShow && (badge.map { !Self.isBlankBadgeText($0) } ?? false)
      let wantsDotOnly = shouldShow && !hasText

      // Clear system badge; we draw all badges with custom views.
      bar.items?[localIndex].badgeValue = nil

      if !shouldShow {
        existing?.removeFromSuperview()
        continue
      }

      let badgeView = existing ?? UIView(frame: .zero)
      badgeView.tag = tag
      badgeView.isUserInteractionEnabled = false
      badgeView.layer.zPosition = 999
      let rawColor: UIColor? = (globalIndex < currentBadgeColors.count) ? currentBadgeColors[globalIndex].map { ImageUtils.colorFromARGB($0.intValue) } : nil
      badgeView.backgroundColor = rawColor ?? bar.tintColor ?? .systemRed
      badgeView.layer.masksToBounds = true
      badgeView.layer.borderWidth = 0
      bar.clipsToBounds = false
      let anchor = iconAnchor(forSlot: localIndex, in: bar, count: count)

      if wantsDotOnly {
        let size: CGFloat = 10.0
        badgeView.layer.cornerRadius = size / 2
        badgeView.subviews.forEach { $0.removeFromSuperview() }
        if badgeView.superview == nil { bar.addSubview(badgeView) }
        bar.bringSubviewToFront(badgeView)
        badgeView.frame = CGRect(x: anchor.maxX - size / 2, y: anchor.minY - size / 2 + 4, width: size, height: size)
      } else if hasText, let text = badge {
        let label: UILabel = (badgeView.subviews.compactMap { $0 as? UILabel }.first) ?? UILabel(frame: .zero)
        if label.superview == nil { badgeView.addSubview(label) }
        label.text = text
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        label.sizeToFit()
        let h: CGFloat = 18
        let padX: CGFloat = 6
        let w = max(h, label.bounds.width + padX * 2)
        badgeView.layer.cornerRadius = h / 2
        label.frame = CGRect(x: (w - label.bounds.width) / 2, y: (h - label.bounds.height) / 2, width: label.bounds.width, height: label.bounds.height)
        if badgeView.superview == nil { bar.addSubview(badgeView) }
        bar.bringSubviewToFront(badgeView)
        badgeView.frame = CGRect(x: anchor.maxX - w / 2, y: anchor.minY - h / 2 + 4, width: w, height: h)
      }
    }
  }

  /// Activates split tab bar constraints when container has a valid width to avoid
  /// unsatisfiable constraint warnings when platform view is still at width 0.
  ///
  /// If the view has no width yet (e.g. created while app is backgrounded), the
  /// activation is parked in `pendingSplitActivation` and resumed on
  /// `willEnterForegroundNotification`. This avoids the infinite
  /// `DispatchQueue.main.async` re-dispatch loop that previously pegged the main
  /// thread and triggered iOS 26 `cpu_resource_fatal` watchdog kills while
  /// backgrounded.
  private func activateSplitConstraintsIfNeeded(
    left: UITabBar,
    right: UITabBar,
    count: Int,
    rightCount: Int,
    leftInset: CGFloat,
    rightInset: CGFloat
  ) {
    let appState = UIApplication.shared.applicationState
    let stateStr: StaticString
    switch appState {
    case .active: stateStr = "active"
    case .inactive: stateStr = "inactive"
    case .background: stateStr = "background"
    @unknown default: stateStr = "unknown"
    }
    guard container.bounds.width > 0 else {
      // Park whenever there is no realistic chance for layout to assign a width
      // on the next runloop tick: backgrounded OR not yet in window hierarchy.
      // Resume via bounds KVO (fires when width becomes non-zero) or foreground
      // notification. Avoids infinite main-thread re-dispatch loop that
      // triggered iOS 26 watchdog kills, and avoids ~1.6s spin at startup.
      if appState == .background || container.window == nil {
        os_log("park: width=0 state=%{public}s window=%{public}s", log: splitActivationLog, type: .info, String(describing: stateStr), container.window == nil ? "nil" : "set")
        print("[CNTabBar] park: width=0 state=\(stateStr) window=\(container.window == nil ? "nil" : "set")")
        pendingSplitActivation = PendingSplitActivation(
          left: left, right: right, count: count, rightCount: rightCount,
          leftInset: leftInset, rightInset: rightInset
        )
        installForegroundObserverIfNeeded()
        return
      }
      os_log("retry: width=0 state=%{public}s window=set", log: splitActivationLog, type: .debug, String(describing: stateStr))
      print("[CNTabBar] retry: width=0 state=\(stateStr) window=set")
      DispatchQueue.main.async { [weak self] in
        self?.activateSplitConstraintsIfNeeded(
          left: left, right: right, count: count, rightCount: rightCount,
          leftInset: leftInset, rightInset: rightInset
        )
      }
      return
    }
    os_log("activate: width=%{public}.1f state=%{public}s", log: splitActivationLog, type: .info, container.bounds.width, String(describing: stateStr))
    print("[CNTabBar] activate: width=\(container.bounds.width) state=\(stateStr)")
    pendingSplitActivation = nil
    let spacing = splitSpacingVal
    let leftWidth = left.sizeThatFits(.zero).width + leftInset * 2
    let rightWidth = right.sizeThatFits(.zero).width + rightInset * 2
    let minItemWidth: CGFloat = 44.0
    let adjustedRightWidth = max(rightWidth, minItemWidth * CGFloat(rightCount))
    let adjustedLeftWidth = max(leftWidth, minItemWidth * CGFloat(count - rightCount))
    let adjustedTotal = adjustedLeftWidth + adjustedRightWidth + spacing
    if adjustedTotal > container.bounds.width {
      let rightFraction = CGFloat(rightCount) / CGFloat(count)
      NSLayoutConstraint.activate([
        right.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -rightInset),
        right.topAnchor.constraint(equalTo: container.topAnchor),
        right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        right.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: rightFraction),
        left.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leftInset),
        left.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -spacing),
        left.topAnchor.constraint(equalTo: container.topAnchor),
        left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
    } else {
      NSLayoutConstraint.activate([
        right.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -rightInset),
        right.topAnchor.constraint(equalTo: container.topAnchor),
        right.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        right.widthAnchor.constraint(equalToConstant: adjustedRightWidth),
        left.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leftInset),
        left.topAnchor.constraint(equalTo: container.topAnchor),
        left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        left.widthAnchor.constraint(equalToConstant: adjustedLeftWidth),
        left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -spacing),
      ])
    }
  }

  private func installForegroundObserverIfNeeded() {
    guard foregroundObserver == nil else { return }
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.resumePendingSplitActivation()
    }
  }

  private func resumePendingSplitActivation() {
    guard let p = pendingSplitActivation,
          let left = p.left, let right = p.right else {
      pendingSplitActivation = nil
      return
    }
    os_log("resume: pending split activation triggered", log: splitActivationLog, type: .info)
    print("[CNTabBar] resume: pending split activation triggered")
    activateSplitConstraintsIfNeeded(
      left: left, right: right, count: p.count, rightCount: p.rightCount,
      leftInset: p.leftInset, rightInset: p.rightInset
    )
  }

  private func scheduleBadgeLayout() {
    let apply = { [weak self] in
      guard let self = self else { return }
      self.container.setNeedsLayout()
      self.container.layoutIfNeeded()
      if let bar = self.tabBar {
        bar.layoutIfNeeded()
        self.applyBadges(to: bar, itemOffset: 0)
      }
      if let left = self.tabBarLeft, let right = self.tabBarRight {
        left.layoutIfNeeded()
        right.layoutIfNeeded()
        self.applyBadges(to: left, itemOffset: 0)
        self.applyBadges(to: right, itemOffset: left.items?.count ?? 0)
      }
    }
    DispatchQueue.main.async(execute: apply)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: apply)
  }

  private func withSuppressedSelectionCallbacks(_ block: () -> Void) {
    suppressSelectionCallbacks = true
    block()
    suppressSelectionCallbacks = false
  }

  private func nativeIndex(forLogicalIndex index: Int) -> Int {
    guard let centerActionIndex, index >= centerActionIndex else { return index }
    return index + 1
  }

  private func logicalIndex(forNativeIndex index: Int) -> Int? {
    guard let centerActionIndex else { return index }
    if index == centerActionIndex { return nil }
    return index > centerActionIndex ? index - 1 : index
  }

  private func insertingCenterActionItem(into items: [UITabBarItem]) -> [UITabBarItem] {
    guard let centerActionIndex else { return items }
    var result = items
    let placeholder = UITabBarItem(title: nil, image: nil, selectedImage: nil)
    placeholder.isEnabled = false
    result.insert(placeholder, at: min(centerActionIndex, result.count))
    return result
  }

  private func restoreSelection(
    singleFallback: UITabBarItem? = nil,
    leftFallback: UITabBarItem? = nil,
    rightFallback: UITabBarItem? = nil
  ) {
    if let bar = tabBar, let items = bar.items {
      let nativeIndex = nativeIndex(forLogicalIndex: currentSelectedIndex)
      if nativeIndex >= 0, nativeIndex < items.count {
        bar.selectedItem = items[nativeIndex]
      } else {
        bar.selectedItem = singleFallback
      }
      bar.setNeedsLayout()
      bar.layoutIfNeeded()
      return
    }

    guard let left = tabBarLeft, let right = tabBarRight, let leftItems = left.items else { return }
    if splitRightAsButton {
      right.selectedItem = nil
      if currentSelectedIndex >= 0, currentSelectedIndex < leftItems.count {
        left.selectedItem = leftItems[currentSelectedIndex]
      } else {
        left.selectedItem = leftFallback
      }
      left.setNeedsLayout()
      left.layoutIfNeeded()
      right.setNeedsLayout()
      right.layoutIfNeeded()
      return
    }

    if currentSelectedIndex >= 0, currentSelectedIndex < leftItems.count {
      left.selectedItem = leftItems[currentSelectedIndex]
      right.selectedItem = nil
    } else if let rightItems = right.items {
      let rightIndex = currentSelectedIndex - leftItems.count
      if rightIndex >= 0, rightIndex < rightItems.count {
        right.selectedItem = rightItems[rightIndex]
        left.selectedItem = nil
      } else {
        left.selectedItem = leftFallback
        right.selectedItem = rightFallback
      }
    } else {
      left.selectedItem = leftFallback
      right.selectedItem = rightFallback
    }
    left.setNeedsLayout()
    left.layoutIfNeeded()
    right.setNeedsLayout()
    right.layoutIfNeeded()
  }

  private func performLabelRefreshIfReady(allowWithoutStableBounds: Bool = false) {
    guard !isRefreshingLabels else { return }
    guard container.window != nil else { return }
    guard container.bounds.width > 0 || allowWithoutStableBounds else { return }

    container.setNeedsLayout()
    container.layoutIfNeeded()

    let animationsWereEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    func completeRefresh(
      singleFallback: UITabBarItem? = nil,
      leftFallback: UITabBarItem? = nil,
      rightFallback: UITabBarItem? = nil
    ) {
      self.restoreSelection(
        singleFallback: singleFallback,
        leftFallback: leftFallback,
        rightFallback: rightFallback
      )
      CATransaction.commit()
      UIView.performWithoutAnimation {
        self.container.setNeedsLayout()
        self.container.layoutIfNeeded()
      }
      self.applyLabelStyles()
      self.scheduleBadgeLayout()
      UIView.setAnimationsEnabled(animationsWereEnabled)
      self.isRefreshingLabels = false
      self.needsLabelRefresh = false
    }

    if let bar = tabBar, let items = bar.items, !items.isEmpty {
      let originalDelegate = bar.delegate
      let originalSelected = bar.selectedItem
      bar.delegate = nil
      isRefreshingLabels = true

      UIView.performWithoutAnimation {
        for item in items {
          bar.selectedItem = item
          bar.setNeedsLayout()
          bar.layoutIfNeeded()
        }
        bar.delegate = originalDelegate
      }
      completeRefresh(singleFallback: originalSelected)
      return
    }

    guard let left = tabBarLeft, let right = tabBarRight else {
      completeRefresh()
      return
    }
    let leftItems = left.items ?? []
    let rightItems = right.items ?? []
    guard !leftItems.isEmpty || !rightItems.isEmpty else {
      completeRefresh()
      return
    }

    let leftDelegate = left.delegate
    let rightDelegate = right.delegate
    let leftOriginal = left.selectedItem
    let rightOriginal = right.selectedItem
    left.delegate = nil
    right.delegate = nil
    isRefreshingLabels = true

    UIView.performWithoutAnimation {
      for item in leftItems {
        left.selectedItem = item
        left.setNeedsLayout()
        left.layoutIfNeeded()
      }
      for item in rightItems {
        right.selectedItem = item
        right.setNeedsLayout()
        right.layoutIfNeeded()
      }
      left.delegate = leftDelegate
      right.delegate = rightDelegate
    }
    completeRefresh(leftFallback: leftOriginal, rightFallback: rightOriginal)
  }

  private func scheduleLabelRefresh(resetBoundsTrigger: Bool = false) {
    if resetBoundsTrigger {
      hasScheduledNonZeroBoundsRefresh = false
      needsLabelRefresh = true
    }

    labelRefreshGeneration += 1
    let generation = labelRefreshGeneration
    let delays: [TimeInterval] = [0.0, 0.05, 0.15, 0.3]

    for delay in delays {
      let execute = { [weak self] in
        guard let self = self,
              self.labelRefreshGeneration == generation,
              self.needsLabelRefresh else { return }
        self.performLabelRefreshIfReady(allowWithoutStableBounds: delay >= 0.3)
      }
      if delay == 0 {
        DispatchQueue.main.async(execute: execute)
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: execute)
      }
    }
  }

  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(name: "\(ChannelConstants.viewIdCupertinoNativeTabBar)_\(viewId)", binaryMessenger: messenger)
    self.container = CupertinoTabBarContainerView(frame: frame)

    var labels: [String] = []
    var symbols: [String] = []
    var activeSymbols: [String] = []
    var badges: [String?] = []
    var customIconBytes: [Data?] = []
    var activeCustomIconBytes: [Data?] = []
    var imageAssetPaths: [String] = []
    var activeImageAssetPaths: [String] = []
    var imageAssetData: [Data?] = []
    var activeImageAssetData: [Data?] = []
    var imageAssetFormats: [String] = []
    var activeImageAssetFormats: [String] = []
    var imageAssetXcassetNames: [String] = []
    var activeImageAssetXcassetNames: [String] = []
    var iconScale: CGFloat = UIScreen.main.scale
    var sizes: [NSNumber] = []
    var colors: [NSNumber] = [] // ignored; use tintColor
    var selectedIndex: Int = 0
    var isDark: Bool = false
    var tint: UIColor? = nil
    var bg: UIColor? = nil
    var split: Bool = false
    var rightCount: Int = 1
    var leftInset: CGFloat = 0
    var rightInset: CGFloat = 0
    var hasCenterAction: Bool = false
    var centerActionSymbol: String = "plus"
    var centerActionIconSize: CGFloat = 24
    var centerActionVerticalOffset: CGFloat = 0
    var centerActionTint: UIColor? = nil
    var centerActionAccessibilityLabel: String? = nil

    var badgeColors: [NSNumber?] = []
    if let dict = args as? [String: Any] {
      labels = (dict["labels"] as? [String]) ?? []
      symbols = (dict["sfSymbols"] as? [String]) ?? []
      activeSymbols = (dict["activeSfSymbols"] as? [String]) ?? []
      badges = Self.parseBadges(dict["badges"])
      badgeColors = Self.parseBadgeColors(dict["badgeColors"])
      if let bytesArray = dict["customIconBytes"] as? [FlutterStandardTypedData?] {
        customIconBytes = bytesArray.map { $0?.data }
      }
      if let bytesArray = dict["activeCustomIconBytes"] as? [FlutterStandardTypedData?] {
        activeCustomIconBytes = bytesArray.map { $0?.data }
      }
      imageAssetPaths = (dict["imageAssetPaths"] as? [String]) ?? []
      activeImageAssetPaths = (dict["activeImageAssetPaths"] as? [String]) ?? []
      if let bytesArray = dict["imageAssetData"] as? [FlutterStandardTypedData?] {
        imageAssetData = bytesArray.map { $0?.data }
      }
      if let bytesArray = dict["activeImageAssetData"] as? [FlutterStandardTypedData?] {
        activeImageAssetData = bytesArray.map { $0?.data }
      }
      imageAssetFormats = (dict["imageAssetFormats"] as? [String]) ?? []
      activeImageAssetFormats = (dict["activeImageAssetFormats"] as? [String]) ?? []
      imageAssetXcassetNames = (dict["imageAssetXcassetNames"] as? [String]) ?? []
      activeImageAssetXcassetNames = (dict["activeImageAssetXcassetNames"] as? [String]) ?? []
      if let scale = dict["iconScale"] as? NSNumber {
        iconScale = CGFloat(truncating: scale)
      }
      sizes = (dict["sfSymbolSizes"] as? [NSNumber]) ?? []
      colors = (dict["sfSymbolColors"] as? [NSNumber]) ?? []
      if let v = dict["selectedIndex"] as? NSNumber { selectedIndex = v.intValue }
      if let v = dict["isDark"] as? NSNumber { isDark = v.boolValue }
      if let style = dict["style"] as? [String: Any] {
        if let n = style["tint"] as? NSNumber { tint = ImageUtils.colorFromARGB(n.intValue) }
        if let n = style["backgroundColor"] as? NSNumber { bg = ImageUtils.colorFromARGB(n.intValue) }
      }
      if let s = dict["split"] as? NSNumber { split = s.boolValue }
      if let rc = dict["rightCount"] as? NSNumber { rightCount = rc.intValue }
      if let sp = dict["splitSpacing"] as? NSNumber { splitSpacingVal = CGFloat(truncating: sp) }
      if let rb = dict["splitRightAsButton"] as? NSNumber { self.splitRightAsButton = rb.boolValue }
      if let value = dict["hasCenterAction"] as? NSNumber { hasCenterAction = value.boolValue }
      if let value = dict["centerActionSymbol"] as? String, !value.isEmpty { centerActionSymbol = value }
      if let value = dict["centerActionSize"] as? NSNumber { centerActionSize = CGFloat(truncating: value) }
      if let value = dict["centerActionIconSize"] as? NSNumber { centerActionIconSize = CGFloat(truncating: value) }
      if let value = dict["centerActionVerticalOffset"] as? NSNumber {
        centerActionVerticalOffset = CGFloat(truncating: value)
      }
      if let value = dict["centerActionTint"] as? NSNumber { centerActionTint = ImageUtils.colorFromARGB(value.intValue) }
      if let value = dict["centerActionAccessibilityLabel"] as? String, !value.isEmpty {
        centerActionAccessibilityLabel = value
      }
      if let ls = dict["labelStyle"] as? [String: Any] { self.labelStyleDict = ls }
      if let als = dict["activeLabelStyle"] as? [String: Any] { self.activeLabelStyleDict = als }
      // content insets controlled by Flutter padding; keep zero here
    }

    // Preload SVG assets dynamically based on what's actually being used for
    // Flutter asset paths; xcasset-based images are loaded via UIImage(named:).
    let allAssetPaths = Set(imageAssetPaths + activeImageAssetPaths).filter { !$0.isEmpty }
    if !allAssetPaths.isEmpty {
      SVGImageLoader.shared.preloadAssetsFromPaths(Array(allAssetPaths))
    }

    super.init()

    self.centerActionIndex = hasCenterAction ? max(labels.count, symbols.count) / 2 : nil
    container.backgroundColor = .clear
    container.onDidMoveToWindow = { [weak self] in
      guard let self = self else { return }
      print("[CNTabBar] didMoveToWindow window=\(self.container.window == nil ? "nil" : "set") width=\(self.container.bounds.width)")
      if self.container.window != nil {
        self.resumePendingSplitActivation()
        if self.needsLabelRefresh {
          if self.container.bounds.width > 0, !self.hasScheduledNonZeroBoundsRefresh {
            self.hasScheduledNonZeroBoundsRefresh = true
          }
          self.scheduleLabelRefresh()
        } else {
          self.scheduleBadgeLayout()
        }
      }
    }
    container.onLayout = { [weak self] in
      guard let self = self else { return }
      if self.container.bounds.width > 0 {
        self.resumePendingSplitActivation()
        if self.needsLabelRefresh, !self.hasScheduledNonZeroBoundsRefresh {
          self.hasScheduledNonZeroBoundsRefresh = true
          self.scheduleLabelRefresh()
        }
      }
    }
    containerBoundsObservation = container.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
      guard let self = self else { return }
      let oldWidth = change.oldValue?.width ?? 0
      let newWidth = change.newValue?.width ?? 0
      guard newWidth > 0, oldWidth != newWidth else { return }
      self.resumePendingSplitActivation()
      self.scheduleBadgeLayout()
      if self.needsLabelRefresh, !self.hasScheduledNonZeroBoundsRefresh {
        self.hasScheduledNonZeroBoundsRefresh = true
        self.scheduleLabelRefresh()
      }
    }
    container.clipsToBounds = false // Allow tab bar and badge overlays to draw without being cut at top/bottom
    container.layer.shadowOpacity = 0 // Explicitly disable layer shadow
    if #available(iOS 13.0, *) { container.overrideUserInterfaceStyle = isDark ? .dark : .light }

    let appearance: UITabBarAppearance? = {
    if #available(iOS 13.0, *) {
      let ap = UITabBarAppearance()
      ap.configureWithTransparentBackground()
      // Remove shadow to prevent shadow appearing over modals/bottom sheets
      ap.shadowColor = .clear
      ap.shadowImage = UIImage()
      return ap
    }
    return nil
  }()
    func buildItems(_ range: Range<Int>) -> [UITabBarItem] {
      var items: [UITabBarItem] = []
      for i in range {
        var image: UIImage? = nil
        var selectedImage: UIImage? = nil
        let xcassetName = (i < imageAssetXcassetNames.count) ? imageAssetXcassetNames[i] : ""
        let activeXcassetName = (i < activeImageAssetXcassetNames.count) ? activeImageAssetXcassetNames[i] : ""
        
        // Priority: xcasset > imageAsset > customIconBytes > SF Symbol
        // Unselected image
        if !xcassetName.isEmpty {
          image = UIImage(named: xcassetName, in: Bundle.main, compatibleWith: nil)
        } else if i < imageAssetData.count, let data = imageAssetData[i] {
          image = Self.createImageFromData(
            data,
            format: (i < imageAssetFormats.count) ? imageAssetFormats[i] : nil,
            scale: iconScale
          )
        } else if i < imageAssetPaths.count && !imageAssetPaths[i].isEmpty {
          image = Self.loadFlutterAsset(imageAssetPaths[i])
        } else if i < customIconBytes.count, let data = customIconBytes[i] {
          image = UIImage(data: data, scale: self.iconScale)?.withRenderingMode(.alwaysTemplate)
        } else if i < symbols.count && !symbols[i].isEmpty {
          image = UIImage(systemName: symbols[i])
        }
        
        // Selected image: Use active versions if available
        if !activeXcassetName.isEmpty {
          selectedImage = UIImage(named: activeXcassetName, in: Bundle.main, compatibleWith: nil)
        } else if i < activeImageAssetData.count, let data = activeImageAssetData[i] {
          selectedImage = Self.createImageFromData(
            data,
            format: (i < activeImageAssetFormats.count) ? activeImageAssetFormats[i] : nil,
            scale: iconScale
          )
        } else if i < activeImageAssetPaths.count && !activeImageAssetPaths[i].isEmpty {
          selectedImage = Self.loadFlutterAsset(activeImageAssetPaths[i])
        } else if i < activeCustomIconBytes.count, let data = activeCustomIconBytes[i] {
          selectedImage = UIImage(data: data, scale: self.iconScale)?.withRenderingMode(.alwaysTemplate)
        } else if i < activeSymbols.count && !activeSymbols[i].isEmpty {
          selectedImage = UIImage(systemName: activeSymbols[i])
        } else {
          selectedImage = image // Fallback to same image
        }
        
        // Apply per-item size if provided
        if i < sizes.count {
          let szValue = CGFloat(truncating: sizes[i])
          if szValue > 0 {
            let targetSize = CGSize(width: szValue, height: szValue)
            if let img = image {
              image = ImageUtils.scaleImage(img, to: targetSize, scale: iconScale)
            }
            if let sel = selectedImage {
              selectedImage = ImageUtils.scaleImage(sel, to: targetSize, scale: iconScale)
            }
          }
        }

        let title = (i < labels.count && !labels[i].isEmpty) ? labels[i] : nil
        let item = UITabBarItem(title: title, image: image, selectedImage: selectedImage)
        item.badgeValue = nil
        items.append(item)
      }
      return items
    }
    let count = max(labels.count, symbols.count)
    if split && count > rightCount {
      let leftEnd = count - rightCount
      let left = UITabBar(frame: .zero)
      let right = UITabBar(frame: .zero)
      tabBarLeft = left; tabBarRight = right
      left.translatesAutoresizingMaskIntoConstraints = false
      right.translatesAutoresizingMaskIntoConstraints = false
      left.clipsToBounds = false
      right.clipsToBounds = false
      left.layer.shadowOpacity = 0
      right.layer.shadowOpacity = 0
      left.delegate = self; right.delegate = self
      if let bg = bg { left.barTintColor = bg; right.barTintColor = bg }
      if #available(iOS 10.0, *), let tint = tint { left.tintColor = tint; right.tintColor = tint }
      if let ap = appearance { if #available(iOS 13.0, *) { left.standardAppearance = ap; right.standardAppearance = ap; if #available(iOS 15.0, *) { left.scrollEdgeAppearance = ap; right.scrollEdgeAppearance = ap } } }
      
      left.items = buildItems(0..<leftEnd)
      right.items = buildItems(leftEnd..<count)
      if selectedIndex < leftEnd, let items = left.items {
        left.selectedItem = items[selectedIndex]
        right.selectedItem = nil
      } else if let items = right.items {
        let idx = selectedIndex - leftEnd
        if idx >= 0 && idx < items.count { right.selectedItem = items[idx] }
        left.selectedItem = nil
      }
      container.addSubview(left); container.addSubview(right)
      // Activate split constraints only after layout (when container has width) to avoid unsatisfiable constraint warnings
      let capturedSelectedIndex = selectedIndex
      let capturedLeftEnd = leftEnd
      DispatchQueue.main.async { [weak self, weak left, weak right] in
        guard let self = self, let left = left, let right = right else { return }
        self.activateSplitConstraintsIfNeeded(left: left, right: right, count: count, rightCount: rightCount, leftInset: leftInset, rightInset: rightInset)
        self.container.setNeedsLayout()
        self.container.layoutIfNeeded()
        left.setNeedsLayout()
        left.layoutIfNeeded()
        right.setNeedsLayout()
        right.layoutIfNeeded()
        // Re-assign items to force label rendering
        let leftItems = left.items
        let rightItems = right.items
        left.items = leftItems
        right.items = rightItems
        // Restore selection after re-assigning items (re-assignment can reset selection)
        if capturedSelectedIndex < capturedLeftEnd, let items = left.items, capturedSelectedIndex < items.count {
          left.selectedItem = items[capturedSelectedIndex]
          right.selectedItem = nil
        } else if let items = right.items {
          let idx = capturedSelectedIndex - capturedLeftEnd
          if idx >= 0 && idx < items.count {
            right.selectedItem = items[idx]
            left.selectedItem = nil
          }
        }
        // Force another update cycle for text rendering
        DispatchQueue.main.async { [weak left, weak right] in
          guard let left = left, let right = right else { return }
          left.setNeedsDisplay()
          right.setNeedsDisplay()
          left.setNeedsLayout()
          left.layoutIfNeeded()
          right.setNeedsLayout()
          right.layoutIfNeeded()
        }
      }
    } else {
      let bar = UITabBar(frame: .zero)
      tabBar = bar
      bar.delegate = self
      bar.translatesAutoresizingMaskIntoConstraints = false
      bar.clipsToBounds = false
      bar.layer.shadowOpacity = 0
      if let bg = bg { bar.barTintColor = bg }
      if #available(iOS 10.0, *), let tint = tint { bar.tintColor = tint }
      if let ap = appearance { if #available(iOS 13.0, *) { bar.standardAppearance = ap; if #available(iOS 15.0, *) { bar.scrollEdgeAppearance = ap } } }
      bar.items = insertingCenterActionItem(into: buildItems(0..<count))
      let nativeSelectedIndex = nativeIndex(forLogicalIndex: selectedIndex)
      if nativeSelectedIndex >= 0, let items = bar.items, nativeSelectedIndex < items.count {
        bar.selectedItem = items[nativeSelectedIndex]
      }
      container.addSubview(bar)
      NSLayoutConstraint.activate([
        bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        bar.topAnchor.constraint(equalTo: container.topAnchor),
        bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
      if hasCenterAction {
        let selectionRestoreGesture = UILongPressGestureRecognizer(
          target: self,
          action: #selector(onTabBarTouchTracking(_:))
        )
        selectionRestoreGesture.minimumPressDuration = 0
        selectionRestoreGesture.cancelsTouchesInView = false
        selectionRestoreGesture.delaysTouchesBegan = false
        selectionRestoreGesture.delegate = self
        bar.addGestureRecognizer(selectionRestoreGesture)

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = centerActionAccessibilityLabel
        button.accessibilityTraits = .button
        button.addTarget(self, action: #selector(onCenterActionTapped), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onCenterActionLongPressed(_:)))
        button.addGestureRecognizer(longPress)

        let symbolConfig = UIImage.SymbolConfiguration(
          pointSize: centerActionIconSize,
          weight: .semibold
        )
        let image = UIImage(systemName: centerActionSymbol, withConfiguration: symbolConfig)
        if #available(iOS 26.0, *) {
          var config = UIButton.Configuration.prominentGlass()
          config.image = image
          config.baseForegroundColor = .white
          config.baseBackgroundColor = centerActionTint
          config.cornerStyle = .capsule
          button.configuration = config
        } else {
          button.setImage(image, for: .normal)
          button.tintColor = .white
          button.backgroundColor = centerActionTint ?? .systemBlue
          button.layer.cornerRadius = centerActionSize / 2
        }

        centerActionButton = button
        bar.addSubview(button)
        NSLayoutConstraint.activate([
          button.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
          button.centerYAnchor.constraint(
            equalTo: bar.safeAreaLayoutGuide.centerYAnchor,
            constant: centerActionVerticalOffset
          ),
          button.widthAnchor.constraint(equalToConstant: centerActionSize),
          button.heightAnchor.constraint(equalToConstant: centerActionSize),
        ])
        bar.bringSubviewToFront(button)
      }
      // Force layout update for background and text rendering on iOS < 16
      // Re-assign items after layout to ensure labels render properly
      DispatchQueue.main.async { [weak self, weak bar] in
        guard let self = self, let bar = bar else { return }
        self.container.setNeedsLayout()
        self.container.layoutIfNeeded()
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        // Re-assign items to force label rendering
        let items = bar.items
        bar.items = items
        let nativeSelectedIndex = self.nativeIndex(forLogicalIndex: selectedIndex)
        if let items = bar.items, nativeSelectedIndex >= 0, nativeSelectedIndex < items.count {
          bar.selectedItem = items[nativeSelectedIndex]
        }
        // Force another update cycle for text rendering
        DispatchQueue.main.async { [weak bar] in
          guard let bar = bar else { return }
          bar.setNeedsDisplay()
          bar.setNeedsLayout()
          bar.layoutIfNeeded()
        }
      }
    }
    // Store split settings for future updates
    self.currentSelectedIndex = selectedIndex
    self.isSplit = split
    self.rightCountVal = rightCount
    self.currentLabels = labels
    self.currentSymbols = symbols
    self.currentActiveSymbols = activeSymbols
    self.currentBadges = badges
    self.currentBadgeColors = badgeColors
    self.currentCustomIconBytes = customIconBytes
    self.currentActiveCustomIconBytes = activeCustomIconBytes
    self.currentImageAssetPaths = imageAssetPaths
    self.currentActiveImageAssetPaths = activeImageAssetPaths
    self.currentImageAssetXcassetNames = imageAssetXcassetNames
    self.currentActiveImageAssetXcassetNames = activeImageAssetXcassetNames
    self.currentImageAssetData = imageAssetData
    self.currentActiveImageAssetData = activeImageAssetData
    self.currentImageAssetFormats = imageAssetFormats
    self.currentActiveImageAssetFormats = activeImageAssetFormats
    self.currentSizes = sizes
    self.iconScale = iconScale
    self.leftInsetVal = leftInset
    self.rightInsetVal = rightInset
    scheduleBadgeLayout()
    if labelStyleDict != nil || activeLabelStyleDict != nil {
      applyLabelStyles()
    }
    scheduleLabelRefresh(resetBoundsTrigger: true)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "getIntrinsicSize":
        // Defer result until after layout so Flutter gets size only when native has finished layout.
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }
          self.container.setNeedsLayout()
          self.container.layoutIfNeeded()
          if let bar = self.tabBar ?? self.tabBarLeft ?? self.tabBarRight {
            let size = bar.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            result(["width": Double(size.width), "height": Double(size.height)])
          } else {
            result(["width": Double(self.container.bounds.width), "height": 50.0])
          }
        }
      case "setItems":
        if let args = call.arguments as? [String: Any] {
          let labels = (args["labels"] as? [String]) ?? []
          let symbols = (args["sfSymbols"] as? [String]) ?? []
          let activeSymbols = (args["activeSfSymbols"] as? [String]) ?? []
          let badges = Self.parseBadges(args["badges"])
          let badgeColors = Self.parseBadgeColors(args["badgeColors"])
          var customIconBytes: [Data?] = []
          var activeCustomIconBytes: [Data?] = []
          var imageAssetPaths: [String] = []
          var activeImageAssetPaths: [String] = []
          var imageAssetData: [Data?] = []
          var activeImageAssetData: [Data?] = []
          var imageAssetFormats: [String] = []
          var activeImageAssetFormats: [String] = []
          var sizes: [NSNumber] = []
          if let bytesArray = args["customIconBytes"] as? [FlutterStandardTypedData?] {
            customIconBytes = bytesArray.map { $0?.data }
          }
          if let bytesArray = args["activeCustomIconBytes"] as? [FlutterStandardTypedData?] {
            activeCustomIconBytes = bytesArray.map { $0?.data }
          }
          imageAssetPaths = (args["imageAssetPaths"] as? [String]) ?? []
          activeImageAssetPaths = (args["activeImageAssetPaths"] as? [String]) ?? []
          if let bytesArray = args["imageAssetData"] as? [FlutterStandardTypedData?] {
            imageAssetData = bytesArray.map { $0?.data }
          }
          if let bytesArray = args["activeImageAssetData"] as? [FlutterStandardTypedData?] {
            activeImageAssetData = bytesArray.map { $0?.data }
          }
          imageAssetFormats = (args["imageAssetFormats"] as? [String]) ?? []
          activeImageAssetFormats = (args["activeImageAssetFormats"] as? [String]) ?? []
          let imageAssetXcassetNames = (args["imageAssetXcassetNames"] as? [String]) ?? []
          let activeImageAssetXcassetNames = (args["activeImageAssetXcassetNames"] as? [String]) ?? []
          sizes = (args["sfSymbolSizes"] as? [NSNumber]) ?? []
          if let scale = args["iconScale"] as? NSNumber {
            self.iconScale = CGFloat(truncating: scale)
          }
          let selectedIndex = (args["selectedIndex"] as? NSNumber)?.intValue ?? 0
          self.currentSelectedIndex = selectedIndex
          self.currentLabels = labels
          self.currentSymbols = symbols
          self.currentActiveSymbols = activeSymbols
          self.currentBadges = badges
          self.currentBadgeColors = badgeColors
          self.currentCustomIconBytes = customIconBytes
          self.currentActiveCustomIconBytes = activeCustomIconBytes
          self.currentImageAssetPaths = imageAssetPaths
          self.currentActiveImageAssetPaths = activeImageAssetPaths
          self.currentImageAssetXcassetNames = imageAssetXcassetNames
          self.currentActiveImageAssetXcassetNames = activeImageAssetXcassetNames
          self.currentImageAssetData = imageAssetData
          self.currentActiveImageAssetData = activeImageAssetData
          self.currentImageAssetFormats = imageAssetFormats
          self.currentActiveImageAssetFormats = activeImageAssetFormats
          self.currentSizes = sizes
          func buildItems(_ range: Range<Int>) -> [UITabBarItem] {
            var items: [UITabBarItem] = []
            let sizes = self.currentSizes
            for i in range {
              var image: UIImage? = nil
              var selectedImage: UIImage? = nil
              let xcassetName = (i < imageAssetXcassetNames.count) ? imageAssetXcassetNames[i] : ""
              let activeXcassetName = (i < activeImageAssetXcassetNames.count) ? activeImageAssetXcassetNames[i] : ""

              // Priority: xcasset > imageAsset > customIconBytes > SF Symbol (match init)
              if !xcassetName.isEmpty {
                image = UIImage(named: xcassetName, in: Bundle.main, compatibleWith: nil)
              } else if i < imageAssetData.count, let data = imageAssetData[i] {
                image = Self.createImageFromData(data, format: (i < imageAssetFormats.count) ? imageAssetFormats[i] : nil, scale: self.iconScale)
              } else if i < imageAssetPaths.count && !imageAssetPaths[i].isEmpty {
                image = Self.loadFlutterAsset(imageAssetPaths[i])
              } else if i < customIconBytes.count, let data = customIconBytes[i] {
                image = UIImage(data: data, scale: self.iconScale)?.withRenderingMode(.alwaysTemplate)
              } else if i < symbols.count && !symbols[i].isEmpty {
                image = UIImage(systemName: symbols[i])
              }

              if !activeXcassetName.isEmpty {
                selectedImage = UIImage(named: activeXcassetName, in: Bundle.main, compatibleWith: nil)
              } else if i < activeImageAssetData.count, let data = activeImageAssetData[i] {
                selectedImage = Self.createImageFromData(data, format: (i < activeImageAssetFormats.count) ? activeImageAssetFormats[i] : nil, scale: self.iconScale)
              } else if i < activeImageAssetPaths.count && !activeImageAssetPaths[i].isEmpty {
                selectedImage = Self.loadFlutterAsset(activeImageAssetPaths[i])
              } else if i < activeCustomIconBytes.count, let data = activeCustomIconBytes[i] {
                selectedImage = UIImage(data: data, scale: self.iconScale)?.withRenderingMode(.alwaysTemplate)
              } else if i < activeSymbols.count && !activeSymbols[i].isEmpty {
                selectedImage = UIImage(systemName: activeSymbols[i])
              } else {
                selectedImage = image
              }

              // Apply per-item size if provided
              if i < sizes.count {
                let szValue = CGFloat(truncating: sizes[i])
                if szValue > 0 {
                  let targetSize = CGSize(width: szValue, height: szValue)
                  if let img = image {
                    image = ImageUtils.scaleImage(img, to: targetSize, scale: self.iconScale)
                  }
                  if let sel = selectedImage {
                    selectedImage = ImageUtils.scaleImage(sel, to: targetSize, scale: self.iconScale)
                  }
                }
              }

              let title = (i < labels.count && !labels[i].isEmpty) ? labels[i] : nil
              let item = UITabBarItem(title: title, image: image, selectedImage: selectedImage)
              item.badgeValue = nil
              items.append(item)
            }
            return items
          }
          let count = max(labels.count, symbols.count)
          if self.isSplit && count > self.rightCountVal, let left = self.tabBarLeft, let right = self.tabBarRight {
            let leftEnd = count - self.rightCountVal
            left.items = buildItems(0..<leftEnd)
            right.items = buildItems(leftEnd..<count)
            if selectedIndex < leftEnd, let items = left.items { left.selectedItem = items[selectedIndex]; right.selectedItem = nil }
            else if let items = right.items {
              let idx = selectedIndex - leftEnd
              if idx >= 0 && idx < items.count { right.selectedItem = items[idx]; left.selectedItem = nil }
            }
            result(nil)
            self.scheduleBadgeLayout()
            self.scheduleLabelRefresh(resetBoundsTrigger: true)
          } else if let bar = self.tabBar {
            bar.items = self.insertingCenterActionItem(into: buildItems(0..<count))
            let nativeSelectedIndex = self.nativeIndex(forLogicalIndex: selectedIndex)
            if let items = bar.items, nativeSelectedIndex >= 0, nativeSelectedIndex < items.count {
              bar.selectedItem = items[nativeSelectedIndex]
            }
            result(nil)
            self.scheduleBadgeLayout()
            self.scheduleLabelRefresh(resetBoundsTrigger: true)
          } else {
            result(FlutterError(code: "state_error", message: "Tab bars not initialized", details: nil))
          }
        } else { result(FlutterError(code: "bad_args", message: "Missing items", details: nil)) }
      case "setLayout":
        if let args = call.arguments as? [String: Any] {
          let split = (args["split"] as? NSNumber)?.boolValue ?? false
          let rightCount = (args["rightCount"] as? NSNumber)?.intValue ?? 1
          // Insets are controlled by Flutter padding; keep stored zeros here
          let leftInset = self.leftInsetVal
          let rightInset = self.rightInsetVal
          if let sp = args["splitSpacing"] as? NSNumber { self.splitSpacingVal = CGFloat(truncating: sp) }
          if let rb = args["splitRightAsButton"] as? NSNumber { self.splitRightAsButton = rb.boolValue }
          let selectedIndex = (args["selectedIndex"] as? NSNumber)?.intValue ?? 0
          // Remove existing bars
          self.tabBar?.removeFromSuperview(); self.tabBar = nil
          self.tabBarLeft?.removeFromSuperview(); self.tabBarLeft = nil
          self.tabBarRight?.removeFromSuperview(); self.tabBarRight = nil
          let labels = self.currentLabels
          let symbols = self.currentSymbols
          let activeSymbols = self.currentActiveSymbols
          let badges = self.currentBadges
          let customIconBytes = self.currentCustomIconBytes
          let activeCustomIconBytes = self.currentActiveCustomIconBytes
          let imageAssetPaths = self.currentImageAssetPaths
          let activeImageAssetPaths = self.currentActiveImageAssetPaths
          let imageAssetXcassetNames = self.currentImageAssetXcassetNames
          let activeImageAssetXcassetNames = self.currentActiveImageAssetXcassetNames
          let imageAssetData = self.currentImageAssetData
          let activeImageAssetData = self.currentActiveImageAssetData
          let imageAssetFormats = self.currentImageAssetFormats
          let activeImageAssetFormats = self.currentActiveImageAssetFormats
          let sizes = self.currentSizes
          let appearance: UITabBarAppearance? = {
            if #available(iOS 13.0, *) {
              let ap = UITabBarAppearance()
              ap.configureWithTransparentBackground()
              ap.shadowColor = .clear
              ap.shadowImage = UIImage()
              return ap
            }
            return nil
          }()
          func buildItems(_ range: Range<Int>) -> [UITabBarItem] {
            var items: [UITabBarItem] = []
            for i in range {
              var image: UIImage? = nil
              var selectedImage: UIImage? = nil
              let xcassetName = (i < imageAssetXcassetNames.count) ? imageAssetXcassetNames[i] : ""
              let activeXcassetName = (i < activeImageAssetXcassetNames.count) ? activeImageAssetXcassetNames[i] : ""

              if !xcassetName.isEmpty {
                image = UIImage(named: xcassetName, in: Bundle.main, compatibleWith: nil)
              } else if i < imageAssetData.count, let data = imageAssetData[i] {
                image = Self.createImageFromData(data, format: (i < imageAssetFormats.count) ? imageAssetFormats[i] : nil, scale: self.iconScale)
              } else if i < imageAssetPaths.count && !imageAssetPaths[i].isEmpty {
                image = Self.loadFlutterAsset(imageAssetPaths[i])
              } else if i < customIconBytes.count, let data = customIconBytes[i] {
                image = UIImage(data: data, scale: self.iconScale)?.withRenderingMode(.alwaysTemplate)
              } else if i < symbols.count && !symbols[i].isEmpty {
                image = UIImage(systemName: symbols[i])
              }

              if !activeXcassetName.isEmpty {
                selectedImage = UIImage(named: activeXcassetName, in: Bundle.main, compatibleWith: nil)
              } else if i < activeImageAssetData.count, let data = activeImageAssetData[i] {
                selectedImage = Self.createImageFromData(data, format: (i < activeImageAssetFormats.count) ? activeImageAssetFormats[i] : nil, scale: self.iconScale)
              } else if i < activeImageAssetPaths.count && !activeImageAssetPaths[i].isEmpty {
                selectedImage = Self.loadFlutterAsset(activeImageAssetPaths[i])
              } else if i < activeCustomIconBytes.count, let data = activeCustomIconBytes[i] {
                selectedImage = UIImage(data: data, scale: self.iconScale)?.withRenderingMode(.alwaysTemplate)
              } else if i < activeSymbols.count && !activeSymbols[i].isEmpty {
                selectedImage = UIImage(systemName: activeSymbols[i])
              } else {
                selectedImage = image
              }

              if i < sizes.count {
                let szValue = CGFloat(truncating: sizes[i])
                if szValue > 0 {
                  let targetSize = CGSize(width: szValue, height: szValue)
                  if let img = image { image = ImageUtils.scaleImage(img, to: targetSize, scale: self.iconScale) }
                  if let sel = selectedImage { selectedImage = ImageUtils.scaleImage(sel, to: targetSize, scale: self.iconScale) }
                }
              }

              let title = (i < labels.count && !labels[i].isEmpty) ? labels[i] : nil
              let item = UITabBarItem(title: title, image: image, selectedImage: selectedImage)
              item.badgeValue = nil
              items.append(item)
            }
            return items
          }
          let count = max(labels.count, symbols.count)
          if split && count > rightCount {
            let leftEnd = count - rightCount
            let left = UITabBar(frame: .zero)
            let right = UITabBar(frame: .zero)
            self.tabBarLeft = left; self.tabBarRight = right
            left.translatesAutoresizingMaskIntoConstraints = false
            right.translatesAutoresizingMaskIntoConstraints = false
            left.clipsToBounds = false
            right.clipsToBounds = false
            left.layer.shadowOpacity = 0; right.layer.shadowOpacity = 0
            left.delegate = self; right.delegate = self
            if let ap = appearance { if #available(iOS 13.0, *) { left.standardAppearance = ap; right.standardAppearance = ap; if #available(iOS 15.0, *) { left.scrollEdgeAppearance = ap; right.scrollEdgeAppearance = ap } } }
            left.items = buildItems(0..<leftEnd)
            right.items = buildItems(leftEnd..<count)
            if self.splitRightAsButton {
              // Button mode: right bar never shows selection; always select in left bar
              right.selectedItem = nil
              if selectedIndex < leftEnd, let items = left.items { left.selectedItem = items[selectedIndex] }
            } else if selectedIndex < leftEnd, let items = left.items { left.selectedItem = items[selectedIndex]; right.selectedItem = nil }
            else if let items = right.items { let idx = selectedIndex - leftEnd; if idx >= 0 && idx < items.count { right.selectedItem = items[idx]; left.selectedItem = nil } }
            self.container.addSubview(left); self.container.addSubview(right)
            let capturedSelectedIndex = selectedIndex
            let capturedLeftEnd = leftEnd
            let capturedButtonMode = self.splitRightAsButton
            DispatchQueue.main.async { [weak self, weak left, weak right] in
              guard let self = self, let left = left, let right = right else { return }
              self.activateSplitConstraintsIfNeeded(left: left, right: right, count: count, rightCount: rightCount, leftInset: leftInset, rightInset: rightInset)
              self.container.setNeedsLayout()
              self.container.layoutIfNeeded()
              left.setNeedsLayout()
              left.layoutIfNeeded()
              right.setNeedsLayout()
              right.layoutIfNeeded()
              // Re-assign items to force label rendering
              let leftItems = left.items
              let rightItems = right.items
              left.items = leftItems
              right.items = rightItems
              // Restore selection after re-assigning items (re-assignment can reset selection)
              if capturedButtonMode {
                right.selectedItem = nil
                if capturedSelectedIndex < capturedLeftEnd, let items = left.items, capturedSelectedIndex < items.count {
                  left.selectedItem = items[capturedSelectedIndex]
                }
              } else if capturedSelectedIndex < capturedLeftEnd, let items = left.items, capturedSelectedIndex < items.count {
                left.selectedItem = items[capturedSelectedIndex]
                right.selectedItem = nil
              } else if let items = right.items {
                let idx = capturedSelectedIndex - capturedLeftEnd
                if idx >= 0 && idx < items.count {
                  right.selectedItem = items[idx]
                  left.selectedItem = nil
                }
              }
              // Force another update cycle for text rendering
              DispatchQueue.main.async { [weak left, weak right] in
                guard let left = left, let right = right else { return }
                left.setNeedsDisplay()
                right.setNeedsDisplay()
                left.setNeedsLayout()
                left.layoutIfNeeded()
                right.setNeedsLayout()
                right.layoutIfNeeded()
                // Restore selection again after final layout pass (layout can reset selection)
                if capturedButtonMode {
                  right.selectedItem = nil
                  if capturedSelectedIndex < capturedLeftEnd, let items = left.items, capturedSelectedIndex < items.count {
                    left.selectedItem = items[capturedSelectedIndex]
                  }
                } else if capturedSelectedIndex < capturedLeftEnd, let items = left.items, capturedSelectedIndex < items.count {
                  left.selectedItem = items[capturedSelectedIndex]
                  right.selectedItem = nil
                } else if let items = right.items {
                  let idx = capturedSelectedIndex - capturedLeftEnd
                  if idx >= 0 && idx < items.count {
                    right.selectedItem = items[idx]
                    left.selectedItem = nil
                  }
                }
              }
            }
          } else {
            let bar = UITabBar(frame: .zero)
            self.tabBar = bar
            bar.delegate = self
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.clipsToBounds = false
            bar.layer.shadowOpacity = 0
            if let ap = appearance { if #available(iOS 13.0, *) { bar.standardAppearance = ap; if #available(iOS 15.0, *) { bar.scrollEdgeAppearance = ap } } }
            bar.items = self.insertingCenterActionItem(into: buildItems(0..<count))
            let nativeSelectedIndex = self.nativeIndex(forLogicalIndex: selectedIndex)
            if let items = bar.items, nativeSelectedIndex >= 0, nativeSelectedIndex < items.count {
              bar.selectedItem = items[nativeSelectedIndex]
            }
            self.container.addSubview(bar)
            NSLayoutConstraint.activate([
              bar.leadingAnchor.constraint(equalTo: self.container.leadingAnchor),
              bar.trailingAnchor.constraint(equalTo: self.container.trailingAnchor),
              bar.topAnchor.constraint(equalTo: self.container.topAnchor),
              bar.bottomAnchor.constraint(equalTo: self.container.bottomAnchor),
            ])
            // Force layout update for background and text rendering on iOS < 16
            // Re-assign items after layout to ensure labels render properly
            DispatchQueue.main.async { [weak self, weak bar] in
              guard let self = self, let bar = bar else { return }
              self.container.setNeedsLayout()
              self.container.layoutIfNeeded()
              bar.setNeedsLayout()
              bar.layoutIfNeeded()
              // Re-assign items to force label rendering
              let savedSelected = bar.selectedItem
              let items = bar.items
              bar.items = items
              // Restore selection after re-assigning items (re-assignment can reset selection)
              if let saved = savedSelected { bar.selectedItem = saved }
              else if let items = bar.items {
                let nativeSelectedIndex = self.nativeIndex(forLogicalIndex: selectedIndex)
                if nativeSelectedIndex >= 0, nativeSelectedIndex < items.count {
                  bar.selectedItem = items[nativeSelectedIndex]
                }
              }
              // Force another update cycle for text rendering
              DispatchQueue.main.async { [weak bar] in
                guard let bar = bar else { return }
                bar.setNeedsDisplay()
                bar.setNeedsLayout()
                bar.layoutIfNeeded()
              }
            }
          }
          self.currentSelectedIndex = selectedIndex
          self.isSplit = split; self.rightCountVal = rightCount; self.leftInsetVal = leftInset; self.rightInsetVal = rightInset
          self.scheduleBadgeLayout()
          self.scheduleLabelRefresh(resetBoundsTrigger: true)
          result(nil)
        } else { result(FlutterError(code: "bad_args", message: "Missing layout", details: nil)) }
      case "setSelectedIndex":
        if let args = call.arguments as? [String: Any], let idx = (args["index"] as? NSNumber)?.intValue {
          self.currentSelectedIndex = idx
          // Single bar
          let nativeIndex = self.nativeIndex(forLogicalIndex: idx)
          if let bar = self.tabBar, let items = bar.items, nativeIndex >= 0, nativeIndex < items.count {
            withSuppressedSelectionCallbacks {
              bar.selectedItem = items[nativeIndex]
            }
            result(nil)
            return
          }
          // Split bars
          if let left = self.tabBarLeft, let leftItems = left.items {
            if idx < leftItems.count, idx >= 0 {
              withSuppressedSelectionCallbacks {
                left.selectedItem = leftItems[idx]
                self.tabBarRight?.selectedItem = nil
              }
              result(nil)
              return
            }
            if let right = self.tabBarRight, let rightItems = right.items {
              let ridx = idx - leftItems.count
              if ridx >= 0, ridx < rightItems.count {
                if self.splitRightAsButton {
                  // Button mode: don't visually select right items
                  result(nil)
                } else {
                  withSuppressedSelectionCallbacks {
                    right.selectedItem = rightItems[ridx]
                    self.tabBarLeft?.selectedItem = nil
                  }
                  result(nil)
                }
                return
              }
            }
          }
          result(FlutterError(code: "bad_args", message: "Index out of range", details: nil))
        } else { result(FlutterError(code: "bad_args", message: "Missing index", details: nil)) }
      case "setStyle":
        if let args = call.arguments as? [String: Any] {
          if let n = args["tint"] as? NSNumber {
            let c = ImageUtils.colorFromARGB(n.intValue)
            if let bar = self.tabBar { bar.tintColor = c }
            if let left = self.tabBarLeft { left.tintColor = c }
            if let right = self.tabBarRight { right.tintColor = c }
          }
          if let n = args["backgroundColor"] as? NSNumber {
            let c = ImageUtils.colorFromARGB(n.intValue)
            if let bar = self.tabBar { bar.barTintColor = c }
            if let left = self.tabBarLeft { left.barTintColor = c }
            if let right = self.tabBarRight { right.barTintColor = c }
          }
          result(nil)
        } else { result(FlutterError(code: "bad_args", message: "Missing style", details: nil)) }
      case "setBrightness":
        if let args = call.arguments as? [String: Any], let isDark = (args["isDark"] as? NSNumber)?.boolValue {
          if #available(iOS 13.0, *) { self.container.overrideUserInterfaceStyle = isDark ? .dark : .light }
          result(nil)
        } else { result(FlutterError(code: "bad_args", message: "Missing isDark", details: nil)) }
      case "setBadges":
        if let args = call.arguments as? [String: Any] {
          let badges = Self.parseBadges(args["badges"])
          let badgeColors = Self.parseBadgeColors(args["badgeColors"])
          self.currentBadges = badges
          self.currentBadgeColors = badgeColors
          self.scheduleBadgeLayout()
          result(nil)
        } else { result(FlutterError(code: "bad_args", message: "Missing badges", details: nil)) }
      case "setSplitRightAsButton":
        if let args = call.arguments as? [String: Any], let val = (args["value"] as? NSNumber)?.boolValue {
          self.splitRightAsButton = val
          // If turning on button mode, deselect right bar and restore left selection
          if val, let right = self.tabBarRight, let left = self.tabBarLeft, let leftItems = left.items {
            right.selectedItem = nil
            let idx = self.currentSelectedIndex
            if idx >= 0, idx < leftItems.count {
              left.selectedItem = leftItems[idx]
            }
          }
          result(nil)
        } else { result(FlutterError(code: "bad_args", message: "Missing value", details: nil)) }
      case "refresh":
        self.scheduleLabelRefresh(resetBoundsTrigger: true)
        result(nil)
      case "setLabelStyle":
        self.labelStyleDict = call.arguments as? [String: Any]
        self.applyLabelStyles()
        result(nil)
      case "setActiveLabelStyle":
        self.activeLabelStyleDict = call.arguments as? [String: Any]
        self.applyLabelStyles()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    if let token = foregroundObserver {
      NotificationCenter.default.removeObserver(token)
    }
    channel.setMethodCallHandler(nil)
    tabBar?.delegate = nil
    tabBarLeft?.delegate = nil
    tabBarRight?.delegate = nil
    centerActionButton?.removeFromSuperview()
    tabBar?.removeFromSuperview()
    tabBarLeft?.removeFromSuperview()
    tabBarRight?.removeFromSuperview()
    container.removeFromSuperview()
  }

  func view() -> UIView { container }

  @objc private func onCenterActionTapped() {
    channel.invokeMethod("centerActionTapped", arguments: nil)
  }

  @objc private func onCenterActionLongPressed(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began else { return }
    channel.invokeMethod("centerActionLongPressed", arguments: nil)
  }

  @objc private func onTabBarTouchTracking(_ recognizer: UILongPressGestureRecognizer) {
    guard
      let centerActionIndex,
      let bar = tabBar,
      let items = bar.items,
      !items.isEmpty
    else { return }
    switch recognizer.state {
    case .ended, .cancelled, .failed:
      let location = recognizer.location(in: bar)
      let slotWidth = bar.bounds.width / CGFloat(items.count)
      let centerSlot = CGRect(
        x: slotWidth * CGFloat(centerActionIndex),
        y: 0,
        width: slotWidth,
        height: bar.bounds.height
      )
      if centerSlot.contains(location) {
        forceRestoreCenterActionSelection()
      }
    default:
      break
    }
  }

  private func forceRestoreCenterActionSelection() {
    guard
      let bar = tabBar,
      let items = bar.items
    else { return }
    let selectedIndex = nativeIndex(forLogicalIndex: currentSelectedIndex)
    guard selectedIndex >= 0, selectedIndex < items.count else { return }

    withSuppressedSelectionCallbacks {
      bar.selectedItem = nil
    }
    DispatchQueue.main.async { [weak self, weak bar] in
      guard let self, let bar, let items = bar.items, selectedIndex < items.count else { return }
      self.withSuppressedSelectionCallbacks {
        bar.selectedItem = items[selectedIndex]
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self else { return }
      self.withSuppressedSelectionCallbacks {
        self.restoreSelection()
      }
    }
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    return true
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    if suppressSelectionCallbacks {
      return
    }
    // Single bar case
    if let single = self.tabBar, single === tabBar, let items = single.items, let idx = items.firstIndex(of: item) {
      guard let logicalIndex = logicalIndex(forNativeIndex: idx) else {
        restoreSelection()
        return
      }
      currentSelectedIndex = logicalIndex
      channel.invokeMethod("valueChanged", arguments: ["index": logicalIndex])
      return
    }
    // Split left
    if let left = tabBarLeft, left === tabBar, let items = left.items, let idx = items.firstIndex(of: item) {
      currentSelectedIndex = idx
      tabBarRight?.selectedItem = nil
      channel.invokeMethod("valueChanged", arguments: ["index": idx])
      return
    }
    // Split right
    if let right = tabBarRight, right === tabBar, let items = right.items, let idx = items.firstIndex(of: item), let left = tabBarLeft, let leftItems = left.items {
      if splitRightAsButton {
        // Button mode: fire callback, then deselect right bar on next run loop
        // (iOS 26 liquid glass ignores synchronous selectedItem = nil)
        channel.invokeMethod("valueChanged", arguments: ["index": leftItems.count + idx])
        let prevIdx = self.currentSelectedIndex
        DispatchQueue.main.async { [weak self, weak right, weak left] in
          guard let self = self else { return }
          self.withSuppressedSelectionCallbacks {
            right?.selectedItem = nil
            if let left = left, let leftItems = left.items,
               prevIdx >= 0, prevIdx < leftItems.count {
              left.selectedItem = leftItems[prevIdx]
            }
          }
        }
        return
      } else {
        currentSelectedIndex = leftItems.count + idx
        tabBarLeft?.selectedItem = nil
        channel.invokeMethod("valueChanged", arguments: ["index": leftItems.count + idx])
      }
      return
    }
  }


  // Use shared utility functions
  private static func loadFlutterAsset(_ assetPath: String) -> UIImage? {
    return ImageUtils.loadFlutterAsset(assetPath)
  }

  private static func createImageFromData(_ data: Data, format: String?, scale: CGFloat) -> UIImage? {
    return ImageUtils.createImageFromData(data, format: format, scale: scale)
  }

}

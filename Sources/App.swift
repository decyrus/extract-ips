import AppKit

private typealias T = DesignTokens

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow!
    private let capture = CaptureService()
    private var snapshot = CaptureSnapshot()
    private var groups: [ConnectionGroup] = []
    private var visibleGroups: [ConnectionGroup] = []
    private var selected = Set<IPv4>()
    private var capturing = false
    private var stopping = false
    private var processAfterStop = false
    private var processed = false
    private var started = Date()
    private var timer: Timer?
    private let appsTable = NSTableView()
    private let ipsTable = NSTableView()
    private let search = NSSearchField()
    private let headline = NSTextField(labelWithString: "Extract IPs")
    private let tagline = NSTextField(labelWithString: "")
    private let footnote = NSTextField(wrappingLabelWithString: "")
    private let languageControl = NSSegmentedControl()
    private let statusMark = NSImageView()
    private var appIcons: [String: NSImage] = [:]
    private var demoMode = false
    private let status = NSTextField(labelWithString: L10n.text("ready"))
    private let summary = NSTextField(labelWithString: L10n.text("guide"))
    private let groupTitle = NSTextField(labelWithString: L10n.text("applications"))
    private let detailTitle = NSTextField(labelWithString: L10n.text("destinations"))
    private let detailHint = NSTextField(wrappingLabelWithString: L10n.text("detail_empty"))
    private let exportTitle = NSTextField(labelWithString: L10n.text("selected_heading"))
    private let exportView = NSTextView()
    private let captureButton = NSButton(title: L10n.text("capture"), target: nil, action: nil)
    private let processButton = NSButton(title: L10n.text("process"), target: nil, action: nil)
    private let copyButton = NSButton(title: L10n.text("copy_ips"), target: nil, action: nil)
    private let jsonButton = NSButton(title: L10n.text("export_json"), target: nil, action: nil)
    private let textButton = NSButton(title: L10n.text("export_txt"), target: nil, action: nil)
    private let allButton = NSButton(title: L10n.text("select_visible"), target: nil, action: nil)
    private let noneButton = NSButton(title: L10n.text("clear_selection"), target: nil, action: nil)
    private let localButton = NSButton(checkboxWithTitle: L10n.text("include_local"), target: nil, action: nil)
    private let compactButton = NSButton(checkboxWithTitle: L10n.text("compact"), target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        capture.onUpdate = { [weak self] value in self?.snapshot = value; self?.refreshStatus() }
        capture.onFinish = { [weak self] value, error in
            guard let self else { return }
            self.snapshot = value
            self.capturing = false
            self.stopping = false
            self.timer?.invalidate()
            if self.processAfterStop { self.processResults() }
            self.processAfterStop = false
            self.refreshStatus()
            if let error { self.showError(error) }
        }
        if CommandLine.arguments.contains("--demo") {
            demoMode = true
            snapshot = DemoSession.snapshot()
            localButton.state = .on
            processResults()
        }
        refreshStatus()
        refreshSelection()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { capture.stop() }

    private func buildMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        menu.addItem(application)
        let submenu = NSMenu()
        submenu.addItem(withTitle: L10n.text("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = submenu
        let edit = NSMenuItem(title: L10n.text("edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L10n.text("edit"))
        editMenu.addItem(withTitle: L10n.text("copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func label(_ field: NSTextField, size: CGFloat = T.fontBody, weight: NSFont.Weight = .regular) -> NSTextField {
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = .labelColor
        return field
    }

    private func stack(_ views: [NSView], vertical: Bool, spacing: CGFloat = T.spaceMedium) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func button(_ button: NSButton, _ action: Selector, key: String = "") -> NSButton {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = .command
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func table(_ table: NSTableView, columns: [(String, String, CGFloat)]) -> NSScrollView {
        table.delegate = self
        table.dataSource = self
        table.rowHeight = T.sizeRow
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func panel(_ view: NSView, inset: CGFloat = T.spaceLarge) -> NSView {
        let panel = SurfaceView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: panel.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -inset)
        ])
        return panel
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: T.sizeWindowWidth, height: T.sizeWindowHeight),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Extract IPs"
        window.minSize = NSSize(width: T.sizeMinWidth, height: T.sizeMinHeight)
        window.center()
        guard let content = window.contentView else { return }
        _ = label(headline, size: T.fontTitle, weight: .bold)
        _ = label(tagline)
        let mark = NSImageView()
        mark.image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.widthAnchor.constraint(equalToConstant: T.sizeBrandIcon).isActive = true
        mark.heightAnchor.constraint(equalToConstant: T.sizeBrandIcon).isActive = true
        let headings = stack([headline, tagline], vertical: true, spacing: T.spaceSmall)
        let flexible = NSView()
        flexible.setContentHuggingPriority(.defaultLow, for: .horizontal)
        languageControl.segmentCount = 2
        languageControl.setLabel("EN", forSegment: 0)
        languageControl.setLabel("RU", forSegment: 1)
        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        languageControl.selectedSegment = L10n.language == "ru" ? 1 : 0
        languageControl.widthAnchor.constraint(equalToConstant: T.sizeLanguage).isActive = true
        let top = stack([mark, headings, flexible, languageControl,
                         button(captureButton, #selector(toggleCapture), key: "r"),
                         button(processButton, #selector(processPressed), key: "p")], vertical: false)
        captureButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        processButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
        captureButton.imagePosition = .imageLeading
        processButton.imagePosition = .imageLeading
        captureButton.bezelColor = Appearance.accent
        captureButton.controlSize = .large
        processButton.controlSize = .large
        _ = label(status, weight: .semibold)
        _ = label(summary, size: T.fontSmall)
        statusMark.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusMark.widthAnchor.constraint(equalToConstant: T.sizeStatusDot).isActive = true
        statusMark.heightAnchor.constraint(equalToConstant: T.sizeStatusDot).isActive = true
        let state = stack([stack([statusMark, status], vertical: false, spacing: T.spaceSmall), summary], vertical: true, spacing: T.spaceSmall)
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        _ = label(groupTitle, size: T.fontHeading, weight: .semibold)
        let appScroll = table(appsTable, columns: [("check", "", T.sizeCheckbox), ("app", "", T.sizeSidebar - T.sizeCheckbox - T.spaceSection)])
        appsTable.headerView = nil
        appsTable.usesAlternatingRowBackgroundColors = false
        appScroll.hasHorizontalScroller = false
        let selection = stack([button(allButton, #selector(selectAll)), button(noneButton, #selector(selectNone))], vertical: false, spacing: T.spaceSmall)
        allButton.controlSize = .small
        noneButton.controlSize = .small
        localButton.target = self
        localButton.action = #selector(localChanged)
        localButton.font = .systemFont(ofSize: T.fontSmall)
        let sidebar = stack([groupTitle, search, appScroll, selection, localButton], vertical: true)
        sidebar.widthAnchor.constraint(equalToConstant: T.sizeSidebar).isActive = true
        for view in [search, appScroll] { view.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }

        _ = label(detailTitle, size: T.fontHeading, weight: .semibold)
        _ = label(detailHint, size: T.fontSmall)
        detailHint.maximumNumberOfLines = 1
        detailHint.lineBreakMode = .byTruncatingMiddle
        let ipScroll = table(ipsTable, columns: [("check", "", T.sizeCheckbox), ("ip", "", T.sizeIpColumn),
                                                ("ports", "", T.sizePortColumn), ("protocol", "", T.sizeProtocolColumn),
                                                ("interface", "", T.sizeInterfaceColumn)])
        _ = label(exportTitle, size: T.fontHeading, weight: .semibold)
        compactButton.target = self
        compactButton.action = #selector(exportChanged)
        compactButton.state = .on
        compactButton.font = .systemFont(ofSize: T.fontSmall)
        let exportHeader = stack([exportTitle, NSView(), compactButton], vertical: false)
        let exportScroll = NSScrollView()
        exportScroll.hasVerticalScroller = true
        exportScroll.drawsBackground = false
        exportScroll.documentView = exportView
        exportView.isEditable = false
        exportView.isSelectable = true
        exportView.isRichText = false
        exportView.font = .monospacedSystemFont(ofSize: T.fontBody, weight: .medium)
        exportView.textColor = .textColor
        exportView.drawsBackground = false
        exportView.textContainerInset = NSSize(width: T.spaceSmall, height: T.spaceSmall)
        exportView.autoresizingMask = [.width]
        exportView.textContainer?.widthTracksTextView = true
        exportScroll.heightAnchor.constraint(equalToConstant: T.sizeExportHeight).isActive = true
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        let actions = stack([button(copyButton, #selector(copyIPs), key: "e"), button(jsonButton, #selector(saveJSON)), button(textButton, #selector(saveText))], vertical: false)
        let exportContent = stack([exportHeader, exportScroll, actions], vertical: true)
        for view in [exportHeader, exportScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: exportContent.widthAnchor).isActive = true
        }
        let exportPanel = panel(exportContent, inset: T.spaceMedium)
        _ = label(footnote, size: T.fontSmall)
        let detail = stack([detailTitle, detailHint, ipScroll, exportPanel, footnote], vertical: true)
        for view in [detailHint, ipScroll, exportPanel, footnote] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
        let body = stack([sidebar, detail], vertical: false, spacing: T.spaceSection)
        body.alignment = .top
        detail.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -T.sizeSidebar - T.spaceSection).isActive = true
        sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        detail.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let root = stack([top, state, body], vertical: true, spacing: T.spaceSection)
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: T.spaceSection),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -T.spaceSection),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: T.spaceLarge),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -T.spaceLarge),
            top.widthAnchor.constraint(equalTo: root.widthAnchor),
            state.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        applyLanguage()
    }

    @objc private func languageChanged() {
        L10n.setLanguage(languageControl.selectedSegment == 1 ? "ru" : "en")
        applyLanguage()
    }

    private func applyLanguage() {
        buildMenu()
        tagline.stringValue = L10n.text("headline")
        footnote.stringValue = L10n.text("footer")
        search.placeholderString = L10n.text("search")
        search.setAccessibilityLabel(L10n.text("search"))
        languageControl.setAccessibilityLabel(L10n.text("language"))
        languageControl.toolTip = L10n.text("language")
        appsTable.setAccessibilityLabel(L10n.text("apps_accessibility"))
        ipsTable.setAccessibilityLabel(L10n.text("ips_accessibility"))
        exportView.setAccessibilityLabel(L10n.text("export_accessibility"))
        for (control, key) in [(processButton, "process"), (copyButton, "copy_ips"), (jsonButton, "export_json"),
                               (textButton, "export_txt"), (allButton, "select_visible"), (noneButton, "clear_selection"),
                               (localButton, "include_local"), (compactButton, "compact")] { control.title = L10n.text(key) }
        compactButton.toolTip = L10n.text("compact_help")
        jsonButton.toolTip = L10n.text("export_help")
        textButton.toolTip = L10n.text("export_help")
        for (id, key) in [("ip", "destination_column"), ("ports", "ports_column"), ("protocol", "protocol_column"), ("interface", "interface_column")] {
            ipsTable.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.title = L10n.text(key)
        }
        applyFilter()
        refreshStatus()
    }

    @objc private func toggleCapture() {
        if capturing {
            stopping = true
            capture.stop()
            refreshStatus()
            return
        }
        if !snapshot.observations.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.text("new_capture_title")
            alert.informativeText = L10n.text("new_capture_body")
            alert.addButton(withTitle: L10n.text("new_capture_confirm"))
            alert.addButton(withTitle: L10n.text("cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        demoMode = false
        snapshot = CaptureSnapshot()
        groups = []
        visibleGroups = []
        selected = []
        processed = false
        processAfterStop = false
        search.stringValue = ""
        appsTable.reloadData()
        ipsTable.reloadData()
        refreshSelection()
        started = Date()
        do {
            try capture.start()
            capturing = true
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
        } catch { showError(L10n.text("launch_error", error.localizedDescription)) }
        refreshStatus()
    }

    @objc private func processPressed() {
        if capturing {
            processAfterStop = true
            stopping = true
            capture.stop()
            refreshStatus()
        } else { processResults() }
    }

    private func processResults() {
        processed = true
        groups = Processor.groups(snapshot.observations, includeLocal: localButton.state == .on)
        selected.formIntersection(Set(groups.flatMap { $0.ips }))
        applyFilter()
        refreshStatus()
    }

    @objc private func localChanged() { if processed { processResults() } }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    private func applyFilter() {
        let previous = currentGroup?.app.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleGroups = groups.filter { group in
            query.isEmpty || group.app.name.localizedCaseInsensitiveContains(query) || group.ips.contains { $0.text.contains(query) }
        }
        appsTable.reloadData()
        if let row = visibleGroups.firstIndex(where: { $0.app.id == previous }) ?? (visibleGroups.isEmpty ? nil : 0) {
            appsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        groupTitle.stringValue = L10n.text("applications_count", visibleGroups.count)
        refreshDetail()
        refreshSelection()
    }

    private var currentGroup: ConnectionGroup? {
        let row = appsTable.selectedRow
        return row >= 0 && row < visibleGroups.count ? visibleGroups[row] : nil
    }

    private var visibleObservations: [Observation] {
        currentGroup?.observations ?? []
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === appsTable ? visibleGroups.count : visibleObservations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let column = tableColumn?.identifier.rawValue ?? ""
        if column == "check" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: tableView === appsTable ? #selector(toggleGroup(_:)) : #selector(toggleIP(_:)))
            check.tag = row
            if tableView === appsTable {
                let group = visibleGroups[row]
                let count = selected.intersection(group.ips).count
                check.allowsMixedState = true
                check.state = count == 0 ? .off : count == group.ips.count ? .on : .mixed
                check.setAccessibilityLabel(L10n.text("select_app_accessibility", group.app.name))
            } else {
                let ip = visibleObservations[row].key.ip
                check.state = selected.contains(ip) ? .on : .off
                check.setAccessibilityLabel(L10n.text("select_ip_accessibility", ip.text))
            }
            return check
        }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: T.fontBody)
        if tableView === appsTable {
            let group = visibleGroups[row]
            field.stringValue = group.app.name
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let icon = NSImageView()
            if appIcons[group.app.id] == nil {
                appIcons[group.app.id] = group.app.path.hasPrefix("/") && FileManager.default.fileExists(atPath: group.app.path)
                    ? NSWorkspace.shared.icon(forFile: group.app.path)
                    : NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            }
            icon.image = appIcons[group.app.id]
            icon.imageScaling = .scaleProportionallyDown
            icon.widthAnchor.constraint(equalToConstant: T.sizeAppIcon).isActive = true
            icon.heightAnchor.constraint(equalToConstant: T.sizeAppIcon).isActive = true
            let count = label(NSTextField(labelWithString: String(group.ips.count)), size: T.fontSmall, weight: .medium)
            count.setContentHuggingPriority(.required, for: .horizontal)
            let row = stack([icon, field, count], vertical: false, spacing: T.spaceSmall)
            row.toolTip = group.app.path
            return row
        } else {
            let value = visibleObservations[row]
            switch column {
            case "ip": field.stringValue = value.key.ip.text; field.font = .monospacedSystemFont(ofSize: T.fontBody, weight: .regular)
            case "ports": field.stringValue = value.ports.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.joined(separator: ", ")
            case "protocol": field.stringValue = value.transports.sorted().joined(separator: "/")
            default: field.stringValue = value.interfaces.sorted().joined(separator: ", ")
            }
            let owners = groups.filter { $0.ips.contains(value.key.ip) }.map { $0.app.name }.joined(separator: ", ")
            field.toolTip = "\(owners)\n\(value.processes.sorted().joined(separator: ", "))\n" + L10n.text("observations", value.count, L10n.time(value.firstSeen), L10n.time(value.lastSeen))
        }
        let cell = NSView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === appsTable { refreshDetail() }
    }

    private func refreshDetail() {
        if let group = currentGroup {
            detailTitle.stringValue = "\(group.app.name) · \(group.ips.count) IP"
            detailHint.stringValue = group.app.path
            detailHint.toolTip = group.app.path
        } else {
            detailTitle.stringValue = processed ? L10n.text("no_destinations") : L10n.text("destinations")
            detailHint.stringValue = processed ? L10n.text("detail_no_results") : L10n.text("detail_before_process")
        }
        ipsTable.reloadData()
    }

    @objc private func toggleGroup(_ sender: NSButton) {
        let group = visibleGroups[sender.tag]
        if group.ips.isSubset(of: selected) { selected.subtract(group.ips) } else { selected.formUnion(group.ips) }
        appsTable.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        refreshSelection()
    }

    @objc private func toggleIP(_ sender: NSButton) {
        let ip = visibleObservations[sender.tag].key.ip
        if selected.contains(ip) { selected.remove(ip) } else { selected.insert(ip) }
        refreshSelection()
    }

    @objc private func selectAll() { selected.formUnion(visibleGroups.flatMap { $0.ips }); refreshSelection() }
    @objc private func selectNone() { selected.removeAll(); refreshSelection() }
    @objc private func exportChanged() { refreshSelection() }
    private var exportLines: [String] { Processor.lines(selected, compact: compactButton.state == .on) }

    private func refreshSelection() {
        appsTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<visibleGroups.count), columnIndexes: IndexSet(integer: 0))
        ipsTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<visibleObservations.count), columnIndexes: IndexSet(integer: 0))
        let lines = exportLines
        exportTitle.stringValue = L10n.text("selection_count", selected.count, lines.count)
        exportView.string = lines.isEmpty ? L10n.text("export_empty") : lines.joined(separator: "\n")
        copyButton.isEnabled = !selected.isEmpty
        jsonButton.isEnabled = !selected.isEmpty
        textButton.isEnabled = !selected.isEmpty
        allButton.isEnabled = !visibleGroups.isEmpty
        noneButton.isEnabled = !selected.isEmpty
    }

    private func refreshStatus() {
        statusMark.contentTintColor = capturing ? Appearance.accent : .secondaryLabelColor
        captureButton.title = capturing ? L10n.text("stop") : L10n.text("capture")
        captureButton.isEnabled = !stopping
        processButton.isEnabled = !stopping && (capturing || !snapshot.observations.isEmpty)
        localButton.isEnabled = !capturing
        let unique = Set(snapshot.observations.map { $0.key.ip }).count
        let local = Set(snapshot.observations.filter { !$0.key.ip.isPublic }.map { $0.key.ip }).count
        if demoMode { status.stringValue = L10n.text("demo") }
        else if stopping { status.stringValue = L10n.text("stopping") }
        else if capturing {
            let seconds = Int(Date().timeIntervalSince(started))
            status.stringValue = L10n.text("capturing", String(format: "%02d:%02d", seconds / 60, seconds % 60), unique)
        } else if processed { status.stringValue = L10n.text("processed", groups.count, Set(groups.flatMap { $0.ips }).count) }
        else if unique > 0 { status.stringValue = L10n.text("stopped", unique) }
        else { status.stringValue = L10n.text("ready") }
        if capturing || unique > 0 || processed {
            summary.stringValue = L10n.text("diagnostics", snapshot.ipv6Count, local, snapshot.malformedRows)
        } else { summary.stringValue = L10n.text("guide") }
    }

    @objc private func copyIPs() {
        guard !selected.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportLines.joined(separator: "\n") + "\n", forType: .string)
        status.stringValue = L10n.text("copy_success", exportLines.count)
    }

    @objc private func saveJSON() { save(json: true) }
    @objc private func saveText() { save(json: false) }

    private func save(json: Bool) {
        guard !selected.isEmpty else { return }
        let lines = exportLines
        do {
            let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let name = "ip-list-\(stamp.string(from: Date()))-\(UUID().uuidString.prefix(8)).\(json ? "json" : "txt")"
            let url = directory.appendingPathComponent(name)
            let data = try json ? Processor.exportJSON(lines) : Data((lines.joined(separator: "\n") + "\n").utf8)
            try data.write(to: url, options: .atomic)
            status.stringValue = L10n.text("save_success", name)
            status.toolTip = url.path
        } catch { showError(L10n.text("save_error", error.localizedDescription)) }
    }

    private func showError(_ text: String) {
        status.stringValue = L10n.text("error_status")
        let alert = NSAlert()
        alert.messageText = L10n.text("error_title")
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}

import AppKit
import AwakeCore
import AwakeSystem
import SwiftUI

struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var contentHeight = SwiftUI.State<CGFloat>(wrappedValue: 320)

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                panelContent.fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        ceil($0.size.height)
                    } action: {
                        if contentHeight.wrappedValue != $0 { contentHeight.wrappedValue = $0 }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight.wrappedValue, maximumBodyHeight))
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Text(
                        "\(AwakeIdentity.version) · © 2026 "
                    )
                    Link(
                        "Arthur Barreau",
                        destination: URL(string: "https://www.linkedin.com/in/arthurbarreau/")!
                    )
                    .foregroundStyle(Color(nsColor: .linkColor))
                    .accessibilityLabel("Arthur Barreau on LinkedIn").help(
                        "Arthur Barreau on LinkedIn")
                    Text(" · MIT")
                }.font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Link(destination: URL(string: "https://github.com/oviron/Awake")!) {
                    Image(nsImage: BrandArt.github).frame(width: 20, height: 20)
                }
                .accessibilityLabel("Awake on GitHub").help("Awake on GitHub")
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 340)
        .background {
            if reduceTransparency || contrast == .increased {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .transaction { $0.animation = nil }
    }

    private var maximumBodyHeight: CGFloat {
        max(200, (NSScreen.main?.visibleFrame.height ?? 740) - 100)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: BrandArt.appIcon(size: 64)).resizable()
                    .frame(width: 32, height: 32).accessibilityHidden(true)
                Text("Awake").font(.system(size: 21, weight: .semibold))
                Spacer()
            }
            statusOverview
            if model.removalInProgress {
                Text("Uninstall pending. Right-click the icon to retry.").font(.callout)
            }
            Divider()
            if model.showsPowerControls {
                sessionControls
            } else {
                setupControls
            }
            Divider()
            SettingsView(model: model)
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(20)
    }

    private var statusOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    model.presentation?.title ?? "Setup required",
                    systemImage: model.presentation?.symbol ?? "moon.zzz"
                )
                .font(.callout.weight(.semibold))
                Spacer()
                if case .available(let percent, _) = model.status?.power.battery {
                    Label(
                        "\(percent)%",
                        systemImage: model.status?.power.source.symbol ?? "battery.75percent"
                    )
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let error = model.connectionError ?? model.status?.sleep.fault?.guidance {
                Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if model.connectionError != nil {
                Button("Reconnect") { Task { await model.refresh() } }.disabled(model.busy)
            }
            if let notice = model.thermalNotice {
                Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.status?.sleep.fault != nil || model.presentation == .attention {
                if model.status?.sleep.ownsGlobalHold == true {
                    Button("Retry restoration") { Task { await model.retryRestoration() } }
                        .disabled(!model.canControl || model.busy)
                } else {
                    Button("Rearm Awake") { Task { await model.rearm() } }
                        .disabled(!model.canControl || model.busy)
                }
            }
            if let session = model.ownSession {
                HStack {
                    Text("Current session")
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if let remaining = model.remainingSeconds(session) {
                            Text(
                                Duration.seconds(remaining).formatted(
                                    .units(
                                        allowed: [.hours, .minutes, .seconds], width: .abbreviated))
                            ).monospacedDigit()
                        } else {
                            Text("No limit")
                        }
                    }
                }.font(.callout).foregroundStyle(.secondary)
            } else {
                StopEditor(model: model)
                startButton.disabled(
                    (!model.canControl && !model.isPreview) || model.busy
                        || model.status?.sleep.fault != nil
                        || model.status?.power.thermal.allowsAwake == false)
            }
            if (model.status?.sessions.count ?? 0) > 0 {
                Button {
                    Task { await model.stopAll() }
                } label: {
                    Label(model.busy ? "Updating…" : "Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .help("End all Awake sessions; running commands continue.")
                .controlSize(.large).buttonStyle(.bordered)
                .disabled((!model.canControl && !model.isPreview) || model.busy)
            }
            if model.showsTaskCount {
                Label(
                    "\(model.taskCount) tracked \(model.taskCount == 1 ? "task" : "tasks")",
                    systemImage: "terminal"
                ).font(.caption)
            }
            if let processes = model.watchedProcesses, !processes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(processes, id: \.pid) { process in
                            Text("Waiting for PID \(String(process.pid))")
                                .font(.caption).monospacedDigit()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: CGFloat(min(processes.count, 4)) * 18)
                .scrollBounceBehavior(.basedOnSize)
            }
            if let notice = model.batteryNotice {
                Label {
                    Text(notice).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var startButton: some View {
        let button = Button {
            Task { await model.startManual() }
        } label: {
            Label(model.busy ? "Verifying…" : "Keep awake", systemImage: "power")
                .frame(maxWidth: .infinity)
        }.controlSize(.large)
        if model.status?.power.thermal.allowsAwake == false {
            button.buttonStyle(.bordered)
        } else if reduceTransparency || contrast == .increased {
            button.buttonStyle(.borderedProminent)
        } else if #available(macOS 26, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private var setupControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.buildTrust == .checking {
                ProgressView("Preparing…").controlSize(.small)
            } else if model.removalComplete {
                Text("Ready to remove").font(.callout)
            } else if !model.trustedBuild {
                Text("Development build — power controls unavailable.").font(.callout)
            } else if model.helperStatus == .requiresApproval {
                Button("Approve in System Settings") { model.openLoginSettings() }
                    .disabled(model.isPreview)
            } else if model.helperStatus == .enabled {
                if model.connectionError == nil && !model.removalInProgress {
                    ProgressView("Connecting…").controlSize(.small)
                }
            } else {
                Button("Enable Awake") { Task { await model.registerHelper() } }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.isPreview)
                Text("Requires macOS administrator approval.").font(.caption).foregroundStyle(
                    .secondary)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private struct StopEditor: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Stop", selection: $model.stopChoice) {
                ForEach(SessionEnd.presetMinutes, id: \.self) { minutes in
                    Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h")
                        .tag(StopChoice.preset(minutes))
                }
                Text("No limit").tag(StopChoice.unlimited)
                Divider()
                Text("Custom duration…").tag(StopChoice.custom)
                Text("Date & time…").tag(StopChoice.date)
                Text("When a process ends…").tag(StopChoice.process)
            }.pickerStyle(.menu)
            switch model.stopChoice {
            case .custom:
                HStack {
                    TextField("Duration", value: $model.customDuration, format: .number)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Duration")
                    Picker("Unit", selection: $model.durationUnit) {
                        ForEach(DurationUnit.allCases) { unit in Text(unit.rawValue).tag(unit) }
                    }.labelsHidden().fixedSize()
                }
            case .date:
                DatePicker(
                    "End", selection: $model.stopDate, displayedComponents: [.date, .hourAndMinute])
            case .process:
                processPicker.onAppear { model.refreshProcesses() }
            case .unlimited, .preset: EmptyView()
            }
        }
    }

    private var processPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search processes", text: $model.processSearch)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search processes")
                Button {
                    model.refreshProcesses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.accessibilityLabel("Refresh processes").help("Refresh processes")
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(
                        model.processes.filter {
                            model.processSearch.isEmpty
                                || $0.name.localizedStandardContains(model.processSearch)
                                || String($0.id).contains(model.processSearch)
                        }
                    ) { process in
                        Button {
                            model.selectProcess(process)
                        } label: {
                            HStack {
                                Text(process.name).lineLimit(1)
                                Spacer()
                                Text(String(process.id)).monospacedDigit().foregroundStyle(
                                    .secondary)
                                Image(
                                    systemName: model.isSelected(process)
                                        ? "checkmark.circle.fill" : "circle")
                            }.padding(5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(process.name), PID \(process.id)")
                        .accessibilityAddTraits(
                            model.isSelected(process) ? [.isSelected] : [])
                    }
                }
            }
            .frame(height: 120)
            .overlay {
                if model.processes.isEmpty {
                    Text(model.processListError ?? "No processes available")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("PIDs").font(.callout)
                TextField("697;660;9931", text: $model.processID)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(
                        "Process IDs, separated by semicolons")
            }
        }
    }
}

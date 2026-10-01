import AwakeCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    private var batteryInput = SwiftUI.State<String>(wrappedValue: "")
    @FocusState private var batteryFocused: Bool

    private static let batteryFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.showsPowerControls {
                Group {
                    if model.showsPowerSource {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Power source")
                            Picker("", selection: $model.draft.mode) {
                                ForEach(PowerMode.allCases, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Power source")
                        }
                    }
                    if model.showsBatteryLimit {
                        HStack {
                            Text("Battery reserved limit")
                            Spacer()
                            HStack(spacing: 2) {
                                TextField("Percent", text: batteryInput.projectedValue)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 44)
                                    .accessibilityLabel("Battery reserved limit, percent")
                                    .focused($batteryFocused)
                                    .onSubmit { applyBatteryInput() }
                                    .onChange(of: batteryInput.wrappedValue) { previous, input in
                                        guard !input.isEmpty else { return }
                                        batteryInput.wrappedValue =
                                            Self.batteryFloor(from: input)
                                            .flatMap {
                                                Self.batteryFormatter.string(
                                                    from: NSNumber(value: $0))
                                            }
                                            ?? previous
                                    }
                                    .onChange(of: batteryFocused) {
                                        if !batteryFocused { applyBatteryInput() }
                                    }
                                    .onChange(of: model.draft.batteryFloor, initial: true) {
                                        batteryInput.wrappedValue =
                                            Self.batteryFormatter.string(
                                                from: NSNumber(value: model.draft.batteryFloor))
                                            ?? ""
                                    }
                                    .onDisappear { applyBatteryInput() }
                                Stepper(
                                    "Battery reserved limit", value: $model.draft.batteryFloor,
                                    in: UserPolicy.batteryFloorRange, step: 1
                                )
                                .labelsHidden().fixedSize()
                                .accessibilityValue("\(model.draft.batteryFloor)%")
                            }
                            Text("%")
                        }
                        .monospacedDigit()
                        if model.draft.batteryFloor == 0 {
                            Label(
                                "Battery protection is off", systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                        }
                    }
                    if model.stopChoice == .process {
                        Toggle("Session time limit", isOn: $model.draft.limitsDuration)
                        if model.draft.limitsDuration {
                            HStack {
                                Text("Maximum minutes")
                                TextField(
                                    "Minutes", value: $model.draft.maximumMinutes, format: .number
                                )
                                .textFieldStyle(.roundedBorder).accessibilityLabel(
                                    "Maximum minutes"
                                )
                                .frame(width: 90)
                            }
                        }
                    }
                }.disabled(!model.canControl && !model.isPreview)
                if model.showsPowerSource || model.stopChoice == .process { Divider() }
                HStack {
                    Toggle(
                        "Allow CLI & AI tasks",
                        isOn: Binding(
                            get: { model.status?.policy.allowsAutomation ?? false },
                            set: { enabled in Task { await model.setAutomation(enabled) } })
                    )
                    .disabled((!model.canControl && !model.isPreview) || model.busy)
                    Link(
                        destination: URL(
                            string:
                                "https://github.com/oviron/Awake/blob/main/docs/cli.md#ai-agent-setup"
                        )!
                    ) {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Set up CLI and AI integration")
                    .help("Set up CLI and AI integration")
                }
            }
            if model.showsSudoTouchID {
                Toggle(
                    "Touch ID for sudo",
                    isOn: Binding(
                        get: {
                            model.status?.sudoTouchID == .enabled
                                || model.status?.sudoTouchID == .external
                        },
                        set: { enabled in
                            if enabled || model.status?.sudoTouchID == .external {
                                model.pendingSudoTouchID = enabled
                            } else {
                                Task { await model.setSudoTouchID(false) }
                            }
                        })
                )
                .disabled(
                    (!model.canControl && !model.isPreview) || model.busy || model.sudoTouchIDBusy
                        || model.status?.sudoTouchID == .unavailable
                )
                .help("Use Touch ID for sudo commands on this Mac.")
                .alert(
                    model.pendingSudoTouchID == false
                        ? "Disable Touch ID for sudo?" : "Enable Touch ID for sudo?",
                    isPresented: Binding(
                        get: { model.pendingSudoTouchID != nil },
                        set: { if !$0 { model.pendingSudoTouchID = nil } }),
                    presenting: model.pendingSudoTouchID
                ) { enabled in
                    Button(enabled ? "Enable" : "Disable", role: enabled ? nil : .destructive) {
                        Task { await model.setSudoTouchID(enabled) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { enabled in
                    Text(
                        enabled
                            ? "Applies to sudo commands across this Mac. Your password remains available."
                            : "This setting was enabled outside Awake. Sudo commands across this Mac will require your password instead."
                    )
                }
            }
            if let message = model.sudoTouchIDMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(message).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                    if model.sudoTouchIDNeedsPermission {
                        Button("Open Full Disk Access") { model.openPrivacySettings() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.72, green: 0.32, blue: 0))
                            .disabled(model.busy)
                    }
                }
            }
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { model.loginStatus == .enabled },
                    set: { enabled in Task { await model.setLaunchAtLogin(enabled) } })
            )
            .disabled(
                (!model.trustedBuild && !model.isPreview) || model.busy || model.removalComplete)
            if model.loginStatus == .requiresApproval {
                Button("Approve in System Settings") { model.openLoginSettings() }.disabled(
                    model.isPreview)
            }
            if model.showsPowerControls {
                HStack {
                    Toggle("Automatic updates", isOn: $model.automaticUpdates)
                        .disabled((!model.trustedBuild && !model.isPreview) || model.updating)
                    if let update = model.availableUpdate, model.showsUpdateButton {
                        Button("Update") { model.requestUpdate() }
                            .help("Install Awake \(update.version)")
                            .disabled(!model.canInstallAvailableUpdate())
                    }
                }
                if let message = model.updateMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout).toggleStyle(.switch).controlSize(.small)
        .onChange(of: model.draft) { model.policyEdited() }
    }

    private func applyBatteryInput() {
        if let value = Self.batteryFloor(from: batteryInput.wrappedValue) {
            model.draft.batteryFloor = value
        }
        batteryInput.wrappedValue =
            Self.batteryFormatter.string(
                from: NSNumber(value: model.draft.batteryFloor)) ?? ""
    }

    static func batteryFloor(from text: String) -> Int? {
        guard !text.isEmpty,
            text.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) })
        else { return nil }
        var value = 0
        for digit in text {
            guard let number = digit.wholeNumberValue else { return nil }
            value = min(UserPolicy.batteryFloorRange.upperBound, value * 10 + number)
        }
        return value
    }
}

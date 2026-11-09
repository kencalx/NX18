// One launcher setting as a row (a menu, a slider with its percentage, a toggle), shared by the iOS launcher (Launcher.swift) and the Mac app's settings window (dm/mac/Launcher.swift).
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled, and so is a row a rule makes inactive (LauncherModel.reason), with the reason as
// its note; an option a rule makes inactive is shown but cannot be picked, with the reason beside it.
import SwiftUI

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.pick(s, $0) }) }   // a greyed option is refused (pick)
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fixed.contains(s.env) }
    private var inactive: Bool { m.inactiveWhy(s) != nil }
    private var current: String { m.values[s.env] ?? s.def }
    // The setting's note, the reason a rule gives (in its place when the row does nothing: what the setting costs no longer matters then), and the lock. Each line is decided
    // as the values change, as is the row's disabled state
    private var note: String {
        var parts: [String] = []
        let reason = m.reason(s)
        if let r = reason, r.inactive { parts.append(r.why) } else {
            if !s.note.isEmpty { parts.append(s.note) }
            if let r = reason, !r.why.isEmpty { parts.append(r.why) }
        }
        if locked { parts.append(m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file") }
        return parts.joined(separator: " · ")
    }
    // An option's label in the menu: with its reason beside it while a rule greys it or gives it a hint. The chosen option keeps its plain label, as the menu's button shows it,
    // and its reason is the row's note
    private func optionLabel(_ o: [String]) -> String {
        guard o[0] != current, let why = m.optionInactive(s, o[0]) ?? m.optionHint(s, o[0]), !why.isEmpty else { return o[1] }
        return "\(o[1]) (\(why))"
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.label)
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.[0]) { o in
                        Text(optionLabel(o)).tag(o[0]).selectionDisabled(m.optionInactive(s, o[0]) != nil)
                    }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(s.label)
                        .accessibilityValue(percentage)
                }
            default:
                Toggle(isOn: Binding(get: { current == s.onValue }, set: { m.pick(s, $0 ? s.onValue : s.offValue) })) {
                    settingLabel
                }
                .disabled(m.optionInactive(s, current == s.onValue ? s.offValue : s.onValue) != nil)   // the value it would switch to is greyed
            }
        }
        .disabled(locked || inactive)
    }
}

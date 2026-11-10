import CaliDomain
import SwiftUI

/// Text typed into the running fields, parsed without floating point (ADR-055: km, `vi` decimal comma).
struct RunEntry: Equatable {
    var km = ""
    var hours = ""
    var minutes = ""
    var seconds = ""

    init(km: String = "", hours: String = "", minutes: String = "", seconds: String = "") {
        (self.km, self.hours, self.minutes, self.seconds) = (km, hours, minutes, seconds)
    }

    init(distanceMeters: Int?, durationSeconds: Int? = nil) {
        if let distanceMeters { km = Self.kmText(distanceMeters) }
        if let durationSeconds {
            hours = durationSeconds >= 3600 ? "\(durationSeconds / 3600)" : ""
            minutes = "\(durationSeconds % 3600 / 60)"
            seconds = "\(durationSeconds % 60)"
        }
    }

    /// "8,25" / "8.25" → 8250 m (rounded to the metre). `nil` when empty or not a number; negative stays
    /// negative so the domain rejects it with a message instead of the UI hiding it.
    var distanceMeters: Int? {
        let text = km.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var meters = value * 1000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &meters, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// h:mm:ss → seconds. `nil` when all three are empty or a part is not a whole number, or minutes /
    /// seconds are over 59. Over 24 h is returned as is and rejected by the domain (CON-004).
    var durationSeconds: Int? {
        let parts = [hours, minutes, seconds].map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.contains(where: { !$0.isEmpty }) else { return nil }
        let values = parts.map { $0.isEmpty ? 0 : Int($0) }
        guard let h = values[0], let m = values[1], let s = values[2], h >= 0, (0...59).contains(m), (0...59).contains(s) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// Something was typed that is not a valid time (letters, 75 minutes, ...).
    var hasInvalidTime: Bool {
        [hours, minutes, seconds].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } && durationSeconds == nil
    }

    /// Live pace line (mockup `runFields`): "4:50/km", or why there is none yet.
    var hasPace: Bool {
        guard let meters = distanceMeters, let time = durationSeconds else { return false }
        if case .success = Pace.derive(distanceMeters: meters, durationSeconds: time) { return true }
        return false
    }

    var paceText: String {
        guard let meters = distanceMeters, let time = durationSeconds else { return "Nhập quãng đường và thời gian" }
        switch Pace.derive(distanceMeters: meters, durationSeconds: time) {
        case .success(let pace): return pace.formatted
        case .failure(let issue):
            return issue.field == "durationSeconds" && time > 0 ? "Thời gian tối đa 24 giờ" : (meters > 0 ? "Nhập thời gian" : "Nhập quãng đường")
        }
    }

    static func kmText(_ meters: Int) -> String {
        Fmt.km(meters).replacingOccurrences(of: " km", with: "").replacingOccurrences(of: ".", with: "")
    }
}

/// Distance (km) + time (giờ / phút / giây) + derived pace, shared by P6 and the race result (MP-07).
struct RunEntryFields: View {
    @Binding var entry: RunEntry
    var lockDistance = false
    var distanceOptional = false
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(lockDistance ? "Quãng đường (km) · theo cự ly giải" : distanceOptional ? "Quãng đường (km, không bắt buộc)" : "Quãng đường (km)")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
                TextField("0", text: $entry.km)
                    .keyboardType(.decimalPad)
                    .focused(focused)
                    .disabled(lockDistance)
                    .font(.title2.bold().monospacedDigit())
                    .padding(Spacing.m)
                    .frame(minHeight: minTapTarget)
                    .background(Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip))
                    .foregroundStyle(lockDistance ? Color.caliSecondary : Color.caliText)
                    .overlay(alignment: .trailing) {
                        if lockDistance {
                            Image(systemName: "lock.fill").foregroundStyle(Color.caliSecondary).padding(.trailing, Spacing.m)
                        }
                    }
                    .accessibilityLabel("Quãng đường, ki lô mét")
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Thời gian").font(.caption).foregroundStyle(Color.caliSecondary)
                HStack(spacing: Spacing.s) {
                    part($entry.hours, "giờ")
                    part($entry.minutes, "phút")
                    part($entry.seconds, "giây")
                }
                if entry.hasInvalidTime {
                    Text("Phút và giây từ 0 đến 59.").font(.caption).foregroundStyle(Color.caliError)
                }
            }
            CardDivider()
            HStack {
                Text("Pace (tự tính)").font(.subheadline).foregroundStyle(Color.caliSecondary)
                Spacer()
                Text(entry.paceText)
                    .font(entry.hasPace ? .headline.monospacedDigit() : .footnote)
                    .foregroundStyle(entry.hasPace ? Color.caliText : Color.caliSecondary)
                    .multilineTextAlignment(.trailing)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .accessibilityElement(children: .combine)
        }
        .caliCard()
    }

    private func part(_ text: Binding<String>, _ label: String) -> some View {
        VStack(spacing: 2) {
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .focused(focused)
                .multilineTextAlignment(.center)
                .font(.title2.bold().monospacedDigit())
                .padding(.vertical, Spacing.s)
                .frame(minHeight: minTapTarget)
                .background(Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip))
                .foregroundStyle(Color.caliText)
                .accessibilityLabel(label)
            Text(label).font(.caption).foregroundStyle(Color.caliSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

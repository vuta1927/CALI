import CaliDomain
import Charts
import SwiftUI

/// docs/18 §6.6 (mockup `progress`): per exercise baseline → current with delta and %, the weekly trend,
/// and adherence by week from week 1. Everything is computed from saved sets of this plan.
struct PlanProgressView: View {
    @Environment(AppStore.self) private var store
    let lineageId: UUID

    var body: some View {
        if let plan = store.plan(lineageId) {
            let rows = store.exerciseProgress(of: plan)
            let adherence = store.weeklyAdherence(of: plan)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    AdherenceCard(weeks: adherence)
                    SectionHeader(title: "Thành tích theo bài")
                    if rows.isEmpty {
                        Text("Chưa có set hoàn thành nào trong giáo án này. Tập một buổi để thấy tiến bộ.")
                            .font(.footnote)
                            .foregroundStyle(Color.caliSecondary)
                            .caliCard()
                    }
                    ForEach(rows) { ExerciseProgressCard(row: $0) }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .caliScreen()
            .navigationTitle("Tiến bộ")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct AdherenceCard: View {
    let weeks: [WeekAdherence]

    var body: some View {
        let done = weeks.reduce(0) { $0 + $1.done }
        let planned = weeks.reduce(0) { $0 + $1.planned }
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bám lịch").font(.headline).foregroundStyle(Color.caliText)
                Spacer()
                Text(planned == 0 ? "Chưa có buổi nào tới hạn" : "\(done)/\(planned) buổi")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Color.caliSecondary)
            }
            if !weeks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: Spacing.s) {
                        ForEach(weeks) { week in
                            VStack(spacing: Spacing.xs) {
                                ZStack(alignment: .bottom) {
                                    Capsule().fill(Color.caliSurfaceRaised).frame(width: 18, height: 56)
                                    Capsule().fill(Color.caliAccent)
                                        .frame(width: 18, height: week.planned == 0 ? 0 : 56 * CGFloat(week.done) / CGFloat(week.planned))
                                }
                                Text("\(week.done)/\(week.planned)").font(.caption2.monospacedDigit()).foregroundStyle(Color.caliText)
                                Text("T\(week.week)").font(.caption2).foregroundStyle(Color.caliSecondary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Tuần \(week.week): \(week.done) trên \(week.planned) buổi")
                        }
                    }
                }
            }
            if planned > done {
                Text("Bỏ lỡ \(planned - done) buổi. Hôm nay chưa được tính.")
                    .font(.caption).foregroundStyle(Color.caliSecondary)
            }
        }
        .caliCard()
    }
}

struct ExerciseProgressCard: View {
    let row: ExerciseProgress

    var body: some View {
        let unit = row.indicator.unit
        let summary = row.summary
        let points = summary.points.compactMap { p in p.value.map { (week: p.week, value: NSDecimalNumber(decimal: $0).doubleValue) } }
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                PosterThumb(exercise: row.exercise, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.exercise.name).font(.headline).foregroundStyle(Color.caliText)
                    Text(row.indicator.label).font(.caption).foregroundStyle(Color.caliSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(GoalFmt.value(summary.current, unit: unit)).font(.title3.bold().monospacedDigit()).foregroundStyle(Color.caliText)
                    if let week = summary.currentWeek { Text("tuần \(week)").font(.caption).foregroundStyle(Color.caliSecondary) }
                }
            }
            if let reference = summary.reference {
                FromToView(fromCaption: "Tuần \(summary.referenceWeek ?? 1)", from: GoalFmt.value(reference, unit: unit),
                           toCaption: "Hiện tại", to: GoalFmt.value(summary.current, unit: unit))
            }
            Text(GoalFmt.delta(summary, unit: unit))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(summary.delta.map { $0 > 0 } == true ? Color.caliAccentInk : Color.caliSecondary)
            if points.count >= 2 {
                Chart(points, id: \.week) { point in
                    LineMark(x: .value("Tuần", point.week), y: .value(unit, point.value))
                    PointMark(x: .value("Tuần", point.week), y: .value(unit, point.value))
                }
                .foregroundStyle(Color.caliAccentInk)
                .chartXAxis {
                    AxisMarks(values: points.map(\.week)) { value in
                        AxisValueLabel { Text("T\(value.as(Int.self) ?? 0)") }
                    }
                }
                .frame(height: 120)
                .accessibilityLabel("Xu hướng theo tuần")
            }
        }
        .caliCard()
    }
}

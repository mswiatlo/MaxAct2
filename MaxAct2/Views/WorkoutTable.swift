import MaxActCore
import SwiftUI

/// The workout list.
///
/// A `Table` rather than a `List`: this is tabular data people want to sort by column and compare
/// across, and multi-selection with ⌘A, shift-click and range-drag comes free and behaves the way
/// Mac users expect.
struct WorkoutTable: View {
    @Bindable var model: AppModel

    /// Versioned, because `TableColumnCustomization` persists a **`currentWidth` per column** as
    /// well as order and visibility. A saved arrangement silently overrides the widths declared
    /// below, so retuning them changes nothing for anyone who has already used the app until the
    /// key is bumped.
    ///
    /// Two things measured while tuning these, both worth knowing before touching them again:
    ///
    /// - **`ideal:` does not control the rendered width when there is room to spare.** The table
    ///   distributes all available width across the flexible columns. Narrowing every `ideal:`
    ///   and relaunching produced a persisted total of 1,094pt both before and after — identical
    ///   to the point, merely reapportioned between columns. `max:` is what actually stops a
    ///   column growing, which is why every column below has one.
    /// - The widths the table persists are its own computed ones, not the declared ideals, so
    ///   reading this key back after a launch is the only reliable way to see what it really did.
    @AppStorage("workoutTableColumns.v5") private var columnCustomizationData = Data()
    @State private var columnCustomization = TableColumnCustomization<WorkoutListItem>()

    var body: some View {
        Table(
            model.visibleItems,
            selection: $model.selection,
            sortOrder: $model.sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Route") { item in
                RouteThumbnailView(
                    renderer: model.thumbnails,
                    workoutID: item.id,
                    hasRoute: item.workout.hasRoute,
                    hasDetail: item.hasDetail,
                    isIndoor: item.workout.isIndoor,
                    routeColor: model.settings.routeColor
                )
            }
            .width(104)
            .customizationID("route")
            .disabledCustomizationBehavior(.resize)

            TableColumn("Date", value: \.workout.start) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.workout.start, format: .dateTime.year().month(.abbreviated).day())
                    Text(item.workout.start, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 96, ideal: 100, max: 110)
            .customizationID("date")

            // Third, beside the date: where a workout happened is part of identifying it, and it
            // reads better next to when than stranded past the numbers. A saved column
            // arrangement wins over this, since `customizationID` is what restoration keys on.
            TableColumn("Place") { item in
                PlaceCell(item: item)
            }
            .width(min: 110, ideal: 124, max: 160)
            .customizationID("place")

            TableColumn("Activity", value: \.workout.kind.displayName) { item in
                Label(item.workout.kind.displayName, systemImage: item.workout.kind.symbolName)
            }
            .width(min: 128, ideal: 134, max: 156)
            .customizationID("activity")

            TableColumn("Duration", value: \.workout.duration) { item in
                Text(WorkoutFormatting.duration(item.workout.duration))
                    .monospacedDigit()
            }
            .width(min: 68, ideal: 72, max: 78)
            .customizationID("duration")

            TableColumn("Distance", value: \.sortDistance) { item in
                Text(WorkoutFormatting.distance(item.workout.distanceMeters))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 76, max: 82)
            .customizationID("distance")

            TableColumn("Pace", value: \.sortPace) { item in
                Text(WorkoutFormatting.paceOrSpeed(
                    metersPerSecond: item.workout.effectiveSpeedMetersPerSecond,
                    for: item.workout.kind
                ))
                .monospacedDigit()
            }
            .width(min: 76, ideal: 80, max: 90)
            .customizationID("pace")

            TableColumn("Energy", value: \.sortEnergy) { item in
                Text(WorkoutFormatting.energy(kilocalories: item.workout.activeEnergyKilocalories))
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 68, max: 74)
            .customizationID("energy")

            TableColumn("Avg HR", value: \.sortHeartRate) { item in
                Text(WorkoutFormatting.heartRate(item.workout.averageHeartRate))
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 70, max: 76)
            .customizationID("heartRate")

            TableColumn("Strava") { item in
                // Centred: a lone glyph pinned to the leading edge of its column reads as
                // misaligned rather than as a column of status marks.
                StravaStateBadge(state: item.stravaState, showsLabel: false)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            // Symbol alone, so the column is barely wider than its own header. The floor is the
            // word "Strava", not the content.
            .width(min: 44, ideal: 50, max: 58)
            .customizationID("strava")
        }
        .tableStyle(.inset)
        // SwiftUI's Table is exposed to accessibility as an *outline*, not a table, and the
        // sidebar List is one too — so UI tests need a way to tell them apart that doesn't depend
        // on ordering.
        .accessibilityIdentifier("WorkoutTable")
        .contextMenu(forSelectionType: WorkoutListItem.ID.self) { ids in
            WorkoutActions(model: model, ids: ids)
        } primaryAction: { ids in
            // Double-click opens the detail for a single row.
            if let id = ids.first, ids.count == 1 { model.selection = [id] }
        }
        .onAppear {
            if let restored = try? JSONDecoder().decode(
                TableColumnCustomization<WorkoutListItem>.self, from: columnCustomizationData
            ) {
                columnCustomization = restored
            }
        }
        .onChange(of: columnCustomization) { _, new in
            columnCustomizationData = (try? JSONEncoder().encode(new)) ?? Data()
        }
    }
}

/// Strava state as **symbol plus text**, never colour alone — colour is unreliable for a
/// meaningful share of users and is lost entirely in a screenshot in bright sun.
struct StravaStateBadge: View {
    let state: StravaState

    /// The table column omits the text: the six states have six *distinct symbol shapes*
    /// (`circle.dashed`, `clock`, `arrow.up.circle`, `checkmark.circle.fill`,
    /// `equal.circle.fill`, `exclamationmark.triangle.fill`), so shape — not colour — is what
    /// distinguishes them, and the wording is still carried by `help` and the accessibility
    /// label. The detail pane, which has room, keeps the text.
    var showsLabel = true

    var body: some View {
        Label {
            if showsLabel { Text(shortLabel) }
        } icon: {
            Image(systemName: state.symbolName)
                .foregroundStyle(tint)
        }
        .help(state.label)
        .accessibilityLabel(state.label)
    }

    private var shortLabel: String {
        switch state {
        case .notUploaded: "—"
        case .queued: "Queued"
        case .uploading: "Uploading"
        case .uploaded: "Uploaded"
        case .duplicate: "Duplicate"
        case .failed: "Failed"
        }
    }

    private var tint: Color {
        switch state {
        case .uploaded, .duplicate: .green
        case .failed: .orange
        case .queued, .uploading: .accentColor
        case .notUploaded: .secondary
        }
    }
}

/// The Place column.
///
/// Three genuinely different states, and conflating any two of them misleads:
///
/// - a resolved name;
/// - **indoor**, which will never have a place, so an em dash that looks like "still loading" is
///   wrong — this is the same distinction the thumbnail placeholder gets right;
/// - no place *yet*, either because detail hasn't been downloaded or geocoding hasn't reached it.
///
/// Symbol **and** text, never a symbol alone, and an explicit label for the indoor case so it
/// isn't announced as an unnamed image.
private struct PlaceCell: View {
    let item: WorkoutListItem

    var body: some View {
        if let place = item.placeLabel {
            Text(place)
        } else if item.workout.isIndoor == true {
            Label("Indoor", systemImage: "house")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help("An indoor workout has no route, so it has no place")
        } else {
            Text(WorkoutFormatting.missing)
                .foregroundStyle(.secondary)
                .accessibilityLabel("No place yet")
        }
    }
}

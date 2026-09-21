import MaxActCore
import SwiftUI

/// The workout list.
///
/// A `Table` rather than a `List`: this is tabular data people want to sort by column and compare
/// across, and multi-selection with ⌘A, shift-click and range-drag comes free and behaves the way
/// Mac users expect.
struct WorkoutTable: View {
    @Bindable var model: AppModel

    @AppStorage("workoutTableColumns") private var columnCustomizationData = Data()
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
            .width(min: 100, ideal: 120)
            .customizationID("date")

            // Third, beside the date: where a workout happened is part of identifying it, and it
            // reads better next to when than stranded past the numbers. A saved column
            // arrangement wins over this, since `customizationID` is what restoration keys on.
            TableColumn("Place") { item in
                PlaceCell(item: item)
            }
            .width(min: 100, ideal: 140)
            .customizationID("place")

            TableColumn("Activity", value: \.workout.kind.displayName) { item in
                Label(item.workout.kind.displayName, systemImage: item.workout.kind.symbolName)
            }
            .width(min: 120, ideal: 160)
            .customizationID("activity")

            TableColumn("Duration", value: \.workout.duration) { item in
                Text(WorkoutFormatting.duration(item.workout.duration))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            .customizationID("duration")

            TableColumn("Distance", value: \.sortDistance) { item in
                Text(WorkoutFormatting.distance(item.workout.distanceMeters))
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 90)
            .customizationID("distance")

            TableColumn("Pace", value: \.sortPace) { item in
                Text(WorkoutFormatting.paceOrSpeed(
                    metersPerSecond: item.workout.effectiveSpeedMetersPerSecond,
                    for: item.workout.kind
                ))
                .monospacedDigit()
            }
            .width(min: 80, ideal: 90)
            .customizationID("pace")

            TableColumn("Energy", value: \.sortEnergy) { item in
                Text(WorkoutFormatting.energy(kilocalories: item.workout.activeEnergyKilocalories))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            .customizationID("energy")

            TableColumn("Avg HR", value: \.sortHeartRate) { item in
                Text(WorkoutFormatting.heartRate(item.workout.averageHeartRate))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            .customizationID("heartRate")

            TableColumn("Strava") { item in
                StravaStateBadge(state: item.stravaState)
            }
            .width(min: 90, ideal: 110)
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

    var body: some View {
        Label {
            Text(shortLabel)
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

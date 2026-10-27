import MaxActCore
import SwiftUI

/// The actions available on a selection.
///
/// One definition, used from the toolbar, the context menu and the menu bar. Mac convention is
/// that every action is reachable all three ways, and defining them once is the only way that
/// stays true as actions are added.
struct WorkoutActions: View {
    let model: AppModel
    let ids: Set<String>

    private var settings: AppSettings { model.settings }

    private var items: [WorkoutListItem] {
        model.items.filter { ids.contains($0.id) }
    }

    var body: some View {
        let needingDetail = items.filter { !$0.hasDetail }

        Button {
            model.startDetailFetch(for: needingDetail)
        } label: {
            Label(
                needingDetail.count > 1
                    ? "Download Detail for \(needingDetail.count) Workouts"
                    : "Download Detail",
                systemImage: "arrow.down.circle"
            )
        }
        .disabled(needingDetail.isEmpty || model.syncStatus.isRunning || !settings.isConfigured)
        .help(settings.isConfigured
              ? "Fetch routes and heart rate from your iPhone"
              : "Set your iPhone's address in Settings first")

        TagsMenu(model: model, ids: ids)

        let counts = model.stravaUploadCount(items)
        Button {
            model.startStravaUpload(for: items)
        } label: {
            Label(
                counts.ready > 1 ? "Upload \(counts.ready) Workouts to Strava" : "Upload to Strava",
                systemImage: "arrow.up.circle"
            )
        }
        .disabled(counts.ready == 0 || model.syncStatus.isRunning || !model.isStravaConnected)
        .help(uploadHelp(counts))
    }

    /// Says *why* the button is disabled, since there are four different reasons and a greyed-out
    /// button with no explanation is a dead end.
    private func uploadHelp(_ counts: (ready: Int, needingDetail: Int)) -> String {
        if !model.isStravaConnected { return "Connect to Strava in Settings first" }
        if counts.ready == 0 && counts.needingDetail > 0 {
            return "Download detail first — without a route and heart rate there's nothing worth uploading"
        }
        if counts.ready == 0 { return "Everything selected is already on Strava" }
        if counts.needingDetail > 0 {
            return "Uploads \(counts.ready); \(counts.needingDetail) still need their detail downloaded"
        }
        return "Upload to Strava, one at a time within its rate limit"
    }
}

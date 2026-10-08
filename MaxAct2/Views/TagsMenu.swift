import MaxActCore
import SwiftUI

/// Tags for a selection — the batch editor that makes tagging worth having. Tagging 400 commutes
/// one at a time is not a thing anyone will do.
///
/// Each tag shows whether **all, some or none** of the selection carries it. Choosing it adds it to
/// all of them, unless all already have it, in which case it's removed from all — the same rule
/// Finder uses for tags on a mixed selection.
struct TagsMenu: View {
    let model: AppModel
    let ids: Set<String>

    var body: some View {
        Menu {
            ForEach(model.allTags, id: \.self) { name in
                let state = coverage(of: name)
                Button {
                    if state == .all { model.removeTag(name, from: ids) } else { model.addTag(name, to: ids) }
                } label: {
                    Label(name, systemImage: state.symbol)
                }
                .help(WorkoutTag.isStravaBacked(name)
                      ? "Also set on Strava for workouts already there"
                      : "Stays on this Mac — Strava has no field for it")
            }
            Divider()
            Button("New Tag…") { model.newTagTargets = ids }
        } label: {
            Label("Tags", systemImage: "tag")
        }
        .disabled(ids.isEmpty)
    }

    private enum Coverage {
        case all, some, none
        var symbol: String {
            switch self {
            case .all: "checkmark"
            case .some: "minus"
            case .none: "circle.dotted"
            }
        }
    }

    private func coverage(of name: String) -> Coverage {
        let selected = model.items.filter { ids.contains($0.id) }
        let tagged = selected.filter { $0.tags.contains(name) }.count
        if tagged == 0 { return .none }
        return tagged == selected.count ? .all : .some
    }

    /// One symbol per tag, so the sidebar and the detail pane agree.
    static func symbol(for name: String) -> String {
        switch name {
        case WorkoutTag.commute: "briefcase"
        case WorkoutTag.trainer: "figure.indoor.cycle"
        default: "tag"
        }
    }
}

/// A workout's tags as small capsules, Strava-backed first.
struct TagChips: View {
    let tags: [String]
    /// A Commute/Trainer edit not yet on Strava — shown so it doesn't look as if it silently failed.
    var pendingOnStrava = false

    var body: some View {
        if !tags.isEmpty || pendingOnStrava {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { name in
                    Label(name, systemImage: TagsMenu.symbol(for: name))
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                if pendingOnStrava {
                    Label("Updating Strava…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tags: " + (tags.isEmpty ? "none" : tags.joined(separator: ", ")))
        }
    }
}

import GroupActivities
import SwiftUI
import UIKit

struct CatalogSharePlayButton: View {
    @Environment(SharePlayCoordinator.self) private var coordinator
    let title: TMDBTitle
    let episode: TMDBEpisode?
    let initialPosition: Double
    var body: some View {
        Button("SharePlay", systemImage: "shareplay") { start() }
            .disabled(coordinator.isLaunching || coordinator.catalogInvitationActivity != nil ||
                (title.kind == .tv && episode == nil))
            .accessibilityIdentifier("catalog.detail.shareplay")
    }

    private func start() {
        guard !coordinator.isLaunching, coordinator.catalogInvitationActivity == nil,
              let activity = coordinator.makeCatalogActivity(
                  title: title,
                  episode: episode,
                  initialPosition: initialPosition,
              ),
              coordinator.checkLaunchAvailability(for: activity) else { return }
        if coordinator.isEligibleForGroupSession {
            Task { await coordinator.activate(activity) }
        } else {
            coordinator.catalogInvitationActivity = activity
        }
    }
}

struct CatalogSharePlayPresentation: ViewModifier {
    @Environment(SharePlayCoordinator.self) private var coordinator
    @State private var invitation: Invitation?
    @State private var presentedActivityID: UUID?
    private struct Invitation: Identifiable {
        let activity: StrimrWatchActivity
        let controller: GroupActivitySharingController
        var id: UUID {
            activity.activityID
        }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: coordinator.catalogInvitationActivity) { _, activity in
                guard let activity else { invitation = nil; return }
                guard invitation == nil, coordinator.beginSharingPresentation(activity) else {
                    coordinator.catalogInvitationActivity = nil
                    return
                }
                do {
                    let controller = try GroupActivitySharingController(activity)
                    invitation = Invitation(activity: activity, controller: controller)
                } catch {
                    coordinator.catalogInvitationActivity = nil
                    coordinator.sharingPresentationFailed(activity)
                }
            }
            .sheet(item: $invitation, onDismiss: {
                coordinator.catalogInvitationActivity = nil
                Task { await coordinator.sharingPresentationDidEnd() }
            }) { request in
                SharePlaySharingControllerView(controller: request.controller)
                    .onAppear { coordinator.sharingPresentationDidAppear() }
                    .task {
                        let result = await request.controller.result
                        if result == .cancelled {
                            coordinator.sharingDidCancel(request.activity)
                        } else {
                            coordinator.sharingDidComplete(request.activity)
                        }
                        invitation = nil
                    }
            }
            .sheet(
                item: Binding(
                    get: { coordinator.catalogPlaybackActivity },
                    set: { value in
                        if value == nil {
                            coordinator.catalogPresentationDismissed(expectedID: presentedActivityID)
                        }
                    },
                ),
                onDismiss: {
                    coordinator.catalogPresentationDismissed(expectedID: presentedActivityID)
                },
            ) { activity in
                CatalogSharePlayLaunchView(activity: activity).id(activity.activityID)
                    .onAppear { presentedActivityID = activity.activityID }
            }
            .alert("SharePlay", isPresented: Binding(
                get: { coordinator.catalogErrorMessage != nil },
                set: {
                    if !$0 {
                        coordinator.catalogErrorMessage = nil
                    }
                },
            )) {
                Button("OK") { coordinator.catalogErrorMessage = nil }
            } message: { Text(coordinator.catalogErrorMessage ?? "") }
    }
}

private struct CatalogSharePlayLaunchView: View {
    @Environment(SharePlayCoordinator.self) private var coordinator
    let activity: StrimrWatchActivity
    @State private var title: TMDBTitle?
    @State private var episode: TMDBEpisode?
    @State private var error: String?
    var body: some View {
        Group {
            if let title {
                CatalogSourcesView(title: title, episode: episode, sharePlayActivityID: activity.activityID)
            } else if let error {
                VStack(spacing: 16) {
                    Text(error)
                    Button("Retry") { self.error = nil; Task { await load() } }
                    Button("Leave SharePlay") { coordinator.leave() }
                }.padding()
            } else {
                ProgressView("Preparing your SharePlay source…")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let item = activity.catalog, item.matches(activity) else {
            error = "This invitation does not identify a valid movie or exact episode."; return
        }
        do {
            let reference = TMDBTitle.reference(id: item.tmdbID, kind: item.isTV ? .tv : .movie, title: activity.title)
            let detail = try await TMDBClient.shared.details(reference)
            var selected: TMDBEpisode?
            if item.isTV, let season = item.season {
                selected = try await TMDBClient.shared.episodes(tvID: item.tmdbID, season: season)
                    .first { $0.episode_number == item.episode && $0.season_number == season }
                guard selected != nil else { throw SharePlayError.mediaUnavailable }
            }
            try Task.checkCancellation()
            episode = selected; title = detail
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "The shared title could not be loaded. Check TMDb configuration and availability. Each participant needs their own authorized playback source."
        }
    }
}

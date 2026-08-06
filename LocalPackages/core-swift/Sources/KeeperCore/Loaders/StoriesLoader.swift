import Foundation

actor StoriesLoader {
    private var taskInProgress: Task<Void, Never>?

    private let toswalletAPI: TosWalletAPI
    private let configuration: Configuration
    private let storiesStore: StoriesStore

    init(
        toswalletAPI: TosWalletAPI,
        configuration: Configuration,
        storiesStore: StoriesStore
    ) {
        self.toswalletAPI = toswalletAPI
        self.configuration = configuration
        self.storiesStore = storiesStore

        configuration.addUpdateObserver(self) { observer in
            observer.loadStories()
        }
    }

    nonisolated func loadStories() {
        Task {
            await loadStories()
        }
    }

    private func loadStories() async {
        if let taskInProgress {
            taskInProgress.cancel()
            self.taskInProgress = nil
        }

        let task = Task {
            guard let storyIds = configuration.value(\.stories),
                  let stories = try? await toswalletAPI.loadStories(
                      storyIds: storyIds
                  )
            else {
                return
            }
            guard !Task.isCancelled else { return }
            await storiesStore.setStories(stories)
        }
        self.taskInProgress = task
    }
}

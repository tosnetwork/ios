import Foundation

public final class KeeperInfoStore: Store<KeeperInfoStore.Event, KeeperInfo?> {
    public enum Event {
        case didUpdateKeeperInfo(KeeperInfo?)
    }

    private let keeperInfoRepository: KeeperInfoRepository

    init(keeperInfoRepository: KeeperInfoRepository) {
        self.keeperInfoRepository = keeperInfoRepository
        super.init(state: nil)
    }

    override public func createInitialState() -> KeeperInfo? {
        try? self.keeperInfoRepository.getKeeperInfo()
    }

    /// Publish a creation/import only after durable repository storage succeeds.
    /// Read the repository on the same serial mutation queue so a failed initial
    /// read cannot be mistaken for an empty registry and overwrite existing data.
    public func persistKeeperInfo(
        _ updateBlock: @escaping (KeeperInfo?) throws -> KeeperInfo?,
        completion: @escaping (Result<KeeperInfo?, Swift.Error>) -> Void
    ) {
        var failure: Swift.Error?
        updateState { [keeperInfoRepository] _ in
            do {
                let current = try keeperInfoRepository.getKeeperInfoIfPresent()
                let newState = try updateBlock(current)
                if let newState {
                    try keeperInfoRepository.saveKeeperInfo(newState)
                } else if current != nil {
                    try keeperInfoRepository.removeKeeperInfo()
                }
                return StateUpdate(newState: newState)
            } catch {
                failure = error
                return nil
            }
        } completion: { updatedState in
            if let failure {
                completion(.failure(failure))
            } else {
                self.sendEvent(.didUpdateKeeperInfo(updatedState))
                completion(.success(updatedState))
            }
        }
    }

    public func updateKeeperInfo(
        _ updateBlock: @escaping (KeeperInfo?) -> KeeperInfo?,
        completion: ((KeeperInfo?) -> Void)? = nil
    ) {
        updateState { [keeperInfoRepository] keeperInfo in
            guard let newState = updateBlock(keeperInfo) else {
                try? keeperInfoRepository.removeKeeperInfo()
                return StateUpdate(newState: nil)
            }
            try? keeperInfoRepository.saveKeeperInfo(newState)
            return StateUpdate(newState: newState)
        } completion: { [weak self] updatedState in
            self?.sendEvent(.didUpdateKeeperInfo(updatedState))
            completion?(updatedState)
        }
    }

    public func updateKeeperInfo(_ updateBlock: @escaping (KeeperInfo?) -> KeeperInfo?) async -> KeeperInfo? {
        return await withCheckedContinuation { continuation in
            updateKeeperInfo(updateBlock) { updatedState in
                continuation.resume(returning: updatedState)
            }
        }
    }
}

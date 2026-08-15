import KeeperCore
import TKLocalize
import TKUIKit
import TonSwift
import UIKit

protocol HistoryModuleOutput: AnyObject {
    var didSelectSpamHistory: (() -> Void)? { get set }
}

protocol HistoryModuleInput: AnyObject {
    func setHistoryListState(_ state: HistoryList.State)
}

protocol HistoryViewModel: AnyObject {
    var didUpdateIsConnecting: ((Bool) -> Void)? { get set }

    var didUpdateTabs: (([TKTabsView.Item]) -> Void)? { get set }
    var didUpdateTabViewIsHidden: ((Bool) -> Void)? { get set }
    var didUpdateSelectedTab: ((TKTabsView.Item) -> Void)? { get set }

    func viewDidLoad()
}

final class HistoryV2ViewModelImplementation: HistoryViewModel, HistoryModuleOutput, HistoryModuleInput {
    // MARK: - HistoryModuleOutput

    var didSelectSpamHistory: (() -> Void)?

    // MARK: - HistoryViewModel

    var didChangeWallet: ((Wallet) -> Void)?
    var didUpdateIsConnecting: ((Bool) -> Void)?
    var didUpdateTabs: (([TKTabsView.Item]) -> Void)?
    var didUpdateTabViewIsHidden: ((Bool) -> Void)?
    var didUpdateSelectedTab: ((TKTabsView.Item) -> Void)?

    private let wallet: Wallet
    private let backgroundUpdate: BackgroundUpdate
    private let historyListModuleInput: HistoryListModuleInput
    private var tabs: [TKTabsView.Item] = []

    init(
        wallet: Wallet,
        backgroundUpdate: BackgroundUpdate,
        historyListModuleInput: HistoryListModuleInput
    ) {
        self.wallet = wallet
        self.backgroundUpdate = backgroundUpdate
        self.historyListModuleInput = historyListModuleInput
    }

    func setHistoryListState(_ state: HistoryList.State) {
        switch state {
        case .loading:
            didUpdateTabViewIsHidden?(true)
        case .content, .empty:
            didUpdateTabViewIsHidden?(false)
        }
    }

    var didSelectFilter: ((HistoryList.Filter) -> Void)?

    func viewDidLoad() {
        setupTabs()
        // V1 history is loaded through native TOS JSON-RPC. The legacy streaming
        // connection is not part of that request and must not keep the title in
        // a perpetual loading state when the stream endpoint is unavailable.
        didUpdateIsConnecting?(false)
    }

    private func setupTabs() {
        tabs = [
            TKTabsView.Item(
                title: TKLocales.History.Tab.all,
                isSelectable: true,
                selectionColor: .Button.tertiaryBackground,
                selectionBorderColor: .Separator.alternate,
                borderWidth: 0.5,
                action: { [weak self] in
                    self?.historyListModuleInput.filter = .all
                }
            ),
            TKTabsView.Item(
                title: TKLocales.History.Tab.sent,
                isSelectable: true,
                selectionColor: .Button.tertiaryBackground,
                selectionBorderColor: .Separator.alternate,
                borderWidth: 0.5,
                action: { [weak self] in
                    self?.historyListModuleInput.filter = .sent
                }
            ),
            TKTabsView.Item(
                title: TKLocales.History.Tab.received,
                isSelectable: true,
                selectionColor: .Button.tertiaryBackground,
                selectionBorderColor: .Separator.alternate,
                borderWidth: 0.5,
                action: { [weak self] in
                    self?.historyListModuleInput.filter = .received
                }
            ),
        ]
        didUpdateTabs?(tabs)
        didUpdateTabViewIsHidden?(true)

        if let allTab = tabs.first {
            didUpdateSelectedTab?(allTab)
        }
    }
}

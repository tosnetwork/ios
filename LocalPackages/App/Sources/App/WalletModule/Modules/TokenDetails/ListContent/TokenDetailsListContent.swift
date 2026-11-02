import UIKit

protocol TokenDetailsListContentViewController: UIViewController {
    var scrollView: UIScrollView { get }
    var didPullToRefresh: (() -> Void)? { get set }
    func setHeaderViewController(_ headerViewController: UIViewController?)
}

extension HistoryListViewController: TokenDetailsListContentViewController {
    var scrollView: UIScrollView {
        customView.collectionView
    }
}

/// Token details without legacy index history. The authenticated header owns the balance.
@MainActor
final class TOSTokenDetailsContentViewController: UIViewController, @preconcurrency TokenDetailsListContentViewController {
    let scrollView = UIScrollView()
    var didPullToRefresh: (() -> Void)?
    private var header: UIViewController?
    private let refresh = UIRefreshControl()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        refresh.addTarget(self, action: #selector(reloadBalance), for: .valueChanged)
        scrollView.refreshControl = refresh
    }

    @objc private func reloadBalance() {
        didPullToRefresh?()
        refresh.endRefreshing()
    }

    func setHeaderViewController(_ controller: UIViewController?) {
        loadViewIfNeeded()
        header?.willMove(toParent: nil)
        header?.view.removeFromSuperview()
        header?.removeFromParent()
        header = controller
        guard let controller else { return }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            controller.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        controller.didMove(toParent: self)
    }
}

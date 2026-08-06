import SnapKit
import TKUIKit
import UIKit

final class LaunchScreenViewController: UIViewController {
    private let galaxyView = TOSGalaxyView()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Background.page

        view.addSubview(galaxyView)
        galaxyView.snp.makeConstraints { make in
            make.center.equalTo(view.safeAreaLayoutGuide)
            make.width.height.equalTo(220).priority(.high)
            make.width.height.lessThanOrEqualTo(view.safeAreaLayoutGuide).multipliedBy(0.62)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        galaxyView.startAnimating()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        galaxyView.stopAnimating()
    }
}

private final class TOSGalaxyView: UIView {
    private let markView = UIImageView(image: UIImage(resource: .icLogo128))
    private let haloView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "launch.tosGalaxy"

        haloView.backgroundColor = UIColor.Accent.blue.withAlphaComponent(0.18)
        haloView.layer.shadowColor = UIColor.Accent.blue.cgColor
        haloView.layer.shadowOpacity = 0.65
        haloView.layer.shadowRadius = 34
        haloView.layer.shadowOffset = .zero
        addSubview(haloView)

        markView.contentMode = .scaleAspectFit
        addSubview(markView)

        haloView.snp.makeConstraints { make in make.edges.equalToSuperview().inset(30) }
        markView.snp.makeConstraints { make in make.edges.equalToSuperview().inset(12) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        haloView.layer.cornerRadius = haloView.bounds.width / 2
    }

    func startAnimating() {
        stopAnimating()
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 9
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        markView.layer.add(rotation, forKey: "tos.galaxy.rotation")

        let breathing = CABasicAnimation(keyPath: "opacity")
        breathing.fromValue = 0.45
        breathing.toValue = 0.95
        breathing.duration = 1.8
        breathing.autoreverses = true
        breathing.repeatCount = .infinity
        breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        haloView.layer.add(breathing, forKey: "tos.galaxy.breathing")
    }

    func stopAnimating() {
        markView.layer.removeAllAnimations()
        haloView.layer.removeAllAnimations()
    }
}

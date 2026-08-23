import UIKit
import UniformTypeIdentifiers

// Minimal share-sheet surface for the pipeline-verification build: proves the
// extension target signs, embeds, and activates from the share sheet. The real
// upload/staging flow arrives with the architecture ticket.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: "dot.radiowaves.left.and.right"))
        icon.preferredSymbolConfiguration = .init(pointSize: 40, weight: .medium)
        icon.tintColor = view.tintColor

        let title = UILabel()
        title.text = "SMBDrop"
        title.font = .preferredFont(forTextStyle: .title1)

        let subtitle = UILabel()
        subtitle.text = "Received \(itemCount) item\(itemCount == 1 ? "" : "s") — uploading arrives in the next build."
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        let done = UIButton(configuration: .borderedProminent())
        done.configuration?.title = "Done"
        done.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, title, subtitle, done])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private var itemCount: Int {
        (extensionContext?.inputItems as? [NSExtensionItem])?
            .reduce(0) { $0 + ($1.attachments?.count ?? 0) } ?? 0
    }
}

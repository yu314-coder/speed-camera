import UIKit
import UserNotifications
import UserNotificationsUI

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let stack = UIStackView()
    private let road = UILabel()
    private let titleLabel = UILabel()
    private let limit = UILabel()
    private let direction = UILabel()
    private let source = UILabel()
    override func loadView() {
        view = UIView(); view.backgroundColor = .secondarySystemBackground
        stack.axis = .vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle:.headline); road.font = .preferredFont(forTextStyle:.title2)
        limit.font = UIFont.systemFont(ofSize:34,weight:.bold)
        direction.font = .preferredFont(forTextStyle:.subheadline); source.font = .preferredFont(forTextStyle:.caption1)
        source.textColor = .secondaryLabel
        for label in [titleLabel,road,limit,direction,source] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true; stack.addArrangedSubview(label) }
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:view.topAnchor,constant:18),stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),stack.bottomAnchor.constraint(lessThanOrEqualTo:view.bottomAnchor,constant:-18)])
        preferredContentSize = CGSize(width:360,height:260)
    }
    func didReceive(_ notification: UNNotification) {
        let info = notification.request.content.userInfo
        titleLabel.text = notification.request.content.title + " · " + (info["type"] as? String ?? "Camera")
        road.text = info["road"] as? String ?? notification.request.content.subtitle
        let speed = info["limit"] as? Int ?? 0
        let meters = info["distance"] as? Int ?? 0
        limit.text = speed > 0 ? "\(speed) km/h · \(meters) m" : "\(meters) m ahead · obey signs"
        direction.text = "Direction: \(info["direction"] as? String ?? "Not supplied")"
        source.text = "\(info["source"] as? String ?? "Official source")\nUpdated: \(info["updated"] as? String ?? "Unknown")\nPosted signs take precedence."
        view.layoutIfNeeded()
        preferredContentSize.height = max(240,stack.systemLayoutSizeFitting(CGSize(width:view.bounds.width-40,height:UIView.layoutFittingCompressedSize.height)).height+36)
    }
}

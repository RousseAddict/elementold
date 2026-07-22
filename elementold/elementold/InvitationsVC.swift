import UIKit

// Lists all pending room invites with Accept / Decline actions. Pushed from
// RoomListVC's "Invitations" banner. Accept joins the room
// (POST /rooms/{id}/join); decline leaves it (POST /rooms/{id}/leave). Either
// way the room drops out of `rooms.invite` on the next /sync, so RoomListVC's
// banner updates on its own — this screen just removes the row locally for
// immediate feedback and pops itself when the last invite is handled.
class InvitationsVC: UIViewController {

    private var invitations: [Invitation]
    private let client: MatrixAPIClient
    private var tableView: UITableView!

    private let cellId = "InvitationCell"

    init(invitations: [Invitation], client: MatrixAPIClient) {
        self.invitations = invitations
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Invitations"
        view.backgroundColor = .white

        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 96
        view.addSubview(tableView)
    }

    private func handleAccept(_ invitation: Invitation) {
        act(on: invitation, path: "/_matrix/client/v3/rooms/\(invitation.roomId)/join",
            failureTitle: "Couldn't join")
    }

    private func handleDecline(_ invitation: Invitation) {
        act(on: invitation, path: "/_matrix/client/v3/rooms/\(invitation.roomId)/leave",
            failureTitle: "Couldn't decline")
    }

    private func act(on invitation: Invitation, path: String, failureTitle: String) {
        client.post(path, body: [:]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.showError(title: failureTitle, message: "\(error)")
                    return
                }
                self.remove(invitation)
            }
        }
    }

    private func remove(_ invitation: Invitation) {
        invitations.removeAll { $0.roomId == invitation.roomId }
        if invitations.isEmpty {
            navigationController?.popViewController(animated: true)
        } else {
            tableView.reloadData()
        }
    }

    private func showError(title: String, message: String) {
#if IOS6_TARGET
        let alert = UIAlertView()
        alert.title = title
        alert.message = message
        alert.addButton(withTitle: "OK")
        alert.show()
#else
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
#endif
    }
}

extension InvitationsVC: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return invitations.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: cellId) as? InvitationCell) ??
            InvitationCell(style: .default, reuseIdentifier: cellId)
        let invitation = invitations[indexPath.row]
        cell.configure(with: invitation)
        cell.onAccept = { [weak self] in self?.handleAccept(invitation) }
        cell.onDecline = { [weak self] in self?.handleDecline(invitation) }
        return cell
    }
}

// One invite: room/inviter text on top, an Accept and a Decline button below.
private class InvitationCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let inviterLabel = UILabel()
    private let acceptButton = UIButton(type: .system)
    private let declineButton = UIButton(type: .system)

    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        nameLabel.backgroundColor = .clear   // iOS 6: labels default to white bg
        nameLabel.font = UIFont.boldSystemFont(ofSize: 16)
        contentView.addSubview(nameLabel)

        inviterLabel.backgroundColor = .clear
        inviterLabel.font = UIFont.systemFont(ofSize: 13)
        inviterLabel.textColor = .gray
        contentView.addSubview(inviterLabel)

        acceptButton.setTitle("Accept", for: .normal)
        acceptButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        acceptButton.setTitleColor(UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0), for: .normal)
        acceptButton.addTarget(self, action: #selector(acceptTapped), for: .touchUpInside)
        contentView.addSubview(acceptButton)

        declineButton.setTitle("Decline", for: .normal)
        declineButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        declineButton.setTitleColor(UIColor(red: 0.8, green: 0.0, blue: 0.0, alpha: 1.0), for: .normal)
        declineButton.addTarget(self, action: #selector(declineTapped), for: .touchUpInside)
        contentView.addSubview(declineButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with invitation: Invitation) {
        nameLabel.text = invitation.name
        if let inviter = invitation.inviter, inviter != invitation.name {
            inviterLabel.text = "Invited by \(inviter)"
            inviterLabel.isHidden = false
        } else {
            inviterLabel.text = nil
            inviterLabel.isHidden = true
        }
    }

    @objc private func acceptTapped() { onAccept?() }
    @objc private func declineTapped() { onDecline?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let margin: CGFloat = 15
        let width = contentView.bounds.width

        nameLabel.frame = CGRect(x: margin, y: 12, width: width - margin * 2, height: 22)
        inviterLabel.frame = CGRect(x: margin, y: 36, width: width - margin * 2, height: 18)

        let buttonWidth: CGFloat = 80
        let buttonHeight: CGFloat = 32
        let buttonY = contentView.bounds.height - buttonHeight - 12
        declineButton.frame = CGRect(x: width - margin - buttonWidth, y: buttonY,
                                      width: buttonWidth, height: buttonHeight)
        acceptButton.frame = CGRect(x: declineButton.frame.minX - 8 - buttonWidth, y: buttonY,
                                     width: buttonWidth, height: buttonHeight)
    }
}

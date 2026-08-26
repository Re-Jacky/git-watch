import SwiftUI

struct PullRequestRowView: View {
    let summary: PullRequestSummary
    let action: RowAction
    let inFlight: Bool
    let errorMessage: String?
    let onAction: () -> Void
    var onDismiss: (() -> Void)? = nil
    var showsAuthor: Bool = false

    enum RowAction: Equatable {
        case none
        case approve
        case merge(MergeMethod)

        var title: String {
            switch self {
            case .none: return ""
            case .approve: return "Approve"
            case let .merge(method): return "Merge · \(method.label)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: { NSWorkspace.shared.open(summary.url) }) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(repositoryLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.appSecondaryText)
                            if showsAuthor {
                                Text("· @\(summary.authorLogin)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.appTertiaryText)
                                    .lineLimit(1)
                            }
                            Text("· \(ageText)")
                                .font(.system(size: 11))
                                .foregroundColor(.appTertiaryText)
                        }

                        Text(summary.title)
                            .font(.system(size: 12))
                            .foregroundColor(.appPrimaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open pull request in browser")

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.appTertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Don't show this PR again (dismiss)")
                }
            }

            HStack(spacing: 8) {
                if summary.checks.isEmpty == false {
                    HStack(spacing: 3) {
                        ForEach(Array(summary.checks.enumerated()), id: \.offset) { _, dot in
                            Circle()
                                .fill(dotColor(dot.outcome))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .help(checksHelpText)
                }

                if let chip = reviewChipText {
                    Text(chip.text)
                        .font(.system(size: 10))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1.5)
                        .background(chip.color.opacity(0.15))
                        .foregroundColor(chip.color)
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)

                if action != .none {
                    Button(action: onAction) {
                        Group {
                            if inFlight {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                            } else {
                                Text(action.title)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .frame(minWidth: actionTitleWidth)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(inFlight)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(Color.appFieldBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var repositoryLabel: String {
        let parts = summary.repositoryNameWithOwner.split(separator: "/")
        let repo = parts.last.map(String.init) ?? summary.repositoryNameWithOwner
        return "\(repo)#\(summary.number)"
    }

    private var ageText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: summary.createdAt, relativeTo: Date())
    }

    private var actionTitleWidth: CGFloat? {
        switch action {
        case .none: return nil
        default: return 92
        }
    }

    private func dotColor(_ outcome: CheckOutcome) -> Color {
        switch outcome {
        case .success: return .appStatusSuccess
        case .failure: return .appStatusFailure
        case .pending: return .appStatusPending
        }
    }

    private var checksHelpText: String {
        let success = summary.checks.filter { $0.outcome == .success }.count
        let failure = summary.checks.filter { $0.outcome == .failure }.count
        let pending = summary.checks.filter { $0.outcome == .pending }.count
        return "\(success) passed · \(failure) failed · \(pending) pending"
    }

    private var reviewChipText: (text: String, color: Color)? {
        switch summary.reviewDecision {
        case .approved:
            return ("Approved", Color.appStatusSuccess)
        case .changesRequested:
            return ("Changes requested", Color.appStatusFailure)
        case .reviewRequired:
            return ("Pending review", Color.appStatusPending)
        case nil:
            return nil
        }
    }
}

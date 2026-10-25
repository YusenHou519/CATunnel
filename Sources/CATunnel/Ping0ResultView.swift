import Foundation
import SwiftUI
import TunnelCore

struct Ping0ResultPresentation {
    let ipType: String
    let riskValue: String
    let sharedUsers: String

    init(_ assessment: Ping0Assessment?) {
        func provided(_ value: String?) -> String {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "未提供" : trimmed
        }
        ipType = provided(assessment?.ipType)
        sharedUsers = provided(assessment?.sharedUsers)
        if let value = assessment?.riskValue, value.isFinite, (0...100).contains(value) {
            riskValue = String(format: value.rounded() == value ? "%.0f / 100" : "%.1f / 100",
                               locale: Locale(identifier: "en_US_POSIX"), value)
        } else {
            riskValue = "未提供"
        }
    }
}

struct Ping0ResultView: View {
    let result: Ping0CheckResult
    let enabled: Bool
    var historical = false
    var fontScale: Double = 1
    let identifierPrefix: String

    private static let checkTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(historical ? "历史 IP 信息 · Ping0" : "IP 信息 · Ping0", systemImage: "globe")
                    .font(font(12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Text(stateTitle)
                    .font(font(10))
                    .foregroundStyle(result.state == .failed ? Color.orange : Color.secondary)
                    .fixedSize()
            }

            if result.state == .available, let assessment = result.assessment {
                let values = Ping0ResultPresentation(assessment)
                Text("查询 IP：\(result.ip ?? assessment.ip)")
                    .font(.system(size: 10 * fontScale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                metric("IP 类型", value: values.ipType, identifier: "type")
                metric("风控值", value: values.riskValue, identifier: "risk")
                metric("共享人数", value: values.sharedUsers, identifier: "users")
                Text("风控值越高风险越高；共享人数为过去 12 个月的估算区间。")
                    .font(font(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(stateMessage)
                    .font(font(11))
                    .foregroundStyle(result.state == .failed ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if [.available, .failed].contains(result.state), let checkedAt = result.checkedAt {
                Text("\(historical ? "历史检测" : "检测时间") · \(Self.checkTime.string(from: checkedAt))")
                    .font(font(10))
                    .foregroundStyle(historical ? Color.orange : Color.secondary)
            }
            if enabled {
                Text("来源：Ping0 公开查询页，网页可能变化；仅供参考。")
                    .font(font(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifierPrefix)
        .captureLayoutEvidence(identifierPrefix)
    }

    private func metric(_ title: String, value: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 60 * fontScale, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(font(11))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifierPrefix)-\(identifier)")
        .captureLayoutEvidence("\(identifierPrefix)-\(identifier)")
    }

    private var stateTitle: String {
        switch result.state {
        case .unchecked: return enabled ? "未检测" : "未开启"
        case .checking: return "检测中"
        case .available: return "已获取"
        case .failed: return "未完成"
        case .skipped: return "已跳过"
        }
    }

    private var stateMessage: String {
        if !enabled { return "未开启 Ping0 查询，可在服务器设置中选择启用。" }
        if result.state == .available { return "未返回可展示的 Ping0 结果。" }
        if !result.message.isEmpty { return result.message }
        switch result.state {
        case .unchecked: return "点击检测，查询 Ping0 IP 信息。"
        case .checking: return "正在查询 Ping0…"
        case .failed: return "Ping0 查询未完成，请查看日志或重新检测。"
        case .skipped: return "本次未查询 Ping0。"
        case .available: return "未返回可展示的 Ping0 结果。"
        }
    }

    private func font(_ size: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: size * fontScale, weight: weight)
    }
}

import Foundation

enum HistoryExport {
    static func encode(_ snapshots: [DiagnosticSnapshot], csv: Bool) throws -> Data {
        if !csv {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(snapshots)
        }
        func escaped(_ value: String) -> String {
            // Quoting alone does not stop spreadsheet formula evaluation.
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: value.hasPrefix) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        var rows = ["timestamp,run_kind,likely_culprit,layer,test,target,status,latency_ms,packet_loss_percent,value,unit,detail"]
        for snapshot in snapshots {
            for probe in snapshot.probes {
                rows.append([formatter.string(from: snapshot.date), snapshot.kind, snapshot.finding.title, probe.layer.rawValue, probe.name, probe.target, probe.health.rawValue,
                             probe.milliseconds.map(String.init(describing:)) ?? "", probe.packetLoss.map(String.init(describing:)) ?? "", probe.value.map(String.init(describing:)) ?? "", probe.unit ?? "", probe.detail].map(escaped).joined(separator: ","))
            }
        }
        return Data((rows.joined(separator: "\n") + "\n").utf8)
    }
}

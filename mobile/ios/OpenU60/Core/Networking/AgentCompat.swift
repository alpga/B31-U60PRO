import Foundation

/// Routes this app asks for that the deployed agent publishes under a different
/// name or shape.
///
/// Two families are covered, both from data the agent already serves:
///
/// * **Dashboard slices** — the agent answers `/api/dashboard` with the radio,
///   pack, WAN interfaces, memory, thermal sensors and traffic in one payload;
///   this app was written against a build that split them into
///   `/api/network/signal`, `/api/battery`, `/api/device/system` and so on.
/// * **eSIM** — the agent's eSIM API is a single `/api/esim` document
///   (`view.profiles`, `view.notifications`, `view.eid`) plus actions posted to
///   the same path; this app was written against a build with one path per
///   operation (`/api/esim/profiles`, `/api/esim/chip`, …).
///
/// Nothing is invented: every field below is copied or renamed from the agent's
/// own reply, so a screen either shows real state or the call fails as before.
enum AgentCompat {
    /// Where the data for `path` comes from.
    static func source(for path: String) -> String {
        path.hasPrefix("/api/esim") ? "/api/esim" : "/api/dashboard"
    }

    /// Paths answered by reshaping another endpoint's reply.
    static func handles(_ path: String) -> Bool {
        switch path {
        case "/api/network/signal", "/api/network/wan", "/api/network/wan6",
             "/api/network/traffic", "/api/device/system", "/api/device/thermal",
             "/api/battery", "/api/modem/status",
             "/api/esim/profiles", "/api/esim/chip", "/api/esim/notifications":
            return true
        default:
            return false
        }
    }

    /// A request that has to be re-addressed rather than reshaped, e.g. switching
    /// profile: the app posts `/api/esim/enable`, the agent takes
    /// `POST /api/esim {"action":"enable"}`.
    static func translate(
        method: String,
        path: String,
        body: Data?
    ) -> (method: String, path: String, body: Data?)? {
        guard method == "POST", path == "/api/esim/enable", let body,
              let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let iccid = request["iccid"] as? String
        else { return nil }
        let action: [String: Any] = ["action": "enable", "iccid": iccid]
        guard let payload = try? JSONSerialization.data(withJSONObject: action) else { return nil }
        return ("POST", "/api/esim", payload)
    }

    /// Builds the envelope the caller's parser expects for `path`.
    static func body(for path: String, source: Data) throws -> Data {
        guard
            let root = try JSONSerialization.jsonObject(with: source) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else {
            throw AgentError.decodingError("compatibility source has no data object")
        }

        let value: Any
        switch path {
        // MARK: Dashboard slices
        case "/api/network/signal":
            value = data["signal"] as? [String: Any] ?? [:]
        case "/api/network/wan":
            value = data["wan"] as? [String: Any] ?? [:]
        case "/api/network/wan6":
            value = data["wan6"] as? [String: Any] ?? [:]
        case "/api/device/thermal":
            value = data["thermal"] as? [String: Any] ?? [:]
        case "/api/network/traffic":
            value = traffic(from: data)
        case "/api/battery":
            value = battery(from: data)
        case "/api/device/system":
            value = system(from: data)
        case "/api/modem/status":
            value = modemStatus(from: data)

        // MARK: eSIM
        case "/api/esim/profiles":
            value = inventory(from: data)
        case "/api/esim/chip":
            value = chip(from: data)
        case "/api/esim/notifications":
            value = ["count": notifications(from: data).count]
        case "/api/esim/enable":
            // The app only uses this to update its optimistic list; the profile
            // list that follows is authoritative.
            value = ["enabled_iccid": enabledIccid(from: data) ?? ""]

        default:
            throw AgentError.serverError("no compatibility mapping for \(path)")
        }

        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": value])
    }

    // MARK: - Dashboard slices

    /// The dashboard's speed counters are one aggregate; the app looks for the
    /// cellular interface by name, so a single synthetic entry is enough.
    private static func traffic(from data: [String: Any]) -> [[String: Any]] {
        let speed = data["speed"] as? [String: Any] ?? [:]
        return [[
            "name": "rmnet_data0",
            "rx_bytes": uint64(speed["rx_bytes"]),
            "tx_bytes": uint64(speed["tx_bytes"]),
        ]]
    }

    /// The kernel reports tenths of a degree; the app validates -40…150 °C.
    private static func battery(from data: [String: Any]) -> [String: Any] {
        let pack = data["battery"] as? [String: Any] ?? [:]
        return [
            "battery_capacity": int(pack["capacity"], default: -1),
            "battery_temperature": double(pack["temperature"]) / 10.0,
            "battery_time_to_full": -1,
            "battery_time_to_empty": -1,
            "battery_status": pack["status"] as? String ?? "",
        ]
    }

    /// `load` is fixed point (loadavg × 65536) and memory is bytes.
    private static func system(from data: [String: Any]) -> [String: Any] {
        let device = data["device"] as? [String: Any] ?? [:]
        let memory = data["memory"] as? [String: Any] ?? [:]
        let loads = device["load_avg"] as? [Any] ?? []
        let fixed = (0..<3).map { index -> Double in
            let value = index < loads.count ? double(loads[index]) : 0
            return value * 65536.0
        }
        return [
            "load": fixed,
            "uptime": int(device["uptime_secs"], default: 0),
            "memory_total": uint64(memory["total_kb"]) * 1024,
            "memory_free": uint64(memory["free_kb"]) * 1024,
        ]
    }

    private static func modemStatus(from data: [String: Any]) -> [String: Any] {
        let signal = data["signal"] as? [String: Any] ?? [:]
        let network = signal["network_type"] as? String ?? ""
        return ["operate_mode": network.isEmpty ? "low_power" : "online"]
    }

    // MARK: - eSIM

    /// `view.profiles` uses `enabled: Bool`; the app reads a `state` string.
    private static func inventory(from data: [String: Any]) -> [String: Any] {
        let view = data["view"] as? [String: Any] ?? [:]
        let profiles = (view["profiles"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
            [
                "iccid": item["iccid"] as? String ?? "",
                "provider": item["provider"] as? String ?? "",
                "name": item["name"] as? String ?? "",
                "nickname": item["nickname"] as? String ?? "",
                "state": (item["enabled"] as? Bool ?? false) ? "enabled" : "disabled",
                "class": item["class"] as? String ?? "",
            ]
        }
        var out: [String: Any] = [
            "profiles": profiles,
            "generation": view["generation"] ?? 0,
            "observed_at": view["read_at"] ?? 0,
            // A finished job stays in the document; only a running one means busy.
            "updating": (data["job"] as? [String: Any])?["state"] as? String == "running",
            "stale": false,
        ]
        // Anything other than an eUICC is reported, not hidden: an ordinary SIM
        // and an empty slot both explain why the list is empty.
        if let card = view["card"] as? String, card != "euicc" {
            let message: String
            switch card {
            case "sim": message = "This is an ordinary SIM, not an eUICC"
            case "absent": message = "No card in the slot"
            default: message = view["detail"] as? String ?? "The card could not be read"
            }
            out["error"] = ["kind": card, "message": message]
        }
        return out
    }

    private static func chip(from data: [String: Any]) -> [String: Any] {
        let view = data["view"] as? [String: Any] ?? [:]
        let info = view["info"] as? [String: Any] ?? [:]
        return [
            "eid": view["eid"] as? String ?? "",
            "firmware": info["firmware"] as? String ?? info["svn"] as? String ?? "",
            "free_nvm_bytes": int(info["free_nvm_bytes"], default: 0),
        ]
    }

    private static func notifications(from data: [String: Any]) -> [[String: Any]] {
        let view = data["view"] as? [String: Any] ?? [:]
        return view["notifications"] as? [[String: Any]] ?? []
    }

    private static func enabledIccid(from data: [String: Any]) -> String? {
        let view = data["view"] as? [String: Any] ?? [:]
        let profiles = view["profiles"] as? [[String: Any]] ?? []
        return profiles.first { $0["enabled"] as? Bool == true }?["iccid"] as? String
    }

    // MARK: - JSON numbers

    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func int(_ value: Any?, default fallback: Int) -> Int {
        (value as? NSNumber)?.intValue ?? fallback
    }

    private static func uint64(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}

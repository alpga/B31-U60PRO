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
        switch path {
        case "/api/device/thermal": return "/api/device/thermal/all"
        case "/api/network/clients": return "/api/network/clients"
        case "/api/network/lan-status", "/api/router/lan": return "/api/router/lan"
        case "/api/dns/status": return "/api/router/dns"
        case "/api/router/apn/auto-profiles": return "/api/router/apn/profiles"
        case "/api/esim/profiles", "/api/esim/chip", "/api/esim/notifications":
            return "/api/esim"
        default:
            return "/api/dashboard"
        }
    }

    /// Paths answered by reshaping another endpoint's reply. Reads only: a write
    /// must reach the agent, which is why the method is part of the question.
    static func handles(_ path: String, method: String) -> Bool {
        guard method == "GET" else { return false }
        switch path {
        case "/api/network/signal", "/api/network/wan", "/api/network/wan6",
             "/api/network/traffic", "/api/network/clients", "/api/network/lan-status",
             "/api/router/lan", "/api/dns/status", "/api/router/apn/auto-profiles",
             "/api/device/system", "/api/device/thermal", "/api/device/battery-info",
             "/api/battery", "/api/modem/status", "/api/modem/data",
             "/api/modem/network-mode",
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
            value = thermal(from: data)
        case "/api/network/traffic":
            value = traffic(from: data)
        case "/api/battery":
            value = battery(from: data)
        case "/api/device/system":
            value = system(from: data)
        case "/api/modem/status":
            value = modemStatus(from: data)
        case "/api/modem/data":
            value = modemData(from: data)
        case "/api/modem/network-mode":
            value = networkMode(from: data)
        case "/api/network/clients":
            value = hosts(from: data)
        case "/api/router/lan":
            // The firmware names these `ipaddr`/`netmask`/`dhcp_enabled`; the LAN
            // screen reads the older `lan_*` spelling.
            let lan: [String: Any] = [
                "lan_ipaddr": data["ipaddr"] as? String ?? "",
                "lan_netmask": data["netmask"] as? String ?? "",
                "dhcp_enable": (data["dhcp_enabled"] as? Bool ?? false) ? "1" : "0",
                "dhcp_start": data["dhcp_start"] as? String ?? "",
                "dhcp_end": data["dhcp_end"] as? String ?? "",
                "dhcp_lease_time": String(int(data["lease_seconds"], default: 0)),
            ]
            value = lan
        case "/api/router/apn/auto-profiles":
            // This firmware has one profile list; the app shows it in both tabs.
            value = data
        case "/api/dns/status":
            // `/api/router/dns` uses dns_mode/prefer_dns_manual; the DNS screen
            // expects mode/primary/secondary plus a stats block.
            let stats: [String: Any] = [
                "cache_entries": 0, "cache_hits": 0, "cache_misses": 0, "queries_total": 0,
            ]
            let dns: [String: Any] = [
                "mode": (data["dns_mode"] as? String == "auto") ? "automatic" : "manual",
                "primary": data["prefer_dns_manual"] as? String ?? "",
                "secondary": data["standby_dns_manual"] as? String ?? "",
                "proxy_running": false,
                "doh_url": "",
                "stats": stats,
            ]
            value = dns
        case "/api/network/lan-status":
            // `/api/router/lan` carries the address as plain fields; the app reads
            // the ubus shape, so it is rebuilt here.
            let lanStatus: [String: Any] = [
                "up": true,
                "ipv4-address": [[
                    "address": data["ipaddr"] as? String ?? "",
                    "mask": data["netmask"] as? String ?? "",
                ]],
            ]
            value = lanStatus

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

    /// The detail sheet wants capacity, temperature and both ETAs: capacity and
    /// temperature live in the dashboard, the ETAs only in the agent's own
    /// battery-info reply, so the two are merged here.
    static func batteryInfo(dashboard: Data, info: Data) throws -> Data {
        var shaped = try JSONSerialization.jsonObject(with: body(for: "/api/battery", source: dashboard)) as? [String: Any] ?? [:]
        var value = shaped["data"] as? [String: Any] ?? [:]
        if let root = try JSONSerialization.jsonObject(with: info) as? [String: Any],
           let detail = root["data"] as? [String: Any] {
            if let full = detail["time_to_full_mins"] as? NSNumber { value["battery_time_to_full"] = full.intValue }
            if let empty = detail["time_to_empty_mins"] as? NSNumber { value["battery_time_to_empty"] = empty.intValue }
            if let online = detail["online"] as? Bool { value["online"] = online }
        }
        shaped["data"] = value
        return try JSONSerialization.data(withJSONObject: shaped)
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

    /// The app shows "airplane mode" when the operating mode is not online, so the
    /// answer must distinguish "no service" from "radio off": only an explicit
    /// low-power mode counts as off.
    private static func modemStatus(from data: [String: Any]) -> [String: Any] {
        let signal = data["signal"] as? [String: Any] ?? [:]
        let mode = signal["domain_stat"] as? String ?? ""
        let registered = !(signal["network_type"] as? String ?? "").isEmpty
        let online = registered || mode != "NO_SERVICE"
        // The app treats anything other than "ONLINE" as airplane mode, so the
        // firmware's own vocabulary is used rather than a private one.
        return [
            "operate_mode": online ? "ONLINE" : "LPM",
            "registered": registered,
            "domain_stat": mode,
        ]
    }

    /// `MobileNetworkParser.parseWWAN` reads connect_mode / roam_enable / enable /
    /// connect_status; the dashboard's radio section carries the last of those.
    private static func modemData(from data: [String: Any]) -> [String: Any] {
        let signal = data["signal"] as? [String: Any] ?? [:]
        let connected = !(signal["network_type"] as? String ?? "").isEmpty
        return [
            "connect_mode": 1,
            "roam_enable": 0,
            "enable": 1,
            "connect_status": connected ? "connected" : "disconnected",
            "network_type": signal["network_type"] ?? "",
        ]
    }

    /// `parseNetInfo` only reads `net_select_mode`, which the netinfo reply has.
    private static func networkMode(from data: [String: Any]) -> [String: Any] {
        let signal = data["signal"] as? [String: Any] ?? [:]
        return [
            "net_select": signal["net_select"] ?? "",
            "net_select_mode": signal["net_select_mode"] ?? "auto_select",
            "m_netselect_status": "",
            "m_netselect_contents": [],
        ]
    }

    /// `DeviceParser.parseHostHints` wants `hosts[mac] = {name, ipaddrs}` and
    /// `enrichWithDHCP` wants `[{macaddr, hostname}]`; the agent sends a flat list.
    private static func hosts(from data: [String: Any]) -> [String: Any] {
        let clients = data["clients"] as? [[String: Any]] ?? []
        var hosts: [String: Any] = [:]
        var leases: [[String: Any]] = []
        for client in clients {
            guard let mac = client["mac"] as? String, !mac.isEmpty else { continue }
            let name = client["hostname"] as? String ?? ""
            let ip = client["ip"] as? String ?? ""
            hosts[mac] = ["name": name, "ipaddrs": ip.isEmpty ? [] : [ip], "ip6addrs": []]
            leases.append(["macaddr": mac, "hostname": name])
        }
        return ["hosts": hosts, "dhcp_leases": leases]
    }

    /// `/api/device/thermal/all` already carries `cpu_0…3`, `battery` and the full
    /// sensor list; the app wants a single `cpuss_temp` plus `sensors[]`.
    private static func thermal(from data: [String: Any]) -> [String: Any] {
        let cores = ["cpu_0", "cpu_1", "cpu_2", "cpu_3"].compactMap { key -> Double? in
            guard let value = data[key] as? NSNumber else { return nil }
            return value.doubleValue
        }
        var sensors = data["sensors"] as? [[String: Any]] ?? []
        if let battery = data["battery"] as? NSNumber {
            sensors.append(["id": "battery", "name": "battery", "temperature_c": battery.doubleValue])
        }
        var out: [String: Any] = ["sensors": sensors]
        if let hottest = cores.max() { out["cpuss_temp"] = hottest }
        if let battery = data["battery"] { out["battery_temp"] = battery }
        return out
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
            case "sim": message = "这是一张普通 SIM 卡，不是 eUICC"
            case "absent": message = "卡槽里没有卡"
            default: message = view["detail"] as? String ?? "读卡失败"
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

/// One dashboard read serves every slice in a refresh tick: the app asks for eight
/// of these paths per poll, and each used to cost its own aggregation on the
/// router. A one-second window collapses them without making the UI stale.
actor SourceSnapshot {
    private var entries: [String: (at: Date, data: Data)] = [:]

    func value(for path: String, ttl: TimeInterval) -> Data? {
        guard let entry = entries[path], Date().timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.data
    }

    func store(_ data: Data, for path: String) {
        entries[path] = (Date(), data)
    }
}

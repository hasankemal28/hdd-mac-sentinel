import Foundation
import IOKit
import IOKit.storage

enum DiskFormat: String, CaseIterable, Identifiable, Sendable {
    case exFAT = "ExFAT"
    case apfs = "APFS"
    case hfs = "JHFS+"

    var id: Self { self }

    var label: String {
        switch self {
        case .exFAT: "exFAT"
        case .apfs: "APFS"
        case .hfs: "Mac OS Genişletilmiş (Günlüklü)"
        }
    }

    var hint: String {
        switch self {
        case .exFAT: "Mac ve Windows ile kullanım için."
        case .apfs: "Güncel macOS sürümleriyle kullanım için."
        case .hfs: "Eski Mac’lerle uyumluluk için."
        }
    }

    func nameError(_ name: String) -> String? {
        if name.isEmpty { return "Bir disk adı girin." }
        if name.hasPrefix("-") || name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:")).contains($0)
        }) {
            return "Disk adı tire ile başlayamaz ve / veya : içeremez."
        }
        if self == .exFAT {
            let forbidden = CharacterSet(charactersIn: "\"*<>?\\|")
            if name.unicodeScalars.contains(where: forbidden.contains) {
                return "Disk adı exFAT’in desteklemediği karakterler içeriyor."
            }
            if name.utf16.count > 11 { return "exFAT için en fazla 11 karakterlik bir ad girin." }
        }
        if name.utf8.count > 255 { return "Daha kısa bir disk adı girin." }
        return nil
    }
}

enum SMARTStatus: Sendable, Equatable {
    case verified, failing, unavailable, unknown

    init(_ rawValue: String?) {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "verified": self = .verified
        case "failing", "failed", "failure", "fatal": self = .failing
        case "not supported", "unsupported", nil, "": self = .unavailable
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .verified: "SMART uyarısı yok"
        case .failing: "SMART arıza bildiriyor"
        case .unavailable: "SMART verisi alınamadı"
        case .unknown: "SMART durumu belirsiz"
        }
    }

    var description: String {
        switch self {
        case .verified: "Diskin kendi tanılama sistemi bir arıza bildirmedi."
        case .failing: "Verilerinizi yedekleyin ve diski değiştirmeyi değerlendirin."
        case .unavailable: "Bazı diskler ve USB adaptörleri SMART bilgisini macOS’a iletmez."
        case .unknown: "macOS’tan alınan SMART durumu yorumlanamadı."
        }
    }
}

struct ExternalDisk: Identifiable, Sendable {
    let id: UInt64
    let device: String
    let name: String
    let size: Int64
    let connection: String
    let mediaType: String?
    let partitionMap: String
    let volumes: [String]
    let smart: SMARTStatus
    let percentageUsed: Int?
    let writable: Bool
    let isStartupDisk: Bool

    var capacity: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .decimal)
    }

    var subtitle: String { "\(capacity) · \(connection) · \(device)" }
    var isGUID: Bool { partitionMap == "GUID_partition_scheme" }
    var partitionMapLabel: String {
        switch partitionMap {
        case "GUID_partition_scheme": "GUID"
        case "FDisk_partition_scheme": "MBR"
        case "Apple_partition_scheme": "Apple Bölüm Haritası"
        case "", "None": "Belirtilmemiş"
        default: partitionMap
        }
    }
}

struct EraseRequest: Identifiable, Sendable {
    let disk: ExternalDisk
    let name: String
    let format: DiskFormat

    var id: UInt64 { disk.id }
}

struct FilesystemCheck: Sendable {
    let label: String
    let status: String
    let detail: String
    let verified: Bool

    var report: String {
        [label, status, detail].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum DiskError: LocalizedError {
    case invalidResponse, diskChanged, startupDisk, notWritable, unsupportedMap
    case noVolumes, invalidName(String), commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Disk bilgileri macOS’tan alınamadı."
        case .diskChanged: "Seçilen disk çıkarıldı veya değişti. Disk listesini yenileyin."
        case .startupDisk: "macOS’un çalıştığı başlangıç diski biçimlendirilemez."
        case .notWritable: "Disk yazmaya kapalı."
        case .unsupportedMap: "Bölüm haritası denetimi için GUID bölümlendirmesi gerekiyor."
        case .noVolumes: "Bu diskte macOS’un denetleyebileceği bir dosya sistemi bulunamadı."
        case .invalidName(let reason): reason
        case .commandFailed(let output): output
        }
    }
}

struct DiskService {
    typealias Plist = [String: Any]
    typealias Run = ([String]) throws -> Data
    let run: Run
    let registryID: (String) -> UInt64?

    init(run: @escaping Run = DiskService.diskutil, registryID: @escaping (String) -> UInt64? = DiskService.mediaID) {
        self.run = run
        self.registryID = registryID
    }

    func scan() throws -> [ExternalDisk] {
        let listing = try plist(["list", "-plist", "external", "physical"])
        guard let entries = listing["AllDisksAndPartitions"] as? [Plist] else {
            throw DiskError.invalidResponse
        }
        guard !entries.isEmpty else { return [] }
        let startup = try startupDisks()
        let containers = (try? plist(["apfs", "list", "-plist"])["Containers"] as? [Plist]) ?? []

        return try entries.compactMap { entry in
            guard let device = entry["DeviceIdentifier"] as? String,
                  Self.isWholeIdentifier(device), let id = registryID(device) else { return nil }
            do {
                let info = try plist(["info", "-plist", device])
                guard isExternalWhole(info, device: device), registryID(device) == id else { return nil }
                let name = (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let solidState = info["SolidState"] as? Bool
                let attributes = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? Plist
                return ExternalDisk(
                    id: id, device: device, name: name ?? "Harici disk",
                    size: (info["TotalSize"] as? Int64) ?? (entry["Size"] as? Int64) ?? 0,
                    connection: info["BusProtocol"] as? String ?? "Bağlantı bilinmiyor",
                    mediaType: solidState.map { $0 ? "SSD" : "SSD dışı ortam" },
                    partitionMap: info["Content"] as? String ?? "",
                    volumes: volumeNames(in: entry, containers: containers),
                    smart: SMARTStatus(info["SMARTStatus"] as? String),
                    percentageUsed: attributes?["PERCENTAGE_USED"] as? Int,
                    writable: info["WritableMedia"] as? Bool == true,
                    isStartupDisk: startup.contains(device)
                )
            } catch {
                if registryID(device) == nil { return nil }
                throw error
            }
        }
    }

    func verify(_ disk: ExternalDisk) throws -> String {
        let info = try currentInfo(for: disk)
        guard info["Content"] as? String == "GUID_partition_scheme" else { throw DiskError.unsupportedMap }
        return Self.output(try run(["verifyDisk", "/dev/\(disk.device)"]))
    }

    func verifyFilesystems(_ disk: ExternalDisk) throws -> [FilesystemCheck] {
        _ = try currentInfo(for: disk)
        let listing = try plist(["list", "-plist", disk.device])
        guard let entry = (listing["AllDisksAndPartitions"] as? [Plist])?.first(where: {
            $0["DeviceIdentifier"] as? String == disk.device
        }), registryID(disk.device) == disk.id else { throw DiskError.diskChanged }

        let partitions = entry["Partitions"] as? [Plist] ?? []
        let physicalIDs = Set(partitions.compactMap { $0["DeviceIdentifier"] as? String } + [disk.device])
        var results: [FilesystemCheck] = []
        var candidates = partitions.isEmpty ? [entry] : partitions
        let apfsStores = candidates.filter(Self.isAPFSStore)

        // APFS volumes have synthesized BSD names. Resolve them through their physical stores.
        if !apfsStores.isEmpty {
            guard let containers = try plist(["apfs", "list", "-plist"])["Containers"] as? [Plist] else {
                throw DiskError.invalidResponse
            }
            var matchedStores = Set<String>()
            for container in containers {
                let stores = Set(physicalStores(in: container))
                guard !physicalIDs.isDisjoint(with: stores) else { continue }
                matchedStores.formUnion(stores)
                if !stores.isSubset(of: physicalIDs) {
                    results.append(FilesystemCheck(
                        label: "APFS kapsayıcısı", status: "Denetlenemedi",
                        detail: "Kapsayıcı birden fazla fiziksel diske yayılıyor.", verified: false))
                } else if let volumes = container["Volumes"] as? [Plist], !volumes.isEmpty {
                    candidates += volumes
                } else {
                    results.append(FilesystemCheck(
                        label: "APFS kapsayıcısı", status: "Denetlenemedi",
                        detail: "macOS bu kapsayıcı için birim listelemedi.", verified: false))
                }
            }
            for partition in apfsStores {
                if let device = partition["DeviceIdentifier"] as? String, !matchedStores.contains(device) {
                    results.append(FilesystemCheck(
                        label: "APFS bölümü (\(device))", status: "Denetlenemedi",
                        detail: "macOS bu bölüm için bir APFS kapsayıcısı göstermedi.", verified: false))
                }
            }
        }

        var checked = Set<String>()
        for candidate in candidates {
            guard let device = candidate["DeviceIdentifier"] as? String,
                  device.range(of: #"\Adisk[0-9]+(?:s[0-9]+)?\z"#, options: .regularExpression) != nil,
                  checked.insert(device).inserted else { continue }
            let content = candidate["Content"] as? String ?? ""
            if content == "EFI" || content == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" ||
                Self.isAPFSStore(candidate) { continue }

            guard registryID(disk.device) == disk.id else { throw DiskError.diskChanged }
            let candidateName = candidate["VolumeName"] as? String ?? candidate["Name"] as? String
            let label = candidateName.map { "\($0) (\(device))" } ?? device
            guard let volumeID = registryID(device) else {
                results.append(FilesystemCheck(label: label, status: "Denetlenemedi",
                                               detail: "Birim artık erişilebilir değil.", verified: false))
                continue
            }
            do {
                let info = try plist(["info", "-plist", device])
                guard info["DeviceIdentifier"] as? String == device,
                      registryID(device) == volumeID,
                      registryID(disk.device) == disk.id else { throw DiskError.diskChanged }
                if physicalIDs.contains(device) {
                    guard info["ParentWholeDisk"] as? String == disk.device else { throw DiskError.diskChanged }
                } else {
                    let stores = (info["APFSPhysicalStores"] as? [Plist] ?? [])
                        .compactMap { $0["APFSPhysicalStore"] as? String }
                    guard !stores.isEmpty, Set(stores).isSubset(of: physicalIDs) else { throw DiskError.diskChanged }
                }
                if info["Locked"] as? Bool == true || candidate["Locked"] as? Bool == true {
                    results.append(FilesystemCheck(label: label, status: "Denetlenemedi",
                                                   detail: "Şifreli birimin kilidi kapalı.", verified: false))
                    continue
                }
                guard info["FilesystemType"] is String || candidateName != nil else { continue }
                let output = Self.output(try run(["verifyVolume", "/dev/\(device)"]))
                guard registryID(device) == volumeID else { throw DiskError.diskChanged }
                results.append(FilesystemCheck(label: label, status: "Sorun bildirilmedi",
                                               detail: output, verified: true))
            } catch {
                guard registryID(disk.device) == disk.id else { throw DiskError.diskChanged }
                results.append(FilesystemCheck(label: label, status: "Denetim tamamlanamadı",
                                               detail: error.localizedDescription, verified: false))
            }
        }
        guard registryID(disk.device) == disk.id else { throw DiskError.diskChanged }
        guard !results.isEmpty else { throw DiskError.noVolumes }
        return results
    }

    private static func isAPFSStore(_ entry: Plist) -> Bool {
        let content = entry["Content"] as? String ?? ""
        return content.hasPrefix("Apple_APFS") || content == "7C3457EF-0000-11AA-AA11-00306543ECAC"
    }

    func erase(_ request: EraseRequest) throws {
        if let error = request.format.nameError(request.name) { throw DiskError.invalidName(error) }
        let disk = request.disk
        guard try !startupDisks().contains(disk.device) else { throw DiskError.startupDisk }
        let info = try currentInfo(for: disk)
        guard info["WritableMedia"] as? Bool == true else { throw DiskError.notWritable }
        _ = try run(["eraseDisk", request.format.rawValue, request.name, "GPT", "/dev/\(disk.device)"])
    }

    private func currentInfo(for disk: ExternalDisk) throws -> Plist {
        guard Self.isWholeIdentifier(disk.device),
              registryID(disk.device) == disk.id else { throw DiskError.diskChanged }
        let list = try plist(["list", "-plist", "external", "physical"])
        guard let external = list["WholeDisks"] as? [String], external.contains(disk.device) else {
            throw DiskError.diskChanged
        }
        let info = try plist(["info", "-plist", disk.device])
        guard isExternalWhole(info, device: disk.device),
              registryID(disk.device) == disk.id else { throw DiskError.diskChanged }
        return info
    }

    private func isExternalWhole(_ info: Plist, device: String) -> Bool {
        info["DeviceIdentifier"] as? String == device &&
        info["WholeDisk"] as? Bool == true &&
        info["Internal"] as? Bool == false &&
        info["VirtualOrPhysical"] as? String != "Virtual"
    }

    func startupDisks() throws -> Set<String> {
        let root = try plist(["info", "-plist", "/"])
        if root["APFSContainerReference"] is String || root["FilesystemType"] as? String == "apfs" {
            guard let stores = root["APFSPhysicalStores"] as? [Plist], !stores.isEmpty else {
                throw DiskError.invalidResponse
            }
            let parents = try stores.map { store in
                guard let device = store["APFSPhysicalStore"] as? String,
                      let parent = device.range(of: #"\Adisk[0-9]+(?=s[0-9]+\z|\z)"#, options: .regularExpression) else {
                    throw DiskError.invalidResponse
                }
                return String(device[parent])
            }
            return Set(parents)
        }
        guard let parent = root["ParentWholeDisk"] as? String, Self.isWholeIdentifier(parent) else {
            throw DiskError.invalidResponse
        }
        return [parent]
    }

    private func volumeNames(in entry: Plist, containers: [Plist]) -> [String] {
        let partitions = entry["Partitions"] as? [Plist] ?? []
        let identifiers = Set(partitions.compactMap { $0["DeviceIdentifier"] as? String })
        var names = ([entry] + partitions).compactMap { $0["VolumeName"] as? String }
        for container in containers {
            guard !identifiers.isDisjoint(with: physicalStores(in: container)) else { continue }
            let volumes = container["Volumes"] as? [Plist] ?? []
            names += volumes.compactMap { volume in
                let roles = volume["Roles"] as? [String] ?? []
                guard Set(roles).isDisjoint(with: ["Preboot", "Recovery", "VM", "Update"]) else { return nil }
                return volume["Name"] as? String
            }
        }
        return Array(Set(names.filter { !$0.isEmpty })).sorted()
    }

    private func physicalStores(in container: Plist) -> [String] {
        (container["PhysicalStores"] as? [Plist] ?? []).compactMap { $0["DeviceIdentifier"] as? String }
    }

    private func plist(_ args: [String]) throws -> Plist {
        guard let value = try PropertyListSerialization.propertyList(from: run(args), format: nil) as? Plist else {
            throw DiskError.invalidResponse
        }
        return value
    }

    static func isWholeIdentifier(_ value: String) -> Bool {
        value.range(of: #"\Adisk[0-9]+\z"#, options: .regularExpression) != nil
    }

    static func mediaID(_ device: String) -> UInt64? {
        let matching = device.withCString { IOBSDNameMatching(kIOMainPortDefault, 0, $0) }
        guard let matching else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard IOObjectConformsTo(service, kIOMediaClass) != 0 else { return nil }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    static func output(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func diskutil(_ args: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = output(data)
            throw DiskError.commandFailed(message.isEmpty ? "macOS işlemi tamamlayamadı." : message)
        }
        return data
    }
}

import AppKit
import CoreBluetooth
import IOKit

private let batteryService = CBUUID(string: "180F")
private let batteryLevel = CBUUID(string: "2A19")
private let refreshInterval: TimeInterval = 300
private let readingLifetime: TimeInterval = 900

final class BatteryApp: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var item: NSStatusItem!
    private var timer: Timer?
    private var scanTimer: Timer?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var readings: [UUID: (Int, Date)] = [:]
    private var deviceReadings: [String: Int] = [:]
    private var keyboardNames: Set<String> = []
    private var mouseNames: Set<String> = []
    private var messages: [UUID: String] = [:]
    private var status = "Looking for keyboards and mice…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        render()
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: refresh()
        case .unauthorized: status = "Allow Bluetooth access in System Settings → Privacy & Security → Bluetooth."
        case .poweredOff: status = "Turn on Bluetooth to read your devices’ batteries."
        case .unsupported: status = "Bluetooth Low Energy is unavailable on this Mac."
        default: status = "Waiting for Bluetooth…"
        }
        if central.state != .poweredOn { readings.removeAll() }
        render()
    }

    @objc func refresh() {
        deviceReadings = readDeviceBatteries()
        guard central.state == .poweredOn else { render(); return }
        let known = central.retrieveConnectedPeripherals(withServices: [batteryService, CBUUID(string: "1812")])
        for peripheral in known where isSupportedDevice(peripheral.name) { attach(peripheral) }
        for peripheral in peripherals.values where peripheral.state == .connected {
            if let service = peripheral.services?.first(where: { $0.uuid == batteryService }),
               let characteristic = service.characteristics?.first(where: { $0.uuid == batteryLevel }) {
                peripheral.readValue(for: characteristic)
            } else {
                peripheral.discoverServices([batteryService])
            }
        }
        central.stopScan()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.central.stopScan()
            if self.peripherals.isEmpty { self.status = "No keyboards or mice found. Wake them and check Bluetooth settings." }
            self.render()
        }
        render()
    }

    // Read values already maintained by macOS without communicating with devices.
    private func readDeviceBatteries() -> [String: Int] {
        var results: [String: Int] = [:]
        mouseNames.removeAll()
        keyboardNames.removeAll()
        for serviceClass in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let values = properties?.takeRetainedValue() as? [String: Any],
                   let name = (values["Product"] ?? values["ProductName"]) as? String {
                    let page = (values["PrimaryUsagePage"] as? NSNumber)?.intValue
                    let usage = (values["PrimaryUsage"] as? NSNumber)?.intValue
                    let pairs = values["DeviceUsagePairs"] as? [[String: Any]] ?? []
                    func hasUsage(_ target: Int) -> Bool {
                        (page == 1 && usage == target) || pairs.contains {
                            ($0["DeviceUsagePage"] as? NSNumber)?.intValue == 1 &&
                            ($0["DeviceUsage"] as? NSNumber)?.intValue == target
                        }
                    }
                    let isMouse = hasUsage(2)
                    let isKeyboard = hasUsage(6)
                    if isMouse || isKeyboard {
                        if isMouse { mouseNames.insert(name.lowercased()) }
                        if isKeyboard { keyboardNames.insert(name.lowercased()) }
                        for key in ["BatteryPercent", "BatteryPercentage", "BatteryLevel"] {
                            if let number = values[key] as? NSNumber, (0...100).contains(number.intValue) {
                                results[name] = number.intValue
                                break
                            }
                        }
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }
        return results
    }

    private func isMouse(_ name: String?) -> Bool {
        let name = (name ?? "").lowercased()
        return mouseNames.contains(name) || name.contains("mouse")
    }

    private func isSupportedDevice(_ name: String?) -> Bool {
        let name = (name ?? "").lowercased()
        return name.contains("keyboard") || name.contains("mouse") || name.contains("joro") || mouseNames.contains(name) || keyboardNames.contains(name)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isSupportedDevice(peripheral.name) || isSupportedDevice(advertisementData[CBAdvertisementDataLocalNameKey] as? String) else { return }
        attach(peripheral)
    }

    private func attach(_ peripheral: CBPeripheral) {
        guard peripherals[peripheral.identifier] == nil || peripheral.state == .disconnected else { return }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        messages[peripheral.identifier] = "Reading battery…"
        if peripheral.state == .connected { peripheral.discoverServices([batteryService]) }
        else if peripheral.state == .disconnected { central.connect(peripheral) }
        render()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        readings.removeValue(forKey: peripheral.identifier)
        messages[peripheral.identifier] = "Could not connect. Check Bluetooth settings and refresh."
        render()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        readings.removeValue(forKey: peripheral.identifier)
        messages[peripheral.identifier] = "Disconnected — wake the device and refresh."
        render()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == batteryService }) else {
            fail(peripheral, error?.localizedDescription ?? "This device does not expose the standard Bluetooth battery service.")
            return
        }
        peripheral.discoverCharacteristics([batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == batteryLevel }) else {
            fail(peripheral, error?.localizedDescription ?? "Battery level is unavailable from this device.")
            return
        }
        if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
        if characteristic.properties.contains(.notify) && !characteristic.isNotifying {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == batteryLevel else { return }
        guard error == nil, let data = characteristic.value, data.count == 1, let percent = data.first, percent <= 100 else {
            fail(peripheral, error?.localizedDescription ?? "The device returned an invalid battery reading.")
            return
        }
        readings[peripheral.identifier] = (Int(percent), Date())
        messages.removeValue(forKey: peripheral.identifier)
        render()
    }

    private func fail(_ peripheral: CBPeripheral, _ message: String) {
        readings.removeValue(forKey: peripheral.identifier)
        messages[peripheral.identifier] = message
        render()
    }

    private func render() {
        guard item != nil else { return }
        let devices = peripherals.values.sorted { ($0.name ?? "") < ($1.name ?? "") }
        let fresh = devices.compactMap { peripheral -> (CBPeripheral, Int)? in
            guard let (percent, date) = readings[peripheral.identifier], Date().timeIntervalSince(date) < readingLifetime else { return nil }
            return (peripheral, percent)
        }
        // Avoid displaying a device twice when both sources expose it.
        let registryDevices = deviceReadings.sorted { $0.key < $1.key }.filter { device in
            !fresh.contains { ($0.0.name ?? "").lowercased() == device.key.lowercased() }
        }
        let indicators = fresh.map { (name: $0.0.name ?? "", percent: $0.1, mouse: isMouse($0.0.name)) }
            + registryDevices.map { (name: $0.key, percent: $0.value, mouse: isMouse($0.key)) }
        let title = NSMutableAttributedString(string: "")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0)]
        for indicator in indicators {
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: attributes)) }
            let symbol = indicator.mouse ? "computermouse" : "keyboard"
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: indicator.mouse ? "Mouse" : "Keyboard") {
                let attachment = NSTextAttachment()
                attachment.image = image
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: " \(indicator.percent)%", attributes: attributes))
        }
        if indicators.isEmpty {
            if let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard") {
                let attachment = NSTextAttachment()
                attachment.image = image
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: " —", attributes: attributes))
        }
        item.button?.image = nil
        item.button?.attributedTitle = title
        let labels = fresh.map { "\($0.0.name ?? "Bluetooth device"): \($0.1)%" } + registryDevices.map { "\($0.key): \($0.value)%" }
        item.button?.toolTip = labels.isEmpty ? status : labels.joined(separator: " · ")
        let menu = NSMenu()
        add("KeyMouse", to: menu)
        menu.addItem(.separator())
        if peripherals.isEmpty && registryDevices.isEmpty { add(status, to: menu) }
        for device in registryDevices {
            add(device.key, to: menu)
            add("\(device.value)%", to: menu)
        }
        for peripheral in devices {
            add(peripheral.name ?? "Bluetooth device", to: menu)
            if let (percent, date) = readings[peripheral.identifier], Date().timeIntervalSince(date) < readingLifetime {
                add("\(percent)% · updated \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))", to: menu)
            } else { add(messages[peripheral.identifier] ?? "Reading is stale — refreshing…", to: menu) }
        }
        if central != nil && central.state != .poweredOn && !peripherals.isEmpty { add(status, to: menu) }
        menu.addItem(.separator())
        let refreshItem = menu.addItem(withTitle: "Refresh Battery", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        let settings = menu.addItem(withTitle: "Bluetooth Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit KeyMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    private func add(_ title: String, to menu: NSMenu) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        menu.addItem(entry)
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
}

let app = NSApplication.shared
let delegate = BatteryApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

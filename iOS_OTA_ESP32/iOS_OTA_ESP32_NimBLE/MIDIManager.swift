//
//  MIDIManager.swift
//  iOS_OTA_ESP32_NimBLE
//
//  Created by AI Assistant on 3/28/24.
//  License: MIT
//

import Foundation
import CoreMIDI

class MIDIManager: ObservableObject {

    @Published var midiDestinations: [(name: String, endpointRef: MIDIEndpointRef)] = []
    @Published var selectedMidiDestination: MIDIEndpointRef?
    @Published var midiDeviceName: String = ""
    @Published var midiConnected: Bool = false
    @Published var connectionStatusMessage: String = "Searching for device..."
    @Published var scanCount: Int = 0 // Add a counter to track number of scans
    @Published var dfuStatusPollAttempts: Int = 0 // Track number of DFU status poll attempts
    @Published var restartAttempts: Int = 0 // Track number of restart attempts
    @Published var dfuModeConfirmed: Bool = false {
        didSet {
            if dfuModeConfirmed {
                stopDfuStatusPolling()
                print("DFU mode confirmed, ready for BLE connection")
                // Reset restart attempts when DFU mode is confirmed
                restartAttempts = 0
            }
        }
    }
    @Published var dfuStatusMessage: String = "please wait..." // Status message for DFU mode
    
    // Constants
    private let maxDfuStatusPollAttempts = 7 // Maximum number of DFU status poll attempts before restarting
    private let maxRestartAttempts = 3 // Maximum number of restart attempts before giving up
    
    private var midiClient: MIDIClientRef = 0
    private var outputPort: MIDIPortRef = 0
    private var inputPort: MIDIPortRef = 0 // For receiving MIDI messages
    private var portScanTimer: Timer?
    private var dfuStatusPollTimer: Timer? // Timer for polling DFU status
    
    // Port names to search for - can be changed to match your devices
    private var portNames = ["XIAO_ESP32S3", "SWIFT"]
    
    enum HardwareStatus {
        case unknown
        case scanning
        case connected
        case disconnected
    }
    
    @Published var hardwareStatus: HardwareStatus = .unknown
    
    init() {
        setupMIDI()
        
        startPeriodicHardwareCheck()
        
        // Start DFU status polling if already connected
        if midiConnected {
            startDFUStatusPolling()
        }
        
        // Add observer for BLE device disconnections
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBLEDisconnection(_:)),
            name: Notification.Name("BLEDeviceDisconnected"),
            object: nil
        )
    }
    
    deinit {
        stopTimers()
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleBLEDisconnection(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let updateCompleted = userInfo["updateCompleted"] as? Bool else {
            return
        }
        
        if updateCompleted {
            print("Device disconnected after completing firmware update - resetting DFU mode")
            DispatchQueue.main.async {
                self.dfuModeConfirmed = false
                self.dfuStatusMessage = "Firmware update completed. Device restarting..."
                
                // Wait a few seconds before starting to scan for the device in normal mode
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    self.startPeriodicHardwareCheck()
                }
            }
        }
    }
    
    // MARK: - Setup
    
    private func setupMIDI() {
        MIDIClientCreate("OTA ESP32 MIDI Client" as CFString, nil, nil, &midiClient)
        MIDIOutputPortCreate(midiClient, "OTA ESP32 MIDI Output" as CFString, &outputPort)
        
        // Create an input port to listen for incoming MIDI messages
        MIDIInputPortCreate(midiClient, "OTA ESP32 MIDI Input" as CFString, midiReadProc, Unmanaged.passUnretained(self).toOpaque(), &inputPort)
        
        listAllMIDISources()
        fetchMIDIDestinations()
        connectToMIDISources()
    }
    
    // Connect to all available MIDI sources to listen for incoming messages
    private func connectToMIDISources() {
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            MIDIPortConnectSource(inputPort, source, nil)
            print("Connected to MIDI source: \(getMIDISourceName(source))")
        }
    }
    
    // Get the name of a MIDI source
    private func getMIDISourceName(_ source: MIDIEndpointRef) -> String {
        var property: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &property)
        return property?.takeRetainedValue() as String? ?? "Unknown"
    }
    
    // MIDI read callback function
    let midiReadProc: MIDIReadProc = { packetList, readProcRefCon, srcConnRefCon in
        let manager = Unmanaged<MIDIManager>.fromOpaque(readProcRefCon!).takeUnretainedValue()
        manager.processMIDIPacketList(packetList, src: srcConnRefCon)
    }
    
    // Process incoming MIDI packets
    private func processMIDIPacketList(_ packetList: UnsafePointer<MIDIPacketList>, src: UnsafeMutableRawPointer?) {
        let packetCount = packetList.pointee.numPackets
        var packet = packetList.pointee.packet
        
        for i in 0..<packetCount {
            // Debug raw packet data
            let rawStatusByte = packet.data.0
            let statusType = rawStatusByte & 0xF0  // Top 4 bits (message type)
            let channel = rawStatusByte & 0x0F     // Bottom 4 bits (channel)
            
            print("MIDI Packet \(i): Status: 0x\(String(rawStatusByte, radix: 16, uppercase: true)) (Type: 0x\(String(statusType, radix: 16, uppercase: true)), Channel: \(channel))")
            
            // Check if it's a Control Change message (0xB0)
            if statusType == MIDIConstants.controlChange {
                let controlNumber = packet.data.1
                let value = packet.data.2
                
                print("Received MIDI CC #\(controlNumber) with value \(value)")
                
                // Check if it's the DFU status CC
                if controlNumber == MIDIConstants.ControlNumber.dfuModeStatus.rawValue {
                    print("Processing DFU status update with value: \(value)")
                    handleDFUStatusUpdate(value)
                }
            }
            
            // Move to the next packet
            packet = MIDIPacketNext(&packet).pointee
        }
    }
    
    // Handle the DFU status update message
    private func handleDFUStatusUpdate(_ value: UInt8) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Reset poll attempts counter since we received a response
            self.dfuStatusPollAttempts = 0
            // Reset restart attempts counter since we received a response
            self.restartAttempts = 0
            
            print("Processing DFU status value: \(value) (hex: 0x\(String(value, radix: 16)))")
            
            // Store the raw value for reference
            let rawValue = value
            
            // Handle different status values
            switch rawValue {
            case 0:
                self.dfuStatusMessage = "SWIFT is in normal mode"
                self.dfuModeConfirmed = false
                self.hardwareStatus = self.midiConnected ? .connected : .disconnected
                print("Device confirmed normal mode operation")
            case 1:
                self.dfuStatusMessage = "DFU mode enabled but not active"
                self.dfuModeConfirmed = false
                print("Device reports DFU mode enabled but not active")
            case 6 ... 126:
                self.dfuStatusMessage = "SWIFT is in normal mode, running V\(Int(rawValue))"
                self.dfuModeConfirmed = false
                self.hardwareStatus = self.midiConnected ? .connected : .disconnected
                print("Device confirmed normal mode operation and version number")
            case 127:
                self.dfuStatusMessage = "SWIFT is in BLE DFU mode"
                self.dfuModeConfirmed = true
                print("Device confirmed DFU mode active and ready for firmware update")
            default:
                self.dfuStatusMessage = "Unknown status code: \(rawValue)"
                print("Device returned unexpected DFU status code: \(rawValue)")
            }
            
            print("DFU Status Update: \(self.dfuStatusMessage)")
            self.updateConnectionStatus()   
        }
    }
    
    private func listAllMIDISources() {
        let sourceCount = MIDIGetNumberOfSources()
        let destCount = MIDIGetNumberOfDestinations()
        
        print("==== MIDI System Information ====")
        print("Total MIDI sources: \(sourceCount)")
        print("Total MIDI destinations: \(destCount)")
        
        if sourceCount > 0 {
            print("Available MIDI sources:")
            for i in 0..<sourceCount {
                let source = MIDIGetSource(i)
                var property: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &property)
                let name = property?.takeRetainedValue() as String? ?? "Unknown"
                print("  - \(name) (index: \(i))")
            }
        }
        
        if destCount > 0 {
            print("Available MIDI destinations:")
            for i in 0..<destCount {
                let dest = MIDIGetDestination(i)
                var property: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(dest, kMIDIPropertyDisplayName, &property)
                let name = property?.takeRetainedValue() as String? ?? "Unknown"
                print("  - \(name) (index: \(i))")
            }
        }
        
        print("==== End MIDI System Information ====")
    }
    
    // MARK: - MIDI Destination Management
    
    func fetchMIDIDestinations() {
        let count = MIDIGetNumberOfDestinations()
        var destinations: [(name: String, endpointRef: MIDIEndpointRef)] = []
        
        for i in 0..<count {
            let destination = MIDIGetDestination(i)
            var property: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(destination, kMIDIPropertyDisplayName, &property)
            let name = property?.takeRetainedValue() as String? ?? "Unknown"
            destinations.append((name: name, endpointRef: destination))
        }
        
        DispatchQueue.main.async {
            self.midiDestinations = destinations
            self.updateConnectionStatus()
        }
    }
    
    private func scanForPort() {
        scanCount += 1
        print("MIDI Scan #\(scanCount) - Available MIDI destinations: \(midiDestinations.map { $0.name })")
        print("Searching for ports containing any of: \(portNames.joined(separator: ", "))")
        
        // Try to find a port that matches any of our desired port names
        let matchingPort = midiDestinations.first { destination in
            for portName in portNames {
                if destination.name.contains(portName) {
                    return true
                }
            }
            return false
        }
        
        if let matchingPort = matchingPort {
            print("Found matching port: \(matchingPort.name)")
            selectedMidiDestination = matchingPort.endpointRef
            midiDeviceName = matchingPort.name
            midiConnected = true
            hardwareStatus = .connected
        } else {
            print("No matching port found. Will retry in 2 seconds...")
            midiDeviceName = ""
            midiConnected = false
            hardwareStatus = .disconnected
        }
        
        updateConnectionStatus()
    }
    
    func startPeriodicHardwareCheck() {
        // Initial check
        checkHardwareConnection()
        
        // Stop any existing timer
        stopTimers()
        
        // Schedule periodic checks - make sure it runs on the main thread
        DispatchQueue.main.async {
            self.portScanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self = self else {
                    print("Self is nil, timer will be invalidated")
                    timer.invalidate()
                    return
                }
                self.checkHardwareConnection()
            }
            
            // Make sure the timer continues to fire when scrolling
            RunLoop.current.add(self.portScanTimer!, forMode: .common)
        }
    }
    
    func checkHardwareConnection() {
        // Fetch available MIDI destinations
        fetchMIDIDestinations()
        
        // Don't change status if already in DFU mode
        if dfuModeConfirmed {
            return
        }
        
        // Check if any of our devices are connected
        let isDeviceConnected = midiDestinations.contains { destination in
            for portName in portNames {
                if destination.name.contains(portName) {
                    return true
                }
            }
            return false
        }
        
        // Handle device connection state changes
        if isDeviceConnected {
            // Device is connected
            if hardwareStatus != .connected {
                // Device just became connected (either new connection or reconnection)
                if let matchingPort = midiDestinations.first(where: { destination in
                    for portName in portNames {
                        if destination.name.contains(portName) {
                            return true
                        }
                    }
                    return false
                }) {
                    // Found a matching device
                    print("Device Connected")
                    selectedMidiDestination = matchingPort.endpointRef
                    midiDeviceName = matchingPort.name
                    midiConnected = true
                    
                    // Only reset status message if we're transitioning from disconnected
                    if hardwareStatus == .disconnected {
                        dfuStatusMessage = "Checking status...please wait..."
                    }
                    
                    hardwareStatus = .connected
                    
                    // Start polling for DFU status when connected
                    //startDFUStatusPolling()
                }
            }
            // If already connected, we still need to start polling in case an update just finished, we want to show the successful result
            startDFUStatusPolling()
        } else {
            // Device is disconnected
            if hardwareStatus == .connected || hardwareStatus == .scanning {
                // Device was previously connected and is now disconnected
                dfuStatusMessage = "device disconnected"
                print("Device Disconnected")
                selectedMidiDestination = nil
                midiDeviceName = ""
                midiConnected = false
                hardwareStatus = .disconnected
                dfuModeConfirmed = false  // Reset DFU mode flag when disconnected
            }
            
            // Always try to reconnect when not connected
            scanForPort()
        }
        
        updateConnectionStatus()
    }
    
    private func updateConnectionStatus() {
        switch hardwareStatus {
        case .unknown:
            connectionStatusMessage = "Initializing..."
        case .scanning:
            connectionStatusMessage = "Searching for device... (Scan #\(scanCount))"
        case .connected:
            connectionStatusMessage = "Connected to \(midiDeviceName) via USB"
        case .disconnected:
            connectionStatusMessage = "Searching for SWIFT USB connection..."
        }
    }
    
    private func stopTimers() {
        if portScanTimer != nil {
            print("Stopping existing MIDI scan timer")
            portScanTimer?.invalidate()
            portScanTimer = nil
        }
        
        if dfuStatusPollTimer != nil {
            print("Stopping DFU status poll timer")
            dfuStatusPollTimer?.invalidate()
            dfuStatusPollTimer = nil
        }
    }
    
    // MARK: - Send MIDI Messages
    
    func sendFirmwareUpdateMode() {
        print("Sending firmware update mode command")
        let midiValue: UInt8 = 1
        let message = MIDIMessage(controlNumber: .dfuModeEnable, value: midiValue)
        sendMIDIMessage(message)
        
        // Start polling for status updates after sending the command
        startDFUStatusPolling()
    }
    
    func pollDFUStatus() {
        // Increment poll attempts counter
        dfuStatusPollAttempts += 1
        print("Polling device DFU status (attempt \(dfuStatusPollAttempts))")
        
        // Check if we've reached the maximum number of attempts
        if dfuStatusPollAttempts >= maxDfuStatusPollAttempts {
            print("Maximum DFU status poll attempts (\(maxDfuStatusPollAttempts)) reached without response. Restarting device...")
            // Calculate the next restart attempt number (current + 1)
            let nextRestartAttempt = restartAttempts + 1
            dfuStatusMessage = "No response, attempting restart \(nextRestartAttempt) of \(maxRestartAttempts - 1)..."
            restartSWIFT()
            
            // Reset the counter after attempting restart
            dfuStatusPollAttempts = 0
            return
        }
        
        let message = MIDIMessage(controlNumber: .dfuModeStatus, value: 0) // Value doesn't matter for status requests
        sendMIDIMessage(message)
    }
    
    func restartSWIFT() {
        restartAttempts += 1
        print("Sending restart command to SWIFT (attempt \(restartAttempts))")
        
        // Check if we've reached the maximum restart attempts
        if restartAttempts >= maxRestartAttempts {
            print("Maximum restart attempts (\(maxRestartAttempts)) reached. Stopping restart attempts.")
            dfuStatusMessage = "Please disconnect and reconnect SWIFT"
            // Stop polling to prevent further restart attempts
            stopDfuStatusPolling()
            return
        }
        
        let message = MIDIMessage(controlNumber: .swiftRestart, value: 0) // Value doesn't matter for reboot request
        sendMIDIMessage(message)
        
        // Reset the status message after attempting restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.dfuStatusMessage = "Checking status...please wait..."
        }
    }
    
    private func sendMIDIMessage(_ message: MIDIMessage) {
        guard let destination = selectedMidiDestination else {
            print("MIDI destination not found or not selected.")
            return
        }
        
        var packet = MIDIPacket()
        packet.timeStamp = 0
        packet.length = 3
        
        let midiBytes = message.bytes
        packet.data.0 = midiBytes[0]
        packet.data.1 = midiBytes[1]
        packet.data.2 = midiBytes[2]
        
        var packetList = MIDIPacketList(numPackets: 1, packet: packet)
        MIDISend(outputPort, destination, &packetList)
        
        print("Sent MIDI message: CC #\(midiBytes[1]) value \(midiBytes[2]) to \(midiDeviceName)")
    }
    
    // Helper structure
    private struct MIDIMessage {
        let controlNumber: MIDIConstants.ControlNumber
        let value: UInt8
        
        var bytes: [UInt8] {
            [MIDIConstants.controlChange, controlNumber.rawValue, value]
        }
    }
    
    // MIDI Constants
    private enum MIDIConstants {
        static let controlChange: UInt8 = 0xB0  // Control Change on channel 1 (0xB0-0xBF for channels 1-16)
        
        // Function to check if a status byte is a Control Change message on any channel
        static func isControlChange(_ status: UInt8) -> Bool {
            return (status & 0xF0) == 0xB0  // Check only the top 4 bits
        }
        
        enum ControlNumber: UInt8 {
            case dfuModeStatus = 0x5A       // CC#90 (0x5A in hex) for DFU mode status feedback
            case dfuModeEnable = 0x5B       // CC#91 (0x5B in hex) to enable DFU mode
            case swiftRestart = 0x13        // CC#19 (0x13 in hex) to reboot SWIFT when in normal mode
        }
    }
    
    // Start polling for DFU status when device is connected via USB
    func startDFUStatusPolling() {
        // Stop any existing timer
        if dfuStatusPollTimer != nil {
            dfuStatusPollTimer?.invalidate()
            dfuStatusPollTimer = nil
        }
        
        // Only start polling if we're connected
        guard midiConnected else {
            print("Cannot start DFU status polling: device not connected")
            return
        }
        
        //print("Starting DFU status polling timer")
        
        // Create a timer that polls every 3 seconds
        dfuStatusPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.midiConnected {
                self.pollDFUStatus()
            }
        }
        
        // Make sure the timer continues to fire when scrolling
        if let timer = dfuStatusPollTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        // Poll immediately without waiting for the timer
        pollDFUStatus()
    }

    private func stopDfuStatusPolling() {
        dfuStatusPollTimer?.invalidate()
        dfuStatusPollTimer = nil
    }
} 

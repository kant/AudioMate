//
//  StatusBarViewController.swift
//  AudioMate
//
//  Created by Ruben Nine on 22/01/16.
//  Copyright © 2016 Ruben Nine. All rights reserved.
//

import Cocoa
import AMCoreAudio
import ReactiveKit

private var kPreferencesSeparator = 1000
private var kDeviceMasterInputVolumeControlMenuItem = 1001
private var kDeviceMasterOutputVolumeControlMenuItem = 1002

enum StatusBarViewLayoutType: Int, RawRepresentable {

    case none = 0
    case sampleRate = 1
    case sampleRateAndClockSource = 2
    case masterVolumeDecibels = 3
    case masterVolumePercent = 4
    case masterVolumeGraphic = 5
}


class StatusBarViewController: NSViewController {

    private var audioDevices = [AudioDevice]()

    private var sortedAudioDevices: [AudioDevice] {

        return self.audioDevices.sorted { $0.name < $1.name }
    }

    private let mainMenu = NSMenu()

    weak var statusItem: NSStatusItem? {

        didSet {
            statusItem?.menu = mainMenu
            statusItem?.button?.addSubview(view)
            statusItem?.button?.target = self
            statusItem?.button?.action = #selector(statusItemButtonPressed(_:))

            DispatchQueue.main.async {
                self.updateStatusBarView()
            }
        }
    }

    fileprivate var statusBarView: StatusBarView {
        return view as! StatusBarView
    }

    private var effectiveLayoutType: StatusBarViewLayoutType?
    fileprivate let disposeBag = DisposeBag()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Set mainMenu delegate
        mainMenu.delegate = self

        let preferencesSeparatorItem = NSMenuItem.separator()
        preferencesSeparatorItem.tag = kPreferencesSeparator

        mainMenu.addItem(preferencesSeparatorItem)

        let preferencesMenuItem = NSMenuItem()

        preferencesMenuItem.title = NSLocalizedString("Preferences…", comment: "")
        preferencesMenuItem.target = self
        preferencesMenuItem.action = #selector(showPreferences(_:))
        preferencesMenuItem.keyEquivalent = ","
        preferencesMenuItem.keyEquivalentModifierMask = NSEventModifierFlags.command

        mainMenu.addItem(preferencesMenuItem)
        mainMenu.addItem(NSMenuItem.separator())

        let quitMenuItem = NSMenuItem()

        quitMenuItem.title = NSLocalizedString("Quit AudioMate", comment: "")
        quitMenuItem.target = NSApp
        quitMenuItem.action = #selector(NSApp.terminate(_:))
        quitMenuItem.keyEquivalent = "q"
        quitMenuItem.keyEquivalentModifierMask = NSEventModifierFlags.command

        mainMenu.addItem(quitMenuItem)

        // Observe changes to layout type preference and react accordingly
        prefs.general.layoutType.observeOn(.main).observeNext { (value) in
            self.updateStatusBarView()
        }.disposeIn(disposeBag)

        // Observe changes to featured device preference and react accordingly
        prefs.general.featuredDevice.observeOn(.main).observeNext { (value) in
            self.updateStatusBarView()
        }.disposeIn(disposeBag)

        // Subscribe to events
        NotificationCenter.defaultCenter.subscribe(self, eventType: AudioHardwareEvent.self, dispatchQueue: .main)
        NotificationCenter.defaultCenter.subscribe(self, eventType: AudioDeviceEvent.self, dispatchQueue: .main)
    }

    override func viewWillLayout() {

        super.viewWillLayout()

        let padding: CGFloat = 10.0 // 10px padding
        let fittingWidthWithPadding = round(view.fittingSize.width + padding)

        view.frame.size = NSSize(width: fittingWidthWithPadding, height: statusBarView.frame.height)

        if !view.isHidden {
            statusItem?.length = NSWidth(statusBarView.frame)
        }
    }

    override func prepare(for segue: NSStoryboardSegue, sender: Any?) {

        guard let identifier = segue.identifier else { return }

        switch identifier {
        case "showPreferences":

            statusItem?.button?.isEnabled = false
            statusBarView.isEnabled = false

            if let wc = segue.destinationController as? PreferencesWindowController {
                wc.windowDidCloseHandler = { [unowned self] in
                    self.statusItem?.button?.isEnabled = true
                    self.statusBarView.isEnabled = true
                }
            }

        default:

            break

        }

        super.prepare(for: segue, sender: sender)
    }

    deinit {

        // Unsubscribe from events
        NotificationCenter.defaultCenter.unsubscribe(self, eventType: AudioHardwareEvent.self)
        NotificationCenter.defaultCenter.unsubscribe(self, eventType: AudioDeviceEvent.self)
    }

    // MARK: - Public Functions

    func addDevice(device: AudioDevice) {

        log.debug("Adding \(device) to menu.")

        audioDevices.append(device)

        // Create menu item for device with submenu
        let menuItem = NSMenuItem()

        menuItem.attributedTitle = attributedString(device: device)
        menuItem.image = transportTypeImage(device: device)
        menuItem.representedObject = device

        buildSubmenu(menuItem: menuItem)

        // Insert menu item keeping the alphabetic order
        let devicesInMenu = mainMenu.items.map { $0.representedObject as? AudioDevice }

        for (idx, item) in devicesInMenu.enumerated() {

            if item == nil {
                // Usually this means:
                //  (1) there's no devices in the menu
                //  (2) we already iterated thru all of them
                // ... so we will place the item at the current idx position and break the loop.
                mainMenu.insertItem(menuItem, at: idx)
                break
            }

            if let item = item, device.name <= item.name {
                mainMenu.insertItem(menuItem, at: idx)
                break
            }
        }

        // Force menu update
        mainMenu.perform(#selector(NSMenu.update),
                         with: nil,
                         afterDelay: 0.15,
                         inModes: [RunLoopMode.eventTrackingRunLoopMode])
    }

    func removeDevice(device: AudioDevice) {

        log.debug("Removing \(device) from menu.")

        // Remove device menu item from menu
        if let deviceMenuItem = menuItem(device: device) {
            mainMenu.removeItem(deviceMenuItem)
        }

        // Remove device from device list
        if let idx = audioDevices.index(of: device) {
            audioDevices.remove(at: idx)
        }
    }

    // MARK: - Private Functions

    fileprivate func updateStatusBarView() {

        let featuredDevice = prefs.general.featuredDevice.value.device
        let layoutType = featuredDevice?.isAlive() == true ? prefs.general.layoutType.value : .none
        let subView = statusBarView.subView()

        // Common for all layouts except .None
        if layoutType != .none {
            statusBarView.isHidden = false
            statusItem?.button?.image = nil
        }

        if effectiveLayoutType == layoutType {
            subView?.updateUI()
        } else {
            statusItem?.length = NSVariableStatusItemLength

            switch layoutType {
            case .sampleRate:

                if subView as? SampleRateStatusBarView == nil {
                    statusBarView.setSubView(subView: SampleRateStatusBarView(forAutoLayout: ()))
                }

            case .sampleRateAndClockSource:

                if subView as? SampleRateAndClockSourceStatusBarView == nil {
                    statusBarView.setSubView(subView: SampleRateAndClockSourceStatusBarView(forAutoLayout: ()))
                }

            case .masterVolumeDecibels:

                if subView as? MasterVolumeDecibelStatusBarView == nil {
                    statusBarView.setSubView(subView: MasterVolumeDecibelStatusBarView(forAutoLayout: ()))
                }

            case .masterVolumePercent:

                if subView as? MasterVolumePercentStatusBarView == nil {
                    statusBarView.setSubView(subView: MasterVolumePercentStatusBarView(forAutoLayout: ()))
                }

            case .masterVolumeGraphic:

                if subView as? MasterVolumeGraphicStatusBarView == nil {
                    statusBarView.setSubView(subView: MasterVolumeGraphicStatusBarView(forAutoLayout: ()))
                }

            case .none:

                statusItem?.length = NSVariableStatusItemLength
                statusBarView.isHidden = true
                statusItem?.button?.image = NSImage(named: "Mini AudioMate")
            }

            effectiveLayoutType = layoutType
        }

        if var subView = statusBarView.subView() {
            if layoutType == .none {
                subView.representedObject = nil
            } else {
                // Update subview represented object
                subView.representedObject = featuredDevice
                // Update statusbar view tooltip
                if let deviceName = featuredDevice?.name {
                    statusBarView.toolTip = String(format: NSLocalizedString("%@ is the device currently being displayed", comment: ""), deviceName)
                } else {
                    statusBarView.toolTip = nil
                }
            }
        }

        view.needsLayout = true
    }

    fileprivate func menuItem(device: AudioDevice) -> NSMenuItem? {

        return (mainMenu.items.filter { ($0.representedObject as? AudioDevice) == device }).first
    }

    private func buildVolumeControlMenuItem(item: NSMenuItem, direction: AMCoreAudio.Direction) {

        guard let device = item.representedObject as? AudioDevice else { return }

        if let volumeControlView = (item.view as? VolumeControlMenuItemView) ?? (instantiateViewFromNibNamed(nibName: "VolumeControlMenuItemView") as? VolumeControlMenuItemView) {
            // Set volume slide ranges
            volumeControlView.volumeSlider.minValue = 0.0
            volumeControlView.volumeSlider.maxValue = 1.0

            // Set input volume slider and mute checkbox values
            if let volume = device.virtualMasterVolume(direction: direction) {
                let volumeSliderAction = direction == .Playback ? #selector(updateOutputVolume(_:)) : #selector(updateInputVolume(_:))

                volumeControlView.volumeSlider.isEnabled = true
                volumeControlView.volumeSlider.isContinuous = true
                volumeControlView.volumeSlider.tag = Int(device.id)
                volumeControlView.volumeSlider.floatValue = volume
                volumeControlView.volumeSlider.target = self
                volumeControlView.volumeSlider.action = volumeSliderAction

                let volumeMuteAction = direction == .Playback ? #selector(updateOutputMute(_:)) : #selector(updateInputMute(_:))

                volumeControlView.muteCheckbox.isEnabled = true
                volumeControlView.muteCheckbox.state = device.isMasterChannelMuted(direction: direction) ?? false ? NSOnState : NSOffState
                volumeControlView.muteCheckbox.tag = Int(device.id)
                volumeControlView.muteCheckbox.target = self
                volumeControlView.muteCheckbox.action = volumeMuteAction
            } else {
                volumeControlView.volumeSlider.isEnabled = false
                volumeControlView.volumeSlider.floatValue = 1.0
                volumeControlView.muteCheckbox.isEnabled = false
                volumeControlView.muteCheckbox.state = NSOffState
            }

            item.view = volumeControlView
        }
    }

    private func buildSubmenu(menuItem: NSMenuItem) {

        guard let device = menuItem.representedObject as? AudioDevice else { return }

        // Create submenu
        menuItem.submenu = NSMenu()
        menuItem.submenu?.autoenablesItems = false

        // Create `Set sample rate` item and submenu
        let sampleRateItem = NSMenuItem(title: NSLocalizedString("Set sample rate", comment: ""),
                                        action: nil,
                                        keyEquivalent: "")

        sampleRateItem.submenu = NSMenu()
        sampleRateItem.submenu?.autoenablesItems = false

        if let sampleRates = device.nominalSampleRates(), sampleRates.count > 0 {
            for sampleRate in sampleRates {
                let item = NSMenuItem(title: device.nominalSampleRate()?.string(as: .sampleRate) ?? "N/A",
                                      action: #selector(updateSampleRate(_:)),
                                      keyEquivalent: "")

                item.isEnabled = device.nominalSampleRate() != sampleRate
                item.state = !item.isEnabled ? NSOnState : NSOffState
                item.tag = Int(device.id)
                item.representedObject = sampleRate
                item.target = self

                sampleRateItem.submenu?.addItem(item)
            }
        } else {
            let unsupportedItem = NSMenuItem()

            unsupportedItem.title = NSLocalizedString("Unsupported", comment: "")
            unsupportedItem.isEnabled = false

            sampleRateItem.submenu?.addItem(unsupportedItem)
        }

        menuItem.submenu?.addItem(sampleRateItem)

        // Create `Set clock source` item and submenu
        let clockSourceItem = NSMenuItem(title: NSLocalizedString("Set clock source", comment: ""),
                                         action: nil,
                                         keyEquivalent: "")

        clockSourceItem.submenu = NSMenu()
        clockSourceItem.submenu?.autoenablesItems = false

        if let clockSourceIDs = device.clockSourceIDs(channel: 0, direction: .Playback) {
            let activeClockSourceID = device.clockSourceID(channel: 0, direction: .Playback)

            for clockSourceID in clockSourceIDs {
                if let clockSourceName = device.clockSourceName(clockSourceID: clockSourceID) {
                    let item = NSMenuItem(title: clockSourceName,
                                          action: #selector(updateClockSource(_:)),
                                          keyEquivalent: "")

                    item.isEnabled = clockSourceID != activeClockSourceID
                    item.state = item.isEnabled == false ? NSOnState : NSOffState
                    item.tag = Int(device.id)
                    item.representedObject = UInt(clockSourceID)
                    item.target = self

                    clockSourceItem.submenu?.addItem(item)
                }
            }
        } else {
            let internalClockItem = NSMenuItem(title: NSLocalizedString("Internal Clock", comment: ""), action: nil, keyEquivalent: "")
            internalClockItem.isEnabled = false
            clockSourceItem.submenu?.addItem(internalClockItem)
        }

        menuItem.submenu?.addItem(clockSourceItem)

        // Add separator item
        menuItem.submenu?.addItem(NSMenuItem.separator())

        if device.canSetVirtualMasterVolume(direction: .Recording) {
            // Create master input volume control menu item
            let inputVolumeControlMenuItem = NSMenuItem()
            inputVolumeControlMenuItem.representedObject = device
            inputVolumeControlMenuItem.tag = kDeviceMasterInputVolumeControlMenuItem

            buildVolumeControlMenuItem(item: inputVolumeControlMenuItem, direction: .Recording)
            menuItem.submenu?.addItem(inputVolumeControlMenuItem)
        }

        if device.canSetVirtualMasterVolume(direction: .Playback) {
            // Create master input volume control menu item
            let outputVolumeControlMenuItem = NSMenuItem()
            outputVolumeControlMenuItem.representedObject = device
            outputVolumeControlMenuItem.tag = kDeviceMasterOutputVolumeControlMenuItem

            buildVolumeControlMenuItem(item: outputVolumeControlMenuItem, direction: .Playback)
            menuItem.submenu?.addItem(outputVolumeControlMenuItem)
        }

        if device.canSetVirtualMasterVolume(direction: .Playback) || device.canSetVirtualMasterVolume(direction: .Recording) {
            // Add separator item
            menuItem.submenu?.addItem(NSMenuItem.separator())
        }

        // Add separator item
        menuItem.submenu?.addItem(NSMenuItem.separator())

        // Add menu items that allow changing the default output, system output, and input device.
        // Only the options that make sense for each device are added here.
        if device.channels(direction: .Playback) > 0 {
            let useForSoundOutputItem = NSMenuItem(title: NSLocalizedString("Use this device for sound output", comment: ""),
                                                   action: #selector(updateDefaultOutputDevice(_:)),
                                                   keyEquivalent: "")

            useForSoundOutputItem.image = NSImage(named: "DefaultOutput")
            useForSoundOutputItem.target = self

            if AudioDevice.defaultOutputDevice()?.id == device.id {
                useForSoundOutputItem.isEnabled = false
                useForSoundOutputItem.state = NSOnState
            } else {
                useForSoundOutputItem.tag = Int(device.id)
            }

            menuItem.submenu?.addItem(useForSoundOutputItem)

            let useForSystemOutputItem = NSMenuItem(title: NSLocalizedString("Play alerts and sound effects through this device", comment: ""),
                                                    action: #selector(updateDefaultSystemOutputDevice(_:)),
                                                    keyEquivalent: "")

            useForSystemOutputItem.image = NSImage(named: "SystemOutput")
            useForSystemOutputItem.target = self

            if AudioDevice.defaultSystemOutputDevice()?.id == device.id {
                useForSystemOutputItem.isEnabled = false
                useForSystemOutputItem.state = NSOnState
            } else {
                useForSystemOutputItem.tag = Int(device.id)
            }

            menuItem.submenu?.addItem(useForSystemOutputItem)
        } else if device.channels(direction: .Recording) > 0 {
            let useForSoundInputItem = NSMenuItem(title: NSLocalizedString("Use this device for sound input", comment: ""),
                                                  action: #selector(updateDefaultInputDevice(_:)),
                                                  keyEquivalent: "")

            useForSoundInputItem.image = NSImage(named: "DefaultInput")
            useForSoundInputItem.target = self

            if AudioDevice.defaultInputDevice()?.id == device.id {
                useForSoundInputItem.isEnabled = false
                useForSoundInputItem.state = NSOnState
            } else {
                useForSoundInputItem.tag = Int(device.id)
            }

            menuItem.submenu?.addItem(useForSoundInputItem)
        }

        // Add separator item
        menuItem.submenu?.addItem(NSMenuItem.separator())

        // Add `Set as featured device` item
        let featuredDeviceMenuItem = NSMenuItem()

        if prefs.general.featuredDevice.value.device != device {
            featuredDeviceMenuItem.title = NSLocalizedString("Set as featured device", comment: "")
            featuredDeviceMenuItem.tag = Int(device.id)
        } else {
            featuredDeviceMenuItem.title = NSLocalizedString("Stop being the featured device", comment: "")
            featuredDeviceMenuItem.tag = 0
        }

        featuredDeviceMenuItem.target = self
        featuredDeviceMenuItem.action = #selector(updateFeaturedDevice(_:))

        menuItem.submenu?.addItem(featuredDeviceMenuItem)

        // Add separator item
        menuItem.submenu?.addItem(NSMenuItem.separator())

        // Add `Configure Actions…` item
        let configureActionsMenuItem = NSMenuItem()

        configureActionsMenuItem.title = NSLocalizedString("Configure device actions…", comment: "")
        configureActionsMenuItem.target = self
        configureActionsMenuItem.action = #selector(showDeviceActions(_:))

        menuItem.submenu?.addItem(configureActionsMenuItem)

        // Update master volume menu items
        updateMasterVolume(menuItem: menuItem, direction: .Recording)
        updateMasterVolume(menuItem: menuItem, direction: .Playback)
    }

    fileprivate func updateMasterVolume(menuItem: NSMenuItem, direction: Direction) {
        if let device = menuItem.representedObject as? AudioDevice {
            let menuItemControlTag: Int

            switch direction {
            case .Recording:
                menuItemControlTag = kDeviceMasterInputVolumeControlMenuItem
            case .Playback:
                menuItemControlTag = kDeviceMasterOutputVolumeControlMenuItem
            default:
                menuItemControlTag = 0
            }

            if let volumeControlMenuItem = menuItem.submenu?.item(withTag: menuItemControlTag),
                   let view = volumeControlMenuItem.view as? VolumeControlMenuItemView,
                   let volume = device.virtualMasterVolume(direction: direction) {
                let formatString: String
                let dBValue = device.virtualMasterVolumeInDecibels(direction: direction) ?? 0.0

                switch direction {
                case .Recording:

                    formatString = NSLocalizedString("Master Input Volume is %.1fdBFS", comment: "")

                case .Playback:

                    formatString = NSLocalizedString("Master Output Volume is %.1fdBFS", comment: "")

                default:

                    formatString = "%.1fdBFS"

                }

                view.volumeLabel.stringValue = String(format: formatString, dBValue)
                view.volumeSlider.floatValue = volume
                view.muteCheckbox.state = (device.isMuted(channel: 0, direction: direction) ?? false) ? NSOnState : NSOffState
            }
        }
    }

    private func attributedString(device: AudioDevice) -> NSAttributedString {

        let font = NSFont.menuBarFont(ofSize: 14.0)
        let attrs = [NSFontAttributeName: font]
        let attrString = NSMutableAttributedString(string: device.name, attributes: attrs)

        // Formatted sample rate and clock source
        let formattedSampleRate = device.nominalSampleRate()?.string(as: .sampleRate) ?? "N/A"
        let formattedClockSource = device.clockSourceName(channel: 0, direction: .Playback) ?? NSLocalizedString("Internal Clock", comment: "")

        // Formatted input and output channels
        let inChannels = device.channels(direction: .Recording) 
        let outChannels = device.channels(direction: .Playback)

        let formatedInputChannels = String(format:inChannels == 1 ? NSLocalizedString("%d in", comment: "") : NSLocalizedString("%d ins", comment: ""), inChannels)
        let formatedOutputChannels = String(format:outChannels == 1 ? NSLocalizedString("%d out", comment: "") : NSLocalizedString("%d outs", comment: ""), outChannels)

        let font2 = NSFont.menuFont(ofSize: NSFont.labelFontSize())
        let attrs2 = [NSFontAttributeName: font2, NSForegroundColorAttributeName: NSColor.secondaryLabelColor]
        let attrStringLine2 = NSMutableAttributedString(string: "\n\(formattedSampleRate) / \(formattedClockSource)\n\(formatedInputChannels)/ \(formatedOutputChannels)", attributes: attrs2)

        attrString.append(attrStringLine2)

        return attrString.copy() as! NSAttributedString
    }

    fileprivate func updateDeviceMenuItem(device: AudioDevice) {

        if let menuItem = menuItem(device: device) {
            menuItem.attributedTitle = attributedString(device: device)
            menuItem.image = transportTypeImage(device: device)

            buildSubmenu(menuItem: menuItem)
        }
    }
    
    fileprivate func updateDeviceMenuItems() {

        for audioDevice in audioDevices {
            updateDeviceMenuItem(device: audioDevice)
        }
    }

    private func instantiateViewFromNibNamed(nibName: String) -> NSView? {

        var topLevelObjects: NSArray = NSArray()
        Bundle.main.loadNibNamed(nibName, owner: self, topLevelObjects: &topLevelObjects)

        for object in topLevelObjects {
            if let view = object as? NSView {
                return view
            }
        }

        return nil
    }

    private func transportTypeImage(device: AudioDevice) -> NSImage {

        if let transportType = device.transportType {
            let outChannels = device.channels(direction: .Playback)
            let inChannels = device.channels(direction: .Recording)

            switch transportType {
            case .BuiltIn:

                if outChannels > 0 && inChannels == 0 {
                    return NSImage(named: "SpeakerIcon")!
                } else if inChannels > 0 && outChannels == 0 {
                    return NSImage(named: "Microphone")!
                } else {
                    return NSImage(named: "Built-in")!
                }

            case .Aggregate:

                return NSImage(named: "Aggregate")!

            case .Virtual:

                return NSImage(named: "Virtual")!

            case .PCI:

                return NSImage(named: "PCI")!

            case .USB:

                return NSImage(named: "USB")!

            case .FireWire:

                return NSImage(named: "FireWire")!

            case .Bluetooth:

                fallthrough

            case .BluetoothLE:

                return NSImage(named: "Bluetooth")!

            case .HDMI:

                return NSImage(named: "HDMI")!

            case .DisplayPort:

                return NSImage(named: "DisplayPort")!

            case .AirPlay:

                return NSImage(named: "Airplay")!

            case .AVB:

                return NSImage(named: "AVBHeader")!

            case .Thunderbolt:

                return NSImage(named: "Thunderbolt")!

            default:

                break

            }
        }

        return NSImage(named: "Unknown")!
    }

    // MARK: - Actions

    @IBAction func statusItemButtonPressed(_ sender: AnyObject) {

        if let button = sender as? NSButton {
            statusBarView.isEnabled = button.isEnabled
        }
    }

    @IBAction func showPreferences(_ sender: AnyObject) {

        performSegue(withIdentifier: "showPreferences", sender: self)
    }

    @IBAction func showDeviceActions(_ sender: AnyObject) {

        log.debug("TODO: Implement")
    }

    @IBAction func updateInputVolume(_ sender: AnyObject) {

        if let slider = sender as? NSSlider {
            let device = AudioDevice.lookupByID(AudioObjectID(slider.tag))
            device?.setVirtualMasterVolume(Float32(slider.floatValue), direction: .Recording)
        }
    }

    @IBAction func updateOutputVolume(_ sender: AnyObject) {

        if let slider = sender as? NSSlider {
            let device = AudioDevice.lookupByID(AudioObjectID(slider.tag))
            device?.setVirtualMasterVolume(Float32(slider.floatValue), direction: .Playback)
        }
    }

    @IBAction func updateInputMute(_ sender: AnyObject) {

        if let button = sender as? NSButton {
            let device = AudioDevice.lookupByID(AudioObjectID(button.tag))

            device?.setMute(button.state == NSOnState, channel: kAudioObjectPropertyElementMaster, direction: .Recording)
        }
    }

    @IBAction func updateOutputMute(_ sender: AnyObject) {

        if let button = sender as? NSButton {
            let device = AudioDevice.lookupByID(AudioObjectID(button.tag))

            device?.setMute(button.state == NSOnState, channel: kAudioObjectPropertyElementMaster, direction: .Playback)
        }
    }

    @IBAction func updateSampleRate(_ sender: AnyObject) {

        if let menuItem = sender as? NSMenuItem {
            let device = AudioDevice.lookupByID(AudioObjectID(menuItem.tag))

            if let sampleRate = menuItem.representedObject as? Float64 {
                device?.setNominalSampleRate(sampleRate)
            }
        }
    }

    @IBAction func updateClockSource(_ sender: AnyObject) {

        if let menuItem = sender as? NSMenuItem {
            let device = AudioDevice.lookupByID(AudioObjectID(menuItem.tag))

            if let clockSourceID = menuItem.representedObject as? UInt {
                device?.setClockSourceID(UInt32(clockSourceID),
                                         channel: UInt32(kAudioObjectPropertyElementMaster),
                                         direction: .Playback)
            }
        }
    }

    @IBAction func updateDefaultInputDevice(_ sender: AnyObject) {

        if let menuItem = sender as? NSMenuItem {
            let device = AudioDevice.lookupByID(AudioObjectID(menuItem.tag))
            device?.setAsDefaultInputDevice()
        }
    }

    @IBAction func updateDefaultOutputDevice(_ sender: AnyObject) {

        if let menuItem = sender as? NSMenuItem {
            let device = AudioDevice.lookupByID(AudioObjectID(menuItem.tag))
            device?.setAsDefaultOutputDevice()
        }
    }

    @IBAction func updateDefaultSystemOutputDevice(_ sender: AnyObject) {

        if let menuItem = sender as? NSMenuItem {
            let device = AudioDevice.lookupByID(AudioObjectID(menuItem.tag))
            device?.setAsDefaultSystemDevice()
        }
    }

    @IBAction func updateFeaturedDevice(_ sender: AnyObject) {

        if let menuItem = sender as? NSMenuItem {
            let device = AudioDevice.lookupByID(AudioObjectID(menuItem.tag))
            prefs.general.featuredDevice.value = DeviceDescriptor(device: device)

            DispatchQueue.main.async {
                self.updateDeviceMenuItems()
            }
        }
    }
}

extension StatusBarViewController: NSMenuDelegate {

    func menuDidClose(_ menu: NSMenu) {

        if var subView = statusBarView.subView() {
            subView.shouldHighlight = false
        }
    }

    func menuWillOpen(_ menu: NSMenu) {

        if var subView = statusBarView.subView() {
            subView.shouldHighlight = true
        }
    }
}

// MARK: - AMEventSubscriber Protocol Implementation
extension StatusBarViewController : EventSubscriber {

    func eventReceiver(_ event: AMCoreAudio.Event) {
        switch event {
        case let event as AudioDeviceEvent:

            switch event {

            case .nominalSampleRateDidChange(let audioDevice):

                updateDeviceMenuItem(device: audioDevice)

                if prefs.general.featuredDevice.value.device == audioDevice {
                    DispatchQueue.main.async {
                        self.updateStatusBarView()
                    }
                }

            case .availableNominalSampleRatesDidChange(let audioDevice):

                updateDeviceMenuItem(device: audioDevice)

            case .clockSourceDidChange(let audioDevice, _, _):

                updateDeviceMenuItem(device: audioDevice)

                if prefs.general.featuredDevice.value.device == audioDevice {
                    DispatchQueue.main.async {
                        self.updateStatusBarView()
                    }
                }
            case .nameDidChange(let audioDevice):

                // Because we want to keep items in alphabetical order and addDevice preserves the order,
                // we will remove and add the device again.
                removeDevice(device: audioDevice)
                addDevice(device: audioDevice)

            case .listDidChange(let audioDevice):

                updateDeviceMenuItem(device: audioDevice)

            case .volumeDidChange(let audioDevice, _, let direction):

                if let menuItem = menuItem(device: audioDevice) {
                    updateMasterVolume(menuItem: menuItem, direction: direction)
                }

                if prefs.general.featuredDevice.value.device == audioDevice {
                    DispatchQueue.main.async {
                        self.updateStatusBarView()
                    }
                }

            case .muteDidChange(let audioDevice, _, let direction):

                if let menuItem = menuItem(device: audioDevice) {
                    updateMasterVolume(menuItem: menuItem, direction: direction)
                }

                if prefs.general.featuredDevice.value.device == audioDevice {
                    DispatchQueue.main.async {
                        self.updateStatusBarView()
                    }
                }

            default:

                break

            }

        case let event as AudioHardwareEvent:

            switch event {
            case .deviceListChanged(let addedDevices, let removedDevices):

                for removedDevice in removedDevices {
                    removeDevice(device: removedDevice)

                    DispatchQueue.main.async {
                        self.updateStatusBarView()
                    }
                }

                for addedDevice in addedDevices {
                    addDevice(device: addedDevice)

                    if prefs.general.featuredDevice.value.device == addedDevice {
                        DispatchQueue.main.async {
                            self.updateStatusBarView()
                        }
                    }
                }

            case .defaultInputDeviceChanged(_):

                updateDeviceMenuItems()

            case .defaultOutputDeviceChanged(_):

                updateDeviceMenuItems()

            case .defaultSystemOutputDeviceChanged(_):

                updateDeviceMenuItems()

            }

        default:

            break

        }
    }
}

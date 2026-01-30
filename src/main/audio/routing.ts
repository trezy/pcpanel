// Audio routing manager for BEACN-style mixing
// Replaces AudioPassthroughManager with mix bus architecture

import * as path from 'path';
import { app } from 'electron';
import {
  AudioRoutingConfig,
  AudioRoutingState,
  AudioOutputDevice,
  ChannelState,
  MixBusState,
  CHANNEL_DEFINITIONS,
} from './types';
import {
  loadConfig,
  saveConfig,
  updateChannelLabel,
  updateChannelVolume,
  updateChannelMuted,
  updateMixBusChannel,
  updateMixBusOutput,
} from './config';

/**
 * Get the path to the native audio addon.
 * Works in both development and packaged modes.
 */
function getNativeModulePath(): string {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, 'native', 'pcpanel_audio.node');
  } else {
    return path.join(__dirname, '../../../native/build/Release/pcpanel_audio.node');
  }
}

// Load the native addon
// eslint-disable-next-line @typescript-eslint/no-var-requires
const audioAddon = require(getNativeModulePath());

interface NativeAudioDevice {
  id: number;
  name: string;
  hasOutput: boolean;
  hasInput: boolean;
}

/**
 * AudioRoutingManager - manages BEACN-style audio mixing
 *
 * Creates mix buses that aggregate multiple PCPanel virtual devices
 * and route them to output devices (headphones, virtual mic, etc.)
 */
class AudioRoutingManager {
  private config: AudioRoutingConfig;
  private mixerHandles: Map<string, number> = new Map();
  private isInitialized = false;
  private saveTimeout: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    this.config = loadConfig();
  }

  /**
   * Initialize the audio routing system
   * Creates mixers for all configured mix buses
   */
  initialize(): void {
    if (this.isInitialized) {
      console.log('AudioRoutingManager already initialized');
      return;
    }

    console.log('Initializing AudioRoutingManager...');

    // Find PCPanel devices
    const devices = this.listDevices();
    const pcpanelDevices = devices.filter((d: NativeAudioDevice) => d.name.startsWith('PCPanel'));

    if (pcpanelDevices.length === 0) {
      console.warn('No PCPanel devices found. Waiting for devices...');
    }

    // Create the Personal Mix (always create even if no devices yet)
    this.createPersonalMix(pcpanelDevices);

    // Create the Voice Chat Mix (outputs to PCPanel Voice Chat virtual mic)
    this.createVoiceChatMix(pcpanelDevices);

    this.isInitialized = true;
    console.log('AudioRoutingManager initialized');
  }

  /**
   * Create the Personal Mix - aggregates all channels to user's output
   */
  private createPersonalMix(pcpanelDevices: NativeAudioDevice[]): void {
    const personalMix = this.config.mixBuses.find(b => b.id === 'personal');
    if (!personalMix) {
      console.error('No personal mix bus configured');
      return;
    }

    try {
      // Create the mixer
      const mixerHandle = audioAddon.createMixer('Personal Mix');
      this.mixerHandles.set('personal', mixerHandle);

      // Add all available PCPanel devices as inputs
      for (const device of pcpanelDevices) {
        const channelDef = CHANNEL_DEFINITIONS.find(c => c.deviceName === device.name);
        if (!channelDef) continue;

        const channel = this.config.inputChannels.find(c => c.id === channelDef.id);
        if (!channel) continue;

        // Check if this channel is enabled in the personal mix
        const mixChannel = personalMix.channels.find(c => c.channelId === channel.id);
        const enabled = mixChannel?.enabled ?? true;

        try {
          audioAddon.mixerAddInput(mixerHandle, device.name);

          // Set initial gain based on channel volume
          const effectiveVolume = channel.muted ? 0 : channel.volume;
          audioAddon.mixerSetInputGain(mixerHandle, device.name, effectiveVolume);
          audioAddon.mixerSetInputEnabled(mixerHandle, device.name, enabled);

          console.log(`Added ${device.name} to Personal Mix (vol: ${effectiveVolume}, enabled: ${enabled})`);
        } catch (err) {
          console.error(`Failed to add ${device.name} to mixer:`, err);
        }
      }

      // Set output device
      if (personalMix.outputDeviceId !== null) {
        audioAddon.mixerSetOutput(mixerHandle, personalMix.outputDeviceId);
      }
      // If null, mixer uses default output

      // Start the mixer
      audioAddon.mixerStart(mixerHandle);
      console.log('Personal Mix started');
    } catch (err) {
      console.error('Failed to create Personal Mix:', err);
    }
  }

  /**
   * Create the Voice Chat Mix - routes selected channels to virtual mic
   * Apps like Discord can select "PCPanel Voice Chat" as their microphone
   */
  private createVoiceChatMix(pcpanelDevices: NativeAudioDevice[]): void {
    const voiceChatMix = this.config.mixBuses.find(b => b.id === 'voicechat');
    if (!voiceChatMix) {
      console.log('No voice chat mix bus configured');
      return;
    }

    // Find the Voice Chat virtual mic device
    const allDevices = this.listDevices();
    const voiceChatDevice = allDevices.find((d: NativeAudioDevice) => d.name === 'PCPanel Voice Chat');

    if (!voiceChatDevice) {
      console.warn('PCPanel Voice Chat device not found. Voice Chat Mix disabled.');
      console.log('Available devices:', allDevices.map((d: NativeAudioDevice) => d.name).join(', '));
      return;
    }

    // Only create mixer if there are channels enabled in the mix
    if (voiceChatMix.channels.length === 0) {
      console.log('Voice Chat Mix has no channels enabled. Skipping mixer creation.');
      return;
    }

    try {
      // Create the mixer
      const mixerHandle = audioAddon.createMixer('Voice Chat Mix');
      this.mixerHandles.set('voicechat', mixerHandle);

      // Add only the channels that are enabled in the voice chat mix
      for (const mixChannel of voiceChatMix.channels) {
        if (!mixChannel.enabled) continue;

        const channel = this.config.inputChannels.find(c => c.id === mixChannel.channelId);
        if (!channel) continue;

        // Find the corresponding PCPanel device
        const device = pcpanelDevices.find((d: NativeAudioDevice) => d.name === channel.deviceName);
        if (!device) continue;

        try {
          audioAddon.mixerAddInput(mixerHandle, device.name);

          // Use gain override if set, otherwise use channel volume
          const gain = mixChannel.gainOverride ?? (channel.muted ? 0 : channel.volume);
          audioAddon.mixerSetInputGain(mixerHandle, device.name, gain);
          audioAddon.mixerSetInputEnabled(mixerHandle, device.name, true);

          console.log(`Added ${device.name} to Voice Chat Mix (gain: ${gain})`);
        } catch (err) {
          console.error(`Failed to add ${device.name} to Voice Chat mixer:`, err);
        }
      }

      // Set output to the Voice Chat virtual mic device
      // The mixer writes to the output stream, which loops back to the input stream
      audioAddon.mixerSetOutput(mixerHandle, voiceChatDevice.id);

      // Start the mixer
      audioAddon.mixerStart(mixerHandle);
      console.log(`Voice Chat Mix started, outputting to ${voiceChatDevice.name} (ID: ${voiceChatDevice.id})`);
    } catch (err) {
      console.error('Failed to create Voice Chat Mix:', err);
    }
  }

  /**
   * Shutdown the audio routing system
   */
  shutdown(): void {
    if (!this.isInitialized) return;

    console.log('Shutting down AudioRoutingManager...');

    // Stop all mixers
    audioAddon.stopAllMixers();
    this.mixerHandles.clear();

    // Save config
    this.saveConfigNow();

    this.isInitialized = false;
    console.log('AudioRoutingManager shutdown complete');
  }

  /**
   * List all audio devices on the system
   */
  listDevices(): NativeAudioDevice[] {
    return audioAddon.listAudioDevices() || [];
  }

  /**
   * Get available output devices for mix routing
   */
  getAvailableOutputDevices(): AudioOutputDevice[] {
    const devices = this.listDevices();
    const defaultOutput = audioAddon.getDefaultOutputDevice();

    return devices
      .filter((d: NativeAudioDevice) => d.hasOutput && !d.name.startsWith('PCPanel'))
      .map((d: NativeAudioDevice) => ({
        id: d.id,
        name: d.name,
        isDefault: defaultOutput && d.id === defaultOutput.id,
      }));
  }

  /**
   * Set channel volume (0.0 - 1.0)
   */
  setChannelVolume(channelId: string, volume: number): void {
    const channel = this.config.inputChannels.find(c => c.id === channelId);
    if (!channel) {
      console.error(`Channel not found: ${channelId}`);
      return;
    }

    // Update config
    this.config = updateChannelVolume(this.config, channelId, volume);
    this.scheduleSave();

    // Update all mixers that include this channel
    const effectiveVolume = this.config.inputChannels.find(c => c.id === channelId)!.muted
      ? 0
      : volume;

    if (this.mixerHandles.size === 0) {
      // Mixer not created yet, just update config
      return;
    }

    for (const [mixId, mixerHandle] of this.mixerHandles) {
      try {
        audioAddon.mixerSetInputGain(mixerHandle, channel.deviceName, effectiveVolume);
        console.log(`Updated ${channel.deviceName} gain to ${effectiveVolume} in mixer ${mixId}`);
      } catch {
        // Channel may not be in this mixer
      }
    }
  }

  /**
   * Set channel volume from hardware value (0-255)
   */
  setChannelVolumeFromHardware(channelId: string, hardwareValue: number): void {
    const volume = hardwareValue / 255;
    this.setChannelVolume(channelId, volume);
  }

  /**
   * Handle hardware control change (knob/slider)
   */
  handleHardwareChange(hardwareIndex: number, value: number): void {
    const mapping = this.config.hardwareMapping[hardwareIndex];
    if (!mapping) {
      console.warn(`No mapping for hardware index ${hardwareIndex}`);
      return;
    }

    switch (mapping.type) {
      case 'channel-volume':
        this.setChannelVolumeFromHardware(mapping.targetId, value);
        break;
      case 'channel-mute':
        // Toggle mute on button press (value > 0)
        if (value > 0) {
          const channel = this.config.inputChannels.find(c => c.id === mapping.targetId);
          if (channel) {
            this.setChannelMuted(mapping.targetId, !channel.muted);
          }
        }
        break;
      default:
        console.warn(`Unknown mapping type: ${mapping.type}`);
    }
  }

  /**
   * Set channel muted state
   */
  setChannelMuted(channelId: string, muted: boolean): void {
    const channel = this.config.inputChannels.find(c => c.id === channelId);
    if (!channel) {
      console.error(`Channel not found: ${channelId}`);
      return;
    }

    // Update config
    this.config = updateChannelMuted(this.config, channelId, muted);
    this.scheduleSave();

    // Update all mixers - set gain to 0 if muted, otherwise use volume
    const effectiveVolume = muted ? 0 : channel.volume;

    for (const [mixId, mixerHandle] of this.mixerHandles) {
      try {
        audioAddon.mixerSetInputGain(mixerHandle, channel.deviceName, effectiveVolume);
      } catch {
        // Channel may not be in this mixer
      }
    }
  }

  /**
   * Set channel display label
   */
  setChannelLabel(channelId: string, label: string): void {
    this.config = updateChannelLabel(this.config, channelId, label);
    this.scheduleSave();
  }

  /**
   * Set whether a channel is enabled in a specific mix
   */
  setChannelEnabledInMix(mixId: string, channelId: string, enabled: boolean): void {
    const channel = this.config.inputChannels.find(c => c.id === channelId);
    if (!channel) {
      console.error(`Channel not found: ${channelId}`);
      return;
    }

    // Update config
    this.config = updateMixBusChannel(this.config, mixId, channelId, enabled);
    this.scheduleSave();

    // Update mixer
    const mixerHandle = this.mixerHandles.get(mixId);
    if (mixerHandle !== undefined) {
      try {
        audioAddon.mixerSetInputEnabled(mixerHandle, channel.deviceName, enabled);
      } catch (err) {
        console.error(`Failed to update channel enabled state in mixer:`, err);
      }
    }
  }

  /**
   * Set the output device for a mix bus
   */
  setMixOutput(mixId: string, deviceId: number | null): void {
    // Update config
    this.config = updateMixBusOutput(this.config, mixId, deviceId);
    this.scheduleSave();

    // Live switch: stop mixer, change output, restart
    const mixerHandle = this.mixerHandles.get(mixId);
    if (mixerHandle !== undefined) {
      try {
        audioAddon.mixerStop(mixerHandle);

        // Determine the actual device ID to use
        let actualDeviceId = deviceId;
        if (actualDeviceId === null) {
          // Use system default output
          const defaultDevice = audioAddon.getDefaultOutputDevice();
          if (defaultDevice) {
            actualDeviceId = defaultDevice.id;
          }
        }

        if (actualDeviceId !== null) {
          audioAddon.mixerSetOutput(mixerHandle, actualDeviceId);
        }

        audioAddon.mixerStart(mixerHandle);
        console.log(`Mix ${mixId} output switched to device ${actualDeviceId}`);
      } catch (err) {
        console.error(`Failed to switch output for mix ${mixId}:`, err);
      }
    }
  }

  /**
   * Get complete routing state for UI
   */
  getState(): AudioRoutingState {
    // Get device activity from native module
    let deviceActivity: Record<string, { id: number; name: string; isActive: boolean; apps: string[] }> = {};
    try {
      deviceActivity = audioAddon.getDeviceActivity() || {};
    } catch (err) {
      console.error('Failed to get device activity:', err);
    }

    // Build channel states with activity
    const channels: ChannelState[] = this.config.inputChannels.map(channel => {
      const activity = deviceActivity[channel.deviceName];
      return {
        ...channel,
        isActive: activity?.isActive ?? false,
        apps: activity?.apps ?? [],
      };
    });

    // Build mix bus states
    const mixBuses: MixBusState[] = this.config.mixBuses.map(bus => ({
      ...bus,
      isRunning: this.mixerHandles.has(bus.id),
      mixerHandle: this.mixerHandles.get(bus.id) ?? null,
    }));

    return {
      channels,
      mixBuses,
      availableOutputs: this.getAvailableOutputDevices(),
    };
  }

  /**
   * Get current configuration
   */
  getConfig(): AudioRoutingConfig {
    return this.config;
  }

  /**
   * Schedule a config save (debounced)
   */
  private scheduleSave(): void {
    if (this.saveTimeout) {
      clearTimeout(this.saveTimeout);
    }
    this.saveTimeout = setTimeout(() => {
      this.saveConfigNow();
    }, 1000);
  }

  /**
   * Save config immediately
   */
  private saveConfigNow(): void {
    if (this.saveTimeout) {
      clearTimeout(this.saveTimeout);
      this.saveTimeout = null;
    }
    saveConfig(this.config);
  }

  // ============================================================
  // Legacy API compatibility (for gradual migration)
  // ============================================================

  /**
   * @deprecated Use handleHardwareChange instead
   */
  setVolumeFromHardware(channelIndex: number, hardwareValue: number): boolean {
    const channelDef = CHANNEL_DEFINITIONS[channelIndex];
    if (!channelDef) return false;
    this.setChannelVolumeFromHardware(channelDef.id, hardwareValue);
    return true;
  }

  /**
   * @deprecated Use getState().channels[index].volume instead
   */
  getVolume(channelIndex: number): number {
    const channelDef = CHANNEL_DEFINITIONS[channelIndex];
    if (!channelDef) return 1.0;
    const channel = this.config.inputChannels.find(c => c.id === channelDef.id);
    return channel?.volume ?? 1.0;
  }

  /**
   * Get channel activity info with app names
   * Compatible with existing UI code
   */
  getChannelActivityInfo(): Record<number, { isActive: boolean; apps: string[] }> {
    const state = this.getState();
    const result: Record<number, { isActive: boolean; apps: string[] }> = {};

    for (const channel of state.channels) {
      result[channel.hardwareIndex] = {
        isActive: channel.isActive,
        apps: channel.apps,
      };
    }

    return result;
  }

  /**
   * Get audio levels for all channels
   * Returns { channelId: { peak, rms } }
   */
  getAudioLevels(): Record<string, { peak: number; rms: number }> {
    const result: Record<string, { peak: number; rms: number }> = {};

    // Get levels from the personal mix (main mixer)
    const personalHandle = this.mixerHandles.get('personal');
    if (personalHandle !== undefined) {
      try {
        const levels = audioAddon.mixerGetLevels(personalHandle) as Record<string, { peak: number; rms: number }>;

        // Map device names back to channel IDs
        for (const channel of this.config.inputChannels) {
          if (levels[channel.deviceName]) {
            result[channel.id] = levels[channel.deviceName];
          }
        }
      } catch (err) {
        // Levels not available
      }
    }

    return result;
  }
}

export const audioRouting = new AudioRoutingManager();

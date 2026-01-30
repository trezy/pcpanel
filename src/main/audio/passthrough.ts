// Audio passthrough manager
// Routes audio from PCPanel virtual devices to real output

import * as path from 'path';
import { app } from 'electron';

/**
 * Get the path to the native audio addon.
 * Works in both development and packaged modes.
 */
function getNativeModulePath(): string {
  if (app.isPackaged) {
    // In packaged app, native modules are in Contents/Resources/native/
    return path.join(process.resourcesPath, 'native', 'pcpanel_audio.node');
  } else {
    // In development, use the build output relative to compiled location (dist/main/audio/)
    return path.join(__dirname, '../../../native/build/Release/pcpanel_audio.node');
  }
}

// Load the native addon
// eslint-disable-next-line @typescript-eslint/no-var-requires
const audioAddon = require(getNativeModulePath());

interface AudioDevice {
  id: number;
  name: string;
  hasOutput: boolean;
  hasInput: boolean;
}

interface PassthroughChannel {
  index: number;
  deviceName: string;
  passthroughId: number | null;
  volume: number;
}

class AudioPassthroughManager {
  private channels: Map<number, PassthroughChannel> = new Map();
  private deviceNames = ['PCPanel K1', 'PCPanel K2', 'PCPanel K3', 'PCPanel K4', 'PCPanel K5',
                         'PCPanel S1', 'PCPanel S2', 'PCPanel S3', 'PCPanel S4'];

  /**
   * List all audio devices on the system
   */
  listDevices(): AudioDevice[] {
    return audioAddon.listAudioDevices() || [];
  }

  /**
   * Get the default output device
   */
  getDefaultOutput(): { id: number; name: string } | null {
    return audioAddon.getDefaultOutputDevice();
  }

  /**
   * Find PCPanel virtual devices
   */
  findPCPanelDevices(): AudioDevice[] {
    const devices = this.listDevices();
    return devices.filter((d: AudioDevice) => d.name.startsWith('PCPanel'));
  }

  /**
   * Start passthrough for a specific channel
   */
  startChannel(channelIndex: number): boolean {
    if (channelIndex < 0 || channelIndex >= this.deviceNames.length) {
      console.error(`Invalid channel index: ${channelIndex}`);
      return false;
    }

    const deviceName = this.deviceNames[channelIndex];

    // Check if already running
    const existing = this.channels.get(channelIndex);
    if (existing && existing.passthroughId !== null) {
      console.log(`Channel ${channelIndex} already running`);
      return true;
    }

    try {
      const passthroughId = audioAddon.startPassthrough(deviceName);

      this.channels.set(channelIndex, {
        index: channelIndex,
        deviceName,
        passthroughId,
        volume: 1.0
      });

      console.log(`Started passthrough for ${deviceName} (channel ${channelIndex})`);
      return true;
    } catch (err) {
      console.error(`Failed to start passthrough for ${deviceName}:`, err);
      return false;
    }
  }

  /**
   * Stop passthrough for a specific channel
   */
  stopChannel(channelIndex: number): boolean {
    const channel = this.channels.get(channelIndex);
    if (!channel || channel.passthroughId === null) {
      return false;
    }

    try {
      audioAddon.stopPassthrough(channel.passthroughId);
      channel.passthroughId = null;
      console.log(`Stopped passthrough for channel ${channelIndex}`);
      return true;
    } catch (err) {
      console.error(`Failed to stop passthrough for channel ${channelIndex}:`, err);
      return false;
    }
  }

  /**
   * Start passthrough for all available PCPanel devices
   */
  startAll(): void {
    const pcpanelDevices = this.findPCPanelDevices();

    for (const device of pcpanelDevices) {
      const channelIndex = this.deviceNames.indexOf(device.name);
      if (channelIndex >= 0) {
        this.startChannel(channelIndex);
      }
    }
  }

  /**
   * Stop all passthrough channels
   */
  stopAll(): void {
    audioAddon.stopAllPassthrough();
    this.channels.clear();
    console.log('Stopped all passthrough channels');
  }

  /**
   * Set volume for a channel (0.0 - 1.0)
   */
  setVolume(channelIndex: number, volume: number): boolean {
    const channel = this.channels.get(channelIndex);
    if (!channel || channel.passthroughId === null) {
      return false;
    }

    const clampedVolume = Math.max(0, Math.min(1, volume));

    try {
      audioAddon.setPassthroughVolume(channel.passthroughId, clampedVolume);
      channel.volume = clampedVolume;
      return true;
    } catch (err) {
      console.error(`Failed to set volume for channel ${channelIndex}:`, err);
      return false;
    }
  }

  /**
   * Set volume from hardware value (0-255)
   */
  setVolumeFromHardware(channelIndex: number, hardwareValue: number): boolean {
    const volume = hardwareValue / 255;
    return this.setVolume(channelIndex, volume);
  }

  /**
   * Get current volume for a channel
   */
  getVolume(channelIndex: number): number {
    const channel = this.channels.get(channelIndex);
    return channel?.volume ?? 1.0;
  }

  /**
   * Check if a channel is active
   */
  isChannelActive(channelIndex: number): boolean {
    const channel = this.channels.get(channelIndex);
    return channel?.passthroughId !== null;
  }

  /**
   * Get all active channels
   */
  getActiveChannels(): number[] {
    const active: number[] = [];
    for (const [index, channel] of this.channels) {
      if (channel.passthroughId !== null) {
        active.push(index);
      }
    }
    return active;
  }

  /**
   * Get activity status for all PCPanel devices
   * Returns which devices currently have audio playing to them, along with app names
   */
  getDeviceActivity(): Record<string, { id: number; name: string; isActive: boolean; apps: string[] }> {
    try {
      return audioAddon.getDeviceActivity() || {};
    } catch (err) {
      console.error('Failed to get device activity:', err);
      return {};
    }
  }

  /**
   * Get channel activity by index
   * Returns true if an app is currently playing audio to this channel
   */
  isChannelPlaying(channelIndex: number): boolean {
    if (channelIndex < 0 || channelIndex >= this.deviceNames.length) {
      return false;
    }
    const deviceName = this.deviceNames[channelIndex];
    const activity = this.getDeviceActivity();
    return activity[deviceName]?.isActive ?? false;
  }

  /**
   * Get all channels that currently have audio playing
   */
  getPlayingChannels(): number[] {
    const activity = this.getDeviceActivity();
    const playing: number[] = [];

    for (let i = 0; i < this.deviceNames.length; i++) {
      const deviceName = this.deviceNames[i];
      if (activity[deviceName]?.isActive) {
        playing.push(i);
      }
    }

    return playing;
  }

  /**
   * Get channel activity info with app names
   * Returns an object mapping channel index to activity info
   */
  getChannelActivityInfo(): Record<number, { isActive: boolean; apps: string[] }> {
    const activity = this.getDeviceActivity();
    const result: Record<number, { isActive: boolean; apps: string[] }> = {};

    for (let i = 0; i < this.deviceNames.length; i++) {
      const deviceName = this.deviceNames[i];
      const info = activity[deviceName];
      result[i] = {
        isActive: info?.isActive ?? false,
        apps: info?.apps ?? []
      };
    }

    return result;
  }
}

export const audioPassthrough = new AudioPassthroughManager();

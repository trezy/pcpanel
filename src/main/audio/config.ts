// Configuration persistence for audio routing

import * as fs from 'fs';
import * as path from 'path';
import { app } from 'electron';
import { AudioRoutingConfig, createDefaultConfig } from './types';

const CONFIG_FILENAME = 'audio-routing.json';

/**
 * Get the configuration file path
 */
function getConfigPath(): string {
  const userDataPath = app.getPath('userData');
  return path.join(userDataPath, CONFIG_FILENAME);
}

/**
 * Load audio routing configuration from disk
 * Returns default config if file doesn't exist or is invalid
 */
export function loadConfig(): AudioRoutingConfig {
  const configPath = getConfigPath();

  try {
    if (fs.existsSync(configPath)) {
      const data = fs.readFileSync(configPath, 'utf-8');
      const parsed = JSON.parse(data) as AudioRoutingConfig;

      // Validate and merge with defaults to ensure all required fields exist
      return mergeWithDefaults(parsed);
    }
  } catch (err) {
    console.error('Failed to load audio routing config:', err);
  }

  return createDefaultConfig();
}

/**
 * Save audio routing configuration to disk
 */
export function saveConfig(config: AudioRoutingConfig): boolean {
  const configPath = getConfigPath();

  try {
    // Ensure directory exists
    const dir = path.dirname(configPath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    fs.writeFileSync(configPath, JSON.stringify(config, null, 2), 'utf-8');
    return true;
  } catch (err) {
    console.error('Failed to save audio routing config:', err);
    return false;
  }
}

/**
 * Merge loaded config with defaults to handle schema changes
 * Ensures new fields are added while preserving user settings
 */
function mergeWithDefaults(loaded: Partial<AudioRoutingConfig>): AudioRoutingConfig {
  const defaults = createDefaultConfig();

  // Merge input channels - preserve user display names and volumes
  const inputChannels = defaults.inputChannels.map(defaultChannel => {
    const loadedChannel = loaded.inputChannels?.find(c => c.id === defaultChannel.id);
    if (loadedChannel) {
      return {
        ...defaultChannel,
        channelName: loadedChannel.channelName ?? defaultChannel.channelName,
        volume: loadedChannel.volume ?? defaultChannel.volume,
        muted: loadedChannel.muted ?? defaultChannel.muted,
      };
    }
    return defaultChannel;
  });

  // Merge mix buses - preserve user settings
  const mixBuses = defaults.mixBuses.map(defaultBus => {
    const loadedBus = loaded.mixBuses?.find(b => b.id === defaultBus.id);
    if (loadedBus) {
      return {
        ...defaultBus,
        name: loadedBus.name ?? defaultBus.name,
        outputDeviceId: loadedBus.outputDeviceId ?? defaultBus.outputDeviceId,
        channels: loadedBus.channels ?? defaultBus.channels,
      };
    }
    return defaultBus;
  });

  // Use loaded hardware mapping if valid, otherwise use defaults
  const hardwareMapping = loaded.hardwareMapping && Object.keys(loaded.hardwareMapping).length > 0
    ? loaded.hardwareMapping
    : defaults.hardwareMapping;

  return {
    inputChannels,
    mixBuses,
    hardwareMapping,
  };
}

/**
 * Update a single channel's name
 */
export function updateChannelLabel(
  config: AudioRoutingConfig,
  channelId: string,
  channelName: string
): AudioRoutingConfig {
  return {
    ...config,
    inputChannels: config.inputChannels.map(channel =>
      channel.id === channelId
        ? { ...channel, channelName }
        : channel
    ),
  };
}

/**
 * Update a channel's volume
 */
export function updateChannelVolume(
  config: AudioRoutingConfig,
  channelId: string,
  volume: number
): AudioRoutingConfig {
  const clampedVolume = Math.max(0, Math.min(1, volume));
  return {
    ...config,
    inputChannels: config.inputChannels.map(channel =>
      channel.id === channelId
        ? { ...channel, volume: clampedVolume }
        : channel
    ),
  };
}

/**
 * Update a channel's mute state
 */
export function updateChannelMuted(
  config: AudioRoutingConfig,
  channelId: string,
  muted: boolean
): AudioRoutingConfig {
  return {
    ...config,
    inputChannels: config.inputChannels.map(channel =>
      channel.id === channelId
        ? { ...channel, muted }
        : channel
    ),
  };
}

/**
 * Update which channels are enabled in a mix bus
 */
export function updateMixBusChannel(
  config: AudioRoutingConfig,
  mixId: string,
  channelId: string,
  enabled: boolean
): AudioRoutingConfig {
  return {
    ...config,
    mixBuses: config.mixBuses.map(bus => {
      if (bus.id !== mixId) return bus;

      const existingIndex = bus.channels.findIndex(c => c.channelId === channelId);

      if (enabled && existingIndex === -1) {
        // Add channel to mix
        return {
          ...bus,
          channels: [...bus.channels, { channelId, enabled: true, gainOverride: null }],
        };
      } else if (!enabled && existingIndex !== -1) {
        // Remove channel from mix
        return {
          ...bus,
          channels: bus.channels.filter(c => c.channelId !== channelId),
        };
      } else if (existingIndex !== -1) {
        // Update enabled state
        return {
          ...bus,
          channels: bus.channels.map(c =>
            c.channelId === channelId ? { ...c, enabled } : c
          ),
        };
      }

      return bus;
    }),
  };
}

/**
 * Update a mix bus's output device
 */
export function updateMixBusOutput(
  config: AudioRoutingConfig,
  mixId: string,
  outputDeviceId: number | null
): AudioRoutingConfig {
  return {
    ...config,
    mixBuses: config.mixBuses.map(bus =>
      bus.id === mixId
        ? { ...bus, outputDeviceId }
        : bus
    ),
  };
}

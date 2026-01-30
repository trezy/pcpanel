// Audio routing configuration types for BEACN-style mixing system

/**
 * Represents a single input channel (virtual output device like PCPanel K1)
 */
export interface InputChannel {
  /** Unique identifier: 'k1', 'k2', 'k3', 'k4', 'k5', 's1', 's2', 's3', 's4' */
  id: string;
  /** Virtual device name: 'PCPanel K1', 'PCPanel S2', etc. */
  deviceName: string;
  /** User-editable channel name: 'Discord', 'Music', 'Game', etc. */
  channelName: string;
  /** Hardware control index (0-8) mapping to physical knob/slider */
  hardwareIndex: number;
  /** Current volume level (0.0 - 1.0) */
  volume: number;
  /** Whether channel is muted */
  muted: boolean;
}

/**
 * Channel configuration within a mix bus
 */
export interface MixBusChannel {
  /** Reference to InputChannel.id */
  channelId: string;
  /** Whether this channel is included in the mix */
  enabled: boolean;
  /** Optional gain override for this channel in this specific mix (null = use channel volume) */
  gainOverride: number | null;
}

/**
 * A mix bus that aggregates multiple input channels and routes to an output
 */
export interface MixBus {
  /** Unique identifier: 'personal', 'voicechat' */
  id: string;
  /** Display name: 'Personal Mix', 'Voice Chat Mix' */
  name: string;
  /** Output device ID (null = default output, or virtual mic device ID) */
  outputDeviceId: number | null;
  /** Channels included in this mix with their settings */
  channels: MixBusChannel[];
}

/**
 * Hardware control mapping types
 */
export type HardwareMappingType = 'channel-volume' | 'mix-output' | 'channel-mute';

/**
 * Maps hardware control index to its function
 */
export interface HardwareMapping {
  /** Type of control action */
  type: HardwareMappingType;
  /** Target channel or mix ID */
  targetId: string;
}

/**
 * Complete audio routing configuration (persisted to disk)
 */
export interface AudioRoutingConfig {
  /** All input channels */
  inputChannels: InputChannel[];
  /** All mix buses */
  mixBuses: MixBus[];
  /** Maps hardware index (0-8) to control function */
  hardwareMapping: Record<number, HardwareMapping>;
}

/**
 * Runtime state for a channel (includes activity info)
 */
export interface ChannelState extends InputChannel {
  /** Whether audio is currently playing to this channel */
  isActive: boolean;
  /** List of app names currently playing to this channel */
  apps: string[];
}

/**
 * Runtime state for a mix bus
 */
export interface MixBusState extends MixBus {
  /** Whether the mixer is currently running */
  isRunning: boolean;
  /** Native mixer handle (for internal use) */
  mixerHandle: number | null;
}

/**
 * Complete runtime state (sent to renderer)
 */
export interface AudioRoutingState {
  /** All channels with activity info */
  channels: ChannelState[];
  /** All mix buses with runtime state */
  mixBuses: MixBusState[];
  /** Available output devices for selection */
  availableOutputs: AudioOutputDevice[];
}

/**
 * Audio output device info
 */
export interface AudioOutputDevice {
  /** Core Audio device ID */
  id: number;
  /** Device name */
  name: string;
  /** Whether this is the system default */
  isDefault: boolean;
}

/**
 * Default channel IDs and device names
 */
export const CHANNEL_DEFINITIONS: readonly { id: string; deviceName: string; hardwareIndex: number }[] = [
  { id: 'k1', deviceName: 'PCPanel K1', hardwareIndex: 0 },
  { id: 'k2', deviceName: 'PCPanel K2', hardwareIndex: 1 },
  { id: 'k3', deviceName: 'PCPanel K3', hardwareIndex: 2 },
  { id: 'k4', deviceName: 'PCPanel K4', hardwareIndex: 3 },
  { id: 'k5', deviceName: 'PCPanel K5', hardwareIndex: 4 },
  { id: 's1', deviceName: 'PCPanel S1', hardwareIndex: 5 },
  { id: 's2', deviceName: 'PCPanel S2', hardwareIndex: 6 },
  { id: 's3', deviceName: 'PCPanel S3', hardwareIndex: 7 },
  { id: 's4', deviceName: 'PCPanel S4', hardwareIndex: 8 },
] as const;

/**
 * Create default configuration
 */
export function createDefaultConfig(): AudioRoutingConfig {
  const inputChannels: InputChannel[] = CHANNEL_DEFINITIONS.map(def => ({
    id: def.id,
    deviceName: def.deviceName,
    channelName: def.id.toUpperCase(),
    hardwareIndex: def.hardwareIndex,
    volume: 1.0,
    muted: false,
  }));

  const mixBuses: MixBus[] = [
    {
      id: 'personal',
      name: 'Personal Mix',
      outputDeviceId: null, // Default output
      channels: CHANNEL_DEFINITIONS.map(def => ({
        channelId: def.id,
        enabled: true,
        gainOverride: null,
      })),
    },
    {
      id: 'voicechat',
      name: 'Voice Chat Mix',
      outputDeviceId: null, // Will be virtual mic device
      channels: [], // Empty by default, user adds channels
    },
  ];

  const hardwareMapping: Record<number, HardwareMapping> = {};
  for (const def of CHANNEL_DEFINITIONS) {
    hardwareMapping[def.hardwareIndex] = {
      type: 'channel-volume',
      targetId: def.id,
    };
  }

  return {
    inputChannels,
    mixBuses,
    hardwareMapping,
  };
}

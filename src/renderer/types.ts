export interface ChannelActivityInfo {
  isActive: boolean;
  apps: string[];
}

export interface AudioLevelInfo {
  peak: number;
  rms: number;
}

export interface DeviceState {
  connected: boolean;
  analogValues: number[];
  buttonStates: boolean[];
}

// Audio routing types (mirrored from main/audio/types.ts)
export interface AudioOutputDevice {
  id: number;
  name: string;
  isDefault: boolean;
}

export interface ChannelState {
  id: string;
  deviceName: string;
  channelName: string;
  hardwareIndex: number;
  volume: number;
  muted: boolean;
  isActive: boolean;
  apps: string[];
}

export interface MixBusChannel {
  channelId: string;
  enabled: boolean;
  gainOverride: number | null;
}

export interface MixBusState {
  id: string;
  name: string;
  outputDeviceId: number | null;
  channels: MixBusChannel[];
  isRunning: boolean;
  mixerHandle: number | null;
}

export interface AudioRoutingState {
  channels: ChannelState[];
  mixBuses: MixBusState[];
  availableOutputs: AudioOutputDevice[];
}

export interface KnobChangeEvent {
  type: 'knob-change';
  index: number;
  value: number;
}

export interface ButtonChangeEvent {
  type: 'button-change';
  index: number;
  pressed: boolean;
}

export interface StateResponseEvent {
  type: 'state-response';
  analogValues: number[];
  buttonStates: boolean[];
}

export type DeviceEvent = KnobChangeEvent | ButtonChangeEvent | StateResponseEvent;

export interface ToastData {
  type: 'success' | 'warning' | 'error' | 'info';
  message: string;
  duration?: number;
}

export interface PCPanelAPI {
  // Event listeners
  onDeviceStatus: (callback: (status: { connected: boolean; message: string }) => void) => void;
  onDeviceEvent: (callback: (event: DeviceEvent) => void) => void;
  onDeviceState: (callback: (state: DeviceState) => void) => void;
  onOutputDevice: (callback: (device: { name: string }) => void) => void;
  onChannelActivity: (callback: (activityInfo: Record<number, ChannelActivityInfo>) => void) => void;
  onAudioLevels: (callback: (levels: Record<string, AudioLevelInfo>) => void) => void;
  onToast: (callback: (toast: ToastData) => void) => void;

  // Legacy API
  getDeviceState: () => Promise<DeviceState>;
  getOutputDevice: () => Promise<{ name: string } | null>;
  getChannelActivity: () => Promise<Record<number, ChannelActivityInfo>>;
  reconnect: () => Promise<void>;

  // Audio routing API
  getAudioRouting: () => Promise<AudioRoutingState>;
  setChannelLabel: (channelId: string, label: string) => Promise<AudioRoutingState>;
  setChannelVolume: (channelId: string, volume: number) => Promise<boolean>;
  setChannelMuted: (channelId: string, muted: boolean) => Promise<boolean>;
  setChannelEnabled: (mixId: string, channelId: string, enabled: boolean) => Promise<boolean>;
  setMixOutput: (mixId: string, deviceId: number | null) => Promise<boolean>;
  getAvailableOutputs: () => Promise<AudioOutputDevice[]>;
}

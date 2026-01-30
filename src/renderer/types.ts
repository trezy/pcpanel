export interface ChannelActivityInfo {
  isActive: boolean;
  apps: string[];
}

export interface DeviceState {
  connected: boolean;
  analogValues: number[];
  buttonStates: boolean[];
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

export interface PCPanelAPI {
  onDeviceStatus: (callback: (status: { connected: boolean; message: string }) => void) => void;
  onDeviceEvent: (callback: (event: DeviceEvent) => void) => void;
  onDeviceState: (callback: (state: DeviceState) => void) => void;
  onOutputDevice: (callback: (device: { name: string }) => void) => void;
  onChannelActivity: (callback: (activityInfo: Record<number, ChannelActivityInfo>) => void) => void;
  getDeviceState: () => Promise<DeviceState>;
  getOutputDevice: () => Promise<{ name: string } | null>;
  getChannelActivity: () => Promise<Record<number, ChannelActivityInfo>>;
  reconnect: () => Promise<void>;
}

import HID from 'node-hid';
import { EventEmitter } from 'events';
import { parseInputPacket, createStateRequestPacket, DeviceEvent, ANALOG_COUNT, BUTTON_COUNT, VENDOR_ID, PRODUCT_ID } from './protocol';

export interface DeviceState {
  connected: boolean;
  analogValues: number[]; // 9 values, 0-255
  buttonStates: boolean[]; // 5 buttons
}

export class PCPanelConnection extends EventEmitter {
  private device: HID.HID | null = null;
  private state: DeviceState;

  constructor() {
    super();
    this.state = {
      connected: false,
      analogValues: new Array(ANALOG_COUNT).fill(0),
      buttonStates: new Array(BUTTON_COUNT).fill(false),
    };
  }

  connect(_path: string): boolean {
    try {
      // Open by VID/PID (more reliable on macOS)
      this.device = new HID.HID(VENDOR_ID, PRODUCT_ID);
      this.state.connected = true;

      this.device.on('data', (data: Buffer) => {
        this.handleData(data);
      });

      this.device.on('error', (error: Error) => {
        this.emit('error', error);
        this.disconnect();
      });

      this.emit('connected');
      return true;
    } catch (error) {
      this.emit('error', error);
      return false;
    }
  }

  disconnect(): void {
    if (this.device) {
      try {
        this.device.close();
      } catch {
        // Ignore close errors
      }
      this.device = null;
    }
    this.state.connected = false;
    this.emit('disconnected');
  }

  private handleData(data: Buffer): void {
    const event = parseInputPacket(data);
    if (!event) {
      return;
    }

    if (event.type === 'knob-change') {
      this.state.analogValues[event.index] = event.value;
    } else if (event.type === 'button-change') {
      this.state.buttonStates[event.index] = event.pressed;
    } else if (event.type === 'state-response') {
      this.state.analogValues = [...event.analogValues];
      this.state.buttonStates = [...event.buttonStates];
    }

    this.emit('event', event);
    this.emit('state', this.getState());
  }

  getState(): DeviceState {
    return { ...this.state };
  }

  isConnected(): boolean {
    return this.state.connected;
  }

  requestState(): boolean {
    if (!this.device) {
      return false;
    }

    try {
      const packet = createStateRequestPacket();
      this.device.write(packet);
      return true;
    } catch (error) {
      this.emit('error', error);
      return false;
    }
  }
}

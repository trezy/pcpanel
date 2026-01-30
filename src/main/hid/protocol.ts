// PC Panel Pro USB HID Protocol Constants

export const VENDOR_ID = 0x0483; // STMicroelectronics
export const PRODUCT_ID = 0xa3c5; // PC Panel Pro 1.0 (actual device PID)

// Input message codes (device -> computer)
export const INPUT_CODE_KNOB_CHANGE = 0x01;
export const INPUT_CODE_BUTTON_CHANGE = 0x02;
export const INPUT_CODE_STATE_RESPONSE = 0x03;

// Output message codes (computer -> device)
export const OUTPUT_CODE_REQUEST_STATE = 0x01;

// PC Panel Pro has 9 analog controls (4 sliders + 5 knobs) and 5 buttons
export const ANALOG_COUNT = 9;
export const BUTTON_COUNT = 5;

// Packet size
export const PACKET_SIZE = 64;

export interface KnobChangeEvent {
  type: 'knob-change';
  index: number; // 0-8
  value: number; // 0-255
}

export interface ButtonChangeEvent {
  type: 'button-change';
  index: number; // 0-4
  pressed: boolean;
}

export interface StateResponseEvent {
  type: 'state-response';
  analogValues: number[]; // 9 values, 0-255
  buttonStates: boolean[]; // 5 buttons
}

export type DeviceEvent = KnobChangeEvent | ButtonChangeEvent | StateResponseEvent;

export function parseInputPacket(data: Buffer): DeviceEvent | null {
  if (data.length < 3) {
    return null;
  }

  const messageType = data[0];
  const index = data[1];
  const value = data[2];

  switch (messageType) {
    case INPUT_CODE_KNOB_CHANGE:
      return {
        type: 'knob-change',
        index,
        value,
      };
    case INPUT_CODE_BUTTON_CHANGE:
      return {
        type: 'button-change',
        index,
        pressed: value === 0x01,
      };
    case INPUT_CODE_STATE_RESPONSE:
      // Full state response: 9 analog values + 5 button states
      if (data.length >= 1 + ANALOG_COUNT + BUTTON_COUNT) {
        const analogValues: number[] = [];
        const buttonStates: boolean[] = [];

        for (let i = 0; i < ANALOG_COUNT; i++) {
          analogValues.push(data[1 + i]);
        }
        for (let i = 0; i < BUTTON_COUNT; i++) {
          buttonStates.push(data[1 + ANALOG_COUNT + i] === 0x01);
        }

        return {
          type: 'state-response',
          analogValues,
          buttonStates,
        };
      }
      return null;
    default:
      return null;
  }
}

export function createStateRequestPacket(): Buffer {
  const packet = Buffer.alloc(PACKET_SIZE);
  packet[0] = OUTPUT_CODE_REQUEST_STATE;
  return packet;
}

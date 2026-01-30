// PC Panel USB HID Protocol Constants

// ============================================================================
// Device Registry
// ============================================================================

export interface DeviceProfile {
  vendorId: number;
  productId: number;
  name: string;
  analogCount: number;  // Total knobs + sliders
  knobCount: number;    // Number of rotary knobs
  sliderCount: number;  // Number of sliders
  buttonCount: number;
}

// Known PCPanel vendor ID (STMicroelectronics)
export const PCPANEL_VENDOR_ID = 0x0483;

// Known device profiles - add new devices here as they're discovered
export const KNOWN_DEVICES: DeviceProfile[] = [
  {
    vendorId: 0x0483,
    productId: 0xa3c5,
    name: 'PC Panel Pro',
    analogCount: 9,
    knobCount: 5,
    sliderCount: 4,
    buttonCount: 5,
  },
  // PC Panel Mini - uncomment and adjust when verified:
  // {
  //   vendorId: 0x0483,
  //   productId: 0x????,  // Need to discover this
  //   name: 'PC Panel Mini',
  //   analogCount: 4,
  //   knobCount: 4,
  //   sliderCount: 0,
  //   buttonCount: 4,
  // },
];

// Heuristic patterns for detecting unknown PCPanel devices
export const DETECTION_HINTS = {
  vendorIds: [0x0483], // STMicroelectronics - known PCPanel manufacturer
  productPatterns: [/pcpanel/i, /panel/i],
  manufacturerPatterns: [/pcpanel/i, /stmicroelectronics/i],
};

// Default profile for unknown devices (conservative - assumes Pro-sized device)
export const UNKNOWN_DEVICE_PROFILE: Omit<DeviceProfile, 'vendorId' | 'productId' | 'name'> = {
  analogCount: 9,
  knobCount: 5,
  sliderCount: 4,
  buttonCount: 5,
};

// ============================================================================
// Legacy exports for backward compatibility
// ============================================================================

// Primary device (PC Panel Pro) - kept for compatibility
export const VENDOR_ID = KNOWN_DEVICES[0].vendorId;
export const PRODUCT_ID = KNOWN_DEVICES[0].productId;
export const ANALOG_COUNT = KNOWN_DEVICES[0].analogCount;
export const BUTTON_COUNT = KNOWN_DEVICES[0].buttonCount;

// ============================================================================
// Protocol Constants
// ============================================================================

// Input message codes (device -> computer)
export const INPUT_CODE_KNOB_CHANGE = 0x01;
export const INPUT_CODE_BUTTON_CHANGE = 0x02;
export const INPUT_CODE_STATE_RESPONSE = 0x03;

// Output message codes (computer -> device)
export const OUTPUT_CODE_REQUEST_STATE = 0x01;

// Packet size
export const PACKET_SIZE = 64;

// ============================================================================
// Event Types
// ============================================================================

export interface KnobChangeEvent {
  type: 'knob-change';
  index: number; // 0-N
  value: number; // 0-255
}

export interface ButtonChangeEvent {
  type: 'button-change';
  index: number; // 0-N
  pressed: boolean;
}

export interface StateResponseEvent {
  type: 'state-response';
  analogValues: number[]; // N values, 0-255
  buttonStates: boolean[]; // M buttons
}

export type DeviceEvent = KnobChangeEvent | ButtonChangeEvent | StateResponseEvent;

// ============================================================================
// Packet Parsing
// ============================================================================

export function parseInputPacket(data: Buffer, profile?: DeviceProfile): DeviceEvent | null {
  if (data.length < 3) {
    return null;
  }

  const messageType = data[0];
  const index = data[1];
  const value = data[2];

  // Use provided profile or default to Pro settings
  const analogCount = profile?.analogCount ?? ANALOG_COUNT;
  const buttonCount = profile?.buttonCount ?? BUTTON_COUNT;

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
      // Full state response: analog values + button states
      if (data.length >= 1 + analogCount + buttonCount) {
        const analogValues: number[] = [];
        const buttonStates: boolean[] = [];

        for (let i = 0; i < analogCount; i++) {
          analogValues.push(data[1 + i]);
        }
        for (let i = 0; i < buttonCount; i++) {
          buttonStates.push(data[1 + analogCount + i] === 0x01);
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

// ============================================================================
// Device Profile Lookup
// ============================================================================

export function findDeviceProfile(vendorId: number, productId: number): DeviceProfile | null {
  return KNOWN_DEVICES.find(
    d => d.vendorId === vendorId && d.productId === productId
  ) ?? null;
}

export function getDeviceProfileOrDefault(vendorId: number, productId: number, name?: string): DeviceProfile {
  const known = findDeviceProfile(vendorId, productId);
  if (known) return known;

  // Return default profile for unknown device
  return {
    vendorId,
    productId,
    name: name ?? `Unknown PCPanel (${vendorId.toString(16)}:${productId.toString(16)})`,
    ...UNKNOWN_DEVICE_PROFILE,
  };
}

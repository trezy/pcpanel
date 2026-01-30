import HID from 'node-hid';
import {
  KNOWN_DEVICES,
  DETECTION_HINTS,
  DeviceProfile,
  findDeviceProfile,
  getDeviceProfileOrDefault,
} from './protocol';

export interface PCPanelDevice {
  path: string;
  vendorId: number;
  productId: number;
  serialNumber?: string;
  productName?: string;
  manufacturer?: string;
  profile: DeviceProfile;
  isKnown: boolean;          // True if this is a known device type
  isPotentialPCPanel: boolean; // True if detected via heuristics
}

export interface UnknownDeviceReport {
  vendorId: number;
  productId: number;
  manufacturer?: string;
  product?: string;
  serialNumber?: string;
  detectionMethod: 'heuristic';
  timestamp: string;
}

// Store for unknown devices we've seen (to report only once per session)
const reportedUnknownDevices = new Set<string>();

/**
 * Determines if a HID device might be a PCPanel device based on heuristics.
 * Used as fallback when the device isn't in our known devices list.
 */
function isPotentialPCPanelDevice(device: HID.Device): boolean {
  // Check vendor ID
  if (DETECTION_HINTS.vendorIds.includes(device.vendorId)) {
    // Check product name patterns
    if (device.product) {
      for (const pattern of DETECTION_HINTS.productPatterns) {
        if (pattern.test(device.product)) {
          return true;
        }
      }
    }

    // Check manufacturer patterns
    if (device.manufacturer) {
      for (const pattern of DETECTION_HINTS.manufacturerPatterns) {
        if (pattern.test(device.manufacturer)) {
          return true;
        }
      }
    }
  }

  return false;
}

/**
 * Check if a device is a known PCPanel device
 */
function isKnownDevice(device: HID.Device): boolean {
  return KNOWN_DEVICES.some(
    known => known.vendorId === device.vendorId && known.productId === device.productId
  );
}

/**
 * Scan for all PCPanel devices (known and potential)
 */
export async function scanForDevices(): Promise<PCPanelDevice[]> {
  const hidDevices = await HID.devicesAsync();
  return processDevices(hidDevices);
}

/**
 * Synchronous version of scanForDevices
 */
export function scanForDevicesSync(): PCPanelDevice[] {
  const hidDevices = HID.devices();
  return processDevices(hidDevices);
}

/**
 * Process HID device list and return PCPanel devices
 */
function processDevices(hidDevices: HID.Device[]): PCPanelDevice[] {
  const results: PCPanelDevice[] = [];
  const seenPaths = new Set<string>();

  for (const device of hidDevices) {
    if (!device.path || seenPaths.has(device.path)) continue;
    seenPaths.add(device.path);

    const isKnown = isKnownDevice(device);
    const isPotential = !isKnown && isPotentialPCPanelDevice(device);

    if (isKnown || isPotential) {
      const profile = isKnown
        ? findDeviceProfile(device.vendorId, device.productId)!
        : getDeviceProfileOrDefault(device.vendorId, device.productId, device.product);

      results.push({
        path: device.path,
        vendorId: device.vendorId,
        productId: device.productId,
        serialNumber: device.serialNumber,
        productName: device.product,
        manufacturer: device.manufacturer,
        profile,
        isKnown,
        isPotentialPCPanel: isPotential,
      });

      // Log unknown devices for reporting
      if (isPotential) {
        logUnknownDevice(device);
      }
    }
  }

  return results;
}

/**
 * Log unknown devices that were detected via heuristics.
 * This helps identify new device types to add support for.
 */
function logUnknownDevice(device: HID.Device): void {
  const key = `${device.vendorId}:${device.productId}`;
  if (reportedUnknownDevices.has(key)) return;
  reportedUnknownDevices.add(key);

  const report: UnknownDeviceReport = {
    vendorId: device.vendorId,
    productId: device.productId,
    manufacturer: device.manufacturer,
    product: device.product,
    serialNumber: device.serialNumber,
    detectionMethod: 'heuristic',
    timestamp: new Date().toISOString(),
  };

  console.log('=== Unknown PCPanel-like device detected ===');
  console.log(JSON.stringify(report, null, 2));
  console.log('Please report this to the developer to add support!');
  console.log('============================================');
}

/**
 * Get all unknown devices that have been detected this session.
 * Useful for showing the user what new devices were found.
 */
export function getUnknownDeviceKeys(): string[] {
  return Array.from(reportedUnknownDevices);
}

/**
 * Scan all HID devices and return any that might be PCPanel devices
 * (for debugging/discovery purposes)
 */
export async function scanAllHIDDevices(): Promise<HID.Device[]> {
  const devices = await HID.devicesAsync();

  // Filter to just STMicroelectronics devices (the known PCPanel manufacturer)
  return devices.filter(d =>
    DETECTION_HINTS.vendorIds.includes(d.vendorId)
  );
}

/**
 * Utility to generate a device fingerprint for debugging
 */
export function getDeviceFingerprint(device: HID.Device): string {
  return [
    `VID:0x${device.vendorId.toString(16).padStart(4, '0')}`,
    `PID:0x${device.productId.toString(16).padStart(4, '0')}`,
    device.manufacturer ?? 'Unknown Mfr',
    device.product ?? 'Unknown Product',
  ].join(' | ');
}

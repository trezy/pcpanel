import HID from 'node-hid';
import { VENDOR_ID, PRODUCT_ID } from './protocol';

export interface PCPanelDevice {
  path: string;
  serialNumber?: string;
  productName?: string;
}

export async function scanForDevices(): Promise<PCPanelDevice[]> {
  const devices = await HID.devicesAsync();

  return devices
    .filter(device =>
      device.vendorId === VENDOR_ID &&
      device.productId === PRODUCT_ID &&
      device.path
    )
    .map(device => ({
      path: device.path!,
      serialNumber: device.serialNumber,
      productName: device.product,
    }));
}

export function scanForDevicesSync(): PCPanelDevice[] {
  const devices = HID.devices();

  return devices
    .filter(device =>
      device.vendorId === VENDOR_ID &&
      device.productId === PRODUCT_ID &&
      device.path
    )
    .map(device => ({
      path: device.path!,
      serialNumber: device.serialNumber,
      productName: device.product,
    }));
}

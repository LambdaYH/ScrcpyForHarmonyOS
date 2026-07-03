import { common } from '@kit.AbilityKit';
import { connection, mdns } from '@kit.NetworkKit';
import { Device, ExtraParam } from '../entity/Device';
import { LoggerAdbManage } from './Logger';

const TRADITIONAL_ADB_SERVICE_TYPE: string = '_adb._tcp';
const WIRELESS_ADB_CONNECT_SERVICE_TYPE: string = '_adb-tls-connect._tcp';
const WIRELESS_ADB_DISCOVERY_TIMEOUT_MS: number = 4000;

export function extractHostFromHostPort(hostPort: string): string {
  const value = hostPort.trim();
  if (value.startsWith('[')) {
    const endIndex = value.indexOf(']');
    return endIndex > 0 ? value.substring(1, endIndex).trim() : value;
  }

  const separatorIndex = value.lastIndexOf(':');
  return separatorIndex > 0 && separatorIndex === value.indexOf(':') ? value.substring(0, separatorIndex).trim() : value;
}

export function extractPortFromHostPort(hostPort: string): string {
  const value = hostPort.trim();
  if (value.startsWith('[')) {
    const endIndex = value.indexOf(']');
    return endIndex > 0 && value.charAt(endIndex + 1) === ':' && endIndex + 2 < value.length ?
      value.substring(endIndex + 2).trim() : '';
  }

  const separatorIndex = value.lastIndexOf(':');
  return separatorIndex > 0 && separatorIndex === value.indexOf(':') ? value.substring(separatorIndex + 1).trim() : '';
}

export function normalizeWirelessAdbAddress(address: string): string {
  let trimmed = address.trim();
  if (trimmed.startsWith('[')) {
    const endIndex = trimmed.indexOf(']');
    if (endIndex > 0) {
      trimmed = trimmed.substring(1, endIndex).trim();
    }
  }
  const scopeIndex = trimmed.indexOf('%');
  if (scopeIndex > 0) {
    trimmed = trimmed.substring(0, scopeIndex);
  }
  return trimmed.toLowerCase();
}

export function formatWirelessAdbHostPort(host: string, port: number | string): string {
  const trimmedHost = host.trim();
  const trimmedPort = String(port).trim();
  if (trimmedHost.includes(':') && !(trimmedHost.startsWith('[') && trimmedHost.endsWith(']'))) {
    return `[${trimmedHost}]:${trimmedPort}`;
  }
  return `${trimmedHost}:${trimmedPort}`;
}

export async function resolvePreferredLocalIp(): Promise<string> {
  const netHandle = await connection.getDefaultNet();
  if (!netHandle || netHandle.netId === 0) {
    throw new Error('No default network');
  }

  const properties = await connection.getConnectionProperties(netHandle);
  const linkAddresses = properties.linkAddresses ?? [];
  let fallbackIp = '';
  for (const address of linkAddresses) {
    const ip = address.address?.address ?? '';
    if (!ip || ip === '127.0.0.1' || ip === '::1') {
      continue;
    }
    if (!fallbackIp) {
      fallbackIp = ip;
    }
    if (ip.includes('.') && !ip.startsWith('169.254.')) {
      return ip;
    }
  }

  if (fallbackIp) {
    return fallbackIp;
  }

  throw new Error('No available local ip');
}

function buildWirelessAdbHostPortFromService(serviceInfo: mdns.LocalServiceInfo): string {
  const host = serviceInfo.host?.address?.trim() ?? '';
  const port = typeof serviceInfo.port === 'number' ? serviceInfo.port : 0;
  if (!host || !Number.isInteger(port) || port <= 0) {
    return '';
  }
  return formatWirelessAdbHostPort(host, port);
}

function sortWirelessAdbConnectHostPorts(hostPorts: string[], preferredHost: string): string[] {
  if (!preferredHost.trim()) {
    return hostPorts;
  }
  const normalizedPreferredHost = normalizeWirelessAdbAddress(preferredHost);
  const matched: string[] = [];
  const others: string[] = [];
  hostPorts.forEach((hostPort) => {
    const host = extractHostFromHostPort(hostPort);
    if (normalizeWirelessAdbAddress(host) === normalizedPreferredHost) {
      matched.push(hostPort);
    } else {
      others.push(hostPort);
    }
  });
  return [...matched, ...others];
}

function describeWirelessAdbService(serviceInfo: mdns.LocalServiceInfo): string {
  const serviceName = serviceInfo.serviceName ?? '';
  const serviceType = serviceInfo.serviceType ?? '';
  const hostAddress = serviceInfo.host?.address ?? '';
  const port = typeof serviceInfo.port === 'number' ? String(serviceInfo.port) : '';
  return `serviceName=${serviceName} serviceType=${serviceType} host=${hostAddress} port=${port}`;
}

async function discoverAdbMdnsHostPorts(context: common.UIAbilityContext,
  serviceType: string,
  preferredHost: string = '',
  timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<string[]> {
  const discoveryService = mdns.createDiscoveryService(context, serviceType);
  const discoveredHostPorts = new Set<string>();
  let settled = false;
  let timerId: number | undefined = undefined;
  LoggerAdbManage.info(`MDNS discover start serviceType=${serviceType} preferredHost=${preferredHost || '-'} timeoutMs=${timeoutMs}`);

  return await new Promise<string[]>((resolve, reject) => {
    const finish = (hostPorts: string[], error?: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timerId !== undefined) {
        clearTimeout(timerId);
      }
      try {
        discoveryService.stopSearchingMDNS();
      } catch (_) {
      }
      try {
        discoveryService.off('serviceFound', onServiceFound);
      } catch (_) {
      }
      try {
        discoveryService.off('serviceLost', onServiceLost);
      } catch (_) {
      }
      if (error) {
        reject(error);
        return;
      }
      const sortedHostPorts = sortWirelessAdbConnectHostPorts(hostPorts, preferredHost);
      LoggerAdbManage.info(`MDNS discover finish serviceType=${serviceType} foundCount=${sortedHostPorts.length} preferredHost=${preferredHost || '-'} hostPorts=${sortedHostPorts.join(',') || '-'}`);
      if (sortedHostPorts.length === 0) {
        reject(new Error('ADB connect service not found'));
        return;
      }
      resolve(sortedHostPorts);
    };

    const onServiceLost = (serviceInfo: mdns.LocalServiceInfo): void => {
      LoggerAdbManage.info(`MDNS service lost ${describeWirelessAdbService(serviceInfo)}`);
      const hostPort = buildWirelessAdbHostPortFromService(serviceInfo);
      if (hostPort) {
        discoveredHostPorts.delete(hostPort);
      }
    };

    const onServiceFound = (serviceInfo: mdns.LocalServiceInfo): void => {
      LoggerAdbManage.info(`MDNS service found ${describeWirelessAdbService(serviceInfo)}`);
      mdns.resolveLocalService(context, serviceInfo).then((resolvedService) => {
        if (settled) {
          return;
        }
        LoggerAdbManage.info(`MDNS service resolved ${describeWirelessAdbService(resolvedService)}`);
        const hostPort = buildWirelessAdbHostPortFromService(resolvedService);
        if (!hostPort) {
          LoggerAdbManage.warn('MDNS resolved service missing host/port, skipped');
          return;
        }
        discoveredHostPorts.add(hostPort);
        if (preferredHost.trim()) {
          const host = extractHostFromHostPort(hostPort);
          if (normalizeWirelessAdbAddress(host) === normalizeWirelessAdbAddress(preferredHost)) {
            LoggerAdbManage.info(`MDNS preferred host matched hostPort=${hostPort}`);
            finish(Array.from(discoveredHostPorts));
          } else {
            LoggerAdbManage.info(`MDNS preferred host mismatch preferredHost=${preferredHost} discoveredHost=${host}`);
          }
        }
      }).catch((err: Error) => {
        LoggerAdbManage.warn(`MDNS resolve service failed: ${err.message}`);
      });
    };

    try {
      discoveryService.on('serviceFound', onServiceFound);
      discoveryService.on('serviceLost', onServiceLost);
      discoveryService.startSearchingMDNS();
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbManage.error(`MDNS discover start failed serviceType=${serviceType}: ${error.message}`);
      finish([], error);
      return;
    }

    timerId = setTimeout(() => {
      LoggerAdbManage.warn(`MDNS discover timeout serviceType=${serviceType} foundCount=${discoveredHostPorts.size} preferredHost=${preferredHost || '-'}`);
      finish(Array.from(discoveredHostPorts));
    }, timeoutMs);
  });
}

export async function discoverWirelessAdbConnectHostPorts(context: common.UIAbilityContext,
  preferredHost: string = '',
  timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<string[]> {
  return await discoverAdbMdnsHostPorts(context, WIRELESS_ADB_CONNECT_SERVICE_TYPE, preferredHost, timeoutMs);
}

export async function discoverWirelessAdbConnectHostPort(context: common.UIAbilityContext,
  preferredHost: string = '',
  timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<string> {
  const hostPorts = await discoverWirelessAdbConnectHostPorts(context, preferredHost, timeoutMs);
  if (!hostPorts.length) {
    throw new Error('ADB connect service not found');
  }
  return hostPorts[0];
}

export async function discoverTraditionalAdbHostPorts(context: common.UIAbilityContext,
  preferredHost: string = '',
  timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<string[]> {
  return await discoverAdbMdnsHostPorts(context, TRADITIONAL_ADB_SERVICE_TYPE, preferredHost, timeoutMs);
}

export function cloneDeviceForWirelessAdb(device: Device): Device {
  const cloned = new Device(device.uuid, device.type);
  cloned.uuid = device.uuid;
  cloned.name = device.name;
  cloned.address = device.address;
  cloned.adbPort = device.adbPort;
  cloned.type = device.type;
  cloned.videoCodec = device.videoCodec;
  cloned.maxSize = device.maxSize;
  cloned.maxFps = device.maxFps;
  cloned.maxVideoBit = device.maxVideoBit;
  cloned.crop = device.crop;
  cloned.displayId = device.displayId;
  cloned.captureOrientation = device.captureOrientation;
  cloned.showBottomNavBar = device.showBottomNavBar;
  cloned.autoSwitchOrientation = device.autoSwitchOrientation;
  cloned.fileReceivePath = device.fileReceivePath;
  cloned.isAudio = device.isAudio;
  cloned.audioCodec = device.audioCodec;
  cloned.maxAudioBit = device.maxAudioBit;
  cloned.wakeOnConnect = device.wakeOnConnect;
  cloned.lightOffOnConnect = device.lightOffOnConnect;
  cloned.keepScreenOnWhileConnected = device.keepScreenOnWhileConnected;
  cloned.stayAwake = device.stayAwake;
  cloned.showTouches = device.showTouches;
  cloned.clipboardAutosync = device.clipboardAutosync;
  cloned.cleanup = device.cleanup;
  cloned.powerOffScreenOnClose = device.powerOffScreenOnClose;
  cloned.autoReconnect = device.autoReconnect;
  cloned.downsizeOnError = device.downsizeOnError;
  cloned.forceAdbForward = device.forceAdbForward;
  cloned.forcePhysicalKeyboard = device.forcePhysicalKeyboard;
  cloned.connectOnStart = device.connectOnStart;
  cloned.logLevel = device.logLevel;
  cloned.extraParams = device.extraParams.map((item: ExtraParam): ExtraParam => {
    return {
      key: item.key,
      value: item.value
    };
  });
  return cloned;
}

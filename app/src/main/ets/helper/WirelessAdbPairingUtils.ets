import { common } from '@kit.AbilityKit';
import { connection, mdns } from '@kit.NetworkKit';
import { Device, ExtraParam } from '../entity/Device';
import { LoggerAdbManage } from './Logger';

const TRADITIONAL_ADB_SERVICE_TYPE: string = '_adb._tcp';
const WIRELESS_ADB_CONNECT_SERVICE_TYPE: string = '_adb-tls-connect._tcp';
const WIRELESS_ADB_PAIRING_SERVICE_TYPE: string = '_adb-tls-pairing._tcp';
const WIRELESS_ADB_DISCOVERY_TIMEOUT_MS: number = 4000;

export interface WirelessAdbEndpoint {
  host: string;
  port: string;
  hostPort: string;
}

export interface NearbyAdbDiscoverySession {
  stop(): void;
}

class NearbyAdbDiscoverySessionImpl implements NearbyAdbDiscoverySession {
  private readonly stopHandler: () => void;

  constructor(stopHandler: () => void) {
    this.stopHandler = stopHandler;
  }

  stop(): void {
    this.stopHandler();
  }
}

export function parseWirelessAdbEndpoint(hostPort: string): WirelessAdbEndpoint | null {
  const value = hostPort.trim();
  if (!value) {
    return null;
  }

  if (value.startsWith('[')) {
    const endIndex = value.indexOf(']');
    if (endIndex <= 0 || value.charAt(endIndex + 1) !== ':' || endIndex + 2 >= value.length) {
      return null;
    }
    const host = value.substring(1, endIndex).trim();
    const port = value.substring(endIndex + 2).trim();
    return host && port ? { host, port, hostPort: formatWirelessAdbHostPort(host, port) } : null;
  }

  const separatorIndex = value.lastIndexOf(':');
  if (separatorIndex <= 0 || separatorIndex !== value.indexOf(':')) {
    return null;
  }
  const host = value.substring(0, separatorIndex).trim();
  const port = value.substring(separatorIndex + 1).trim();
  return host && port ? { host, port, hostPort: formatWirelessAdbHostPort(host, port) } : null;
}

export function createWirelessAdbEndpoint(host: string, port: number | string): WirelessAdbEndpoint | null {
  const trimmedHost = host.trim();
  const trimmedPort = String(port).trim();
  if (!trimmedHost || !trimmedPort) {
    return null;
  }
  return {
    host: trimmedHost,
    port: trimmedPort,
    hostPort: formatWirelessAdbHostPort(trimmedHost, trimmedPort)
  };
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

function buildWirelessAdbEndpointFromService(serviceInfo: mdns.LocalServiceInfo): WirelessAdbEndpoint | null {
  const host = serviceInfo.host?.address?.trim() ?? '';
  const port = typeof serviceInfo.port === 'number' ? serviceInfo.port : 0;
  if (!host || !Number.isInteger(port) || port <= 0) {
    return null;
  }
  return createWirelessAdbEndpoint(host, port);
}

function sortWirelessAdbConnectEndpoints(endpoints: WirelessAdbEndpoint[], preferredHost: string): WirelessAdbEndpoint[] {
  if (!preferredHost.trim()) {
    return endpoints;
  }
  const normalizedPreferredHost = normalizeWirelessAdbAddress(preferredHost);
  const matched: WirelessAdbEndpoint[] = [];
  const others: WirelessAdbEndpoint[] = [];
  endpoints.forEach((endpoint) => {
    if (normalizeWirelessAdbAddress(endpoint.host) === normalizedPreferredHost) {
      matched.push(endpoint);
    } else {
      others.push(endpoint);
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

function sortNearbyWirelessAdbEndpoints(endpoints: Iterable<WirelessAdbEndpoint>): WirelessAdbEndpoint[] {
  return Array.from(endpoints).sort((left, right) => left.hostPort.localeCompare(right.hostPort));
}

interface NearbyAdbDiscoveryTracker {
  serviceType: string;
  discoveryService: mdns.DiscoveryService;
  discoveredEndpoints: Map<string, WirelessAdbEndpoint>;
  onServiceFound?: (serviceInfo: mdns.LocalServiceInfo) => void;
  onServiceLost?: (serviceInfo: mdns.LocalServiceInfo) => void;
}

function stopNearbyAdbDiscoveryTracker(tracker: NearbyAdbDiscoveryTracker): void {
  try {
    if (tracker.onServiceFound) {
      tracker.discoveryService.off('serviceFound', tracker.onServiceFound);
    }
  } catch (_) {
  }
  try {
    if (tracker.onServiceLost) {
      tracker.discoveryService.off('serviceLost', tracker.onServiceLost);
    }
  } catch (_) {
  }
  try {
    tracker.discoveryService.stopSearchingMDNS();
  } catch (_) {
  }
}

export function startNearbyAdbDiscovery(context: common.UIAbilityContext,
  onUpdate: (activeEndpoints: WirelessAdbEndpoint[]) => void,
  onError: (error: Error) => void): NearbyAdbDiscoverySession {
  const trackers: NearbyAdbDiscoveryTracker[] = [
    {
      serviceType: TRADITIONAL_ADB_SERVICE_TYPE,
      discoveryService: mdns.createDiscoveryService(context, TRADITIONAL_ADB_SERVICE_TYPE),
      discoveredEndpoints: new Map<string, WirelessAdbEndpoint>()
    },
    {
      serviceType: WIRELESS_ADB_CONNECT_SERVICE_TYPE,
      discoveryService: mdns.createDiscoveryService(context, WIRELESS_ADB_CONNECT_SERVICE_TYPE),
      discoveredEndpoints: new Map<string, WirelessAdbEndpoint>()
    }
  ];
  let stopped: boolean = false;

  const emitUpdate = (): void => {
    if (stopped) {
      return;
    }
    const mergedEndpoints = new Map<string, WirelessAdbEndpoint>();
    trackers.forEach((tracker) => {
      tracker.discoveredEndpoints.forEach((endpoint) => mergedEndpoints.set(endpoint.hostPort, endpoint));
    });
    onUpdate(sortNearbyWirelessAdbEndpoints(mergedEndpoints.values()));
  };

  const stopAll = (): void => {
    if (stopped) {
      return;
    }
    stopped = true;
    trackers.forEach((tracker) => stopNearbyAdbDiscoveryTracker(tracker));
  };

  trackers.forEach((tracker) => {
    tracker.onServiceLost = (serviceInfo: mdns.LocalServiceInfo): void => {
      LoggerAdbManage.info(`MDNS nearby service lost ${describeWirelessAdbService(serviceInfo)}`);
      const endpoint = buildWirelessAdbEndpointFromService(serviceInfo);
      if (!endpoint) {
        return;
      }
      tracker.discoveredEndpoints.delete(endpoint.hostPort);
      emitUpdate();
    };

    tracker.onServiceFound = (serviceInfo: mdns.LocalServiceInfo): void => {
      LoggerAdbManage.info(`MDNS nearby service found ${describeWirelessAdbService(serviceInfo)}`);
      mdns.resolveLocalService(context, serviceInfo).then((resolvedService) => {
        if (stopped) {
          return;
        }
        const endpoint = buildWirelessAdbEndpointFromService(resolvedService);
        if (!endpoint) {
          LoggerAdbManage.warn('MDNS nearby resolved service missing host/port, skipped');
          return;
        }
        tracker.discoveredEndpoints.set(endpoint.hostPort, endpoint);
        emitUpdate();
      }).catch((err: Error) => {
        LoggerAdbManage.warn(`MDNS nearby resolve service failed: ${err.message}`);
      });
    };

    try {
      tracker.discoveryService.on('serviceFound', tracker.onServiceFound);
      tracker.discoveryService.on('serviceLost', tracker.onServiceLost);
      tracker.discoveryService.startSearchingMDNS();
      LoggerAdbManage.info(`MDNS nearby discover started serviceType=${tracker.serviceType}`);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbManage.error(`MDNS nearby discover start failed serviceType=${tracker.serviceType}: ${error.message}`);
      stopAll();
      onError(error);
    }
  });

  emitUpdate();

  return new NearbyAdbDiscoverySessionImpl((): void => {
    stopAll();
  });
}

async function discoverAdbMdnsHostPorts(context: common.UIAbilityContext,
  serviceType: string,
  preferredHost: string = '',
  timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<WirelessAdbEndpoint[]> {
  const discoveryService = mdns.createDiscoveryService(context, serviceType);
  const discoveredEndpoints = new Map<string, WirelessAdbEndpoint>();
  let settled = false;
  let timerId: number | undefined = undefined;
  LoggerAdbManage.info(`MDNS discover start serviceType=${serviceType} preferredHost=${preferredHost || '-'} timeoutMs=${timeoutMs}`);

  return await new Promise<WirelessAdbEndpoint[]>((resolve, reject) => {
    const finish = (endpoints: WirelessAdbEndpoint[], error?: Error): void => {
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
      const sortedEndpoints = sortWirelessAdbConnectEndpoints(endpoints, preferredHost);
      LoggerAdbManage.info(`MDNS discover finish serviceType=${serviceType} foundCount=${sortedEndpoints.length} preferredHost=${preferredHost || '-'} hostPorts=${sortedEndpoints.map((endpoint) => endpoint.hostPort).join(',') || '-'}`);
      if (sortedEndpoints.length === 0) {
        reject(new Error('ADB connect service not found'));
        return;
      }
      resolve(sortedEndpoints);
    };

    const onServiceLost = (serviceInfo: mdns.LocalServiceInfo): void => {
      LoggerAdbManage.info(`MDNS service lost ${describeWirelessAdbService(serviceInfo)}`);
      const endpoint = buildWirelessAdbEndpointFromService(serviceInfo);
      if (endpoint) {
        discoveredEndpoints.delete(endpoint.hostPort);
      }
    };

    const onServiceFound = (serviceInfo: mdns.LocalServiceInfo): void => {
      LoggerAdbManage.info(`MDNS service found ${describeWirelessAdbService(serviceInfo)}`);
      mdns.resolveLocalService(context, serviceInfo).then((resolvedService) => {
        if (settled) {
          return;
        }
        LoggerAdbManage.info(`MDNS service resolved ${describeWirelessAdbService(resolvedService)}`);
        const endpoint = buildWirelessAdbEndpointFromService(resolvedService);
        if (!endpoint) {
          LoggerAdbManage.warn('MDNS resolved service missing host/port, skipped');
          return;
        }
        discoveredEndpoints.set(endpoint.hostPort, endpoint);
        if (preferredHost.trim()) {
          if (normalizeWirelessAdbAddress(endpoint.host) === normalizeWirelessAdbAddress(preferredHost)) {
            LoggerAdbManage.info(`MDNS preferred host matched hostPort=${endpoint.hostPort}`);
            finish(Array.from(discoveredEndpoints.values()));
          } else {
            LoggerAdbManage.info(`MDNS preferred host mismatch preferredHost=${preferredHost} discoveredHost=${endpoint.host}`);
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
      LoggerAdbManage.info(`MDNS discover timeout serviceType=${serviceType} foundCount=${discoveredEndpoints.size} preferredHost=${preferredHost || '-'}`);
      finish(Array.from(discoveredEndpoints.values()));
    }, timeoutMs);
  });
}

export async function discoverAdbMdnsEndpointByServiceName(context: common.UIAbilityContext,
  serviceType: string, serviceName: string, isCanceled?: () => boolean,
  timeoutMs: number = 0): Promise<WirelessAdbEndpoint> {
  const trimmedServiceName = serviceName.trim();
  if (!trimmedServiceName) {
    throw new Error('ADB mDNS service name is empty');
  }
  const discoveryService = mdns.createDiscoveryService(context, serviceType);
  let settled = false;
  let timeoutId: number | undefined = undefined;
  let cancelPollId: number | undefined = undefined;
  LoggerAdbManage.info(
    `MDNS discover specific start serviceType=${serviceType} serviceName=${trimmedServiceName} timeoutMs=${timeoutMs}`);

  return await new Promise<WirelessAdbEndpoint>((resolve, reject) => {
    const finish = (endpoint?: WirelessAdbEndpoint, error?: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timeoutId !== undefined) {
        clearTimeout(timeoutId);
      }
      if (cancelPollId !== undefined) {
        clearInterval(cancelPollId);
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
      if (!endpoint) {
        reject(new Error('ADB pairing service not found'));
        return;
      }
      LoggerAdbManage.info(
        `MDNS discover specific finish serviceType=${serviceType} serviceName=${trimmedServiceName} hostPort=${endpoint.hostPort}`);
      resolve(endpoint);
    };

    const onServiceLost = (serviceInfo: mdns.LocalServiceInfo): void => {
      if (serviceInfo.serviceName?.trim() === trimmedServiceName) {
        LoggerAdbManage.info(`MDNS specific service lost ${describeWirelessAdbService(serviceInfo)}`);
      }
    };

    const onServiceFound = (serviceInfo: mdns.LocalServiceInfo): void => {
      if (serviceInfo.serviceName?.trim() !== trimmedServiceName) {
        return;
      }
      LoggerAdbManage.info(`MDNS specific service found ${describeWirelessAdbService(serviceInfo)}`);
      mdns.resolveLocalService(context, serviceInfo).then((resolvedService) => {
        if (settled) {
          return;
        }
        LoggerAdbManage.info(`MDNS specific service resolved ${describeWirelessAdbService(resolvedService)}`);
        const endpoint = buildWirelessAdbEndpointFromService(resolvedService);
        if (!endpoint) {
          LoggerAdbManage.warn('MDNS specific resolved service missing host/port, skipped');
          return;
        }
        finish(endpoint);
      }).catch((err: Error) => {
        LoggerAdbManage.warn(`MDNS specific resolve service failed: ${err.message}`);
      });
    };

    try {
      discoveryService.on('serviceFound', onServiceFound);
      discoveryService.on('serviceLost', onServiceLost);
      discoveryService.startSearchingMDNS();
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbManage.error(`MDNS discover specific start failed serviceType=${serviceType}: ${error.message}`);
      finish(undefined, error);
      return;
    }

    if (timeoutMs > 0) {
      timeoutId = setTimeout(() => {
        LoggerAdbManage.info(
          `MDNS discover specific timeout serviceType=${serviceType} serviceName=${trimmedServiceName}`);
        finish(undefined, new Error('ADB pairing service not found'));
      }, timeoutMs);
    }
    if (isCanceled) {
      cancelPollId = setInterval(() => {
        if (settled || !isCanceled()) {
          return;
        }
        LoggerAdbManage.info(
          `MDNS discover specific canceled serviceType=${serviceType} serviceName=${trimmedServiceName}`);
        finish(undefined, new Error('QR pairing canceled'));
      }, 200);
    }
  });
}

export async function discoverWirelessAdbConnectHostPorts(context: common.UIAbilityContext,
  preferredHost: string = '',
  timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<WirelessAdbEndpoint[]> {
  return await discoverAdbMdnsHostPorts(context, WIRELESS_ADB_CONNECT_SERVICE_TYPE, preferredHost, timeoutMs);
}

export async function discoverWirelessAdbConnectHostPort(context: common.UIAbilityContext,
  preferredHost: string = '',
  timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<WirelessAdbEndpoint> {
  const endpoints = await discoverWirelessAdbConnectHostPorts(context, preferredHost, timeoutMs);
  if (!endpoints.length) {
    throw new Error('ADB connect service not found');
  }
  return endpoints[0];
}

export async function discoverTraditionalAdbHostPorts(context: common.UIAbilityContext,
  preferredHost: string = '',
  timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<WirelessAdbEndpoint[]> {
  return await discoverAdbMdnsHostPorts(context, TRADITIONAL_ADB_SERVICE_TYPE, preferredHost, timeoutMs);
}

export async function discoverQrPairingHostPort(context: common.UIAbilityContext, serviceName: string,
  isCanceled?: () => boolean, timeoutMs: number = 0): Promise<WirelessAdbEndpoint> {
  return await discoverAdbMdnsEndpointByServiceName(context, WIRELESS_ADB_PAIRING_SERVICE_TYPE, serviceName, isCanceled,
    timeoutMs);
}

export async function discoverWirelessAdbConnectHostPortByServiceName(context: common.UIAbilityContext,
  serviceName: string, timeoutMs: number = WIRELESS_ADB_DISCOVERY_TIMEOUT_MS): Promise<WirelessAdbEndpoint> {
  return await discoverAdbMdnsEndpointByServiceName(context, WIRELESS_ADB_CONNECT_SERVICE_TYPE, serviceName, undefined,
    timeoutMs);
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

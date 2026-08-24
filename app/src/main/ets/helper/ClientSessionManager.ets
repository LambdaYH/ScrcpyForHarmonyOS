/* Multi-session lifecycle manager. */
import { NativeStreamClient } from '../client/tools/NativeStreamClient';
import { Device } from '../entity/Device';
import { LoggerClientSession } from './Logger';

export enum ClientSessionState {
  CONNECTING = 'CONNECTING', ACTIVE = 'ACTIVE', HOT_MINIMIZED = 'HOT_MINIMIZED',
  RESTORING = 'RESTORING', RECONNECTING = 'RECONNECTING',
  SUSPENDED = 'SUSPENDED', CLOSED = 'CLOSED'
}

export interface ClientSessionSnapshot {
  sessionId: string;
  device: Device;
  state: ClientSessionState;
  generation: number;
  lastActiveTime: number;
  lastError: string;
  hasClient: boolean;
  adbId: number;
  runtimeId: number;
}

export interface CreateSessionResult {
  sessionId?: string;
  limitReached: boolean;
  existing: boolean;
}

interface ClientSessionRecord {
  sessionId: string;
  device: Device;
  state: ClientSessionState;
  generation: number;
  lastActiveTime: number;
  lastError: string;
  client?: NativeStreamClient;
}

export type ClientSessionChangeListener = (sessions: ClientSessionSnapshot[]) => void;

export class ClientSessionManager {
  private static instance: ClientSessionManager;
  private sessions: Map<string, ClientSessionRecord> = new Map<string, ClientSessionRecord>();
  private listeners: Set<ClientSessionChangeListener> = new Set<ClientSessionChangeListener>();
  private activeSessionId?: string;
  private maxRetainedSessions: number = 3;
  private nextSessionSequence: number = 1;
  private heartbeatTimer: number = -1;
  private heartbeatInFlight: Set<string> = new Set<string>();
  private readonly HEARTBEAT_INTERVAL_MS: number = 15000;

  private constructor() {}

  public static getInstance(): ClientSessionManager {
    if (!ClientSessionManager.instance) {
      ClientSessionManager.instance = new ClientSessionManager();
    }
    return ClientSessionManager.instance;
  }

  public configure(maxRetainedSessions: number): void {
    this.maxRetainedSessions = Math.max(1, Math.min(6, Math.floor(maxRetainedSessions)));
    this.emitChange();
  }

  public getMaxRetainedSessions(): number { return this.maxRetainedSessions; }

  public createSession(device: Device): CreateSessionResult {
    const existing = this.findByDeviceUuid(device.uuid);
    if (existing) {
      existing.lastActiveTime = Date.now();
      this.emitChange();
      return { sessionId: existing.sessionId, limitReached: false, existing: true };
    }
    if (this.sessions.size >= this.maxRetainedSessions) {
      return { limitReached: true, existing: false };
    }
    const sessionId = `session-${this.nextSessionSequence++}-${device.uuid}`;
    this.sessions.set(sessionId, {
      sessionId, device, state: ClientSessionState.CONNECTING, generation: 1,
      lastActiveTime: Date.now(), lastError: ''
    });
    this.activeSessionId = sessionId;
    this.emitChange();
    return { sessionId, limitReached: false, existing: false };
  }

  public attachClient(sessionId: string, client: NativeStreamClient): boolean {
    const session = this.sessions.get(sessionId);
    if (!session || session.state === ClientSessionState.CLOSED) {
      client.stop();
      return false;
    }
    if (session.client && session.client !== client) session.client.stop();
    session.client = client;
    session.generation++;
    const generation = session.generation;
    client.setLifecycleListener((type: string, detail: string): void => {
      const current = this.sessions.get(sessionId);
      if (!current || current.generation !== generation || current.client !== client) return;
      current.lastError = detail;
      current.state = ClientSessionState.SUSPENDED;
      if (this.activeSessionId === sessionId) this.activeSessionId = undefined;
      LoggerClientSession.warn(`[ClientSessionManager] ${sessionId} ${type}: ${detail}`);
      this.refreshHeartbeatScheduler();
      this.emitChange();
    });
    client.setMinimizedListener((): void => {
      const current = this.sessions.get(sessionId);
      if (!current || current.generation !== generation || current.client !== client) return;
      if (current.state === ClientSessionState.SUSPENDED) return;
      current.state = ClientSessionState.HOT_MINIMIZED;
      current.lastActiveTime = Date.now();
      current.lastError = '';
      this.emitChange();
    });
    this.refreshHeartbeatScheduler();
    this.emitChange();
    return true;
  }

  public getClient(sessionId: string): NativeStreamClient | undefined { return this.sessions.get(sessionId)?.client; }
  public getSession(sessionId: string): ClientSessionSnapshot | undefined {
    const session = this.sessions.get(sessionId);
    return session ? this.toSnapshot(session) : undefined;
  }
  public findSessionByDeviceUuid(deviceUuid: string): ClientSessionSnapshot | undefined {
    const session = this.findByDeviceUuid(deviceUuid);
    return session ? this.toSnapshot(session) : undefined;
  }

  public beginRestore(sessionId: string): boolean {
    const session = this.sessions.get(sessionId);
    if (!session || session.state === ClientSessionState.CLOSED) return false;
    if (this.activeSessionId && this.activeSessionId !== sessionId) return false;
    LoggerClientSession.info(
      `[ClientSessionManager] beginRestore session=${sessionId} from=${session.state} active=${this.activeSessionId ?? ''}`
    );
    this.activeSessionId = sessionId;
    session.state = session.state === ClientSessionState.SUSPENDED
      ? ClientSessionState.RECONNECTING : ClientSessionState.RESTORING;
    session.lastActiveTime = Date.now();
    session.lastError = '';
    this.emitChange();
    return true;
  }

  public markActive(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    this.activeSessionId = sessionId;
    session.state = ClientSessionState.ACTIVE;
    session.lastActiveTime = Date.now();
    session.lastError = '';
    this.emitChange();
  }

  public markConnecting(sessionId: string, reconnecting: boolean = false): void {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    session.state = reconnecting ? ClientSessionState.RECONNECTING : ClientSessionState.CONNECTING;
    session.lastError = '';
    this.emitChange();
  }

  public markSuspended(sessionId: string, error: string): void {
    const session = this.sessions.get(sessionId);
    if (!session || session.state === ClientSessionState.CLOSED) return;
    session.state = ClientSessionState.SUSPENDED;
    session.lastError = error;
    session.lastActiveTime = Date.now();
    if (this.activeSessionId === sessionId) this.activeSessionId = undefined;
    this.refreshHeartbeatScheduler();
    this.emitChange();
  }

  public async minimizeSession(sessionId: string): Promise<boolean> {
    const session = this.sessions.get(sessionId);
    if (!session || !session.client) return false;
    const previousState = session.state;
    session.client.setListener(undefined);
    const hot = session.client.minimize();
    if (hot && session.client.isStreamRunning()) {
      session.state = ClientSessionState.HOT_MINIMIZED;
      session.lastError = '';
    } else if (session.state === ClientSessionState.ACTIVE) {
      session.state = ClientSessionState.SUSPENDED;
      session.lastError = 'Failed to keep session hot while minimizing';
    }
    session.lastActiveTime = Date.now();
    if (this.activeSessionId === sessionId) this.activeSessionId = undefined;
    LoggerClientSession.info(
      `[ClientSessionManager] minimize session=${sessionId} from=${previousState} to=${session.state} hot=${hot}`
    );
    this.refreshHeartbeatScheduler();
    this.emitChange();
    return true;
  }

  public replaceClientForReconnect(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    const client = session.client;
    session.client = undefined;
    session.generation++;
    session.state = ClientSessionState.RECONNECTING;
    client?.setListener(undefined);
    client?.setLifecycleListener(undefined);
    client?.setMinimizedListener(undefined);
    client?.stop();
    this.refreshHeartbeatScheduler();
    this.emitChange();
  }

  public async disconnectSession(sessionId: string): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) return;
    this.sessions.delete(sessionId);
    if (this.activeSessionId === sessionId) this.activeSessionId = undefined;
    session.state = ClientSessionState.CLOSED;
    session.generation++;
    session.client?.setListener(undefined);
    session.client?.setLifecycleListener(undefined);
    session.client?.setMinimizedListener(undefined);
    session.client?.stop();
    this.refreshHeartbeatScheduler();
    this.emitChange();
  }

  public async enterSystemBackground(): Promise<void> {
    if (this.activeSessionId) {
      const active = this.sessions.get(this.activeSessionId);
      if (active?.client) {
        active.client.setListener(undefined);
        const hot = active.client.minimize();
        active.state = hot && active.client.isStreamRunning()
          ? ClientSessionState.HOT_MINIMIZED : ClientSessionState.SUSPENDED;
        active.lastError = hot ? '' : 'Failed to keep session hot in system background';
        active.lastActiveTime = Date.now();
      }
      this.activeSessionId = undefined;
    }
    this.emitChange();
  }

  public leaveSystemBackground(): void {
    this.emitChange();
  }

  public subscribe(listener: ClientSessionChangeListener): () => void {
    this.listeners.add(listener);
    listener(this.listSessions());
    return (): void => { this.listeners.delete(listener); };
  }

  public listSessions(): ClientSessionSnapshot[] {
    return Array.from(this.sessions.values())
      .filter((session: ClientSessionRecord): boolean => session.state !== ClientSessionState.CLOSED)
      .sort((left: ClientSessionRecord, right: ClientSessionRecord): number =>
        right.lastActiveTime - left.lastActiveTime)
      .map((session: ClientSessionRecord): ClientSessionSnapshot => this.toSnapshot(session));
  }

  public hasRetainedSessions(): boolean { return this.sessions.size > 0; }
  public hasActiveSession(): boolean { return this.activeSessionId !== undefined; }
  public getCurrentClient(): NativeStreamClient | undefined {
    return this.activeSessionId ? this.sessions.get(this.activeSessionId)?.client : undefined;
  }

  public stopAll(): void {
    const sessions = Array.from(this.sessions.values());
    this.sessions.clear();
    this.activeSessionId = undefined;
    sessions.forEach((session: ClientSessionRecord): void => {
      session.client?.setListener(undefined);
      session.client?.setLifecycleListener(undefined);
      session.client?.setMinimizedListener(undefined);
      session.client?.stop();
    });
    this.refreshHeartbeatScheduler();
    this.emitChange();
  }

  private refreshHeartbeatScheduler(): void {
    const hasClient = Array.from(this.sessions.values()).some(
      (session: ClientSessionRecord): boolean => session.client !== undefined &&
        session.state !== ClientSessionState.CLOSED && session.state !== ClientSessionState.SUSPENDED
    );
    if (hasClient && this.heartbeatTimer === -1) {
      this.heartbeatTimer = setInterval((): void => {
        this.runHeartbeatCycle();
      }, this.HEARTBEAT_INTERVAL_MS) as number;
      return;
    }
    if (!hasClient && this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
      this.heartbeatInFlight.clear();
    }
  }

  private runHeartbeatCycle(): void {
    this.sessions.forEach((session: ClientSessionRecord): void => {
      if (!session.client || session.state === ClientSessionState.CLOSED ||
        session.state === ClientSessionState.SUSPENDED ||
        this.heartbeatInFlight.has(session.sessionId)) return;
      this.heartbeatInFlight.add(session.sessionId);
      void session.client.heartbeatAdb().then((alive: boolean): void => {
        if (!alive) {
          LoggerClientSession.warn(`[ClientSessionManager] ADB heartbeat unavailable session=${session.sessionId}`);
        }
      }).catch((error: Error): void => {
        LoggerClientSession.warn(`[ClientSessionManager] ADB heartbeat failed session=${session.sessionId}:`, error);
      }).finally((): void => {
        this.heartbeatInFlight.delete(session.sessionId);
      });
    });
  }

  private findByDeviceUuid(deviceUuid: string): ClientSessionRecord | undefined {
    return Array.from(this.sessions.values()).find((session: ClientSessionRecord): boolean =>
      session.device.uuid === deviceUuid && session.state !== ClientSessionState.CLOSED);
  }

  private toSnapshot(session: ClientSessionRecord): ClientSessionSnapshot {
    return {
      sessionId: session.sessionId, device: session.device, state: session.state,
      generation: session.generation, lastActiveTime: session.lastActiveTime,
      lastError: session.lastError, hasClient: session.client !== undefined,
      adbId: session.client?.getAdbId() ?? -1, runtimeId: session.client?.getRuntimeId() ?? -1
    };
  }

  private emitChange(): void {
    const snapshots = this.listSessions();
    this.listeners.forEach((listener: ClientSessionChangeListener): void => {
      try { listener(snapshots); }
      catch (error) { LoggerClientSession.error('[ClientSessionManager] listener failed:', error); }
    });
  }
}

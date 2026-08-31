/*
 * ClientSessionManager.ets
 * 
 * Manages the active native client session to ensure proper cleanup.
 * Prevents multiple sessions from running simultaneously and provides a global cleanup mechanism.
 */

import { NativeStreamClient } from '../client/tools/NativeStreamClient';
import { LoggerClientSession } from './Logger';

export type ClientSessionStateListener = (hasActiveSession: boolean) => void;

export class ClientSessionManager {
  private static instance: ClientSessionManager;
  private currentClient?: NativeStreamClient;
  private stateListeners: ClientSessionStateListener[] = [];

  private constructor() {}

  public static getInstance(): ClientSessionManager {
    if (!ClientSessionManager.instance) {
      ClientSessionManager.instance = new ClientSessionManager();
    }
    return ClientSessionManager.instance;
  }

  // Register a new client, stopping any existing one first
  public register(client: NativeStreamClient): void {
    if (this.currentClient && this.currentClient !== client) {
      LoggerClientSession.warn('[ClientSessionManager] Stopping previous client before registering new one');
      this.stopAll();
    }
    this.currentClient = client;
    LoggerClientSession.info('[ClientSessionManager] Client registered');
    this.notifyStateChanged();
  }

  // Unregister a client (usually called when it stops itself normally)
  public unregister(client: NativeStreamClient): void {
    if (this.currentClient === client) {
      this.currentClient = undefined;
      LoggerClientSession.info('[ClientSessionManager] Client unregistered');
      this.notifyStateChanged();
    }
  }

  // Force stop the current client
  public stopAll(): void {
    if (this.currentClient) {
      this.stop(this.currentClient);
    }
  }

  // Stop a client only when it still owns the current registration. A page that
  // is disappearing can race with a replacement page registering a new client;
  // identity checking prevents the old page from stopping the replacement.
  public stop(client: NativeStreamClient): boolean {
    if (this.currentClient !== client) {
      LoggerClientSession.info('[ClientSessionManager] Skip stopping stale client');
      return false;
    }

    this.currentClient = undefined;
    try {
      client.stop();
    } catch (e) {
      LoggerClientSession.error('[ClientSessionManager] Error stopping client:', e);
    }
    this.notifyStateChanged();
    return true;
  }

  public subscribe(listener: ClientSessionStateListener): () => void {
    this.stateListeners.push(listener);
    listener(this.hasActiveSession());
    return (): void => {
      this.stateListeners = this.stateListeners.filter((item: ClientSessionStateListener) => item !== listener);
    };
  }

  private notifyStateChanged(): void {
    const hasActiveSession = this.hasActiveSession();
    this.stateListeners.slice().forEach((listener: ClientSessionStateListener): void => {
      try {
        listener(hasActiveSession);
      } catch (err) {
        LoggerClientSession.error('[ClientSessionManager] State listener failed:', err);
      }
    });
  }

  // Check if there is an active session
  public hasActiveSession(): boolean {
    return !!this.currentClient;
  }

  public getCurrentClient(): NativeStreamClient | undefined {
    return this.currentClient;
  }
}

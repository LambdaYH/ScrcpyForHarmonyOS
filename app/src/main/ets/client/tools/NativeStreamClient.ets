import { Device } from '../../entity/Device';
import { ClientStream } from './ClientStream';
import { ControlPacket } from './ControlPacket';
import * as libscrcpy from 'libscrcpy_native.so';
import { ServerManager } from '../../helper/ServerManager';
import { LoggerClientStream } from '../../helper/Logger';

export interface NativeStreamListener {
  onVideoConfig: (width: number, height: number) => void;
  onDisconnect: (reason: string) => void;
  onError: (error: string) => void;
  onClipboard: (text: string) => void;
  onFirstFrame?: () => void;
  onWaitAuth?: () => void;
  onUhidOutput?: (data: string) => void;
}

type NativeEventCallback = (type: string, data: string) => void;
type NativeStartReverseStreamsFn = (
  runtimeId: number,
  adbId: number,
  expectVideo: boolean,
  expectAudio: boolean,
  expectControl: boolean,
  surfaceId: string,
  audioSampleRate: number,
  audioChannelCount: number,
  callback: NativeEventCallback
) => Promise<number>;
type AdbReverseFn = (adbId: number, socketName: string, port: number) => Promise<number>;
type AdbReverseRemoveFn = (adbId: number, socketName: string) => Promise<number>;
type StreamKind = 'video' | 'audio' | 'control' | 'other';

export class NativeStreamClient {
  private static readonly REVERSE_READY_TIMEOUT_MS: number = 10000;
  private static readonly FORWARD_CONNECT_RETRY_DELAY_MS: number = 100;
  private static readonly FALLBACK_SERVER_COOLDOWN_MS: number = 300;
  private clientStream: ClientStream;
  private runtimeId: number;
  private device: Device;
  private context: Context;
  private adbId: number = -1;
  private listener?: NativeStreamListener;
  // A HOT restore reuses the running native stream, so scrcpy does not send
  // another codec configuration when a new ControlPage attaches. Keep the
  // latest dimensions here and replay them to each newly-bound page.
  private lastVideoWidth: number = 0;
  private lastVideoHeight: number = 0;
  private reverseReadyPending: boolean = false;
  private reverseReadyResolve?: () => void;
  private reverseReadyReject?: (error: Error) => void;
  private stopped: boolean = false;
  private startGeneration: number = 0;
  private lifecycleListener?: (type: string, detail: string) => void;
  private minimizedListener?: () => void;
  private minimizeRequested: boolean = false;
  
  // Stream IDs
  private videoStreamId: number = -1;
  private audioStreamId: number = -1;
  private controlStreamId: number = -1;

  constructor(context: Context, device: Device, listener?: NativeStreamListener) {
    this.context = context;
    this.device = device;
    this.listener = listener;
    this.clientStream = new ClientStream(device);
    this.runtimeId = libscrcpy.nativeCreateRuntime();
  }

  getRuntimeId(): number {
    return this.runtimeId;
  }

  setListener(listener?: NativeStreamListener): void {
    this.listener = listener;
    if (listener && this.lastVideoWidth > 0 && this.lastVideoHeight > 0) {
      LoggerClientStream.info(
        `[NativeStreamClient] Replaying cached video size ${this.lastVideoWidth}x${this.lastVideoHeight}`
      );
      listener.onVideoConfig(this.lastVideoWidth, this.lastVideoHeight);
    }
  }

  setLifecycleListener(listener?: (type: string, detail: string) => void): void {
    this.lifecycleListener = listener;
  }

  setMinimizedListener(listener?: () => void): void {
    this.minimizedListener = listener;
  }

  getAdbId(): number {
    return this.clientStream.getAdbId();
  }

  isAdbReady(): boolean {
    return this.clientStream.isAdbReady();
  }

  async heartbeatAdb(): Promise<boolean> {
    return await this.clientStream.heartbeatAdb();
  }

  isStreamRunning(): boolean {
    return this.runtimeId >= 0 && libscrcpy.nativeIsRuntimeRunning(this.runtimeId);
  }

  minimize(): boolean {
    const running = this.isStreamRunning();
    LoggerClientStream.info(
      `[NativeStreamClient] Minimize runtime=${this.runtimeId} running=${running} adbReady=${this.isAdbReady()}`
    );
    if (this.runtimeId < 0 || !running) {
      this.minimizeRequested = true;
      return false;
    }
    this.minimizeRequested = true;
    const result: number = libscrcpy.nativeMinimizeStreams(this.runtimeId);
    LoggerClientStream.info(`[NativeStreamClient] Minimize runtime=${this.runtimeId} result=${result}`);
    return result === 0;
  }

  resume(surfaceId: string): boolean {
    const running = this.isStreamRunning();
    LoggerClientStream.info(
      `[NativeStreamClient] Resume runtime=${this.runtimeId} running=${running} adbReady=${this.isAdbReady()}`
    );
    if (this.runtimeId < 0 || !running) {
      return false;
    }
    this.minimizeRequested = false;
    const result: number = libscrcpy.nativeAttachSurface(this.runtimeId, surfaceId);
    let activated: boolean = false;
    if (result === 0) {
      activated = libscrcpy.nativeSetActiveRuntime(this.runtimeId) as boolean;
    }
    LoggerClientStream.info(
      `[NativeStreamClient] Resume runtime=${this.runtimeId} result=${result} activated=${activated}`
    );
    return result === 0 && activated;
  }

  // Start the session
  async start(serverJarData: ArrayBuffer | null, surfaceId: string): Promise<void> {
    this.stopped = false;
    const generation = ++this.startGeneration;
    try {
      // 1. Prepare the server and reuse the connected ADB session.
      const reusingAdb = this.clientStream.isAdbReady();
      this.adbId = await this.clientStream.prepareServerForNative(this.context, serverJarData, () => {
          if (this.listener && this.listener.onWaitAuth) {
              this.listener.onWaitAuth();
          }
      });

      const eventCallback = this.createNativeEventCallback(generation);
      if (this.device.forceAdbForward) {
        LoggerClientStream.info('[NativeStreamClient] Tunnel mode: force-adb-forward enabled');
      } else {
        LoggerClientStream.info('[NativeStreamClient] Tunnel mode: trying reverse first');
      }
      const reverseStarted = this.device.forceAdbForward
        ? false
        : await this.tryStartReverse(surfaceId, eventCallback, generation,
          reusingAdb ? 5000 : NativeStreamClient.REVERSE_READY_TIMEOUT_MS);
      this.throwIfStoppedOrStale(generation);
      if (!reverseStarted) {
        // If a retained ADB transport cannot establish reverse sockets, avoid
        // retrying dozens of forward opens on the same aborted server.
        if (reusingAdb && !this.device.forceAdbForward) {
          throw new Error('Reused ADB stream restore failed');
        }
        LoggerClientStream.info('[NativeStreamClient] Tunnel mode: using forward');
        const args = ServerManager.buildServerArgs(this.device, true);
        await this.clientStream.startServer(args);
        await this.openNativeStreams();
        await this.startNativeProcessing(surfaceId, eventCallback);
      }
      this.throwIfStoppedOrStale(generation);

      if (this.device.lightOffOnConnect) {
        this.sendControl(ControlPacket.createSetDisplayPower(false));
      }
      if (this.minimizeRequested && this.runtimeId >= 0 && this.isStreamRunning()) {
        if (libscrcpy.nativeMinimizeStreams(this.runtimeId) === 0) {
          this.minimizedListener?.();
        }
      }
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.error('[NativeStreamClient] Start failed:', errMsg);
      this.stop();
      throw (err instanceof Error) ? err : new Error(String(err));
    }
  }

  // Stop the session
  stop(): void {
    try {
      this.stopped = true;
      this.minimizeRequested = false;
      this.startGeneration++;
      this.rejectReverseReady(new Error('Session stopped'));
      this.adbId = -1;
      void this.stopNativeAndClose();
    } catch (err) {
      LoggerClientStream.error('[NativeStreamClient] Stop global error:', err);
    }
  }

  private async stopNativeAndClose(): Promise<void> {
    const runtimeId = this.runtimeId;
    try {
      if (runtimeId >= 0) {
        await libscrcpy.nativeStopStreamsAsync(runtimeId);
      }
    } catch (e) {
      LoggerClientStream.error('[NativeStreamClient] nativeStopStreamsAsync failed:', e);
    }

    try {
      this.clientStream.close();
    } catch (e) {
      LoggerClientStream.error('[NativeStreamClient] clientStream close failed:', e);
    }
    if (runtimeId >= 0) {
      try {
        libscrcpy.nativeDestroyRuntime(runtimeId);
      } catch (e) {
        LoggerClientStream.error('[NativeStreamClient] nativeDestroyRuntime failed:', e);
      }
      if (this.runtimeId === runtimeId) {
        this.runtimeId = -1;
      }
    }
  }

  async pushFileFromFd(
    fd: number,
    fileSize: number,
    remotePath: string,
    onProgress?: (progress: number) => void
  ): Promise<void> {
    await this.clientStream.pushFileFromFd(fd, fileSize, remotePath, onProgress);
  }

  async listRemoteDirectory(remotePath: string): Promise<Array<libscrcpy.RemoteFileEntry>> {
    return await this.clientStream.listRemoteDirectory(remotePath);
  }

  async execShell(cmd: string): Promise<libscrcpy.AdbShellCommandResult> {
    return await this.clientStream.execShell(cmd);
  }

  async installPackageFromFd(
    fd: number,
    fileSize: number,
    remoteName: string,
    installArgs: string = '-r',
    onProgress?: (progress: number) => void
  ): Promise<libscrcpy.AdbInstallPackageResult> {
    return await this.clientStream.installPackageFromFd(fd, fileSize, remoteName, installArgs, onProgress);
  }

  private async tryStartReverse(
    surfaceId: string,
    eventCallback: NativeEventCallback,
    generation: number,
    readyTimeoutMs: number
  ): Promise<boolean> {
    const reverseArgs = ServerManager.buildServerArgs(this.device, false);
    const socketName = ServerManager.getSocketName();

    const reversePort: number = await this.callNativeStartReverseStreams(
      this.adbId,
      true,
      this.device.isAudio,
      true,
      surfaceId,
      48000,
      2,
      eventCallback
    );
    this.throwIfStoppedOrStale(generation);

    if (reversePort <= 0) {
      LoggerClientStream.warn(`[NativeStreamClient] Reverse listener start failed: ${reversePort}, fallback to forward`);
      libscrcpy.nativeStopStreams(this.runtimeId);
      return false;
    }

    let reverseResult: number;
    try {
      reverseResult = await this.callAdbReverse(this.adbId, socketName, reversePort);
    } catch (err) {
      this.throwIfStoppedOrStale(generation);
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.warn(`[NativeStreamClient] adb reverse threw: ${errMsg}, fallback to forward`);
      libscrcpy.nativeStopStreams(this.runtimeId);
      return false;
    }
    if (reverseResult !== 0) {
      this.throwIfStoppedOrStale(generation);
      LoggerClientStream.warn(`[NativeStreamClient] adb reverse failed: ${reverseResult}, fallback to forward`);
      libscrcpy.nativeStopStreams(this.runtimeId);
      return false;
    }

    LoggerClientStream.info(`[NativeStreamClient] Tunnel mode: using reverse`);
    const reverseReadyPromise = this.waitForReverseReady(readyTimeoutMs);
    await this.clientStream.startServer(reverseArgs);
    try {
      await reverseReadyPromise;
      this.throwIfStoppedOrStale(generation);
      return true;
    } catch (err) {
      if (this.isStoppedOrStale(generation)) {
        throw (err instanceof Error) ? err : new Error(String(err));
      }
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.warn(`[NativeStreamClient] Reverse startup incomplete: ${errMsg}, fallback to forward`);
      await this.clientStream.stopServerAndWait();
      if (!this.isStoppedOrStale(generation) && this.adbId >= 0) {
        await this.callAdbReverseRemove(this.adbId, socketName);
      }
      libscrcpy.nativeStopStreams(this.runtimeId);
      await new Promise<void>(resolve => setTimeout(resolve, NativeStreamClient.FALLBACK_SERVER_COOLDOWN_MS));
      this.throwIfStoppedOrStale(generation);
      return false;
    }
  }

  // Send control message (e.g. touch event)
  sendControl(data: ArrayBuffer): boolean {
    try {
      return this.runtimeId >= 0 && libscrcpy.nativeSendControl(this.runtimeId, data);
    } catch (err) {
      LoggerClientStream.error('[NativeStreamClient] Send control failed:', err);
      return false;
    }
  }

  private async openNativeStreams(): Promise<void> {
    const socketName = ServerManager.getSocketName(); // e.g. "scrcpy_12345678"

    // Retry while waiting for the server to listen on the abstract socket.
    let retries = 50; // 50 * 100ms = 5 seconds
    while (retries > 0) {
      this.videoStreamId = await this.tryOpenLocalSocket(socketName, 'video');
      if (this.videoStreamId >= 0) {
        break;
      }
      if (!this.clientStream.isServerShellAlive()) {
        throw new Error('Scrcpy server exited before video socket became ready');
      }
      retries--;
      if (retries === 0) {
        throw new Error("Failed to connect Video stream after multiple retries");
      }
      LoggerClientStream.warn(`[NativeStreamClient] Video stream connect failed, retrying... (${retries} left)`);
      await new Promise<void>(resolve => setTimeout(resolve, NativeStreamClient.FORWARD_CONNECT_RETRY_DELAY_MS));
    }
    
    LoggerClientStream.info(`[NativeStreamClient] Video Stream Connected`);

    // 2. Audio Stream
    if (this.device.isAudio) {
        this.audioStreamId = await this.tryOpenLocalSocket(socketName, 'audio');
        if (this.audioStreamId < 0) {
            LoggerClientStream.warn("Failed to connect Audio stream, disabling audio");
            this.audioStreamId = -1;
        } else {
            LoggerClientStream.info(`[NativeStreamClient] Audio Stream Connected`);
        }
    }

    // 3. Control Stream
    this.controlStreamId = await this.tryOpenLocalSocket(socketName, 'control');
    if (this.controlStreamId < 0) throw new Error("Failed to connect Control stream");
    LoggerClientStream.info(`[NativeStreamClient] Control Stream Connected`);
  }

  private async tryOpenLocalSocket(socketName: string, streamKind: StreamKind): Promise<number> {
    try {
      return await libscrcpy.adbLocalSocketForward(this.adbId, socketName, streamKind);
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.warn(`[NativeStreamClient] adbLocalSocketForward threw: ${errMsg}`);
      return -1;
    }
  }

  private createNativeEventCallback(generation: number): NativeEventCallback {
    return (type: string, data: string) => {
        if (generation !== this.startGeneration || this.stopped) {
            return;
        }
        switch (type) {
            case 'reverse_ready':
                this.resolveReverseReady();
                return;
            case 'disconnected':
                if (this.reverseReadyPending) {
                    this.rejectReverseReady(new Error('Reverse disconnected before ready'));
                    return;
                }
                if (this.lifecycleListener) {
                    this.lifecycleListener('disconnected', data || 'Server Disconnected');
                }
                break;
            case 'error':
                if (this.reverseReadyPending) {
                    this.rejectReverseReady(new Error(data));
                    return;
                }
                if (this.lifecycleListener) {
                    this.lifecycleListener('error', data);
                }
                break;
        }

        // Video size events must be retained even while the page listener is
        // detached. This also covers an orientation change while minimized.
        if (type === 'video_config' || type === 'video_size_changed') {
            try {
                interface VideoConfig { width: number; height: number; }
                const config = JSON.parse(data) as VideoConfig;
                if (config.width <= 0 || config.height <= 0) {
                    throw new Error(`Invalid video size ${config.width}x${config.height}`);
                }
                this.lastVideoWidth = config.width;
                this.lastVideoHeight = config.height;
                if (this.listener) {
                    this.listener.onVideoConfig(config.width, config.height);
                }
            } catch (e) {
                LoggerClientStream.error('Parse video config/size failed:', JSON.stringify(e));
            }
            return;
        }

        if (!this.listener) {
            return;
        }

        switch (type) {
            case 'clipboard':
                this.listener.onClipboard(data);
                break;
            case 'uhid_output':
                if (this.listener.onUhidOutput) {
                    this.listener.onUhidOutput(data);
                }
                break;
            case 'disconnected':
                this.listener.onDisconnect('Server Disconnected');
                break;
            case 'error':
                this.listener.onError(data);
                break;
            case 'first_frame':
                if (this.listener.onFirstFrame) {
                    this.listener.onFirstFrame();
                }
                break;
        }
    };
  }

  private async startNativeProcessing(
    surfaceId: string,
    eventCallback: NativeEventCallback
  ): Promise<void> {
    const res: number = await libscrcpy.nativeStartStreams(
        this.runtimeId,
        this.adbId,
        this.videoStreamId,
        this.audioStreamId, // -1 if disabled
        this.controlStreamId,
        surfaceId,
        48000,
        2,
        eventCallback
    );

    if (res !== 0) {
        throw new Error(`nativeStartStreams failed with code ${res}`);
    }
  }

  private async callNativeStartReverseStreams(
    adbId: number,
    expectVideo: boolean,
    expectAudio: boolean,
    expectControl: boolean,
    surfaceId: string,
    audioSampleRate: number,
    audioChannelCount: number,
    callback: NativeEventCallback
  ): Promise<number> {
    const nativeStartReverseStreams = libscrcpy.nativeStartReverseStreams as NativeStartReverseStreamsFn;
    return await nativeStartReverseStreams(
      this.runtimeId,
      adbId,
      expectVideo,
      expectAudio,
      expectControl,
      surfaceId,
      audioSampleRate,
      audioChannelCount,
      callback
    );
  }

  private async callAdbReverse(adbId: number, socketName: string, port: number): Promise<number> {
    const adbReverse = libscrcpy.adbReverse as AdbReverseFn;
    return await adbReverse(adbId, socketName, port);
  }

  private async callAdbReverseRemove(adbId: number, socketName: string): Promise<number> {
    const adbReverseRemove = libscrcpy.adbReverseRemove as AdbReverseRemoveFn;
    return await adbReverseRemove(adbId, socketName);
  }

  private isStoppedOrStale(generation: number): boolean {
    return this.stopped || generation !== this.startGeneration || this.adbId < 0;
  }

  private throwIfStoppedOrStale(generation: number): void {
    if (this.isStoppedOrStale(generation)) {
      throw new Error('Session stopped');
    }
  }

  private waitForReverseReady(timeoutMs: number): Promise<void> {
    this.rejectReverseReady(new Error('Restarting reverse wait'));
    this.reverseReadyPending = true;

    return new Promise<void>((resolve, reject) => {
      const timeoutId: number = setTimeout(() => {
        this.rejectReverseReady(new Error('Timed out waiting for reverse sockets'));
      }, timeoutMs) as number;

      this.reverseReadyResolve = () => {
        clearTimeout(timeoutId);
        this.reverseReadyPending = false;
        this.reverseReadyResolve = undefined;
        this.reverseReadyReject = undefined;
        resolve();
      };

      this.reverseReadyReject = (error: Error) => {
        clearTimeout(timeoutId);
        this.reverseReadyPending = false;
        this.reverseReadyResolve = undefined;
        this.reverseReadyReject = undefined;
        reject(error);
      };
    });
  }

  private resolveReverseReady(): void {
    if (!this.reverseReadyPending || !this.reverseReadyResolve) {
      return;
    }
    this.reverseReadyResolve();
  }

  private rejectReverseReady(error: Error): void {
    if (!this.reverseReadyPending || !this.reverseReadyReject) {
      return;
    }
    this.reverseReadyReject(error);
  }
}

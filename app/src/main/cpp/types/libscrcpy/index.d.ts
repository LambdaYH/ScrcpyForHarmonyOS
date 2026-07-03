export interface AdbShellCommandResult {
    exitCode: number;
    exitCodeReliable: boolean;
    stdout: string;
    stderr: string;
}

export interface AdbInstallPackageResult extends AdbShellCommandResult {
    success: boolean;
    remotePath: string;
}

export interface AdbQrPairingSessionInfo {
  sessionId: number;
  pairingCode: string;
  serviceName: string;
}

export interface AdbQrPairingResult {
  guid: string;
  pairedHost: string;
  hostPort: string;
}

export const adbCreate: (ip: string, port: number) => number;
export const adbConnect: (adbId: number, pubKeyPath: string, priKeyPath: string) => number;
export const adbGetLastConnectError: (adbId: number) => string;
export const adbPair: (hostPort: string, pairingCode: string, pubKeyPath: string, priKeyPath: string) => Promise<string>;
export const adbStartQrPairing: (pubKeyPath: string, priKeyPath: string, localIp: string) => Promise<AdbQrPairingSessionInfo>;
export const adbWaitQrPairing: (sessionId: number) => Promise<AdbQrPairingResult>;
export const adbStopQrPairing: (sessionId: number) => void;
export const adbRunCmd: (adbId: number, cmd: string) => string;
export const adbExecShell: (adbId: number, cmd: string) => Promise<AdbShellCommandResult>;
export const adbInstallPackage: (
    adbId: number,
    data: ArrayBuffer,
    remoteName: string,
    installArgs?: string,
    onProgress?: (progress: number) => void
) => Promise<AdbInstallPackageResult>;
export const adbInstallPackageFromFd: (
    adbId: number,
    fd: number,
    fileSize: number,
    remoteName: string,
    installArgs?: string,
    onProgress?: (progress: number) => void
) => Promise<AdbInstallPackageResult>;
export const adbPushFile: (
    adbId: number,
    data: ArrayBuffer,
    remotePath: string,
    onProgress?: (progress: number) => void
) => Promise<void>;
export const adbPushFileFromFd: (
    adbId: number,
    fd: number,
    fileSize: number,
    remotePath: string,
    onProgress?: (progress: number) => void
) => Promise<void>;
export const adbTcpForward: (adbId: number, port: number) => number;
export const adbLocalSocketForward: (
    adbId: number,
    socketName: string,
    streamKind?: 'video' | 'audio' | 'control' | 'other'
) => Promise<number>;
export const adbReverse: (adbId: number, socketName: string, port: number) => Promise<number>;
export const adbReverseRemove: (adbId: number, socketName: string) => Promise<number>;
export const adbGetShell: (adbId: number) => Promise<number>;
export const adbRestartOnTcpip: (adbId: number, port: number) => string;
export const adbIsStreamClosed: (adbId: number, streamId: number) => boolean;
export const adbIsConnected: (adbId: number) => boolean;
export const nativeStartStreams: (
    adbId: number,
    videoStreamId: number,
    audioStreamId: number,
    controlStreamId: number,
    surfaceId: string,
    audioSampleRate: number,
    audioChannelCount: number,
    cb: (type: string, data: string) => void
) => Promise<number>;
export const nativeStartReverseStreams: (
    adbId: number,
    expectVideo: boolean,
    expectAudio: boolean,
    expectControl: boolean,
    surfaceId: string,
    audioSampleRate: number,
    audioChannelCount: number,
    cb: (type: string, data: string) => void
) => Promise<number>;
export const nativeStopStreams: () => void;
export const nativeSendControl: (data: ArrayBuffer) => boolean;
export const adbClose: (adbId: number) => void;
export const adbStreamRead: (adbId: number, streamId: number, size: number) => ArrayBuffer;
export const adbStreamWrite: (adbId: number, streamId: number, data: ArrayBuffer) => Promise<void>;
export const destroyBufferPool: () => void;
export const createVideoDecoder: () => number;
export const initVideoDecoder: (id: number, type: string, surface: string, width: number, height: number) => number;
export const startVideoDecoder: (id: number) => number;
export const pushVideoData: (id: number, data: ArrayBuffer, pts: number, flags: number) => number;

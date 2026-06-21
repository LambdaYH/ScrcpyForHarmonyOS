declare module 'libscrcpy_native.so' {
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

    export interface RemoteFileEntry {
        name: string;
        path: string;
        mode: number;
        size: number;
        mtime: number;
        isDirectory: boolean;
        isRegularFile: boolean;
    }

    // Audio decoder
    export function createAudioDecoder(): number;
    export function initAudioDecoder(id: number, codecType: string, sampleRate: number, channelCount: number): number;
    export function startAudioDecoder(id: number): number;
    export function pushAudioData(id: number, data: ArrayBuffer, pts: number): number;
    export function releaseAudioDecoder(id: number): void;

    // Video decoder
    export function createVideoDecoder(): number;
    export function initVideoDecoder(id: number, codecType: string, surfaceId: string, width: number, height: number): number;
    export function startVideoDecoder(id: number): number;
    export function pushVideoData(id: number, data: ArrayBuffer, pts: number, flags?: number): number;
    export function releaseVideoDecoder(id: number): void;



    // ADB Module
    export function adbCreate(ip: string, port: number): Promise<number>;
    export function adbConnect(adbId: number, pubKeyPath: string, priKeyPath: string, onWaitAuth?: () => void): Promise<number>;
    export function adbGetLastConnectError(adbId: number): string;
    export function adbPair(hostPort: string, pairingCode: string, pubKeyPath: string, priKeyPath: string): Promise<string>;
    export function adbRunCmd(adbId: number, cmd: string): string;
    export function adbExecShell(adbId: number, cmd: string): Promise<AdbShellCommandResult>;
    export function adbInstallPackage(
        adbId: number,
        data: ArrayBuffer,
        remoteName: string,
        installArgs?: string,
        onProgress?: (progress: number) => void
    ): Promise<AdbInstallPackageResult>;
    export function adbInstallPackageFromFd(
        adbId: number,
        fd: number,
        fileSize: number,
        remoteName: string,
        installArgs?: string,
        onProgress?: (progress: number) => void
    ): Promise<AdbInstallPackageResult>;
    export function adbPushFile(
        adbId: number,
        data: ArrayBuffer,
        remotePath: string,
        onProgress?: (progress: number) => void
    ): Promise<void>;
    export function adbPushFileFromFd(
        adbId: number,
        fd: number,
        fileSize: number,
        remotePath: string,
        onProgress?: (progress: number) => void
    ): Promise<void>;
    export function adbListDirectory(adbId: number, remotePath: string): Promise<Array<RemoteFileEntry>>;
    export function adbPullFileToFd(
        adbId: number,
        fd: number,
        remotePath: string,
        onProgress?: (progress: number) => void
    ): Promise<number>;
    export function adbTcpForward(adbId: number, port: number): number;
    export function adbLocalSocketForward(
        adbId: number,
        socketName: string,
        streamKind?: 'video' | 'audio' | 'control' | 'other'
    ): Promise<number>;
    export function adbReverse(adbId: number, socketName: string, port: number): Promise<number>;
    export function adbReverseRemove(adbId: number, socketName: string): Promise<number>;
    export function adbGetShell(adbId: number): Promise<number>;
    export function adbRestartOnTcpip(adbId: number, port: number): string;
    export function adbStreamRead(adbId: number, streamId: number, size: number): ArrayBuffer;
    export function adbStreamWrite(adbId: number, streamId: number, data: ArrayBuffer): Promise<void>;
    export function adbStreamClose(adbId: number, streamId: number): void;
    export function adbIsStreamClosed(adbId: number, streamId: number): boolean;
    export function adbClose(adbId: number): void;
    export function adbGenerateKeyPair(pubKeyPath: string, priKeyPath: string): number;
    export function adbIsConnected(adbId: number): boolean;

    // Stream Manager
    export function nativeStartStreams(
        adbId: number,
        videoStreamId: number,
        audioStreamId: number,
        controlStreamId: number,
        surfaceId: string,
        audioSampleRate: number,
        audioChannelCount: number,
        callback: (type: string, data: string) => void
    ): Promise<number>;
    export function nativeStartReverseStreams(
        adbId: number,
        expectVideo: boolean,
        expectAudio: boolean,
        expectControl: boolean,
        surfaceId: string,
        audioSampleRate: number,
        audioChannelCount: number,
        callback: (type: string, data: string) => void
    ): Promise<number>;
    export function nativeStopStreams(): void;
    export function nativeSendControl(data: ArrayBuffer): boolean;
}

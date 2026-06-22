export interface RemoteFileSortItem {
  name: string;
  isDirectory: boolean;
}

export function normalizeRemoteDirectoryPath(path: string): string {
  const trimmed = path.trim();
  if (trimmed.length === 0 || trimmed === '/') {
    return '/';
  }
  return trimmed.endsWith('/') ? trimmed : `${trimmed}/`;
}

export function getRemoteParentPath(path: string): string {
  const normalized = normalizeRemoteDirectoryPath(path);
  if (normalized === '/') {
    return '/';
  }
  const withoutTrailingSlash = normalized.substring(0, normalized.length - 1);
  const separatorIndex = withoutTrailingSlash.lastIndexOf('/');
  return separatorIndex <= 0 ? '/' : `${withoutTrailingSlash.substring(0, separatorIndex)}/`;
}

export function compareRemoteFileEntries(left: RemoteFileSortItem, right: RemoteFileSortItem): number {
  if (left.isDirectory !== right.isDirectory) {
    return left.isDirectory ? -1 : 1;
  }
  return left.name.toLowerCase().localeCompare(right.name.toLowerCase());
}

import { describe, it, expect } from '@ohos/hypium';
import {
  compareRemoteFileEntries,
  getRemoteParentPath,
  normalizeRemoteDirectoryPath,
  RemoteFileSortItem
} from '../main/ets/helper/RemoteFileBrowserHelper';

export default function remoteFileBrowserHelperTest() {
  describe('RemoteFileBrowserHelper', () => {
    it('normalizesDirectoryPaths', 0, () => {
      expect(normalizeRemoteDirectoryPath('')).assertEqual('/');
      expect(normalizeRemoteDirectoryPath('/')).assertEqual('/');
      expect(normalizeRemoteDirectoryPath(' /sdcard/Download ')).assertEqual('/sdcard/Download/');
      expect(normalizeRemoteDirectoryPath('/sdcard/')).assertEqual('/sdcard/');
    });

    it('returnsParentPaths', 0, () => {
      expect(getRemoteParentPath('/')).assertEqual('/');
      expect(getRemoteParentPath('/sdcard/')).assertEqual('/');
      expect(getRemoteParentPath('/sdcard/Download/')).assertEqual('/sdcard/');
    });

    it('sortsDirectoriesBeforeFilesByName', 0, () => {
      const entries: RemoteFileSortItem[] = [
        { name: 'z.txt', isDirectory: false },
        { name: 'beta', isDirectory: true },
        { name: 'Alpha', isDirectory: true },
        { name: 'a.txt', isDirectory: false }
      ];
      entries.sort(compareRemoteFileEntries);
      expect(entries.map((entry: RemoteFileSortItem): string => entry.name).join(','))
        .assertEqual('Alpha,beta,a.txt,z.txt');
    });
  });
}

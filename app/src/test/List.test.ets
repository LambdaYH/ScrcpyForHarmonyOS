import localUnitTest from './LocalUnit.test';
import keyboardUhidControllerTest from './KeyboardUhidController.test';
import remoteFileBrowserHelperTest from './RemoteFileBrowserHelper.test';
import remoteUnlockHelperTest from './RemoteUnlockHelper.test';

export default function testsuite() {
  localUnitTest();
  keyboardUhidControllerTest();
  remoteFileBrowserHelperTest();
  remoteUnlockHelperTest();
}

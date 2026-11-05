import localUnitTest from './LocalUnit.test';
import keyboardUhidControllerTest from './KeyboardUhidController.test';
import remoteFileBrowserHelperTest from './RemoteFileBrowserHelper.test';
import remoteUnlockHelperTest from './RemoteUnlockHelper.test';
import adbCommandUtilsTest from './AdbCommandUtils.test';
import adbCommandExecutorTest from './AdbCommandExecutor.test';

export default function testsuite() {
  localUnitTest();
  keyboardUhidControllerTest();
  remoteFileBrowserHelperTest();
  remoteUnlockHelperTest();
  adbCommandUtilsTest();
  adbCommandExecutorTest();
}

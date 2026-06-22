import localUnitTest from './LocalUnit.test';
import keyboardUhidControllerTest from './KeyboardUhidController.test';
import remoteFileBrowserHelperTest from './RemoteFileBrowserHelper.test';

export default function testsuite() {
  localUnitTest();
  keyboardUhidControllerTest();
  remoteFileBrowserHelperTest();
}

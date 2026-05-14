import localUnitTest from './LocalUnit.test';
import keyboardUhidControllerTest from './KeyboardUhidController.test';

export default function testsuite() {
  localUnitTest();
  keyboardUhidControllerTest();
}

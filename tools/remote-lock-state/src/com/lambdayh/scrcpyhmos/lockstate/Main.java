package com.lambdayh.scrcpyhmos.lockstate;

import android.app.KeyguardManager;
import android.content.Context;
import android.os.Build;
import android.os.Looper;
import android.os.PowerManager;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * One-shot lock state probe executed through app_process on the controlled Android device.
 */
public final class Main {
    private static final String OUTPUT_PREFIX = "SCRCPY_HMOS_LOCK_STATE_V1";

    private Main() {
        // No instances.
    }

    public static void main(String[] args) {
        try {
            Context context = createSystemContext();
            KeyguardManager keyguardManager =
                    (KeyguardManager) context.getSystemService(Context.KEYGUARD_SERVICE);
            PowerManager powerManager =
                    (PowerManager) context.getSystemService(Context.POWER_SERVICE);
            if (keyguardManager == null || powerManager == null) {
                throw new IllegalStateException("required system service unavailable");
            }

            boolean interactive = powerManager.isInteractive();
            boolean deviceLocked = keyguardManager.isDeviceLocked();
            boolean keyguardShowing = keyguardManager.isKeyguardLocked();
            System.out.println(OUTPUT_PREFIX
                    + " interactive=" + toFlag(interactive)
                    + " deviceLocked=" + toFlag(deviceLocked)
                    + " keyguardShowing=" + toFlag(keyguardShowing)
                    + " sdk=" + Build.VERSION.SDK_INT);
        } catch (Throwable throwable) {
            Throwable rootCause = throwable;
            while (rootCause.getCause() != null) {
                rootCause = rootCause.getCause();
            }
            System.err.println(OUTPUT_PREFIX + " error=" + rootCause.getClass().getSimpleName());
            rootCause.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private static String toFlag(boolean value) {
        return value ? "1" : "0";
    }

    private static Context createSystemContext() throws Exception {
        if (Looper.myLooper() == null) {
            Looper.prepare();
        }
        Class<?> activityThreadClass = Class.forName("android.app.ActivityThread");
        Constructor<?> constructor = activityThreadClass.getDeclaredConstructor();
        constructor.setAccessible(true);
        Object activityThread = constructor.newInstance();

        Field currentThreadField = activityThreadClass.getDeclaredField("sCurrentActivityThread");
        currentThreadField.setAccessible(true);
        currentThreadField.set(null, activityThread);

        Field systemThreadField = activityThreadClass.getDeclaredField("mSystemThread");
        systemThreadField.setAccessible(true);
        systemThreadField.setBoolean(activityThread, true);

        Method getSystemContextMethod = activityThreadClass.getDeclaredMethod("getSystemContext");
        getSystemContextMethod.setAccessible(true);
        Context context = (Context) getSystemContextMethod.invoke(activityThread);
        if (context == null) {
            throw new IllegalStateException("system context unavailable");
        }
        return context;
    }
}

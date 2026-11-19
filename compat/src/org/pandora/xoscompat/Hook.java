package org.pandora.xoscompat;

import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.wifi.WifiManager;
import android.util.Log;
import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.callbacks.XC_LoadPackage;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * pandora (Xiaomi 17 Pro, MIShare 5.4.1) companion for the xos0 exclusive-radio backend.
 *
 * radio.sh switches Wi-Fi off while it owns the radio (sys.xos.exclusive=1). Native MIShare treats
 * "Wi-Fi switched off" as a reason to stop AirDrop and drop the "everyone" switch. While the backend owns
 * the radio this module keeps reporting Wi-Fi as enabled to MIShare and drops WIFI_STATE_CHANGED for it.
 *
 * Unlike houji's compat (hard-coded obfuscated MIShare 5.4.2 class names) the receivers are found at
 * registration time: any receiver MIShare registers with WIFI_STATE_CHANGED in its filter gets its
 * onReceive hooked, so the module does not depend on the app's obfuscation map.
 */
public final class Hook implements IXposedHookLoadPackage {
    private static final String TAG = "PandoraXosCompat";
    private static final String MISHARE_PKG = "com.miui.mishare.connectivity";
    private static final String RESOLVER_PKG = "com.android.intentresolver";
    private static final Set<Class<?>> HOOKED = Collections.synchronizedSet(new HashSet<Class<?>>());

    static boolean ownsRadio() {
        try {
            Object val = Class.forName("android.os.SystemProperties")
                    .getMethod("get", String.class, String.class)
                    .invoke(null, "sys.xos.exclusive", "");
            return "1".equals(val);
        } catch (Throwable e) {
            return false;
        }
    }

    static String propValue() {
        try {
            return String.valueOf(Class.forName("android.os.SystemProperties")
                    .getMethod("get", String.class, String.class)
                    .invoke(null, "sys.xos.exclusive", "<empty>"));
        } catch (Throwable e) {
            return "<error " + e + ">";
        }
    }

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam p) throws Throwable {
        if (MISHARE_PKG.equals(p.packageName)) {
            hookMiShare();
            try {
                hookLivePhoto(p.classLoader);
            } catch (Throwable t) {
                Log.w(TAG, "Live Photo hook unavailable", t);
            }
        } else if (RESOLVER_PKG.equals(p.packageName)) {
            try {
                hookIntentResolver(p.classLoader);
            } catch (Throwable t) {
                Log.w(TAG, "IntentResolver gallery hook unavailable", t);
            }
        }
    }

    private void hookMiShare() throws Throwable {
        XposedBridge.hookMethod(WifiManager.class.getDeclaredMethod("getWifiState"), new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                if (ownsRadio()) param.setResult(WifiManager.WIFI_STATE_ENABLED);
            }
        });
        XposedBridge.hookMethod(WifiManager.class.getDeclaredMethod("isWifiEnabled"), new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                if (ownsRadio()) param.setResult(true);
            }
        });
        XposedBridge.hookMethod(WifiManager.class.getDeclaredMethod("setWifiEnabled", boolean.class),
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        if (ownsRadio() && Boolean.TRUE.equals(param.args[0])) {
                            Log.i(TAG, "suppress setWifiEnabled(true) while xos backend owns the radio");
                            param.setResult(true);
                        }
                    }
                });

        // Find MIShare's Wi-Fi state receivers when they are registered (ContextImpl.registerReceiver*).
        XC_MethodHook onRegister = new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                Object[] a = param.args;
                if (a == null || a.length < 2 || !(a[0] instanceof BroadcastReceiver)
                        || !(a[1] instanceof IntentFilter)) {
                    return;
                }
                if (((IntentFilter) a[1]).hasAction(WifiManager.WIFI_STATE_CHANGED_ACTION)) {
                    hookReceiver(a[0].getClass());
                }
            }
        };
        int n = 0;
        for (Method m : Class.forName("android.app.ContextImpl").getDeclaredMethods()) {
            Class<?>[] t = m.getParameterTypes();
            if (m.getName().startsWith("registerReceiver") && t.length >= 2
                    && t[0] == BroadcastReceiver.class && t[1] == IntentFilter.class) {
                XposedBridge.hookMethod(m, onRegister);
                n++;
            }
        }
        Log.i(TAG, "Loaded in MIShare: Wi-Fi state masking active while sys.xos.exclusive=1 (now "
                + propValue() + "), registerReceiver hooks=" + n);
    }

    private static void hookReceiver(Class<?> cls) {
        if (!HOOKED.add(cls)) return;
        Class<?> c = cls;
        while (c != null && c != BroadcastReceiver.class) {
            try {
                final Method m = c.getDeclaredMethod("onReceive", Context.class, Intent.class);
                final String name = cls.getName();
                XposedBridge.hookMethod(m, new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        Intent i = (Intent) param.args[1];
                        if (i != null && WifiManager.WIFI_STATE_CHANGED_ACTION.equals(i.getAction()) && ownsRadio()) {
                            Log.i(TAG, "drop WIFI_STATE_CHANGED (state="
                                    + i.getIntExtra(WifiManager.EXTRA_WIFI_STATE, -1) + ") for " + name);
                            param.setResult(null);
                        }
                    }
                });
                Log.i(TAG, "hooked Wi-Fi state receiver " + name);
                return;
            } catch (NoSuchMethodException e) {
                c = c.getSuperclass();
            } catch (Throwable t) {
                Log.w(TAG, "hook receiver failed " + cls.getName(), t);
                return;
            }
        }
    }

    /**
     * MIShare 5.4.1 unpacks an Apple Live Photo (.pvt) into a separate JPEG and MOV. Its upload handler
     * a.k1 commits the staged files with {@code ArrayList d(ArrayList<File>)} (rename into the inbox), then
     * answers HTTP 200 and hands the committed list to AirDropService for media scanning. Before that commit,
     * replace each JPEG+MOV pair carrying the same Apple pairing UUID by one Motion Photo JPEG (the format of
     * Xiaomi Gallery's own MVIMG_*.jpg). Any failure leaves the list and files untouched.
     */
    private static void hookLivePhoto(ClassLoader cl) throws Throwable {
        Class<?> k1 = Class.forName("a.k1", false, cl);
        Method commit = k1.getDeclaredMethod("d", java.util.ArrayList.class);
        XposedBridge.hookMethod(commit, new XC_MethodHook() {
            @Override
            protected void beforeHookedMethod(MethodHookParam param) {
                try {
                    @SuppressWarnings("unchecked")
                    java.util.ArrayList<Object> files = (java.util.ArrayList<Object>) param.args[0];
                    if (files != null && files.size() >= 2) mergeLivePhotos(files);
                } catch (Throwable t) {
                    Log.w(TAG, "Live Photo merge skipped", t);
                }
            }
        });
        Log.i(TAG, "Loaded in MIShare: Live Photo -> Motion Photo merge on a.k1.d");
    }

    private static final long LIVE_MOV_MAX = 48L << 20;

    static void mergeLivePhotos(java.util.ArrayList<Object> files) {
        java.util.List<java.io.File> jpegs = new java.util.ArrayList<>();
        java.util.List<java.io.File> movs = new java.util.ArrayList<>();
        for (Object o : files) {
            if (!(o instanceof java.io.File)) return; // unexpected list shape: leave it alone
            java.io.File f = (java.io.File) o;
            String n = f.getName().toLowerCase(java.util.Locale.ROOT);
            if (n.endsWith(".jpg") || n.endsWith(".jpeg")) jpegs.add(f);
            else if (n.endsWith(".mov") && f.length() > 0 && f.length() <= LIVE_MOV_MAX) movs.add(f);
        }
        if (jpegs.isEmpty() || movs.isEmpty()) return;
        java.util.Map<java.io.File, java.util.Set<String>> jpegIds = new java.util.HashMap<>();
        for (java.io.File j : jpegs) jpegIds.put(j, MotionPhoto.jpegUuids(j));
        for (java.io.File mov : movs) {
            String id = MotionPhoto.movContentId(mov);
            if (id == null) continue;
            java.io.File jpeg = null;
            for (java.io.File j : jpegs) {
                if (jpegIds.get(j).contains(id)) {
                    jpeg = j;
                    break;
                }
            }
            if (jpeg == null) {
                Log.i(TAG, "Live Photo: no JPEG for " + mov.getName() + " id=" + id);
                continue;
            }
            java.io.File tmp = new java.io.File(jpeg.getParentFile(), "." + jpeg.getName() + ".motion");
            try {
                MotionPhoto.Result r = MotionPhoto.merge(jpeg, mov, tmp, new OrientTranscoder());
                java.io.File backup = new java.io.File(jpeg.getParentFile(), "." + jpeg.getName() + ".orig");
                if (!jpeg.renameTo(backup)) throw new java.io.IOException("backup failed " + jpeg);
                if (!tmp.renameTo(jpeg)) {
                    if (!backup.renameTo(jpeg)) Log.e(TAG, "Live Photo: could not restore " + jpeg);
                    throw new java.io.IOException("replace failed " + jpeg);
                }
                backup.delete();
                int mi = files.indexOf(mov);
                if (mi >= 0) files.remove(mi);
                if (!mov.delete()) Log.w(TAG, "Live Photo: could not delete staged " + mov);
                jpegs.remove(jpeg);
                Log.i(TAG, "Live Photo merged " + jpeg.getName() + " + " + mov.getName() + " id=" + id + " " + r);
            } catch (Throwable t) {
                tmp.delete();
                Log.w(TAG, "Live Photo merge failed for " + jpeg.getName() + " + " + mov.getName(), t);
            }
        }
    }

    // Same as houji: the gallery share grid starts MIShare's AirDrop trampoline with a URI-grant-preserving mode.
    private void hookIntentResolver(ClassLoader cl) throws Throwable {
        final Class<?> stub = Class.forName("com.android.intentresolver.ChooserActivityStubImpl", false, cl);
        final Class<?> target = Class.forName("com.android.intentresolver.chooser.TargetInfo", false, cl);
        XposedBridge.hookMethod(
                stub.getDeclaredMethod("checkStartGalleryActivity", int.class, String.class, List.class),
                new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                        if (!Integer.valueOf(0).equals(param.args[0]) || !MISHARE_PKG.equals(param.args[1])) return;
                        boolean fromGrid = false;
                        for (StackTraceElement f : Thread.currentThread().getStackTrace()) {
                            if ("com.android.intentresolver.adapter.MiuiChooserGridAdapter".equals(f.getClassName())
                                    && "startSelected".equals(f.getMethodName())) {
                                fromGrid = true;
                                break;
                            }
                        }
                        if (!fromGrid) return;
                        Object selected = stub.getField("mTargetInfo").get(param.thisObject);
                        if (selected == null) return;
                        ComponentName cn = (ComponentName) target.getMethod("getResolvedComponentName").invoke(selected);
                        if (cn != null && MISHARE_PKG.equals(cn.getPackageName())
                                && "com.xiaomi.sharop.AirDropShareTrampolineActivity".equals(cn.getClassName())) {
                            param.args[0] = 2;
                            Log.i(TAG, "gallery AirDrop target: standard activity dispatch");
                        }
                    }
                });
        Log.i(TAG, "Loaded in IntentResolver: gallery AirDrop dispatch");
    }
}

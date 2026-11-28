// SPDX-License-Identifier: GPL-2.0-only
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.CookieHandler;
import java.net.CookieManager;
import java.net.CookiePolicy;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.Inflater;
import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;

// On-device Samsung FUS partial firmware fetcher (pure java.* stdlib, runs via Android app_process or desktop JVM).
public final class FwFetcher {
    private static final String FUS_URL = "https://neofussvr.sslcs.cdngc.net/";
    private static final String CLOUD_URL = "https://cloud-neofussvr.samsungmobile.com/NF_SmartDownloadBinaryForMass.do?file=";
    private static final byte[] AUTH_KEY = hexToBytes("422e73733617ae2b198940fd4e32b0a5");
    private static final String UA = "SMART 2.0";

    private String nonce = "";
    private String sig = "";

    @SuppressWarnings("unchecked")
    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: FwFetcher <recipe.json> <output_path>");
            System.exit(2);
        }
        File recipeFile = new File(args[0]);
        File outFile = new File(args[1]);
        String jsonText = new String(readAllBytes(recipeFile), StandardCharsets.UTF_8);
        Map<String, Object> recipe = (Map<String, Object>) new MiniJson(jsonText).parse();
        String wantSha = str(recipe, "sha256");

        if (outFile.isFile() && sha256Hex(readAllBytes(outFile)).equals(wantSha)) {
            System.out.println("- 已有校验通过的固件，跳过下载");
            return;
        }

        CookieHandler.setDefault(new CookieManager(null, CookiePolicy.ACCEPT_ALL));
        FwFetcher fus = new FwFetcher();
        byte[] fw = fus.fetch(recipe);

        File parent = outFile.getParentFile();
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }
        File tmp = new File(outFile.getAbsolutePath() + ".tmp");
        try (FileOutputStream fos = new FileOutputStream(tmp)) {
            fos.write(fw);
        }
        if (outFile.exists()) {
            outFile.delete();
        }
        if (!tmp.renameTo(outFile)) {
            throw new IOException("无法写入目标固件: " + outFile);
        }
        System.out.println("- 固件还原并校验通过（" + fw.length + " 字节，SHA-256 " + wantSha.substring(0, 16) + "…）");
    }

    @SuppressWarnings("unchecked")
    private byte[] fetch(Map<String, Object> recipe) throws Exception {
        String fw = str(recipe, "fw");
        String model = str(recipe, "model");
        String region = str(recipe, "region");
        long expectedPkgSize = lng(recipe, "package_size");
        Map<String, Object> d = obj(recipe, "deflate");
        Map<String, Object> l4 = obj(recipe, "lz4");

        System.out.println("- 连接三星官方服务器（FUS）: " + model + " " + region + " " + fw.split("/")[0]);
        post("NF_SmartDownloadGenerateNonce.do", null);

        String informXml = buildMsg(new String[][] {
            {"ACCESS_MODE", "1"},
            {"BINARY_NATURE", "1"},
            {"REQUEST_TYPE", "2"},
            {"LOGIC_CHECK", logicCheck(fw, nonce)},
            {"BINARY_SW_VERSION", fw},
            {"BINARY_LOCAL_CODE", region},
            {"BINARY_MODEL_NAME", model}
        }, true);
        String x = post("NF_SmartDownloadBinaryInform.do", informXml.getBytes(StandardCharsets.UTF_8));
        Map<String, String> kv = parseXmlDataTags(x);
        String binName = kv.get("BINARY_NAME");
        if (binName == null || binName.isEmpty()) {
            throw new IOException("三星服务器未返回该版本固件，请检查网络或更新位置文件");
        }
        long pkgSize = Long.parseLong(kv.get("BINARY_BYTE_SIZE"));
        if (pkgSize != expectedPkgSize) {
            throw new IOException("固件包大小不符: " + pkgSize + " != " + expectedPkgSize);
        }

        String nameSlice = binName.substring(binName.length() - 25, binName.length() - 9);
        String initXml = buildMsg(new String[][] {
            {"BINARY_NAME", binName},
            {"BINARY_SW_VERSION", fw},
            {"DEVICE_LOCAL_CODE", region},
            {"DEVICE_MODEL_TYPE", kv.get("DEVICE_MODEL_TYPE")},
            {"LOGIC_CHECK", logicCheck(nameSlice, nonce)}
        }, false);
        post("NF_SmartDownloadBinaryInitForMass.do", initXml.getBytes(StandardCharsets.UTF_8));

        String dlPath = kv.get("MODEL_PATH") + binName;
        byte[] aesKey = md5(logicCheck(fw, kv.get("LOGIC_VALUE_FACTORY")).getBytes(StandardCharsets.UTF_8));

        long bit = lng(d, "bit");
        long fetchEnd = lng(d, "fetch_end");
        long a = ((bit / 8L) / 16L) * 16L;
        long b = ((fetchEnd + 15L) / 16L) * 16L;
        double dlMb = (b - a) / (1024.0 * 1024.0);
        System.out.printf(Locale.US, "- 正在从三星服务器下载 %.1f MB 固件切片...%n", dlMb);

        long t0 = System.currentTimeMillis();
        byte[] enc = getRange(dlPath, a, b - 1L);
        long dt = Math.max(1L, (System.currentTimeMillis() - t0) / 1000L);
        System.out.println("- 下载完成（约 " + dt + " 秒），正在本地解密与还原...");

        byte[] decAll = aesEcbDecrypt(aesKey, enc);
        int sliceOff = (int) (bit / 8L - a);
        int sliceLen = (int) (fetchEnd - bit / 8L);
        byte[] raw = Arrays.copyOfRange(decAll, sliceOff, sliceOff + sliceLen);

        byte[] ap = inflateFrom(raw, (int) (bit % 8L));
        long dOut = lng(d, "out");
        long l4Start = lng(l4, "start");
        long l4Out = lng(l4, "out");
        int l4Blocks = (int) lng(l4, "blocks");
        int l4Span = (int) lng(l4, "span");
        boolean linked = bool(l4, "linked");
        boolean blockChecksum = bool(l4, "block_checksum");

        long need = (l4Start - dOut) + l4Span;
        if (ap.length < need) {
            throw new IOException("deflate 解出数据不足: " + ap.length + " < " + need);
        }

        int p = (int) (l4Start - dOut);
        ByteArrayOutputStream lz4Out = new ByteArrayOutputStream(Math.max(4 * 1024 * 1024, l4Blocks * 1024 * 1024));
        if (linked) {
            lz4Out.write(new byte[65536]);
        }
        long base = l4Out - lz4Out.size();
        for (int bi = 0; bi < l4Blocks; bi++) {
            int w = readLe32(ap, p);
            p += 4;
            int bl = w & 0x7fffffff;
            if ((w & 0x80000000) != 0) {
                lz4Out.write(ap, p, bl);
            } else if (linked) {
                byte[] cur = lz4Out.toByteArray();
                byte[] updated = lz4Block(ap, p, bl, cur);
                lz4Out.reset();
                lz4Out.write(updated);
            } else {
                byte[] blkOut = lz4Block(ap, p, bl, null);
                lz4Out.write(blkOut);
            }
            p += bl + (blockChecksum ? 4 : 0);
        }
        byte[] buf = lz4Out.toByteArray();

        List<Object> vw = arr(recipe, "vendor_window");
        long v0 = ((Number) vw.get(0)).longValue();
        int vlen = ((Number) vw.get(1)).intValue();
        byte[] vend = new byte[vlen];

        for (Object itemObj : arr(recipe, "raw")) {
            List<Object> item = (List<Object>) itemObj;
            long srcOff = ((Number) item.get(0)).longValue();
            int ln = ((Number) item.get(1)).intValue();
            long voff = ((Number) item.get(2)).longValue();
            int q = (int) (srcOff - base);
            if (q < 0 || q + ln > buf.length) {
                throw new IOException("位置文件与 LZ4 数据不符");
            }
            System.arraycopy(buf, q, vend, (int) (voff - v0), ln);
        }
        List<Object> fillArr = (List<Object>) recipe.get("fill");
        if (fillArr != null) {
            for (Object itemObj : fillArr) {
                List<Object> item = (List<Object>) itemObj;
                long voff = ((Number) item.get(0)).longValue();
                int ln = ((Number) item.get(1)).intValue();
                byte[] pat = hexToBytes((String) item.get(2));
                int dstPos = (int) (voff - v0);
                for (int k = 0; k < ln; k++) {
                    vend[dstPos + k] = pat[k % pat.length];
                }
            }
        }

        int fileSize = (int) lng(recipe, "file_size");
        byte[] out = new byte[fileSize];
        for (Object eObj : arr(recipe, "extents")) {
            Map<String, Object> e = (Map<String, Object>) eObj;
            int logical = (int) lng(e, "logical");
            int llen = (int) lng(e, "llen");
            long phys = lng(e, "phys");
            int plen = (int) lng(e, "plen");
            boolean z = bool(e, "z");
            int skip = e.containsKey("skip") ? (int) lng(e, "skip") : 0;
            int vendOff = (int) (phys - v0);
            if (vendOff < 0 || vendOff + plen > vend.length) {
                throw new IOException("位置文件与 vendor 窗口不符");
            }
            if (z) {
                int s = vendOff;
                int end = vendOff + plen;
                while (s < end && vend[s] == 0) s++;
                byte[] dec = lz4Block(vend, s, end - s, null);
                int copyLen = Math.min(llen, dec.length - skip);
                System.arraycopy(dec, skip, out, logical, copyLen);
            } else {
                System.arraycopy(vend, vendOff, out, logical, llen);
            }
        }

        String gotSha = sha256Hex(out);
        String wantSha = str(recipe, "sha256");
        if (!gotSha.equals(wantSha)) {
            throw new IOException("SHA-256 校验失败: " + gotSha + " != " + wantSha);
        }
        return out;
    }

    private String authz() {
        return "FUS nonce=\"" + nonce + "\", signature=\"" + sig + "\", nc=\"\", type=\"\", realm=\"\", newauth=\"1\"";
    }

    private String post(String path, byte[] body) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(FUS_URL + path).openConnection();
        conn.setRequestMethod("POST");
        conn.setConnectTimeout(30000);
        conn.setReadTimeout(60000);
        conn.setRequestProperty("Authorization", authz());
        conn.setRequestProperty("User-Agent", UA);
        conn.setRequestProperty("Accept", "application/xml");
        conn.setDoOutput(true);
        if (body != null && body.length > 0) {
            conn.setRequestProperty("Content-Type", "application/xml");
            try (OutputStream os = conn.getOutputStream()) {
                os.write(body);
            }
        } else {
            conn.setFixedLengthStreamingMode(0);
            conn.getOutputStream().close();
        }
        int code = conn.getResponseCode();
        if (code != 200) {
            throw new IOException("三星服务器返回 HTTP " + code + " (" + path + ")");
        }
        String nextNonce = conn.getHeaderField("NONCE");
        byte[] respBytes = readStream(conn.getInputStream());
        conn.disconnect();
        if (nextNonce != null && !nextNonce.isEmpty()) {
            this.nonce = nextNonce;
            byte[] block = new byte[16];
            Arrays.fill(block, (byte) '0');
            byte[] nb = nextNonce.getBytes(StandardCharsets.UTF_8);
            System.arraycopy(nb, 0, block, 0, Math.min(16, nb.length));
            this.sig = bytesToHex(aesEcbEncryptBlock(AUTH_KEY, block));
        }
        return new String(respBytes, StandardCharsets.UTF_8);
    }

    private byte[] getRange(String path, long a, long b) throws Exception {
        int wantLen = (int) (b - a + 1L);
        IOException lastErr = null;
        for (int attempt = 0; attempt < 5; attempt++) {
            HttpURLConnection conn = null;
            try {
                conn = (HttpURLConnection) new URL(CLOUD_URL + path).openConnection();
                conn.setRequestMethod("GET");
                conn.setConnectTimeout(30000);
                conn.setReadTimeout(120000);
                conn.setRequestProperty("Authorization", authz());
                conn.setRequestProperty("User-Agent", UA);
                conn.setRequestProperty("Range", "bytes=" + a + "-" + b);
                int code = conn.getResponseCode();
                if (code != 206) {
                    throw new IOException("服务器不支持分段下载 (HTTP " + code + ")");
                }
                byte[] data = readStream(conn.getInputStream());
                if (data.length == wantLen) {
                    return data;
                }
                lastErr = new IOException("下载不完整: " + data.length + "/" + wantLen);
            } catch (IOException e) {
                lastErr = e;
            } finally {
                if (conn != null) conn.disconnect();
            }
            Thread.sleep((2 + attempt * 3) * 1000L);
        }
        throw lastErr != null ? lastErr : new IOException("下载失败");
    }

    private static String logicCheck(String inp, String nonce) {
        StringBuilder sb = new StringBuilder(nonce.length());
        for (int i = 0; i < nonce.length(); i++) {
            int idx = nonce.charAt(i) & 15;
            sb.append(idx < inp.length() ? inp.charAt(idx) : '.');
        }
        return sb.toString();
    }

    private static String buildMsg(String[][] put, boolean includeGet) {
        StringBuilder sb = new StringBuilder();
        sb.append("<FUSMsg><FUSHdr><ProtoVer>1.0</ProtoVer><SessionID>0</SessionID><MsgID>1</MsgID></FUSHdr><FUSBody><Put>");
        if (includeGet) sb.append("<CmdID>1</CmdID>");
        for (String[] kv : put) {
            sb.append('<').append(kv[0]).append("><Data>").append(kv[1]).append("</Data></").append(kv[0]).append('>');
        }
        sb.append("</Put>");
        if (includeGet) {
            sb.append("<Get><CmdID>2</CmdID><BINARY_SW_VERSION /></Get>");
        }
        sb.append("</FUSBody></FUSMsg>");
        return sb.toString();
    }

    private static Map<String, String> parseXmlDataTags(String xml) {
        Map<String, String> map = new HashMap<>();
        Pattern p = Pattern.compile("<([A-Z0-9_]+)>\\s*<Data>([^<]*)</Data>\\s*</\\1>");
        Matcher m = p.matcher(xml);
        while (m.find()) {
            map.put(m.group(1), m.group(2));
        }
        return map;
    }

    private static byte[] aesEcbEncryptBlock(byte[] key, byte[] block) throws Exception {
        Cipher c = Cipher.getInstance("AES/ECB/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"));
        return c.doFinal(block);
    }

    private static byte[] aesEcbDecrypt(byte[] key, byte[] data) throws Exception {
        Cipher c = Cipher.getInstance("AES/ECB/NoPadding");
        c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"));
        return c.doFinal(data);
    }

    private static byte[] inflateFrom(byte[] raw, int k) throws Exception {
        int lit = 0;
        byte[] input = raw;
        if (k != 0) {
            List<Integer> bits = new ArrayList<>();
            boolean found = false;
            for (int b = 0; b < 8 && !found; b++) {
                for (int a = 0; a < 8 && !found; a++) {
                    if ((10 * a + 19 * b) % 8 == k && (a != 0 || b != 0)) {
                        lit = b;
                        for (int i = 0; i < a + b; i++) {
                            bits.add(0); bits.add(1); bits.add(0);
                            if (i >= a) {
                                int code = 0b110010000;
                                for (int j = 0; j < 9; j++) {
                                    bits.add((code >> (8 - j)) & 1);
                                }
                            }
                            for (int j = 0; j < 7; j++) bits.add(0);
                        }
                        found = true;
                    }
                }
            }
            int j = bits.size() / 8;
            byte[] pre = new byte[j + 1];
            for (int idx = 0; idx < j; idx++) {
                int v = 0;
                for (int t = 0; t < 8; t++) v |= bits.get(8 * idx + t) << t;
                pre[idx] = (byte) v;
            }
            int last = 0;
            for (int t = 0; t < k; t++) last |= bits.get(8 * j + t) << t;
            pre[j] = (byte) (last | ((raw[0] & 0xff) & ((0xff << k) & 0xff)));
            input = new byte[pre.length + raw.length - 1];
            System.arraycopy(pre, 0, input, 0, pre.length);
            System.arraycopy(raw, 1, input, pre.length, raw.length - 1);
        }

        Inflater inf = new Inflater(true);
        try {
            inf.setDictionary(new byte[32768]);
            inf.setInput(input);
            ByteArrayOutputStream baos = new ByteArrayOutputStream(input.length * 2);
            byte[] tmp = new byte[65536];
            while (!inf.finished()) {
                int n = inf.inflate(tmp);
                if (n > 0) {
                    baos.write(tmp, 0, n);
                } else if (inf.needsInput() || inf.needsDictionary()) {
                    break;
                }
            }
            byte[] full = baos.toByteArray();
            return lit == 0 ? full : Arrays.copyOfRange(full, lit, full.length);
        } finally {
            inf.end();
        }
    }

    private static byte[] lz4Block(byte[] src, int srcOff, int srcLen, byte[] history) throws IOException {
        int cap = Math.max(4096, srcLen * 2) + (history != null ? history.length : 0);
        byte[] dst = new byte[cap];
        int outPos = 0;
        if (history != null && history.length > 0) {
            System.arraycopy(history, 0, dst, 0, history.length);
            outPos = history.length;
        }
        int i = srcOff;
        int end = srcOff + srcLen;
        while (i < end) {
            int t = src[i++] & 0xff;
            int ln = t >>> 4;
            if (ln == 15) {
                int b;
                do {
                    b = src[i++] & 0xff;
                    ln += b;
                } while (b == 255);
            }
            if (ln > 0) {
                dst = ensureCap(dst, outPos + ln);
                System.arraycopy(src, i, dst, outPos, ln);
                i += ln;
                outPos += ln;
            }
            if (i >= end) break;
            int off = (src[i] & 0xff) | ((src[i + 1] & 0xff) << 8);
            i += 2;
            int ml = t & 15;
            if (ml == 15) {
                int b;
                do {
                    b = src[i++] & 0xff;
                    ml += b;
                } while (b == 255);
            }
            ml += 4;
            int st = outPos - off;
            if (off == 0 || st < 0) {
                throw new IOException("bad LZ4 offset");
            }
            dst = ensureCap(dst, outPos + ml);
            if (off >= ml) {
                System.arraycopy(dst, st, dst, outPos, ml);
                outPos += ml;
            } else {
                for (int k = 0; k < ml; k++) {
                    dst[outPos++] = dst[st + (k % off)];
                }
            }
        }
        return Arrays.copyOf(dst, outPos);
    }

    private static byte[] ensureCap(byte[] buf, int need) {
        if (need <= buf.length) return buf;
        int next = buf.length;
        while (next < need) next = Math.max(next * 2, need);
        return Arrays.copyOf(buf, next);
    }

    private static int readLe32(byte[] a, int p) {
        return (a[p] & 0xff)
                | ((a[p + 1] & 0xff) << 8)
                | ((a[p + 2] & 0xff) << 16)
                | ((a[p + 3] & 0xff) << 24);
    }

    private static byte[] md5(byte[] data) throws Exception {
        return MessageDigest.getInstance("MD5").digest(data);
    }

    private static String sha256Hex(byte[] data) throws Exception {
        return bytesToHex(MessageDigest.getInstance("SHA-256").digest(data));
    }

    private static byte[] readAllBytes(File f) throws IOException {
        try (FileInputStream fis = new FileInputStream(f)) {
            return readStream(fis);
        }
    }

    private static byte[] readStream(InputStream in) throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream(65536);
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) >= 0) {
            baos.write(buf, 0, n);
        }
        return baos.toByteArray();
    }

    private static byte[] hexToBytes(String hex) {
        byte[] out = new byte[hex.length() / 2];
        for (int i = 0; i < out.length; i++) {
            out[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }

    private static String bytesToHex(byte[] bytes) {
        char[] hex = "0123456789abcdef".toCharArray();
        char[] out = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int v = bytes[i] & 0xff;
            out[i * 2] = hex[v >>> 4];
            out[i * 2 + 1] = hex[v & 0x0f];
        }
        return new String(out);
    }

    private static String str(Map<String, Object> m, String k) { return (String) m.get(k); }
    private static long lng(Map<String, Object> m, String k) { return ((Number) m.get(k)).longValue(); }
    private static boolean bool(Map<String, Object> m, String k) { return Boolean.TRUE.equals(m.get(k)); }
    @SuppressWarnings("unchecked")
    private static Map<String, Object> obj(Map<String, Object> m, String k) { return (Map<String, Object>) m.get(k); }
    @SuppressWarnings("unchecked")
    private static List<Object> arr(Map<String, Object> m, String k) { return (List<Object>) m.get(k); }

    // Minimal zero-dependency JSON parser for recipe files.
    private static final class MiniJson {
        private final String s;
        private int i;
        MiniJson(String s) { this.s = s; }

        Object parse() {
            ws();
            char c = s.charAt(i);
            if (c == '{') return parseObj();
            if (c == '[') return parseArr();
            if (c == '"') return parseStr();
            if (c == 't') { i += 4; return Boolean.TRUE; }
            if (c == 'f') { i += 5; return Boolean.FALSE; }
            if (c == 'n') { i += 4; return null; }
            return parseNum();
        }

        private void ws() {
            while (i < s.length() && s.charAt(i) <= ' ') i++;
        }

        private Map<String, Object> parseObj() {
            Map<String, Object> m = new HashMap<>();
            i++; ws();
            if (s.charAt(i) == '}') { i++; return m; }
            while (true) {
                ws();
                String k = parseStr();
                ws(); i++; // ':'
                m.put(k, parse());
                ws();
                char c = s.charAt(i++);
                if (c == '}') return m;
            }
        }

        private List<Object> parseArr() {
            List<Object> l = new ArrayList<>();
            i++; ws();
            if (s.charAt(i) == ']') { i++; return l; }
            while (true) {
                l.add(parse());
                ws();
                char c = s.charAt(i++);
                if (c == ']') return l;
            }
        }

        private String parseStr() {
            i++; // '"'
            StringBuilder sb = new StringBuilder();
            while (true) {
                char c = s.charAt(i++);
                if (c == '"') return sb.toString();
                if (c == '\\') {
                    char e = s.charAt(i++);
                    if (e == 'n') sb.append('\n');
                    else if (e == 'r') sb.append('\r');
                    else if (e == 't') sb.append('\t');
                    else sb.append(e);
                } else {
                    sb.append(c);
                }
            }
        }

        private Number parseNum() {
            int start = i;
            if (s.charAt(i) == '-') i++;
            while (i < s.length()) {
                char c = s.charAt(i);
                if (c >= '0' && c <= '9') i++;
                else break;
            }
            return Long.parseLong(s.substring(start, i));
        }
    }
}

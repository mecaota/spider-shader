// =============================================================================
// SilkNetPatternCore.cs — 糸の網（mecaota/SpiderSilkNet）の絵柄を作る生成器の本体。
//
//  ・UnityEngine に依存しない純粋な C#。Unity の Editor（SpiderSilkNetBaker）と、
//    Unity の外の .NET の焼き出しツール（ノートの proto-net\impl-src）の両方が、このファイルを
//    そのままコンパイルして使う（同じ種なら、どちらで焼いても画素の値は同じ。PNG の圧縮のバイト列は実行環境で違ってよい）。
//  ・試作（proto-net\src\NetPatterns.cs、v3）を移したもので、視覚レビュー §10 の直しを入れた。
//    - 籠目: 角の丸めを膜の量から切り離す（距離を 3.5 画素ぼかして閾値を取り、元の糸と合わせる）。
//            小さい穴の連なりは埋めずに、間の糸を消して中くらいの穴 1 つにまとめる。
//            白い面に入る円の半径は 12 画素まで（超える所には穴を開け直す）。
//    - 張り巣: 板の外へつなぐ綱を縁へ向かって半径 5〜6 まで細らせる。縁の固定点は 5〜6 か所まで。
//            中くらいの糸（半径 3〜5）を足し、細い筋を 1.3 倍に増やす（半径 1.5〜3）。
//            結び目の白い面に入る円の半径は 14 画素まで。穴を埋めるのは結び目のまわりの小さい穴だけ。
//  ・膜（糸の間の水かき）は、既定の膜の量（0.3 = 半径 4.8 画素の閉じ処理）で閉じた形の符号付き距離を
//    形の画像の G に焼く（修正 2 回目。以前は「穴の太さ」を焼いて閾値で切っていたが、段々の場なので膜のふちが階段になった）。
//    実行時の _NetFill は、R（糸だけ）と G（膜あり）の距離の間を補間し、焼いた量より多い分は G をずらして足す。
//  ・引き伸ばし膜は作らない（ユーザーの決定）。
//
//  データ版 4。画像の中身:
//    形   (RGB PNG → BC5): R = 糸だけの符号付き距離（糸の内側が負）、G = 既定の膜の量で閉じた形の符号付き距離
//    補助 (RGBA PNG → BC7): RG = ふちの外向き、B = 糸の半径、A = 糸ごとの乱数
//    被覆率 (灰色 PNG → R8): 既定の膜の量での糸＋膜の面積（遠景用。ミップの平均で面積が保たれる）
//  張り巣とドレープ用の板は、縁から 2 画素を必ず穴にする（板の縁で糸や膜がまっすぐ切れて見えないように）。
//  1 枚 512 角を縦に並べた 1 枚の PNG にし、取り込み設定の「2D Array」（行の数 = 枚数）で配列にする。
//  上下の扱い: 生成器の画素の行 y は下向きに増える（PNG の一番上が y = 0）。Unity は PNG の一番上の行を v = 1 として
//  取り込むので、絵柄は上下そのまま見えるが、補助の「ふちの外向き」の y 成分は絵柄の UV（v は上向き）と符号が逆。
//  読む側（SGS_ReadNetDetail）で y の符号を反転している。
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

namespace Mecaota.SpiderShader.SilkNet
{
    // ---------------- 小さな数学の部品（Unity と .NET の両方で同じ結果にするため自前で持つ） ----------------
    public struct V2
    {
        public float X, Y;
        public V2(float x, float y) { X = x; Y = y; }
        public static V2 operator +(V2 a, V2 b) => new V2(a.X + b.X, a.Y + b.Y);
        public static V2 operator -(V2 a, V2 b) => new V2(a.X - b.X, a.Y - b.Y);
        public static V2 operator -(V2 a) => new V2(-a.X, -a.Y);
        public static V2 operator *(V2 a, float s) => new V2(a.X * s, a.Y * s);
        public static V2 operator *(float s, V2 a) => new V2(a.X * s, a.Y * s);
        public static V2 operator /(V2 a, float s) => new V2(a.X / s, a.Y / s);
        public float Length() => M.Sqrt(X * X + Y * Y);
        public static float Dot(V2 a, V2 b) => a.X * b.X + a.Y * b.Y;
        public static V2 Normalize(V2 a) { float l = a.Length(); return l > 1e-12f ? a / l : new V2(1, 0); }
        public static readonly V2 UnitX = new V2(1, 0);
    }

    // (x, y, 半径) の組
    public struct V3
    {
        public float X, Y, Z;
        public V3(float x, float y, float z) { X = x; Y = y; Z = z; }
    }

    public static class M
    {
        public const float PI = 3.14159265358979f;
        public static float Sin(float v) => (float)Math.Sin(v);
        public static float Cos(float v) => (float)Math.Cos(v);
        public static float Sqrt(float v) => (float)Math.Sqrt(v);
        public static float Abs(float v) => v < 0 ? -v : v;
        public static float Floor(float v) => (float)Math.Floor(v);
        public static float Ceiling(float v) => (float)Math.Ceiling(v);
        public static float Round(float v) => (float)Math.Round(v);
        public static float Exp(float v) => (float)Math.Exp(v);
        public static float Pow(float a, float b) => (float)Math.Pow(a, b);
        public static float Atan2(float y, float x) => (float)Math.Atan2(y, x);
        public static float Min(float a, float b) => a < b ? a : b;
        public static float Max(float a, float b) => a > b ? a : b;
        public static int Min(int a, int b) => a < b ? a : b;
        public static int Max(int a, int b) => a > b ? a : b;
        public static float Clamp(float v, float a, float b) => v < a ? a : (v > b ? b : v);
        public static int Clamp(int v, int a, int b) => v < a ? a : (v > b ? b : v);
        public static float Clamp01(float v) => Clamp(v, 0f, 1f);
        public static float Lerp(float a, float b, float t) => a + (b - a) * Clamp01(t);
        public static float Smooth(float t) { t = Clamp01(t); return t * t * (3 - 2 * t); }
    }

    // ---------------- 乱数（試作と同じ xorshift。種が同じなら同じ絵柄） ----------------
    public sealed class NetRng
    {
        ulong s;
        public NetRng(int seed) { s = (ulong)(uint)seed * 2685821657736338717UL + 88172645463325252UL; Next(); Next(); }
        public ulong Next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
        public float F() => (Next() >> 40) / (float)(1 << 24);
        public float R(float a, float b) => a + (b - a) * F();
        public int I(int a, int b) => a + (int)(F() * (b - a));
        public float Sign() => F() < 0.5f ? -1f : 1f;
    }

    // ---------------- 距離変換（Felzenszwalb）・ぼかし ----------------
    public static class NetDt
    {
        const double INF = 1e20;
        static void Dt1(double[] f, int n, double[] d, int[] v, double[] z)
        {
            int k = 0; v[0] = 0; z[0] = -INF; z[1] = INF;
            for (int q = 1; q < n; q++)
            {
                double s = ((f[q] + (double)q * q) - (f[v[k]] + (double)v[k] * v[k])) / (2.0 * q - 2.0 * v[k]);
                while (s <= z[k])
                {
                    k--;
                    s = ((f[q] + (double)q * q) - (f[v[k]] + (double)v[k] * v[k])) / (2.0 * q - 2.0 * v[k]);
                }
                k++; v[k] = q; z[k] = s; z[k + 1] = INF;
            }
            k = 0;
            for (int q = 0; q < n; q++)
            {
                while (z[k + 1] < q) k++;
                double dx = q - v[k];
                d[q] = dx * dx + f[v[k]];
            }
        }

        // feature の画素までの距離の二乗（w×h）
        public static double[] Sq(bool[] feature, int w, int h)
        {
            var g = new double[w * h];
            for (int i = 0; i < g.Length; i++) g[i] = feature[i] ? 0 : INF;
            int m = Math.Max(w, h);
            var f = new double[m]; var d = new double[m]; var v = new int[m]; var z = new double[m + 1];
            for (int x = 0; x < w; x++)
            {
                for (int y = 0; y < h; y++) f[y] = g[y * w + x];
                Dt1(f, h, d, v, z);
                for (int y = 0; y < h; y++) g[y * w + x] = d[y];
            }
            for (int y = 0; y < h; y++)
            {
                for (int x = 0; x < w; x++) f[x] = g[y * w + x];
                Dt1(f, w, d, v, z);
                for (int x = 0; x < w; x++) g[y * w + x] = d[x];
            }
            return g;
        }

        // feature（n×n）までのユークリッド距離。wrap で上下左右をつなぐ（3×3 に並べて測る）
        public static float[] Edt(bool[] feature, int n, bool wrap)
        {
            int W = wrap ? 3 * n : n;
            var big = new bool[W * W];
            for (int y = 0; y < W; y++)
                for (int x = 0; x < W; x++)
                    big[y * W + x] = feature[(y % n) * n + (x % n)];
            var d = Sq(big, W, W);
            var o = new float[n * n];
            int off = wrap ? n : 0;
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                    o[y * n + x] = (float)Math.Min(Math.Sqrt(d[(y + off) * W + x + off]), 1000.0);
            return o;
        }

        // 符号付き距離（画素単位）。糸（thread>=0.5）の内側が負
        public static float[] Sdf(float[] thread, int n, bool wrap)
        {
            var thr = new bool[n * n]; var hol = new bool[n * n];
            for (int i = 0; i < thr.Length; i++) { thr[i] = thread[i] >= 0.5f; hol[i] = !thr[i]; }
            var dOut = Edt(thr, n, wrap);
            var dIn = Edt(hol, n, wrap);
            var sd = new float[n * n];
            for (int i = 0; i < sd.Length; i++) sd[i] = thr[i] ? -(dIn[i] - 0.5f) : (dOut[i] - 0.5f);
            return sd;
        }

        public static float[] Blur(float[] a, int n, float sigma, bool wrap)
        {
            int r = (int)M.Ceiling(sigma * 3);
            var k = new float[2 * r + 1]; float s = 0;
            for (int i = -r; i <= r; i++) { k[i + r] = M.Exp(-i * i / (2 * sigma * sigma)); s += k[i + r]; }
            for (int i = 0; i < k.Length; i++) k[i] /= s;
            var t = new float[n * n]; var o = new float[n * n];
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                {
                    float acc = 0;
                    for (int i = -r; i <= r; i++)
                    {
                        int xx = x + i; xx = wrap ? ((xx % n) + n) % n : M.Clamp(xx, 0, n - 1);
                        acc += a[y * n + xx] * k[i + r];
                    }
                    t[y * n + x] = acc;
                }
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                {
                    float acc = 0;
                    for (int i = -r; i <= r; i++)
                    {
                        int yy = y + i; yy = wrap ? ((yy % n) + n) % n : M.Clamp(yy, 0, n - 1);
                        acc += t[yy * n + x] * k[i + r];
                    }
                    o[y * n + x] = acc;
                }
            return o;
        }
    }

    public struct NetHole
    {
        public int id; public float area, cx, cy, major, minor, angle, eqd;
    }

    public static class NetMorph
    {
        // 穴（thread<0.5）を 4 連結で数える。lab: 0=糸、1..count=穴
        public static NetHole[] LabelHoles(float[] thread, int n, bool wrap, out int[] lab, out int count)
        {
            lab = new int[n * n]; count = 0;
            var stats = new List<NetHole>();
            var qx = new int[n * n]; var qy = new int[n * n]; var qp = new int[n * n];
            int[] dx = { 1, -1, 0, 0 }, dy = { 0, 0, 1, -1 };
            for (int s = 0; s < n * n; s++)
            {
                if (thread[s] >= 0.5f || lab[s] != 0) continue;
                count++;
                int id = count, head = 0, tail = 0;
                lab[s] = id; qp[tail] = s; qx[tail] = 0; qy[tail] = 0; tail++;
                double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0; int cnt = 0;
                int sx0 = s % n, sy0 = s / n;
                while (head < tail)
                {
                    int p = qp[head], ux = qx[head], uy = qy[head]; head++;
                    cnt++; sx += ux; sy += uy; sxx += (double)ux * ux; syy += (double)uy * uy; sxy += (double)ux * uy;
                    int px = p % n, py = p / n;
                    for (int k = 0; k < 4; k++)
                    {
                        int nx = px + dx[k], ny = py + dy[k];
                        if (wrap) { nx = (nx + n) % n; ny = (ny + n) % n; }
                        else if (nx < 0 || ny < 0 || nx >= n || ny >= n) continue;
                        int np = ny * n + nx;
                        if (thread[np] >= 0.5f || lab[np] != 0) continue;
                        lab[np] = id; qp[tail] = np; qx[tail] = ux + dx[k]; qy[tail] = uy + dy[k]; tail++;
                    }
                }
                double mx = sx / cnt, my = sy / cnt;
                double vxx = sxx / cnt - mx * mx + 1.0 / 12, vyy = syy / cnt - my * my + 1.0 / 12, vxy = sxy / cnt - mx * my;
                double tr = vxx + vyy, det = vxx * vyy - vxy * vxy;
                double disc = Math.Sqrt(Math.Max(tr * tr / 4 - det, 0));
                double l1 = tr / 2 + disc, l2 = Math.Max(tr / 2 - disc, 1e-6);
                stats.Add(new NetHole
                {
                    id = id, area = cnt,
                    cx = (float)(((sx0 + mx) % n + n) % n), cy = (float)(((sy0 + my) % n + n) % n),
                    major = (float)(4 * Math.Sqrt(l1)), minor = (float)(4 * Math.Sqrt(l2)),
                    angle = (float)(0.5 * Math.Atan2(2 * vxy, vxx - vyy)),
                    eqd = (float)(2 * Math.Sqrt(cnt / Math.PI))
                });
            }
            return stats.ToArray();
        }
    }

    // ---------------- 円・折れ線のスタンプ ----------------
    public static class NetRast
    {
        public static void Disc(float[] m, int n, float cx, float cy, float r, bool wrap)
        {
            if (r < 0.5f) return;
            int x0 = (int)M.Floor(cx - r), x1 = (int)M.Ceiling(cx + r);
            int y0 = (int)M.Floor(cy - r), y1 = (int)M.Ceiling(cy + r);
            float r2 = r * r;
            for (int y = y0; y <= y1; y++)
            {
                int yy = y;
                if (wrap) yy = ((y % n) + n) % n; else if (y < 0 || y >= n) continue;
                float dy = y - cy;
                for (int x = x0; x <= x1; x++)
                {
                    int xx = x;
                    if (wrap) xx = ((x % n) + n) % n; else if (x < 0 || x >= n) continue;
                    float dx = x - cx;
                    if (dx * dx + dy * dy <= r2) m[yy * n + xx] = 1f;
                }
            }
        }
        // pts: (x, y, 半径)。0.5 画素刻みで円を重ねる
        public static void Stamp(float[] m, int n, IList<V3> pts, bool wrap)
        {
            for (int i = 0; i + 1 < pts.Count; i++)
            {
                var a = pts[i]; var b = pts[i + 1];
                float len = M.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
                int st = Math.Max(1, (int)M.Ceiling(len / 0.5f));
                for (int k = 0; k <= st; k++)
                {
                    float t = (float)k / st;
                    Disc(m, n, a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t, wrap);
                }
            }
        }
        public static bool Hit(float[] m, int n, float x, float y, bool wrap)
        {
            int xi = (int)M.Round(x), yi = (int)M.Round(y);
            if (wrap) { xi = ((xi % n) + n) % n; yi = ((yi % n) + n) % n; }
            else if (xi < 0 || yi < 0 || xi >= n || yi >= n) return false;
            return m[yi * n + xi] >= 0.5f;
        }
    }

    // ---------------- 絵柄 ----------------
    // Drape = ドレープ用の板（張り巣の変種。結び目 1 つと太い幹。配列の Wrap は Clamp で、シェーダーでは張り巣と同じ扱い）
    public enum NetKind { Cage = 0, Web = 1, Drape = 2 }

    public sealed class NetPatternResult
    {
        public NetKind Kind;
        public int Seed;
        public float[] Thread;      // 0/1 の糸（膜なし）
        public float[] Sd;          // 糸の符号付き距離（画素）
        public readonly Dictionary<string, float> Info = new Dictionary<string, float>();
    }

    public static class NetPatterns
    {
        public const int Size = 512;
        public const int DataVersion = 4;
        public const float DistanceRange = 24f;   // 距離の画像の範囲（±画素）。糸の半径の 3 倍以上（張り巣の付け根 12 × 2）
        public const float ThickRange = 16f;      // 穴の太さの範囲（画素）。膜の量 1.0 = 16 画素の閉じ処理
        public const float RadiusRange = 16f;     // 糸の半径の範囲（画素）
        public const float FillMax = 16f;         // _NetFill = 1 のときの膜の半径（画素）

        // G（膜あり）を焼く膜の量。マテリアルの _NetBakeRange.y と合わせる（インスペクタが JSON の closedFill から入れる）。
        // 張り巣は 0.16（0.3 で閉じると、混んだ所の三角の穴が丸められて小さい丸の並び = 細胞に見えた）
        public const float BakedFill = 0.30f;
        public static float DefaultFill(NetKind k) => k == NetKind.Web ? 0.16f : BakedFill;
        // 板の縁で必ず穴にする幅（画素）
        public const int BoardBorder = 2;

        public static NetPatternResult Generate(NetKind kind, int seed, int n = Size)
        {
            return kind == NetKind.Cage ? Cage(n, seed) : Web(n, seed, kind == NetKind.Drape);
        }

        // ========== 共通の部品 ==========
        static V2 Arc(float cx, float cy, float phi, float k, float s)
        {
            if (M.Abs(k) < 1e-5f) return new V2(cx + M.Cos(phi) * s, cy + M.Sin(phi) * s);
            return new V2(cx + (M.Sin(phi + k * s) - M.Sin(phi)) / k, cy - (M.Cos(phi + k * s) - M.Cos(phi)) / k);
        }

        static List<V3> Wavy(NetRng g, float x0, float y0, float th0, float len, float amp, float r)
        {
            float f1 = g.R(0.7f, 1.6f), f2 = g.R(1.7f, 3.2f), p1 = g.R(0, 6.28f), p2 = g.R(0, 6.28f);
            var pts = new List<V3>();
            float x = x0, y = y0;
            for (float s = 0; s <= len; s += 1f)
            {
                float th = th0 + amp * (0.75f * M.Sin(6.2832f * f1 * s / len + p1) + 0.25f * M.Sin(6.2832f * f2 * s / len + p2));
                pts.Add(new V3(x, y, r));
                x += M.Cos(th); y += M.Sin(th);
            }
            return pts;
        }

        static void TaperEnds(List<V3> pts, float len, float minR)
        {
            int n = pts.Count;
            for (int i = 0; i < n; i++)
            {
                float d = Math.Min(i, n - 1 - i);
                float t = M.Smooth(d / len);
                var p = pts[i]; p.Z = M.Max(minR, p.Z * (0.35f + 0.65f * t)); pts[i] = p;
            }
        }

        // 修正 2 回目の籠目用の縄: 筒を 1 周するたがに見えないよう、短く（幅の 30〜45%）、向きをばらし、よく曲げる
        static void AddShortRopes(float[] m, float[] rope, int n, NetRng g, int count, float r, bool wrap, List<List<V3>> rec)
        {
            for (int i = 0; i < count; i++)
            {
                float th0 = g.R(0, M.PI) * (g.F() < 0.5f ? 1f : -1f);
                float len = g.R(0.30f, 0.45f) * n;
                var pts = Wavy(g, g.R(0, n), g.R(0, n), th0, len, g.R(0.45f, 0.8f), r);
                TaperEnds(pts, 40f, r * 0.45f);
                NetRast.Stamp(m, n, pts, wrap);
                if (rope != null) NetRast.Stamp(rope, n, pts, wrap);
                rec?.Add(pts);
            }
        }

        static void AddRopes(float[] m, float[] rope, int n, NetRng g, int count, float r, bool wrap, List<List<V3>> rec)
        {
            for (int i = 0; i < count; i++)
            {
                float y0 = (i + g.R(0.15f, 0.85f)) * n / count;
                float th0 = g.R(-0.6f, 0.6f);
                if (i % 2 == 1) th0 += g.R(-0.5f, 0.5f);
                float len = g.R(1.0f, 1.25f) * n;
                var pts = Wavy(g, g.R(0, n), y0, th0, len, g.R(0.25f, 0.55f), r);
                TaperEnds(pts, 45f, r * 0.45f);
                NetRast.Stamp(m, n, pts, wrap);
                if (rope != null) NetRast.Stamp(rope, n, pts, wrap);
                rec?.Add(pts);
            }
        }

        // 穴の中心付近を通る滑らかな曲線を引き、既存の糸にぶつかった所で止める（pPass の確率で糸を通り抜ける）
        static bool Cut(float[] m, int n, NetRng g, float cx, float cy, float phi, float k, float lmax, float pPass, float r, bool wrap, List<List<V3>> rec, List<V2> ends = null)
        {
            int sPos = Walk(m, n, g, cx, cy, phi, k, +1, lmax, pPass, wrap);
            int sNeg = Walk(m, n, g, cx, cy, phi, k, -1, lmax, pPass, wrap);
            if (sPos < 8 || sNeg < 8) return false;
            if (ends != null)
            {
                // 1 点に集まる線を 4 本までにする
                var e1 = Arc(cx, cy, phi, k, sPos); var e2 = Arc(cx, cy, phi, k, -sNeg);
                foreach (var e in new[] { e1, e2 })
                {
                    int near = 0;
                    foreach (var q in ends)
                    {
                        float dx = M.Abs(q.X - e.X), dy = M.Abs(q.Y - e.Y);
                        if (wrap) { dx = M.Min(dx, n - dx); dy = M.Min(dy, n - dy); }
                        if (dx * dx + dy * dy < 14f * 14f) near++;
                    }
                    if (near >= 2) return false;
                }
                ends.Add(e1); ends.Add(e2);
            }
            var pts = new List<V3>();
            for (int s = -sNeg; s <= sPos; s++)
            {
                var p = Arc(cx, cy, phi, k, s);
                pts.Add(new V3(p.X, p.Y, r));
            }
            NetRast.Stamp(m, n, pts, wrap);
            rec?.Add(pts);
            return true;
        }

        static int Walk(float[] m, int n, NetRng g, float cx, float cy, float phi, float k, int dir, float lmax, float pPass, bool wrap)
        {
            bool through = g.F() < pPass;
            int phase = 0, inCount = 0;
            for (int s = 1; s <= (int)lmax; s++)
            {
                var p = Arc(cx, cy, phi, k, dir * s);
                bool hit = NetRast.Hit(m, n, p.X, p.Y, wrap);
                if (phase == 0)
                {
                    if (hit) { inCount++; if (inCount >= 2) { if (!through) return s; phase = 1; inCount = 0; } } else inCount = 0;
                }
                else if (phase == 1) { if (!hit) { phase = 2; inCount = 0; } }
                else
                {
                    if (hit) { inCount++; if (inCount >= 2) return s; } else inCount = 0;
                }
            }
            return -1;
        }

        // 平行な細い糸の束（裂け目状の細長い穴）。converge で両端を元の糸へ戻す
        static void Bundle(float[] m, int n, NetRng g, List<V3> path, float baseR, float rF, float slit, int lines, bool wrap, bool converge = false, float edgeMargin = 0f)
        {
            if (path.Count < 120) return;
            int len = Math.Min(path.Count - 20, g.I(90, 150));
            int i0 = g.I(10, path.Count - len - 9);
            if (edgeMargin > 0f)
            {
                // v4 直し: 板の縁の近くで束を作ると、入れ子の弧が縁で切れて等高線のような縞に見える。
                // 区間全体が縁から edgeMargin 以上離れる位置を探し、無ければ束を作らない
                bool found = false;
                for (int t = 0; t < 40 && !found; t++)
                {
                    i0 = g.I(10, path.Count - len - 9);
                    found = true;
                    for (int i = 0; i <= len && found; i += 4)
                    {
                        var q = path[i0 + i];
                        if (q.X < edgeMargin || q.Y < edgeMargin || q.X > n - 1 - edgeMargin || q.Y > n - 1 - edgeMargin) found = false;
                    }
                }
                if (!found) return;
            }
            float side = g.Sign();
            float off = baseR + rF * 0.7f;
            for (int L = 0; L < lines; L++)
            {
                float slitMax = slit * g.R(0.9f, 1.2f);
                var pts = new List<V3>();
                for (int i = 0; i <= len; i++)
                {
                    var a = path[i0 + i]; var b = path[Math.Min(i0 + i + 2, path.Count - 1)]; var c = path[Math.Max(i0 + i - 2, 0)];
                    var tg = V2.Normalize(new V2(b.X - c.X, b.Y - c.Y));
                    var nm = new V2(-tg.Y, tg.X) * side;
                    float t = (float)i / len;
                    float bump = M.Pow(M.Sin(M.PI * t), 0.7f);
                    float d = converge ? (off + slitMax) * bump : off + slitMax * bump;
                    pts.Add(new V3(a.X + nm.X * d, a.Y + nm.Y * d, rF));
                }
                NetRast.Stamp(m, n, pts, wrap);
                off += 2 * rF + slitMax * g.R(0.35f, 1.0f) + 1.0f;
            }
        }

        // 大きい穴の中を細い糸で渡す
        static void FineCross(float[] m, int n, NetRng g, float minD, int count, float rF, bool wrap, List<List<V3>> rec)
        {
            var st = NetMorph.LabelHoles(m, n, wrap, out _, out _);
            var cand = st.Where(h => h.eqd >= minD).OrderBy(h => g.F()).Take(count).ToList();
            foreach (var h in cand)
            {
                float phi = g.R(0, M.PI);
                float off = g.R(-0.2f, 0.2f) * h.eqd;
                float cx = h.cx + M.Cos(phi + 1.57f) * off, cy = h.cy + M.Sin(phi + 1.57f) * off;
                Cut(m, n, g, cx, cy, phi, g.R(-1f, 1f) / 380f, 220f, 0.25f, rF, wrap, rec);
            }
        }

        // ---- v4: 小さい穴の連なりを、間の糸を消して 1 つの穴にまとめる ----
        // 最大の穴の ratio 倍以下の穴を「小さい穴」とし、隙間 gap 画素以内でつながる組が 3 個以上なら、
        // 組の穴を半径 closeR の閉じ処理でつなぎ、間の糸（縄は除く）を消す。
        static float[] MergeSmallRuns(float[] m, float[] rope, int n, bool wrap, float ratio, int gap, float closeR, out int merged)
        {
            merged = 0;
            var st = NetMorph.LabelHoles(m, n, wrap, out var lab, out int cnt);
            if (st.Length == 0) return m;
            float dMax = st.Max(h => h.eqd);
            var isSmall = new bool[cnt + 1];
            foreach (var h in st) if (h.eqd <= ratio * dMax) isSmall[h.id] = true;
            // 小さい穴から幅 gap/2 まで広げ、ぶつかった組をつなぐ
            var parent = new int[cnt + 1]; for (int i = 0; i <= cnt; i++) parent[i] = i;
            int Find(int x) { while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; } return x; }
            var owner = new int[n * n]; var dist = new int[n * n];
            var q = new Queue<int>();
            for (int i = 0; i < n * n; i++) if (lab[i] > 0 && isSmall[lab[i]]) { owner[i] = lab[i]; q.Enqueue(i); }
            int half = (gap + 1) / 2;
            int[] dx = { 1, -1, 0, 0 }, dy = { 0, 0, 1, -1 };
            while (q.Count > 0)
            {
                int p = q.Dequeue();
                if (dist[p] >= half) continue;
                int px = p % n, py = p / n;
                for (int k = 0; k < 4; k++)
                {
                    int nx = px + dx[k], ny = py + dy[k];
                    if (wrap) { nx = (nx + n) % n; ny = (ny + n) % n; } else if (nx < 0 || ny < 0 || nx >= n || ny >= n) continue;
                    int np = ny * n + nx;
                    if (owner[np] == 0)
                    {
                        if (lab[np] > 0 && !isSmall[lab[np]]) continue;   // 大きい穴へは広げない
                        owner[np] = owner[p]; dist[np] = dist[p] + 1; q.Enqueue(np);
                    }
                    else if (owner[np] != owner[p])
                    {
                        int a = Find(owner[np]), b = Find(owner[p]);
                        if (a != b) parent[a] = b;
                    }
                }
            }
            var groupSize = new Dictionary<int, int>();
            for (int id = 1; id <= cnt; id++) if (isSmall[id]) { int r = Find(id); groupSize[r] = groupSize.TryGetValue(r, out var c) ? c + 1 : 1; }
            var outp = (float[])m.Clone();
            foreach (var kv in groupSize)
            {
                if (kv.Value < 3) continue;
                merged++;
                var hmask = new bool[n * n];
                for (int i = 0; i < n * n; i++) if (lab[i] > 0 && isSmall[lab[i]] && Find(lab[i]) == kv.Key) hmask[i] = true;
                // 閉じ処理: 穴から closeR 以内に広げ、その外から closeR 以内を削る
                var d1 = NetDt.Edt(hmask, n, wrap);
                var notDil = new bool[n * n];
                for (int i = 0; i < n * n; i++) notDil[i] = d1[i] > closeR;
                var d2 = NetDt.Edt(notDil, n, wrap);
                for (int i = 0; i < n * n; i++)
                    if (d1[i] <= closeR && d2[i] > closeR && (rope == null || rope[i] < 0.5f)) outp[i] = 0f;
            }
            return outp;
        }

        // 板の縁から BoardBorder 画素を穴にする
        public static void ClearBorder(float[] m, int n)
        {
            int b = BoardBorder;
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                    if (x < b || y < b || x >= n - b || y >= n - b) m[y * n + x] = 0f;
        }

        // 小さい穴を埋める。fill(穴) が true の穴だけ埋める
        static float[] FillHoles(float[] m, int n, bool wrap, Func<NetHole, bool> fill)
        {
            var st = NetMorph.LabelHoles(m, n, wrap, out var lab, out int cnt);
            var kill = new bool[cnt + 1];
            foreach (var h in st) if (fill(h)) kill[h.id] = true;
            var o = (float[])m.Clone();
            for (int i = 0; i < o.Length; i++) if (lab[i] > 0 && kill[lab[i]]) o[i] = 1f;
            return o;
        }

        // ---- v4: 角の丸め（膜の量とは別）。距離を sigma でぼかして閾値を取り、元の糸と合わせる ----
        static float[] RoundCorners(float[] m, int n, bool wrap, float sigma)
        {
            var sd = NetDt.Blur(NetDt.Sdf(m, n, wrap), n, sigma, wrap);
            var o = (float[])m.Clone();
            for (int i = 0; i < o.Length; i++) if (sd[i] < 0) o[i] = 1f;
            return o;
        }

        // ---- v4: 白い面に入る円の半径を maxR までにする。超える所の中心に豆形の穴を開け直す ----
        // 穴は「糸のふちから wall 画素より内側」だけを削るので、まわりには wall 画素の糸が残る。縄は残す。
        // wedge = true（張り巣）: 豆形ではなく、塊の長い向きに沿った細長い三角の穴にする。丸い穴が並ぶと
        //   泡や細胞（蓮コラ）に見えるため。さらに、互いに clusterR 以内の穴は maxPerCluster 個までにし、
        //   超える所は開けない（白い面が maxR を少し超えて残るほうを選ぶ）
        static float[] CarveDeep(float[] m, float[] rope, int n, bool wrap, NetRng g, float maxR, float wall, out int carved,
            bool wedge = false, float clusterR = 0f, int maxPerCluster = 0)
        {
            carved = 0;
            var cur = (float[])m.Clone();
            var centers = new List<V2>();
            var blocked = new bool[n * n];
            for (int iter = 0; iter < 40; iter++)
            {
                var sd = NetDt.Sdf(cur, n, wrap);
                // 深い点を深い順に、互いに 48 画素以上離して選ぶ
                var cand = new List<int>();
                for (int i = 0; i < sd.Length; i++) if (-sd[i] > maxR && !blocked[i]) cand.Add(i);
                if (cand.Count == 0) break;
                cand.Sort((a, b) => sd[a].CompareTo(sd[b]));
                var picked = new List<int>();
                foreach (int i in cand)
                {
                    int x = i % n, y = i / n; bool ok = true;
                    foreach (int j in picked)
                    {
                        float ddx = M.Abs(x - j % n), ddy = M.Abs(y - j / n);
                        if (wrap) { ddx = M.Min(ddx, n - ddx); ddy = M.Min(ddy, n - ddy); }
                        if (ddx * ddx + ddy * ddy < 48 * 48) { ok = false; break; }
                    }
                    if (ok) picked.Add(i);
                    if (picked.Count >= 12) break;
                }
                int carvedThisRound = 0;
                foreach (int i in picked)
                {
                    float depth = -sd[i];
                    float R = depth - wall + 1.5f;
                    int cx = i % n, cy = i / n;
                    if (maxPerCluster > 0)
                    {
                        int near = 0;
                        foreach (var c in centers)
                        {
                            float ddx = M.Abs(c.X - cx), ddy = M.Abs(c.Y - cy);
                            if (wrap) { ddx = M.Min(ddx, n - ddx); ddy = M.Min(ddy, n - ddy); }
                            if (ddx * ddx + ddy * ddy < clusterR * clusterR) near++;
                        }
                        if (near >= maxPerCluster)
                        {
                            // この塊にはもう開けない: 近くの深い画素を候補から外す
                            int e = (int)M.Ceiling(R * 2f);
                            for (int oy = -e; oy <= e; oy++)
                                for (int ox = -e; ox <= e; ox++)
                                {
                                    int xx = cx + ox, yy = cy + oy;
                                    if (wrap) { xx = ((xx % n) + n) % n; yy = ((yy % n) + n) % n; } else if (xx < 0 || yy < 0 || xx >= n || yy >= n) continue;
                                    blocked[yy * n + xx] = true;
                                }
                            continue;
                        }
                    }
                    float a, b, th;
                    if (wedge)
                    {
                        // 塊の長い向き: 中心のまわり（半径 2R）で、ふちから wall 以上内側の画素の広がりの主軸
                        double sxx = 0, syy = 0, sxy = 0; int cntW = 0; int e = (int)M.Ceiling(2f * R);
                        for (int oy = -e; oy <= e; oy++)
                            for (int ox = -e; ox <= e; ox++)
                            {
                                int xx = cx + ox, yy = cy + oy;
                                if (wrap) { xx = ((xx % n) + n) % n; yy = ((yy % n) + n) % n; } else if (xx < 0 || yy < 0 || xx >= n || yy >= n) continue;
                                if (-sd[yy * n + xx] < wall) continue;
                                sxx += ox * ox; syy += oy * oy; sxy += ox * oy; cntW++;
                            }
                        th = cntW > 4 ? 0.5f * M.Atan2((float)(2 * sxy), (float)(sxx - syy)) : g.R(0, M.PI);
                        if (g.F() < 0.5f) th += M.PI;   // 三角のとがった先の向きをばらす
                        a = R * g.R(1.9f, 2.4f); b = R * g.R(0.95f, 1.2f);
                    }
                    else { a = R * g.R(1.15f, 1.5f); b = R * g.R(0.75f, 0.95f); th = g.R(0, M.PI); }
                    float ca = M.Cos(th), sa = M.Sin(th);
                    int ext = (int)M.Ceiling(a) + 1;
                    for (int oy = -ext; oy <= ext; oy++)
                        for (int ox = -ext; ox <= ext; ox++)
                        {
                            float u = (ox * ca + oy * sa) / a, v = (-ox * sa + oy * ca) / b;
                            if (wedge) { if (u < -1f || u > 1f || M.Abs(v) > 0.5f * (1f - u)) continue; }   // 細長い三角（u = -1 が底、u = 1 がとがった先）
                            else if (u * u + v * v > 1f) continue;
                            int xx = cx + ox, yy = cy + oy;
                            if (wrap) { xx = ((xx % n) + n) % n; yy = ((yy % n) + n) % n; } else if (xx < 0 || yy < 0 || xx >= n || yy >= n) continue;
                            int k = yy * n + xx;
                            if (-sd[k] >= wall && (rope == null || rope[k] < 0.5f)) cur[k] = 0f;
                        }
                    carved++; carvedThisRound++;
                    centers.Add(new V2(cx, cy));
                }
                if (carvedThisRound == 0 && maxPerCluster > 0)
                {
                    // 開けられる所が無くなった（残りは上限に達した塊だけ）
                    bool any = false;
                    for (int i = 0; i < sd.Length && !any; i++) if (-sd[i] > maxR && !blocked[i]) any = true;
                    if (!any) break;
                }
            }
            return cur;
        }

        // ========== 籠目（糸を先に引く方式、上下左右につながる） ==========
        public static NetPatternResult Cage(int n, int seed)
        {
            var res = new NetPatternResult { Kind = NetKind.Cage, Seed = seed };
            var g = new NetRng(seed);
            const bool wrap = true;
            // v3 の既定値: 縄 4 本・半径 4.25、普通の糸 2.5、細い筋 1.5、穴の差し渡しの上限 80、
            // 通り抜ける確率 0.72、束 3、細い筋 70 本、裂け目 15、点の除去 14.5
            int ropes = 4; float rRope = 4.25f, rNorm = 2.5f, rFine = 1.5f, holeMax = 80f, pPass = 0.72f;
            int bundlesN = 3, fineN = 70; float slit = 15f, minHole = 14.5f;
            var m = new float[n * n]; var rope = new float[n * n];
            var rec = new List<List<V3>>();
            // 修正 2 回目: 長い横向きの縄（筒のたがに見えた）をやめ、短い縄を 8 本にする
            ropes = 8;
            AddShortRopes(m, rope, n, g, ropes, rRope, wrap, rec);
            int cuts = 0, seedsAdded = 0;
            var ends = new List<V2>();
            for (int round = 0; round < 24; round++)
            {
                var st = NetMorph.LabelHoles(m, n, wrap, out _, out _);
                var big = st.Where(h => h.eqd > holeMax).OrderByDescending(h => h.area).ToList();
                if (big.Count == 0) break;
                foreach (var h in big)
                {
                    bool done = false;
                    for (int attempt = 0; attempt < 8 && !done; attempt++)
                    {
                        float rr0 = g.F();
                        float phi = rr0 < 0.45f ? h.angle + g.R(-0.3f, 0.3f) : rr0 < 0.7f ? h.angle + 1.5708f + g.R(-0.4f, 0.4f) : g.R(0, M.PI);
                        float off = g.R(-0.28f, 0.28f) * h.eqd;
                        float cx = h.cx + M.Cos(phi + 1.5708f) * off, cy = h.cy + M.Sin(phi + 1.5708f) * off;
                        // 修正 2 回目: たわみを強め（長さ 128 画素 = 幅の 1/4 で 40〜60 度向きが変わる）、まっすぐ長く進む糸を作らない
                        if (Cut(m, n, g, cx, cy, phi, g.Sign() * g.R(0.0055f, 0.008f), 260f, pPass, rNorm, wrap, rec, ends)) { cuts++; done = true; }
                    }
                    // 切れなかった大きい穴（短い縄にしたので、糸まで 260 画素より遠い所がある）には、
                    // 穴の中ほどに普通の太さの曲がった糸を 1 本置く（次の回でそこから切る）
                    if (!done && h.eqd > 1.6f * holeMax)
                    {
                        var pts = Wavy(g, h.cx, h.cy, g.R(0, 2 * M.PI), g.R(0.2f, 0.3f) * n, g.R(0.5f, 0.9f), rNorm);
                        TaperEnds(pts, 30f, rNorm * 0.6f);
                        NetRast.Stamp(m, n, pts, wrap);
                        rec.Add(pts);
                        seedsAdded++;
                    }
                }
            }
            FineCross(m, n, g, 24f, fineN, rFine, wrap, rec);
            // 修正 2 回目: 縦横比 3 を超える細長い穴は、真ん中に橋を 1 本渡して 2 つに分ける
            int bridges = 0;
            for (int round = 0; round < 4; round++)
            {
                var st = NetMorph.LabelHoles(m, n, wrap, out _, out _);
                var thin = st.Where(h => h.eqd > 20f && h.major > 3f * h.minor).ToList();
                if (thin.Count == 0) break;
                foreach (var h in thin)
                    if (Cut(m, n, g, h.cx, h.cy, h.angle + 1.5708f, g.Sign() * g.R(0.002f, 0.004f), 128f, 0f, rNorm, wrap, rec)) bridges++;
            }
            int bundles = 0;
            var longs = rec.Where(qq => qq.Count > 160).ToList();
            for (int b = 0; b < bundlesN && longs.Count > 0; b++)
            {
                var path = longs[g.I(0, longs.Count)];
                Bundle(m, n, g, path, path[0].Z, rFine, slit, g.I(1, 3), wrap);
                bundles++;
            }
            // ---- v4 の直し ----
            m = MergeSmallRuns(m, rope, n, wrap, 0.3f, 14, 8f, out int merged);
            m = FillHoles(m, n, wrap, h => h.eqd < minHole);
            m = RoundCorners(m, n, wrap, 3.5f);
            m = CarveDeep(m, rope, n, wrap, g, 12f, 3f, out int carved);
            // 開け直した穴の切れ端で点のような穴ができたら埋める
            m = FillHoles(m, n, wrap, h => h.eqd < 8f);
            res.Thread = m;
            res.Sd = NetDt.Blur(NetDt.Sdf(m, n, wrap), n, 0.7f, wrap);
            res.Info["cuts"] = cuts; res.Info["bundles"] = bundles; res.Info["ropes"] = ropes;
            res.Info["merged_runs"] = merged; res.Info["carved_holes"] = carved; res.Info["bridges"] = bridges; res.Info["seed_threads"] = seedsAdded;
            return res;
        }

        // ========== 張り巣（板 1 枚、つながらない） ==========
        // drape = true: ドレープ用の板（修正 2 回目）。真ん中に大きい結び目を 1 つ置き、そこから太い幹（1.5〜2 倍）を出す。
        //   結び目のまわりの股に膜を多めに付け、細い筋は半分にする。縁へは細らせる
        public static NetPatternResult Web(int n, int seed, bool drape = false)
        {
            var res = new NetPatternResult { Kind = drape ? NetKind.Drape : NetKind.Web, Seed = seed };
            var g = new NetRng(seed);
            const bool wrap = false;
            int K = 12;
            float rRoot = 12f, rMidBase = 2.0f, rF = 1.5f;
            int fineN = drape ? 32 : 65;    // v4: 50 → 65（1.3 倍）。ドレープ用は半分
            int mediumN = 15;               // 修正 2 回目: 中くらいの糸 10 → 15 本（1.5 倍）
            // v4 直し: 張り巣の平行な束（両端で幹へ戻る細い 2 本）は、輪郭線と陰の帯が付くと入れ子の弧の縞（等高線）に見えたので作らない。
            // 細長い穴の並びは、細い筋と中くらいの糸の間に自然にできる
            // 修正 2 回目: 板の中で先がとがって終わる糸（ひげ）は、とげに見えたので作らない
            int bundlesN = 0, whiskers = 0, hubs = drape ? 1 : 2;
            float hubR = 55f;
            float tetherEdgeR = 5.5f;       // v4: 綱は縁で半径 5.5
            var m = new float[n * n];
            // 固定点: 4 辺に不規則に。1〜2 辺は飛ばす
            var ts = new List<float>();
            for (int i = 0; i < K; i++) ts.Add((i + g.R(0.1f, 0.9f)) * 4f * n / K);
            var anchors = new List<(V2 pos, V2 inward, int edge)>();
            var skip = new HashSet<int>(); int nSkip = g.I(1, 3); while (skip.Count < nSkip) skip.Add(g.I(0, 4));
            foreach (var t in ts)
            {
                int e = (int)(t / n); float u = t - e * n;
                if (skip.Contains(e)) continue;
                V2 pos, inw;
                switch (e)
                {
                    case 0: pos = new V2(u, 0); inw = new V2(0, 1); break;
                    case 1: pos = new V2(n - 1, u); inw = new V2(-1, 0); break;
                    case 2: pos = new V2(n - 1 - u, n - 1); inw = new V2(0, -1); break;
                    default: pos = new V2(0, n - 1 - u); inw = new V2(1, 0); break;
                }
                // v4: 縁から 6〜15% 内へずらす（綱が縁へ向かって細る長さを取る）
                pos += inw * (g.R(0.06f, 0.15f) * n);
                anchors.Add((pos, inw, e));
            }
            // v4: 縁の固定点は 5〜6 か所まで（多い分は種で選んで外す）
            int maxEdge = g.I(5, 7);
            while (anchors.Count > maxEdge) anchors.RemoveAt(g.I(0, anchors.Count));
            var hubPos = new List<V2>();
            for (int h = 0; h < hubs; h++)
            {
                var hp = drape ? new V2(g.R(0.46f, 0.54f) * n, g.R(0.46f, 0.54f) * n) : new V2(g.R(0.3f, 0.7f) * n, g.R(0.3f, 0.7f) * n);
                hubPos.Add(hp); anchors.Add((hp, V2.UnitX, -1));
            }
            // 綱: 固定点から板の外（取り付け先）へ。v4: 縁で半径 5.5 まで細らせ、ときどき細い 2 本に分ける
            int tethers = 0;
            foreach (var a in anchors)
            {
                if (a.edge < 0) continue;
                bool split = g.F() < 0.35f;
                int cntT = split ? 2 : 1;
                for (int ti = 0; ti < cntT; ti++)
                {
                    float ta = split ? (ti == 0 ? -1f : 1f) * g.R(0.18f, 0.3f) : g.R(-0.35f, 0.35f);
                    var od = new V2(-(a.inward.X * M.Cos(ta) - a.inward.Y * M.Sin(ta)), -(a.inward.X * M.Sin(ta) + a.inward.Y * M.Cos(ta)));
                    // 板の外へ出るまでの長さ
                    float lt = 0; while (lt < n) { var qq = a.pos + od * lt; if (qq.X < 0 || qq.Y < 0 || qq.X > n - 1 || qq.Y > n - 1) break; lt += 1f; }
                    lt = M.Max(lt, 8f);
                    float r0 = split ? rRoot * 0.62f : rRoot, r1 = split ? tetherEdgeR * 0.75f : tetherEdgeR;
                    var tp = new List<V3>();
                    for (float s1 = 0; s1 < lt + 20f; s1 += 1f)
                    {
                        var qq = a.pos + od * s1;
                        tp.Add(new V3(qq.X, qq.Y, M.Lerp(r0, r1, M.Smooth(s1 / lt))));
                    }
                    NetRast.Stamp(m, n, tp, false);
                    tethers++;
                }
            }
            var prim = new List<List<V3>>();
            int linked = 0, strands = 0; var fan = new List<int>();
            var allPts = new List<V2>();
            foreach (var a in anchors)
            {
                bool hub = a.edge < 0;
                int cntS = hub ? (drape ? g.I(7, 10) : g.I(4, 7)) : g.I(2, 5); if (!hub) fan.Add(cntS);
                for (int j = 0; j < cntS; j++)
                {
                    float spread = 0.75f;
                    float da = hub ? (j + g.R(-0.2f, 0.2f)) * 6.2832f / cntS : (cntS == 1 ? 0 : (j / (float)(cntS - 1) - 0.5f) * 2f * spread) + g.R(-0.1f, 0.1f);
                    float ca = M.Cos(da), sa = M.Sin(da);
                    var dir = new V2(a.inward.X * ca - a.inward.Y * sa, a.inward.X * sa + a.inward.Y * ca);
                    float kind = g.F();
                    V2 target; bool anchorEnd = false; bool free = false;
                    if (kind < 0.5f)
                    {
                        float bestScore = 1e9f; V2 bt = default(V2); bool found = false;
                        foreach (var b in anchors)
                        {
                            if (b.edge == a.edge || b.edge < 0) continue;
                            var dv = b.pos - a.pos; float dl = dv.Length();
                            float cosang = V2.Dot(dv / dl, dir);
                            if (cosang < 0.86f) continue;
                            float score = dl * g.R(0.6f, 1.4f);
                            if (score < bestScore) { bestScore = score; bt = b.pos; found = true; }
                        }
                        if (found) { target = bt; anchorEnd = true; linked++; }
                        else { target = a.pos + dir * g.R(150, 330); free = true; }
                    }
                    else if (kind < 0.72f && allPts.Count > 50)
                    {
                        V2 bt = default(V2); float bs = -1;
                        for (int t = 0; t < 60; t++)
                        {
                            var qq = allPts[g.I(0, allPts.Count)];
                            var dv = qq - a.pos; float dl = dv.Length();
                            if (dl < 60 || dl > 300) continue;
                            float c = V2.Dot(dv / dl, dir);
                            if (c > bs) { bs = c; bt = qq; }
                        }
                        if (bs > 0.8f) target = bt; else { target = a.pos + dir * g.R(150, 330); free = true; }
                    }
                    else { target = a.pos + dir * g.R(130, 340); free = true; }
                    if (free)
                    {
                        // 行き先の無い筋は板の外まで延ばす
                        var dv0 = target - a.pos; var dd = V2.Normalize(dv0); float l0 = dv0.Length();
                        while (l0 < 4 * n) { var qq = a.pos + dd * l0; if (qq.X < -24 || qq.Y < -24 || qq.X > n + 23 || qq.Y > n + 23) break; l0 += 8; }
                        target = a.pos + dd * l0;
                    }
                    float len = (target - a.pos).Length();
                    var perp = new V2(-dir.Y, dir.X);
                    float sag = len * g.R(-0.14f, 0.14f);
                    var ctrl = (a.pos + target) * 0.5f + perp * sag * 2f;
                    var pts = new List<V3>();
                    int N = Math.Max(20, (int)len);
                    float wob1 = g.R(0, 6.28f), wobA = g.R(0.5f, 2.2f);
                    float rMid = rMidBase * g.R(1f, 1.4f);   // v4: 筋ごとに中ほどの太さをばらす
                    float arcLen = 0;
                    var raw = new List<V2>();
                    for (int i = 0; i <= N; i++)
                    {
                        float t = (float)i / N;
                        var qq = (1 - t) * (1 - t) * a.pos + 2 * (1 - t) * t * ctrl + t * t * target;
                        qq += perp * (wobA * M.Sin(wob1 + t * 9f) * M.Sin(M.PI * t));
                        raw.Add(qq);
                    }
                    for (int i = 0; i <= N; i++)
                    {
                        if (i > 0) arcLen += (raw[i] - raw[i - 1]).Length();
                        float s0 = arcLen;
                        float tp0 = M.Max(0f, 1f - (s0 / len) / 0.25f), tp1 = M.Max(0f, 1f - ((len - s0) / len) / 0.25f);
                        // ドレープ用の結び目の幹: 中ほど 1.75 倍、付け根 19 画素から長さの 35% で細る
                        bool trunk = drape && hub;
                        float rMidS = trunk ? rMid * 1.75f : rMid;
                        float rootK = hub ? (trunk ? M.Pow(M.Max(0f, 1f - (s0 / len) / 0.35f), 1.2f) : 0f) : M.Pow(anchorEnd ? M.Max(tp0, tp1) : tp0, 1.4f);
                        float rr = rMidS + ((trunk ? 19f : rRoot) - rMidS) * rootK;
                        // 板の外へ出る所は綱と同じく縁で細らせる（四角い枠に見せない）
                        float edgeDist = M.Min(M.Min(raw[i].X, raw[i].Y), M.Min(n - 1 - raw[i].X, n - 1 - raw[i].Y));
                        if (edgeDist < 40f) rr = M.Min(rr, M.Lerp(tetherEdgeR, rr, edgeDist / 40f));
                        pts.Add(new V3(raw[i].X, raw[i].Y, rr));
                        if (i % 4 == 0) allPts.Add(raw[i]);
                    }
                    NetRast.Stamp(m, n, pts, false);
                    prim.Add(pts); strands++;
                }
            }
            // v4: 中くらいの糸（半径 3〜5）。幹どうしを長めにつなぎ、端は少し細らせる
            int mediums = 0;
            for (int tries = 0; tries < 4000 && mediums < mediumN; tries++)
            {
                var A = prim[g.I(0, prim.Count)]; var B = prim[g.I(0, prim.Count)];
                if (A == B) continue;
                var pa = A[g.I((int)(A.Count * 0.2f), (int)(A.Count * 0.85f) + 1)]; var pb = B[g.I((int)(B.Count * 0.2f), (int)(B.Count * 0.85f) + 1)];
                if (pa.X < 20 || pa.Y < 20 || pa.X > n - 21 || pa.Y > n - 21 || pb.X < 20 || pb.Y < 20 || pb.X > n - 21 || pb.Y > n - 21) continue;
                float d = new V2(pa.X - pb.X, pa.Y - pb.Y).Length();
                if (d < 90 || d > 300) continue;
                var nv = new V2(-(pb.Y - pa.Y) / d, (pb.X - pa.X) / d);
                float sagM = d * g.Sign() * g.R(0.06f, 0.16f);   // 修正 2 回目: たるみ（弧）を必ず付ける
                float rM = g.R(3f, 4.5f);
                var pts = new List<V3>();
                for (int i = 0; i <= (int)d; i++)
                {
                    float t = i / d;
                    var qq = new V2(pa.X + (pb.X - pa.X) * t, pa.Y + (pb.Y - pa.Y) * t) + nv * (sagM * 4f * t * (1 - t));
                    float taper = 0.6f + 0.4f * M.Smooth(M.Min(t, 1 - t) / 0.2f);
                    pts.Add(new V3(qq.X, qq.Y, rM * taper));
                }
                NetRast.Stamp(m, n, pts, false);
                prim.Add(pts);
                mediums++;
            }
            // 細い筋: 異なる幹どうしを不規則につなぐ。v4: 半径 1.5〜3
            int made = 0;
            for (int tries = 0; tries < 10000 && made < fineN; tries++)
            {
                var A = prim[g.I(0, prim.Count)]; var B = prim[g.I(0, prim.Count)];
                if (A == B) continue;
                var pa = A[g.I((int)(A.Count * 0.2f), (int)(A.Count * 0.85f) + 1)]; var pb = B[g.I((int)(B.Count * 0.2f), (int)(B.Count * 0.85f) + 1)];
                // 半分は結び目のまわりに集める。v4: 結び目のまわりで見つからないまま 5000 回試したら、この条件を外す
                // （試作では条件を満たせないと本数が止まり、細い筋が 8 本ほどしか引けない板があった）
                if (hubPos.Count > 0 && made % 2 == 0 && tries < 5000)
                {
                    var hp = hubPos[g.I(0, hubPos.Count)];
                    if (new V2(pa.X - hp.X, pa.Y - hp.Y).Length() > hubR || new V2(pb.X - hp.X, pb.Y - hp.Y).Length() > hubR * 1.1f) continue;
                }
                float d = new V2(pa.X - pb.X, pa.Y - pb.Y).Length();
                if (d < 25 || d > 190) continue;
                var nv = new V2(-(pb.Y - pa.Y) / d, (pb.X - pa.X) / d);
                float sagF = d * g.R(-0.12f, 0.12f);
                float rFl = rF * g.R(1f, 2f);
                var pts = new List<V3>();
                for (int i = 0; i <= (int)d; i++)
                {
                    float t = i / d;
                    var qq = new V2(pa.X + (pb.X - pa.X) * t, pa.Y + (pb.Y - pa.Y) * t) + nv * (sagF * 4f * t * (1 - t));
                    pts.Add(new V3(qq.X, qq.Y, rFl));
                }
                NetRast.Stamp(m, n, pts, false);
                made++;
            }
            int bundles = 0;
            var longs = prim.Where(qq => qq.Count > 190).ToList();
            for (int b = 0; b < bundlesN && longs.Count > 0; b++)
            {
                var path = longs[g.I(0, longs.Count)];
                // v4 直し: 束は 2 本（裂け目 1 つ）にし、縁から 70 画素以上離す（入れ子の弧の縞を作らない）
                Bundle(m, n, g, path, rMidBase, rF, 10f, 2, false, true, 70f);
                bundles++;
            }
            // ひげ（先のとがった自由端）
            int freeEnds = 0;
            int nWhisk = whiskers > 0 ? whiskers + (g.F() < 0.5f ? 1 : 0) : 0;   // 修正 2 回目: ひげ 0 本なら 1 本も足さない
            for (int w = 0, tries = 0; w < nWhisk && tries < 400; tries++)
            {
                var A = prim[g.I(0, prim.Count)];
                if (A.Count < 80) continue;
                int ia = g.I((int)(A.Count * 0.3f), (int)(A.Count * 0.7f));
                var a0 = A[ia]; var a1 = A[Math.Min(ia + 3, A.Count - 1)];
                if (a0.Z > rMidBase * 2.1f) continue;
                if (a0.X < 40 || a0.Y < 40 || a0.X > n - 40 || a0.Y > n - 40) continue;
                var tg = V2.Normalize(new V2(a1.X - a0.X, a1.Y - a0.Y));
                float ang = g.Sign() * g.R(0.5f, 1.1f);
                var d = new V2(tg.X * M.Cos(ang) - tg.Y * M.Sin(ang), tg.X * M.Sin(ang) + tg.Y * M.Cos(ang));
                float L = w == 0 ? g.R(85, 105) : g.R(45, 65);
                var tip = new V2(a0.X + d.X * L, a0.Y + d.Y * L);
                if (tip.X < 24 || tip.Y < 24 || tip.X > n - 25 || tip.Y > n - 25) continue;
                bool hit = false;
                for (float s2 = L * 0.3f; s2 <= L + 8 && !hit; s2 += 1f)
                    for (int k = 0; k < 8 && !hit; k++)
                    {
                        float off = s2 < L * 0.6f ? 3f : 8f;
                        if (NetRast.Hit(m, n, a0.X + d.X * s2 + M.Cos(k * 0.785f) * off, a0.Y + d.Y * s2 + M.Sin(k * 0.785f) * off, false)) hit = true;
                    }
                if (hit) continue;
                float r0 = rMidBase * 2.1f;
                var pts = new List<V3>();
                for (int i = 0; i <= (int)L; i++) pts.Add(new V3(a0.X + d.X * i, a0.Y + d.Y * i, M.Max(0.45f, r0 * M.Pow(1 - i / L, 0.85f))));
                NetRast.Stamp(m, n, pts, false);
                freeEnds++; w++;
            }
            // ---- v4 の直し ----
            // 穴を埋めるのは、点のような穴（差し渡し 6 未満）と、結び目のまわりの差し渡し 20 未満の穴だけ
            m = FillHoles(m, n, wrap, h =>
            {
                if (h.eqd < 6f) return true;
                // 修正 2 回目: 丸に近い小さい穴（差し渡し 16 未満、縦横比 2.2 未満）は、膜で丸められると細胞の並びに見えるので埋める。
                // 糸の間の細長い三角は残す
                if (h.eqd < 16f && h.major < 2.2f * h.minor) return true;
                if (h.eqd >= 20f) return false;
                foreach (var hp in hubPos) if (new V2(h.cx - hp.X, h.cy - hp.Y).Length() < hubR * 1.3f) return true;
                return false;
            });
            // v4 直し: 結び目の穴は細長い三角にし、1 つの結び目（半径 70 画素）に 3 個まで（修正 2 回目で 2 → 3）
            if (drape)
            {
                // ドレープ用: 結び目の白い塊と、まわりの股の膜（半径 110 画素の中だけ角を大きく丸める）
                var hp = hubPos[0];
                NetRast.Disc(m, n, hp.X, hp.Y, 24f, false);
                var rounded = RoundCorners(m, n, false, 6f);
                for (int y = 0; y < n; y++)
                    for (int x = 0; x < n; x++)
                        if (new V2(x - hp.X, y - hp.Y).Length() < 110f) m[y * n + x] = rounded[y * n + x];
            }
            // 結び目の白い面は半径 14 画素まで（ドレープ用は大きい結び目を残すので 26 画素まで）
            // 修正 2 回目: 穴の角を丸めてから開け直し、開け直した穴の直角の角も小さく丸める
            m = RoundCorners(m, n, wrap, 2f);
            m = CarveDeep(m, null, n, wrap, g, drape ? 26f : 14f, 3f, out int carved, true, 70f, 3);
            m = RoundCorners(m, n, wrap, 1.0f);
            m = FillHoles(m, n, wrap, h => h.eqd < 6f);
            ClearBorder(m, n);
            res.Thread = m;
            res.Sd = NetDt.Blur(NetDt.Sdf(m, n, wrap), n, 0.7f, wrap);
            int edgeAnchors = anchors.Count(q => q.edge >= 0);
            res.Info["edge_anchors"] = edgeAnchors; res.Info["tethers"] = tethers; res.Info["strands"] = strands;
            res.Info["medium_threads"] = mediums; res.Info["fine_threads"] = made; res.Info["bundles"] = bundles;
            res.Info["free_ends"] = freeEnds; res.Info["linked"] = linked; res.Info["carved_holes"] = carved;
            res.Info["fan_min"] = fan.Count > 0 ? fan.Min() : 0; res.Info["fan_max"] = fan.Count > 0 ? fan.Max() : 0;
            return res;
        }
    }

    // ---------------- 焼き込みの画像（1 枚分） ----------------
    public sealed class NetSlice
    {
        public int N;
        public NetKind Kind;
        public float[] Sd;        // 糸の距離（画素、内側が負）
        public float[] Thick;     // 穴の太さ（画素。糸の画素は ThickRange）。焼く途中の値で、画像には入れない
        public float[] DClosed;   // 既定の膜の量で閉じた形の符号付き距離（画素、内側が負）
        public float[] DirX, DirY;// ふちの外向き
        public float[] Radius;    // 糸の半径（画素）
        public float[] Rand;      // 糸ごとの乱数 0..1
        public float[] Coverage;  // 既定の膜での糸＋膜 0/1
        public readonly Dictionary<string, float> Stats = new Dictionary<string, float>();
    }

    public static class NetBake
    {
        // 1 枚分の補助の値を作る
        public static NetSlice MakeSlice(NetPatternResult r, int n = NetPatterns.Size)
        {
            bool wrap = r.Kind == NetKind.Cage;
            var s = new NetSlice { N = n, Kind = r.Kind, Sd = r.Sd };
            // 穴の太さ: 半径 c の円が収まる所（穴の開き処理）を 0.5 画素刻みで調べ、収まる最大の c を入れる
            var dist = new float[n * n];
            for (int i = 0; i < dist.Length; i++) dist[i] = r.Sd[i] + 0.5f;   // 糸のふちまでの距離
            s.Thick = new float[n * n];
            for (float c = 0.5f; c <= NetPatterns.ThickRange + 1e-3f; c += 0.5f)
            {
                var core = new bool[n * n]; bool any = false;
                for (int i = 0; i < core.Length; i++) { core[i] = dist[i] >= c; any |= core[i]; }
                if (!any) break;
                var d = NetDt.Edt(core, n, wrap);
                for (int i = 0; i < d.Length; i++) if (r.Sd[i] > 0 && d[i] <= c) s.Thick[i] = c;
            }
            for (int i = 0; i < s.Thick.Length; i++) if (r.Sd[i] > 0 && s.Thick[i] >= NetPatterns.ThickRange) s.Thick[i] = NetPatterns.ThickRange;
            // 糸の画素は範囲の上限にする（実行時の膜の距離「穴の太さ − 膜の半径」が糸の中で負にならず、糸の距離をそのまま使える）
            for (int i = 0; i < s.Thick.Length; i++) if (r.Sd[i] <= 0) s.Thick[i] = NetPatterns.ThickRange;
            // 膜あり（既定の膜の量で閉じた形）: 穴の太さが膜の半径より小さい所を糸に足し、距離にしてから 1.5 画素ぼかす
            {
                float fillPx = NetPatterns.DefaultFill(r.Kind) * NetPatterns.FillMax;
                var closed = new float[n * n];
                for (int i = 0; i < closed.Length; i++) closed[i] = (r.Sd[i] <= 0 || s.Thick[i] < fillPx) ? 1f : 0f;
                if (!wrap) NetPatterns.ClearBorder(closed, n);
                s.DClosed = NetDt.Blur(NetDt.Sdf(closed, n, wrap), n, 1.5f, wrap);
                // 膜ありの形は糸だけの形を必ず含む（距離は糸だけ以下）
                for (int i = 0; i < s.DClosed.Length; i++) s.DClosed[i] = M.Min(s.DClosed[i], r.Sd[i]);
            }
            // ふちの外向き（距離の勾配）
            s.DirX = new float[n * n]; s.DirY = new float[n * n];
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                {
                    int xp = wrap ? (x + 1) % n : M.Min(x + 1, n - 1), xm = wrap ? (x - 1 + n) % n : M.Max(x - 1, 0);
                    int yp = wrap ? (y + 1) % n : M.Min(y + 1, n - 1), ym = wrap ? (y - 1 + n) % n : M.Max(y - 1, 0);
                    float gx = r.Sd[y * n + xp] - r.Sd[y * n + xm], gy = r.Sd[yp * n + x] - r.Sd[ym * n + x];
                    float l = M.Sqrt(gx * gx + gy * gy);
                    if (l < 1e-5f) { gx = 1; gy = 0; l = 1; }
                    s.DirX[y * n + x] = gx / l; s.DirY[y * n + x] = gy / l;
                }
            // 糸の半径: 糸の内側の深さの最大値を、半径 9 画素の窓で拾う（穴の側にも近くの糸の値が入る）
            var dep = new float[n * n]; for (int i = 0; i < dep.Length; i++) dep[i] = M.Max(0, -r.Sd[i] + 0.5f);
            s.Radius = MaxFilter(dep, n, 9, wrap);
            for (int i = 0; i < s.Radius.Length; i++) s.Radius[i] = M.Clamp(s.Radius[i], 1f, NetPatterns.RadiusRange);
            // 糸ごとの乱数: なめらかな値のノイズ（籠目は周期 8 マスでつながる）
            s.Rand = new float[n * n];
            var g = new NetRng(r.Seed * 7 + 3);
            const int cells = 8; var lat = new float[cells * cells]; for (int i = 0; i < lat.Length; i++) lat[i] = g.F();
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                {
                    float fx = x * cells / (float)n, fy = y * cells / (float)n;
                    int ix = (int)fx, iy = (int)fy; float tx = M.Smooth(fx - ix), ty = M.Smooth(fy - iy);
                    int ix1 = (ix + 1) % cells, iy1 = (iy + 1) % cells;
                    float a = lat[iy * cells + ix], b = lat[iy * cells + ix1], c = lat[iy1 * cells + ix], d = lat[iy1 * cells + ix1];
                    s.Rand[y * n + x] = (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty;
                }
            // 被覆率（既定の膜の量）
            float fill = NetPatterns.DefaultFill(r.Kind) * NetPatterns.FillMax;
            s.Coverage = new float[n * n];
            int thr0 = 0, thrF = 0, outer = 0, thO = 0; float maxDepth = 0;
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                {
                    int i = y * n + x;
                    bool t0 = r.Sd[i] < 0;
                    bool tf = s.DClosed[i] < 0;
                    s.Coverage[i] = tf ? 1f : 0f;
                    if (t0) thr0++;
                    if (tf) thrF++;
                    maxDepth = M.Max(maxDepth, -r.Sd[i]);
                    float rr = M.Max(M.Abs(x - n / 2f), M.Abs(y - n / 2f)) / (n / 2f);
                    if (rr > 0.5f) { outer++; if (tf) thO++; }
                }
            s.Stats["thread_fraction_fill0"] = thr0 / (float)(n * n);
            s.Stats["thread_fraction_default_fill"] = thrF / (float)(n * n);
            s.Stats["thread_fraction_outer_default_fill"] = thO / (float)outer;
            s.Stats["max_inscribed_radius_px"] = maxDepth;
            var holes = NetMorph.LabelHoles(r.Thread, n, wrap, out _, out _);
            if (holes.Length > 0)
            {
                s.Stats["holes"] = holes.Length;
                s.Stats["hole_eqd_max"] = holes.Max(h => h.eqd);
                s.Stats["hole_eqd_min"] = holes.Min(h => h.eqd);
            }
            foreach (var kv in r.Info) s.Stats[kv.Key] = kv.Value;
            return s;
        }

        static float[] MaxFilter(float[] a, int n, int R, bool wrap)
        {
            var t = new float[n * n]; var o = new float[n * n];
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                {
                    float m = 0;
                    for (int k = -R; k <= R; k++) { int xx = wrap ? ((x + k) % n + n) % n : M.Clamp(x + k, 0, n - 1); m = M.Max(m, a[y * n + xx]); }
                    t[y * n + x] = m;
                }
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                {
                    float m = 0;
                    for (int k = -R; k <= R; k++) { int yy = wrap ? ((y + k) % n + n) % n : M.Clamp(y + k, 0, n - 1); m = M.Max(m, t[yy * n + x]); }
                    o[y * n + x] = m;
                }
            return o;
        }

        static byte B(float v) => (byte)M.Clamp((int)Math.Round(v * 255.0), 0, 255);

        // 枚を縦に並べた 3 種類の画像（形 RGB・補助 RGBA・被覆率 灰色）の画素を作る。行 0 = 画像の一番上
        public static void Pack(IList<NetSlice> slices, out byte[] shape, out byte[] detail, out byte[] coverage, out int width, out int height)
        {
            int n = slices[0].N; width = n; height = n * slices.Count;
            shape = new byte[width * height * 3]; detail = new byte[width * height * 4]; coverage = new byte[width * height];
            for (int k = 0; k < slices.Count; k++)
            {
                var s = slices[k];
                for (int i = 0; i < n * n; i++)
                {
                    int o = k * n * n + i;
                    shape[o * 3 + 0] = B(0.5f + s.Sd[i] / (2f * NetPatterns.DistanceRange));
                    shape[o * 3 + 1] = B(0.5f + s.DClosed[i] / (2f * NetPatterns.DistanceRange));
                    shape[o * 3 + 2] = 0;
                    detail[o * 4 + 0] = B(0.5f + 0.5f * s.DirX[i]);
                    detail[o * 4 + 1] = B(0.5f + 0.5f * s.DirY[i]);
                    detail[o * 4 + 2] = B(s.Radius[i] / NetPatterns.RadiusRange);
                    detail[o * 4 + 3] = B(s.Rand[i]);
                    coverage[o] = B(s.Coverage[i]);
                }
            }
        }

        // 種と設定の JSON（同じ絵柄を再現するため）
        public static string Json(NetKind kind, IList<int> seeds, IList<NetSlice> slices, string tool)
        {
            var ci = CultureInfo.InvariantCulture;
            var sb = new StringBuilder();
            sb.Append("{\n");
            sb.Append("  \"dataVersion\": ").Append(NetPatterns.DataVersion).Append(",\n");
            sb.Append("  \"kind\": \"").Append(kind.ToString()).Append("\",\n");
            sb.Append("  \"generator\": \"SilkNetPatternCore v4\",\n");
            sb.Append("  \"tool\": \"").Append(tool).Append("\",\n");
            sb.Append("  \"size\": ").Append(slices[0].N).Append(",\n");
            sb.Append("  \"sliceCount\": ").Append(slices.Count).Append(",\n");
            sb.Append("  \"wrap\": \"").Append(kind == NetKind.Cage ? "Repeat" : "Clamp").Append("\",\n");
            sb.Append("  \"seeds\": [").Append(string.Join(", ", seeds.Select(v => v.ToString(ci)))).Append("],\n");
            sb.Append("  \"distanceRangePx\": ").Append(NetPatterns.DistanceRange.ToString(ci)).Append(",\n");
            sb.Append("  \"closedFill\": ").Append(NetPatterns.DefaultFill(kind).ToString(ci)).Append(",\n");
            sb.Append("  \"radiusRangePx\": ").Append(NetPatterns.RadiusRange.ToString(ci)).Append(",\n");
            sb.Append("  \"fillMaxPx\": ").Append(NetPatterns.FillMax.ToString(ci)).Append(",\n");
            sb.Append("  \"coverageFill\": ").Append(NetPatterns.DefaultFill(kind).ToString(ci)).Append(",\n");
            sb.Append("  \"layout\": \"slices stacked vertically, slice 0 at the top; import as 2D Array with flipbookRows = sliceCount\",\n");
            sb.Append("  \"slices\": [\n");
            for (int k = 0; k < slices.Count; k++)
            {
                sb.Append("    { \"seed\": ").Append(seeds[k].ToString(ci));
                foreach (var kv in slices[k].Stats.OrderBy(p => p.Key, StringComparer.Ordinal))
                    sb.Append(", \"").Append(kv.Key).Append("\": ").Append(Math.Round(kv.Value, 4).ToString(ci));
                sb.Append(" }").Append(k + 1 < slices.Count ? ",\n" : "\n");
            }
            sb.Append("  ]\n}\n");
            return sb.ToString();
        }

        // 絵柄 1 種類を焼いて、PNG 3 枚と JSON を書き出す。戻り値は 1 枚ずつの値（プレビュー用）
        public static List<NetSlice> BakeSet(NetKind kind, IList<int> seeds, string outDir, string baseName, string tool)
        {
            var slices = new List<NetSlice>();
            foreach (int seed in seeds) slices.Add(MakeSlice(NetPatterns.Generate(kind, seed)));
            Pack(slices, out var shape, out var detail, out var coverage, out int w, out int h);
            Directory.CreateDirectory(outDir);
            File.WriteAllBytes(Path.Combine(outDir, baseName + "_Shape.png"), NetPng.Encode(w, h, 3, shape));
            File.WriteAllBytes(Path.Combine(outDir, baseName + "_Detail.png"), NetPng.Encode(w, h, 4, detail));
            File.WriteAllBytes(Path.Combine(outDir, baseName + "_Coverage.png"), NetPng.Encode(w, h, 1, coverage));
            File.WriteAllText(Path.Combine(outDir, baseName + ".json"), Json(kind, seeds, slices, tool).Replace("\n", "\r\n"), new UTF8Encoding(false));
            return slices;
        }

        // 既定の種（焼き直しで同じ絵柄を作る）。張り巣は種 39 と同じ程度に読める板を選んだ（IMPL-NOTES 参照）
        public static readonly int[] DefaultCageSeeds = { 21, 26 };
        public static readonly int[] DefaultWebSeeds = { 55, 54, 53 };
        public static readonly int[] DefaultDrapeSeeds = { 46, 53 };
    }

    // ---------------- PNG の書き出し（zlib の枠を自前で付ける。Unity と .NET の両方で動く） ----------------
    public static class NetPng
    {
        static readonly uint[] Crc = MakeCrc();
        static uint[] MakeCrc()
        {
            var t = new uint[256];
            for (uint n = 0; n < 256; n++)
            {
                uint c = n;
                for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                t[n] = c;
            }
            return t;
        }
        static void Be32(Stream s, uint v) { s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v); }
        static void Chunk(Stream s, string type, byte[] data)
        {
            Be32(s, (uint)data.Length);
            var tb = Encoding.ASCII.GetBytes(type);
            s.Write(tb, 0, tb.Length);
            s.Write(data, 0, data.Length);
            uint c = 0xFFFFFFFFu;
            foreach (var b in tb) c = Crc[(c ^ b) & 0xFF] ^ (c >> 8);
            foreach (var b in data) c = Crc[(c ^ b) & 0xFF] ^ (c >> 8);
            Be32(s, c ^ 0xFFFFFFFFu);
        }
        // ch: 1 = 灰色, 3 = RGB, 4 = RGBA（8 ビット）
        public static byte[] Encode(int w, int h, int ch, byte[] px)
        {
            var raw = new byte[(w * ch + 1) * h];
            for (int y = 0; y < h; y++)
            {
                raw[y * (w * ch + 1)] = 0;
                Buffer.BlockCopy(px, y * w * ch, raw, y * (w * ch + 1) + 1, w * ch);
            }
            var z = new MemoryStream();
            z.WriteByte(0x78); z.WriteByte(0x9C);
            using (var ds = new DeflateStream(z, CompressionLevel.Optimal, true)) ds.Write(raw, 0, raw.Length);
            uint a = 1, b = 0;
            foreach (byte v in raw) { a = (a + v) % 65521; b = (b + a) % 65521; }
            Be32(z, (b << 16) | a);
            var fs = new MemoryStream();
            fs.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }, 0, 8);
            var ih = new byte[13];
            ih[0] = (byte)(w >> 24); ih[1] = (byte)(w >> 16); ih[2] = (byte)(w >> 8); ih[3] = (byte)w;
            ih[4] = (byte)(h >> 24); ih[5] = (byte)(h >> 16); ih[6] = (byte)(h >> 8); ih[7] = (byte)h;
            ih[8] = 8; ih[9] = (byte)(ch == 1 ? 0 : ch == 3 ? 2 : 6);
            Chunk(fs, "IHDR", ih);
            Chunk(fs, "IDAT", z.ToArray());
            Chunk(fs, "IEND", new byte[0]);
            return fs.ToArray();
        }
    }
}

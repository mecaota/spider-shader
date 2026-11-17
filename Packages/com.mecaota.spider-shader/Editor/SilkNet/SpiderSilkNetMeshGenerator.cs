using System.IO;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderSilkNetMeshGenerator — 糸の網（mecaota/SpiderSilkNet）用のメッシュを作る（エディタ専用）。
//
//  ・籠（SilkNetCage）: 上（吊る所）を絞り、下を丸く閉じた筒（参考の 1 枚目と同じ向き。修正 2 回目で上下を直した）。
//    半径にむらを付けて輪郭をでこぼこにする（輪郭はメッシュの仕事）。
//    原点が籠の中心。高さ 2.2、半径 0.42（人が入る大きさ）。UV は u = 周、v = 子午線の長さ ÷ 周の長さ
//    なので、_NetTiling (1, 1) で絵柄の画素がほぼ正方形になる（周 1 回で絵柄 1 枚、縦は約 0.85 枚）。
//    マテリアルの「籠の半分の大きさ」(_NetCageExtent) は (0.47, 1.1, 0.47)。
//  ・内側の籠（SilkNetCageInner）: 籠を 0.92 倍にし、面を裏返したもの（法線は内向き）。
//    外の籠を「描かない」、内側の籠を「内側の籠用」にすると、外から奥の壁だけが見える。
//    面を裏返さないと、手前の壁が二重に見える。
//  ・平面 17×17（SilkNetPlane17）と 33×33（SilkNetPlane33）: 体に当たった巣・ドレープ用。
//    WebPlaneMeshGenerator と同じ形（1 辺 1、XZ 平面、法線 +Y、変形を見込んだ広いバウンズ）。
//  保存先はパッケージの Runtime/SilkNet/Meshes（書き込めないときは Assets/SpiderSilkNet/Meshes）。
//  既存のアセットは GUID を保ったまま中身を入れ替える。
// =============================================================================
public static class SpiderSilkNetMeshGenerator
{
    public const float CageHeight = 2.2f;
    public const float CageRadius = 0.42f;
    public const float InnerScale = 0.92f;

    [MenuItem("Tools/SpiderShader/糸の網/メッシュを作る（籠・内側の籠・平面）")]
    static void MenuGenerate()
    {
        string folder = MeshFolder();
        EnsureFolder(folder);
        SaveMesh(BuildCage(64, 96, 1f, false, 7), folder + "/SilkNetCage.asset");
        SaveMesh(BuildCage(64, 96, InnerScale, true, 7), folder + "/SilkNetCageInner.asset");
        WebPlaneMeshGenerator.Generate(folder + "/SilkNetPlane17.asset", 16, 1f, 2f, 0.5f);
        WebPlaneMeshGenerator.Generate(folder + "/SilkNetPlane33.asset", 32, 1f, 2f, 0.5f);
        AssetDatabase.SaveAssets();
        Debug.Log("[糸の網] メッシュを作りました: " + folder);
    }

    static string MeshFolder()
    {
        string patterns = SpiderSilkNetBaker.PatternFolder();
        if (patterns != null)
        {
            string folder = Path.GetDirectoryName(patterns).Replace('\\', '/') + "/Meshes";
            if (folder.StartsWith("Assets/")) return folder;
            // 書き込めるのはプロジェクトの Packages の中に実体がある埋め込みのパッケージだけ
            // （PackageCache の物や、プロジェクトの外を指すローカルのパッケージには書かない）
            var info = UnityEditor.PackageManager.PackageInfo.FindForAssetPath(folder);
            if (info != null && info.source == UnityEditor.PackageManager.PackageSource.Embedded)
                return folder;
        }
        return "Assets/SpiderSilkNet/Meshes";
    }

    static void EnsureFolder(string folder)
    {
        if (AssetDatabase.IsValidFolder(folder)) return;
        Directory.CreateDirectory(FileUtil.GetPhysicalPath(folder));
        AssetDatabase.Refresh();
    }

    // 子午線の形（0..1 の高さ t、0 が下 → 半径の倍率）。上（t = 1）は絞り、下（t = 0）は丸く閉じる。
    // 試作の籠の式は「上から測った深さ」なので、t を上下反転して使う
    static float Profile(float t)
    {
        float h = (1f - t) * 5.3f;                // 試作の籠と同じ比（高さ 5.3 : 半径 1）。h は上からの深さ
        if (h < 1.2f) { float s = h / 1.2f; s = s * s * (3 - 2 * s); return 0.05f + 0.95f * Mathf.Pow(s, 0.9f); }
        if (h < 4.8f) return 1.0f + 0.035f * Mathf.Sin(Mathf.PI * (h - 1.2f) / 3.6f);
        float q = (h - 4.8f) / 0.5f;
        return Mathf.Max(0.03f, Mathf.Pow(Mathf.Max(0f, 1f - Mathf.Pow(q, 2.5f)), 0.5f));
    }

    // 半径のむら（輪郭をでこぼこにする）。上下の端では 0
    static float Wobble(float t, float th, float amp, float phase)
    {
        float h = (1f - t) * 5.3f;
        float fade = Mathf.Clamp01((h - 0.3f) / 1.0f) * Mathf.Clamp01((5.3f - h) / 0.6f);
        return 1f + amp * fade * (0.6f * Mathf.Sin(2 * th + 0.7f + h * 0.9f + phase) + 0.4f * Mathf.Sin(3 * th + h * 1.7f + 2f) + 0.3f * Mathf.Sin(5 * th - h * 2.3f + phase * 0.5f));
    }

    public static Mesh BuildCage(int around, int rows, float scale, bool flipped, int seed)
    {
        float phase = seed * 1.37f;
        int cols = around + 1;                    // 継ぎ目の頂点は 2 つ持つ（u = 0 と 1）
        var pos = new Vector3[cols * (rows + 1)];
        for (int j = 0; j <= rows; j++)
        {
            float t = (float)j / rows;
            for (int i = 0; i <= around; i++)
            {
                float th = 2f * Mathf.PI * i / around;
                float r = CageRadius * Profile(t) * Wobble(t, th, 0.065f, phase);
                pos[j * cols + i] = new Vector3(Mathf.Sin(th) * r, (t - 0.5f) * CageHeight, Mathf.Cos(th) * r) * scale;
            }
        }
        // v = 子午線の長さ ÷ 周の長さ（周方向の平均）
        var vAcc = new float[rows + 1];
        float circ = 2f * Mathf.PI * CageRadius * scale;
        for (int j = 1; j <= rows; j++)
        {
            float sum = 0f;
            for (int i = 0; i < around; i++) sum += Vector3.Distance(pos[j * cols + i], pos[(j - 1) * cols + i]);
            vAcc[j] = vAcc[j - 1] + sum / around / circ;
        }
        var uv = new Vector2[pos.Length]; var nrm = new Vector3[pos.Length]; var tan = new Vector4[pos.Length];
        for (int j = 0; j <= rows; j++)
            for (int i = 0; i <= around; i++)
            {
                int k = j * cols + i;
                uv[k] = new Vector2((float)i / around, vAcc[j]);
                int ip = (i + 1) % around, im = (i - 1 + around) % around;
                Vector3 du = pos[j * cols + ip] - pos[j * cols + im];
                Vector3 dv = pos[Mathf.Min(j + 1, rows) * cols + i] - pos[Mathf.Max(j - 1, 0) * cols + i];
                Vector3 n = Vector3.Cross(du, dv);   // 外向き（u は +x 回り、v は上向き）
                if (n.sqrMagnitude < 1e-12f) n = new Vector3(pos[k].x, 0f, pos[k].z);
                if (Vector3.Dot(n, new Vector3(pos[k].x, 0f, pos[k].z)) < 0f) n = -n;
                n = n.normalized;
                if (n.sqrMagnitude < 0.5f) n = j == 0 ? Vector3.down : Vector3.up;
                if (flipped) n = -n;
                nrm[k] = n;
                Vector3 tg = du.sqrMagnitude > 1e-12f ? du.normalized : Vector3.right;
                // 従法線（cross(N, T) × w）が v の増える向き（上）になるよう w を決める
                float w = Vector3.Dot(Vector3.Cross(n, tg), dv) >= 0f ? 1f : -1f;
                tan[k] = new Vector4(tg.x, tg.y, tg.z, w);
            }
        var tris = new int[around * rows * 6];
        int q = 0;
        for (int j = 0; j < rows; j++)
            for (int i = 0; i < around; i++)
            {
                int a = j * cols + i, b = a + 1, c = a + cols, d = c + 1;
                // 外向きの面が表（三角形 a,b,c の表の向きは cross(b - a, c - a)。u は周、v は上向き）。内側の籠は裏返す
                if (!flipped) { tris[q++] = a; tris[q++] = b; tris[q++] = c; tris[q++] = b; tris[q++] = d; tris[q++] = c; }
                else          { tris[q++] = a; tris[q++] = c; tris[q++] = b; tris[q++] = b; tris[q++] = c; tris[q++] = d; }
            }
        var mesh = new Mesh { name = flipped ? "SilkNetCageInner" : "SilkNetCage" };
        mesh.indexFormat = UnityEngine.Rendering.IndexFormat.UInt16;
        mesh.vertices = pos; mesh.normals = nrm; mesh.tangents = tan; mesh.uv = uv; mesh.triangles = tris;
        mesh.RecalculateBounds();
        var bb = mesh.bounds; bb.Expand(0.05f); mesh.bounds = bb;
        return mesh;
    }

    static void SaveMesh(Mesh src, string path)
    {
        var mesh = AssetDatabase.LoadAssetAtPath<Mesh>(path);
        if (mesh == null)
        {
            AssetDatabase.CreateAsset(src, path);
            return;
        }
        mesh.Clear();
        mesh.name = src.name;
        mesh.indexFormat = src.indexFormat;
        mesh.vertices = src.vertices; mesh.normals = src.normals; mesh.tangents = src.tangents; mesh.uv = src.uv;
        mesh.triangles = src.triangles; mesh.bounds = src.bounds;
        EditorUtility.SetDirty(mesh);
        Object.DestroyImmediate(src);
    }
}

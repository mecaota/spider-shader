using System.IO;
using UnityEditor;
using UnityEngine;

// =============================================================================
// WebPlaneMeshGenerator — 足捕縛の変形（SpiderWeb の _PullEnable）用 細分化平面メッシュ生成
//
//  Unity 標準の Plane は 10×10 分割（11×11 頂点・10m 角）しかなく、足まわりを
//  なめらかな円錐状に持ち上げるには粗すぎる。ここでは 1 unit 角・N×N 分割の平面
//  （XZ 平面・法線 +Y・UV 0..1・接線 +X）をメッシュアセットとして生成する。
//  UV の中央 (0.5, 0.5) が平面の中心＝巣のハブになる。
//
//  ★ バウンズ拡張:
//     頂点シェーダーの変位は Renderer のバウンズを広げないため、足を持ち上げた
//     頂点が画面端で「メッシュごと」フラスタムカリングされうる。メッシュの bounds を
//     法線方向 ±boundsUp・横方向 +boundsLateral だけ広げて保存する（オブジェクト
//     空間なので Transform のスケールにも追従する）。
//     ※ Batching Static を付けると結合メッシュになりこのバウンズが失われるので禁止。
//
//  既存アセットがあれば mesh.Clear()＋再充填で GUID を維持する（シーン参照が切れない）。
//  Editor 専用。ワールドのビルドには含まれない。
// =============================================================================
public class WebPlaneMeshGenerator : ScriptableWizard
{
    public const string DefaultAssetPath = "Assets/mecaota/models/WebPlane.asset";
    private const int   DefaultSegments  = 64;

    [Tooltip("1 辺の分割数。頂点数は (segments+1)^2。最大 255（16bit インデックスに収める）")]
    public int segments = DefaultSegments;

    [Tooltip("平面の 1 辺の長さ（ローカル単位）")]
    public float size = 1f;

    [Tooltip("バウンズを法線方向（±Y）へ広げる量（ローカル単位）")]
    public float boundsUp = 2f;

    [Tooltip("バウンズを横方向（XZ・片側）へ広げる量（ローカル単位）")]
    public float boundsLateral = 0.5f;

    [Tooltip("保存先アセットパス（Assets/ からの相対）")]
    public string assetPath = DefaultAssetPath;

    [MenuItem("Tools/SpiderShader/Generate WebPlane Mesh...")]
    private static void Open()
    {
        DisplayWizard<WebPlaneMeshGenerator>("WebPlane Mesh", "Generate");
    }

    // ダイアログ無しで既定パスへ再生成する（MCP の execute_menu_item 等から冪等に呼べる）
    [MenuItem("Tools/SpiderShader/Regenerate WebPlane Mesh (Default Path)")]
    private static void RegenerateDefault()
    {
        Generate(DefaultAssetPath, DefaultSegments, 1f, 2f, 0.5f);
    }

    private void OnWizardCreate()
    {
        Generate(assetPath, segments, size, boundsUp, boundsLateral);
    }

    private void OnWizardUpdate()
    {
        int s = Mathf.Clamp(segments, 1, 255);
        helpString = $"頂点 {(s + 1) * (s + 1)} / 三角形 {s * s * 2}。既存アセットは GUID を維持して上書きします。";
        isValid = !string.IsNullOrEmpty(assetPath) && assetPath.StartsWith("Assets/") && assetPath.EndsWith(".asset");
    }

    public static Mesh Generate(string path, int segments, float size, float boundsUp, float boundsLateral)
    {
        segments = Mathf.Clamp(segments, 1, 255); // 256^2 = 65536 は UInt16 の上限を超える
        int   n    = segments + 1;
        float step = size / segments;
        float half = size * 0.5f;

        var verts = new Vector3[n * n];
        var norms = new Vector3[n * n];
        var tans  = new Vector4[n * n];
        var uvs   = new Vector2[n * n];
        for (int j = 0; j < n; j++)
        {
            for (int i = 0; i < n; i++)
            {
                int k = j * n + i;
                verts[k] = new Vector3(i * step - half, 0f, j * step - half);
                norms[k] = Vector3.up;
                // 接線 = +X（u 方向）。Unity の従法線は cross(N, T) * w なので、
                // v 方向（+Z）にするには w = -1（標準 Quad と同じ規約）
                tans[k]  = new Vector4(1f, 0f, 0f, -1f);
                uvs[k]   = new Vector2((float)i / segments, (float)j / segments);
            }
        }

        // 表面が +Y を向く巻き順（Unity は左手系・時計回りが表）
        var tris = new int[segments * segments * 6];
        int t = 0;
        for (int j = 0; j < segments; j++)
        {
            for (int i = 0; i < segments; i++)
            {
                int a = j * n + i;      // (x0, z0)
                int b = a + 1;          // (x1, z0)
                int c = a + n;          // (x0, z1)
                int d = c + 1;          // (x1, z1)
                tris[t++] = a; tris[t++] = c; tris[t++] = b;
                tris[t++] = c; tris[t++] = d; tris[t++] = b;
            }
        }

        Mesh mesh   = AssetDatabase.LoadAssetAtPath<Mesh>(path);
        bool exists = mesh != null;
        if (exists) { mesh.Clear(); }
        else        { mesh = new Mesh(); }

        mesh.name        = Path.GetFileNameWithoutExtension(path);
        mesh.indexFormat = UnityEngine.Rendering.IndexFormat.UInt16;
        mesh.vertices    = verts;
        mesh.normals     = norms;
        mesh.tangents    = tans;
        mesh.uv          = uvs;
        mesh.triangles   = tris;
        // RecalculateBounds は呼ばない（変位分を見込んだ拡張バウンズを手で設定する）
        mesh.bounds = new Bounds(Vector3.zero,
            new Vector3(size + 2f * boundsLateral, 2f * boundsUp, size + 2f * boundsLateral));

        if (exists)
        {
            EditorUtility.SetDirty(mesh);
        }
        else
        {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !AssetDatabase.IsValidFolder(dir))
            {
                Directory.CreateDirectory(Path.GetFullPath(dir));
                AssetDatabase.Refresh();
            }
            AssetDatabase.CreateAsset(mesh, path);
        }
        AssetDatabase.SaveAssets();
        Debug.Log($"[WebPlaneMeshGenerator] {(exists ? "updated" : "created")} {path}: " +
                  $"verts={mesh.vertexCount} tris={tris.Length / 3} bounds={mesh.bounds.size}");
        return mesh;
    }
}

using System;
using System.IO;
using Mecaota.SpiderShader.SilkNet;
using UnityEditor;
using UnityEngine;

// =============================================================================
// SpiderSilkNetBaker — 糸の網（mecaota/SpiderSilkNet）の絵柄を焼く Editor の入口（エディタ専用）。
//
//  ・絵柄を作る本体は SilkNetPatternCore.cs（Unity に依存しない C#）。Unity の外の .NET ツールでも
//    同じファイルで焼けるので、同じ種なら同じ画素の PNG になる。
//  ・既存の焼き込み（SpiderGooSheetBaker、蜘蛛の巣ドレープ用・データ版 3）とは別のクラス。
//    版 4 は配列の .asset を作らず、1 枚 512 角を縦に並べた PNG を書き、取り込み設定の「2D Array」で配列にする
//    （容量が小さく、焼き直しのたびにリポジトリが膨らみにくい。Android の上書き設定もそのまま使える）。
//  ・焼き直すとリポジトリの履歴が増えるので、焼き直すのは版を上げるときだけにする。
//    使った種と設定は同じフォルダの JSON に残る。
// =============================================================================
public static class SpiderSilkNetBaker
{
    public const string ShaderName = "mecaota/SpiderSilkNet";
    public const string CageBaseName = "SilkNet_Cage";
    public const string WebBaseName = "SilkNet_Web";
    public const string DrapeBaseName = "SilkNet_Drape";

    /// <summary>パッケージの中の絵柄のフォルダ（Assets/ または Packages/ からのパス）。シェーダーの場所から求める。</summary>
    public static string PatternFolder()
    {
        var shader = Shader.Find(ShaderName);
        string path = shader != null ? AssetDatabase.GetAssetPath(shader) : null;
        if (string.IsNullOrEmpty(path)) return null;
        // .../Runtime/SpiderSilkNet.shader → .../Runtime/SilkNet/Patterns
        return Path.GetDirectoryName(path).Replace('\\', '/') + "/SilkNet/Patterns";
    }

    [MenuItem("Tools/SpiderShader/糸の網/絵柄を焼き直す（籠目・張り巣・ドレープ用の板）")]
    static void MenuBake()
    {
        string folder = PatternFolder();
        if (folder == null) { EditorUtility.DisplayDialog("糸の網の絵柄", "mecaota/SpiderSilkNet が見つかりません。", "OK"); return; }
        if (!EditorUtility.DisplayDialog("糸の網の絵柄",
                "籠目（種 " + string.Join(", ", NetBake.DefaultCageSeeds) + "）と張り巣（種 " + string.Join(", ", NetBake.DefaultWebSeeds) + "）とドレープ用の板（種 " + string.Join(", ", NetBake.DefaultDrapeSeeds) + "）を焼き直し、\n" +
                folder + " の PNG と JSON を上書きします。\n\n焼き直しはパッケージの版を上げるときだけにしてください（リポジトリの履歴が増えます）。",
                "焼き直す", "やめる"))
            return;
        Bake(folder);
    }

    public static void Bake(string folder)
    {
        // Packages/ のパスは実体の場所と違うことがある（PackageCache やプロジェクトの外のローカルのパッケージ）
        string full = FileUtil.GetPhysicalPath(folder);
        try
        {
            EditorUtility.DisplayProgressBar("糸の網の絵柄", "籠目を焼いています", 0.2f);
            NetBake.BakeSet(NetKind.Cage, NetBake.DefaultCageSeeds, full, CageBaseName, "Unity Editor (SpiderSilkNetBaker)");
            EditorUtility.DisplayProgressBar("糸の網の絵柄", "張り巣を焼いています", 0.6f);
            NetBake.BakeSet(NetKind.Web, NetBake.DefaultWebSeeds, full, WebBaseName, "Unity Editor (SpiderSilkNetBaker)");
            EditorUtility.DisplayProgressBar("糸の網の絵柄", "ドレープ用の板を焼いています", 0.85f);
            NetBake.BakeSet(NetKind.Drape, NetBake.DefaultDrapeSeeds, full, DrapeBaseName, "Unity Editor (SpiderSilkNetBaker)");
        }
        finally { EditorUtility.ClearProgressBar(); }
        foreach (string baseName in new[] { CageBaseName, WebBaseName, DrapeBaseName })
        {
            foreach (string suffix in new[] { "_Shape.png", "_Detail.png", "_Coverage.png", ".json" })
                AssetDatabase.ImportAsset(folder + "/" + baseName + suffix, ImportAssetOptions.ForceUpdate);
        }
        Debug.Log("[糸の網] 絵柄を焼き直しました: " + folder);
    }
}

// -----------------------------------------------------------------------------
// 絵柄の PNG の取り込み設定（2D Array・リニア・ミップあり・PC は BC5 / BC7 / R8）。
// 名前が SilkNet_ で始まり、フォルダが .../SilkNet/Patterns/ の PNG にだけ効く。
// .meta にも同じ値を書いてあるが、焼き直しや手で設定を崩したときに、取り込みのたびにこの値へ戻す。
// -----------------------------------------------------------------------------
public class SpiderSilkNetPatternImporter : AssetPostprocessor
{
    void OnPreprocessTexture()
    {
        string path = assetPath.Replace('\\', '/');
        if (!path.Contains("/SilkNet/Patterns/") || !Path.GetFileName(path).StartsWith("SilkNet_", StringComparison.Ordinal)) return;
        if (!path.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) return;
        var ti = (TextureImporter)assetImporter;
        int rows = ReadRows(path);
        bool cage = path.Contains("_Cage_");
        bool shape = path.EndsWith("_Shape.png", StringComparison.Ordinal);
        bool detail = path.EndsWith("_Detail.png", StringComparison.Ordinal);

        ti.textureType = TextureImporterType.Default;
        ti.textureShape = TextureImporterShape.Texture2DArray;
        // 1 枚 512 角を縦に並べた画像。上から 0, 1, 2 枚目
        // 枚数が読めないときは行の数に触らず、.meta の値を残す
        if (rows > 0)
        {
            var settings = new TextureImporterSettings();
            ti.ReadTextureSettings(settings);
            settings.flipbookColumns = 1;
            settings.flipbookRows = rows;
            ti.SetTextureSettings(settings);
        }
        ti.sRGBTexture = false;
        ti.alphaSource = detail ? TextureImporterAlphaSource.FromInput : TextureImporterAlphaSource.None;
        ti.mipmapEnabled = true;
        ti.mipmapFilter = TextureImporterMipFilter.BoxFilter;   // 被覆率の面積がミップで保たれる
        ti.npotScale = TextureImporterNPOTScale.None;           // 縦に並べた全体は 2 のべき乗でない
        ti.wrapMode = cage ? TextureWrapMode.Repeat : TextureWrapMode.Clamp;
        ti.filterMode = FilterMode.Trilinear;
        ti.anisoLevel = 8;   // 斜めから見た籠の左右の端で、糸が平均されて消えないように
        ti.maxTextureSize = 2048;
        ti.isReadable = false;

        var pc = ti.GetPlatformTextureSettings("Standalone");
        pc.overridden = true;
        pc.maxTextureSize = 2048;
        pc.format = shape ? TextureImporterFormat.BC5 : detail ? TextureImporterFormat.BC7 : TextureImporterFormat.R8;
        pc.textureCompression = TextureImporterCompression.CompressedHQ;
        ti.SetPlatformTextureSettings(pc);
    }

    // PNG の IHDR から縦横を読み、縦に並んだ枚数を返す。読めなければ -1
    static int ReadRows(string assetPathValue)
    {
        try
        {
            var b = new byte[24];
            int read;
            using (var fs = File.OpenRead(FileUtil.GetPhysicalPath(assetPathValue))) read = fs.Read(b, 0, 24);
            if (read < 24) return -1;
            int w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
            int h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
            return (w > 0 && h > 0 && h % w == 0) ? h / w : -1;
        }
        catch (Exception) { return -1; }
    }
}

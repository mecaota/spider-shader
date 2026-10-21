#if !COMPILER_UDONSHARP
// このファイルは C# の null 許容の注釈（nullable）を使わない書き方をしている。利用側のプロジェクトが
// 追加のコンパイラ引数（csc.rsp の -nullable:enable など）で注釈を有効にしても警告が出ないよう、明示的に無効にする。
#nullable disable
// =============================================================================
// SpiderWebBakeBackup.cs — 巣を lilToon に焼き込む前の「元の設定」の控え（データだけのコンポーネント）
//
//  ・Tools/SpiderShader/SpiderWeb を lilToon に焼き込む… で焼いたとき、焼いたレンダラーに自動で付く。
//  ・持つのは「元の値」だけ:
//      - 元のマテリアル（参照）と、その全部の値の写し（元のアセットが消えても作り直せるように）
//      - 焼き込みで変えたレンダラーの設定（影など）
//      - 焼き込みの設定・作ったアセットの場所・同意した注意事項
//    インスペクター（Editor/SpiderWebBakeBackupEditor.cs）の「元に戻す」で、焼く前の状態に戻せる。
//
//  ■ Play モードとビルドに影響しないしくみ
//    1. Unity のメッセージ関数（Awake / Start / Update / OnValidate / Reset など）を 1 つも持たない。
//       このクラスにはメソッドが無いので、Play 中も何もしない（値を持っているだけ）。
//    2. VRC.SDKBase.IEditorOnly を付けてある（VRChat SDK の「エディター専用」の印）。
//    3. ワールドのビルドでは Editor/SpiderWebBakeBuildStrip.cs がシーンから取り除く
//       （Play に入るときは何もしない）。焼き込みのときに HideFlags.DontSaveInBuild も付ける。
//    4. UdonSharp のコンパイルからは見えないようにしてある（#if !COMPILER_UDONSHARP。Udon では使わない）。
//
//  ★ ここにはメソッドを書かないこと（処理はすべて Editor 側の SpiderWebLilToonBaker.cs）。
// =============================================================================
using System;
using UnityEngine;

[DisallowMultipleComponent]
[AddComponentMenu("")]   // 「Add Component」の一覧には出さない（焼き込みのときだけ自動で付く）
public sealed class SpiderWebBakeBackup : MonoBehaviour, VRC.SDKBase.IEditorOnly
{
    [Tooltip("この控えの書式の版（読み取り側の互換用）")]
    public int dataVersion = 1;
    [Tooltip("焼いたツールの版（SpiderWebLilToonBaker.ToolVersion）")]
    public string toolVersion = "";
    [Tooltip("焼いた日時（ローカル時刻）")]
    public string bakedAt = "";

    [Tooltip("焼く前の sharedMaterials（全スロット）")]
    public Material[] originalMaterials = new Material[0];
    [Tooltip("焼いたあとの sharedMaterials（全スロット）")]
    public Material[] bakedMaterials = new Material[0];
    [Tooltip("差し替えたスロットの、元のマテリアルの全部の値の写し")]
    public SpiderWebMaterialSnapshot[] snapshots = new SpiderWebMaterialSnapshot[0];
    [Tooltip("焼く前のレンダラーの設定")]
    public SpiderWebRendererSnapshot rendererSettings = new SpiderWebRendererSnapshot();
    [Tooltip("焼いたとき prefab のインスタンスだったか")]
    public bool wasPrefabInstance;
    [Tooltip("焼く前から prefab の上書きになっていたレンダラーの値（元に戻すとき、これ以外の上書きは prefab の値へ戻す）")]
    public string[] prefabOverriddenPaths = new string[0];

    [Tooltip("焼き込みの設定と結果")]
    public SpiderWebBakeRecord bake = new SpiderWebBakeRecord();
    [Tooltip("焼き込みで作ったアセット（元に戻しても消さない。削除はユーザーが行う）")]
    public string[] createdAssets = new string[0];

    [Tooltip("同意した『重大』の項目")]
    public string[] acceptedCritical = new string[0];
    [Tooltip("同意した『注意』の項目")]
    public string[] acceptedCaution = new string[0];
    [Tooltip("同意した『参考』の項目")]
    public string[] acceptedInfo = new string[0];
    [Tooltip("同意したときの確認内容の指紋（SHA-256）")]
    public string consentHash = "";
}

// ---- 以下は控えの中身（値だけの入れ物。メソッドは持たない） ----

/// <summary>マテリアル 1 つぶんの、全部の値の写し。</summary>
[Serializable]
public sealed class SpiderWebMaterialSnapshot
{
    public int slot;                 // レンダラーのマテリアルのスロット番号
    public string name = "";
    public string assetPath = "";    // 焼いたときの場所（アセットでなければ空）
    public string assetGuid = "";
    public string shaderName = "";
    public string shaderGuid = "";
    public string parentPath = "";   // マテリアルバリアントの親（作り直すときは親を持たない普通のマテリアルになる）
    public string parentGuid = "";
    public int customRenderQueue = -1;   // -1 = シェーダーの値に従う
    public string[] keywords = new string[0];
    public bool enableInstancing;
    public bool doubleSidedGI;
    public int globalIlluminationFlags;
    public string[] tagKeys = new string[0];
    public string[] tagValues = new string[0];
    public string[] disabledPasses = new string[0];
    public SpiderWebSnapshotFloat[] floats = new SpiderWebSnapshotFloat[0];
    public SpiderWebSnapshotInt[] ints = new SpiderWebSnapshotInt[0];
    public SpiderWebSnapshotColor[] colors = new SpiderWebSnapshotColor[0];
    public SpiderWebSnapshotTexture[] textures = new SpiderWebSnapshotTexture[0];
}

[Serializable]
public sealed class SpiderWebSnapshotFloat
{
    public string name = "";
    public float value;
}

[Serializable]
public sealed class SpiderWebSnapshotInt
{
    public string name = "";
    public int value;
}

/// <summary>色は保存されている生の値（Material.GetColor は 1 ULP ずれることがあるため使わない）。</summary>
[Serializable]
public sealed class SpiderWebSnapshotColor
{
    public string name = "";
    public Color value;
}

[Serializable]
public sealed class SpiderWebSnapshotTexture
{
    public string name = "";
    public Texture texture;
    public string textureGuid = "";
    public Vector2 scale = Vector2.one;
    public Vector2 offset = Vector2.zero;
}

/// <summary>焼き込みで変えるレンダラーの設定（焼く前の値）。</summary>
[Serializable]
public sealed class SpiderWebRendererSnapshot
{
    public int shadowCastingMode;     // UnityEngine.Rendering.ShadowCastingMode
    public bool receiveShadows;
    public int sortingLayerID;
    public int sortingOrder;
    public int lightProbeUsage;       // UnityEngine.Rendering.LightProbeUsage
    public int reflectionProbeUsage;  // UnityEngine.Rendering.ReflectionProbeUsage
    public bool hadPropertyBlock;     // 焼いたとき MaterialPropertyBlock が付いていたか（値は焼けない）
}

/// <summary>焼き込みの設定と、スロットごとの結果。</summary>
[Serializable]
public sealed class SpiderWebBakeRecord
{
    public int resolution;
    public string mode = "";          // "Cutout" / "Transparent"
    public float cutoff;              // lilToon の _Cutoff（Cutout のとき）
    public float coverageThreshold;   // 被覆率を保つ不透明度のしきい値
    public string outputFolder = "";
    public SpiderWebBakedSlot[] slots = new SpiderWebBakedSlot[0];
}

[Serializable]
public sealed class SpiderWebBakedSlot
{
    public int slot;
    public int subMesh;
    public Vector4 uvRect;            // xy = 焼いた UV の最小、zw = 大きさ
    public int width;
    public int height;
    public float threadTexels;        // 糸 1 本の太さ（テクセル）の目安
    public string texturePath = "";
    public string materialPath = "";
    public float[] mipCoverage = new float[0];       // 取り込み（圧縮）後の各ミップ段の被覆率
    public float[] mipCoverageNaive = new float[0];  // 参考: 被覆率を保たない単純な平均のミップの被覆率
}
#endif

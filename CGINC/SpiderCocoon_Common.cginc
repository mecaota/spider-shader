#ifndef SPIDERCOCOON_COMMON_INCLUDED
#define SPIDERCOCOON_COMMON_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_Common.cginc
// 全 uniform 宣言・appdata/v2f 構造体・共通定数。
// UnityCG.cginc / Lighting.cginc は .shader 側で先に include しておくこと。
// ---------------------------------------------------------------------------

// レイヤーループのコンパイル時上限（_LayerCount のスライダー最大値と一致させる）。
// 固定上限にしておくとドライバが「無限ループでない」と保証でき移植性が高い。
#define SC_MAX_LAYERS 8
#define SC_HALF_PI    1.5707963267948966

// ---- 見た目（糸） ---------------------------------------------------------
float4 _ThreadColor;          // 糸の色（既定 #fff）。a は全体不透明度
float  _ThreadThickness;      // 1周期（隣の糸まで）に占める不透明帯の割合 0..1
float  _ThreadJitter;         // 糸ごとの太さ乱雑性 0..1
float  _ThreadFuzz;           // 糸長方向の太さうねり量 0..1
float  _ThreadFuzzScale;      // うねりの細かさ（周波数）

// ---- レイアウト（巻き） ---------------------------------------------------
float  _WindingCount;         // 円周方向に巻く本数 W。シーム維持のため内部で整数丸め
float  _ThreadDensity;        // 巻き数の倍率（_WindingCount に乗算してから丸め）
float  _FiberAngle;           // 基準の糸の角度（度）。0=軸に平行、±で傾く（連続値）

// ---- トゥーン -------------------------------------------------------------
float  _ToonSteps;            // 陰影の段階数 1..8
float  _ToonSmooth;           // 段差の柔らかさ
float4 _ShadowColor;          // 影部の着色
float  _AmbientBoost;         // 環境光の底上げ
float  _LightInfluence;       // シーン光の反映度（0=完全発光, 1=光に大きく依存）

// ---- シルエットのリムライト ----------------------------------------------
float4 _RimColor;             // リムライト色
float  _RimPower;             // リムの幅／鋭さ（大きいほど細い）
float  _RimStrength;          // リムの強さ
float  _RimFloor;             // リムの下限（>0で正面中央にも発光を乗せる）

// ---- 各糸ごとの陰影 -------------------------------------------------------
float  _FiberNormalStrength;  // 糸断面に沿った法線の曲げ量 0..1
float4 _RimShadowColor;       // 各ファイバーの縁の影色
float  _RimShadowStrength;    // 各ファイバーの縁影の濃さ

// ---- レイヤー（重ね描画） -------------------------------------------------
float  _LayerCount;           // レイヤー枚数 1..8（最背面=index0=オフセット0）
float  _LayerAngleStep;       // レイヤーごとの角度オフセット（度・連続値）
float  _LayerPosStepX;        // レイヤーごとの位置オフセット X（軸方向）
float  _LayerPosStepY;        // レイヤーごとの位置オフセット Y（円周方向）
float  _LayerThicknessFalloff;// 奥（index大）ほど糸を細くする量

// ---- ビルボード（継ぎ目を裏へ回す） --------------------------------------
float  _Billboard;            // 0/1。Y軸まわりに回して UV シームを常に裏へ
float  _BillboardSeamOffset;  // シーム位置の微調整（度）

// ---- 裏面の扱い / 視界ジャック（包まれ演出） ------------------------------
float  _HideBackFibers;       // 1=裏面の糸を描かない（奥の暗い糸の透けを防ぐ）
float  _VisionJackEnable;     // 0/1。カメラが繭の内側に入ったら包まれ演出を発火
float  _VisionJackRadius;     // 内側判定の半径（オブジェクト空間。軸からの距離がこれ未満で発火）
float  _VisionJackHeight;     // 内側判定の高さ（オブジェクト空間。|y| がこれ未満で発火）
float  _VisionJackInMirror;   // ミラー内でも発火するか 0/1
float  _JackRadius;           // 内壁（楕円体）の半径倍率（発火判定半径に乗算）
float  _JackStretch;          // 内壁が上下に閉じるまでの縦距離の倍率

float  _ZWrite;

// ---------------------------------------------------------------------------
struct appdata
{
    float4 vertex  : POSITION;
    float3 normal  : NORMAL;
    float4 tangent : TANGENT;   // 糸断面の法線を曲げる基準軸に使う
    float2 uv      : TEXCOORD0;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct v2f
{
    float4 pos          : SV_POSITION;
    float2 uv           : TEXCOORD0;
    float3 worldPos     : TEXCOORD1;
    float3 worldNormal  : TEXCOORD2;
    float4 worldTangent : TEXCOORD3; // xyz=tangent, w=ハンドネス符号
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

// VRChat ミラー検出（ミラーは投影行列に斜行成分が入る）
bool SC_IsInMirror()
{
    return unity_CameraProjection[2][0] != 0.0f || unity_CameraProjection[2][1] != 0.0f;
}

// VRの「中央（両目の中点）」カメラ位置。
// _WorldSpaceCameraPos はステレオ時に目ごとの位置へ差し替わるため、
// 内/外のような二値判定に使うと、境界付近で左目だけ発火するなど
// 左右の表示が食い違う。二値判定には必ずこちらを使う。
float3 SC_MonoCameraPos()
{
#if defined(USING_STEREO_MATRICES)
    return 0.5 * (unity_StereoWorldSpaceCameraPos[0].xyz + unity_StereoWorldSpaceCameraPos[1].xyz);
#else
    return _WorldSpaceCameraPos;
#endif
}

#endif // SPIDERCOCOON_COMMON_INCLUDED

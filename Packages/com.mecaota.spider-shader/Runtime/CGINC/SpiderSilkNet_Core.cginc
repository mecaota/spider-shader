// =============================================================================
//  SpiderSilkNet_Core.cginc — 糸の網（mecaota/SpiderSilkNet）の頂点・画素の処理（3 パス共通）
//
//  ■ 何をしているか（シェーダー入門向け）
//    不規則な網の形は Editor で距離の画像に焼いてある（Editor/SilkNet/SilkNetPatternCore.cs、データ版 4）。
//    実行時は画像を読んで、既存の粘液の陰影（SpiderGoo_Shading.cginc の STG_Goo*）で塗るだけ。
//    1. 絵柄の UV: 籠目（_NetKind 0）は _NetTiling 回並べ、_NetSeed で左右反転とずらし。
//                  張り巣（_NetKind 1）は板 1 枚で、_NetSeed で 90 度ごとの回転と反転。
//    2. 距離: 形の画像の R（糸だけ）と G（焼いた膜の量で閉じた形）の距離を、_NetFill で補間する。
//             焼いた量より多い分は G を外へずらす。そのあと太さの倍率（_NetWidth）で動かす。
//             （修正 2 回目。以前の「穴の太さ」の閾値は段々の場なので、膜のふちが階段になった）
//    3. 塗り: 平らな 2 色（明部と影部）。光の反対側の縁にだけ一定幅の陰の帯を付け、
//             ふちに陰より濃い細い輪郭線を引く（試作 v2 の濃さ。白い背景でも糸が読める）。
//             遠景（被覆率の表示）では輪郭線が細って消えるので、糸の色を輪郭線の色へ 35% 寄せる。
//    4b. 奥の壁の描き方: 膜は 0。元の半径が 3 画素未満の糸は丸ごと描かず、残す糸の半径は 4 画素まで。
//    4. 裏側: _BackMode で、裏向きの面（籠の奥の壁）を「表と同じ / 細い糸 / 描かない / 内側の籠用」にする。
//             カメラが籠の中（_NetCageExtent の箱の中）にいるときは、裏向きの面も表と同じに描く。
//    5. 距離: _NetSimpleDistance から 1 m かけて、糸の半径・ふちの向き・陰の帯を「補助の画像の値」から
//             「一定の値」へ滑らかに移し、その先は補助の画像を読まない（境目で太さや縁の細りが飛ばない）。
//             距離は両目の中間の位置から測る（VR で左右の目の境目がずれない）。
//             _BackHideDistance より遠いと、奥の壁の描き方の面を描かない。
//
//  ■ 3 パス（深度 → 裏向きの面 → 表向きの面）
//    両面を 1 パスで描くと、奥の糸が手前の膜の上に乗ることがある。そこで、
//    深度のパスで芯（不透明度 0.5 以上）だけ深度を書き、裏向きの面（Cull Front）を先に、
//    表向きの面（Cull Back）を後に塗る。描かない面は、色のパスでは頂点をつぶし、
//    深度のパスでは画素を捨てる（見えない糸の深度で、後から描く別の籠やドレープが欠けないように）。
//    頂点をつぶす経路も含め、全パスで SPS-I（シングルパス・インスタンシング）のマクロを通す。
//
//  ■ 体に沿わせる（キーワード _NET_DRAPE）
//    SpiderWeb / SpiderWebDrape と同じ SW_DrapeDeform（CGINC/SpiderWeb_Drape.cginc）で、
//    平面メッシュの頂点を体のカプセルへ動かす。配列（常に 20 要素）と値の契約も同じ。
// =============================================================================
#ifndef SPIDERSILKNET_CORE_INCLUDED
#define SPIDERSILKNET_CORE_INCLUDED

// これ以上の不透明度の芯だけが深度を書く（巣・ドレープと同じ境目）
#define SSN_DEPTH_SOLID_ALPHA 0.5
// 膜の量 1 のときの膜の半径（画素）。生成器の NetPatterns.FillMax と同じ
#define SSN_FILL_MAX 16.0
// 遠くで補助の画像を読まないときに使う糸の半径（画素）
#define SSN_SIMPLE_RADIUS 2.5
// 補助の画像の値から一定の値へ移る距離の幅 (m)
#define SSN_SIMPLE_BLEND 1.0

#include "UnityCG.cginc"
#include "Lighting.cginc"
#include "SpiderCocoon_Noise.cginc"
#include "SpiderCocoon_Common.cginc"
#include "SpiderCocoon_Thread.cginc"
#include "SpiderCocoon_Lighting.cginc"
#include "SpiderGoo_Shading.cginc"
#include "SpiderGooSheet_BakedPattern.cginc"
#include "SpiderWeb_Drape.cginc"

// ---- 糸の網の固有の値（質感 21 項目は SpiderSilk_Look.cginc） ----
float  _NetKind;            // 0 = 籠目（Repeat）, 1 = 張り巣（Clamp の板 1 枚）
float  _NetSlice;           // 使う枚。-1 なら _NetSeed から選ぶ
float  _NetSeed;            // ずらし・反転・回転の乱数 0..1（部品ごとに MPB で入れる）
float4 _NetTiling;          // xy = UV 1 あたりに絵柄を並べる回数（整数に丸める）
float  _NetWidth;           // 糸の太さの倍率
float  _NetFill;            // 膜の量 0..1
float  _NetMerge;           // 修正 2 回目から使わない（膜の形は焼いた距離で決まる）。マテリアルの互換のため残す
float  _NetEdgeFade;        // 板の縁で糸と膜を細らせる幅（UV。張り巣だけ。ノイズで縁をでこぼこにする）
float  _NetProfileShade;    // 糸の断面の陰（丸みと陰の帯）の強さ
float  _BackMode;           // 0 = 表と同じ, 1 = 細い糸, 2 = 描かない, 3 = 内側の籠用
float4 _NetCageExtent;      // 籠の半分の大きさ（物体の座標）。0 なら中か外かの判定をしない
float4 _BackTint;           // 奥の壁に掛ける色
float  _BackWidth;          // 奥の壁の糸の太さの倍率
float  _NetSimpleDistance;  // これより遠い画素は一色で塗る (m)
float  _BackHideDistance;   // これより遠いと奥の壁を描かない (m)
float  _FormShade;          // メッシュの丸みに沿った陰（2 色に区切る）

struct ssn_appdata
{
    float4 vertex  : POSITION;
    float3 normal  : NORMAL;
    float4 tangent : TANGENT;
    float2 uv      : TEXCOORD0;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct ssn_v2f
{
    float4 pos          : SV_POSITION;
    float2 uv           : TEXCOORD0;
    float3 worldPos     : TEXCOORD1;
    float3 worldNormal  : TEXCOORD2;
    float4 worldTangent : TEXCOORD3;
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

// パスの種類（頂点と画素の共通関数へ定数で渡す）
#define SSN_PASS_DEPTH 0
#define SSN_PASS_BACK  1
#define SSN_PASS_FRONT 2

// 面の描き方: 0 = 描かない, 1 = 表の描き方, 2 = 奥の壁の描き方
#define SSN_STYLE_NONE  0
#define SSN_STYLE_FRONT 1
#define SSN_STYLE_BACK  2

// カメラが籠の中にいるか。カメラの位置を物体の座標に直し、_NetCageExtent の箱の内側かで決める。
// 両目で同じ判定になるよう、目の中間の位置を使う（ミラーや撮影カメラは、そのカメラの位置で判定する）
bool SSN_CameraInside()
{
    float3 e = abs(_NetCageExtent.xyz);
    if (e.x < 1e-5 || e.y < 1e-5 || e.z < 1e-5) return false;
    float3 p = mul(unity_WorldToObject, float4(SC_MonoCameraPos(), 1.0)).xyz;
    return all(abs(p) < e);
}

// 物体の原点からカメラまでの距離（奥の壁を消す判定。物体全体で同じ値にして、面の一部だけ消えないようにする）
float SSN_ObjectDistance()
{
    float3 c = mul(unity_ObjectToWorld, float4(0.0, 0.0, 0.0, 1.0)).xyz;
    return distance(c, SC_MonoCameraPos());
}

int SSN_FaceStyle(bool frontFace)
{
    int mode = (int)round(_BackMode);
    bool inside = SSN_CameraInside();
    bool backFar = SSN_ObjectDistance() > _BackHideDistance;
    if (mode == 3)
    {
        // 内側の籠用: 外から見たとき、面を裏返した内側の籠の「こちらを向いた面」= 奥の壁だけを描く。
        // カメラが籠の中なら描かない（外の籠が表と同じに描く）
        if (inside || !frontFace || backFar) return SSN_STYLE_NONE;
        return SSN_STYLE_BACK;
    }
    if (frontFace || inside || mode == 0) return SSN_STYLE_FRONT;
    if (mode == 2) return SSN_STYLE_NONE;
    return backFar ? SSN_STYLE_NONE : SSN_STYLE_BACK;
}

float SSN_Hash(float n) { return frac(sin(n * 12.9898 + 4.1414) * 43758.5453); }

// 絵柄の UV と、元の UV → 絵柄の UV の向きの行列（ふちの向きを元の UV へ戻すのに使う）
float2 SSN_PatternUV(float2 uv, out float2x2 A)
{
    float seed = _NetSeed * 97.31;
    if (_NetKind < 0.5)
    {
        // 籠目: 整数回並べ、左右反転とずらしだけ（継ぎ目が出ないよう回転はしない）
        float2 tiling = max(round(_NetTiling.xy), float2(1.0, 1.0));
        float flip = SSN_Hash(seed + 1.7) < 0.5 ? -1.0 : 1.0;
        float2 shift = float2(SSN_Hash(seed + 3.1), SSN_Hash(seed + 5.9));
        A = float2x2(flip * tiling.x, 0.0, 0.0, tiling.y);
        return float2(uv.x * tiling.x * flip, uv.y * tiling.y) + shift;
    }
    // 張り巣: 板の中心で 90 度ごとに回し、ときどき左右反転する
    int rot = (int)floor(SSN_Hash(seed + 7.3) * 4.0) & 3;
    float flipW = SSN_Hash(seed + 11.1) < 0.5 ? -1.0 : 1.0;
    float2 c = uv - 0.5;
    c.x *= flipW;
    float2x2 R = (rot == 0) ? float2x2(1, 0, 0, 1) : (rot == 1) ? float2x2(0, -1, 1, 0) : (rot == 2) ? float2x2(-1, 0, 0, -1) : float2x2(0, 1, -1, 0);
    A = mul(R, float2x2(flipW, 0.0, 0.0, 1.0));
    return mul(R, c) + 0.5;
}

float SSN_SliceIndex()
{
    float count = max(_NetSliceCount, 1.0);
    if (_NetSlice < -0.5) return min(floor(SSN_Hash(_NetSeed * 97.31 + 13.7) * count), count - 1.0);
    return clamp(round(_NetSlice), 0.0, count - 1.0);
}

// 糸と膜を合わせた距離（画素）。dThread = 糸だけ、dClosed = 焼いた膜の量で閉じた形、r = 糸の半径、fill = 膜の量 0..1。
// 膜の量が焼いた量以下なら 2 つの距離を補間し、多い分は閉じた形を外へずらす（1 あたり半径 8 画素）。どちらも本物の距離なので
// 線形補間しても膜のふちは滑らか
float SSN_NetDistance(float dThread, float dClosed, float r, float widthMul, float fill)
{
    float baked = max(_NetBakeRange.y, 1e-3);
    float d = (fill <= baked) ? lerp(dThread, dClosed, fill / baked)
                              : dClosed - (fill - baked) * SSN_FILL_MAX * 0.5;
    float grow = min((widthMul - 1.0) * r, 0.75 * _NetBakeRange.x);
    return d - grow;
}

// 奥の壁の描き方の距離: 膜は 0。糸の中心線からの距離（= 半径 + 糸だけの距離）から、細くした半幅（4 画素まで）を引く
float SSN_BackDistance(float dThread, float r, float widthMul)
{
    float half = min(r * widthMul, 4.0);
    return (r + dThread) - half;
}

// 板の縁で糸と膜を細らせる量（画素）。縁を少しでこぼこにするため、縁からの距離にノイズを足す
float SSN_EdgeFade(float2 puv)
{
    if (_NetKind < 0.5 || _NetEdgeFade <= 1e-4) return 0.0;
    float e = min(min(puv.x, puv.y), min(1.0 - puv.x, 1.0 - puv.y));
    // 縁に沿った位置（周の長さ）でノイズを取る
    float along = (abs(puv.x - 0.5) > abs(puv.y - 0.5)) ? puv.y : puv.x;
    float wob = STG_ValueNoise2(float2(along * 23.0, _NetSeed * 17.0 + (puv.x + puv.y) * 3.0)) - 0.5;
    float t = 1.0 - saturate((e + wob * _NetEdgeFade * 0.6) / _NetEdgeFade);
    // 縁では 20 画素ぶん外へ押す（太い膜も消える）
    return t * t * 20.0;
}

// ---------------------------------------------------------------------------
// 頂点
// ---------------------------------------------------------------------------
ssn_v2f SSN_Vert(ssn_appdata v, int passKind)
{
    ssn_v2f o;
    UNITY_SETUP_INSTANCE_ID(v);
    UNITY_INITIALIZE_OUTPUT(ssn_v2f, o);
    UNITY_TRANSFER_INSTANCE_ID(v, o);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

    bool drawn;
    if (passKind == SSN_PASS_BACK)       drawn = SSN_FaceStyle(false) != SSN_STYLE_NONE;
    else if (passKind == SSN_PASS_FRONT) drawn = SSN_FaceStyle(true) != SSN_STYLE_NONE;
    else                                 drawn = (SSN_FaceStyle(true) != SSN_STYLE_NONE) || (SSN_FaceStyle(false) != SSN_STYLE_NONE);

    UNITY_BRANCH
    if (!drawn)
    {
        // 全頂点を同じ有効なクリップ座標へ（三角形の面積が 0 になり、画素が生まれない）
        o.pos = float4(0.0, 0.0, 0.0, 1.0);
    }
    else
    {
        float3 wp = mul(unity_ObjectToWorld, v.vertex).xyz;
        float3 N0 = UnityObjectToWorldNormal(v.normal);
        float3 T0 = UnityObjectToWorldDir(v.tangent.xyz);
        o.uv = v.uv;
        o.pos = UnityObjectToClipPos(v.vertex);
        o.worldPos = wp;
        o.worldNormal = N0;
        o.worldTangent = float4(T0, v.tangent.w);
    #if defined(_NET_DRAPE)
        // 体に沿わせる網（位置・法線・接線をワールドで直接求める）
        UNITY_BRANCH
        if (SW_DrapeActive())
        {
            float3 pDr, NDr, TDr;
            SW_DrapeDeform(v.uv, pDr, NDr, TDr);
            o.pos = UnityWorldToClipPos(pDr);
            o.worldPos = pDr;
            o.worldNormal = NDr;
            o.worldTangent = float4(TDr, v.tangent.w);
        }
    #endif
    }
    // 分岐の途中では返さず、初期化済みの出力をここから 1 回だけ返す
    return o;
}

// ---------------------------------------------------------------------------
// 画素（色と深度で共通）
// ---------------------------------------------------------------------------
fixed4 SSN_Frag(ssn_v2f i, float facing, int passKind, out float depthAlpha)
{
    depthAlpha = 0.0;
    UNITY_SETUP_INSTANCE_ID(i);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

    // 隣の画素との差を使う処理（微分）は、discard の前にすべて済ませる
    float stretchFade = 1.0;
#if defined(_NET_DRAPE)
    stretchFade = SW_DrapeStretchFade(i.worldPos, i.uv);
#endif
    float2x2 A;
    float2 puv = SSN_PatternUV(i.uv, A);
    SGS_NetShape sh = SGS_ReadShapeSlice(puv, SSN_SliceIndex());

    bool frontFace = facing > 0.0;
    int style = SSN_FaceStyle(frontFace);
    if (style == SSN_STYLE_NONE) discard;
    if (_NetSliceCount < 0.5) discard;   // 絵柄の配列が未設定（インスペクタに理由を表示）

    bool isWeb = _NetKind > 0.5;
    if (isWeb) clip(min(min(puv.x, puv.y), min(1.0 - puv.x, 1.0 - puv.y)));

    bool backStyle = style == SSN_STYLE_BACK;
    // 奥の壁の描き方: 膜なしの細い糸（太さ _BackWidth 倍、半幅 4 画素まで）
    float widthMul = max(_NetWidth, 0.0) * (backStyle ? _BackWidth : 1.0);
    float fill = backStyle ? 0.0 : saturate(_NetFill);
    float aa = max(sh.texelPerPixel * 0.6, 1e-3);
    float edgeFade = SSN_EdgeFade(puv);

    // 早い棄却: 太さの倍率で最大限ふくらませても届かない穴の画素は、補助の画像を読む前に捨てる
    float growMax = max(widthMul - 1.0, 0.0) * _NetBakeRange.z;
    float dBound = min(sh.d, (fill > 0.0) ? sh.dClosed - max(fill - _NetBakeRange.y, 0.0) * SSN_FILL_MAX * 0.5 : 1e4) - growMax + edgeFade;
    if (dBound > aa + 0.5 && sh.coverage <= 0.0) discard;

    // 一色で塗る側への移り具合 0..1（両目の中間から測る。境目は 1 m かけて滑らかに移す）。
    // 奥の壁の描き方は糸の半径で糸を選ぶので、常に補助の画像を読む（奥の壁は _BackHideDistance で消える）
    float simpleT = backStyle ? 0.0 : saturate((distance(i.worldPos, SC_MonoCameraPos()) - _NetSimpleDistance) / SSN_SIMPLE_BLEND);
    bool simple = simpleT >= 1.0;
    float r = SSN_SIMPLE_RADIUS;
    float2 dirUV = float2(0.0, 0.0);
    float strandRandom = 0.5;
    UNITY_BRANCH
    if (!simple)
    {
        SGS_NetDetail det = SGS_ReadNetDetail(sh);
        r = lerp(det.radius, SSN_SIMPLE_RADIUS, simpleT);
        // ふちの向きを絵柄の UV から元の UV へ戻す（勾配は転置で戻す）。遠くへ移るほど面の向きへ寄せる
        dirUV = mul(transpose(A), det.direction);
        dirUV = (dot(dirUV, dirUV) > 1e-8) ? normalize(dirUV) * (1.0 - simpleT) : float2(0.0, 0.0);
        strandRandom = det.strandRandom;
    }

    // 奥の壁: 元の半径が 3 画素未満の糸は丸ごと描かない（細くしてちぎれた短い線を残さない）
    if (backStyle && r < 3.0) discard;
    float d = backStyle ? SSN_BackDistance(sh.d, r, widthMul) : SSN_NetDistance(sh.d, sh.dClosed, r, widthMul, fill);
    // 張り巣: 板の縁で糸と膜を細らせる（四角い枠や、まっすぐな切り口に見せない）
    d += edgeFade;

    // 遠景: 糸の直径が画面の 4 画素 → 1 画素の間で、面積（被覆率）の表示へ移る
    float farWeight = (_NetDataVersion > 2.5) ? smoothstep(0.25, 1.0, sh.texelPerPixel / max(2.0 * r * widthMul, 1e-3)) : 0.0;
    float nearMask = 1.0 - smoothstep(-aa, aa, d);
    float visible = lerp(nearMask, sh.coverage * saturate(widthMul), farWeight);
    if (visible <= 0.0) discard;

    // ---- 陰影 ----
    float3 Nface = normalize(i.worldNormal);
    float3 N = Nface * (frontFace ? 1.0 : -1.0);
    float3 T = normalize(i.worldTangent.xyz);
    float3 B = normalize(cross(Nface, T)) * i.worldTangent.w * unity_WorldTransformParams.w;
    float3 V = normalize(_WorldSpaceCameraPos - i.worldPos);
    float3 L = STG_GooLightDir();

    float3 outW = T * dirUV.x + B * dirUV.y;
    outW = (dot(outW, outW) > 1e-8) ? normalize(outW) * length(dirUV) : float3(0.0, 0.0, 0.0);
    STG_GooSurface s = STG_GooProfileW(d, max(r * widthMul, 0.5), outW, N);
    // ふちの向きが無い（遠景・一色で塗る側）と、輪郭で N×0 + 0 を正規化して NaN になり、リムが全面に出る。面の向きにする
    s.Nt = (dot(outW, outW) > 1e-8) ? s.Nt : N;
    s.Nt = normalize(lerp(N, s.Nt, saturate(_NetProfileShade)));

    // 平らな 2 色: 明部と影部を、既存の塗り（シーン光の反映を含む）で 1 回ずつ求める
    STG_GooSurface sLit = s; sLit.Nt = L;
    STG_GooSurface sShade = s; sShade.Nt = -L;
    float3 litCol = STG_GooBaseColor(sLit, N, L);
    float3 shadeCol = STG_GooBaseColor(sShade, N, L);
    // メッシュの丸みに沿った陰（既定 0 = 使わない）
    float formToon = SC_ToonRamp(dot(N, L) * 0.5 + 0.5 - _GooShade, _ToonSteps, _ToonSmooth);
    float3 col = lerp(shadeCol, litCol, lerp(1.0, formToon, saturate(_FormShade)));

    // 陰の帯: 光の反対側の縁にだけ、一定幅（糸の太さの 3 割、最大 4 画素）の帯を置く。
    // 光の向きへずらした所ではなく、光と反対へずらした所の距離を読み、そこが穴なら帯（くし状の刻みが出ない）。
    // 細い糸（半径 2 画素未満）には付けない
    UNITY_BRANCH
    if (!simple && !backStyle && _NetProfileShade > 0.0 && r * widthMul >= 2.0)
    {
        float2 lightUV = float2(dot(L, T), dot(L, B));
        float2 lightP = mul(A, lightUV);
        float ll = length(lightP);
        if (ll > 0.05)
        {
            float bandW = min(0.6 * r * widthMul, 4.0);
            float2 off = -lightP / ll * bandW / max(_NetBakeRange.w, 1.0);
            float2 o2 = SGS_ReadNetShapeAt(sh, off);
            // ずらした所の距離（膜を含む）を、画面 1 画素の幅で滑らかに切る（穴か穴でないかの二択にしない）
            float dOff = SSN_NetDistance(o2.x, o2.y, r, widthMul, fill) + edgeFade;
            float halfPx = 0.5 * sh.texelPerPixel;
            float band = smoothstep(-halfPx, halfPx, dOff) * saturate(ll * 2.0) * (1.0 - simpleT);
            col = lerp(col, shadeCol, band * saturate(_NetProfileShade));
        }
    }
    if (backStyle) col *= _BackTint.rgb;

    // リム・透け・AA は既存の仕上げ（ツヤの筋と q 基準の輪郭線は使わない: detail = 0）
    float aaQ = aa / max(r * widthMul, 0.5);
    fixed4 c = STG_GooFinishAAWet(col, 0.0, s, d, N, V, L, strandRandom, 0.0, aa, aaQ, _GooAmount);

    // 輪郭線: ふちから画面 1.25 画素ぶんの濃い細い線（陰より濃い _GooOutlineColor）。奥の壁には引かない
    if (!backStyle)
    {
        float olW = 1.25 * sh.texelPerPixel + 0.3;
        float ol = (1.0 - smoothstep(olW - aa, olW + aa, -d)) * step(1e-4, _GooOutline) * (1.0 - farWeight);
        c.rgb = lerp(c.rgb, _GooOutlineColor.rgb, ol * _GooOutlineColor.a);
        c.a = lerp(c.a, max(c.a, _GooOutlineColor.a * _GooOpacity * nearMask), ol);
    }

    // 遠景では輪郭線が細って消え、白い糸が白地に溶けるので、糸の色を輪郭線の色へ 35% 寄せる
    c.rgb = lerp(c.rgb, _GooOutlineColor.rgb, 0.35 * farWeight * (backStyle ? 0.0 : 1.0));
    // 遠景は面積 × 平均の不透明度（丸い断面の厚みの幅平均は π/4）
    float farAlpha = sh.coverage * saturate(widthMul) * _GooOpacity * (1.0 - _GooClarity * _GooAmount * 0.78539816);
    c.a = lerp(c.a, farAlpha, farWeight);
    c.a *= stretchFade;
    depthAlpha = c.a * (1.0 - farWeight);
    if (c.a <= 0.001) discard;
    return c;
}

// ---- パスの入口 ----
ssn_v2f vertDepth(ssn_appdata v) { return SSN_Vert(v, SSN_PASS_DEPTH); }
ssn_v2f vertBack(ssn_appdata v)  { return SSN_Vert(v, SSN_PASS_BACK); }
ssn_v2f vertFront(ssn_appdata v) { return SSN_Vert(v, SSN_PASS_FRONT); }

fixed4 fragDepth(ssn_v2f i, fixed facing : VFACE) : SV_Target
{
    float depthAlpha;
    SSN_Frag(i, facing, SSN_PASS_DEPTH, depthAlpha);
    clip(depthAlpha - SSN_DEPTH_SOLID_ALPHA);
    return 0;
}
fixed4 fragBack(ssn_v2f i, fixed facing : VFACE) : SV_Target
{
    float depthAlpha;
    return SSN_Frag(i, facing, SSN_PASS_BACK, depthAlpha);
}
fixed4 fragFront(ssn_v2f i, fixed facing : VFACE) : SV_Target
{
    float depthAlpha;
    return SSN_Frag(i, facing, SSN_PASS_FRONT, depthAlpha);
}

#endif // SPIDERSILKNET_CORE_INCLUDED

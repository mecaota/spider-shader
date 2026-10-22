// =============================================================================
// SpiderWeb_Core.cginc — 蜘蛛の巣（mecaota/SpiderWeb）の頂点・フラグメントの処理
//
//  2026-10-14: SpiderWeb.shader の CGINCLUDE の中身を、そのままここへ移した。
//    巣のシェーダー（Runtime/SpiderWeb.shader）と、巣の模様を lilToon 用のテクスチャへ焼き込む
//    Editor 専用シェーダー（Editor/Shaders/SpiderWebBaker.shader。SW_BAKE を定義して include する）が
//    同じ式を使うため。移す前と後で、巣の描画が画素一致することを確認済み。
//
//  ■ 使い方
//    巣のシェーダー: CGINCLUDE の中で #include "CGINC/SpiderWeb_Core.cginc" するだけ。
//    焼き込み     : #define SW_BAKE 1 と SW_BAKE_LIGHT_DIR を書いてから include する。fragCore の中の
//                   #if defined(SW_BAKE) の 1 か所だけが、視線と光の向きを置き換える。
//
//  ★ 巣の模様（縦糸・横糸・粘液）の説明は SpiderWeb.shader の冒頭にある。
//  ★ ここを変えると巣と焼き込みの両方が変わる。焼いた巣（lilToon）には自動では反映されない
//    （焼き直しが必要）。
// =============================================================================
#ifndef SPIDERWEB_CORE_INCLUDED
#define SPIDERWEB_CORE_INCLUDED

// これ以上の不透明度のピクセルだけが深度を書く（AreaWebMarker の 0.35 などの
// 淡い巣は深度を書かない）
#define SW_DEPTH_SOLID_ALPHA 0.5


#include "UnityCG.cginc"
#include "Lighting.cginc"

// 糸の質感・照明は繭シェーダーと共通の実装を使う。
// Common.cginc が共通 uniform（_ThreadColor 等）と appdata/v2f を宣言
// するため、このシェーダーでは巣固有の uniform だけを追加宣言する。
#include "SpiderCocoon_Noise.cginc"
#include "SpiderCocoon_Common.cginc"
#include "SpiderCocoon_Thread.cginc"
#include "SpiderCocoon_Lighting.cginc"
// 粘液の塗り（蜘蛛糸・繭と共通）
#include "SpiderGoo_Shading.cginc"
#include "SpiderSilk_Motion.cginc"

// ---- 巣固有の uniform（共通 uniform は Common.cginc 宣言を使用） ----
float  _HubOffsetX;
float  _HubOffsetY;
float  _WebRadius;
float  _Thickness;
float  _RadialCount;
float  _RingCount;
float  _Sag;
float  _SpokeExtend;
float  _Irregular;
float  _Seed;
float _FanEnable, _FanAngle, _FanRotation, _FanMeshRim;
float _SpokeWidth, _RingWidth, _Organic, _JunctionSize;
// 粘液の形。_GooThick / _GooBeads / _GooBeadFreq / _GooWebFill / _GooWebScale は
// 蜘蛛糸・繭と同名なので SpiderCocoon_Common.cginc で宣言済み（巣では UV 単位）。
// 粘液感・色・陰影・光沢の uniform は質感 = SpiderSilk_Look.cginc
float _SpokeGoo, _RingGoo;

// ---- 接触追従の変形（uniform と変位関数は繭と共通の Pull.cginc） ----
#include "SpiderCocoon_Pull.cginc"
// ---- 投げつけた網が体に覆いかぶさる変形 ----
#include "SpiderWeb_Drape.cginc"
#if defined(SW_REVEAL)
float _RevealNear, _RevealFar, _RevealNoise, _RevealNoiseScale;
float4 _ClipLine;

float SW_RevealFade(float3 wp, float2 uv)
{
    float3 cam = SC_MonoCameraPos();
    float n = (STG_ValueNoise2(wp.xy * _RevealNoiseScale) + STG_ValueNoise2(wp.zy * _RevealNoiseScale + 17.3)) * 0.5;
    float d = distance(wp, cam) + (n - 0.5) * 2.0 * _RevealNoise;
    float reveal = 1.0 - smoothstep(_RevealNear, max(_RevealFar, _RevealNear + 0.01), d);
    float clipY = lerp(_ClipLine.x, _ClipLine.y, saturate(uv.x));
    float bottom = saturate((wp.y - clipY) / 0.25);
    return reveal * bottom;
}
#endif

// 共通の appdata に UV2 を足したもの。UV2.x は扇形の外周までの距離
//（_FanMeshRim 用。WebPlane など UV2 の無いメッシュでは使わない）
struct web_appdata
{
    float4 vertex  : POSITION;
    float3 normal  : NORMAL;
    float4 tangent : TANGENT;
    float2 uv      : TEXCOORD0;
    float2 uv2     : TEXCOORD1;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct web_v2f
{
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
    float3 worldPos : TEXCOORD1;
    float3 worldNormal : TEXCOORD2;
    float4 worldTangent : TEXCOORD3;
    float fanRim : TEXCOORD4;   // ハブ→扇の外周の UV 距離（メッシュ提供時のみ）
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

// 縦糸番号を 0..N-1 に折り返す（フロア剰余）。
// 角度は atan2 で -180°..+180° として得られ、±180° の継ぎ目で
// 番号が N ずれる。折り返しておくと継ぎ目の両側で同じ乱数になり、
// 継ぎ目に縦の裂け目が出ない。
float wrapId(float k, float n)
{
    return k - n * floor(k / n);
}

// 縦糸 k の角度ジッター（セクター単位・最大 ±0.2）。
// _Seed はハッシュ入力への加算で注入（旧実装とビット等価）。
// saturate はスクリプト等から Range 外の値が入ってもセル判定の
// 前提（|ジッター|<=0.2）を守るための保険。
float spokeJitter(float k, float n)
{
    if (_FanEnable > 0.5 && (k < 0.5 || k > n - 1.5)) return 0.0;
    return SC_Hash11Signed(wrapId(k, n) + _Seed * 37.219) * 0.2 * saturate(_Irregular);
}

// 角度 aVal（セクター単位）を挟む2本の縦糸（ジッター後の実位置）を求める。
// ジッターで縦糸が動いた結果 aVal が区間外に出ていたら隣のセルへ
// 1段ずらす（ジッター最大±0.2なので1段で必ず収まる）。
// これで「セルの切り替わり位置＝実際の縦糸の位置」となり、
// 垂れ・揺らぎがセル境界でジャンプしない（断裂バグ修正の核心）。
void spokeCell(float aVal, float n, out float k0, out float a0, out float a1)
{
    if (_FanEnable > 0.5) aVal = clamp(aVal, 0.0, n - 1.0001);
    k0 = floor(aVal);
    a0 = k0 + spokeJitter(k0, n);
    a1 = (k0 + 1.0) + spokeJitter(k0 + 1.0, n);
    if (aVal < a0)
    {
        a1 = a0; k0 -= 1.0; a0 = k0 + spokeJitter(k0, n);
    }
    else if (aVal >= a1)
    {
        a0 = a1; k0 += 1.0; a1 = (k0 + 1.0) + spokeJitter(k0 + 1.0, n);
    }
}

float webThreadWidth(float id, float seed, float along)
{
    float legacy = SC_ThreadWidthMul(id, seed, along);
    // 指数の倍率は常に正。強い太さの揺らぎでも糸を途切れさせない。
    float jitter = SC_Hash11Signed(id + seed);
    float fuzz = SC_ValueNoise1(along * _ThreadFuzzScale + (id + seed) * 7.0) * 2.0 - 1.0;
    float organic = exp2(saturate(_ThreadJitter) * jitter
                       + saturate(_ThreadFuzz) * 0.75 * fuzz);
    return lerp(legacy, organic, saturate(_Organic));
}

web_v2f vert(web_appdata v)
{
    web_v2f o;
    UNITY_SETUP_INSTANCE_ID(v);
    UNITY_INITIALIZE_OUTPUT(web_v2f, o);
    UNITY_TRANSFER_INSTANCE_ID(v, o);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

    float3 wp = mul(unity_ObjectToWorld, v.vertex).xyz;
    float3 N0 = UnityObjectToWorldNormal(v.normal);
    float3 T0 = UnityObjectToWorldDir(v.tangent.xyz);
    o.uv = v.uv;
    o.fanRim = (_FanMeshRim > 0.5) ? v.uv2.x : 0.0;

    // 体に覆いかぶさる網（位置・法線・接線をワールドで直接求める）
    UNITY_BRANCH
    if (SW_DrapeActive())
    {
        float3 pDr, NDr, TDr;
        SW_DrapeDeform(v.uv, pDr, NDr, TDr);
        o.pos          = UnityWorldToClipPos(pDr);
        o.worldPos     = pDr;
        o.worldNormal  = NDr;
        o.worldTangent = float4(TDr, v.tangent.w);
        return o;
    }

    // 変形が無効（またはどのスロットも未使用）なら従来どおりのパススルー
    UNITY_BRANCH
    if (!SC_PullActive())
    {
        o.pos          = UnityObjectToClipPos(v.vertex);
        o.worldPos     = wp;
        o.worldNormal  = N0;
        o.worldTangent = float4(T0, v.tangent.w);
        return o;
    }

    // ---- 接触追従の変形（ワールド空間。法線・接線は変位後の面から再計算） ----
    float3 pD = wp, N = N0, Tn = T0;
    SC_PullDeform(pD, N, Tn);

    o.pos          = UnityWorldToClipPos(pD);
    o.worldPos     = pD;
    o.worldNormal  = N;
    o.worldTangent = float4(Tn, v.tangent.w);
    return o;
}

// depthOnly: 深度だけのパス（DEPTHSOLID）から呼ぶとき true（定数で渡すので分岐は消える）
fixed4 fragCore(web_v2f i, fixed facing, bool depthOnly)
{
    UNITY_SETUP_INSTANCE_ID(i);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

    // 隣り合う画素の差を使うので、discard で画素を捨てる前に伸び率を調べる。
    float drapeStretchFade = SW_DrapeStretchFade(i.worldPos, i.uv);
    #if defined(SW_REVEAL)
    float revealFade = SW_RevealFade(i.worldPos, i.uv);
    #endif

    // ★ 早い棄却（2026-10-14 軽量化。結果は最後の判定と同じ）
    //   最後の不透明度は「糸の不透明度 × 伸び率のフェード × 近接表示のフェード」。
    //   糸の不透明度には上限がある（STG_GooAlphaCeiling）ので、上限にフェードを掛けた値が
    //   最後の判定（色: 0.001 以下で捨てる / 深度: SW_DEPTH_SOLID_ALPHA 未満で捨てる）に
    //   届かない画素は、重い糸の計算の前に捨てる。近接表示で完全に消える遠くの画素がここで終わる。
    //   掛ける順番も最後の計算（goo.a *= 伸び率; goo.a *= 近接表示）と同じにしてある。
    float alphaCeiling = STG_GooAlphaCeiling(0.0) * drapeStretchFade;
    #if defined(SW_REVEAL)
    alphaCeiling *= revealFade;
    #endif
    if (alphaCeiling <= 0.001) discard;
    if (depthOnly && alphaCeiling < SW_DEPTH_SOLID_ALPHA) discard;

    // 裏面（カメラに背を向けた面）を描かないオプション。
    // スフィア等の立体では奥側の糸が透けて見えるのを防げる
    if (_HideBackFibers > 0.5 && facing < 0.0) discard;

    // 本数は必ず整数に丸める。非整数だと ±180° の継ぎ目で乱数が
    // 食い違い、縦の裂け目が出る（スクリプトやアニメーションから
    // 非整数が入っても壊れないための保険）。
    float N  = max(3.0, round(_RadialCount));
    float NR = max(1.0, round(_RingCount));

    // 縦糸・ハブの座標は動かさず、下の横糸の半径だけを動かす。
    float2 uvW = i.uv;
    float edgeD = 0.5 - max(abs(i.uv.x - 0.5), abs(i.uv.y - 0.5));
    float edgePin = (_SwayAnimAnchor > 1e-4)
        ? smoothstep(0.0, max(_SwayAnimAnchor, 1e-4), edgeD) : 1.0;
    float ringMotion = (_SwayAnimEnable > 0.5 ? 1.0 : 0.0) * edgePin;

    // ============ ハブ（中心結節点）の偏心幾何 ============
    // 外周円（UV中央・半径 _WebRadius）は固定のまま、糸が
    // 集まるハブだけを _HubOffset（半径に対する比）でずらす。
    float2 hubOfs = float2(_HubOffsetX, _HubOffsetY);
    float  hubLen = length(hubOfs);
    hubOfs *= (hubLen > 0.9) ? 0.9 / hubLen : 1.0;  // 斜め入力でも外周円の内側に制限
    float2 h = hubOfs * _WebRadius;                 // ハブ変位（UV空間）
    // ハブは必ずメッシュの内側に留める（縦糸終端の射影が壊れない保険）
    float hLen = length(h);
    h *= (hLen > 0.45) ? 0.45 / hLen : 1.0;
    bool fan = _FanEnable > 0.5;
    // 扇形では -1/+1 がメッシュ端。円形モードの偏心幾何はそのまま。
    if (fan) h = clamp(float2(_HubOffsetX, _HubOffsetY), -0.999, 0.999) * 0.5;

    float2 p   = (uvW - 0.5) - h;                   // ハブ基準の座標（巣はUV中央）
    float  r   = length(p);
    float2 u   = (r > 1e-5) ? p / r : float2(1.0, 0.0);
    float2 radialDir = u;                           // ハブ→外向き

    // ハブから方向 u に伸ばした半直線が外周円に届くまでの距離 Redge。
    // 「|ハブ + 距離×u - 外周円中心| = 半径」の2次方程式の正の解で、
    // ハブが円の内側にある限り必ず正の実数になる。
    float uh    = dot(u, h);
    float Redge = -uh + sqrt(max(uh * uh + _WebRadius * _WebRadius - dot(h, h), 1e-6));
    // ハブから方向 u に伸ばした半直線がメッシュ端（UV 正方形の縁）に届くまでの距離
    float tqx = (abs(u.x) > 1e-6) ? ((u.x > 0.0 ? 0.5 : -0.5) - h.x) / u.x : 1e6;
    float tqy = (abs(u.y) > 1e-6) ? ((u.y > 0.0 ? 0.5 : -0.5) - h.y) / u.y : 1e6;
    if (fan)
    {
        // 扇形: 横糸は外周まで並べる。外周はメッシュが UV2 で渡す距離
        //（木の幹に張り付く巣＝地面との接地線）、無ければ UV 正方形の端。
        // 巣の半径はそれより内側で止めたいときの上限。最外周の横糸が
        // メッシュ端で半分に切れないよう、糸の太さぶん内側に置く
        float rimDist  = (i.fanRim > 1e-4) ? i.fanRim : min(tqx, tqy);
        float rimInset = _Thickness * max(_RingWidth, 0.05)
                       * lerp(1.0, _GooThick, saturate(_GooAmount) * saturate(_RingGoo));
        Redge = max(min(_WebRadius, rimDist - rimInset), 0.001);
    }
    // 正規化半径: ハブで0、外周円上で1。リングはこの空間に等間隔で
    // 並べるので、ハブが偏ると片側が密・反対側が疎になる（実巣と同じ）。
    float rho = r / Redge;

    // ============ 縦糸: 1本の直線・終端はメッシュ端に固定 ============
    // 縦糸 k は「ハブ → メッシュ端の固定終端 E_k」を結ぶ1本の直線。
    // E_k は UV 中央からセクター角 φ_k の方向へ伸ばした線がメッシュ端
    //（UV 正方形の縁）に当たる点で、ハブに依存しない。
    // → ハブを動かしても縦糸の終端は動かず、直線のまま終端を支点に
    //   傾くだけ。延長 OFF は外周円から外側を透明にするだけで、
    //   糸の形そのものは変わらない。
    //
    // セル判定は「ピクセルをハブからの視線でメッシュ端に射影した点の
    // 中心角」で行う。縦糸上のピクセルは必ず自分の終端 E_k に射影
    // される（中心角=φ_k）ため、垂れ・揺らぎの区間切替は厳密に
    // 縦糸の上で起こり、横糸が空中で切れることはない。
    float2 Q  = h + min(tqx, tqy) * u;              // メッシュ端への射影点
    float ang = atan2(Q.y, Q.x);                    // 射影点の中心角
    float fanRotation = radians(_FanRotation);
    float fanHalf = radians(clamp(_FanAngle, 15.0, 330.0)) * 0.5;
    // 扇の中の角度（扇の向きを 0 とした -180°..+180°）。扇のときだけ計算する
    // （扇かどうかはマテリアルで決まるので、全画素が同じ側へ分かれる。2026-10-14 軽量化）
    float fanTheta = 0.0;
    [branch] if (fan)
    {
        float pAng = atan2(p.y, p.x) - fanRotation;
        fanTheta = atan2(sin(pAng), cos(pAng));
        // 扇形の揺れの固定: UV 正方形の縁ではなく、外周と両端の縦糸からの距離で固定する
        float fanEdgeD = min((1.0 - rho) * Redge, (fanHalf - abs(fanTheta)) * r);
        float fanPin = (_SwayAnimAnchor > 1e-4)
            ? smoothstep(0.0, max(_SwayAnimAnchor, 1e-4), fanEdgeD) : 1.0;
        ringMotion = (_SwayAnimEnable > 0.5 ? 1.0 : 0.0) * fanPin;
    }

    // ---- ジッター後の実位置でセル（区間）を確定 ----
    float sector = UNITY_TWO_PI / N;                // 1区間の角度
    float a = ang / sector;                         // 射影中心角（セクター単位）
    if (fan)
    {
        sector = (2.0 * fanHalf) / (N - 1.0);
        a = (fanTheta + fanHalf) / sector;
        ang = fanTheta;
    }
    float k0, a0, a1;
    spokeCell(a, N, k0, a0, a1);
    float segId = wrapId(k0, N);                    // この区間のID

    // ---- 縦糸の距離場 ----
    // 隣り合う2本それぞれの固定終端 E（UV 中央から角度 φ の方向へ
    // 伸ばした線がメッシュ端に当たる点。max 成分での正規化が
    // 「原点から正方形の縁まで」の閉形式になる）
    float angleOffset = fan ? fanRotation - fanHalf : 0.0;
    float2 e0 = float2(cos(a0 * sector + angleOffset), sin(a0 * sector + angleOffset));
    float2 e1 = float2(cos(a1 * sector + angleOffset), sin(a1 * sector + angleOffset));
    float2 E0 = e0 * (0.5 / max(abs(e0.x), abs(e0.y)));
    float2 E1 = e1 * (0.5 / max(abs(e1.x), abs(e1.y)));
    // 走行方向: ハブ（原点）→ 固定終端。ハブ移動で変わるのはここだけ
    float2 dirA = normalize(E0 - h);
    float2 dirB = normalize(E1 - h);
    if (fan) { dirA = e0; dirB = e1; }

    // ---- 縦糸間での正規化位置 t（垂れ下がりの基準） ----
    // 射影角 a ではなく「ハブから見た実際の角度」で取る。射影角だと
    // メッシュのかどを通る向きで角度の進み方が急変し、垂れた横糸の
    // 弧に折れ目が出るため（ハブ偏心時のみ現れる）。
    // 縦糸上では視線方向が dirA/dirB と一致して t=0/1 になるので、
    // 「sagCurve は縦糸上で厳密に0」の保証はそのまま維持される。
    float thA = atan2(dirA.y, dirA.x);
    float dAB = atan2(dirB.y, dirB.x) - thA;
    dAB += (dAB <= 0.0) ? UNITY_TWO_PI : 0.0;       // 0..2π に巻き戻し
    float dA  = atan2(u.y, u.x) - thA;
    dA  += (dA < 0.0) ? UNITY_TWO_PI : 0.0;
    float t        = saturate(dA / max(dAB, 1e-4));
    float sagCurve = SSM_PinEnvelope(t);            // 縦糸上0・中間1
    // 符号付き垂直距離（2Dの外積＝直線までの厳密距離）。
    // ハブより後ろ側（糸が無い側）ではハブまでの距離 r に切り替える
    //（dot=0 の境界では |外積|=r なので連続につながる）
    float sd0 = dirA.x * p.y - dirA.y * p.x;
    float sd1 = dirB.x * p.y - dirB.y * p.x;
    float dist0 = (dot(p, dirA) >= 0.0) ? abs(sd0) : r;
    float dist1 = (dot(p, dirB) >= 0.0) ? abs(sd1) : r;
    bool  nearLeft    = dist0 < dist1;
    float spokeK      = nearLeft ? k0 : (k0 + 1.0);  // 採用した縦糸の番号
    float spokeSigned = nearLeft ? sd0 : sd1;
    float spokeDist   = nearLeft ? dist0 : dist1;
    // 糸の横断方向（法線曲げ用）: 走行方向に対して垂直
    float2 spokeDir  = nearLeft ? dirA : dirB;
    float2 spokePerp = float2(-spokeDir.y, spokeDir.x);

    // 縦糸の太さ: 糸ごとの個体差＋長さ方向のうねり（繭と共通の式）。
    // 位置ジッターと同じ乱数にならないよう +57 で系列をずらす。
    // 糸に沿った座標は r（ハブからの距離）。
    float hwS = max(_Thickness * webThreadWidth(wrapId(spokeK, N), _Seed * 37.219 + 57.0, r), 1e-4);
    float silkS = SC_ValueNoise1(r * 17.0 + wrapId(spokeK, N) * 19.7 + _Seed);
    hwS *= max(_SpokeWidth, 0.05) * lerp(1.0, 0.45 + 1.25 * silkS, _Organic);

    // ============ 横糸: rho 空間に等間隔配置 → 垂れ＋揺らぎ ============
    // saturate は Range 外の値がスクリプト等から入っても
    // 除算や区間判定が壊れないための保険
    float sag = saturate(_Sag);
    float irr = saturate(_Irregular);
    float sp       = 1.0 / NR;                       // リング間隔（rho空間）
    // A tensioned arc between spokes, not a nearly circular ring.
    // Scale the static bow with angular span and radius, shared by
    // every ring so nested arcs preserve their order. Endpoints stay fixed.
    float bow = 4.0 * t * (1.0 - t);
    float spanVariation = lerp(1.0, 0.8 + 0.4 *
        SC_Hash11(segId * 311.7 + _Seed * 37.219), irr);
    float warpBase = 1.0 + min(sag * 2.5 * sin(min(dAB, UNITY_PI) * 0.5)
                               * spanVariation, 0.65) * bow;
    float kc       = round(rho * warpBase / sp);     // 最寄りリングの推定番号

    // 前後1本ずつ（kc-1 .. kc+1）の候補から最寄りを厳密に選ぶ（2026-10-14 Phase 3 で ±2 から ±1 に）。
    // ±1 で取りこぼさない理由: 横糸 k の位置（kc と同じ「間隔 1」の目盛り）のずれは、下の揺らぎ
    //   rj（0.2 + 0.12）・垂れの揺らぎ vs（0.04）・揺れ ringShift（0.06）を全部足しても間隔の 0.42 倍まで。
    //   この画素は kc から 0.5 以内なので、kc の横糸は 0.92 以内、kc±2 の横糸は 1.08 以上離れていて、
    //   kc±2 が最寄りになることはない（横糸どうしの順番も入れ替わらない: 隣との差は 0.16 以上）。
    //   ★ 揺らぎ・垂れ・揺れの係数を上げて合計が 0.5 を超えるなら ±2 に戻すこと。
    // 外周より外（kc = NR+2）だけは ±1 だと最外周 NR が候補から外れるので、kc を NR+1 に寄せて
    //   ±2 のときと同じく NR を見つける（kc ≥ NR+3 は ±2 のときも候補が無かった）。
    float kcS = (kc > NR + 1.5 && kc < NR + 2.5) ? NR + 1.0 : kc;
    float ringSigned = 1e6;
    float ringK      = 0.0;
    [unroll]
    for (int m = -1; m <= 1; m++)
    {
        float k = kcS + (float)m;
        if (k > 0.5 && k < NR + 0.5)
        {
            // 最外周（k==NR）だけは乱数揺らぎを0にして、外周円に
            // 沿った予測しやすい形に保つ（垂れ自体は残る）
            float gateOut = (k < NR - 0.5) ? 1.0 : 0.0;
            // リングごとの半径の揺らぎ
            float rj = SC_Hash11Signed(k * 7.31 + 113.7 + _Seed * 37.219)
                     * 0.2 * sp * irr * gateOut;
            // Both adjacent cells use the same value at each spoke.
            // Uneven attachment heights break concentric regularity
            // without leaving detached endpoints at a cell boundary.
            float j0 = SC_Hash11Signed(k * 73.1 + wrapId(k0, N) * 191.7 + _Seed);
            float j1 = SC_Hash11Signed(k * 73.1 + wrapId(k0 + 1.0, N) * 191.7 + _Seed);
            rj += lerp(j0, j1, smoothstep(0.0, 1.0, t)) * 0.12 * sp * irr * gateOut;
            // 区間（リング×縦糸間）ごとの垂れ幅の揺らぎ。
            // sagCurve 倍なので縦糸上では必ず0＝区間が替わる瞬間も
            // リング半径は連続で、糸は縦糸の上で繋がったまま
            float vs = SC_Hash11Signed(k * 127.1 + segId * 311.7 + _Seed * 37.219)
                     * 0.04 * sp * irr * sagCurve * gateOut / warpBase;
            float rhoK = max((k * sp + rj) / warpBase - vs, 1e-4);
            // Limit to 6% ring spacing: keep ordering and the +/-1 candidate search valid (see above).
            // Spoke junctions remain exactly fixed (sagCurve=0).
            float amplitude = min(max(_SwayAnimAmount, 0.0),
                                  0.06 * sp * Redge / max(warpBase, 1e-3));
            float phase = SC_Hash11(k * 127.1 + segId * 311.7 + _Seed) * UNITY_TWO_PI;
            float ringShift = amplitude * sagCurve * ringMotion
                // Move the whole arc gently; spatial waves along t
                // made otherwise dry capture silk look serrated.
                * SSM_ElasticWave(0.0, _SwayAnimWaves, _Time.y * _SwayAnimSpeed, phase);
            rhoK += ringShift / max(Redge, 1e-4);
            float ds   = (rho - rhoK) * Redge;       // UV空間の実距離に換算
            if (abs(ds) < abs(ringSigned)) { ringSigned = ds; ringK = k; }
        }
    }
    float ringDist = abs(ringSigned);

    // 横糸の太さ乱雑性。糸に沿った座標は角度だが、±180°の継ぎ目で
    // 値が飛ばないよう折り返して連続化する（繭デカールと同じ手法）
    float foldAng = abs(frac(ang / UNITY_TWO_PI + 0.5) - 0.5) * 2.0;
    float hwR = max(_Thickness * webThreadWidth(ringK, _Seed * 37.219 + 157.0, foldAng), 1e-4);
    // UV位置を使うことで角度の継ぎ目でも太さが連続する。
    float silkR = SC_ValueNoise1(dot(uvW, float2(19.1, 27.7)) + ringK * 13.3 + _Seed);
    hwR *= max(_RingWidth, 0.05) * lerp(1.0, 0.4 + 1.3 * silkR, _Organic);

    // ============ 粘液の糸（塗りは SpiderGoo_Shading.cginc と共通） ============
    // 粘液感（_GooAmount）で太り・玉・膜をまとめて弱める（1 で各設定値そのまま）
    float amt = saturate(_GooAmount);
    // 縦糸の粘液（_SpokeGoo）: 1 で横糸と同じ粘液、0 で乾いた細い糸
    float spokeG = saturate(_SpokeGoo);
    float ringG = saturate(_RingGoo);
    // 1) 太さ: 粘液の太さ倍率 × 粘着玉。実物の巣でも横糸（捕獲糸）には
    //    糊の玉が数珠状に並ぶので、玉は横糸に強く・縦糸には控えめに付ける。
    float alongS = r;                                   // 縦糸に沿った座標
    float alongR = foldAng * UNITY_PI * r;              // 横糸に沿った座標（継ぎ目で折り返して連続）
    float bAmt   = saturate(_GooBeads) * amt;
    float thick  = lerp(1.0, _GooThick, amt);
    float beadS  = smoothstep(0.35, 0.9, SC_ValueNoise1(alongS * _GooBeadFreq
                              + wrapId(spokeK, N) * 7.13 + _Seed * 3.1));
    float beadR  = smoothstep(0.35, 0.9, SC_ValueNoise1(alongR * _GooBeadFreq
                              + ringK * 5.71 + _Seed * 3.1 + 17.0));
    hwS = lerp(max(_Thickness * max(_SpokeWidth, 0.05), 1e-4), hwS, spokeG);
    hwR = lerp(max(_Thickness * max(_RingWidth, 0.05), 1e-4), hwR, ringG);
    float gS = hwS * lerp(1.0, thick, spokeG) * lerp(1.0, 1.0 + 0.8 * bAmt, beadS * 0.5 * spokeG);
    float gR = hwR * lerp(1.0, thick, ringG) * lerp(1.0, lerp(1.0 - 0.2 * bAmt, 1.0 + 1.6 * bAmt, beadR), ringG);

    // 2) 糸ごとの距離場（負=粘液の中）。縦糸は延長 OFF なら外周円で止める
    float overG = (rho - 1.0) * Redge;
    float dS    = spokeDist - gS;
    bool  capS  = (_SpokeExtend < 0.5) && (overG > dS);
    if (capS) dS = overG;
    float dR    = ringDist - gR;

    // ---- 塗りの向き（面の法線・接線・視線・光） ----
    float3 NfrontG = normalize(i.worldNormal);
    float3 NwG = NfrontG * sign(facing);
    float3 TG  = normalize(i.worldTangent.xyz);
    float3 BG  = normalize(cross(NfrontG, TG)) * i.worldTangent.w * unity_WorldTransformParams.w;
    float3 VG  = normalize(_WorldSpaceCameraPos - i.worldPos);
    float3 LG  = STG_GooLightDir();
#if defined(SW_BAKE)
    // ★ 焼き込み専用（Editor/Shaders/SpiderWebBaker.shader が SW_BAKE を定義して読み込む）。
    //   lilToon へ焼く色は「見る向きに依らない色」にしたいので、視線を「面を正面から見る」向きに、
    //   光を焼くときのシーンの太陽の向き（SW_BAKE_LIGHT_DIR。C# が渡す）に置き換える。
    //   面の向き・接線は巣と同じくメッシュから取る（焼き込み用の頂点シェーダーがワールドの向きにして渡す）。
    //   巣のシェーダー（SpiderWeb.shader）は SW_BAKE を定義しないので、ここは無いのと同じ。
    VG = NfrontG;
    LG = SW_BAKE_LIGHT_DIR;
#endif

    // A single continuous field for all four wet/dry combinations.
    // Only shading and strand width vary; junction connectivity does not.
    float cellR = sp * Redge / max(warpBase, 1e-3);    // 横糸の間隔（UV）
    float cellS = r * sector;                          // その半径での縦糸の間隔（弧長）
    float fillN = STG_ValueNoise2(uvW * _GooWebScale + _Seed * 1.37);
    float kGoo  = _Thickness * _JunctionSize * 2.5
                + _GooWebFill * amt * min(spokeG, ringG) * min(cellR, cellS) * lerp(0.2, 2.2, fillN * fillN);
    float hSR;                                         // 縦糸側の重み
    float dGoo  = STG_SMin(dS, dR, kGoo, hSR);

    // 輪郭の外向き（UV 平面内）: 縦糸は横断方向、横糸は放射方向。
    // 融合部分は同じ重みで混ぜる（断面の法線がなめらかにつながる）
    float2 gS2 = (dot(p, spokeDir) >= 0.0)
               ? spokePerp * ((spokeSigned >= 0.0) ? 1.0 : -1.0) : u;
    if (capS) gS2 = radialDir;
    float2 gR2 = radialDir * ((ringSigned >= 0.0) ? 1.0 : -1.0);
    float2 gG  = lerp(gR2, gS2, hSR);
    gG = (dot(gG, gG) > 1e-8) ? normalize(gG) : radialDir;
    float  rG  = lerp(gR, gS, hSR);

    if (fan)
    {
        float boundary = (abs(fanTheta) - fanHalf) * r;
        dGoo = max(dGoo, boundary - gS);
    }

    // 4) 塗り（丸い断面・トゥーン・ハイライト・輪郭線・透け）。
    //    濡れ具合（ツヤ・透け）は縦横それぞれの粘液感に合わせる。
    float spokeness = saturate((hSR - 0.35) / 0.6);
    float wet       = amt * lerp(ringG, spokeG, spokeness);
    STG_GooSurface gs = STG_GooProfile(dGoo, rG, gG, NwG, TG, BG);
    float3 colG = STG_GooBaseColor(gs, NwG, LG);
    // 数 px しかない細い糸では輪郭線・ハイライトを弱める（遠景のにじみ防止）
    float detail = saturate(1.6 - fwidth(gs.q) * 2.5);
    float glossN = SC_ValueNoise1(lerp(alongR, alongS, hSR) * _GooBeadFreq * 0.6 + 3.3);
    fixed4 goo = STG_GooFinishWet(colG, 0.0, gs, dGoo, NwG, VG, LG, glossN, detail, rG, wet);
    // 色・深度の両パスが使う最終不透明度を薄くし、伸びた所の深度も残さない。
    goo.a *= drapeStretchFade;
    #if defined(SW_REVEAL)
    goo.a *= revealFade;
    #endif
    if (goo.a <= 0.001) discard;
    return goo;
}

fixed4 frag(web_v2f i, fixed facing : VFACE) : SV_Target
{
    return fragCore(i, facing, false);
}

// Pass 0 用: 色は使わず、芯（不透明度が高い所）だけ残して深度を書かせる
// （戻り値の色は使わないので、色と光の計算はコンパイラが省く。不透明度の上限で先に捨てる分は fragCore）
fixed4 fragDepth(web_v2f i, fixed facing : VFACE) : SV_Target
{
    fixed4 c = fragCore(i, facing, true);
    clip(c.a - SW_DEPTH_SOLID_ALPHA);
    return 0;
}

#endif // SPIDERWEB_CORE_INCLUDED

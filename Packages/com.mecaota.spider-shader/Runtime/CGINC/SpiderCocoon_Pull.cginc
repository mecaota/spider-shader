// =============================================================================
//  SpiderCocoon_Pull.cginc — 接触追従の頂点変形（巣・繭 共通）
//
//  「巣や繭に手足が触れた場所がその手足に追従して伸びる／凹む」表現。
//  Udon（SurfaceContactDeformer）が MaterialPropertyBlock で渡す
//    _PullAnchors[i].xyz : 捕縛点（ワールド座標。触れた瞬間の面上の点）  .w=1 で有効
//    _PullTargets[i].xyz : 追従先（ワールド座標。そのボーンの現在位置）
//    _PullCount          : 有効スロット数（0 なら変形なし）
//  について、捕縛点から _PullRadius 以内の頂点を「捕縛点→追従先」のずれの方向へ
//  距離減衰つきで動かす。ずれの向きは問わないので、面から離れれば伸び、
//  面へ押し込めば凹む。半径の外は厳密に 0（メッシュ端＝係留は不動）。
//  スロットは最大 SC_PULL_MAX 本（複数プレイヤーの両足・両手・腰・頭など）。
//  影響圏が重なる所は重みの和で正規化し、二重に引かれて手足より先まで
//  持ち上がるのを防ぐ。法線・接線は変位後の面から有限差分で求め直す。
//
//  配列 uniform は ShaderLab の Properties に書けないため MPB 専用
//  （MaterialPropertyBlock.SetVectorArray）。Unity は最初に渡された配列長で
//  固定するので、Udon 側は常に SC_PULL_MAX 要素の配列を渡すこと。
//  変位はワールド空間で計算するため、バッチングで unity_ObjectToWorld が
//  単位行列になっても結果は変わらない。
//  細かい変形には細分化したメッシュが必要（Tools/SpiderShader/Generate WebPlane Mesh 等）。
// =============================================================================
#ifndef SPIDERCOCOON_PULL_INCLUDED
#define SPIDERCOCOON_PULL_INCLUDED

#define SC_PULL_MAX 16

float  _PullEnable;
float  _PullRadius;
float  _PullFalloff;
float  _PullStrength;
float  _PullMaxStretch;
float  _PullTearFade;
float  _PullCount;
float4 _PullAnchors[SC_PULL_MAX];
float4 _PullTargets[SC_PULL_MAX];

// 変形を評価する必要があるか（無効、またはスロットが 1 本も無ければ false）
bool SC_PullActive()
{
    return (_PullEnable > 0.5) && (_PullCount > 0.5);
}

// 1スロット分の変位。xyz = 重み付き変位、w = 重み。
// A.w はスロット有効フラグ（0 なら丸ごと無効）
float4 SC_PullTerm(float3 p, float4 A, float4 T)
{
    float3 delta = T.xyz - A.xyz;                       // 捕縛点 → 手足の現在位置
    float  t = 1.0 - smoothstep(0.0, _PullRadius, distance(p, A.xyz));
    float  w = (t > 0.0) ? _PullStrength * pow(t, _PullFalloff) : 0.0; // t=0 の pow を避ける
    if (_PullMaxStretch > 0.0)                          // 千切れ: 伸びすぎたら糸が戻る
        w *= saturate(1.0 - (length(delta) - _PullMaxStretch) / max(_PullTearFade, 1e-3));
    return float4(delta * w, w) * A.w;
}

// 全スロットの合成（重みの和で正規化）。_PullCount で打ち切る動的ループ
float3 SC_PullOffset(float3 p)
{
    float4 s = 0;
    int n = min((int)_PullCount, SC_PULL_MAX);
    [loop]
    for (int i = 0; i < n; i++)
    {
        s += SC_PullTerm(p, _PullAnchors[i], _PullTargets[i]);
    }
    return s.xyz / max(1.0, s.w);
}

// ワールド座標 wp・法線 N・接線 T を変位後の値に更新する。
// 法線は「変位後の面」の接線方向 2 本の外積。各方向は元の接線 T / 従法線 B に
// 沿って ±eps ずらした点を変位関数に通した中心差分（メッシュの粗さに依存しない）。
// B = cross(N,T) なら cross(T,B) == N なので、無変形時は元の法線と一致する。
void SC_PullDeform(inout float3 wp, inout float3 N, inout float3 T)
{
    float3 N0 = N, T0 = T;
    float3 B0  = cross(N0, T0);
    float  eps = max(0.01, _PullRadius * 0.05);
    float3 pD  = wp + SC_PullOffset(wp);
    float3 pTp = wp + T0 * eps, pTm = wp - T0 * eps;
    float3 pBp = wp + B0 * eps, pBm = wp - B0 * eps;
    float3 dT  = (pTp + SC_PullOffset(pTp)) - (pTm + SC_PullOffset(pTm));
    float3 dB  = (pBp + SC_PullOffset(pBp)) - (pBm + SC_PullOffset(pBm));
    float3 Nn  = cross(dT, dB);
    wp = pD;
    N  = (dot(Nn, Nn) > 1e-12) ? normalize(Nn) : N0;   // 退化時は元の法線
    T  = (dot(dT, dT) > 1e-12) ? normalize(dT) : T0;   // tangent 無しメッシュの保険
}

#endif // SPIDERCOCOON_PULL_INCLUDED

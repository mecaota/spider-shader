#ifndef SPIDERCOCOON_NOISE_INCLUDED
#define SPIDERCOCOON_NOISE_INCLUDED

// ---------------------------------------------------------------------------
// SpiderCocoon_Noise.cginc
// 糸ごとの個体差（太さの乱雑性）に使う安価な hash / value noise。
// テクスチャ不要・決定論的（同じ糸インデックスなら毎フレーム同じ値）。
// ※ spider-thread/SpiderThread_Noise.cginc を SC_ プレフィックスで複製。
// ---------------------------------------------------------------------------

// 1D hash -> [0,1)
float SC_Hash11(float p)
{
    p = frac(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

// -1..1 に展開した hash（揺らぎ用）
float SC_Hash11Signed(float p)
{
    return SC_Hash11(p) * 2.0 - 1.0;
}

// 1D value noise（太さの連続的なうねりに使用）
float SC_ValueNoise1(float x)
{
    float i = floor(x);
    float f = frac(x);
    float u = f * f * (3.0 - 2.0 * f);
    return lerp(SC_Hash11(i), SC_Hash11(i + 1.0), u);
}

#endif // SPIDERCOCOON_NOISE_INCLUDED

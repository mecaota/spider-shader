// 蜘蛛の巣ドレープ（粘液シート）の焼き込み画像を読む。
// 距離と被覆率を先に読み、全微分・LODを確定してから穴の画素を除外する。
// 残った画素だけ補助情報を明示LODで読む。色・深度でこの処理を共用する。
#ifndef SPIDER_GOO_SHEET_BAKED_PATTERN_INCLUDED
#define SPIDER_GOO_SHEET_BAKED_PATTERN_INCLUDED
UNITY_DECLARE_TEX2DARRAY(_BakedShape);
UNITY_DECLARE_TEX2DARRAY(_BakedDetail);
UNITY_DECLARE_TEX2DARRAY(_BakedCoverage);
float _BakedUVSpan, _BakedSliceCount;
float4 _BakedWetParams, _BakedTexelSize;
float4 _BakedDistanceRange; // xyz=スライスごとの距離範囲、w=データ版（3）
float4 _BakedRadiusRange;   // xyz=スライスごとの半径範囲、w=BC5符号化の有無

struct SGS_Shape
{
    float3 uvSlice;
    float lod;
    float d;
    float radius;
    float aaD;
    float aaQ;
    float coverage;
    float farWeight;
    float visibleMask;
};

// widthScale: 糸の太さの倍率（1 で焼いたまま）。層ごとに太さを変えるのに使う。
SGS_Shape SGS_ReadShape(float2 patternUV, float layer, float layers, float widthScale)
{
    SGS_Shape s;
    // 内側は密、外側は疎。層数変更では配列を焼き直さない。
    float count = clamp(round(layers), 1.0, 8.0);
    float slice = round(layer * max(_BakedSliceCount - 1.0, 0.0) / max(count - 1.0, 1.0));
    slice = clamp(slice, 0.0, max(_BakedSliceCount - 1.0, 0.0));
    float2 uv = (patternUV - 0.5) / max(_BakedUVSpan, 1e-4) + 0.5;
    s.uvSlice = float3(uv, slice);
    float2 dx = ddx(uv), dy = ddy(uv);
    float footprint = max(length(dx * _BakedTexelSize.zw), length(dy * _BakedTexelSize.zw));
    s.lod = clamp(log2(max(footprint, 1.0)), 0.0, log2(max(_BakedTexelSize.z, 1.0)));
    float2 shape = UNITY_SAMPLE_TEX2DARRAY_LOD(_BakedShape, s.uvSlice, s.lod).rg;
    if (_BakedRadiusRange.w > 0.5)
    {
        shape.x = (shape.x * 2.0 - 1.0) * _BakedDistanceRange[(int)slice];
        shape.y *= _BakedRadiusRange[(int)slice];
    }
    s.d = shape.x;
    s.radius = max(shape.y, 1e-4);
    // 太さの倍率：糸の芯までの距離（d + 半径）はそのままで、半径だけを倍率分にする
    // （距離場をふくらませる / 縮める）。倍率1なら grow = 0 で、焼いたままと同じ値になる。
    // 圧縮時は保存した距離の範囲を超えると縁が切れるので、ふくらむ量を範囲の3/4までにする。
    float growLimit = (_BakedRadiusRange.w > 0.5) ? 0.75 * _BakedDistanceRange[(int)slice] : 1e3;
    float grow = min((widthScale - 1.0) * s.radius, growLimit);
    s.d -= grow;
    s.radius = max(s.radius + grow, 1e-4);
    float q = saturate(1.0 + s.d / max(s.radius, 1e-4));
    s.aaD = min(fwidth(s.d) * 0.6, s.radius);
    s.aaQ = fwidth(q);
    float aa = s.aaD + 1e-5; // STG_GooFinishAAWetと同じAA判定
    float nearMask = 1.0 - smoothstep(-aa, aa, s.d);
    s.coverage = 0.0;
    s.farWeight = 0.0;
    if (_BakedDistanceRange.w > 2.5)
    {
        // 遠景の被覆率は糸の幅にほぼ比例するので、倍率をそのまま掛ける（倍率1なら焼いたまま）。
        s.coverage = saturate(UNITY_SAMPLE_TEX2DARRAY_LOD(_BakedCoverage, s.uvSlice, s.lod).r * max(widthScale, 0.0));
        float pixelUV = max(length(dx), length(dy)) * _BakedUVSpan;
        // 糸の直径が4px→1pxの間で面積による表示へ。距離の平均が正になっても糸を失わない。
        s.farWeight = smoothstep(0.25, 1.0, pixelUV / max(2.0 * s.radius, 1e-4));
    }
    // このマスクが0なら、後の塗り（光沢・輪郭を含む）が不透明度を作ることはない。
    // 遠景の被覆率を調べずに正距離だけで捨てると、細い糸を消すので両方を含める。
    s.visibleMask = lerp(nearMask, s.coverage, s.farWeight);
    return s;
}

struct SGS_Detail
{
    float2 direction;
    float wet;
    float glossNoise;
};
SGS_Detail SGS_ReadDetail(SGS_Shape shape)
{
    // discard後は暗黙の微分/LODを使わない。
    float4 value = UNITY_SAMPLE_TEX2DARRAY_LOD(_BakedDetail, shape.uvSlice, shape.lod);
    SGS_Detail result;
    result.direction = value.rg * 2.0 - 1.0;
    result.direction = (dot(result.direction, result.direction) > 1e-6) ? normalize(result.direction) : float2(1.0, 0.0);
    result.wet = _BakedWetParams.x * lerp(_BakedWetParams.z, _BakedWetParams.y, value.b);
    result.glossNoise = value.a;
    return result;
}
#endif

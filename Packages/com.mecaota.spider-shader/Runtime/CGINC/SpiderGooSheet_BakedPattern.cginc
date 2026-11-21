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
// ---- データ版 4: 糸の網（mecaota/SpiderSilkNet）用の読み取り ----
// 枚の番号を直接指定して読む。既存の SGS_ReadShape / SGS_ReadDetail（層の番号から枚を決める版 3）は変えない。
// 版 4 の画像（Editor/SilkNet/SilkNetPatternCore.cs が焼く。1 枚 512 角を縦に並べた PNG を 2D Array で取り込む）:
//   _BakedShape    rg = 糸だけの符号付き距離, 既定の膜の量で閉じた形（糸＋膜）の符号付き距離（どちらも 0.5 がふち、小さいほど内側）
//   _BakedDetail   rgba = ふちの外向き xy, 糸の半径, 糸ごとの乱数
//   _BakedCoverage r = 既定の膜の量での糸＋膜の面積（遠景用）
float4 _NetBakeRange;   // x = 距離の範囲（±画素）, y = G を焼いた膜の量（0..1）, z = 糸の半径の範囲（画素）, w = 1 枚の一辺の画素数
float  _NetDataVersion; // 4（2.5 より大きいときだけ遠景の被覆率を使う）
float  _NetSliceCount;  // 配列の枚数（0 なら未設定）

struct SGS_NetShape
{
    float3 uvSlice;       // 読んだ UV（折り返す前）と枚の番号
    float  lod;           // 明示したミップの段
    float  d;             // 糸だけの符号付き距離（画素。負が糸の内側）
    float  dClosed;       // 既定の膜の量で閉じた形の符号付き距離（画素）
    float  texelPerPixel; // 画面 1 画素あたりの絵柄の画素数（AA の幅と遠景の判定に使う）
    float  coverage;      // 遠景の被覆率（版 4 未満は 0）
};

// patternUV: 折り返す前の UV。籠目（Repeat）は 0..1 を超えてよい。ミップの段は折り返す前の微分で決めるので、
// タイルの継ぎ目でミップが飛ばない。微分はここで確定させるので、この後で discard してよい。
SGS_NetShape SGS_ReadShapeSlice(float2 patternUV, float slice)
{
    SGS_NetShape s;
    float texels = max(_NetBakeRange.w, 1.0);
    s.uvSlice = float3(patternUV, clamp(slice, 0.0, max(_NetSliceCount - 1.0, 0.0)));
    float2 dx = ddx(patternUV) * texels, dy = ddy(patternUV) * texels;
    s.texelPerPixel = max(max(length(dx), length(dy)), 1e-4);
    // ミップを半段浅くする（斜めから見た遠景で糸が平均されて薄まりすぎないように）
    s.lod = clamp(log2(max(s.texelPerPixel, 1.0)) - 0.5, 0.0, log2(texels));
    float2 v = UNITY_SAMPLE_TEX2DARRAY_LOD(_BakedShape, s.uvSlice, s.lod).rg;
    s.d = (v.x * 2.0 - 1.0) * _NetBakeRange.x;
    s.dClosed = (v.y * 2.0 - 1.0) * _NetBakeRange.x;
    s.coverage = (_NetDataVersion > 2.5) ? UNITY_SAMPLE_TEX2DARRAY_LOD(_BakedCoverage, s.uvSlice, s.lod).r : 0.0;
    return s;
}

// 同じ枚・同じミップの段で、UV をずらした所の 2 つの距離（糸だけ, 膜あり）を読む（陰の帯を作るため）
float2 SGS_ReadNetShapeAt(SGS_NetShape s, float2 uvOffset)
{
    float2 v = UNITY_SAMPLE_TEX2DARRAY_LOD(_BakedShape, float3(s.uvSlice.xy + uvOffset, s.uvSlice.z), s.lod).rg;
    return (v * 2.0 - 1.0) * _NetBakeRange.x;
}

struct SGS_NetDetail
{
    float2 direction;     // ふちの外向き（絵柄の UV の向き。正規化済み）
    float  radius;        // 糸の半径（画素）
    float  strandRandom;  // 糸ごとの乱数 0..1
};

SGS_NetDetail SGS_ReadNetDetail(SGS_NetShape s)
{
    // discard の後でも使えるよう、暗黙の微分は使わない（段は SGS_ReadShapeSlice で決めたもの）
    float4 v = UNITY_SAMPLE_TEX2DARRAY_LOD(_BakedDetail, s.uvSlice, s.lod);
    SGS_NetDetail r;
    r.direction = v.rg * 2.0 - 1.0;
    // 生成器は画素の行（下向き）で勾配を取り、Unity は PNG の一番上を v = 1 として取り込む。
    // 絵柄の UV（v は上向き）に合わせて y の符号を反転する
    r.direction.y = -r.direction.y;
    r.direction = (dot(r.direction, r.direction) > 1e-6) ? normalize(r.direction) : float2(1.0, 0.0);
    r.radius = max(v.b * _NetBakeRange.z, 0.5);
    r.strandRandom = v.a;
    return r;
}
#endif

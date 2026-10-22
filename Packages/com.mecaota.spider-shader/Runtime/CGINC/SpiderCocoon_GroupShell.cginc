#ifndef SPIDERCOCOON_GROUP_SHELL_INCLUDED
#define SPIDERCOCOON_GROUP_SHELL_INCLUDED

// 外殻の深度パス（GROUP_SHELL_DEPTH）で深度を書く不透明度の下限。
// 視界ジャック（0.9）より低くし、糸の本体（不透明度 0.7〜0.9 くらい）は奥の物を隠し、薄い膜だけ透かす
#define SCG_SHELL_DEPTH_ALPHA 0.5

// World-space envelope. The shape never comes from screen depth: both VR eyes see the same
// surface, and moving the camera cannot change which body samples define it.
// 外殻の形は、ワールド座標の部位（_GroupMemA/B）と繭同士の接続部位だけで決まる。画面の深度から形は作らないので、
// 両目で同じ形になり、カメラを動かしても形は変わらない。
// 画面の深度（_CameraDepthTexture）を読むのは 1 か所だけ: 不透明な物の向こうに完全に隠れた
// 2x2 の画素（quad）を、レイマーチの前に丸ごと捨てる（SCG_QuadHidden。2026-10-14 Phase 3）。
// 捨てるのは「描いても ZTest で必ず負ける」quad だけなので、下の前提を満たせば、見えている画素の色と深度は変わらない。
//   - 以前の案（画素ごとにレイの終点を深度で打ち切る。WorkLogs/2026-10-14-render-perf-audit/phase2a.md の 3d）は、
//     MSAA の輪郭の画素や 2x2 の画面微分を通して遮蔽物の輪郭で見た目が変わったので見送った。
//     今の形は quad 単位で、周り 1 画素まで見るので、まっすぐな輪郭ではその問題が起きない（同 phase3.md の 7）。
//   - 前提（満たさないと、見えるはずの外殻を quad ごと捨てることがある）:
//     ・深度テクスチャがこのカメラのもの。大きさが画面と違う・画素の番号と画面 UV が合わない・鏡・平行投影では打ち切らない。
//     ・(a) 深度テクスチャに入る物は、深度バッファでも前を隠すこと。深度テクスチャには入るのに深度バッファでは
//       前を隠さない物の向こうでは、見えるはずの外殻を quad ごと捨てる。例: キュー 2500 以下で ShadowCaster パスを持つ
//       ZWrite Off の物、alpha to coverage のカットアウト、ShadowCaster と本体で頂点の変形が違うシェーダー。
//     ・(b) MSAA で、遮蔽物どうしの間に 1 画素より細い隙間があると、その隙間からサンプル点だけが見える分が消える
//       （隙間の両側の画素中心がどちらも隠れているため）。まっすぐな輪郭と、1 画素以上の隙間なら一致する。
//   - 前提が守れない場面では、マテリアルの _GroupDepthCut を 0 にすると打ち切らない（従来どおり全部レイマーチする）。
float _GroupRadiusScale;
float _GroupAxisFollow;
float _GroupAxisBlend;
float _GroupLeadIndex;
float4 _GroupWrapOrigin;
float _GroupMarchSteps; // 外殻レイマーチの最大歩数（全身の 2 m 級の箱でも穴が開かないよう上げられる）
// 「形を絞った接続部位」（_GroupBridgePairs[k].w > 0 の組）の半分の高さの倍率（既定 1）。
// 絞った接続部位の半分の高さ = 短いほうの部位の半分の高さ × この値。
// w = 0 の組（腿↔腿など）と、組を使わない木の繭には効かない。
float _GroupBridgeHeightScale;
// 言葉の対応: コード上の Bridge / bridge（_GroupBridge*・SCG_PairBridge・bridgeCenter など）＝繭同士の接続部位。
// 接続部位は 2 つの部位の中心を結ぶ線分に沿って断面を動かした線織面（ruled surface）に厚みを付けた形。
// 名前を Bridge のままにしている理由は SpiderCocoon_Group.cginc の _GroupBridgeCount の注記。
// 遠い外殻の最大歩数（2026-10-14 Phase 3）。カメラ（両目の中点）から箱の中心までの距離が
// _GroupMarchFarStart m までは _GroupMarchSteps、_GroupMarchFarEnd m 以上は _GroupMarchStepsFar で、
// 間はなめらかに減らす。遠い外殻は画面上で小さいので、歩数切れで輪郭の外周が 1 画素細る程度。
// _GroupMarchStepsFar を _GroupMarchSteps 以上にすると減らさない（従来どおり）。
float _GroupMarchStepsFar;
float _GroupMarchFarStart;
float _GroupMarchFarEnd;
// 隠れた quad を捨てるか（マテリアル。既定 1、0 で打ち切らない。上の前提が守れない場面の逃げ道）
float _GroupDepthCut;
// 深度テクスチャの大きさ（Unity が設定する。このカメラの深度テクスチャかの確認に使う）
float4 _CameraDepthTexture_TexelSize;

// 部位 1 本の断面までの符号付き距離（m。負=内側）。
// rounding（_GroupMemB[k].w）= 端の丸め 0..1
//   0 = 端が平らな円筒（角だけ丸い。従来どおり。木の繭はいつも 0）
//   1 = カプセル（軸の線分までの距離 − 半径。端は半球）。頭を短いカプセルにすると
//       球に近い塊になり、手足をカプセルにすると関節の重なりが滑らかになる
//   途中の値は 2 つの距離を線形に混ぜる。
// cap = 端の面までの距離（ほつれと「端の糸の織り」に使う）。rounding > 0.5 では
//   端の面が無いので「遠い（十分内側）」として -1 m を返し、ほつれを出さない。
float SCG_RoundedSection(float3 delta, float axialSquared, float radius,
                         float halfHeight, float thickness, float rounding, out float cap)
{
    float axial = sqrt(max(axialSquared, 0.0));
    float radial = sqrt(max(dot(delta, delta) - axialSquared, 0.0));
    float2 q = float2(radial - radius, axial - halfHeight);
    float flatD = min(max(q.x, q.y), 0.0) + length(max(q, 0.0));
    float w = saturate(rounding);
    // カプセル: 軸の線分（半分の高さ halfHeight）までの距離 − 半径
    float capsuleD = length(float2(radial, max(q.y, 0.0))) - radius;
    cap = (w > 0.5) ? -1.0 : q.y - thickness;
    return lerp(flatD, capsuleD, w) - thickness;
}

void SCG_UnionSection(float d, float cap, float blend, inout float best, inout float capBest)
{
    if (best > 1e5) { best = d; capBest = cap; return; }
    float h;
    best = STG_SMin(best, d, blend, h);
    capBest = lerp(cap, capBest, h);
}

// 部位 a と部位 b の間をつなぐ接続部位（外皮）の距離。中心は 2 部位の中心を結ぶ線上を
// 滑らかに移り、軸・半径・半分の高さも a→b へ補間する（代表からの放射と同じ形）。
// span = この接続部位を作ってよい「部位表面どうしの隙間」の上限（m）。
// shape = _GroupBridgePairs[k].w（接続部位の形の絞り）。
//   0 = 従来どおり（半径・高さとも a→b の補間）
//   > 0 = 半径をこの倍率にし、半分の高さを「短いほうの部位の半分の高さ ×
//         _GroupBridgeHeightScale」にする。前腕↔胴を 0.5 にすると、手首まで届く
//         マントにならず、前腕の内側と腰の間に細い膜が張るだけになる。
// 接続部位の端の丸めは a・b の rounding（_GroupMemB.w）を補間する。
//
// ★ 下限で飛ばす（2026-10-14 軽量化。結果は飛ばさない場合と同じ）
//   skipAbove: 接続部位までの距離がこの値以上と分かれば、断面の計算を省いて skipAbove を返す
//   （呼び出し側は「これ以上なら smooth-min の寄与が 0」の値を渡す。飛ばさないときは 1e30）。
//   接続部位の断面までの距離は、断面の中心（a→b の線分上の点）からの距離 |delta| − 半径 − 半分の高さ − 厚み
//   より小さくならない（SCG_RoundedSection は半径 r・半分の高さ h の形の距離で、その形は
//   半径 r + h の球に収まるため）。下の d + (1 - gate) * (...) の足し分もそのまま足せる。
float SCG_PairBridge(float3 p, int ia, int ib, float span, float radiusScale,
                     float thickness, float shape, float skipAbove, out float ec)
{
    float3 ca = _GroupMemA[ia].xyz;
    float ha = max(length(_GroupMemB[ia].xyz), 1e-5);
    float3 aa = _GroupMemB[ia].xyz / ha;
    float3 cb = _GroupMemA[ib].xyz;
    float hb = max(length(_GroupMemB[ib].xyz), 1e-5);
    float3 ab = _GroupMemB[ib].xyz / hb;
    float3 segment = cb - ca;
    float length2 = dot(segment, segment);
    float t = saturate(0.5 + dot(p - (ca + cb) * 0.5, segment) / max(length2, 0.0009));
    float3 delta = p - lerp(ca, cb, t);
    float rr = lerp(_GroupMemA[ia].w, _GroupMemA[ib].w, t) * radiusScale;
    float hh = lerp(ha, hb, t);
    if (shape > 0.0)
    {
        rr *= shape;
        hh = min(ha, hb) * max(_GroupBridgeHeightScale, 0.0);
    }
    float gap = max(length(segment) - _GroupMemA[ia].w - _GroupMemA[ib].w - ha - hb, 0.0);
    float gate = 1.0 - smoothstep(span, span + thickness, gap);
    float extra = (1.0 - gate) * (length(segment) + rr + hh + thickness);
    // 下限 |delta| - rr - hh - thickness + extra が skipAbove 以上なら、断面の計算を省く
    float reach = skipAbove - extra + rr + hh + thickness;   // |delta| がこれ以上なら飛ばせる
    if (skipAbove < 1e29 && (reach <= 0.0 || dot(delta, delta) >= reach * reach))
    {
        ec = 0.0;          // 飛ばした接続部位は合成に使われないので、端の値は何でもよい
        return skipAbove;
    }
    float ya = dot(delta, aa), yb = dot(delta, ab);
    float yy = lerp(ya*ya, yb*yb, t);
    float rounding = lerp(_GroupMemB[ia].w, _GroupMemB[ib].w, t);
    float d = SCG_RoundedSection(delta, yy, rr, hh, thickness, rounding, ec);
    return d + extra;
}

// 距離場で、レイマーチの間ずっと変わらない値（2026-10-14 軽量化）。
// 以前は距離場を評価するたび（1 画素で最大 120 歩 + 法線 6 回 + 二分法 6 回）に計算し直していた。
// 1 画素の最初に 1 回だけ作り、SCG_VolumeFieldC に渡す（式は同じなので値も同じ）。
struct SCG_FieldConst
{
    int    n;             // 部位の数
    int    lead;          // 代表の部位
    float  thickness;     // 膨らみ（glue の厚み + 外殻の膨らみ）
    float  blend;         // 部位どうしをなめらかにつなぐ幅（smooth-min の k）
    bool   pairMode;      // 接続部位の組が渡されている（全身繭）
    float  radiusScale;
    float3 c0;            // 代表の中心・半分の高さ・軸（代表から放射状に作る接続部位用）
    float  h0;
    float3 a0;
    bool   radial;        // 代表から放射状に接続部位を作る（組なし。木の繭など）
    bool   pairs;         // 組ごとに接続部位を作る
    int    pairCount;
};

SCG_FieldConst SCG_MakeFieldConst()
{
    SCG_FieldConst c;
    c.n = clamp((int)_GroupMemCount, 0, SCG_MAX_MEMBERS);
    c.lead = clamp((int)_GroupLeadIndex, 0, max(c.n - 1, 0));
    c.thickness = max(_GlueThickness, 0.0) + max(_GroupBulge, 0.0);
    // 一体感は 1 を超えて上げられる（全身繭で脇・股の合流を大きく丸める）
    c.blend = max(c.thickness * 0.3 * max(_GroupShellBlend, 0.0), 1e-5);
    // 接続部位の組が渡されていれば（全身繭）組ごとに接続部位を作り、代表からの放射はしない
    c.pairMode = _GroupBridgeCount > 0.5;
    c.radiusScale = clamp(_GroupRadiusScale, 0.25, 1.0);
    c.c0 = _GroupMemA[c.lead].xyz;
    c.h0 = max(length(_GroupMemB[c.lead].xyz), 1e-5);
    c.a0 = _GroupMemB[c.lead].xyz / c.h0;
    // 代表が骨なしなら放射状の接続部位も作らない
    c.radial = !c.pairMode && _GroupBridgeSpan > 0.0005 && _GroupMemA[c.lead].w > 0.0;
    c.pairs = c.pairMode && _GroupBridgeSpan > 0.0005 && c.n > 1;
    c.pairCount = min((int)_GroupBridgeCount, SCG_MAX_BRIDGES);
    return c;
}

// smooth-min で寄与が 0 と言い切るための余裕（m）。浮動小数の誤差（1e-6 m 程度）より十分大きく、
// 形には効かないほど小さい
#define SCG_SKIP_MARGIN 0.0001

// Members plus ruled-surface connections (the "bridges": 繭同士の接続部位) from the stable representative. Squared axis
// projections interpolate the unoriented axes: +Y/-Y and 90 degree crossings
// never trigger a sign flip or a vanishing lerped axis.
//
// ★ 遠い部位・接続部位は計算を飛ばす（allowSkip。2026-10-14 軽量化。結果は飛ばさない場合と同じ）
//   部位どうしは smooth-min（STG_SMin）でつなぐ。新しい距離 d が今までの最小 best より
//   blend（smooth-min の k）以上大きければ、STG_SMin の結果は best のまま（寄与が厳密に 0）:
//     d - best >= k のとき m = max(k - |best - d|, 0) / k = 0 なので、min(best, d) - 0 = best。
//   部位の距離は「中心からの距離 − (半分の高さ + 半径 + 厚み)」より小さくならない
//   （SCG_RoundedSection の形は、中心から半分の高さ + 半径の球に収まるため）。
//   そこで「中心からの距離 >= best + blend + 半分の高さ + 半径 + 厚み + 余裕」なら飛ばす。
//   最初の部位（best がまだ無い）は必ず計算する。
//   端の値（cap）は飛ばした部位の分を合成しない。飛ばさない場合も lerp の重みが 1 なので
//   丸め誤差（1 ulp）以外は同じ。cap を使う呼び出し（外殻の色のほつれ）は allowSkip = false で呼ぶ。
float SCG_VolumeFieldC(float3 p, SCG_FieldConst fc, bool allowSkip, out float cap)
{
    float best = 1e6; cap = 0;
    [loop] for (int k = 0; k < SCG_MAX_MEMBERS; k++)
    {
        if (k >= fc.n) break;
        if (_GroupMemA[k].w <= 0.0) continue;   // 半径 0 以下の部位（骨なし）は存在しない扱い
        float3 ck = _GroupMemA[k].xyz;
        float hk = max(length(_GroupMemB[k].xyz), 1e-5);
        float3 ak = _GroupMemB[k].xyz / hk;
        float  rk = _GroupMemA[k].w * fc.radiusScale;
        float3 delta = p - ck;
        // 飛ばしてよい距離の境目（best < 1e5 = 最初の部位はもう計算済み）
        float skipAbove = (allowSkip && best < 1e5) ? best + fc.blend + SCG_SKIP_MARGIN : 1e30;
        float memberReach = skipAbove + hk + rk + fc.thickness;   // 中心からの距離がこれ以上なら飛ばせる
        if (skipAbove > 1e29 || dot(delta, delta) < memberReach * memberReach)
        {
            float y = dot(delta, ak);
            float ec;
            float d = SCG_RoundedSection(delta, y*y, rk, hk, fc.thickness,
                                         _GroupMemB[k].w, ec);
            SCG_UnionSection(d, ec, fc.blend, best, cap);
        }
        if (!fc.radial || k == fc.lead) continue;
        float3 segment = ck - fc.c0;
        float length2 = dot(segment, segment);
        // Blend continuously even when the two restraint centres coincide.
        float t = saturate(0.5 + dot(p - (fc.c0 + ck) * 0.5, segment) / max(length2, 0.0009));
        float3 bridgeCenter = lerp(fc.c0, ck, t);
        delta = p - bridgeCenter;
        float rr = lerp(_GroupMemA[fc.lead].w, _GroupMemA[k].w, t) * fc.radiusScale;
        float hh = lerp(fc.h0, hk, t);
        // No binary distance cutoff: a continuous fade limits unusually long ruled-surface connections.
        float gap = max(length(segment) - _GroupMemA[fc.lead].w - _GroupMemA[k].w - fc.h0 - hk, 0.0);
        float gate = 1.0 - smoothstep(_GroupBridgeSpan, _GroupBridgeSpan + fc.thickness, gap);
        float extra = (1.0 - gate) * (length(segment) + rr + hh + fc.thickness);
        // 接続部位も同じく下限で飛ばす（断面の中心は c0→ck の線分上。SCG_PairBridge の説明）
        skipAbove = (allowSkip && best < 1e5) ? best + fc.blend + SCG_SKIP_MARGIN : 1e30;
        float bridgeReach = skipAbove - extra + rr + hh + fc.thickness;
        if (skipAbove < 1e29 && (bridgeReach <= 0.0 || dot(delta, delta) >= bridgeReach * bridgeReach)) continue;
        float ya = dot(delta, fc.a0), yb = dot(delta, ak);
        float yy = lerp(ya*ya, yb*yb, t);
        float ec;
        float bridgeD = SCG_RoundedSection(delta, yy, rr, hh, fc.thickness,
                                           lerp(_GroupMemB[fc.lead].w, _GroupMemB[k].w, t), ec);
        bridgeD += extra;
        SCG_UnionSection(bridgeD, ec, fc.blend, best, cap);
    }
    if (fc.pairs)
    {
        [loop] for (int j = 0; j < SCG_MAX_BRIDGES; j++)
        {
            if (j >= fc.pairCount) break;
            float4 pr = _GroupBridgePairs[j];
            int ia = clamp((int)pr.x, 0, fc.n - 1);
            int ib = clamp((int)pr.y, 0, fc.n - 1);
            if (ia == ib) continue;
            if (_GroupMemA[ia].w <= 0.0 || _GroupMemA[ib].w <= 0.0) continue;   // 骨なしの部位を含む接続部位は作らない
            float span = _GroupBridgeSpan * (pr.z > 0.0 ? pr.z : 1.0);
            float skipAbove = (allowSkip && best < 1e5) ? best + fc.blend + SCG_SKIP_MARGIN : 1e30;
            float pec;
            float pairD = SCG_PairBridge(p, ia, ib, span, fc.radiusScale, fc.thickness, pr.w, skipAbove, pec);
            if (pairD >= skipAbove) continue;   // 飛ばした（または寄与が 0 と分かった）接続部位
            SCG_UnionSection(pairD, pec, fc.blend, best, cap);
        }
    }
    return best;
}

// 従来の呼び方（飛ばさない。端の値 cap も厳密に従来どおり）
float SCG_VolumeField(float3 p, out float cap)
{
    return SCG_VolumeFieldC(p, SCG_MakeFieldConst(), false, cap);
}

float SCG_VolumeDistance(float3 p)
{
    float cap;
    return SCG_VolumeField(p, cap);
}

// レイマーチ・法線・二分法用（距離だけを使う。遠い部位を飛ばす）
float SCG_VolumeDistanceC(float3 p, SCG_FieldConst fc)
{
    float cap;
    return SCG_VolumeFieldC(p, fc, true, cap);
}

// 全部位がカプセル（端の丸め > 0.5）か。そのとき端の値 cap はどこでも -1（SCG_RoundedSection）になり、
// 外殻のほつれは「十分内側」で一定なので、距離場をもう 1 回評価して cap を求める必要が無い。
// 0.51 は、2 部位の丸めを補間した接続部位の丸めも確実に 0.5 を超えるための余裕。
bool SCG_AllCapsules(SCG_FieldConst fc)
{
    bool all = true;
    [loop] for (int k = 0; k < SCG_MAX_MEMBERS; k++)
    {
        if (k >= fc.n) break;
        if (_GroupMemA[k].w <= 0.0) continue;   // 骨なしの部位は距離場に入らない
        if (_GroupMemB[k].w < 0.51) { all = false; break; }
    }
    return all;
}

// One angular coordinate around the group, one gently warped height coordinate.
// Blend the member axes/offsets as a continuous field, not a nearest-member switch.
void SCG_AxisWrap(float3 p, out float3 local, out float3 colX, out float3 colY)
{
    float3 baseX = unity_ObjectToWorld._m00_m10_m20;
    float3 baseY = unity_ObjectToWorld._m01_m11_m21;
    float3 baseZ = unity_ObjectToWorld._m02_m12_m22;
    float3 x = normalize(baseX), y = normalize(baseY), z = normalize(baseZ);
    float3 origin = _GroupWrapOrigin.w > 0.5 ? _GroupWrapOrigin.xyz : _GroupCylA.xyz;
    float3 delta = p - origin;
    float weightSum = 0, heightSum = 0;
    float3 directionSum = 0;
    float width = max(_GroupAxisBlend, 0.025);
    [loop] for (int k = 0; k < SCG_MAX_MEMBERS; k++)
    {
        if (k >= (int)_GroupMemCount) break;
        if (_GroupMemA[k].w <= 0.0) continue;   // 半径 0 以下の部位（骨なし）は巻きの向きに加えない
        float hh = max(length(_GroupMemB[k].xyz), 1e-5);
        float3 axis = _GroupMemB[k].xyz / hh;
        float3 dk = p - _GroupMemA[k].xyz;
        float off = dot(dk, axis);
        float3 radial = dk - axis * off;
        float outside = max(abs(off) - hh, 0.0);
        float distance2 = dot(radial, radial) + outside * outside;
        float weight = 1.0 / max(distance2 + width * width, 1e-4);
        weight *= weight;
        // Tensor projection has the same value for axis and -axis. The shared
        // direction remains as a bias at perpendicular axes to avoid folds.
        float3 guide = normalize(y * 0.35 + axis * dot(axis, y) * 0.65);
        // 全身繭（接続部位の組あり）では高さを部位の中心ではなく共通の原点から測る。
        // 部位ごとの中心から測ると、胴↔腿・前腕↔手のように中心の高さが違う部位の
        // 境目で高さが急に変わり、帯が詰まって横一直線の継ぎ目になる。
        // 木の繭（組なし）は従来どおり部位の中心から測る（見た目は変わらない）。
        heightSum += dot(_GroupBridgeCount > 0.5 ? delta : dk, guide) * weight;
        directionSum += guide * weight;
        weightSum += weight;
    }
    float follow = saturate(_GroupAxisFollow);
    float height = lerp(dot(delta, y), heightSum / max(weightSum, 1e-6), follow);
    float3 direction = normalize(lerp(y, directionSum / max(weightSum, 1e-6), follow));
    // Keep broad ribbons on the enlarged sheath rather than doubling their
    // screen frequency when the shell becomes taller than the source decal.
    float heightScale = length(baseY) + 2.0 * (max(_GlueThickness, 0.0) + max(_GroupBulge, 0.0));
    local = float3(dot(delta, x) / max(length(baseX), 1e-4),
                   height / max(heightScale, 1e-4),
                   dot(delta, z) / max(length(baseZ), 1e-4));
    colX = baseX;
    colY = direction * length(baseY);
#if defined(SC_COCOON_SHEET_STYLE) && defined(SC_SURFACE_NET)
    // ねばねばネット風は h = local.y × |colY| で実際の高さ m に戻すので、local.y を割った
    // heightScale を長さにする（繭の帯は colY の向きしか使わないので影響なし）
    colY = direction * heightScale;
#endif
}

// ---- 隠れた quad を丸ごと捨てる（2026-10-14 Phase 3。SCG_QuadHidden）----
// quad（2x2 の画素）の 4 画素と、その周り 1 画素（合わせて 4x4 の画素中心）の全部で、
// 「深度テクスチャの面までの距離 × 1.01 + 1 cm が、その画素の視線が箱に入る距離以下」
// （= 不透明な面が外殻の箱より手前にある）なら、その quad を丸ごと捨てる。
//   - 画面微分は使わない。4 つの画素が同じ 16 点を同じ式で調べるので、quad の全員が同じ答えになる
//     （捨てた quad には見える画素が無いので、残る画素の fwidth も変わらない）。
//   - 周り 1 画素まで見るのは MSAA のため。深度テクスチャは画素中心の 1 点の値なので、遮蔽物の輪郭の画素では
//     中心は隠れていてもサンプル点の一部が見えていることがある。サンプル点の中心からのずれは最大で 4x 0.40 px、8x 0.62 px。
//     まっすぐな輪郭なら、そのとき隣（斜めを含む 8 つ）の画素中心のどれかは、輪郭から「1 − ずれ」以上外に出る
//     （隣との余裕 ≥ 1 − ずれ > 0。4x で 0.60 px、8x で 0.38 px）ので、その quad は捨てない。
//   - 一致しない場合はファイル冒頭の前提 (a)(b)。深度テクスチャに入るのに深度バッファでは前を隠さない物の向こうと、
//     MSAA で遮蔽物どうしの間の 1 画素より細い隙間。困るときはマテリアルの _GroupDepthCut を 0 にする。
//   - 深度テクスチャがこのカメラのものでない（大きさが画面と違う）、画素の番号と画面 UV が半画素以上ずれる
//     （Viewport Rect の原点がずれたカメラ、上下の向きの取り違えなど）、鏡、平行投影では打ち切らない
//     （呼び出し側と SCG_QuadHidden）。
// 画素中心 pix（片目の中の画素の番号 + 0.5）が「隠れている」なら 1、そうでなければ 0
float SCG_DepthHiddenAt(float2 pix, float2 texel, bool flipY, float3 ro, float3 halfBox)
{
    float2 uv = pix * texel;
    if (flipY) uv.y = 1.0 - uv.y;
    float raw = SC_SAMPLE_DEPTH_LOD(SC_DEPTH_UV(saturate(uv)));
#if defined(UNITY_REVERSED_Z)
    bool hasSurface = raw > 1e-7;                      // 空（面が無い）は隠れていない
#else
    bool hasSurface = raw < 1.0 - 1e-7;
#endif
    float eyeZ = LinearEyeDepth(raw);
    // この画素中心の視線（視線深度 1 m あたりの進み）。SC_ViewPosAt と同じ逆射影
    float2 ndc = float2(uv.x * 2.0 - 1.0, (uv.y * 2.0 - 1.0) * _ProjectionParams.x);
    float3 vdir = float3((ndc.x + UNITY_MATRIX_P._m02) / UNITY_MATRIX_P._m00,
                         (ndc.y + UNITY_MATRIX_P._m12) / UNITY_MATRIX_P._m11, -1.0);
    float3 wdir = mul((float3x3)UNITY_MATRIX_I_V, vdir);
    float3 od = mul((float3x3)unity_WorldToObject, wdir);
    float3 sd = float3(od.x >= 0 ? 1 : -1, od.y >= 0 ? 1 : -1, od.z >= 0 ? 1 : -1) * max(abs(od), 1e-7);
    float3 ta = (-halfBox - ro) / sd, tb = (halfBox - ro) / sd;
    float3 lo = min(ta, tb);
    float zStart = max(lo.x, max(lo.y, lo.z));         // 箱に入る視線深度
    float len = length(wdir);                          // 視線深度 → レイに沿った距離
    // 余裕は 1% + 1 cm。画面の外の画素は「隠れていない」扱い
    bool hidden = hasSurface && all(uv >= 0.0) && all(uv <= 1.0)
               && eyeZ * len * 1.01 + 0.01 <= max(zStart * len, 0.0001);
    return hidden ? 1.0 : 0.0;
}

// svPos = SV_Position.xy（画素の中心 x.5）、screenUV = 頂点から補間した画面 UV（片目の 0..1。保険の照合に使う）、
// ro = カメラの位置（箱のオブジェクト空間）、halfBox = 箱の半分の大きさ
bool SCG_QuadHidden(float2 svPos, float2 screenUV, float3 ro, float3 halfBox)
{
    float2 texel = SC_EyeTexelSize();
    float2 eyeSize = round(1.0 / texel);
    float2 depthSize = _CameraDepthTexture_TexelSize.zw;
#if defined(UNITY_SINGLE_PASS_STEREO)
    depthSize.x *= 0.5;                        // double-wide は両目で 1 枚
#endif
    if (any(abs(depthSize - eyeSize) > 0.5)) return false;   // このカメラの深度テクスチャではない（無い・別の大きさ）
    float2 p = svPos;                          // 画素の中心（x.5）
#if defined(UNITY_SINGLE_PASS_STEREO)
    p.x -= unity_StereoEyeIndex * eyeSize.x;   // 片目の中の番号へ
#endif
    float2 base = floor(p * 0.5) * 2.0;        // quad の左上の画素の番号（4 画素で同じ値）
    // 画素の番号 → 画面 UV（ComputeNonStereoScreenPos と同じ向き。RT への描画は上下が逆）
#if UNITY_UV_STARTS_AT_TOP
    bool flipY = _ProjectionParams.x > 0.0;
#else
    bool flipY = _ProjectionParams.x < 0.0;
#endif
    // 保険: 自分の画素について、SV_Position から作った UV と、頂点から補間した画面 UV（screenUV）が半画素以上
    // ずれていたら打ち切らない。Viewport Rect の原点がずれたカメラ（SV_Position は描画先の画素の番号なので原点の分ずれる）や、
    // 上の flipY の取り違えへの備え。どちらもカメラ全体で同じずれなので、quad の 4 画素の答えはそろう
    float2 uvSelf = (floor(p) + 0.5) * texel;
    if (flipY) uvSelf.y = 1.0 - uvSelf.y;
    if (any(abs(uvSelf - screenUV) >= 0.5 * texel)) return false;
    // 自分の画素が見えていれば、16 点の全部が隠れることはない（答えは「捨てない」で、ほかの 3 画素と同じ）。
    // 自分の画素の判定は、下の 16 点の中の同じ点と同じ式・同じ値なので、quad の答えはそろったまま。
    // 見えている外殻の画素（ふつうの場合）は、ここで 1 点だけ見て終わる
    bool allHidden = false;
    [branch] if (SCG_DepthHiddenAt(floor(p) + 0.5, texel, flipY, ro, halfBox) > 0.5)
    {
        // ★ ループの途中で return しない（試作で、途中の return を FXC が誤って消し、全部捨てる版になった）。
        //   16 点を数えてから、最後に 1 回だけ答えを決める
        float n = 0.0;
        [unroll] for (int j = 0; j < 4; j++)
            [unroll] for (int i = 0; i < 4; i++)
                n += SCG_DepthHiddenAt(base + float2(i, j) - 0.5, texel, flipY, ro, halfBox);   // base-1 .. base+2 の画素中心
        allHidden = n > 15.5;
    }
    return allHidden;
}

// svPos = SV_Position.xy（隠れた quad を捨てる SCG_QuadHidden に使う）
fixed4 SCG_ShadeGroupShell(float2 screenUV, float3 worldDir, float2 svPos, out float rawOut)
{
    rawOut = 0;
    float3 origin = _WorldSpaceCameraPos;
    float3 ray = normalize(worldDir);
    float3 forward = -UNITY_MATRIX_V[2].xyz;
    if (unity_OrthoParams.w > 0.5)
    {
        origin += worldDir - forward * dot(worldDir, forward);
        ray = forward;
    }
    float3 ro = mul(unity_WorldToObject, float4(origin, 1)).xyz;
    float3 rd = mul((float3x3)unity_WorldToObject, ray);
    float3 safeD = float3(rd.x >= 0 ? 1 : -1, rd.y >= 0 ? 1 : -1, rd.z >= 0 ? 1 : -1)
                 * max(abs(rd), 1e-7);
    float3 halfBox = SCG_BoxHalf();
    float3 ta = (-halfBox - ro) / safeD;
    float3 tb = ( halfBox - ro) / safeD;
    float3 lo = min(ta, tb), hi = max(ta, tb);
    float start = max(max(lo.x, max(lo.y, lo.z)), 0.0001);
    float end = min(hi.x, min(hi.y, hi.z));
    // 不透明な物の向こうに完全に隠れた quad は、レイマーチの前に丸ごと捨てる（SCG_QuadHidden。マテリアルの
    // _GroupDepthCut が 0 のとき、鏡と平行投影では使わない）
    // ★ この discard を、関数の途中の return（色を返す）に変えないこと。2026-10-14 のレビューのデバッグ版で、
    //   ここを途中の return にした一時シェーダーが GPU を止め、デバイス消失（Unity Error）になった。
    //   デバッグするときは旗（bool）を立てるだけにして、関数の最後で色を付ける。
    [branch] if (_GroupDepthCut > 0.5 && unity_OrthoParams.w < 0.5 && !SC_IsInMirror())
    {
        if (SCG_QuadHidden(svPos, screenUV, ro, halfBox)) discard;
    }
    if (end <= start) discard;
    // 距離場の、画素の中で変わらない値は最初に 1 回だけ作る（SCG_FieldConst）
    SCG_FieldConst fc = SCG_MakeFieldConst();
    float t = start;
    float d = SCG_VolumeDistanceC(origin + ray * t, fc);
    bool inside = d < 0;
    bool hit = false;
    // Fixed world tolerance; no per-eye randomization, dithering or screen-derived shape.
    // 最大歩数はマテリアルの _GroupMarchSteps（32〜160、既定 80）。遠い外殻は _GroupMarchStepsFar まで減らす
    // （2026-10-14 Phase 3）。距離は箱の中心まで（物体ごとに 1 つの値。両目で同じ歩数になるよう中央の目から測る）
    float3 boxCenter = float3(unity_ObjectToWorld._m03, unity_ObjectToWorld._m13, unity_ObjectToWorld._m23);
    float camDist = distance(SC_MonoCameraPos(), boxCenter);
    float farT = saturate((camDist - _GroupMarchFarStart) / max(_GroupMarchFarEnd - _GroupMarchFarStart, 1e-3));
    float stepsF = lerp(_GroupMarchSteps, min(_GroupMarchStepsFar, _GroupMarchSteps), farT);
    int marchSteps = clamp((int)stepsF, 32, 160);
    [loop] for (int step = 0; step < 160; step++)
    {
        if (step >= marchSteps) break;
        if (abs(d) < 0.0004) { hit = true; break; }
        float oldT = t, oldD = d;
        // 1 歩 = 距離場の値 × 0.7（2026-10-14 Phase 3 で 0.35 から引き上げ。歩数がほぼ半分になる）。
        // 面を飛び越えて符号が変わったときは、下の二分法で交点を詰める
        t += max(abs(d) * 0.7, 0.00015);
        if (t > end) break;
        d = SCG_VolumeDistanceC(origin + ray * t, fc);
        if (oldD * d < 0.0)
        {
            // Refine any bracketed crossing (tilted ruled-surface connection fields are conservative approximations).
            float a = oldT, b = t;
            [unroll] for (int k = 0; k < 6; k++)
            {
                float mid = (a + b) * 0.5;
                float md = SCG_VolumeDistanceC(origin + ray * mid, fc);
                if (oldD * md > 0) a = mid; else b = mid;
            }
            t = (a + b) * 0.5; hit = true; break;
        }
    }
    if (!hit) discard;
    float3 wp = origin + ray * t;
    float e = 0.001;
    // 法線 = 距離場の勾配。正四面体の 4 点（k = (+,-,-), (-,-,+), (-,+,-), (+,+,+)）で求める
    // （2026-10-14 Phase 3。以前は各軸 ±e の 6 回。陰影がごくわずかに変わるだけで、距離場の評価が 2 回減る）
    const float2 kk = float2(1.0, -1.0);
    float3 n = kk.xyy * SCG_VolumeDistanceC(wp + kk.xyy * e, fc)
             + kk.yyx * SCG_VolumeDistanceC(wp + kk.yyx * e, fc)
             + kk.yxy * SCG_VolumeDistanceC(wp + kk.yxy * e, fc)
             + kk.xxx * SCG_VolumeDistanceC(wp + kk.xxx * e, fc);
    n = dot(n,n) > 1e-12 ? normalize(n) : -ray;
    if (inside) n = -n;
    // 巻きの端のほつれ（edge）。全部位がカプセルなら端の値 cap はどこでも -1 なので、
    // 距離場をもう 1 回評価せずに同じ値（cap = -1 の式）を使う（SCG_AllCapsules）
    float edge;
    [branch] if (SCG_AllCapsules(fc))
    {
        edge = saturate(1.0 / max(_GooEdgeFray, 0.002));
    }
    else
    {
        float cap; SCG_VolumeFieldC(wp, fc, false, cap);
        edge = saturate(-cap / max(_GooEdgeFray, 0.002));
    }
    float3 wrap, colX, colY;
    SCG_AxisWrap(wp, wrap, colX, colY);
    fixed4 color = SC_ShadeCocoonAtExUnclipped(wrap, wp, n, colX, colY, edge);
    // Close the axial openings with overlapping silk ribbons. Cylindrical UVs
    // collapse on a cap and the old edge fray erased it altogether. A shared
    // planar weave covers the space between limbs without a camera-facing fill.
    // ねばねばネット風（キーワード SC_SURFACE_NET）は模様がそのまま端まで続くので、端の蓋の織りは描かない
#if !(defined(SC_COCOON_SHEET_STYLE) && defined(SC_SURFACE_NET))
    {
        float capWeight = smoothstep(0.3, 0.8, abs(dot(n, normalize(colY))));
        float3 planeX = normalize(unity_ObjectToWorld._m00_m10_m20);
        float3 planeZ = normalize(unity_ObjectToWorld._m02_m12_m22);
        float2 capUV = wrap.xz * 0.65 + 0.5;
        // 画面微分（fwidth）は分岐の外で全画素が計算する（分岐の中では隣の画素の値が無いことがある）
        float2 capAA = fwidth(capUV);
        float alpha;
        // 端の蓋が効かない画素（capWeight = 0。体の横向きの面のほとんど）では、蓋の織り 2 回分の合成を省く。
        // lerp(x, y, 0) = x なので、下の else は元の式に capWeight = 0 を入れた値と同じ（2026-10-14 軽量化）
        // 条件に capAA を含めるのは、コンパイラが fwidth を分岐の中へ移さないようにするため
        // （分岐の中で微分を取ると、分岐しなかった隣の画素の値が無く、輪郭のぼかしが変わる）。
        // capAA は 0 以上の有限の値なので、この条件は capWeight > 0 と同じ
        [branch] if (capWeight > 0.0 && capAA.x + capAA.y < 1e30)
        {
            // Two crossing sets of the same viscous ribbons make the opening dense,
            // with small fibre gaps rather than an opaque flat disk.
            fixed4 capA = SC_CompositeGooUnclipped(capUV, n, planeX, planeZ, wp,
                                        capAA, false, false, false, 1.0);
            fixed4 capB = SC_CompositeGooUnclipped(float2(capUV.y, -capUV.x) + 0.173,
                                        n, planeZ, -planeX, wp,
                                        capAA.yx, false, false, false, 1.0);
            float capAlpha = capA.a + capB.a * (1.0 - capA.a);
            float3 capPremul = capA.rgb * capA.a + capB.rgb * capB.a * (1.0 - capA.a);
            alpha = lerp(color.a, capAlpha, capWeight);
            color.rgb = lerp(color.rgb * color.a, capPremul, capWeight) / max(alpha, 1e-5);
        }
        else
        {
            alpha = color.a;
            color.rgb = (color.rgb * color.a) / max(alpha, 1e-5);
        }
        color.a = alpha;
    }
#endif
    // ほぼ透明な所は捨てる。深度を書くのは、さらに濃い所だけ（GROUP_SHELL_DEPTH パス）
    clip(color.a - 0.06);
    float4 cp = UnityWorldToClipPos(wp);
    rawOut = cp.z / cp.w;
    #if defined(SHADER_API_GLCORE) || defined(SHADER_API_GLES) || defined(SHADER_API_GLES3)
        rawOut = rawOut * 0.5 + 0.5;
    #endif
    return color;
}
#endif

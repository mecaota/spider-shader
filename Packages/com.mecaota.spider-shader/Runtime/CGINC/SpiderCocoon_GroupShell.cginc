#ifndef SPIDERCOCOON_GROUP_SHELL_INCLUDED
#define SPIDERCOCOON_GROUP_SHELL_INCLUDED

// 外殻の深度パス（GROUP_SHELL_DEPTH）で深度を書く不透明度の下限。
// 視界ジャック（0.9）より低くし、糸の本体（不透明度 0.7〜0.9 くらい）は奥の物を隠し、薄い膜だけ透かす
#define SCG_SHELL_DEPTH_ALPHA 0.5

// World-space envelope. No screen-depth samples: both VR eyes see the same
// surface, and moving the camera cannot change which body samples define it.
float _GroupRadiusScale;
float _GroupAxisFollow;
float _GroupAxisBlend;
float _GroupLeadIndex;
float4 _GroupWrapOrigin;

float SCG_RoundedSection(float3 delta, float axialSquared, float radius,
                         float halfHeight, float thickness, out float cap)
{
    float axial = sqrt(max(axialSquared, 0.0));
    float radial = sqrt(max(dot(delta, delta) - axialSquared, 0.0));
    float2 q = float2(radial - radius, axial - halfHeight);
    cap = q.y - thickness;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - thickness;
}

void SCG_UnionSection(float d, float cap, float blend, inout float best, inout float capBest)
{
    if (best > 1e5) { best = d; capBest = cap; return; }
    float h;
    best = STG_SMin(best, d, blend, h);
    capBest = lerp(cap, capBest, h);
}

// Members plus ruled bridges from the stable representative. Squared axis
// projections interpolate the unoriented axes: +Y/-Y and 90 degree crossings
// never trigger a sign flip or a vanishing lerped axis.
float SCG_VolumeField(float3 p, out float cap)
{
    float best = 1e6; cap = 0;
    int n = clamp((int)_GroupMemCount, 0, SCG_MAX_MEMBERS);
    int lead = clamp((int)_GroupLeadIndex, 0, max(n - 1, 0));
    float thickness = max(_GlueThickness, 0.0) + max(_GroupBulge, 0.0);
    float blend = max(thickness * 0.3 * saturate(_GroupShellBlend), 1e-5);
    float radiusScale = clamp(_GroupRadiusScale, 0.25, 1.0);
    float3 c0 = _GroupMemA[lead].xyz;
    float h0 = max(length(_GroupMemB[lead].xyz), 1e-5);
    float3 a0 = _GroupMemB[lead].xyz / h0;
    [loop] for (int k = 0; k < SCG_MAX_MEMBERS; k++)
    {
        if (k >= n) break;
        float3 ck = _GroupMemA[k].xyz;
        float hk = max(length(_GroupMemB[k].xyz), 1e-5);
        float3 ak = _GroupMemB[k].xyz / hk;
        float3 delta = p - ck;
        float y = dot(delta, ak);
        float ec;
        float d = SCG_RoundedSection(delta, y*y, _GroupMemA[k].w * radiusScale, hk, thickness, ec);
        SCG_UnionSection(d, ec, blend, best, cap);
        if (k == lead || _GroupBridgeSpan <= 0.0005) continue;
        float3 segment = ck - c0;
        float length2 = dot(segment, segment);
        // Blend continuously even when the two restraint centres coincide.
        float t = saturate(0.5 + dot(p - (c0 + ck) * 0.5, segment) / max(length2, 0.0009));
        float3 bridgeCenter = lerp(c0, ck, t);
        delta = p - bridgeCenter;
        float ya = dot(delta, a0), yb = dot(delta, ak);
        float yy = lerp(ya*ya, yb*yb, t);
        float rr = lerp(_GroupMemA[lead].w, _GroupMemA[k].w, t) * radiusScale;
        float hh = lerp(h0, hk, t);
        float bridgeD = SCG_RoundedSection(delta, yy, rr, hh, thickness, ec);
        // No binary distance cutoff: a continuous fade limits unusually long bridges.
        float gap = max(length(segment) - _GroupMemA[lead].w - _GroupMemA[k].w - h0 - hk, 0.0);
        float gate = 1.0 - smoothstep(_GroupBridgeSpan, _GroupBridgeSpan + thickness, gap);
        bridgeD += (1.0 - gate) * (length(segment) + rr + hh + thickness);
        SCG_UnionSection(bridgeD, ec, blend, best, cap);
    }
    return best;
}

float SCG_VolumeDistance(float3 p)
{
    float cap;
    return SCG_VolumeField(p, cap);
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
        heightSum += dot(dk, guide) * weight;
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
}

fixed4 SCG_ShadeGroupShell(float2 screenUV, float3 worldDir, out float rawOut)
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
    if (end <= start) discard;
    float t = start;
    float d = SCG_VolumeDistance(origin + ray * t);
    bool inside = d < 0;
    bool hit = false;
    // Fixed world tolerance; no per-eye randomization, dithering or screen-derived shape.
    [loop] for (int step = 0; step < 80; step++)
    {
        if (abs(d) < 0.0004) { hit = true; break; }
        float oldT = t, oldD = d;
        t += max(abs(d) * 0.35, 0.00015);
        if (t > end) break;
        d = SCG_VolumeDistance(origin + ray * t);
        if (oldD * d < 0.0)
        {
            // Refine any bracketed crossing (tilted bridge fields are conservative approximations).
            float a = oldT, b = t;
            [unroll] for (int k = 0; k < 6; k++)
            {
                float mid = (a + b) * 0.5;
                float md = SCG_VolumeDistance(origin + ray * mid);
                if (oldD * md > 0) a = mid; else b = mid;
            }
            t = (a + b) * 0.5; hit = true; break;
        }
    }
    if (!hit) discard;
    float3 wp = origin + ray * t;
    float e = 0.001;
    float3 n = float3(
        SCG_VolumeDistance(wp + float3(e,0,0)) - SCG_VolumeDistance(wp - float3(e,0,0)),
        SCG_VolumeDistance(wp + float3(0,e,0)) - SCG_VolumeDistance(wp - float3(0,e,0)),
        SCG_VolumeDistance(wp + float3(0,0,e)) - SCG_VolumeDistance(wp - float3(0,0,e)));
    n = dot(n,n) > 1e-12 ? normalize(n) : -ray;
    if (inside) n = -n;
    float cap; SCG_VolumeField(wp, cap);
    float edge = saturate(-cap / max(_GooEdgeFray, 0.002));
    float3 wrap, colX, colY;
    SCG_AxisWrap(wp, wrap, colX, colY);
    fixed4 color = SC_ShadeCocoonAtExUnclipped(wrap, wp, n, colX, colY, edge);
    // Close the axial openings with overlapping silk ribbons. Cylindrical UVs
    // collapse on a cap and the old edge fray erased it altogether. A shared
    // planar weave covers the space between limbs without a camera-facing fill.
    float capWeight = smoothstep(0.3, 0.8, abs(dot(n, normalize(colY))));
    float3 planeX = normalize(unity_ObjectToWorld._m00_m10_m20);
    float3 planeZ = normalize(unity_ObjectToWorld._m02_m12_m22);
    float2 capUV = wrap.xz * 0.65 + 0.5;
    float2 capAA = fwidth(capUV);
    // Two crossing sets of the same viscous ribbons make the opening dense,
    // with small fibre gaps rather than an opaque flat disk.
    fixed4 capA = SC_CompositeGooUnclipped(capUV, n, planeX, planeZ, wp,
                                capAA, false, false, false, 1.0);
    fixed4 capB = SC_CompositeGooUnclipped(float2(capUV.y, -capUV.x) + 0.173,
                                n, planeZ, -planeX, wp,
                                capAA.yx, false, false, false, 1.0);
    float capAlpha = capA.a + capB.a * (1.0 - capA.a);
    float3 capPremul = capA.rgb * capA.a + capB.rgb * capB.a * (1.0 - capA.a);
    float alpha = lerp(color.a, capAlpha, capWeight);
    color.rgb = lerp(color.rgb * color.a, capPremul, capWeight) / max(alpha, 1e-5);
    color.a = alpha;
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

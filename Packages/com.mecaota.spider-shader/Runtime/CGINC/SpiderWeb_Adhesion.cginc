#ifndef SPIDERWEB_ADHESION_INCLUDED
#define SPIDERWEB_ADHESION_INCLUDED

float _PullAdhesion, _PullContactSize, _PullContactThicken, _PullEdgePin;

// Compact support keeps distant silk fixed. Inverse-distance weights preserve
// each contact even when two limbs share the same influence area.
float4 SW_AdhesionOffset(float3 p)
{
    float radius = max(_PullRadius, 0.001);
    float core = min(max(_PullContactSize, 0.001), radius * 0.65);
    float3 deltaSum = 0.0;
    float weightSum = 0.0;
    float envelope = 0.0;
    float contact = 0.0;
    int n = clamp((int)_PullCount, 0, SC_PULL_MAX);
    [loop]
    for (int j = 0; j < n; j++)
    {
        float4 anchor = _PullAnchors[j];
        float3 delta = _PullTargets[j].xyz - anchor.xyz;
        float d = distance(p, anchor.xyz);
        float falloff = 1.0 - smoothstep(core, radius, d);
        float tear = 1.0;
        if (_PullMaxStretch > 0.0)
            tear = saturate(1.0 - (length(delta) - _PullMaxStretch) / max(_PullTearFade, 0.001));
        float w = pow(max(falloff, 0.0), max(_PullFalloff, 0.25)) * saturate(anchor.w);
        float priority = w / pow(max(d / radius, 0.001), 4.0);
        deltaSum += delta * tear * priority;
        weightSum += priority;
        envelope = max(envelope, w);
        contact = max(contact, (1.0 - smoothstep(core, min(core * 2.0, radius), d)) * tear * saturate(anchor.w));
    }
    return float4(deltaSum / max(weightSum, 1e-8) * envelope * saturate(_PullStrength),
                  contact * saturate(_PullStrength));
}

float SW_EdgeWeight(float2 uv)
{
    float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
    return _PullEdgePin > 1e-5 ? smoothstep(0.0, _PullEdgePin, edge) : 1.0;
}

void SW_AdhesionDeform(inout float3 p, inout float3 N, inout float3 T,
                       float2 uv, float handedness, out float contact)
{
    float3 N0 = normalize(N);
    float3 T0 = normalize(T);
    float3 B0 = cross(N0, T0);
    float eps = max(0.002, min(_PullContactSize * 0.2, _PullRadius * 0.025));
    float4 offset = SW_AdhesionOffset(p);
    float edge = SW_EdgeWeight(uv);
    // WebPlane has a unit UV span. Account for nonuniform object scale when
    // evaluating the pinning band for finite-difference normals.
    float uScale = max(length(mul((float3x3)unity_WorldToObject, T0)), 1e-5);
    float vScale = max(length(mul((float3x3)unity_WorldToObject, B0)), 1e-5);
    float2 du = float2(eps * uScale, 0.0);
    float2 dv = float2(0.0, eps * vScale * handedness * unity_WorldTransformParams.w);
    float3 dT = T0 * (2.0 * eps)
        + SW_AdhesionOffset(p + T0 * eps).xyz * SW_EdgeWeight(uv + du)
        - SW_AdhesionOffset(p - T0 * eps).xyz * SW_EdgeWeight(uv - du);
    float3 dB = B0 * (2.0 * eps)
        + SW_AdhesionOffset(p + B0 * eps).xyz * SW_EdgeWeight(uv + dv)
        - SW_AdhesionOffset(p - B0 * eps).xyz * SW_EdgeWeight(uv - dv);
    p += offset.xyz * edge;
    contact = offset.w * edge;
    float3 normal = cross(dT, dB);
    N = dot(normal, normal) > 1e-12 ? normalize(normal) : N0;
    T = dot(dT, dT) > 1e-12 ? normalize(dT) : T0;
}

#endif

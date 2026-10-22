// SpiderWebDrapeBaker.shader — 蜘蛛の巣ドレープベイカーシェーダー。Editorからだけ使用。蜘蛛の巣ドレープ（粘液シート）の形状と塗りの補助値を保存します。
// 出力は 3 パス：距離・半径 / 向き・補助・光沢ノイズ / 被覆率。
// 全面へ書き、ブレンド・深度・時刻・画面AA・discardは使いません。
Shader "Hidden/mecaota/SpiderWebDrapeBaker"
{
    SubShader
    {
        Cull Off ZWrite Off ZTest Always Blend Off
        CGINCLUDE
        #include "../CGINC/SpiderGooSheet_BakeSource.cginc"
        // xy=模様の中心（0.5,0.5）、z=1（窓は使わない）、w=焼くUV全幅。
        float4 _BakeWindow;
        float _BakeTexelSize;
        SGS_Pattern EvaluateBake(v2f_img i)
        {
            float2 uv = _BakeWindow.xy + (i.uv - 0.5) * (_BakeWindow.z * _BakeWindow.w);
            SGS_Pattern p = SGS_Evaluate(uv);
            p.d /= _BakeWindow.z;
            p.radius /= _BakeWindow.z;
            return p;
        }
        float4 fragShape(v2f_img i) : SV_Target
        {
            SGS_Pattern p = EvaluateBake(i);
            return float4(p.d, p.radius, 0.0, 1.0);
        }
        float4 fragDetail(v2f_img i) : SV_Target
        {
            SGS_Pattern p = EvaluateBake(i);
            return float4(p.direction * 0.5 + 0.5, p.spokeness, p.glossNoise);
        }
        float CoverageAt(v2f_img i, float2 offset)
        {
            i.uv += offset * _BakeTexelSize;
            SGS_Pattern p = EvaluateBake(i);
            float aa = min(_BakeWindow.w * _BakeTexelSize * 0.3, p.radius) + 1e-6;
            return 1.0 - smoothstep(-aa, aa, p.d);
        }
        float4 fragCoverage(v2f_img i) : SV_Target
        {
            float c = (CoverageAt(i, float2(-0.25, -0.25)) + CoverageAt(i, float2(0.25, -0.25))
                     + CoverageAt(i, float2(-0.25, 0.25)) + CoverageAt(i, float2(0.25, 0.25))) * 0.25;
            return float4(c, 0.0, 0.0, 1.0);
        }
        ENDCG
        Pass
        {
            Name "SHAPE"
            CGPROGRAM
            #pragma target 3.5
            #pragma vertex vert_img
            #pragma fragment fragShape
            ENDCG
        }
        Pass
        {
            Name "DETAIL"
            CGPROGRAM
            #pragma target 3.5
            #pragma vertex vert_img
            #pragma fragment fragDetail
            ENDCG
        }
        Pass
        {
            Name "COVERAGE"
            CGPROGRAM
            #pragma target 3.5
            #pragma vertex vert_img
            #pragma fragment fragCoverage
            ENDCG
        }
    }
    Fallback Off
}

// =============================================================================
// SpiderWebBaker.shader — 蜘蛛の巣ベイカーシェーダー。蜘蛛の巣（mecaota/SpiderWeb）の模様をテクスチャへ焼くための Editor 専用シェーダー
//
//  Editor/SpiderWebLilToonBaker.cs だけが使う（マテリアルに付けて使うものではない。Hidden）。
//
//  Pass 0 BAKE    : 巣のメッシュを「UV の平面」に広げて描く（頂点の位置 = UV）。
//                   1 画素 = テクスチャの 1 テクセル。巣と同じ式（Runtime/CGINC/SpiderWeb_Core.cginc）で
//                   色と不透明度を計算し、色は sRGB に直して 8bit の RenderTexture に書く。
//                   扇形の巣の UV2（外周までの距離）も、UV が 0..1 をはみ出すメッシュもそのまま扱える
//                   （画面全体に四角を描く Blit では、この 2 つが扱えない）。
//  Pass 1 MIPREAD : 取り込んだテクスチャの指定したミップ段を、そのまま読み出す（被覆率の実測用）。
//
//  ■ 見る向きに依らない色にするしかけ
//    SW_BAKE を定義してから SpiderWeb_Core.cginc を読み込むと、視線が「面を正面から見る」向きに、光が
//    焼くときのシーンの太陽の向き（_BakeLightDir）になる（Core の #if defined(SW_BAKE) の 1 か所）。
//    面の向き・接線は、巣のレンダラーの Transform（_BakeObjectToWorld）でワールドの向きにして渡す
//    （巣のシェーダーと同じ向きで、糸の丸い断面の陰影とハイライトが付く）。
//    シーン光の反映度（_LightInfluence）・揺れ・接触の変形・体への巻き付きは、C# 側でマテリアルの値を
//    0 にしてから描く（光の色と明るさは焼かず、lilToon 側のライティングに任せる）。
// =============================================================================
Shader "Hidden/mecaota/SpiderWebBaker"
{
    SubShader
    {
        Cull Off ZWrite Off ZTest Always Blend Off

        CGINCLUDE
            // 焼き込み用の切り替え（SpiderWeb_Core.cginc の中で、視線と光の向きを置き換える）
            #define SW_BAKE 1
            // 焼くときのシーンの太陽の向き（光の来る向き。ワールド）
            float4 _BakeLightDir;
            #define SW_BAKE_LIGHT_DIR normalize(_BakeLightDir.xyz)
            #include "../../Runtime/CGINC/SpiderWeb_Core.cginc"

            // 巣のレンダラーの Transform（面の向き・接線をワールドにする）。_BakeTangentSign は鏡写しの拡大で -1
            float4x4 _BakeObjectToWorld;
            float4x4 _BakeWorldToObject;
            float _BakeTangentSign;

            // xy = 焼く UV の範囲の最小、zw = 範囲の大きさ（C# が実測したメッシュの UV 範囲）
            float4 _BakeUVRect;

            // 頂点の位置を UV にする。GL.LoadOrtho の中で描くので、(0,0) が左下・(1,1) が右上
            web_v2f vertBake(web_appdata v)
            {
                web_v2f o;
                UNITY_INITIALIZE_OUTPUT(web_v2f, o);
                float2 p = (v.uv - _BakeUVRect.xy) / _BakeUVRect.zw;
                o.pos = UnityObjectToClipPos(float3(p, 0.0));
                o.uv = v.uv;
                // 扇形の巣の外周（_FanMeshRim のときだけ UV2.x を使う。巣のシェーダーと同じ）
                o.fanRim = (_FanMeshRim > 0.5) ? v.uv2.x : 0.0;
                // 面の向き・接線は巣のシェーダーと同じくワールドの向き（法線は逆転置で変換）
                o.worldPos = mul(_BakeObjectToWorld, float4(v.vertex.xyz, 1.0)).xyz;
                o.worldNormal = normalize(mul(v.normal, (float3x3)_BakeWorldToObject));
                o.worldTangent = float4(normalize(mul((float3x3)_BakeObjectToWorld, v.tangent.xyz)), v.tangent.w * _BakeTangentSign);
                return o;
            }

            float4 fragBake(web_v2f i) : SV_Target
            {
                // 表から見た扱い（facing = 1）。糸が無い画素は fragCore が discard する（透明のまま残る）
                fixed4 c = fragCore(i, 1.0, false);
                float3 rgb = saturate(c.rgb);
                // 8bit の sRGB テクスチャ（PNG）にするので、ここで sRGB に直して書く
                return float4(LinearToGammaSpaceExact(rgb.r), LinearToGammaSpaceExact(rgb.g),
                              LinearToGammaSpaceExact(rgb.b), saturate(c.a));
            }

            // ---- Pass 1: ミップ段の読み出し ----
            sampler2D _MainTex;
            float _BakeReadLod;
            float4 fragMipRead(v2f_img i) : SV_Target
            {
                // 出力の画素の中心 = そのミップ段のテクセルの中心なので、補間されずにそのままの値が出る
                return tex2Dlod(_MainTex, float4(i.uv, 0.0, _BakeReadLod));
            }
        ENDCG

        Pass
        {
            Name "BAKE"
            CGPROGRAM
            #pragma target 3.5
            #pragma vertex vertBake
            #pragma fragment fragBake
            ENDCG
        }

        Pass
        {
            Name "MIPREAD"
            CGPROGRAM
            #pragma target 3.5
            #pragma vertex vert_img
            #pragma fragment fragMipRead
            ENDCG
        }
    }
    Fallback Off
}

// =============================================================================
// SpiderWebGroundProjector.shader — Projector で床に蜘蛛の巣を投影 (VRChat / Built-in RP)
//
//  「地面に映る影（ブロブシャドウ）」と同じ、Unity 標準 Projector コンポーネント
//  方式のシェーダー。真下に向けた Projector が視錐台内のジオメトリを
//  このマテリアルで再描画し、テクスチャを床へ貼り付ける。
//
//  ★ なぜこの方式か（スクリーンスペース深度方式との違い）:
//     深度テクスチャから床を推定する方式は、左右の目が別々の深度バッファを
//     別々の角度から読むため（VRChat PC はマルチパスステレオ）、判定が
//     視点依存になり VR でチラつきや距離依存の破綻を起こした。
//     Projector 方式は「実際のメッシュ」を投影行列で再描画するだけで、
//     深度テクスチャを一切使わない。受け面の向きも頂点法線（実データ）で
//     判定するため、左右の目・ミラー・距離のすべてで完全に安定する。
//
//  ★ セットアップ:
//     1. 空の GameObject に Projector コンポーネントを追加し、真下に向ける
//        （Rotation X = 90）。プレイヤー追従オブジェクトの子でも、床の上の
//        固定位置でもよい。
//     2. Orthographic を ON にし、Orthographic Size で投影範囲（半径 m）を調整。
//        Near Clip 0.1 / Far Clip は床まで確実に届く距離（例 5）。
//     3. このシェーダーのマテリアルを Projector の Material に割り当てる。
//        Projector ごとに distinct なマテリアルにすること。
//     4. アバターに巣を映したくない場合は Projector の Ignore Layers で
//        Player 系レイヤーを除外する。
//
//  ★ 制約:
//     - 上向きの面（床）専用。天井に映したい場合は上向きの Projector を
//       もう1つ置く（_NormalYMin を負の向きで判定する改造が必要）。
//     - Projector は視錐台内のジオメトリを再描画するため、巨大な範囲へ
//       広げるほど描画コストが増える。範囲は必要最小限に。
// =============================================================================
Shader "mecaota/SpiderWebGroundProjector"
{
    Properties
    {
        [Header(Ground Web)]
        _GroundTex   ("投影テクスチャ 蜘蛛の巣など (Web Texture)", 2D) = "black" {}
        _GroundColor ("テクスチャの色 (Tint)", Color)                = (1, 1, 1, 1)

        [Header(Receiver Filter)]
        _NormalYMin  ("受ける面の法線Y下限 (Min Normal Y)", Range(0, 0.95)) = 0.5
        _EdgeFade    ("投影範囲の縁フェード (Edge Fade)", Range(0.01, 0.5)) = 0.15
        _FarFadeStart("遠端フェード開始 0-1 (Far Fade Start)", Range(0, 1)) = 0.7
    }

    SubShader
    {
        Tags { "Queue" = "Transparent" "RenderType" = "Transparent" }

        Pass
        {
            ZWrite Off
            ColorMask RGB
            Blend SrcAlpha OneMinusSrcAlpha
            // 受け面と同一平面を再描画するため、Z ファイティング防止に
            // 深度を手前へ僅かにオフセットする（ブロブシャドウの定石）
            Offset -1, -1

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment frag
            #pragma target   3.0
            #include "UnityCG.cginc"

            // Projector コンポーネントが供給する行列。
            //   unity_Projector     : 頂点 → 投影テクスチャ座標（xy/w が 0-1）
            //   unity_ProjectorClip : 頂点 → 投影方向の深度（x/w が near=0 → far=1）
            float4x4 unity_Projector;
            float4x4 unity_ProjectorClip;

            sampler2D _GroundTex;
            float4    _GroundTex_ST;
            fixed4    _GroundColor;
            float     _NormalYMin;
            float     _EdgeFade;
            float     _FarFadeStart;

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float4 pos         : SV_POSITION;
                float4 uvProj      : TEXCOORD0; // 投影テクスチャ座標
                float4 uvDepth     : TEXCOORD1; // 投影方向の深度
                float3 worldNormal : TEXCOORD2; // 受け面の実法線（ワールド）
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                o.pos         = UnityObjectToClipPos(v.vertex);
                o.uvProj      = mul(unity_Projector,     v.vertex);
                o.uvDepth     = mul(unity_ProjectorClip, v.vertex);
                o.worldNormal = UnityObjectToWorldNormal(v.normal);
                return o;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                // 投影テクスチャ座標（視錐台の中で 0-1）。外は描かない
                float2 uv = i.uvProj.xy / max(i.uvProj.w, 1e-5);
                if (any(uv < 0.0) || any(uv > 1.0)) discard;

                // 投影方向の深度（near=0 → far=1）。プロジェクタ後方は描かない
                float depth01 = i.uvDepth.x / max(i.uvDepth.w, 1e-5);
                if (depth01 < 0.0 || depth01 > 1.0) discard;

                // 受け面の向き: 実メッシュの頂点法線で「上向きの面（床）」だけに
                // 限定する。深度からの推定と違い左右の目で完全に一致するため、
                // VR でも判定がチラつかない。壁や体の正面に縦筋が伸びるのも防ぐ。
                float3 n = normalize(i.worldNormal);
                float mask = smoothstep(_NormalYMin, _NormalYMin + 0.1, n.y);

                // 投影範囲の縁をなだらかに消す（矩形の切れ目を見せない）
                float2 e    = min(uv, 1.0 - uv);
                float  edge = smoothstep(0.0, _EdgeFade, min(e.x, e.y));

                // 遠端（Far Clip 付近）もなだらかに消す
                float farFade = 1.0 - smoothstep(_FarFadeStart, 1.0, depth01);

                float2 tuv = uv * _GroundTex_ST.xy + _GroundTex_ST.zw;
                fixed4 col = tex2D(_GroundTex, tuv) * _GroundColor;
                col.a *= mask * edge * farFade;
                if (col.a <= 0.001) discard;
                return col;
            }
            ENDCG
        }
    }

    Fallback Off
}

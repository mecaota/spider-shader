// =============================================================================
// SpiderCocoonProjectorMask.shader — Projector で「繭の受け手」ビットをステンシルに書く (VRChat / Built-in RP)
//
//  色を一切描かないシェーダー（ColorMask 0）。Unity の Projector コンポーネントは
//  「視錐台に入ったレンダラーを、Projector のマテリアルでもう一度描く」部品なので、
//  Projector の Ignore Layers で Player / PlayerLocal / MirrorReflection 以外を除外すると、
//  アバターのメッシュだけがこのマテリアルで描き直される。そのとき、見えている画素の
//  ステンシルに受け手ビット（既定 32）を立てるのが唯一の仕事。
//
//  繭そのものを描くのは従来どおり SpiderCocoonDepthDecal（Pass 2/3）。そちらの
//  Stencil を Glue Stencil Ref 32 / ReadMask 240（受け手ビットあり・ジャック 128 と
//  糸の芯 64 と蜘蛛の体 16 なし。2026-10-14 に 224 から変更）にすると、
//  床・壁・木・ピックアップには構造的に繭が出なくなる。
//
//  ★ 誰のアバターか（_OwnerMode = 1）:
//     Projector のパスでは unity_ObjectToWorld が「描き直されている相手（受け手）」の
//     行列になる。その平行移動成分（受け手レンダラーの原点。アバターのメッシュは
//     ルート直下＝足元か、SkinnedMeshRenderer の rootBone＝腰にあることが多い）を
//     被害者のルート（足元）/ 腰と比べ、遠ければ頂点を縮退させて何も描かない。
//     装着物（骨の下の MeshRenderer）は、原点が被害者の頭・胸・両手・両足の点
//     （_OwnerPt0〜5、Udon が骨の位置を渡す）のどれかに近ければ受け入れる。
//     以前の「原点が Projector の視錐台の中なら受け入れる」判定は廃止した
//     （隣に立つ人のアバター全体が受け入れられてしまうため）。
//     判定はドロー単位で一定なので頂点シェーダーで行う（フラグメントを 1 つも出さない）。
//
//  ★ 糸の厚みぶんの膨張（_Inflate）:
//     デカールは輪郭の外 _GlueThickness 以内の背景画素にも糸を盛る（左右の脚が
//     つながって見える）。マスクも同じ幅だけ外へ広げるため、頂点を「カメラ側へ向けた
//     法線」方向に _Inflate だけ動かす。ZTest LEqual なので膨らませた面は実メッシュの
//     手前に来てテストに通り、手前の柱・壁・他人には負ける（そこには立たない）。
//     裏面（髪カード・スカートの内側）も同じ向きに膨らむよう Cull Off にしてある。
//
//  ★ セットアップ:
//     - Projector: Orthographic、被害者に追従（Udon）、Ignore Layers = Player 系以外すべて、
//       GameObject のレイヤーは Default（ミラーが映すレイヤー）。
//     - マテリアルは Projector ごとに distinct（共有すると全員が同じ所有者になる）。
//     - Udon は _OwnerRoot / _OwnerHips / _OwnerPt0〜5 を毎フレーム Material.SetVector するだけ
//       （Projector コンポーネントの設定は Udon から変えられない）。
//     - 描画順はマテリアルの Queue（Transparent-100 = 2900）で、アバター（2000〜2460）の後、
//       蜘蛛糸の芯（2990）・繭デカール（3000）の前に並ぶ想定。Frame Debugger で確認する。
//
//  ★ 制約:
//     - IgnoreProjector=True のアバターマテリアル（Standard Fade/Transparent 等）には立たない。
//     - Queue 3000 以降でステンシルを Replace するアバター部位ではビットが消える（その部位に繭が出ない）。
//     - LQ ミラー（Default を映さない反射マスク）の中では繭が出ない。
//     - Quest は深度デカール自体が非対応（PC 専用）。SPS-I では片目に出ない Unity の既知問題あり。
// =============================================================================
Shader "mecaota/SpiderCocoonProjectorMask"
{
    Properties
    {
        // ※ ShaderLab の属性引数は ASCII のみ（日本語を書くとパースエラー）。
        [Header(Receiver Stencil)]
        // デカールの Glue Stencil Ref と同じ値にする（既定 32。64 = 糸の芯、128 = ジャックは使えない）
        [IntRange] _StencilReceiverBit ("受け手ビット デカールの Glue Stencil Ref と同じ (Receiver Bit)", Range(0, 255)) = 32
        // デカールの糸の厚み（_GlueThickness）と同じ値にする
        _Inflate ("輪郭の外への膨張 m デカールの糸の厚みと同じ (Inflate)", Range(0, 0.2)) = 0.06

        [Header(Owner)]
        [Enum(Everyone In Frustum,0,Owner Only,1)] _OwnerMode ("対象 0=視錐台の全員 1=所有者のみ (Owner Mode)", Float) = 1
        _OwnerRoot ("所有者のルート xyz=位置 w=許容半径 m (Owner Root)", Vector) = (0, -9999, 0, 0)
        _OwnerHips ("所有者の腰 xyz=位置 w=許容半径 m (Owner Hips)", Vector) = (0, -9999, 0, 0)

        [Header(Owner Points)]
        // 所有者の頭・胸・左手・右手・左足・右足。装着物の原点がここに近ければ所有者扱い（w <= 0 で無効）
        _OwnerPt0 ("所有者の頭 xyz=位置 w=許容半径 m (Owner Point 0)", Vector) = (0, -9999, 0, 0)
        _OwnerPt1 ("所有者の胸 xyz=位置 w=許容半径 m (Owner Point 1)", Vector) = (0, -9999, 0, 0)
        _OwnerPt2 ("所有者の左手 xyz=位置 w=許容半径 m (Owner Point 2)", Vector) = (0, -9999, 0, 0)
        _OwnerPt3 ("所有者の右手 xyz=位置 w=許容半径 m (Owner Point 3)", Vector) = (0, -9999, 0, 0)
        _OwnerPt4 ("所有者の左足 xyz=位置 w=許容半径 m (Owner Point 4)", Vector) = (0, -9999, 0, 0)
        _OwnerPt5 ("所有者の右足 xyz=位置 w=許容半径 m (Owner Point 5)", Vector) = (0, -9999, 0, 0)

        [Header(Clip And Debug)]
        // 所有者モードでは体を丸ごと塗る（指先が切れない）ので既定 OFF。全員モードで範囲を絞るときだけ ON
        [ToggleUI] _FrustumClip ("視錐台の外を切る (Frustum Clip)", Float) = 0
        // ColorMask の値。0 = 色を書かない（本番）、15 = 緑で塗って確認（デバッグ）
        [Enum(Off,0,On,15)] _DebugView ("デバッグ表示 緑で塗る (Debug View)", Float) = 0
    }

    SubShader
    {
        // Queue 2900: アバターの不透明(2000)/カットアウト(2450)/lilToon 半透明(2460) の後、
        // 蜘蛛糸の芯(2990)・繭デカール(3000) の前。
        // DisableBatching: 動的バッチで unity_ObjectToWorld が単位行列になると原点判定が壊れる。
        Tags { "Queue" = "Transparent-100" "RenderType" = "Transparent" "IgnoreProjector" = "True" "DisableBatching" = "True" }

        Pass
        {
            Name "RECEIVERMASK"
            ColorMask [_DebugView]     // 既定 0 = 色を書かない。デバッグ時 15 = RGBA
            ZWrite    Off
            ZTest     LEqual           // 受け手の実深度と比較。手前の柱・壁・他人には負ける
            Cull      Off              // 両面ポリゴン（髪カード・スカートの裏）も対象
            Offset    -1, -1           // _Inflate = 0 でも同一面の Z ファイトで落ちない（ブロブシャドウの定石）
            Blend     SrcAlpha OneMinusSrcAlpha   // デバッグ表示用（ColorMask 0 では無関係）
            Stencil
            {
                Ref       [_StencilReceiverBit]
                WriteMask [_StencilReceiverBit]  // このビットだけ触る（64 / 128 は壊さない）
                ReadMask  0
                Comp      Always
                Pass      Replace
                ZFail     Keep                   // 深度テストに負けた画素には立てない
            }

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment frag
            #pragma target   3.0
            #pragma multi_compile_instancing
            #include "UnityCG.cginc"

            // Projector コンポーネントが受け手ごとに供給する行列（受け手のオブジェクト空間から）。
            //   unity_Projector     : 頂点 → Projector の 0..1 座標（xy/w）
            //   unity_ProjectorClip : 頂点 → Projector の near..far（x/w = 0..1）
            float4x4 unity_Projector;
            float4x4 unity_ProjectorClip;

            float  _Inflate;
            float  _OwnerMode;
            float  _FrustumClip;
            float4 _OwnerRoot;
            float4 _OwnerHips;
            float4 _OwnerPt0, _OwnerPt1, _OwnerPt2, _OwnerPt3, _OwnerPt4, _OwnerPt5;

            // 原点が点 pt（xyz = 位置、w = 半径）の半径内か。w <= 0 の点は無効（distance >= 0 なので常に false）
            bool SCPM_Near(float3 origin, float4 pt)
            {
                return distance(origin, pt.xyz) < pt.w;
            }

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float4 pos     : SV_POSITION;
                float4 uvProj  : TEXCOORD0;   // Projector の 0..1 座標（視錐台クリップ用）
                float4 uvDepth : TEXCOORD1;   // Projector の near..far
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // 受け手レンダラーの原点が所有者のものか。ドロー単位で一定なので頂点で判定する。
            bool SCPM_IsOwner()
            {
                if (_OwnerMode < 0.5) return true;
                float3 origin = unity_ObjectToWorld._m03_m13_m23;
                if (distance(origin, _OwnerRoot.xyz) < _OwnerRoot.w) return true;   // 足元（GetPosition）
                if (distance(origin, _OwnerHips.xyz) < _OwnerHips.w) return true;   // 腰（SMR の rootBone）
                // 装着物（手に持つ物・帽子・靴など）: 原点が頭・胸・両手・両足のどれかに近いか
                return SCPM_Near(origin, _OwnerPt0) || SCPM_Near(origin, _OwnerPt1)
                    || SCPM_Near(origin, _OwnerPt2) || SCPM_Near(origin, _OwnerPt3)
                    || SCPM_Near(origin, _OwnerPt4) || SCPM_Near(origin, _OwnerPt5);
            }

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                // 所有者でなければ縮退させてフラグメントを 1 つも出さない。
                // (2, 2, 2, 1) は x > w なので必ず視錐台の外でクリップされる（w = 0 は除算が未定義になる環境がある）
                if (!SCPM_IsOwner()) { o.pos = float4(2.0, 2.0, 2.0, 1.0); return o; }

                float3 wp = mul(unity_ObjectToWorld, v.vertex).xyz;
                float3 nw = UnityObjectToWorldNormal(v.normal);   // SkinnedMeshRenderer はスキニング済みの法線
                float  ln = length(nw);
                float3 n  = ln > 1e-6 ? nw / ln : float3(0.0, 0.0, 0.0);   // 法線の無いメッシュは膨らませない
                // 法線をカメラ側へ向けてから膨らませる（裏面も手前に来て ZTest に通る）。
                // _WorldSpaceCameraPos は VR の目ごと・ミラーカメラごとの値なので、どの視点でも正しい。
                float  s  = dot(n, _WorldSpaceCameraPos - wp) < 0.0 ? -1.0 : 1.0;
                wp += n * (s * _Inflate);

                o.pos     = mul(UNITY_MATRIX_VP, float4(wp, 1.0));
                o.uvProj  = mul(unity_Projector,     v.vertex);   // 視錐台の判定は膨張前の頂点で
                o.uvDepth = mul(unity_ProjectorClip, v.vertex);
                return o;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                if (_FrustumClip > 0.5)
                {
                    float2 uv = i.uvProj.xy / max(i.uvProj.w, 1e-5);
                    float  d  = i.uvDepth.x / max(i.uvDepth.w, 1e-5);
                    if (any(uv < 0.0) || any(uv > 1.0) || d < 0.0 || d > 1.0) discard;
                }
                // ColorMask 0 なら捨てられる。デバッグ表示（15）では緑で塗る
                return fixed4(0.1, 1.0, 0.3, 0.35);
            }
            ENDCG
        }
    }

    Fallback Off
}

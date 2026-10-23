// =============================================================================
// CocoonProjector.shader — 繭プロジェクターシェーダー（Projector で「繭の受け手」ビットをステンシルに書く）(VRChat / Built-in RP)
//
//  色を一切描かないシェーダー（ColorMask 0）。Unity の Projector コンポーネントは
//  「視錐台に入ったレンダラーを、Projector のマテリアルでもう一度描く」部品なので、
//  Projector の Ignore Layers で Player / PlayerLocal / MirrorReflection 以外を除外すると、
//  アバターのメッシュだけがこのマテリアルで描き直される。そのとき、見えている画素の
//  ステンシルに受け手ビット（既定 32）を立てるのが唯一の仕事。
//
//  繭そのものを描くのは従来どおり CocoonDecal（Pass 2/3）。そちらの
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
//  ★ 部位の選択（_PartHead 〜 _PartShinR、2026-10-23）:
//     繭を付ける部位を 11 個（頭・胸・腰・左右の上腕・左右の前腕と手・左右のもも・左右のすねと足）から選べる。
//     受け手の各画素の「体の位置」（膨張前の頂点のワールド座標）を、骨と骨を結ぶ部位ごとの円柱と比べ、
//     一番近い円柱（中に入っている深さが一番深い円柱）の部位が OFF なら印を立てない（discard）。
//     ON の部位の距離と OFF の部位の距離の差が _PartEdgeFray より小さい境目は、ノイズでほつれさせる。
//     骨の位置は Owner の xyz（腰・頭・胸・両手・両足）と Part Joints（首・肩・肘・股関節・膝）を使う。
//     全部 ON なら判定そのものを飛ばす（従来と同じ見た目・同じ負荷）。全部 OFF なら何も描かない。
//
//  ★ セットアップ:
//     - Projector: Orthographic、被害者に追従（Udon）、Ignore Layers = Player 系以外すべて、
//       GameObject のレイヤーは Default（ミラーが映すレイヤー）。
//     - マテリアルは Projector ごとに distinct（共有すると全員が同じ所有者になる）。
//     - Udon は _OwnerRoot / _OwnerHips / _OwnerPt0〜5 と Part Joints を毎フレーム Material.SetVector するだけ
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
Shader "mecaota/CocoonProjector"
{
    Properties
    {
        // ※ ShaderLab の属性引数は ASCII のみ（日本語を書くとパースエラー）。
        [Header(Receiver Stencil)]
        // デカールの Glue Stencil Ref と同じ値にする（既定 32。64 = 糸の芯、128 = ジャックは使えない）
        [IntRange] _StencilReceiverBit ("受け手ビット 繭デカールの Glue Stencil Ref と同じ (Receiver Bit)", Range(0, 255)) = 32
        // デカールの糸の厚み（_GlueThickness）と同じ値にする
        _Inflate ("輪郭の外への膨張 m 繭デカールの糸の厚みと同じ (Inflate)", Range(0, 0.2)) = 0.06

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

        [Header(Parts)]
        // 繭を付ける部位。OFF の部位には印を立てない（その部位に繭が出ない）。全部 ON で従来どおり体全体
        [ToggleUI] _PartHead ("部位 頭 (Head)", Float) = 1
        [ToggleUI] _PartChest ("部位 胸 (Chest)", Float) = 1
        [ToggleUI] _PartWaist ("部位 腰 (Waist)", Float) = 1
        [ToggleUI] _PartUpperArmL ("部位 左の上腕 (Left Upper Arm)", Float) = 1
        [ToggleUI] _PartForearmL ("部位 左の前腕と手 (Left Forearm And Hand)", Float) = 1
        [ToggleUI] _PartUpperArmR ("部位 右の上腕 (Right Upper Arm)", Float) = 1
        [ToggleUI] _PartForearmR ("部位 右の前腕と手 (Right Forearm And Hand)", Float) = 1
        [ToggleUI] _PartThighL ("部位 左のもも (Left Thigh)", Float) = 1
        [ToggleUI] _PartShinL ("部位 左のすねと足 (Left Shin And Foot)", Float) = 1
        [ToggleUI] _PartThighR ("部位 右のもも (Right Thigh)", Float) = 1
        [ToggleUI] _PartShinR ("部位 右のすねと足 (Right Shin And Foot)", Float) = 1
        // 部位ごとの円柱の太さに掛ける倍率（体格が標準から外れて境目がずれるときに調整する）
        _PartRadiusScale ("部位の太さの倍率 (Part Radius Scale)", Range(0.3, 3)) = 1
        // 部位の境目をほつれさせる幅 m。0 でまっすぐ切れる
        _PartEdgeFray ("部位の境目のほつれ幅 m (Part Edge Fray)", Range(0, 0.1)) = 0.02

        [Header(Part Joints)]
        // 部位の判定に使う関節の位置（xyz、w は使わない。Udon が骨の位置を渡す）。
        // 腰・頭・胸・両手・両足は Owner の xyz を使う（w は所有者の判定用。0 でも位置は部位の判定に使われる）
        _JointNeck ("関節 首 (Neck)", Vector) = (0, -9999, 0, 0)
        _JointUpperArmL ("関節 左肩 (Left Upper Arm)", Vector) = (0, -9999, 0, 0)
        _JointLowerArmL ("関節 左肘 (Left Lower Arm)", Vector) = (0, -9999, 0, 0)
        _JointUpperArmR ("関節 右肩 (Right Upper Arm)", Vector) = (0, -9999, 0, 0)
        _JointLowerArmR ("関節 右肘 (Right Lower Arm)", Vector) = (0, -9999, 0, 0)
        _JointUpperLegL ("関節 左の股関節 (Left Upper Leg)", Vector) = (0, -9999, 0, 0)
        _JointLowerLegL ("関節 左膝 (Left Lower Leg)", Vector) = (0, -9999, 0, 0)
        _JointUpperLegR ("関節 右の股関節 (Right Upper Leg)", Vector) = (0, -9999, 0, 0)
        _JointLowerLegR ("関節 右膝 (Right Lower Leg)", Vector) = (0, -9999, 0, 0)

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

            float  _PartHead, _PartChest, _PartWaist;
            float  _PartUpperArmL, _PartForearmL, _PartUpperArmR, _PartForearmR;
            float  _PartThighL, _PartShinL, _PartThighR, _PartShinR;
            float  _PartRadiusScale;
            float  _PartEdgeFray;
            float4 _JointNeck;
            float4 _JointUpperArmL, _JointLowerArmL, _JointUpperArmR, _JointLowerArmR;
            float4 _JointUpperLegL, _JointLowerLegL, _JointUpperLegR, _JointLowerLegR;

            // 原点が点 pt（xyz = 位置、w = 半径）の半径内か。w <= 0 の点は無効（distance >= 0 なので常に false）
            bool SCPM_Near(float3 origin, float4 pt)
            {
                return distance(origin, pt.xyz) < pt.w;
            }

            // ON の部位の数（0〜11）。ドロー単位で一定
            float SCPM_PartsOn()
            {
                return _PartHead + _PartChest + _PartWaist
                     + _PartUpperArmL + _PartForearmL + _PartUpperArmR + _PartForearmR
                     + _PartThighL + _PartShinL + _PartThighR + _PartShinR;
            }

            // 点 p から、a→b を軸とする半径 r の円柱（両端は平ら）までの符号付き距離 m。中なら負。
            // 端の骨が「どこでもない」（y < -9000）か長さ 0 なら、とても遠い値を返す（その部位にはならない）
            float SCPM_Cylinder(float3 p, float3 a, float3 b, float r)
            {
                if (min(a.y, b.y) < -9000.0) return 1e5;
                float3 ba   = b - a;
                float  baba = dot(ba, ba);
                if (baba < 1e-8) return 1e5;
                float3 pa     = p - a;
                float  t      = dot(pa, ba) / baba;                    // 軸に沿った位置（0 = a、1 = b）
                float  radial = length(pa - ba * t) - r;              // 円柱の側面から外への距離
                float  along  = (abs(t - 0.5) - 0.5) * sqrt(baba);    // 両端の面から外への距離
                return min(max(radial, along), 0.0) + length(max(float2(radial, along), 0.0));
            }

            // 部位の距離 d を、ON の部位の最小（dOn）か OFF の部位の最小（dOff）に入れる
            void SCPM_Part(float d, float on, inout float dOn, inout float dOff)
            {
                if (on > 0.5) dOn = min(dOn, d);
                else          dOff = min(dOff, d);
            }

            // 境目のほつれ用の 3D 値ノイズ（-1..1）
            float SCPM_Hash31(float3 q)
            {
                q = frac(q * 0.1031);
                q += dot(q, q.yzx + 33.33);
                return frac((q.x + q.y) * q.z);
            }
            float SCPM_Noise(float3 x)
            {
                float3 i = floor(x);
                float3 f = frac(x);
                f = f * f * (3.0 - 2.0 * f);
                float n000 = SCPM_Hash31(i);
                float n100 = SCPM_Hash31(i + float3(1, 0, 0));
                float n010 = SCPM_Hash31(i + float3(0, 1, 0));
                float n110 = SCPM_Hash31(i + float3(1, 1, 0));
                float n001 = SCPM_Hash31(i + float3(0, 0, 1));
                float n101 = SCPM_Hash31(i + float3(1, 0, 1));
                float n011 = SCPM_Hash31(i + float3(0, 1, 1));
                float n111 = SCPM_Hash31(i + float3(1, 1, 1));
                float n = lerp(lerp(lerp(n000, n100, f.x), lerp(n010, n110, f.x), f.y),
                               lerp(lerp(n001, n101, f.x), lerp(n011, n111, f.x), f.y), f.z);
                return n * 2.0 - 1.0;
            }

            // 体の位置 p が ON の部位に入るか。部位ごとの円柱のうち、p が一番深く入っている（距離が最小の）ものの部位で決める。
            // 円柱の太さは大人の体（腰〜首 0.45 m）の目安を、所有者の腰〜首の長さで伸び縮みさせる。
            bool SCPM_InSelectedParts(float3 p)
            {
                float3 hips  = _OwnerHips.xyz;
                float3 head  = _OwnerPt0.xyz;
                float3 chest = _OwnerPt1.xyz;
                float3 neck  = _JointNeck.xyz;
                float3 handL = _OwnerPt2.xyz, handR = _OwnerPt3.xyz;
                float3 footL = _OwnerPt4.xyz, footR = _OwnerPt5.xyz;
                float3 elbowL = _JointLowerArmL.xyz, elbowR = _JointLowerArmR.xyz;
                float3 kneeL  = _JointLowerLegL.xyz, kneeR  = _JointLowerLegR.xyz;

                float s = clamp(distance(hips, neck) / 0.45, 0.2, 5.0) * _PartRadiusScale;
                // 頭のてっぺん・指先・かかとには骨が無いので、一つ手前の骨からのばす
                float3 headTop  = head + (head - neck) * 2.0;
                float3 handTipL = handL + (handL - elbowL) * 0.7;
                float3 handTipR = handR + (handR - elbowR) * 0.7;
                float3 soleL    = footL + (footL - kneeL) * 0.15;
                float3 soleR    = footR + (footR - kneeR) * 0.15;
                // 腰は腰の骨より少し下（股関節の高さあたり）から。骨盤とお尻を腰に入れる
                float3 pelvis   = hips + (hips - chest) * 0.4;

                float dOn = 1e5, dOff = 1e5;
                SCPM_Part(SCPM_Cylinder(p, neck,   headTop, 0.10 * s), _PartHead,  dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, chest,  neck,    0.15 * s), _PartChest, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, pelvis, chest,   0.15 * s), _PartWaist, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, _JointUpperArmL.xyz, elbowL, 0.050 * s), _PartUpperArmL, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, elbowL, handL,               0.045 * s), _PartForearmL,  dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, handL, handTipL,             0.060 * s), _PartForearmL,  dOn, dOff);   // 手（親指の分だけ太く）
                SCPM_Part(SCPM_Cylinder(p, _JointUpperArmR.xyz, elbowR, 0.050 * s), _PartUpperArmR, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, elbowR, handR,               0.045 * s), _PartForearmR,  dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, handR, handTipR,             0.060 * s), _PartForearmR,  dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, _JointUpperLegL.xyz, kneeL,  0.080 * s), _PartThighL,    dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, kneeL, soleL,                0.055 * s), _PartShinL,     dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, _JointUpperLegR.xyz, kneeR,  0.080 * s), _PartThighR,    dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, kneeR, soleR,                0.055 * s), _PartShinR,     dOn, dOff);

                // 骨の位置が 1 つも来ていない（設定忘れ）ときは、部位で切らずに従来どおり体全体に印を立てる
                if (dOn > 1e4 && dOff > 1e4) return true;
                // ON の部位のほうが近ければ入る。差が _PartEdgeFray より小さい境目はノイズで出入りさせる。
                // ノイズは腰からの相対位置で引く（歩いても模様が体の上を流れない）
                float fray = _PartEdgeFray > 0.0 ? SCPM_Noise((p - hips) * (1.0 / 0.025)) * _PartEdgeFray : 0.0;
                return dOff - dOn > fray;
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
                float3 bodyPos : TEXCOORD2;   // 膨張前の体の位置（部位の判定用、ワールド座標）
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

                // 所有者でない・部位が全部 OFF なら縮退させてフラグメントを 1 つも出さない。
                // (2, 2, 2, 1) は x > w なので必ず視錐台の外でクリップされる（w = 0 は除算が未定義になる環境がある）
                if (!SCPM_IsOwner() || SCPM_PartsOn() < 0.5) { o.pos = float4(2.0, 2.0, 2.0, 1.0); return o; }

                float3 wp = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.bodyPos = wp;
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
                // 部位の選択。全部 ON（11）なら判定しない
                if (SCPM_PartsOn() < 10.5)
                {
                    if (!SCPM_InSelectedParts(i.bodyPos)) discard;
                }
                // ColorMask 0 なら捨てられる。デバッグ表示（15）では緑で塗る
                return fixed4(0.1, 1.0, 0.3, 0.35);
            }
            ENDCG
        }
    }

    Fallback Off
}

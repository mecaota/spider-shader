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
//  ★ 手前の物で切る（_OccluderCut、2026-10-23）:
//     膨らませた面は実メッシュより _Inflate だけ手前にあるので、そのすき間に入った物
//     （腰に置いた手、胸の前で組んだ腕、触れている他人の手など）にも印が立ってしまう。
//     そこで各画素で _CameraDepthTexture（繭デカールと同じ深度テクスチャ）を読み、
//     見えている面が「膨らませる前の体の位置」より _OccluderTolerance 以上手前なら印を立てない。
//     体の面そのもの（深さがほぼ同じ）と、輪郭の外の背景（深さが奥）には今までどおり立つ。
//     判定は Projector ごとに閉じているので、部位ごとに Projector を重ねても互いの印を消さない。
//     深度の読み方（VR の両目・ミラーの斜めの近クリップ面）は CocoonDecal と同じ書き方にしてある。
//
//  ★ 部位の選択（_PartHips 〜 _PartRightFoot、2026-10-23）:
//     繭を付ける部位を、Humanoid のボーンと同じ名前の 17 部位（Hips・Spine・Chest・Neck・Head、
//     左右の UpperArm・LowerArm・Hand、左右の UpperLeg・LowerLeg・Foot）から選べる。
//     各部位は「そのボーンから次のボーンまで」（Hips は骨盤から Spine まで、Hand は手首から指先まで、
//     Foot はかかとからつま先まで）。
//     受け手の各画素の「体の位置」（膨張前の頂点のワールド座標）を、骨と骨を結ぶ部位ごとの円柱と比べ、
//     一番近い円柱（中に入っている深さが一番深い円柱）の部位が OFF なら印を立てない（discard）。
//     境目は _PartEdgeFray の幅までノイズでほつれさせる。ほつれは ON の部位の外側へだけ広がるので、
//     隣り合う部位を別々の Projector（別々のマテリアル）で出しても、境目に穴が開かない。
//     ノイズは受け手のメッシュの UV で引く（肌に貼り付くので、腕を振っても体の向きを変えても模様が流れない）。
//     骨の位置は Owner の xyz（腰・頭・胸・両手・両足）と Part Joints（背骨・首・肩・肘・股関節・膝・つま先・中指の付け根）を使う。
//     来ていない骨（y = -9999）から作る点（頭のてっぺん・指先など）も「どこでもない」にし、その円柱は使わない。
//     ON の部位の円柱が 1 つも作れない（骨が足りない）ときは、部位で切らずに体全体に印を立てる。
//     全部 ON なら判定そのものを飛ばす（従来と同じ見た目・同じ負荷）。全部 OFF なら何も描かない。
//     Udon（SpiderCocoonProjectorMaskDriver）では TrackBone の配列で選ぶ（空 = 全身）。
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

        [Header(Occluder Cut)]
        // 体の面より手前にある物（腰に置いた手など）には印を立てない。深度テクスチャを読む（繭デカールと同じ）
        [ToggleUI] _OccluderCut ("手前の物で切る (Occluder Cut)", Float) = 1
        // 見えている面が体の面よりこの距離以上手前なら「手前の物」とみなす。手の厚み（2〜3 cm）より小さくする
        _OccluderTolerance ("手前とみなす距離 m (Occluder Tolerance)", Range(0, 0.05)) = 0.01

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
        // 繭を付ける部位（Humanoid のボーン名）。OFF の部位には印を立てない（その部位に繭が出ない）。全部 ON で従来どおり体全体
        [ToggleUI] _PartHips ("部位 骨盤 股関節から背骨の骨まで (Hips)", Float) = 1
        [ToggleUI] _PartSpine ("部位 お腹 背骨の骨から胸の骨まで (Spine)", Float) = 1
        [ToggleUI] _PartChest ("部位 胸 肩も含む (Chest)", Float) = 1
        [ToggleUI] _PartNeck ("部位 首 (Neck)", Float) = 1
        [ToggleUI] _PartHead ("部位 頭 (Head)", Float) = 1
        [ToggleUI] _PartLeftUpperArm ("部位 左の上腕 (Left Upper Arm)", Float) = 1
        [ToggleUI] _PartLeftLowerArm ("部位 左の前腕 (Left Lower Arm)", Float) = 1
        [ToggleUI] _PartLeftHand ("部位 左手 (Left Hand)", Float) = 1
        [ToggleUI] _PartRightUpperArm ("部位 右の上腕 (Right Upper Arm)", Float) = 1
        [ToggleUI] _PartRightLowerArm ("部位 右の前腕 (Right Lower Arm)", Float) = 1
        [ToggleUI] _PartRightHand ("部位 右手 (Right Hand)", Float) = 1
        [ToggleUI] _PartLeftUpperLeg ("部位 左のもも (Left Upper Leg)", Float) = 1
        [ToggleUI] _PartLeftLowerLeg ("部位 左のすね (Left Lower Leg)", Float) = 1
        [ToggleUI] _PartLeftFoot ("部位 左足 足首から先 (Left Foot)", Float) = 1
        [ToggleUI] _PartRightUpperLeg ("部位 右のもも (Right Upper Leg)", Float) = 1
        [ToggleUI] _PartRightLowerLeg ("部位 右のすね (Right Lower Leg)", Float) = 1
        [ToggleUI] _PartRightFoot ("部位 右足 足首から先 (Right Foot)", Float) = 1
        // 部位ごとの円柱の太さに掛ける倍率（体格が標準から外れて境目がずれるときに調整する）
        _PartRadiusScale ("部位の太さの倍率 (Part Radius Scale)", Range(0.3, 3)) = 1
        // 部位の境目をほつれさせる幅 m（ON の部位の外側へこの幅まで）。0 でまっすぐ切れる
        _PartEdgeFray ("部位の境目のほつれ幅 m (Part Edge Fray)", Range(0, 0.1)) = 0.02

        [Header(Part Joints)]
        // 部位の判定に使う骨の位置（xyz、w は使わない。Udon が骨の位置を渡す）。
        // 腰・頭・胸・両手・両足は Owner の xyz を使う（w は所有者の判定用。0 でも位置は部位の判定に使われる）
        _JointSpine ("骨 背骨 (Spine)", Vector) = (0, -9999, 0, 0)
        _JointNeck ("骨 首 (Neck)", Vector) = (0, -9999, 0, 0)
        _JointLeftUpperArm ("骨 左肩 (Left Upper Arm)", Vector) = (0, -9999, 0, 0)
        _JointLeftLowerArm ("骨 左肘 (Left Lower Arm)", Vector) = (0, -9999, 0, 0)
        _JointRightUpperArm ("骨 右肩 (Right Upper Arm)", Vector) = (0, -9999, 0, 0)
        _JointRightLowerArm ("骨 右肘 (Right Lower Arm)", Vector) = (0, -9999, 0, 0)
        _JointLeftUpperLeg ("骨 左の股関節 (Left Upper Leg)", Vector) = (0, -9999, 0, 0)
        _JointLeftLowerLeg ("骨 左膝 (Left Lower Leg)", Vector) = (0, -9999, 0, 0)
        _JointRightUpperLeg ("骨 右の股関節 (Right Upper Leg)", Vector) = (0, -9999, 0, 0)
        _JointRightLowerLeg ("骨 右膝 (Right Lower Leg)", Vector) = (0, -9999, 0, 0)
        // つま先の骨。無ければ足首から真下へ足の円柱をのばす
        _JointLeftToes ("骨 左のつま先 (Left Toes)", Vector) = (0, -9999, 0, 0)
        _JointRightToes ("骨 右のつま先 (Right Toes)", Vector) = (0, -9999, 0, 0)
        // 中指の付け根の骨（MiddleProximal）。手の円柱を手首から指の向きへのばす。無ければ前腕の向きへのばす
        _JointLeftFingers ("骨 左の中指の付け根 (Left Middle Proximal)", Vector) = (0, -9999, 0, 0)
        _JointRightFingers ("骨 右の中指の付け根 (Right Middle Proximal)", Vector) = (0, -9999, 0, 0)

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
            #pragma target   3.5           // 深度テクスチャを VR のシングルパスインスタンシング（テクスチャ配列）でも読むため
            #pragma multi_compile_instancing
            #include "UnityCG.cginc"

            // 手前の物で切る判定に使う深度テクスチャ（繭デカールと同じもの）
            UNITY_DECLARE_SCREENSPACE_TEXTURE(_CameraDepthTexture);

            // Projector コンポーネントが受け手ごとに供給する行列（受け手のオブジェクト空間から）。
            //   unity_Projector     : 頂点 → Projector の 0..1 座標（xy/w）
            //   unity_ProjectorClip : 頂点 → Projector の near..far（x/w = 0..1）
            float4x4 unity_Projector;
            float4x4 unity_ProjectorClip;

            float  _Inflate;
            float  _OccluderCut;
            float  _OccluderTolerance;
            float  _OwnerMode;
            float  _FrustumClip;
            float4 _OwnerRoot;
            float4 _OwnerHips;
            float4 _OwnerPt0, _OwnerPt1, _OwnerPt2, _OwnerPt3, _OwnerPt4, _OwnerPt5;

            float  _PartHips, _PartSpine, _PartChest, _PartNeck, _PartHead;
            float  _PartLeftUpperArm, _PartLeftLowerArm, _PartLeftHand;
            float  _PartRightUpperArm, _PartRightLowerArm, _PartRightHand;
            float  _PartLeftUpperLeg, _PartLeftLowerLeg, _PartLeftFoot;
            float  _PartRightUpperLeg, _PartRightLowerLeg, _PartRightFoot;
            float  _PartRadiusScale;
            float  _PartEdgeFray;
            float4 _JointSpine, _JointNeck;
            float4 _JointLeftUpperArm, _JointLeftLowerArm, _JointRightUpperArm, _JointRightLowerArm;
            float4 _JointLeftUpperLeg, _JointLeftLowerLeg, _JointRightUpperLeg, _JointRightLowerLeg;
            float4 _JointLeftToes, _JointRightToes;
            float4 _JointLeftFingers, _JointRightFingers;

            // 原点が点 pt（xyz = 位置、w = 半径）の半径内か。w <= 0 の点は無効（distance >= 0 なので常に false）
            bool SCPM_Near(float3 origin, float4 pt)
            {
                return distance(origin, pt.xyz) < pt.w;
            }

            // ON の部位の数（0〜17）。ドロー単位で一定
            float SCPM_PartsOn()
            {
                return _PartHips + _PartSpine + _PartChest + _PartNeck + _PartHead
                     + _PartLeftUpperArm + _PartLeftLowerArm + _PartLeftHand
                     + _PartRightUpperArm + _PartRightLowerArm + _PartRightHand
                     + _PartLeftUpperLeg + _PartLeftLowerLeg + _PartLeftFoot
                     + _PartRightUpperLeg + _PartRightLowerLeg + _PartRightFoot;
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

            // 骨の位置が来ているか（来ていない骨は y = -9999）
            bool SCPM_Valid(float3 v)
            {
                return v.y > -9000.0;
            }

            // 点 a から「b → a の向き」に、a と b の距離の k 倍だけ先へのばした点。
            // どちらかの骨が来ていなければ「どこでもない」を返す（その点を使う円柱は使われない）
            float3 SCPM_Extend(float3 a, float3 b, float k)
            {
                return (SCPM_Valid(a) && SCPM_Valid(b)) ? a + (a - b) * k : float3(0.0, -9999.0, 0.0);
            }

            // 足（足首から先）の円柱までの距離。つま先の骨があれば、かかとからつま先の先まで。
            // 無ければ足首から真下（すねの向き。膝も無ければワールドの下）へ少しのばす
            float SCPM_Foot(float3 p, float3 foot, float3 knee, float4 toes, float s)
            {
                if (!SCPM_Valid(toes.xyz))
                {
                    float3 sole = SCPM_Valid(knee) ? SCPM_Extend(foot, knee, 0.15) : foot - float3(0.0, 0.08 * s, 0.0);
                    return SCPM_Cylinder(p, foot, sole, 0.055 * s);
                }
                float3 heel   = SCPM_Extend(foot, toes.xyz, 0.35);
                float3 toeTip = SCPM_Extend(toes.xyz, foot, 0.3);
                return SCPM_Cylinder(p, heel, toeTip, 0.050 * s);
            }

            // 手（手首から指先）の円柱の先。中指の付け根があれば指の向きへ（手首を曲げても指を追う）、
            // 無ければ前腕の向きへのばす
            float3 SCPM_HandTip(float3 hand, float3 elbow, float4 fingers)
            {
                return SCPM_Valid(fingers.xyz) ? SCPM_Extend(fingers.xyz, hand, 1.0) : SCPM_Extend(hand, elbow, 0.7);
            }

            // 体の位置 p が ON の部位に入るか。部位ごとの円柱のうち、p が一番深く入っている（距離が最小の）ものの部位で決める。
            // 円柱の太さは大人の体（腰〜首 0.45 m）の目安を、所有者の腰〜首の長さで伸び縮みさせる。
            // uv は境目のほつれのノイズ用（受け手のメッシュの UV）
            bool SCPM_InSelectedParts(float3 p, float2 uv)
            {
                float3 hips  = _OwnerHips.xyz;
                float3 head  = _OwnerPt0.xyz;
                float3 chest = _OwnerPt1.xyz;
                float3 spine = _JointSpine.xyz;
                float3 neck  = _JointNeck.xyz;
                float3 handL = _OwnerPt2.xyz, handR = _OwnerPt3.xyz;
                float3 footL = _OwnerPt4.xyz, footR = _OwnerPt5.xyz;
                float3 elbowL = _JointLeftLowerArm.xyz, elbowR = _JointRightLowerArm.xyz;
                float3 kneeL  = _JointLeftLowerLeg.xyz, kneeR  = _JointRightLowerLeg.xyz;

                // 体の大きさ。腰〜首（無ければ腰〜頭）の長さを大人の目安と比べる。どちらも無ければ等倍
                float size = 1.0;
                if (SCPM_Valid(hips) && SCPM_Valid(neck))      size = distance(hips, neck) / 0.45;
                else if (SCPM_Valid(hips) && SCPM_Valid(head)) size = distance(hips, head) / 0.55;
                float s = clamp(size, 0.2, 5.0) * _PartRadiusScale;
                // 頭のてっぺん・指先には骨が無いので、一つ手前の骨からのばす（首が無ければワールドの上へ）
                float3 headTop  = SCPM_Valid(neck) ? SCPM_Extend(head, neck, 2.0) : head + float3(0.0, 0.15 * s, 0.0);
                float3 handTipL = SCPM_HandTip(handL, elbowL, _JointLeftFingers);
                float3 handTipR = SCPM_HandTip(handR, elbowR, _JointRightFingers);
                // 骨盤は腰の骨より少し下（股関節の高さあたり）から。お尻を Hips に入れる（胸が無ければ背骨から、どちらも無ければ腰の骨から）
                float3 pelvis   = SCPM_Valid(chest) ? SCPM_Extend(hips, chest, 0.4)
                                : (SCPM_Valid(spine) ? SCPM_Extend(hips, spine, 0.8) : hips);

                float dOn = 1e5, dOff = 1e5;
                SCPM_Part(SCPM_Cylinder(p, pelvis, spine,   0.15 * s), _PartHips,  dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, spine,  chest,   0.15 * s), _PartSpine, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, chest,  neck,    0.15 * s), _PartChest, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, neck,   head,    0.06 * s), _PartNeck,  dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, head,   headTop, 0.10 * s), _PartHead,  dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, _JointLeftUpperArm.xyz, elbowL, 0.050 * s), _PartLeftUpperArm, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, elbowL, handL,                  0.045 * s), _PartLeftLowerArm, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, handL,  handTipL,               0.060 * s), _PartLeftHand,     dOn, dOff);   // 親指の分だけ太く
                SCPM_Part(SCPM_Cylinder(p, _JointRightUpperArm.xyz, elbowR, 0.050 * s), _PartRightUpperArm, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, elbowR, handR,                   0.045 * s), _PartRightLowerArm, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, handR,  handTipR,                0.060 * s), _PartRightHand,     dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, _JointLeftUpperLeg.xyz, kneeL, 0.080 * s), _PartLeftUpperLeg, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, kneeL, footL,                  0.055 * s), _PartLeftLowerLeg, dOn, dOff);
                SCPM_Part(SCPM_Foot(p, footL, kneeL, _JointLeftToes, s),               _PartLeftFoot,     dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, _JointRightUpperLeg.xyz, kneeR, 0.080 * s), _PartRightUpperLeg, dOn, dOff);
                SCPM_Part(SCPM_Cylinder(p, kneeR, footR,                   0.055 * s), _PartRightLowerLeg, dOn, dOff);
                SCPM_Part(SCPM_Foot(p, footR, kneeR, _JointRightToes, s),               _PartRightFoot,     dOn, dOff);

                // ON の部位の円柱が 1 つも作れない（骨の位置が来ていない・足りない）ときは、部位で切らずに体全体に印を立てる
                if (dOn > 1e4) return true;
                // ON の部位のほうが近ければ入る。さらに OFF の部位へ 0〜_PartEdgeFray m だけノイズではみ出させて境目をほつれさせる
                // （外側へだけはみ出すので、隣の部位を別のマテリアルで出しても境目に隙間ができない）。
                // ノイズはメッシュの UV で引く（肌に貼り付くので、腕を振っても体の向きを変えても模様が流れない）
                float fray = _PartEdgeFray > 0.0 ? (SCPM_Noise(float3(uv * 64.0, 0.0)) * 0.5 + 0.5) * _PartEdgeFray : 0.0;
                return dOn - dOff < fray;
            }

            // 画面 UV（片目ローカル 0..1）から深度テクスチャの読み先へ。Single-Pass(double-wide) では横長テクスチャの片目側へ、
            // それ以外では恒等変換（CocoonDecal の SC_DEPTH_UV と同じ）
            #define SCPM_DEPTH_UV(uv) UnityStereoTransformScreenSpaceTex(uv)

            // 生の深度から視線方向の深さ m を戻す。ミラーカメラの斜めの近クリップ面（oblique 投影）でも正しい
            // （CocoonDecal の SC_EyeDepthOblique と同じ。通常の透視投影でも同じ値になる）
            float SCPM_EyeDepthOblique(float2 uv, float rawDepth)
            {
                float2 ndc = float2(uv.x * 2.0 - 1.0, (uv.y * 2.0 - 1.0) * _ProjectionParams.x);
                #if defined(UNITY_REVERSED_Z)
                    float ndcZ = rawDepth;
                #else
                    float ndcZ = rawDepth * 2.0 - 1.0;
                #endif
                float K = UNITY_MATRIX_P._m20 * (ndc.x + UNITY_MATRIX_P._m02) / UNITY_MATRIX_P._m00
                        + UNITY_MATRIX_P._m21 * (ndc.y + UNITY_MATRIX_P._m12) / UNITY_MATRIX_P._m11
                        - UNITY_MATRIX_P._m22;
                float denom = ndcZ - K;
                denom = (abs(denom) < 1e-8) ? 1e-8 : denom;
                return UNITY_MATRIX_P._m23 / denom;
            }

            // 見えている面が、体の位置 bodyPos より _OccluderTolerance 以上手前か（＝手前に別の物がある）。
            // 深度が無い画素（背景・空）と正射影のカメラでは false（今までどおり印を立てる）
            bool SCPM_Occluded(float4 screenPos, float3 bodyPos)
            {
                if (unity_OrthoParams.w > 0.5) return false;
                float2 uv  = screenPos.xy / max(screenPos.w, 1e-5);
                float  raw = UNITY_SAMPLE_SCREENSPACE_TEXTURE(_CameraDepthTexture, SCPM_DEPTH_UV(uv)).r;
                #if defined(UNITY_REVERSED_Z)
                    if (raw < 1e-7) return false;
                #else
                    if (raw > 1.0 - 1e-7) return false;
                #endif
                float sceneZ = SCPM_EyeDepthOblique(uv, raw);
                float bodyZ  = -mul(UNITY_MATRIX_V, float4(bodyPos, 1.0)).z;   // 体の位置の視線方向の深さ
                return sceneZ < bodyZ - _OccluderTolerance;
            }

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float2 uv     : TEXCOORD0;   // 部位の境目のほつれのノイズ用
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float4 pos     : SV_POSITION;
                float4 uvProj  : TEXCOORD0;   // Projector の 0..1 座標（視錐台クリップ用）
                float4 uvDepth : TEXCOORD1;   // Projector の near..far
                float3 bodyPos : TEXCOORD2;   // 膨張前の体の位置（部位の判定用、ワールド座標）
                float2 uv      : TEXCOORD3;   // 受け手のメッシュの UV（部位の境目のほつれ用）
                float4 screenPos : TEXCOORD4; // 画面の位置（手前の物で切る判定で深度テクスチャを読む）
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
                o.uv      = v.uv;
                float3 nw = UnityObjectToWorldNormal(v.normal);   // SkinnedMeshRenderer はスキニング済みの法線
                float  ln = length(nw);
                float3 n  = ln > 1e-6 ? nw / ln : float3(0.0, 0.0, 0.0);   // 法線の無いメッシュは膨らませない
                // 法線をカメラ側へ向けてから膨らませる（裏面も手前に来て ZTest に通る）。
                // _WorldSpaceCameraPos は VR の目ごと・ミラーカメラごとの値なので、どの視点でも正しい。
                float  s  = dot(n, _WorldSpaceCameraPos - wp) < 0.0 ? -1.0 : 1.0;
                wp += n * (s * _Inflate);

                o.pos     = mul(UNITY_MATRIX_VP, float4(wp, 1.0));
                // 非ステレオ版（片目ローカル 0..1）。ステレオの変換は深度を読む瞬間に SCPM_DEPTH_UV で 1 回だけ行う（CocoonDecal と同じ約束）
                o.screenPos = ComputeNonStereoScreenPos(o.pos);
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
                // 体の面より手前に別の物（腰に置いた手など）が見えている画素には立てない
                if (_OccluderCut > 0.5 && SCPM_Occluded(i.screenPos, i.bodyPos)) discard;
                // 部位の選択。全部 ON（17）なら判定しない
                if (SCPM_PartsOn() < 16.5)
                {
                    if (!SCPM_InSelectedParts(i.bodyPos, i.uv)) discard;
                }
                // ColorMask 0 なら捨てられる。デバッグ表示（15）では緑で塗る
                return fixed4(0.1, 1.0, 0.3, 0.35);
            }
            ENDCG
        }
    }

    Fallback Off
}

// =============================================================================
// SpiderWeb.shader — 蜘蛛の巣 シェーダー (VRChat / Built-in RP 専用)
//
//  平面（Quad など）の UV 空間に、縦糸（放射スポーク）と横糸（渦巻きリング）を
//  テクスチャ無しの数式（距離場）で描く。
//
//  ■ 描き方のしくみ（シェーダー入門向けの要約）
//    1. ピクセルごとに「一番近い縦糸までの距離」「一番近い横糸までの距離」を
//       計算する（これを距離場と呼ぶ）。距離が糸の太さ以下なら糸として塗る。
//    2. 縦糸はハブ（中心結節点）からの放射線。角度を縦糸の本数で等分し、
//       糸ごとにランダムな角度ずれ（揺らぎ）を足す。
//    3. 横糸は同心円。縦糸と縦糸の間で中心側へ「垂れ下がり」、区間ごとに
//       ランダムな垂れ幅（揺らぎ）を足す。
//
//  ■ 揺らぎで糸が切れない理由（過去バグの修正ポイント）
//    横糸の垂れ・揺らぎは「どの縦糸間の区間にいるか」で決まる。この区間の
//    切り替わり位置を『揺らぎでずれた後の縦糸の実際の位置』に厳密に合わせ、
//    さらに区間ごとの揺らぎ量に sagCurve（縦糸上で必ず 0 になる曲線）を
//    掛けてあるため、区間が切り替わる瞬間も横糸の半径は連続＝糸は繋がる。
//
//  ■ 中心結節点（ハブ）の偏心
//    外周円（UV中央・_WebRadius）と縦糸の終端（メッシュ端の位置）は固定の
//    まま、糸が集まるハブだけを _HubOffsetX/Y でずらせる。縦糸は
//    「ハブ→メッシュ端の固定終端」を結ぶ1本の直線のままで、終端を支点に
//    傾くだけ。実物の蜘蛛の巣のように、ハブに近い側はリング間隔が密に、
//    遠い側は疎になる。
//
//  ■ 縦糸の延長（係留糸）
//    _SpokeExtend を ON にすると、縦糸が外周円で止まらずメッシュの端まで
//    見える。OFF は同じ直線の外周円から外側を透明にしているだけなので、
//    ON/OFF やハブ操作で縦糸の向き・終端位置は変わらない（横糸は延長しない）。
//
//  ■ 質感・照明
//    糸の太さの乱雑性（SC_ThreadWidthMul）・断面の法線曲げ（SC_PerturbNormal）・
//    トゥーン陰影（SC_ShadeFiberToon）・リムライト（SC_RimLight）はすべて
//    繭シェーダー（SpiderCocoon）と共通の CGINC 実装を使用。
// =============================================================================
Shader "mecaota/SpiderWeb"
{
    Properties
    {
        // カテゴリ分けは CustomEditor（SpiderCocoonShaderGUI）が担当。
        // [Header] は標準インスペクタ向けのフォールバック表示。
        // ※ ShaderLab の属性引数は ASCII のみ（日本語を書くとパースエラー）。
        [Header(Web Shape)]
        _HubOffsetX ("中心結節点オフセット X (Hub Offset X)", Range(-0.9, 0.9)) = 0
        _HubOffsetY ("中心結節点オフセット Y (Hub Offset Y)", Range(-0.9, 0.9)) = 0
        _WebRadius ("巣の半径 (Web Radius)", Range(0.05, 0.7)) = 0.45
        _Thickness ("糸の太さ (Thread Width)", Range(0.0005, 0.02)) = 0.0025
        [IntRange] _RadialCount ("縦糸の本数 放射 (Radial Count)", Range(3, 36)) = 14
        [IntRange] _RingCount   ("横糸の本数 渦巻 (Ring Count)", Range(1, 30)) = 9
        _Sag ("垂れ下がり具合 (Sag)", Range(0, 1)) = 0.4
        [ToggleUI] _SpokeExtend ("縦糸をメッシュ端まで延長 (Extend Spokes)", Float) = 0

        [Header(Render State)]
        [ToggleUI] _HideBackFibers ("裏面の糸を隠す (Hide Back Fibers)", Float) = 0

        [Header(Irregularity)]
        _Irregular ("揺らぎの強さ (Irregularity)", Range(0, 1)) = 0.35
        _Seed      ("揺らぎシード (Seed)", Float) = 0

        [Header(Thread Design)]
        _ThreadColor     ("糸の色 (Thread Color)", Color) = (0.92, 0.96, 1.0, 1.0)
        _ThreadJitter    ("太さの乱雑性 (Thickness Jitter)", Range(0, 1)) = 0.3
        _ThreadFuzz      ("幅の揺らぎ (Fuzz Amount)", Range(0, 1)) = 0.2
        _ThreadFuzzScale ("揺らぎの細かさ (Fuzz Scale)", Float) = 8.0

        [Header(Toon Shading)]
        _ToonSteps      ("トゥーン段階数 (Toon Steps)", Range(1, 8)) = 3
        _ToonSmooth     ("段差の柔らかさ (Toon Smooth)", Range(0.001, 0.5)) = 0.05
        _ShadowColor    ("影色 (Shadow Tint)", Color) = (0.55, 0.55, 0.62, 1)
        _AmbientBoost   ("環境光の底上げ (Ambient Boost)", Range(0, 1)) = 0.35
        _LightInfluence ("シーン光の反映度 (Light Influence)", Range(0, 1)) = 0.5

        [Header(Rim Light)]
        _RimColor    ("リムライト色 (Rim Color)", Color) = (0.8, 0.9, 1.0, 1)
        _RimPower    ("リム幅 / 鋭さ (Rim Power)", Range(0.5, 16)) = 4.0
        _RimStrength ("リム強さ (Rim Strength)", Range(0, 4)) = 0.4
        _RimFloor    ("リムの下限/全体発光 (Rim Floor)", Range(0, 1)) = 0.25

        [Header(Fiber Shading)]
        _FiberNormalStrength ("糸断面の法線曲げ (Fiber Normal Strength)", Range(0, 1)) = 0.6
        _RimShadowColor      ("ファイバー縁の影色 (Fiber Edge Shadow)", Color) = (0.25, 0.22, 0.22, 1)
        _RimShadowStrength   ("ファイバー縁影の濃さ (Edge Shadow Strength)", Range(0, 1)) = 0.3
    }

    SubShader
    {
        Tags
        {
            "Queue"           = "Transparent"
            "RenderType"      = "Transparent"
            "IgnoreProjector" = "True"
            "VRCFallback"     = "Hidden"
        }

        Pass
        {
            Name "FORWARD"
            // ForwardBase タグ: メインライト・環境光を確実にバインドする
            Tags { "LightMode" = "ForwardBase" }

            Blend SrcAlpha OneMinusSrcAlpha
            // ZWrite On: 糸ピクセルが深度を書き（隙間は discard で書かない）、
            // スフィア等の立体メッシュでも自分自身の手前/奥の糸が正しい
            // 前後関係で描かれる（透明ソート狂いの対策）。
            ZWrite On
            Cull Off   // 両面描画（薄い巣は裏からも見える）

            CGPROGRAM
            #pragma vertex   vert
            #pragma fragment frag
            #pragma target   3.5
            #pragma multi_compile_instancing
            #pragma multi_compile_fwdbase

            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            // 糸の質感・照明は繭シェーダーと共通の実装を使う。
            // Common.cginc が共通 uniform（_ThreadColor 等）と appdata/v2f を宣言
            // するため、このシェーダーでは巣固有の uniform だけを追加宣言する。
            #include "CGINC/SpiderCocoon_Noise.cginc"
            #include "CGINC/SpiderCocoon_Common.cginc"
            #include "CGINC/SpiderCocoon_Thread.cginc"
            #include "CGINC/SpiderCocoon_Lighting.cginc"

            // ---- 巣固有の uniform（共通 uniform は Common.cginc 宣言を使用） ----
            float  _HubOffsetX;
            float  _HubOffsetY;
            float  _WebRadius;
            float  _Thickness;
            float  _RadialCount;
            float  _RingCount;
            float  _Sag;
            float  _SpokeExtend;
            float  _Irregular;
            float  _Seed;

            // 縦糸番号を 0..N-1 に折り返す（フロア剰余）。
            // 角度は atan2 で -180°..+180° として得られ、±180° の継ぎ目で
            // 番号が N ずれる。折り返しておくと継ぎ目の両側で同じ乱数になり、
            // 継ぎ目に縦の裂け目が出ない。
            float wrapId(float k, float n)
            {
                return k - n * floor(k / n);
            }

            // 縦糸 k の角度ジッター（セクター単位・最大 ±0.2）。
            // _Seed はハッシュ入力への加算で注入（旧実装とビット等価）。
            // saturate はスクリプト等から Range 外の値が入ってもセル判定の
            // 前提（|ジッター|<=0.2）を守るための保険。
            float spokeJitter(float k, float n)
            {
                return SC_Hash11Signed(wrapId(k, n) + _Seed * 37.219) * 0.2 * saturate(_Irregular);
            }

            // 角度 aVal（セクター単位）を挟む2本の縦糸（ジッター後の実位置）を求める。
            // ジッターで縦糸が動いた結果 aVal が区間外に出ていたら隣のセルへ
            // 1段ずらす（ジッター最大±0.2なので1段で必ず収まる）。
            // これで「セルの切り替わり位置＝実際の縦糸の位置」となり、
            // 垂れ・揺らぎがセル境界でジャンプしない（断裂バグ修正の核心）。
            void spokeCell(float aVal, float n, out float k0, out float a0, out float a1)
            {
                k0 = floor(aVal);
                a0 = k0 + spokeJitter(k0, n);
                a1 = (k0 + 1.0) + spokeJitter(k0 + 1.0, n);
                if (aVal < a0)
                {
                    a1 = a0; k0 -= 1.0; a0 = k0 + spokeJitter(k0, n);
                }
                else if (aVal >= a1)
                {
                    a0 = a1; k0 += 1.0; a1 = (k0 + 1.0) + spokeJitter(k0 + 1.0, n);
                }
            }

            // 距離場 dist を半幅 hw の線として描画（スクリーンスペースAA付き）。
            // aa は呼び出し側で fwidth（隣のピクセルとの値の差＝1pxぶんの変化量）
            // から算出して渡す。AA幅は糸幅を上限にクランプし、遠距離や斜め見で
            // 巣全体が広いにじみに化けるのを防ぐ（Thread.cginc と同じ流儀）。
            float lineAlpha(float dist, float hw, float aa)
            {
                aa = min(aa + 1e-5, hw);
                return 1.0 - smoothstep(hw - aa, hw + aa, dist);
            }

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);

                o.pos          = UnityObjectToClipPos(v.vertex);
                o.uv           = v.uv;
                o.worldPos     = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.worldNormal  = UnityObjectToWorldNormal(v.normal);
                o.worldTangent = float4(UnityObjectToWorldDir(v.tangent.xyz), v.tangent.w);
                return o;
            }

            fixed4 frag(v2f i, fixed facing : VFACE) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(i);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // 裏面（カメラに背を向けた面）を描かないオプション。
                // スフィア等の立体では奥側の糸が透けて見えるのを防げる
                if (_HideBackFibers > 0.5 && facing < 0.0) discard;

                // 本数は必ず整数に丸める。非整数だと ±180° の継ぎ目で乱数が
                // 食い違い、縦の裂け目が出る（スクリプトやアニメーションから
                // 非整数が入っても壊れないための保険）。
                float N  = max(3.0, round(_RadialCount));
                float NR = max(1.0, round(_RingCount));

                // ============ ハブ（中心結節点）の偏心幾何 ============
                // 外周円（UV中央・半径 _WebRadius）は固定のまま、糸が
                // 集まるハブだけを _HubOffset（半径に対する比）でずらす。
                float2 hubOfs = float2(_HubOffsetX, _HubOffsetY);
                float  hubLen = length(hubOfs);
                hubOfs *= (hubLen > 0.9) ? 0.9 / hubLen : 1.0;  // 斜め入力でも外周円の内側に制限
                float2 h = hubOfs * _WebRadius;                 // ハブ変位（UV空間）
                // ハブは必ずメッシュの内側に留める（縦糸終端の射影が壊れない保険）
                float hLen = length(h);
                h *= (hLen > 0.45) ? 0.45 / hLen : 1.0;

                float2 p   = (i.uv - 0.5) - h;                  // ハブ基準の座標（巣はUV中央）
                float  r   = length(p);
                float2 u   = (r > 1e-5) ? p / r : float2(1.0, 0.0);
                float2 radialDir = u;                           // ハブ→外向き

                // ハブから方向 u に伸ばした半直線が外周円に届くまでの距離 Redge。
                // 「|ハブ + 距離×u - 外周円中心| = 半径」の2次方程式の正の解で、
                // ハブが円の内側にある限り必ず正の実数になる。
                float uh    = dot(u, h);
                float Redge = -uh + sqrt(max(uh * uh + _WebRadius * _WebRadius - dot(h, h), 1e-6));
                // 正規化半径: ハブで0、外周円上で1。リングはこの空間に等間隔で
                // 並べるので、ハブが偏ると片側が密・反対側が疎になる（実巣と同じ）。
                float rho = r / Redge;

                // ============ 縦糸: 1本の直線・終端はメッシュ端に固定 ============
                // 縦糸 k は「ハブ → メッシュ端の固定終端 E_k」を結ぶ1本の直線。
                // E_k は UV 中央からセクター角 φ_k の方向へ伸ばした線がメッシュ端
                //（UV 正方形の縁）に当たる点で、ハブに依存しない。
                // → ハブを動かしても縦糸の終端は動かず、直線のまま終端を支点に
                //   傾くだけ。延長 OFF は外周円から外側を透明にするだけで、
                //   糸の形そのものは変わらない。
                //
                // セル判定は「ピクセルをハブからの視線でメッシュ端に射影した点の
                // 中心角」で行う。縦糸上のピクセルは必ず自分の終端 E_k に射影
                // される（中心角=φ_k）ため、垂れ・揺らぎの区間切替は厳密に
                // 縦糸の上で起こり、横糸が空中で切れることはない。
                float tqx = (abs(u.x) > 1e-6) ? ((u.x > 0.0 ? 0.5 : -0.5) - h.x) / u.x : 1e6;
                float tqy = (abs(u.y) > 1e-6) ? ((u.y > 0.0 ? 0.5 : -0.5) - h.y) / u.y : 1e6;
                float2 Q  = h + min(tqx, tqy) * u;              // メッシュ端への射影点
                float ang = atan2(Q.y, Q.x);                    // 射影点の中心角

                // ---- ジッター後の実位置でセル（区間）を確定 ----
                float sector = UNITY_TWO_PI / N;                // 1区間の角度
                float a = ang / sector;                         // 射影中心角（セクター単位）
                float k0, a0, a1;
                spokeCell(a, N, k0, a0, a1);
                float segId = wrapId(k0, N);                    // この区間のID

                // ---- 縦糸の距離場 ----
                // 隣り合う2本それぞれの固定終端 E（UV 中央から角度 φ の方向へ
                // 伸ばした線がメッシュ端に当たる点。max 成分での正規化が
                // 「原点から正方形の縁まで」の閉形式になる）
                float2 e0 = float2(cos(a0 * sector), sin(a0 * sector));
                float2 e1 = float2(cos(a1 * sector), sin(a1 * sector));
                float2 E0 = e0 * (0.5 / max(abs(e0.x), abs(e0.y)));
                float2 E1 = e1 * (0.5 / max(abs(e1.x), abs(e1.y)));
                // 走行方向: ハブ（原点）→ 固定終端。ハブ移動で変わるのはここだけ
                float2 dirA = normalize(E0 - h);
                float2 dirB = normalize(E1 - h);

                // ---- 縦糸間での正規化位置 t（垂れ下がりの基準） ----
                // 射影角 a ではなく「ハブから見た実際の角度」で取る。射影角だと
                // メッシュのかどを通る向きで角度の進み方が急変し、垂れた横糸の
                // 弧に折れ目が出るため（ハブ偏心時のみ現れる）。
                // 縦糸上では視線方向が dirA/dirB と一致して t=0/1 になるので、
                // 「sagCurve は縦糸上で厳密に0」の保証はそのまま維持される。
                float thA = atan2(dirA.y, dirA.x);
                float dAB = atan2(dirB.y, dirB.x) - thA;
                dAB += (dAB <= 0.0) ? UNITY_TWO_PI : 0.0;       // 0..2π に巻き戻し
                float dA  = atan2(u.y, u.x) - thA;
                dA  += (dA < 0.0) ? UNITY_TWO_PI : 0.0;
                float t        = saturate(dA / max(dAB, 1e-4));
                float sagCurve = 4.0 * t * (1.0 - t);            // 縦糸上0・中間1
                // 符号付き垂直距離（2Dの外積＝直線までの厳密距離）。
                // ハブより後ろ側（糸が無い側）ではハブまでの距離 r に切り替える
                //（dot=0 の境界では |外積|=r なので連続につながる）
                float sd0 = dirA.x * p.y - dirA.y * p.x;
                float sd1 = dirB.x * p.y - dirB.y * p.x;
                float dist0 = (dot(p, dirA) >= 0.0) ? abs(sd0) : r;
                float dist1 = (dot(p, dirB) >= 0.0) ? abs(sd1) : r;
                bool  nearLeft    = dist0 < dist1;
                float spokeK      = nearLeft ? k0 : (k0 + 1.0);  // 採用した縦糸の番号
                float spokeSigned = nearLeft ? sd0 : sd1;
                float spokeDist   = nearLeft ? dist0 : dist1;
                // 糸の横断方向（法線曲げ用）: 走行方向に対して垂直
                float2 spokeDir  = nearLeft ? dirA : dirB;
                float2 spokePerp = float2(-spokeDir.y, spokeDir.x);

                // 縦糸の太さ: 糸ごとの個体差＋長さ方向のうねり（繭と共通の式）。
                // 位置ジッターと同じ乱数にならないよう +57 で系列をずらす。
                // 糸に沿った座標は r（ハブからの距離）。
                float hwS = max(_Thickness * SC_ThreadWidthMul(wrapId(spokeK, N), _Seed * 37.219 + 57.0, r), 1e-4);

                // ============ 横糸: rho 空間に等間隔配置 → 垂れ＋揺らぎ ============
                // saturate は Range 外の値がスクリプト等から入っても
                // 除算や区間判定が壊れないための保険
                float sag = saturate(_Sag);
                float irr = saturate(_Irregular);
                float sp       = 1.0 / NR;                       // リング間隔（rho空間）
                float warpBase = 1.0 + sag * sagCurve;           // 垂れ: 区間中央ほど内側へ
                float kc       = round(rho * warpBase / sp);     // 最寄りリングの推定番号

                // 前後2本ずつの候補から最寄りを厳密に選ぶ（揺らぎ・垂れで
                // ずれても取りこぼさない。±2で全パラメータ範囲をカバー）
                float ringSigned = 1e6;
                float ringK      = 0.0;
                [unroll]
                for (int m = -2; m <= 2; m++)
                {
                    float k = kc + (float)m;
                    if (k > 0.5 && k < NR + 0.5)
                    {
                        // 最外周（k==NR）だけは乱数揺らぎを0にして、外周円に
                        // 沿った予測しやすい形に保つ（垂れ自体は残る）
                        float gateOut = (k < NR - 0.5) ? 1.0 : 0.0;
                        // リングごとの半径の揺らぎ
                        float rj = SC_Hash11Signed(k * 7.31 + 113.7 + _Seed * 37.219)
                                 * 0.3 * sp * irr * gateOut;
                        // 区間（リング×縦糸間）ごとの垂れ幅の揺らぎ。
                        // sagCurve 倍なので縦糸上では必ず0＝区間が替わる瞬間も
                        // リング半径は連続で、糸は縦糸の上で繋がったまま
                        float vs = SC_Hash11Signed(k * 127.1 + segId * 311.7 + _Seed * 37.219)
                                 * 0.5 * sp * irr * sagCurve * gateOut;
                        float rhoK = max((k * sp + rj) / warpBase - vs, 1e-4);
                        float ds   = (rho - rhoK) * Redge;       // UV空間の実距離に換算
                        if (abs(ds) < abs(ringSigned)) { ringSigned = ds; ringK = k; }
                    }
                }
                float ringDist = abs(ringSigned);

                // 横糸の太さ乱雑性。糸に沿った座標は角度だが、±180°の継ぎ目で
                // 値が飛ばないよう折り返して連続化する（繭デカールと同じ手法）
                float foldAng = abs(frac(ang / UNITY_TWO_PI + 0.5) - 0.5) * 2.0;
                float hwR = max(_Thickness * SC_ThreadWidthMul(ringK, _Seed * 37.219 + 157.0, foldAng), 1e-4);

                // ============ アルファ（糸の形） ============
                // fwidth = 隣のピクセルとの値の差 ≒ 1px ぶんの変化量。
                // 符号付き距離に対して取り、abs より滑らかなAA幅を得る
                float aaS = fwidth(spokeSigned);
                float aaR = fwidth(ringSigned);

                // 縦糸は外周円で終端（AA付き・最外周リングの幅の内側でフェード）。
                // _SpokeExtend が ON のときは終端せずメッシュの端まで伸ばす
                //（実物の巣を壁や枝に張るための「係留糸」の表現。横糸は延長しない）
                float over    = (rho - 1.0) * Redge;             // 外周からのはみ出し(UV)
                float aaO     = fwidth(over) + 1e-5;
                float outerMask = 1.0 - smoothstep(0.0, aaO + hwR, over);
                outerMask = max(outerMask, _SpokeExtend);

                float spokes = lineAlpha(spokeDist, hwS, aaS) * outerMask;
                float rings  = lineAlpha(ringDist,  hwR, aaR);
                float web    = max(spokes, rings);
                float alpha  = web * _ThreadColor.a;
                if (alpha <= 0.001) discard;                     // 隙間は描かない

                // ============ どちらの糸の上か → 断面法線・質感 ============
                // 太さが糸ごとに違うため、太さで正規化した距離で近い方を選ぶ
                bool   spokeWins = (spokeDist / hwS) < (ringDist / hwR);
                float  sgnDist = spokeWins ? spokeSigned : ringSigned;
                float2 latDir  = spokeWins ? spokePerp   : radialDir; // 糸の横断方向(UV)
                float  hwWin   = spokeWins ? hwS : hwR;
                float  aaWin   = spokeWins ? aaS : aaR;

                // 糸横断の符号付き位置 -1..+1。AA込みの「見かけの幅」で正規化する
                // ことで、1px 幅の細糸でも縁→中心の法線変化が潰れない
                //（旧実装の立体感が効かないバグの修正ポイント）
                float signedAcross = clamp(sgnDist / (hwWin + aaWin), -1.0, 1.0);
                float rimEdge      = saturate(abs(sgnDist) / hwWin);  // 縁ほど1

                // ---- 基底ベクトル（VFACE で裏面の法線を反転） ----
                float3 Nw = normalize(i.worldNormal) * sign(facing);
                float3 T  = normalize(i.worldTangent.xyz);
                float3 B  = normalize(cross(Nw, T)) * i.worldTangent.w * unity_WorldTransformParams.w;

                // ---- トゥーン陰影＋リムライト（繭シェーダーと共通の質感） ----
                // Directional Light が無いシーンでは _WorldSpaceLightPos0 が
                // 零ベクトルになり normalize が NaN を生む（Quest系で未定義動作）。
                // 微小な上向き成分を足して「真上からの光」にフォールバックする
                float3 L = normalize(_WorldSpaceLightPos0.xyz + float3(0.0, 1e-4, 0.0));
                float3 V = normalize(_WorldSpaceCameraPos - i.worldPos);
                float3 ambient = ShadeSH9(float4(Nw, 1.0)) + _AmbientBoost;

                float3 col = SC_ShadeFiberToon(Nw, T, B, latDir.x, latDir.y,
                                               signedAcross, rimEdge, L, ambient);
                col += SC_RimLight(Nw, V);

                return fixed4(col, alpha);
            }
            ENDCG
        }
    }

    Fallback Off
    CustomEditor "SpiderCocoonShaderGUI"
}

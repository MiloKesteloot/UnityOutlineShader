Shader "Hidden/Roystan/Outline Post Process"
{
    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.postprocessing/PostProcessing/Shaders/StdLib.hlsl"

            TEXTURE2D_SAMPLER2D(_MainTex, sampler_MainTex);
            TEXTURE2D_SAMPLER2D(_CameraNormalsTexture, sampler_CameraNormalsTexture);
            TEXTURE2D_SAMPLER2D(_CameraDepthTexture, sampler_CameraDepthTexture);

            float4 _MainTex_TexelSize;

            float _Scale;

            float _DepthThreshold;
            float _DepthNormalThreshold;
            float _DepthNormalThresholdScale;
            float _NormalThreshold;
            float _ColorTolerance;

            float4x4 _ClipToView;

            int _ColorCount;
            float4 _SurfaceColors[16];
            float4 _OutlineColors[16];

            // How close two depth values must be to treat the edge as a contact
            // edge (same plane) rather than a silhouette (one in front of another).
            // Tweak if needed — lower = stricter, higher = more edges treated as contact.
            #define DEPTH_CONTACT_THRESHOLD 0.001

            // Returns the priority index (0 = highest) of the closest registered color,
            // or -1 if no color is within _ColorTolerance.
            int GetColorPriority(float3 pixel)
            {
                int bestIndex = -1;
                float bestDist = _ColorTolerance;

                for (int i = 0; i < _ColorCount; i++)
                {
                    float dist = length(pixel - _SurfaceColors[i].rgb);
                    if (dist < bestDist)
                    {
                        bestDist = dist;
                        bestIndex = i;
                    }
                }

                return bestIndex;
            }

            float4 alphaBlend(float4 top, float4 bottom)
            {
                float3 color = (top.rgb * top.a) + (bottom.rgb * (1 - top.a));
                float alpha = top.a + bottom.a * (1 - top.a);
                return float4(color, alpha);
            }

            struct Varyings
            {
                float4 vertex : SV_POSITION;
                float2 texcoord : TEXCOORD0;
                float2 texcoordStereo : TEXCOORD1;
                float3 viewSpaceDir : TEXCOORD2;
            #if STEREO_INSTANCING_ENABLED
                uint stereoTargetEyeIndex : SV_RenderTargetArrayIndex;
            #endif
            };

            Varyings Vert(AttributesDefault v)
            {
                Varyings o;
                o.vertex = float4(v.vertex.xy, 0.0, 1.0);
                o.texcoord = TransformTriangleVertexToUV(v.vertex.xy);
                o.viewSpaceDir = mul(_ClipToView, o.vertex).xyz;

            #if UNITY_UV_STARTS_AT_TOP
                o.texcoord = o.texcoord * float2(1.0, -1.0) + float2(0.0, 1.0);
            #endif

                o.texcoordStereo = TransformStereoScreenSpaceTex(o.texcoord, 1.0);
                return o;
            }

            float4 Frag(Varyings i) : SV_Target
            {
                float halfScaleFloor = floor(_Scale * 0.5);
                float halfScaleCeil  = ceil(_Scale * 0.5);

                float2 bottomLeftUV  = i.texcoord - float2(_MainTex_TexelSize.x, _MainTex_TexelSize.y) * halfScaleFloor;
                float2 topRightUV    = i.texcoord + float2(_MainTex_TexelSize.x, _MainTex_TexelSize.y) * halfScaleCeil;
                float2 bottomRightUV = i.texcoord + float2( _MainTex_TexelSize.x * halfScaleCeil, -_MainTex_TexelSize.y * halfScaleFloor);
                float2 topLeftUV     = i.texcoord + float2(-_MainTex_TexelSize.x * halfScaleFloor,  _MainTex_TexelSize.y * halfScaleCeil);

                // --- Depth ---
                float depth0 = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, bottomLeftUV).r;
                float depth1 = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, topRightUV).r;
                float depth2 = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, bottomRightUV).r;
                float depth3 = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, topLeftUV).r;

                // --- Normals ---
                float3 normal0 = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, bottomLeftUV).rgb;
                float3 normal1 = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, topRightUV).rgb;
                float3 normal2 = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, bottomRightUV).rgb;
                float3 normal3 = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, topLeftUV).rgb;

                // --- Colors ---
                float4 color0 = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, bottomLeftUV);
                float4 color1 = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, topRightUV);
                float4 color2 = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, bottomRightUV);
                float4 color3 = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, topLeftUV);

                // --- Depth edge ---
                float3 viewNormal = normal0 * 2 - 1;
                float NdotV = 1 - dot(viewNormal, -i.viewSpaceDir);
                float normalThreshold01 = saturate((NdotV - _DepthNormalThreshold) / (1 - _DepthNormalThreshold));
                float normalThreshold   = normalThreshold01 * _DepthNormalThresholdScale + 1;
                float depthThreshold    = _DepthThreshold * depth0 * normalThreshold;

                float edgeDepth = sqrt(pow(depth1 - depth0, 2) + pow(depth3 - depth2, 2)) * 100;
                edgeDepth = edgeDepth > depthThreshold ? 1 : 0;

                // --- Normal edge ---
                float3 normalDiff0 = normal1 - normal0;
                float3 normalDiff1 = normal3 - normal2;
                float edgeNormal = sqrt(dot(normalDiff0, normalDiff0) + dot(normalDiff1, normalDiff1));
                edgeNormal = edgeNormal > _NormalThreshold ? 1 : 0;

                // --- Luminance edge ---
                float lum0 = dot(color0.rgb, float3(0.3, 0.59, 0.11));
                float lum1 = dot(color1.rgb, float3(0.3, 0.59, 0.11));
                float lum2 = dot(color2.rgb, float3(0.3, 0.59, 0.11));
                float lum3 = dot(color3.rgb, float3(0.3, 0.59, 0.11));
                float edgeLuminance = sqrt(pow(lum1 - lum0, 2) + pow(lum3 - lum2, 2));
                edgeLuminance = edgeLuminance > 0.5 ? 1 : 0;

                float edge = max(max(edgeDepth, edgeNormal), edgeLuminance);

                // ---------------------------------------------------------------
                // PRIORITY SELECTION
                //
                // For each Roberts cross diagonal pair (A: 0 vs 1, B: 2 vs 3):
                //
                //   - SILHOUETTE edge (depths differ): the closer sample is the
                //     surface we're on — use it exclusively. Depth wins, priority
                //     is irrelevant. A close green in front of a far red gets a
                //     dark green outline.
                //
                //   - CONTACT edge (depths similar): both surfaces are coplanar.
                //     Check both samples and let priority decide. A red touching
                //     a green gets a dark red outline (red = index 0).
                //
                // The winner across both pairs is the lowest priority index found.
                // ---------------------------------------------------------------

                int winnerIndex = -1;

                // --- Pair A: bottomLeft (0) vs topRight (1) ---
                float depthDiffA = abs(depth1 - depth0);
                if (depthDiffA < DEPTH_CONTACT_THRESHOLD)
                {
                    // Contact edge — priority decides between both samples
                    int pA0 = GetColorPriority(color0.rgb);
                    int pA1 = GetColorPriority(color1.rgb);
                    int bestA = -1;
                    if (pA0 >= 0) bestA = pA0;
                    if (pA1 >= 0 && (bestA < 0 || pA1 < bestA)) bestA = pA1;
                    if (bestA >= 0 && (winnerIndex < 0 || bestA < winnerIndex)) winnerIndex = bestA;
                }
                else
                {
                    // Silhouette edge — closer sample wins outright
                    float4 nearColor = (depth0 < depth1) ? color0 : color1;
                    int pA = GetColorPriority(nearColor.rgb);
                    if (pA >= 0 && (winnerIndex < 0 || pA < winnerIndex)) winnerIndex = pA;
                }

                // --- Pair B: bottomRight (2) vs topLeft (3) ---
                float depthDiffB = abs(depth3 - depth2);
                if (depthDiffB < DEPTH_CONTACT_THRESHOLD)
                {
                    // Contact edge — priority decides between both samples
                    int pB2 = GetColorPriority(color2.rgb);
                    int pB3 = GetColorPriority(color3.rgb);
                    int bestB = -1;
                    if (pB2 >= 0) bestB = pB2;
                    if (pB3 >= 0 && (bestB < 0 || pB3 < bestB)) bestB = pB3;
                    if (bestB >= 0 && (winnerIndex < 0 || bestB < winnerIndex)) winnerIndex = bestB;
                }
                else
                {
                    // Silhouette edge — closer sample wins outright
                    float4 nearColor = (depth2 < depth3) ? color2 : color3;
                    int pB = GetColorPriority(nearColor.rgb);
                    if (pB >= 0 && (winnerIndex < 0 || pB < winnerIndex)) winnerIndex = pB;
                }

                float4 sceneColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.texcoord);

                if (winnerIndex < 0 || edge < 0.5)
                    return sceneColor;

                float4 outlineColor = float4(_OutlineColors[winnerIndex].rgb, _OutlineColors[winnerIndex].a * edge);
                return alphaBlend(outlineColor, sceneColor);
            }
            ENDHLSL
        }
    }
}

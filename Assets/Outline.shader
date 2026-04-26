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
            float _DepthContactThreshold;

            float4x4 _ClipToView;

            int _ColorCount;
            float4 _SurfaceColors[32];
            float4 _OutlineColors[32];

            // NOTE: Color matching is performed in the color space of _MainTex (typically gamma
            // in Unity's built-in pipeline). _SurfaceColors set via the inspector are also
            // gamma-encoded in that case, so matching is consistent. If you switch to a linear
            // color space pipeline, verify that both sides agree on encoding.
            int GetColorPriority(float3 pixel)
            {
                int bestIndex = -1;
                float bestDist = _ColorTolerance;
                // Clamped to 32 to guard against misconfigured _ColorCount exceeding the array size.
                int count = min(_ColorCount, 32);
                for (int i = 0; i < count; i++)
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

                // Raw depth — no linearization. Values are near 0 for far objects,
                // slightly higher for near objects. Differences are small but real.
                float depth0 = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, bottomLeftUV).r;
                float depth1 = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, topRightUV).r;
                float depth2 = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, bottomRightUV).r;
                float depth3 = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, topLeftUV).r;

                float3 normal0 = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, bottomLeftUV).rgb;
                float3 normal1 = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, topRightUV).rgb;
                float3 normal2 = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, bottomRightUV).rgb;
                float3 normal3 = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, topLeftUV).rgb;

                float4 color0 = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, bottomLeftUV);
                float4 color1 = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, topRightUV);
                float4 color2 = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, bottomRightUV);
                float4 color3 = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, topLeftUV);

                // --- Depth edge ---
                // viewSpaceDir is interpolated across the triangle so it must be normalized
                // before use in the dot product, otherwise NdotV will be incorrect off-centre.
                float3 viewNormal = normal0 * 2 - 1;
                float NdotV = 1 - dot(viewNormal, -normalize(i.viewSpaceDir));
                // Guard against divide-by-zero when _DepthNormalThreshold is exactly 1.
                float depthNormalDenom = max(1 - _DepthNormalThreshold, 1e-5);
                float normalThreshold01 = saturate((NdotV - _DepthNormalThreshold) / depthNormalDenom);
                float normalThreshold   = normalThreshold01 * _DepthNormalThresholdScale + 1;
                float depthThreshold    = _DepthThreshold * depth0 * normalThreshold;
                float edgeDepth = sqrt(pow(depth1 - depth0, 2) + pow(depth3 - depth2, 2)) * 100;
                edgeDepth = edgeDepth > depthThreshold ? 1 : 0;

                // --- Normal edge ---
                // Normal differences are computed in [0,1] space; the *2-1 decode cancels out
                // in subtraction so this is equivalent to comparing in [-1,1] space.
                float3 normalDiff0 = normal1 - normal0;
                float3 normalDiff1 = normal3 - normal2;
                float edgeNormal = sqrt(dot(normalDiff0, normalDiff0) + dot(normalDiff1, normalDiff1));
                edgeNormal = edgeNormal > _NormalThreshold ? 1 : 0;

                // --- Color edge ---
                // Fires when two samples match different registered colors.
                // This catches edges like red vs blue that have similar luminance.
                int centerPriority = GetColorPriority(color0.rgb);
                int p1 = GetColorPriority(color1.rgb);
                int p2 = GetColorPriority(color2.rgb);
                int p3 = GetColorPriority(color3.rgb);
                float edgeColor = 0;
                if (centerPriority != p1 || centerPriority != p2 || centerPriority != p3)
                    edgeColor = 1;

                float edge = max(max(edgeDepth, edgeNormal), edgeColor);

                // ---------------------------------------------------------------
                // PRIORITY SELECTION
                //
                // Raw depth: higher value = closer to camera (reversed Z).
                // If depth spread exceeds _DepthContactThreshold = silhouette.
                // Silhouette: nearest sample (highest raw depth) wins outright.
                // Contact: lowest priority index across all samples wins.
                // ---------------------------------------------------------------

                float minDepth = min(min(depth0, depth1), min(depth2, depth3));
                float maxDepth = max(max(depth0, depth1), max(depth2, depth3));
                bool isSilhouette = (maxDepth - minDepth) > _DepthContactThreshold;

                int winnerIndex = -1;

                if (isSilhouette)
                {
                    // Highest raw depth value = nearest to camera.
                    // Reuse already-computed priorities rather than calling GetColorPriority again.
                    int p0 = centerPriority;
                    float nearestDepth = depth0;
                    winnerIndex = p0;
                    if (depth1 > nearestDepth) { nearestDepth = depth1; winnerIndex = p1; }
                    if (depth2 > nearestDepth) { nearestDepth = depth2; winnerIndex = p2; }
                    if (depth3 > nearestDepth) { nearestDepth = depth3; winnerIndex = p3; }
                }
                else
                {
                    // Contact edge — lowest priority index wins.
                    int p0 = centerPriority;
                    if (p0 >= 0) winnerIndex = p0;
                    if (p1 >= 0 && (winnerIndex < 0 || p1 < winnerIndex)) winnerIndex = p1;
                    if (p2 >= 0 && (winnerIndex < 0 || p2 < winnerIndex)) winnerIndex = p2;
                    if (p3 >= 0 && (winnerIndex < 0 || p3 < winnerIndex)) winnerIndex = p3;
                }

                float4 sceneColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.texcoord);

                if (winnerIndex < 0 || edge < 0.5)
                    return sceneColor;

                float4 outlineColor = _OutlineColors[winnerIndex];
                return alphaBlend(outlineColor, sceneColor);
            }
            ENDHLSL
        }
    }
}

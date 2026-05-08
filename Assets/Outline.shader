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
            // World-space depth added to the denominator before normalising.
            // 0 = pure relative (current behaviour). Larger values blend toward
            // absolute, stabilising edge detection for close-up geometry without
            // losing smooth-surface suppression at distance.
            float _DepthBlend;

            float4x4 _ClipToView;

            int _AliasCount;
            float4 _AliasColors[128]; // rgb = color to match against
            float4 _AliasIds[128];    // x = groupId, y = objectId, z = isIsolated (baked by C#)

            int _ObjectCount;
            float4 _ObjectMainColor[16];    // replacement color shown in final render
            float4 _ObjectOutlineColor[16]; // outline color drawn at edges

            // Converts raw non-linear depth to linear eye depth (world units).
            float LinearizeDepth(float rawDepth)
            {
                return 1.0 / (_ZBufferParams.z * rawDepth + _ZBufferParams.w);
            }

            // Returns the groupId, objectId, and isIsolated flag for the closest alias match
            // within _ColorTolerance, or -1/-1/0 when no alias matches.
            // groupId encodes (objectIndex * 3 + subGroup) for normal groups, or a unique
            // per-alias id for decorations. isIsolated=1 means decoration tier — edges only
            // fire against other decoration pixels, never against group A/B/C pixels.
            void GetAliasInfo(float3 pixel, out int groupId, out int objectId, out int isIsolated)
            {
                groupId    = -1;
                objectId   = -1;
                isIsolated = 0;
                float bestDist = _ColorTolerance;
                int count = min(_AliasCount, 128);
                for (int i = 0; i < count; i++)
                {
                    float dist = length(pixel - _AliasColors[i].rgb);
                    if (dist < bestDist)
                    {
                        bestDist   = dist;
                        groupId    = (int)round(_AliasIds[i].x);
                        objectId   = (int)round(_AliasIds[i].y);
                        isIsolated = (int)round(_AliasIds[i].z);
                    }
                }
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
                // 32 evenly spaced directions around a circle (every 11.25 degrees).
                static const int NUM_DIRS = 32;
                static const float2 RING_DIRS[32] =
                {
                    float2( 1.0000,  0.0000),
                    float2( 0.9808,  0.1951),
                    float2( 0.9239,  0.3827),
                    float2( 0.8315,  0.5556),
                    float2( 0.7071,  0.7071),
                    float2( 0.5556,  0.8315),
                    float2( 0.3827,  0.9239),
                    float2( 0.1951,  0.9808),
                    float2( 0.0000,  1.0000),
                    float2(-0.1951,  0.9808),
                    float2(-0.3827,  0.9239),
                    float2(-0.5556,  0.8315),
                    float2(-0.7071,  0.7071),
                    float2(-0.8315,  0.5556),
                    float2(-0.9239,  0.3827),
                    float2(-0.9808,  0.1951),
                    float2(-1.0000,  0.0000),
                    float2(-0.9808, -0.1951),
                    float2(-0.9239, -0.3827),
                    float2(-0.8315, -0.5556),
                    float2(-0.7071, -0.7071),
                    float2(-0.5556, -0.8315),
                    float2(-0.3827, -0.9239),
                    float2(-0.1951, -0.9808),
                    float2( 0.0000, -1.0000),
                    float2( 0.1951, -0.9808),
                    float2( 0.3827, -0.9239),
                    float2( 0.5556, -0.8315),
                    float2( 0.7071, -0.7071),
                    float2( 0.8315, -0.5556),
                    float2( 0.9239, -0.3827),
                    float2( 0.9808, -0.1951),
                };

                // Sample center depth first so we can linearize it before sampling the ring.
                float centerDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, i.texcoord).r;
                float linearCenterDepth = LinearizeDepth(centerDepth);

                // Scale the ring radius proportionally with screen height so outline thickness
                // stays visually constant when the window is resized.
                float pixelRadius = _Scale * (_ScreenParams.y / 1080.0);
                float2 texelRadius = _MainTex_TexelSize.xy * pixelRadius;

                float3 centerNormal = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, i.texcoord).rgb;
                float4 centerColor  = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.texcoord);

                float  ringDepth [32];
                float3 ringNormal[32];
                float4 ringColor [32];

                for (int s = 0; s < NUM_DIRS; s++)
                {
                    float2 uv = i.texcoord + RING_DIRS[s] * texelRadius;
                    ringDepth [s] = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, uv).r;
                    ringNormal[s] = SAMPLE_TEXTURE2D(_CameraNormalsTexture, sampler_CameraNormalsTexture, uv).rgb;
                    ringColor [s] = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, uv);
                }

                // Linearize ring depths; track min/max for priority selection below.
                float linearRingDepth[32];
                float linearMinDepth = linearCenterDepth;
                float linearMaxDepth = linearCenterDepth;
                for (int ld = 0; ld < NUM_DIRS; ld++)
                {
                    linearRingDepth[ld] = LinearizeDepth(ringDepth[ld]);
                    linearMinDepth = min(linearMinDepth, linearRingDepth[ld]);
                    linearMaxDepth = max(linearMaxDepth, linearRingDepth[ld]);
                }

                // --- Depth edge ---
                float3 viewNormal = centerNormal * 2 - 1;
                float NdotV = 1 - dot(viewNormal, -normalize(i.viewSpaceDir));
                float depthNormalDenom = max(1 - _DepthNormalThreshold, 1e-5);
                float normalThreshold01 = saturate((NdotV - _DepthNormalThreshold) / depthNormalDenom);
                float normalThreshold   = normalThreshold01 * _DepthNormalThresholdScale + 1;

                // Walk outward in small steps per direction and check each step-to-step
                // relative linear depth difference. Using a ratio (delta / prev) makes the
                // threshold distance-independent.
                static const int DEPTH_STEPS = 5;
                float edgeDepth = 0;
                float stepMinLinear = linearCenterDepth;
                float stepMaxLinear = linearCenterDepth;
                [unroll]
                for (int d = 0; d < NUM_DIRS; d++)
                {
                    float prevLinear = linearCenterDepth;
                    [unroll]
                    for (int step = 1; step < DEPTH_STEPS; step++)
                    {
                        float t = (float)step / (float)DEPTH_STEPS;
                        float2 uv = i.texcoord + RING_DIRS[d] * texelRadius * t;
                        float stepRaw    = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_CameraDepthTexture, uv).r;
                        float stepLinear = LinearizeDepth(stepRaw);
                        if (abs(stepLinear - prevLinear) / (prevLinear + _DepthBlend) > _DepthThreshold * normalThreshold)
                            edgeDepth = 1;
                        stepMinLinear = min(stepMinLinear, stepLinear);
                        stepMaxLinear = max(stepMaxLinear, stepLinear);
                        prevLinear = stepLinear;
                    }
                    float ringLinear = linearRingDepth[d];
                    if (abs(ringLinear - prevLinear) / (prevLinear + _DepthBlend) > _DepthThreshold * normalThreshold)
                        edgeDepth = 1;
                }
                // Merge step-sample extremes into the ring extremes for a complete depth range.
                float allMinDepth = min(linearMinDepth, stepMinLinear);
                float allMaxDepth = max(linearMaxDepth, stepMaxLinear);

                // --- Normal edge ---
                float maxNormalDiff = 0;
                for (int n = 0; n < NUM_DIRS; n++)
                {
                    float3 diff = ringNormal[n] - centerNormal;
                    maxNormalDiff = max(maxNormalDiff, dot(diff, diff));
                }
                float edgeNormal = sqrt(maxNormalDiff) > _NormalThreshold ? 1 : 0;

                // --- Alias lookup ---
                int centerGroupId, centerObjectId, centerIsolated;
                GetAliasInfo(centerColor.rgb, centerGroupId, centerObjectId, centerIsolated);

                int ringGroupId  [32];
                int ringObjectId [32];
                int ringIsolated [32];
                for (int c = 0; c < NUM_DIRS; c++)
                    GetAliasInfo(ringColor[c].rgb, ringGroupId[c], ringObjectId[c], ringIsolated[c]);

                // --- Color edge ---
                // Fires when center and ring belong to different alias groups (different groupIds)
                // AND are in the same isolation tier. This prevents decoration pixels from
                // producing edges against group A/B/C pixels (and vice versa).
                float edgeColor = 0;
                for (int e = 0; e < NUM_DIRS; e++)
                {
                    if (centerGroupId >= 0 && ringGroupId[e] >= 0
                        && ringGroupId[e]   != centerGroupId
                        && ringIsolated[e]  == centerIsolated)
                    {
                        edgeColor = 1;
                        break;
                    }
                }

                float edge = max(max(edgeDepth, edgeNormal), edgeColor);

                // ---------------------------------------------------------------
                // PRIORITY SELECTION
                //
                // If linear depth spread exceeds _DepthContactThreshold = silhouette.
                // Silhouette: nearest sample (smallest linear depth) wins outright.
                // Contact:    lowest objectId across all samples wins.
                // ---------------------------------------------------------------
                bool isSilhouette = (allMaxDepth / max(allMinDepth, 1e-5)) > (1.0 + _DepthContactThreshold);

                int winnerObjectId = -1;

                if (isSilhouette)
                {
                    // Nearest-to-camera wins, but only if it is meaningfully closer than
                    // the center. Same-depth neighbours must not steal the win.
                    float nearestLinearDepth = linearCenterDepth;
                    winnerObjectId = centerObjectId;
                    bool foundValidNearSample = false;
                    for (int si = 0; si < NUM_DIRS; si++)
                    {
                        bool meaningfullyCloser = (linearCenterDepth / max(linearRingDepth[si], 1e-5)) > (1.0 + _DepthContactThreshold);
                        if (meaningfullyCloser && ringObjectId[si] >= 0 && linearRingDepth[si] < nearestLinearDepth)
                        {
                            nearestLinearDepth = linearRingDepth[si];
                            winnerObjectId     = ringObjectId[si];
                            foundValidNearSample = true;
                        }
                    }
                    // If no registered near sample won, check whether any surface (including
                    // step samples) is closer than us. If so, suppress — we are background
                    // looking at unregistered foreground geometry.
                    if (!foundValidNearSample)
                    {
                        if ((linearCenterDepth / max(allMinDepth, 1e-5)) > (1.0 + _DepthContactThreshold))
                            winnerObjectId = -1;
                    }
                }
                else
                {
                    // Contact edge — lowest objectId wins for a uniform outline colour
                    // along the boundary.
                    if (centerObjectId >= 0) winnerObjectId = centerObjectId;
                    for (int ci = 0; ci < NUM_DIRS; ci++)
                    {
                        if (ringObjectId[ci] >= 0 && (winnerObjectId < 0 || ringObjectId[ci] < winnerObjectId))
                            winnerObjectId = ringObjectId[ci];
                    }
                }

                // Replace registered non-decoration pixels with their object's main color.
                // Decoration pixels keep their raw color so each decoration shade stays visible.
                float4 displayColor = centerColor;
                if (centerObjectId >= 0 && centerIsolated == 0)
                    displayColor = _ObjectMainColor[centerObjectId];

                if (winnerObjectId < 0 || edge < 0.5)
                    return displayColor;

                float4 outlineColor = _ObjectOutlineColor[winnerObjectId];
                return alphaBlend(outlineColor, displayColor);
            }
            ENDHLSL
        }
    }
}

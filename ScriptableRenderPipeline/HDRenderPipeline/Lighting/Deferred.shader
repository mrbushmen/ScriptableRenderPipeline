Shader "Hidden/HDRenderPipeline/Deferred"
{
    Properties
    {
        // We need to be able to control the blend mode for deferred shader in case we do multiple pass
        _SrcBlend("", Float) = 1
        _DstBlend("", Float) = 1

        _StencilRef("", Int) = 0
        _StencilCmp("", Int) = 3
    }

    SubShader
    {
        Pass
        {
            Stencil
            {
                Ref  [_StencilRef]
                Comp [_StencilCmp]
                Pass Keep
            }

            ZWrite Off
            ZTest  Always
            Blend [_SrcBlend] [_DstBlend], One Zero
            Cull Off

            HLSLPROGRAM
            #pragma target 4.5
            #pragma only_renderers d3d11 ps4 vulkan metal // TEMP: until we go further in dev
            // #pragma enable_d3d11_debug_symbols

            #pragma vertex Vert
            #pragma fragment Frag

            // Chose supported lighting architecture in case of deferred rendering
            #pragma multi_compile LIGHTLOOP_SINGLE_PASS LIGHTLOOP_TILE_PASS

            // Split lighting is utilized during the SSS pass.
            #pragma multi_compile _ OUTPUT_SPLIT_LIGHTING
            #pragma multi_compile _ SHADOWS_SHADOWMASK
            #pragma multi_compile _ DEBUG_DISPLAY

            #define USE_FPTL_LIGHTLIST // deferred opaque always use FPTL

            //-------------------------------------------------------------------------------------
            // Include
            //-------------------------------------------------------------------------------------

            #include "ShaderLibrary/Common.hlsl"
            #include "../Debug/DebugDisplay.hlsl"

            // Note: We have fix as guidelines that we have only one deferred material (with control of GBuffer enabled). Mean a users that add a new
            // deferred material must replace the old one here. If in the future we want to support multiple layout (cause a lot of consistency problem),
            // the deferred shader will require to use multicompile.
            #define UNITY_MATERIAL_LIT // Need to be define before including Material.hlsl
            #include "../ShaderVariables.hlsl"
            #include "../Lighting/Lighting.hlsl" // This include Material.hlsl

            //-------------------------------------------------------------------------------------
            // variable declaration
            //-------------------------------------------------------------------------------------

            #ifdef SHADOWS_SHADOWMASK
            TEXTURE2D(_ShadowMaskTexture);
            #endif

            struct Attributes
            {
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            struct Outputs
            {
            #ifdef OUTPUT_SPLIT_LIGHTING
                float4 specularLighting : SV_Target0;
                float3 diffuseLighting  : SV_Target1;
            #else
                float4 combinedLighting : SV_Target0;
            #endif
            };

            Varyings Vert(Attributes input)
            {
                Varyings output;
                output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID);
                return output;
            }

            Outputs Frag(Varyings input)
            {
                // This need to stay in sync with deferred.compute

                // input.positionCS is SV_Position
                PositionInputs posInput = GetPositionInput(input.positionCS.xy, _ScreenSize.zw, uint2(input.positionCS.xy) / GetTileSize());
                float depth = LOAD_TEXTURE2D(_MainDepthTexture, posInput.positionSS).x;
                UpdatePositionInput(depth, UNITY_MATRIX_I_VP, UNITY_MATRIX_VP, posInput);
                float3 V = GetWorldSpaceNormalizeViewDir(posInput.positionWS);

                BSDFData bsdfData;
                BakeLightingData bakeLightingData;
                DECODE_FROM_GBUFFER(posInput.positionSS, MATERIAL_FEATURE_MASK_FLAGS, bsdfData, bakeLightingData.bakeDiffuseLighting);
                #ifdef SHADOWS_SHADOWMASK
                DecodeShadowMask(LOAD_TEXTURE2D(_ShadowMaskTexture, posInput.positionSS), bakeLightingData.bakeShadowMask);
                #endif

                PreLightData preLightData = GetPreLightData(V, posInput, bsdfData);

                float3 diffuseLighting;
                float3 specularLighting;
                LightLoop(V, posInput, preLightData, bsdfData, bakeLightingData, LIGHT_FEATURE_MASK_FLAGS_OPAQUE, diffuseLighting, specularLighting);

                Outputs outputs;

            #ifdef OUTPUT_SPLIT_LIGHTING
                if (_EnableSSSAndTransmission != 0)
                {
                    outputs.specularLighting = float4(specularLighting, 1.0);
                    outputs.diffuseLighting  = TagLightingForSSS(diffuseLighting);
                }
                else
                {
                    outputs.specularLighting = float4(diffuseLighting + specularLighting, 1.0);
                    outputs.diffuseLighting  = 0;
                }
            #else
                outputs.combinedLighting = float4(diffuseLighting + specularLighting, 1.0);
            #endif

                return outputs;
            }

        ENDHLSL
        }

    }
    Fallback Off
}

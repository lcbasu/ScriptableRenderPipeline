//-----------------------------------------------------------------------------
// SurfaceData and BSDFData
//-----------------------------------------------------------------------------

// SurfaceData is define in Lit.cs which generate Lit.cs.hlsl
#include "Lit.cs.hlsl"
#include "SubsurfaceScatteringSettings.cs.hlsl"

// Define refraction keyword helpers
#define HAS_REFRACTION (defined(_REFRACTION_PLANE) || defined(_REFRACTION_SPHERE))
#if HAS_REFRACTION
# include "../../../Core/ShaderLibrary/Refraction.hlsl"

# if defined(_REFRACTION_PLANE)
#  define REFRACTION_MODEL(V, posInputs, bsdfData) RefractionModelPlane(V, posInputs.positionWS, bsdfData.normalWS, bsdfData.ior, bsdfData.thickness)
# elif defined(_REFRACTION_SPHERE)
#  define REFRACTION_MODEL(V, posInputs, bsdfData) RefractionModelSphere(V, posInputs.positionWS, bsdfData.normalWS, bsdfData.ior, bsdfData.thickness)
# endif
#endif

// In case we pack data uint16 buffer we need to change the output render target format to uint16
// TODO: Is there a way to automate these output type based on the format declare in lit.cs ?
#if SHADEROPTIONS_PACK_GBUFFER_IN_U16
#define GBufferType0 uint4
#define GBufferType1 uint4

// TODO: How to abstract that ? We would like to avoid this PS4 test here
#ifdef SHADER_API_PSSL
// On PS4 we need to specify manually the format of the output render target, output type is not enough
#pragma PSSL_target_output_format(target 0 FMT_UINT16_ABGR)
#pragma PSSL_target_output_format(target 1 FMT_UINT16_ABGR)
#endif

#else
#define GBufferType0 float4
#define GBufferType1 float4
#define GBufferType2 float4
#define GBufferType3 float4
#endif

// Reference Lambert diffuse / GGX Specular for IBL and area lights
#ifdef HAS_LIGHTLOOP // Both reference define below need to be define only if LightLoop is present, else we get a compile error
// #define LIT_DISPLAY_REFERENCE_AREA
// #define LIT_DISPLAY_REFERENCE_IBL
#endif
// Use Lambert diffuse instead of Disney diffuse
// #define LIT_DIFFUSE_LAMBERT_BRDF
// Use optimization of Precomputing LambdaV
// TODO: Test if this is a win
// #define LIT_USE_BSDF_PRE_LAMBDAV
#define LIT_USE_GGX_ENERGY_COMPENSATION

// Sampler use by area light, gaussian pyramid, ambient occlusion etc...
SamplerState s_linear_clamp_sampler;
SamplerState s_trilinear_clamp_sampler;

// Rough refraction texture
// Color pyramid (width, height, lodcount, Unused)
TEXTURE2D(_GaussianPyramidColorTexture);
// Depth pyramid (width, height, lodcount, Unused)
TEXTURE2D(_PyramidDepthTexture);

CBUFFER_START(UnityGaussianPyramidParameters)
float4 _GaussianPyramidColorMipSize;
float4 _PyramidDepthMipSize;
CBUFFER_END

// Ambient occlusion texture
TEXTURE2D(_AmbientOcclusionTexture);

CBUFFER_START(UnityAmbientOcclusionParameters)
float4 _AmbientOcclusionParam; // xyz occlusion color, w directLightStrenght
CBUFFER_END

// Area light textures
// TODO: This one should be set into a constant Buffer at pass frequency (with _Screensize)
TEXTURE2D(_PreIntegratedFGD);
TEXTURE2D_ARRAY(_LtcData); // We pack the 3 Ltc data inside a texture array
#define LTC_GGX_MATRIX_INDEX 0 // RGBA
#define LTC_DISNEY_DIFFUSE_MATRIX_INDEX 1 // RGBA
#define LTC_MULTI_GGX_FRESNEL_DISNEY_DIFFUSE_INDEX 2 // RGB, A unused
#define LTC_LUT_SIZE   64
#define LTC_LUT_SCALE  ((LTC_LUT_SIZE - 1) * rcp(LTC_LUT_SIZE))
#define LTC_LUT_OFFSET (0.5 * rcp(LTC_LUT_SIZE))

// Subsurface scattering constant
#define SSS_WRAP_ANGLE (PI/12)              // 15 degrees
#define SSS_WRAP_LIGHT cos(PI/2 - SSS_WRAP_ANGLE)

CBUFFER_START(UnitySSSParameters)
// Warning: Unity is not able to losslessly transfer integers larger than 2^24 to the shader system.
// Therefore, we bitcast uint to float in C#, and bitcast back to uint in the shader.
uint   _EnableSSSAndTransmission; // Globally toggles subsurface and transmission scattering on/off
float  _TexturingModeFlags;       // 1 bit/profile; 0 = PreAndPostScatter, 1 = PostScatter
float  _TransmissionFlags;        // 2 bit/profile; 0 = inf. thick, 1 = thin, 2 = regular
// Old SSS Model >>>
uint   _UseDisneySSS;
float4 _HalfRcpVariancesAndWeights[SSS_N_PROFILES][2]; // 2x Gaussians in RGB, A is interpolation weights
// <<< Old SSS Model
// Use float4 to avoid any packing issue between compute and pixel shaders
float4  _ThicknessRemaps[SSS_N_PROFILES];   // R: start, G = end - start, BA unused
float4 _ShapeParams[SSS_N_PROFILES];        // RGB = S = 1 / D, A = filter radius
float4 _TransmissionTints[SSS_N_PROFILES];  // RGB = 1/4 * color, A = unused
CBUFFER_END

//-----------------------------------------------------------------------------
// Helper for cheap screen space raycasting
//-----------------------------------------------------------------------------

float3 EstimateRaycast(float3 V, PositionInputs posInputs, float3 positionWS, float3 rayWS)
{
    // For all refraction approximation, to calculate the refracted point in world space,
    //   we approximate the scene as a plane (back plane) with normal -V at the depth hit point.
    //   (We avoid to raymarch the depth texture to get the refracted point.)

    uint2 depthSize = uint2(_PyramidDepthMipSize.xy);

    // Get the depth of the approximated back plane
    float pyramidDepth = LOAD_TEXTURE2D_LOD(_PyramidDepthTexture, posInputs.positionSS * (depthSize >> 2), 2).r;
    float depth = LinearEyeDepth(pyramidDepth, _ZBufferParams);

    // Distance from point to the back plane
    float depthFromPositionInput = depth - posInputs.depthVS;

    float offset = dot(-V, positionWS - posInputs.positionWS);
    float depthFromPosition = depthFromPositionInput - offset;

    float hitDistanceFromPosition = depthFromPosition / dot(-V, rayWS);

    return positionWS + rayWS * hitDistanceFromPosition;
}

//-----------------------------------------------------------------------------
// Ligth and material classification for the deferred rendering path
// Configure what kind of combination is supported
//-----------------------------------------------------------------------------

// Lighting architecture and material are suppose to be decoupled files.
// However as we use material classification it is hard to be fully separated
// the dependecy is define in this include where there is shared define for material and lighting in case of deferred material.
// If a user do a lighting architecture without material classification, this can be remove
#include "../../Lighting/TilePass/TilePass.cs.hlsl"

static int g_FeatureFlags = 0xFFFFFFFF;

// This method allows us to know at compile time what shader features should be removed from the code when the materialID cannot be known on the whole tile (any combination of 2 or more differnet materials in the same tile)
// This is only useful for classification during lighting, so it's not needed in EncodeIntoGBuffer and ConvertSurfaceDataToBSDFData (where we always know exactly what the MaterialID is)
bool HasMaterialFeatureFlag(int flag)
{
    return ((g_FeatureFlags & flag) != 0);
}

// Combination need to be define in increasing "comlexity" order as define by FeatureFlagsToTileVariant
static const uint kFeatureVariantFlags[NUM_FEATURE_VARIANTS] =
{
    // Precomputed illumination (no dynamic lights) for all material types (except for the clear coat)
    /*  0 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_ENV | (MATERIAL_FEATURE_MASK_FLAGS & (~MATERIALFEATUREFLAGS_LIT_CLEAR_COAT)),

    // Standard>Specular
    /*  1 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | MATERIALFEATUREFLAGS_LIT_STANDARD,
    /*  2 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_AREA | MATERIALFEATUREFLAGS_LIT_STANDARD,
    /*  3 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_STANDARD,
    /*  4 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_STANDARD,
    /*  5 */ LIGHT_FEATURE_MASK_FLAGS_OPAQUE | MATERIALFEATUREFLAGS_LIT_STANDARD,

    // SSS
    /*  6 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | MATERIALFEATUREFLAGS_LIT_SSS,
    /*  7 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_AREA | MATERIALFEATUREFLAGS_LIT_SSS,
    /*  8 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_SSS,
    /*  9 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_SSS,
    /* 10 */ LIGHT_FEATURE_MASK_FLAGS_OPAQUE | MATERIALFEATUREFLAGS_LIT_SSS,

    // Aniso
    /* 11 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | MATERIALFEATUREFLAGS_LIT_ANISO,
    /* 12 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_AREA | MATERIALFEATUREFLAGS_LIT_ANISO,
    /* 13 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_ANISO,
    /* 14 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_ANISO,
    /* 15 */ LIGHT_FEATURE_MASK_FLAGS_OPAQUE | MATERIALFEATUREFLAGS_LIT_ANISO,

    // With foliage or crowd with SSS and standard can overlap a lot, better to have a dedicated combination
    /* 16 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | MATERIALFEATUREFLAGS_LIT_SSS | MATERIALFEATUREFLAGS_LIT_STANDARD,
    /* 17 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_AREA | MATERIALFEATUREFLAGS_LIT_SSS | MATERIALFEATUREFLAGS_LIT_STANDARD,
    /* 18 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_SSS | MATERIALFEATUREFLAGS_LIT_STANDARD,
    /* 19 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_SSS | MATERIALFEATUREFLAGS_LIT_STANDARD,
    /* 20 */ LIGHT_FEATURE_MASK_FLAGS_OPAQUE | MATERIALFEATUREFLAGS_LIT_SSS | MATERIALFEATUREFLAGS_LIT_STANDARD,

    // ClearCoat
    /* 21 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | MATERIALFEATUREFLAGS_LIT_CLEAR_COAT,
    /* 22 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_AREA | MATERIALFEATUREFLAGS_LIT_CLEAR_COAT,
    /* 23 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_CLEAR_COAT,
    /* 24 */ LIGHTFEATUREFLAGS_SKY | LIGHTFEATUREFLAGS_DIRECTIONAL | LIGHTFEATUREFLAGS_PUNCTUAL | LIGHTFEATUREFLAGS_ENV | MATERIALFEATUREFLAGS_LIT_CLEAR_COAT,
    /* 25 */ LIGHT_FEATURE_MASK_FLAGS_OPAQUE | MATERIALFEATUREFLAGS_LIT_CLEAR_COAT,

    /* 26 */ LIGHT_FEATURE_MASK_FLAGS_OPAQUE | MATERIAL_FEATURE_MASK_FLAGS, // Catch all case with MATERIAL_FEATURE_MASK_FLAGS is needed in case we disable material classification
};

uint FeatureFlagsToTileVariant(uint featureFlags)
{
    for (int i = 0; i < NUM_FEATURE_VARIANTS; i++)
    {
        if ((featureFlags & kFeatureVariantFlags[i]) == featureFlags)
            return i;
    }
    return NUM_FEATURE_VARIANTS - 1;
}

// This function need to return a compile time value, else there is no optimization
uint TileVariantToFeatureFlags(uint variant)
{
    return kFeatureVariantFlags[variant];
}

//-----------------------------------------------------------------------------
// Helper functions/variable specific to this material
//-----------------------------------------------------------------------------

float PackMaterialId(int materialId)
{
    return float(materialId) / 3.0;
}

int UnpackMaterialId(float f)
{
    return int(round(f * 3.0));
}

void FillMaterialIdStandardData(float3 baseColor, float metallic, inout BSDFData bsdfData)
{
    bsdfData.diffuseColor = baseColor * (1.0 - metallic);
    float val = DEFAULT_SPECULAR_VALUE;
    bsdfData.fresnel0 = lerp(val.xxx, baseColor, metallic);
}

void FillMaterialIdAnisoData(float roughness, float3 normalWS, float3 tangentWS, float anisotropy, inout BSDFData bsdfData)
{
    bsdfData.tangentWS = tangentWS;
    bsdfData.bitangentWS = cross(normalWS, tangentWS);
    ConvertAnisotropyToRoughness(roughness, anisotropy, bsdfData.roughnessT, bsdfData.roughnessB);
    bsdfData.anisotropy = anisotropy;
}

void FillMaterialIdSSSData(float3 baseColor, int subsurfaceProfile, float subsurfaceRadius, float thickness, inout BSDFData bsdfData)
{
    bsdfData.diffuseColor = baseColor;

    bsdfData.fresnel0 = SKIN_SPECULAR_VALUE; // TODO take from subsurfaceProfile instead
    bsdfData.subsurfaceProfile = subsurfaceProfile;
    bsdfData.subsurfaceRadius  = subsurfaceRadius;
    bsdfData.thickness = _ThicknessRemaps[subsurfaceProfile].x + _ThicknessRemaps[subsurfaceProfile].y * thickness;

    uint transmissionMode = BitFieldExtract(asuint(_TransmissionFlags), 2u, 2u * subsurfaceProfile);

    bsdfData.enableTransmission = _EnableSSSAndTransmission != 0 && transmissionMode != SSS_TRSM_MODE_NONE;

    if (bsdfData.enableTransmission)
    {
        bsdfData.useThinObjectMode = transmissionMode == SSS_TRSM_MODE_THIN;

        if (_UseDisneySSS != 0)
        {
            bsdfData.transmittance = ComputeTransmittanceDisney(_ShapeParams[subsurfaceProfile].rgb,
                                                                _TransmissionTints[subsurfaceProfile].rgb,
                                                                bsdfData.thickness, bsdfData.subsurfaceRadius);
        }
        else
        {
            bsdfData.transmittance = ComputeTransmittanceJimenez(_HalfRcpVariancesAndWeights[subsurfaceProfile][0].rgb,
                                                                 _HalfRcpVariancesAndWeights[subsurfaceProfile][0].a,
                                                                 _HalfRcpVariancesAndWeights[subsurfaceProfile][1].rgb,
                                                                 _HalfRcpVariancesAndWeights[subsurfaceProfile][1].a,
                                                                 _TransmissionTints[subsurfaceProfile].rgb,
                                                                 bsdfData.thickness, bsdfData.subsurfaceRadius);
        }
    }
}

// Returns the modified albedo (diffuse color) for materials with subsurface scattering.
// Ref: Advanced Techniques for Realistic Real-Time Skin Rendering.
float3 ApplyDiffuseTexturingMode(BSDFData bsdfData)
{
    float3 albedo = bsdfData.diffuseColor;

    if (bsdfData.materialId == MATERIALID_LIT_SSS)
    {
    #if defined(SHADERPASS) && (SHADERPASS == SHADERPASS_SUBSURFACE_SCATTERING)
        // If the SSS pass is executed, we know we have SSS enabled.
        bool enableSssAndTransmission = true;
    #else
        bool enableSssAndTransmission = _EnableSSSAndTransmission != 0;
    #endif

        if (enableSssAndTransmission)
        {
            bool performPostScatterTexturing = IsBitSet(asuint(_TexturingModeFlags), bsdfData.subsurfaceProfile);

            if (performPostScatterTexturing)
            {
                // Post-scatter texturing mode: the albedo is only applied during the SSS pass.
            #if !defined(SHADERPASS) || (SHADERPASS != SHADERPASS_SUBSURFACE_SCATTERING)
                albedo = float3(1, 1, 1);
            #endif
            }
            else
            {
                // Pre- and pos- scatter texturing mode.
                albedo = sqrt(albedo);
            }
        }
    }

    return albedo;
}

void FillMaterialIdClearCoatData(float3 coatNormalWS, float coatCoverage, float coatIOR, inout BSDFData bsdfData)
{
    bsdfData.coatNormalWS = lerp(bsdfData.normalWS, coatNormalWS, coatCoverage);
    bsdfData.coatIOR = lerp(1.0, 1.0 + coatIOR, coatCoverage);
    bsdfData.coatCoverage = coatCoverage;
}

void FillMaterialIdTransparencyData(float3 baseColor, float metallic, float ior, float3 transmittanceColor, float atDistance, float thickness, float transmittanceMask, inout BSDFData bsdfData)
{
    // Uses thickness from SSS's property set
    bsdfData.ior = ior;

    // IOR define the fresnel0 value, so update it also for consistency (and even if not physical we still need to take into account any metal mask)
    bsdfData.fresnel0 = lerp(IORToFresnel0(ior).xxx, baseColor, metallic);

    bsdfData.absorptionCoefficient = TransmittanceColorAtDistanceToAbsorption (transmittanceColor, atDistance);
    bsdfData.transmittanceMask = transmittanceMask;
    bsdfData.thickness = max(thickness, 0.0001);
}

// For image based lighting, a part of the BSDF is pre-integrated.
// This is done both for specular and diffuse (in case of DisneyDiffuse)
void GetPreIntegratedFGD(float NdotV, float perceptualRoughness, float3 fresnel0, out float3 specularFGD, out float diffuseFGD, out float reflectivity)
{
    // Pre-integrate GGX FGD
    // Integral{BSDF * <N,L> dw} =
    // Integral{(F0 + (1 - F0) * (1 - <V,H>)^5) * (BSDF / F) * <N,L> dw} =
    // F0 * Integral{(BSDF / F) * <N,L> dw} +
    // (1 - F0) * Integral{(1 - <V,H>)^5 * (BSDF / F) * <N,L> dw} =
    // (1 - F0) * x + F0 * y = lerp(x, y, F0)
    // Pre integrate DisneyDiffuse FGD:
    // z = DisneyDiffuse
    float3 preFGD = SAMPLE_TEXTURE2D_LOD(_PreIntegratedFGD, s_linear_clamp_sampler, float2(NdotV, perceptualRoughness), 0).xyz;

    specularFGD = lerp(preFGD.xxx, preFGD.yyy, fresnel0);

#ifdef LIT_DIFFUSE_LAMBERT_BRDF
    diffuseFGD = 1.0;
#else
    // Remap from the [0, 1] to the [0.5, 1.5] range.
    diffuseFGD = preFGD.z + 0.5;
#endif

    reflectivity = preFGD.y;
}

void ApplyDebugToSurfaceData(inout SurfaceData surfaceData)
{
#ifdef DEBUG_DISPLAY
    if (_DebugLightingMode == DEBUGLIGHTINGMODE_SPECULAR_LIGHTING)
    {
        bool overrideSmoothness = _DebugLightingSmoothness.x != 0.0;
        float overrideSmoothnessValue = _DebugLightingSmoothness.y;

        if (overrideSmoothness)
        {
            surfaceData.perceptualSmoothness = overrideSmoothnessValue;
        }
    }

    if (_DebugLightingMode == DEBUGLIGHTINGMODE_DIFFUSE_LIGHTING)
    {
        surfaceData.baseColor = _DebugLightingAlbedo.xyz;
    }
#endif
}

//-----------------------------------------------------------------------------
// conversion function for forward
//-----------------------------------------------------------------------------

BSDFData ConvertSurfaceDataToBSDFData(SurfaceData surfaceData)
{
    ApplyDebugToSurfaceData(surfaceData);

    BSDFData bsdfData;
    ZERO_INITIALIZE(BSDFData, bsdfData);

    bsdfData.specularOcclusion = surfaceData.specularOcclusion;
    bsdfData.normalWS = surfaceData.normalWS;
    bsdfData.perceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(surfaceData.perceptualSmoothness);
    bsdfData.roughness = PerceptualRoughnessToRoughness(bsdfData.perceptualRoughness);
    bsdfData.materialId = surfaceData.materialId;

    // IMPORTANT: In case of foward or gbuffer pass we must know what we are statically, so compiler can do compile time optimization
    if (bsdfData.materialId == MATERIALID_LIT_STANDARD)
    {
        FillMaterialIdStandardData(surfaceData.baseColor, surfaceData.metallic, bsdfData);
    }
    else if (bsdfData.materialId == MATERIALID_LIT_SPECULAR)
    {
        // Note: Specular is not a material id but just a way to parameterize the standard materialid, thus we reset materialId to MATERIALID_LIT_STANDARD
        bsdfData.materialId = MATERIALID_LIT_STANDARD;
        bsdfData.diffuseColor = surfaceData.baseColor;
        bsdfData.fresnel0 = surfaceData.specularColor;
    }
    else if (bsdfData.materialId == MATERIALID_LIT_SSS)
    {
        FillMaterialIdSSSData(surfaceData.baseColor, surfaceData.subsurfaceProfile, surfaceData.subsurfaceRadius, surfaceData.thickness, bsdfData);
    }
    else if (bsdfData.materialId == MATERIALID_LIT_ANISO)
    {
        FillMaterialIdStandardData(surfaceData.baseColor, surfaceData.metallic, bsdfData);
        FillMaterialIdAnisoData(bsdfData.roughness, surfaceData.normalWS, surfaceData.tangentWS, surfaceData.anisotropy, bsdfData);
    }
    else if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT)
    {
        // When using clear coat we assume that bottom layer is regular
        FillMaterialIdStandardData(surfaceData.baseColor, surfaceData.metallic, bsdfData);
        FillMaterialIdClearCoatData(surfaceData.coatNormalWS, surfaceData.coatCoverage, surfaceData.coatIOR, bsdfData);
    }

#if HAS_REFRACTION
    // Note: Will override thickness of SSS's property set
    FillMaterialIdTransparencyData(
        surfaceData.baseColor, surfaceData.metallic, surfaceData.ior, surfaceData.transmittanceColor, surfaceData.atDistance, surfaceData.thickness, surfaceData.transmittanceMask,
        bsdfData);
#endif

    return bsdfData;
}

//-----------------------------------------------------------------------------
// conversion function for deferred
//-----------------------------------------------------------------------------

// Encode SurfaceData (BSDF parameters) into GBuffer
// Must be in sync with RT declared in HDRenderPipeline.cs ::Rebuild
void EncodeIntoGBuffer( SurfaceData surfaceData,
                        float3 bakeDiffuseLighting,
                        #if SHADEROPTIONS_PACK_GBUFFER_IN_U16
                        out GBufferType0 outGBufferU0,
                        out GBufferType1 outGBufferU1
                        #else
                        out GBufferType0 outGBuffer0,
                        out GBufferType1 outGBuffer1,
                        out GBufferType2 outGBuffer2,
                        out GBufferType3 outGBuffer3
                        #endif
                        )
{
#if SHADEROPTIONS_PACK_GBUFFER_IN_U16
    float4 outGBuffer0, outGBuffer1, outGBuffer2, outGBuffer3;
#endif

    ApplyDebugToSurfaceData(surfaceData);

    // RT0 - 8:8:8:8 sRGB
    outGBuffer0 = float4(surfaceData.baseColor, surfaceData.specularOcclusion);

    // RT1 - 10:10:10:2
    // We store perceptualRoughness instead of roughness because it save a sqrt ALU when decoding
    // (as we want both perceptualRoughness and roughness for the lighting due to Disney Diffuse model)
    // Encode normal on 20bit with oct compression + 2bit of sign
    float2 octNormalWS = PackNormalOctEncode((surfaceData.materialId == MATERIALID_LIT_CLEAR_COAT) ? surfaceData.coatNormalWS : surfaceData.normalWS);
    // To have more precision encode the sign of xy in a separate uint
    uint octNormalSign = (octNormalWS.x < 0.0 ? 1 : 0) | (octNormalWS.y < 0.0 ? 2 : 0);
    // Store octNormalSign on two bits with perceptualRoughness
    outGBuffer1 = float4(abs(octNormalWS), PackFloatInt10bit(PerceptualSmoothnessToPerceptualRoughness(surfaceData.perceptualSmoothness), octNormalSign, 4.0), PackMaterialId(surfaceData.materialId));

    // RT2 - 8:8:8:8
    if (surfaceData.materialId == MATERIALID_LIT_STANDARD)
    {
        outGBuffer2 = float4(float3(0.0, 0.0, 0.0), PackFloatInt8bit(surfaceData.metallic, GBUFFER_LIT_STANDARD_REGULAR_ID, 4.0));
    }
    else if (surfaceData.materialId == MATERIALID_LIT_SPECULAR)
    {
        outGBuffer1.a = PackMaterialId(MATERIALID_LIT_STANDARD); // Encode MATERIALID_LIT_SPECULAR as MATERIALID_LIT_STANDARD + GBUFFER_LIT_STANDARD_SPECULAR_COLOR_ID value in GBuffer2
        outGBuffer2 = float4(surfaceData.specularColor, PackFloatInt8bit(0.0, GBUFFER_LIT_STANDARD_SPECULAR_COLOR_ID, 4.0));
    }
    else if (surfaceData.materialId == MATERIALID_LIT_SSS)
    {
        outGBuffer2 = float4(surfaceData.subsurfaceRadius, surfaceData.thickness, 0.0, PackByte(surfaceData.subsurfaceProfile));
    }
    else if (surfaceData.materialId == MATERIALID_LIT_ANISO)
    {
        // Encode tangent on 16bit with oct compression
        float2 octTangentWS = PackNormalOctEncode(surfaceData.tangentWS);
        // To have more precision encode the sign of xy in a separate uint
        uint octTangentSign = (octTangentWS.x < 0.0 ? 1 : 0) | (octTangentWS.y < 0.0 ? 2 : 0);

        outGBuffer2 = float4(abs(octTangentWS), surfaceData.anisotropy * 0.5 + 0.5, PackFloatInt8bit(surfaceData.metallic, octTangentSign, 4.0));
    }
    else if (surfaceData.materialId == MATERIALID_LIT_CLEAR_COAT)
    {
        // In the cae of clear coat, we want more precision for the coat normal than for the bottom normal (as it is expected to be smooth). So swap the normal encoding storage in Gbuffer.
        // It also allow to use clear coat normal for SSR
        float2 octBottomNormalWS = PackNormalOctEncode(surfaceData.normalWS);
        outGBuffer2 = float4(octBottomNormalWS * 0.5 + 0.5, surfaceData.coatCoverage, PackFloatInt8bit(surfaceData.coatIOR, (int)(surfaceData.metallic * 15.5f), 16.0) );
    }

    // Lighting
    outGBuffer3 = float4(bakeDiffuseLighting, 0.0);

#if SHADEROPTIONS_PACK_GBUFFER_IN_U16
    // Now pack all buffer into 2 uint buffer

    // We don't have hardware sRGB to store base color in case we pack int u16, so rather than perform full sRGB encoding just use cheap gamma20
    // TODO: test alternative like FastLinearToSRGB to better match unpacked gbuffer
    outGBuffer0.xyz = LinearToGamma20(outGBuffer0.xyz);

    uint packedGBuffer1 = PackR10G10B10A2(outGBuffer1);

    outGBufferU0 = uint4(   PackFloatToUInt(outGBuffer0.x, 8, 0)  | PackFloatToUInt(outGBuffer0.y, 8, 8),
                            PackFloatToUInt(outGBuffer0.z, 8, 0)  | PackFloatToUInt(outGBuffer0.w, 8, 8),
                            (packedGBuffer1 & 0x0000FFFF),
                            (packedGBuffer1 & 0xFFFF0000) >> 16);

    uint packedGBuffer3 = PackToR11G11B10f(outGBuffer3.xyz);

    outGBufferU1 = uint4(   PackFloatToUInt(outGBuffer2.x, 8, 0)  | PackFloatToUInt(outGBuffer2.y, 8, 8),
                            PackFloatToUInt(outGBuffer2.z, 8, 0)  | PackFloatToUInt(outGBuffer2.w, 8, 8),
                            (packedGBuffer3 & 0x0000FFFF),
                            (packedGBuffer3 & 0xFFFF0000) >> 16);
#endif
}

float4 DecodeGBuffer0(GBufferType0 encodedGBuffer0)
{
    float4 decodedGBuffer0;
#if SHADEROPTIONS_PACK_GBUFFER_IN_U16
    decodedGBuffer0.x = UnpackUIntToFloat(encodedGBuffer0.x, 8, 0);
    decodedGBuffer0.y = UnpackUIntToFloat(encodedGBuffer0.x, 8, 8);
    decodedGBuffer0.z = UnpackUIntToFloat(encodedGBuffer0.y, 8, 0);
    decodedGBuffer0.w = UnpackUIntToFloat(encodedGBuffer0.y, 8, 8);

    decodedGBuffer0.xyz = Gamma20ToLinear(encodedGBuffer0.xyz);
#else
    decodedGBuffer0 = encodedGBuffer0;
#endif
    return decodedGBuffer0;
}

void DecodeFromGBuffer(
#if SHADEROPTIONS_PACK_GBUFFER_IN_U16
    GBufferType0 inGBufferU0,
    GBufferType1 inGBufferU1,
#else
    GBufferType0 inGBuffer0,
    GBufferType1 inGBuffer1,
    GBufferType2 inGBuffer2,
    GBufferType3 inGBuffer3,
#endif
    uint featureFlags,
    out BSDFData bsdfData,
    out float3 bakeDiffuseLighting)
{
    ZERO_INITIALIZE(BSDFData, bsdfData);

    g_FeatureFlags = featureFlags;

#if SHADEROPTIONS_PACK_GBUFFER_IN_U16
    float4 inGBuffer0, inGBuffer1, inGBuffer2, inGBuffer3;

    inGBuffer0 = DecodeGBuffer0(inGBufferU0);

    uint packedGBuffer1 = inGBufferU0.z | inGBufferU0.w << 16;
    inGBuffer1 = UnpackR10G10B10A2(packedGBuffer1);

    inGBuffer2.x = UnpackUIntToFloat(inGBufferU1.x, 8, 0);
    inGBuffer2.y = UnpackUIntToFloat(inGBufferU1.x, 8, 8);
    inGBuffer2.z = UnpackUIntToFloat(inGBufferU1.y, 8, 0);
    inGBuffer2.w = UnpackUIntToFloat(inGBufferU1.y, 8, 8);

    uint packedGBuffer3 = inGBufferU1.z | inGBufferU1.w << 16;
    inGBuffer3.xyz = UnpackFromR11G11B10f(packedGBuffer1);
    inGBuffer3.w = 0.0;
#endif

    float3 baseColor = inGBuffer0.rgb;
    bsdfData.specularOcclusion = inGBuffer0.a;

    int octNormalSign;
    UnpackFloatInt10bit(inGBuffer1.b, 4.0, bsdfData.perceptualRoughness, octNormalSign);
    inGBuffer1.r = (octNormalSign & 1) ? -inGBuffer1.r : inGBuffer1.r;
    inGBuffer1.g = (octNormalSign & 2) ? -inGBuffer1.g : inGBuffer1.g;

    bsdfData.normalWS = UnpackNormalOctEncode(float2(inGBuffer1.r, inGBuffer1.g));

    bsdfData.roughness = PerceptualRoughnessToRoughness(bsdfData.perceptualRoughness);

    // The material features system for material classification must allow compile time optimization (i.e everything should be static)
    // Note that as we store materialId for Aniso based on content of RT2 we need to add few extra condition.
    // The code is also call from MaterialFeatureFlagsFromGBuffer, so must work fully dynamic if featureFlags is 0xFFFFFFFF
    int supportsStandard = HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_STANDARD);
    int supportsSSS = HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_SSS);
    int supportsAniso = HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_ANISO);
    int supportClearCoat = HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT);

    if (supportsStandard + supportsSSS + supportsAniso + supportClearCoat > 1)
    {
        // only fetch materialid if it is not statically known from feature flags
        bsdfData.materialId = UnpackMaterialId(inGBuffer1.a);
    }
    else
    {
        // materialid is statically known. this allows the compiler to eliminate a lot of code.
        if (supportsStandard)
            bsdfData.materialId = MATERIALID_LIT_STANDARD;
        else if (supportsSSS)
            bsdfData.materialId = MATERIALID_LIT_SSS;
        else if (supportsAniso)
            bsdfData.materialId = MATERIALID_LIT_ANISO;
        else
            bsdfData.materialId = MATERIALID_LIT_CLEAR_COAT;
    }

    if (bsdfData.materialId == MATERIALID_LIT_STANDARD && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_STANDARD))
    {
        float metallic;
        int materialIdExtent;
        UnpackFloatInt8bit(inGBuffer2.a, 4.0, metallic, materialIdExtent);

        if (materialIdExtent == GBUFFER_LIT_STANDARD_SPECULAR_COLOR_ID)
        {
            // Note: Specular is not a material id but just a way to parameterize the standard materialid, thus we reset materialId to MATERIALID_LIT_STANDARD
            // For material classification it will be consider as Standard as well, thus no need to create special case
            bsdfData.diffuseColor = baseColor;
            bsdfData.fresnel0 = inGBuffer2.rgb;
        }
        else // GBUFFER_LIT_STANDARD_REGULAR_ID
        {
            FillMaterialIdStandardData(baseColor, metallic, bsdfData);
        }
    }
    else if (bsdfData.materialId == MATERIALID_LIT_SSS && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_SSS))
    {
        float subsurfaceRadius  = inGBuffer2.x;
        float thickness         = inGBuffer2.y;
        int   subsurfaceProfile = UnpackByte(inGBuffer2.w);

        FillMaterialIdSSSData(baseColor, subsurfaceProfile, subsurfaceRadius, thickness, bsdfData);
    }
    else if (bsdfData.materialId == MATERIALID_LIT_ANISO && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_ANISO))
    {
        float metallic;
        int octTangentSign;
        UnpackFloatInt8bit(inGBuffer2.a, 4.0, metallic, octTangentSign);
        FillMaterialIdStandardData(baseColor, metallic, bsdfData);

        inGBuffer2.r = (octTangentSign & 1) ? -inGBuffer2.r : inGBuffer2.r;
        inGBuffer2.g = (octTangentSign & 2) ? -inGBuffer2.g : inGBuffer2.g;
        float3 tangentWS = UnpackNormalOctEncode(inGBuffer2.rg);
        float anisotropy = inGBuffer2.b * 2 - 1;

        FillMaterialIdAnisoData(bsdfData.roughness, bsdfData.normalWS, tangentWS, anisotropy, bsdfData);
    }
    else if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    {
        // We have swap the encoding of the normal to have more precision for coat normal as it is more smooth
        float3 coatNormalWS = bsdfData.normalWS;
        bsdfData.normalWS = UnpackNormalOctEncode(float2(inGBuffer2.rg * 2.0 - 1.0));

        float coatCoverage = inGBuffer2.b;
        float coatIOR;
        int metallic;
        UnpackFloatInt8bit(inGBuffer2.a, 16.0, coatIOR, metallic);

        // When using clear coat we assume that bottom layer is regular
        FillMaterialIdStandardData(baseColor, metallic / 15.0f, bsdfData);
        FillMaterialIdClearCoatData(coatNormalWS, coatCoverage, coatIOR, bsdfData);
    }

    bakeDiffuseLighting = inGBuffer3.rgb;
}

// Function call from the material classification compute shader
// Note that as we store materialId on two buffer (for anisotropy case), the code need to load 2 RGBA8 buffer
uint MaterialFeatureFlagsFromGBuffer(
#if SHADEROPTIONS_PACK_GBUFFER_IN_U16
    GBufferType0 inGBufferU0,
    GBufferType1 inGBufferU1
#else
    GBufferType0 inGBuffer0,
    GBufferType1 inGBuffer1,
    GBufferType2 inGBuffer2,
    GBufferType3 inGBuffer3
#endif
)
{
    BSDFData bsdfData;
    float3 unused;

    DecodeFromGBuffer(
#if SHADEROPTIONS_PACK_GBUFFER_IN_U16
        inGBufferU0, inGBufferU1,
#else
        inGBuffer0, inGBuffer1, inGBuffer2, inGBuffer3,
#endif
        0xFFFFFFFF,
        bsdfData,
        unused
    );

    return (1 << bsdfData.materialId); // This match all the MATERIALFEATUREFLAGS_LIT_XXX flag
}


//-----------------------------------------------------------------------------
// Debug method (use to display values)
//-----------------------------------------------------------------------------

void GetSurfaceDataDebug(uint paramId, SurfaceData surfaceData, inout float3 result, inout bool needLinearToSRGB)
{
    GetGeneratedSurfaceDataDebug(paramId, surfaceData, result, needLinearToSRGB);
}

void GetBSDFDataDebug(uint paramId, BSDFData bsdfData, inout float3 result, inout bool needLinearToSRGB)
{
    GetGeneratedBSDFDataDebug(paramId, bsdfData, result, needLinearToSRGB);
}

//-----------------------------------------------------------------------------
// PreLightData
//-----------------------------------------------------------------------------

// Precomputed lighting data to send to the various lighting functions
struct PreLightData
{
    // General
    float NdotV;

    // GGX
    float partLambdaV;
    float energyCompensation;
    float TdotV;
    float BdotV;

    // Clear coat
    float coatNdotV;
    float ieta;
    float coatFresnel0;
    float3 coatV;
    float3 refractV; // The view vector refracted through clear coat interface

    // IBL
    float3 iblDirWS;                     // Dominant specular direction, used for IBL in EvaluateBSDF_Env()
    float  iblMipLevel;

    // IBL clear coat
    float3 coatIblDirWS;

    float3 specularFGD;                  // Store preconvoled BRDF for both specular and diffuse
    float diffuseFGD;

    // Area lights (17 VGPRs)
    float3x3 orthoBasisViewNormal; // Right-handed view-dependent orthogonal basis around the normal (6x VGPRs)
    float3x3 ltcTransformDiffuse;  // Inverse transformation for Lambertian or Disney Diffuse        (4x VGPRs)
    float3x3 ltcTransformSpecular; // Inverse transformation for GGX                                 (4x VGPRs)
    float    ltcMagnitudeDiffuse;
    float3   ltcMagnitudeFresnel;

    // area light clear coat
    float3x3 ltcXformClearCoat;                // TODO: make sure the compiler not wasting VGPRs on constants
    float    ltcClearCoatFresnelTerm;
    float3x3 ltcCoatT;

    // Refraction
    float3 transmissionRefractV;            // refracted view vector after exiting the shape
    float3 transmissionPositionWS;          // start of the refracted ray after exiting the shape
    float3 transmissionTransmittance;       // transmittance due to absorption
    float transmissionSSMipLevel;           // mip level of the screen space gaussian pyramid for rough refraction
};

// This is a refract - TODO: do we call original refract or this one, original maybe slightly more expensive, to check
float3 ClearCoatTransform(float3 X, float3 N, float ieta)
{
    float XdotN = saturate(dot(N, X));
    return ieta * X + (sqrt(1 + ieta * ieta * (XdotN * XdotN - 1)) - ieta * XdotN) * N;
}

PreLightData GetPreLightData(float3 V, PositionInputs posInput, BSDFData bsdfData)
{
    PreLightData preLightData;

    float3 N;
    float  NdotV;

    if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    {
        N     = bsdfData.coatNormalWS;
        NdotV = saturate(dot(N, V));
        preLightData.coatNdotV = NdotV;

        float ieta = 1.0 / bsdfData.coatIOR; // inverse eta
        preLightData.ieta = ieta;
        preLightData.coatFresnel0 = Sqr(bsdfData.coatIOR - 1.0) / Sqr(bsdfData.coatIOR + 1.0);

        // Clear coat IBL
        preLightData.coatIblDirWS = reflect(-V, N);

        // Clear coat area light
        float theta = FastACosPos(NdotV);
        float2 uv = LTC_LUT_OFFSET + LTC_LUT_SCALE * float2(0.0, theta * INV_HALF_PI); // Use Roughness of 0.0 for clearCoat roughness

                                                                                       // Get the inverse LTC matrix for GGX
                                                                                       // Note we load the matrix transpose (avoid to have to transpose it in shader)
        preLightData.ltcXformClearCoat = 0.0;
        preLightData.ltcXformClearCoat._m22 = 1.0;
        preLightData.ltcXformClearCoat._m00_m02_m11_m20 = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTC_GGX_MATRIX_INDEX, 0);

        float3 ltcMagnitude = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTC_MULTI_GGX_FRESNEL_DISNEY_DIFFUSE_INDEX, 0).rgb;
        float ltcClearCoatFresnelMagnitudeDiff = ltcMagnitude.r; // The difference of magnitudes of GGX and Fresnel
        float ltcClearCoatFresnelMagnitude = ltcMagnitude.g;
        preLightData.ltcClearCoatFresnelTerm = preLightData.coatFresnel0 * ltcClearCoatFresnelMagnitudeDiff + ltcClearCoatFresnelMagnitude;

        // TODO: Convert the area light with respect to Fresnel transmission
        preLightData.ltcCoatT = float3x3(   ieta + (1.0 - ieta) * N.x * N.x, 0.0 + (1.0 - ieta) * N.y * N.x, 0.0 + (1.0 - ieta) * N.z * N.x,
                                            0.0 + (1.0 - ieta) * N.x * N.y, ieta + (1.0 - ieta) * N.y * N.y, 0.0 + (1.0 - ieta) * N.z * N.y,
                                            0.0 + (1.0 - ieta) * N.x * N.z, 0.0 + (1.0 - ieta) * N.y * N.z, ieta + (1.0 - ieta) * N.z * N.z );

        // Modify V for following calculation
        preLightData.refractV = ClearCoatTransform(V, N, ieta);
        V = preLightData.refractV;
    }

    N     = bsdfData.normalWS;
    NdotV = saturate(dot(N, V));
    preLightData.NdotV = NdotV;

    float3 iblR;

    // GGX aniso
    if (bsdfData.materialId == MATERIALID_LIT_ANISO && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_ANISO))
    {
        preLightData.TdotV       = dot(bsdfData.tangentWS, V);
        preLightData.BdotV       = dot(bsdfData.bitangentWS, V);
        preLightData.partLambdaV = GetSmithJointGGXAnisoPartLambdaV(preLightData.TdotV, preLightData.BdotV, NdotV, bsdfData.roughnessT, bsdfData.roughnessB);

        // For GGX aniso and IBL we have done an empirical (eye balled) approximation compare to the reference.
        // We use a single fetch, and we stretch the normal to use based on various criteria.
        // result are far away from the reference but better than nothing
        // For positive anisotropy values: tangent = highlight stretch (anisotropy) direction, bitangent = grain (brush) direction.
        float3 grainDirWS = (bsdfData.anisotropy >= 0) ? bsdfData.bitangentWS : bsdfData.tangentWS;
        // Reduce stretching for (perceptualRoughness < 0.2).
        float  stretch = abs(bsdfData.anisotropy) * saturate(5 * bsdfData.perceptualRoughness);
        // NOTE: If we follow the theory we should use the modified normal for the different calculation implying a normal (like NdotV) and use 'anisoIblNormalWS'
        // into function like GetSpecularDominantDir(). However modified normal is just a hack. The goal is just to stretch a cubemap, no accuracy here.
        // With this in mind and for performance reasons we chose to only use modified normal to calculate R.
        float3 anisoIblNormalWS = GetAnisotropicModifiedNormal(grainDirWS, N, V, stretch);
        iblR = reflect(-V, anisoIblNormalWS);
    }
    else // GGX iso
    {
        preLightData.TdotV       = 0;
        preLightData.BdotV       = 0;
        preLightData.partLambdaV = GetSmithJointGGXPartLambdaV(NdotV, bsdfData.roughness);
        iblR                     = reflect(-V, N);
    }

    float reflectivity;

    // IBL
    GetPreIntegratedFGD(NdotV, bsdfData.perceptualRoughness, bsdfData.fresnel0, preLightData.specularFGD, preLightData.diffuseFGD, reflectivity);

    if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    {
        // Update the roughness and the IBL miplevel
        // Bottom layer is affected by upper layer BRDF, result can't be more sharp than input (it is to mimic what a path tracer will do)
        float roughness = PerceptualRoughnessToRoughness(bsdfData.perceptualRoughness);
        float shininess = Sqr(preLightData.ieta) * (2.0 / Sqr(roughness) - 2.0);
        roughness = sqrt(2.0 / (shininess + 2.0));
        preLightData.iblDirWS = GetSpecularDominantDir(N, iblR, roughness, NdotV);
        preLightData.iblMipLevel = PerceptualRoughnessToMipmapLevel(RoughnessToPerceptualRoughness(roughness));
    }
    else
    {
        // Note: this is a ad-hoc tweak.
        float iblRoughness, iblPerceptualRoughness;

        if (bsdfData.materialId == MATERIALID_LIT_ANISO && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_ANISO))
        {
            // Use the min roughness, and bias it for higher values of anisotropy and roughness.
            float roughnessBias    = 0.075 * bsdfData.anisotropy * bsdfData.roughness;
            iblRoughness           = saturate(min(bsdfData.roughnessT, bsdfData.roughnessB) + roughnessBias);
            iblPerceptualRoughness = RoughnessToPerceptualRoughness(iblRoughness);
        }
        else
        {
            iblRoughness           = bsdfData.roughness;
            iblPerceptualRoughness = bsdfData.perceptualRoughness;
        }

        preLightData.iblDirWS    = GetSpecularDominantDir(N, iblR, iblRoughness, NdotV);
        preLightData.iblMipLevel = PerceptualRoughnessToMipmapLevel(iblPerceptualRoughness);
    }

#ifdef LIT_USE_GGX_ENERGY_COMPENSATION
    // Ref: Practical multiple scattering compensation for microfacet models.
    // We only apply the formulation for metals.
    // For dielectrics, the change of reflectance is negligible.
    // We deem the intensity difference of a couple of percent for high values of roughness
    // to not be worth the cost of another precomputed table.
    // Note: this formulation bakes the BSDF non-symmetric!
    preLightData.energyCompensation = 1.0 / reflectivity - 1.0;
#else
    preLightData.energyCompensation = 0.0;
#endif // LIT_USE_GGX_ENERGY_COMPENSATION

    // Area light
    // UVs for sampling the LUTs
    float theta = FastACosPos(NdotV); // For Area light - UVs for sampling the LUTs
    float2 uv = LTC_LUT_OFFSET + LTC_LUT_SCALE * float2(bsdfData.perceptualRoughness, theta * INV_HALF_PI);

    // Note we load the matrix transpose (avoid to have to transpose it in shader)
#ifdef LIT_DIFFUSE_LAMBERT_BRDF
    preLightData.ltcTransformDiffuse = k_identity3x3;
#else
    // Get the inverse LTC matrix for Disney Diffuse
    preLightData.ltcTransformDiffuse      = 0.0;
    preLightData.ltcTransformDiffuse._m22 = 1.0;
    preLightData.ltcTransformDiffuse._m00_m02_m11_m20 = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTC_DISNEY_DIFFUSE_MATRIX_INDEX, 0);
#endif

    // Get the inverse LTC matrix for GGX
    // Note we load the matrix transpose (avoid to have to transpose it in shader)
    preLightData.ltcTransformSpecular      = 0.0;
    preLightData.ltcTransformSpecular._m22 = 1.0;
    preLightData.ltcTransformSpecular._m00_m02_m11_m20 = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTC_GGX_MATRIX_INDEX, 0);

    // Construct a right-handed view-dependent orthogonal basis around the normal
    preLightData.orthoBasisViewNormal[0] = normalize(V - N * NdotV);
    preLightData.orthoBasisViewNormal[2] = N;
    preLightData.orthoBasisViewNormal[1] = normalize(cross(preLightData.orthoBasisViewNormal[2], preLightData.orthoBasisViewNormal[0]));

    float3 ltcMagnitude = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTC_MULTI_GGX_FRESNEL_DISNEY_DIFFUSE_INDEX, 0).rgb;
    float  ltcGGXFresnelMagnitudeDiff = ltcMagnitude.r; // The difference of magnitudes of GGX and Fresnel
    float  ltcGGXFresnelMagnitude     = ltcMagnitude.g;
    float  ltcDisneyDiffuseMagnitude  = ltcMagnitude.b;

#ifdef LIT_DIFFUSE_LAMBERT_BRDF
    preLightData.ltcMagnitudeDiffuse = 1;
#else
    preLightData.ltcMagnitudeDiffuse = ltcDisneyDiffuseMagnitude;
#endif

    // TODO: the fit seems rather poor. The scaling factor of 0.5 allows us
    // to match the reference for rough metals, but further darkens dielectrics.
    if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    {
        // Change the Fresnel term to account for transmission through Clear Coat and reflection on the base layer
        float F = F_Schlick(preLightData.coatFresnel0, preLightData.coatNdotV);
        F = Sqr(-F * bsdfData.coatCoverage + 1.0);
        F /= preLightData.ieta; //TODO: LaurentB why / ieta here and not for other lights ?

        preLightData.ltcMagnitudeFresnel = F * bsdfData.fresnel0 * ltcGGXFresnelMagnitudeDiff + (float3)ltcGGXFresnelMagnitude;
    }
    else
    {
        preLightData.ltcMagnitudeFresnel = bsdfData.fresnel0 * ltcGGXFresnelMagnitudeDiff + (float3)ltcGGXFresnelMagnitude;
    }

#ifdef REFRACTION_MODEL
    RefractionModelResult refraction = REFRACTION_MODEL(V, posInput, bsdfData);
    preLightData.transmissionRefractV = refraction.rayWS;
    preLightData.transmissionPositionWS = refraction.positionWS;
    preLightData.transmissionTransmittance = exp(-bsdfData.absorptionCoefficient * refraction.distance);
    // Empirical remap to try to match a bit the refractio probe blurring for the fallback
    preLightData.transmissionSSMipLevel = sqrt(bsdfData.perceptualRoughness) * uint(_GaussianPyramidColorMipSize.z);
#else
    preLightData.transmissionRefractV = -V;
    preLightData.transmissionPositionWS = posInput.positionWS;
    preLightData.transmissionTransmittance = float3(1.0, 1.0, 1.0);
    preLightData.transmissionSSMipLevel = 0;
#endif

    return preLightData;
}

//-----------------------------------------------------------------------------
// bake lighting function
//-----------------------------------------------------------------------------

// GetBakedDiffuseLigthing function compute the bake lighting + emissive color to be store in emissive buffer (Deferred case)
// In forward it must be add to the final contribution.
// This function require the 3 structure surfaceData, builtinData, bsdfData because it may require both the engine side data, and data that will not be store inside the gbuffer.
float3 GetBakedDiffuseLigthing(SurfaceData surfaceData, BuiltinData builtinData, BSDFData bsdfData, PreLightData preLightData)
{
    bsdfData.diffuseColor = ApplyDiffuseTexturingMode(bsdfData);

    // Premultiply bake diffuse lighting information with DisneyDiffuse pre-integration
    return builtinData.bakeDiffuseLighting * preLightData.diffuseFGD * surfaceData.ambientOcclusion * bsdfData.diffuseColor + builtinData.emissiveColor;
}

//-----------------------------------------------------------------------------
// light transport functions
//-----------------------------------------------------------------------------

LightTransportData GetLightTransportData(SurfaceData surfaceData, BuiltinData builtinData, BSDFData bsdfData)
{
    LightTransportData lightTransportData;

    // diffuseColor for lightmapping should basically be diffuse color.
    // But rough metals (black diffuse) still scatter quite a lot of light around, so
    // we want to take some of that into account too.

    lightTransportData.diffuseColor = bsdfData.diffuseColor + bsdfData.fresnel0 * bsdfData.roughness * 0.5 * surfaceData.metallic;
    lightTransportData.emissiveColor = builtinData.emissiveColor;

    return lightTransportData;
}

//-----------------------------------------------------------------------------
// LightLoop related function (Only include if required)
// HAS_LIGHTLOOP is define in Lighting.hlsl
//-----------------------------------------------------------------------------

#ifdef HAS_LIGHTLOOP

//-----------------------------------------------------------------------------
// Lighting structure for light accumulation
//-----------------------------------------------------------------------------

// These structure allow to accumulate lighting accross the Lit material
// AggregateLighting is init to zero and transfer to EvaluateBSDF, but the LightLoop can't access its content.
struct DirectLighting
{
    float3 diffuse;
    float3 specular;
};

struct IndirectLighting
{
    float3 specularReflected;
    float3 specularTransmitted;
};

struct AggregateLighting
{
    DirectLighting   direct;
    IndirectLighting indirect;
};

void AccumulateDirectLighting(DirectLighting src, inout AggregateLighting dst)
{
    dst.direct.diffuse += src.diffuse;
    dst.direct.specular += src.specular;
}

void AccumulateIndirectLighting(IndirectLighting src, inout AggregateLighting dst)
{
    dst.indirect.specularReflected += src.specularReflected;
    dst.indirect.specularTransmitted += src.specularTransmitted;
}

//-----------------------------------------------------------------------------
// BSDF share between directional light, punctual light and area light (reference)
//-----------------------------------------------------------------------------

void BSDF(  float3 V, float3 L, float3 positionWS, PreLightData preLightData, BSDFData bsdfData,
            out float3 diffuseLighting,
            out float3 specularLighting)
{
    float3 F = 1.0;
    specularLighting = float3(0.0, 0.0, 0.0);

    if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT) )
    {
        // Optimized math. Ref: PBR Diffuse Lighting for GGX + Smith Microsurfaces (slide 114).
        float NdotL = saturate(dot(bsdfData.coatNormalWS, L));
        float NdotV = preLightData.coatNdotV;
        float LdotV = dot(L, V);
        float invLenLV = rsqrt(max(2 * LdotV + 2, FLT_SMALL));
        float NdotH = saturate((NdotL + NdotV) * invLenLV);
        float LdotH = saturate(invLenLV * LdotV + invLenLV);

        // Evaluate Fresnel on the Clear Coat
        F = F_Schlick(preLightData.coatFresnel0, LdotH);
        // TODO: No need to call D (to see with LaurentB) + question on * NdotL
        specularLighting += F * D_GGX(NdotH, 0.01) * NdotL * bsdfData.coatCoverage;

        // Change the Fresnel term to account for transmission through Clear Coat and reflection on the base layer
        F = Sqr(-F * bsdfData.coatCoverage + 1.0);

        // Change the Light and View direction to account for IOR change.
        // Update the half vector accordingly
        V = preLightData.refractV;
        L = ClearCoatTransform(L, bsdfData.coatNormalWS, preLightData.ieta);
    }

    // Optimized math. Ref: PBR Diffuse Lighting for GGX + Smith Microsurfaces (slide 114).
    float NdotL    = saturate(dot(bsdfData.normalWS, L)); // Must have the same value without the clamp
    float NdotV    = preLightData.NdotV;                  // Get the unaltered (geometric) version
    float LdotV    = dot(L, V);
    float invLenLV = rsqrt(max(2 * LdotV + 2, FLT_SMALL)); // invLenLV = rcp(length(L + V)) - caution about the case where V and L are opposite, it can happen, use max to avoid this
    float NdotH    = saturate((NdotL + NdotV) * invLenLV);
    float LdotH    = saturate(invLenLV * LdotV + invLenLV);

    F *= F_Schlick(bsdfData.fresnel0, LdotH);

    float DV;

    if (bsdfData.materialId == MATERIALID_LIT_ANISO && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_ANISO))
    {
        float3 H = (L + V) * invLenLV;
        // For anisotropy we must not saturate these values
        float TdotH = dot(bsdfData.tangentWS, H);
        float TdotL = dot(bsdfData.tangentWS, L);
        float BdotH = dot(bsdfData.bitangentWS, H);
        float BdotL = dot(bsdfData.bitangentWS, L);

        bsdfData.roughnessT = ClampRoughnessForAnalyticalLights(bsdfData.roughnessT);
        bsdfData.roughnessB = ClampRoughnessForAnalyticalLights(bsdfData.roughnessB);

        // TODO: Do comparison between this correct version and the one from isotropic and see if there is any visual difference
        DV = DV_SmithJointGGXAniso(TdotH, BdotH, NdotH,
                                   preLightData.TdotV, preLightData.BdotV, preLightData.NdotV,
                                   TdotL, BdotL, NdotL,
                                   bsdfData.roughnessT, bsdfData.roughnessB
        #ifdef LIT_USE_BSDF_PRE_LAMBDAV
                                 , preLightData.partLambdaV);
        #else
                                   );
        #endif
    }
    else
    {
        bsdfData.roughness = ClampRoughnessForAnalyticalLights(bsdfData.roughness);

        DV = DV_SmithJointGGX(NdotH, NdotL, NdotV, bsdfData.roughness
        #ifdef LIT_USE_BSDF_PRE_LAMBDAV
                            , preLightData partLambdaV);
        #else
                              );
        #endif
    }
    specularLighting += F * DV;

#ifdef LIT_DIFFUSE_LAMBERT_BRDF
    float  diffuseTerm = Lambert();
#elif LIT_DIFFUSE_GGX_BRDF
    float3 diffuseTerm = DiffuseGGX(bsdfData.diffuseColor, NdotV, NdotL, NdotH, LdotV, bsdfData.roughness);
#else
    // A note on subsurface scattering.
    // The correct way to handle SSS is to transmit light inside the surface, perform SSS,
    // and then transmit it outside towards the viewer.
    // Transmit(X) = F_Transm_Schlick(F0, F90, NdotX), where F0 = 0, F90 = 1.
    // Therefore, the diffuse BSDF should be decomposed as follows:
    // f_d = A / Pi * F_Transm_Schlick(0, 1, NdotL) * F_Transm_Schlick(0, 1, NdotV) + f_d_reflection,
    // with F_Transm_Schlick(0, 1, NdotV) applied after the SSS pass.
    // The alternative (artistic) formulation of Disney is to set F90 = 0.5:
    // f_d = A / Pi * F_Transm_Schlick(0, 0.5, NdotL) * F_Transm_Schlick(0, 0.5, NdotV) + f_retro_reflection.
    // That way, darkening at grading angles is reduced to 0.5.
    // In practice, applying F_Transm_Schlick(F0, F90, NdotV) after the SSS pass is expensive,
    // as it forces us to read the normal buffer at the end of the SSS pass.
    // Separating f_retro_reflection also has a small cost (mostly due to energy compensation
    // for multi-bounce GGX), and the visual difference is negligible.
    // Therefore, we choose not to separate diffuse lighting into reflected and transmitted.
    float diffuseTerm = DisneyDiffuse(NdotV, NdotL, LdotV, bsdfData.perceptualRoughness);
#endif

    // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
    diffuseLighting = diffuseTerm;
}

// Currently, we only model diffuse transmission. Specular transmission is not yet supported.
// We assume that the back side of the object is a uniformly illuminated infinite plane
// with the reversed normal (and the view vector) of the current sample.
float3 EvaluateTransmission(BSDFData bsdfData, float intensity, float shadow)
{
    // For low thickness, we can reuse the shadowing status for the back of the object.
    shadow = bsdfData.useThinObjectMode ? shadow : 1;

    float backLight = intensity * shadow;

    return backLight * bsdfData.transmittance; // Premultiplied with the diffuse color
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_Directional (supports directional and box projector lights)
//-----------------------------------------------------------------------------

float4 EvaluateCookie_Directional(LightLoopContext lightLoopContext, DirectionalLightData lightData,
                                  float3 lighToSample)
{
    // Compute the NDC position (in [-1, 1]^2) by projecting 'positionWS' onto the near plane.
    // 'lightData.right' and 'lightData.up' are pre-scaled on CPU.
    float3x3 lightToWorld = float3x3(lightData.right, lightData.up, lightData.forward);
    float3   positionLS   = mul(lighToSample, transpose(lightToWorld));
    float2   positionNDC  = positionLS.xy;

    bool isInBounds;

    // Remap the texture coordinates from [-1, 1]^2 to [0, 1]^2.
    float2 coord = positionNDC * 0.5 + 0.5;

    if (lightData.tileCookie)
    {
        // Tile the texture if the 'repeat' wrap mode is enabled.
        coord = frac(coord);
        isInBounds = true;
    }
    else
    {
        isInBounds = Max3(abs(positionNDC.x), abs(positionNDC.y), 1.0 - positionLS.z) <= 1.0;
    }

    // We let the sampler handle tiling or clamping to border.
    // Note: tiling (the repeat mode) is not currently supported.
    float4 cookie = SampleCookie2D(lightLoopContext, coord, lightData.cookieIndex);

    cookie.a = isInBounds ? cookie.a : 0.0;

    return cookie;
}

DirectLighting EvaluateBSDF_Directional(    LightLoopContext lightLoopContext,
                                            float3 V, PositionInputs posInput, PreLightData preLightData,
                                            DirectionalLightData lightData, BSDFData bsdfData, BakeLightingData bakeLightingData)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 positionWS = posInput.positionWS;

    float3 L = -lightData.forward; // Lights are pointing backward in Unity
    float NdotL = dot(bsdfData.normalWS, L);
    float illuminance = saturate(NdotL);

    float shadow = 1.0;
    float shadowMask = 1.0;
#ifdef SHADOWS_SHADOWMASK
    // shadowMaskSelector.x is -1 if there is no shadow mask
    // Note that we override shadow value (in case we don't have any dynamic shadow)
    shadow = shadowMask = (lightData.shadowMaskSelector.x >= 0.0) ? dot(bakeLightingData.bakeShadowMask, lightData.shadowMaskSelector) : 1.0;
#endif

    [branch] if (lightData.shadowIndex >= 0)
    {
#ifdef _SURFACE_TYPE_TRANSPARENT
        shadow = GetDirectionalShadowAttenuation(lightLoopContext.shadowContext, positionWS, bsdfData.normalWS, lightData.shadowIndex, L, posInput.unPositionSS);
#else
        shadow = LOAD_TEXTURE2D(_DeferredShadowTexture, posInput.unPositionSS).x;
#endif

#ifdef SHADOWS_SHADOWMASK
        float fade = saturate(posInput.depthVS * lightData.fadeDistanceScaleAndBias.x + lightData.fadeDistanceScaleAndBias.y);

        // See comment in EvaluateBSDF_Punctual
        shadow = lightData.dynamicShadowCasterOnly ? min(shadowMask, shadow) : shadow;
        shadow = lerp(shadow, shadowMask, fade); // Caution to lerp parameter: fade is the reverse of shadowDimmer

        // Note: There is no shadowDimmer when there is no shadow mask
#endif
    }

    illuminance *= shadow;

    [branch] if (lightData.cookieIndex >= 0)
    {
        float3 lightToSurface = positionWS - lightData.positionWS;
        float4 cookie = EvaluateCookie_Directional(lightLoopContext, lightData, lightToSurface);

        // Premultiply.
        lightData.color         *= cookie.rgb;
        lightData.diffuseScale  *= cookie.a;
        lightData.specularScale *= cookie.a;
    }

    [branch] if (illuminance > 0.0)
    {
        BSDF(V, L, positionWS, preLightData, bsdfData, lighting.diffuse, lighting.specular);

        lighting.diffuse *= illuminance * lightData.diffuseScale;
        lighting.specular *= illuminance * lightData.specularScale;
    }

    [branch] if (bsdfData.enableTransmission)
    {
        // Apply wrapped lighting to better handle thin objects (cards) at grazing angles.
        float wrappedNdotL = ComputeWrappedDiffuseLighting(-NdotL, SSS_WRAP_LIGHT);

    #ifdef LIT_DIFFUSE_LAMBERT_BRDF
        illuminance  = Lambert() * wrappedNdotL;
    #else
        float tNdotL = saturate(-NdotL);
        float  NdotV = preLightData.NdotV;
        illuminance  = INV_PI * F_Transm_Schlick(0, 0.5, NdotV) * F_Transm_Schlick(0, 0.5, tNdotL) * wrappedNdotL;
    #endif

        // We use diffuse lighting for accumulation since it is going to be blurred during the SSS pass.
        // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
        lighting.diffuse += EvaluateTransmission(bsdfData, illuminance * lightData.diffuseScale, shadow);
    }

    // Save ALU by applying 'lightData.color' only once.
    lighting.diffuse *= lightData.color;
    lighting.specular *= lightData.color;

    return lighting;
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_Punctual (supports spot, point and projector lights)
//-----------------------------------------------------------------------------

float4 EvaluateCookie_Punctual(LightLoopContext lightLoopContext, LightData lightData,
                               float3 lighToSample)
{
    int lightType = lightData.lightType;

    // Translate and rotate 'positionWS' into the light space.
    // 'lightData.right' and 'lightData.up' are pre-scaled on CPU.
    float3x3 lightToWorld = float3x3(lightData.right, lightData.up, lightData.forward);
    float3   positionLS   = mul(lighToSample, transpose(lightToWorld));

    float4 cookie;

    [branch] if (lightType == GPULIGHTTYPE_POINT)
    {
        cookie = SampleCookieCube(lightLoopContext, positionLS, lightData.cookieIndex);
    }
    else
    {
        // Compute the NDC position (in [-1, 1]^2) by projecting 'positionWS' onto the plane at 1m distance.
        // Box projector lights require no perspective division.
        float  perspectiveZ = (lightType != GPULIGHTTYPE_PROJECTOR_BOX) ? positionLS.z : 1;
        float2 positionNDC  = positionLS.xy / perspectiveZ;
        bool   isInBounds   = Max3(abs(positionNDC.x), abs(positionNDC.y), 1 - positionLS.z) <= 1;

        // Remap the texture coordinates from [-1, 1]^2 to [0, 1]^2.
        float2 coord = positionNDC * 0.5 + 0.5;

        // We let the sampler handle clamping to border.
        cookie = SampleCookie2D(lightLoopContext, coord, lightData.cookieIndex);
        cookie.a = isInBounds ? cookie.a : 0;
    }

    return cookie;
}

float GetPunctualShapeAttenuation(LightData lightData, float3 L, float distSq)
{
    // Note: lightData.invSqrAttenuationRadius is 0 when applyRangeAttenuation is false
    float attenuation = GetDistanceAttenuation(distSq, lightData.invSqrAttenuationRadius);
    // Reminder: lights are oriented backward (-Z)
    return attenuation * GetAngleAttenuation(L, -lightData.forward, lightData.angleScale, lightData.angleOffset);
}

DirectLighting EvaluateBSDF_Punctual(   LightLoopContext lightLoopContext,
                                        float3 V, PositionInputs posInput,
                                        PreLightData preLightData, LightData lightData, BSDFData bsdfData, BakeLightingData bakeLightingData, int GPULightType)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 positionWS = posInput.positionWS;
    int    lightType  = GPULightType;

    // All punctual light type in the same formula, attenuation is neutral depends on light type.
    // light.positionWS is the normalize light direction in case of directional light and invSqrAttenuationRadius is 0
    // mean dot(unL, unL) = 1 and mean GetDistanceAttenuation() will return 1
    // For point light and directional GetAngleAttenuation() return 1

    float3 lightToSurface = positionWS - lightData.positionWS;
    float3 unL    = -lightToSurface;
    float  distSq = dot(unL, unL);
    float  dist   = sqrt(distSq);
    float3 L      = (lightType != GPULIGHTTYPE_PROJECTOR_BOX) ? unL * rsqrt(distSq) : -lightData.forward;
    float  NdotL  = dot(bsdfData.normalWS, L);
    float  illuminance = saturate(NdotL);

    float attenuation = GetPunctualShapeAttenuation(lightData, L, distSq);

    // Premultiply.
    lightData.diffuseScale  *= attenuation;
    lightData.specularScale *= attenuation;

    float shadow = 1.0;
    float shadowMask = 1.0;
#ifdef SHADOWS_SHADOWMASK
    // shadowMaskSelector.x is -1 if there is no shadow mask
    // Note that we override shadow value (in case we don't have any dynamic shadow)
    shadow = shadowMask = (lightData.shadowMaskSelector.x >= 0.0) ? dot(bakeLightingData.bakeShadowMask, lightData.shadowMaskSelector) : 1.0;
#endif

    [branch] if (lightData.shadowIndex >= 0)
    {
        // TODO: make projector lights cast shadows.
        float3 offset = float3(0.0, 0.0, 0.0); // GetShadowPosOffset(nDotL, normal);
        float4 L_dist = { L, dist };
        shadow = GetPunctualShadowAttenuation(lightLoopContext.shadowContext, positionWS + offset, bsdfData.normalWS, lightData.shadowIndex, L_dist, posInput.unPositionSS);
#ifdef SHADOWS_SHADOWMASK
        // Note: Legacy Unity have two shadow mask mode. ShadowMask (ShadowMask contain static objects shadow and ShadowMap contain only dynamic objects shadow, final result is the minimun of both value)
        // and ShadowMask_Distance (ShadowMask contain static objects shadow and ShadowMap contain everything and is blend with ShadowMask based on distance (Global distance setup in QualitySettigns)).
        // HDRenderPipeline change this behavior. Only ShadowMask mode is supported but we support both blend with distance AND minimun of both value. Distance is control by light.
        // The following code do this.
        // The min handle the case of having only dynamic objects in the ShadowMap
        // The second case for blend with distance is handled with ShadowDimmer. ShadowDimmer is define manually and by shadowDistance by light.
        // With distance, ShadowDimmer become one and only the ShadowMask appear, we get the blend with distance behavior.
        shadow = lightData.dynamicShadowCasterOnly ? min(shadowMask, shadow) : shadow;
        shadow = lerp(shadowMask, shadow, lightData.shadowDimmer);
#else
        shadow = lerp(1.0, shadow, lightData.shadowDimmer);
#endif
    }

    illuminance *= shadow;

    // Projector lights always have a cookies, so we can perform clipping inside the if().
    [branch] if (lightData.cookieIndex >= 0)
    {
        float4 cookie = EvaluateCookie_Punctual(lightLoopContext, lightData, lightToSurface);

        // Premultiply.
        lightData.color         *= cookie.rgb;
        lightData.diffuseScale  *= cookie.a;
        lightData.specularScale *= cookie.a;
    }

    [branch] if (illuminance > 0.0)
    {
        bsdfData.roughness = max(bsdfData.roughness, lightData.minRoughness); // Simulate that a punctual light have a radius with this hack
        BSDF(V, L, positionWS, preLightData, bsdfData, lighting.diffuse, lighting.specular);

        lighting.diffuse *= illuminance * lightData.diffuseScale;
        lighting.specular *= illuminance * lightData.specularScale;
    }

    [branch] if (bsdfData.enableTransmission)
    {
        // Apply wrapped lighting to better handle thin objects (cards) at grazing angles.
        float wrappedNdotL = ComputeWrappedDiffuseLighting(-NdotL, SSS_WRAP_LIGHT);

    #ifdef LIT_DIFFUSE_LAMBERT_BRDF
        illuminance  = Lambert() * wrappedNdotL;
    #else
        float tNdotL = saturate(-NdotL);
        float  NdotV = preLightData.NdotV;
        illuminance  = INV_PI * F_Transm_Schlick(0, 0.5, NdotV) * F_Transm_Schlick(0, 0.5, tNdotL) * wrappedNdotL;
    #endif

        // We use diffuse lighting for accumulation since it is going to be blurred during the SSS pass.
        // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
        lighting.diffuse += EvaluateTransmission(bsdfData, illuminance * lightData.diffuseScale, shadow);
    }

    // Save ALU by applying 'lightData.color' only once.
    lighting.diffuse *= lightData.color;
    lighting.specular *= lightData.color;

    return lighting;
}

#include "LitReference.hlsl"

//-----------------------------------------------------------------------------
// EvaluateBSDF_Line - Approximation with Linearly Transformed Cosines
//-----------------------------------------------------------------------------

DirectLighting EvaluateBSDF_Line(   LightLoopContext lightLoopContext,
                                    float3 V, PositionInputs posInput,
                                    PreLightData preLightData, LightData lightData, BSDFData bsdfData, BakeLightingData bakeLightingData)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 positionWS = posInput.positionWS;

#ifdef LIT_DISPLAY_REFERENCE_AREA
    IntegrateBSDF_LineRef(V, positionWS, preLightData, lightData, bsdfData,
                          lighting.diffuse, lighting.specular);
#else
    float  len = lightData.size.x;
    float3 T   = lightData.right;

    float3 unL = lightData.positionWS - positionWS;

    // Pick the major axis of the ellipsoid.
    float3 axis = lightData.right;

    // We define the ellipsoid s.t. r1 = (r + len / 2), r2 = r3 = r.
    // TODO: This could be precomputed.
    float radius         = rsqrt(lightData.invSqrAttenuationRadius);
    float invAspectRatio = radius / (radius + (0.5 * len));

    // Compute the light attenuation.
    float intensity = GetEllipsoidalDistanceAttenuation(unL,  lightData.invSqrAttenuationRadius,
                                                        axis, invAspectRatio);

    // Terminate if the shaded point is too far away.
    if (intensity == 0.0)
        return lighting;

    lightData.diffuseScale  *= intensity;
    lightData.specularScale *= intensity;

    // Translate the light s.t. the shaded point is at the origin of the coordinate system.
    lightData.positionWS -= positionWS;

    // TODO: some of this could be precomputed.
    float3 P1 = lightData.positionWS - T * (0.5 * len);
    float3 P2 = lightData.positionWS + T * (0.5 * len);

    // Rotate the endpoints into the local coordinate system.
    P1 = mul(P1, transpose(preLightData.orthoBasisViewNormal));
    P2 = mul(P2, transpose(preLightData.orthoBasisViewNormal));

    // Compute the binormal in the local coordinate system.
    float3 B = normalize(cross(P1, P2));

    float ltcValue;

    // Evaluate the diffuse part
    {
        ltcValue  = LTCEvaluate(P1, P2, B, preLightData.ltcTransformDiffuse);
        ltcValue *= lightData.diffuseScale;
        // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
        lighting.diffuse = preLightData.ltcMagnitudeDiffuse * ltcValue;
    }

    [branch] if (bsdfData.enableTransmission)
    {
        // Flip the view vector and the normal. The bitangent stays the same.
        float3x3 flipMatrix = float3x3(-1,  0,  0,
                                        0,  1,  0,
                                        0,  0, -1);

        // Use the Lambertian approximation for performance reasons.
        // The matrix multiplication should not generate any extra ALU on GCN.
        ltcValue  = LTCEvaluate(P1, P2, B, mul(flipMatrix, k_identity3x3));
        ltcValue *= lightData.diffuseScale;

        // We use diffuse lighting for accumulation since it is going to be blurred during the SSS pass.
        // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
        lighting.diffuse += EvaluateTransmission(bsdfData, ltcValue, 1);
    }

    // Evaluate the coat part
    if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    {
        // TODO
        // ltcValue  = LTCEvaluate(P1, P2, B, preLightData.ltcXformClearCoat);
        // ltcValue *= lightData.specularScale;
        // specularLighting = preLightData.ltcClearCoatFresnelTerm * (ltcValue * bsdfData.coatCoverage);
    }

    // Evaluate the specular part
    {
        ltcValue  = LTCEvaluate(P1, P2, B, preLightData.ltcTransformSpecular);
        ltcValue *= lightData.specularScale;
        lighting.specular += preLightData.ltcMagnitudeFresnel * ltcValue;
    }

    // Save ALU by applying 'lightData.color' only once.
    lighting.diffuse *= lightData.color;
    lighting.specular *= lightData.color;
#endif // LIT_DISPLAY_REFERENCE_AREA

    return lighting;
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_Area - Approximation with Linearly Transformed Cosines
//-----------------------------------------------------------------------------

// #define ELLIPSOIDAL_ATTENUATION

DirectLighting EvaluateBSDF_Rect(   LightLoopContext lightLoopContext,
                                    float3 V, PositionInputs posInput,
                                    PreLightData preLightData, LightData lightData, BSDFData bsdfData, BakeLightingData bakeLightingData)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 positionWS = posInput.positionWS;

#ifdef LIT_DISPLAY_REFERENCE_AREA
    IntegrateBSDF_AreaRef(V, positionWS, preLightData, lightData, bsdfData,
                          lighting.diffuse, lighting.specular);
#else
    float3 unL = lightData.positionWS - positionWS;

    if (dot(lightData.forward, unL) >= 0.0001)
    {
        // The light is back-facing.
        return lighting;
    }

    // Rotate the light direction into the light space.
    float3x3 lightToWorld = float3x3(lightData.right, lightData.up, -lightData.forward);
    unL = mul(unL, transpose(lightToWorld));

    // TODO: This could be precomputed.
    float halfWidth  = lightData.size.x * 0.5;
    float halfHeight = lightData.size.y * 0.5;

    // Define the dimensions of the attenuation volume.
    // TODO: This could be precomputed.
    float  radius     = rsqrt(lightData.invSqrAttenuationRadius);
    float3 invHalfDim = rcp(float3(radius + halfWidth,
                                   radius + halfHeight,
                                   radius));

    // Compute the light attenuation.
#ifdef ELLIPSOIDAL_ATTENUATION
    // The attenuation volume is an axis-aligned ellipsoid s.t.
    // r1 = (r + w / 2), r2 = (r + h / 2), r3 = r.
    float intensity = GetEllipsoidalDistanceAttenuation(unL, invHalfDim);
#else
    // The attenuation volume is an axis-aligned box s.t.
    // hX = (r + w / 2), hY = (r + h / 2), hZ = r.
    float intensity = GetBoxDistanceAttenuation(unL, invHalfDim);
#endif

    // Terminate if the shaded point is too far away.
    if (intensity == 0.0)
        return lighting;

    lightData.diffuseScale  *= intensity;
    lightData.specularScale *= intensity;

    // Translate the light s.t. the shaded point is at the origin of the coordinate system.
    lightData.positionWS -= positionWS;

    float4x3 lightVerts;

    // TODO: some of this could be precomputed.
    lightVerts[0] = lightData.positionWS + lightData.right *  halfWidth + lightData.up *  halfHeight;
    lightVerts[1] = lightData.positionWS + lightData.right *  halfWidth + lightData.up * -halfHeight;
    lightVerts[2] = lightData.positionWS + lightData.right * -halfWidth + lightData.up * -halfHeight;
    lightVerts[3] = lightData.positionWS + lightData.right * -halfWidth + lightData.up *  halfHeight;

    // Rotate the endpoints into the local coordinate system.
    lightVerts = mul(lightVerts, transpose(preLightData.orthoBasisViewNormal));

    float ltcValue;

    // Evaluate the diffuse part
    {
        // Polygon irradiance in the transformed configuration.
        ltcValue  = PolygonIrradiance(mul(lightVerts, preLightData.ltcTransformDiffuse));
        ltcValue *= lightData.diffuseScale;
        // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
        lighting.diffuse = preLightData.ltcMagnitudeDiffuse * ltcValue;
    }

    [branch] if (bsdfData.enableTransmission)
    {
        // Flip the view vector and the normal. The bitangent stays the same.
        float3x3 flipMatrix = float3x3(-1,  0,  0,
                                        0,  1,  0,
                                        0,  0, -1);

        // Use the Lambertian approximation for performance reasons.
        // The matrix multiplication should not generate any extra ALU on GCN.
        float3x3 ltcTransform = mul(flipMatrix, k_identity3x3);

        // Polygon irradiance in the transformed configuration.
        ltcValue  = PolygonIrradiance(mul(lightVerts, ltcTransform));
        ltcValue *= lightData.diffuseScale;

        // We use diffuse lighting for accumulation since it is going to be blurred during the SSS pass.
        // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
        lighting.diffuse += EvaluateTransmission(bsdfData, ltcValue, 1);
    }

    // Evaluate the coat part
    if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    {
        // TODO
        // ltcValue = LTCEvaluate(lightVerts, V, bsdfData.coatNormalWS, preLightData.coatNdotV, preLightData.ltcXformClearCoat);
        // lighting.specular = preLightData.ltcClearCoatFresnelTerm  * (ltcValue * bsdfData.coatCoverage);

        // modify matL value based on Fresnel transmission
        // matL = mul(matL, preLightData.ltcCoatT);

        // V = preLightData.refractV;
    }

    // Evaluate the specular part
    {
        // Polygon irradiance in the transformed configuration.
        ltcValue  = PolygonIrradiance(mul(lightVerts, preLightData.ltcTransformSpecular));
        ltcValue *= lightData.specularScale;
        lighting.specular += preLightData.ltcMagnitudeFresnel * ltcValue;
    }

    // Save ALU by applying 'lightData.color' only once.
    lighting.diffuse *= lightData.color;
    lighting.specular *= lightData.color;
#endif // LIT_DISPLAY_REFERENCE_AREA

    return lighting;
}

DirectLighting EvaluateBSDF_Area(   LightLoopContext lightLoopContext,
                                    float3 V, PositionInputs posInput,
                                    PreLightData preLightData, LightData lightData, BSDFData bsdfData, BakeLightingData bakeLightingData, int GPULightType)
{
    if (GPULightType == GPULIGHTTYPE_LINE)
    {
        return EvaluateBSDF_Line(lightLoopContext, V, posInput, preLightData, lightData, bsdfData, bakeLightingData);
    }
    else
    {
        return EvaluateBSDF_Rect(lightLoopContext, V, posInput, preLightData, lightData, bsdfData, bakeLightingData);
    }
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_SSLighting for screen space lighting
// ----------------------------------------------------------------------------

IndirectLighting EvaluateBSDF_SSReflection(LightLoopContext lightLoopContext,
                                            float3 V, PositionInputs posInput,
                                            PreLightData preLightData, BSDFData bsdfData,
                                            inout float hierarchyWeight)
{
    IndirectLighting lighting;
    ZERO_INITIALIZE(IndirectLighting, lighting);

    // TODO

    return lighting;
}

IndirectLighting EvaluateBSDF_SSRefraction(LightLoopContext lightLoopContext,
                                            float3 V, PositionInputs posInput,
                                            PreLightData preLightData, BSDFData bsdfData,
                                            inout float hierarchyWeight)
{
    IndirectLighting lighting;
    ZERO_INITIALIZE(IndirectLighting, lighting);

#if HAS_REFRACTION
    // Refraction process:
    //  1. Depending on the shape model, we calculate the refracted point in world space and the optical depth
    //  2. We calculate the screen space position of the refracted point
    //  3. If this point is available (ie: in color buffer and point is not in front of the object)
    //    a. Get the corresponding color depending on the roughness from the gaussian pyramid of the color buffer
    //    b. Multiply by the transmittance for absorption (depends on the optical depth)

    float3 refractedBackPointWS = EstimateRaycast(V, posInput, preLightData.transmissionPositionWS, preLightData.transmissionRefractV);

    // Calculate screen space coordinates of refracted point in back plane
    float4 refractedBackPointCS = mul(UNITY_MATRIX_VP, float4(refractedBackPointWS, 1.0));
    float2 refractedBackPointSS = ComputeScreenSpacePosition(refractedBackPointCS);
    uint2 depthSize = uint2(_PyramidDepthMipSize.xy);
    float refractedBackPointDepth = LinearEyeDepth(LOAD_TEXTURE2D_LOD(_PyramidDepthTexture, refractedBackPointSS * depthSize, 0).r, _ZBufferParams);

    // Exit if texel is out of color buffer
    // Or if the texel is from an object in front of the object
    if (refractedBackPointDepth < posInput.depthVS
        || any(refractedBackPointSS < 0.0)
        || any(refractedBackPointSS > 1.0))
    {
        // Do nothing and don't update the hierarchy weight so we can fall back on refraction probe
        return lighting;
    }

    // Map the roughness to the correct mip map level of the color pyramid
    lighting.specularTransmitted = SAMPLE_TEXTURE2D_LOD(_GaussianPyramidColorTexture, s_trilinear_clamp_sampler, refractedBackPointSS, preLightData.transmissionSSMipLevel).rgb;

    // Beer-Lamber law for absorption
    lighting.specularTransmitted *= preLightData.transmissionTransmittance;

    float weight = 1.0;
    UpdateLightingHierarchyWeights(hierarchyWeight, weight); // Shouldn't be needed, but safer in case we decide to change hierarchy priority
    // We use specularFGD as an approximation of the fresnel effect (that also handle smoothness), so take the remaining for transmission
    lighting.specularTransmitted *= (1.0 - preLightData.specularFGD) * weight;
#else
    // No refraction, no need to go further
    hierarchyWeight = 1.0;
#endif

    return lighting;
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_Env
// ----------------------------------------------------------------------------

// _preIntegratedFGD and _CubemapLD are unique for each BRDF
IndirectLighting EvaluateBSDF_Env(  LightLoopContext lightLoopContext,
                                    float3 V, PositionInputs posInput,
                                    PreLightData preLightData, EnvLightData lightData, BSDFData bsdfData, int envShapeType, int GPUImageBasedLightingType,
                                    inout float hierarchyWeight)
{
    IndirectLighting lighting;
    ZERO_INITIALIZE(IndirectLighting, lighting);
#if !HAS_REFRACTION
    if (GPUImageBasedLightingType == GPUIMAGEBASEDLIGHTINGTYPE_REFRACTION)
        return lighting;
#endif

    float3 envLighting = float3(0.0, 0.0, 0.0);
    float3 positionWS = posInput.positionWS;
    float weight = 1.0;

#ifdef LIT_DISPLAY_REFERENCE_IBL

    envLighting = IntegrateSpecularGGXIBLRef(lightLoopContext, V, preLightData, lightData, bsdfData);

    // TODO: Do refraction reference (is it even possible ?)


//    #ifdef LIT_DIFFUSE_LAMBERT_BRDF
//    envLighting += IntegrateLambertIBLRef(lightData, V, bsdfData);
//    #else
//    envLighting += IntegrateDisneyDiffuseIBLRef(lightLoopContext, V, preLightData, lightData, bsdfData);
//    #endif

    weight = 1.0;

#else

    // TODO: factor this code in common, so other material authoring don't require to rewrite everything,
    // TODO: test the strech from Tomasz
    // float shrinkedRoughness = AnisotropicStrechAtGrazingAngle(bsdfData.roughness, bsdfData.perceptualRoughness, NdotV);

    // Guideline for reflection volume: In HDRenderPipeline we separate the projection volume (the proxy of the scene) from the influence volume (what pixel on the screen is affected)
    // However we add the constrain that the shape of the projection and influence volume is the same (i.e if we have a sphere shape projection volume, we have a shape influence).
    // It allow to have more coherence for the dynamic if in shader code.
    // Users can also chose to not have any projection, in this case we use the property minProjectionDistance to minimize code change. minProjectionDistance is set to huge number
    // that simulate effect of no shape projection

    float3 R = preLightData.iblDirWS;
    float3 coatR = preLightData.coatIblDirWS;

    if (GPUImageBasedLightingType == GPUIMAGEBASEDLIGHTINGTYPE_REFRACTION)
    {
        positionWS = preLightData.transmissionPositionWS;
        R = preLightData.transmissionRefractV;
    }

    // In Unity the cubemaps are capture with the localToWorld transform of the component.
    // This mean that location and orientation matter. So after intersection of proxy volume we need to convert back to world.

    // CAUTION: localToWorld is the transform use to convert the cubemap capture point to world space (mean it include the offset)
    // the center of the bounding box is thus in locals space: positionLS - offsetLS
    // We use this formulation as it is the one of legacy unity that was using only AABB box.
    float3x3 worldToLocal = transpose(float3x3(lightData.right, lightData.up, lightData.forward)); // worldToLocal assume no scaling
    float3 positionLS = positionWS - lightData.positionWS;
    positionLS = mul(positionLS, worldToLocal).xyz - lightData.offsetLS; // We want to calculate the intersection from the center of the bounding box.

    // Note: using envShapeType instead of lightData.envShapeType allow to make compiler optimization in case the type is know (like for sky)
    if (envShapeType == ENVSHAPETYPE_SPHERE)
    {
        // 1. First process the projection
        float3 dirLS = mul(R, worldToLocal);
        float sphereOuterDistance = lightData.innerDistance.x + lightData.blendDistance;
        float dist = SphereRayIntersectSimple(positionLS, dirLS, sphereOuterDistance);
        dist = max(dist, lightData.minProjectionDistance); // Setup projection to infinite if requested (mean no projection shape)
        // We can reuse dist calculate in LS directly in WS as there is no scaling. Also the offset is already include in lightData.positionWS
        R = (positionWS + dist * R) - lightData.positionWS;

        // Test again for clear code
        if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
        {
            dirLS = mul(coatR, worldToLocal);
            dist = SphereRayIntersectSimple(positionLS, dirLS, sphereOuterDistance);
            coatR = (positionWS + dist * coatR) - lightData.positionWS;
        }

        // 2. Process the influence
        float distFade = max(length(positionLS) - lightData.innerDistance.x, 0.0);
        weight = saturate(1.0 - distFade / max(lightData.blendDistance, 0.0001)); // avoid divide by zero
    }
    else if (envShapeType == ENVSHAPETYPE_BOX)
    {
        float3 dirLS = mul(R, worldToLocal);
        float3 boxOuterDistance = lightData.innerDistance + float3(lightData.blendDistance, lightData.blendDistance, lightData.blendDistance);
        float dist = BoxRayIntersectSimple(positionLS, dirLS, -boxOuterDistance, boxOuterDistance);
        dist = max(dist, lightData.minProjectionDistance); // Setup projection to infinite if requested (mean no projection shape)
        // No need to normalize for fetching cubemap
        // We can reuse dist calculate in LS directly in WS as there is no scaling. Also the offset is already include in lightData.positionWS
        R = (positionWS + dist * R) - lightData.positionWS;

        // TODO: add distance based roughness

        // Test again for clear code
        if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
        {
            dirLS = mul(coatR, worldToLocal);
            dist = BoxRayIntersectSimple(positionLS, dirLS, -boxOuterDistance, boxOuterDistance);
            coatR = (positionWS + dist * coatR) - lightData.positionWS;
        }

        // Influence volume
        // Calculate falloff value, so reflections on the edges of the volume would gradually blend to previous reflection.
        float distFade = DistancePointBox(positionLS, -lightData.innerDistance, lightData.innerDistance);
        weight = saturate(1.0 - distFade / max(lightData.blendDistance, 0.0001)); // avoid divide by zero
    }

    // Smooth weighting
    weight = Smoothstep01(weight);

    float3 F = 1.0;

    // Evaluate the Clear Coat component if needed and change the BSDF roughness to match Fresnel transmission
    if (bsdfData.materialId == MATERIALID_LIT_CLEAR_COAT && HasMaterialFeatureFlag(MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    {
        F = F_Schlick(preLightData.coatFresnel0, preLightData.coatNdotV);

        // Evaluate the Clear Coat color
        float4 preLD = SampleEnv(lightLoopContext, lightData.envIndex, coatR, 0.0);
        envLighting += F * preLD.rgb * bsdfData.coatCoverage;

        // Change the Fresnel term to account for transmission through Clear Coat and reflection on the base layer.
        F = Sqr(-F * bsdfData.coatCoverage + 1.0);
    }

    float4 preLD = SampleEnv(lightLoopContext, lightData.envIndex, R, preLightData.iblMipLevel);
    envLighting += F * preLD.rgb;

#endif

    UpdateLightingHierarchyWeights(hierarchyWeight, weight);
    envLighting *= weight;

    if (GPUImageBasedLightingType == GPUIMAGEBASEDLIGHTINGTYPE_REFLECTION)
        lighting.specularReflected = envLighting * preLightData.specularFGD;
    else
        // specular transmisted lighting is the remaining of the reflection (let's use this approx)
        lighting.specularTransmitted = (1.0 - preLightData.specularFGD) * envLighting * preLightData.transmissionTransmittance;

    return lighting;
}

//-----------------------------------------------------------------------------
// PostEvaluateBSDF
// ----------------------------------------------------------------------------

void PostEvaluateBSDF(  LightLoopContext lightLoopContext,
                        float3 V, PositionInputs posInput,
                        PreLightData preLightData, BSDFData bsdfData, BakeLightingData bakeLightingData, AggregateLighting lighting,
                        out float3 diffuseLighting, out float3 specularLighting)
{
    float3 bakeDiffuseLighting = bakeLightingData.bakeDiffuseLighting;

    // Use GTAOMultiBounce approximation for ambient occlusion (allow to get a tint from the baseColor)
#define GTAO_MULTIBOUNCE_APPROX 1

    // Note: When we ImageLoad outside of texture size, the value returned by Load is 0 (Note: On Metal maybe it clamp to value of texture which is also fine)
    // We use this property to have a neutral value for AO that doesn't consume a sampler and work also with compute shader (i.e use ImageLoad)
    // We store inverse AO so neutral is black. So either we sample inside or outside the texture it return 0 in case of neutral

    // Ambient occlusion use for indirect lighting (reflection probe, baked diffuse lighting)
    float indirectAmbientOcclusion = 1.0 - LOAD_TEXTURE2D(_AmbientOcclusionTexture, posInput.unPositionSS).x;
    // Ambient occlusion use for direct lighting (directional, punctual, area)
    float directAmbientOcclusion = lerp(1.0, indirectAmbientOcclusion, _AmbientOcclusionParam.w);

    // Add indirect diffuse + emissive (if any) - Ambient occlusion is multiply by emissive which is wrong but not a big deal
#if GTAO_MULTIBOUNCE_APPROX
    bakeDiffuseLighting *= GTAOMultiBounce(indirectAmbientOcclusion, bsdfData.diffuseColor);
#else
    bakeDiffuseLighting *= lerp(_AmbientOcclusionParam.rgb, float3(1.0, 1.0, 1.0), indirectAmbientOcclusion);
#endif

    float specularOcclusion = GetSpecularOcclusionFromAmbientOcclusion(preLightData.NdotV, indirectAmbientOcclusion, bsdfData.roughness);
    // Try to mimic multibounce with specular color. Not the point of the original formula but ok result.
    // Take the min of screenspace specular occlusion and visibility cone specular occlusion
#if GTAO_MULTIBOUNCE_APPROX
    lighting.indirect.specularReflected *= GTAOMultiBounce(min(bsdfData.specularOcclusion, specularOcclusion), bsdfData.fresnel0);
#else
    lighting.indirect.specularReflected *= lerp(_AmbientOcclusionParam.rgb, float3(1.0, 1.0, 1.0), min(bsdfData.specularOcclusion, specularOcclusion));
#endif

    lighting.direct.diffuse *=
#if GTAO_MULTIBOUNCE_APPROX
                                GTAOMultiBounce(directAmbientOcclusion, bsdfData.diffuseColor);
#else
                                lerp(_AmbientOcclusionParam.rgb, float3(1.0, 1.0, 1.0), directAmbientOcclusion);
#endif

    float3 modifiedDiffuseColor = ApplyDiffuseTexturingMode(bsdfData);

    // Apply the albedo to the direct diffuse lighting (only once). The indirect (baked)
    // diffuse lighting has already had the albedo applied in GetBakedDiffuseLigthing().
    diffuseLighting = modifiedDiffuseColor * lighting.direct.diffuse + bakeDiffuseLighting;

    // If refraction is enable we use the transmittanceMask to lerp between current diffuse lighting and refraction value
    // Physically speaking, it should be transmittanceMask should be 1, but for artistic reasons, we let the value vary
#if HAS_REFRACTION
    diffuseLighting = lerp(diffuseLighting, lighting.indirect.specularTransmitted, bsdfData.transmittanceMask);
#endif

    specularLighting = lighting.direct.specular + lighting.indirect.specularReflected;
    // Rescale the GGX to account for the multiple scattering.
    specularLighting *= 1.0 + bsdfData.fresnel0 * preLightData.energyCompensation;

#ifdef DEBUG_DISPLAY
    if (_DebugLightingMode == DEBUGLIGHTINGMODE_INDIRECT_DIFFUSE_OCCLUSION_FROM_SSAO)
    {
        diffuseLighting = indirectAmbientOcclusion;
        specularLighting = float3(0.0, 0.0, 0.0); // Disable specular lighting
    }
    else if (_DebugLightingMode == DEBUGLIGHTINGMODE_INDIRECT_SPECULAR_OCCLUSION_FROM_SSAO)
    {
        diffuseLighting = GetSpecularOcclusionFromAmbientOcclusion(preLightData.NdotV, indirectAmbientOcclusion, bsdfData.roughness);
        specularLighting = float3(0.0, 0.0, 0.0); // Disable specular lighting
    }
    #if GTAO_MULTIBOUNCE_APPROX
    else if (_DebugLightingMode == DEBUGLIGHTINGMODE_INDIRECT_DIFFUSE_GTAO_FROM_SSAO)
    {
        diffuseLighting = GTAOMultiBounce(indirectAmbientOcclusion, bsdfData.diffuseColor);
        specularLighting = float3(0.0, 0.0, 0.0); // Disable specular lighting
    }
    else if (_DebugLightingMode == DEBUGLIGHTINGMODE_INDIRECT_SPECULAR_GTAO_FROM_SSAO)
    {
        diffuseLighting = GTAOMultiBounce(specularOcclusion, bsdfData.fresnel0);
        specularLighting = float3(0.0, 0.0, 0.0); // Disable specular lighting
    }
    #endif
#endif
}

#endif // #ifdef HAS_LIGHTLOOP

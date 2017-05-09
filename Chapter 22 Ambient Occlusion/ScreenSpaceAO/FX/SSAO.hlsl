#define kernelSize  64
cbuffer cbSsao : register(b0)
{
	float4x4 gProj;
	float4x4 gInvProj;
	float4x4 gProjTex;
	float4   gOffsetVectors[kernelSize];

	// Coordinates given in view space.
	float    gOcclusionRadius    = 0.5f;
	float    gOcclusionFadeStart = 0.2f;
	float    gOcclusionFadeEnd   = 2.0f;
	float    gSurfaceEpsilon     = 0.05f;
};

Texture2D gNormalDepthMap : register(t0);
Texture2D gRandomVecMap   : register(t1);

SamplerState gSamNormalDepth : register(s0);
SamplerState gSamRandomVec   : register(s1);

static const float2 gNoiseScale = {1280.f / 4, 720.f / 4};
static const int gSampleCount = kernelSize;
static const float2 gTexCoords[6] =
{
    float2(0.0f, 1.0f),
    float2(0.0f, 0.0f),
    float2(1.0f, 0.0f),
    float2(0.0f, 1.0f),
    float2(1.0f, 0.0f),
    float2(1.0f, 1.0f)
};
 
struct VertexOut
{
    float4 PosH : SV_POSITION;
    float3 PosV : POSITION;
	float2 TexC : TEXCOORD0;
};

VertexOut VS(uint vid : SV_VertexID)
{
    VertexOut vout;

    vout.TexC = gTexCoords[vid];

    // Quad covering screen in NDC space ( near plain)
    vout.PosH = float4(2.0f*vout.TexC.x - 1.0f, 1.0f - 2.0f*vout.TexC.y, 0.0f, 1.0f);
 
    // Transform quad corners to view space near plane.
    float4 ph = mul(vout.PosH, gInvProj);
	// divide w to convert view space (after invProj z = 1, w = 1/z)
    vout.PosV = ph.xyz / ph.w;

    return vout;
}

// Determines how much the sample point q occludes the point p as a function
// of distZ.
float OcclusionFunction(float distZ)
{
	//
	// If depth(q) is "behind" depth(p), then q cannot occlude p.  Moreover, if 
	// depth(q) and depth(p) are sufficiently close, then we also assume q cannot
	// occlude p because q needs to be in front of p by Epsilon to occlude p.
	//
	// We use the following function to determine the occlusion.  
	// 
	//
	//       1.0     -------------\
	//               |           |  \
	//               |           |    \
	//               |           |      \ 
	//               |           |        \
	//               |           |          \
	//               |           |            \
	//  ------|------|-----------|-------------|---------|--> zv
	//        0     Eps          z0            z1        
	//
	
	float occlusion = 0.0f;
	if(distZ > gSurfaceEpsilon)
	{
		float fadeLength = gOcclusionFadeEnd - gOcclusionFadeStart;
		
		// Linearly decrease occlusion from 1 to 0 as distZ goes 
		// from gOcclusionFadeStart to gOcclusionFadeEnd.	
		occlusion = saturate( (gOcclusionFadeEnd-distZ)/fadeLength );
	}
	
	return occlusion;	
}

float4 PS(VertexOut pin) : SV_Target
{
	// p -- the point we are computing the ambient occlusion for.
	// n -- normal vector at p.
	// q -- a random offset from p.
	// r -- a potential occluder that might occlude p.

	// Get viewspace normal and z-coord of this pixel.  The tex-coords for
	// the fullscreen quad we drew are already in uv-space.
	float4 normalDepth = gNormalDepthMap.SampleLevel(gSamNormalDepth, pin.TexC, 0.0f);
 
	float3 normal = normalize(normalDepth.xyz);
	float pz = normalDepth.w;

	//
	// Reconstruct full view space position (x,y,z).
	// Find t such that p = t*pin.ToFarPlane.
	// p.z = t*pin.ToFarPlane.z
	// t = p.z / pin.ToFarPlane.z
	//
	float3 p = (pz/pin.PosV.z)*pin.PosV;	

	float3 randomVec = gRandomVecMap.SampleLevel(gSamRandomVec, gNoiseScale*pin.TexC, 0.0f).rgb;

	float3 tangent = normalize(randomVec - normal * dot(randomVec, normal));
	float3 bitangent = cross(normal, tangent);
	float3x3 tbn = float3x3(tangent, bitangent, normal);

	float occlusion = 0.0f;
	// Sample neighboring points about p in the hemisphere oriented by n.
	[unroll]
	for(int i = 0; i < gSampleCount; ++i)
	{
		float3 Sample = mul(gOffsetVectors[i].xyz, tbn);
		Sample = p + Sample * gOcclusionRadius;
	
		// Project q and generate projective tex-coords.  
		float4 offset = float4(Sample, 1.0f);
		offset = mul(offset, gProj);
		offset.xy /= offset.w;
		offset.xy = offset.xy * 0.5 + 0.5;
		// float4 offset = mul(float4(Sample, 1.0f), gProjTex);
		// offset /= offset.w;

		// Find the nearest depth value along the ray from the eye to q (this is not
		// the depth of q, as q is just an arbitrary point near p and might
		// occupy empty space).  To find the nearest depth we look it up in the depthmap.

		float sampleDepth = gNormalDepthMap.SampleLevel(gSamNormalDepth, offset.xy, 0.0f).a;

		// float rangeCheck = abs(pz - sampleDepth) < gOcclusionRadius ? 1.0 : 0.0;
		float rangeCheck = smoothstep(0.0, 1.0, gOcclusionRadius / abs(pz - sampleDepth));
		// float rangeCheck = 1.0f;
		occlusion += (sampleDepth <= Sample.z ? 1.0 : 0.0) * rangeCheck;
	}
	occlusion /= gSampleCount;
	
	float access = 1.0f - occlusion;

	// Sharpen the contrast of the SSAO map to make the SSAO affect more dramatic.
	return saturate(pow(access, 3.0f));
}
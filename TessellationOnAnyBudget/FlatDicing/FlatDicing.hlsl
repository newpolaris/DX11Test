//--------------------------------------------------------------------------------------
// File: FlatDicing.hlsl
//
// These shaders implement the PN-Triangles tessellation technique
//
// Contributed by the AMD Developer Relations Team
//
// Copyright (c) Microsoft Corporation. All rights reserved.
//--------------------------------------------------------------------------------------

#include "AdaptiveTessellation.hlsl"


//--------------------------------------------------------------------------------------
// Constant buffer
//--------------------------------------------------------------------------------------

cbuffer cbPNTriangles : register( b0 )
{
    float4x4    g_f4x4World;                // World matrix for object
    float4x4    g_f4x4View;                 // View matrix for object
	float4x4    g_f4x4WorldView;            // Wrold * View matrix
    float4x4    g_f4x4Projection;           // Projection matrix
    float4x4    g_f4x4ViewProjection;       // View * Projection matrix
    float4x4    g_f4x4WorldViewProjection;  // World * View * Projection matrix
    float4      g_f4LightDir;               // Light direction vector
    float4      g_f4Eye;                    // Eye
    float4      g_f4ViewVector;             // View Vector
    float4      g_f4TessFactors;            // Tessellation factors ( x=Edge, y=Inside, z=MinDistance, w=Range )
    float4      g_f4ScreenParams;           // Screen resolution ( x=Current width, y=Current height )
    float4      g_f4GUIParams1;             // GUI params1 ( x=BackFace Epsilon, y=Silhouette Epsilon, z=Range scale, w=Edge size )
    float4      g_f4GUIParams2;             // GUI params2 ( x=Screen resolution scale, y=View Frustum Epsilon )
    float4      g_f4ViewFrustumPlanes[4];   // View frustum planes ( x=left, y=right, z=top, w=bottom )
}

// Some global lighting constants
static float4 g_f4MaterialDiffuseColor  = float4( 1.0f, 1.0f, 1.0f, 1.0f );
static float4 g_f4LightDiffuse          = float4( 1.0f, 1.0f, 1.0f, 1.0f );
static float4 g_f4MaterialAmbientColor  = float4( 0.2f, 0.2f, 0.2f, 1.0f );

// Some global epsilons for adaptive tessellation
static float g_fMaxScreenWidth = 2560.0f;
static float g_fMaxScreenHeight = 1600.0f;


//--------------------------------------------------------------------------------------
// Buffers, Textures and Samplers
//--------------------------------------------------------------------------------------

// Textures
Texture2D g_txDiffuse : register( t0 );

// Samplers
SamplerState g_SamplePoint  : register( s0 );
SamplerState g_SampleLinear : register( s1 );


//--------------------------------------------------------------------------------------
// Shader structures
//--------------------------------------------------------------------------------------

struct VS_RenderSceneInput
{
    float3 f3Position   : POSITION;  
    float3 f3Normal     : NORMAL;     
    float2 f2TexCoord   : TEXCOORD;
};

struct HS_RenderSceneInput
{
    float3 f3Position   : POSITION;
    float3 f3Normal     : NORMAL;
    float2 f2TexCoord   : TEXCOORD;
};

struct HS_ConstantOutput
{
    // Tess factor for the FF HW block
    float fTessFactor[3]    : SV_TessFactor;
    float fInsideTessFactor : SV_InsideTessFactor;
    
    // Geometry cubic generated control points
    float3 f3B210    : POSITION3;
    float3 f3B120    : POSITION4;
    float3 f3B021    : POSITION5;
    float3 f3B012    : POSITION6;
    float3 f3B102    : POSITION7;
    float3 f3B201    : POSITION8;
    float3 f3B111    : CENTER;
    
    // Normal quadratic generated control points
    float3 f3N110    : NORMAL3;      
    float3 f3N011    : NORMAL4;
    float3 f3N101    : NORMAL5;
};

struct HS_ControlPointOutput
{
    float3 f3Position      : POSITION;
    float3 f3Normal        : NORMAL;
    float2 f2TexCoord      : TEXCOORD;
	float fOppositeEdgeLOD : LODDATA;
	float fClipped         : CLIPPED; // 1.0 means clipped, 0.0 means unclipped
};

struct DS_Output
{
    float4 f4Position   : SV_Position;
    float2 f2TexCoord   : TEXCOORD0;
    float4 f4Diffuse    : COLOR0;
};

struct PS_RenderSceneInput
{
    float4 f4Position   : SV_Position;
    float2 f2TexCoord   : TEXCOORD0;
    float4 f4Diffuse    : COLOR0;
};

struct PS_RenderOutput
{
    float4 f4Color      : SV_Target0;
};


//--------------------------------------------------------------------------------------
// This vertex shader computes standard transform and lighting, with no tessellation stages following
//--------------------------------------------------------------------------------------
PS_RenderSceneInput VS_RenderScene( VS_RenderSceneInput I )
{
    PS_RenderSceneInput O;
    float3 f3NormalWorldSpace;
    
    // Transform the position from object space to homogeneous projection space
    O.f4Position = mul( float4( I.f3Position, 1.0f ), g_f4x4WorldViewProjection );
    
    // Transform the normal from object space to world space    
    f3NormalWorldSpace = normalize( mul( I.f3Normal, (float3x3)g_f4x4World ) );
    
    // Calc diffuse color    
    O.f4Diffuse.rgb = g_f4MaterialDiffuseColor * g_f4LightDiffuse * max( 0, dot( f3NormalWorldSpace, g_f4LightDir.xyz ) ) + g_f4MaterialAmbientColor;  
    O.f4Diffuse.a = 1.0f;
    
    // Pass through texture coords
    O.f2TexCoord = I.f2TexCoord; 
    
    return O;    
}


//--------------------------------------------------------------------------------------
// This vertex shader is a pass through stage, with HS, tessellation, and DS stages following
//--------------------------------------------------------------------------------------
HS_RenderSceneInput VS_RenderSceneWithTessellation( VS_RenderSceneInput I )
{
    HS_RenderSceneInput O;
    
    // Pass through world space position
    O.f3Position = mul( float4(I.f3Position, 1.f), g_f4x4WorldView ).xyz;
    
    // Pass through normalized world space normal    
    O.f3Normal = normalize( mul( I.f3Normal, (float3x3)g_f4x4World ) );
        
    // Pass through texture coordinates
    O.f2TexCoord = I.f2TexCoord;
    
    return O;    
}


//--------------------------------------------------------------------------------------
// This hull shader passes the tessellation factors through to the HW tessellator, 
// and the 10 (geometry), 6 (normal) control points of the PN-triangular patch to the domain shader
//--------------------------------------------------------------------------------------
HS_ConstantOutput HS_ConstantFlat( const OutputPatch<HS_ControlPointOutput, 3> I )
{
    HS_ConstantOutput O = (HS_ConstantOutput)0;

	O.fTessFactor[0] = I[1].fOppositeEdgeLOD;
	O.fTessFactor[1] = I[2].fOppositeEdgeLOD;
	O.fTessFactor[2] = I[0].fOppositeEdgeLOD;

    // Inside tess factor is just the average of the edge factors
    O.fInsideTessFactor = max( max( O.fTessFactor[0], O.fTessFactor[1]), O.fTessFactor[2] );

	if (I[0].fClipped && I[1].fClipped && I[2].fClipped) 
	{ 
		O.fTessFactor[0] = 0; O.fTessFactor[1] = 0; O.fTessFactor[2] = 0; 
	}

    return O;
}

[domain("tri")]
[partitioning("fractional_odd")]
[outputtopology("triangle_cw")]
[patchconstantfunc("HS_ConstantFlat")]
[outputcontrolpoints(3)]
[maxtessfactor(9)]
HS_ControlPointOutput HS_FlatTriangles( 
	InputPatch<HS_RenderSceneInput, 3> I,
	uint uCPID : SV_OutputControlPointID )
{
    HS_ControlPointOutput O = (HS_ControlPointOutput)0;
	
    // Just pass through inputs = fast pass through mode triggered
    O.f3Position = I[uCPID].f3Position;
    O.f3Normal = I[uCPID].f3Normal;
    O.f2TexCoord = I[uCPID].f2TexCoord;

	O.fClipped = 0.0f;
	O.fOppositeEdgeLOD = g_f4TessFactors.x;
    
    return O;
}


//--------------------------------------------------------------------------------------
// This domain shader applies contol point weighting to the barycentric coords produced by the FF tessellator 
//--------------------------------------------------------------------------------------
[domain("tri")]
DS_Output DS_PNTriangles( HS_ConstantOutput HSConstantData, 
	const OutputPatch<HS_ControlPointOutput, 3> I,
	float3 f3BarycentricCoords : SV_DomainLocation )
{
    DS_Output O = (DS_Output)0;

	float fU = f3BarycentricCoords[0];
	float fV = f3BarycentricCoords[1];
	float fW = f3BarycentricCoords[2];
	float3 f3Position = I[0].f3Position * fW + I[1].f3Position * fU + I[2].f3Position * fV;
    float3 f3Normal = I[0].f3Normal * fW + I[1].f3Normal * fU + I[2].f3Normal * fV;

    // Normalize the interpolated normal    
    f3Normal = normalize( f3Normal );

    // Linearly interpolate the texture coords
    O.f2TexCoord = I[0].f2TexCoord * fW + I[1].f2TexCoord * fU + I[2].f2TexCoord * fV;

    // Calc diffuse color    
    O.f4Diffuse.rgb = g_f4MaterialDiffuseColor * g_f4LightDiffuse * max( 0, dot( f3Normal, g_f4LightDir.xyz ) ) + g_f4MaterialAmbientColor;  
    O.f4Diffuse.a = 1.0f; 

    // Transform model position with view-projection matrix
    O.f4Position = mul( float4( f3Position.xyz, 1.0 ), g_f4x4Projection );
        
    return O;
}


//--------------------------------------------------------------------------------------
// This shader outputs the pixel's color by passing through the lit 
// diffuse material color & modulating with the diffuse texture
//--------------------------------------------------------------------------------------
PS_RenderOutput PS_RenderSceneTextured( PS_RenderSceneInput I )
{
    PS_RenderOutput O;
    
    O.f4Color = g_txDiffuse.Sample( g_SampleLinear, I.f2TexCoord ) * I.f4Diffuse;
    
    return O;
}


//--------------------------------------------------------------------------------------
// This shader outputs the pixel's color by passing through the lit 
// diffuse material color
//--------------------------------------------------------------------------------------
PS_RenderOutput PS_RenderScene( PS_RenderSceneInput I )
{
    PS_RenderOutput O;
    
    O.f4Color = I.f4Diffuse;
    
    return O;
}


//--------------------------------------------------------------------------------------
// EOF
//--------------------------------------------------------------------------------------
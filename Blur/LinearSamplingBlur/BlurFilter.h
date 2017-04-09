//***************************************************************************************
// BlurFilter.h by Frank Luna (C) 2011 All Rights Reserved.
//
// Performs a blur operation on the topmost mip level of an input texture.
//***************************************************************************************

#ifndef BLURFILTER_H
#define BLURFILTER_H

#include <Windows.h>
#include <xnamath.h>
#include "d3dUtil.h"

class BlurFilter
{
public:
	BlurFilter();
	~BlurFilter();


	ID3D11ShaderResourceView* GetBlurredOutput();

	// Generate Gaussian blur weights.
	void SetGaussianWeights(float sigma);

	// Manually specify blur weights.
	void SetWeights(const float weights[9]);

	///<summary>
	/// The width and height should match the dimensions of the input texture to blur.
	/// It is OK to call Init() again to reinitialize the blur filter with a different 
	/// dimension or format.
	///</summary>
	void Init(ID3D11Device* device, UINT width, UINT height, DXGI_FORMAT format);

	void BuildWeight(int radius);

	void BlurInPlace(ID3D11DeviceContext * dc, ID3D11ShaderResourceView * inputSRV, ID3D11RenderTargetView* inputRTV, ID3D11DepthStencilView * depthSten, int blurCount);

	void SetShader(std::vector<ID3D11DeviceChild*> shader);

private:

	UINT mWidth;
	UINT mHeight;
	DXGI_FORMAT mFormat;

	ID3D11ShaderResourceView* mBlurredOutputTexSRV;
	ID3D11UnorderedAccessView* mBlurredOutputTexUAV;
	ID3D11RenderTargetView* mBlurredOutputTexRTV;

	std::vector<ID3D11DeviceChild*> mShader;
};

#endif // BLURFILTER_H
Shader "Learn/BilateralBlur"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }

        Cull Off ZWrite Off ZTest Always        
        CGINCLUDE
		#pragma multi_compile_local _ USE_DEPTH_TEXTURE
		// method used to downsample depth buffer: 0 = min; 1 = max; 2 = min/max in chessboard pattern
        #define DOWNSAMPLE_DEPTH_MODE 0
        #define UPSAMPLE_DEPTH_THRESHOLD 1.5f
        #define BLUR_DEPTH_FACTOR 0.5
        #define GAUSS_BLUR_DEVIATION 1.5        
        #define FULL_RES_BLUR_KERNEL_SIZE 7
        #define HALF_RES_BLUR_KERNEL_SIZE 5
        #define QUARTER_RES_BLUR_KERNEL_SIZE 6
        #define PI 3.1415927f

        #include "UnityCG.cginc"

        

		UNITY_DECLARE_TEX2D(_CameraDepthTexture);        
        UNITY_DECLARE_TEX2D(_HalfResDepthBuffer);        
        UNITY_DECLARE_TEX2D(_QuarterResDepthBuffer);        
        UNITY_DECLARE_TEX2D(_HalfResColor);
        UNITY_DECLARE_TEX2D(_QuarterResColor);
        UNITY_DECLARE_TEX2D(_MainTex);

        float4 _CameraDepthTexture_TexelSize;
        float4 _HalfResDepthBuffer_TexelSize;
        float4 _QuarterResDepthBuffer_TexelSize;

		struct appdata
        {
            float4 vertex : POSITION;
            float2 uv : TEXCOORD0;
        };

        struct v2f
        {
            float2 uv : TEXCOORD0;
            float4 vertex : SV_POSITION;
        };

		
		struct v2fDownsample
		{
#if SHADER_TARGET > 40// >4.0 的 moel 可以使用 gather 函数对周围像素进行采样，只需要当前 uv 坐标
			float2 uv : TEXCOORD0;
#else//// < 4.0 的 moel 不可以使用 gather 函数对周围像素进行采样，需要周围像素坐标
			float2 uv00 : TEXCOORD0;
			float2 uv01 : TEXCOORD1;
			float2 uv10 : TEXCOORD2;
			float2 uv11 : TEXCOORD3;
#endif
			float4 vertex : SV_POSITION;
		};

		struct v2fUpsample
		{
			float2 uv : TEXCOORD0;
			float2 uv00 : TEXCOORD1;
			float2 uv01 : TEXCOORD2;
			float2 uv10 : TEXCOORD3;
			float2 uv11 : TEXCOORD4;
			float4 vertex : SV_POSITION;
		};
		
        float GaussianWeight(float offset, float deviation)
		{
			float weight = 1.0f / sqrt(2.0f * PI * deviation * deviation);
			weight *= exp(-(offset * offset) / (2.0f * deviation * deviation));
			return weight;
		}
        
        v2f vert (appdata v)
        {
            v2f o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.uv;
            return o;
        }

		v2fDownsample vertDownsampleDepth(appdata v, float2 texelSize)
        {
	        v2fDownsample o;
        	o.vertex = UnityObjectToClipPos(v.vertex);
#if SHDER_TARGET > 40
        	o.uv = v.uv;
#else
        	o.uv00 = v.uv - 0.5 * texelSize.xy;
			o.uv10 = o.uv00 + float2(texelSize.x, 0);
			o.uv01 = o.uv00 + float2(0, texelSize.y);
			o.uv11 = o.uv00 + texelSize.xy;
#endif
        	return o;
        }

		v2fUpsample vertUpsample(appdata v, float2 texelSize)
        {
            v2fUpsample o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.uv;

            o.uv00 = v.uv - 0.5 * texelSize.xy;
            o.uv10 = o.uv00 + float2(texelSize.x, 0);
            o.uv01 = o.uv00 + float2(0, texelSize.y);
            o.uv11 = o.uv00 + texelSize.xy;
            return o;
        }


		//根据深度差来 upscale texture，当相邻像素深度差比较小时，使用双线性插值，否则使用最近邻插值
		float4 BilateralUpsample(
			v2fUpsample input,
			Texture2D hiDepth,
			Texture2D loDepth,
			Texture2D loColor,
			SamplerState linearSampler,
			SamplerState pointSampler)
        {
	        const float threshold = UPSAMPLE_DEPTH_THRESHOLD;
        	float4 highResDepth = LinearEyeDepth(hiDepth.Sample(pointSampler, input.uv)).xxxx;
        	float4 lowResDepth;

        	lowResDepth[0] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv00));
            lowResDepth[1] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv10));
            lowResDepth[2] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv01));
            lowResDepth[3] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv11));

        	float4 depthDiff = abs(lowResDepth - highResDepth);

			float accumDiff = dot(depthDiff, float4(1, 1, 1, 1));

        	//branch命令是指只执行符合条件的一则逻辑，对于其中一则逻辑复杂一则简单的情况，可以提升性能（不利于并行运算）
        	//相反，如果用 flatten 命令，分支两侧会同时进行运算，然后最终根据条件进行选择最终结果（有利于并行运算）
        	//一般情况下不指定命令，编译器会根据自己的判断选择其中一种方式，但是不是所有的编译器结果都是理想的，因此一般可以通过手动指定来达到目的
        	[branch]
			if (accumDiff < threshold) // small error, not an edge -> use bilinear filter
			{
				return loColor.Sample(linearSampler, input.uv);
			}

        	// find nearest sample
			float minDepthDiff = depthDiff[0];
			float2 nearestUv = input.uv00;

			if (depthDiff[1] < minDepthDiff)
			{
				nearestUv = input.uv10;
				minDepthDiff = depthDiff[1];
			}

			if (depthDiff[2] < minDepthDiff)
			{
				nearestUv = input.uv01;
				minDepthDiff = depthDiff[2];
			}

			if (depthDiff[3] < minDepthDiff)
			{
				nearestUv = input.uv11;
				minDepthDiff = depthDiff[3];
			}

            return loColor.Sample(pointSampler, nearestUv);
        }

		float DownsampleDepth(v2fDownsample input, Texture2D depthTexture, SamplerState depthSampler)
		{
#if SHADER_TARGET > 40
            float4 depth = depthTexture.Gather(depthSampler, input.uv);
#else
			float4 depth;
			depth.x = depthTexture.Sample(depthSampler, input.uv00).x;
			depth.y = depthTexture.Sample(depthSampler, input.uv01).x;
			depth.z = depthTexture.Sample(depthSampler, input.uv10).x;
			depth.w = depthTexture.Sample(depthSampler, input.uv11).x;

#endif

#if DOWNSAMPLE_DEPTH_MODE == 0 // min  depth
            return min(min(depth.x, depth.y), min(depth.z, depth.w));
#elif DOWNSAMPLE_DEPTH_MODE == 1 // max  depth
            return max(max(depth.x, depth.y), max(depth.z, depth.w));
#elif DOWNSAMPLE_DEPTH_MODE == 2 // min/max depth in chessboard pattern

			float minDepth = min(min(depth.x, depth.y), min(depth.z, depth.w));
			float maxDepth = max(max(depth.x, depth.y), max(depth.z, depth.w));

			// chessboard pattern
			int2 position = input.vertex.xy % 2;
			int index = position.x + position.y;
			return index == 1 ? minDepth : maxDepth;
#endif
		}

        float4 BilateralBlur(v2f input, int2 direction, Texture2D depth, SamplerState depthSampler, const int kernelRadius, float2 pixelSize)
		{
			const float deviation = kernelRadius / GAUSS_BLUR_DEVIATION;

			float2 uv = input.uv;
			float4 centerColor = _MainTex.Sample(sampler_MainTex, uv);
			float3 color = centerColor.xyz;
			//return float4(color, 1);
			float centerDepth = (LinearEyeDepth(depth.Sample(depthSampler, uv)));

			float weightSum = 0;

			// gaussian weight is computed from constants only -> will be computed in compile time
            float weight = GaussianWeight(0, deviation);
			color *= weight;
			weightSum += weight;
						
			[unroll]
        	for (int i = -kernelRadius; i < 0; i += 1)
			{
                float2 offset = (direction * i);
                float3 sampleColor = _MainTex.Sample(sampler_MainTex, input.uv, offset);
                float sampleDepth = (LinearEyeDepth(depth.Sample(depthSampler, input.uv, offset)));

				#if defined(USE_DEPTH_TEXTURE)
					float depthDiff = abs(centerDepth - sampleDepth);
	                float dFactor = depthDiff * BLUR_DEPTH_FACTOR;
					float w = exp(-(dFactor * dFactor));
				#else
					float w = 1;
				#endif
				
				

				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			[unroll]
        	for (int i = 1; i <= kernelRadius; i += 1)
			{
				float2 offset = (direction * i);
                float3 sampleColor = _MainTex.Sample(sampler_MainTex, input.uv, offset);
                float sampleDepth = (LinearEyeDepth(depth.Sample(depthSampler, input.uv, offset)));

				#if defined(USE_DEPTH_TEXTURE)
					float depthDiff = abs(centerDepth - sampleDepth);
	                float dFactor = depthDiff * BLUR_DEPTH_FACTOR;
					float w = exp(-(dFactor * dFactor));
				#else
					float w = 1;
				#endif
				
				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			color /= weightSum;
			return float4(color, centerColor.w);
		}
        ENDCG

		//Pass 0, Full Size Horizontally Blur
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment fragHorizontal
			#pragma target 4.0

            fixed4 fragHorizontal(v2f input) : SV_Target
            {
            	return BilateralBlur(input, int2(1, 0), _CameraDepthTexture, sampler_CameraDepthTexture, FULL_RES_BLUR_KERNEL_SIZE, _CameraDepthTexture_TexelSize.xy);
            }
            ENDCG
        }

		//Pass 1, Full Size Vertically Blur
		Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment fragVertical
			#pragma target 4.0

            fixed4 fragVertical(v2f input) : SV_Target
            {
            	return BilateralBlur(input, int2(0, 1), _CameraDepthTexture, sampler_CameraDepthTexture, FULL_RES_BLUR_KERNEL_SIZE, _CameraDepthTexture_TexelSize.xy);
            }
            ENDCG
        }

		// pass 2 - horizontal blur (lores)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment horizontalFrag
            #pragma target 4.0

			fixed4 horizontalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input, int2(1, 0), _HalfResDepthBuffer, sampler_HalfResDepthBuffer, HALF_RES_BLUR_KERNEL_SIZE, _HalfResDepthBuffer_TexelSize.xy);
		}

			ENDCG
		}

		// pass 3 - vertical blur (lores)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment verticalFrag
            #pragma target 4.0

			fixed4 verticalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input, int2(0, 1), _HalfResDepthBuffer, sampler_HalfResDepthBuffer, HALF_RES_BLUR_KERNEL_SIZE, _HalfResDepthBuffer_TexelSize.xy);
		}

			ENDCG
		}

		// pass 4 - downsample depth to half
		Pass
		{
			CGPROGRAM
			#pragma vertex vertHalfDepth
			#pragma fragment frag
            #pragma target gl4.1

			v2fDownsample vertHalfDepth(appdata v)
			{
                return vertDownsampleDepth(v, _CameraDepthTexture_TexelSize);
			}

			float frag(v2fDownsample input) : SV_Target
			{
                return DownsampleDepth(input, _CameraDepthTexture, sampler_CameraDepthTexture);
			}

			ENDCG
		}

		// pass 5 - bilateral upsample
		Pass
		{
			Blend One Zero

			CGPROGRAM
			#pragma vertex vertUpsampleToFull
			#pragma fragment frag		
            #pragma target 4.0

			v2fUpsample vertUpsampleToFull(appdata v)
			{
                return vertUpsample(v, _HalfResDepthBuffer_TexelSize);
			}
			float4 frag(v2fUpsample input) : SV_Target
			{
				return BilateralUpsample(input, _CameraDepthTexture, _HalfResDepthBuffer, _HalfResColor, sampler_HalfResColor, sampler_HalfResDepthBuffer);
			}

			ENDCG
		}

		// pass 6 - downsample depth to quarter
		Pass
		{
			CGPROGRAM
            #pragma vertex vertQuarterDepth
            #pragma fragment frag
            #pragma target gl4.1

			v2fDownsample vertQuarterDepth(appdata v)
			{
                return vertDownsampleDepth(v, _HalfResDepthBuffer_TexelSize);
			}

			float frag(v2fDownsample input) : SV_Target
			{
                return DownsampleDepth(input, _HalfResDepthBuffer, sampler_HalfResDepthBuffer);
			}

			ENDCG
		}

		// pass 7 - bilateral upsample quarter to full
		Pass
		{
			Blend One Zero

			CGPROGRAM
            #pragma vertex vertUpsampleToFull
            #pragma fragment frag		
            #pragma target 4.0

			v2fUpsample vertUpsampleToFull(appdata v)
			{
                return vertUpsample(v, _QuarterResDepthBuffer_TexelSize);
			}
			float4 frag(v2fUpsample input) : SV_Target
			{
                return BilateralUpsample(input, _CameraDepthTexture, _QuarterResDepthBuffer, _QuarterResColor, sampler_QuarterResColor, sampler_QuarterResDepthBuffer);
			}

			ENDCG
		}

		// pass 8 - horizontal blur (quarter res)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment horizontalFrag
            #pragma target 4.0

			fixed4 horizontalFrag(v2f input) : SV_Target
			{
                return BilateralBlur(input, int2(1, 0), _QuarterResDepthBuffer, sampler_QuarterResDepthBuffer, QUARTER_RES_BLUR_KERNEL_SIZE, _QuarterResDepthBuffer_TexelSize.xy);
			}

			ENDCG
		}

		// pass 9 - vertical blur (quarter res)
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment verticalFrag
            #pragma target 4.0

			fixed4 verticalFrag(v2f input) : SV_Target
			{
                return BilateralBlur(input, int2(0, 1), _QuarterResDepthBuffer, sampler_QuarterResDepthBuffer, QUARTER_RES_BLUR_KERNEL_SIZE, _QuarterResDepthBuffer_TexelSize.xy);
			}

			ENDCG
		}

		// pass 10 - downsample depth to half (fallback for DX10)
		Pass
		{
			CGPROGRAM
			#pragma vertex vertHalfDepth
			#pragma fragment frag
			#pragma target 4.0

			v2fDownsample vertHalfDepth(appdata v)
			{
				return vertDownsampleDepth(v, _CameraDepthTexture_TexelSize);
			}

			float frag(v2fDownsample input) : SV_Target
			{
				return DownsampleDepth(input, _CameraDepthTexture, sampler_CameraDepthTexture);
			}

			ENDCG
		}

		// pass 11 - downsample depth to quarter (fallback for DX10)
		Pass
		{
			CGPROGRAM
			#pragma vertex vertQuarterDepth
			#pragma fragment frag
			#pragma target 4.0

			v2fDownsample vertQuarterDepth(appdata v)
			{
				return vertDownsampleDepth(v, _HalfResDepthBuffer_TexelSize);
			}

			float frag(v2fDownsample input) : SV_Target
			{
				return DownsampleDepth(input, _HalfResDepthBuffer, sampler_HalfResDepthBuffer);
			}

			ENDCG
		}
    }
}

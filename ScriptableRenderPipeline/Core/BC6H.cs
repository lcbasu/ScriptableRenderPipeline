using UnityEngine.Assertions;
using UnityEngine.Rendering;

namespace UnityEngine.Experimental.Rendering
{
    public class BC6H
    {
        public static BC6H DefaultInstance;

        static readonly int _Source = Shader.PropertyToID("_Source");
        static readonly int _Target = Shader.PropertyToID("_Target");
        static readonly int _Index = Shader.PropertyToID("_Index");
        static readonly int __Tmp_RT0 = Shader.PropertyToID("__Tmp_RT0");
        static readonly int __Tmp_RT1 = Shader.PropertyToID("__Tmp_RT1");

        static readonly RenderTextureDescriptor k_CubemapToRTArrayDescriptor = new RenderTextureDescriptor
        {
            autoGenerateMips = false,
            bindMS = false,
            colorFormat = RenderTextureFormat.ARGBHalf,
            depthBufferBits = 0,
            dimension = TextureDimension.Tex2DArray,
            enableRandomWrite = true,
            sRGB = false,
            volumeDepth = 6,
            useMipMap = false,
            msaaSamples = 1
        };

        readonly ComputeShader m_Shader;
        readonly int m_KernelEncodeFast;
        readonly int[] m_KernelEncodeFastGroupSize;

        public BC6H(ComputeShader shader)
        {
            Assert.IsNotNull(shader);

            m_Shader = shader;
            m_KernelEncodeFast = m_Shader.FindKernel("KEncodeFastCubemap");

            uint x, y, z;
            m_Shader.GetKernelThreadGroupSizes(m_KernelEncodeFast, out x, out y, out z);
            m_KernelEncodeFastGroupSize = new[] { (int)x, (int)y, (int)z };
        }

        // Only use mode11 of BC6H encoding
        public void EncodeFastCubemap(CommandBuffer cmb, RenderTargetIdentifier source, int sourceSize, RenderTargetIdentifier target)
        {
            int targetWidth, targetHeight;
            CalculateOutputSize(sourceSize, sourceSize, out targetWidth, out targetHeight);

            // Convert TextureCube source to Texture2DArray
            var cubemapToTexture2DArrayDescriptor = k_CubemapToRTArrayDescriptor;
            cubemapToTexture2DArrayDescriptor.width = sourceSize;
            cubemapToTexture2DArrayDescriptor.height = sourceSize;
            cmb.GetTemporaryRT(__Tmp_RT0, cubemapToTexture2DArrayDescriptor);

            for (var i = 0; i < 6; i++)
                cmb.CopyTexture(source, i, __Tmp_RT0, i);

            cmb.SetComputeTextureParam(m_Shader, m_KernelEncodeFast, _Source, __Tmp_RT0); 
            cmb.SetComputeTextureParam(m_Shader, m_KernelEncodeFast, _Target, target);
            cmb.DispatchCompute(m_Shader, m_KernelEncodeFast, targetWidth, targetHeight, 6);

            cmb.ReleaseTemporaryRT(__Tmp_RT0);
        }

        static void CalculateOutputSize(int swidth, int sheight, out int twidth, out int theight)
        {
            // BC6H encode 4x4 blocks of 32bit in 128bit
            twidth = swidth >> 2;
            theight = sheight >> 2;
        }
    }

    public static class BC6HExtensions
    {
        //public static void BC6HEncodeFastCubemap(this CommandBuffer cmb, RenderTargetIdentifier source, int sourceSize, RenderTargetIdentifier target)
        //{
        //    BC6H.DefaultInstance.EncodeFastCubemap(cmb, source, sourceSize, target);
        //}
    }
}
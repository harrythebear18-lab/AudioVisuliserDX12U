using System.Numerics;
using System.Runtime.InteropServices;
using Vortice.Direct3D12;
using Vortice.DXGI;
using DebugLogger = DXRenderer.DebugLogger;

namespace DXRenderer;

#region OpenXR Constants & Enums

internal enum XrStructureType : uint
{
    InstanceCreateInfo = 2,
    InstanceProperties = 3,
    SystemGetInfo = 5,
    SystemProperties = 6,
    SessionCreateInfo = 8,
    SessionBeginInfo = 9,
    Space = 11,
    ReferenceSpaceCreateInfo = 12,
    ViewConfigurationProperties = 13,
    ViewConfigurationView = 14,
    SwapchainCreateInfo = 16,
    SwapchainImageD3D12KHR = 100001001,
    GraphicsBindingD3D12KHR = 100008001,
    CompositionLayerProjection = 19,
    CompositionLayerProjectionView = 20,
    CompositionLayerDepthInfoKHR = 100001000,
    FrameBeginInfo = 21,
    FrameEndInfo = 22,
    FrameState = 23,
    ViewLocateInfo = 24,
    View = 25,
    EventBuffer = 26,
    HapticVibration = 51,
}

internal enum XrFormFactor : uint
{
    HeadMountedDisplay = 1,
}

internal enum XrViewConfigurationType : uint
{
    PrimaryStereo = 1,
}

internal enum XrReferenceSpaceType : uint
{
    View = 1,
    Local = 2,
    Stage = 3,
}

internal enum XrEnvironmentBlendMode : uint
{
    Opaque = 1,
    AlphaBlend = 2,
    Additive = 3,
}

internal enum XrSessionState : uint
{
    Unknown = 0,
    Idle = 1,
    Ready = 2,
    Synchronized = 3,
    Visible = 4,
    Focused = 5,
    Stopping = 6,
    LossPending = 7,
    Exiting = 8,
}

internal enum XrResult : uint
{
    Success = 0,
    TimeoutExpired = 1,
    SessionLossPending = 3,
    EventUnavailable = 7,
    SpaceUnavailable = 8,
    FormFactorUnavailable = 25,
    FormFactorUnsupported = 26,
    SystemUnsupported = 27,
    GraphicsDeviceInvalid = 32,
    ErrorValidationFailure = 0xFFFF0001,
    ErrorRuntimeFailure = 0xFFFF0002,
    ErrorOutOfMemory = 0xFFFF0003,
    ErrorApiVersionUnsupported = 0xFFFF0004,
    ErrorInitializationFailed = 0xFFFF0006,
    ErrorFunctionUnsupported = 0xFFFF0007,
    ErrorFeatureUnsupported = 0xFFFF0008,
    ErrorLimitReached = 0xFFFF0009,
    ErrorSizeInsufficient = 0xFFFF000A,
    ErrorHandleInvalid = 0xFFFF000B,
    ErrorInstanceLost = 0xFFFF000C,
    ErrorSessionRunning = 0xFFFF000E,
    ErrorSessionNotRunning = 0xFFFF000F,
    ErrorSessionLost = 0xFFFF0010,
    ErrorSystemInvalid = 0xFFFF0011,
    ErrorPathInvalid = 0xFFFF0012,
    ErrorPathCountInsufficient = 0xFFFF0013,
    ErrorPathUnsupported = 0xFFFF0014,
    ErrorLayerInvalid = 0xFFFF0015,
    ErrorLayerLimitReached = 0xFFFF0016,
    ErrorSwapchainRectInvalid = 0xFFFF0017,
    ErrorSwapchainFormatUnsupported = 0xFFFF0018,
    ErrorActiontypeMismatch = 0xFFFF0019,
    ErrorSessionNotReady = 0xFFFF001A,
    ErrorSessionNotStopped = 0xFFFF001B,
    ErrorTimeInvalid = 0xFFFF001C,
    ErrorReferenceSpaceUnsupported = 0xFFFF001D,
    ErrorFileAccessError = 0xFFFF001E,
    ErrorFileContentsInvalid = 0xFFFF001F,
    ErrorFormFactorUnsupported = 0xFFFF0020,
    ErrorFormFactorUnavailable = 0xFFFF0021,
    ErrorEnvironmentBlendModeUnsupported = 0xFFFF0022,
    ErrorNameInvalid = 0xFFFF0023,
    ErrorActionUnsupported = 0xFFFF0024,
    ErrorOrderInvalid = 0xFFFF0025,
    ErrorViewConfigurationTypeUnsupported = 0xFFFF0026,
    ErrorViewConfigurationTypeUnavailable = 0xFFFF0027,
    ErrorViewConfigurationUnsupported = 0xFFFF0028,
    ErrorViewConfigurationUnavailable = 0xFFFF0029,
    ErrorSwapchainRectExtents = 0xFFFF002A,
    ErrorCompositionLayerInvalid = 0xFFFF002B,
    ErrorCompositionLayerNotSupported = 0xFFFF002C,
    ErrorSecondaryViewConfigurationTypeNotEnabled = 0xFFFF002D,
    ErrorSecondaryViewConfigurationNotActive = 0xFFFF002E,
    ErrorTrackerUnsupported = 0xFFFF002F,
}

internal enum XrSwapchainUsageFlags : uint
{
    ColorAttachment = 0x00000001,
    DepthStencilAttachment = 0x00000002,
    TransferSrc = 0x00000008,
    TransferDst = 0x00000010,
    Sampled = 0x00000020,
    UnorderedAccess = 0x00000040,
}

internal enum XrCompositionLayerFlags : uint
{
    CorrectChromaticAberration = 0x00000001,
    BlendTextureSourceAlpha = 0x00000002,
    NoMidDepth = 0x00000004,
}

#endregion

#region OpenXR Structures

[StructLayout(LayoutKind.Sequential)]
internal struct XrInstanceCreateInfo
{
    public XrStructureType type;
    public IntPtr next;
    public uint createFlags;
    public XrApplicationInfo applicationInfo;
    public uint enabledApiLayerCount;
    public IntPtr enabledApiLayerNames;
    public uint enabledExtensionCount;
    public IntPtr enabledExtensionNames;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
internal struct XrApplicationInfo
{
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string applicationName;
    public uint applicationVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string engineName;
    public uint engineVersion;
    public uint apiVersion;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrInstanceProperties
{
    public XrStructureType type;
    public IntPtr next;
    public uint runtimeVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string runtimeName;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSystemGetInfo
{
    public XrStructureType type;
    public IntPtr next;
    public XrFormFactor formFactor;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSystemProperties
{
    public XrStructureType type;
    public IntPtr next;
    public ulong systemId;
    public uint vendorId;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
    public string systemName;
    public XrSystemGraphicsProperties graphicsProperties;
    public XrSystemTrackingProperties trackingProperties;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSystemGraphicsProperties
{
    public uint maxSwapchainImageHeight;
    public uint maxSwapchainImageWidth;
    public uint maxLayerCount;
    public uint maxSwapchainSampleCount;
    public uint maxViewCount;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSystemTrackingProperties
{
    public uint orientationTracking;
    public uint positionTracking;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrGraphicsBindingD3D12KHR
{
    public XrStructureType type;
    public IntPtr next;
    public IntPtr device;       // ID3D12Device*
    public IntPtr queue;        // ID3D12CommandQueue*
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSessionCreateInfo
{
    public XrStructureType type;
    public IntPtr next;
    public uint createFlags;
    public ulong systemId;
    public IntPtr graphicsBinding;  // pointer to XrGraphicsBindingD3D12KHR
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSessionBeginInfo
{
    public XrStructureType type;
    public IntPtr next;
    public XrViewConfigurationType primaryViewConfigurationType;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrReferenceSpaceCreateInfo
{
    public XrStructureType type;
    public IntPtr next;
    public XrReferenceSpaceType referenceSpaceType;
    public XrPosef poseInReferenceSpace;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrPosef
{
    public XrQuaternionf orientation;
    public XrVector3f position;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrQuaternionf
{
    public float x, y, z, w;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrVector3f
{
    public float x, y, z;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrViewConfigurationView
{
    public XrStructureType type;
    public IntPtr next;
    public uint recommendedImageRectWidth;
    public uint recommendedImageRectHeight;
    public uint maxImageRectWidth;
    public uint maxImageRectHeight;
    public uint recommendedSwapchainSampleCount;
    public uint maxSwapchainSampleCount;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSwapchainCreateInfo
{
    public XrStructureType type;
    public IntPtr next;
    public uint createFlags;
    public uint usageFlags;
    public XrViewConfigurationType format;
    public uint sampleCount;
    public uint width;
    public uint height;
    public uint faceCount;
    public uint arraySize;
    public uint mipCount;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSwapchainImageD3D12KHR
{
    public XrStructureType type;
    public IntPtr next;
    public IntPtr texture;  // ID3D12Resource*
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrView
{
    public XrStructureType type;
    public IntPtr next;
    public XrPosef pose;
    public XrFovf fov;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrFovf
{
    public float angleLeft;
    public float angleRight;
    public float angleUp;
    public float angleDown;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrViewLocateInfo
{
    public XrStructureType type;
    public IntPtr next;
    public XrViewConfigurationType viewConfigurationType;
    public long displayTime;
    public IntPtr space;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrFrameBeginInfo
{
    public XrStructureType type;
    public IntPtr next;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrFrameEndInfo
{
    public XrStructureType type;
    public IntPtr next;
    public long displayTime;
    public XrEnvironmentBlendMode environmentBlendMode;
    public uint layerCount;
    public IntPtr layers;  // pointer to array of XrCompositionLayerBaseHeader*
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrFrameState
{
    public XrStructureType type;
    public IntPtr next;
    public long predictedDisplayTime;
    public uint predictedDisplayPeriod;
    public uint shouldRender;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrCompositionLayerProjectionView
{
    public XrStructureType type;
    public IntPtr next;
    public XrPosef pose;
    public XrFovf fov;
    public IntPtr subImage;  // XrSwapchainSubImage
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrSwapchainSubImage
{
    public IntPtr swapchain;  // XrSwapchain
    public XrRect2Di imageRect;
    public uint imageArrayIndex;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrRect2Di
{
    public XrOffset2Di offset;
    public XrExtent2Di extent;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrOffset2Di
{
    public int x, y;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrExtent2Di
{
    public int width, height;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrCompositionLayerProjection
{
    public XrStructureType type;
    public IntPtr next;
    public uint layerFlags;
    public IntPtr space;
    public uint viewCount;
    public IntPtr views;  // XrCompositionLayerProjectionView*
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrCompositionLayerDepthInfoKHR
{
    public XrStructureType type;
    public IntPtr next;
    public IntPtr subImage;  // XrSwapchainSubImage
    public float minDepth;   // Reversed-Z: 1.0f (near)
    public float maxDepth;   // Reversed-Z: 0.0f (far)
    public float nearZ;
    public float farZ;
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrEventBuffer
{
    public XrStructureType type;
    public IntPtr next;
    public int type_;  // XrEventType
}

#endregion

#region OpenXR P/Invoke

internal static class OpenXRNative
{
    private const string LibName = "openxr_loader";

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrCreateInstance(ref XrInstanceCreateInfo createInfo, out IntPtr instance);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrDestroyInstance(IntPtr instance);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrGetInstanceProperties(IntPtr instance, ref XrInstanceProperties properties);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrGetSystem(IntPtr instance, ref XrSystemGetInfo getInfo, out ulong systemId);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrGetSystemProperties(IntPtr instance, ulong systemId, ref XrSystemProperties properties);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrCreateSession(IntPtr instance, ref XrSessionCreateInfo createInfo, out IntPtr session);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrDestroySession(IntPtr session);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrBeginSession(IntPtr session, ref XrSessionBeginInfo beginInfo);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrEndSession(IntPtr session);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrCreateReferenceSpace(IntPtr session, ref XrReferenceSpaceCreateInfo createInfo, out IntPtr space);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrDestroySpace(IntPtr space);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrEnumerateViewConfigurationViews(
        IntPtr instance, ulong systemId, XrViewConfigurationType viewConfigType,
        uint viewCapacityInput, ref uint viewCountOutput, IntPtr views);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrCreateSwapchain(IntPtr session, ref XrSwapchainCreateInfo createInfo, out IntPtr swapchain);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrDestroySwapchain(IntPtr swapchain);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrEnumerateSwapchainImages(
        IntPtr swapchain, uint imageCapacityInput, ref uint imageCountOutput, IntPtr images);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrAcquireSwapchainImage(IntPtr swapchain, IntPtr acquireInfo, out uint index);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrWaitSwapchainImage(IntPtr swapchain, IntPtr waitInfo);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrReleaseSwapchainImage(IntPtr swapchain, IntPtr releaseInfo);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrWaitFrame(IntPtr session, IntPtr frameWaitInfo, ref XrFrameState frameState);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrBeginFrame(IntPtr session, ref XrFrameBeginInfo frameBeginInfo);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrEndFrame(IntPtr session, ref XrFrameEndInfo frameEndInfo);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrLocateViews(
        IntPtr session, ref XrViewLocateInfo viewLocateInfo, out XrViewState viewState,
        uint viewCapacityInput, ref uint viewCountOutput, IntPtr views);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrPollEvent(IntPtr instance, ref XrEventBuffer eventBuffer);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrEnumerateInstanceExtensionProperties(
        IntPtr layerName, uint propertyCapacityInput, ref uint propertyCountOutput, IntPtr properties);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    internal static extern XrResult xrGetD3D12GraphicsRequirementsKHR(
        IntPtr instance, ulong systemId, IntPtr graphicsRequirements);
}

[StructLayout(LayoutKind.Sequential)]
internal struct XrViewState
{
    public XrStructureType type;
    public IntPtr next;
    public uint viewStateFlags;
}

#endregion

/// <summary>
/// OpenXR manager for VR headset integration with D3D12 renderer.
/// Handles instance creation, session lifecycle, swapchains, and frame loop.
/// Uses XR_KHR_D3D12_enable extension to bind to the existing D3D12 device.
/// </summary>
public class OpenXRManager : IDisposable
{
    private IntPtr _instance = IntPtr.Zero;
    private ulong _systemId;
    private IntPtr _session = IntPtr.Zero;
    private IntPtr _space = IntPtr.Zero;
    private XrSessionState _sessionState = XrSessionState.Unknown;

    // Per-eye swapchains
    private readonly IntPtr[] _colorSwapchains = new IntPtr[2];
    private readonly IntPtr[] _depthSwapchains = new IntPtr[2];
    private readonly int[] _colorSwapchainLengths = new int[2];
    private readonly int[] _depthSwapchainLengths = new int[2];

    // Swapchain image arrays (D3D12 texture pointers)
    private readonly IntPtr[][] _colorImages = new IntPtr[2][];
    private readonly IntPtr[][] _depthImages = new IntPtr[2][];

    // Acquired image indices per eye
    private readonly uint[] _acquiredColorIndex = new uint[2];
    private readonly uint[] _acquiredDepthIndex = new uint[2];
    private readonly bool[] _colorAcquired = new bool[2];

    // Frame state
    private XrFrameState _frameState;
    private bool _frameBegun = false;

    // View data
    private XrView[] _views = new XrView[2];

    // Properties
    public bool IsInitialized { get; private set; }
    public bool IsSessionRunning => _sessionState == XrSessionState.Focused || _sessionState == XrSessionState.Visible || _sessionState == XrSessionState.Synchronized;
    public bool ShouldRender => _frameState.shouldRender != 0;
    public int EyeWidth { get; private set; }
    public int EyeHeight { get; private set; }
    public float IPD { get; private set; } = 0.063f;

    // Extension availability
    private bool _hasDepthExtension = false;

    /// <summary>
    /// Initialize OpenXR instance and system with D3D12 graphics binding.
    /// </summary>
    /// <param name="d3d12Device">Native ID3D12Device pointer</param>
    /// <param name="d3d12CommandQueue">Native ID3D12CommandQueue pointer</param>
    /// <returns>True if initialization succeeded</returns>
    public bool Initialize(IntPtr d3d12Device, IntPtr d3d12CommandQueue)
    {
        if (d3d12Device == IntPtr.Zero || d3d12CommandQueue == IntPtr.Zero)
        {
            DebugLogger.Warn("[OpenXR] Cannot initialize: D3D12 device or command queue is null");
            return false;
        }

        try
        {
            // 1. Check available extensions
            if (!CheckExtensionSupport("XR_KHR_D3D12_enable"))
            {
                DebugLogger.Warn("[OpenXR] XR_KHR_D3D12_enable extension not available");
                return false;
            }
            _hasDepthExtension = CheckExtensionSupport("XR_KHR_composition_layer_depth");

            // 2. Create instance with D3D12 extension
            if (!CreateInstance())
            {
                DebugLogger.Warn("[OpenXR] Failed to create instance");
                return false;
            }

            // 3. Get system (HMD)
            if (!GetSystem())
            {
                DebugLogger.Warn("[OpenXR] No HMD detected");
                return false;
            }

            // 4. Create session with D3D12 binding
            if (!CreateSession(d3d12Device, d3d12CommandQueue))
            {
                DebugLogger.Warn("[OpenXR] Failed to create session");
                return false;
            }

            // 5. Create reference space (LOCAL — seated experience, stable horizon)
            if (!CreateReferenceSpace())
            {
                DebugLogger.Warn("[OpenXR] Failed to create reference space");
                return false;
            }

            // 6. Create swapchains for both eyes
            if (!CreateSwapchains())
            {
                DebugLogger.Warn("[OpenXR] Failed to create swapchains");
                return false;
            }

            IsInitialized = true;
            DebugLogger.Info($"[OpenXR] Initialized successfully. Eye resolution: {EyeWidth}x{EyeHeight}, Depth extension: {_hasDepthExtension}");
            return true;
        }
        catch (Exception ex)
        {
            DebugLogger.Error($"[OpenXR] Initialization exception: {ex.Message}");
            return false;
        }
    }

    private bool CheckExtensionSupport(string extensionName)
    {
        uint count = 0;
        var result = OpenXRNative.xrEnumerateInstanceExtensionProperties(
            IntPtr.Zero, 0, ref count, IntPtr.Zero);
        if (result != XrResult.Success)
        {
            DebugLogger.Warn($"[OpenXR] Failed to enumerate extensions: {result}");
            return false;
        }

        // Each XrExtensionProperties is 256 + 4 + 4 = 264 bytes (name[128] + uint version + XrStructureType)
        // Actually: type(4) + next(8) + extensionName[128] + extensionVersion(4) = 144 bytes on x64
        int structSize = Marshal.SizeOf<XrExtensionProperties>();
        IntPtr buffer = Marshal.AllocHGlobal((int)(count * structSize));
        try
        {
            // Initialize type fields
            for (uint i = 0; i < count; i++)
            {
                IntPtr ptr = buffer + (int)(i * structSize);
                Marshal.WriteInt32(ptr, (int)XrStructureType.InstanceProperties); // type field placeholder
            }

            result = OpenXRNative.xrEnumerateInstanceExtensionProperties(
                IntPtr.Zero, count, ref count, buffer);
            if (result != XrResult.Success)
            {
                DebugLogger.Warn($"[OpenXR] Failed to enumerate extensions (2nd call): {result}");
                return false;
            }

            for (uint i = 0; i < count; i++)
            {
                IntPtr ptr = buffer + (int)(i * structSize);
                // extensionName starts at offset 16 (type=4 + next=8 + padding=4) on x64
                // Actually: type(4) + padding(4) + next(8) + extensionName[128] = offset 16
                string name = Marshal.PtrToStringAnsi(ptr + 16)!;
                if (name == extensionName)
                    return true;
            }
            return false;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private bool CreateInstance()
    {
        // API version 1.0
        uint apiVersion = (1u << 48) | (0u << 32); // XR_MAKE_VERSION(1, 0, 0)

        var appInfo = new XrApplicationInfo
        {
            applicationName = "RS by Resonance",
            applicationVersion = 1,
            engineName = "RapidSpectrum",
            engineVersion = 1,
            apiVersion = apiVersion,
        };

        // Extensions
        string[] extensions = _hasDepthExtension
            ? new[] { "XR_KHR_D3D12_enable", "XR_KHR_composition_layer_depth" }
            : new[] { "XR_KHR_D3D12_enable" };

        IntPtr extPtr = Marshal.AllocHGlobal(extensions.Length * IntPtr.Size);
        try
        {
            for (int i = 0; i < extensions.Length; i++)
            {
                Marshal.WriteIntPtr(extPtr + i * IntPtr.Size, Marshal.StringToHGlobalAnsi(extensions[i]));
            }

            var createInfo = new XrInstanceCreateInfo
            {
                type = XrStructureType.InstanceCreateInfo,
                next = IntPtr.Zero,
                createFlags = 0,
                applicationInfo = appInfo,
                enabledApiLayerCount = 0,
                enabledApiLayerNames = IntPtr.Zero,
                enabledExtensionCount = (uint)extensions.Length,
                enabledExtensionNames = extPtr,
            };

            var result = OpenXRNative.xrCreateInstance(ref createInfo, out _instance);
            if (result != XrResult.Success)
            {
                DebugLogger.Error($"[OpenXR] xrCreateInstance failed: {result}");
                return false;
            }

            // Log runtime info
            var props = new XrInstanceProperties
            {
                type = XrStructureType.InstanceProperties,
                next = IntPtr.Zero,
                runtimeName = new string('\0', 128),
            };
            OpenXRNative.xrGetInstanceProperties(_instance, ref props);
            DebugLogger.Info($"[OpenXR] Runtime: {props.runtimeName?.TrimEnd('\0')}, version: {props.runtimeVersion}");

            return true;
        }
        finally
        {
            for (int i = 0; i < extensions.Length; i++)
            {
                IntPtr strPtr = Marshal.ReadIntPtr(extPtr + i * IntPtr.Size);
                if (strPtr != IntPtr.Zero) Marshal.FreeHGlobal(strPtr);
            }
            Marshal.FreeHGlobal(extPtr);
        }
    }

    private bool GetSystem()
    {
        var getInfo = new XrSystemGetInfo
        {
            type = XrStructureType.SystemGetInfo,
            next = IntPtr.Zero,
            formFactor = XrFormFactor.HeadMountedDisplay,
        };

        var result = OpenXRNative.xrGetSystem(_instance, ref getInfo, out _systemId);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrGetSystem failed: {result}");
            return false;
        }

        // Get system properties for limits
        var props = new XrSystemProperties
        {
            type = XrStructureType.SystemProperties,
            next = IntPtr.Zero,
            systemName = new string('\0', 256),
        };
        OpenXRNative.xrGetSystemProperties(_instance, _systemId, ref props);
        DebugLogger.Info($"[OpenXR] System: {props.systemName?.TrimEnd('\0')}, Max swapchain: {props.graphicsProperties.maxSwapchainImageWidth}x{props.graphicsProperties.maxSwapchainImageHeight}");

        return true;
    }

    private bool CreateSession(IntPtr d3d12Device, IntPtr d3d12CommandQueue)
    {
        // D3D12 graphics binding
        var graphicsBinding = new XrGraphicsBindingD3D12KHR
        {
            type = XrStructureType.GraphicsBindingD3D12KHR,
            next = IntPtr.Zero,
            device = d3d12Device,
            queue = d3d12CommandQueue,
        };

        IntPtr gbPtr = Marshal.AllocHGlobal(Marshal.SizeOf<XrGraphicsBindingD3D12KHR>());
        try
        {
            Marshal.StructureToPtr(graphicsBinding, gbPtr, false);

            var createInfo = new XrSessionCreateInfo
            {
                type = XrStructureType.SessionCreateInfo,
                next = IntPtr.Zero,
                createFlags = 0,
                systemId = _systemId,
                graphicsBinding = gbPtr,
            };

            var result = OpenXRNative.xrCreateSession(_instance, ref createInfo, out _session);
            if (result != XrResult.Success)
            {
                DebugLogger.Error($"[OpenXR] xrCreateSession failed: {result}");
                return false;
            }

            return true;
        }
        finally
        {
            Marshal.FreeHGlobal(gbPtr);
        }
    }

    private bool CreateReferenceSpace()
    {
        var createInfo = new XrReferenceSpaceCreateInfo
        {
            type = XrStructureType.ReferenceSpaceCreateInfo,
            next = IntPtr.Zero,
            referenceSpaceType = XrReferenceSpaceType.Local,
            poseInReferenceSpace = new XrPosef
            {
                orientation = new XrQuaternionf { x = 0, y = 0, z = 0, w = 1 },
                position = new XrVector3f { x = 0, y = 0, z = 0 },
            },
        };

        var result = OpenXRNative.xrCreateReferenceSpace(_session, ref createInfo, out _space);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrCreateReferenceSpace failed: {result}");
            return false;
        }

        return true;
    }

    private bool CreateSwapchains()
    {
        // Enumerate view configuration views to get recommended resolution
        uint viewCount = 0;
        var result = OpenXRNative.xrEnumerateViewConfigurationViews(
            _instance, _systemId, XrViewConfigurationType.PrimaryStereo,
            0, ref viewCount, IntPtr.Zero);
        if (result != XrResult.Success || viewCount < 2)
        {
            DebugLogger.Error($"[OpenXR] Failed to enumerate view config views: {result}");
            return false;
        }

        int vcSize = Marshal.SizeOf<XrViewConfigurationView>();
        IntPtr vcBuffer = Marshal.AllocHGlobal((int)(viewCount * vcSize));
        try
        {
            for (uint i = 0; i < viewCount; i++)
            {
                IntPtr ptr = vcBuffer + (int)(i * vcSize);
                Marshal.WriteInt32(ptr, (int)XrStructureType.ViewConfigurationView);
            }

            result = OpenXRNative.xrEnumerateViewConfigurationViews(
                _instance, _systemId, XrViewConfigurationType.PrimaryStereo,
                viewCount, ref viewCount, vcBuffer);
            if (result != XrResult.Success)
            {
                DebugLogger.Error($"[OpenXR] Failed to enumerate view config views (2nd): {result}");
                return false;
            }

            // Use first view's recommended resolution (both eyes typically same)
            var view0 = Marshal.PtrToStructure<XrViewConfigurationView>(vcBuffer);
            EyeWidth = (int)view0.recommendedImageRectWidth;
            EyeHeight = (int)view0.recommendedImageRectHeight;

            // Calculate IPD from the two eye poses (will be refined during LocateViews)
            // For now use default 63mm
        }
        finally
        {
            Marshal.FreeHGlobal(vcBuffer);
        }

        // Create color + depth swapchains for each eye
        // Color format: R8G8B8A8_UNORM (DXGI_FORMAT_R8G8B8A8_UNORM = 28)
        // Depth format: D32_FLOAT (DXGI_FORMAT_D32_FLOAT = 40)
        for (int eye = 0; eye < 2; eye++)
        {
            if (!CreateEyeSwapchain(eye, isDepth: false))
            {
                DebugLogger.Error($"[OpenXR] Failed to create color swapchain for eye {eye}");
                return false;
            }
            if (_hasDepthExtension)
            {
                if (!CreateEyeSwapchain(eye, isDepth: true))
                {
                    DebugLogger.Error($"[OpenXR] Failed to create depth swapchain for eye {eye}");
                    return false;
                }
            }
        }

        return true;
    }

    private bool CreateEyeSwapchain(int eye, bool isDepth)
    {
        var createInfo = new XrSwapchainCreateInfo
        {
            type = XrStructureType.SwapchainCreateInfo,
            next = IntPtr.Zero,
            createFlags = 0,
            usageFlags = isDepth
                ? (uint)XrSwapchainUsageFlags.DepthStencilAttachment
                : (uint)XrSwapchainUsageFlags.ColorAttachment | (uint)XrSwapchainUsageFlags.Sampled,
            format = isDepth ? (XrViewConfigurationType)40 : (XrViewConfigurationType)28, // DXGI format as int
            sampleCount = 1,
            width = (uint)EyeWidth,
            height = (uint)EyeHeight,
            faceCount = 1,
            arraySize = 1,
            mipCount = 1,
        };

        var result = OpenXRNative.xrCreateSwapchain(_session, ref createInfo,
            out IntPtr swapchain);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrCreateSwapchain failed for eye {eye} ({(isDepth ? "depth" : "color")}): {result}");
            return false;
        }

        // Enumerate swapchain images to get D3D12 texture pointers
        uint imageCount = 0;
        result = OpenXRNative.xrEnumerateSwapchainImages(swapchain, 0, ref imageCount, IntPtr.Zero);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrEnumerateSwapchainImages (count) failed: {result}");
            return false;
        }

        int imgStructSize = Marshal.SizeOf<XrSwapchainImageD3D12KHR>();
        IntPtr imgBuffer = Marshal.AllocHGlobal((int)(imageCount * imgStructSize));
        try
        {
            // Initialize type fields
            for (uint i = 0; i < imageCount; i++)
            {
                IntPtr ptr = imgBuffer + (int)(i * imgStructSize);
                Marshal.WriteInt32(ptr, (int)XrStructureType.SwapchainImageD3D12KHR);
            }

            result = OpenXRNative.xrEnumerateSwapchainImages(swapchain, imageCount, ref imageCount, imgBuffer);
            if (result != XrResult.Success)
            {
                DebugLogger.Error($"[OpenXR] xrEnumerateSwapchainImages (data) failed: {result}");
                return false;
            }

            // Extract texture pointers
            var images = new IntPtr[imageCount];
            for (uint i = 0; i < imageCount; i++)
            {
                IntPtr ptr = imgBuffer + (int)(i * imgStructSize);
                var img = Marshal.PtrToStructure<XrSwapchainImageD3D12KHR>(ptr);
                images[i] = img.texture;
            }

            if (isDepth)
            {
                _depthSwapchains[eye] = swapchain;
                _depthSwapchainLengths[eye] = (int)imageCount;
                _depthImages[eye] = images;
            }
            else
            {
                _colorSwapchains[eye] = swapchain;
                _colorSwapchainLengths[eye] = (int)imageCount;
                _colorImages[eye] = images;
            }

            return true;
        }
        finally
        {
            Marshal.FreeHGlobal(imgBuffer);
        }
    }

    /// <summary>
    /// Poll for OpenXR events and update session state.
    /// Call this each frame before WaitFrame.
    /// </summary>
    public void PollEvents()
    {
        var eventBuffer = new XrEventBuffer
        {
            type = XrStructureType.EventBuffer,
            next = IntPtr.Zero,
            type_ = 0,
        };

        while (OpenXRNative.xrPollEvent(_instance, ref eventBuffer) == XrResult.Success)
        {
            // Map event type to session state
            // Event types: 1=SessionStateChanged, etc.
            // For now, we just poll and let xrWaitFrame handle state transitions
        }
    }

    /// <summary>
    /// Wait for the VR runtime to signal the next frame.
    /// Gates the render thread to the headset's display refresh rate.
    /// </summary>
    public void WaitFrame()
    {
        _frameState = new XrFrameState
        {
            type = XrStructureType.FrameState,
            next = IntPtr.Zero,
        };

        var result = OpenXRNative.xrWaitFrame(_session, IntPtr.Zero, ref _frameState);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrWaitFrame failed: {result}");
        }
    }

    /// <summary>
    /// Begin the OpenXR frame. Call after WaitFrame and before rendering.
    /// </summary>
    public void BeginFrame()
    {
        var beginInfo = new XrFrameBeginInfo
        {
            type = XrStructureType.FrameBeginInfo,
            next = IntPtr.Zero,
        };

        var result = OpenXRNative.xrBeginFrame(_session, ref beginInfo);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrBeginFrame failed: {result}");
            return;
        }
        _frameBegun = true;
    }

    /// <summary>
    /// Locate views for both eyes at the predicted display time.
    /// Returns head pose and per-eye poses.
    /// </summary>
    /// <returns>Array of 2 EyePose structs (left, right)</returns>
    public EyePose[] LocateViews()
    {
        var locateInfo = new XrViewLocateInfo
        {
            type = XrStructureType.ViewLocateInfo,
            next = IntPtr.Zero,
            viewConfigurationType = XrViewConfigurationType.PrimaryStereo,
            displayTime = _frameState.predictedDisplayTime,
            space = _space,
        };

        uint viewCount = 2;
        int viewSize = Marshal.SizeOf<XrView>();
        IntPtr viewBuffer = Marshal.AllocHGlobal((int)viewCount * viewSize);
        try
        {
            for (uint i = 0; i < viewCount; i++)
            {
                IntPtr ptr = viewBuffer + (int)(i * viewSize);
                Marshal.WriteInt32(ptr, (int)XrStructureType.View);
            }

            var result = OpenXRNative.xrLocateViews(_session, ref locateInfo,
                out _, viewCount, ref viewCount, viewBuffer);
            if (result != XrResult.Success)
            {
                DebugLogger.Error($"[OpenXR] xrLocateViews failed: {result}");
                return new EyePose[2];
            }

            var poses = new EyePose[2];
            for (int i = 0; i < 2; i++)
            {
                IntPtr ptr = viewBuffer + i * viewSize;
                _views[i] = Marshal.PtrToStructure<XrView>(ptr);
                poses[i] = new EyePose
                {
                    Position = new Vector3(_views[i].pose.position.x, _views[i].pose.position.y, _views[i].pose.position.z),
                    Orientation = new Quaternion(_views[i].pose.orientation.x, _views[i].pose.orientation.y,
                                                  _views[i].pose.orientation.z, _views[i].pose.orientation.w),
                    FovLeft = _views[i].fov.angleLeft,
                    FovRight = _views[i].fov.angleRight,
                    FovUp = _views[i].fov.angleUp,
                    FovDown = _views[i].fov.angleDown,
                };
            }

            // Calculate IPD from eye positions
            float ipd = Vector3.Distance(poses[0].Position, poses[1].Position);
            if (ipd > 0.001f) IPD = ipd;

            return poses;
        }
        finally
        {
            Marshal.FreeHGlobal(viewBuffer);
        }
    }

    /// <summary>
    /// Acquire the next swapchain image for the specified eye.
    /// Returns the D3D12 texture pointer to render into.
    /// </summary>
    public IntPtr AcquireColorImage(int eyeIndex)
    {
        var result = OpenXRNative.xrAcquireSwapchainImage(_colorSwapchains[eyeIndex], IntPtr.Zero, out _acquiredColorIndex[eyeIndex]);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrAcquireSwapchainImage failed for eye {eyeIndex}: {result}");
            return IntPtr.Zero;
        }

        result = OpenXRNative.xrWaitSwapchainImage(_colorSwapchains[eyeIndex], IntPtr.Zero);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrWaitSwapchainImage failed for eye {eyeIndex}: {result}");
            return IntPtr.Zero;
        }

        _colorAcquired[eyeIndex] = true;
        return _colorImages[eyeIndex][_acquiredColorIndex[eyeIndex]];
    }

    /// <summary>
    /// Release the acquired color swapchain image for the specified eye.
    /// </summary>
    public void ReleaseColorImage(int eyeIndex)
    {
        if (!_colorAcquired[eyeIndex]) return;

        var result = OpenXRNative.xrReleaseSwapchainImage(_colorSwapchains[eyeIndex], IntPtr.Zero);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrReleaseSwapchainImage failed for eye {eyeIndex}: {result}");
        }
        _colorAcquired[eyeIndex] = false;
    }

    /// <summary>
    /// End the OpenXR frame and submit composition layers.
    /// Includes XR_KHR_composition_layer_depth with Reversed-Z when available.
    /// </summary>
    public void EndFrame()
    {
        if (!_frameBegun) return;

        // Build composition layer projection
        int projViewSize = Marshal.SizeOf<XrCompositionLayerProjectionView>();
        IntPtr projViewsPtr = Marshal.AllocHGlobal(2 * projViewSize);
        try
        {
            for (int eye = 0; eye < 2; eye++)
            {
                var subImage = new XrSwapchainSubImage
                {
                    swapchain = _colorSwapchains[eye],
                    imageRect = new XrRect2Di
                    {
                        offset = new XrOffset2Di { x = 0, y = 0 },
                        extent = new XrExtent2Di { width = EyeWidth, height = EyeHeight },
                    },
                    imageArrayIndex = 0,
                };

                IntPtr subImagePtr = Marshal.AllocHGlobal(Marshal.SizeOf<XrSwapchainSubImage>());
                Marshal.StructureToPtr(subImage, subImagePtr, false);

                // If depth extension is available, chain XrCompositionLayerDepthInfoKHR
                IntPtr depthInfoPtr = IntPtr.Zero;
                if (_hasDepthExtension && _depthSwapchains[eye] != IntPtr.Zero)
                {
                    var depthSubImage = new XrSwapchainSubImage
                    {
                        swapchain = _depthSwapchains[eye],
                        imageRect = new XrRect2Di
                        {
                            offset = new XrOffset2Di { x = 0, y = 0 },
                            extent = new XrExtent2Di { width = EyeWidth, height = EyeHeight },
                        },
                        imageArrayIndex = 0,
                    };
                    IntPtr depthSubImagePtr = Marshal.AllocHGlobal(Marshal.SizeOf<XrSwapchainSubImage>());
                    Marshal.StructureToPtr(depthSubImage, depthSubImagePtr, false);

                    var depthInfo = new XrCompositionLayerDepthInfoKHR
                    {
                        type = XrStructureType.CompositionLayerDepthInfoKHR,
                        next = IntPtr.Zero,
                        subImage = depthSubImagePtr,
                        // Reversed-Z: near=1.0, far=0.0 — critical for LSR/ASW stability
                        minDepth = 1.0f,
                        maxDepth = 0.0f,
                        nearZ = 0.1f,
                        farZ = 100.0f,
                    };
                    depthInfoPtr = Marshal.AllocHGlobal(Marshal.SizeOf<XrCompositionLayerDepthInfoKHR>());
                    Marshal.StructureToPtr(depthInfo, depthInfoPtr, false);
                }

                var projView = new XrCompositionLayerProjectionView
                {
                    type = XrStructureType.CompositionLayerProjectionView,
                    next = depthInfoPtr,  // Chain depth info
                    pose = _views[eye].pose,
                    fov = _views[eye].fov,
                    subImage = subImagePtr,
                };
                Marshal.StructureToPtr(projView, projViewsPtr + eye * projViewSize, false);
            }

            var projLayer = new XrCompositionLayerProjection
            {
                type = XrStructureType.CompositionLayerProjection,
                next = IntPtr.Zero,
                layerFlags = (uint)XrCompositionLayerFlags.BlendTextureSourceAlpha,
                space = _space,
                viewCount = 2,
                views = projViewsPtr,
            };

            IntPtr layerPtr = Marshal.AllocHGlobal(Marshal.SizeOf<XrCompositionLayerProjection>());
            try
            {
                Marshal.StructureToPtr(projLayer, layerPtr, false);

                // Array of layer pointers (just one projection layer)
                IntPtr[] layerPointers = { layerPtr };
                IntPtr layerArrayPtr = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(layerArrayPtr, layerPtr);
                try
                {
                    var endInfo = new XrFrameEndInfo
                    {
                        type = XrStructureType.FrameEndInfo,
                        next = IntPtr.Zero,
                        displayTime = _frameState.predictedDisplayTime,
                        environmentBlendMode = XrEnvironmentBlendMode.Opaque,
                        layerCount = 1,
                        layers = layerArrayPtr,
                    };

                    var result = OpenXRNative.xrEndFrame(_session, ref endInfo);
                    if (result != XrResult.Success)
                    {
                        DebugLogger.Error($"[OpenXR] xrEndFrame failed: {result}");
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(layerArrayPtr);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(layerPtr);
            }

            // Free subImage and depth info allocations
            for (int eye = 0; eye < 2; eye++)
            {
                var pv = Marshal.PtrToStructure<XrCompositionLayerProjectionView>(projViewsPtr + eye * projViewSize);
                if (pv.subImage != IntPtr.Zero) Marshal.FreeHGlobal(pv.subImage);
                if (pv.next != IntPtr.Zero)
                {
                    // Free depth subImage
                    var di = Marshal.PtrToStructure<XrCompositionLayerDepthInfoKHR>(pv.next);
                    if (di.subImage != IntPtr.Zero) Marshal.FreeHGlobal(di.subImage);
                    Marshal.FreeHGlobal(pv.next);
                }
            }
        }
        finally
        {
            Marshal.FreeHGlobal(projViewsPtr);
        }

        _frameBegun = false;
    }

    /// <summary>
    /// Begin the OpenXR session (transition to READY → SYNCHRONIZED).
    /// </summary>
    public bool BeginSession()
    {
        if (_session == IntPtr.Zero) return false;

        var beginInfo = new XrSessionBeginInfo
        {
            type = XrStructureType.SessionBeginInfo,
            next = IntPtr.Zero,
            primaryViewConfigurationType = XrViewConfigurationType.PrimaryStereo,
        };

        var result = OpenXRNative.xrBeginSession(_session, ref beginInfo);
        if (result != XrResult.Success)
        {
            DebugLogger.Error($"[OpenXR] xrBeginSession failed: {result}");
            return false;
        }

        _sessionState = XrSessionState.Synchronized;
        DebugLogger.Info("[OpenXR] Session begun");
        return true;
    }

    /// <summary>
    /// End the OpenXR session.
    /// </summary>
    public void EndSession()
    {
        if (_session != IntPtr.Zero)
        {
            OpenXRNative.xrEndSession(_session);
            _sessionState = XrSessionState.Stopping;
        }
    }

    public void Dispose()
    {
        // Release swapchains
        for (int eye = 0; eye < 2; eye++)
        {
            if (_colorSwapchains[eye] != IntPtr.Zero)
            {
                OpenXRNative.xrDestroySwapchain(_colorSwapchains[eye]);
                _colorSwapchains[eye] = IntPtr.Zero;
            }
            if (_depthSwapchains[eye] != IntPtr.Zero)
            {
                OpenXRNative.xrDestroySwapchain(_depthSwapchains[eye]);
                _depthSwapchains[eye] = IntPtr.Zero;
            }
        }

        if (_space != IntPtr.Zero)
        {
            OpenXRNative.xrDestroySpace(_space);
            _space = IntPtr.Zero;
        }

        if (_session != IntPtr.Zero)
        {
            OpenXRNative.xrDestroySession(_session);
            _session = IntPtr.Zero;
        }

        if (_instance != IntPtr.Zero)
        {
            OpenXRNative.xrDestroyInstance(_instance);
            _instance = IntPtr.Zero;
        }

        IsInitialized = false;
    }
}

/// <summary>
/// Per-eye pose data from OpenXR view localization.
/// </summary>
public struct EyePose
{
    public Vector3 Position;
    public Quaternion Orientation;
    public float FovLeft;
    public float FovRight;
    public float FovUp;
    public float FovDown;
}

/// <summary>
/// XrExtensionProperties structure for extension enumeration.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct XrExtensionProperties
{
    public XrStructureType type;
    public IntPtr next;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
    public string extensionName;
    public uint extensionVersion;
}

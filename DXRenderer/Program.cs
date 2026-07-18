using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DXRenderer;

static class Program
{
    private static bool _forceDx11Only = false;

    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        int width = 1920;
        int height = 1080;

        // Unified renderer: DX11 + DX12 co-rendering into one window
        // (ignores --dx11/--dx12 flags; always uses both when available)
        foreach (var arg in args)
        {
            if (arg.Equals("--dx11-only", StringComparison.OrdinalIgnoreCase))
                _forceDx11Only = true;
        }

        var form = new Form
        {
            Text = "RTX Audio Visualizer — DX12 Ultimate",
            Width = width,
            Height = height,
            StartPosition = FormStartPosition.CenterScreen,
            KeyPreview = true
        };

        IRenderer? renderer = null;
        AudioBridge? audio = null;
        VisualSmoother? visualSmoother = null;
        VisualDirectorBot? director = null;
        OllamaVisionFeedback? ollamaFeedback = null;
        DirectorHUD? directorHud = null;
        StageSimWASAPI.LightingBrain? brain = null;
        StageSimWASAPI.MusicBrainAI? musicAI = null;
        float time = 0;
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        bool rendererInitialized = false;
        int _frameCount = 0;

        // Mode selection dropdown — top-right, away from HUD
        var modeCombo = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Width = 200,
            Top = 8,
            Left = width - 220,
            Visible = false
        };
        modeCombo.SelectedIndexChanged += (s2, e2) =>
        {
            if (renderer != null && modeCombo.SelectedIndex >= 0 && modeCombo.SelectedIndex < renderer.ModeCount)
            {
                renderer.SetMode(modeCombo.Items[modeCombo.SelectedIndex].ToString()!);
            }
            // Refocus the form so keyboard hotkeys keep working
            form.Focus();
        };
        modeCombo.DropDownClosed += (s2, e2) => form.Focus();
        form.Controls.Add(modeCombo);

        form.Shown += (s, e) =>
        {
            if (rendererInitialized) return;
            rendererInitialized = true;

            try
            {
                DebugLogger.Info("Initializing DX12 Ultimate renderer...");

                renderer = CreateRenderer(form.Handle, width, height);

                DebugLogger.Info($"Renderer initialized: {renderer.BackendName}, Modes: {renderer.ModeCount}");

                audio = new AudioBridge();
                audio.Start();
                visualSmoother = new VisualSmoother();
                director = new VisualDirectorBot();

                // Initialize LightingBrain for automatic mode selection
                brain = new StageSimWASAPI.LightingBrain();
                DebugLogger.Info("LightingBrain initialized for automatic mode selection");

                // Optional AI visual critic — two-model pipeline:
                //   qwen2.5vl:7b observes the frame, qwen2.5-coder:7b translates to shader adjustments
                // Starts disabled, press O to enable
                ollamaFeedback = new OllamaVisionFeedback(form.Handle,
                    visionModel: "qwen2.5vl:7b", textModel: "qwen2.5-coder:7b");
                ollamaFeedback.Start();
                if (director != null)
                {
                    director.VisionFeedback = ollamaFeedback;
                    // Route AI suggestions through adaptive profiles, not direct UBO override
                    ollamaFeedback.AdaptiveProfiles = director.AdaptiveProfiles;
                }

                // AI music director — text model evaluates brain decisions & plans musical goals
                // Like smc-autosort's GoalPlanner, but for music/visual direction
                musicAI = new StageSimWASAPI.MusicBrainAI();
                musicAI.Start();

                DebugLogger.Info("Audio bridge started");

                directorHud = new DirectorHUD(director, ollamaFeedback, musicAI);
                directorHud.Hide();

                DebugLogger.Info($"\n=== {renderer.BackendName} Renderer Ready ===");
                DebugLogger.Info($"  M=Next Mode  N=Prev Mode  H=Toggle Brain HUD  B=Toggle Director HUD  ESC=Quit");
                DebugLogger.Info($"  D=Cycle Director (Auto/Observe/Off)  O=Toggle Ollama  A=Toggle Auto Mode Selection");
                DebugLogger.Info($"  G=Toggle Music AI  C=Toggle Chat (in Director HUD)");
                DebugLogger.Info($"  Work Graphs: {renderer.SupportsWorkGraphs}");
                DebugLogger.Info($"  Mode: {renderer.CurrentMode}");
                DebugLogger.Info($"  Auto Mode Selection: ON (LightingBrain)\n");

                // Populate mode dropdown
                modeCombo.Items.Clear();
                for (int mi = 0; mi < renderer.ModeCount; mi++)
                {
                    string modeName = renderer.GetModeName(mi);
                    modeCombo.Items.Add($"{mi + 1}. {modeName}");
                }
                modeCombo.SelectedIndex = 0;
                modeCombo.Visible = true;
            }
            catch (Exception ex)
            {
                DebugLogger.WriteCrash(ex, "Renderer initialization");
                MessageBox.Show($"Failed to initialize renderer:\n{ex}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                form.Close();
            }
        };

        form.KeyDown += (s, e) =>
        {
            switch (e.KeyCode)
            {
                case Keys.Escape:
                    form.Close();
                    break;
                case Keys.M:
                    renderer?.NextMode();
                    if (renderer != null) modeCombo.SelectedIndex = renderer.CurrentModeIndex;
                    break;
                case Keys.N:
                    renderer?.PrevMode();
                    if (renderer != null) modeCombo.SelectedIndex = renderer.CurrentModeIndex;
                    break;
                case Keys.H:
                    renderer?.ToggleHUD();
                    break;
                case Keys.B:
                    if (directorHud == null || directorHud.IsDisposed)
                    {
                        directorHud = new DirectorHUD(director, ollamaFeedback, musicAI);
                        directorHud.Show();
                        directorHud.BringToFront();
                    }
                    else
                        directorHud.Visible = !directorHud.Visible;
                    DebugLogger.Info($"Director HUD: {(directorHud != null && !directorHud.IsDisposed && directorHud.Visible ? "ON" : "OFF")}");
                    break;
                case Keys.D:
                    if (director != null)
                    {
                        // Cycle: Auto → Observe → Off → Auto
                        director.Mode = director.Mode switch
                        {
                            VisualDirectorBot.DirectorMode.Auto => VisualDirectorBot.DirectorMode.Observe,
                            VisualDirectorBot.DirectorMode.Observe => VisualDirectorBot.DirectorMode.Off,
                            _ => VisualDirectorBot.DirectorMode.Auto
                        };
                        DebugLogger.Info($"VisualDirectorBot: {director.ModeLabel}");
                    }
                    break;
                case Keys.O:
                    if (ollamaFeedback != null) ollamaFeedback.Enabled = !ollamaFeedback.Enabled;
                    DebugLogger.Info($"OllamaFeedback: {(ollamaFeedback?.Enabled == true ? "ON" : "OFF")}");
                    break;
                case Keys.A:
                    // Toggle auto mode selection (manual override)
                    DebugLogger.Info("Auto mode selection toggle - manual override active");
                    break;
                case Keys.G:
                    if (musicAI != null) musicAI.Enabled = !musicAI.Enabled;
                    DebugLogger.Info($"MusicBrainAI: {(musicAI?.Enabled == true ? "ON" : "OFF")}");
                    break;
                case Keys.C:
                    if (directorHud == null || directorHud.IsDisposed)
                    {
                        directorHud = new DirectorHUD(director, ollamaFeedback, musicAI);
                        directorHud.Show();
                        directorHud.BringToFront();
                    }
                    else
                    {
                        if (directorHud.Visible) directorHud.Hide();
                        else { directorHud.Show(); directorHud.BringToFront(); }
                    }
                    DebugLogger.Info($"Director HUD: {(directorHud.Visible ? "ON" : "OFF")}");
                    break;
            }
        };

        Application.Idle += (s, e) =>
        {
            if (renderer == null || audio == null) return;

            while (AppStillIdle())
            {
                time = (float)stopwatch.Elapsed.TotalSeconds;
                _frameCount++;

                try
                {
                    audio.PollFrame();
                    var rawFrame = audio.GetLatestFrame();

                    // Update LightingBrain with audio data for genre detection and mode selection
                    if (brain != null && audio.Analyzer != null)
                    {
                        float dt = 1.0f / 60.0f;
                        brain.Update(audio.Analyzer, dt);

                        // Debug: log brain state
                        if (_frameCount % 60 == 0)
                        {
                            DebugLogger.Info($"[Brain] Genre: {brain.GetGenreName()} (conf: {brain.GenreConfidence:F2}), Section: {brain.GetSectionName()}, RecMode: {brain.RecommendedMode}, ShouldChange: {brain.ShouldChangeMode}");
                        }

                        // Feed Ollama vision feedback into brain for adaptive refinement
                        if (ollamaFeedback != null && ollamaFeedback.Enabled && ollamaFeedback.IsConnected)
                        {
                            brain.UpdateVisionFeedback(
                                ollamaFeedback.VisualEnergy,
                                ollamaFeedback.VisualMood,
                                ollamaFeedback.ColorBalance,
                                ollamaFeedback.Complexity
                            );
                        }

                        // Update AI pipeline context so the models know what's active
                        if (ollamaFeedback != null && renderer != null)
                        {
                            ollamaFeedback.UpdatePipelineContext(
                                renderer.CurrentMode,
                                director?.Mood.ToString() ?? "",
                                rawFrame.BPM,
                                rawFrame.Overall,
                                rawFrame.Section);
                        }

                        // Feed current mode + genre into the director's adaptive system
                        if (director != null && renderer != null)
                        {
                            director.CurrentModeName = renderer.CurrentMode;
                            director.CurrentGenre = brain.GetGenreName();
                        }

                        // Feed brain state to Music AI for evaluation
                        if (musicAI != null && brain != null)
                        {
                            musicAI.UpdateBrainState(brain);
                        }

                        // GPU reset on prolonged silence — resets frame state for darkness, preserves mode
                        if (brain.ShouldResetGPU && renderer != null)
                        {
                            renderer.ResetGPU();
                        }

                        // Auto mode selection disabled — manual control only (hotkeys + dropdown)
                        // if (brain.ShouldChangeMode && renderer != null)
                        // {
                        //     string modeName = brain.RecommendedMode.ToString();
                        //     renderer.SetMode(modeName);
                        //     DebugLogger.Info($"[LightingBrain] Auto mode change: {modeName}");
                        // }
                    }

                    // Visual director composes — in Observe mode it logs but returns neutral graph.
                    var graph = director != null
                        ? director.Compose(rawFrame)
                        : new RenderGraph();

                    // Final CPU smoothing/decay produces the AudioUBO for GPU upload.
                    var ubo = visualSmoother!.Smooth(graph, rawFrame);

                    // AI adjustments are routed through AdaptiveProfileManager
                    // (set up at startup). The director's Compose() already blends
                    // adaptive baselines with reactive values. No direct UBO override.

                    var spectrum = audio.GetSpectrum();
                    var leftSpec = audio.GetLeftSpectrum();
                    var rightSpec = audio.GetRightSpectrum();
                    
                    // Ensure arrays are not null before passing to renderer
                    if (spectrum == null) spectrum = new float[1024];
                    if (leftSpec == null) leftSpec = spectrum;
                    if (rightSpec == null) rightSpec = spectrum;
                    
                    renderer.UpdateAudioData(ref ubo, spectrum, leftSpec, rightSpec);

                    rawFrame.LatRenderMs = renderer.RenderLatencyMs;
                    rawFrame.LatTotalPipelineMs += renderer.RenderLatencyMs;
                    renderer.UpdateHUD(rawFrame);
                    renderer.Render(time);

                    directorHud?.UpdateSnapshot(rawFrame, graph, director, ollamaFeedback);
                }
                catch (Exception ex)
                {
                    DebugLogger.WriteCrash(ex, "Render loop");
                    break;
                }
            }
        };

        form.FormClosing += (s, e) =>
        {
            DebugLogger.Info("Shutting down...");
            audio?.Stop();
            ollamaFeedback?.Dispose();
            musicAI?.Dispose();
            directorHud?.Dispose();
            renderer?.Dispose();
        };

        Application.Run(form);
    }

    /// <summary>
    /// Create the DX12 Ultimate renderer. Falls back to DX11 if DX12 fails.
    /// </summary>
    static IRenderer CreateRenderer(IntPtr hwnd, int width, int height)
    {
        if (!_forceDx11Only)
        {
            try
            {
                return new DX12Renderer(hwnd, width, height);
            }
            catch (Exception ex)
            {
                DebugLogger.Warn($"DX12 renderer init failed, falling back to DX11: {ex}");
            }
        }

        return new DX11Renderer(hwnd, width, height);
    }

    [DllImport("user32.dll")]
    static extern bool PeekMessage(out NativeMessage msg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [StructLayout(LayoutKind.Sequential)]
    struct NativeMessage
    {
        public IntPtr hWnd;
        public uint msg;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public System.Drawing.Point p;
    }

    static bool AppStillIdle()
    {
        NativeMessage msg;
        return !PeekMessage(out msg, IntPtr.Zero, 0, 0, 0);
    }
}

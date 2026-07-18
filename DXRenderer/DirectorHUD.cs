using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;
using StageSimWASAPI;

namespace DXRenderer;

/// <summary>
/// Compact dark-themed control panel for the music visualizer director bot.
/// Modeled after the smc-autosort game bot control panel.
/// Shows brain state, director state, activity log, and mode controls.
/// </summary>
public class DirectorHUD : Form
{
    // Colors — dark theme matching smc-autosort
    private static readonly Color BG          = Color.FromArgb(13, 17, 23);   // #0d1117
    private static readonly Color BG_CARD     = Color.FromArgb(22, 27, 34);   // #161b22
    private static readonly Color BG_INPUT    = Color.FromArgb(13, 17, 23);   // #0d1117
    private static readonly Color FG          = Color.FromArgb(230, 237, 243); // #e6edf3
    private static readonly Color FG_DIM      = Color.FromArgb(125, 133, 144); // #7d8590
    private static readonly Color ACCENT      = Color.FromArgb(0, 255, 204);   // #00ffcc
    private static readonly Color ACCENT_RED  = Color.FromArgb(255, 107, 107); // #ff6b6b
    private static readonly Color ACCENT_YEL  = Color.FromArgb(240, 192, 64);  // #f0c040
    private static readonly Color ACCENT_GRN  = Color.FromArgb(63, 185, 80);   // #3fb950
    private static readonly Color ACCENT_PUR  = Color.FromArgb(188, 140, 255); // #bc8cff
    private static readonly Color ACCENT_BLU  = Color.FromArgb(88, 166, 255);  // #58a6ff
    private static readonly Color BORDER      = Color.FromArgb(48, 54, 61);    // #30363d

    private readonly VisualDirectorBot _director;
    private readonly OllamaVisionFeedback? _ollama;
    private MusicBrainAI? _musicAI;

    private readonly Label _modeIndicator;
    private readonly Label _brainLabel;
    private readonly Label _botLabel;
    private readonly Label _ollamaLabel;
    private readonly RichTextBox _chatBox;
    private readonly TextBox _chatInput;
    private readonly Button _btnSend;
    private readonly Button _btnAuto;
    private readonly Button _btnObserve;
    private readonly Button _btnOff;
    private readonly Button _btnOllama;
    private readonly Button _btnMusicAI;
    private readonly Button _btnGenerate;
    private readonly Button _btnClear;
    private readonly FlowLayoutPanel _moodPanel;
    private readonly List<string> _logBuffer = new();
    private const int MAX_LOG = 80;
    private string _lastShownSuggestion = "";

    private static readonly string[] SectionNames = {
        "Unknown", "Intro", "Verse", "PreChorus", "Chorus",
        "BuildUp", "Drop", "Breakdown", "Bridge", "Interlude", "Outro"
    };

    public DirectorHUD(VisualDirectorBot director, OllamaVisionFeedback? ollama, MusicBrainAI? musicAI = null)
    {
        _director = director;
        _ollama = ollama;
        _musicAI = musicAI;

        Text = "MusicBot — RTX Audio Visualizer";
        Size = new Size(440, 640);
        StartPosition = FormStartPosition.Manual;
        Location = new Point(10, 10);
        TopMost = true;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        BackColor = BG;
        ForeColor = FG;
        Font = new Font("Consolas", 9f);
        MaximizeBox = false;
        MinimizeBox = false;

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 8,
            Padding = new Padding(0)
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // 0: header
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // 1: brain state
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // 2: director state
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // 3: ollama state
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // 4: mode buttons
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // 5: mood buttons
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));  // 6: log
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));       // 7: footer

        // --- Header ---
        var header = new Panel { BackColor = BG_CARD, Dock = DockStyle.Fill, Height = 36 };
        var title = new Label
        {
            Text = "MusicBot",
            ForeColor = ACCENT,
            Font = new Font("Segoe UI", 13f, FontStyle.Bold),
            Dock = DockStyle.Left,
            TextAlign = ContentAlignment.MiddleLeft,
            Padding = new Padding(12, 0, 0, 0)
        };
        _modeIndicator = new Label
        {
            Text = "AUTO",
            ForeColor = ACCENT_YEL,
            Font = new Font("Segoe UI", 9f, FontStyle.Bold),
            Dock = DockStyle.Right,
            TextAlign = ContentAlignment.MiddleRight,
            Padding = new Padding(0, 0, 12, 0)
        };
        header.Controls.Add(title);
        header.Controls.Add(_modeIndicator);
        layout.Controls.Add(header, 0, 0);

        // --- Brain State ---
        _brainLabel = CreateSectionLabel("Brain State", ACCENT);
        layout.Controls.Add(_brainLabel, 0, 1);

        // --- Director State ---
        _botLabel = CreateSectionLabel("Director", ACCENT_BLU);
        layout.Controls.Add(_botLabel, 0, 2);

        // --- Ollama State ---
        _ollamaLabel = CreateSectionLabel("Ollama AI", ACCENT_PUR);
        layout.Controls.Add(_ollamaLabel, 0, 3);

        // --- Mode Buttons ---
        var btnPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Padding = new Padding(12, 4, 12, 4),
            BackColor = BG
        };
        _btnAuto = CreateModeButton("Auto", ACCENT_YEL);
        _btnAuto.Click += (s, e) => { director.Mode = VisualDirectorBot.DirectorMode.Auto; RefreshControls(); };
        _btnObserve = CreateModeButton("Observe", ACCENT_PUR);
        _btnObserve.Click += (s, e) => { director.Mode = VisualDirectorBot.DirectorMode.Observe; RefreshControls(); };
        _btnOff = CreateModeButton("Off", ACCENT_RED);
        _btnOff.Click += (s, e) => { director.Mode = VisualDirectorBot.DirectorMode.Off; RefreshControls(); };
        _btnOllama = CreateModeButton("Ollama", ACCENT_GRN);
        _btnOllama.Click += (s, e) => { if (_ollama != null) _ollama.Enabled = !_ollama.Enabled; RefreshControls(); };
        _btnMusicAI = CreateModeButton("Music AI", ACCENT_BLU);
        _btnMusicAI.Click += (s, e) => { if (_musicAI != null) _musicAI.Enabled = !_musicAI.Enabled; RefreshControls(); };
        _btnGenerate = CreateModeButton("Generate", ACCENT);
        _btnGenerate.Click += (s, e) => { _ollama?.RequestGenerate(); Log("Generate requested — AI will produce adjustments next cycle"); };
        _btnClear = CreateModeButton("Clear AI", ACCENT_RED);
        _btnClear.Click += (s, e) => { _ollama?.ClearAdjustments(); Log("AI adjustments cleared"); };
        btnPanel.Controls.Add(_btnAuto);
        btnPanel.Controls.Add(_btnObserve);
        btnPanel.Controls.Add(_btnOff);
        btnPanel.Controls.Add(_btnOllama);
        btnPanel.Controls.Add(_btnMusicAI);
        btnPanel.Controls.Add(_btnGenerate);
        btnPanel.Controls.Add(_btnClear);
        layout.Controls.Add(btnPanel, 0, 4);

        // --- Mood Buttons ---
        var moodHeader = new Label
        {
            Text = "Mood",
            ForeColor = FG_DIM,
            Font = new Font("Segoe UI", 8f),
            Dock = DockStyle.Top,
            Padding = new Padding(12, 4, 0, 0),
            BackColor = BG
        };
        _moodPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight,
            Padding = new Padding(12, 0, 12, 4),
            BackColor = BG
        };
        foreach (var mood in (VisualDirectorBot.MoodPreset[])Enum.GetValues(typeof(VisualDirectorBot.MoodPreset)))
        {
            var btn = new Button
            {
                Text = mood.ToString(),
                Tag = mood,
                AutoSize = true,
                BackColor = BG_CARD,
                ForeColor = FG,
                FlatStyle = FlatStyle.Flat,
                Font = new Font("Segoe UI", 8f, FontStyle.Bold),
                Padding = new Padding(8, 2, 8, 2),
                Margin = new Padding(0, 0, 4, 0)
            };
            btn.Click += (s, e) =>
            {
                director.Mood = (VisualDirectorBot.MoodPreset)((Button)s!).Tag!;
                RefreshControls();
            };
            _moodPanel.Controls.Add(btn);
        }
        var moodContainer = new Panel { Dock = DockStyle.Fill, AutoSize = true, BackColor = BG };
        moodContainer.Controls.Add(_moodPanel);
        moodContainer.Controls.Add(moodHeader);
        layout.Controls.Add(moodContainer, 0, 5);

        // --- Chat / Activity Log ---
        var chatFrame = new Panel { Dock = DockStyle.Fill, BackColor = BG, Padding = new Padding(12, 4, 12, 4) };
        var chatLabel = new Label
        {
            Text = "Chat / Activity Log",
            ForeColor = FG_DIM,
            Font = new Font("Segoe UI", 8f),
            Dock = DockStyle.Top,
            Padding = new Padding(0, 0, 0, 2)
        };
        _chatBox = new RichTextBox
        {
            ReadOnly = true,
            BackColor = BG_CARD,
            ForeColor = FG,
            BorderStyle = BorderStyle.None,
            Font = new Font("Consolas", 8f),
            Dock = DockStyle.Fill,
            ScrollBars = RichTextBoxScrollBars.Vertical
        };
        // Input row at bottom of chat frame
        var inputPanel = new Panel
        {
            Dock = DockStyle.Bottom,
            Height = 30,
            BackColor = BG_INPUT
        };
        _btnSend = new Button
        {
            Text = "Send",
            Width = 60,
            Dock = DockStyle.Right,
            FlatStyle = FlatStyle.Flat,
            BackColor = BG_CARD,
            ForeColor = ACCENT,
            Font = new Font("Segoe UI", 8f, FontStyle.Bold)
        };
        _chatInput = new TextBox
        {
            Dock = DockStyle.Fill,
            BackColor = BG_INPUT,
            ForeColor = FG,
            Font = new Font("Consolas", 9f),
            BorderStyle = BorderStyle.FixedSingle,
            PlaceholderText = "Type a message or goal..."
        };
        _chatInput.KeyDown += (s, e) =>
        {
            if (e.KeyCode == Keys.Enter && !e.Shift)
            {
                e.SuppressKeyPress = true;
                SendChatMessage();
            }
        };
        _btnSend.Click += (s, e) => SendChatMessage();
        inputPanel.Controls.Add(_chatInput);
        inputPanel.Controls.Add(_btnSend);
        chatFrame.Controls.Add(_chatBox);
        chatFrame.Controls.Add(inputPanel);
        chatFrame.Controls.Add(chatLabel);
        layout.Controls.Add(chatFrame, 0, 6);

        // Seed the chat with a welcome message
        AppendChatLine("[System] ", FG_DIM);
        AppendChatLine("Chat ready. Type a goal like 'build energy toward a drop'\n", FG_DIM);
        AppendChatLine("[System] ", FG_DIM);
        AppendChatLine("Or ask questions like 'what mode fits this genre?'\n\n", FG_DIM);

        // --- Footer ---
        var footer = new Label
        {
            Text = "M=Next  N=Prev  H=Brain HUD  B=Toggle  D=Cycle Dir  O=Ollama  G=MusicAI  ESC=Quit",
            ForeColor = FG_DIM,
            Font = new Font("Segoe UI", 7f),
            Dock = DockStyle.Bottom,
            TextAlign = ContentAlignment.BottomLeft,
            Padding = new Padding(12, 2, 12, 4),
            BackColor = BG
        };
        layout.Controls.Add(footer, 0, 7);

        Controls.Add(layout);
        RefreshControls();
    }

    private static Label CreateSectionLabel(string title, Color accentColor)
    {
        return new Label
        {
            Text = title,
            Dock = DockStyle.Fill,
            AutoSize = false,
            Height = 70,
            BackColor = BG_CARD,
            ForeColor = FG,
            Font = new Font("Consolas", 8f),
            Padding = new Padding(12, 4, 12, 4),
            BorderStyle = BorderStyle.None
        };
    }

    private static Button CreateModeButton(string text, Color accentColor)
    {
        return new Button
        {
            Text = text,
            AutoSize = true,
            BackColor = BG_CARD,
            ForeColor = accentColor,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 8f, FontStyle.Bold),
            Padding = new Padding(10, 3, 10, 3),
            Margin = new Padding(0, 0, 4, 0)
        };
    }

    private void RefreshControls()
    {
        _modeIndicator.Text = _director.ModeLabel;
        _modeIndicator.ForeColor = _director.Mode switch
        {
            VisualDirectorBot.DirectorMode.Auto => ACCENT_YEL,
            VisualDirectorBot.DirectorMode.Observe => ACCENT_PUR,
            VisualDirectorBot.DirectorMode.Off => ACCENT_RED,
            _ => FG_DIM
        };

        // Highlight active mode button
        _btnAuto.BackColor = _director.Mode == VisualDirectorBot.DirectorMode.Auto ? Color.FromArgb(60, 50, 20) : BG_CARD;
        _btnObserve.BackColor = _director.Mode == VisualDirectorBot.DirectorMode.Observe ? Color.FromArgb(50, 40, 70) : BG_CARD;
        _btnOff.BackColor = _director.Mode == VisualDirectorBot.DirectorMode.Off ? Color.FromArgb(70, 30, 30) : BG_CARD;
        _btnOllama.Text = _ollama?.Enabled != true ? "Ollama" : _ollama.IsConnected ? "Ollama ✓" : "Ollama …";
        _btnOllama.BackColor = _ollama?.Enabled != true ? BG_CARD : _ollama.IsConnected ? Color.FromArgb(20, 50, 30) : Color.FromArgb(50, 40, 20);
        _btnMusicAI.Text = _musicAI?.Enabled != true ? "Music AI" : _musicAI.IsConnected ? "Music AI ✓" : "Music AI …";
        _btnMusicAI.BackColor = _musicAI?.Enabled != true ? BG_CARD : _musicAI.IsConnected ? Color.FromArgb(20, 30, 50) : Color.FromArgb(40, 35, 20);
        _btnGenerate.BackColor = BG_CARD;
        _btnClear.BackColor = _ollama?.Graph.ActiveCurveCount > 0 ? Color.FromArgb(50, 25, 25) : BG_CARD;

        foreach (Button btn in _moodPanel.Controls)
        {
            btn.BackColor = ((VisualDirectorBot.MoodPreset)btn.Tag! == _director.Mood)
                ? Color.FromArgb(30, 60, 90)
                : BG_CARD;
        }
    }

    public void Log(string message)
    {
        if (InvokeRequired)
        {
            Invoke(new Action(() => Log(message)));
            return;
        }
        var timestamp = DateTime.Now.ToString("HH:mm:ss");
        AppendChatLine($"[{timestamp}] ", FG_DIM);
        AppendChatLine(message + "\n", FG);
        ScrollChatToEnd();
    }

    /// <summary>
    /// Append colored text to the chat box.
    /// </summary>
    private void AppendChatLine(string text, Color color)
    {
        if (IsDisposed || !IsHandleCreated || _chatBox.IsDisposed) return;
        _chatBox.SelectionStart = _chatBox.TextLength;
        _chatBox.SelectionLength = 0;
        _chatBox.SelectionColor = color;
        _chatBox.AppendText(text);
        _chatBox.SelectionColor = _chatBox.ForeColor;
    }

    private void ScrollChatToEnd()
    {
        _chatBox.SelectionStart = _chatBox.TextLength;
        _chatBox.ScrollToCaret();
    }

    /// <summary>
    /// Send a chat message to the Music AI and display the response.
    /// </summary>
    private async void SendChatMessage()
    {
        var text = _chatInput.Text.Trim();
        if (string.IsNullOrEmpty(text)) return;
        _chatInput.Clear();

        // Show user message
        AppendChatLine("[You] ", ACCENT_BLU);
        AppendChatLine(text + "\n", FG);
        ScrollChatToEnd();

        if (_musicAI == null)
        {
            AppendChatLine("[System] ", FG_DIM);
            AppendChatLine("Music AI not initialized.\n", FG_DIM);
            ScrollChatToEnd();
            return;
        }

        if (!_musicAI.Enabled)
        {
            _musicAI.Enabled = true;
            AppendChatLine("[System] ", FG_DIM);
            AppendChatLine("Music AI enabled.\n", FG_DIM);
        }

        AppendChatLine("[AI] ", ACCENT_GRN);
        AppendChatLine("Thinking...\n", FG_DIM);
        ScrollChatToEnd();

        try
        {
            await _musicAI.SetGoalAsync(text);
            var plan = _musicAI.Plan;
            // Remove the "Thinking..." line
            var thinkingLen = "[AI] Thinking...\n".Length;
            _chatBox.SelectionStart = _chatBox.TextLength - thinkingLen;
            _chatBox.SelectionLength = thinkingLen;
            _chatBox.SelectedText = "";

            if (plan.Count > 0)
            {
                AppendChatLine("[AI] ", ACCENT_GRN);
                AppendChatLine($"Goal: {text}\n", FG);
                AppendChatLine($"Plan ({plan.Count} steps):\n", FG);
                foreach (var step in plan)
                {
                    AppendChatLine($"  {step.Step}. {step.Action} {step.Value}\n", FG_DIM);
                    AppendChatLine($"     done when: {step.DoneWhen}\n", FG_DIM);
                }
                AppendChatLine("\n", FG);
            }

            var eval = _musicAI.GetLatestEvaluation();
            if (eval != null && !string.IsNullOrEmpty(eval.Suggestion))
            {
                AppendChatLine("[AI] ", ACCENT_GRN);
                AppendChatLine(eval.Suggestion + "\n\n", FG);
            }
        }
        catch (Exception ex)
        {
            AppendChatLine("[Error] ", ACCENT_RED);
            AppendChatLine(ex.Message + "\n", ACCENT_RED);
        }

        ScrollChatToEnd();
    }

    /// <summary>
    /// Refresh the HUD display from the latest frame state.
    /// </summary>
    public void UpdateSnapshot(
        QuadBufferedVisuals.VisualFrame frame,
        RenderGraph graph,
        VisualDirectorBot? director,
        OllamaVisionFeedback? ollama)
    {
        if (InvokeRequired)
        {
            Invoke(new Action(() => UpdateSnapshot(frame, graph, director, ollama)));
            return;
        }

        if (IsDisposed || !IsHandleCreated) return;

        string sectionName = frame.Section >= 0 && frame.Section < SectionNames.Length
            ? SectionNames[frame.Section]
            : "?";
        bool silent = frame.IsSilent != 0;

        _brainLabel.Text =
            $"  Brain: {sectionName} | BPM:{frame.BPM:F1} | Beat:{frame.BeatIntensity:F3}\n" +
            $"  Energy:{frame.Overall:F3} | Clarity:{frame.SpectralClarity:F2} | Persist:{frame.MotionPersistence:F2}\n" +
            $"  B:{frame.Band1:F2} M:{frame.Band3:F2} H:{frame.Band6:F2} | Silent:{(silent ? "Y" : "N")}";

        _botLabel.Text =
            $"  Bot: {director?.ModeLabel ?? "-"} | Node:{director?.CurrentGraphNode ?? "-"} | Mood:{director?.Mood}\n" +
            $"  Intensity:{graph.Intensity:F2} Pulse:{graph.Pulse:F2} Accent:{graph.Accent:F2}\n" +
            $"  ColorShift:{graph.ColorShift:F2} Speed:{graph.Speed:F2} Zoom:{graph.Zoom:F2}";

        string ollamaStatus = ollama?.Enabled != true ? "OFF" : ollama.IsConnected ? "ON" : "WAITING";
        string visionObs = ollama?.VisionObservation?.Trim() ?? "";
        if (visionObs.Length > 80) visionObs = visionObs.Substring(0, 80) + "...";
        string suggestion = ollama?.Graph.LastSuggestion?.Trim() ?? "";
        if (suggestion.Length > 60) suggestion = suggestion.Substring(0, 60) + "...";

        string musicStatus = _musicAI?.Enabled != true ? "OFF" : _musicAI.IsConnected ? "ON" : "WAITING";
        string musicGoal = _musicAI?.CurrentGoal?.Trim() ?? "";
        if (musicGoal.Length > 40) musicGoal = musicGoal.Substring(0, 40) + "...";

        string autoLabel = ollama?.AutoApply == true ? "AUTO" : ollama?.IsCurrentModeAutonomous == true ? "AUTONOMOUS" : "OBSERVE";
        _ollamaLabel.Text =
            $"  Ollama: {ollamaStatus} [{autoLabel}] | Curves:{ollama?.Graph.ActiveCurveCount ?? 0} KF:{ollama?.Graph.TotalKeyframeCount ?? 0}\n" +
            $"  Fast: B={ollama?.FastBrightness:F2} M={ollama?.FastMotion:F2} C={ollama?.FastColorVariance:F2}\n" +
            $"  Vision: {visionObs}\n" +
            $"  AI: {suggestion}\n" +
            $"  Music AI: {musicStatus} | Goal: {musicGoal} | Plan: {_musicAI?.PlanIndex ?? 0}/{_musicAI?.PlanCount ?? 0}";

        // Show new AI suggestions in the chat
        if (_musicAI != null)
        {
            var eval = _musicAI.GetLatestEvaluation();
            if (eval != null && !string.IsNullOrEmpty(eval.Suggestion) && eval.Suggestion != _lastShownSuggestion)
            {
                _lastShownSuggestion = eval.Suggestion;
                AppendChatLine("[AI] ", ACCENT_GRN);
                AppendChatLine(eval.Suggestion + "\n", FG);
                ScrollChatToEnd();
            }
        }

        RefreshControls();
    }
}

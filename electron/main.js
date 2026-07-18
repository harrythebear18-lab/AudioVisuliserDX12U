const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const { spawn } = require('child_process');

let mainWindow = null;
let rdmaReader = null;
let frameBuffer = [];  // quad buffer on renderer side
const MAX_FRAMES = 4;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 720,
    title: 'RTX Audio Visualizer',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      webgl: true,
      experimentalFeatures: true,
    }
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  if (process.argv.includes('--dev')) {
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  }

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// Spawn C# RDMAReader — reads from RDMA shared memory, outputs JSON frames via stdout
function startRDMAReader() {
  const dllPath = path.join(__dirname, '..', 'RDMAReader', 'bin', 'Debug', 'net10.0', 'RDMAReader.dll');
  rdmaReader = spawn('dotnet', [dllPath], {
    cwd: path.join(__dirname, '..'),
    stdio: ['pipe', 'pipe', 'pipe']
  });

  let lineBuffer = '';

  rdmaReader.stdout.on('data', (data) => {
    lineBuffer += data.toString();
    const lines = lineBuffer.split('\n');
    lineBuffer = lines.pop(); // keep incomplete line

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('RDMA') || trimmed.startsWith('Connected')) {
        console.log(`[rdma-reader] ${trimmed}`);
        continue;
      }
      try {
        const frame = JSON.parse(trimmed);
        // Quad buffer — push, trim old frames
        frameBuffer.push(frame);
        while (frameBuffer.length > MAX_FRAMES) frameBuffer.shift();

        // Send latest frame to renderer
        if (mainWindow && !mainWindow.isDestroyed()) {
          mainWindow.webContents.send('audio-frame', frame);
        }
      } catch (e) {
        // not JSON, log it
        console.log(`[rdma-reader] ${trimmed}`);
      }
    }
  });

  rdmaReader.stderr.on('data', (data) => {
    console.error(`[rdma-reader-error] ${data.toString().trim()}`);
  });

  rdmaReader.on('exit', (code) => {
    console.log(`[rdma-reader] Process exited with code ${code}`);
  });
}

app.whenReady().then(() => {
  createWindow();
  startRDMAReader();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (rdmaReader) {
    rdmaReader.kill();
    rdmaReader = null;
  }
  if (process.platform !== 'darwin') app.quit();
});

ipcMain.handle('get-audio-status', () => {
  return rdmaReader ? 'running' : 'stopped';
});
